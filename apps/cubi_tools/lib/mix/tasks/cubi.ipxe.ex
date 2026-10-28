defmodule Mix.Tasks.Cubi.Ipxe do
  @shortdoc "Builds an iPXE that trusts only your root CA, with imgverify"
  @moduledoc """
  Builds iPXE (`Cubi.Tools.Ipxe`) with `TRUST=` your root CA and the
  `imgverify` command, for booting a served directory built with
  `mix firmware.ipxe --signer DIR --imgverify` (docs/specs.md §2.11.2):

      mix cubi.ipxe [--ca PATH] [--out DIR] [--target NAME ...] [--jobs N]

    * `--ca` - the root certificate, default `ca.pem` in the PKI directory
      (`--dir`, `CUBI_PKI_DIR`, `~/.cubi/pki`)
    * `--out` - default `_build/<env>/cubi_ipxe/`
    * `--target` - `undionly.kpxe`, `ipxe.efi` or `1af41000.rom`; repeatable,
      default all three

  The iPXE source is downloaded once, checked against a pinned SHA-512, and
  built with `make`, `gcc`, `perl` and liblzma's headers. The trusted root is
  the only one this iPXE accepts, for HTTPS too.
  """
  use Mix.Task

  @switches [ca: :string, dir: :string, out: :string, target: :keep, jobs: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    ca = opts[:ca] || Cubi.Pki.paths(Cubi.Pki.dir(opts[:dir])).ca_cert
    output = opts[:out] || Path.join(Mix.Project.build_path(), "cubi_ipxe")

    build_opts =
      [ca: ca, output: output]
      |> then(&if(opts[:jobs], do: Keyword.put(&1, :jobs, opts[:jobs]), else: &1))
      |> then(fn o ->
        case Keyword.get_values(opts, :target) do
          [] -> o
          targets -> Keyword.put(o, :targets, targets)
        end
      end)

    Mix.shell().info("Building iPXE #{Cubi.Tools.Ipxe.version()} trusting #{ca}…")

    paths =
      try do
        Cubi.Tools.Ipxe.build!(build_opts)
      rescue
        e in [RuntimeError, ArgumentError] -> Mix.raise(Exception.message(e))
      end

    Mix.shell().info("""
    iPXE trusting only #{ca}:
    #{Enum.map_join(paths, "\n", &"  #{Path.relative_to_cwd(&1)}")}
    """)
  end
end
