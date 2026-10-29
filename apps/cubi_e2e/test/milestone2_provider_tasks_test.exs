defmodule Cubi.E2E.Milestone2ProviderTasksTest do
  @moduledoc """
  docs/milestone2.md, acceptance for the provider tasks, run with
  `Cubi.Provider.Qemu` from the `hello` fixture as an operator would:
  provision, deploy, provision again, list, upgrade, destroy.

  Two public images are served over HTTP: the public directory, and a copy
  with another firmware UUID to upgrade to (`Cubi.E2E.PublicImage`).
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Artifacts, Hello, HttpServer, Key, PublicImage}

  @moduletag e2e: :tier1
  @moduletag timeout: 900_000

  @fixture Path.expand("../fixtures/hello", __DIR__)

  setup context do
    v1 = Artifacts.public_dir!()
    v2 = Path.join(context.dir, "public-v2")
    uuid2 = PublicImage.variant!(v1, v2)

    servers =
      for {name, dir} <- [v1: v1, v2: v2], into: %{} do
        {:ok, pid, port} = HttpServer.start_link(dir, Path.join(context.dir, "#{name}-http.log"))
        # Linked to the test process, so possibly stopping already.
        on_exit(fn ->
          try do
            ThousandIsland.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end)

        {name, "http://10.0.2.2:#{port}"}
      end

    qemu = Path.join(context.dir, "qemu")

    on_exit(fn ->
      {:ok, state} = Cubi.Provider.Qemu.init(dir: qemu)
      {:ok, left} = Cubi.Provider.Qemu.list(state)
      for i <- left, do: Cubi.Provider.Qemu.destroy(state, i)
    end)

    %{v1: v1, v2: v2, uuid2: uuid2, urls: servers, qemu: qemu}
  end

  defp mix(context, args) do
    System.cmd("mix", args,
      cd: @fixture,
      env: [{"MIX_ENV", "prod"}, {"CUBI_E2E_QEMU_DIR", context.qemu}],
      stderr_to_stdout: true
    )
  end

  defp ssh_args(),
    do: ["--user", "cubi-e2e", "--identity", Path.join(Key.dir(), "id_ed25519")]

  defp script_args(context, version) do
    ["--image", context.urls[version], "--local", context[version]] ++
      ["--ca", Key.pki_dir(), "--ssh", Key.public_key_path()] ++ ssh_args()
  end

  defp qemu(context) do
    {:ok, state} = Cubi.Provider.Qemu.init(dir: context.qemu)
    state
  end

  test "provision, deploy, list, upgrade and destroy n1", context do
    # provision returns once n1 answers ssh.
    {out, status} =
      mix(context, ["cubi.provision", "n1", "--provider", "qemu" | script_args(context, :v1)])

    assert status == 0, out
    assert out =~ "n1 is up at qemu"

    {:ok, n1} = Cubi.Provider.Qemu.get(qemu(context), "n1")
    port = n1.provider.ssh_port

    # deploy by name.
    archive = Hello.build!("0.1.0", :ok, context.v1)

    {out, status} =
      mix(context, ["cubi.deploy", "n1", archive, "--provider", "qemu" | ssh_args()])

    assert status == 0, out
    assert out =~ "ok hello 0.1.0"
    assert Node.eval(port, "if Code.ensure_loaded?(Hello), do: Hello.version()") == "0.1.0"

    # provisioning n1 again fails and leaves it running.
    {out, status} =
      mix(context, ["cubi.provision", "n1", "--provider", "qemu" | script_args(context, :v1)])

    assert status != 0
    assert out =~ "n1 already exists"
    assert {:ok, %{status: :running, id: id}} = Cubi.Provider.Qemu.get(qemu(context), "n1")
    assert id == n1.id
    assert Node.eval(port, "Hello.version()") == "0.1.0"

    # listed.
    {out, 0} = mix(context, ["cubi.instances"])
    assert out =~ ~r/qemu\s+n1\s+running\s+127\.0\.0\.1/

    # upgraded onto v2: its firmware UUID, and the base image alone.
    {out, status} =
      mix(context, ["cubi.upgrade", "n1", "--provider", "qemu" | script_args(context, :v2)])

    assert status == 0, out
    assert out =~ "n1 runs firmware #{context.uuid2}"
    assert Node.eval(port, ~s|Nerves.Runtime.KV.get_active("nerves_fw_uuid")|) == context.uuid2
    refute Node.eval(port, "Code.ensure_loaded?(Hello)")

    # destroyed: nothing listed, no QEMU left.
    pid = File.read!(Path.join(n1.provider.dir, "qemu.pid")) |> String.trim()
    {out, 0} = mix(context, ["cubi.destroy", "n1", "--yes"])
    assert out =~ "n1 destroyed"
    {out, 0} = mix(context, ["cubi.instances"])
    assert out =~ "no instances"
    refute File.exists?("/proc/#{pid}")
  end
end
