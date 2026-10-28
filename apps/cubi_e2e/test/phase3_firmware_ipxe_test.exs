defmodule Cubi.E2E.Phase3FirmwareIpxeTest do
  @moduledoc """
  docs/phase3.md, acceptance: one command turns a clean checkout into a served
  directory.

  The command is `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware.ipxe` in
  apps/cubi_fw; this checks its output, `_build/x86_64_e2e/ipxe/`, against
  the `.fw` it came from, then boots it the way `boot.ipxe` says.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.Artifacts

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  @images ~w(rootfs.squashfs stage1.cpio.zst vmlinuz)
  @files ~w(boot.ipxe base.json) ++ @images ++ Enum.map(@images, &(&1 <> ".sig"))

  setup_all do
    dir = Artifacts.served_dir!()
    fw = Path.join([dir, "..", "nerves", "images", "cubi_fw.fw"]) |> Path.expand()
    {meta, 0} = System.cmd("fwup", ["-m", "-i", fw])
    [_, uuid] = Regex.run(~r/^meta-uuid="(.*)"$/m, meta)
    [_, version] = Regex.run(~r/^meta-version=(.*)$/m, meta)
    {:ok, served: dir, fw_uuid: uuid, fw_version: version}
  end

  test "the directory holds the served files, and SHA256SUMS matches them", %{served: dir} do
    assert Enum.sort(File.ls!(dir)) == Enum.sort(["SHA256SUMS" | @files])

    sums =
      for line <- dir |> Path.join("SHA256SUMS") |> File.read!() |> String.split("\n", trim: true),
          into: %{} do
        [sum, name] = String.split(line, "  ")
        {name, sum}
      end

    for name <- @files do
      actual =
        :crypto.hash(:sha256, File.read!(Path.join(dir, name))) |> Base.encode16(case: :lower)

      assert sums[name] == actual, name
    end
  end

  test "the served rootfs has no /boot, and carries the firmware metadata", %{served: dir} do
    {listing, 0} = System.cmd("unsquashfs", ["-n", "-lln", Path.join(dir, "rootfs.squashfs")])

    refute listing =~ ~r{squashfs-root/boot(/|$)}m
    assert listing =~ ~r{^-rw-r--r-- 0/0 .* squashfs-root/etc/firmware\.kv$}m
    assert listing =~ ~r{^-rwsr-xr-x 0/0 .* squashfs-root/bin/busybox$}m
  end

  test "the images are signed by the test CA's signer, and nobody else's", %{served: dir} do
    ca = Cubi.Pki.paths(Cubi.E2E.Key.pki_dir()).ca_cert
    other = Path.join(System.tmp_dir!(), "cubi_p3_other_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(other) end)
    Cubi.Pki.gen_ca!(other)

    for image <- @images do
      path = Path.join(dir, image)
      assert Cubi.Pki.Cms.verify(path, path <> ".sig", ca) == :ok, image

      assert {:error, _} =
               Cubi.Pki.Cms.verify(path, path <> ".sig", Cubi.Pki.paths(other).ca_cert)
    end
  end

  test "the served rootfs trusts the test CA for releases (docs/specs.md §2.11.2)", %{served: dir} do
    rootfs = Path.join(dir, "rootfs.squashfs")
    {listing, 0} = System.cmd("unsquashfs", ["-n", "-lln", rootfs])
    {ca, 0} = System.cmd("unsquashfs", ["-cat", rootfs, "etc/cubi/ca.pem"])

    assert listing =~ ~r{^-rw-r--r-- 0/0 .* squashfs-root/etc/cubi/ca\.pem$}m
    assert ca == File.read!(Cubi.Pki.paths(Cubi.E2E.Key.pki_dir()).ca_cert)
  end

  test "base.json describes the image's OTP and applications", %{served: dir} = context do
    base = dir |> Path.join("base.json") |> File.read!() |> JSON.decode!()

    assert base["otp_release"] == "29"
    assert base["firmware"]["uuid"] == context.fw_uuid
    assert base["release"]["name"] == "cubi_fw"

    assert %{"kernel" => _, "elixir" => _, "shoehorn" => _, "cubi_fw" => _} =
             base["applications"]
  end

  test "boot.ipxe loads what is served, by relative URL", %{served: dir} do
    script = File.read!(Path.join(dir, "boot.ipxe"))

    assert script =~ ~r/^kernel vmlinuz /m
    assert script =~ ~r/^initrd stage1\.cpio\.zst$/m
    assert script =~ ~r/^initrd rootfs\.squashfs \/rootfs\.squashfs$/m
    refute script =~ "http"
  end

  test "booted as served, the firmware reports the .fw's metadata, validated", context do
    [_, cmdline] =
      Regex.run(~r/^kernel vmlinuz (.*)$/m, File.read!(Path.join(context.served, "boot.ipxe")))

    vm =
      start_vm!(context, %VM{
        name: "p3",
        memory: 1024,
        boot:
          {:direct, Artifacts.kernel!(),
           [Artifacts.stage1!(), {"/rootfs.squashfs", {:file, Artifacts.rootfs!()}, 0o644}],
           Artifacts.cmdline(cmdline)}
      })

    Console.await(vm, ~r/Interactive Elixir/, 60_000)

    assert Node.eval(vm, ~S"""
           {Nerves.Runtime.firmware_validation_status(),
            Nerves.Runtime.KV.get_active("nerves_fw_uuid"),
            Nerves.Runtime.KV.get_active("nerves_fw_version")}
           """) == {:validated, context.fw_uuid, context.fw_version}
  end
end
