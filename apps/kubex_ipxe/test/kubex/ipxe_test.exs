defmodule Kubex.IpxeTest do
  use ExUnit.Case, async: true

  @fwup_output """
  meta-product=kubex_fw
  meta-version=0.1.0
  meta-author="The Nerves Team"
  meta-platform=x86_64
  meta-architecture=x86_64
  meta-creation-date="2026-10-27T14:35:24Z"
  meta-uuid="648f236c-1b51-5f00-76b4-a24e4c12521b"
  meta-nickname="fox-margin"
  """

  test "fwup's metadata is parsed, quotes removed" do
    meta = Kubex.Ipxe.parse_metadata(@fwup_output)

    assert meta["uuid"] == "648f236c-1b51-5f00-76b4-a24e4c12521b"
    assert meta["author"] == "The Nerves Team"
    assert meta["version"] == "0.1.0"
    assert meta["creation-date"] == "2026-10-27T14:35:24Z"
  end

  test "the KV is what a Nerves install writes for slot a, active and validated" do
    kv = @fwup_output |> Kubex.Ipxe.parse_metadata() |> Kubex.Ipxe.kv()

    assert kv == %{
             "nerves_fw_active" => "a",
             "nerves_fw_validated" => "1",
             "a.nerves_fw_product" => "kubex_fw",
             "a.nerves_fw_version" => "0.1.0",
             "a.nerves_fw_author" => "The Nerves Team",
             "a.nerves_fw_platform" => "x86_64",
             "a.nerves_fw_architecture" => "x86_64",
             "a.nerves_fw_uuid" => "648f236c-1b51-5f00-76b4-a24e4c12521b"
           }
  end

  test "the KV file is sorted key=value lines, and refuses a newline in a value" do
    assert Kubex.Ipxe.encode_kv(%{"b" => "two words", "a" => "x=y"}) == "a=x=y\nb=two words\n"

    assert_raise ArgumentError, fn -> Kubex.Ipxe.encode_kv(%{"a" => "x\ny"}) end
  end

  test "boot.ipxe loads the kernel, stage-1 and the rootfs as /rootfs.squashfs, by relative URL" do
    script =
      @fwup_output
      |> Kubex.Ipxe.parse_metadata()
      |> Kubex.Ipxe.boot_script("console=ttyS0 kubex.join=demo")

    assert script =~ ~r/\A#!ipxe\n/
    assert script =~ "kernel vmlinuz console=ttyS0 kubex.join=demo\n"
    assert script =~ "initrd stage1.cpio.zst\n"
    assert script =~ "initrd rootfs.squashfs /rootfs.squashfs\n"
    assert script =~ ~r/\nboot\n\z/
    assert script =~ "648f236c-1b51-5f00-76b4-a24e4c12521b"
  end
end
