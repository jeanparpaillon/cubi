defmodule Kubex.Pki.CmsTest do
  use ExUnit.Case, async: true

  alias Kubex.Pki
  alias Kubex.Pki.Cms

  @moduletag :tmp_dir

  setup_all do
    base = Path.join(System.tmp_dir!(), "kubex_cms_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    dir = Path.join(base, "pki")
    other = Path.join(base, "other")
    Pki.gen_ca!(dir)
    Pki.gen_ca!(other, name: "other")

    %{pki: dir, other: other}
  end

  setup %{tmp_dir: tmp} do
    paths = for name <- ~w(vmlinuz rootfs.squashfs), do: Path.join(tmp, name)
    for path <- paths, do: File.write!(path, :crypto.strong_rand_bytes(4096))
    %{images: paths}
  end

  test "writes a .sig per file, which verifies against the root", %{pki: dir, images: images} do
    assert Cms.sign!(images, dir) == Enum.map(images, &(&1 <> ".sig"))

    for image <- images do
      assert Cms.verify(image, image <> ".sig", Pki.paths(dir).ca_cert) == :ok
    end
  end

  test "a changed byte fails", %{pki: dir, images: [image | _]} do
    [sig] = Cms.sign!([image], dir)
    <<first, rest::binary>> = File.read!(image)
    File.write!(image, <<Bitwise.bxor(first, 1), rest::binary>>)

    assert {:error, _} = Cms.verify(image, sig, Pki.paths(dir).ca_cert)
  end

  test "another root fails", %{pki: dir, other: other, images: [image | _]} do
    [sig] = Cms.sign!([image], dir)

    assert {:error, _} = Cms.verify(image, sig, Pki.paths(other).ca_cert)
  end

  test "carries the signer certificate and no signed attributes", %{pki: dir, images: [image | _]} do
    [sig] = Cms.sign!([image], dir)

    {out, 0} =
      System.cmd("openssl", ~w(cms -cmsout -print -inform DER -in) ++ [sig])

    assert out =~ "CN=kubex signer"
    assert out =~ "signedAttrs:\n          <ABSENT>"
  end
end
