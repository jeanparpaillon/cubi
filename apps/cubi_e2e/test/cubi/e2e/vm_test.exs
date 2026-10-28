defmodule Cubi.E2E.VMTest do
  use ExUnit.Case, async: true

  alias Cubi.E2E.VM

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
    assert {"-fw_cfg", "name=etc/sercon-port,file=/t/dir/sercon-port"} in p
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

  test "fixture disks live in the VM's directory, named after their serial" do
    argv =
      VM.argv(
        VM.normalize(spec(disks: [{:virtio, "KBXD0", :blank}, {:nvme, "KBXN0", :dirty}])),
        @paths
      )

    p = pairs(argv)

    assert {"-drive", "if=none,id=d0,file=/t/dir/disk-KBXD0.qcow2,format=qcow2"} in p
    assert {"-drive", "if=none,id=d1,file=/t/dir/disk-KBXN0.qcow2,format=qcow2"} in p
  end

  test "several initrds, or a named one, become one assembled file in the test dir" do
    for initrds <- [["a", "b"], [{"/cubi/token", "t", 0o400}]] do
      argv = VM.argv(VM.normalize(spec(boot: {:direct, "/k", initrds, ""})), @paths)
      assert {"-initrd", "/t/dir/initrd.img"} in pairs(argv)
    end
  end

  describe "PXE boot" do
    @pxe_paths Map.put(@paths, :http_port, 8080)

    defp netdev(argv),
      do:
        argv
        |> pairs()
        |> Enum.find_value(fn
          {"-netdev", v} -> v
          _ -> nil
        end)

    defp nic(argv),
      do:
        argv
        |> pairs()
        |> Enum.find_value(fn
          {"-device", "virtio-net" <> _ = v} -> v
          _ -> nil
        end)

    test "BIOS over TFTP: slirp serves the directory, QEMU's iPXE ROM runs boot.ipxe" do
      argv = VM.argv(VM.normalize(spec(boot: {:pxe, :tftp, "/srv/ipxe"})), @pxe_paths)

      assert netdev(argv) =~ ",tftp=/srv/ipxe,bootfile=boot.ipxe"
      assert nic(argv) =~ ",bootindex=0"
      refute "-kernel" in argv
    end

    test "BIOS over HTTP: the DHCP filename is the boot.ipxe URL" do
      argv = VM.argv(VM.normalize(spec(boot: {:pxe, :http, "/srv/ipxe"})), @pxe_paths)

      assert netdev(argv) =~ ",bootfile=http://10.0.2.2:8080/boot.ipxe"
      refute netdev(argv) =~ "tftp="
    end

    test "UEFI, either protocol: OVMF's PXE loads ipxe.efi from the per-VM TFTP root" do
      for protocol <- [:tftp, :http] do
        argv =
          VM.argv(
            VM.normalize(spec(firmware: :uefi, boot: {:pxe, protocol, "/srv/ipxe"})),
            @pxe_paths
          )

        assert netdev(argv) =~ ",tftp=/t/dir/pxe,bootfile=ipxe.efi"
        assert nic(argv) =~ ",bootindex=0"
      end
    end

    test "trusted iPXE, BIOS: cubi's build replaces the NIC's option ROM" do
      argv =
        VM.argv(VM.normalize(spec(ipxe: :trusted, boot: {:pxe, :tftp, "/srv/ipxe"})), @pxe_paths)

      assert nic(argv) =~
               ",romfile=#{Cubi.E2E.Ipxe.trusted_path("1af41000.rom")}"
    end

    test "stock iPXE, or UEFI: the NIC keeps QEMU's option ROM" do
      for spec <- [
            spec(boot: {:pxe, :tftp, "/srv/ipxe"}),
            spec(firmware: :uefi, ipxe: :trusted, boot: {:pxe, :tftp, "/srv/ipxe"})
          ] do
        refute VM.argv(VM.normalize(spec), @pxe_paths) |> nic() =~ "romfile"
      end
    end

    test "direct boot puts no boot options on the NIC" do
      argv = VM.argv(VM.normalize(spec()), @paths)

      refute netdev(argv) =~ "bootfile"
      refute nic(argv) =~ "bootindex"
    end
  end
end
