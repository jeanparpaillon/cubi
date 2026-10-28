defmodule Cubi.Provider.Case do
  @moduledoc """
  The conformance suite every `Cubi.Provider` module runs (docs/specs.md
  §2.12.3):

      defmodule Cubi.Provider.VultrTest do
        use Cubi.Provider.Case, provider: Cubi.Provider.Vultr

        setup do
          # stub the API, then:
          %{provider_opts: [api_key: "test", region: "cdg"]}
        end
      end

  The provider is initialised in each test, from the context, so the module's
  own `setup` runs first. Context keys, all optional:

    * `:provider_opts` - passed to `c:Cubi.Provider.init/1`, default `[]`
    * `:provider_spec` - merged into every `create/2` spec: `size`, `region`,
      `firmware` (default `:bios`), `script`

  Instances are named `conformance-<n>`, and those a test leaves behind are
  destroyed in `on_exit`, which fails the test if that does not work: a
  leftover instance on a real account costs money.
  """

  alias Cubi.Provider.Instance

  @script """
  #!ipxe
  echo cubi conformance
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    case_opts = Keyword.take(opts, [:async])

    quote do
      use ExUnit.Case, unquote(case_opts)

      import Cubi.Provider.Case, only: [start!: 1, spec: 2]

      @moduletag cubi_provider: unquote(provider)

      describe "Cubi.Provider conformance:" do
        test "create/2 returns the instance, which list/1 and get/2 then report", context do
          {mod, state} = start!(context)
          spec = spec(context, "a")

          assert {:ok, %Instance{} = created} = mod.create(state, spec)
          assert created.name == spec.name
          assert is_binary(created.id) and created.id != ""
          assert created.status in [:pending, :running]
          assert Enum.all?(created.addresses, &is_binary/1)

          assert {:ok, %Instance{id: id, name: name}} = mod.get(state, spec.name)
          assert {id, name} == {created.id, created.name}

          assert {:ok, listed} = mod.list(state)
          assert [%Instance{id: ^id}] = Enum.filter(listed, &(&1.name == spec.name))
        end

        test "create/2 on a taken name is an error and leaves the first instance", context do
          {mod, state} = start!(context)
          spec = spec(context, "a")

          assert {:ok, %Instance{id: id}} = mod.create(state, spec)
          assert {:error, _} = mod.create(state, %{spec | script: spec.script <> "# again\n"})

          assert {:ok, listed} = mod.list(state)
          assert [%Instance{id: ^id}] = Enum.filter(listed, &(&1.name == spec.name))
        end

        test "get/2 of an unknown name is :not_found", context do
          {mod, state} = start!(context)
          assert mod.get(state, spec(context, "never").name) == {:error, :not_found}
        end

        test "set_script/3 and reboot/2 keep the instance", context do
          {mod, state} = start!(context)
          spec = spec(context, "a")

          assert {:ok, %Instance{id: id} = instance} = mod.create(state, spec)
          assert :ok = mod.set_script(state, instance, spec.script <> "# v2\n")
          assert {:ok, %Instance{id: ^id} = instance} = mod.get(state, spec.name)
          assert :ok = mod.reboot(state, instance)
          assert {:ok, %Instance{id: ^id}} = mod.get(state, spec.name)
        end

        test "destroy/2 removes it from list/1 and get/2, and leaves the others", context do
          {mod, state} = start!(context)
          a = spec(context, "a")
          b = spec(context, "b")

          assert {:ok, instance} = mod.create(state, a)
          assert {:ok, %Instance{id: kept}} = mod.create(state, b)
          assert :ok = mod.destroy(state, instance)

          assert mod.get(state, a.name) == {:error, :not_found}
          assert {:ok, listed} = mod.list(state)
          refute Enum.any?(listed, &(&1.name == a.name))
          assert [%Instance{id: ^kept}] = Enum.filter(listed, &(&1.name == b.name))
        end
      end
    end
  end

  @doc """
  Initialises the context's provider, and registers the cleanup of every
  instance this test created.
  """
  @spec start!(map()) :: Cubi.Provider.t()
  def start!(context) do
    mod = Map.fetch!(context, :cubi_provider)
    {:ok, state} = mod.init(Map.get(context, :provider_opts, []))
    prefix = prefix(context)

    ExUnit.Callbacks.on_exit(fn ->
      {:ok, listed} = mod.list(state)

      for %Instance{name: name} = instance <- listed, String.starts_with?(name, prefix) do
        :ok = mod.destroy(state, instance)
      end
    end)

    {mod, state}
  end

  @doc "A spec for this test's instance `suffix`."
  @spec spec(map(), String.t()) :: Cubi.Provider.spec()
  def spec(context, suffix) do
    Map.merge(
      %{
        name: prefix(context) <> suffix,
        script: @script,
        firmware: :bios,
        size: nil,
        region: nil
      },
      Map.get(context, :provider_spec, %{})
    )
  end

  # One prefix per test, so a test's cleanup never touches another's
  # instances, even with async tests against the same account.
  defp prefix(context) do
    key = {__MODULE__, context.module, context.test}

    case Process.get(key) do
      nil ->
        prefix = "conformance-#{System.unique_integer([:positive])}-"
        Process.put(key, prefix)
        prefix

      prefix ->
        prefix
    end
  end
end
