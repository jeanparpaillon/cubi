defmodule CubiFwTest do
  use ExUnit.Case
  doctest CubiFw

  test "greets the world" do
    assert CubiFw.hello() == :world
  end
end
