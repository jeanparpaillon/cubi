defmodule Cubi.Storage do
  @moduledoc """
  A storage node's pool, brought up once at boot from the kernel command line
  (docs/specs.md §2.10.3, `Cubi.Storage.Pool`). No `cubi.vdevs=` means a
  diskless node.

  Whatever goes wrong is reported on the console as well as logged, and
  nothing is retried: a refused create needs a person, and the node carries on
  without its pool (restricted mode, phase 7).

  `cubi.zfs.testkey=<64 hex>` keys `<pool>/cubi/crypt` while there is no
  cluster to fetch the real key from. It is for hand-booted QEMU only, so a
  `:prod` build ignores it.
  """
  use GenServer

  require Logger

  alias Cubi.Storage.{Args, Pool}

  @testkey Mix.env() != :prod

  @type status :: :diskless | {:ok, Pool.result()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "How setup went. Waits for it to finish."
  @spec status() :: status()
  def status(), do: GenServer.call(__MODULE__, :status, :infinity)

  @impl GenServer
  def init(opts), do: {:ok, opts, {:continue, :setup}}

  @impl GenServer
  def handle_continue(:setup, opts) do
    cmdline = Cubi.Cmdline.read(Keyword.get(opts, :cmdline, "/proc/cmdline"))

    status =
      with {:ok, %Args{vdevs: vdevs} = args} when vdevs != nil <- Args.parse(cmdline),
           {:ok, key} <- testkey(cmdline) do
        Pool.setup(
          args,
          Keyword.merge(opts, key: key, machine_id: Nerves.Runtime.serial_number())
        )
      else
        {:ok, %Args{vdevs: nil}} -> :diskless
        {:error, _} = error -> error
      end

    report(status)
    {:noreply, status}
  end

  @impl GenServer
  def handle_call(:status, _from, status), do: {:reply, status, status}

  if @testkey do
    defp testkey(cmdline) do
      case List.keyfind(cmdline, "cubi.zfs.testkey", 0) do
        nil ->
          {:ok, nil}

        {_, key} when is_binary(key) and byte_size(key) == 64 ->
          if key =~ ~r/^[0-9a-fA-F]+$/ do
            message =
              "cubi: storage: cubi.zfs.testkey= keys the pool: for QEMU only, never a real node"

            Logger.warning(message)
            console(message)
            {:ok, key}
          else
            {:error, {:testkey, :not_64_hex}}
          end

        _ ->
          {:error, {:testkey, :not_64_hex}}
      end
    end
  else
    defp testkey(_cmdline), do: {:ok, nil}
  end

  defp report(:diskless), do: Logger.info("storage: diskless node")

  defp report({:ok, %{pool: pool, created: created, crypt: crypt}}) do
    message =
      "cubi: storage: pool #{pool} #{if created, do: "created", else: "imported"}, crypt #{crypt}"

    Logger.info(message)
    console(message)
  end

  defp report({:error, reason}) do
    message = "cubi: storage: refused, running without a pool: #{inspect(reason)}"
    Logger.error(message)
    console(message)
  end

  # BEAM's standard output is the console under erlinit.
  defp console(message), do: IO.puts(:user, message)
end
