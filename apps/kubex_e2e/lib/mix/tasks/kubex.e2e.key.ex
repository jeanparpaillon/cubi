defmodule Mix.Tasks.Kubex.E2e.Key do
  @shortdoc "Creates the harness ssh key and test CA that e2e firmware trusts"
  @moduledoc """
  Creates `priv/harness_key/id_ed25519{,.pub}` and the test CA in `priv/pki/`
  (`mix kubex.gen_ca`'s four files) if missing.

  Run it once before building `MIX_ENV=e2e` firmware in `apps/kubex_fw`, which embeds
  the public key as its only authorized key, is signed by the test CA's signer,
  and trusts its root for releases.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    case Kubex.E2E.Key.ensure!() do
      :created -> Mix.shell().info("Created #{Kubex.E2E.Key.public_key_path()}")
      :exists -> Mix.shell().info("Already there: #{Kubex.E2E.Key.public_key_path()}")
    end

    case Kubex.E2E.Key.ensure_pki!() do
      :created -> Mix.shell().info("Created the test CA in #{Kubex.E2E.Key.pki_dir()}")
      :exists -> Mix.shell().info("Already there: #{Kubex.E2E.Key.pki_dir()}")
    end
  end
end
