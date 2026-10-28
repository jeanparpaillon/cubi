defmodule Mix.Tasks.Cubi.Sign do
  @shortdoc "Signs a cubi release archive"
  @moduledoc """
  Adds `manifest.sig` and `signer.pem` to a release archive, in place
  (docs/specs.md §2.11.4, `Cubi.Pki.Archive`):

      mix cubi.sign [ARCHIVE] [--signer DIR]

    * `ARCHIVE` - default the newest `_build/<env>/cubi/*.tar.gz`, what
      `mix cubi.release` wrote
    * `--signer DIR` - the PKI directory (`mix cubi.gen_ca`), default
      `CUBI_PKI_DIR`, else `~/.cubi/pki`

  An archive already signed is signed again: both members are replaced. One
  whose files do not match its manifest is refused, and so is a signer its own
  root does not accept: the archive is checked as a node would, signer dates
  included, before it is written.
  """
  use Mix.Task

  alias Cubi.Pki.Archive

  @switches [signer: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)
    archive = archive!(rest)
    dir = Cubi.Pki.dir(opts[:signer])
    paths = Cubi.Pki.paths(dir)

    for path <- [paths.ca_cert, paths.signer_cert, paths.signer_key],
        not File.exists?(path),
        do: Mix.raise("no #{path}: --signer names a directory from `mix cubi.gen_ca`")

    entries =
      case Archive.read(File.read!(archive)) do
        {:ok, entries} -> entries
        {:error, reason} -> Mix.raise("#{archive} is not a cubi release: #{inspect(reason)}")
      end

    signed =
      with {:ok, signed} <- Archive.sign(entries, Cubi.Pki.load_signer!(dir)),
           {:ok, _manifest} <- Archive.verify(signed, File.read!(paths.ca_cert)) do
        signed
      else
        {:error, reason} -> Mix.raise("cannot sign #{archive}: #{inspect(reason)}")
      end

    Archive.write!(archive, signed)
    {:ok, manifest} = Archive.manifest(signed)

    Mix.shell().info("""
    #{manifest["name"]} #{manifest["version"]} signed: #{Path.relative_to_cwd(archive)}
      root SHA-256: #{Cubi.Pki.ca_fingerprint(dir)}
    Nodes accept it if their image trusts that root (/etc/cubi/ca.pem).
    """)
  end

  defp archive!([path | _]) do
    if not File.regular?(path), do: Mix.raise("no #{path}")
    path
  end

  defp archive!([]) do
    pattern = Path.join([Mix.Project.build_path(), "cubi", "*.tar.gz"])

    case Path.wildcard(pattern) do
      [] -> Mix.raise("no archive in #{Path.dirname(pattern)}: run `mix cubi.release` first")
      found -> Enum.max_by(found, &File.stat!(&1, time: :posix).mtime)
    end
  end
end
