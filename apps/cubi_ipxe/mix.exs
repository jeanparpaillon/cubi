defmodule Cubi.Ipxe.MixProject do
  use Mix.Project

  def project do
    [
      app: :cubi_ipxe,
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

  # Build-time only: `mix firmware.ipxe` runs in the firmware project
  # (docs/specs.md §2.3). Never part of a release.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.13", runtime: false},
      # Signs the served images (docs/specs.md §2.11.2).
      {:cubi_pki, in_umbrella: true}
    ]
  end
end
