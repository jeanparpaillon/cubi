defmodule Cubi.E2E.Stage1Test do
  @moduledoc """
  Stage-1's own behaviour (docs/specs.md §2.4, docs/cluster.md §2.2; docs/security.md §5):
  the token is carried into `/root`, erlinit starts with a clean environment
  whatever the cmdline says, and a failure reboots a production image but
  drops a dev image to a shell.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.Artifacts

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  defp rootfs(), do: {"/rootfs.squashfs", {:file, Artifacts.rootfs!()}, 0o644}

  test "the token lands in /root/.cubi, 0400, and cmdline env and init= don't reach erlinit",
       context do
    vm =
      start_vm!(context, %VM{
        name: "token",
        memory: 512,
        boot:
          {:direct, Artifacts.kernel!(),
           [Artifacts.stage1!(), rootfs(), {"/cubi/token", "kbxn_test.0123:s3cret\n", 0o400}],
           Artifacts.cmdline("console=ttyS0 init=/bin/sh KBX_INJECTED=1 ERL_AFLAGS=-kbx_injected")}
      })

    Console.await(vm, ~r/Interactive Elixir/, 60_000)

    assert Node.eval(vm, ~S"""
           %{mode: mode, uid: uid} = File.stat!("/root/.cubi/token")
           {File.read!("/root/.cubi/token"), Bitwise.band(mode, 0o7777), uid,
            Bitwise.band(File.stat!("/root/.cubi").mode, 0o7777)}
           """) == {"kbxn_test.0123:s3cret\n", 0o400, 0, 0o700}

    assert Node.eval(vm, ~S"""
           {System.get_env("KBX_INJECTED"), System.get_env("ERL_AFLAGS"),
            :init.get_argument(:kbx_injected)}
           """) == {nil, nil, :error}

    root_mount =
      Node.eval(vm, ~S"""
      File.read!("/proc/mounts")
      |> String.split("\n")
      |> Enum.find(&match?([_, "/root" | _], String.split(&1)))
      """)

    assert [_, "/root", "tmpfs", opts | _] = String.split(root_mount)
    assert ~w(nosuid nodev mode=700) -- String.split(opts, ",") == []

    refute Console.output(vm) =~ "s3cret"
  end

  test "prod: a missing rootfs is reported, then the machine reboots, with no shell", context do
    vm =
      start_vm!(context, %VM{
        name: "fail-prod",
        memory: 512,
        boot:
          {:direct, Artifacts.kernel!(), [Artifacts.stage1!(:prod)],
           Artifacts.cmdline("console=ttyS0")}
      })

    Console.await(vm, ~r/cubi stage-1: no \/rootfs.squashfs in the initramfs/, 60_000)
    Console.await(vm, ~r/cubi stage-1: rebooting in 10 s/, 5_000)
    Console.await(vm, ~r/Linux version/, 30_000)
    refute Console.output(vm) =~ "dropping to a shell"
  end

  test "dev: a missing rootfs drops to a shell", context do
    vm =
      start_vm!(context, %VM{
        name: "fail-dev",
        memory: 512,
        boot:
          {:direct, Artifacts.kernel!(), [Artifacts.stage1!(:dev)],
           Artifacts.cmdline("console=ttyS0")}
      })

    Console.await(vm, ~r/cubi stage-1: dev build, dropping to a shell/, 60_000)
    Console.send_input(vm, "echo kbx$((6 * 7))\n")
    Console.await(vm, ~r/kbx42/, 5_000)
  end
end
