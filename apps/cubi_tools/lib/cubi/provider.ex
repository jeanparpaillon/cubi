defmodule Cubi.Provider do
  @moduledoc """
  The IaaS behind cloud instances (docs/specs.md §2.12.3): one module per
  provider, each implementing this behaviour.

  **The provider is the inventory.** Instances are named and tagged `cubi`, and
  `c:list/1` returns only those; there is no local state. Names are unique per
  provider: `c:create/2` on a taken name is an error. **The script goes in as
  content**, never as a URL, and whatever the provider stores alongside it is
  removed by `c:destroy/2`. Every module runs the shared conformance suite,
  `Cubi.Provider.Case` (in `test/support`).

  Providers are configured by name in the operator's project, credentials
  from the environment and never from the config itself:

      config :cubi_tools, :providers,
        qemu: {Cubi.Provider.Qemu, []},
        vultr: {Cubi.Provider.Vultr, api_key: {:env, "VULTR_API_KEY"}, region: "cdg"}

  `init/1` resolves a name to `{module, state}`, replacing each top-level
  `{:env, var}` option by that variable's value.
  """

  alias Cubi.Provider.Instance

  @type state :: term()
  @type t :: {module(), state()}

  @typedoc """
  What to create. `size` and `region` are the provider's own strings, passed
  through; `nil` leaves them to the provider's configured default.
  """
  @type spec :: %{
          required(:name) => String.t(),
          required(:script) => String.t(),
          required(:firmware) => :bios | :uefi,
          optional(:size) => String.t() | nil,
          optional(:region) => String.t() | nil
        }

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback create(state(), spec()) :: {:ok, Instance.t()} | {:error, term()}
  @callback list(state()) :: {:ok, [Instance.t()]} | {:error, term()}
  @callback get(state(), name :: String.t()) ::
              {:ok, Instance.t()} | {:error, :not_found | term()}
  @callback set_script(state(), Instance.t(), script :: String.t()) :: :ok | {:error, term()}
  @callback reboot(state(), Instance.t()) :: :ok | {:error, term()}
  @callback destroy(state(), Instance.t()) :: :ok | {:error, term()}

  @doc """
  The configured providers, `[{name, {module, opts}}]`, options unresolved.
  """
  @spec configured() :: [{atom(), {module(), keyword()}}]
  def configured(), do: Application.get_env(:cubi_tools, :providers, [])

  @doc """
  `{module, opts}` for a configured provider, by name. A string name (from a
  task's `--provider`) is matched against the configured ones, never turned
  into an atom.
  """
  @spec config(atom() | String.t()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def config(name) do
    found =
      Enum.find(configured(), fn {key, _} -> key == name or Atom.to_string(key) == name end)

    case found do
      {_, {module, opts}} when is_atom(module) and is_list(opts) -> {:ok, {module, opts}}
      {_, other} -> {:error, {:bad_provider_config, name, other}}
      nil -> {:error, {:unknown_provider, name, Keyword.keys(configured())}}
    end
  end

  @doc """
  Looks up a provider by name, resolves its options and calls its `c:init/1`.
  """
  @spec init(atom() | String.t()) :: {:ok, t()} | {:error, term()}
  def init(name) do
    with {:ok, {module, opts}} <- config(name),
         {:ok, opts} <- resolve_env(opts),
         {:ok, state} <- module.init(opts) do
      {:ok, {module, state}}
    end
  end

  @doc """
  Replaces each top-level `{:env, var}` value by the variable's value. An
  unset or empty variable is an error naming it, so a missing API key fails
  before any request.
  """
  @spec resolve_env(keyword()) :: {:ok, keyword()} | {:error, {:missing_env, String.t()}}
  def resolve_env(opts) do
    Enum.reduce_while(opts, {:ok, []}, fn
      {key, {:env, var}}, {:ok, acc} ->
        case System.get_env(var) do
          value when value in [nil, ""] -> {:halt, {:error, {:missing_env, var}}}
          value -> {:cont, {:ok, [{key, value} | acc]}}
        end

      pair, {:ok, acc} ->
        {:cont, {:ok, [pair | acc]}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
