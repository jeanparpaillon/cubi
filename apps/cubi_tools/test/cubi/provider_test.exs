defmodule Cubi.ProviderTest do
  use ExUnit.Case, async: false

  alias Cubi.Provider

  @moduletag :tmp_dir

  setup do
    previous = Application.fetch_env(:cubi_tools, :providers)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:cubi_tools, :providers, value)
        :error -> Application.delete_env(:cubi_tools, :providers)
      end
    end)
  end

  defp configure(providers), do: Application.put_env(:cubi_tools, :providers, providers)

  test "a provider is found by atom or by string name", %{tmp_dir: tmp} do
    configure(fake: {Cubi.Provider.Fake, dir: tmp})

    assert Provider.config(:fake) == {:ok, {Cubi.Provider.Fake, dir: tmp}}
    assert Provider.config("fake") == {:ok, {Cubi.Provider.Fake, dir: tmp}}
    assert {:ok, {Cubi.Provider.Fake, %{dir: ^tmp}}} = Provider.init("fake")
  end

  test "an unknown name lists the configured ones, a malformed entry is reported" do
    configure(fake: {Cubi.Provider.Fake, []}, bad: Cubi.Provider.Fake)

    assert Provider.config("nope") == {:error, {:unknown_provider, "nope", [:fake, :bad]}}
    assert Provider.config(:bad) == {:error, {:bad_provider_config, :bad, Cubi.Provider.Fake}}
    assert Provider.init("nope") == {:error, {:unknown_provider, "nope", [:fake, :bad]}}
  end

  test "no providers configured" do
    Application.delete_env(:cubi_tools, :providers)
    assert Provider.config(:qemu) == {:error, {:unknown_provider, :qemu, []}}
  end

  test "{:env, var} options are read from the environment, others kept in order" do
    var = "CUBI_PROVIDER_TEST_#{System.unique_integer([:positive])}"
    System.put_env(var, "secret")
    on_exit(fn -> System.delete_env(var) end)

    assert Provider.resolve_env(region: "cdg", api_key: {:env, var}, size: nil) ==
             {:ok, region: "cdg", api_key: "secret", size: nil}
  end

  test "an unset or empty variable is an error naming it, before init/1 is called" do
    var = "CUBI_PROVIDER_TEST_#{System.unique_integer([:positive])}"
    assert Provider.resolve_env(api_key: {:env, var}) == {:error, {:missing_env, var}}

    System.put_env(var, "")
    on_exit(fn -> System.delete_env(var) end)
    assert Provider.resolve_env(api_key: {:env, var}) == {:error, {:missing_env, var}}

    configure(fake: {Cubi.Provider.Fake, dir: {:env, var}})
    assert Provider.init(:fake) == {:error, {:missing_env, var}}
  end

  test "init/1 passes on the module's own error" do
    configure(fake: {Cubi.Provider.Fake, []})
    assert Provider.init(:fake) == {:error, {:missing_option, :dir}}
  end
end
