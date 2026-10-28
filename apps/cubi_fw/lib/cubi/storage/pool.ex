defmodule Cubi.Storage.Pool do
  @moduledoc """
  Brings up a storage node's pool and the `<pool>/cubi` tree
  (docs/specs.md §2.10.3), idempotently, so running it again after a BEAM
  restart finds everything in place:

  1. load `spl` with a host ID derived from the machine ID, then `zfs`;
  2. import the pool, or create it if none is found, `cubi.zfs.create=1` was
     given and every listed disk is blank (`wipefs`). Never `-f`;
  3. create what is missing of `<pool>/cubi` and `<pool>/cubi/identity`,
     mount them on `/cubi` and `/cubi/identity`;
  4. with a key, create or unlock `<pool>/cubi/crypt` and mount its
     children on `/cubi/khepri` and `/cubi/log`. Without one, an existing
     `crypt` stays locked.

  The only key so far is `cubi.zfs.testkey=` (QEMU, no cluster); phase 7
  brings the cluster's. It reaches `zfs` on stdin, never argv or a file.
  `crypt` records that it was keyed this way (`cubi:testkey=on`) so that
  bootstrap and join can refuse it.

  Every command goes through `opts[:run]`, `(argv, stdin | nil) ->
  {output, exit_status}`, so that tests can stand in for ZFS.
  """

  require Logger

  alias Cubi.Storage.{Args, Devices}

  @zpool "/usr/sbin/zpool"
  @zfs "/usr/sbin/zfs"
  @wipefs "/sbin/wipefs"
  @modprobe "/sbin/modprobe"
  @mount_zfs "/sbin/mount.zfs"

  @type crypt :: :mounted | :locked | :absent
  @type result :: %{pool: String.t(), created: boolean(), crypt: crypt()}

  @type opt ::
          {:run, ([String.t()], binary() | nil -> {String.t(), non_neg_integer()})}
          | {:key, binary() | nil}
          | {:machine_id, String.t()}
          | {:refreservation, String.t()}
          | {:sys, Path.t()}
          | {:mounts, Path.t()}
          | {:mountpoint, Path.t()}

  @doc """
  `{:ok, result}`, or `{:error, reason}` with nothing created. `args.vdevs`
  must not be `nil`: a diskless node has no pool.
  """
  @spec setup(Args.t(), [opt()]) :: {:ok, result()} | {:error, term()}
  def setup(%Args{vdevs: vdevs} = args, opts) when is_list(vdevs) do
    opts = Keyword.merge(defaults(), opts)

    with :ok <- load_zfs(opts),
         {:ok, created} <- import_or_create(args, opts),
         :ok <- cubi_tree(args.pool, opts),
         {:ok, crypt} <- crypt(args.pool, opts) do
      {:ok, %{pool: args.pool, created: created, crypt: crypt}}
    end
  end

  defp defaults() do
    [
      run: &run/2,
      key: nil,
      refreservation: "4G",
      sys: "/sys",
      mounts: "/proc/mounts",
      mountpoint: "/cubi"
    ]
  end

  @doc """
  The `spl_hostid` for a machine ID: 32 bits of its SHA-256, never 0, which
  ZFS treats as no host ID at all (docs/phase0.md).
  """
  @spec hostid(String.t()) :: pos_integer()
  def hostid(machine_id) do
    case :crypto.hash(:sha256, "cubi-hostid:" <> machine_id) do
      <<0::32, _::binary>> -> 1
      <<id::32, _::binary>> -> id
    end
  end

  ## 1. Modules

  defp load_zfs(opts) do
    hostid = hostid(Keyword.fetch!(opts, :machine_id))
    param = Path.join(opts[:sys], "module/spl/parameters/spl_hostid")

    case File.read(param) do
      {:error, :enoent} ->
        with :ok <- cmd(opts, [@modprobe, "spl", "spl_hostid=#{hostid}"]),
             do: cmd(opts, [@modprobe, "zfs"])

      # Loaded already (a BEAM restart): only right if with our host ID.
      {:ok, value} ->
        if String.trim(value) == Integer.to_string(hostid),
          do: cmd(opts, [@modprobe, "zfs"]),
          else: {:error, {:spl_hostid, String.trim(value)}}
    end
  end

  ## 2. Import or create

  defp import_or_create(args, opts) do
    with {:ok, devices} <- Devices.resolve(args.vdevs, opts[:sys]) do
      case imported?(args.pool, opts) or import_pool(args.pool, opts) do
        true ->
          check_vdevs(args.pool, devices, opts)
          {:ok, false}

        :not_found when args.create ->
          create(args.pool, devices, opts)

        :not_found ->
          {:error, {:no_pool, args.pool}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp imported?(pool, opts),
    do: match?({_, 0}, exec(opts, [@zpool, "list", "-H", "-o", "name", pool]))

  # -N: nothing may mount on a read-only rootfs. cachefile=none: nowhere to
  # keep one. -d /dev: labels carry GUIDs, so scanning finds the pool
  # whatever the device names.
  defp import_pool(pool, opts) do
    case exec(opts, [@zpool, "import", "-N", "-o", "cachefile=none", "-d", "/dev", pool]) do
      {_, 0} ->
        true

      {out, _} ->
        if out =~ "no such pool available", do: :not_found, else: {:error, {:import, pool, out}}
    end
  end

  defp create(pool, devices, opts) do
    disks = for "/dev/" <> _ = d <- devices, do: d

    case Enum.flat_map(disks, &signatures(&1, opts)) do
      [] ->
        argv = [@zpool, "create", "-o", "cachefile=none", "-O", "mountpoint=none", pool | devices]
        with :ok <- cmd(opts, argv), do: {:ok, true}

      dirty ->
        {:error, {:not_blank, dirty}}
    end
  end

  # [] for a blank disk, else what wipefs finds on it: a partition table, a
  # filesystem, a ZFS label from another pool...
  defp signatures(disk, opts) do
    case exec(opts, [@wipefs, "--no-act", "--noheadings", "--output", "TYPE", disk]) do
      {out, 0} -> for type <- String.split(out, "\n", trim: true), do: {disk, type}
      {out, _} -> [{disk, {:wipefs, String.trim(out)}}]
    end
  end

  # The pool may have been grown or repaired by hand: say so, carry on.
  defp check_vdevs(pool, devices, opts) do
    wanted = for "/dev/" <> disk <- devices, into: MapSet.new(), do: disk

    with {out, 0} <- exec(opts, [@zpool, "status", "-P", pool]) do
      found =
        for [path] <- Regex.scan(~r{(?<=\s)/dev/\S+}, out),
            into: MapSet.new(),
            do: disk_of(path, opts)

      if found != wanted,
        do:
          Logger.warning(
            "pool #{pool} is on #{Enum.join(found, " ")}, cubi.vdevs names #{Enum.join(wanted, " ")}"
          )
    end

    :ok
  end

  # /dev/vda1 -> vda, /dev/nvme0n1p1 -> nvme0n1: the partition's parent in sysfs.
  defp disk_of("/dev/" <> name, opts) do
    link = Path.join([opts[:sys], "class/block", name])

    case File.read_link(link) do
      {:ok, target} ->
        if File.exists?(Path.join(link, "partition")),
          do: target |> Path.dirname() |> Path.basename(),
          else: name

      {:error, _} ->
        name
    end
  end

  ## 3. <pool>/cubi and identity

  defp cubi_tree(pool, opts) do
    datasets = datasets(pool, opts)
    base = "#{pool}/cubi"

    # Ra fsyncs its WAL: sync=disabled is never allowed.
    props =
      ~w(mountpoint=legacy compression=lz4 atime=off sync=standard) ++
        ["refreservation=#{opts[:refreservation]}"]

    with :ok <- ensure(datasets, base, props, opts),
         :ok <- ensure(datasets, base <> "/identity", [], opts),
         :ok <- mount(base, opts[:mountpoint], opts) do
      mount(base <> "/identity", Path.join(opts[:mountpoint], "identity"), opts)
    end
  end

  defp datasets(pool, opts) do
    case exec(opts, [@zfs, "list", "-H", "-o", "name", "-r", pool]) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end

  defp ensure(datasets, name, props, opts) do
    if name in datasets,
      do: :ok,
      else: cmd(opts, [@zfs, "create" | Enum.flat_map(props, &["-o", &1])] ++ [name])
  end

  defp mount(dataset, dir, opts) do
    if mounted?(dataset, dir, opts) do
      :ok
    else
      File.mkdir_p!(dir)
      cmd(opts, [@mount_zfs, dataset, dir])
    end
  end

  defp mounted?(dataset, dir, opts) do
    case File.read(opts[:mounts]) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.any?(&match?([^dataset, ^dir, "zfs" | _], String.split(&1, " ")))

      {:error, _} ->
        false
    end
  end

  ## 4. crypt

  defp crypt(pool, opts) do
    crypt = "#{pool}/cubi/crypt"
    key = opts[:key]
    exists = crypt in datasets(pool, opts)

    cond do
      key == nil and exists ->
        {:ok, :locked}

      key == nil ->
        {:ok, :absent}

      exists ->
        with :ok <- load_key(crypt, key, opts), do: mount_crypt(crypt, opts)

      true ->
        argv =
          [@zfs, "create"] ++
            Enum.flat_map(
              ~w(encryption=aes-256-gcm keyformat=hex keylocation=prompt canmount=off cubi:testkey=on),
              &["-o", &1]
            ) ++ [crypt]

        with :ok <- cmd(opts, argv, key <> "\n"),
             :ok <- cmd(opts, [@zfs, "create", crypt <> "/khepri"]),
             :ok <- cmd(opts, [@zfs, "create", crypt <> "/log"]),
             do: mount_crypt(crypt, opts)
    end
  end

  defp load_key(crypt, key, opts) do
    case exec(opts, [@zfs, "get", "-H", "-o", "value", "keystatus", crypt]) do
      {"available" <> _, 0} -> :ok
      _ -> cmd(opts, [@zfs, "load-key", "-L", "prompt", crypt], key <> "\n")
    end
  end

  defp mount_crypt(crypt, opts) do
    with :ok <- mount(crypt <> "/khepri", Path.join(opts[:mountpoint], "khepri"), opts),
         :ok <- mount(crypt <> "/log", Path.join(opts[:mountpoint], "log"), opts),
         do: {:ok, :mounted}
  end

  ## Commands

  defp cmd(opts, argv, input \\ nil) do
    case exec(opts, argv, input) do
      {_, 0} -> :ok
      {out, status} -> {:error, {Path.basename(hd(argv)), tl(argv), status, String.trim(out)}}
    end
  end

  defp exec(opts, argv, input \\ nil), do: opts[:run].(argv, input)

  @doc false
  # The real runner. The key goes in on a pipe: zfs reads one line of a hex
  # key from a stdin that is not a terminal.
  @spec run([String.t()], binary() | nil) :: {String.t(), non_neg_integer()}
  def run([exe | args], nil), do: System.cmd(exe, args, stderr_to_stdout: true)

  def run([exe | args], input) do
    port =
      Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, args: args])

    true = Port.command(port, input)
    collect(port, [])
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc, data])
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    end
  end
end
