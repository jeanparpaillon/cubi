defmodule Mix.Tasks.Cubi.Instances do
  @shortdoc "Lists the cubi instances at your providers"
  @moduledoc """
  Lists the instances a provider holds for cubi (docs/specs.md §2.12.4): the
  provider is the inventory, there is no local state.

      mix cubi.instances [--provider P]

  Without `--provider`, every configured provider is asked. One line per
  instance: provider, name, status, addresses, and the image its boot script
  names (the version, when the URL ends with one).
  """
  use Mix.Task

  alias Cubi.Tools.ProviderTask

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [provider: :string])

    providers =
      if opts[:provider],
        do: [opts[:provider]],
        else: Enum.map(Cubi.Provider.configured(), &elem(&1, 0))

    if providers == [], do: Mix.raise("no provider configured: config :cubi_tools, :providers")

    rows =
      for name <- providers,
          {provider, module, state} = ProviderTask.provider!(name),
          instance <- list!(provider, module, state) do
        [
          provider,
          instance.name,
          to_string(instance.status),
          Enum.join(instance.addresses, ","),
          image(instance.image)
        ]
      end

    if rows == [] do
      Mix.shell().info("no instances")
    else
      Mix.shell().info(table([~w(PROVIDER NAME STATUS ADDRESSES IMAGE) | rows]))
    end
  end

  defp list!(provider, module, state) do
    case module.list(state) do
      {:ok, instances} -> Enum.sort_by(instances, & &1.name)
      {:error, reason} -> Mix.raise("provider #{provider}: #{inspect(reason)}")
    end
  end

  defp image(nil), do: "-"
  defp image(url), do: url |> String.trim_trailing("/") |> Path.basename()

  defp table(rows) do
    widths =
      rows
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map_join(rows, "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end)
  end
end
