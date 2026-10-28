defmodule Cubi.Deploy.Loader do
  @moduledoc """
  Loads, starts and stops a release's applications in the node's own BEAM
  (docs/specs.md §2.11.6).

  Applications the node's `lib/` already has at the same version are the
  image's: they are left alone, never loaded from the release nor stopped with
  it. The others are the release's own, in its version directory.
  """

  @doc "The release's own applications: its manifest's, minus the image's."
  @spec own_apps(map(), %{String.t() => String.t()}) :: [%{String.t() => String.t()}]
  def own_apps(manifest, node_lib) do
    Enum.reject(manifest["applications"], fn %{"name" => n, "vsn" => v} -> node_lib[n] == v end)
  end

  @doc """
  Adds each own application's `ebin` to the code path, loads it, then applies
  the release's `sys.config`. Stops at the first failure, unloading what it
  loaded.
  """
  @spec load(Path.t(), map(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  def load(dir, manifest, node_lib) do
    apps = own_apps(manifest, node_lib)

    result =
      Enum.reduce_while(apps, {:ok, []}, fn %{"name" => name, "vsn" => vsn}, {:ok, done} ->
        ebin = Path.join([dir, "lib", "#{name}-#{vsn}", "ebin"])
        app = String.to_atom(name)

        with true <- :code.add_patha(String.to_charlist(ebin)),
             :ok <- Application.load(app) do
          {:cont, {:ok, [app | done]}}
        else
          {:error, reason} -> {:halt, {:error, {:load, name, reason}, [app | done]}}
        end
      end)

    case result do
      {:ok, _} ->
        apply_config(Path.join([dir, "releases", manifest["version"], "sys.config"]))

      {:error, reason, done} ->
        Enum.each(done, &unload/1)
        {:error, reason}
    end
  end

  @doc """
  Starts each application of the manifest's `start`, in order, `:temporary`:
  a release that dies never takes the node down with it.
  """
  @spec start(map()) :: :ok | {:error, term()}
  def start(manifest) do
    Enum.reduce_while(manifest["start"], :ok, fn name, :ok ->
      case Application.ensure_all_started(String.to_atom(name), :temporary) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:start, name, reason}}}
      end
    end)
  end

  @doc """
  Stops and unloads every own application, `start`'s first and in reverse,
  then purges its modules and drops its code path. Purging kills any process
  still running that code. Never fails: it is also the cleanup after a failed
  start.
  """
  @spec stop(map(), %{String.t() => String.t()}) :: :ok
  def stop(manifest, node_lib) do
    own = manifest |> own_apps(node_lib) |> Enum.map(&String.to_atom(&1["name"]))
    started = manifest["start"] |> Enum.map(&String.to_atom/1) |> Enum.filter(&(&1 in own))
    order = Enum.reverse(started) ++ Enum.reverse(own -- started)

    Enum.each(order, &Application.stop/1)
    Enum.each(order, &unload/1)
  end

  @doc "Whether every application of `start` is running."
  @spec running?(map()) :: boolean()
  def running?(manifest) do
    running = for {app, _, _} <- Application.started_applications(), do: Atom.to_string(app)
    Enum.all?(manifest["start"], &(&1 in running))
  end

  defp unload(app) do
    modules = Application.spec(app, :modules) || []
    ebin = :code.lib_dir(app)
    _ = Application.unload(app)

    for module <- modules do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    if is_list(ebin),
      do: :code.del_path(Path.join(to_string(ebin), "ebin") |> String.to_charlist())

    :ok
  end

  defp apply_config(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [config]} when is_list(config) -> Application.put_all_env(config)
      {:ok, []} -> :ok
      {:error, :enoent} -> :ok
      other -> {:error, {:sys_config, other}}
    end
  end
end
