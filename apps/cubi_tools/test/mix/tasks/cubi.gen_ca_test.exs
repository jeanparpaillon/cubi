defmodule Mix.Tasks.Cubi.GenCaTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Cubi.GenCa

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp run(args) do
    GenCa.run(args)
    assert_received {:mix_shell, :info, [out]}
    out
  end

  test "creates the PKI in --dir and prints the root fingerprint", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "pki")
    out = run(["--dir", dir, "--name", "acme"])

    assert out =~ Cubi.Pki.ca_fingerprint(dir)

    assert Cubi.Pki.load_signer!(dir).cert
           |> X509.Certificate.subject()
           |> X509.RDNSequence.to_string() ==
             "/CN=acme signer"
  end

  test "defaults to CUBI_PKI_DIR", %{tmp_dir: tmp} do
    System.put_env("CUBI_PKI_DIR", tmp)
    on_exit(fn -> System.delete_env("CUBI_PKI_DIR") end)

    run([])
    assert File.exists?(Path.join(tmp, "ca.pem"))
  end

  test "a second run fails and leaves the first CA intact", %{tmp_dir: tmp} do
    run(["--dir", tmp])
    ca = File.read!(Path.join(tmp, "ca.key"))

    assert_raise Mix.Error, ~r/refusing to overwrite/, fn -> GenCa.run(["--dir", tmp]) end
    assert File.read!(Path.join(tmp, "ca.key")) == ca
  end

  test "--signer-only replaces a removed signer under the same root", %{tmp_dir: tmp} do
    run(["--dir", tmp])
    fingerprint = Cubi.Pki.ca_fingerprint(tmp)
    old = File.read!(Path.join(tmp, "signer.pem"))

    assert_raise Mix.Error, ~r/refusing to overwrite/, fn ->
      GenCa.run(["--dir", tmp, "--signer-only"])
    end

    File.rm!(Path.join(tmp, "signer.pem"))
    File.rm!(Path.join(tmp, "signer.key"))
    assert run(["--dir", tmp, "--signer-only"]) =~ "New signer"

    assert Cubi.Pki.ca_fingerprint(tmp) == fingerprint
    assert File.read!(Path.join(tmp, "signer.pem")) != old
    {sig, pem} = Cubi.Pki.sign("x", Cubi.Pki.load_signer!(tmp))
    assert Cubi.Pki.verify("x", sig, pem, File.read!(Path.join(tmp, "ca.pem"))) == :ok
  end

  test "--signer-only without a root fails", %{tmp_dir: tmp} do
    assert_raise Mix.Error, ~r/ca\.pem/, fn -> GenCa.run(["--dir", tmp, "--signer-only"]) end
  end
end
