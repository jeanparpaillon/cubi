defmodule Mix.Tasks.Cubi.Deploy do
  @shortdoc "Deploys a signed release archive to a running cubi node"
  @moduledoc """
  Streams a signed release archive to a node's `cubi_deploy` ssh subsystem,
  the way `mix upload` streams a `.fw` (docs/specs.md §2.11.5):

      mix cubi.deploy NODE [ARCHIVE] [--port N] [--user U] [--identity FILE]
                                     [--ssh-option OPT ...]
      mix cubi.deploy NAME [ARCHIVE] --provider P [--user U] [--identity FILE] …

    * `ARCHIVE` - default the newest `_build/<env>/cubi/*.tar.gz`
    * `--provider P` - `NAME` is an instance of that provider
      (docs/specs.md §2.12.4): its address and ssh port come from the
      provider, and host key checking is off, since a diskless node has a
      new host key at every boot (`Cubi.Tools.Ssh`)
    * `--port`, `--user`, `--identity` - passed to `ssh` as `-p`, `-l`, `-i`
    * `--ssh-option OPT` - passed as `-o OPT`; repeatable

  It runs the system `ssh`, so `~/.ssh/config` applies. The node prints a
  line per step and a last line `ok <name> <version>` or `error <reason>`,
  after the settle period; this task prints them and exits non-zero unless
  that last line is `ok`. An unsigned archive is refused before anything is
  sent: the node would refuse it anyway.
  """
  use Mix.Task

  @switches [
    port: :integer,
    user: :string,
    identity: :string,
    ssh_option: :keep,
    provider: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)

    {node, archive} =
      case rest do
        [node, archive | _] -> {node, archive}
        [node] -> {node, newest!()}
        [] -> Mix.raise("usage: mix cubi.deploy NODE [ARCHIVE]")
      end

    if not File.regular?(archive), do: Mix.raise("no #{archive}")
    check_signed!(archive)

    {node, opts} = if opts[:provider], do: via_provider(node, opts), else: {node, opts}

    Mix.shell().info("Deploying #{Path.relative_to_cwd(archive)} to #{node}")
    {lines, status} = stream(archive, ssh_args(node, opts))

    case {status, List.last(lines)} do
      {0, "ok " <> _} -> :ok
      {_, last} -> Mix.raise("deploy failed (ssh status #{status}): #{last || "no answer"}")
    end
  end

  @doc false
  @spec ssh_args(String.t(), keyword()) :: [String.t()]
  def ssh_args(node, opts) do
    port = if opts[:port], do: ["-p", Integer.to_string(opts[:port])], else: []
    user = if opts[:user], do: ["-l", opts[:user]], else: []
    identity = if opts[:identity], do: ["-i", opts[:identity]], else: []
    extra = opts |> Keyword.get_values(:ssh_option) |> Enum.flat_map(&["-o", &1])

    port ++ user ++ identity ++ extra ++ ["-s", node, "cubi_deploy"]
  end

  @doc false
  # The instance's address and ssh port, from its provider.
  def via_provider(name, opts) do
    provider = Cubi.Tools.ProviderTask.provider!(opts[:provider])

    target =
      provider |> Cubi.Tools.ProviderTask.instance!(name) |> Cubi.Tools.ProviderTask.target()

    {target.host, Keyword.put(Cubi.Tools.ProviderTask.ssh_opts(opts), :port, target.port)}
  end

  # An Erlang port cannot close ssh's stdin without closing its stdout too, so
  # the shell redirects the archive into it.
  defp stream(archive, ssh_args) do
    ssh = System.find_executable("ssh") || Mix.raise("ssh not found")

    {lines, status} =
      System.cmd("sh", ["-c", ~s(exec "$0" "$@" < "$CUBI_ARCHIVE"), ssh | ssh_args],
        env: [{"CUBI_ARCHIVE", archive}],
        stderr_to_stdout: true,
        into: %Cubi.Tools.Lines{}
      )

    {Cubi.Tools.Lines.lines(lines), status}
  end

  defp check_signed!(archive) do
    case Cubi.Pki.Archive.read(File.read!(archive)) do
      {:ok, %{"manifest.sig" => _, "signer.pem" => _}} -> :ok
      {:ok, _} -> Mix.raise("#{archive} is not signed: run `mix cubi.sign` first")
      {:error, reason} -> Mix.raise("#{archive} is not a cubi release: #{inspect(reason)}")
    end
  end

  defp newest!() do
    pattern = Path.join([Mix.Project.build_path(), "cubi", "*.tar.gz"])

    case Path.wildcard(pattern) do
      [] -> Mix.raise("no archive in #{Path.dirname(pattern)}: run `mix cubi.release` first")
      found -> Enum.max_by(found, &File.stat!(&1, time: :posix).mtime)
    end
  end
end
