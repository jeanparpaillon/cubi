defmodule KubexHello.Router do
  @moduledoc """
  Serves the one page: a welcome line and the running version.
  """
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, KubexHello.page())
  end

  match _ do
    send_resp(conn, 404, "Not found\n")
  end
end
