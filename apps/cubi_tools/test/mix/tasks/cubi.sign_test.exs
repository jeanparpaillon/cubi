defmodule Mix.Tasks.Cubi.SignTest do
  use ExUnit.Case, async: false

  alias Cubi.Pki.Archive
  alias Mix.Tasks.Cubi.Sign

  @moduletag :tmp_dir

  setup_all do
    base = Path.join(System.tmp_dir!(), "cubi_sign_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    for name <- ~w(pki other), do: Cubi.Pki.gen_ca!(Path.join(base, name))
    %{pki: Path.join(base, "pki"), other: Path.join(base, "other")}
  end

  setup %{tmp_dir: tmp} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    files = %{"lib/hello-0.1.0/ebin/hello.app" => "app", "releases/0.1.0/sys.config" => "[]."}

    manifest =
      Cubi.Tools.Release.manifest(%{
        name: "hello",
        version: "0.1.0",
        base: %{"otp_release" => "29", "erts_version" => "17.0.2"},
        ship: [%{name: "hello", vsn: "0.1.0"}],
        requires: %{},
        start: ["hello"],
        files: files
      })

    archive = Path.join(tmp, "hello-0.1.0.tar.gz")
    Archive.write!(archive, Map.put(files, "manifest.json", JSON.encode!(manifest)))
    %{archive: archive}
  end

  defp ca(dir), do: File.read!(Cubi.Pki.paths(dir).ca_cert)

  test "adds manifest.sig and signer.pem, which verify against the root", context do
    Sign.run([context.archive, "--signer", context.pki])

    assert_received {:mix_shell, :info, [out]}
    assert out =~ "hello 0.1.0 signed"
    assert out =~ Cubi.Pki.ca_fingerprint(context.pki)

    entries = Archive.read!(context.archive)
    assert {:ok, %{"name" => "hello"}} = Archive.verify(entries, ca(context.pki))
    assert {:error, {:bad_signer_chain, _}} = Archive.verify(entries, ca(context.other))
  end

  test "signing again replaces the signature and the signer", context do
    Sign.run([context.archive, "--signer", context.other])
    Sign.run([context.archive, "--signer", context.pki])

    entries = Archive.read!(context.archive)
    assert {:ok, _} = Archive.verify(entries, ca(context.pki))
    assert entries |> Map.keys() |> Enum.count(&(&1 == "manifest.sig")) == 1
  end

  test "an archive whose files do not match its manifest is refused, untouched", context do
    entries = Archive.read!(context.archive)
    Archive.write!(context.archive, Map.put(entries, "lib/hello-0.1.0/ebin/hello.app", "evil"))
    before = File.read!(context.archive)

    assert_raise Mix.Error, ~r/hash_mismatch/, fn ->
      Sign.run([context.archive, "--signer", context.pki])
    end

    assert File.read!(context.archive) == before
  end

  test "defaults to CUBI_PKI_DIR", context do
    System.put_env("CUBI_PKI_DIR", context.pki)
    on_exit(fn -> System.delete_env("CUBI_PKI_DIR") end)

    Sign.run([context.archive])
    assert {:ok, _} = Archive.verify(Archive.read!(context.archive), ca(context.pki))
  end

  test "a missing archive or signer directory fails", context do
    assert_raise Mix.Error, ~r/no .*nope\.tar\.gz/, fn -> Sign.run(["nope.tar.gz"]) end

    assert_raise Mix.Error, ~r/mix cubi.gen_ca/, fn ->
      Sign.run([context.archive, "--signer", context.tmp_dir])
    end
  end
end
