defmodule Mix.Tasks.Cubi.E2e.Public do
  @shortdoc "Builds the public directory the milestone 2 tests boot"
  @moduledoc """
  Builds `_build/x86_64_public/ipxe/` with `mix firmware.ipxe --public`
  (`Cubi.E2E.Public`), replacing what is there. The tests build it
  themselves when it is missing; run this after changing the image.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Built #{Cubi.E2E.Public.build!()}")
  end
end
