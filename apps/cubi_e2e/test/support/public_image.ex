defmodule Cubi.E2E.PublicImage do
  @moduledoc """
  A second public image for upgrade tests (docs/milestone2.md): a copy of
  the public directory whose rootfs differs only by its firmware UUID, in
  `/etc/firmware.kv`, with `base.json` and `SHA256SUMS` to match. What a
  node reports after `mix cubi.upgrade` is then the copy's UUID. Unsigned:
  stock iPXE does not check signatures, and nothing else reads them.
  """

  @doc "Writes the copy into `dest` and returns its firmware UUID."
  @spec variant!(Path.t(), Path.t()) :: String.t()
  def variant!(source, dest) do
    File.rm_rf!(dest)
    File.mkdir_p!(dest)

    for name <- ~w(vmlinuz stage1.cpio.zst),
        do: File.cp!(Path.join(source, name), Path.join(dest, name))

    work = Path.join(dest, ".work")
    root = Path.join(work, "root")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("unsquashfs", ["-n", "-d", root, Path.join(source, "rootfs.squashfs")])

    uuid = uuid()
    kv = Path.join(root, "etc/firmware.kv")

    File.write!(
      kv,
      Regex.replace(~r/^a\.nerves_fw_uuid=.*$/m, File.read!(kv), "a.nerves_fw_uuid=#{uuid}")
    )

    {_, 0} =
      System.cmd("mksquashfs", [
        root,
        Path.join(dest, "rootfs.squashfs"),
        "-all-root",
        "-noappend",
        "-quiet"
      ])

    File.rm_rf!(work)

    base = source |> Path.join("base.json") |> File.read!() |> JSON.decode!()

    File.write!(
      Path.join(dest, "base.json"),
      JSON.encode!(put_in(base, ["firmware", "uuid"], uuid))
    )

    File.write!(
      Path.join(dest, "SHA256SUMS"),
      for name <- dest |> File.ls!() |> Enum.sort(), name != "SHA256SUMS" do
        sum =
          :crypto.hash(:sha256, File.read!(Path.join(dest, name))) |> Base.encode16(case: :lower)

        "#{sum}  #{name}\n"
      end
    )

    uuid
  end

  defp uuid() do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> =
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end
end
