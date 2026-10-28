defmodule Cubi.Storage.Args do
  @moduledoc """
  The storage boot arguments (docs/specs.md §2.10.3):

    * `cubi.vdevs=<SPEC>` - `zpool create` vdev syntax with commas for
      spaces. Absent means a diskless node.
    * `cubi.zpool=<NAME>` - pool name, default `cubi`.
    * `cubi.zfs.create=1` - creating the pool is allowed if none is found.

  Anything doubtful is an error rather than a guess: a typo in a boot argument
  must never lead to a disk being written. That includes giving one of these
  arguments twice.
  """

  defstruct vdevs: nil, pool: "cubi", create: false

  @type vdev :: {:keyword, String.t()} | {:device, String.t()}
  @type t :: %__MODULE__{vdevs: [vdev()] | nil, pool: String.t(), create: boolean()}

  @keys ~w(cubi.vdevs cubi.zpool cubi.zfs.create)
  @groups ~w(mirror raidz raidz1 raidz2 raidz3)
  @classes ~w(spare log cache special dedup)

  @spec parse([Cubi.Cmdline.arg()]) :: {:ok, t()} | {:error, term()}
  def parse(args) do
    args = Enum.filter(args, fn {name, _} -> name in @keys end)

    with :ok <- no_duplicates(args),
         args = Map.new(args),
         {:ok, vdevs} <- vdevs(Map.fetch(args, "cubi.vdevs")),
         {:ok, pool} <- pool(Map.get(args, "cubi.zpool", "cubi")),
         {:ok, create} <- create(Map.get(args, "cubi.zfs.create", "0")) do
      {:ok, %__MODULE__{vdevs: vdevs, pool: pool, create: create}}
    end
  end

  defp no_duplicates(args) do
    case Enum.frequencies_by(args, &elem(&1, 0)) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> :ok
      {name, _} -> {:error, {:duplicate, name}}
    end
  end

  defp vdevs(:error), do: {:ok, nil}

  defp vdevs({:ok, spec}) when is_binary(spec) do
    tokens = Enum.map(String.split(spec, ","), &classify/1)

    cond do
      spec == "" or Enum.any?(tokens, &(&1 == {:device, ""})) ->
        {:error, {:vdevs, :empty_name, spec}}

      not Enum.any?(tokens, &match?({:device, _}, &1)) ->
        {:error, {:vdevs, :no_device, spec}}

      dup = duplicate_device(tokens) ->
        {:error, {:vdevs, {:duplicate_device, dup}, spec}}

      bad = dangling_keyword(tokens) ->
        {:error, {:vdevs, {:dangling_keyword, bad}, spec}}

      true ->
        {:ok, tokens}
    end
  end

  defp vdevs({:ok, nil}), do: {:error, {:vdevs, :empty_name, nil}}

  defp classify(token) do
    if token in @groups or token in @classes or draid?(token),
      do: {:keyword, token},
      else: {:device, token}
  end

  # draid[<parity>][:<data>d][:<children>c][:<spares>s]
  defp draid?(token), do: Regex.match?(~r/^draid[1-3]?(:\d+[dcs])*$/, token)

  defp duplicate_device(tokens) do
    tokens
    |> Enum.flat_map(fn
      {:device, name} -> [name]
      _ -> []
    end)
    |> Enum.frequencies()
    |> Enum.find_value(fn {name, n} -> n > 1 && name end)
  end

  # A keyword has to be followed by a device, or a class by a group
  # (`log,mirror,a,b`).
  defp dangling_keyword(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.find_value(fn
      [{:keyword, k}, nil] ->
        k

      [{:keyword, k}, {:keyword, next}] ->
        if k in @classes and next not in @classes, do: nil, else: k

      _ ->
        nil
    end)
  end

  # zpool's own rules (zfs_namecheck.c, pool_namecheck), less the space,
  # which can't be on the cmdline anyway.
  defp pool(name) do
    cond do
      not is_binary(name) or not Regex.match?(~r/^[A-Za-z][A-Za-z0-9_.:-]{0,254}$/, name) ->
        {:error, {:zpool, :invalid, name}}

      name in ~w(mirror raidz draid spare log) or Regex.match?(~r/^(raidz|draid|c\d)/, name) ->
        {:error, {:zpool, :reserved, name}}

      true ->
        {:ok, name}
    end
  end

  defp create("1"), do: {:ok, true}
  defp create("0"), do: {:ok, false}
  defp create(other), do: {:error, {:create, other}}
end
