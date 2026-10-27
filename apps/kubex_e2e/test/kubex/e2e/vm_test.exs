defmodule Kubex.E2E.VMTest do
  use ExUnit.Case, async: true

  alias Kubex.E2E.VM

  @paths %{dir: "/t/dir", run_dir: "/run/kbx-x", ssh_port: 2222}

  defp spec(overrides \\ []) do
    struct!(
      VM,
      [name: "s1", boot: {:direct, "/k/vmlinuz", ["/k/initrd.img"], "console=ttyS0"}] ++ overrides
    )
  end

  defp pairs(argv), do: argv |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&List.to_tuple/1)

  test "the UUID and the MAC are derived from the name, so a restart is the same machine" do
    a = VM.normalize(spec())
    assert a == VM.normalize(spec())
    assert a.uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert a.mac =~ ~r/^52:54:00(:[0-9a-f]{2}){3}$/

    b = VM.normalize(spec(name: "s2"))
    assert b.uuid != a.uuid and b.mac != a.mac
  end

  test "explicit UUID and MAC win" do
    s = VM.normalize(spec(uuid: "6f1c0000-0000-4000-8000-000000000001", mac: "52:54:00:99:00:01"))
    assert s.uuid == "6f1c0000-0000-4000-8000-000000000001"
    assert s.mac == "52:54:00:99:00:01"
  end

  test "direct boot: KVM, paused start, SMBIOS UUID, console and QMP sockets in the run dir" do
    s = VM.normalize(spec())
    argv = VM.argv(s, @paths)
    p = pairs(argv)

    assert {"-machine", "q35,accel=kvm"} in p
    assert {"-m", "1024"} in p
    assert "-S" in argv
    assert {"-uuid", s.uuid} in p
    assert {"-smbios", "type=1,uuid=#{s.uuid}"} in p
    assert {"-kernel", "/k/vmlinuz"} in p
    assert {"-initrd", "/k/initrd.img"} in p
    assert {"-append", "console=ttyS0"} in p
    assert {"-chardev", "socket,id=con,path=/run/kbx-x/con.sock,server=on,wait=off"} in p
    assert {"-serial", "chardev:con"} in p
    assert {"-qmp", "unix:/run/kbx-x/qmp.sock,server=on,wait=off"} in p
    assert {"-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22"} in p
    assert {"-device", "virtio-net-pci,netdev=n0,mac=#{s.mac}"} in p
    refute Enum.any?(argv, &String.contains?(&1, "pflash"))
  end

  test "UEFI uses the shared OVMF code and a per-VM copy of the vars" do
    argv = VM.argv(VM.normalize(spec(firmware: :uefi)), @paths)

    assert "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd" in argv
    assert "if=pflash,format=raw,file=/t/dir/OVMF_VARS_4M.fd" in argv
  end

  test "a skewed RTC starts at the given time" do
    argv = VM.argv(VM.normalize(spec(rtc: {:skew, ~U[2020-01-01 00:00:00Z]})), @paths)
    assert {"-rtc", "base=2020-01-01T00:00:00"} in pairs(argv)
  end

  test "disks carry explicit serials on their bus" do
    argv =
      VM.argv(
        VM.normalize(spec(disks: [{:virtio, "KBXD0", "d0.qcow2"}, {:nvme, "KBXN0", "d1.img"}])),
        @paths
      )

    p = pairs(argv)

    assert {"-drive", "if=none,id=d0,file=d0.qcow2,format=qcow2"} in p
    assert {"-device", "virtio-blk-pci,drive=d0,serial=KBXD0"} in p
    assert {"-drive", "if=none,id=d1,file=d1.img,format=raw"} in p
    assert {"-device", "nvme,drive=d1,serial=KBXN0"} in p
  end

  test "several initrds are refused: QEMU takes one for a Linux kernel" do
    assert_raise ArgumentError, ~r/exactly one initrd/, fn ->
      VM.argv(VM.normalize(spec(boot: {:direct, "/k", ["a", "b"], ""})), @paths)
    end
  end
end
