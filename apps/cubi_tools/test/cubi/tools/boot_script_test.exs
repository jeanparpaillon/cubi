defmodule Cubi.Tools.BootScriptTest do
  use ExUnit.Case, async: true

  alias Cubi.Tools.BootScript

  doctest BootScript

  @moduletag :tmp_dir

  setup_all do
    base = Path.join(System.tmp_dir!(), "cubi_boot_script_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    Cubi.Pki.gen_ca!(base)
    ca = File.read!(Cubi.Pki.paths(base).ca_cert)
    {:ok, ca_hex} = Cubi.Pki.cert_sha256(ca)
    %{ca: ca, ca_hex: ca_hex}
  end

  @rootfs_hex String.duplicate("ab", 32)
  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl jean@host"

  setup %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "SHA256SUMS"),
      "#{String.duplicate("cd", 32)}  vmlinuz\n#{@rootfs_hex}  rootfs.squashfs\n"
    )

    %{local: dir}
  end

  defp render(ctx, opts) do
    BootScript.render(
      Keyword.merge(
        [
          image: "https://images.example/cubi/0.1.0/",
          local: ctx.local,
          ca: ctx.ca,
          ssh_keys: [@ed25519]
        ],
        opts
      )
    )
  end

  test "the script: base URL, the pins, the key without its comment", ctx do
    assert render(ctx, []) ==
             {:ok,
              """
              #!ipxe
              set base https://images.example/cubi/0.1.0
              kernel ${base}/vmlinuz console=ttyS0 cubi.rootfs=sha256:#{@rootfs_hex} cubi.ca=sha256:#{ctx.ca_hex} cubi.ssh=ssh-ed25519:AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
              initrd ${base}/stage1.cpio.zst
              initrd ${base}/rootfs.squashfs /rootfs.squashfs
              boot
              """}
  end

  test "the rootfs pin comes from the image's own SHA256SUMS over HTTPS by default", ctx do
    get = fn "https://images.example/cubi/0.1.0/SHA256SUMS" ->
      {:ok, "#{@rootfs_hex}  rootfs.squashfs\n"}
    end

    assert {:ok, script} =
             BootScript.render(
               image: "https://images.example/cubi/0.1.0",
               ca: ctx.ca,
               ssh_keys: [@ed25519],
               get: get
             )

    assert script =~ "cubi.rootfs=sha256:#{@rootfs_hex}"
  end

  test "an http:// image needs a local copy to read the pins from", ctx do
    assert {:error, {:not_https, _}} =
             BootScript.render(image: "http://10.0.2.2:8000", ca: ctx.ca, ssh_keys: [@ed25519])

    assert {:ok, script} = render(ctx, image: "http://10.0.2.2:8000")
    assert script =~ "set base http://10.0.2.2:8000\n"
  end

  test "several keys, in order, and extra kernel arguments first", ctx do
    rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ== other"
    {:ok, script} = render(ctx, ssh_keys: [@ed25519, rsa], cmdline: "console=tty0 quiet")

    assert script =~
             ~r/vmlinuz console=tty0 quiet cubi\.rootfs=\S+ cubi\.ca=\S+ cubi\.ssh=ssh-ed25519:\S+ cubi\.ssh=ssh-rsa:AAAAB3NzaC1yc2EAAAADAQABAAABAQ==\n/
  end

  test "no key is refused unless no_ssh; keys with no_ssh are refused", ctx do
    assert render(ctx, ssh_keys: []) == {:error, :no_ssh_keys}
    assert {:ok, script} = render(ctx, ssh_keys: [], no_ssh: true)
    refute script =~ "cubi.ssh="
    assert render(ctx, no_ssh: true) == {:error, :ssh_keys_with_no_ssh}
  end

  test "malformed keys, a missing rootfs sum and a bad CA are refused", ctx do
    assert render(ctx, ssh_keys: ["ssh-ed25519"]) == {:error, {:bad_ssh_key, "ssh-ed25519"}}

    assert render(ctx, ssh_keys: ["ssh-ed25519 a:b"]) ==
             {:error, {:bad_ssh_key, "ssh-ed25519 a:b"}}

    assert render(ctx, ca: "junk") == {:error, :bad_ca_certificate}

    File.write!(Path.join(ctx.local, "SHA256SUMS"), "#{@rootfs_hex}  vmlinuz\n")
    assert render(ctx, []) == {:error, {:not_in_sha256sums, "rootfs.squashfs"}}
  end

  test "2048 bytes: vmlinuz prefix, cmdline and NUL; one byte over is refused", ctx do
    {:ok, script} = render(ctx, [])
    [_, cmdline] = Regex.run(~r/kernel \$\{base\}\/vmlinuz (.*)\n/, script)
    used = BootScript.cmdline_bytes(cmdline)
    assert used == byte_size("vmlinuz ") + byte_size(cmdline) + 1

    # Pad the leading arguments to land exactly on the limit, then one past it.
    pad = fn n -> "console=ttyS0 x=" <> String.duplicate("y", n) end
    fits = 2048 - used - byte_size(" x=")
    assert {:ok, _} = render(ctx, cmdline: pad.(fits))
    assert render(ctx, cmdline: pad.(fits + 1)) == {:error, {:cmdline_too_long, 2049, 2048}}
  end

  test "RSA keys fill the cmdline fast: four 4096-bit ones do not fit", ctx do
    rsa4096 = "ssh-rsa " <> Base.encode64(:crypto.strong_rand_bytes(535))

    assert {:error, {:cmdline_too_long, _, 2048}} =
             render(ctx, ssh_keys: List.duplicate(rsa4096, 4))
  end
end
