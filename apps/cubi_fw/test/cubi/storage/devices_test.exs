defmodule Cubi.Storage.DevicesTest do
  use ExUnit.Case, async: true

  alias Cubi.Storage.Devices

  @moduletag :tmp_dir

  # The sysfs files a QEMU guest shows for `-device virtio-blk-pci,serial=…`,
  # `-device nvme,serial=…` and a SATA disk with a WWN (docs/phase0.md).
  defp sysfs(dir, disks) do
    for {disk, files} <- disks, {file, value} <- files do
      path = Path.join([dir, "block", disk, file])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, value <> "\n")
    end

    dir
  end

  defp qemu(dir) do
    sysfs(dir, %{
      "vda" => %{"serial" => "KBXD0"},
      "vdb" => %{"serial" => "KBXD1"},
      "vdc" => %{},
      "nvme0n1" => %{
        "wwid" => "nvme.1b36-4b42584e30-51454d55204e564d65204374726c-00000001",
        "nsid" => "1",
        "device/model" => "QEMU NVMe Ctrl                          ",
        "device/serial" => "KBXN0               "
      },
      "nvme0n2" => %{
        "wwid" => "nvme.1b36-4b42584e30-51454d55204e564d65204374726c-00000002",
        "nsid" => "2",
        "device/model" => "QEMU NVMe Ctrl                          ",
        "device/serial" => "KBXN0               "
      },
      "nvme0c0n1" => %{"nsid" => "1", "wwid" => "nvme.hidden"},
      "sda" => %{"device/wwid" => "naa.5000c500a1b2c3d4", "device/model" => "ST4000NM0035-1V4"},
      "sdb" => %{"device/wwid" => "t10.ATA     QEMU HARDDISK                           QM00005"},
      "loop0" => %{"serial" => "nope"}
    })
  end

  test "names udev would give", %{tmp_dir: dir} do
    assert Devices.names(qemu(dir)) == %{
             "virtio-KBXD0" => ["vda"],
             "virtio-KBXD1" => ["vdb"],
             "nvme-QEMU_NVMe_Ctrl_KBXN0" => ["nvme0n1"],
             "nvme-QEMU_NVMe_Ctrl_KBXN0_1" => ["nvme0n1"],
             "nvme-QEMU_NVMe_Ctrl_KBXN0_2" => ["nvme0n2"],
             "nvme-nvme.1b36-4b42584e30-51454d55204e564d65204374726c-00000001" => ["nvme0n1"],
             "nvme-nvme.1b36-4b42584e30-51454d55204e564d65204374726c-00000002" => ["nvme0n2"],
             "wwn-0x5000c500a1b2c3d4" => ["sda"]
           }
  end

  test "resolve: keywords kept, names to /dev nodes", %{tmp_dir: dir} do
    vdevs = [keyword: "mirror", device: "virtio-KBXD0", device: "nvme-QEMU_NVMe_Ctrl_KBXN0_2"]
    assert Devices.resolve(vdevs, qemu(dir)) == {:ok, ~w(mirror /dev/vda /dev/nvme0n2)}
  end

  test "resolve: an unknown name is an error listing the known ones", %{tmp_dir: dir} do
    assert {:error, {:unknown_device, "virtio-KBXD9", known}} =
             Devices.resolve([device: "virtio-KBXD0", device: "virtio-KBXD9"], qemu(dir))

    assert "virtio-KBXD1" in known
    # Kernel names are not by-id names.
    assert {:error, {:unknown_device, "vda", _}} = Devices.resolve([device: "vda"], dir)
  end

  test "resolve: a name two disks answer to is refused", %{tmp_dir: dir} do
    sysfs(dir, %{"vda" => %{"serial" => "SAME"}, "vdb" => %{"serial" => "SAME"}})

    assert Devices.resolve([device: "virtio-SAME"], dir) ==
             {:error, {:ambiguous_device, "virtio-SAME", ~w(vda vdb)}}
  end

  test "escaping", %{tmp_dir: dir} do
    sysfs(dir, %{"vda" => %{"serial" => "  a  b/c\tdé "}})
    assert Map.keys(Devices.names(dir)) == ["virtio-a_b_c_dé"]
  end

  test "no sysfs, no names", %{tmp_dir: dir} do
    assert Devices.names(Path.join(dir, "none")) == %{}
  end

  # This machine's own disks, against its udev.
  test "agrees with the host's /dev/disk/by-id" do
    case File.ls("/dev/disk/by-id") do
      {:ok, links} ->
        names = Devices.names("/sys")

        for {name, [disk]} <- names do
          assert name in links, "#{name} (#{disk}) not in /dev/disk/by-id"
          assert Path.basename(File.read_link!("/dev/disk/by-id/" <> name)) == disk
        end

      {:error, _} ->
        :ok
    end
  end
end
