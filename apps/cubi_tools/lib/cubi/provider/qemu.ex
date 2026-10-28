defmodule Cubi.Provider.Qemu do
  @moduledoc """
  Local QEMU machines as a `Cubi.Provider` (docs/specs.md §2.12.3), for
  development and for the harness.

  Each instance is a **background QEMU process** (`-daemonize`), so it
  outlives the Mix task that created it, like a cloud instance outlives
  `mix cubi.provision`. Its files are under `<dir>/<name>/`:

  | File | What |
  | --- | --- |
  | `instance.json` | id, firmware, size, SMBIOS UUID, MAC and ssh port: what restarts the same machine |
  | `tftp/boot.ipxe` | the script, the one thing the provider stores |
  | `tftp/ipxe.efi`, `tftp/autoexec.ipxe` | UEFI only: what OVMF's PXE client chainloads |
  | `qemu.pid`, `qemu.argv` | the running process, and how it was started |
  | `console.log` | the serial console, appended across reboots |

  **The script is delivered over TFTP by QEMU itself** (user-mode
  networking's `tftp=`, as docs/phase4.md's `:tftp` boots do), never by
  a server of the provider's own: nothing has to outlive the Mix task but
  QEMU. BIOS boots run it from QEMU's iPXE NIC ROM; UEFI boots go through
  OVMF's PXE, `ipxe.efi` and an `autoexec.ipxe` that chains it. The images the
  script names are fetched from wherever its `${base}` points, which the
  guest reaches through user-mode NAT: an HTTPS host, or a local server as
  `http://10.0.2.2:<port>` (the host, as the guest sees it).

  Instances are reachable on `127.0.0.1`, ssh on the port in
  `instance.provider.ssh_port`. A reboot is a cold one: QEMU is stopped and
  started again from `instance.json`, so it fetches the current script.

  Options of `init/1`, all optional:

    * `:dir` - default `_build/cubi/qemu`, relative to the current directory
    * `:qemu` - default `qemu-system-x86_64`
    * `:accel` - `"kvm"` (default) or `"tcg"`
    * `:size` - the default `-m`, `"1024"` (MiB); a spec's `size` is passed
      to `-m` too, so `"2G"` works
    * `:ovmf_dir` - default `/usr/share/OVMF`, for UEFI
    * `:ipxe_efi` - the `ipxe.efi` UEFI instances chainload, default
      `/usr/lib/ipxe/ipxe.efi`; checked when a UEFI instance is created

  `region` is ignored.
  """

  @behaviour Cubi.Provider

  alias Cubi.Provider.Instance

  @name ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/

  @impl true
  def init(opts) do
    {:ok,
     %{
       dir: opts |> Keyword.get(:dir, "_build/cubi/qemu") |> Path.expand(),
       qemu: Keyword.get(opts, :qemu, "qemu-system-x86_64"),
       accel: Keyword.get(opts, :accel, "kvm"),
       size: Keyword.get(opts, :size, "1024"),
       ovmf_dir: Keyword.get(opts, :ovmf_dir, "/usr/share/OVMF"),
       ipxe_efi: Keyword.get(opts, :ipxe_efi, "/usr/lib/ipxe/ipxe.efi")
     }}
  end

  @impl true
  def create(state, spec) do
    dir = instance_dir(state, spec.name)

    cond do
      not Regex.match?(@name, spec.name) ->
        {:error, {:bad_name, spec.name}}

      File.exists?(dir) ->
        {:error, {:name_taken, spec.name}}

      spec.firmware == :uefi and not File.regular?(state.ipxe_efi) ->
        {:error, {:no_ipxe_efi, state.ipxe_efi}}

      true ->
        record = %{
          "id" => random_hex(8),
          "name" => spec.name,
          "firmware" => Atom.to_string(spec.firmware),
          "size" => spec[:size] || state.size,
          "uuid" => uuid(),
          "mac" => mac(),
          "ssh_port" => free_port()
        }

        File.mkdir_p!(Path.join(dir, "tftp"))
        prepare_firmware(state, dir, spec.firmware)
        File.write!(Path.join(dir, "tftp/boot.ipxe"), spec.script)
        File.write!(Path.join(dir, "instance.json"), JSON.encode!(record))

        case start(state, dir, record) do
          :ok ->
            get(state, spec.name)

          {:error, _} = error ->
            File.rm_rf!(dir)
            error
        end
    end
  end

  @impl true
  def list(state) do
    instances =
      state.dir
      |> Path.join("*/instance.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&instance(state, &1 |> Path.dirname() |> Path.basename()))

    {:ok, instances}
  end

  @impl true
  def get(state, name) do
    if Regex.match?(@name, name) and File.regular?(record_path(state, name)),
      do: {:ok, instance(state, name)},
      else: {:error, :not_found}
  end

  @impl true
  def set_script(state, %Instance{name: name}, script) do
    with {:ok, _} <- get(state, name) do
      path = Path.join([instance_dir(state, name), "tftp", "boot.ipxe"])
      File.write!(path <> ".new", script)
      File.rename!(path <> ".new", path)
    end
  end

  @impl true
  def reboot(state, %Instance{name: name}) do
    with {:ok, _} <- get(state, name) do
      dir = instance_dir(state, name)
      stop(dir)
      start(state, dir, read_record(state, name))
    end
  end

  @impl true
  def destroy(state, %Instance{name: name}) do
    with {:ok, _} <- get(state, name) do
      dir = instance_dir(state, name)
      stop(dir)
      File.rm_rf!(dir)
      :ok
    end
  end

  ## Instances

  defp instance(state, name) do
    record = read_record(state, name)
    dir = instance_dir(state, name)

    %Instance{
      id: record["id"],
      name: name,
      status: if(pid(dir), do: :running, else: :stopped),
      addresses: ["127.0.0.1"],
      provider: %{
        dir: dir,
        firmware: String.to_existing_atom(record["firmware"]),
        ssh_port: record["ssh_port"],
        uuid: record["uuid"],
        console: Path.join(dir, "console.log")
      }
    }
  end

  defp instance_dir(state, name), do: Path.join(state.dir, name)
  defp record_path(state, name), do: Path.join(instance_dir(state, name), "instance.json")
  defp read_record(state, name), do: state |> record_path(name) |> File.read!() |> JSON.decode!()

  ## The process

  defp start(state, dir, record) do
    args = argv(state, dir, record)
    File.write!(Path.join(dir, "qemu.argv"), Enum.join(args, "\n") <> "\n")

    # -daemonize: QEMU returns once the machine is set up, and the child
    # keeps running on its own, its stdio on /dev/null and its working
    # directory /, hence absolute paths everywhere.
    case System.cmd(state.qemu, args, cd: dir, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:qemu_failed, status, String.trim(output)}}
    end
  rescue
    e in ErlangError -> {:error, {:qemu_failed, state.qemu, e.original}}
  end

  @doc false
  def argv(state, dir, record) do
    netdev =
      Enum.join(
        [
          "user,id=n0",
          "hostfwd=tcp:127.0.0.1:#{record["ssh_port"]}-:22",
          "tftp=#{opt(Path.join(dir, "tftp"))}"
          | bootfile(record["firmware"])
        ],
        ","
      )

    List.flatten([
      ["-name", "cubi-" <> record["name"]],
      ["-machine", "q35,accel=#{state.accel}", "-cpu", cpu(state.accel)],
      ["-m", record["size"], "-uuid", record["uuid"]],
      ["-smbios", "type=1,uuid=#{record["uuid"]}"],
      ["-display", "none", "-monitor", "none"],
      ["-chardev", "file,id=con,append=on,path=#{opt(Path.join(dir, "console.log"))}"],
      ["-serial", "chardev:con"],
      firmware_args(state, dir, record["firmware"]),
      ["-netdev", netdev, "-device", "virtio-net-pci,netdev=n0,mac=#{record["mac"]},bootindex=0"],
      ["-daemonize", "-pidfile", Path.join(dir, "qemu.pid")]
    ])
  end

  # A value inside QEMU's comma-separated options: commas are doubled.
  defp opt(value), do: String.replace(value, ",", ",,")

  defp bootfile("bios"), do: ["bootfile=boot.ipxe"]
  defp bootfile("uefi"), do: ["bootfile=ipxe.efi"]

  defp cpu("kvm"), do: "host"
  defp cpu(_), do: "max"

  # SeaBIOS, and iPXE's NIC ROM under it, write to VGA unless told otherwise;
  # it reads etc/sercon-port as a raw little-endian integer: 0x3f8 is ttyS0.
  defp firmware_args(_state, dir, "bios"),
    do: ["-fw_cfg", "name=etc/sercon-port,file=#{opt(Path.join(dir, "sercon-port"))}"]

  defp firmware_args(state, dir, "uefi") do
    [
      ["-drive", "if=pflash,format=raw,readonly=on,file=#{opt(ovmf(state, "OVMF_CODE_4M.fd"))}"],
      ["-drive", "if=pflash,format=raw,file=#{opt(Path.join(dir, "OVMF_VARS_4M.fd"))}"]
    ]
  end

  defp prepare_firmware(_state, dir, :bios),
    do: File.write!(Path.join(dir, "sercon-port"), <<0x3F8::little-16>>)

  defp prepare_firmware(state, dir, :uefi) do
    File.cp!(ovmf(state, "OVMF_VARS_4M.fd"), Path.join(dir, "OVMF_VARS_4M.fd"))
    File.cp!(state.ipxe_efi, Path.join(dir, "tftp/ipxe.efi"))
    # autoexec.ipxe runs before iPXE's own DHCP.
    File.write!(Path.join(dir, "tftp/autoexec.ipxe"), "#!ipxe\ndhcp\nchain boot.ipxe\n")
  end

  defp ovmf(state, file), do: Path.join(state.ovmf_dir, file)

  # The pid from qemu.pid, if that process is still this instance's QEMU: a
  # recycled pid runs something else, without our pidfile in its cmdline.
  defp pid(dir) do
    pidfile = Path.join(dir, "qemu.pid")

    with {:ok, text} <- File.read(pidfile),
         {pid, _} <- Integer.parse(text),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- String.contains?(cmdline, <<0>> <> pidfile <> <<0>>) do
      pid
    else
      _ -> nil
    end
  end

  # SIGTERM, which QEMU handles as a clean quit; SIGKILL after 5 s. The
  # console of the stopped run is appended to console.log.
  defp stop(dir) do
    if pid = pid(dir) do
      System.cmd("kill", ["-TERM", Integer.to_string(pid)])

      if not wait_gone(pid, 5_000) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)])
        wait_gone(pid, 5_000)
      end
    end

    File.rm(Path.join(dir, "qemu.pid"))
  end

  defp wait_gone(pid, timeout) do
    cond do
      not File.exists?("/proc/#{pid}") ->
        true

      timeout <= 0 ->
        false

      true ->
        Process.sleep(50)
        wait_gone(pid, timeout - 50)
    end
  end

  ## Identity

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp uuid() do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> ->
      Enum.join([p1, p2, p3, p4, p5], "-")
    end)
  end

  defp mac() do
    <<x, y, z>> = :crypto.strong_rand_bytes(3)

    Enum.map_join(
      [0x52, 0x54, 0x00, x, y, z],
      ":",
      &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
    )
  end

  defp free_port() do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
