defmodule Cubi.E2E.Disk do
  @moduledoc """
  Disk fixtures for `Cubi.E2E.VM` specs (docs/testing.md §5).

  A disk is `{bus, serial, kind}`, `bus` `:virtio` or `:nvme`. QEMU gets the
  serial explicitly, so the guest's sysfs, and with it the by-id-style names
  of `cubi.vdevs=`, are known in advance. `kind` is

    * `:blank` - an empty qcow2 image;
    * `:dirty` - an image with a GPT written by `sfdisk`, one partition over
      the whole disk: what pool creation must refuse;
    * a path - an image of the test's own making, used as is.

  The image of a `:blank` or `:dirty` disk is `disk-<serial>.qcow2` in the
  VM's directory. It is made when missing and kept otherwise, so a restarted
  VM finds its disks, and its pool, as it left them. `discard!/2` before a
  restart gives a fresh blank disk under the same serial: a disk swap.

  Images are 8G, sparse: `<pool>/cubi` alone reserves 4G.
  """

  @size "8G"

  @type kind :: :blank | :dirty | Path.t()
  @type t :: {:virtio | :nvme, serial :: String.t(), kind()}

  @doc "Where the disk's image is; a relative path is relative to `dir`."
  @spec path(Path.t(), String.t(), kind()) :: Path.t()
  def path(_dir, _serial, path) when is_binary(path), do: path
  def path(dir, serial, kind) when kind in [:blank, :dirty], do: Path.join(dir, file(serial))

  @doc "Makes the image if missing. A path kind is left alone."
  @spec prepare!(Path.t(), t()) :: :ok
  def prepare!(_dir, {_bus, _serial, path}) when is_binary(path), do: :ok

  def prepare!(dir, {_bus, serial, kind}) do
    image = path(dir, serial, kind)
    if not File.exists?(image), do: create!(image, kind)
    :ok
  end

  @doc "Deletes a disk's image, so that the next start makes a fresh one."
  @spec discard!(Path.t(), String.t()) :: :ok
  def discard!(dir, serial) do
    File.rm!(Path.join(dir, file(serial)))
    :ok
  end

  @doc """
  The SHA-256 of an image file, to check that a guest did not write to it.
  A qcow2 file only changes when the guest writes.
  """
  @spec digest!(Path.t()) :: String.t()
  def digest!(image) do
    File.stream!(image, 1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp file(serial), do: "disk-#{serial}.qcow2"

  defp create!(image, :blank), do: qemu_img!(["create", "-q", "-f", "qcow2", image, @size])

  # sfdisk can't write into a qcow2: partition a sparse raw file, convert it.
  # Its script comes on stdin, which System.cmd can't feed: a shell redirects.
  defp create!(image, :dirty) do
    raw = image <> ".raw"
    script = image <> ".sfdisk"

    try do
      qemu_img!(["create", "-q", "-f", "raw", raw, @size])
      File.write!(script, "label: gpt\n,,L\n")

      {_, 0} =
        System.cmd("sh", ["-c", ~S(sfdisk --quiet "$1" < "$2"), "sh", raw, script],
          stderr_to_stdout: true
        )

      qemu_img!(["convert", "-q", "-f", "raw", "-O", "qcow2", raw, image])
    after
      File.rm(raw)
      File.rm(script)
    end
  end

  defp qemu_img!(args) do
    case System.cmd("qemu-img", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> raise "qemu-img #{Enum.join(args, " ")}: exit #{status}: #{out}"
    end
  end
end
