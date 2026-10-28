defmodule Cubi.E2E.Milestone1DeployNodeTest do
  @moduledoc """
  docs/milestone1.md, the node side of a deploy (docs/specs.md §2.11.5,
  §2.11.6): `examples/cubi_hello`, built against the e2e image and signed by
  the test CA, sent through the `cubi_deploy` ssh subsystem of a diskless
  node, runs there; an unsigned one is refused. Killed after it settled, it is
  rolled back through shoehorn and `Cubi.Deploy.ShoehornHandler` (§2.11.7).
  `mix cubi.deploy` and the fixtures that crash are later steps.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.Artifacts
  alias Cubi.Pki.Archive

  @moduletag e2e: :tier1
  @moduletag timeout: 600_000

  @hello Path.expand("../../../examples/cubi_hello", __DIR__)

  setup_all do
    served = Artifacts.served_dir!()

    {out, status} =
      System.cmd("mix", ["do", "deps.get,", "cubi.release", "--base", served],
        cd: @hello,
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("mix cubi.release failed in #{@hello}:\n#{out}")

    unsigned = File.read!(Path.join(@hello, "_build/prod/cubi/cubi_hello-0.1.0.tar.gz"))
    {:ok, entries} = Archive.read(unsigned)
    {:ok, signed} = Archive.sign(entries, Cubi.Pki.load_signer!(Cubi.E2E.Key.pki_dir()))

    path =
      Path.join(System.tmp_dir!(), "cubi_hello_e2e_#{System.unique_integer([:positive])}.tar.gz")

    Archive.write!(path, signed)
    on_exit(fn -> File.rm(path) end)

    {:ok, served: served, signed: File.read!(path), unsigned: unsigned}
  end

  test "a signed release is installed on a diskless node and runs; an unsigned one is refused",
       context do
    vm =
      start_vm!(context, %VM{
        name: "m1-deploy",
        memory: 1024,
        boot: {:pxe, :tftp, context.served}
      })

    Console.await(vm, ~r/Interactive Elixir/, 90_000)

    assert {lines, 1} = Node.subsystem(vm, "cubi_deploy", context.unsigned)
    assert List.last(lines) == "error :unsigned"

    assert {lines, 0} = Node.subsystem(vm, "cubi_deploy", context.signed)
    assert List.last(lines) == "ok cubi_hello 0.1.0"
    assert "cubi_deploy: settling 10 s" in lines

    assert Node.eval(vm, "CubiHello.page()") == "Welcome to Cubi\nVersion: 0.1.0\n"

    assert Node.eval(vm, ~S"""
           {Cubi.Deploy.state(),
            File.ls!("/cubi/releases") |> Enum.sort(),
            "/proc/mounts" |> File.read!() |> String.contains?("tmpfs /cubi tmpfs")}
           """) ==
             {%{current: "0.1.0", previous: nil, bad: []}, ~w(0.1.0 incoming state.json), true}

    # Dies after its settle period: shoehorn hears of it, and with no previous
    # release, nothing runs any more.
    assert Node.eval(vm, ~S"""
           {:ok, sup} = :application.get_supervisor(:cubi_hello)
           Process.exit(sup, :kill)

           Enum.find_value(1..50, fn _ ->
             Process.sleep(100)
             state = Cubi.Deploy.state()
             if state.current == nil, do: state
           end)
           """) == %{current: nil, previous: nil, bad: ["0.1.0"]}

    assert Node.eval(vm, ~S"""
           {Application.started_applications() |> List.keymember?(:cubi_hello, 0),
            Code.ensure_loaded?(CubiHello), File.ls!("/cubi/releases") |> Enum.sort()}
           """) == {false, false, ~w(incoming state.json)}

    # The image itself carries on.
    assert Node.eval(vm, "Application.started_applications() |> List.keymember?(:cubi_fw, 0)")
  end
end
