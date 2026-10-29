defmodule Cubi.E2E.Milestone2PublicImageTest do
  @moduledoc """
  docs/milestone2.md, `mix firmware.ipxe --public` (docs/specs.md §2.12.1):
  the public rootfs carries no CA and no ssh key, and a node booted from it
  is configured by its cmdline alone: logins from `cubi.ssh=`, releases
  trusted through `cubi.ca=` and the archive's `ca.pem`.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.{Artifacts, Hello, Key}

  @moduletag e2e: :tier1
  @moduletag timeout: 600_000

  setup_all do
    public = Artifacts.public_dir!()
    rootfs = Path.join(public, "rootfs.squashfs")

    base = Path.join(System.tmp_dir!(), "cubi_m2_public_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    other = Path.join(base, "other")
    Cubi.Pki.gen_ca!(other, name: "other")

    stranger = Path.join(base, "stranger")
    File.mkdir_p!(stranger)
    File.chmod!(stranger, 0o700)

    {_, 0} =
      System.cmd("ssh-keygen", [
        "-q",
        "-t",
        "ed25519",
        "-N",
        "",
        "-f",
        Path.join(stranger, "id_ed25519")
      ])

    {:ok,
     public: public,
     rootfs: rootfs,
     rootfs_hex: :crypto.hash(:sha256, File.read!(rootfs)) |> Base.encode16(case: :lower),
     ca_hex: ca_hex(Key.pki_dir()),
     other: other,
     stranger: stranger}
  end

  defp ca_hex(pki) do
    {:ok, hex} =
      pki |> Cubi.Pki.paths() |> Map.fetch!(:ca_cert) |> File.read!() |> Cubi.Pki.cert_sha256()

    hex
  end

  defp harness_key_arg() do
    [type, b64 | _] = Key.public_key_path() |> File.read!() |> String.split()
    "cubi.ssh=#{type}:#{b64}"
  end

  defp boot!(context, name, args) do
    start_vm!(context, %VM{
      name: name,
      memory: 1024,
      boot:
        {:direct, Path.join(context.public, "vmlinuz"),
         [
           Path.join(context.public, "stage1.cpio.zst"),
           {"/rootfs.squashfs", {:file, context.rootfs}, 0o644}
         ], Artifacts.cmdline("console=ttyS0 cubi.rootfs=sha256:#{context.rootfs_hex} " <> args)}
    })
  end

  test "the public rootfs lists no /etc/cubi/ca.pem, and its nerves_ssh config holds no key",
       context do
    {listing, 0} = System.cmd("unsquashfs", ["-n", "-l", context.rootfs])
    refute listing =~ "etc/cubi/ca.pem"

    [_erts, vsn] =
      System.cmd("unsquashfs", ["-cat", context.rootfs, "srv/erlang/releases/start_erl.data"])
      |> elem(0)
      |> String.split()

    {sys_config, 0} =
      System.cmd("unsquashfs", ["-cat", context.rootfs, "srv/erlang/releases/#{vsn}/sys.config"])

    path = Path.join(context.dir, "sys.config")
    File.write!(path, sys_config)
    {:ok, [config]} = :file.consult(path)
    ssh = Keyword.get(config, :nerves_ssh, [])
    assert Keyword.get(ssh, :authorized_keys, []) == []
    assert Keyword.get(ssh, :user_passwords, []) == []

    for file <- ~w(vmlinuz stage1.cpio.zst rootfs.squashfs boot.ipxe base.json SHA256SUMS),
        do: assert(File.exists?(Path.join(context.public, file)))
  end

  test "configured by its cmdline: the pinned root's release runs, another key and root do not",
       context do
    vm = boot!(context, "public", "cubi.ca=sha256:#{context.ca_hex} " <> harness_key_arg())

    # Built against the public base.json, signed with the test CA: ca.pem inside.
    v1 = Hello.build!("0.1.0", :ok, context.public)
    # Up and answering ssh before the deploy, however fast the build was.
    assert Node.eval(vm, ":ok") == :ok
    {out, status} = Hello.deploy(vm, v1)
    assert status == 0, out
    assert out =~ "ok hello 0.1.0"

    assert Node.eval(vm, "if Code.ensure_loaded?(Hello), do: Hello.version()") == "0.1.0"

    # Correctly signed under its own ca.pem, which is not the pinned root.
    v2 = Hello.build!("0.2.0", :ok, context.public, signer: context.other)
    {out, status} = Hello.deploy(vm, v2)
    assert status != 0
    assert out =~ "archive_ca_not_pinned"
    assert Node.eval(vm, "Cubi.Deploy.state().current") == "0.1.0"

    assert {:error, _} = Node.login(vm, context.stranger)
  end

  test "no cubi.ssh=: every key is refused", context do
    vm = boot!(context, "public-nossh", "cubi.ca=sha256:#{context.ca_hex}")
    Console.await(vm, ~r/Interactive Elixir/, 120_000)

    # The daemon is up and answers, but takes no key, not even the harness's.
    deadline = System.monotonic_time(:millisecond) + 60_000

    result =
      Stream.repeatedly(fn -> Node.login(vm, Key.dir()) end)
      |> Enum.find(fn r ->
        auth_refused?(r) or System.monotonic_time(:millisecond) > deadline or
          (Process.sleep(1_000) && false)
      end)

    assert auth_refused?(result), inspect(result)
  end

  defp auth_refused?({:error, reason}),
    do: inspect(reason) =~ "Unable to connect using the available authentication methods"

  defp auth_refused?(_), do: false
end
