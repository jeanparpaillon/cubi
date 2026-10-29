defmodule Cubi.E2E.Key do
  @moduledoc """
  The harness's ssh key (docs/testing.md §3).

  `MIX_ENV=e2e` firmware trusts this key and nothing else. It is generated
  locally by `mix cubi.e2e.key` and never committed: an e2e image found on a
  real network must not open to a key anyone can download.
  """

  @dir Path.expand("../../../priv/harness_key", __DIR__)

  @doc "The directory holding `id_ed25519` and `id_ed25519.pub`, as `:ssh`'s `user_dir`."
  @spec dir() :: Path.t()
  def dir(), do: @dir

  @spec public_key_path() :: Path.t()
  def public_key_path(), do: Path.join(@dir, "id_ed25519.pub")

  @pki Path.expand("../../../priv/pki", __DIR__)

  @doc """
  The test CA's PKI directory (`Cubi.Pki`): `MIX_ENV=e2e` firmware is signed
  by its signer and trusts its root for releases (docs/specs.md §2.11.2).
  """
  @spec pki_dir() :: Path.t()
  def pki_dir(), do: @pki

  @doc "Creates the test CA if it does not exist yet. Returns `:created` or `:exists`."
  @spec ensure_pki!() :: :created | :exists
  def ensure_pki!() do
    if File.exists?(Cubi.Pki.paths(@pki).signer_key) do
      :exists
    else
      Cubi.Pki.gen_ca!(@pki, name: "cubi e2e")
      :created
    end
  end

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
          ["-q", "-t", "ed25519", "-N", "", "-C", "cubi-e2e-harness", "-f", private],
          stderr_to_stdout: true
        )

      :created
    end
  end

  @operators Path.expand("../../../priv/operators", __DIR__)

  @doc """
  An operator of the milestone 2 tests, `:a` or `:b` (docs/milestone2.md):
  its own CA (`pki`, a `Cubi.Pki` directory) and ssh key (`ssh_dir` holding
  `id_ed25519`, `ssh_pub` its public key), under `priv/operators/<name>/`.
  Neither is the harness's, so a node set up for one lets in no one else.
  """
  @spec operator(:a | :b) :: %{pki: Path.t(), ssh_dir: Path.t(), ssh_pub: Path.t()}
  def operator(name) when name in [:a, :b] do
    dir = Path.join(@operators, Atom.to_string(name))
    ssh = Path.join(dir, "ssh")
    %{pki: Path.join(dir, "pki"), ssh_dir: ssh, ssh_pub: Path.join(ssh, "id_ed25519.pub")}
  end

  @doc "Creates both operators' CA and key where missing. Returns the names created."
  @spec ensure_operators!() :: [:a | :b]
  def ensure_operators!() do
    for name <- [:a, :b], op = operator(name), not File.exists?(op.ssh_pub) do
      if not File.exists?(Cubi.Pki.paths(op.pki).signer_key),
        do: Cubi.Pki.gen_ca!(op.pki, name: "cubi e2e operator #{name}")

      File.mkdir_p!(op.ssh_dir)
      File.chmod!(op.ssh_dir, 0o700)

      {_, 0} =
        System.cmd(
          "ssh-keygen",
          ["-q", "-t", "ed25519", "-N", "", "-C", "cubi-e2e-operator-#{name}"] ++
            ["-f", Path.join(op.ssh_dir, "id_ed25519")],
          stderr_to_stdout: true
        )

      name
    end
  end
end
