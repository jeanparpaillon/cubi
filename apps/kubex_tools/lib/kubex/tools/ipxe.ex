defmodule Kubex.Tools.Ipxe do
  @moduledoc """
  Builds an iPXE that trusts the operator's root CA and nothing else, with
  `imgverify` enabled (docs/specs.md §2.7, §2.11.2).

  The source is iPXE's release tarball, pinned by version and SHA-512, cached
  in `~/.cache/kubex/` (`XDG_CACHE_HOME`). It is unpacked and built in a
  directory of its own there, so later builds are incremental; iPXE's
  makefile rebuilds what depends on `TRUST=` when the CA changes.

  Two settings differ from a stock build:

    * `TRUST=<ca.pem>` - the only root iPXE trusts, for `imgverify` and for
      HTTPS alike. Without it, iPXE trusts its own project CA.
    * `IMAGE_TRUST_CMD` in `config/local/general.h` - the `imgverify` and
      `imgtrust` commands, off by default.

  Targets, by output name:

  | Output | iPXE target | For |
  | --- | --- | --- |
  | `undionly.kpxe` | `bin/undionly.kpxe` | chainloaded by a BIOS PXE ROM |
  | `ipxe.efi` | `bin-x86_64-efi/ipxe.efi` | chainloaded by UEFI PXE |
  | `1af41000.rom` | `bin/1af41000.rom` | QEMU's virtio-net option ROM (`romfile=`), for the e2e harness |
  """

  @version "2.0.0"
  @url "https://github.com/ipxe/ipxe/archive/refs/tags/v#{@version}.tar.gz"
  @sha512 "e1fc1cb2deb0bf5da62bb6d1387f6ebf6a2b085afb3e4f787f133a25c7c81f523c205279357395a45014f7f557b4960eb280e9917f4fe1f852e73ad52c05387c"

  @targets %{
    "undionly.kpxe" => "bin/undionly.kpxe",
    "ipxe.efi" => "bin-x86_64-efi/ipxe.efi",
    "1af41000.rom" => "bin/1af41000.rom"
  }

  @general_h """
  /* kubex: imgverify and imgtrust (docs/specs.md §2.11.2). */
  #define IMAGE_TRUST_CMD
  """

  @spec version() :: String.t()
  def version(), do: @version

  @doc "The output names `build!/1` knows."
  @spec targets() :: [String.t()]
  def targets(), do: @targets |> Map.keys() |> Enum.sort()

  @doc """
  Builds the targets and copies them into `:output`, with the trusted root as
  `ca.pem` next to them. Options:

    * `:ca` (required) - the root certificate to trust
    * `:output` (required) - where the binaries go
    * `:targets` - output names, default all of `targets/0`
    * `:cache` - default `~/.cache/kubex`
    * `:jobs` - `make -j`, default the number of schedulers

  Needs `make`, `gcc`, `perl` and liblzma's headers. Returns the output paths.
  """
  @spec build!(keyword()) :: [Path.t()]
  def build!(opts) do
    ca = opts |> Keyword.fetch!(:ca) |> Path.expand()
    output = opts |> Keyword.fetch!(:output) |> Path.expand()
    targets = Keyword.get(opts, :targets, targets())
    cache = Keyword.get_lazy(opts, :cache, &cache_dir/0)
    jobs = Keyword.get(opts, :jobs, System.schedulers_online())

    if not File.regular?(ca), do: raise("no #{ca}")

    src = source!(cache)
    File.write!(Path.join(src, "config/local/general.h"), @general_h)
    make!(src, make_args(targets, ca, jobs))

    File.mkdir_p!(output)
    File.cp!(ca, Path.join(output, "ca.pem"))

    for target <- targets do
      dest = Path.join(output, target)
      File.cp!(Path.join(src, Map.fetch!(@targets, target)), dest)
      dest
    end
  end

  @doc false
  @spec make_args([String.t()], Path.t(), pos_integer()) :: [String.t()]
  def make_args(targets, ca, jobs) do
    paths =
      for target <- targets do
        Map.get(@targets, target) ||
          raise ArgumentError, "unknown target #{target}; known: #{Enum.join(targets(), ", ")}"
      end

    # NO_WERROR: iPXE's -Werror trips on warnings newer compilers add; the
    # source is pinned, so a warning is never ours to fix.
    ["-j#{jobs}" | paths] ++ ["TRUST=#{ca}", "NO_WERROR=1"]
  end

  @doc false
  @spec cache_dir() :: Path.t()
  def cache_dir() do
    Path.join(System.get_env("XDG_CACHE_HOME") || Path.expand("~/.cache"), "kubex")
  end

  # The unpacked `src/` directory, downloading and checking the tarball first
  # if needed. The tarball is checked on every build, cached or not.
  defp source!(cache) do
    File.mkdir_p!(cache)
    tarball = Path.join(cache, "ipxe-#{@version}.tar.gz")
    tree = Path.join(cache, "ipxe-#{@version}")

    data =
      case File.read(tarball) do
        {:ok, data} -> data
        {:error, _} -> download!(tarball)
      end

    if sha512(data) != @sha512,
      do: raise("#{tarball} does not match the pinned SHA-512; delete it to download again")

    if not File.dir?(Path.join(tree, "src")) do
      :ok = :erl_tar.extract({:binary, data}, [:compressed, cwd: String.to_charlist(cache)])
    end

    Path.join(tree, "src")
  end

  defp download!(tarball) do
    case Mix.Utils.read_path(@url, sha512: @sha512, timeout: 120_000) do
      {:ok, data} ->
        File.write!(tarball, data)
        data

      other ->
        raise "cannot download #{@url}: #{inspect(other)}"
    end
  end

  defp sha512(data), do: :crypto.hash(:sha512, data) |> Base.encode16(case: :lower)

  defp make!(src, args) do
    make = System.find_executable("make") || raise "make not found"

    case System.cmd(make, args, cd: src, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> raise "make in #{src} exited #{status}:\n#{tail(out)}"
    end
  end

  defp tail(out), do: out |> String.split("\n") |> Enum.take(-30) |> Enum.join("\n")
end
