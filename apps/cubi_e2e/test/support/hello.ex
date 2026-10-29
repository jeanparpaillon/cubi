defmodule Cubi.E2E.Hello do
  @moduledoc """
  The `hello` release fixture (`fixtures/hello`, docs/milestone1.md): built
  with `mix cubi.release` against the served image, signed with
  `mix cubi.sign`, deployed with `mix cubi.deploy`, all run as a user would,
  in the fixture's directory.
  """

  alias Cubi.E2E.{Key, VM}
  alias Cubi.Pki.Archive

  @dir Path.expand("../../fixtures/hello", __DIR__)

  @doc """
  Builds and signs `hello` `version` in `mode` (`:ok`, `:crash_on_start`,
  `:crash_later`) against the served directory. Returns the archive's path.
  Options: `:signer`, a PKI directory, default the test CA.
  """
  @spec build!(String.t(), atom(), Path.t(), keyword()) :: Path.t()
  def build!(version, mode, served, opts \\ []) do
    env = [{"MIX_ENV", "prod"}, {"HELLO_VERSION", version}, {"HELLO_MODE", Atom.to_string(mode)}]

    # The version is an environment variable, so mix.exs does not change and
    # Mix would keep the previous version's .app: compile --force.
    mix!(["do", "compile", "--force", "+", "cubi.release", "--base", served], env)

    archive = Path.join(@dir, "_build/prod/cubi/hello-#{version}.tar.gz")
    signer = Keyword.get(opts, :signer, Key.pki_dir())
    mix!(["cubi.sign", archive, "--signer", signer], env)

    # Kept aside: the next build of the same version would overwrite it.
    out =
      Path.join(
        System.tmp_dir!(),
        "hello-#{version}-#{mode}-#{System.unique_integer([:positive])}.tar.gz"
      )

    File.cp!(archive, out)
    out
  end

  @doc """
  A copy of `archive` with `change` applied to its entries (`Cubi.Pki.Archive`),
  then re-signed with the test CA if `resign`: what `mix cubi.release` would
  never build, but a node must refuse anyway.
  """
  @spec tamper!(Path.t(), (Archive.entries() -> Archive.entries()), boolean()) :: Path.t()
  def tamper!(archive, change, resign) do
    entries = archive |> File.read!() |> Archive.read() |> elem(1) |> change.()

    entries =
      if resign do
        {:ok, signed} = Archive.sign(entries, Cubi.Pki.load_signer!(Key.pki_dir()))
        signed
      else
        entries
      end

    out =
      Path.join(System.tmp_dir!(), "hello-tampered-#{System.unique_integer([:positive])}.tar.gz")

    Archive.write!(out, entries)
    out
  end

  @doc "Changes `manifest.json` with `fun`, keeping everything else."
  @spec edit_manifest(Archive.entries(), (map() -> map())) :: Archive.entries()
  def edit_manifest(entries, fun) do
    manifest = entries |> Map.fetch!("manifest.json") |> JSON.decode!() |> fun.()
    Map.put(entries, "manifest.json", JSON.encode!(manifest))
  end

  @doc """
  `mix cubi.deploy` of `archive` to the VM's forwarded ssh port (or that port
  itself, for a `Cubi.Provider.Qemu` instance), with the harness key. Returns `{output, exit_status}`.
  """
  @spec deploy(GenServer.server() | :inet.port_number(), Path.t()) ::
          {String.t(), non_neg_integer()}
  def deploy(vm, archive) do
    port = if is_integer(vm), do: vm, else: VM.info(vm).paths.ssh_port

    args =
      ["cubi.deploy", "127.0.0.1", archive, "--port", Integer.to_string(port)] ++
        ["--user", "cubi-e2e", "--identity", Path.join(Key.dir(), "id_ed25519")] ++
        Enum.flat_map(
          ~w(StrictHostKeyChecking=no UserKnownHostsFile=/dev/null LogLevel=ERROR),
          &["--ssh-option", &1]
        )

    System.cmd("mix", args, cd: @dir, env: [{"MIX_ENV", "prod"}], stderr_to_stdout: true)
  end

  defp mix!(args, env) do
    case System.cmd("mix", args, cd: @dir, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> raise "mix #{Enum.join(args, " ")} exited #{status} in #{@dir}:\n#{out}"
    end
  end
end
