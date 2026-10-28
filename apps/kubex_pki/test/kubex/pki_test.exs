defmodule Kubex.PkiTest do
  use ExUnit.Case, async: true

  alias Kubex.Pki

  @moduletag :tmp_dir

  # RSA-3072 key generation takes a while: one PKI for the whole module, plus
  # another one to stand for a foreign CA.
  setup_all do
    base = Path.join(System.tmp_dir!(), "kubex_pki_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    dir = Path.join(base, "pki")
    other = Path.join(base, "other")
    Pki.gen_ca!(dir)
    Pki.gen_ca!(other, name: "other")

    %{pki: dir, other: other, signer: Pki.load_signer!(dir)}
  end

  defp ca_pem(dir), do: File.read!(Pki.paths(dir).ca_cert)

  describe "gen_ca!/2" do
    test "writes the four files, keys and directory private", %{pki: dir} do
      paths = Pki.paths(dir)

      assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
      assert File.stat!(paths.ca_key).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(paths.signer_key).mode |> Bitwise.band(0o777) == 0o600
      assert File.exists?(paths.ca_cert) and File.exists?(paths.signer_cert)
    end

    test "the root is a CA with pathlen 0, the signer is not", %{pki: dir} do
      ca =
        dir |> Pki.paths() |> Map.fetch!(:ca_cert) |> File.read!() |> X509.Certificate.from_pem!()

      signer = Pki.load_signer!(dir).cert

      assert {:Extension, _, true, {:BasicConstraints, true, 0}} =
               X509.Certificate.extension(ca, :basic_constraints)

      assert {:Extension, _, _, {:BasicConstraints, false, _}} =
               X509.Certificate.extension(signer, :basic_constraints)

      assert X509.Certificate.issuer(signer) == X509.Certificate.subject(ca)
    end

    test "refuses to overwrite and leaves the existing CA intact", %{pki: dir} do
      before = for {_, path} <- Pki.paths(dir), into: %{}, do: {path, File.read!(path)}

      assert_raise RuntimeError, ~r/refusing to overwrite/, fn -> Pki.gen_ca!(dir) end
      for {path, content} <- before, do: assert(File.read!(path) == content)
    end

    test "refuses when any one of the files exists", %{tmp_dir: tmp} do
      File.write!(Pki.paths(tmp).signer_key, "")

      assert_raise RuntimeError, ~r/signer\.key/, fn -> Pki.gen_ca!(tmp) end
      refute File.exists?(Pki.paths(tmp).ca_key)
    end
  end

  describe "dir/1" do
    test "an explicit directory wins, then KUBEX_PKI_DIR, then ~/.kubex/pki" do
      assert Pki.dir("some/where") == Path.expand("some/where")

      case System.get_env("KUBEX_PKI_DIR") do
        nil -> assert Pki.dir() == Path.expand("~/.kubex/pki")
        env -> assert Pki.dir() == Path.expand(env)
      end
    end
  end

  describe "gen_signer!/2" do
    test "refuses while a signer exists", %{pki: dir} do
      assert_raise RuntimeError, ~r/refusing to overwrite/, fn -> Pki.gen_signer!(dir) end
    end

    test "issues a new signer that the same root accepts", %{pki: dir, tmp_dir: tmp} do
      for file <- ["ca.pem", "ca.key"], do: File.cp!(Path.join(dir, file), Path.join(tmp, file))

      Pki.gen_signer!(tmp)
      signer = Pki.load_signer!(tmp)
      {sig, pem} = Pki.sign("data", signer)

      assert pem != File.read!(Pki.paths(dir).signer_cert)
      assert Pki.verify("data", sig, pem, ca_pem(dir)) == :ok
    end
  end

  describe "verify/5" do
    test "accepts a signature by the signer", %{pki: dir, signer: signer} do
      {sig, pem} = Pki.sign("manifest", signer)
      assert Pki.verify("manifest", sig, pem, ca_pem(dir)) == :ok
    end

    test "refuses changed data", %{pki: dir, signer: signer} do
      {sig, pem} = Pki.sign("manifest", signer)
      assert Pki.verify("manifest!", sig, pem, ca_pem(dir)) == {:error, :bad_signature}
    end

    test "refuses a signer from another CA", %{pki: dir, other: other} do
      {sig, pem} = Pki.sign("manifest", Pki.load_signer!(other))

      assert {:error, {:bad_signer_chain, _}} = Pki.verify("manifest", sig, pem, ca_pem(dir))
    end

    test "refuses a signer swapped for another one", %{pki: dir, other: other, signer: signer} do
      {sig, _} = Pki.sign("manifest", signer)
      other_pem = File.read!(Pki.paths(other).signer_cert)

      assert {:error, _} = Pki.verify("manifest", sig, other_pem, ca_pem(dir))
    end

    test "refuses a certificate of the root without codeSigning", %{pki: dir} do
      signer = issue(dir, ext_key_usage: X509.Certificate.Extension.ext_key_usage([:serverAuth]))
      {sig, pem} = Pki.sign("manifest", signer)

      assert Pki.verify("manifest", sig, pem, ca_pem(dir)) == {:error, :not_code_signing}
    end

    test "checks the signer's dates unless told not to", %{pki: dir} do
      now = DateTime.utc_now()

      validity =
        X509.Certificate.Validity.new(
          DateTime.add(now, -30, :day),
          DateTime.add(now, -1, :day)
        )

      signer = issue(dir, [], validity)
      {sig, pem} = Pki.sign("manifest", signer)

      assert Pki.verify("manifest", sig, pem, ca_pem(dir)) == {:error, :signer_expired}
      assert Pki.verify("manifest", sig, pem, ca_pem(dir), check_dates: false) == :ok
    end

    test "refuses garbage certificates", %{pki: dir, signer: signer} do
      {sig, pem} = Pki.sign("manifest", signer)

      assert Pki.verify("manifest", sig, "nope", ca_pem(dir)) == {:error, :bad_signer}
      assert Pki.verify("manifest", sig, pem, "nope") == {:error, :bad_ca}
    end
  end

  # A leaf issued by the root in `dir`, like the signer but with `extensions`
  # merged in. A small EC key: only the chain and the usage matter here.
  defp issue(dir, extensions, validity \\ 365) do
    paths = Pki.paths(dir)
    ca = paths.ca_cert |> File.read!() |> X509.Certificate.from_pem!()
    ca_key = paths.ca_key |> File.read!() |> X509.PrivateKey.from_pem!()
    key = X509.PrivateKey.new_ec(:secp256r1)

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=test", ca, ca_key,
        template:
          X509.Certificate.Template.new(:server,
            validity: validity,
            extensions:
              Keyword.merge(
                [ext_key_usage: X509.Certificate.Extension.ext_key_usage([:codeSigning])],
                extensions
              )
          )
      )

    %{cert: cert, key: key}
  end
end
