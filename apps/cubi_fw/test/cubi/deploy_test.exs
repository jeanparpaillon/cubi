defmodule Cubi.DeployTest do
  # Loads and starts applications in this BEAM: not async.
  use ExUnit.Case, async: false

  import Cubi.DeployFixtures

  @moduletag :tmp_dir

  setup_all do
    base = Path.join(System.tmp_dir!(), "cubi_deploy_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    for name <- ~w(pki other), do: Cubi.Pki.gen_ca!(Path.join(base, name))
    %{pki: Path.join(base, "pki"), other: Path.join(base, "other")}
  end

  setup %{tmp_dir: tmp, pki: pki, test: test} do
    app = "fix#{:erlang.phash2(test)}"
    on_exit(fn -> cleanup(app) end)

    root = Path.join(tmp, "releases")

    deploy =
      start_supervised!(
        {Cubi.Deploy,
         name: nil,
         root: root,
         ca_cert: Cubi.Pki.paths(pki).ca_cert,
         cmdline: "/nonexistent/cmdline",
         settle: 600,
         node: %{otp_release: to_string(:erlang.system_info(:otp_release)), lib: %{}}}
      )

    %{deploy: deploy, root: root, app: app}
  end

  defp install(ctx, vsn, behaviour \\ :ok, opts \\ []) do
    pki = Keyword.get(opts, :pki, ctx.pki)
    name = Keyword.get(opts, :name, "hello")
    data = archive(name, ctx.app, vsn, behaviour, pki, opts)
    test = self()
    Cubi.Deploy.install(ctx.deploy, data, &send(test, {:progress, &1}))
  end

  defp running_vsn(app) do
    if List.keymember?(Application.started_applications(), String.to_atom(app), 0),
      do: module(app).version()
  end

  test "installs a release: verified, started, recorded", ctx do
    assert install(ctx, "0.1.0") == {:ok, %{name: "hello", version: "0.1.0"}}

    assert running_vsn(ctx.app) == "0.1.0"
    assert Application.get_env(String.to_atom(ctx.app), :greeting) == "0.1.0"
    assert Cubi.Deploy.state(ctx.deploy) == %{current: "0.1.0", previous: nil, bad: []}

    for step <- ["verifying", "unpacking hello 0.1.0", "starting 0.1.0", "settling 0 s"],
        do: assert_received({:progress, ^step})
  end

  test "a new version replaces the old one, which becomes previous; older ones are pruned", ctx do
    {:ok, _} = install(ctx, "0.1.0")
    {:ok, _} = install(ctx, "0.2.0")

    assert running_vsn(ctx.app) == "0.2.0"
    assert Cubi.Deploy.state(ctx.deploy) == %{current: "0.2.0", previous: "0.1.0", bad: []}
    assert_received {:progress, "stopping 0.1.0"}

    {:ok, _} = install(ctx, "0.3.0")
    assert Enum.sort(File.ls!(ctx.root)) == ~w(0.2.0 0.3.0 incoming state.json)
  end

  test "a version that fails to start is rolled back and marked bad", ctx do
    {:ok, _} = install(ctx, "0.1.0")

    assert {:error, {:failed, {:start, _, _}}} = install(ctx, "0.2.0", :crash_on_start)

    assert running_vsn(ctx.app) == "0.1.0"
    assert Cubi.Deploy.state(ctx.deploy) == %{current: "0.1.0", previous: nil, bad: ["0.2.0"]}
    refute File.exists?(Path.join(ctx.root, "0.2.0"))
    assert_received {:progress, "restarting 0.1.0"}

    assert install(ctx, "0.2.0") == {:error, {:bad_version, "0.2.0"}}
  end

  test "a version that dies while settling is rolled back too", ctx do
    {:ok, _} = install(ctx, "0.1.0")

    assert install(ctx, "0.2.0", :crash_later) == {:error, {:failed, :exited_while_settling}}
    assert running_vsn(ctx.app) == "0.1.0"
  end

  test "a first release that fails leaves nothing running", ctx do
    assert {:error, {:failed, _}} = install(ctx, "0.1.0", :crash_on_start)
    assert running_vsn(ctx.app) == nil
    assert Cubi.Deploy.state(ctx.deploy) == %{current: nil, previous: nil, bad: ["0.1.0"]}
  end

  test "refusals change nothing", ctx do
    {:ok, _} = install(ctx, "0.1.0")

    assert install(ctx, "0.2.0", :ok, sign: false) == {:error, :unsigned}
    assert {:error, {:bad_signer_chain, _}} = install(ctx, "0.2.0", :ok, pki: ctx.other)

    assert install(ctx, "0.2.0", :ok, otp_release: "1") ==
             {:error, {:otp_release, "1", to_string(:erlang.system_info(:otp_release))}}

    assert install(ctx, "0.2.0", :ok, name: "other") ==
             {:error, {:another_release, "other", "hello"}}

    assert install(ctx, "0.1.0") == {:error, {:already_current, "0.1.0"}}
    assert Cubi.Deploy.install(ctx.deploy, "not an archive") |> elem(0) == :error

    assert running_vsn(ctx.app) == "0.1.0"
    assert Cubi.Deploy.state(ctx.deploy) == %{current: "0.1.0", previous: nil, bad: []}
  end

  describe "at start" do
    defp restart(ctx) do
      :ok = stop_supervised(Cubi.Deploy)
      cleanup(ctx.app)
      refute running_vsn(ctx.app)

      deploy =
        start_supervised!(
          {Cubi.Deploy,
           name: nil,
           root: ctx.root,
           ca_cert: Cubi.Pki.paths(ctx.pki).ca_cert,
           cmdline: "/nonexistent/cmdline",
           settle: 600,
           node: %{otp_release: to_string(:erlang.system_info(:otp_release)), lib: %{}}}
        )

      # Booting happens in handle_continue: a call waits for it.
      _ = Cubi.Deploy.state(deploy)
      deploy
    end

    test "the current release is started again, verified from disk", ctx do
      {:ok, _} = install(ctx, "0.1.0")
      {:ok, _} = install(ctx, "0.2.0")

      deploy = restart(ctx)

      assert running_vsn(ctx.app) == "0.2.0"
      assert Cubi.Deploy.state(deploy) == %{current: "0.2.0", previous: "0.1.0", bad: []}
    end

    test "a current release changed on disk falls back to the previous one", ctx do
      {:ok, _} = install(ctx, "0.1.0")
      {:ok, _} = install(ctx, "0.2.0")
      File.write!(Path.join([ctx.root, "0.2.0", "releases/0.2.0/sys.config"]), "tampered")

      deploy = restart(ctx)

      assert running_vsn(ctx.app) == "0.1.0"
      assert Cubi.Deploy.state(deploy) == %{current: "0.1.0", previous: nil, bad: ["0.2.0"]}
    end

    test "nothing recorded, nothing started", ctx do
      deploy = restart(ctx)
      assert Cubi.Deploy.state(deploy) == %{current: nil, previous: nil, bad: []}
    end
  end

  describe "trusted root (docs/specs.md §2.11.4 step 1)" do
    import ExUnit.CaptureLog

    # A node whose image has no CA (`/etc/cubi/ca.pem` absent) unless
    # `image_ca` names one, booted with `cmdline`.
    defp pinned_deploy(ctx, cmdline, image_ca \\ nil) do
      path = Path.join(ctx.tmp_dir, "cmdline")
      File.write!(path, cmdline <> "\n")
      ca_cert = if image_ca, do: Cubi.Pki.paths(image_ca).ca_cert, else: "/nonexistent/ca.pem"

      start_supervised!(
        {Cubi.Deploy,
         name: nil,
         root: Path.join(ctx.tmp_dir, "pinned"),
         ca_cert: ca_cert,
         cmdline: path,
         settle: 600,
         node: %{otp_release: to_string(:erlang.system_info(:otp_release)), lib: %{}}},
        id: :pinned
      )
    end

    defp pin(dir) do
      {:ok, hex} =
        dir |> Cubi.Pki.paths() |> Map.fetch!(:ca_cert) |> File.read!() |> Cubi.Pki.cert_sha256()

      "cubi.ca=sha256:" <> hex
    end

    defp install_on(deploy, ctx, vsn, opts) do
      data = archive("hello", ctx.app, vsn, :ok, Keyword.get(opts, :pki, ctx.pki), opts)
      Cubi.Deploy.install(deploy, data)
    end

    test "no image CA: the archive's own ca.pem, pinned by cubi.ca=, at deploy and at boot",
         ctx do
      deploy = pinned_deploy(ctx, "console=ttyS0 " <> pin(ctx.pki))

      assert install_on(deploy, ctx, "0.1.0", ca: ctx.pki) ==
               {:ok, %{name: "hello", version: "0.1.0"}}

      assert running_vsn(ctx.app) == "0.1.0"

      # A storage node at its next boot: verified again from disk, ca.pem kept.
      :ok = stop_supervised(:pinned)
      cleanup(ctx.app)
      deploy = pinned_deploy(ctx, pin(ctx.pki))
      assert Cubi.Deploy.state(deploy).current == "0.1.0"
      assert running_vsn(ctx.app) == "0.1.0"
    end

    test "no image CA: archives without the pinned root are refused", ctx do
      deploy = pinned_deploy(ctx, pin(ctx.pki))

      assert install_on(deploy, ctx, "0.1.0", []) == {:error, :no_archive_ca}

      # Correctly signed under its own ca.pem, which is not the pinned one.
      assert {:error, {:archive_ca_not_pinned, _}} =
               install_on(deploy, ctx, "0.1.0", pki: ctx.other, ca: ctx.other)

      # The pinned root, but a signer from another one.
      assert {:error, {:bad_signer_chain, _}} =
               install_on(deploy, ctx, "0.1.0", pki: ctx.other, ca: ctx.pki)

      refute running_vsn(ctx.app)
      assert Cubi.Deploy.state(deploy) == %{current: nil, previous: nil, bad: []}
    end

    test "an image CA pinned to another root refuses every release, and says so at boot",
         ctx do
      {deploy, log} =
        with_log(fn ->
          deploy = pinned_deploy(ctx, pin(ctx.other), ctx.pki)
          _ = Cubi.Deploy.state(deploy)
          deploy
        end)

      assert log =~ "every release will be refused"
      assert log =~ "ca_pin_mismatch"

      assert {:error, {:ca_pin_mismatch, _}} = install_on(deploy, ctx, "0.1.0", ca: ctx.pki)

      assert {:error, {:ca_pin_mismatch, _}} =
               install_on(deploy, ctx, "0.1.0", pki: ctx.other, ca: ctx.other)
    end

    test "neither an image CA nor a pin: every release is refused", ctx do
      {deploy, log} =
        with_log(fn ->
          deploy = pinned_deploy(ctx, "console=ttyS0")
          _ = Cubi.Deploy.state(deploy)
          deploy
        end)

      assert log =~ "no cubi.ca= pin, every release will be refused"
      assert install_on(deploy, ctx, "0.1.0", ca: ctx.pki) == {:error, :no_trusted_ca}
    end
  end

  describe "after the settle period" do
    # What shoehorn would cast: the release's application dies for real.
    defp crash(ctx) do
      app = String.to_atom(ctx.app)
      {:ok, sup} = :application.get_supervisor(app)
      ref = Process.monitor(sup)
      Process.exit(sup, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      wait_until(fn -> not List.keymember?(Application.started_applications(), app, 0) end)
      GenServer.cast(ctx.deploy, {:exited, app, :killed})
      # A call after the cast: it has been handled.
      Cubi.Deploy.state(ctx.deploy)
    end

    defp wait_until(fun, tries \\ 50) do
      cond do
        fun.() ->
          :ok

        tries == 0 ->
          flunk("condition never met")

        true ->
          Process.sleep(20)
          wait_until(fun, tries - 1)
      end
    end

    test "a release that dies is rolled back to the previous one, marked bad", ctx do
      {:ok, _} = install(ctx, "0.1.0")
      {:ok, _} = install(ctx, "0.2.0")

      assert crash(ctx) == %{current: "0.1.0", previous: nil, bad: ["0.2.0"]}
      assert running_vsn(ctx.app) == "0.1.0"
      assert Enum.sort(File.ls!(ctx.root)) == ~w(0.1.0 incoming state.json)
      assert install(ctx, "0.2.0") == {:error, {:bad_version, "0.2.0"}}
    end

    test "with no previous release, nothing runs", ctx do
      {:ok, _} = install(ctx, "0.1.0")

      assert crash(ctx) == %{current: nil, previous: nil, bad: ["0.1.0"]}
      assert running_vsn(ctx.app) == nil

      # A new version can still be deployed.
      assert {:ok, _} = install(ctx, "0.3.0")
    end

    test "a previous release that fails to start again is marked bad too", ctx do
      {:ok, _} = install(ctx, "0.1.0")
      {:ok, _} = install(ctx, "0.2.0")
      File.write!(Path.join([ctx.root, "0.1.0", "releases/0.1.0/sys.config"]), "tampered")

      assert crash(ctx) == %{current: nil, previous: nil, bad: ["0.2.0", "0.1.0"]}
      assert running_vsn(ctx.app) == nil
    end

    test "an exit of an application that runs again, or of another one, is ignored", ctx do
      {:ok, _} = install(ctx, "0.1.0")

      GenServer.cast(ctx.deploy, {:exited, String.to_atom(ctx.app), :killed})
      GenServer.cast(ctx.deploy, {:exited, :logger, :killed})

      assert Cubi.Deploy.state(ctx.deploy) == %{current: "0.1.0", previous: nil, bad: []}
      assert running_vsn(ctx.app) == "0.1.0"
    end
  end
end
