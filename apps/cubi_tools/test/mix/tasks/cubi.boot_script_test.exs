defmodule Mix.Tasks.Cubi.BootScriptTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Cubi.BootScript

  @moduletag :tmp_dir

  setup_all do
    base =
      Path.join(System.tmp_dir!(), "cubi_boot_script_task_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base) end)
    Cubi.Pki.gen_ca!(base)
    %{pki: base}
  end

  setup %{tmp_dir: dir} do
    image = Path.join(dir, "image")
    File.mkdir_p!(image)

    File.write!(
      Path.join(image, "SHA256SUMS"),
      "#{String.duplicate("ab", 32)}  rootfs.squashfs\n"
    )

    key = Path.join(dir, "id_ed25519.pub")
    File.write!(key, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsab me@host\n")

    %{image: image, key: key}
  end

  defp args(ctx, extra),
    do:
      ["--image", "http://10.0.2.2:8000", "--local", ctx.image, "--ca", ctx.pki, "--ssh", ctx.key] ++
        extra

  test "prints the script, and only the script, on stdout", ctx do
    out = capture_io(fn -> BootScript.run(args(ctx, [])) end)
    assert out =~ ~r/\A#!ipxe\nset base http:\/\/10\.0\.2\.2:8000\n/
    assert out =~ "cubi.ssh=ssh-ed25519:AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsab"
  end

  test "--output writes the file, private, and nothing on stdout", ctx do
    path = Path.join(ctx.tmp_dir, "n1.ipxe")
    assert capture_io(fn -> BootScript.run(args(ctx, ["--output", path])) end) == ""
    assert File.read!(path) =~ "#!ipxe"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "a cmdline over 2048 bytes exits non-zero and prints nothing on stdout", ctx do
    long = "console=ttyS0 x=" <> String.duplicate("y", 2000)

    out =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/2048/, fn -> BootScript.run(args(ctx, ["--cmdline", long])) end
      end)

    assert out == ""
  end

  test "refusals: --ssh with --no-ssh, a missing CA, an http:// image without --local", ctx do
    assert_raise Mix.Error, ~r/--ssh and --no-ssh/, fn ->
      BootScript.run(args(ctx, ["--no-ssh"]))
    end

    assert_raise Mix.Error, ~r/mix cubi.gen_ca/, fn ->
      BootScript.run(["--image", "https://x/1", "--ca", ctx.tmp_dir, "--ssh", ctx.key])
    end

    assert_raise Mix.Error, ~r/not https:\/\/.*--local/, fn ->
      BootScript.run(["--image", "http://10.0.2.2:8000", "--ca", ctx.pki, "--ssh", ctx.key])
    end
  end

  test "--no-ssh renders a script without keys", ctx do
    out =
      capture_io(fn ->
        BootScript.run(["--image", "http://h", "--local", ctx.image, "--ca", ctx.pki, "--no-ssh"])
      end)

    refute out =~ "cubi.ssh="
  end

  test "a version is looked up through :image_base, by default the project's GitHub releases" do
    on_exit(fn -> Application.delete_env(:cubi_tools, :image_base) end)

    assert BootScript.image!("0.2.0") ==
             "https://github.com/jeanparpaillon/cubi/releases/download/v0.2.0"

    assert BootScript.image!("v0.2.0") == BootScript.image!("0.2.0")
    assert BootScript.image!("https://other/x") == "https://other/x"

    Application.put_env(:cubi_tools, :image_base, "https://images.example/cubi/")
    assert BootScript.image!("0.2.0") == "https://images.example/cubi/0.2.0"

    Application.put_env(:cubi_tools, :image_base, "https://cdn.example/cubi-{version}/img")
    assert BootScript.image!("0.2.0") == "https://cdn.example/cubi-0.2.0/img"
  end
end
