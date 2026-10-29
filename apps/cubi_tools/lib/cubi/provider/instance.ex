defmodule Cubi.Provider.Instance do
  @moduledoc """
  An instance as a `Cubi.Provider` reports it (docs/specs.md §2.12.3).

    * `id` - the provider's own identifier
    * `name` - the cubi name, unique per provider
    * `status` - `:pending` (being created or booting), `:running`,
      `:stopped`, or `:unknown` for anything the provider reports otherwise
    * `addresses` - IP addresses as strings, public ones first
    * `image` - the image its stored script boots, the URL of its `set base`
      line (`Cubi.Tools.BootScript.image_of/1`), `nil` without one
    * `provider` - whatever else the provider module keeps about it; an
      `ssh_port` there replaces 22 (`Cubi.Tools.ProviderTask`)
  """

  @enforce_keys [:id, :name, :status]
  defstruct [:id, :name, :status, image: nil, addresses: [], provider: %{}]

  @type status :: :pending | :running | :stopped | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          status: status(),
          addresses: [String.t()],
          image: String.t() | nil,
          provider: map()
        }
end
