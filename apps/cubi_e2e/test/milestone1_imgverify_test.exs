defmodule Cubi.E2E.Milestone1ImgverifyTest do
  @moduledoc """
  docs/milestone1.md, acceptance: with the custom iPXE, a node boots the signed
  directory, and a one-byte change to `rootfs.squashfs` makes it refuse to
  boot (docs/specs.md §2.11.2).

  Each test serves a copy of `_build/x86_64_e2e/ipxe/` (symlinks, except what
  it changes) whose `boot.ipxe` has the `imgverify` lines, as
  `mix firmware.ipxe --imgverify` writes them. The trusted iPXE comes from
  `mix cubi.e2e.ipxe`.
  """
  use Cubi.E2E.Case

  alias Cubi.E2E.Artifacts

  @moduletag e2e: :tier1
  @moduletag timeout: 300_000

  @images ~w(vmlinuz stage1.cpio.zst rootfs.squashfs)

  # What iPXE prints when imgverify fails, whatever the reason; a stock build
  # without IMAGE_TRUST_CMD (Ubuntu's) does not even have the command.
  @refused ~r/Could not verify|imgverify: command not found/

  setup_all do
    {:ok, served: Artifacts.served_dir!()}
  end

  for firmware <- [:bios, :uefi] do
    test "#{firmware}: the trusted iPXE verifies the signed images and boots them", context do
      dir = serve!(context, "signed")

      vm =
        start_vm!(context, %VM{
          name: "m1-#{unquote(firmware)}",
          firmware: unquote(firmware),
          ipxe: :trusted,
          boot: {:pxe, :tftp, dir}
        })

      Console.await(vm, ~r/Interactive Elixir/, 90_000)
      refute Console.output(vm) =~ @refused
    end
  end

  test "a one-byte change to rootfs.squashfs is refused before the kernel starts", context do
    dir =
      serve!(context, "tampered", fn dir ->
        rootfs = Path.join(dir, "rootfs.squashfs")
        File.rm!(rootfs)
        File.cp!(Path.join(context.served, "rootfs.squashfs"), rootfs)
        flip_last_byte!(rootfs)
      end)

    assert_refused(context, "m1-tampered", :trusted, dir)
  end

  test "images signed by another CA's signer are refused", context do
    other = Path.join(context.dir, "other-pki")
    Cubi.Pki.gen_ca!(other, name: "other")

    dir =
      serve!(context, "other-ca", fn dir ->
        for image <- @images, do: File.rm!(Path.join(dir, image <> ".sig"))
        Cubi.Pki.Cms.sign!(Enum.map(@images, &Path.join(dir, &1)), other)
      end)

    assert_refused(context, "m1-other-ca", :trusted, dir)
  end

  test "a stock iPXE, which does not trust the test CA, refuses the signed images", context do
    assert_refused(context, "m1-stock", :stock, serve!(context, "stock"))
  end

  defp assert_refused(context, name, ipxe, dir) do
    vm = start_vm!(context, %VM{name: name, ipxe: ipxe, boot: {:pxe, :tftp, dir}})

    Console.await(vm, @refused, 60_000)
    # Long enough for the kernel to print its banner, had iPXE booted it.
    Process.sleep(5_000)
    refute Console.output(vm) =~ "Linux version"
  end

  # A served directory: symlinks to the e2e build, boot.ipxe with imgverify
  # lines, then `change` applied.
  defp serve!(context, name, change \\ fn _ -> :ok end) do
    dir = Path.join(context.dir, name)
    File.mkdir_p!(dir)

    for file <- File.ls!(context.served),
        file != "boot.ipxe",
        do: File.ln_s!(Path.join(context.served, file), Path.join(dir, file))

    File.write!(
      Path.join(dir, "boot.ipxe"),
      imgverify(File.read!(Path.join(context.served, "boot.ipxe")))
    )

    change.(dir)
    dir
  end

  # The e2e build's boot.ipxe has no imgverify lines, so stock iPXE can boot it
  # (docs/phase4.md); add them after each image, as
  # `Cubi.Ipxe.boot_script(meta, cmdline, imgverify: true)` does.
  defp imgverify(script) do
    script = Regex.replace(~r/^(kernel|initrd) (\S+)(.*)$/m, script, "\\0\nimgverify \\2 \\2.sig")
    for image <- @images, do: assert(script =~ "\nimgverify #{image} #{image}.sig\n")
    script
  end

  defp flip_last_byte!(path) do
    size = File.stat!(path).size
    {:ok, io} = :file.open(path, [:read, :write, :binary])
    {:ok, <<byte>>} = :file.pread(io, size - 1, 1)
    :ok = :file.pwrite(io, size - 1, <<Bitwise.bxor(byte, 1)>>)
    :ok = :file.close(io)
  end
end
