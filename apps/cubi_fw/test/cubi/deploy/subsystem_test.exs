defmodule Cubi.Deploy.SubsystemTest do
  # Streams an archive through a real ssh daemon on localhost.
  use ExUnit.Case, async: false

  import Cubi.DeployFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    pki = Path.join(tmp, "pki")
    Cubi.Pki.gen_ca!(pki)
    app = "fixssh#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup(app) end)

    deploy =
      start_supervised!(
        {Cubi.Deploy,
         name: nil,
         root: Path.join(tmp, "releases"),
         ca_cert: Cubi.Pki.paths(pki).ca_cert,
         settle: 300,
         node: %{otp_release: to_string(:erlang.system_info(:otp_release)), lib: %{}}}
      )

    host_keys = Path.join(tmp, "host")
    File.mkdir_p!(host_keys)
    key = Path.join(host_keys, "ssh_host_ed25519_key")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        system_dir: String.to_charlist(host_keys),
        user_passwords: [{~c"t", ~c"t"}],
        subsystems: [Cubi.Deploy.Subsystem.subsystem_spec(deploy: deploy, max_size: 1_000_000)]
      )

    on_exit(fn -> :ssh.stop_daemon(daemon) end)
    {:ok, info} = :ssh.daemon_info(daemon)

    %{port: info[:port], pki: pki, app: app, deploy: deploy}
  end

  # What `ssh -s <node> cubi_deploy < archive` does: the lines it prints and
  # its exit status.
  defp deploy(port, data) do
    {:ok, conn} =
      :ssh.connect(~c"127.0.0.1", port,
        user: ~c"t",
        password: ~c"t",
        silently_accept_hosts: true,
        save_accepted_host: false,
        user_interaction: false
      )

    {:ok, ch} = :ssh_connection.session_channel(conn, 5_000)
    :success = :ssh_connection.subsystem(conn, ch, ~c"cubi_deploy", 5_000)

    # The node may answer and close before everything is sent (too large).
    for <<chunk::binary-size(1000) <- data>>, do: :ssh_connection.send(conn, ch, chunk)
    rest = binary_part(data, div(byte_size(data), 1000) * 1000, rem(byte_size(data), 1000))
    :ssh_connection.send(conn, ch, rest)
    :ssh_connection.send_eof(conn, ch)

    result = collect(conn, ch, "", nil)
    :ssh.close(conn)
    result
  end

  defp collect(conn, ch, out, status) do
    receive do
      {:ssh_cm, ^conn, {:data, ^ch, 0, data}} -> collect(conn, ch, out <> data, status)
      {:ssh_cm, ^conn, {:exit_status, ^ch, s}} -> collect(conn, ch, out, s)
      {:ssh_cm, ^conn, {:eof, ^ch}} -> collect(conn, ch, out, status)
      {:ssh_cm, ^conn, {:closed, ^ch}} -> {String.split(out, "\n", trim: true), status}
    after
      15_000 -> flunk("no answer; so far: #{inspect(out)}")
    end
  end

  test "a signed archive is installed: progress lines, then ok, exit status 0", ctx do
    {lines, status} = deploy(ctx.port, archive("hello", ctx.app, "0.1.0", :ok, ctx.pki))

    assert status == 0
    assert List.last(lines) == "ok hello 0.1.0"
    assert "cubi_deploy: verifying" in lines
    assert "cubi_deploy: settling 0 s" in lines
    assert Cubi.Deploy.state(ctx.deploy).current == "0.1.0"
    assert File.ls!(Cubi.Deploy.incoming_dir(ctx.deploy)) == []
  end

  test "an unsigned archive is refused: error line, exit status 1", ctx do
    {lines, status} =
      deploy(ctx.port, archive("hello", ctx.app, "0.1.0", :ok, ctx.pki, sign: false))

    assert status == 1
    assert List.last(lines) == "error :unsigned"
    assert Cubi.Deploy.state(ctx.deploy).current == nil
  end

  test "more than max_size is refused before anything is installed", ctx do
    {lines, status} = deploy(ctx.port, :crypto.strong_rand_bytes(1_500_000))

    assert status == 1
    assert List.last(lines) == "error {:too_large, 1000000}"
  end
end
