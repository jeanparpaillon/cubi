defmodule Kubex.E2E.Phase4NetbootTest do
  @moduledoc """
  docs/phase4.md, acceptance: a cold QEMU VM with no disk boots to IEx, for
  both BIOS and UEFI.

  Over user-mode TFTP and over HTTP, from the directory `mix firmware.ipxe`
  writes. Each case also checks that the node runs the served firmware, and
  which way the files came.
  """
  use Kubex.E2E.Case

  alias Kubex.E2E.Artifacts

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  @images ~w(boot.ipxe vmlinuz stage1.cpio.zst rootfs.squashfs)

  setup_all do
    served = Artifacts.served_dir!()

    {kv, 0} =
      System.cmd("unsquashfs", ["-cat", Path.join(served, "rootfs.squashfs"), "etc/firmware.kv"])

    [_, uuid] = Regex.run(~r/^a\.nerves_fw_uuid=(.*)$/m, kv)
    {:ok, served: served, fw_uuid: uuid}
  end

  for firmware <- [:bios, :uefi], protocol <- [:tftp, :http] do
    test "#{firmware} over #{protocol}: no disk, boots the served firmware to IEx", context do
      vm =
        start_vm!(context, %VM{
          name: "p4-#{unquote(firmware)}-#{unquote(protocol)}",
          firmware: unquote(firmware),
          memory: 1024,
          boot: {:pxe, unquote(protocol), context.served}
        })

      Console.await(vm, ~r/rootfs\.squashfs\.\.\. ok/, 60_000)
      Console.await(vm, ~r/Interactive Elixir/, 60_000)

      assert Node.eval(vm, ~S"""
             {Nerves.Runtime.firmware_validation_status(),
              Nerves.Runtime.KV.get_active("nerves_fw_uuid")}
             """) == {:validated, context.fw_uuid}

      console = Console.output(vm)

      http_log =
        Path.join([context.dir, "p4-#{unquote(firmware)}-#{unquote(protocol)}", "http.log"])

      case unquote(protocol) do
        :http ->
          assert File.read!(http_log) == Enum.map_join(@images, &"GET /#{&1} 200\n")

        :tftp ->
          refute File.exists?(http_log)
      end

      # UEFI runs the kernel through its EFI stub; BIOS through the legacy boot protocol.
      if unquote(firmware) == :uefi do
        assert console =~ "autoexec.ipxe... ok"
        assert console =~ ~r/efi: EFI v\d/
      else
        refute console =~ ~r/efi: EFI v\d/
      end
    end
  end
end
