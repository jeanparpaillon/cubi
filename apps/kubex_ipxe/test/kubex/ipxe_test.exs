defmodule Kubex.IpxeTest do
  use ExUnit.Case, async: true

  # Two roots, for trusted_ca!/2: generated once, RSA-3072 takes a while.
  setup_all do
    base = Path.join(System.tmp_dir!(), "kubex_ipxe_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    for name <- ~w(pki other), do: Kubex.Pki.gen_ca!(Path.join(base, name))
    %{pki: Path.join(base, "pki"), other: Path.join(base, "other")}
  end

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

  test "imgverify: true checks each image against its .sig right after loading it" do
    script =
      @fwup_output
      |> Kubex.Ipxe.parse_metadata()
      |> Kubex.Ipxe.boot_script("console=ttyS0", imgverify: true)

    assert script =~ """
           kernel vmlinuz console=ttyS0
           imgverify vmlinuz vmlinuz.sig
           initrd stage1.cpio.zst
           imgverify stage1.cpio.zst stage1.cpio.zst.sig
           initrd rootfs.squashfs /rootfs.squashfs
           imgverify rootfs.squashfs rootfs.squashfs.sig
           boot
           """
  end

  test "without imgverify, the script has no imgverify line" do
    script = @fwup_output |> Kubex.Ipxe.parse_metadata() |> Kubex.Ipxe.boot_script("x")
    refute script =~ "imgverify"
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

  describe "base/3" do
    @describetag :tmp_dir

    test "reads ERTS and every application from the rootfs, OTP from the system", %{tmp_dir: root} do
      erlang = Path.join(root, "srv/erlang")
      File.mkdir_p!(Path.join(erlang, "releases"))
      File.write!(Path.join(erlang, "releases/start_erl.data"), "17.0.2 0.1.0\n")

      for dir <- ~w(kernel-11.0.2 nerves_runtime-0.13.13 elixir-1.20.2),
          do: File.mkdir_p!(Path.join([erlang, "lib", dir]))

      meta = Kubex.Ipxe.parse_metadata(@fwup_output)

      assert Kubex.Ipxe.base(root, "29.0.2", meta) == %{
               "format" => 1,
               "otp_release" => "29",
               "otp_version" => "29.0.2",
               "erts_version" => "17.0.2",
               "release" => %{"name" => "kubex_fw", "version" => "0.1.0"},
               "firmware" => %{
                 "product" => "kubex_fw",
                 "version" => "0.1.0",
                 "uuid" => "648f236c-1b51-5f00-76b4-a24e4c12521b"
               },
               "applications" => %{
                 "kernel" => "11.0.2",
                 "nerves_runtime" => "0.13.13",
                 "elixir" => "1.20.2"
               }
             }
    end
  end

  describe "trusted_ca!/2" do
    test "no CA and no signer: nothing trusted" do
      assert Kubex.Ipxe.trusted_ca!(nil, nil) == nil
    end

    test "a CA alone is trusted as is, signed or not", %{other: other} do
      ca = Kubex.Pki.paths(other).ca_cert
      assert Kubex.Ipxe.trusted_ca!(ca, nil) == ca
    end

    test "a signer alone brings its own root", %{pki: pki} do
      assert Kubex.Ipxe.trusted_ca!(nil, pki) == Kubex.Pki.paths(pki).ca_cert
    end

    @tag :tmp_dir
    test "a copy of the signer's root is accepted", %{pki: pki, tmp_dir: tmp} do
      copy = Path.join(tmp, "ca.pem")
      File.cp!(Kubex.Pki.paths(pki).ca_cert, copy)

      assert Kubex.Ipxe.trusted_ca!(copy, pki) == copy
    end

    test "another root than the signer's is refused", %{pki: pki, other: other} do
      assert_raise RuntimeError, ~r/not the root that issued the signer/, fn ->
        Kubex.Ipxe.trusted_ca!(Kubex.Pki.paths(other).ca_cert, pki)
      end
    end
  end
end
