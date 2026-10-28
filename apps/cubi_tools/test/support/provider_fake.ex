defmodule Cubi.Provider.Fake do
  @moduledoc """
  A `Cubi.Provider` that only keeps records, one file per instance under
  `:dir`: the reference the conformance suite is checked against, and a
  provider for task tests. Files rather than a process, so the state outlives
  the test process and `on_exit` can still clean up.

  Each record keeps the current script and the number of reboots, read back
  with `script/2` and `reboots/2`.
  """

  @behaviour Cubi.Provider

  alias Cubi.Provider.Instance

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :dir) do
      {:ok, dir} ->
        File.mkdir_p!(dir)
        {:ok, %{dir: dir}}

      :error ->
        {:error, {:missing_option, :dir}}
    end
  end

  @impl true
  def create(state, spec) do
    path = path(state, spec.name)

    if File.exists?(path) do
      {:error, {:name_taken, spec.name}}
    else
      instance = %Instance{
        id: Integer.to_string(System.unique_integer([:positive])),
        name: spec.name,
        status: :running,
        addresses: ["192.0.2.1"],
        provider: %{script: spec.script, firmware: spec.firmware, reboots: 0}
      }

      write!(path, instance)
      {:ok, instance}
    end
  end

  @impl true
  def list(state) do
    {:ok,
     state.dir |> Path.join("*.term") |> Path.wildcard() |> Enum.sort() |> Enum.map(&read!/1)}
  end

  @impl true
  def get(state, name) do
    path = path(state, name)
    if File.exists?(path), do: {:ok, read!(path)}, else: {:error, :not_found}
  end

  @impl true
  def set_script(state, instance, script), do: update(state, instance, &%{&1 | script: script})

  @impl true
  def reboot(state, instance), do: update(state, instance, &%{&1 | reboots: &1.reboots + 1})

  @impl true
  def destroy(state, instance) do
    case File.rm(path(state, instance.name)) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
    end
  end

  @doc "The instance's current script."
  def script(state, name), do: with({:ok, i} <- get(state, name), do: {:ok, i.provider.script})

  @doc "How many times the instance was rebooted."
  def reboots(state, name), do: with({:ok, i} <- get(state, name), do: {:ok, i.provider.reboots})

  defp update(state, %Instance{name: name}, fun) do
    with {:ok, instance} <- get(state, name) do
      write!(path(state, name), %{instance | provider: fun.(instance.provider)})
    end
  end

  defp path(state, name), do: Path.join(state.dir, name <> ".term")
  defp write!(path, instance), do: File.write!(path, :erlang.term_to_binary(instance))
  defp read!(path), do: path |> File.read!() |> :erlang.binary_to_term()
end
