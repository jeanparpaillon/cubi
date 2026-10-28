defmodule Cubi.Deploy do
  @moduledoc """
  Installs signed releases on this node, one at a time
  (docs/specs.md §2.11.4–§2.11.7).

  `install/2` takes an archive, as `mix cubi.deploy` sends it through the
  `cubi_deploy` ssh subsystem (`Cubi.Deploy.Subsystem`):

    1. read it and verify it against the image's root, `/etc/cubi/ca.pem`,
       signer dates included (`Cubi.Pki.Archive.verify/3`);
    2. check it against this node (`Cubi.Deploy.Check`);
    3. unpack it to `/cubi/releases/<version>/` (`Cubi.Deploy.Store`);
    4. stop the current release, load and start the new one
       (`Cubi.Deploy.Loader`);
    5. wait the settle period, the new release's applications all running;
    6. record it: `previous` ← `current` ← new version, and prune.

  A failure in 4 or 5 puts things back: the new version is stopped and marked
  bad, never to be started again, and the release that was running is started
  again from its directory, verified again first.

  **After the settle period**, shoehorn reports the exit of any application to
  `Cubi.Deploy.ShoehornHandler`, which casts it here. If it is one of the
  current release's own applications and the release is no longer all
  running, the release is **rolled back** (§2.11.7): stopped, marked bad, and
  `previous` started in its place, verified again from disk. With no
  `previous`, or one that fails too (then bad as well), nothing runs. An exit
  for an application that is running again, after an install already rolled
  back, is stale and ignored.

  On a diskless node `/cubi` is a tmpfs mounted here; on a storage node it is
  the pool's (`Cubi.Storage`), with `/cubi/releases` its own dataset.
  """
  use GenServer

  require Logger

  alias Cubi.Deploy.{Check, Loader, Store}
  alias Cubi.Pki.Archive

  @defaults [
    root: "/cubi/releases",
    ca_cert: "/etc/cubi/ca.pem",
    settle: 10_000,
    # Options for the target only: wait for Cubi.Storage, and mount a tmpfs
    # here if nothing is mounted on it.
    wait_storage: false,
    tmpfs: nil,
    mounts: "/proc/mounts"
  ]

  @type progress :: (String.t() -> any())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Installs `archive` (its bytes). `progress` is called with a line for each
  step. Returns once the release has settled, or has been rolled back.
  """
  @spec install(GenServer.server(), binary(), progress()) ::
          {:ok, %{name: String.t(), version: String.t()}} | {:error, term()}
  def install(server \\ __MODULE__, archive, progress \\ fn _ -> :ok end),
    do: GenServer.call(server, {:install, archive, progress}, :infinity)

  @doc "Where an incoming archive is written."
  @spec incoming_dir(GenServer.server()) :: Path.t()
  def incoming_dir(server \\ __MODULE__), do: GenServer.call(server, :incoming_dir)

  @doc "The deployed releases' state (`Cubi.Deploy.Store`)."
  @spec state(GenServer.server()) :: Store.state()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @impl GenServer
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)
    {:ok, %{opts: opts, root: opts[:root], current: nil}, {:continue, :prepare}}
  end

  @impl GenServer
  def handle_continue(:prepare, state) do
    if state.opts[:wait_storage], do: Cubi.Storage.status()
    if state.opts[:tmpfs], do: ensure_tmpfs(state.opts[:tmpfs], state.opts[:mounts])
    File.mkdir_p!(Store.incoming_dir(state.root))
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:incoming_dir, _from, state),
    do: {:reply, Store.incoming_dir(state.root), state}

  def handle_call(:state, _from, state), do: {:reply, Store.state(state.root), state}

  def handle_call({:install, archive, progress}, _from, state) do
    {reply, state} = do_install(archive, progress, state)
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:exited, app, reason}, %{current: %{manifest: manifest}} = state) do
    node = node_info(state.opts)
    own = for %{"name" => name} <- Loader.own_apps(manifest, node.lib), do: name

    if Atom.to_string(app) in own and not Loader.running?(manifest),
      do: {:noreply, rollback(state, node, {app, reason})},
      else: {:noreply, state}
  end

  def handle_cast({:exited, _app, _reason}, state), do: {:noreply, state}

  defp do_install(archive, progress, state) do
    node = node_info(state.opts)
    stored = Store.state(state.root)

    progress.("verifying")

    with {:ok, entries} <- Archive.read(archive),
         {:ok, ca} <- read_ca(state.opts[:ca_cert]),
         {:ok, manifest} <- Archive.verify(entries, ca),
         :ok <- Check.run(manifest, node, stored, current_name(state)) do
      version = manifest["version"]
      progress.("unpacking #{manifest["name"]} #{version}")
      dir = Store.unpack!(state.root, version, entries)

      if state.current do
        progress.("stopping #{state.current.manifest["version"]}")
        Loader.stop(state.current.manifest, node.lib)
      end

      progress.("starting #{version}")

      case start_and_settle(dir, manifest, node, state.opts[:settle], progress) do
        :ok ->
          Store.put_state!(state.root, %{stored | previous: stored.current, current: version})
          Store.prune!(state.root, [version, stored.current])
          new = %{manifest: manifest, version: version}
          {{:ok, %{name: manifest["name"], version: version}}, %{state | current: new}}

        {:error, reason} ->
          Logger.error("deploy: #{version} failed, rolling back: #{inspect(reason)}")
          progress.("failed, rolling back: #{inspect(reason)}")
          Loader.stop(manifest, node.lib)
          Store.put_state!(state.root, %{stored | bad: Enum.uniq(stored.bad ++ [version])})
          File.rm_rf!(dir)
          {{:error, {:failed, reason}}, restart_current(state, node, progress)}
      end
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp start_and_settle(dir, manifest, node, settle, progress) do
    with :ok <- Loader.load(dir, manifest, node.lib),
         :ok <- Loader.start(manifest) do
      progress.("settling #{div(settle, 1000)} s")
      settle(manifest, System.monotonic_time(:millisecond) + settle)
    end
  end

  defp settle(manifest, deadline) do
    cond do
      not Loader.running?(manifest) ->
        {:error, :exited_while_settling}

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(200)
        settle(manifest, deadline)
    end
  end

  # The release stopped for the install, back as it was.
  defp restart_current(%{current: nil} = state, _node, _progress), do: state

  defp restart_current(%{current: current} = state, node, progress) do
    progress.("restarting #{current.version}")

    case start_from_disk(state, current.version, node) do
      {:ok, _manifest} ->
        state

      {:error, reason} ->
        Logger.error("deploy: could not restart #{current.version}: #{inspect(reason)}")
        %{state | current: nil}
    end
  end

  # Starts a version from its directory, verified again first, signer dates
  # excepted (§2.11.4). Leaves nothing loaded if it fails.
  defp start_from_disk(state, version, node) do
    with {:ok, entries} <- Store.entries(state.root, version),
         {:ok, ca} <- read_ca(state.opts[:ca_cert]),
         {:ok, manifest} <- Archive.verify(entries, ca, check_dates: false),
         :ok <- Loader.load(Store.version_dir(state.root, version), manifest, node.lib) do
      case Loader.start(manifest) do
        :ok ->
          {:ok, manifest}

        {:error, _} = error ->
          Loader.stop(manifest, node.lib)
          error
      end
    end
  end

  defp rollback(%{current: current} = state, node, cause) do
    stored = Store.state(state.root)
    Logger.error("deploy: #{current.version} exited (#{inspect(cause)}), rolling back")
    Loader.stop(current.manifest, node.lib)
    bad = Enum.uniq(stored.bad ++ [current.version])

    {new_current, bad} =
      case stored.previous && start_from_disk(state, stored.previous, node) do
        {:ok, manifest} ->
          Logger.warning("deploy: rolled back to #{stored.previous}")
          {%{manifest: manifest, version: stored.previous}, bad}

        nil ->
          Logger.warning("deploy: no previous release, nothing runs")
          {nil, bad}

        {:error, reason} ->
          Logger.error("deploy: previous #{stored.previous} failed too: #{inspect(reason)}")
          {nil, Enum.uniq(bad ++ [stored.previous])}
      end

    version = new_current && new_current.version
    Store.put_state!(state.root, %{current: version, previous: nil, bad: bad})
    Store.prune!(state.root, [version])
    %{state | current: new_current}
  end

  defp current_name(%{current: nil}), do: nil
  defp current_name(%{current: %{manifest: manifest}}), do: manifest["name"]

  defp node_info(opts), do: if(opts[:node], do: opts[:node], else: Check.node())

  defp read_ca(path) do
    case File.read(path) do
      {:ok, pem} -> {:ok, pem}
      {:error, _} -> {:error, {:no_trusted_ca, path}}
    end
  end

  # A diskless node: nothing is mounted on `dir`, so a tmpfs goes there, and
  # every deployed release is gone at the next boot (§2.11.6).
  defp ensure_tmpfs(dir, mounts) do
    mounted =
      mounts
      |> File.read!()
      |> String.split("\n")
      |> Enum.any?(&(Enum.at(String.split(&1), 1) == dir))

    if not mounted do
      {_, 0} =
        System.cmd("/bin/mount", ~w(-t tmpfs -o mode=0755,nodev,nosuid tmpfs) ++ [dir],
          stderr_to_stdout: true
        )

      Logger.info("deploy: diskless, releases kept in a tmpfs on #{dir}")
    end
  end
end
