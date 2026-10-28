defmodule Kubex.CmdlineTest do
  use ExUnit.Case, async: true

  alias Kubex.Cmdline

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

  @tag :tmp_dir
  test "read/1", %{tmp_dir: dir} do
    path = Path.join(dir, "cmdline")
    File.write!(path, "console=ttyS0 kubex.vdevs=mirror,a,b\n")
    assert Cmdline.read(path) == [{"console", "ttyS0"}, {"kubex.vdevs", "mirror,a,b"}]
  end
end
