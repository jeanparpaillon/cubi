defmodule KubexFwTest do
  use ExUnit.Case
  doctest KubexFw

  test "greets the world" do
    assert KubexFw.hello() == :world
  end
end
