defmodule Kubex.E2E.Ipxe do
  @moduledoc """
  The `ipxe.efi` UEFI PXE boots chainload (docs/phase4.md): OVMF's own PXE
  client can only run an EFI binary. BIOS boots use QEMU's iPXE NIC ROM and
  need nothing.

  `KUBEX_E2E_IPXE_EFI` names one; otherwise it is `priv/ipxe/ipxe.efi`,
  fetched once by `mix kubex.e2e.ipxe` from Ubuntu's `ipxe` package.

  **The trusted iPXE** is kubex's own build (`Kubex.Tools.Ipxe`), trusting only
  the test CA, with `imgverify` (docs/specs.md §2.11.2). `mix kubex.e2e.ipxe`
  builds it into `priv/ipxe/trusted/` (`KUBEX_E2E_IPXE_TRUSTED` names another
  directory); VMs use it with `ipxe: :trusted`.
  """

  @path Path.expand("../../../priv/ipxe/ipxe.efi", __DIR__)
  @trusted Path.expand("../../../priv/ipxe/trusted", __DIR__)

  @doc "Where `mix kubex.e2e.ipxe` puts it."
  @spec default_path() :: Path.t()
  def default_path(), do: @path

  @doc "Where `mix kubex.e2e.ipxe` builds the trusted iPXE."
  @spec default_trusted_dir() :: Path.t()
  def default_trusted_dir(), do: @trusted

  @spec trusted_dir() :: Path.t()
  def trusted_dir(), do: System.get_env("KUBEX_E2E_IPXE_TRUSTED") || @trusted

  @doc "A trusted iPXE binary's path, whether it exists or not."
  @spec trusted_path(String.t()) :: Path.t()
  def trusted_path(name), do: Path.join(trusted_dir(), name)

  @doc "A trusted iPXE binary's path; raises if it was not built."
  @spec trusted!(String.t()) :: Path.t()
  def trusted!(name) do
    path = trusted_path(name)

    if not File.regular?(path),
      do: raise("no #{path}: run `mix kubex.e2e.ipxe` in apps/kubex_e2e")

    path
  end

  @spec efi!() :: Path.t()
  def efi!() do
    path = System.get_env("KUBEX_E2E_IPXE_EFI") || @path

    if not File.regular?(path),
      do: raise("no #{path}: run `mix kubex.e2e.ipxe` in apps/kubex_e2e")

    path
  end
end
