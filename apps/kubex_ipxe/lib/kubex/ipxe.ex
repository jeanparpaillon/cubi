defmodule Kubex.Ipxe do
  @moduledoc """
  Turns a Nerves `.fw` into the directory a boot server serves to iPXE
  (docs/specs.md §2.2, §2.3, §2.6):

  | File | From |
  | --- | --- |
  | `vmlinuz` | `/boot/bzImage` inside the `.fw`'s rootfs: the `.fw` has no kernel resource |
  | `stage1.cpio.zst` | the system artifact's `images/` |
  | `rootfs.squashfs` | `data/rootfs.img`, rebuilt without `/boot` and with `/etc/firmware.kv` (below) |
  | `boot.ipxe` | rendered here; relative URLs, so the directory can be served from anywhere |
  | `SHA256SUMS` | the four files above |

  **The served rootfs** is the `.fw`'s, rebuilt with two changes:

    * **no `/boot`.** It only holds the kernel GRUB would load from disk, 5.7 MB
      that iPXE serves separately as `vmlinuz` and that would otherwise sit in
      every node's RAM a second time.
    * **firmware metadata in `/etc/firmware.kv`.** A Nerves install has `fwup`
      write the firmware's metadata (`a.nerves_fw_version`,
      `a.nerves_fw_uuid`, …) into the U-Boot or GRUB environment. A diskless
      node has no such environment, and the UUID only exists once the `.fw` is
      built, after its squashfs is sealed. So it goes into the served squashfs,
      one `key=value` per line, and the firmware's `config/runtime.exs` loads it
      into `Nerves.Runtime.KVBackend.InMemory`.

  The rebuild needs no root, the way Nerves' own `merge-squashfs` works:
  unpack, then repack with a pseudo file that restores every entry's mode and
  owner (`unsquashfs -lln`), and the same sort priorities as `rel2fw.sh`, so
  erlinit's files still come first.
  """

  @kv_path "etc/firmware.kv"

  # rel2fw.sh's built-in priorities: the files read first at boot.
  @sort_priorities "sbin/init 32764\netc/erlinit.config 32763\n"

  # The keys a Nerves fwup.conf writes for slot "a" on a complete install.
  @fw_keys ~w(product description version platform architecture author vcs_identifier misc uuid)

  @type metadata :: %{String.t() => String.t()}

  @doc """
  Builds the served directory. Options:

    * `:firmware` (required) - the `.fw`
    * `:stage1` (required) - `stage1.cpio.zst` from the system artifact
    * `:output` (required) - the directory, wiped first
    * `:cmdline` - kernel arguments in `boot.ipxe`, default `"console=ttyS0"`

  Returns the metadata read from the `.fw`.
  """
  @spec build!(keyword()) :: metadata()
  def build!(opts) do
    fw = Keyword.fetch!(opts, :firmware)
    stage1 = Keyword.fetch!(opts, :stage1)
    output = Keyword.fetch!(opts, :output)
    cmdline = Keyword.get(opts, :cmdline, "console=ttyS0")

    for path <- [fw, stage1], not File.exists?(path), do: raise("no #{path}")

    meta = metadata!(fw)

    File.rm_rf!(output)
    File.mkdir_p!(output)
    work = Path.join(output, ".work")
    File.mkdir_p!(work)

    original = Path.join(work, "rootfs.img")
    File.write!(original, extract!(fw, "data/rootfs.img"))

    {kernel, 0} = cmd!("unsquashfs", ["-cat", original, "boot/bzImage"])
    File.write!(Path.join(output, "vmlinuz"), kernel)

    rebuild_rootfs!(original, Path.join(output, "rootfs.squashfs"), kv(meta), work)

    File.cp!(stage1, Path.join(output, "stage1.cpio.zst"))
    File.write!(Path.join(output, "boot.ipxe"), boot_script(meta, cmdline))
    File.rm_rf!(work)

    File.write!(
      Path.join(output, "SHA256SUMS"),
      for name <- ~w(boot.ipxe rootfs.squashfs stage1.cpio.zst vmlinuz) do
        sum = :crypto.hash(:sha256, File.read!(Path.join(output, name)))
        [Base.encode16(sum, case: :lower), "  ", name, "\n"]
      end
    )

    meta
  end

  @doc "The `.fw`'s metadata, as `fwup -m` reports it, without the `meta-` prefix."
  @spec metadata!(Path.t()) :: metadata()
  def metadata!(fw) do
    {text, 0} = cmd!("fwup", ["-m", "-i", fw])
    parse_metadata(text)
  end

  @doc false
  @spec parse_metadata(String.t()) :: metadata()
  def parse_metadata(text) do
    for line <- String.split(text, "\n", trim: true),
        [key, value] <- [String.split(line, "=", parts: 2)],
        "meta-" <> name = key,
        into: %{} do
      {name, unquote_value(value)}
    end
  end

  defp unquote_value("\"" <> rest),
    do: rest |> String.trim_trailing("\"") |> String.replace(~S(\"), ~S("))

  defp unquote_value(value), do: value

  @doc """
  The KV a Nerves install would have written for this firmware in slot `a`,
  marked active and validated: the boot server only serves images it means
  nodes to run.
  """
  @spec kv(metadata()) :: %{String.t() => String.t()}
  def kv(meta) do
    for {name, value} <- meta,
        key = String.replace(name, "-", "_"),
        key in @fw_keys,
        into: %{"nerves_fw_active" => "a", "nerves_fw_validated" => "1"} do
      {"a.nerves_fw_" <> key, value}
    end
  end

  @doc "`kv/1` as the `/etc/firmware.kv` text: `key=value` lines, sorted."
  @spec encode_kv(%{String.t() => String.t()}) :: String.t()
  def encode_kv(kv) do
    for {key, value} <- Enum.sort(kv), into: "" do
      if String.contains?(value, "\n"), do: raise(ArgumentError, "newline in #{key}")
      "#{key}=#{value}\n"
    end
  end

  @doc "The generic `boot.ipxe`: kernel, stage-1 and the rootfs as a named initrd (§2.2)."
  @spec boot_script(metadata(), String.t()) :: String.t()
  def boot_script(meta, cmdline) do
    """
    #!ipxe
    # #{meta["product"]} #{meta["version"]} (#{meta["uuid"]}), from `mix firmware.ipxe`.
    # URLs are relative to this script. A boot server renders a per-node script
    # instead, with kubex.join= and the token (docs/specs.md §2.7).
    kernel vmlinuz #{cmdline}
    initrd stage1.cpio.zst
    initrd rootfs.squashfs /rootfs.squashfs
    boot
    """
  end

  defp rebuild_rootfs!(input, output, kv, work) do
    root = Path.join(work, "root")
    {_, 0} = cmd!("unsquashfs", ["-n", "-f", "-d", root, input])
    File.rm_rf!(Path.join(root, "boot"))
    File.write!(Path.join(root, @kv_path), encode_kv(kv))

    {listing, 0} = cmd!("unsquashfs", ["-n", "-lln", input])

    pseudo =
      listing
      |> pseudo_definitions()
      |> Enum.reject(&(String.starts_with?(&1, "/boot ") or String.starts_with?(&1, "/boot/")))
      |> Kernel.++(["/#{@kv_path} m 644 0 0"])

    pseudo_file = Path.join(work, "pseudo")
    File.write!(pseudo_file, Enum.map(pseudo, &[&1, "\n"]))
    sort_file = Path.join(work, "priorities")
    File.write!(sort_file, @sort_priorities)

    {_, 0} =
      cmd!("mksquashfs", [
        root,
        output,
        "-all-root",
        "-pseudo-override",
        "-pf",
        pseudo_file,
        "-sort",
        sort_file,
        "-noappend",
        "-no-recovery",
        "-no-progress",
        "-quiet"
      ])

    :ok
  end

  @doc """
  `mksquashfs` pseudo definitions (`path m mode uid gid`) restoring the mode
  and owner of every directory and file in an `unsquashfs -lln` listing, the
  image root and symlinks excepted, as Nerves' `merge-squashfs` does.
  Extracting as a normal user loses owners and could lose setuid bits.
  """
  @spec pseudo_definitions(String.t()) :: [String.t()]
  def pseudo_definitions(listing) do
    for line <- String.split(listing, "\n", trim: true),
        [perms, uid, gid, path] <- [listing_fields(line)],
        String.first(perms) in ["d", "-"],
        path != "" do
      escaped = String.replace(path, " ", "\\ ")
      "#{escaped} m #{perms |> mode() |> Integer.to_string(8)} #{uid} #{gid}"
    end
  end

  defp listing_fields(line) do
    case Regex.run(~r/^(\S{10})\s+(\d+)\/(\d+)\s+\S+\s+\S+\s+\S+\s+squashfs-root(.*)$/, line) do
      [_, perms, uid, gid, path] -> [perms, uid, gid, path]
      nil -> []
    end
  end

  @doc false
  # "-rwsr-xr-x" -> 0o4755
  @spec mode(String.t()) :: non_neg_integer()
  def mode(<<_type, u::binary-3, g::binary-3, o::binary-3>>) do
    import Bitwise
    {u_bits, suid} = triplet(u, 0o4000)
    {g_bits, sgid} = triplet(g, 0o2000)
    {o_bits, sticky} = triplet(o, 0o1000)
    (u_bits <<< 6) + (g_bits <<< 3) + o_bits + suid + sgid + sticky
  end

  defp triplet(<<r, w, x>>, special) do
    bits = if(r == ?r, do: 4, else: 0) + if(w == ?w, do: 2, else: 0)

    case x do
      ?x -> {bits + 1, 0}
      c when c in [?s, ?t] -> {bits + 1, special}
      c when c in [?S, ?T] -> {bits, special}
      _ -> {bits, 0}
    end
  end

  defp extract!(fw, name) do
    case :zip.unzip(String.to_charlist(fw), [:memory, file_list: [String.to_charlist(name)]]) do
      {:ok, [{_, data}]} -> data
      other -> raise "cannot read #{name} from #{fw}: #{inspect(other)}"
    end
  end

  defp cmd!(tool, args) do
    exe =
      System.find_executable(tool) || raise "#{tool} not found: install fwup and squashfs-tools"

    case System.cmd(exe, args, stderr_to_stdout: false) do
      {out, 0} -> {out, 0}
      {out, status} -> raise "#{tool} #{Enum.join(args, " ")} exited #{status}: #{out}"
    end
  end
end
