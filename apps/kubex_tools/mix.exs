defmodule Kubex.Tools.MixProject do
  use Mix.Project

  def project do
    [
      app: :kubex_tools,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Host-only: the operator's Mix tasks (docs/specs.md §2.11). User projects add
  # it with `runtime: false`; never part of a release.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:kubex_pki, in_umbrella: true}
    ]
  end
end
