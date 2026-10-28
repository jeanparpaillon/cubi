defmodule Hello.MixProject do
  use Mix.Project

  # The e2e harness builds this release in several versions, some of which
  # crash on purpose (docs/milestone1.md): HELLO_VERSION and HELLO_MODE.
  def project do
    [
      app: :hello,
      version: System.get_env("HELLO_VERSION", "0.1.0"),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Hello.Application, []}]
  end

  defp deps do
    [{:cubi_tools, path: "../../../cubi_tools", runtime: false}]
  end
end
