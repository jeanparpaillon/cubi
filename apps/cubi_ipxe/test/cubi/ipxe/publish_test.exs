defmodule Cubi.Ipxe.PublishTest do
  use ExUnit.Case, async: true

  alias Cubi.Ipxe.Publish

  @moduletag :tmp_dir

  setup_all do
    base = Path.join(System.tmp_dir!(), "cubi_publish_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    for name <- ~w(project other), do: Cubi.Pki.gen_ca!(Path.join(base, name))
    %{project: Path.join(base, "project"), other: Path.join(base, "other")}
  end

  # What `mix firmware.ipxe --public --signer` writes, in miniature: a real
  # squashfs whose release config is `ssh`, signatures by `signer`.
  defp image!(dir, opts) do
    root = Path.join(dir, "root")
    releases = Path.join(root, "srv/erlang/releases")
    File.mkdir_p!(Path.join(releases, "0.1.0"))
    File.write!(Path.join(releases, "start_erl.data"), "17.0.2 0.1.0\n")
    config = [nerves_ssh: Keyword.get(opts, :ssh, authorized_keys: [])]
    File.write!(Path.join(releases, "0.1.0/sys.config"), :io_lib.format(~c"~p.~n", [config]))

    if Keyword.get(opts, :ca_in_rootfs, false) do
      File.mkdir_p!(Path.join(root, "etc/cubi"))
      File.write!(Path.join(root, "etc/cubi/ca.pem"), "x")
    end

    out = Path.join(dir, "ipxe")
    File.mkdir_p!(out)

    {_, 0} =
      System.cmd("mksquashfs", [root, Path.join(out, "rootfs.squashfs"), "-all-root", "-quiet"])

    File.write!(Path.join(out, "vmlinuz"), "kernel")
    File.write!(Path.join(out, "stage1.cpio.zst"), "stage1")
    File.write!(Path.join(out, "boot.ipxe"), "#!ipxe\nboot\n")

    File.write!(
      Path.join(out, "base.json"),
      JSON.encode!(%{"firmware" => %{"version" => Keyword.get(opts, :version, "0.1.0")}})
    )

    if signer = Keyword.get(opts, :signer) do
      Cubi.Pki.Cms.sign!(
        Enum.map(~w(vmlinuz stage1.cpio.zst rootfs.squashfs), &Path.join(out, &1)),
        signer
      )
    end

    write_sums!(out)
    out
  end

  defp write_sums!(out) do
    sums =
      for name <- out |> File.ls!() |> Enum.sort(), name != "SHA256SUMS" do
        "#{:crypto.hash(:sha256, File.read!(Path.join(out, name))) |> Base.encode16(case: :lower)}  #{name}\n"
      end

    File.write!(Path.join(out, "SHA256SUMS"), sums)
  end

  defp ca(dir), do: Cubi.Pki.paths(dir).ca_cert

  test "a signed public image is staged as <version>/, boot.ipxe left out", ctx do
    from = image!(ctx.tmp_dir, signer: ctx.project)
    to = Path.join(ctx.tmp_dir, "publish")

    assert {"0.1.0", dir} = Publish.stage!(from, to, ca(ctx.project))
    assert dir == Path.join(to, "0.1.0")
    assert Enum.sort(File.ls!(dir)) == Enum.sort(["SHA256SUMS" | Publish.files()])

    {:ok, sums} = parse(File.read!(Path.join(dir, "SHA256SUMS")))
    assert Map.keys(sums) |> Enum.sort() == Enum.sort(Publish.files())

    for {name, hex} <- sums,
        do:
          assert(
            hex ==
              :crypto.hash(:sha256, File.read!(Path.join(dir, name)))
              |> Base.encode16(case: :lower)
          )
  end

  test "a version already staged is never replaced", ctx do
    from = image!(ctx.tmp_dir, signer: ctx.project)
    to = Path.join(ctx.tmp_dir, "publish")
    {_, dir} = Publish.stage!(from, to, ca(ctx.project))
    before = File.read!(Path.join(dir, "SHA256SUMS"))

    assert_raise RuntimeError, ~r/never replaced/, fn ->
      Publish.stage!(from, to, ca(ctx.project))
    end

    assert File.read!(Path.join(dir, "SHA256SUMS")) == before
  end

  test "unsigned, or signed under another root, is refused", ctx do
    to = Path.join(ctx.tmp_dir, "publish")

    unsigned = image!(Path.join(ctx.tmp_dir, "a"), [])

    assert_raise RuntimeError, ~r/not signed/, fn ->
      Publish.stage!(unsigned, to, ca(ctx.project))
    end

    other = image!(Path.join(ctx.tmp_dir, "b"), signer: ctx.other)

    assert_raise RuntimeError, ~r/does not verify/, fn ->
      Publish.stage!(other, to, ca(ctx.project))
    end

    refute File.exists?(to)
  end

  test "a file that does not match SHA256SUMS is refused", ctx do
    from = image!(ctx.tmp_dir, signer: ctx.project)
    File.write!(Path.join(from, "base.json"), ~s({"firmware": {"version": "9.9.9"}}))

    assert_raise RuntimeError, ~r/base.json does not match/, fn ->
      Publish.stage!(from, Path.join(ctx.tmp_dir, "publish"), ca(ctx.project))
    end
  end

  test "a rootfs with a CA or an ssh key is refused, nothing staged", ctx do
    to = Path.join(ctx.tmp_dir, "publish")

    with_ca = image!(Path.join(ctx.tmp_dir, "a"), signer: ctx.project, ca_in_rootfs: true)

    assert_raise RuntimeError, ~r/etc\/cubi\/ca.pem/, fn ->
      Publish.stage!(with_ca, to, ca(ctx.project))
    end

    with_key =
      image!(Path.join(ctx.tmp_dir, "b"),
        signer: ctx.project,
        ssh: [authorized_keys: ["ssh-ed25519 AAAA"]]
      )

    assert_raise RuntimeError, ~r/authorized_keys/, fn ->
      Publish.stage!(with_key, to, ca(ctx.project))
    end

    assert File.ls!(to) == []
  end

  test "--release: tag v<version> on the commit, the staged files as assets" do
    args = Mix.Tasks.Firmware.Publish.gh_args("me/cubi", "0.1.0", "/p/0.1.0", "/n", "abc123")

    assert Enum.take(args, 13) ==
             ~w(release create v0.1.0 --repo me/cubi --target abc123 --title) ++
               [
                 "cubi image 0.1.0",
                 "--notes-file",
                 "/n",
                 "/p/0.1.0/vmlinuz",
                 "/p/0.1.0/stage1.cpio.zst"
               ]

    assert length(args) == 11 + length(Publish.files()) + 1
    assert List.last(args) == "/p/0.1.0/SHA256SUMS"
  end

  defp parse(text) do
    {:ok,
     for line <- String.split(text, "\n", trim: true), into: %{} do
       [hex, name] = String.split(line, "  ", parts: 2)
       {name, hex}
     end}
  end
end
