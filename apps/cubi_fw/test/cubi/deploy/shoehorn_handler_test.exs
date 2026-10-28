defmodule Cubi.Deploy.ShoehornHandlerTest do
  use ExUnit.Case, async: true

  alias Cubi.Deploy.ShoehornHandler

  setup do
    name = :"deploy_#{System.unique_integer([:positive])}"
    Process.register(self(), name)
    {:ok, state} = ShoehornHandler.init(cubi_deploy: name)
    %{state: state}
  end

  test "an exit is passed on to Cubi.Deploy, and the node continues", %{state: state} do
    assert ShoehornHandler.application_exited(:hello, :shutdown, state) == {:continue, state}
    assert_received {:"$gen_cast", {:exited, :hello, :shutdown}}
  end

  test "Application.stop/1's exits are not passed on", %{state: state} do
    assert ShoehornHandler.application_exited(:hello, :stopped, state) == {:continue, state}
    refute_received {:"$gen_cast", _}
  end

  test "starts are ignored" do
    assert ShoehornHandler.application_started(:hello, :s) == {:continue, :s}
  end

  test "with no Cubi.Deploy running it still continues, never raises" do
    {:ok, state} = ShoehornHandler.init(cubi_deploy: :nobody_here)
    assert ShoehornHandler.application_exited(:hello, :shutdown, state) == {:continue, state}
  end

  test "the default target is Cubi.Deploy" do
    assert ShoehornHandler.init(handler: ShoehornHandler) == {:ok, Cubi.Deploy}
  end
end
