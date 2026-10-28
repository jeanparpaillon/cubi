defmodule Cubi.Deploy.CheckTest do
  use ExUnit.Case, async: true

  alias Cubi.Deploy.Check

  @node %{
    otp_release: "29",
    lib: %{"kernel" => "11.0.2", "elixir" => "1.20.2", "plug" => "1.20.3"}
  }
  @empty %{current: nil, previous: nil, bad: []}

  defp manifest(overrides \\ %{}) do
    Map.merge(
      %{
        "format" => 1,
        "name" => "hello",
        "version" => "0.2.0",
        "otp_release" => "29",
        "applications" => [%{"name" => "hello", "vsn" => "0.2.0"}],
        "requires" => %{"elixir" => "1.20.2"},
        "start" => ["hello"]
      },
      overrides
    )
  end

  test "a release built for this node passes" do
    assert Check.run(manifest(), @node, @empty, nil) == :ok
  end

  test "an unknown format and another OTP release are refused" do
    assert Check.run(manifest(%{"format" => 2}), @node, @empty, nil) ==
             {:error, {:unknown_format, 2}}

    assert Check.run(manifest(%{"otp_release" => "28"}), @node, @empty, nil) ==
             {:error, {:otp_release, "28", "29"}}
  end

  test "an application of the image at another version is refused; at the same, accepted" do
    apps = [%{"name" => "plug", "vsn" => "1.19.0"}, %{"name" => "hello", "vsn" => "0.2.0"}]

    assert Check.run(manifest(%{"applications" => apps}), @node, @empty, nil) ==
             {:error, {:conflicts, [{"plug", "1.19.0", "1.20.3"}]}}

    same = [%{"name" => "plug", "vsn" => "1.20.3"}, %{"name" => "hello", "vsn" => "0.2.0"}]
    assert Check.run(manifest(%{"applications" => same}), @node, @empty, nil) == :ok
  end

  test "requires must be in the image at exactly that version" do
    assert Check.run(
             manifest(%{"requires" => %{"elixir" => "1.20.1", "eex" => "1.20.2"}}),
             @node,
             @empty,
             nil
           ) ==
             {:error, {:requires, [{"eex", "1.20.2", nil}, {"elixir", "1.20.1", "1.20.2"}]}}
  end

  test "one release per node: another name is refused while one runs" do
    running = %{@empty | current: "0.1.0"}

    assert Check.run(manifest(), @node, running, "hello") == :ok

    assert Check.run(manifest(), @node, running, "other") ==
             {:error, {:another_release, "hello", "other"}}
  end

  test "the current version and bad versions are refused" do
    assert Check.run(manifest(), @node, %{@empty | current: "0.2.0"}, "hello") ==
             {:error, {:already_current, "0.2.0"}}

    assert Check.run(manifest(), @node, %{@empty | bad: ["0.2.0"]}, nil) ==
             {:error, {:bad_version, "0.2.0"}}
  end
end
