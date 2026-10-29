defmodule Cubi.Pki do
  @moduledoc """
  The operator's PKI for signed boot images and releases (docs/specs.md
  §2.11.1, §2.11.4): a root CA, and a signer certificate it issues with the
  `codeSigning` extended key usage.

  A PKI directory holds four files:

  | File | What |
  | --- | --- |
  | `ca.pem`, `ca.key` | self-signed root, `CA:TRUE`, `pathlen:0`, 20 years |
  | `signer.pem`, `signer.key` | issued by the root, `CA:FALSE`, `digitalSignature`, `codeSigning`, 10 years |

  Keys are RSA-3072, written unencrypted with mode `0600`, in a directory made
  `0700`. Nothing here ever overwrites one of these files: losing a CA means new
  images for every node, so replacing it is never a side effect.

  Signing and verification use `:public_key` only, so the node needs no
  OpenSSL. CMS signatures for iPXE are in `Cubi.Pki.Cms`, host-only.
  """

  require Record

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  @ca_cert "ca.pem"
  @ca_key "ca.key"
  @signer_cert "signer.pem"
  @signer_key "signer.key"

  @rsa_bits 3072
  @ca_days round(20 * 365.2425)
  @signer_days round(10 * 365.2425)

  @code_signing {1, 3, 6, 1, 5, 5, 7, 3, 3}
  @ext_key_usage {2, 5, 29, 37}

  @type signer :: %{cert: X509.Certificate.t(), key: X509.PrivateKey.t()}

  @doc """
  The PKI directory to use: `dir` if given, else `CUBI_PKI_DIR`, else
  `~/.cubi/pki`.
  """
  @spec dir(Path.t() | nil) :: Path.t()
  def dir(dir \\ nil) do
    Path.expand(dir || System.get_env("CUBI_PKI_DIR") || "~/.cubi/pki")
  end

  @doc """
  The SHA-256 fingerprint of the root certificate in `dir`, as colon-separated
  hex: what an operator compares against an iPXE build's `TRUST=` certificate.
  """
  @spec ca_fingerprint(Path.t()) :: String.t()
  def ca_fingerprint(dir) do
    dir
    |> paths()
    |> Map.fetch!(:ca_cert)
    |> File.read!()
    |> X509.Certificate.from_pem!()
    |> X509.Certificate.to_der()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16()
    |> String.codepoints()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end

  @doc """
  The SHA-256 of a PEM certificate's DER, as lowercase hex: the form a
  `cubi.ca=sha256:<hex>` pin takes (docs/specs.md §2.12.2). Only the first
  certificate of the PEM counts.
  """
  @spec cert_sha256(String.t()) :: {:ok, String.t()} | {:error, :bad_certificate}
  def cert_sha256(pem) do
    case X509.Certificate.from_pem(pem) do
      {:ok, cert} ->
        der = X509.Certificate.to_der(cert)
        {:ok, :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)}

      {:error, _} ->
        {:error, :bad_certificate}
    end
  end

  @doc "The paths of the four files in a PKI directory."
  @spec paths(Path.t()) :: %{atom() => Path.t()}
  def paths(dir) do
    %{
      ca_cert: Path.join(dir, @ca_cert),
      ca_key: Path.join(dir, @ca_key),
      signer_cert: Path.join(dir, @signer_cert),
      signer_key: Path.join(dir, @signer_key)
    }
  end

  @doc """
  Creates a root CA and a signer in `dir`. Raises, writing nothing, if any of
  the four files already exists. Options:

    * `:name` - prefix of both subjects' CN, default `"cubi"`
  """
  @spec gen_ca!(Path.t(), keyword()) :: :ok
  def gen_ca!(dir, opts \\ []) do
    name = Keyword.get(opts, :name, "cubi")
    paths = paths(dir)
    refuse_existing!(Map.values(paths))
    mkdir_private!(dir)

    ca_key = X509.PrivateKey.new_rsa(@rsa_bits)

    ca_cert =
      X509.Certificate.self_signed(ca_key, "/CN=#{name} root CA",
        template:
          X509.Certificate.Template.new(:root_ca,
            validity: @ca_days,
            extensions: [
              basic_constraints: X509.Certificate.Extension.basic_constraints(true, 0),
              key_usage: X509.Certificate.Extension.key_usage([:keyCertSign, :cRLSign])
            ]
          )
      )

    write_key!(paths.ca_key, ca_key)
    File.write!(paths.ca_cert, X509.Certificate.to_pem(ca_cert))
    write_signer!(paths, name, ca_cert, ca_key)
  end

  @doc """
  Issues a new signer from the root CA in `dir`, for a lost or rotated signer
  key. Raises if `signer.pem` or `signer.key` exists. Nodes need no change: they
  trust the root. Takes the same options as `gen_ca!/2`.
  """
  @spec gen_signer!(Path.t(), keyword()) :: :ok
  def gen_signer!(dir, opts \\ []) do
    name = Keyword.get(opts, :name, "cubi")
    paths = paths(dir)
    refuse_existing!([paths.signer_cert, paths.signer_key])

    ca_cert = paths.ca_cert |> File.read!() |> X509.Certificate.from_pem!()
    ca_key = paths.ca_key |> File.read!() |> X509.PrivateKey.from_pem!()
    write_signer!(paths, name, ca_cert, ca_key)
  end

  @doc "Reads the signer certificate and key from `dir`."
  @spec load_signer!(Path.t()) :: signer()
  def load_signer!(dir) do
    paths = paths(dir)

    %{
      cert: paths.signer_cert |> File.read!() |> X509.Certificate.from_pem!(),
      key: paths.signer_key |> File.read!() |> X509.PrivateKey.from_pem!()
    }
  end

  @doc """
  Signs `data` with the signer's key (RSA, SHA-256). Returns the raw signature
  and the signer certificate as PEM, the two members `mix cubi.sign` adds to a
  release next to its manifest (§2.11.4).
  """
  @spec sign(binary(), signer()) :: {signature :: binary(), signer_pem :: String.t()}
  def sign(data, %{cert: cert, key: key}) do
    {:public_key.sign(data, :sha256, key), X509.Certificate.to_pem(cert)}
  end

  @doc """
  Verifies `signature` over `data`, made by the certificate in `signer_pem`,
  against the root certificate in `ca_pem`. This is steps 1 and 2 of §2.11.4:

    1. the signer is path-valid from the root and carries `codeSigning`;
    2. the signature verifies with the signer's key.

  Options:

    * `:check_dates` - whether the signer's validity dates count, default
      `true`. A deploy checks them; a node re-verifying at boot does not, so a
      release never vanishes because its signer expired while it ran.
  """
  @spec verify(binary(), binary(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def verify(data, signature, signer_pem, ca_pem, opts \\ []) do
    check_dates = Keyword.get(opts, :check_dates, true)

    with {:ok, ca} <- decode_cert(ca_pem, :bad_ca),
         {:ok, signer} <- decode_cert(signer_pem, :bad_signer),
         :ok <- validate_path(ca, signer, check_dates),
         :ok <- code_signing(signer) do
      if :public_key.verify(data, :sha256, signature, X509.Certificate.public_key(signer)),
        do: :ok,
        else: {:error, :bad_signature}
    end
  end

  defp write_signer!(paths, name, ca_cert, ca_key) do
    key = X509.PrivateKey.new_rsa(@rsa_bits)

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=#{name} signer", ca_cert, ca_key,
        template:
          X509.Certificate.Template.new(:server,
            validity: @signer_days,
            extensions: [
              key_usage: X509.Certificate.Extension.key_usage([:digitalSignature]),
              ext_key_usage: X509.Certificate.Extension.ext_key_usage([:codeSigning])
            ]
          )
      )

    write_key!(paths.signer_key, key)
    File.write!(paths.signer_cert, X509.Certificate.to_pem(cert))
  end

  defp refuse_existing!(paths) do
    case Enum.filter(paths, &File.exists?/1) do
      [] -> :ok
      existing -> raise "refusing to overwrite #{Enum.join(existing, ", ")}"
    end
  end

  defp mkdir_private!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
  end

  # Created empty with 0600 first, so the key is never readable by others,
  # even for a moment.
  defp write_key!(path, key) do
    File.write!(path, "")
    File.chmod!(path, 0o600)
    File.write!(path, X509.PrivateKey.to_pem(key))
  end

  defp decode_cert(pem, error) do
    case X509.Certificate.from_pem(pem) do
      {:ok, cert} -> {:ok, cert}
      _ -> {:error, error}
    end
  end

  defp validate_path(ca, signer, check_dates) do
    case :public_key.pkix_path_validation(ca, [X509.Certificate.to_der(signer)],
           verify_fun: {&verify_fun/3, check_dates}
         ) do
      {:ok, _} -> :ok
      {:error, {:bad_cert, :cert_expired}} -> {:error, :signer_expired}
      {:error, {:bad_cert, reason}} -> {:error, {:bad_signer_chain, reason}}
    end
  end

  # `:cert_expired` covers both not-yet-valid and expired.
  defp verify_fun(_cert, {:bad_cert, :cert_expired}, false), do: {:valid, false}
  defp verify_fun(_cert, {:bad_cert, _} = reason, _), do: {:fail, reason}
  defp verify_fun(_cert, {:extension, _}, state), do: {:unknown, state}
  defp verify_fun(_cert, _valid, state), do: {:valid, state}

  defp code_signing(signer) do
    case X509.Certificate.extension(signer, @ext_key_usage) do
      extension(extnValue: usages) when is_list(usages) ->
        if @code_signing in usages, do: :ok, else: {:error, :not_code_signing}

      _ ->
        {:error, :not_code_signing}
    end
  end
end
