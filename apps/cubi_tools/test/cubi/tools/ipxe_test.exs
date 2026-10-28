defmodule Cubi.Tools.IpxeTest do
  use ExUnit.Case, async: true

  alias Cubi.Tools.Ipxe

  test "make builds the named targets, trusting only the given root" do
    assert Ipxe.make_args(["ipxe.efi", "1af41000.rom"], "/pki/ca.pem", 4) ==
             [
               "-j4",
               "bin-x86_64-efi/ipxe.efi",
               "bin/1af41000.rom",
               "TRUST=/pki/ca.pem",
               "CERT=/pki/ca.pem",
               "NO_WERROR=1"
             ]
  end

  test "an unknown target is refused before anything is built" do
    assert_raise ArgumentError, ~r/unknown target ipxe\.lkrn/, fn ->
      Ipxe.make_args(["ipxe.lkrn"], "/pki/ca.pem", 1)
    end
  end

  @tag :tmp_dir
  test "up_to_date?/3 wants this version's settings, the same CA and every target",
       %{tmp_dir: tmp} do
    ca = Path.join(tmp, "ca.pem")
    File.write!(ca, "root")
    out = Path.join(tmp, "out")
    refute Ipxe.up_to_date?(out, ca)

    # What build!/1 leaves behind, without running make.
    File.mkdir_p!(out)
    for t <- Ipxe.targets(), do: File.write!(Path.join(out, t), "")
    File.cp!(ca, Path.join(out, "ca.pem"))
    refute Ipxe.up_to_date?(out, ca), "no BUILD: built before it existed, or with other settings"

    File.write!(Path.join(out, "BUILD"), Ipxe.build_info(Ipxe.targets(), ca))
    assert Ipxe.up_to_date?(out, ca)

    File.write!(ca, "another root")
    refute Ipxe.up_to_date?(out, ca)
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
