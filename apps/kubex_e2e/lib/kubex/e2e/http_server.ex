defmodule Kubex.E2E.HttpServer do
  @moduledoc """
  Serves a directory over HTTP on host loopback for PXE boots
  (docs/testing.md §4.1). The guest reaches it as `10.0.2.2:<port>`.

  Only plain files directly in the directory are served. Every request is
  appended to a log, `GET /<name> <status>` per line, so a test can tell what
  actually travelled over HTTP.
  """
  @behaviour Plug

  import Plug.Conn

  @doc "Starts the server on a free loopback port. Returns the server and the port."
  @spec start_link(Path.t(), Path.t()) :: {:ok, pid(), :inet.port_number()}
  def start_link(dir, log) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__, dir: dir, log: log},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, pid, port}
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: [name]} = conn, opts)
      when name not in [".", ".."] do
    path = Path.join(opts[:dir], name)

    if File.regular?(path) do
      log(opts, conn, 200)
      send_file(conn, 200, path)
    else
      log(opts, conn, 404)
      send_resp(conn, 404, "")
    end
  end

  def call(conn, opts) do
    log(opts, conn, 404)
    send_resp(conn, 404, "")
  end

  defp log(opts, conn, status),
    do: File.write!(opts[:log], "#{conn.method} #{conn.request_path} #{status}\n", [:append])
end
