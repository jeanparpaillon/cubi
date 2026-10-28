defmodule CubiHello do
  @moduledoc """
  A minimal release to deploy onto a cubi node (docs/specs.md §2.11).
  """

  @doc """
  The page body. The version is the loaded application's, so it shows which
  release is running after a deploy or a rollback.
  """
  @spec page() :: String.t()
  def page do
    "Welcome to Cubi\nVersion: #{version()}\n"
  end

  @spec version() :: String.t()
  def version do
    :cubi_hello |> Application.spec(:vsn) |> to_string()
  end
end
