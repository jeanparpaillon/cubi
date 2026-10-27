defmodule Kubex.E2E.Console do
  @moduledoc """
  A VM's serial console (docs/testing.md §2).

  Everything QEMU writes to the serial port is appended to `console.log` in
  the test directory and kept in memory. `await/3` is expect-style: it
  matches from a cursor, and a match moves the cursor past it, so successive
  awaits follow the boot in order.
  """
  use GenServer

  alias Kubex.E2E.VM

  defmodule TimeoutError do
    defexception [:regex, :timeout, :tail]

    @impl Exception
    def message(e) do
      "console did not match #{inspect(e.regex)} within #{e.timeout} ms. Last output:\n" <> e.tail
    end
  end

  @doc false
  def start_link(socket_path, log_path),
    do: GenServer.start_link(__MODULE__, {socket_path, log_path})

  @doc """
  Waits until the console output after the cursor matches `regex`, then moves
  the cursor past the match. Returns the captures, as `Regex.run/2` does.
  Raises `Kubex.E2E.Console.TimeoutError` with the last output otherwise.
  """
  @spec await(GenServer.server(), Regex.t(), timeout()) :: [String.t()]
  def await(vm, %Regex{} = regex, timeout \\ 30_000) do
    case GenServer.call(console(vm), {:await, regex, timeout}, :infinity) do
      {:ok, captures} -> captures
      {:timeout, tail} -> raise TimeoutError, regex: regex, timeout: timeout, tail: tail
    end
  end

  @doc "Types `data` on the serial console."
  @spec send_input(GenServer.server(), iodata()) :: :ok
  def send_input(vm, data), do: GenServer.call(console(vm), {:send, data})

  @doc "Everything received so far."
  @spec output(GenServer.server()) :: binary()
  def output(vm), do: GenServer.call(console(vm), :output)

  defp console(vm), do: VM.info(vm).console

  @impl GenServer
  def init({socket_path, log_path}) do
    with {:ok, socket} <- VM.connect_unix(socket_path, 5_000, active: true) do
      {:ok,
       %{
         socket: socket,
         log: File.open!(log_path, [:append, :binary]),
         buffer: "",
         cursor: 0,
         waiters: []
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:await, regex, timeout}, from, state) do
    case match(state, regex) do
      {:ok, captures, state} ->
        {:reply, {:ok, captures}, state}

      :nomatch ->
        ref = make_ref()
        Process.send_after(self(), {:timeout, ref}, timeout)
        {:noreply, %{state | waiters: state.waiters ++ [{ref, regex, from}]}}
    end
  end

  def handle_call({:send, data}, _from, state),
    do: {:reply, :gen_tcp.send(state.socket, data), state}

  def handle_call(:output, _from, state), do: {:reply, state.buffer, state}

  @impl GenServer
  def handle_info({:tcp, _socket, data}, state) do
    IO.binwrite(state.log, data)
    {:noreply, serve_waiters(%{state | buffer: state.buffer <> data})}
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:noreply, state}

  def handle_info({:timeout, ref}, state) do
    case List.keytake(state.waiters, ref, 0) do
      {{^ref, _regex, from}, waiters} ->
        GenServer.reply(from, {:timeout, tail(state.buffer)})
        {:noreply, %{state | waiters: waiters}}

      nil ->
        {:noreply, state}
    end
  end

  # Waiters are served in order: a later await never consumes output an
  # earlier one is still waiting for.
  defp serve_waiters(%{waiters: [{_ref, regex, from} | rest]} = state) do
    case match(state, regex) do
      {:ok, captures, state} ->
        GenServer.reply(from, {:ok, captures})
        serve_waiters(%{state | waiters: rest})

      :nomatch ->
        state
    end
  end

  defp serve_waiters(state), do: state

  defp match(state, regex) do
    rest = binary_part(state.buffer, state.cursor, byte_size(state.buffer) - state.cursor)

    case Regex.run(regex, rest, return: :index) do
      [{start, len} | _] = indexes ->
        captures =
          Enum.map(indexes, fn {s, l} -> if s < 0, do: "", else: binary_part(rest, s, l) end)

        {:ok, captures, %{state | cursor: state.cursor + start + len}}

      nil ->
        :nomatch
    end
  end

  defp tail(buffer) do
    size = byte_size(buffer)
    keep = min(size, 4_000)
    binary_part(buffer, size - keep, keep)
  end
end
