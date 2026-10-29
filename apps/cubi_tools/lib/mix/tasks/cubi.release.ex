defmodule Mix.Tasks.Cubi.Release do
  @shortdoc "Builds a cubi release archive for a base image"
  @moduledoc """
  Runs `mix release`, then packs what the base image lacks into
  `_build/<env>/cubi/<name>-<version>.tar.gz` with its `manifest.json`
  (docs/specs.md §2.11.3, `Cubi.Tools.Release`):

      MIX_ENV=prod mix cubi.release --base DIR|URL [RELEASE]

    * `--base DIR|URL` - a served directory (`mix firmware.ipxe`), local or
      a public image's `https://` URL (docs/specs.md §2.12.1); its
      `base.json` says what the image ships. A URL's is checked against the
      `SHA256SUMS` next to it (`Cubi.Tools.Image`)
    * `RELEASE` - the release to build, as for `mix release`

  Refuses, listing every reason, when the host's OTP major is not the
  image's, when an application is in the image at another version, or when
  the release needs an OTP application the image lacks. Configuration for the
  image's applications is dropped with a warning; `config/runtime.exs` is not
  run on the node. The archive is unsigned: `mix cubi.sign` next.
  """
  use Mix.Task

  alias Cubi.Tools.Release

  @switches [base: :string]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: @switches)

    source =
      opts[:base] ||
        Mix.raise(
          "--base DIR|URL is required: a `mix firmware.ipxe` directory, or its https:// URL"
        )

    base = read_base!(source)

    with {:error, message} <-
           Release.check_otp(base, to_string(:erlang.system_info(:otp_release))),
         do: Mix.raise(message)

    if File.exists?("config/runtime.exs"),
      do: warn("config/runtime.exs is not run on a cubi node: only build-time config is packed")

    rel_dir = Path.join([Mix.Project.build_path(), "cubi", "rel"])
    File.rm_rf!(rel_dir)
    Mix.Task.run("release", rest ++ ["--path", rel_dir, "--overwrite", "--quiet"])

    {name, version} = release_id!(rel_dir)
    output = Path.join([Mix.Project.build_path(), "cubi", "#{name}-#{version}.tar.gz"])

    result =
      Release.pack(rel_dir,
        base: base,
        name: name,
        version: version,
        start: start_apps(),
        otp_apps: Release.host_otp_apps(),
        output: output
      )

    File.rm_rf!(rel_dir)

    case result do
      {:ok, %{plan: plan, dropped_config: dropped}} ->
        if dropped != [],
          do: warn("configuration dropped, it belongs to the image: #{Enum.join(dropped, ", ")}")

        Mix.shell().info("""
        #{name} #{version} for #{get_in(base, ["firmware", "product"])} #{get_in(base, ["firmware", "version"])}: #{Path.relative_to_cwd(output)}
          ships:    #{Enum.map_join(plan.ship, " ", &"#{&1.name}-#{&1.vsn}")}
          requires: #{map_size(plan.requires)} applications of the image
        Unsigned: run `mix cubi.sign #{Path.relative_to_cwd(output)}`.
        """)

      {:error, errors} ->
        Mix.raise("cannot build for this image:\n" <> Enum.map_join(errors, "\n", &"  * #{&1}"))
    end
  end

  defp read_base!(source) do
    case Cubi.Tools.Image.base(source) do
      {:ok, base} ->
        base

      {:error, {:not_https, url}} ->
        Mix.raise("--base #{url}: only https:// URLs, HTTPS is what vouches for the image")

      {:error, {:fetch_failed, where, :enoent}} ->
        Mix.raise("no #{where}: --base names a `mix firmware.ipxe` directory")

      {:error, reason} ->
        Mix.raise("--base #{source}: #{inspect(reason)}")
    end
  end

  # releases/start_erl.data is "ERTS_VSN REL_VSN"; the .rel file is named
  # after the release.
  defp release_id!(rel_dir) do
    [_erts, version] =
      rel_dir |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()

    [rel] = Path.wildcard(Path.join([rel_dir, "releases", version, "*.rel"]))
    {Path.basename(rel, ".rel"), version}
  end

  # The project's own applications: what the node starts (§2.11.3).
  defp start_apps() do
    case Mix.Project.apps_paths() do
      nil -> [to_string(Mix.Project.config()[:app])]
      apps -> apps |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    end
  end

  defp warn(message), do: Mix.shell().info([:yellow, "warning: ", :reset, message])
end
