defmodule Mix.Tasks.Kubex.GenCa do
  @shortdoc "Creates the root CA and the signer for boot images and releases"
  @moduledoc """
  Writes a root CA and a code-signing certificate issued by it
  (docs/specs.md §2.11.1, `Kubex.Pki`):

      mix kubex.gen_ca [--dir DIR] [--name NAME]
      mix kubex.gen_ca --signer-only [--dir DIR] [--name NAME]

  The directory is `--dir`, else `KUBEX_PKI_DIR`, else `~/.kubex/pki`. It gets
  `ca.pem`, `ca.key`, `signer.pem` and `signer.key`.

    * `--name` - prefix of the certificates' CN, default `kubex`
    * `--signer-only` - issue a new signer from the root already in the
      directory, for a lost or rotated signer key. Nodes need no change.

  Nothing is ever overwritten: the task fails if any file it would write is
  there. Both keys are offline keys; keep them off the boot server and the
  nodes.
  """
  use Mix.Task

  @switches [dir: :string, name: :string, signer_only: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    dir = Kubex.Pki.dir(opts[:dir])
    pki_opts = Keyword.take(opts, [:name])

    try do
      if opts[:signer_only],
        do: Kubex.Pki.gen_signer!(dir, pki_opts),
        else: Kubex.Pki.gen_ca!(dir, pki_opts)
    rescue
      e in [RuntimeError, File.Error] -> Mix.raise(Exception.message(e))
    end

    paths = Kubex.Pki.paths(dir)

    Mix.shell().info("""
    #{if opts[:signer_only], do: "New signer", else: "Root CA and signer"} in #{Path.relative_to_cwd(dir)}
      root:   #{paths.ca_cert}
      signer: #{paths.signer_cert}
      root SHA-256: #{Kubex.Pki.ca_fingerprint(dir)}

    ca.key and signer.key are offline keys: keep them off the boot server and the nodes.
    """)
  end
end
