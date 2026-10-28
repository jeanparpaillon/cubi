defmodule Cubi.Deploy.StoreTest do
  use ExUnit.Case, async: true

  alias Cubi.Deploy.Store

  @moduletag :tmp_dir

  test "an empty root has no current, no previous, nothing bad", %{tmp_dir: root} do
    assert Store.state(root) == %{current: nil, previous: nil, bad: []}
  end

  test "state round-trips through state.json, with no temporary file left", %{tmp_dir: root} do
    state = %{current: "0.2.0", previous: "0.1.0", bad: ["0.1.5"]}
    Store.put_state!(root, state)

    assert Store.state(root) == state
    assert File.ls!(root) == ["state.json"]
  end

  test "unpack!/3 then entries/2 gives the archive back", %{tmp_dir: root} do
    entries = %{"manifest.json" => "{}", "lib/a-1/ebin/a.app" => "app", "lib/a-1/priv/x" => "x"}
    dir = Store.unpack!(root, "1", entries)

    assert dir == Path.join(root, "1")
    assert Store.entries(root, "1") == {:ok, entries}
    assert Store.entries(root, "2") == {:error, {:no_such_version, "2"}}
  end

  test "unpack!/3 replaces a leftover of the same version", %{tmp_dir: root} do
    Store.unpack!(root, "1", %{"stale" => "x"})
    Store.unpack!(root, "1", %{"fresh" => "y"})

    assert Store.entries(root, "1") == {:ok, %{"fresh" => "y"}}
  end

  test "prune!/2 keeps the given versions, incoming and state.json", %{tmp_dir: root} do
    for v <- ~w(1 2 3), do: Store.unpack!(root, v, %{"f" => v})
    File.mkdir_p!(Store.incoming_dir(root))
    Store.put_state!(root, %{current: "3", previous: "2", bad: []})

    Store.prune!(root, ["3", "2", nil])

    assert Enum.sort(File.ls!(root)) == ~w(2 3 incoming state.json)
  end
end
