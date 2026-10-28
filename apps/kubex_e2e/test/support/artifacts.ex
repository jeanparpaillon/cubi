defmodule Kubex.E2E.Artifacts do
  @moduledoc """
  The images e2e tests boot, located once per test run.

    * `kernel!/0` and `stage1!/1` - from the `kubex_system_x86_64` artifact's
      `images/`: built locally by `kubex_fw` (`nerves: [compile: true]`), or
      downloaded into `~/.nerves/artifacts`. `KUBEX_E2E_KERNEL` overrides the
      kernel.
    * `rootfs!/0` - `data/rootfs.img` from the umbrella's `MIX_ENV=e2e`
      firmware, `_build/x86_64_e2e/nerves/images/kubex_fw.fw`.
  """

  @system "kubex_system_x86_64"

  @spec kernel!() :: Path.t()
  def kernel!() do
    case System.get_env("KUBEX_E2E_KERNEL") do
      nil -> image!("bzImage")
      path -> Path.expand(path)
    end
  end

  @doc """
  The kernel cmdline for `kernel!/0`: `args`, plus `kho=off` when
  `KUBEX_E2E_KERNEL` names a borrowed kernel. Ubuntu's kernel enables kexec
  handover by default, and its scratch reservation sometimes takes ~400 MB of
  a 512 MB guest before init, which then panics "deadlocked on memory". The
  system's kernel has no KHO.
  """
  @spec cmdline(String.t()) :: String.t()
  def cmdline(args) do
    if System.get_env("KUBEX_E2E_KERNEL"), do: "kho=off " <> args, else: args
  end

  @spec rootfs!() :: Path.t()
  def rootfs!() do
    once({:rootfs}, fn ->
      fw = Path.join([root(), "_build", "x86_64_e2e", "nerves", "images", "kubex_fw.fw"])

      if not File.exists?(fw),
        do: raise("no #{fw}: run `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware` in apps/kubex_fw")

      out = Path.join(dir(), "rootfs.squashfs")

      {:ok, [{_, data}]} =
        :zip.unzip(String.to_charlist(fw), [:memory, file_list: [~c"data/rootfs.img"]])

      File.write!(out, data)
      out
    end)
  end

  @doc "The stage-1 initramfs built by the system (docs/specs.md §2.4)."
  @spec stage1!(:prod | :dev) :: Path.t()
  def stage1!(mode \\ :prod)
  def stage1!(:prod), do: image!("stage1.cpio.zst")
  def stage1!(:dev), do: image!("stage1-dev.cpio.zst")

  defp image!(name) do
    path = Path.join(system_images!(), name)
    if not File.exists?(path), do: raise("no #{path}: rebuild #{@system}")
    path
  end

  defp system_images!() do
    once({:system_images}, fn ->
      app = Path.join([root(), "apps", @system])
      version = app |> Path.join("VERSION") |> File.read!() |> String.trim()
      name = "#{@system}-portable-#{version}"

      candidates = [
        Path.join([app, ".nerves", "artifacts", name, "images"]),
        Path.join([System.user_home!(), ".nerves", "artifacts", name, "images"])
      ]

      Enum.find(candidates, &File.dir?/1) ||
        raise "no #{name} artifact; build the firmware: `MIX_TARGET=x86_64 mix compile` in apps/kubex_fw"
    end)
  end

  defp once(key, fun) do
    key = {__MODULE__, key}

    case :persistent_term.get(key, nil) do
      nil -> fun.() |> tap(&:persistent_term.put(key, &1))
      path -> path
    end
  end

  defp root(), do: Mix.Project.build_path() |> Path.dirname() |> Path.dirname()

  defp dir() do
    dir = Path.join([root(), "_build", "e2e", "artifacts"])
    File.mkdir_p!(dir)
    dir
  end
end
