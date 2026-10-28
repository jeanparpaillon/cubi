defmodule CubiHello.MixProject do
  use Mix.Project

  def project do
    [
      app: :cubi_hello,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CubiHello.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5", only: :test},
      # mix cubi.release / cubi.sign / cubi.deploy (docs/specs.md §2.11).
      # Host-only, never in the release.
      {:cubi_tools, path: "../../apps/cubi_tools", runtime: false}
    ]
  end
end
