defmodule Cubi.DeployFixtures do
  @moduledoc """
  Signed release archives built in the test, around one tiny application
  compiled on the spot, for `Cubi.Deploy` on the host.

  `behaviour` is what the application does:

    * `:ok` - starts and keeps running
    * `:crash_on_start` - `start/2` returns an error
    * `:crash_later` - its only child exits after 300 ms, taking the
      application down
  """

  alias Cubi.Pki.Archive

  @doc """
  An archive for release `name` (and application `app`), version `vsn`,
  signed by the signer in `pki`. Options: `:otp_release`, `:requires`,
  `:sign` (default `true`), `:ca` (a PKI directory whose root is added as the
  archive's `ca.pem`).
  """
  @spec archive(String.t(), String.t(), String.t(), atom(), Path.t(), keyword()) :: binary()
  def archive(name, app, vsn, behaviour, pki, opts \\ []) do
    files = app_files(app, vsn, behaviour)

    manifest = %{
      "format" => 1,
      "name" => name,
      "version" => vsn,
      "otp_release" =>
        Keyword.get(opts, :otp_release, to_string(:erlang.system_info(:otp_release))),
      "erts_version" => to_string(:erlang.system_info(:version)),
      "applications" => [%{"name" => app, "vsn" => vsn}],
      "requires" => Keyword.get(opts, :requires, %{}),
      "start" => [app],
      "files" =>
        Map.new(files, fn {p, d} ->
          {p, :crypto.hash(:sha256, d) |> Base.encode16(case: :lower)}
        end)
    }

    entries = Map.put(files, "manifest.json", JSON.encode!(manifest))

    entries =
      if Keyword.get(opts, :sign, true) do
        {:ok, signed} = Archive.sign(entries, Cubi.Pki.load_signer!(pki))
        signed
      else
        entries
      end

    entries =
      case Keyword.get(opts, :ca) do
        nil -> entries
        dir -> Map.put(entries, "ca.pem", File.read!(Cubi.Pki.paths(dir).ca_cert))
      end

    path =
      Path.join(System.tmp_dir!(), "cubi_fixture_#{System.unique_integer([:positive])}.tar.gz")

    Archive.write!(path, entries)
    data = File.read!(path)
    File.rm!(path)
    data
  end

  @doc "The module of a fixture application."
  @spec module(String.t()) :: module()
  def module(app), do: Module.concat(["CubiFixture", Macro.camelize(app)])

  @doc "Stops, unloads and purges a fixture application, whatever its state."
  @spec cleanup(String.t()) :: :ok
  def cleanup(app) do
    atom = String.to_atom(app)
    _ = Application.stop(atom)
    _ = Application.unload(atom)
    mod = module(app)
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
    :ok
  end

  defp app_files(app, vsn, behaviour) do
    mod = module(app)
    # Each version compiles the same module: that is the point, not a mistake.
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    [{^mod, beam}] = Code.compile_string(source(mod, vsn, behaviour))
    Code.put_compiler_option(:ignore_module_conflict, previous)
    # Compiling loads it; the deploy must load it from the release instead.
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)

    app_term =
      {:application, String.to_atom(app),
       [
         description: ~c"cubi deploy fixture",
         vsn: String.to_charlist(vsn),
         modules: [mod],
         registered: [],
         applications: [:kernel, :stdlib, :elixir],
         mod: {mod, []}
       ]}

    ebin = "lib/#{app}-#{vsn}/ebin"

    %{
      "#{ebin}/#{app}.app" => IO.iodata_to_binary(:io_lib.format(~c"~p.~n", [app_term])),
      "#{ebin}/#{mod}.beam" => beam,
      "releases/#{vsn}/sys.config" =>
        IO.iodata_to_binary(:io_lib.format(~c"~p.~n", [[{String.to_atom(app), [greeting: vsn]}]]))
    }
  end

  defp source(mod, vsn, behaviour) do
    start =
      case behaviour do
        :ok ->
          "Supervisor.start_link([], strategy: :one_for_one)"

        :crash_on_start ->
          "{:error, :boom}"

        :crash_later ->
          """
          Supervisor.start_link(
            [Supervisor.child_spec({Task, fn -> Process.sleep(300); exit(:boom) end}, restart: :permanent)],
            strategy: :one_for_one, max_restarts: 0)
          """
      end

    """
    defmodule #{inspect(mod)} do
      use Application
      def start(_type, _args), do: #{start}
      def version, do: #{inspect(vsn)}
    end
    """
  end
end
