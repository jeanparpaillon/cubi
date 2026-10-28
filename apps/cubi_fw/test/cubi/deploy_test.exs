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
end
