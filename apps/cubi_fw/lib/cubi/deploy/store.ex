defmodule Cubi.Deploy.Store do
  @moduledoc """
  Deployed releases on disk (docs/specs.md §2.11.6), under a root that is
  `/cubi/releases` on a node:

      state.json          {"current": vsn | null, "previous": vsn | null, "bad": [vsn]}
      <version>/          the archive unpacked, its manifest, signature and
                          signer included, so it can be verified again
      incoming/           an archive being received

  `state.json` is written to a temporary file and renamed, so a power loss
  leaves the old state or the new one, never half of either.
  """

  @type state :: %{current: String.t() | nil, previous: String.t() | nil, bad: [String.t()]}

  @empty %{current: nil, previous: nil, bad: []}

  @spec state(Path.t()) :: state()
  def state(root) do
    case File.read(Path.join(root, "state.json")) do
      {:ok, json} ->
        map = JSON.decode!(json)
        %{current: map["current"], previous: map["previous"], bad: map["bad"] || []}

      {:error, :enoent} ->
        @empty
    end
  end

  @spec put_state!(Path.t(), state()) :: :ok
  def put_state!(root, state) do
    path = Path.join(root, "state.json")

    json =
      JSON.encode!(%{
        "current" => state.current,
        "previous" => state.previous,
        "bad" => state.bad
      })

    File.write!(path <> ".tmp", json)
    File.rename!(path <> ".tmp", path)
  end

  @spec version_dir(Path.t(), String.t()) :: Path.t()
  def version_dir(root, version), do: Path.join(root, version)

  @spec incoming_dir(Path.t()) :: Path.t()
  def incoming_dir(root), do: Path.join(root, "incoming")

  @doc """
  Writes `entries` (`Cubi.Pki.Archive`) as `<root>/<version>/`, replacing any
  leftover of an earlier attempt. Unpacked next to it first, then renamed.
  """
  @spec unpack!(Path.t(), String.t(), Cubi.Pki.Archive.entries()) :: Path.t()
  def unpack!(root, version, entries) do
    dir = version_dir(root, version)
    tmp = dir <> ".unpacking"
    File.rm_rf!(tmp)

    for {path, data} <- entries do
      target = Path.join(tmp, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, data)
    end

    File.rm_rf!(dir)
    File.rename!(tmp, dir)
    dir
  end

  @doc "Reads `<root>/<version>/` back as archive entries, to verify it again."
  @spec entries(Path.t(), String.t()) :: {:ok, Cubi.Pki.Archive.entries()} | {:error, term()}
  def entries(root, version) do
    dir = version_dir(root, version)

    if File.dir?(dir) do
      entries =
        for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
            File.regular?(path),
            into: %{},
            do: {Path.relative_to(path, dir), File.read!(path)}

      {:ok, entries}
    else
      {:error, {:no_such_version, version}}
    end
  end

  @doc "Deletes every version directory but `keep`, and anything left unpacking."
  @spec prune!(Path.t(), [String.t() | nil]) :: :ok
  def prune!(root, keep) do
    keep = MapSet.new(["incoming" | Enum.reject(keep, &is_nil/1)])

    for name <- File.ls!(root),
        File.dir?(Path.join(root, name)),
        name not in keep,
        do: File.rm_rf!(Path.join(root, name))

    :ok
  end
end
