# Builds the stage-1 initramfs (docs/specs.md §2.4).
#
#     elixir stage1/build.exs [--mode prod|dev] [--fail-delay SECONDS]
#                             [--busybox PATH] [-o OUTPUT]
#
# Writes a zstd-compressed newc cpio holding /init (this directory's `init`), a
# static busybox, the mount points and /dev/console. The archive is written
# here rather than with cpio(1) so that it needs no root (for the device node)
# and is reproducible: owner 0, mtime 0, fixed order.
#
# /kubex is shipped empty: the kernel does not create parent directories when
# it unpacks an initrd, so iPXE's `initrd … /kubex/token` needs it to exist in
# an earlier archive.
#
# Phase 2 moves this build into the system fork's Buildroot (post-image.sh).

{opts, _, invalid} =
  OptionParser.parse(System.argv(),
    strict: [mode: :string, fail_delay: :integer, busybox: :string, output: :string],
    aliases: [o: :output]
  )

if invalid != [], do: raise("unknown options: #{inspect(invalid)}")

mode = Keyword.get(opts, :mode, "prod")
if mode not in ["prod", "dev"], do: raise("--mode must be prod or dev, got #{mode}")

fail_delay = Keyword.get(opts, :fail_delay, 10)
busybox = Keyword.get(opts, :busybox, "/usr/bin/busybox")
here = __DIR__
output =
  opts
  |> Keyword.get(:output, Path.join([here, "..", "_build", "stage1", "stage1-#{mode}.cpio.zst"]))
  |> Path.expand()

# The kernel runs /init before any library could be found: busybox must be
# static.
{headers, 0} = System.cmd("readelf", ["-l", busybox])
if headers =~ "INTERP", do: raise("#{busybox} is dynamically linked; install busybox-static")

init =
  here
  |> Path.join("init")
  |> File.read!()
  |> String.replace("@MODE@", mode)
  |> String.replace("@FAIL_DELAY@", Integer.to_string(fail_delay))

# {name, type, mode, contents | {major, minor}}
entries = [
  {"bin", :dir, 0o755, nil},
  {"bin/busybox", :file, 0o755, File.read!(busybox)},
  {"dev", :dir, 0o755, nil},
  {"dev/console", :char, 0o600, {5, 1}},
  {"init", :file, 0o755, init},
  {"kubex", :dir, 0o700, nil},
  {"newroot", :dir, 0o755, nil},
  {"proc", :dir, 0o555, nil},
  {"sys", :dir, 0o555, nil}
]

pad4 = fn size -> rem(4 - rem(size, 4), 4) end

newc = fn {name, type, perm, data}, ino ->
  {file_type, body, {rmaj, rmin}} =
    case type do
      :dir -> {0o040000, "", {0, 0}}
      :file -> {0o100000, data, {0, 0}}
      :char -> {0o020000, "", data}
    end

  name0 = name <> <<0>>
  nlink = if type == :dir, do: 2, else: 1

  fields =
    [ino, file_type + perm, 0, 0, nlink, 0, byte_size(body), 0, 0, rmaj, rmin, byte_size(name0), 0]
    |> Enum.map(&(&1 |> Integer.to_string(16) |> String.pad_leading(8, "0")))

  header = IO.iodata_to_binary(["070701", fields, name0])

  [header, :binary.copy(<<0>>, pad4.(byte_size(header))), body, :binary.copy(<<0>>, pad4.(byte_size(body)))]
end

cpio =
  entries
  |> Enum.with_index(1)
  |> Enum.map(fn {entry, ino} -> newc.(entry, ino) end)
  |> Kernel.++([newc.({"TRAILER!!!", :file, 0, ""}, 0)])
  |> IO.iodata_to_binary()

File.mkdir_p!(Path.dirname(output))
raw = output <> ".tmp"
File.write!(raw, cpio)
{_, 0} = System.cmd("zstd", ["-q", "-19", "-f", "--rm", raw, "-o", output])
IO.puts("#{output} (#{mode}, #{File.stat!(output).size} bytes)")
