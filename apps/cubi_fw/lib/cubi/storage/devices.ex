defmodule Cubi.Storage.Devices do
  @moduledoc """
  The by-id names udev would give each disk, built from sysfs, since Nerves
  runs no udev and has no `/dev/disk/by-id` (docs/specs.md §2.10.3). The rules
  are those of systemd's `60-persistent-storage.rules`:

  | Disk | Names | sysfs |
  | --- | --- | --- |
  | virtio-blk | `virtio-<serial>` | `vd*/serial` |
  | NVMe | `nvme-<model>_<serial>` (namespace 1), `nvme-<model>_<serial>_<nsid>`, `nvme-<wwid>` | `nvme*n*/device/{model,serial}`, `nvme*n*/{nsid,wwid}` |
  | SCSI, SATA | `wwn-0x<naa>` | `sd*/device/wwid` |

  Values are trimmed, whitespace runs become one `_`, and ASCII characters
  udev doesn't allow in a link name become `_`. A name that more than one disk
  answers to resolves to none of them.

  Not covered: `ata-<model>_<serial>` and `scsi-…`, which udev reads from the
  disk itself (`ata_id`, `scsi_id`) rather than from sysfs.
  """

  alias Cubi.Storage.Args

  @doc """
  By-id name => kernel names (more than one when ambiguous), for every whole
  disk under `<sys>/block`.
  """
  @spec names(Path.t()) :: %{String.t() => [String.t()]}
  def names(sys \\ "/sys") do
    block = Path.join(sys, "block")

    case File.ls(block) do
      {:ok, disks} -> disks
      {:error, _} -> []
    end
    |> Enum.sort()
    |> Enum.flat_map(fn disk ->
      for name <- disk_names(Path.join(block, disk), disk), do: {name, disk}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Turns parsed `cubi.vdevs=` into `zpool create` arguments, each device
  resolved to its `/dev` node.
  """
  @spec resolve([Args.vdev()], Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def resolve(vdevs, sys \\ "/sys") do
    names = names(sys)

    Enum.reduce_while(vdevs, {:ok, []}, fn
      {:keyword, k}, {:ok, acc} ->
        {:cont, {:ok, [k | acc]}}

      {:device, name}, {:ok, acc} ->
        case Map.get(names, name) do
          [disk] -> {:cont, {:ok, ["/dev/" <> disk | acc]}}
          nil -> {:halt, {:error, {:unknown_device, name, Map.keys(names)}}}
          disks -> {:halt, {:error, {:ambiguous_device, name, disks}}}
        end
    end)
    |> case do
      {:ok, args} -> {:ok, Enum.reverse(args)}
      error -> error
    end
  end

  defp disk_names(dir, "vd" <> _) do
    for serial <- attr(dir, "serial"), do: "virtio-" <> serial
  end

  # nvme0n1, not the per-path nvme0c0n1 of a multipath namespace.
  defp disk_names(dir, "nvme" <> rest) do
    if Regex.match?(~r/^\d+n\d+$/, rest) do
      wwid = for w <- attr(dir, "wwid"), do: "nvme-" <> w

      serial =
        with [model] <- attr(dir, "device/model"),
             [serial] <- attr(dir, "device/serial"),
             [nsid] <- attr(dir, "nsid") do
          id = "nvme-#{model}_#{serial}"
          if nsid == "1", do: [id, "#{id}_#{nsid}"], else: ["#{id}_#{nsid}"]
        else
          _ -> []
        end

      wwid ++ serial
    else
      []
    end
  end

  defp disk_names(dir, "sd" <> _) do
    for "naa." <> hex <- attr(dir, "device/wwid"), do: "wwn-0x" <> hex
  end

  defp disk_names(_dir, _disk), do: []

  # [] for a missing or blank attribute, else its escaped value.
  defp attr(dir, name) do
    with {:ok, value} <- File.read(Path.join(dir, name)),
         value when value != "" <- escape(value) do
      [value]
    else
      _ -> []
    end
  end

  # udev: whitespace runs to one "_", then ASCII outside its allowed set;
  # non-ASCII UTF-8 is kept.
  defp escape(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/[^0-9A-Za-z#+\-.:=@_\x{80}-\x{10FFFF}]/u, "_")
  end
end
