defmodule Cubi.Tools.Lines do
  @moduledoc false
  # A Collectable for System.cmd's output: prints each line as it arrives and
  # keeps them all, so a task can both show progress and read the verdict.

  defstruct buffer: "", lines: []

  @spec lines(%__MODULE__{}) :: [String.t()]
  def lines(%__MODULE__{buffer: buffer, lines: lines}) do
    rest = if buffer == "", do: [], else: [buffer]
    Enum.reverse(lines, rest)
  end

  defimpl Collectable do
    def into(acc) do
      fun = fn
        acc, {:cont, chunk} ->
          {complete, [buffer]} = Enum.split(String.split(acc.buffer <> chunk, "\n"), -1)
          for line <- complete, do: Mix.shell().info(line)
          %{acc | buffer: buffer, lines: Enum.reverse(complete, acc.lines)}

        acc, :done ->
          if acc.buffer != "", do: Mix.shell().info(acc.buffer)
          acc

        _acc, :halt ->
          :ok
      end

      {acc, fun}
    end
  end
end
