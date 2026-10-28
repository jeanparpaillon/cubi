defmodule Mix.Tasks.Cubi.DeployTest do
  use ExUnit.Case, async: false

  alias Cubi.Pki.Archive
  alias Mix.Tasks.Cubi.Deploy

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "ssh arguments: port, user, identity and options, then the subsystem" do
    assert Deploy.ssh_args("node1",
             port: 2222,
             user: "cubi",
             identity: "/k/id",
             ssh_option: "StrictHostKeyChecking=no",
             ssh_option: "UserKnownHostsFile=/dev/null"
           ) ==
             ~w(-p 2222 -l cubi -i /k/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -s node1 cubi_deploy)

    assert Deploy.ssh_args("node1", []) == ~w(-s node1 cubi_deploy)
  end

  test "an unsigned archive is refused before anything is sent", %{tmp_dir: tmp} do
    archive = Path.join(tmp, "a.tar.gz")
    Archive.write!(archive, %{"manifest.json" => ~s({"files": {}})})

    assert_raise Mix.Error, ~r/not signed: run `mix cubi.sign` first/, fn ->
      Deploy.run(["nowhere.invalid", archive])
    end
  end

  test "a missing archive or node fails", %{tmp_dir: tmp} do
    assert_raise Mix.Error, ~r/usage/, fn -> Deploy.run([]) end
    assert_raise Mix.Error, ~r/no .*nope/, fn -> Deploy.run(["n", Path.join(tmp, "nope")]) end
  end

  test "the lines collectable prints and keeps every line, partial ones included" do
    acc =
      Enum.into(
        ["cubi_deploy: verif", "ying\ncubi_deploy: st", "arting\nok hello 0.1.0"],
        %Cubi.Tools.Lines{}
      )

    assert Cubi.Tools.Lines.lines(acc) ==
             ["cubi_deploy: verifying", "cubi_deploy: starting", "ok hello 0.1.0"]

    assert_received {:mix_shell, :info, ["cubi_deploy: verifying"]}
    assert_received {:mix_shell, :info, ["ok hello 0.1.0"]}
  end
end
