defmodule Cubi.E2E.Milestone2QemuProviderTest do
  @moduledoc """
  docs/milestone2.md, `Cubi.Provider.Qemu`: the e2e image, served over HTTP
  like a public directory, boots to IEx in a provider instance under BIOS and
  UEFI, from a script that names it by absolute URL as a cloud script would.
  The instance outlives nothing of the test but its files: it is a background
  QEMU, destroyed at the end.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Artifacts, HttpServer}
  alias Cubi.Provider.Qemu

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  setup context do
    {:ok, http, port} =
      HttpServer.start_link(Artifacts.served_dir!(), Path.join(context.dir, "http.log"))

    on_exit(fn -> if Process.alive?(http), do: ThousandIsland.stop(http) end)

    {:ok, state} =
      Qemu.init(dir: Path.join(context.dir, "qemu"), ipxe_efi: Cubi.E2E.Ipxe.efi!())

    on_exit(fn ->
      {:ok, instances} = Qemu.list(state)
      for i <- instances, do: :ok = Qemu.destroy(state, i)
    end)

    %{state: state, base: "http://10.0.2.2:#{port}"}
  end

  for firmware <- [:bios, :uefi] do
    test "#{firmware}: an instance boots the served image from its script", context do
      script = """
      #!ipxe
      set base #{context.base}
      kernel ${base}/vmlinuz console=ttyS0
      initrd ${base}/stage1.cpio.zst
      initrd ${base}/rootfs.squashfs /rootfs.squashfs
      boot
      """

      name = "m2-#{unquote(firmware)}"

      {:ok, instance} =
        Qemu.create(context.state, %{name: name, script: script, firmware: unquote(firmware)})

      assert instance.status == :running

      assert Node.eval(instance.provider.ssh_port, "Nerves.Runtime.firmware_validation_status()") ==
               :validated

      assert {:ok, [%{name: ^name}]} = Qemu.list(context.state)
      console = File.read!(instance.provider.console)
      assert console =~ "Interactive Elixir"
      if unquote(firmware) == :uefi, do: assert(console =~ "autoexec.ipxe")

      assert File.read!(Path.join(context.dir, "http.log")) =~ "GET /rootfs.squashfs 200"
    end
  end
end
