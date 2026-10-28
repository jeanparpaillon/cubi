defmodule Mix.Tasks.Firmware.Ipxe do
  @shortdoc "Builds the firmware, then the directory a boot server serves to iPXE"
  @moduledoc """
  Runs `mix firmware`, then writes `vmlinuz`, `stage1.cpio.zst`,
  `rootfs.squashfs`, `boot.ipxe`, `base.json` and `SHA256SUMS` into
  `_build/<target>_<env>/ipxe/` (docs/specs.md §2.3, §2.11.2, `Cubi.Ipxe`).

      MIX_TARGET=x86_64 mix firmware.ipxe [--cmdline "console=ttyS0 …"] [--signer DIR] [--imgverify]

    * `--signer DIR` - a PKI directory (`mix cubi.gen_ca`): its signer
      writes `vmlinuz.sig`, `stage1.cpio.zst.sig` and `rootfs.squashfs.sig`.
      Defaults to `config :cubi_fw, :signer`. Required unless `MIX_ENV=dev`,
      which builds an unsigned directory with a warning.
    * `--imgverify` - write `imgverify` lines into `boot.ipxe`, so iPXE
      refuses an image whose signature does not verify. Needs a signer, and an
      iPXE that trusts its root (`mix cubi.ipxe`): a stock iPXE refuses every
      image.

  The root certificate the node trusts for releases, `/etc/cubi/ca.pem` in
  the served rootfs, is `config :cubi_fw, :ca_cert`, else the signer's
  `ca.pem`. If both are set they must be the same certificate. With neither,
  the node refuses every release.

  Run it in a Nerves firmware project whose system ships
  `images/stage1.cpio.zst` (`cubi_system_x86_64`). Needs `fwup`,
  `unsquashfs`, `mksquashfs` and, to sign, `openssl` on the host.
  """
  use Mix.Task

  @switches [cmdline: :string, signer: :string, imgverify: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    signer = signer(opts[:signer] || Application.get_env(:cubi_fw, :signer))
    ca_cert = trusted_ca(Application.get_env(:cubi_fw, :ca_cert), signer)

    if opts[:imgverify] && signer == nil,
      do: Mix.raise("--imgverify needs a signer: the script would refuse every image")

    Mix.Task.run("firmware", [])

    system = System.get_env("NERVES_SYSTEM") || Mix.raise("NERVES_SYSTEM is not set")
    output = Path.join(Mix.Project.build_path(), "ipxe")

    meta =
      Cubi.Ipxe.build!(
        firmware: Nerves.Env.firmware_path(),
        stage1: Path.join([system, "images", "stage1.cpio.zst"]),
        output: output,
        cmdline: Keyword.get(opts, :cmdline, "console=ttyS0"),
        otp_version: otp_version!(system),
        ca_cert: ca_cert,
        signer: signer,
        imgverify: opts[:imgverify] || false
      )

    Mix.shell().info("""
    #{meta["product"]} #{meta["version"]} (#{meta["uuid"]}) ready to serve in
      #{Path.relative_to_cwd(output)}
    #{if signer, do: "signed by #{signer}", else: "UNSIGNED"}; releases trusted from #{ca_cert || "nobody"}
    """)
  end

  defp signer(nil) do
    if Mix.env() != :dev,
      do:
        Mix.raise(
          "MIX_ENV=#{Mix.env()} needs a signer: --signer DIR, or config :cubi_fw, :signer"
        )

    Mix.shell().info([:yellow, "No signer: the served images are unsigned (MIX_ENV=dev only)."])
    nil
  end

  defp signer(dir) do
    dir = Path.expand(dir)
    paths = Cubi.Pki.paths(dir)

    for path <- [paths.ca_cert, paths.signer_cert, paths.signer_key],
        not File.exists?(path),
        do: Mix.raise("no #{path}: --signer names a directory from `mix cubi.gen_ca`")

    dir
  end

  defp trusted_ca(ca_cert, signer) do
    case Cubi.Ipxe.trusted_ca!(ca_cert && Path.expand(ca_cert), signer) do
      nil ->
        Mix.shell().info([
          :yellow,
          "No root CA (config :cubi_fw, :ca_cert): the node will refuse every release."
        ])

        nil

      path ->
        path
    end
  rescue
    e in RuntimeError -> Mix.raise(Exception.message(e))
  end

  # staging/usr/lib/erlang/releases/<major>/OTP_VERSION in the system artifact.
  defp otp_version!(system) do
    case Path.wildcard(Path.join(system, "staging/usr/lib/erlang/releases/*/OTP_VERSION")) do
      [file] -> file |> File.read!() |> String.trim()
      other -> Mix.raise("expected one OTP_VERSION in #{system}, found #{inspect(other)}")
    end
  end
end
