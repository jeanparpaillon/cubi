defmodule Mix.Tasks.Cubi.Upgrade do
  @shortdoc "Reboots a cubi instance onto another image version"
  @moduledoc """
  Upgrading is a reboot (docs/specs.md §2.7, §2.12.4): a new boot script for
  the new image, given to the provider, then a reboot. Returns once the node
  answers ssh and reports the new image's firmware UUID.

      mix cubi.upgrade NAME --image VERSION|URL [--provider P] [--timeout SECONDS]
                            [script options] [ssh options]

  Script and ssh options are those of `mix cubi.provision`: give the same
  ones, since the script is rendered again from them. The instance is
  diskless, so its deployed release is gone after the reboot: deploy it
  again (`mix cubi.deploy NAME --provider P`).
  """
  use Mix.Task

  alias Cubi.Tools.{Image, ProviderTask, Ssh}

  @impl Mix.Task
  def run(args) do
    switches =
      [provider: :string] ++
        Mix.Tasks.Cubi.BootScript.script_switches() ++ ProviderTask.ssh_switches()

    {opts, rest, _} = OptionParser.parse(args, strict: switches)

    name =
      case rest do
        [name | _] -> name
        [] -> Mix.raise("usage: mix cubi.upgrade NAME --image VERSION|URL")
      end

    if opts[:image] == nil, do: Mix.raise("--image VERSION|URL is required")
    if opts[:no_ssh], do: Mix.raise("--no-ssh: the upgrade could not be checked")

    {provider, module, state} = p = ProviderTask.provider!(opts[:provider])
    instance = ProviderTask.instance!(p, name)

    script = Mix.Tasks.Cubi.BootScript.render!(opts)
    uuid = firmware_uuid!(opts[:local] || Mix.Tasks.Cubi.BootScript.image!(opts[:image]))

    with :ok <- module.set_script(state, instance, script),
         :ok <- module.reboot(state, instance) do
      :ok
    else
      {:error, reason} -> Mix.raise("provider #{provider}: #{inspect(reason)}")
    end

    Mix.shell().info("#{name} rebooting onto #{Cubi.Tools.BootScript.image_of(script)}")

    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 600) * 1000
    instance = ProviderTask.wait_up!(p, name, opts)
    wait_uuid!(ProviderTask.target(instance), uuid, ProviderTask.ssh_opts(opts), deadline)

    Mix.shell().info("""
    #{name} runs firmware #{uuid}
      Its deployed release is gone with the reboot: deploy it again.
    """)
  end

  defp firmware_uuid!(source) do
    case Image.base(source) do
      {:ok, %{"firmware" => %{"uuid" => uuid}}} -> uuid
      {:ok, _} -> Mix.raise("#{source}: base.json names no firmware UUID")
      {:error, reason} -> Mix.raise("#{source}: #{inspect(reason)}")
    end
  end

  # A cloud reboot may not have happened yet when ssh first answers: wait
  # for the new firmware, not just for ssh.
  defp wait_uuid!(target, uuid, ssh_opts, deadline) do
    {out, _} = Ssh.eval(target, ~s|Nerves.Runtime.KV.get_active("nerves_fw_uuid")|, ssh_opts)

    cond do
      out =~ uuid ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        Mix.raise("the node never reported firmware #{uuid}; last answer: #{String.trim(out)}")

      true ->
        Process.sleep(Application.get_env(:cubi_tools, :poll_ms, 5_000))
        wait_uuid!(target, uuid, ssh_opts, deadline)
    end
  end
end
