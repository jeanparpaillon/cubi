defmodule Cubi.E2E.Milestone2TwoOperatorsTest do
  @moduledoc """
  docs/milestone2.md, acceptance: one public directory boots two QEMU
  instances, with scripts for operator A's CA and key and for operator B's.
  Each accepts `hello` signed under its own CA and refuses it signed under
  the other's, still running its previous release; each lets in its own
  operator's key only. The two operators are `Cubi.E2E.Key.operator/1`'s.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Artifacts, Hello, HttpServer, Key}
  alias Cubi.Provider.Qemu

  @moduletag e2e: :tier1
  @moduletag timeout: 900_000

  setup context do
    Key.ensure_operators!()
    public = Artifacts.public_dir!()

    {:ok, http, port} = HttpServer.start_link(public, Path.join(context.dir, "http.log"))

    on_exit(fn ->
      try do
        ThousandIsland.stop(http)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, state} = Qemu.init(dir: Path.join(context.dir, "qemu"))

    on_exit(fn ->
      {:ok, left} = Qemu.list(state)
      for i <- left, do: Qemu.destroy(state, i)
    end)

    nodes =
      for name <- [:a, :b], into: %{} do
        op = Key.operator(name)

        {:ok, script} =
          Cubi.Tools.BootScript.render(
            image: "http://10.0.2.2:#{port}",
            local: public,
            ca: File.read!(Cubi.Pki.paths(op.pki).ca_cert),
            ssh_keys: [File.read!(op.ssh_pub)]
          )

        {:ok, instance} =
          Qemu.create(state, %{name: "op-#{name}", script: script, firmware: :bios})

        {name, %{port: instance.provider.ssh_port, op: op}}
      end

    %{public: public, nodes: nodes}
  end

  defp eval(node, code), do: Node.eval(node.port, code, 300_000, key_dir: node.op.ssh_dir)
  defp deploy(node, archive), do: Hello.deploy(node.port, archive, key_dir: node.op.ssh_dir)

  test "each node runs its own operator's releases only, and lets in its own key only",
       context do
    build = fn version, name ->
      Hello.build!(version, :ok, context.public, signer: Key.operator(name).pki)
    end

    for {own, other} <- [a: :b, b: :a] do
      node = context.nodes[own]
      assert eval(node, ":ok") == :ok

      {out, status} = deploy(node, build.("0.1.0", own))
      assert status == 0, out
      assert out =~ "ok hello 0.1.0"

      # Correctly signed, under the other operator's CA, which carries it.
      {out, status} = deploy(node, build.("0.2.0", other))
      assert status != 0
      assert out =~ "archive_ca_not_pinned"

      assert eval(node, "{Hello.version(), Cubi.Deploy.state()}") ==
               {"0.1.0", %{current: "0.1.0", previous: nil, bad: []}}

      assert Node.login(node.port, Key.operator(own).ssh_dir) == :ok
      assert {:error, _} = Node.login(node.port, Key.operator(other).ssh_dir)
      assert {:error, _} = Node.login(node.port, Key.dir())
    end
  end
end
