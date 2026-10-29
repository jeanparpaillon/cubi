defmodule Mix.Tasks.Cubi.Destroy do
  @shortdoc "Destroys a cubi instance"
  @moduledoc """
  Destroys an instance and whatever its provider stored alongside it, the
  boot script included (docs/specs.md §2.12.4):

      mix cubi.destroy NAME [--provider P] [--yes]

  Asks first, unless `--yes`.
  """
  use Mix.Task

  alias Cubi.Tools.ProviderTask

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [provider: :string, yes: :boolean])

    name =
      case rest do
        [name | _] -> name
        [] -> Mix.raise("usage: mix cubi.destroy NAME [--provider P] [--yes]")
      end

    {provider, module, state} = p = ProviderTask.provider!(opts[:provider])
    instance = ProviderTask.instance!(p, name)

    if opts[:yes] || Mix.shell().yes?("Destroy #{name} at #{provider}?") do
      case module.destroy(state, instance) do
        :ok -> Mix.shell().info("#{name} destroyed")
        {:error, reason} -> Mix.raise("provider #{provider}: #{inspect(reason)}")
      end
    else
      Mix.shell().info("#{name} left as it is")
    end
  end
end
