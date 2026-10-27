defmodule Kubex.E2E.Case do
  @moduledoc """
  ExUnit case template for e2e tests (docs/testing.md §2).

  Each test gets `context.dir`, `_build/e2e/<module>/<test>/`. It is wiped at
  the start of the test and left in place afterwards, with the console log,
  the QMP log and the QEMU argv, so a failure can be read after the fact.
  `start_vm!/2` starts a machine under the test supervisor, which stops it
  when the test ends.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Kubex.E2E.Case, only: [start_vm!: 2]
      alias Kubex.E2E.{Console, Node, VM}
    end
  end

  setup context do
    # The umbrella's _build, whether tests run from the root or from the app.
    build_root = Path.dirname(Mix.Project.build_path())
    dir = Path.join([build_root, "e2e", slug(context.module), slug(context.test)])

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    {:ok, dir: dir}
  end

  @doc "Starts `spec` with its files in `<context.dir>/<spec.name>/`."
  @spec start_vm!(map(), Kubex.E2E.VM.t()) :: pid()
  def start_vm!(context, spec) do
    ExUnit.Callbacks.start_supervised!(
      {Kubex.E2E.VM, spec: spec, dir: Path.join(context.dir, spec.name)},
      shutdown: 10_000
    )
  end

  defp slug(name) do
    name
    |> to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
  end
end
