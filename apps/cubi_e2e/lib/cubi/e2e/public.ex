defmodule Cubi.E2E.Public do
  @moduledoc """
  The public directory the milestone 2 tests boot (docs/specs.md §2.12.1),
  `_build/x86_64_public/ipxe/`: built here, with `MIX_TARGET=x86_64
  MIX_ENV=public mix firmware.ipxe --public` in apps/cubi_fw, when it is not
  there yet. Unsigned: stock iPXE does not check signatures.

  A directory already there is used as it is, whoever built it (a signed
  release build, for instance), so delete it to test a change to the image.
  """

  @root Path.expand("../../../../..", __DIR__)

  @spec dir() :: Path.t()
  def dir(), do: Path.join([@root, "_build", "x86_64_public", "ipxe"])

  @doc "The directory, built first if missing. The first build compiles for a while."
  @spec ensure!() :: Path.t()
  def ensure!() do
    if not File.exists?(Path.join(dir(), "rootfs.squashfs")), do: build!()
    dir()
  end

  @doc "Builds it, replacing what is there."
  @spec build!() :: Path.t()
  def build!() do
    env = [
      {"MIX_TARGET", "x86_64"},
      {"MIX_ENV", "public"},
      {"BR2_PRIMARY_SITE", System.get_env("BR2_PRIMARY_SITE", "https://sources.buildroot.net")}
    ]

    case System.cmd("mix", ["firmware.ipxe", "--public"],
           cd: Path.join(@root, "apps/cubi_fw"),
           env: env,
           stderr_to_stdout: true
         ) do
      {_, 0} -> dir()
      {out, status} -> raise "mix firmware.ipxe --public exited #{status}:\n#{out}"
    end
  end
end
