defmodule Cubi.E2E.InitrdTest do
  use ExUnit.Case, async: true

  alias Cubi.E2E.Initrd

  @moduletag :tmp_dir

  test "parts start on 4-byte boundaries, and a named part is a newc file the kernel can unpack",
       %{tmp_dir: dir} do
    first = Path.join(dir, "first.bin")
    File.write!(first, "abcde")

    out =
      Initrd.assemble!([first, {"/cubi/token", "secret\n", 0o400}], Path.join(dir, "initrd.img"))

    data = File.read!(out)

    # "abcde" padded to 8 bytes, then the wrapped file.
    assert <<"abcde", 0, 0, 0, rest::binary>> = data
    assert rem(byte_size(data), 4) == 0

    File.write!(Path.join(dir, "rest.cpio"), rest)
    extract = Path.join(dir, "x")
    File.mkdir_p!(extract)

    {listing, 0} =
      System.cmd(
        "sh",
        ["-c", "cpio -itv < ../rest.cpio && cpio -id --no-absolute-filenames < ../rest.cpio"],
        cd: extract,
        stderr_to_stdout: true
      )

    assert listing =~ ~r/^-r-------- .* root .* cubi\/token$/m
    assert File.read!(Path.join([extract, "cubi", "token"])) == "secret\n"
  end
end
