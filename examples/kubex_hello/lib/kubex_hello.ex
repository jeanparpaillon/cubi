defmodule KubexHello do
  @moduledoc """
  A minimal release to deploy onto a kubex node (docs/specs.md §2.11).
  """

  @doc """
  The page body. The version is the loaded application's, so it shows which
  release is running after a deploy or a rollback.
  """
  @spec page() :: String.t()
  def page do
    "Welcome to Kubex\nVersion: #{version()}\n"
  end

  @spec version() :: String.t()
  def version do
    :kubex_hello |> Application.spec(:vsn) |> to_string()
  end
end
