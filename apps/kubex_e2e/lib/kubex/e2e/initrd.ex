defmodule Kubex.E2E.Initrd do
  @moduledoc """
  Assembles the single initrd file that QEMU's `-initrd` takes, the way iPXE
  hands several initrds to the kernel (docs/specs.md §2.2).

  Each part is either a file, passed through as is (a cpio archive, possibly
  compressed), or `{name, contents, mode}`: a file wrapped on the fly in a newc
  header under `name`, like iPXE's `initrd <url> <name> mode=…`. Every part
  starts on a 4-byte boundary: the kernel silently ignores a cpio that follows
  a compressed one unaligned (docs/phase0.md).

  The kernel does not create parent directories, so a named part such as
  `/kubex/token` needs its directory in an earlier part (stage-1 ships an
  empty `/kubex`).
  """

  @type part ::
          Path.t()
          | {name :: String.t(), contents :: iodata() | {:file, Path.t()},
             mode :: non_neg_integer()}

  @doc "Writes the parts, in order, to `output`."
  @spec assemble!([part()], Path.t()) :: Path.t()
  def assemble!(parts, output) do
    data = Enum.map(parts, &part/1)
    File.write!(output, data)
    output
  end

  defp part(path) when is_binary(path), do: path |> File.read!() |> pad()

  defp part({name, {:file, path}, mode}), do: part({name, File.read!(path), mode})

  defp part({"/" <> name, contents, mode}) do
    contents = IO.iodata_to_binary(contents)

    [entry(name, 0o100000 + mode, contents), entry("TRAILER!!!", 0, "")]
    |> IO.iodata_to_binary()
    |> pad()
  end

  defp entry(name, mode, body) do
    name0 = name <> <<0>>

    fields =
      [1, mode, 0, 0, 1, 0, byte_size(body), 0, 0, 0, 0, byte_size(name0), 0]
      |> Enum.map(&(&1 |> Integer.to_string(16) |> String.pad_leading(8, "0")))

    header = IO.iodata_to_binary(["070701", fields, name0])
    [header, zeros(byte_size(header)), body, zeros(byte_size(body))]
  end

  defp pad(data) when is_binary(data), do: [data, zeros(byte_size(data))]

  defp zeros(size), do: :binary.copy(<<0>>, rem(4 - rem(size, 4), 4))
end
