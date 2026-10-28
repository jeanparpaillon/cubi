defmodule KubexHello.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = Application.fetch_env!(:kubex_hello, :port)

    children = [
      {Bandit, plug: KubexHello.Router, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: KubexHello.Supervisor)
  end
end
