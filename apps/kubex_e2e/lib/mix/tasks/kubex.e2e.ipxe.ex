defmodule Mix.Tasks.Kubex.E2e.Ipxe do
  @shortdoc "Fetches the ipxe.efi that UEFI PXE tests chainload"
  @moduledoc """
  Downloads Ubuntu's `ipxe` package with `apt download` (no root) and keeps
  its `ipxe.efi` as `priv/ipxe/ipxe.efi` (`Kubex.E2E.Ipxe`). Needs a Debian or
  Ubuntu host; elsewhere, set `KUBEX_E2E_IPXE_EFI` to any x86_64 `ipxe.efi`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    target = Kubex.E2E.Ipxe.default_path()

    if File.regular?(target) do
      Mix.shell().info("Already there: #{target}")
    else
      work = Path.join(System.tmp_dir!(), "kubex-e2e-ipxe-#{System.unique_integer([:positive])}")
      File.mkdir_p!(work)

      try do
        {_, 0} = System.cmd("apt", ["download", "ipxe"], cd: work, stderr_to_stdout: true)
        [deb] = Path.wildcard(Path.join(work, "ipxe_*.deb"))
        {_, 0} = System.cmd("dpkg-deb", ["-x", deb, Path.join(work, "x")])
        File.mkdir_p!(Path.dirname(target))
        # ipxe.efi is a symlink to ipxe-amd64.efi in the package; copy the file.
        File.cp!(Path.join(work, "x/usr/lib/ipxe/ipxe.efi"), target)
        Mix.shell().info("Fetched #{Path.basename(deb)} -> #{target}")
      after
        File.rm_rf!(work)
      end
    end
  end
end
