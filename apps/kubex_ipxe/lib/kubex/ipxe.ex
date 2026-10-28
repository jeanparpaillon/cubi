defmodule Kubex.Ipxe do
  @moduledoc """
  Turns a Nerves `.fw` into the directory a boot server serves to iPXE
  (docs/specs.md §2.2, §2.3, §2.6):

  | File | From |
  | --- | --- |
  | `vmlinuz` | `/boot/bzImage` inside the `.fw`'s rootfs: the `.fw` has no kernel resource |
  | `stage1.cpio.zst` | the system artifact's `images/` |
  | `rootfs.squashfs` | `data/rootfs.img`, plus `/firmware.kv` appended (below) |
  | `boot.ipxe` | rendered here; relative URLs, so the directory can be served from anywhere |
  | `SHA256SUMS` | the four files above |

  **Firmware metadata.** A Nerves install has `fwup` write the firmware's
  metadata (`a.nerves_fw_version`, `a.nerves_fw_uuid`, …) into the U-Boot or
  GRUB environment. A diskless node has no such environment, and the UUID only
  exists once the `.fw` is built, after its squashfs is sealed. So the metadata
  is appended to the served squashfs as `/firmware.kv`, one `key=value` per
  line, and the firmware's `config/runtime.exs` loads it into
  `Nerves.Runtime.KVBackend.InMemory`. It is at the root because a squashfs
  append cannot add to an existing directory, and not under `/kubex`, which is
  the ZFS dataset's mount point (§2.10.3).
  """

  @kv_file "firmware.kv"

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

    rootfs = Path.join(output, "rootfs.squashfs")
    File.write!(rootfs, extract!(fw, "data/rootfs.img"))

    {kernel, 0} = cmd!("unsquashfs", ["-cat", rootfs, "boot/bzImage"])
    File.write!(Path.join(output, "vmlinuz"), kernel)

    append_kv!(rootfs, kv(meta), work)

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

  @doc "`kv/1` as the `/firmware.kv` text: `key=value` lines, sorted."
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

  defp append_kv!(rootfs, kv, work) do
    dir = Path.join(work, "append")
    File.mkdir_p!(dir)
    file = Path.join(dir, @kv_file)
    File.write!(file, encode_kv(kv))
    # mksquashfs keeps the mode it finds; don't let the host umask decide.
    File.chmod!(file, 0o644)

    {_, 0} =
      cmd!("mksquashfs", [dir, rootfs, "-all-root", "-no-recovery", "-quiet", "-no-progress"])

    :ok
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
