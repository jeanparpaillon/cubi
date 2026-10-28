defmodule Kubex.Tools.ReleaseTest do
  use ExUnit.Case, async: true

  alias Kubex.Tools.Release

  @base %{
    "otp_release" => "29",
    "erts_version" => "17.0.2",
    "applications" => %{
      "kernel" => "11.0.2",
      "stdlib" => "8.0.1",
      "crypto" => "5.9",
      "elixir" => "1.20.2",
      "logger" => "1.20.2"
    }
  }

  @otp MapSet.new(~w(kernel stdlib crypto xmerl))

  defp app(name, vsn), do: %{name: name, vsn: vsn}

  describe "plan/3" do
    test "OTP's applications are never shipped nor pinned, whatever their host version" do
      assert {:ok, %{ship: [], requires: requires}} =
               Release.plan([app("kernel", "11.0.3"), app("crypto", "5.9.1")], @base, @otp)

      assert requires == %{}
    end

    test "the image's other applications at the same version are required, not shipped" do
      assert {:ok, %{ship: [], requires: %{"elixir" => "1.20.2", "logger" => "1.20.2"}}} =
               Release.plan([app("elixir", "1.20.2"), app("logger", "1.20.2")], @base, @otp)
    end

    test "what the image lacks is shipped, sorted" do
      apps = [app("plug", "1.20.3"), app("bandit", "1.14.1"), app("eex", "1.20.2")]

      assert {:ok, %{ship: ship}} = Release.plan(apps, @base, @otp)
      assert Enum.map(ship, & &1.name) == ~w(bandit eex plug)
    end

    test "every conflict and missing OTP application is reported at once" do
      apps = [app("elixir", "1.20.1"), app("xmerl", "2.1"), app("bandit", "1.14.1")]

      assert {:error, errors} = Release.plan(apps, @base, @otp)

      assert errors == [
               "elixir 1.20.1 conflicts with 1.20.2 in the image",
               "xmerl is part of OTP and the image does not have it: add it to the firmware"
             ]
    end
  end

  test "check_otp/2 wants the image's OTP major" do
    assert Release.check_otp(@base, "29") == :ok
    assert {:error, "the image runs OTP 29, this host 28" <> _} = Release.check_otp(@base, "28")
  end

  test "split_config/2 keeps the shipped applications' configuration only" do
    sys = [kubex_hello: [port: 8080], logger: [level: :debug], bandit: [x: 1]]

    assert Release.split_config(sys, ["kubex_hello", "bandit"]) ==
             {[kubex_hello: [port: 8080], bandit: [x: 1]], [:logger]}
  end

  test "host_otp_apps/0 knows kernel and ssl, and not elixir" do
    apps = Release.host_otp_apps()
    assert "kernel" in apps and "ssl" in apps
    refute "elixir" in apps
  end

  describe "pack/2" do
    @describetag :tmp_dir

    test "writes the manifest and the shipped files, hashed", %{tmp_dir: tmp} do
      rel = Path.join(tmp, "rel")
      File.mkdir_p!(Path.join(rel, "releases/0.1.0"))

      File.write!(Path.join(rel, "releases/0.1.0/hello.rel"), """
      {release,{"hello","0.1.0"},{erts,"17.0.3"},
       [{kernel,"11.0.3",permanent},{elixir,"1.20.2",permanent},
        {hello,"0.1.0",permanent},{iex,"1.20.2",none}]}.
      """)

      File.write!(
        Path.join(rel, "releases/0.1.0/sys.config"),
        "[{hello,[{port,8080}]},{logger,[{level,debug}]}].\n"
      )

      for {path, data} <- [
            {"lib/hello-0.1.0/ebin/hello.app", "app"},
            {"lib/hello-0.1.0/priv/static/index.html", "<p>"},
            {"lib/hello-0.1.0/src/hello.erl", "not shipped"},
            {"lib/iex-1.20.2/ebin/iex.app", "iex"}
          ] do
        File.mkdir_p!(Path.dirname(Path.join(rel, path)))
        File.write!(Path.join(rel, path), data)
      end

      output = Path.join(tmp, "out/hello-0.1.0.tar.gz")

      assert {:ok, %{plan: plan, dropped_config: [:logger]}} =
               Release.pack(rel,
                 base: @base,
                 name: "hello",
                 version: "0.1.0",
                 start: ["hello"],
                 otp_apps: @otp,
                 output: output
               )

      assert Enum.map(plan.ship, & &1.name) == ~w(hello iex)

      {:ok, entries} = :erl_tar.extract(String.to_charlist(output), [:compressed, :memory])
      entries = Map.new(entries, fn {name, data} -> {to_string(name), data} end)

      assert Map.keys(entries) |> Enum.sort() == [
               "lib/hello-0.1.0/ebin/hello.app",
               "lib/hello-0.1.0/priv/static/index.html",
               "lib/iex-1.20.2/ebin/iex.app",
               "manifest.json",
               "releases/0.1.0/sys.config"
             ]

      manifest = JSON.decode!(entries["manifest.json"])

      assert manifest["format"] == 1
      assert manifest["otp_release"] == "29"
      assert manifest["erts_version"] == "17.0.2"
      assert manifest["start"] == ["hello"]
      assert manifest["requires"] == %{"elixir" => "1.20.2"}

      assert manifest["applications"] == [
               %{"name" => "hello", "vsn" => "0.1.0"},
               %{"name" => "iex", "vsn" => "1.20.2"}
             ]

      for {path, data} <- entries, path != "manifest.json" do
        assert manifest["files"][path] == Base.encode16(:crypto.hash(:sha256, data), case: :lower)
      end

      sys_config = Path.join(tmp, "sys.config")
      File.write!(sys_config, entries["releases/0.1.0/sys.config"])
      assert :file.consult(String.to_charlist(sys_config)) == {:ok, [[hello: [port: 8080]]]}
    end
  end
end
