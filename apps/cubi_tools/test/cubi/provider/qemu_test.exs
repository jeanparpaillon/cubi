defmodule Cubi.Provider.QemuTest do
  # Starts real QEMU processes, under TCG so that no /dev/kvm is needed; the
  # trivial script never boots anything. Booting an image through this
  # provider is the harness's (apps/cubi_e2e).
  use Cubi.Provider.Case, provider: Cubi.Provider.Qemu, async: true

  alias Cubi.Provider.Qemu

  @moduletag :tmp_dir
  @moduletag :qemu

  setup %{tmp_dir: tmp} do
    %{provider_opts: [dir: tmp, accel: "tcg", size: "64"]}
  end

  test "a reboot restarts QEMU with the same machine and the new script", context do
    {Qemu, state} = start!(context)
    spec = spec(context, "a")

    {:ok, instance} = Qemu.create(state, spec)
    dir = instance.provider.dir
    pid = File.read!(Path.join(dir, "qemu.pid"))
    argv = File.read!(Path.join(dir, "qemu.argv"))

    :ok = Qemu.set_script(state, instance, "#!ipxe\n# v2\n")
    :ok = Qemu.reboot(state, instance)

    assert File.read!(Path.join(dir, "tftp/boot.ipxe")) == "#!ipxe\n# v2\n"
    assert File.read!(Path.join(dir, "qemu.pid")) != pid
    assert File.read!(Path.join(dir, "qemu.argv")) == argv
    assert {:ok, %{status: :running}} = Qemu.get(state, spec.name)
  end

  test "destroy/2 leaves no QEMU process behind", context do
    {Qemu, state} = start!(context)
    {:ok, instance} = Qemu.create(state, spec(context, "a"))
    pid = File.read!(Path.join(instance.provider.dir, "qemu.pid")) |> String.trim()

    :ok = Qemu.destroy(state, instance)
    refute File.exists?("/proc/#{pid}")
    refute File.exists?(instance.provider.dir)
  end

  test "an instance whose QEMU died is reported stopped, and a reboot starts it", context do
    {Qemu, state} = start!(context)
    spec = spec(context, "a")
    {:ok, instance} = Qemu.create(state, spec)
    pid = File.read!(Path.join(instance.provider.dir, "qemu.pid")) |> String.trim()

    System.cmd("kill", ["-KILL", pid])
    Process.sleep(200)
    assert {:ok, %{status: :stopped}} = Qemu.get(state, spec.name)

    :ok = Qemu.reboot(state, instance)
    assert {:ok, %{status: :running}} = Qemu.get(state, spec.name)
  end

  test "argv: BIOS boots boot.ipxe from the NIC ROM, UEFI chainloads ipxe.efi" do
    {:ok, state} = Qemu.init(dir: "/q", accel: "kvm")

    record = %{
      "name" => "n1",
      "firmware" => "bios",
      "size" => "1024",
      "uuid" => "u",
      "mac" => "52:54:00:00:00:01",
      "ssh_port" => 2222
    }

    bios = Qemu.argv(state, "/q/n1", record)
    assert "user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,tftp=/q/n1/tftp,bootfile=boot.ipxe" in bios
    assert "-daemonize" in bios
    assert "host" in bios

    uefi = Qemu.argv(state, "/q/n1", %{record | "firmware" => "uefi"})
    assert "user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,tftp=/q/n1/tftp,bootfile=ipxe.efi" in uefi
    assert "if=pflash,format=raw,file=/q/n1/OVMF_VARS_4M.fd" in uefi
  end

  test "bad names, and UEFI without an ipxe.efi, are refused before anything starts",
       %{tmp_dir: tmp} do
    {:ok, state} = Qemu.init(dir: tmp, ipxe_efi: Path.join(tmp, "none.efi"))
    spec = %{name: "n1", script: "#!ipxe\n", firmware: :bios}

    assert {:error, {:bad_name, "../x"}} = Qemu.create(state, %{spec | name: "../x"})
    assert {:error, {:bad_name, "N1"}} = Qemu.create(state, %{spec | name: "N1"})
    assert {:error, {:no_ipxe_efi, _}} = Qemu.create(state, %{spec | firmware: :uefi})
    assert Qemu.get(state, "../x") == {:error, :not_found}
    assert Qemu.list(state) == {:ok, []}
  end

  test "a QEMU that fails to start leaves nothing behind", %{tmp_dir: tmp} do
    {:ok, state} = Qemu.init(dir: tmp, qemu: "false")
    spec = %{name: "n1", script: "#!ipxe\n", firmware: :bios}

    assert {:error, {:qemu_failed, 1, _}} = Qemu.create(state, spec)
    assert Qemu.list(state) == {:ok, []}
  end
end
