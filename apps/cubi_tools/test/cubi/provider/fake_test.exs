defmodule Cubi.Provider.FakeTest do
  use Cubi.Provider.Case, provider: Cubi.Provider.Fake, async: true

  alias Cubi.Provider.Fake

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    %{provider_opts: [dir: tmp]}
  end

  test "keeps the script it was given and counts reboots", context do
    {Fake, state} = start!(context)
    spec = spec(context, "a")

    {:ok, instance} = Fake.create(state, spec)
    :ok = Fake.set_script(state, instance, "#!ipxe\n# v2\n")
    :ok = Fake.reboot(state, instance)

    assert Fake.script(state, spec.name) == {:ok, "#!ipxe\n# v2\n"}
    assert Fake.reboots(state, spec.name) == {:ok, 1}
  end
end
