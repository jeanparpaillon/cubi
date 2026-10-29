# Stock Nerves systems and cubi's own

Part of the cubi node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

**Decision (2026-10-29): cubi keeps the public image + deployed release
model.** The cubi project publishes a base image per version, and operators
deploy signed releases onto it ([§2.11](specs.md), [§2.12](specs.md)). The
alternative, where each operator builds their own firmware with their app
inside (the usual Nerves model), is not taken. This note covers what that
base image may be built on. Today the only option is cubi's fork,
`cubi_system_x86_64`. A stock Nerves system (`nerves_system_x86_64`,
`nerves_system_vultr`) can carry the same `cubi_fw` app, with fewer
capabilities.

## Where the fork's delta can live

Everything cubi adds to `nerves_system_x86_64` v1.34.0, and whether it needs a
system at all:

| Delta | Needs a system? | Home with a stock system |
| --- | --- | --- |
| `erlinit.config` (no mounts, `-d /usr/bin/cubi-boardid`, `-n %s`) and `cubi-boardid` ([§2.6](specs.md)) | no | `apps/cubi_fw/rootfs_overlay`, which Nerves lays over the system's. The overlay carries the **disk** variant (cubi's boardid, the stock mounts). `mix firmware.ipxe`, which already repacks the squashfs ([§2.3](specs.md)), swaps in the **diskless** variant (no mounts) |
| stage-1 initramfs (busybox, `init`, the `cubi.rootfs=` check, [§2.4](specs.md)) | no | a static cpio built once per cubi version and published with the images. It does not depend on the kernel's version, only on the options below being built in **(verify)** |
| `BLK_DEV_INITRD`, `BLK_DEV_LOOP` | **yes**, kernel | a pull request upstream. Without them, stock systems cannot boot diskless at all |
| `SQUASHFS_XZ`/`ZSTD`, `RD_XZ`/`ZSTD` | kernel | not needed: stay on gzip (larger downloads) and an uncompressed or gzip stage-1 |
| physical NICs and disks (`igb`, `ixgbe`, `i40e`, `r8169`, `tg3`, `nvme`, `ahci`, …), `EFI_STUB`, `PSTORE*` | kernel | the same upstream PR, or go without. A stock kernel has virtio only |
| `ena` (EC2 Nitro), `ice`, `bnxt_en`, `mlx5_core` ([milestone 4](milestone4.md)) | kernel | as above |
| OpenZFS (`package/cubi-zfs`), `wipefs` ([§2.10.5](specs.md)) | **yes**: the module is built against the kernel | none. This is what the fork exists for |
| `libp11`, `nbtty` | Buildroot packages | the fork, or upstream if they turn out generally useful |

So once the kernel PR is in, **the fork shrinks to ZFS**. Without that PR, a
stock system has two more limits: no diskless boot, and virtio NICs only.

## What a stock-system image cannot do

- **No ZFS, so no storage node.** No `cubi.vdevs=` ([§2.10.3](specs.md)),
  no Khepri state on an encrypted pool, so never a voter ([cluster.md §4.2](cluster.md),
  [phase 7](phase7.md)). It is a compute node: it runs releases and joins as
  a non-voting member. Khepri on the ext4 application partition is not
  offered, because it would lose the pool's encryption, mirroring and
  snapshots ([security.md](security.md)).
- **No diskless boot until upstream has `BLK_DEV_INITRD` and `BLK_DEV_LOOP`.**
  Until then a stock image boots only from disk, the standard Nerves way
  (below). The cmdline pins of [§2.12.2](specs.md) and the stage-1 rootfs check
  go with diskless boot.
- **virtio hardware only:** QEMU and KVM clouds (Vultr, OVHcloud Public Cloud,
  Hetzner, …). No EC2 Nitro (`ena`) and no bare metal, unless upstream takes
  the drivers.
- **Smaller things:** gzip squashfs (bigger, slower first boot over the
  network), and no pstore, so a kernel panic leaves no trace.

## Two boot modes, two systems

The system decides the capabilities, the provider decides the boot mode, and
cubi checks that they match:

| | diskless (iPXE, [§2.4](specs.md)) | disk (fwup A/B, standard Nerves) |
| --- | --- | --- |
| `cubi_system_x86_64` | yes: today's design | yes: its `fwup.conf` is upstream's |
| stock system | only after the kernel PR | yes |
| Storage node (`zfs`) | cubi system only | cubi system only |

**Disk mode** is new. Some providers have no network boot, such as EC2 without
the ipxe.org AMI or OpenStack, and some machines should not depend on a boot
server. For those, the node boots like any Nerves device:

- **Image.** The published `.fw`, written to a raw disk image with
  `fwup -t complete` and registered with the provider (an AMI, a Glance image,
  a Vultr snapshot from a URL **(verify)**). This is still one public image
  per version, built by the project, not by the operator.
- **Per-instance configuration.** No private iPXE script carries
  `cubi.ca=` and `cubi.ssh=`, and the cmdline comes from the image's
  `grub.cfg`. The same values come instead from the provider's metadata
  service (user data, link-local HTTP) on a cloud, or from the fwup
  environment (`Nerves.Runtime.KV`, keys `cubi_ca`, `cubi_ssh`) when an
  operator writes the disk themself. `Cubi.Cmdline` becomes one source of
  several, read in that order: cmdline, KV, user data. The values are the
  same and are just as non-secret ([§2.12.2](specs.md)).
- **Integrity.** No stage-1, so no `cubi.rootfs=` pin. The rootfs is trusted
  because the provider holds the registered image, and fwup checks the
  `.fw`'s signature on every upgrade. The public `.fw` is signed with the cubi
  project's fwup key, and the image trusts its public half.
- **Base upgrade** is fwup's A/B swap: `mix cubi.upgrade` streams the new
  version's `.fw` over `ssh_subsystem_fwup` and reboots, and
  `nerves_runtime`'s validation rolls back a base that does not come up. So
  `ssh_subsystem_fwup` returns, in disk mode only ([§2.6](specs.md) removes it
  from diskless images).
- **Deployed releases persist.** `Cubi.Deploy.Store` keeps them on the
  application partition, as a storage node keeps them on its pool, and
  re-verifies them at boot ([§2.11](specs.md)). After a base upgrade, a stored
  release built against the old `base.json` is checked again and refused if it
  no longer matches. Whether the node then runs it anyway or runs nothing is
  open.

## How cubi tells them apart

- **`base.json` grows `system` and `features`.** `system` is
  `{name, version}`. `features` is a subset of `diskless`, `disk`, `zfs`,
  `nics:physical`, `nics:ena`. `mix firmware.ipxe` (and its disk-mode
  sibling) fills them from what the image contains: `zfs.ko` and `zpool` in the
  rootfs, and the kernel options from a table in `cubi_tools` per system name
  and version, since a Nerves kernel carries no `IKCONFIG`. An unknown system
  gets `disk` only.
- **Releases do not care which system.** A release is checked against the
  OTP version and the applications in `base.json` ([§2.11.3](specs.md)), never
  against `system`. The cubi system tracks upstream's tags, so the cubi and
  stock images of one cubi version share `nerves_system_br`, OTP and `cubi_fw`
  dependencies, and **one signed release runs on both**.
- **Providers declare their boot modes**, as a new `Cubi.Provider`
  callback, `modes/1`:
  - QEMU and Vultr: `[:diskless, :disk]`
  - OVHcloud bare metal (stored iPXE script): `[:diskless]`
  - OVHcloud Public Cloud: `[:disk]`
  - EC2: `[:disk]` (`:diskless` through the ipxe.org AMI)

  `mix cubi.provision` intersects them with the image's `features`. It
  refuses a mismatch before it creates anything: a storage node on a
  stock image, `ena` missing on EC2, diskless on a stock image without the
  kernel options.
- **The node checks at runtime too.** `Cubi.Storage` probes for `zfs.ko`. On a
  node without it, `cubi.vdevs=` is logged as an error and the node runs as
  compute, rather than crash-looping before ssh comes up.
- **What the project publishes per version:**
  - `cubi/<version>/`: the diskless directory, built on the cubi system. It
    is the only flavour with ZFS.
  - `cubi/<version>/disk/`: the signed `.fw` and its raw image, built on
    the cubi system so that `ena` and the physical NICs are in.
  - A stock-system flavour is published only once it buys something: it
    would let a user skip the fork's Buildroot build, but the project builds
    the images anyway.

  The practical gain of stock systems is **for operators who build their own
  base image**. They can use a precompiled `nerves_system_x86_64` artifact and
  never run Buildroot. And cubi avoids the fork wherever ZFS is not needed.

## Open points and checks

- The stage-1 cpio stays independent of the kernel version as long as the
  kernel has `squashfs`, `loop`, `devtmpfs` and `tmpfs` built in **(verify)**.
- An app `rootfs_overlay` replaces the system's `/etc/erlinit.config`
  **(verify)**, and `nerves_runtime`'s init leaves the disks alone on a
  diskless node: it must not format a disk because the seeded KV names an
  application partition **(verify)**.
- `nerves_system_vultr`'s `.fw` keeps the kernel at `/boot/bzImage` inside the
  rootfs, like `nerves_system_x86_64`'s, so `mix firmware.ipxe` reads it
  unchanged **(verify)**.
- Whether `nerves_system_x86_64`'s maintainers take `BLK_DEV_INITRD` +
  `BLK_DEV_LOOP` (+ physical NIC modules). Ask before writing the PR.
- What a disk-mode node does with a stored release that the new base refuses
  (above).
