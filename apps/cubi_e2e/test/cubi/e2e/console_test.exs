defmodule Cubi.E2E.ConsoleTest do
  # Drives Console's GenServer directly, against a unix socket standing in for
  # QEMU's chardev. The public API goes through a VM, which needs QEMU.
  use ExUnit.Case, async: true

  alias Cubi.E2E.Console

  setup do
    dir = Path.join(System.tmp_dir!(), "kbx-ct-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    sock = Path.join(dir, "c.sock")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, sock}, active: false])
    test = self()

    spawn_link(fn ->
      {:ok, peer} = :gen_tcp.accept(listen)
      :ok = :gen_tcp.controlling_process(peer, test)
      send(test, {:peer, peer})
      Process.sleep(:infinity)
    end)

    {:ok, console} = Console.start_link(sock, Path.join(dir, "console.log"))
    assert_receive {:peer, peer}
    {:ok, console: console, peer: peer, log: Path.join(dir, "console.log")}
  end

  defp await(console, regex, timeout \\ 1_000) do
    case GenServer.call(console, {:await, regex, timeout}) do
      {:ok, captures} -> captures
      {:timeout, tail} -> {:timeout, tail}
    end
  end

  test "matches output already received, and output that arrives later", %{console: c, peer: peer} do
    :ok = :gen_tcp.send(peer, "Linux version 6.18\n")
    assert await(c, ~r/Linux version (\S+)/) == ["Linux version 6.18", "6.18"]

    task = Task.async(fn -> await(c, ~r/iex\(1\)>/) end)
    Process.sleep(50)
    :ok = :gen_tcp.send(peer, "Interactive Elixir\niex(1)> ")
    assert Task.await(task) == ["iex(1)>"]
  end

  test "a match moves the cursor: the same text is not matched twice", %{console: c, peer: peer} do
    :ok = :gen_tcp.send(peer, "boot\nboot\n")
    assert await(c, ~r/boot/) == ["boot"]
    assert await(c, ~r/boot/) == ["boot"]
    assert {:timeout, _} = await(c, ~r/boot/, 100)
  end

  test "a match split across two reads is found", %{console: c, peer: peer} do
    task = Task.async(fn -> await(c, ~r/Kernel command line: (.*)\n/) end)
    :ok = :gen_tcp.send(peer, "Kernel comm")
    Process.sleep(20)
    :ok = :gen_tcp.send(peer, "and line: console=ttyS0\n")
    assert Task.await(task) == ["Kernel command line: console=ttyS0\n", "console=ttyS0"]
  end

  test "a timeout returns the tail of the output", %{console: c, peer: peer} do
    :ok = :gen_tcp.send(peer, "Kernel panic - not syncing\n")
    assert {:timeout, tail} = await(c, ~r/iex/, 100)
    assert tail =~ "Kernel panic"
  end

  test "everything is copied to the log, and input reaches the guest", %{
    console: c,
    peer: peer,
    log: log
  } do
    :ok = :gen_tcp.send(peer, "hello\n")
    assert await(c, ~r/hello/) == ["hello"]
    assert File.read!(log) == "hello\n"

    :ok = GenServer.call(c, {:send, "1 + 1\n"})
    assert {:ok, "1 + 1\n"} = :gen_tcp.recv(peer, 0, 1_000)
  end
end
