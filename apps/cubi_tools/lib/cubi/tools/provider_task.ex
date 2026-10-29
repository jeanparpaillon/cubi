defmodule Cubi.Tools.ProviderTask do
  @moduledoc false
  # What `mix cubi.provision`, `cubi.instances`, `cubi.upgrade`,
  # `cubi.destroy` and `cubi.deploy --provider` share (docs/specs.md
  # §2.12.4): choosing the provider, finding an instance, reaching it.

  alias Cubi.Provider.Instance
  alias Cubi.Tools.Ssh

  @doc "The switches for reaching an instance over ssh, as `mix cubi.deploy` takes them."
  def ssh_switches(), do: [user: :string, identity: :string, ssh_option: :keep, timeout: :integer]

  @doc """
  `{name, module, state}` for `--provider`, or for the only provider
  configured when it is not given.
  """
  def provider!(nil) do
    case Cubi.Provider.configured() do
      [{name, _}] ->
        provider!(name)

      [] ->
        Mix.raise("no provider configured: config :cubi_tools, :providers")

      many ->
        Mix.raise("--provider is required: one of #{Enum.map_join(many, ", ", &elem(&1, 0))}")
    end
  end

  def provider!(name) do
    case Cubi.Provider.init(name) do
      {:ok, {module, state}} -> {to_string(name), module, state}
      {:error, {:missing_env, var}} -> Mix.raise("provider #{name}: #{var} is not set")
      {:error, reason} -> Mix.raise("provider #{name}: #{inspect(reason)}")
    end
  end

  @doc "The instance `name`, or a Mix error."
  def instance!({provider, module, state}, name) do
    case module.get(state, name) do
      {:ok, instance} -> instance
      {:error, :not_found} -> Mix.raise("no instance #{name} at provider #{provider}")
      {:error, reason} -> Mix.raise("provider #{provider}: #{inspect(reason)}")
    end
  end

  @doc "Where to ssh: its first address, on its `ssh_port` if the provider forwards one."
  def target(%Instance{addresses: [host | _], provider: provider}),
    do: %{host: host, port: Map.get(provider, :ssh_port, 22)}

  def target(%Instance{name: name}), do: Mix.raise("instance #{name} has no address yet")

  @doc "The ssh options of a task's `opts`, with the provider defaults first."
  def ssh_opts(opts),
    do: Ssh.provider_options() ++ Keyword.take(opts, [:user, :identity, :ssh_option])

  @doc """
  Waits until the instance is `:running`, then until it answers ssh. Returns
  the instance as it is then. `--timeout` in seconds, default 600.
  """
  def wait_up!({provider, module, state}, name, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 600) * 1000

    instance = wait_running!({provider, module, state}, name, deadline)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Ssh.wait(target(instance), ssh_opts(opts), remaining) do
      :ok ->
        instance

      {:error, last} ->
        Mix.raise("#{name} is running but never answered ssh: #{last}")
    end
  end

  defp wait_running!(provider, name, deadline) do
    case instance!(provider, name) do
      %Instance{status: :running, addresses: [_ | _]} = instance ->
        instance

      %Instance{status: status} ->
        if System.monotonic_time(:millisecond) > deadline,
          do: Mix.raise("#{name} still #{status}, giving up"),
          else: Process.sleep(Application.get_env(:cubi_tools, :poll_ms, 5_000))

        wait_running!(provider, name, deadline)
    end
  end
end
