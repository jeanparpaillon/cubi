defmodule Cubi.Cmdline do
  @moduledoc """
  The kernel command line, split the way the kernel's `next_arg()` does:
  whitespace separates arguments, double quotes protect it, and the quotes
  themselves are dropped. Arguments after `--` belong to init and are left out.
  """

  @type arg :: {String.t(), String.t() | nil}

  @doc "Reads and parses `/proc/cmdline`."
  @spec read(Path.t()) :: [arg()]
  def read(path \\ "/proc/cmdline"), do: path |> File.read!() |> parse()

  @doc """
  `{name, value}` pairs in order, duplicates kept. A bare `name` has value
  `nil`; `name=` has `""`.

      iex> Cubi.Cmdline.parse(~S(console=ttyS0 quiet cubi.zpool="tank" -- init=x))
      [{"console", "ttyS0"}, {"quiet", nil}, {"cubi.zpool", "tank"}]
  """
  @spec parse(String.t()) :: [arg()]
  def parse(cmdline) do
    cmdline
    |> split([], "", false)
    |> Enum.take_while(&(&1 != "--"))
    |> Enum.map(fn arg ->
      case String.split(arg, "=", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, nil}
      end
    end)
  end

  @doc """
  The ssh authorized keys named by `cubi.ssh=<type>:<base64>` (docs/specs.md
  §2.12.2), as `authorized_keys` lines, in cmdline order. The `:` stands for
  the line's space; there is no comment. Malformed values are left out.

      iex> Cubi.Cmdline.ssh_keys([{"cubi.ssh", "ssh-ed25519:AAAAC3Nz"}, {"cubi.ssh", "junk"}])
      ["ssh-ed25519 AAAAC3Nz"]
  """
  @spec ssh_keys([arg()]) :: [String.t()]
  def ssh_keys(args) do
    for {"cubi.ssh", value} <- args,
        [_, type, key] <- [Regex.run(~r/\A([a-z0-9@.-]+):([A-Za-z0-9+\/]+={0,2})\z/, value || "")],
        do: type <> " " <> key
  end

  defp split(<<>>, acc, "", _quoted), do: Enum.reverse(acc)
  defp split(<<>>, acc, cur, _quoted), do: Enum.reverse([cur | acc])
  defp split(<<?", rest::binary>>, acc, cur, quoted), do: split(rest, acc, cur, not quoted)

  defp split(<<c, rest::binary>>, acc, cur, false) when c in ~c" \t\n" do
    if cur == "", do: split(rest, acc, "", false), else: split(rest, [cur | acc], "", false)
  end

  defp split(<<c, rest::binary>>, acc, cur, quoted), do: split(rest, acc, cur <> <<c>>, quoted)
end
