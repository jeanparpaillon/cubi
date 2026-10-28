defmodule Mix.Tasks.Cubi.E2e.Ipxe do
  @shortdoc "Fetches the stock ipxe.efi and builds the trusted iPXE for e2e tests"
  @moduledoc """
  Two iPXEs (`Cubi.E2E.Ipxe`):

    * **stock** - downloads Ubuntu's `ipxe` package with `apt download` (no
      root) and keeps its `ipxe.efi` as `priv/ipxe/ipxe.efi`. Needs a Debian or
      Ubuntu host; elsewhere, set `CUBI_E2E_IPXE_EFI` to any x86_64 `ipxe.efi`.
    * **trusted** - builds cubi's own iPXE (`mix cubi.ipxe`) trusting only
      the test CA (`mix cubi.e2e.key` first) into `priv/ipxe/trusted/`.
      Rebuilt when the test CA or the build settings change.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    stock()
    trusted()
  end

  defp trusted() do
    ca = Cubi.Pki.paths(Cubi.E2E.Key.pki_dir()).ca_cert
    out = Cubi.E2E.Ipxe.default_trusted_dir()

    if not File.regular?(ca), do: Mix.raise("no #{ca}: run `mix cubi.e2e.key` first")

    if Cubi.Tools.Ipxe.up_to_date?(out, ca) do
      Mix.shell().info("Already there: #{out}")
    else
      Mix.Task.run("cubi.ipxe", ["--ca", ca, "--out", out])
    end
  end

  defp stock() do
    target = Cubi.E2E.Ipxe.default_path()

    if File.regular?(target) do
      Mix.shell().info("Already there: #{target}")
    else
      work = Path.join(System.tmp_dir!(), "cubi-e2e-ipxe-#{System.unique_integer([:positive])}")
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
