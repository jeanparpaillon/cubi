defmodule Kubex.E2E.Phase3FirmwareIpxeTest do
  @moduledoc """
  docs/phase3.md, acceptance: one command turns a clean checkout into a served
  directory.

  The command is `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware.ipxe` in
  apps/kubex_fw; this checks its output, `_build/x86_64_e2e/ipxe/`, against
  the `.fw` it came from, then boots it the way `boot.ipxe` says.
  """
  use Kubex.E2E.Case

  alias Kubex.E2E.Artifacts

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  @files ~w(boot.ipxe rootfs.squashfs stage1.cpio.zst vmlinuz)

  setup_all do
    dir = Artifacts.served_dir!()
    fw = Path.join([dir, "..", "nerves", "images", "kubex_fw.fw"]) |> Path.expand()
    {meta, 0} = System.cmd("fwup", ["-m", "-i", fw])
    [_, uuid] = Regex.run(~r/^meta-uuid="(.*)"$/m, meta)
    [_, version] = Regex.run(~r/^meta-version=(.*)$/m, meta)
    {:ok, served: dir, fw_uuid: uuid, fw_version: version}
  end

  test "the directory holds the four files, and SHA256SUMS matches them", %{served: dir} do
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
