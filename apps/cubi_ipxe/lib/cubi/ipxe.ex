defmodule Cubi.Ipxe do
  @moduledoc """
  Turns a Nerves `.fw` into the directory a boot server serves to iPXE
  (docs/specs.md §2.2, §2.3, §2.6):

  | File | From |
  | --- | --- |
  | `vmlinuz` | `/boot/bzImage` inside the `.fw`'s rootfs: the `.fw` has no kernel resource |
  | `stage1.cpio.zst` | the system artifact's `images/` |
  | `rootfs.squashfs` | `data/rootfs.img`, rebuilt without `/boot` and with `/etc/firmware.kv` (below) |
  | `boot.ipxe` | rendered here; relative URLs, so the directory can be served from anywhere |
  | `base.json` | what the image ships, for `mix cubi.release --base` (below) |
  | `*.sig` | with a signer: detached CMS signatures of `vmlinuz`, `stage1.cpio.zst` and `rootfs.squashfs` (§2.11.2) |
  | `SHA256SUMS` | every file above |

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
    * **the root CA in `/etc/cubi/ca.pem`**, when there is one: the
      certificate the node checks deployed releases against (§2.11.2). The
      rootfs signature then covers it.

  **A public image** (`public: true`, docs/specs.md §2.12.1) is the generic
  one the cubi project publishes: no `/etc/cubi/ca.pem` and no way in compiled
  into the release (`check_public!/1`). The operator's configuration comes
  from the cmdline instead (§2.12.2).

  **`base.json`** describes the image to the tools that build releases for it
  (§2.11.3): the OTP and ERTS versions, and every application in the rootfs's
  `/srv/erlang/lib` with its version.

  The rebuild needs no root, the way Nerves' own `merge-squashfs` works:
  unpack, then repack with a pseudo file that restores every entry's mode and
  owner (`unsquashfs -lln`), and the same sort priorities as `rel2fw.sh`, so
  erlinit's files still come first.
  """

  @kv_path "etc/firmware.kv"
  @ca_path "etc/cubi/ca.pem"
  @images ~w(vmlinuz stage1.cpio.zst rootfs.squashfs)

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
    * `:otp_version` (required) - the system's full OTP version, for `base.json`
    * `:ca_cert` - root certificate to install as `/etc/cubi/ca.pem`
    * `:signer` - PKI directory (`Cubi.Pki`) whose signer signs the images
    * `:imgverify` - write the `imgverify` lines into `boot.ipxe` (§2.11.2);
      needs `:signer`
    * `:public` - build the generic image of §2.12.1: no `:ca_cert` allowed,
      and the rootfs is refused by `check_public!/1` if it holds a CA or an
      ssh login

  Returns the metadata read from the `.fw`.
  """
  @spec build!(keyword()) :: metadata()
  def build!(opts) do
    fw = Keyword.fetch!(opts, :firmware)
    stage1 = Keyword.fetch!(opts, :stage1)
    output = Keyword.fetch!(opts, :output)
    cmdline = Keyword.get(opts, :cmdline, "console=ttyS0")
    otp_version = Keyword.fetch!(opts, :otp_version)
    ca_cert = Keyword.get(opts, :ca_cert)
    signer = Keyword.get(opts, :signer)
    imgverify = Keyword.get(opts, :imgverify, false)
    public = Keyword.get(opts, :public, false)

    if imgverify and signer == nil, do: raise(ArgumentError, ":imgverify needs a :signer")
    if public and ca_cert, do: raise(ArgumentError, "a :public image carries no :ca_cert")

    for path <- [fw, stage1 | List.wrap(ca_cert)], not File.exists?(path), do: raise("no #{path}")

    meta = metadata!(fw)

    File.rm_rf!(output)
    File.mkdir_p!(output)
    work = Path.join(output, ".work")
    File.mkdir_p!(work)

    original = Path.join(work, "rootfs.img")
    File.write!(original, extract!(fw, "data/rootfs.img"))

    {kernel, 0} = cmd!("unsquashfs", ["-cat", original, "boot/bzImage"])
    File.write!(Path.join(output, "vmlinuz"), kernel)

    root = unpack_rootfs!(original, work)
    if public, do: check_public!(root)
    base = base(root, otp_version, meta)
    added = add_files!(root, kv(meta), ca_cert)
    repack_rootfs!(original, root, Path.join(output, "rootfs.squashfs"), added, work)

    File.cp!(stage1, Path.join(output, "stage1.cpio.zst"))
    File.write!(Path.join(output, "boot.ipxe"), boot_script(meta, cmdline, imgverify: imgverify))
    File.write!(Path.join(output, "base.json"), [:json.format(base), "\n"])
    File.rm_rf!(work)

    if signer, do: Cubi.Pki.Cms.sign!(Enum.map(@images, &Path.join(output, &1)), signer)

    File.write!(
      Path.join(output, "SHA256SUMS"),
      for name <- output |> File.ls!() |> Enum.sort(), name != "SHA256SUMS" do
        sum = :crypto.hash(:sha256, File.read!(Path.join(output, name)))
        [Base.encode16(sum, case: :lower), "  ", name, "\n"]
      end
    )

    meta
  end

  @doc """
  The root certificate a build installs as `/etc/cubi/ca.pem` (§2.11.2):
  `ca_cert` if given, else the signer's own `ca.pem`, else `nil`. With both,
  they must be the same certificate: an image signed by one root that trusts
  another for releases is a mistake.
  """
  @spec trusted_ca!(Path.t() | nil, Path.t() | nil) :: Path.t() | nil
  def trusted_ca!(ca_cert, nil), do: ca_cert

  def trusted_ca!(ca_cert, signer) do
    signer_ca = Cubi.Pki.paths(signer).ca_cert

    cond do
      ca_cert == nil ->
        signer_ca

      der(ca_cert) == der(signer_ca) ->
        ca_cert

      true ->
        raise "#{ca_cert} is not the root that issued the signer in #{signer} " <>
                "(#{signer_ca}): the image would not trust its own signer"
    end
  end

  defp der(path),
    do: path |> File.read!() |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()

  @doc """
  Raises unless the unpacked rootfs at `root` is fit to publish (§2.12.1): no
  `/etc/cubi/ca.pem`, and no ssh login in the release's `sys.config`, neither
  `nerves_ssh` authorized keys nor user passwords. Whoever writes the boot
  script decides those, never the image.
  """
  @spec check_public!(Path.t()) :: :ok
  def check_public!(root) do
    if File.exists?(Path.join(root, @ca_path)),
      do: raise("a public image must not carry /#{@ca_path}")

    ssh = root |> sys_config!() |> Keyword.get(:nerves_ssh, [])

    for key <- [:authorized_keys, :user_passwords], Keyword.get(ssh, key, []) not in [[], nil] do
      raise "a public image must not carry nerves_ssh #{key}: " <>
              "build it with MIX_ENV=public, which configures none"
    end

    :ok
  end

  defp sys_config!(root) do
    erlang = Path.join(root, "srv/erlang")

    [_erts, release_version] =
      erlang |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()

    path = Path.join([erlang, "releases", release_version, "sys.config"])

    case :file.consult(path) do
      {:ok, [config]} -> config
      other -> raise "cannot read #{path}: #{inspect(other)}"
    end
  end

  @doc """
  `base.json` for an unpacked rootfs at `root` (§2.11.3).
  """
  @spec base(Path.t(), String.t(), metadata()) :: map()
  def base(root, otp_version, meta) do
    erlang = Path.join(root, "srv/erlang")

    [erts_version, release_version] =
      erlang |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()

    applications =
      for dir <- erlang |> Path.join("lib") |> File.ls!(),
          [_, name, vsn] <- [Regex.run(~r/^(.+)-([^-]+)$/, dir)],
          into: %{},
          do: {name, vsn}

    %{
      "format" => 1,
      "otp_release" => otp_version |> String.split(".") |> hd(),
      "otp_version" => otp_version,
      "erts_version" => erts_version,
      "release" => %{"name" => meta["product"], "version" => release_version},
      "firmware" => Map.take(meta, ["product", "version", "uuid"]),
      "applications" => applications
    }
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

  @doc """
  The generic `boot.ipxe`: kernel, stage-1 and the rootfs as a named initrd
  (§2.2). With `imgverify: true`, each image is followed by its `imgverify`
  against `<image>.sig` (§2.11.2): a failure stops the script before `boot`.
  Only an iPXE built to trust the signer's root (`mix cubi.ipxe`) runs it.
  """
  @spec boot_script(metadata(), String.t(), keyword()) :: String.t()
  def boot_script(meta, cmdline, opts \\ []) do
    verify = fn image ->
      if opts[:imgverify], do: "imgverify #{image} #{image}.sig\n", else: ""
    end

    """
    #!ipxe
    # #{meta["product"]} #{meta["version"]} (#{meta["uuid"]}), from `mix firmware.ipxe`.
    # URLs are relative to this script. A boot server renders a per-node script
    # instead, with cubi.join= and the token (docs/specs.md §2.7).
    kernel vmlinuz #{cmdline}
    #{verify.("vmlinuz")}initrd stage1.cpio.zst
    #{verify.("stage1.cpio.zst")}initrd rootfs.squashfs /rootfs.squashfs
    #{verify.("rootfs.squashfs")}boot
    """
  end

  defp unpack_rootfs!(input, work) do
    root = Path.join(work, "root")
    {_, 0} = cmd!("unsquashfs", ["-n", "-f", "-d", root, input])
    File.rm_rf!(Path.join(root, "boot"))
    root
  end

  # Writes the files the served rootfs gains, and returns their pseudo
  # definitions: all root-owned.
  defp add_files!(root, kv, ca_cert) do
    File.write!(Path.join(root, @kv_path), encode_kv(kv))

    ca =
      if ca_cert do
        File.mkdir_p!(Path.join(root, Path.dirname(@ca_path)))
        File.cp!(ca_cert, Path.join(root, @ca_path))
        ["/#{Path.dirname(@ca_path)} m 755 0 0", "/#{@ca_path} m 644 0 0"]
      else
        []
      end

    ["/#{@kv_path} m 644 0 0" | ca]
  end

  defp repack_rootfs!(input, root, output, added, work) do
    {listing, 0} = cmd!("unsquashfs", ["-n", "-lln", input])

    pseudo =
      listing
      |> pseudo_definitions()
      |> Enum.reject(&(String.starts_with?(&1, "/boot ") or String.starts_with?(&1, "/boot/")))
      |> Kernel.++(added)

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
