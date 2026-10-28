defmodule Cubi.E2E.Artifacts do
  @moduledoc """
  The images e2e tests boot, located once per test run.

    * `kernel!/0`, `stage1!/0` and `rootfs!/0` - the directory a boot server
      serves, `_build/x86_64_e2e/ipxe/`, from
      `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware.ipxe` in apps/cubi_fw
      (docs/specs.md §2.3). Tests boot exactly what is served.
      `CUBI_E2E_KERNEL` overrides the kernel.
    * `stage1!(:dev)` - from the `cubi_system_x86_64` artifact's `images/`
      (built by `cubi_fw`, or downloaded into `~/.nerves/artifacts`): it is
      never served.
  """

  @system "cubi_system_x86_64"

  @spec kernel!() :: Path.t()
  def kernel!() do
    case System.get_env("CUBI_E2E_KERNEL") do
      nil -> served!("vmlinuz")
      path -> Path.expand(path)
    end
  end

  @doc """
  The kernel cmdline for `kernel!/0`: `args`, plus `kho=off` when
  `CUBI_E2E_KERNEL` names a borrowed kernel. Ubuntu's kernel enables kexec
  handover by default, and its scratch reservation sometimes takes ~400 MB of
  a 512 MB guest before init, which then panics "deadlocked on memory". The
  system's kernel has no KHO.
  """
  @spec cmdline(String.t()) :: String.t()
  def cmdline(args) do
    if System.get_env("CUBI_E2E_KERNEL"), do: "kho=off " <> args, else: args
  end

  @spec rootfs!() :: Path.t()
  def rootfs!(), do: served!("rootfs.squashfs")

  @doc "The served directory itself (`mix firmware.ipxe`'s output)."
  @spec served_dir!() :: Path.t()
  def served_dir!() do
    dir = Path.join([root(), "_build", "x86_64_e2e", "ipxe"])

    if not File.exists?(Path.join(dir, "boot.ipxe")),
      do:
        raise("no #{dir}: run `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware.ipxe` in apps/cubi_fw")

    dir
  end

  @doc "The stage-1 initramfs built by the system (docs/specs.md §2.4)."
  @spec stage1!(:prod | :dev) :: Path.t()
  def stage1!(mode \\ :prod)
  def stage1!(:prod), do: served!("stage1.cpio.zst")
  def stage1!(:dev), do: image!("stage1-dev.cpio.zst")

  defp served!(name), do: Path.join(served_dir!(), name)

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
        raise "no #{name} artifact; build the firmware: `MIX_TARGET=x86_64 mix compile` in apps/cubi_fw"
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
end
