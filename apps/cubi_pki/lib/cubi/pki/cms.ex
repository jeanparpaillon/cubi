defmodule Cubi.Pki.Cms do
  @moduledoc """
  Detached CMS signatures for the boot images, the format iPXE `imgverify`
  reads (docs/specs.md §2.11.2). Host-only: `:public_key` cannot write CMS, so
  this runs `openssl`.

  A signature is `<file>.sig`, DER, made with `openssl cms -sign -binary
  -noattr`, signer certificate included and no other.
  """

  @doc """
  Writes `<path>.sig` for each path, signed with the signer in the PKI
  directory `pki_dir` (`Cubi.Pki.paths/1`). Returns the signature paths.
  """
  @spec sign!([Path.t()], Path.t()) :: [Path.t()]
  def sign!(paths, pki_dir) do
    pki = Cubi.Pki.paths(pki_dir)

    for path <- paths do
      sig = path <> ".sig"

      openssl!(
        ~w(cms -sign -binary -noattr -md sha256 -outform DER) ++
          ["-signer", pki.signer_cert, "-inkey", pki.signer_key, "-in", path, "-out", sig]
      )

      sig
    end
  end

  @doc """
  Checks `sig` over `path` against the root certificate at `ca_cert`, with the
  `codeSigning` purpose, as iPXE would. For tests and for checking a served
  directory before publishing it.
  """
  @spec verify(Path.t(), Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def verify(path, sig, ca_cert) do
    args =
      ~w(cms -verify -binary -inform DER -purpose codesign -out /dev/null) ++
        ["-in", sig, "-content", path, "-CAfile", ca_cert]

    case System.cmd(openssl(), args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp openssl!(args) do
    case System.cmd(openssl(), args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> raise "openssl #{hd(args)} exited #{status}: #{out}"
    end
  end

  defp openssl do
    System.find_executable("openssl") ||
      raise "openssl not found: it is needed to sign boot images (docs/specs.md §2.11.2)"
  end
end
