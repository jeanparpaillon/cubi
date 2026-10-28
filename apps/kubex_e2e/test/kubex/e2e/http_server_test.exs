defmodule Kubex.E2E.HttpServerTest do
  use ExUnit.Case, async: true

  alias Kubex.E2E.HttpServer

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    served = Path.join(dir, "served")
    File.mkdir_p!(Path.join(served, "sub"))
    File.write!(Path.join(served, "boot.ipxe"), "#!ipxe\n")
    File.write!(Path.join([served, "sub", "hidden"]), "no")
    log = Path.join(dir, "http.log")
    # Linked to the test process, so it stops with the test.
    {:ok, _pid, port} = HttpServer.start_link(served, log)
    {:ok, port: port, log: log}
  end

  defp get(port, path) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    response = recv_all(socket, "")
    [status_line | _] = String.split(response, "\r\n")
    [_, body] = String.split(response, "\r\n\r\n", parts: 2)
    {status_line, body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  test "serves files at the top of the directory, and logs each request", %{port: port, log: log} do
    assert {"HTTP/1.1 200 OK", "#!ipxe\n"} = get(port, "/boot.ipxe")
    assert {"HTTP/1.1 404 Not Found", ""} = get(port, "/missing")
    assert {"HTTP/1.1 404 Not Found", ""} = get(port, "/sub/hidden")
    assert {"HTTP/1.1 404 Not Found", ""} = get(port, "/../http.log")

    assert File.read!(log) ==
             "GET /boot.ipxe 200\nGET /missing 404\nGET /sub/hidden 404\nGET /../http.log 404\n"
  end
end
