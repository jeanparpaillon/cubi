defmodule Kubex.E2E.Artifacts do
  @moduledoc """
  The images e2e tests boot, built or located once per test run.

    * `kernel!/0` - `KUBEX_E2E_KERNEL`. Until the system fork (phase 2), a
      borrowed kernel with initramfs and loop support (docs/phase1.md).
    * `rootfs!/0` - `data/rootfs.img` from the umbrella's `MIX_ENV=e2e`
      firmware, `_build/x86_64_e2e/nerves/images/kubex_fw.fw`.
    * `stage1!/1` - built from `stage1/` with `stage1/build.exs`.
  """

  @spec kernel!() :: Path.t()
  def kernel!() do
    case System.get_env("KUBEX_E2E_KERNEL") do
      nil ->
        raise "set KUBEX_E2E_KERNEL to a kernel with BLK_DEV_INITRD, BLK_DEV_LOOP and SQUASHFS"

      path ->
        Path.expand(path)
    end
  end

  @doc """
  The kernel cmdline for `kernel!/0`: `args` plus what the borrowed kernel
  needs. Ubuntu's kernel enables kexec handover by default, and its scratch
  reservation sometimes takes ~400 MB of a 512 MB guest before init, which
  then panics "deadlocked on memory". The Nerves kernel has no KHO, so this
  goes away with the system fork (phase 2).
  """
  @spec cmdline(String.t()) :: String.t()
  def cmdline(args), do: "kho=off " <> args

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

  @spec stage1!(:prod | :dev) :: Path.t()
  def stage1!(mode \\ :prod) do
    once({:stage1, mode}, fn ->
      out = Path.join(dir(), "stage1-#{mode}.cpio.zst")
      # Short fail delay, so tests of the failure path don't wait 10 s.
      args = [
        Path.join([root(), "stage1", "build.exs"]),
        "--mode",
        "#{mode}",
        "--fail-delay",
        "2",
        "-o",
        out
      ]

      {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
      if status != 0, do: raise("stage1/build.exs failed:\n#{output}")
      out
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
