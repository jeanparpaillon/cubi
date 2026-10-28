defmodule Cubi.E2E.DiskTest do
  use ExUnit.Case, async: true

  alias Cubi.E2E.Disk

  @moduletag :tmp_dir

  defp info(image) do
    {json, 0} = System.cmd("qemu-img", ["info", "--output=json", image])
    JSON.decode!(json)
  end

  # The partition table as sfdisk dumps it, read through a raw copy.
  defp sfdisk_dump(image, dir) do
    raw = Path.join(dir, "dump.raw")
    {_, 0} = System.cmd("qemu-img", ["convert", "-O", "raw", image, raw])
    {out, status} = System.cmd("sfdisk", ["--dump", raw], stderr_to_stdout: true)
    File.rm!(raw)
    {out, status}
  end

  test "blank: an 8G sparse qcow2 with no partition table", %{tmp_dir: dir} do
    :ok = Disk.prepare!(dir, {:virtio, "KBXD0", :blank})
    image = Path.join(dir, "disk-KBXD0.qcow2")

    assert %{"format" => "qcow2", "virtual-size" => 8_589_934_592} = info(image)
    assert File.stat!(image).size < 1_000_000
    assert {_, status} = sfdisk_dump(image, dir)
    assert status != 0
  end

  test "dirty: a GPT with one partition", %{tmp_dir: dir} do
    :ok = Disk.prepare!(dir, {:nvme, "KBXN0", :dirty})
    image = Path.join(dir, "disk-KBXN0.qcow2")

    assert %{"format" => "qcow2", "virtual-size" => 8_589_934_592} = info(image)
    assert {dump, 0} = sfdisk_dump(image, dir)
    assert dump =~ "label: gpt"
    assert dump =~ ~r/dump\.raw1 : start=/
    assert File.ls!(dir) == ["disk-KBXN0.qcow2"]
  end

  test "kept across prepares; discard! makes the next one fresh", %{tmp_dir: dir} do
    disk = {:virtio, "KBXD0", :blank}
    :ok = Disk.prepare!(dir, disk)
    image = Path.join(dir, "disk-KBXD0.qcow2")
    File.write!(image, "the guest wrote here")

    :ok = Disk.prepare!(dir, disk)
    assert File.read!(image) == "the guest wrote here"

    :ok = Disk.discard!(dir, "KBXD0")
    :ok = Disk.prepare!(dir, disk)
    assert %{"format" => "qcow2"} = info(image)
  end

  test "a path is used as is", %{tmp_dir: dir} do
    assert Disk.path(dir, "X", "mine.img") == "mine.img"
    :ok = Disk.prepare!(dir, {:virtio, "X", "mine.img"})
    assert File.ls!(dir) == []
  end

  test "digest! is the image file's SHA-256", %{tmp_dir: dir} do
    image = Path.join(dir, "f")
    File.write!(image, "abc")

    assert Disk.digest!(image) ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end
end
