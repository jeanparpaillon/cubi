defmodule Cubi.E2E.Phase6StorageTest do
  @moduledoc """
  docs/phase6.md: the pool on QEMU disks with explicit serials
  (`Cubi.E2E.Disk`), named in `cubi.vdevs=` by their by-id-style names.

  Khepri comes with step 4; until then, a file written with `O_SYNC` stands
  for the data that must survive a reboot.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Artifacts, Disk}

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  @key String.duplicate("0123456789abcdef", 4)
  @mirror "cubi.vdevs=mirror,virtio-KBXD0,nvme-QEMU_NVMe_Ctrl_KBXN0"

  defp spec(name, disks, args) do
    %VM{
      name: name,
      memory: 1024,
      disks: disks,
      boot:
        {:direct, Artifacts.kernel!(),
         [Artifacts.stage1!(), {"/rootfs.squashfs", {:file, Artifacts.rootfs!()}, 0o644}],
         Artifacts.cmdline("console=ttyS0 " <> args)}
    }
  end

  # Makes the VM's images ahead of its start, and hashes them.
  defp digests(context, name, disks) do
    dir = Path.join(context.dir, name)
    File.mkdir_p!(dir)

    for {_, serial, kind} = disk <- disks do
      Disk.prepare!(dir, disk)
      Disk.digest!(Disk.path(dir, serial, kind))
    end
  end

  # The console line Cubi.Storage prints once setup is over.
  defp storage_line(vm) do
    [line] = Console.await(vm, ~r/cubi: storage: (?:pool|refused)[^\r\n]*\r?\n/, 120_000)
    line
  end

  test "a blank virtio + NVMe mirror is created, then imported across power cycles", context do
    disks = [{:virtio, "KBXD0", :blank}, {:nvme, "KBXN0", :blank}]
    spec = spec("p6-mirror", disks, "#{@mirror} cubi.zfs.create=1 cubi.zfs.testkey=#{@key}")

    vm = start_vm!(context, spec)
    assert storage_line(vm) =~ "pool cubi created, crypt mounted"
    assert Console.output(vm) =~ "cubi.zfs.testkey= keys the pool: for QEMU only"

    assert {{:ok, %{created: true, crypt: :mounted}}, props, status} =
             Node.eval(vm, ~S"""
             File.write!("/cubi/khepri/probe", "kept", [:sync])

             {props, 0} =
               System.cmd("zfs", ~w(get -H -o name,property,value -r
                 refreservation,mountpoint,encryption,cubi:testkey,sync cubi/cubi))

             {status, 0} = System.cmd("zpool", ~w(status -P cubi))
             {Cubi.Storage.status(), props, status}
             """)

    assert props =~ "cubi/cubi\trefreservation\t4G"
    assert props =~ "cubi/cubi\tmountpoint\tlegacy"
    assert props =~ "cubi/cubi\tsync\tstandard"
    assert props =~ "cubi/cubi/crypt\tencryption\taes-256-gcm"
    assert props =~ "cubi/cubi/crypt\tcubi:testkey\ton"
    assert props =~ "cubi/cubi/identity\tencryption\toff"
    assert status =~ ~r{mirror-0.*\n\s+/dev/vda1 .*\n\s+/dev/nvme0n1p1 }s

    # Pulled plug, no export: the same machine imports it without -f.
    vm = restart_vm!(context, spec)
    assert storage_line(vm) =~ "pool cubi imported, crypt mounted"
    assert Node.eval(vm, ~S|File.read!("/cubi/khepri/probe")|) == "kept"

    # No key: the pool and identity come up, crypt stays locked.
    vm = restart_vm!(context, spec("p6-mirror", disks, @mirror))
    assert storage_line(vm) =~ "pool cubi imported, crypt locked"

    assert Node.eval(vm, ~S"""
           File.read!("/proc/mounts") |> String.split("\n") |> Enum.filter(&(&1 =~ " zfs "))
           |> Enum.map(&(&1 |> String.split(" ") |> Enum.take(2)))
           """) == [["cubi/cubi", "/cubi"], ["cubi/cubi/identity", "/cubi/identity"]]

    # Another pool name over those disks: they hold one already, refused.
    vm =
      restart_vm!(
        context,
        spec("p6-mirror", disks, "#{@mirror} cubi.zpool=other cubi.zfs.create=1")
      )

    assert storage_line(vm) =~ "refused"
    assert {:error, {:not_blank, [_ | _]}} = Node.eval(vm, "Cubi.Storage.status()")
  end

  test "a disk with a partition table is refused, and left untouched", context do
    disks = [{:virtio, "KBXD0", :blank}, {:virtio, "KBXD1", :dirty}]
    before = digests(context, "p6-dirty", disks)

    vm =
      start_vm!(
        context,
        spec("p6-dirty", disks, "cubi.vdevs=mirror,virtio-KBXD0,virtio-KBXD1 cubi.zfs.create=1")
      )

    assert storage_line(vm) =~ "refused"

    assert Node.eval(vm, "Cubi.Storage.status()") ==
             {:error,
              {:not_blank, [{"/dev/vdb", "gpt"}, {"/dev/vdb", "gpt"}, {"/dev/vdb", "PMBR"}]}}

    :ok = stop_supervised({VM, "p6-dirty"})
    assert digests(context, "p6-dirty", disks) == before
  end

  test "without cubi.zfs.create=1, blank disks are refused, and left untouched", context do
    disks = [{:virtio, "KBXD0", :blank}, {:nvme, "KBXN0", :blank}]
    before = digests(context, "p6-nocreate", disks)
    vm = start_vm!(context, spec("p6-nocreate", disks, @mirror))

    assert storage_line(vm) =~ "refused"
    assert Node.eval(vm, "Cubi.Storage.status()") == {:error, {:no_pool, "cubi"}}

    :ok = stop_supervised({VM, "p6-nocreate"})
    assert digests(context, "p6-nocreate", disks) == before
  end
end
