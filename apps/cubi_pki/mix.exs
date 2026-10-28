defmodule Cubi.Pki.MixProject do
  use Mix.Project

  def project do
    [
      app: :cubi_pki,
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

  # Host and target (docs/specs.md §2.11.1, §2.11.4): the host tasks generate
  # and sign, the node verifies. `Cubi.Pki.Cms` is host-only (it runs
  # `openssl`), but costs nothing in a release.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key]
    ]
  end

  defp deps do
    [
      {:x509, "~> 0.9"}
    ]
  end
end
