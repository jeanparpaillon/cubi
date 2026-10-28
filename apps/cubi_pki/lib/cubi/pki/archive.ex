defmodule Cubi.Pki.Archive do
  @moduledoc """
  A cubi release archive (docs/specs.md §2.11.3, §2.11.4): a gzipped tar of
  `manifest.json`, the files it hashes and, once signed, `manifest.sig` and
  `signer.pem`.

  Reading, writing and checking it live here, next to `Cubi.Pki`, because both
  sides need them: `mix cubi.release` and `mix cubi.sign` on the host, the
  deploy on the node. Everything is read into memory: a release is small, and
  nothing reaches the disk before it is verified.
  """

  @manifest "manifest.json"
  @signature "manifest.sig"
  @signer "signer.pem"

  @type entries :: %{String.t() => binary()}

  @doc "The members that are not files of the release."
  @spec meta_members() :: [String.t()]
  def meta_members(), do: [@manifest, @signature, @signer]

  @doc """
  Reads an archive into `%{path => content}`. Refuses anything but regular
  files with safe paths: relative, no `.` or `..` component, no duplicates.
  """
  @spec read(binary()) :: {:ok, entries()} | {:error, term()}
  def read(data) do
    with {:ok, table} <- :erl_tar.table({:binary, data}, [:compressed, :verbose]),
         :ok <- check_members(table),
         {:ok, files} <- :erl_tar.extract({:binary, data}, [:compressed, :memory]) do
      {:ok, Map.new(files, fn {name, content} -> {to_string(name), content} end)}
    else
      {:error, {:bad_member, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:bad_archive, reason}}
    end
  end

  @spec read!(Path.t()) :: entries()
  def read!(path) do
    case read(File.read!(path)) do
      {:ok, entries} -> entries
      {:error, reason} -> raise "#{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Writes `entries` as an archive at `path`: `manifest.json` first, then the
  signature and the signer if present, then the files in path order.
  """
  @spec write!(Path.t(), entries()) :: :ok
  def write!(path, entries) do
    {meta, files} = Map.split(entries, meta_members())

    ordered =
      for(name <- meta_members(), Map.has_key?(meta, name), do: {name, meta[name]}) ++
        Enum.sort(files)

    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"

    :ok =
      :erl_tar.create(
        String.to_charlist(tmp),
        for({name, data} <- ordered, do: {String.to_charlist(name), IO.iodata_to_binary(data)}),
        [:compressed]
      )

    File.rename!(tmp, path)
  end

  @doc "The decoded manifest."
  @spec manifest(entries()) :: {:ok, map()} | {:error, term()}
  def manifest(entries) do
    with {:ok, json} <- Map.fetch(entries, @manifest) |> or_error(:no_manifest),
         {:ok, %{"files" => files} = manifest} when is_map(files) <- decode(json) do
      {:ok, manifest}
    else
      {:ok, _} -> {:error, :bad_manifest}
      error -> error
    end
  end

  @doc """
  Step 3 of §2.11.4: the archive holds exactly the manifest's files, besides
  its own members, and each matches its SHA-256.
  """
  @spec check_files(entries(), map()) :: :ok | {:error, term()}
  def check_files(entries, %{"files" => hashes}) do
    present = entries |> Map.drop(meta_members()) |> Map.keys() |> MapSet.new()
    listed = hashes |> Map.keys() |> MapSet.new()

    cond do
      (missing = MapSet.difference(listed, present)) != MapSet.new() ->
        {:error, {:missing_files, Enum.sort(missing)}}

      (extra = MapSet.difference(present, listed)) != MapSet.new() ->
        {:error, {:unlisted_files, Enum.sort(extra)}}

      true ->
        case Enum.reject(hashes, fn {path, hash} -> sha256(entries[path]) == hash end) do
          [] -> :ok
          bad -> {:error, {:hash_mismatch, bad |> Enum.map(&elem(&1, 0)) |> Enum.sort()}}
        end
    end
  end

  @doc """
  Adds `manifest.sig` and `signer.pem` for `signer` (`Cubi.Pki.load_signer!/1`),
  replacing any previous signature. Refuses an archive whose files do not match
  its manifest: signing would vouch for them.
  """
  @spec sign(entries(), Cubi.Pki.signer()) :: {:ok, entries()} | {:error, term()}
  def sign(entries, signer) do
    with {:ok, manifest} <- manifest(entries),
         :ok <- check_files(entries, manifest) do
      {signature, pem} = Cubi.Pki.sign(entries[@manifest], signer)
      {:ok, Map.merge(entries, %{@signature => signature, @signer => pem})}
    end
  end

  @doc """
  Steps 1 to 3 of §2.11.4 against the root certificate `ca_pem`: the signer,
  the signature over `manifest.json`, then the files. Returns the manifest.
  `opts` go to `Cubi.Pki.verify/5` (`:check_dates`).
  """
  @spec verify(entries(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(entries, ca_pem, opts \\ []) do
    with {:ok, signature} <- Map.fetch(entries, @signature) |> or_error(:unsigned),
         {:ok, pem} <- Map.fetch(entries, @signer) |> or_error(:unsigned),
         {:ok, json} <- Map.fetch(entries, @manifest) |> or_error(:no_manifest),
         :ok <- Cubi.Pki.verify(json, signature, pem, ca_pem, opts),
         {:ok, manifest} <- manifest(entries),
         :ok <- check_files(entries, manifest) do
      {:ok, manifest}
    end
  end

  defp check_members(table) do
    names = for {name, _type, _, _, _, _, _} <- table, do: to_string(name)

    bad =
      Enum.find(table, fn {name, type, _, _, _, _, _} ->
        type != :regular or not safe_path?(to_string(name))
      end)

    cond do
      bad != nil -> {:error, {:bad_member, bad |> elem(0) |> to_string()}}
      length(names) != length(Enum.uniq(names)) -> {:error, {:bad_member, :duplicate}}
      true -> :ok
    end
  end

  defp safe_path?(path) do
    parts = String.split(path, "/")
    path != "" and Path.type(path) == :relative and Enum.all?(parts, &(&1 not in ["", ".", ".."]))
  end

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, :bad_manifest}
    end
  end

  defp or_error({:ok, _} = ok, _), do: ok
  defp or_error(:error, reason), do: {:error, reason}

  defp sha256(nil), do: nil
  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
