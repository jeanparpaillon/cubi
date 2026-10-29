defmodule Cubi.Pki.ArchiveTest do
  use ExUnit.Case, async: true

  alias Cubi.Pki
  alias Cubi.Pki.Archive

  @moduletag :tmp_dir

  setup_all do
    base = Path.join(System.tmp_dir!(), "cubi_archive_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    for name <- ~w(pki other), do: Pki.gen_ca!(Path.join(base, name))
    %{pki: Path.join(base, "pki"), other: Path.join(base, "other")}
  end

  @files %{"lib/a-1/ebin/a.app" => "app", "lib/a-1/priv/x" => "x"}

  defp entries(files \\ @files) do
    hashes =
      Map.new(files, fn {p, d} -> {p, Base.encode16(:crypto.hash(:sha256, d), case: :lower)} end)

    Map.put(files, "manifest.json", JSON.encode!(%{"format" => 1, "files" => hashes}))
  end

  defp ca(dir), do: File.read!(Pki.paths(dir).ca_cert)

  test "write!/2 then read/1 round-trips, manifest first", %{tmp_dir: tmp} do
    path = Path.join(tmp, "a.tar.gz")
    Archive.write!(path, entries())

    {:ok, table} = :erl_tar.table(String.to_charlist(path), [:compressed])
    assert hd(table) == ~c"manifest.json"
    assert Archive.read!(path) == entries()
  end

  describe "read/1 refuses" do
    defp tar(members) do
      path = Path.join(System.tmp_dir!(), "cubi_tar_#{System.unique_integer([:positive])}.tar.gz")
      :ok = :erl_tar.create(String.to_charlist(path), members, [:compressed])
      data = File.read!(path)
      File.rm!(path)
      data
    end

    test "paths with .. or absolute ones" do
      assert {:error, {:bad_member, "lib/../../etc/x"}} =
               Archive.read(tar([{~c"lib/../../etc/x", "x"}]))

      assert {:error, {:bad_member, _}} = Archive.read(tar([{~c"/etc/x", "x"}]))
    end

    test "symlinks", %{tmp_dir: tmp} do
      File.ln_s!("/etc/passwd", Path.join(tmp, "link"))
      data = tar([{~c"link", String.to_charlist(Path.join(tmp, "link"))}])

      assert {:error, {:bad_member, "link"}} = Archive.read(data)
    end

    test "something that is not a gzipped tar" do
      assert {:error, {:bad_archive, _}} = Archive.read("nope")
    end
  end

  describe "check_files/2" do
    test "accepts exactly the listed files, meta members aside" do
      e = entries() |> Map.merge(%{"manifest.sig" => "s", "signer.pem" => "p"})
      {:ok, m} = Archive.manifest(e)
      assert Archive.check_files(e, m) == :ok
    end

    test "names missing, unlisted and changed files" do
      {:ok, m} = Archive.manifest(entries())

      assert Archive.check_files(Map.delete(entries(), "lib/a-1/priv/x"), m) ==
               {:error, {:missing_files, ["lib/a-1/priv/x"]}}

      assert Archive.check_files(Map.put(entries(), "lib/b", "b"), m) ==
               {:error, {:unlisted_files, ["lib/b"]}}

      assert Archive.check_files(Map.put(entries(), "lib/a-1/priv/x", "y"), m) ==
               {:error, {:hash_mismatch, ["lib/a-1/priv/x"]}}
    end
  end

  describe "sign/2 and verify/3" do
    test "a signed archive verifies against its root only", %{pki: pki, other: other} do
      {:ok, signed} = Archive.sign(entries(), Pki.load_signer!(pki))

      assert {:ok, %{"format" => 1}} = Archive.verify(signed, ca(pki))
      assert {:error, {:bad_signer_chain, _}} = Archive.verify(signed, ca(other))
    end

    test "unsigned, or changed after signing, is refused", %{pki: pki} do
      assert Archive.verify(entries(), ca(pki)) == {:error, :unsigned}

      {:ok, signed} = Archive.sign(entries(), Pki.load_signer!(pki))

      assert Archive.verify(Map.put(signed, "lib/a-1/priv/x", "y"), ca(pki)) ==
               {:error, {:hash_mismatch, ["lib/a-1/priv/x"]}}

      assert Archive.verify(Map.put(signed, "manifest.json", "{}"), ca(pki)) ==
               {:error, :bad_signature}
    end

    test "a ca.pem member is known: not an unlisted file, round-tripped, never trusted by itself",
         %{pki: pki, other: other, tmp_dir: tmp} do
      {:ok, signed} = Archive.sign(entries(), Pki.load_signer!(pki))
      with_ca = Map.put(signed, "ca.pem", ca(other))

      assert Archive.ca(with_ca) == ca(other)
      assert Archive.ca(signed) == nil
      assert {:ok, _} = Archive.verify(with_ca, ca(pki))
      assert {:error, {:bad_signer_chain, _}} = Archive.verify(with_ca, ca(other))

      path = Path.join(tmp, "a.tar.gz")
      Archive.write!(path, with_ca)
      assert Archive.read!(path) == with_ca
    end

    test "sign/2 refuses files that do not match the manifest", %{pki: pki} do
      assert {:error, {:hash_mismatch, _}} =
               Archive.sign(Map.put(entries(), "lib/a-1/priv/x", "y"), Pki.load_signer!(pki))
    end
  end
end
