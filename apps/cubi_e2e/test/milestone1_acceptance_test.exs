defmodule Cubi.E2E.Milestone1AcceptanceTest do
  @moduledoc """
  docs/milestone1.md, acceptance: deploying the `hello` fixture with
  `mix cubi.deploy` to QEMU nodes (docs/specs.md §2.11.4–§2.11.7).

  The other acceptance points are covered elsewhere: `mix cubi.gen_ca` by
  `apps/cubi_tools/test/mix/tasks/cubi.gen_ca_test.exs`, the images'
  signatures by `phase3_firmware_ipxe_test.exs`, iPXE by
  `milestone1_imgverify_test.exs`.

  `hello` 0.1.0 and 0.2.0 run; 0.3.0 crashes in `start/2`; 0.4.0 dies 5 s
  after starting, within the node's 10 s settle period.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Artifacts, Hello}

  @moduletag e2e: :tier1
  @moduletag timeout: 900_000

  @key String.duplicate("0123456789abcdef", 4)

  setup_all do
    served = Artifacts.served_dir!()
    other = Path.join(System.tmp_dir!(), "cubi_m1_other_#{System.unique_integer([:positive])}")
    Cubi.Pki.gen_ca!(other, name: "other")
    on_exit(fn -> File.rm_rf!(other) end)

    v1 = Hello.build!("0.1.0", :ok, served)
    v2 = Hello.build!("0.2.0", :ok, served)
    v3 = Hello.build!("0.3.0", :crash_on_start, served)
    v4 = Hello.build!("0.4.0", :crash_later, served)

    refused = %{
      unsigned: Hello.tamper!(v2, &Map.drop(&1, ["manifest.sig", "signer.pem"]), false),
      other_ca: Hello.build!("0.2.0", :ok, served, signer: other),
      changed:
        Hello.tamper!(
          v2,
          fn entries ->
            [beam | _] = entries |> Map.keys() |> Enum.filter(&String.ends_with?(&1, ".beam"))
            Map.update!(entries, beam, &(&1 <> "x"))
          end,
          false
        ),
      other_otp:
        Hello.tamper!(
          v2,
          &Hello.edit_manifest(&1, fn m -> %{m | "otp_release" => "28"} end),
          true
        ),
      base_app_conflict:
        Hello.tamper!(
          v2,
          &Hello.edit_manifest(&1, fn m ->
            %{
              m
              | "applications" => m["applications"] ++ [%{"name" => "logger", "vsn" => "0.0.1"}]
            }
          end),
          true
        )
    }

    archives = [v1, v2, v3, v4 | Map.values(refused)]
    on_exit(fn -> Enum.each(archives, &File.rm/1) end)

    {:ok, served: served, v1: v1, v2: v2, v3: v3, v4: v4, refused: refused}
  end

  defp version(vm) do
    Node.eval(vm, "if Code.ensure_loaded?(Hello), do: Hello.version()")
  end

  # The pids of processes the image started: a restart would change them.
  defp base_pids(vm) do
    Node.eval(vm, ~S"""
    for name <- [CubiFw.Supervisor, NervesSSH, Cubi.Deploy, Cubi.Storage, Shoehorn.ReportHandler],
        into: %{},
        do: {name, Process.whereis(name)}
    """)
  end

  test "diskless: deploy, refusals, replace, roll back, and nothing left after a reboot",
       context do
    spec = %VM{name: "m1-diskless", memory: 1024, boot: {:pxe, :tftp, context.served}}
    vm = start_vm!(context, spec)
    Console.await(vm, ~r/Interactive Elixir/, 90_000)
    assert version(vm) == nil

    # v1 runs, without Erlang distribution.
    assert {out, 0} = Hello.deploy(vm, context.v1)
    assert out =~ "ok hello 0.1.0"
    assert version(vm) == "0.1.0"
    refute Node.eval(vm, ":erlang.is_alive()")

    # Each refusal leaves v1 running.
    for {kind, expected} <- [
          unsigned: ~r/not signed: run `mix cubi.sign` first/,
          other_ca: ~r/error \{:bad_signer_chain/,
          changed: ~r/error \{:hash_mismatch/,
          other_otp: ~r/error \{:otp_release, "28"/,
          base_app_conflict: ~r/error \{:conflicts, \[\{"logger", "0.0.1"/
        ] do
      {out, status} = Hello.deploy(vm, context.refused[kind])
      assert status != 0, "#{kind} was accepted:\n#{out}"
      assert out =~ expected, "#{kind}:\n#{out}"
      assert version(vm) == "0.1.0", "#{kind} changed what runs"
    end

    # v2 replaces v1: one version of hello loaded, from one code path.
    assert {out, 0} = Hello.deploy(vm, context.v2)
    assert out =~ "ok hello 0.2.0"
    assert version(vm) == "0.2.0"

    assert Node.eval(vm, ~S"""
           {Enum.count(Application.loaded_applications(), &(elem(&1, 0) == :hello)),
            Enum.count(:code.get_path(), &(to_string(&1) =~ "/hello-")),
            :code.which(Hello) |> to_string() =~ "/hello-0.2.0/"}
           """) == {1, 1, true}

    base = base_pids(vm)

    # v3 crashes on start: back to v2 right away, the deploy fails, and v3 is bad.
    {elapsed, {out, status}} = :timer.tc(fn -> Hello.deploy(vm, context.v3) end, :millisecond)
    assert status != 0
    assert out =~ "rolling back"
    assert version(vm) == "0.2.0"
    assert elapsed < 10_000 + 5_000, "the rollback took #{elapsed} ms"

    assert {out, status} = Hello.deploy(vm, context.v3)
    assert status != 0
    assert out =~ ~s(error {:bad_version, "0.3.0"})

    # v4 dies after it started, within the settle period: rolled back the same way.
    assert {out, status} = Hello.deploy(vm, context.v4)
    assert status != 0
    assert out =~ "error {:failed, :exited_while_settling}"
    assert version(vm) == "0.2.0"

    # The image's own processes never restarted.
    assert base_pids(vm) == base

    assert Node.eval(vm, "Cubi.Deploy.state()") == %{
             current: "0.2.0",
             previous: "0.1.0",
             bad: ["0.3.0", "0.4.0"]
           }

    # Diskless: a reboot drops every deployed release.
    vm = restart_vm!(context, spec)
    Console.await(vm, ~r/Interactive Elixir/, 90_000)
    assert version(vm) == nil
    assert Node.eval(vm, "Cubi.Deploy.state()") == %{current: nil, previous: nil, bad: []}
  end

  test "storage node: the deployed release runs again after a reboot", context do
    disks = [{:virtio, "KBXD0", :blank}, {:nvme, "KBXN0", :blank}]
    args = "cubi.vdevs=mirror,virtio-KBXD0,nvme-QEMU_NVMe_Ctrl_KBXN0 cubi.zfs.testkey=#{@key}"

    spec = fn extra ->
      %VM{
        name: "m1-storage",
        memory: 1024,
        disks: disks,
        boot:
          {:direct, Artifacts.kernel!(),
           [Artifacts.stage1!(), {"/rootfs.squashfs", {:file, Artifacts.rootfs!()}, 0o644}],
           Artifacts.cmdline("console=ttyS0 #{args} #{extra}")}
      }
    end

    vm = start_vm!(context, spec.("cubi.zfs.create=1"))
    Console.await(vm, ~r/cubi: storage: pool cubi created/, 120_000)

    assert {_, 0} = Hello.deploy(vm, context.v1)
    assert {_, 0} = Hello.deploy(vm, context.v2)
    assert version(vm) == "0.2.0"

    vm = restart_vm!(context, spec.(""))
    Console.await(vm, ~r/cubi: storage: pool cubi imported/, 120_000)

    # Cubi.Deploy starts the release after the pool, in handle_continue: a
    # call to it waits for that.
    assert Node.eval(vm, "{Cubi.Deploy.state(), File.ls!(\"/cubi/releases\") |> Enum.sort()}") ==
             {%{current: "0.2.0", previous: "0.1.0", bad: []},
              ~w(0.1.0 0.2.0 incoming state.json)}

    assert version(vm) == "0.2.0"
  end
end
