defmodule Cubi.Ipxe.Publish do
  @moduledoc """
  Stages a public image for publishing (docs/specs.md §2.12.1): the output
  of `mix firmware.ipxe --public --signer <project PKI>`, checked, copied to
  `<out>/<version>/`, ready to upload as is under the project's image URL.

  Refused unless every check passes:

    * every file a node or `mix cubi.release --base` reads is there:
      `vmlinuz`, `stage1.cpio.zst`, `rootfs.squashfs`, `base.json`, and the
      three `.sig` files: an unsigned image is never published;
    * each matches the build's `SHA256SUMS`;
    * each `.sig` verifies against the project's root (`openssl cms`, as
      iPXE's `imgverify` would);
    * the rootfs is public: no CA, no ssh login (`Cubi.Ipxe.check_public!/1`);
    * `<out>/<version>/` does not exist yet. A published version is never
      replaced: operators' scripts pin its rootfs, and a node would refuse
      the new one.

  `boot.ipxe` is left out: a public script without pins would only invite
  unpinned boots. `SHA256SUMS` is written again for the published files.
  """

  @images ~w(vmlinuz stage1.cpio.zst rootfs.squashfs)
  @files @images ++ ~w(base.json) ++ Enum.map(@images, &(&1 <> ".sig"))

  @doc "The files a published version holds, `SHA256SUMS` aside."
  @spec files() :: [String.t()]
  def files(), do: @files

  @doc """
  Checks the directory `from` and copies it to `<to>/<version>/`, `version`
  being its `base.json`'s firmware version. `ca_cert` is the project's root.
  Returns `{version, dir}`; raises with the reason otherwise.
  """
  @spec stage!(Path.t(), Path.t(), Path.t()) :: {String.t(), Path.t()}
  def stage!(from, to, ca_cert) do
    missing =
      for name <- ["SHA256SUMS" | @files], not File.regular?(Path.join(from, name)), do: name

    cond do
      Enum.any?(missing, &String.ends_with?(&1, ".sig")) ->
        raise "#{from} is not signed (no #{Enum.join(missing, ", ")}): " <>
                "build it with --signer, the project's PKI"

      missing != [] ->
        raise "#{from} lacks #{Enum.join(missing, ", ")}: not a `mix firmware.ipxe` directory"

      true ->
        :ok
    end

    check_sums!(from)

    for image <- @images do
      sig = Path.join(from, image <> ".sig")

      case Cubi.Pki.Cms.verify(Path.join(from, image), sig, ca_cert) do
        :ok -> :ok
        {:error, why} -> raise "#{image}.sig does not verify against #{ca_cert}: #{why}"
      end
    end

    version = version!(from)
    dest = Path.join(to, version)
    if File.exists?(dest), do: raise("#{dest} exists: a published version is never replaced")

    tmp = dest <> ".staging"
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    try do
      Cubi.Ipxe.check_public_rootfs!(Path.join(from, "rootfs.squashfs"), Path.join(tmp, ".work"))
      File.rm_rf!(Path.join(tmp, ".work"))
      for name <- @files, do: File.cp!(Path.join(from, name), Path.join(tmp, name))
      File.write!(Path.join(tmp, "SHA256SUMS"), sums(tmp, @files))
      File.rename!(tmp, dest)
    after
      File.rm_rf!(tmp)
    end

    {version, dest}
  end

  defp check_sums!(from) do
    listed =
      for line <-
            from |> Path.join("SHA256SUMS") |> File.read!() |> String.split("\n", trim: true),
          [hex, name] <- [String.split(line, ~r/ [ *]/, parts: 2)],
          into: %{},
          do: {name, String.downcase(hex)}

    for name <- @files do
      actual = sha256(Path.join(from, name))

      case Map.fetch(listed, name) do
        {:ok, ^actual} -> :ok
        {:ok, _} -> raise "#{name} does not match #{from}/SHA256SUMS"
        :error -> raise "#{name} is not in #{from}/SHA256SUMS"
      end
    end
  end

  defp version!(from) do
    case from |> Path.join("base.json") |> File.read!() |> JSON.decode() do
      {:ok, %{"firmware" => %{"version" => version}}} when is_binary(version) ->
        if version =~ ~r/\A[0-9A-Za-z.+-]+\z/,
          do: version,
          else: raise("base.json: firmware version #{inspect(version)} cannot name a directory")

      _ ->
        raise "#{from}/base.json names no firmware version"
    end
  end

  defp sums(dir, names) do
    for name <- Enum.sort(names), do: [sha256(Path.join(dir, name)), "  ", name, "\n"]
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end
