defmodule Cubi.Deploy.ShoehornHandler do
  @moduledoc """
  shoehorn's handler on a cubi node (`config :shoehorn, handler: …`,
  docs/specs.md §2.11.7).

  shoehorn calls it for every application that exits, whenever it started,
  from a `logger` filter. It never stops or starts anything itself: it runs in
  shoehorn's report handler, under a 30 s halt timer, and a raise there halts
  the node. It only casts the exit to `Cubi.Deploy`, which decides whether it
  concerns the deployed release, and always answers `:continue`. Exits by
  `Application.stop/1` (reason `:stopped`) are `Cubi.Deploy`'s own, and not
  passed on.

  The base image's applications get shoehorn's default behaviour: nothing.
  """
  @behaviour Shoehorn.Handler

  @impl Shoehorn.Handler
  def init(opts), do: {:ok, Keyword.get(opts, :cubi_deploy, Cubi.Deploy)}

  @impl Shoehorn.Handler
  def application_started(_app, deploy), do: {:continue, deploy}

  @impl Shoehorn.Handler
  def application_exited(_app, :stopped, deploy), do: {:continue, deploy}

  def application_exited(app, reason, deploy) do
    # A cast never raises, even with no Cubi.Deploy running.
    GenServer.cast(deploy, {:exited, app, reason})
    {:continue, deploy}
  end
end
