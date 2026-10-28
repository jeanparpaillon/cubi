defmodule Hello do
  @moduledoc "The e2e harness's release fixture (docs/milestone1.md)."

  @doc "The running version: what the harness asks a node for."
  @spec version() :: String.t()
  def version(), do: :hello |> Application.spec(:vsn) |> to_string()
end
