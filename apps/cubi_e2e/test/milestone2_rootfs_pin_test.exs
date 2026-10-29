defmodule Cubi.E2E.Milestone2RootfsPinTest do
  @moduledoc """
  docs/milestone2.md, stage-1's `cubi.rootfs=sha256:<hex>` (docs/specs.md
  §2.4, §2.12.2): a matching pin boots, a wrong pin or a changed rootfs stops
  the boot at stage-1 before BEAM, a malformed pin fails rather than skips,
  and no pin boots with a warning.

  Direct kernel boots of the production stage-1, so a failure reboots.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.Artifacts

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  setup_all do
    rootfs = Artifacts.rootfs!()
    hash = :crypto.hash(:sha256, File.read!(rootfs)) |> Base.encode16(case: :lower)
    {:ok, rootfs: rootfs, hash: hash}
  end

  defp boot!(context, name, rootfs, args) do
    start_vm!(context, %VM{
      name: name,
      memory: 512,
      boot:
        {:direct, Artifacts.kernel!(),
         [Artifacts.stage1!(:prod), {"/rootfs.squashfs", {:file, rootfs}, 0o644}],
         Artifacts.cmdline("console=ttyS0 " <> args)}
    })
  end

  # The failure is reported, the machine reboots into the same failure, and
  # BEAM never started in between.
  defp assert_stopped_at_stage1(vm, message) do
    Console.await(vm, ~r/cubi stage-1: #{Regex.escape(message)}/, 60_000)
    Console.await(vm, ~r/cubi stage-1: rebooting in 10 s/, 5_000)
    Console.await(vm, ~r/Linux version/, 30_000)

    console = Console.output(vm)
    refute console =~ "Interactive Elixir"
    refute console =~ "erlinit"
    refute console =~ "rootfs sha256 ok"
  end

  test "a matching pin boots to IEx", context do
    vm = boot!(context, "pin-ok", context.rootfs, "cubi.rootfs=sha256:#{context.hash}")

    Console.await(vm, ~r/cubi stage-1: rootfs sha256 ok/, 60_000)
    Console.await(vm, ~r/Interactive Elixir/, 60_000)
    refute Console.output(vm) =~ "not checked"
  end

  test "a pin that does not match the rootfs stops the boot at stage-1", context do
    other = :crypto.hash(:sha256, "another rootfs") |> Base.encode16(case: :lower)
    vm = boot!(context, "pin-wrong", context.rootfs, "cubi.rootfs=sha256:#{other}")
    assert_stopped_at_stage1(vm, "rootfs hash mismatch")
  end

  test "a one-byte change to the rootfs under a correct pin stops the boot at stage-1",
       context do
    changed = Path.join(context.dir, "rootfs.squashfs")
    data = File.read!(context.rootfs)
    last = byte_size(data) - 1
    File.write!(changed, [binary_part(data, 0, last), Bitwise.bxor(:binary.at(data, last), 1)])

    vm = boot!(context, "pin-changed", changed, "cubi.rootfs=sha256:#{context.hash}")
    assert_stopped_at_stage1(vm, "rootfs hash mismatch")
  end

  test "the last cubi.rootfs= wins", context do
    other = :crypto.hash(:sha256, "another rootfs") |> Base.encode16(case: :lower)

    vm =
      boot!(
        context,
        "pin-last",
        context.rootfs,
        "cubi.rootfs=sha256:#{context.hash} cubi.rootfs=sha256:#{other}"
      )

    assert_stopped_at_stage1(vm, "rootfs hash mismatch")
  end

  for {name, pin, message} <- [
        {"sha1", "sha1:0123456789abcdef0123456789abcdef01234567", "only sha256:<hex>"},
        {"upper", "sha256:" <> String.duplicate("AB", 32), "not lowercase hex"},
        {"short", "sha256:abcd", "not 64 hex digits"},
        {"empty", "", "only sha256:<hex>"}
      ] do
    test "a malformed pin (#{name}) fails rather than skips the check", context do
      vm = boot!(context, "pin-#{unquote(name)}", context.rootfs, "cubi.rootfs=#{unquote(pin)}")
      assert_stopped_at_stage1(vm, "bad cubi.rootfs=: #{unquote(message)}")
    end
  end

  test "no pin boots, with a warning on the console", context do
    vm = boot!(context, "pin-none", context.rootfs, "")

    Console.await(vm, ~r/cubi stage-1: warning: no cubi\.rootfs= on the cmdline/, 60_000)
    Console.await(vm, ~r/Interactive Elixir/, 60_000)
  end
end
