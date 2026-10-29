defmodule Mix.Tasks.Cubi.E2e.Key do
  @shortdoc "Creates the harness ssh key and test CA that e2e firmware trusts"
  @moduledoc """
  Creates `priv/harness_key/id_ed25519{,.pub}` and the test CA in `priv/pki/`
  (`mix cubi.gen_ca`'s four files) if missing, and the two operators of the
  milestone 2 tests, each a CA and an ssh key, in `priv/operators/{a,b}/`.

  Run it once before building `MIX_ENV=e2e` firmware in `apps/cubi_fw`, which embeds
  the public key as its only authorized key, is signed by the test CA's signer,
  and trusts its root for releases.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    case Cubi.E2E.Key.ensure!() do
      :created -> Mix.shell().info("Created #{Cubi.E2E.Key.public_key_path()}")
      :exists -> Mix.shell().info("Already there: #{Cubi.E2E.Key.public_key_path()}")
    end

    case Cubi.E2E.Key.ensure_pki!() do
      :created -> Mix.shell().info("Created the test CA in #{Cubi.E2E.Key.pki_dir()}")
      :exists -> Mix.shell().info("Already there: #{Cubi.E2E.Key.pki_dir()}")
    end

    created = Cubi.E2E.Key.ensure_operators!()

    Mix.shell().info(
      "Operators #{inspect([:a, :b])}: #{if created == [], do: "already there", else: "created #{inspect(created)}"}"
    )
  end
end
