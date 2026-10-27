defmodule Kubex.E2E.Phase1DirectBootTest do
  @moduledoc """
  docs/phase1.md, acceptance: `Nerves.Runtime.firmware_valid?/0` is true, and
  `/` is read-only.

  Boots `KUBEX_E2E_KERNEL` with `KUBEX_E2E_INITRD` (stage-1 and the e2e
  rootfs, concatenated) directly, without iPXE.
  """
  use Kubex.E2E.Case

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  setup do
    kernel = System.get_env("KUBEX_E2E_KERNEL")
    initrd = System.get_env("KUBEX_E2E_INITRD")

    if is_nil(kernel) or is_nil(initrd),
      do: flunk("set KUBEX_E2E_KERNEL and KUBEX_E2E_INITRD to the phase 1 artifacts")

    {:ok, kernel: Path.expand(kernel), initrd: Path.expand(initrd)}
  end

  for firmware <- [:bios, :uefi] do
    test "#{firmware}: boots to IEx, firmware is valid, / is read-only", context do
      vm =
        start_vm!(context, %VM{
          name: "p1-#{unquote(firmware)}",
          firmware: unquote(firmware),
          memory: 512,
          boot: {:direct, context.kernel, [context.initrd], "console=ttyS0"}
        })

      Console.await(vm, ~r/Run \/init as init process/, 60_000)
      Console.await(vm, ~r/Interactive Elixir/, 60_000)

      assert Node.eval(vm, "Nerves.Runtime.firmware_valid?()") == true

      assert Node.eval(vm, ~S"""
             File.read!("/proc/mounts")
             |> String.split("\n")
             |> Enum.find_value(fn line ->
               case String.split(line) do
                 [_dev, "/", _type, opts | _] -> String.split(opts, ",")
                 _ -> nil
               end
             end)
             """)
             |> Enum.member?("ro")
    end
  end
end
