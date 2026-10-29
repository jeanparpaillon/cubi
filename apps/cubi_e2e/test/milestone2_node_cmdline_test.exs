defmodule Cubi.E2E.Milestone2NodeCmdlineTest do
  @moduledoc """
  docs/milestone2.md, the node's side of the cmdline (docs/specs.md §2.12.2):
  `cubi.ssh=` adds authorized keys to the image's, and `cubi.ca=` is read by
  the release verification (§2.11.4 step 1), on a real node: through
  `config/runtime.exs` and `/proc/cmdline`, which the host tests cannot reach.

  The e2e image carries its own CA and the harness key, so this checks the
  image-plus-cmdline cases; a public image, with neither, is the harness step
  of milestone 2.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Artifacts, Key}
  alias Cubi.Pki.Archive

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  setup_all do
    base = Path.join(System.tmp_dir!(), "cubi_m2_cmdline_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    keys =
      for name <- [:a, :b], into: %{} do
        dir = Path.join(base, Atom.to_string(name))
        File.mkdir_p!(dir)
        File.chmod!(dir, 0o700)

        {_, 0} =
          System.cmd("ssh-keygen", [
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "m2-#{name}",
            "-f",
            Path.join(dir, "id_ed25519")
          ])

        [type, b64 | _] = Path.join(dir, "id_ed25519.pub") |> File.read!() |> String.split()
        {name, %{dir: dir, arg: "cubi.ssh=#{type}:#{b64}", line: "#{type} #{b64}"}}
      end

    {:ok, image_hex} =
      Key.pki_dir()
      |> Cubi.Pki.paths()
      |> Map.fetch!(:ca_cert)
      |> File.read!()
      |> Cubi.Pki.cert_sha256()

    {:ok, keys: keys, image_hex: image_hex, archive: archive(base)}
  end

  # Signed by the image's own CA, with a manifest no node accepts: it gets
  # past step 1 only when the trusted root is the image's.
  defp archive(base) do
    manifest = JSON.encode!(%{"format" => 1, "files" => %{}})

    {:ok, signed} =
      Archive.sign(%{"manifest.json" => manifest}, Cubi.Pki.load_signer!(Key.pki_dir()))

    path = Path.join(base, "probe.tar.gz")
    Archive.write!(path, signed)
    File.read!(path)
  end

  defp boot!(context, name, args) do
    start_vm!(context, %VM{
      name: name,
      memory: 512,
      boot:
        {:direct, Artifacts.kernel!(),
         [Artifacts.stage1!(), {"/rootfs.squashfs", {:file, Artifacts.rootfs!()}, 0o644}],
         Artifacts.cmdline("console=ttyS0 " <> args)}
    })
  end

  defp deploy_log(vm) do
    Node.eval(vm, ~S"""
    RingLogger.get()
    |> Enum.map(&IO.chardata_to_string(&1.message))
    |> Enum.filter(&String.starts_with?(&1, "deploy: "))
    """)
  end

  test "cubi.ssh= adds its key to the image's; any other key is refused", context do
    vm = boot!(context, "ssh", context.keys.a.arg)

    # Node.eval logs in with the harness key, compiled into the image.
    keys = Node.eval(vm, "Application.get_env(:nerves_ssh, :authorized_keys)")
    assert context.keys.a.line in keys
    assert Enum.any?(keys, &String.starts_with?(&1, "ssh-ed25519 "))
    refute context.keys.b.line in keys

    assert Node.login(vm, context.keys.a.dir) == :ok
    assert {:error, _} = Node.login(vm, context.keys.b.dir)
  end

  test "cubi.ca= pinning another root than the image's refuses every release", context do
    other = :crypto.hash(:sha256, "another root") |> Base.encode16(case: :lower)
    vm = boot!(context, "ca-mismatch", "cubi.ca=sha256:#{other}")

    assert Enum.any?(deploy_log(vm), &(&1 =~ "every release will be refused"))

    {lines, status} = Node.subsystem(vm, "cubi_deploy", context.archive)
    assert status != 0
    assert List.last(lines) =~ ~r/^error .*ca_pin_mismatch/
  end

  test "cubi.ca= pinning the image's own root changes nothing", context do
    vm = boot!(context, "ca-match", "cubi.ca=sha256:#{context.image_hex}")

    assert "deploy: releases trusted from /etc/cubi/ca.pem" in deploy_log(vm)

    # Past the trusted root and the signature: refused for its manifest only.
    {lines, status} = Node.subsystem(vm, "cubi_deploy", context.archive)
    assert status != 0
    last = List.last(lines)
    assert last =~ ~r/^error /
    refute last =~ ~r/ca_pin|trusted_ca|signer|signature/
  end
end
