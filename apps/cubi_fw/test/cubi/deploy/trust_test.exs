defmodule Cubi.Deploy.TrustTest do
  use ExUnit.Case, async: true

  alias Cubi.Deploy.Trust

  setup_all do
    base = Path.join(System.tmp_dir!(), "cubi_trust_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    for name <- ~w(a b), do: Cubi.Pki.gen_ca!(Path.join(base, name))

    for name <- ~w(a b), into: %{} do
      pem = File.read!(Cubi.Pki.paths(Path.join(base, name)).ca_cert)
      {:ok, hex} = Cubi.Pki.cert_sha256(pem)
      {String.to_atom(name), %{pem: pem, hex: hex}}
    end
  end

  defp pin(hex), do: {:ok, hex}

  describe "pin/1" do
    test "absent, well-formed, the last one wins" do
      hex = String.duplicate("ab", 32)
      other = String.duplicate("cd", 32)

      assert Trust.pin([{"console", "ttyS0"}]) == nil
      assert Trust.pin([{"cubi.ca", "sha256:" <> hex}]) == {:ok, hex}

      assert Trust.pin([{"cubi.ca", "sha256:" <> other}, {"cubi.ca", "sha256:" <> hex}]) ==
               {:ok, hex}
    end

    test "malformed pins are errors, never ignored" do
      for value <- [
            nil,
            "",
            "sha1:" <> String.duplicate("ab", 20),
            "sha256:" <> String.duplicate("AB", 32),
            "sha256:abcd",
            String.duplicate("ab", 32)
          ] do
        assert Trust.pin([{"cubi.ca", value}]) == {:error, {:bad_ca_pin, value}}
      end
    end
  end

  describe "root/3" do
    test "the image's CA, alone or pinned to itself; the archive's ca.pem is ignored", ctx do
      entries = %{"ca.pem" => ctx.b.pem}

      assert Trust.root(ctx.a.pem, nil, entries) == {:ok, ctx.a.pem}
      assert Trust.root(ctx.a.pem, pin(ctx.a.hex), entries) == {:ok, ctx.a.pem}
    end

    test "the image's CA and a pin for another root refuse everything", ctx do
      assert Trust.root(ctx.a.pem, pin(ctx.b.hex), %{"ca.pem" => ctx.b.pem}) ==
               {:error, {:ca_pin_mismatch, image: ctx.a.hex, pin: ctx.b.hex}}
    end

    test "no image CA: the archive's ca.pem, only when the pin names it", ctx do
      assert Trust.root(nil, pin(ctx.a.hex), %{"ca.pem" => ctx.a.pem}) == {:ok, ctx.a.pem}

      assert Trust.root(nil, pin(ctx.a.hex), %{"ca.pem" => ctx.b.pem}) ==
               {:error, {:archive_ca_not_pinned, ctx.b.hex}}

      assert Trust.root(nil, pin(ctx.a.hex), %{}) == {:error, :no_archive_ca}
      assert Trust.root(nil, pin(ctx.a.hex), %{"ca.pem" => "junk"}) == {:error, :bad_archive_ca}
    end

    test "neither, or a malformed pin, refuse everything", ctx do
      assert Trust.root(nil, nil, %{"ca.pem" => ctx.a.pem}) == {:error, :no_trusted_ca}

      bad = {:error, {:bad_ca_pin, "x"}}
      assert Trust.root(ctx.a.pem, bad, %{}) == bad
      assert Trust.root(nil, bad, %{"ca.pem" => ctx.a.pem}) == bad
    end
  end
end
