defmodule Cubi.Tools.ImageTest do
  use ExUnit.Case, async: true

  alias Cubi.Tools.Image

  @base ~s({"format": 1, "otp_release": "29"})
  @url "https://images.example/cubi/0.1.0"

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  # A published directory as a map of file names, served by the stub; the
  # requested URLs are sent to the test process.
  defp get(files) do
    test = self()

    fn url ->
      send(test, {:get, url})

      case Map.fetch(files, String.replace_prefix(url, @url <> "/", "")) do
        {:ok, data} -> {:ok, data}
        :error -> {:error, {:http_status, 404}}
      end
    end
  end

  test "a URL's base.json, checked against SHA256SUMS" do
    files = %{
      "base.json" => @base,
      "SHA256SUMS" => "#{sha(@base)}  base.json\n#{sha("k")}  vmlinuz\n"
    }

    assert Image.base(@url, get: get(files)) == {:ok, %{"format" => 1, "otp_release" => "29"}}

    assert Image.base(@url <> "/", get: get(files)) ==
             {:ok, %{"format" => 1, "otp_release" => "29"}}

    assert_received {:get, "https://images.example/cubi/0.1.0/base.json"}
    assert_received {:get, "https://images.example/cubi/0.1.0/SHA256SUMS"}
  end

  test "a base.json that does not match SHA256SUMS, or is not listed, is refused" do
    other = ~s({"format": 1, "otp_release": "28"})

    assert {:error, {:sha256_mismatch, "base.json", listed: listed, actual: actual}} =
             Image.base(@url,
               get: get(%{"base.json" => other, "SHA256SUMS" => "#{sha(@base)}  base.json\n"})
             )

    assert {listed, actual} == {sha(@base), sha(other)}

    assert Image.base(@url,
             get: get(%{"base.json" => @base, "SHA256SUMS" => "#{sha("k")}  vmlinuz\n"})
           ) == {:error, {:not_in_sha256sums, "base.json"}}
  end

  test "a missing file names its URL" do
    assert Image.base(@url, get: get(%{})) ==
             {:error, {:fetch_failed, @url <> "/base.json", {:http_status, 404}}}

    assert Image.base(@url, get: get(%{"base.json" => @base})) ==
             {:error, {:fetch_failed, @url <> "/SHA256SUMS", {:http_status, 404}}}
  end

  test "plain http and other schemes are refused before any request" do
    for url <- ["http://images.example/cubi/0.1.0", "ftp://images.example/x"] do
      assert Image.base(url, get: fn _ -> flunk("fetched") end) == {:error, {:not_https, url}}
    end
  end

  @tag :tmp_dir
  test "a local directory is read as is, SHA256SUMS or not", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "base.json"), @base)
    assert {:ok, %{"otp_release" => "29"}} = Image.base(dir)

    File.write!(Path.join(dir, "SHA256SUMS"), "#{sha("other")}  base.json\n")
    assert {:ok, %{"otp_release" => "29"}} = Image.base(dir)

    assert Image.base(Path.join(dir, "nope")) ==
             {:error, {:fetch_failed, Path.join([dir, "nope", "base.json"]), :enoent}}
  end

  test "SHA256SUMS: sha256sum's text and binary forms; anything else is refused" do
    a = sha("a")

    assert Image.parse_sums("#{a}  vmlinuz\n#{String.upcase(a)} *rootfs.squashfs\n") ==
             {:ok, %{"vmlinuz" => a, "rootfs.squashfs" => a}}

    assert Image.parse_sums("#{a} vmlinuz") == {:error, {:bad_sha256sums, "#{a} vmlinuz"}}
    assert Image.parse_sums("abcd  vmlinuz") == {:error, {:bad_sha256sums, "abcd  vmlinuz"}}
  end

  test "malformed base.json behind a matching sum" do
    files = %{"base.json" => "[1]", "SHA256SUMS" => "#{sha("[1]")}  base.json\n"}
    assert Image.base(@url, get: get(files)) == {:error, {:bad_base_json, @url <> "/base.json"}}
  end

  # The real client against the network: excluded unless `--include network`.
  describe "https_get/1" do
    @describetag :network

    test "verifies the server certificate and follows redirects" do
      assert {:ok, _} = Image.https_get("https://github.com/")
      assert {:error, _} = Image.https_get("https://self-signed.badssl.com/")
      assert {:error, _} = Image.https_get("https://wrong.host.badssl.com/")
      assert {:error, _} = Image.https_get("https://expired.badssl.com/")
    end
  end
end
