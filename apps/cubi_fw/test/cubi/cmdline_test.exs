defmodule Cubi.CmdlineTest do
  use ExUnit.Case, async: true

  alias Cubi.Cmdline

  doctest Cmdline

  test "quotes protect whitespace and are dropped" do
    assert Cmdline.parse(~s(a="b c" "d=e f" g)) == [{"a", "b c"}, {"d", "e f"}, {"g", nil}]
  end

  test "empty values, runs of whitespace, trailing newline" do
    assert Cmdline.parse("  a=  b=c=d\n") == [{"a", ""}, {"b", "c=d"}]
  end

  test "duplicates are kept, in order" do
    assert Cmdline.parse("a=1 a=2") == [{"a", "1"}, {"a", "2"}]
  end

  test "ssh_keys/1: cubi.ssh= values as authorized_keys lines, in order, malformed ones left out" do
    args =
      Cmdline.parse(
        "cubi.ssh=ssh-ed25519:AAAAC3NzaC1lZDI1NTE5AAAAIA cubi.ssh=ssh-rsa:AAAAB3Nza== " <>
          "cubi.ssh=ecdsa-sha2-nistp256:AAAAE2Vj cubi.ssh cubi.ssh= cubi.ssh=ssh-ed25519 " <>
          "cubi.ssh=ssh-ed25519:AA:BB other=ssh-rsa:AAAA"
      )

    assert Cmdline.ssh_keys(args) == [
             "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA",
             "ssh-rsa AAAAB3Nza==",
             "ecdsa-sha2-nistp256 AAAAE2Vj"
           ]
  end

  @tag :tmp_dir
  test "read/1", %{tmp_dir: dir} do
    path = Path.join(dir, "cmdline")
    File.write!(path, "console=ttyS0 cubi.vdevs=mirror,a,b\n")
    assert Cmdline.read(path) == [{"console", "ttyS0"}, {"cubi.vdevs", "mirror,a,b"}]
  end
end
