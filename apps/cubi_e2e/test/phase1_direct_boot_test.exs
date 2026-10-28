defmodule Cubi.E2E.Phase1DirectBootTest do
  @moduledoc """
  docs/phase1.md, acceptance: `Nerves.Runtime.firmware_valid?/0` is true, and
  `/` is read-only.

  Boots the kernel directly, without iPXE: stage-1 from `stage1/`, then the
  e2e rootfs as a named initrd, as iPXE would hand it over (`Cubi.E2E.Artifacts`).
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.Artifacts

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  for firmware <- [:bios, :uefi] do
    test "#{firmware}: boots to IEx, firmware is valid, / is read-only", context do
      vm =
        start_vm!(context, %VM{
          name: "p1-#{unquote(firmware)}",
          firmware: unquote(firmware),
          memory: 512,
          boot:
            {:direct, Artifacts.kernel!(),
             [Artifacts.stage1!(), {"/rootfs.squashfs", {:file, Artifacts.rootfs!()}, 0o644}],
             Artifacts.cmdline("console=ttyS0")}
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
