defmodule Cubi.Tools.Ssh do
  @moduledoc """
  The system `ssh` to a cubi node (docs/specs.md §2.11.5), whose shell
  evaluates Elixir: waiting for it to answer, and reading one value off it.

  A target is `%{host, port}` plus the options `mix cubi.deploy` takes
  (`:user`, `:identity`, `:ssh_option`). For instances of a provider,
  `provider_options/0` adds `StrictHostKeyChecking=no` and
  `UserKnownHostsFile=/dev/null`: a diskless node makes a new host key at
  every boot, so a known-hosts entry would only refuse it after its first
  reboot. Nothing secret travels to the node, and releases are trusted by
  their signature, never by the host they are sent to.

  `config :cubi_tools, :ssh` names another executable, for tests.
  """

  @type target :: %{host: String.t(), port: :inet.port_number()}

  @doc "The `-o` options for a provider's instances, as `ssh_option:` entries."
  @spec provider_options() :: keyword()
  def provider_options() do
    [
      ssh_option: "StrictHostKeyChecking=no",
      ssh_option: "UserKnownHostsFile=/dev/null",
      ssh_option: "LogLevel=ERROR"
    ]
  end

  @doc "`ssh`'s arguments up to the host, for `target` and `opts`."
  @spec args(target(), keyword()) :: [String.t()]
  def args(target, opts) do
    user = if opts[:user], do: ["-l", opts[:user]], else: []
    identity = if opts[:identity], do: ["-i", opts[:identity]], else: []
    extra = opts |> Keyword.get_values(:ssh_option) |> Enum.flat_map(&["-o", &1])
    ["-p", Integer.to_string(target.port)] ++ user ++ identity ++ extra ++ [target.host]
  end

  @doc """
  Evaluates `code` on the node and returns what it printed and ssh's exit
  status. Never prompts (`BatchMode`), and gives up connecting after 5 s.
  """
  @spec eval(target(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def eval(target, code, opts \\ []) do
    batch = [ssh_option: "BatchMode=yes", ssh_option: "ConnectTimeout=5"]
    System.cmd(executable(), args(target, batch ++ opts) ++ [code], stderr_to_stdout: true)
  end

  @doc """
  Waits until the node evaluates `:ok` over ssh: booted, its ssh daemon up,
  and one of our keys accepted. `{:error, last_output}` after `timeout` ms.
  """
  @spec wait(target(), keyword(), timeout()) :: :ok | {:error, String.t()}
  def wait(target, opts, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(target, opts, deadline, "")
  end

  defp do_wait(target, opts, deadline, last) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, last}
    else
      case eval(target, ":ok", opts) do
        {out, 0} ->
          if out =~ ":ok", do: :ok, else: retry(target, opts, deadline, out)

        {out, _} ->
          retry(target, opts, deadline, out)
      end
    end
  end

  defp retry(target, opts, deadline, out) do
    Process.sleep(Application.get_env(:cubi_tools, :ssh_retry_ms, 2_000))
    do_wait(target, opts, deadline, String.trim(out))
  end

  defp executable() do
    case Application.get_env(:cubi_tools, :ssh) do
      nil -> System.find_executable("ssh") || Mix.raise("ssh not found")
      path -> path
    end
  end
end
