defmodule Kubex.E2E.MixProject do
  use Mix.Project

  def project do
    [
      app: :kubex_e2e,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:muontrap, "~> 2.0"},
      # The HTTP side of PXE boots (docs/testing.md §4.1).
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"}
    ]
  end
end
