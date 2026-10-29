defmodule Cubi.E2E.Milestone2GithubReleaseTest do
  @moduledoc """
  docs/phase0.md, milestone 2's open check, against the published release:
  a stock iPXE (QEMU's NIC ROM under BIOS, Ubuntu's `ipxe.efi` under UEFI)
  fetches the public image over HTTPS from GitHub's release URL, through its
  redirect to the asset host, and boots it under a rendered script.
  `hello` is built with `mix cubi.release --base <release URL>` and deployed.

  Reaches github.com: run with `--include network` besides `e2e:tier1`.
  `CUBI_E2E_RELEASE` names another version than 0.1.0.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Hello, Key}
  alias Cubi.Provider.Qemu

  @moduletag e2e: :tier1
  @moduletag :network
  @moduletag timeout: 900_000

  setup context do
    version = System.get_env("CUBI_E2E_RELEASE", "0.1.0")
    url = "https://github.com/jeanparpaillon/cubi/releases/download/v#{version}"
    {:ok, base} = Cubi.Tools.Image.base(url)

    {:ok, state} = Qemu.init(dir: Path.join(context.dir, "qemu"), ipxe_efi: Cubi.E2E.Ipxe.efi!())

    on_exit(fn ->
      {:ok, left} = Qemu.list(state)
      for i <- left, do: Qemu.destroy(state, i)
    end)

    {:ok, script} =
      Cubi.Tools.BootScript.render(
        image: url,
        ca: File.read!(Cubi.Pki.paths(Key.pki_dir()).ca_cert),
        ssh_keys: [File.read!(Key.public_key_path())]
      )

    %{url: url, uuid: base["firmware"]["uuid"], state: state, script: script}
  end

  for firmware <- [:bios, :uefi] do
    test "#{firmware}: stock iPXE boots the release from GitHub, hello deploys", context do
      {:ok, instance} =
        Qemu.create(context.state, %{
          name: "gh-#{unquote(firmware)}",
          script: context.script,
          firmware: unquote(firmware)
        })

      port = instance.provider.ssh_port

      assert Node.eval(port, ~s|Nerves.Runtime.KV.get_active("nerves_fw_uuid")|, 600_000) ==
               context.uuid

      console = File.read!(instance.provider.console)
      assert console =~ "cubi stage-1: rootfs sha256 ok"

      archive = Hello.build!("0.1.0", :ok, context.url)
      {out, status} = Hello.deploy(port, archive)
      assert status == 0, out
      assert Node.eval(port, "Hello.version()") == "0.1.0"
    end
  end
end
