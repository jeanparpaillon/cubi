defmodule CubiHello.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.fetch_env!(:cubi_hello, :port)

    children = [
      {Bandit, plug: CubiHello.Router, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CubiHello.Supervisor)
  end
end
