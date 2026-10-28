defmodule Cubi.Tools.Release do
  @moduledoc """
  Turns a `mix release` into a cubi release archive for one base image
  (docs/specs.md §2.11.3).

  The image already runs a BEAM with its own applications, so the archive
  holds only what the image lacks. Each application of the release is one of:

    * **OTP's** (listed in OTP's `installed_application_versions`): never
      shipped. They come from the Nerves system and may carry NIFs built for
      the image's libc. The image must have them; their version may differ
      from the host's within the same OTP major.
    * **in the image at the same version**: left out, and recorded in the
      manifest's `requires`, so the node can check it runs that image.
    * **in the image at another version**: refused. Two versions of one
      application cannot be loaded at once.
    * **anything else**: shipped, `ebin/` and `priv/`.

  `elixir`, `logger` and the rest of Elixir follow the general rule, so the
  release must be compiled with the image's Elixir.

  Only the shipped applications' build-time configuration is kept from
  `sys.config`: the node applies it with `Application.put_all_env/1`, and
  configuration for one of the image's applications would change the image.
  """

  @type app :: %{name: String.t(), vsn: String.t()}
  @type plan :: %{ship: [app()], requires: %{String.t() => String.t()}}

  @doc """
  Sorts the release's applications against `base` (a decoded `base.json`).
  `otp_apps` are the names of OTP's applications. Returns every problem at
  once.
  """
  @spec plan([app()], map(), MapSet.t(String.t())) :: {:ok, plan()} | {:error, [String.t()]}
  def plan(apps, base, otp_apps) do
    image = Map.fetch!(base, "applications")

    {plan, errors} =
      Enum.reduce(apps, {%{ship: [], requires: %{}}, []}, fn %{name: name, vsn: vsn} = app,
                                                             {plan, errors} ->
        cond do
          name in otp_apps and Map.has_key?(image, name) ->
            {plan, errors}

          name in otp_apps ->
            {plan,
             [
               "#{name} is part of OTP and the image does not have it: add it to the firmware"
               | errors
             ]}

          image[name] == vsn ->
            {%{plan | requires: Map.put(plan.requires, name, vsn)}, errors}

          Map.has_key?(image, name) ->
            {plan, ["#{name} #{vsn} conflicts with #{image[name]} in the image" | errors]}

          true ->
            {%{plan | ship: [app | plan.ship]}, errors}
        end
      end)

    case errors do
      [] -> {:ok, %{plan | ship: Enum.sort_by(plan.ship, & &1.name)}}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Checks the host can build for `base`: the same OTP major.
  """
  @spec check_otp(map(), String.t()) :: :ok | {:error, String.t()}
  def check_otp(base, host_otp_release) do
    if base["otp_release"] == host_otp_release,
      do: :ok,
      else:
        {:error,
         "the image runs OTP #{base["otp_release"]}, this host #{host_otp_release}: build with OTP #{base["otp_release"]}"}
  end

  @doc """
  Splits `sys.config` terms into the configuration of `apps` and the
  application names whose configuration is dropped.
  """
  @spec split_config([{atom(), keyword()}], [String.t()]) ::
          {[{atom(), keyword()}], [atom()]}
  def split_config(sys_config, apps) do
    {kept, dropped} = Enum.split_with(sys_config, fn {app, _} -> Atom.to_string(app) in apps end)
    {kept, Enum.map(dropped, &elem(&1, 0))}
  end

  @doc """
  The manifest (§2.11.3) for `files`, a map of archive path to content.
  """
  @spec manifest(map()) :: map()
  def manifest(opts) do
    %{
      "format" => 1,
      "name" => opts.name,
      "version" => opts.version,
      "otp_release" => opts.base["otp_release"],
      "erts_version" => opts.base["erts_version"],
      "applications" => Enum.map(opts.ship, &%{"name" => &1.name, "vsn" => &1.vsn}),
      "requires" => opts.requires,
      "start" => opts.start,
      "files" =>
        Map.new(opts.files, fn {path, data} ->
          {path, :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)}
        end)
    }
  end

  @doc """
  Builds the archive from an assembled `mix release` in `rel_dir`. Options:

    * `:base` (required) - the decoded `base.json`
    * `:name`, `:version` (required) - the release's
    * `:start` (required) - application names to start, in order
    * `:otp_apps` (required) - OTP's application names
    * `:output` (required) - the `.tar.gz` to write

  Returns `{:ok, %{plan: plan, dropped_config: [atom()]}}` or the errors of
  `plan/3`.
  """
  @spec pack(Path.t(), keyword()) ::
          {:ok, %{plan: plan(), dropped_config: [atom()]}} | {:error, [String.t()]}
  def pack(rel_dir, opts) do
    name = Keyword.fetch!(opts, :name)
    version = Keyword.fetch!(opts, :version)
    base = Keyword.fetch!(opts, :base)
    releases = Path.join([rel_dir, "releases", version])

    with {:ok, plan} <-
           plan(
             rel_apps(Path.join(releases, "#{name}.rel")),
             base,
             Keyword.fetch!(opts, :otp_apps)
           ) do
      {:ok, sys_config} = :file.consult(String.to_charlist(Path.join(releases, "sys.config")))
      {config, dropped} = split_config(List.first(sys_config, []), Enum.map(plan.ship, & &1.name))

      files =
        plan.ship
        |> Enum.flat_map(&app_files(rel_dir, &1))
        |> Map.new()
        |> Map.put("releases/#{version}/sys.config", sys_config(config))

      manifest =
        manifest(%{
          name: name,
          version: version,
          base: base,
          ship: plan.ship,
          requires: plan.requires,
          start: Keyword.fetch!(opts, :start),
          files: files
        })

      Cubi.Pki.Archive.write!(
        Keyword.fetch!(opts, :output),
        Map.put(files, "manifest.json", IO.iodata_to_binary([:json.format(manifest), "\n"]))
      )

      {:ok, %{plan: plan, dropped_config: dropped}}
    end
  end

  @doc "OTP's application names on this host."
  @spec host_otp_apps() :: MapSet.t(String.t())
  def host_otp_apps() do
    [
      :code.root_dir(),
      "releases",
      :erlang.system_info(:otp_release),
      "installed_application_versions"
    ]
    |> Path.join()
    |> File.read!()
    |> String.split()
    |> MapSet.new(fn app_vsn -> app_vsn |> String.split("-") |> hd() end)
  end

  defp rel_apps(rel_file) do
    {:ok, [{:release, _, _, apps}]} = :file.consult(String.to_charlist(rel_file))
    for {name, vsn, _type} <- apps, do: %{name: Atom.to_string(name), vsn: to_string(vsn)}
  end

  defp app_files(rel_dir, %{name: name, vsn: vsn}) do
    dir = "lib/#{name}-#{vsn}"

    for sub <- ["ebin", "priv"],
        path <- Path.wildcard(Path.join([rel_dir, dir, sub, "**"]), match_dot: true),
        File.regular?(path) do
      {Path.relative_to(path, rel_dir), File.read!(path)}
    end
  end

  defp sys_config(config) do
    "%% coding: utf-8\n" <> :unicode.characters_to_binary(:io_lib.format(~c"~tp.~n", [config]))
  end
end
