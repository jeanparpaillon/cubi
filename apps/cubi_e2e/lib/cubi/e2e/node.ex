defmodule Cubi.E2E.Node do
  @moduledoc """
  Runs Elixir on a guest over `nerves_ssh` exec, with the harness key
  (docs/testing.md §2–§3).

  `nerves_ssh` evaluates the command with `Code.eval_string/1` and sends back
  `inspect(result)`. The code is wrapped so that the result comes back as
  `:erlang.term_to_binary/1` in Base64 behind a marker, so a term is returned,
  not text scraped from the output, and anything the code prints is ignored.
  """

  alias Cubi.E2E.{Key, VM}

  defmodule EvalError do
    defexception [:code, :output]

    @impl Exception
    def message(e), do: "guest evaluation failed:\n#{e.code}\n---\n#{e.output}"
  end

  @doc """
  Evaluates `code` on the guest and returns its value. The guest is a
  `Cubi.E2E.VM`, or the host port forwarded to its ssh (a
  `Cubi.Provider.Qemu` instance's `ssh_port`). Waits for ssh to come
  up for at most `timeout` ms, which covers the boot. Raises
  `Cubi.E2E.Node.EvalError` if the code raises on the guest.

  `key_dir:` logs in with the key there (`id_ed25519`) rather than the
  harness's: a node provisioned for an operator lets in that operator's key
  only (`Cubi.E2E.Key.operator/1`).
  """
  @spec eval(GenServer.server() | :inet.port_number(), String.t(), timeout(), keyword()) ::
          term()
  def eval(vm, code, timeout \\ 120_000, opts \\ []) do
    port = ssh_port(vm)
    deadline = System.monotonic_time(:millisecond) + timeout

    conn = connect(port, deadline, Keyword.get(opts, :key_dir, Key.dir()))

    try do
      output = exec(conn, wrap(code), remaining(deadline))

      case Regex.run(~r/KBX:([A-Za-z0-9+\/=]+)/, output) do
        [_, b64] -> b64 |> Base.decode64!() |> :erlang.binary_to_term()
        nil -> raise EvalError, code: code, output: output
      end
    after
      :ssh.close(conn)
    end
  end

  @doc """
  Runs ssh subsystem `name` on the guest, as `ssh -s <guest> <name> < data`
  would: sends `data`, then EOF, and returns the lines it printed and its
  exit status. Waits for ssh like `eval/3`.
  """
  @spec subsystem(GenServer.server() | :inet.port_number(), String.t(), binary(), timeout()) ::
          {[String.t()], non_neg_integer() | nil}
  def subsystem(vm, name, data, timeout \\ 120_000) do
    port = ssh_port(vm)
    deadline = System.monotonic_time(:millisecond) + timeout
    conn = connect(port, deadline, Key.dir())

    try do
      {:ok, channel} = :ssh_connection.session_channel(conn, remaining(deadline))

      :success =
        :ssh_connection.subsystem(conn, channel, String.to_charlist(name), remaining(deadline))

      # The guest may answer and close before everything is sent.
      _ = :ssh_connection.send(conn, channel, data, remaining(deadline))
      _ = :ssh_connection.send_eof(conn, channel)
      collect_status(conn, channel, [], nil, remaining(deadline))
    after
      :ssh.close(conn)
    end
  end

  defp collect_status(conn, channel, acc, status, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, 0, data}} ->
        collect_status(conn, channel, [acc, data], status, timeout)

      {:ssh_cm, ^conn, {:exit_status, ^channel, s}} ->
        collect_status(conn, channel, acc, s, timeout)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        {acc |> IO.iodata_to_binary() |> String.split("\n", trim: true), status}

      {:ssh_cm, ^conn, _} ->
        collect_status(conn, channel, acc, status, timeout)
    after
      timeout -> raise "ssh subsystem timed out after #{timeout} ms"
    end
  end

  defp wrap(code) do
    """
    "KBX:" <> Base.encode64(:erlang.term_to_binary((fn ->
    #{code}
    end).()))
    """
  end

  @doc """
  One ssh login attempt with the key in `key_dir` (`id_ed25519`, as `:ssh`'s
  `user_dir`), closed at once. For checking which keys a guest accepts; use
  `eval/3` to wait for a guest to come up.
  """
  @spec login(GenServer.server() | :inet.port_number(), Path.t()) :: :ok | {:error, term()}
  def login(vm, key_dir) do
    opts = [
      user: ~c"cubi-e2e",
      user_dir: String.to_charlist(key_dir),
      auth_methods: ~c"publickey",
      silently_accept_hosts: true,
      save_accepted_host: false,
      user_interaction: false,
      connect_timeout: 5_000
    ]

    case :ssh.connect(~c"127.0.0.1", ssh_port(vm), opts, 10_000) do
      {:ok, conn} -> :ssh.close(conn)
      {:error, _} = error -> error
    end
  end

  defp connect(port, deadline, key_dir) do
    opts = [
      user: ~c"cubi-e2e",
      user_dir: String.to_charlist(key_dir),
      auth_methods: ~c"publickey",
      silently_accept_hosts: true,
      save_accepted_host: false,
      user_interaction: false,
      connect_timeout: 5_000
    ]

    case :ssh.connect(~c"127.0.0.1", port, opts, 5_000) do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        if remaining(deadline) == 0 do
          raise "ssh to 127.0.0.1:#{port} never came up: #{inspect(reason)}"
        else
          Process.sleep(1_000)
          connect(port, deadline, key_dir)
        end
    end
  end

  defp exec(conn, command, timeout) do
    {:ok, channel} = :ssh_connection.session_channel(conn, timeout)
    :success = :ssh_connection.exec(conn, channel, String.to_charlist(command), timeout)
    collect(conn, channel, [], timeout)
  end

  defp collect(conn, channel, acc, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, _type, data}} ->
        collect(conn, channel, [acc, data], timeout)

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        collect(conn, channel, acc, timeout)

      {:ssh_cm, ^conn, {:exit_status, ^channel, _}} ->
        collect(conn, channel, acc, timeout)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        IO.iodata_to_binary(acc)
    after
      timeout -> raise "ssh exec timed out after #{timeout} ms"
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp ssh_port(port) when is_integer(port), do: port
  defp ssh_port(vm), do: VM.info(vm).paths.ssh_port
end
