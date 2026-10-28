defmodule Cubi.Deploy.Subsystem do
  @moduledoc """
  The `cubi_deploy` ssh subsystem (docs/specs.md §2.11.5), modelled on
  `ssh_subsystem_fwup`:

      ssh -s <node> cubi_deploy < release.tar.gz

  It writes what it receives to `/cubi/releases/incoming/`, at most 256 MB,
  and on EOF hands the archive to `Cubi.Deploy.install/3`. It answers with
  lines: `cubi_deploy: <step>` while it works, then `ok <name> <version>` or
  `error <reason>`, with exit status 0 or 1. The ssh session decides who may
  send an archive; only its signature decides whether it is installed.
  """

  @behaviour :ssh_client_channel

  @max_size 256 * 1024 * 1024

  @spec subsystem_spec(keyword()) :: :ssh.subsystem_spec()
  def subsystem_spec(opts \\ []), do: {~c"cubi_deploy", {__MODULE__, opts}}

  @impl :ssh_client_channel
  def init(opts) do
    {:ok,
     %{
       deploy: Keyword.get(opts, :deploy, Cubi.Deploy),
       max_size: Keyword.get(opts, :max_size, @max_size),
       cm: nil,
       id: nil,
       file: nil,
       path: nil,
       size: 0,
       phase: :receiving
     }}
  end

  @impl :ssh_client_channel
  def handle_msg({:ssh_channel_up, id, cm}, state) do
    dir = Cubi.Deploy.incoming_dir(state.deploy)
    path = Path.join(dir, "#{System.unique_integer([:positive])}.tar.gz")
    file = File.open!(path, [:write, :binary, :raw])
    {:ok, %{state | id: id, cm: cm, file: file, path: path}}
  end

  def handle_msg({:progress, line}, state) do
    say(state, "cubi_deploy: #{line}")
    {:ok, state}
  end

  def handle_msg({:installed, result}, state) do
    File.rm(state.path)

    case result do
      {:ok, %{name: name, version: version}} -> finish(state, "ok #{name} #{version}", 0)
      {:error, reason} -> finish(state, "error #{inspect(reason)}", 1)
    end
  end

  def handle_msg(_message, state), do: {:ok, state}

  @impl :ssh_client_channel
  def handle_ssh_msg({:ssh_cm, _cm, {:data, _id, 0, data}}, %{phase: :receiving} = state) do
    size = state.size + byte_size(data)

    if size > state.max_size do
      File.close(state.file)
      File.rm(state.path)
      finish(state, "error {:too_large, #{state.max_size}}", 1)
    else
      :ok = IO.binwrite(state.file, data)
      {:ok, %{state | size: size}}
    end
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _id}}, %{phase: :receiving} = state) do
    File.close(state.file)
    channel = self()
    deploy = state.deploy
    path = state.path

    # The install takes the settle period; the channel keeps serving meanwhile.
    _ =
      Task.start(fn ->
        result =
          Cubi.Deploy.install(deploy, File.read!(path), &send(channel, {:progress, &1}))

        send(channel, {:installed, result})
      end)

    {:ok, %{state | phase: :installing}}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:exit_status, _id, _}}, state), do: {:stop, state.id, state}

  def handle_ssh_msg({:ssh_cm, _cm, {:exit_signal, _id, _, _, _}}, state),
    do: {:stop, state.id, state}

  def handle_ssh_msg(_message, state), do: {:ok, state}

  @impl :ssh_client_channel
  def handle_call(_request, _from, state), do: {:reply, :error, state}

  @impl :ssh_client_channel
  def handle_cast(_message, state), do: {:noreply, state}

  @impl :ssh_client_channel
  def code_change(_old, state, _extra), do: {:ok, state}

  @impl :ssh_client_channel
  def terminate(_reason, state) do
    if state.phase == :receiving and state.path, do: File.rm(state.path)
    :ok
  end

  defp finish(state, line, status) do
    say(state, line)
    _ = :ssh_connection.send_eof(state.cm, state.id)
    _ = :ssh_connection.exit_status(state.cm, state.id, status)
    :ssh_connection.close(state.cm, state.id)
    {:ok, %{state | phase: :done}}
  end

  defp say(state, line), do: :ssh_connection.send(state.cm, state.id, line <> "\n")
end
