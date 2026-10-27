defmodule Kubex.E2E.Key do
  @moduledoc """
  The harness's ssh key (docs/testing.md §3).

  `MIX_ENV=e2e` firmware trusts this key and nothing else. It is generated
  locally by `mix kubex.e2e.key` and never committed: an e2e image found on a
  real network must not open to a key anyone can download.
  """

  @dir Path.expand("../../../priv/harness_key", __DIR__)

  @doc "The directory holding `id_ed25519` and `id_ed25519.pub`, as `:ssh`'s `user_dir`."
  @spec dir() :: Path.t()
  def dir(), do: @dir

  @spec public_key_path() :: Path.t()
  def public_key_path(), do: Path.join(@dir, "id_ed25519.pub")

  @doc "Creates the key pair if it does not exist yet. Returns `:created` or `:exists`."
  @spec ensure!() :: :created | :exists
  def ensure!() do
    private = Path.join(@dir, "id_ed25519")

    if File.exists?(private) do
      :exists
    else
      File.mkdir_p!(@dir)
      File.chmod!(@dir, 0o700)

      {_, 0} =
        System.cmd(
          "ssh-keygen",
          ["-q", "-t", "ed25519", "-N", "", "-C", "kubex-e2e-harness", "-f", private],
          stderr_to_stdout: true
        )

      :created
    end
  end
end
