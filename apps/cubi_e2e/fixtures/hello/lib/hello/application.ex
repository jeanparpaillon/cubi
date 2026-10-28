defmodule Hello.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    case Application.fetch_env!(:hello, :mode) do
      :ok ->
        Supervisor.start_link([], strategy: :one_for_one, name: Hello.Supervisor)

      :crash_on_start ->
        {:error, :crash_on_start}

      :crash_later ->
        crash = fn ->
          Process.sleep(5_000)
          exit(:crash_later)
        end

        Supervisor.start_link(
          [Supervisor.child_spec({Task, crash}, restart: :permanent)],
          strategy: :one_for_one,
          max_restarts: 0,
          name: Hello.Supervisor
        )
    end
  end
end
