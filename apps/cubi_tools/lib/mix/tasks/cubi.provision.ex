defmodule Mix.Tasks.Cubi.Provision do
  @shortdoc "Creates a cloud instance that boots a public cubi image as your node"
  @moduledoc """
  Renders the boot script (`mix cubi.boot_script`), creates the instance with
  it, and returns once the instance runs and answers ssh (docs/specs.md
  §2.12.4):

      mix cubi.provision NAME [--provider P] [--size S] [--region R]
                              [--firmware bios|uefi] [--timeout SECONDS]
                              [script options] [ssh options]

    * `--provider` - a name under `config :cubi_tools, :providers`; may be
      left out when only one is configured
    * `--size`, `--region` - the provider's own strings, default its config
    * `--firmware` - `bios` (default) or `uefi`
    * `--timeout` - how long to wait for ssh, default 600 s
    * script options - `--image`, `--local`, `--ca`, `--ssh`, `--no-ssh`,
      `--cmdline`, as for `mix cubi.boot_script`
    * ssh options - `--user`, `--identity`, `--ssh-option`, as for
      `mix cubi.deploy`; used to check the node answers

  A name already taken at the provider is refused before anything is
  created. If the instance never answers, it is left in place for you to
  look at, and `mix cubi.destroy` removes it. With `--no-ssh` the task does
  not wait for ssh: nobody can log in.
  """
  use Mix.Task

  alias Cubi.Tools.ProviderTask

  @impl Mix.Task
  def run(args) do
    switches =
      [provider: :string, size: :string, region: :string, firmware: :string] ++
        Mix.Tasks.Cubi.BootScript.script_switches() ++ ProviderTask.ssh_switches()

    {opts, rest, _} = OptionParser.parse(args, strict: switches)
    name = name!(rest)
    {provider, module, state} = p = ProviderTask.provider!(opts[:provider])

    case module.get(state, name) do
      {:error, :not_found} -> :ok
      {:ok, _} -> Mix.raise("#{name} already exists at provider #{provider}")
      {:error, reason} -> Mix.raise("provider #{provider}: #{inspect(reason)}")
    end

    script = Mix.Tasks.Cubi.BootScript.render!(opts)

    spec = %{
      name: name,
      script: script,
      firmware: firmware!(opts[:firmware]),
      size: opts[:size],
      region: opts[:region]
    }

    case module.create(state, spec) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("cannot create #{name} at #{provider}: #{inspect(reason)}")
    end

    Mix.shell().info("#{name} created at #{provider}, waiting for it to boot")

    instance =
      if opts[:no_ssh],
        do: ProviderTask.instance!(p, name),
        else: ProviderTask.wait_up!(p, name, opts)

    target = ProviderTask.target(instance)
    [_, ca] = Regex.run(~r/cubi\.ca=sha256:([0-9a-f]+)/, script)

    Mix.shell().info("""
    #{name} is up at #{provider}: #{Enum.join(instance.addresses, " ")}, ssh port #{target.port}
      image: #{instance.image}
      trusts releases signed under the root sha256:#{ca}
    """)
  end

  defp name!([name | _]), do: name
  defp name!([]), do: Mix.raise("usage: mix cubi.provision NAME [--provider P]")

  defp firmware!(nil), do: :bios
  defp firmware!("bios"), do: :bios
  defp firmware!("uefi"), do: :uefi
  defp firmware!(other), do: Mix.raise("--firmware #{other}: bios or uefi")
end
