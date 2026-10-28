defmodule Kubex.Tools.IpxeTest do
  use ExUnit.Case, async: true

  alias Kubex.Tools.Ipxe

  test "make builds the named targets, trusting only the given root" do
    assert Ipxe.make_args(["ipxe.efi", "1af41000.rom"], "/pki/ca.pem", 4) ==
             [
               "-j4",
               "bin-x86_64-efi/ipxe.efi",
               "bin/1af41000.rom",
               "TRUST=/pki/ca.pem",
               "NO_WERROR=1"
             ]
  end

  test "an unknown target is refused before anything is built" do
    assert_raise ArgumentError, ~r/unknown target ipxe\.lkrn/, fn ->
      Ipxe.make_args(["ipxe.lkrn"], "/pki/ca.pem", 1)
    end
  end

  @tag :tmp_dir
  test "a cached tarball that does not match the pinned checksum is refused", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "ipxe-#{Ipxe.version()}.tar.gz"), "not ipxe")
    ca = Path.join(tmp, "ca.pem")
    File.write!(ca, "")

    assert_raise RuntimeError, ~r/does not match the pinned SHA-512/, fn ->
      Ipxe.build!(ca: ca, output: Path.join(tmp, "out"), cache: tmp)
    end

    refute File.exists?(Path.join(tmp, "out"))
  end
end
