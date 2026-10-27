defmodule Kubex.E2E.Node do
  @moduledoc """
  Runs Elixir on a guest over `nerves_ssh` exec, with the harness key
  (docs/testing.md §2–§3).

  `nerves_ssh` evaluates the command with `Code.eval_string/1` and sends back
  `inspect(result)`. The code is wrapped so that the result comes back as
  `:erlang.term_to_binary/1` in Base64 behind a marker, so a term is returned,
  not text scraped from the output, and anything the code prints is ignored.
  """

  alias Kubex.E2E.{Key, VM}

  defmodule EvalError do
    defexception [:code, :output]

    @impl Exception
    def message(e), do: "guest evaluation failed:\n#{e.code}\n---\n#{e.output}"
  end

  @doc """
  Evaluates `code` on the guest and returns its value. Waits for ssh to come
  up for at most `timeout` ms, which covers the boot. Raises
  `Kubex.E2E.Node.EvalError` if the code raises on the guest.
  """
  @spec eval(GenServer.server(), String.t(), timeout()) :: term()
  def eval(vm, code, timeout \\ 120_000) do
    port = VM.info(vm).paths.ssh_port
    deadline = System.monotonic_time(:millisecond) + timeout

    conn = connect(port, deadline)

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

  defp wrap(code) do
    """
    "KBX:" <> Base.encode64(:erlang.term_to_binary((fn ->
    #{code}
    end).()))
    """
  end

  defp connect(port, deadline) do
    opts = [
      user: ~c"kubex-e2e",
      user_dir: String.to_charlist(Key.dir()),
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
          connect(port, deadline)
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
end
