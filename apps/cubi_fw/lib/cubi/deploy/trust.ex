defmodule Cubi.Deploy.Trust do
  @moduledoc """
  The root a release is verified against, step 1 of docs/specs.md §2.11.4:

  | Image CA (`/etc/cubi/ca.pem`) | `cubi.ca=` pin | Trusted root |
  | --- | --- | --- |
  | yes | none | the image's |
  | yes | matches it | the image's |
  | yes | another root | none: every release is refused |
  | no | yes | the archive's `ca.pem`, if its SHA-256 equals the pin |
  | no | none | none: every release is refused |

  A pin is `cubi.ca=sha256:<64 lowercase hex digits>`; the last one on the
  cmdline counts. A malformed pin refuses every release rather than being
  ignored: it was meant to restrict trust.
  """

  alias Cubi.Pki.Archive

  @type pin :: nil | {:ok, String.t()} | {:error, {:bad_ca_pin, String.t() | nil}}

  @doc "The `cubi.ca=` pin of a parsed cmdline (`Cubi.Cmdline`)."
  @spec pin([Cubi.Cmdline.arg()]) :: pin()
  def pin(cmdline) do
    case for({"cubi.ca", _} = arg <- cmdline, do: arg) |> List.last() do
      nil -> nil
      {_, value} -> parse_pin(value)
    end
  end

  defp parse_pin("sha256:" <> hex = value) do
    if byte_size(hex) == 64 and hex =~ ~r/\A[0-9a-f]+\z/,
      do: {:ok, hex},
      else: {:error, {:bad_ca_pin, value}}
  end

  defp parse_pin(value), do: {:error, {:bad_ca_pin, value}}

  @doc """
  The trusted root for `entries` (`Cubi.Pki.Archive`), given the image's CA
  (its PEM, or `nil`) and the pin.
  """
  @spec root(String.t() | nil, pin(), Archive.entries()) :: {:ok, String.t()} | {:error, term()}
  def root(_image_ca, {:error, _} = bad, _entries), do: bad

  def root(image_ca, pin, entries) do
    case conflict(image_ca, pin) do
      :ok -> do_root(image_ca, pin, entries)
      error -> error
    end
  end

  defp do_root(image_ca, _pin, _entries) when is_binary(image_ca), do: {:ok, image_ca}
  defp do_root(nil, nil, _entries), do: {:error, :no_trusted_ca}

  defp do_root(nil, {:ok, hex}, entries) do
    case Archive.ca(entries) do
      nil ->
        {:error, :no_archive_ca}

      pem ->
        case Cubi.Pki.cert_sha256(pem) do
          {:ok, ^hex} -> {:ok, pem}
          {:ok, other} -> {:error, {:archive_ca_not_pinned, other}}
          {:error, _} -> {:error, :bad_archive_ca}
        end
    end
  end

  @doc """
  `:ok` unless the image's CA and the pin name different roots, or the pin is
  malformed: then every release is refused, and the node says so at boot.
  """
  @spec conflict(String.t() | nil, pin()) :: :ok | {:error, term()}
  def conflict(_image_ca, {:error, _} = bad), do: bad

  def conflict(image_ca, {:ok, hex}) when is_binary(image_ca) do
    case Cubi.Pki.cert_sha256(image_ca) do
      {:ok, ^hex} -> :ok
      {:ok, image} -> {:error, {:ca_pin_mismatch, image: image, pin: hex}}
      {:error, _} -> {:error, :bad_image_ca}
    end
  end

  def conflict(_image_ca, _pin), do: :ok
end
