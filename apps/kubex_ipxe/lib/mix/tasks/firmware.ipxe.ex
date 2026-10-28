defmodule Mix.Tasks.Firmware.Ipxe do
  @shortdoc "Builds the firmware, then the directory a boot server serves to iPXE"
  @moduledoc """
  Runs `mix firmware`, then writes `vmlinuz`, `stage1.cpio.zst`,
  `rootfs.squashfs`, `boot.ipxe` and `SHA256SUMS` into
  `_build/<target>_<env>/ipxe/` (docs/specs.md §2.3, `Kubex.Ipxe`).

      MIX_TARGET=x86_64 mix firmware.ipxe [--cmdline "console=ttyS0 …"]

  Run it in a Nerves firmware project whose system ships
  `images/stage1.cpio.zst` (`kubex_system_x86_64`). Needs `fwup`,
  `unsquashfs` and `mksquashfs` on the host.
  """
  use Mix.Task

  @switches [cmdline: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    Mix.Task.run("firmware", [])

    system = System.get_env("NERVES_SYSTEM") || Mix.raise("NERVES_SYSTEM is not set")
    output = Path.join(Mix.Project.build_path(), "ipxe")

    meta =
      Kubex.Ipxe.build!(
        firmware: Nerves.Env.firmware_path(),
        stage1: Path.join([system, "images", "stage1.cpio.zst"]),
        output: output,
        cmdline: Keyword.get(opts, :cmdline, "console=ttyS0")
      )

    Mix.shell().info("""
    #{meta["product"]} #{meta["version"]} (#{meta["uuid"]}) ready to serve in
      #{Path.relative_to_cwd(output)}
    """)
  end
end
