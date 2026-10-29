defmodule Mix.Tasks.Firmware.Publish do
  @shortdoc "Stages the public image for upload, after checking it"
  @moduledoc """
  Stages the public image `mix firmware.ipxe --public` built for upload
  (docs/specs.md §2.12.1, `Cubi.Ipxe.Publish`):

      MIX_TARGET=x86_64 MIX_ENV=public mix firmware.publish --ca DIR [--out DIR]
                                                             [--release [--repo OWNER/NAME]]

    * `--ca DIR` - the cubi project's PKI directory (`mix cubi.gen_ca`):
      every `.sig` must verify against its root. Required: an unsigned image
      is never published
    * `--out DIR` - where `<version>/` goes, default `_build/publish`
    * `--release` - then publish it as the GitHub release `v<version>` of
      `--repo` (default `jeanparpaillon/cubi`), with `gh`: the default image
      location of `mix cubi.boot_script`. The tag is put on the current
      commit, which must be clean and pushed to `origin`, so a release always
      names the source it was built from

  Reads `_build/<target>_public/ipxe/`, checks it (signed by the project's
  root, `SHA256SUMS`, no CA nor ssh login in the rootfs), and copies it to
  `<out>/<version>/`, the version being the firmware's. A version already
  staged is refused.

  Without `--release`, upload every file of `<out>/<version>/`, unchanged,
  wherever `config :cubi_tools, :image_base` of the operators points. Never
  replace a published file. Signing needs the project's offline key, so this
  stays a manual step, never CI's.
  """
  use Mix.Task

  @repo "jeanparpaillon/cubi"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [ca: :string, out: :string, release: :boolean, repo: :string]
      )

    commit = if opts[:release], do: releasable_commit!()

    ca_dir = opts[:ca] || Mix.raise("--ca DIR is required: the cubi project's PKI directory")
    ca_cert = Cubi.Pki.paths(Path.expand(ca_dir)).ca_cert

    if not File.regular?(ca_cert),
      do: Mix.raise("no #{ca_cert}: --ca names a `mix cubi.gen_ca` directory")

    from = Path.join(Mix.Project.build_path(), "ipxe")
    out = Path.expand(opts[:out] || Path.join([Mix.Project.build_path(), "..", "publish"]))

    {version, dir} =
      try do
        Cubi.Ipxe.Publish.stage!(from, out, ca_cert)
      rescue
        e in [RuntimeError, File.Error] -> Mix.raise(Exception.message(e))
      end

    Mix.shell().info("""
    cubi image #{version} staged in #{Path.relative_to_cwd(dir)}:
      #{Enum.join(Cubi.Ipxe.Publish.files() ++ ["SHA256SUMS"], " ")}
    """)

    if commit, do: release!(opts[:repo] || @repo, version, dir, ca_cert, commit)
  end

  @doc false
  # `gh release create`'s arguments: tag v<version> on `commit`, the staged
  # files as assets.
  def gh_args(repo, version, dir, notes_file, commit) do
    ["release", "create", "v" <> version, "--repo", repo, "--target", commit] ++
      ["--title", "cubi image #{version}", "--notes-file", notes_file] ++
      Enum.map(Cubi.Ipxe.Publish.files() ++ ["SHA256SUMS"], &Path.join(dir, &1))
  end

  defp release!(repo, version, dir, ca_cert, commit) do
    gh = System.find_executable("gh") || Mix.raise("--release needs the GitHub CLI, gh")

    notes =
      Path.join(System.tmp_dir!(), "cubi-release-notes-#{System.unique_integer([:positive])}")

    File.write!(notes, """
    Public cubi image #{version}, built from #{commit}: kernel, stage-1 and rootfs, \
    with no CA and no ssh key inside (docs/specs.md §2.12.1). Boot it with a \
    private script from `mix cubi.boot_script --image #{version}`.

    Signed by the cubi project's root, SHA-256 `#{root_fingerprint(ca_cert)}`.

    ```
    #{String.trim_trailing(File.read!(Path.join(dir, "SHA256SUMS")))}
    ```
    """)

    try do
      case System.cmd(gh, gh_args(repo, version, dir, notes, commit), stderr_to_stdout: true) do
        {out, 0} -> Mix.shell().info("released: #{String.trim(out)}")
        {out, status} -> Mix.raise("gh release create exited #{status}: #{String.trim(out)}")
      end
    after
      File.rm(notes)
    end
  end

  # The commit a release is tagged on: the working tree clean, and the
  # commit already on origin, or the tag would point at something else.
  defp releasable_commit!() do
    {status, 0} = System.cmd("git", ["status", "--porcelain"])
    if status != "", do: Mix.raise("--release: the working tree has changes; commit them first")

    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    commit = String.trim(commit)

    case System.cmd("git", ["branch", "-r", "--contains", commit], stderr_to_stdout: true) do
      {out, 0} when out != "" -> commit
      _ -> Mix.raise("--release: #{commit} is not on origin yet; push it first")
    end
  end

  defp root_fingerprint(ca_cert) do
    {:ok, hex} = Cubi.Pki.cert_sha256(File.read!(ca_cert))
    hex
  end
end
