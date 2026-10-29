defmodule Cubi.E2E.Milestone2BootScriptTest do
  @moduledoc """
  docs/milestone2.md, `Cubi.Tools.BootScript` end to end: the public
  directory served over HTTP, a script rendered for it with the test CA and
  the harness key, booted by a `Cubi.Provider.Qemu` instance. The node checks
  the rootfs against the script's pin, lets the harness in, and runs a
  `hello` signed under the pinned root.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Artifacts, Hello, HttpServer, Key}
  alias Cubi.Provider.Qemu

  @moduletag e2e: :tier1
  @moduletag timeout: 600_000

  setup context do
    public = Artifacts.public_dir!()
    {:ok, http, port} = HttpServer.start_link(public, Path.join(context.dir, "http.log"))
    on_exit(fn -> if Process.alive?(http), do: ThousandIsland.stop(http) end)

    {:ok, state} = Qemu.init(dir: Path.join(context.dir, "qemu"))

    on_exit(fn ->
      {:ok, instances} = Qemu.list(state)
      for i <- instances, do: :ok = Qemu.destroy(state, i)
    end)

    %{public: public, state: state, base: "http://10.0.2.2:#{port}"}
  end

  test "a rendered script boots the public image as the operator's node", context do
    {:ok, script} =
      Cubi.Tools.BootScript.render(
        image: context.base,
        local: context.public,
        ca: File.read!(Cubi.Pki.paths(Key.pki_dir()).ca_cert),
        ssh_keys: [File.read!(Key.public_key_path())]
      )

    {:ok, instance} = Qemu.create(context.state, %{name: "bs1", script: script, firmware: :bios})
    port = instance.provider.ssh_port

    assert Node.eval(port, "Nerves.Runtime.firmware_validation_status()") == :validated

    console = File.read!(instance.provider.console)
    assert console =~ "cubi stage-1: rootfs sha256 ok"
    refute console =~ "not checked"

    v1 = Hello.build!("0.1.0", :ok, context.public)
    {out, status} = Hello.deploy(port, v1)
    assert status == 0, out
    assert Node.eval(port, "if Code.ensure_loaded?(Hello), do: Hello.version()") == "0.1.0"
  end
end
