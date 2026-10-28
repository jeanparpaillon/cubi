defmodule Cubi.Deploy.Check do
  @moduledoc """
  What a node checks of a verified manifest before installing it
  (docs/specs.md §2.11.4 steps 4 and 5, §2.11.6, §2.11.7):

    * the format is known and `otp_release` is the node's;
    * every application is absent from the node's `lib/` or there at the
      same version, and every one in `requires` is there at exactly that
      version: the release was built for this image;
    * one release per node: its name is the current release's, if any;
    * the version is neither the current one nor marked bad.

  The node is described by a map, so the checks run anywhere:
  `%{otp_release: "29", lib: %{"kernel" => "11.0.2", …}}` (`node/0`).
  """

  @type node_info :: %{otp_release: String.t(), lib: %{String.t() => String.t()}}

  @doc "This node: its OTP release and the applications in its `lib/`."
  @spec node() :: node_info()
  def node() do
    lib_dir = :code.lib_dir() |> to_string()

    lib =
      for dir <- File.ls!(lib_dir),
          [_, name, vsn] <- [Regex.run(~r/^(.+)-([^-]+)$/, dir)],
          into: %{},
          do: {name, vsn}

    %{otp_release: to_string(:erlang.system_info(:otp_release)), lib: lib}
  end

  @spec run(map(), node_info(), Cubi.Deploy.Store.state(), String.t() | nil) ::
          :ok | {:error, term()}
  def run(manifest, node, state, current_name) do
    with :ok <- format(manifest),
         :ok <- otp(manifest, node),
         :ok <- applications(manifest, node),
         :ok <- requires(manifest, node),
         :ok <- one_release(manifest, state, current_name) do
      version(manifest, state)
    end
  end

  defp format(%{"format" => 1}), do: :ok
  defp format(manifest), do: {:error, {:unknown_format, manifest["format"]}}

  defp otp(%{"otp_release" => otp}, %{otp_release: otp}), do: :ok

  defp otp(manifest, node),
    do: {:error, {:otp_release, manifest["otp_release"], node.otp_release}}

  defp applications(manifest, node) do
    conflicts =
      for %{"name" => name, "vsn" => vsn} <- manifest["applications"] || [],
          (have = node.lib[name]) != nil and have != vsn,
          do: {name, vsn, have}

    if conflicts == [], do: :ok, else: {:error, {:conflicts, conflicts}}
  end

  defp requires(manifest, node) do
    missing =
      for {name, vsn} <- manifest["requires"] || %{},
          node.lib[name] != vsn,
          do: {name, vsn, node.lib[name]}

    if missing == [], do: :ok, else: {:error, {:requires, Enum.sort(missing)}}
  end

  defp one_release(%{"name" => name}, %{current: nil}, _current_name) when is_binary(name),
    do: :ok

  defp one_release(%{"name" => name}, _state, name), do: :ok

  defp one_release(%{"name" => name}, _state, current_name),
    do: {:error, {:another_release, name, current_name}}

  defp version(%{"version" => vsn}, %{current: vsn}), do: {:error, {:already_current, vsn}}

  defp version(%{"version" => vsn}, %{bad: bad}) do
    if vsn in bad, do: {:error, {:bad_version, vsn}}, else: :ok
  end
end
