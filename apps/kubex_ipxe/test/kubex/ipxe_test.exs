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

  test "modes are read from ls-style permissions, setuid, setgid and sticky included" do
    assert Kubex.Ipxe.mode("-rwxr-xr-x") == 0o755
    assert Kubex.Ipxe.mode("-rwsr-xr-x") == 0o4755
    assert Kubex.Ipxe.mode("drwxrwxrwt") == 0o1777
    assert Kubex.Ipxe.mode("-rwxr-Sr--") == 0o2744
    assert Kubex.Ipxe.mode("drwx------") == 0o700
  end

  test "pseudo definitions restore mode and owner of files and directories, not the root or symlinks" do
    listing = """
    drwxr-xr-x 1000/1000               306 2026-10-27 15:35 squashfs-root
    -rwsr-xr-x 0/0                 1073000 2026-10-27 15:35 squashfs-root/bin/busybox
    lrwxrwxrwx 0/0                       7 2026-10-27 15:35 squashfs-root/bin/sh -> busybox
    drwxrwxrwt 0/0                       3 2026-10-27 15:35 squashfs-root/tmp
    drwxr-xr-x 33/33                     3 2026-10-27 15:35 squashfs-root/var/www
    -rw-r--r-- 0/0                      12 2026-10-27 15:35 squashfs-root/etc/a file
    """

    assert Kubex.Ipxe.pseudo_definitions(listing) == [
             "/bin/busybox m 4755 0 0",
             "/tmp m 1777 0 0",
             "/var/www m 755 33 33",
             "/etc/a\\ file m 644 0 0"
           ]
  end
end
