defmodule Kubex.E2E.Ipxe do
  @moduledoc """
  The `ipxe.efi` UEFI PXE boots chainload (docs/phase4.md): OVMF's own PXE
  client can only run an EFI binary. BIOS boots use QEMU's iPXE NIC ROM and
  need nothing.

  `KUBEX_E2E_IPXE_EFI` names one; otherwise it is `priv/ipxe/ipxe.efi`,
  fetched once by `mix kubex.e2e.ipxe` from Ubuntu's `ipxe` package. Phase 5
  builds kubex's own iPXE.
  """

  @path Path.expand("../../../priv/ipxe/ipxe.efi", __DIR__)

  @doc "Where `mix kubex.e2e.ipxe` puts it."
  @spec default_path() :: Path.t()
  def default_path(), do: @path

  @spec efi!() :: Path.t()
  def efi!() do
    path = System.get_env("KUBEX_E2E_IPXE_EFI") || @path

    if not File.regular?(path),
      do: raise("no #{path}: run `mix kubex.e2e.ipxe` in apps/kubex_e2e")

    path
  end
end
