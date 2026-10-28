defmodule Kubex.E2E.Phase2SystemForkTest do
  @moduledoc """
  docs/phase2.md, acceptance: the phase-1 QEMU command boots with artifacts
  from the fork alone. The phase-1 test (`Phase1DirectBootTest`) already boots
  the system's kernel and stage-1 (`Kubex.E2E.Artifacts`); this adds what the
  fork itself changed:

    * the kernel is the system's, and erlinit has no disk to mount and a
      machine ID to use (docs/specs.md §2.6);
    * the hostname and serial number are the SMBIOS UUID, or the first MAC
      when the UUID is blank;
    * disk drivers load on their own, and ZFS loads with a fixed hostid and
      creates a pool (§2.5, §2.10.3, §2.10.5).
  """
  use Kubex.E2E.Case

  alias Kubex.E2E.Artifacts

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  defp boot(context, overrides) do
    spec =
      struct!(
        VM,
        [
          name: "p2",
          memory: 1024,
          boot:
            {:direct, Artifacts.kernel!(),
             [Artifacts.stage1!(), {"/rootfs.squashfs", {:file, Artifacts.rootfs!()}, 0o644}],
             Artifacts.cmdline("console=ttyS0")}
        ] ++ overrides
      )

    vm = start_vm!(context, spec)
    Console.await(vm, ~r/Interactive Elixir/, 60_000)
    vm
  end

  defp sh(vm, command) do
    Node.eval(vm, "System.cmd(\"sh\", [\"-c\", #{inspect(command)}], stderr_to_stdout: true)")
  end

  test "the system's kernel boots, and erlinit mounts nothing and finds a machine ID", context do
    vm = boot(context, [])
    console = Console.output(vm)

    assert console =~ ~r/Linux version 6\.18\.\S+ \(buildroot@buildroot\)/
    refute console =~ "erlinit: Cannot mount"
    refute console =~ "boardid"
  end

  test "hostname and serial number are the SMBIOS UUID", context do
    vm = boot(context, name: "p2-uuid")
    uuid = VM.info(vm).spec.uuid

    assert Node.eval(vm, "{:inet.gethostname(), Nerves.Runtime.serial_number()}") ==
             {{:ok, String.to_charlist(uuid)}, uuid}
  end

  test "with a blank SMBIOS UUID, the first MAC stands in", context do
    vm =
      boot(context,
        name: "p2-mac",
        uuid: "00000000-0000-0000-0000-000000000000",
        mac: "52:54:00:99:00:01"
      )

    assert Node.eval(vm, "{:inet.gethostname(), Nerves.Runtime.serial_number()}") ==
             {{:ok, ~c"525400990001"}, "525400990001"}
  end

  test "disk drivers autoload, and ZFS loads with a fixed hostid and creates a pool", context do
    disks =
      for {bus, serial} <- [virtio: "KBXD0", nvme: "KBXN0"] do
        # A sparse 1 GiB raw image.
        path = Path.join(context.dir, "#{serial}.img")

        File.open!(path, [:write], fn f ->
          {:ok, _} = :file.position(f, 1_073_741_824)
          :ok = :file.truncate(f)
        end)

        {bus, serial, path}
      end

    vm = boot(context, name: "p2-zfs", disks: disks)

    modules =
      Node.eval(vm, ~S"""
      File.read!("/proc/modules") |> String.split("\n", trim: true) |> Enum.map(&hd(String.split(&1)))
      """)

    assert "nvme" in modules

    assert {"KBXN0", "KBXD0"} ==
             Node.eval(vm, ~S"""
             {String.trim(File.read!("/sys/block/nvme0n1/device/serial")),
              String.trim(File.read!("/sys/block/vda/serial"))}
             """)

    assert {"2319391790\n", 0} =
             sh(
               vm,
               "modprobe spl spl_hostid=0x8a3f1c2e && modprobe zfs && " <>
                 "cat /sys/module/spl/parameters/spl_hostid"
             )

    assert {"kubex\tONLINE\n", 0} =
             sh(
               vm,
               "zpool create -o cachefile=none -m none kubex /dev/vda && " <>
                 "zpool export kubex && zpool import -N -o cachefile=none -d /dev kubex && " <>
                 "zpool list -H -o name,health"
             )
  end
end
