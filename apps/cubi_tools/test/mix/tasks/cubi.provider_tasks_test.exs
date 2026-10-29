defmodule Mix.Tasks.Cubi.ProviderTasksTest do
  # mix cubi.provision, cubi.instances, cubi.upgrade, cubi.destroy and
  # cubi.deploy --provider, against Cubi.Provider.Fake and a stub ssh.
  use ExUnit.Case, async: false

  alias Cubi.Provider.Fake
  alias Mix.Tasks.Cubi.{Deploy, Destroy, Instances, Provision, Upgrade}

  @moduletag :tmp_dir

  setup_all do
    base =
      Path.join(System.tmp_dir!(), "cubi_provider_tasks_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base) end)
    Cubi.Pki.gen_ca!(base)
    %{pki: base}
  end

  setup %{tmp_dir: tmp} do
    Mix.shell(Mix.Shell.Process)

    # ssh: log the arguments, answer `:ok`, report $CUBI_STUB_UUID.
    ssh = Path.join(tmp, "ssh")

    File.write!(ssh, """
    #!/bin/sh
    echo "$@" >> "$(dirname "$0")/ssh.log"
    case "$*" in
      *nerves_fw_uuid*) echo "\\"$CUBI_STUB_UUID\\"" ;;
      *) echo ":ok" ;;
    esac
    """)

    File.chmod!(ssh, 0o755)

    for {key, value} <- [
          ssh: ssh,
          poll_ms: 10,
          ssh_retry_ms: 10,
          providers: [fake: {Fake, dir: Path.join(tmp, "fake")}]
        ],
        do: Application.put_env(:cubi_tools, key, value)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      for key <- [:ssh, :poll_ms, :ssh_retry_ms, :providers],
          do: Application.delete_env(:cubi_tools, key)

      System.delete_env("CUBI_STUB_UUID")
    end)

    for {version, uuid} <- [{"0.1.0", "uuid-one"}, {"0.2.0", "uuid-two"}] do
      dir = Path.join(tmp, version)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "base.json"), JSON.encode!(%{"firmware" => %{"uuid" => uuid}}))
      sum = String.duplicate(if(version == "0.1.0", do: "a1", else: "b2"), 32)
      File.write!(Path.join(dir, "SHA256SUMS"), "#{sum}  rootfs.squashfs\n")
    end

    key = Path.join(tmp, "id.pub")
    File.write!(key, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsab me\n")

    {:ok, state} = Fake.init(dir: Path.join(tmp, "fake"))
    %{state: state, key: key}
  end

  defp script_args(ctx, version) do
    ["--image", "http://images.local/cubi/#{version}", "--local", Path.join(ctx.tmp_dir, version)] ++
      ["--ca", ctx.pki, "--ssh", ctx.key]
  end

  defp infos() do
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:mix_shell, :info, [msg]} -> receive_all([msg | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "provision: creates with the rendered script, waits for ssh, prints where it is", ctx do
    Provision.run(["n1" | script_args(ctx, "0.1.0")])

    out = infos()
    assert out =~ "n1 is up at fake: 192.0.2.1, ssh port 22"
    assert out =~ "image: http://images.local/cubi/0.1.0"
    {:ok, hex} = Cubi.Pki.cert_sha256(File.read!(Cubi.Pki.paths(ctx.pki).ca_cert))
    assert out =~ "sha256:#{hex}"

    {:ok, script} = Fake.script(ctx.state, "n1")
    assert script =~ "cubi.rootfs=sha256:#{String.duplicate("a1", 32)}"
    assert script =~ "cubi.ssh=ssh-ed25519:"

    log = File.read!(Path.join(ctx.tmp_dir, "ssh.log"))
    assert log =~ "-p 22"
    assert log =~ "StrictHostKeyChecking=no"
    assert log =~ "192.0.2.1 :ok"
  end

  test "provision again fails before touching the instance", ctx do
    Provision.run(["n1" | script_args(ctx, "0.1.0")])
    {:ok, before} = Fake.get(ctx.state, "n1")

    assert_raise Mix.Error, ~r/n1 already exists at provider fake/, fn ->
      Provision.run(["n1" | script_args(ctx, "0.2.0")])
    end

    assert Fake.get(ctx.state, "n1") == {:ok, before}
  end

  test "provision refuses a bad firmware, and a missing name", ctx do
    assert_raise Mix.Error, ~r/bios or uefi/, fn ->
      Provision.run(["n1", "--firmware", "efi" | script_args(ctx, "0.1.0")])
    end

    assert_raise Mix.Error, ~r/usage/, fn -> Provision.run([]) end
    assert {:ok, []} = Fake.list(ctx.state)
  end

  test "instances: one line per instance, with the image's version", ctx do
    Instances.run([])
    assert infos() == "no instances"

    Provision.run(["n2" | script_args(ctx, "0.2.0")])
    Provision.run(["n1" | script_args(ctx, "0.1.0")])
    _ = infos()

    Instances.run(["--provider", "fake"])

    assert infos() == """
           PROVIDER  NAME  STATUS   ADDRESSES  IMAGE
           fake      n1    running  192.0.2.1  0.1.0
           fake      n2    running  192.0.2.1  0.2.0\
           """
  end

  test "upgrade: the new script, a reboot, then the new firmware UUID", ctx do
    Provision.run(["n1" | script_args(ctx, "0.1.0")])
    System.put_env("CUBI_STUB_UUID", "uuid-two")

    Upgrade.run(["n1" | script_args(ctx, "0.2.0")])

    assert infos() =~ "n1 runs firmware uuid-two"
    {:ok, script} = Fake.script(ctx.state, "n1")
    assert script =~ "set base http://images.local/cubi/0.2.0"
    assert script =~ String.duplicate("b2", 32)
    assert Fake.reboots(ctx.state, "n1") == {:ok, 1}
  end

  test "upgrade fails when the node never reports the new firmware", ctx do
    Provision.run(["n1" | script_args(ctx, "0.1.0")])
    System.put_env("CUBI_STUB_UUID", "uuid-one")

    assert_raise Mix.Error, ~r/never reported firmware uuid-two.*uuid-one/, fn ->
      Upgrade.run(["n1", "--timeout", "0" | script_args(ctx, "0.2.0")])
    end
  end

  test "upgrade needs --image and an existing instance", ctx do
    assert_raise Mix.Error, ~r/--image/, fn -> Upgrade.run(["n1"]) end

    assert_raise Mix.Error, ~r/no instance n9 at provider fake/, fn ->
      Upgrade.run(["n9" | script_args(ctx, "0.2.0")])
    end
  end

  test "destroy asks first, unless --yes", ctx do
    Provision.run(["n1" | script_args(ctx, "0.1.0")])

    send(self(), {:mix_shell_input, :yes?, false})
    Destroy.run(["n1"])
    assert {:ok, _} = Fake.get(ctx.state, "n1")

    Destroy.run(["n1", "--yes"])
    assert Fake.get(ctx.state, "n1") == {:error, :not_found}
    assert_raise Mix.Error, ~r/no instance n1/, fn -> Destroy.run(["n1", "--yes"]) end
  end

  test "deploy --provider: the instance's address and port, host keys not checked", ctx do
    Provision.run(["n1" | script_args(ctx, "0.1.0")])

    {host, opts} = Deploy.via_provider("n1", provider: "fake", identity: "/k/id")

    assert Deploy.ssh_args(host, opts) ==
             ~w(-p 22 -i /k/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -s 192.0.2.1 cubi_deploy)
  end

  test "the provider is required when several are configured", ctx do
    Application.put_env(:cubi_tools, :providers,
      a: {Fake, dir: Path.join(ctx.tmp_dir, "a")},
      b: {Fake, dir: Path.join(ctx.tmp_dir, "b")}
    )

    assert_raise Mix.Error, ~r/--provider is required: one of a, b/, fn -> Destroy.run(["n1"]) end
  end
end
