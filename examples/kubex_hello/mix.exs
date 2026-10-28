defmodule KubexHello.MixProject do
  use Mix.Project

  def project do
    [
      app: :kubex_hello,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {KubexHello.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5", only: :test}
    ]
  end
end
