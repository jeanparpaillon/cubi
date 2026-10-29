# Cubi node boot — specification

Plan for booting cubi nodes from the network: iPXE fetches a kernel and
an initramfs over HTTP(S), and the machine comes up straight into BEAM. The OS
lives in RAM. Anything that must survive a reboot lives on a ZFS pool whose
disks are named on the kernel cmdline, the way SmartOS does it (§2.10). There is
nothing to flash, and "updating a node" means serving new files and rebooting it.
Application releases are the exception: they are signed and deployed onto a
running node (§2.11).

Nothing here is built yet. Points marked **(verify)** are assumptions to confirm
in [phase 0](phase0.md) before anything depends on them. The work is split into phases
(§3, one file each), and open questions are in [questions.md](questions.md).
The threat model, and the recommended setup with a TPM on every machine, are
in [security.md](security.md).

This spec covers one node: boot, storage, signed releases, cloud instances.
Clustering (join, membership, the cluster CA, Khepri, the cluster-wide ZFS key)
is a separate layer on top, specified in [cluster.md](cluster.md). That design
was §2.8, §2.9 and §2.10.1–2 here. The numbers are left unused so that
references to the other sections stay valid.

---

## 1. What changes compared with a normal Nerves image

A standard Nerves firmware is tied to a block device at every layer:

| Layer | Standard Nerves | Diskless / iPXE |
| --- | --- | --- |
| Bootloader | U-Boot / GRUB from disk, A/B slot | iPXE from NIC ROM or chainloaded |
| Rootfs | squashfs on a partition, mounted read-only | squashfs **inside the initramfs**, loop-mounted |
| App data (`/root`) | ext4/f2fs partition | tmpfs |
| Persistent state | — | a ZFS pool, on nodes given disks with `cubi.vdevs=`, with a dataset reserved for cubi (§2.10) |
| Firmware metadata | U-Boot env (`nerves_fw_*` KV) | `Nerves.Runtime.KVBackend.InMemory`, seeded at build time |
| Update | `fwup` writes the inactive slot | the iPXE server serves a new pair of files; the node reboots. Application releases are deployed on top without a reboot (§2.11) |
| Rollback / validate | `nerves_fw_validated` + slot switch | no-op locally: the boot server decides which version to serve. A failing application release is rolled back on the node (§2.11.7) |
| Node identity | serial number from `boardid` | the SMBIOS UUID, from `cubi-boardid` (§2.6). The cluster layer adds a certificate issued on join ([cluster.md](cluster.md)) |

Erlang distribution, `vintage_net`, `shoehorn` and `nerves_runtime` are unchanged
once BEAM is running. The changes are all below BEAM and in how firmware
metadata is reported.

## 2. Design decisions

### 2.1 Target: x86_64 first, by forking `nerves_system_x86_64`

iPXE is at home on x86 (legacy BIOS `undionly.kpxe` and UEFI `ipxe.efi`), and
QEMU ships an iPXE NIC ROM, so the whole loop can be tested on a laptop. Fork
`nerves_system_x86_64` the same way `marmoos_system_rpi3` was forked (see
`marmoos_os/docs/system.md` §2: kernel options cannot be added out of tree).
Working name: `cubi_system_x86_64`.

arm64 UEFI (servers, or an rpi4 running EDK2 firmware) is a later variant. The
initramfs mechanics are the same; only the system fork differs.

### 2.2 Rootfs layout: squashfs carried as a file inside the initramfs

There are two ways to do it:

- **A. Whole rootfs as cpio** (`BR2_TARGET_ROOTFS_CPIO`, `/init` → `erlinit`).
  This is the simplest, but the kernel unpacks everything into RAM, so the full
  uncompressed rootfs (ERTS + release, typically 150–300 MB) sits in tmpfs, and
  it is writable, which breaks Nerves' read-only-rootfs assumption.
- **B. Small stage-1 init + `rootfs.squashfs` as a file.** The stage-1 init
  loop-mounts the squashfs read-only and runs `switch_root` into it, then
  `erlinit` runs as usual. RAM cost is the *compressed* size plus page cache, and
  the rootfs stays read-only as Nerves expects.

**Choose B.** It also unlocks the key build trick in §2.3: the squashfs is the
exact file `mix firmware` already produces.

iPXE can hand the squashfs to the kernel as a named file inside the initramfs
without us building a cpio for it: `initrd <url> /rootfs.squashfs` makes iPXE
wrap it in a cpio header on the fly, and the kernel concatenates multiple
initrds. This works in both QEMU's BIOS ROM and `ipxe.efi` under OVMF, and
`mode=400` on a private file's `initrd` line (§2.4) is honoured ([phase 0](phase0.md)). The
fallback is to wrap it ourselves with `cpio -o -H newc`, which costs nothing,
but every piece must then be padded to a 4-byte boundary before concatenation.
The kernel silently ignores a cpio that follows a compressed one unaligned;
iPXE pads by itself.

### 2.3 Build: post-process the `.fw`, don't fight `mix firmware`

The system tarball does not contain the application. `mix firmware` (rel2fw)
merges the OTP release into the squashfs and packs it into a `.fw`, which is a
zip. So the iPXE artifacts are derived from the `.fw`:

```
mix firmware  →  cubi.fw (zip)
                   └── data/rootfs.img      → rootfs.squashfs
                         └── /boot/bzImage  → vmlinuz
stage1.cpio.zst  (built once, by the system)
```

The `.fw` has no kernel resource: GRUB loads `/boot/bzImage` from the rootfs
partition, so the kernel is only inside the squashfs ([phase 0](phase0.md)). The
`mix firmware.ipxe` task (umbrella app `cubi_ipxe`, a build-time dependency of
the firmware app) runs `mix firmware`, then:

- unzips `data/rootfs.img` and takes the kernel out of it with `unsquashfs
  -cat rootfs.img boot/bzImage`;
- rebuilds that squashfs **without `/boot`**, and with `/etc/firmware.kv` (the
  firmware metadata, §2.6). `/boot` only holds the kernel GRUB would load from
  disk: served separately as `vmlinuz`, it would otherwise sit in every node's
  RAM twice (5.7 MB). The rebuild needs no root, the way Nerves'
  `merge-squashfs` works: unpack, then repack with a pseudo file restoring each
  entry's mode and owner from `unsquashfs -lln`, and `rel2fw.sh`'s sort
  priorities;
- copies `stage1.cpio.zst` out of the system artifact;
- writes a generic `boot.ipxe` with relative URLs, so the directory can be
  served from anywhere, `base.json` (§2.11.3), the images' signatures
  (§2.11.2), and `SHA256SUMS` of every file;

all into `_build/<target>_<env>/ipxe/`. The `.fw` itself is unchanged: `/boot`
is only dropped from what is served.

`--public` builds the generic directory the cubi project publishes for cloud
instances (§2.12.1): no `/etc/cubi/ca.pem` and no ssh authorized keys.

### 2.4 Stage-1 init

This is `/init` in a tiny cpio. For now it is a busybox `sh` script,
`stage1/init` in the system fork, built by Buildroot: `package/cubi-stage1`
makes a ~200 KB static busybox with only the applets the script uses, and
`post-createfs.sh` assembles `images/stage1.cpio.zst` and
`images/stage1-dev.cpio.zst` (~105 KB each) with the kernel's
`gen_init_cpio`. Production
needs a small static C program instead, because busybox in the initramfs is a
shell that `rdinit=` can reach ([security.md](security.md) §5). Its whole job:

1. Mount `proc`, `sys`, `devtmpfs`.
2. If the cmdline has `cubi.rootfs=sha256:<hex>`, check `/rootfs.squashfs`
   against it (busybox `sha256sum`); a mismatch is a failure,
   `cubi stage-1: rootfs hash mismatch`. The last occurrence counts, as for
   the kernel's own parameters. A malformed pin (another algorithm, anything
   but 64 lowercase hex digits, an empty value) is a failure too, never a
   skipped check. Without the argument there is no check, and a warning on
   the console (§2.12.2).
3. `losetup` + mount `/rootfs.squashfs` read-only on `/newroot`.
4. Mount a tmpfs on `/newroot/root` (`mode=0700,nodev,nosuid`). Persistence is
   not stage-1's concern: cubi imports its ZFS pool from BEAM (§2.10.3).
5. Move `/cubi/token`, if present, to `/newroot/root/.cubi/token`, mode
   `0400`. A private file for the layers above (the cluster layer's join
   token, [cluster.md](cluster.md) §2.2) travels this way, as an extra
   initrd, never on the cmdline, which is world-readable.
6. `mount --move /dev /newroot/dev`. erlinit expects a populated `/dev` and
   only remounts it; without the move it has no console and no `/dev/null`.
7. `exec env -i TERM=linux HOME=/ switch_root /newroot /sbin/init`: always
   erlinit, with no arguments and a clean environment. The kernel turns
   unknown `key=value` cmdline arguments into init's environment, and
   `ERL_AFLAGS=…` would otherwise reach the BEAM.

The archive also ships `/dev/console` and an empty `/cubi` directory. The
kernel does not create parent directories when it unpacks an initrd, so
iPXE's `initrd … /cubi/token` needs `/cubi` to exist in an earlier archive.
`gen_init_cpio` writes the device node without root, with owner 0 and mtime 0,
so the archive is reproducible.

`switch_root` empties the old rootfs, but the loop device keeps the squashfs
file alive. A failure at any step prints `cubi stage-1: …` on the console.
`prod` builds then reboot after a delay, so iPXE retries; only `dev` builds
drop to a shell. e2e images use `prod`.

### 2.5 Kernel configuration (system fork)

The stock x86_64 defconfig is a virtio-only QEMU target. It has no initramfs
support, no loop device, no EFI stub, and no driver for physical NICs or disks;
its only module is `efivarfs` ([phase 0](phase0.md) has the table). On top of it, add:

- `BLK_DEV_INITRD`, `RD_ZSTD` (and/or `RD_XZ`), `BLK_DEV_LOOP` — **built-in**,
  not modules: stage-1 runs before any module can be loaded. `SQUASHFS`,
  `DEVTMPFS` and `TMPFS` are already built in, but squashfs with zlib only: add
  `SQUASHFS_XZ` or `SQUASHFS_ZSTD` if the compressor changes ([questions.md](questions.md)).
- `EFI_STUB` (`EFI` is already on): iPXE on UEFI boots `bzImage` as an EFI image
  and passes the initrd through the EFI initrd protocol.
- NIC drivers (`e1000e`, `igb`, `r8169`, …) as modules. `virtio_net` is already
  built in. The network is brought up by `vintage_net` after BEAM starts, and
  the kernel does not need the network to boot because iPXE already fetched
  everything.
- OpenZFS and storage drivers, as modules (§2.10.5).

### 2.6 `erlinit.config` and runtime configuration

- Drop both `-m` mounts: stage-1 owns `/root`, and there is no boot partition.
- Replace `-d /usr/bin/boardid` with `/usr/bin/cubi-boardid`, a small script
  that prints the SMBIOS UUID, or the first MAC without colons when the UUID is
  blank (all zeros or all `f`). The hostname is that ID as is (`-n %s`), and
  `nerves_runtime`'s `:boardid_path` points at the same script, so
  `serial_number/0` agrees. This gives a hostname and an Erlang node name
  `cubi@<UUID>` that are stable per machine. The cluster layer's identity is
  a certificate on top of it ([cluster.md](cluster.md) §2). The MAC
  fallback only sees NICs whose driver is built in: erlinit runs the script
  before anything loads modules.
- `Nerves.Runtime.KVBackend.InMemory`, seeded with what `fwup` writes into the
  boot environment on a disk install: `nerves_fw_active`, `a.nerves_fw_version`,
  `a.nerves_fw_uuid` …, plus `nerves_fw_validated: "1"`. This keeps
  `Nerves.Runtime.firmware_valid?/0` and friends truthful. The UUID only exists
  once the `.fw` is built, after its squashfs is sealed, so it can't be in the
  release's config. `mix firmware.ipxe` writes it into the served squashfs as
  `/etc/firmware.kv` (`key=value` lines, §2.3), and `config/runtime.exs` loads
  it at boot. The served squashfs then describes itself, under the same
  signature (§2.7).
- Remove `ssh_subsystem_fwup` from the target deps. `mix upload` has nothing to
  write to, and a half-working update path is worse than none.

### 2.7 The iPXE side: the boot server

The boot server does more than serve files. Its per-node scripts decide what
each machine runs, so it is part of the trust boundary:

| Role | What it does |
| --- | --- |
| **Images** | Serves `vmlinuz`, `stage1.cpio.zst` and `rootfs.squashfs` per version. Choosing the version per node replaces A/B slots: promoting a version, canarying it or rolling it back is all server-side |
| **Per-node script** | Renders `https://boot.example/node/${uuid}.ipxe` for each machine in its **inventory**, the list of SMBIOS UUIDs it boots |

A node's script:

```ipxe
#!ipxe
set base https://boot.example/cubi/${version}
kernel ${base}/vmlinuz console=ttyS0 cubi.vdevs=${vdevs}
initrd ${base}/stage1.cpio.zst
initrd ${base}/rootfs.squashfs /rootfs.squashfs
boot
```

`cubi.vdevs=` is left out for a diskless node (§2.10.3). The cluster layer
adds its arguments and a token file to this script, and gives the server its
token roles ([cluster.md](cluster.md) §1).

- **Integrity.** Build a custom iPXE with `DOWNLOAD_PROTO_HTTPS`, an embedded
  `TRUST=` CA, and `imgverify` on the three image files (signed with
  `openssl cms`).
  UEFI Secure Boot (shim + signed iPXE) is out of scope for v1.
- **Only the chainload step may use plain TFTP/HTTP.** Serving
  `undionly.kpxe` / `ipxe.efi` by client architecture from a dnsmasq proxy-DHCP
  config lets this coexist with an existing DHCP server, and that step carries no
  secret. Everything after it, scripts and per-node files, is HTTPS.

### 2.10 Persistent state on ZFS

This is the SmartOS model. The OS is a RAM image thrown away at every boot,
loaded from the network or a USB key. Everything that must survive lives on a
ZFS pool built from local disks. SmartOS calls its pool `zones` and keeps even
its own configuration there (`zones/usbkey`). In cubi:

- **the OS** is the iPXE image (§2.2);
- **the state** is a pool whose disks are named on the cmdline;
- **a node with no disks named** is diskless: nothing of it survives a reboot.

#### 2.10.3 ZFS: boot arguments, pool and reserved dataset

| Argument | Meaning |
| --- | --- |
| `cubi.vdevs=<SPEC>` | physical devices, in `zpool create` vdev syntax with commas for spaces, e.g. `mirror,nvme-SAMSUNG_…_S4EWNX0R,nvme-SAMSUNG_…_S4EWNX0T`. Absent = diskless node |
| `cubi.zpool=<NAME>` | pool name, default `cubi` |
| `cubi.zfs.create=1` | allows creating the pool if none is found |

`Cubi.Storage` handles the pool from BEAM at boot, before anything uses it. Doing it there
rather than in stage-1 keeps the ZFS modules and tools in the squashfs. The
steps:

1. **Load ZFS.** `modprobe spl spl_hostid=<H>`, then `modprobe zfs`, with `H`
   derived from the SMBIOS UUID: 32 bits, never 0. That is stable per machine,
   so the pool imports without `-f` across reboots, even after a power loss,
   while a pool moved to other hardware still needs a deliberate `-f`. A pool
   that was cleanly exported imports anywhere. A hostid of 0 is refused like
   any foreign one. All of this was checked on OpenZFS 2.3.9 ([phase 0](phase0.md)).
   `H` is the first 32 bits of `SHA-256("cubi-hostid:" <> machine ID)`, 1 if
   that is 0. If `spl` is already loaded (a BEAM restart), its `spl_hostid`
   must be `H`, or setup refuses.
2. **Import.** `zpool import -N -o cachefile=none -d /dev <name>`:
   - `-N` because the rootfs is read-only, so nothing may automount;
   - `cachefile=none` because there is nowhere to keep one;
   - devices are found by scanning. Pool labels carry GUIDs, so device names
     don't matter for an import.
3. **Not found.** Create the pool only if `cubi.zfs.create=1` **and** every
   listed device has no partition table or filesystem signature (`wipefs -n`).
   Never use `-f`. Anything else refuses, with a console message, and the node
   drops to restricted mode. A typo in a boot argument must never wipe a disk.
   "Not found" means `zpool import` said *no such pool available*: any other
   import failure (a foreign host ID, missing devices) refuses without
   looking further. The pool is created with `-o cachefile=none -O
   mountpoint=none`, since its root dataset has nowhere to mount on the
   read-only rootfs.
4. **Imported, but with different vdevs than `cubi.vdevs`** (the pool was grown
   or repaired by hand): log it, continue.
5. **Reserved dataset `<pool>/cubi`.**
   - `refreservation=` (e.g. 4G) is space no other dataset can take, so
     workloads can never fill cubi's own state. This is the SmartOS-style
     reserved volume.
   - `mountpoint=legacy`, mounted by cubi on `/cubi`, an empty directory
     shipped in the rootfs overlay.
   - `compression=lz4`, `atime=off`, and `sync=standard`. Ra fsyncs its WAL,
     so `sync=disabled` is never allowed.
   - Its children:

     | Dataset | Mounted on | Holds |
     | --- | --- | --- |
     | `<pool>/cubi/identity` | `/cubi/identity` | reserved for the cluster layer's node identity ([cluster.md](cluster.md) §4.3). **In clear**: it is read before any key is available |
     | `<pool>/cubi/crypt` | — | encryption root, no data (§2.10.4) |
     | `<pool>/cubi/crypt/khepri` | `/cubi/khepri` | reserved for the cluster layer's store, Ra's data directory ([cluster.md](cluster.md) §4) |
     | `<pool>/cubi/crypt/log` | `/cubi/log` | logs and crash dumps, which can hold the key |
     | `<pool>/cubi/releases` | `/cubi/releases` | deployed application releases (§2.11.6). **In clear**: signed, and checked at every boot |

     `crypt` and its children exist only once the node is handed a key
     (§2.10.4). Before that, logs stay in RAM. For hand-booted QEMU
     ([phase 6](phase6.md)), `cubi.zfs.testkey=<hex>` on the cmdline keys
     `crypt`, with a warning. It is compiled out of `:prod`. `crypt` then
     carries the user property `cubi:testkey=on`, so a layer that supplies
     real keys can refuse such a pool. With a key, an existing `crypt` is unlocked
     (`zfs load-key`) and a missing one created; without one, an existing
     `crypt` stays locked. `crypt` itself is `canmount=off`.
6. **The rest of the pool** is left to workloads, later.

On shutdown, cubi stops whatever uses the pool (the cluster layer's store
first), then runs `zpool export`.

**Device names.** Nerves runs no udev, so `/dev/disk/by-id/` does not exist
(checked in [phase 0](phase0.md)). `cubi.vdevs=` therefore takes by-id-*style*
names, and cubi resolves them itself from sysfs to `/dev/nvme0n1` and the like.
The sysfs sources:
`/sys/block/nvme*/device/{model,serial}` and `wwid` for NVMe,
`/sys/block/vd*/serial` for virtio-blk, and `/sys/block/sd*/device/{model,wwid}`
for SCSI and SATA. The values are space-padded. The alternative, adding eudev
to the system, is heavier for one lookup.

The names are exactly udev's (`60-persistent-storage.rules`): `virtio-<serial>`;
`nvme-<model>_<serial>` (namespace 1 only), `nvme-<model>_<serial>_<nsid>` and
`nvme-<wwid>`; `wwn-0x<naa>` for SCSI and SATA. Values are trimmed, whitespace
runs become one `_`, other ASCII outside udev's allowed set becomes `_`. So a
name copied from `/dev/disk/by-id` on any Linux works. `ata-…` and `scsi-…`
names are not offered: udev reads them from the disk (`ata_id`, `scsi_id`), not
from sysfs. The parse refuses rather than guesses, so a typo cannot reach
`zpool create`:

- a kernel name (`vda`, `/dev/nvme0n1`), which is not stable across boots;
- a name no disk has, or one that two disks answer to;
- the same device twice, an empty name, a vdev keyword with nothing after it;
- any of the three arguments given twice, `cubi.zfs.create=` other than `0`
  or `1`, and a pool name `zpool` would reject.

#### 2.10.4 Secrets at rest

`<pool>/cubi/crypt` is a ZFS encryption root (`encryption=aes-256-gcm`,
`keyformat=hex`, `keylocation=prompt`, `canmount=off`) holding what must not
be readable off the machine: `log` and the cluster layer's `khepri` (§2.10.3).
The node never chooses or stores the key. It is handed one at boot, and:

- holds it in RAM in one process, redacted in `format_status/1`, never logged;
- passes it to `zfs load-key -L prompt` (or `zfs create`) on a stdin pipe, so
  it never touches a file;
- without a key, leaves an existing `crypt` locked and creates none.

Where the key comes from is not the node's concern. Today the only source is
`cubi.zfs.testkey=` (QEMU, §2.10.3); the cluster layer fetches one key for the
whole cluster from its peers ([cluster.md](cluster.md) §5).

**With the key, the pool opens without cubi.** On any Linux with OpenZFS:
`zpool import -N <pool>`, then `zfs load-key -L prompt <pool>/cubi/crypt`.
Raw sends (`zfs send -w`) of the encrypted datasets stay encrypted off the
machine, and the same key opens them.

#### 2.10.5 System fork additions

- **OpenZFS through Buildroot's `zfs` package**, OpenZFS 2.4.1 in the Buildroot
  2026.05 of `nerves_system_br` 1.34.0. It builds the modules against the system
  kernel plus `zpool`/`zfs`. It pulls in `libaio`, `libcurl`, and `libtirpc`
  (musl has no native RPC). zlib, OpenSSL and util-linux `libblkid`/`libuuid`
  are already in the rootfs. Two consequences:
  - **The package `depends on BR2_PACKAGE_HAS_UDEV`**, which the stock
    devtmpfs-only system does not have, so it cannot be selected as is. OpenZFS's
    configure treats libudev as optional. The plan is a copy of the package in
    the system's `BR2_EXTERNAL` with that dependency dropped, rather than
    switching `/dev` management to eudev for a library nobody runs.
  - **+4.9 MB in the gzip squashfs**, measured on the phase 2 build: modules,
    `zpool`/`zfs`/`zdb`/`mount.zfs` and their libraries, `libcurl`, `libtirpc`
    and `libaio` included (`zfs.ko` alone is 10.1 MB unpacked). `libzpool` plus
    `zdb` is 1.8 MB of that, the obvious cut if size matters. `make install`
    also ships the OpenZFS test suite (34 MB), kernel headers, dracut,
    initramfs-tools, udev and `zed` files; the system's `post-build.sh`
    removes them. The NIC and storage modules of §2.5 add 1.3 MB more; the
    system rootfs is 27.4 MB against 20.8 MB stock.
- **util-linux `wipefs`** (`BR2_PACKAGE_UTIL_LINUX_WIPEFS`), for the blank
  disk check before `zpool create` (§2.10.3). util-linux is already built for
  `libblkid`; the tool adds 40 kB.
- **Storage drivers** (`nvme`, `ahci`, `sd_mod`, `virtio_blk`, `virtio_scsi`)
  as modules, loaded before the import.
- **Licensing.** Shipping the CDDL ZFS module next to a GPL kernel in one image
  is the position Ubuntu takes, and it is still debated. Distributing cubi
  images needs that decision taken deliberately.

### 2.11 Releases on a running node

The image is still upgraded by rebooting (§2.7). On top of it, an operator can
push an **application release** onto a running node, without a reboot, and the
node rolls it back by itself when it fails. This is [milestone 1](milestone1.md):
it needs no Erlang distribution and no cluster layer. Each node is handled on
its own, over ssh, and trusts whatever is signed by the operator's CA.

It mimics Nerves firmware signing and `mix upload`:

| Nerves | cubi |
| --- | --- |
| `mix firmware.gen.key` → `fwup-key.{pub,priv}` (ed25519) | `mix cubi.gen_ca` → root CA and a signer certificate issued by it (§2.11.1) |
| public keys passed to `fwup --public-key` on the device | the CA certificate in the rootfs, `/etc/cubi/ca.pem` (§2.11.2), or pinned by `cubi.ca=` on a public image (§2.12.2) |
| `mix firmware.sign` → signature added inside the `.fw` | `mix cubi.sign` → signature added inside the release archive (§2.11.4) |
| `mix upload <host>` → `ssh_subsystem_fwup` | `mix cubi.deploy <node>` → the `cubi_deploy` ssh subsystem (§2.11.5) |
| `Nerves.Runtime.validate_firmware/0`, else revert to the other slot | a settle period, then a shoehorn handler that reverts to the previous release (§2.11.7) |

#### 2.11.1 PKI: a root CA and a signer

`mix cubi.gen_ca` writes four files into `~/.cubi/pki/` (`--dir` or
`CUBI_PKI_DIR` overrides it; the directory is created `0700`):

| File | What |
| --- | --- |
| `ca.pem`, `ca.key` | self-signed root, `CA:TRUE`, `pathlen:0`, 20 years |
| `signer.pem`, `signer.key` | issued by the root, `CA:FALSE`, `keyUsage=digitalSignature`, `extendedKeyUsage=codeSigning`, 10 years |

- **RSA-3072**, not ECDSA: the boot images are checked by iPXE `imgverify`,
  which must accept the key **(verify)**. One key type keeps one signer for
  both uses.
- **It refuses to overwrite.** A second run into a directory holding any of the
  four files fails and changes nothing. A lost CA means new images for every
  node, so replacing it is never a side effect.
- **`--signer-only`** issues a new signer from an existing root, for when the
  signer key is lost or rotated. Nodes need no change: they trust the root.
- Keys are written unencrypted, mode `0600`. Both are **offline** keys, held by
  the operator ([security.md](security.md) §2): they never reach the boot
  server or a node. The root is only needed again to issue a signer.
- Built with the `x509` package, in `apps/cubi_pki`, which runs on the
  host and on the node.

There is no revocation in milestone 1. Rotating the signer does not invalidate
what the old one signed; rotating the root does, at the cost of new images.

#### 2.11.2 Signed boot images

- **The CA is in the image.** `mix firmware.ipxe` adds the root certificate to
  the served rootfs as `/etc/cubi/ca.pem`, the way it adds
  `/etc/firmware.kv` (§2.3). Never the signer, never a key. The rootfs
  signature therefore covers the CA the node will trust for releases. The
  certificate is `config :cubi_fw, :ca_cert`, else the signer's own
  `ca.pem`; with both, they must be the same certificate. `config/target.exs`
  sets it to the operator's `~/.cubi/pki/ca.pem` (or `CUBI_PKI_DIR`'s) when
  there is one, and to the test CA for `MIX_ENV=e2e`. With none, the build
  warns: the node will refuse every release unless its cmdline pins a CA with
  `cubi.ca=` (§2.12.2). `--public` builds leave the CA out on purpose, and
  refuse to build if one is configured (§2.12.1).
- **`mix firmware.ipxe --signer <dir>`** writes a detached CMS signature next to
  each image: `vmlinuz.sig`, `stage1.cpio.zst.sig`, `rootfs.squashfs.sig`, made
  with `openssl cms -sign -binary -noattr -outform DER`, signer certificate
  included. That is the format `imgverify` reads. They are listed in
  `SHA256SUMS`. `:public_key` cannot write CMS, so this adds `openssl` to the
  build host's prerequisites. `--signer` defaults to `config :cubi_fw,
  :signer`, which only `MIX_ENV=e2e` sets. Without a signer, `MIX_ENV=dev`
  builds an unsigned directory with a warning and every other environment
  refuses.
- **`boot.ipxe` gets the `imgverify` lines only with `--imgverify`.** A stock
  iPXE (QEMU's ROM, distribution `ipxe.efi`) does not trust our CA and would
  refuse every image. Only the custom iPXE built with `TRUST=` the root
  certificate (§2.7) runs a script that has them:

  ```ipxe
  kernel vmlinuz console=ttyS0
  imgverify vmlinuz vmlinuz.sig
  initrd stage1.cpio.zst
  imgverify stage1.cpio.zst stage1.cpio.zst.sig
  initrd rootfs.squashfs /rootfs.squashfs
  imgverify rootfs.squashfs rootfs.squashfs.sig
  boot
  ```

  A failed `imgverify` stops the script before `boot`. A production boot
  server renders its own per-node scripts (§2.7) with the same lines.
- **`mix cubi.ipxe`** (in `apps/cubi_tools`) builds that iPXE: the v2.0.0
  release tarball, pinned by SHA-512 and cached in `~/.cache/cubi/`, built
  with `TRUST=<ca.pem>`, `CERT=<ca.pem>` and `IMAGE_TRUST_CMD`, into `undionly.kpxe` (BIOS
  chainload), `ipxe.efi` (UEFI chainload) and `1af41000.rom` (QEMU's
  virtio-net option ROM, for the harness). iPXE 2.0.0 verifies RSA and ECDSA
  (P-256, P-384) and requires `codeSigning` on the signer. `TRUST=` embeds
  only the root's fingerprint and a signature carries only the signer, so the
  root certificate itself goes in with `CERT=`; without it `imgverify` fails
  with "No usable certificates" (`0216eb3c`). `TRUST=` is its
  only root for HTTPS too, so an HTTPS boot server ([phase 5](phase5.md))
  needs a certificate from the same root, or a second `TRUST=` entry.
- e2e images are signed with a test CA that `mix cubi.e2e.key` creates next to
  the harness key, in `apps/cubi_e2e/priv/pki/` ([testing.md](testing.md)).

#### 2.11.3 What a release is

A cubi release holds only what the base image lacks. Its applications are
loaded into the node's own BEAM, next to the base image's (§2.11.6), not run as
a second BEAM: that is what lets shoehorn watch them, and it saves a second
ERTS in RAM.

`mix cubi.release --base <ipxe dir>`, run in the user's Mix project, builds a
`mix release` and packs `_build/<env>/cubi/<name>-<version>.tar.gz`:

```
manifest.json
lib/<app>-<vsn>/ebin/…            one directory per application
lib/<app>-<vsn>/priv/…
releases/<version>/sys.config     build-time configuration
```

- **`--base`** names a served directory (§2.3), local or at an `https://`
  URL such as a public image's (§2.12.1), from which it reads `base.json`. A
  URL's `base.json` is checked against the `SHA256SUMS` fetched next to it
  (`Cubi.Tools.Image`). Only `https://`, the server certificate checked
  against the system's CAs: HTTPS to the publisher is what vouches for a
  public image, and sums fetched over plain HTTP would prove nothing.
  `base.json` holds the OTP release, the ERTS version and every application
  with its version in the image. `mix firmware.ipxe` writes that file. The host's OTP
  major must be the image's. Each application of the `mix release` is then
  sorted (`Cubi.Tools.Release.plan/3`), and every problem is reported at once:

  | Application | Becomes |
  | --- | --- |
  | part of OTP (OTP's `installed_application_versions`), in the image | nothing: never shipped, whatever the host's patch version. The image's come from the Nerves system and may carry NIFs built for its libc |
  | part of OTP, not in the image | a refusal: the firmware must add it |
  | in the image at the same version | an entry in the manifest's `requires` |
  | in the image at another version | a refusal: two versions cannot be loaded at once |
  | anything else | shipped |

  `elixir`, `logger` and the rest of Elixir are not OTP's, so the release must
  be compiled with the image's Elixir. Elixir applications the image lacks
  (`eex`, for a Plug app) are shipped.
- **Same target as the image.** Pure Erlang and Elixir code builds anywhere;
  NIFs need the project built with the image's `MIX_TARGET` and system, as
  `cubi_fw` is.
- **Configuration is build-time only, and only the shipped applications'.**
  `sys.config` is applied with `Application.put_all_env/1` before the
  applications start, so configuration for one of the image's applications
  (`config :logger`, say) would change the image: it is dropped, with a
  warning. `config/runtime.exs` is not evaluated in milestone 1, and its
  presence is a warning.
- **Protocols.** The image's protocols are consolidated (`Enumerable`,
  `Inspect`, `String.Chars`, `JSON.Encoder`, `Jason.Encoder`…), so a release's
  own implementation of one of them is never dispatched to. Protocols the
  release defines are fine: they are shipped unconsolidated, from `ebin/`.
  The `mix release`'s `consolidated/` directory is not packed
  ([questions.md](questions.md)).
- **`manifest.json`** (Elixir's `JSON`, so nothing extra on the node):

  | Key | What |
  | --- | --- |
  | `format` | `1` |
  | `name`, `version` | the release |
  | `otp_release`, `erts_version` | what it was built for, copied from `base.json` |
  | `applications` | `[{name, vsn}]`, every application in the archive |
  | `requires` | `{name: vsn}`, the image's applications the release uses, OTP's excepted |
  | `start` | the applications to start, in order: the release's own, not their dependencies, which `ensure_all_started` reaches |
  | `files` | `{path: sha256}` for every other file in the archive |

#### 2.11.4 Signature

`mix cubi.sign <archive> [--signer <dir>]` signs the exact bytes of
`manifest.json` with `signer.key` (RSA, SHA-256, `:public_key.sign/3`) and adds
three members to the archive in place, the way `mix firmware.sign` rewrites the
`.fw`: `manifest.sig` (the raw signature), `signer.pem`, and `ca.pem`, the
root from the signer's directory, for nodes that pin it rather than carry it
(§2.12.2). Signing an archive that is already signed replaces all three. `--signer` defaults to `Cubi.Pki.dir/1`,
the archive to the newest in `_build/<env>/cubi/`. Signing vouches for the
files, so it first checks them against the manifest (step 3 below) and refuses
on any difference; once signed, the archive is verified as a node would, signer
dates included, before it is written. The archive code (`Cubi.Pki.Archive`:
read, write, sign, verify) is in `apps/cubi_pki`, shared by the host tasks and
the node.

The manifest hashes every file, so one signature covers the archive. The bytes
are signed as they are: there is no canonical JSON to agree on.

The node verifies with `:public_key` only, no OpenSSL, in this order:

1. `signer.pem` is path-valid against the **trusted root**
   (`:public_key.pkix_path_validation/3`), with `codeSigning` in its extended
   key usage. The trusted root is `/etc/cubi/ca.pem` if the image has one,
   else the archive's `ca.pem` if its SHA-256 (over the DER) equals the
   cmdline's `cubi.ca=sha256:<hex>` (§2.12.2). If the image has a CA *and* the
   cmdline pins one, they must be the same certificate, or every release is
   refused, which is logged at boot. So is a malformed pin (anything but
   `sha256:` and 64 lowercase hex digits; the last `cubi.ca=` counts): it was
   meant to restrict trust, and is never ignored. With neither a CA nor a pin,
   every release is refused. `Cubi.Deploy.Trust` makes the choice.
   `Cubi.Pki.Archive.verify` takes the trusted root as an argument; choosing
   it is `Cubi.Deploy`'s job.
2. `manifest.sig` verifies over `manifest.json` with the signer's key.
3. The archive holds exactly the files in `files` plus the manifest, the
   signature, `signer.pem` and optionally `ca.pem`, and each matches its hash. Paths are relative,
   with no `..` and no symlinks.
4. `format` is known and `otp_release` is the node's.
5. Every application in `applications` is either absent from the node's
   `lib/` or present there at the same version (then skipped), and every one
   in `requires` is present at exactly that version: the release was built for
   this image.

At deploy (§2.11.5) the signer's validity dates are checked against the node's
clock, which `nerves_time` keeps at least at the image's build time. At boot
(§2.11.6) they are not: a release must not vanish from a node because its signer
expired while it ran. Every other step is repeated.

#### 2.11.5 Deploy over ssh

Like `mix upload`, the transport is ssh, and the session's authorized keys are
`nerves_ssh`'s: compiled into the image, or read from `cubi.ssh=` on a public
image (§2.12.2). Erlang distribution stays off. The ssh session decides who may
*send* a release; only the signature decides whether it is installed.

- **On the node,** `cubi_deploy` is an ssh subsystem
  (`Cubi.Deploy.Subsystem`), listed in `config :nerves_ssh, subsystems:` next
  to the default sftp. Not added at runtime with `NervesSSH.add_subsystem/2`:
  `nerves_ssh` rebuilds its daemon from its config whenever it restarts, which
  it does at least once at boot (no host key yet), and a runtime addition is
  lost then. It reads the
  archive from the channel up to EOF, at most 256 MB (it lands in RAM on a
  diskless node), into `/cubi/releases/incoming/`, then verifies (§2.11.4),
  unpacks to `/cubi/releases/<version>/` and installs (§2.11.6).
- **It answers with lines,** `cubi_deploy: <step>` for progress and one final
  `ok <name> <version>` or `error <reason>`, plus the channel's exit status, so
  any ssh client can drive it.
- **`mix cubi.deploy <node> [archive]`** streams the newest archive in
  `_build/<env>/cubi/` with the system `ssh -s <node> cubi_deploy`, honouring
  `--port`, `--user`, `--identity` and `--ssh-option` (repeatable, as `-o`),
  prints the node's lines as they come and exits non-zero unless ssh exits 0
  and the last line is `ok`. An unsigned archive is refused before it is sent.
  The archive is redirected into ssh by `sh -c 'exec ssh … < archive'`: an
  Erlang port cannot close ssh's stdin, which is how the node learns the
  archive is complete, without closing its stdout too.
- **The client always gets an answer.** A crash inside an install is turned
  into `error {:crashed, …}`, and a `Cubi.Deploy` that is down into
  `error {:deploy_down, …}`, at connect or during the install: a deploy never
  hangs.
- The answer comes **after the settle period** (§2.11.7), so a release that
  crashes a few seconds after starting is reported as a failed deploy, not as
  `ok`.

#### 2.11.6 On the node: storage, load, start

**One release per node** in milestone 1. A second release name is refused;
deploying another version of the same name replaces it.

- **Where.** `/cubi/releases/`. On a storage node that is the dataset
  `<pool>/cubi/releases` (§2.10.3), in clear: integrity comes from the
  signature, checked again at every boot. A release must therefore not carry
  secrets in `sys.config`. On a diskless node it is a tmpfs mounted on
  `/cubi`, so a reboot drops every deployed release and the node runs the base
  image alone.
- **State** is `/cubi/releases/state.json`: `current`, `previous` (versions or
  `null`) and `bad` (a list of versions), written to a temporary file and
  renamed. Only the directories of `current`, `previous` and an incoming
  version are kept; older ones are deleted after a successful install. A
  version directory keeps the archive's `manifest.json`, `manifest.sig` and
  `signer.pem`, so it can be verified again from disk (`Cubi.Deploy.Store`).
  Every file is written `O_SYNC` and `state.json` is fsynced again after its
  rename, which on ZFS commits the intent log, the rename included. Without
  that, a write waits for the next transaction group (up to 5 s), and a power
  cut right after a deploy brought the previous state back. The image has no
  `sync` binary to fall back on.
- **Load.** For each application dir: `:code.add_patha(ebin)`, then
  `Application.load/1`; then `sys.config` through `Application.put_all_env/1`.
- **Start.** `Application.ensure_all_started(app, :temporary)` for each entry of
  `start`, in order. `:temporary` because a release must never take the base
  image down with it: when one of its applications dies, the node keeps
  running and shoehorn hears of it (§2.11.7). A start returning an error is a
  failed start, handled as in §2.11.7 without waiting for shoehorn.
- **Stop.** In reverse order: `Application.stop/1`, `Application.unload/1`,
  `:code.purge/1` then `:code.delete/1` for every module in the application's
  `modules`, `:code.del_path/1`. Purging kills any process still running the
  old code, so nothing of a stopped release survives. Two versions of a
  release are never loaded at once.
- **Install** = verify, stop `current`, load and start the new version, wait the
  settle period, then `previous` ← `current` ← new version. Re-deploying the
  version already running is refused. A load or start error, or one of
  `start`'s applications not running at any check during the settle period
  (every 200 ms), fails the install: the new version is stopped, marked bad and
  its directory deleted, and the release that was running is verified again
  from disk (signer dates excepted) and started again. `Cubi.Deploy` runs one
  install at a time.
- **Boot.** `Cubi.Deploy` is a child of `cubi_fw`, which shoehorn starts after
  its `init` list. It waits for `Cubi.Storage`, mounts the tmpfs on a diskless
  node, then verifies `current` again from its directory, signer dates
  excepted, and starts it, in `handle_continue`: a call to `Cubi.Deploy`
  returns once that is done. A `current` that fails verification or start at
  boot is rolled back like any other failure: marked bad, `previous` started
  in its place.

#### 2.11.7 Rollback through shoehorn

shoehorn installs a `logger` filter that turns every "application exited"
report into a call to its handler, for applications started at any time, not
only at boot (checked on a node, [phase 0](phase0.md)). It is a *primary*
filter, so it only sees what the primary log level lets through: a temporary
application's exit is a `:notice`, and a level above it would hide every
release failure. cubi sets `config :shoehorn, handler:
Cubi.Deploy.ShoehornHandler`:

- It returns `{:continue, state}` for every application. A dead base image
  application is left to shoehorn's usual behaviour (the default handler does
  nothing), never a halt from cubi.
- For any application that exited with a reason other than `:stopped`, it
  casts `{:exited, app, reason}` to `Cubi.Deploy` and returns at once. It
  never stops or starts anything itself: it runs inside shoehorn's report
  handler, under a 30 s halt timer, and a raise there halts the node; a cast
  cannot raise. Exits caused by `Cubi.Deploy`'s own stop are `:stopped` and
  not passed on. Which exits concern the release is `Cubi.Deploy`'s call.

`Cubi.Deploy` acts on an exit of one of the current release's own
applications while that release is no longer all running. An exit for an
application that runs again is stale: an install that already rolled back
during its settle period, and restarted the same application from the
previous version, is not rolled back twice. It then **rolls back**: it stops
`current` (§2.11.6), adds its version to `bad`, and starts `previous`,
verified again from disk, which becomes `current`, with `previous` left
`null`. With no `previous` it only stops the release; a `previous` that fails
to start is marked bad as well, and nothing runs. Directories of bad versions
are deleted. A version in `bad` is never started again: not at boot, and not
when the same archive is deployed again, which is refused. Deploying a new
version is the only way forward.

**The settle period** (`config :cubi_fw, Cubi.Deploy, settle:`, in ms, default
10 s; a node setting, since the subsystem takes no arguments) is the window during an install
in which a failure makes the deploy itself fail (§2.11.5). The rollback is the
same during and after it: in milestone 1, *any* later exit of a `current`
application rolls back too, even days later. Whether a release should instead
be considered good once settled is open ([questions.md](questions.md)).

### 2.12 Cloud instances

Provisioning a node on someone else's machines (a cloud VM, a VPS, a rented
bare-metal server) comes down to **one private iPXE script** that points at
**public cubi images** and names the operator's CA on the kernel cmdline. The
operator builds no image: the cubi project publishes one kernel, one stage-1
and one rootfs per version, identical for every operator. Everything that makes
a node *theirs* is in the script. This is [milestone 2](milestone2.md). Like
milestone 1 it needs no Erlang distribution and no cluster layer: each instance is a
standalone node running releases deployed with `mix cubi.deploy` (§2.11).

```
public, per cubi version                    private, per instance
https://…/cubi/<version>/                   rendered by mix cubi.provision,
  vmlinuz                                   handed to the provider's API
  stage1.cpio.zst
  rootfs.squashfs   ◄── pinned by hash ──── #!ipxe
  base.json                                 set base https://…/cubi/<version>
  SHA256SUMS                                kernel ${base}/vmlinuz console=ttyS0 \
  *.sig                                       cubi.rootfs=sha256:<hex> \
                                              cubi.ca=sha256:<hex> \
                                              cubi.ssh=ssh-ed25519:<base64>
                                            initrd ${base}/stage1.cpio.zst
                                            initrd ${base}/rootfs.squashfs /rootfs.squashfs
                                            boot
```

#### 2.12.1 Public images

**The public image is generic.** It carries no CA, no ssh key and no signer.
`MIX_ENV=public mix firmware.ipxe --public` builds it, into
`_build/<target>_public/ipxe/`: no `/etc/cubi/ca.pem` (§2.11.2), not even the
signer's, and no `nerves_ssh` authorized keys compiled in. `MIX_ENV=public` is
the configuration that sets neither; `--public` fails before building if
either is configured, and checks the built rootfs again
(`Cubi.Ipxe.check_public!/1`, which also refuses `nerves_ssh` user
passwords). It still writes `base.json` and `SHA256SUMS` (§2.3), and the
`.sig` files when given a signer; without one the directory is unsigned, for
local tests only.

The project publishes one directory per version: `vmlinuz`,
`stage1.cpio.zst`, `rootfs.squashfs`, `base.json`, `SHA256SUMS`, and the
`.sig` files, signed by the **cubi project's** CA for operators who run a
custom iPXE that trusts it (§2.11.2). That CA is created with
`mix cubi.gen_ca` and kept offline, like any operator's (§2.11.1). Where the
directories are hosted is open ([questions.md](questions.md)).

`mix cubi.release --base` accepts the published directory's URL (§2.11.3), so
an operator builds releases against a public image without downloading it.

#### 2.12.2 The private script and its cmdline

The operator's configuration moves from the image to the cmdline, read with
`Cubi.Cmdline` by key, never by position (§2.6, [phase 0](phase0.md)):

| Argument | What | Read by |
| --- | --- | --- |
| `cubi.rootfs=sha256:<hex>` | the SHA-256 of `rootfs.squashfs` | stage-1, before `losetup` (§2.4): a mismatch prints `cubi stage-1: rootfs hash mismatch` and reboots, like any stage-1 failure. Absent, there is no check and the console says so |
| `cubi.ca=sha256:<hex>` | the SHA-256 of the operator's root certificate (DER) | `Cubi.Deploy`, when verifying a release (§2.11.4 step 1) |
| `cubi.ssh=<type>:<base64>` | one ssh authorized key, repeatable. The space of the `authorized_keys` line becomes `:`, and the comment is dropped | `config/runtime.exs`, added to the keys compiled into the image, if any, in `nerves_ssh`'s `authorized_keys`. Malformed values are ignored |

- **A pin, not the certificate.** An RSA-3072 root is ~0.9 KB of DER, ~1.2 KB
  in base64, out of x86's 2048-byte `COMMAND_LINE_SIZE`, which §2.10.3's
  `cubi.vdevs=` and the cluster layer's arguments also need. So the cmdline pins the
  root's fingerprint, and the certificate travels **in the release archive**:
  `mix cubi.sign` adds `ca.pem` next to `signer.pem` (§2.11.4). A node accepts
  that `ca.pem` as its root only if it matches the pin, and an image that
  carries its own CA and is pinned to another one refuses every release.
- **Nothing in the script is secret.** `/proc/cmdline` is world-readable, and
  that is fine for a fingerprint, a hash and public keys. The script is
  **private because it is the trust anchor**: whoever writes it decides what
  the node runs and who may log in. It therefore travels only through the
  provider's authenticated API (user data, a stored PXE script), never at a
  public or guessable URL. A provider that can only boot a script from a URL
  is out of scope. Secrets never go on the cmdline: they
  travel as an initrd file (§2.4).
- **What the chain rests on.** A cloud's iPXE is stock, so it cannot
  `imgverify` against any of our CAs. The kernel and stage-1 are protected by
  HTTPS to the publisher only: stock iPXE checks the web PKI through its
  cross-signed root **(verify)**. From stage-1 on, the private script's pins
  take over: the rootfs by hash, releases by CA. Closing the first gap needs a
  cubi-built iPXE per provider image ([questions.md](questions.md)).
- **No `cubi.ssh=`, no ssh.** The node then accepts no login, and so no
  deploy. `Cubi.Tools.BootScript` refuses to render such a script unless
  given `--no-ssh`.
- **2048 bytes.** `Cubi.Tools.BootScript` refuses a cmdline longer than
  `COMMAND_LINE_SIZE` rather than let the kernel truncate it silently. It
  counts what the kernel's buffer gets under UEFI, the worst case: the image
  name iPXE puts in front (`vmlinuz `, [phase 0](phase0.md)), the cmdline and
  the terminating NUL. An ed25519 key costs about 90 bytes, an RSA-4096 one
  about 740, so three of those fill it.

`Cubi.Tools.BootScript` renders the script from a version (or a directory
URL), a signer directory and ssh public keys: it fetches `SHA256SUMS` for the
rootfs pin (`Cubi.Tools.Image`, so over HTTPS only), computes the CA's
fingerprint, and reads the keys (default `~/.ssh/id_*.pub`). A script may
instead name a local server, `http://10.0.2.2:<port>` for a QEMU node, if the
pins are read from the same image on disk (`--local DIR`).
`mix cubi.boot_script` prints it, or writes it `0600` with `--output`; the
provisioning tasks (§2.12.4) call the same module.

#### 2.12.3 `Cubi.Provider`

The IaaS details sit behind a behaviour in `apps/cubi_tools`, one module per
provider:

```elixir
@callback init(opts :: keyword()) :: {:ok, state} | {:error, term()}
@callback create(state, spec()) :: {:ok, Cubi.Provider.Instance.t()} | {:error, term()}
@callback list(state) :: {:ok, [Cubi.Provider.Instance.t()]} | {:error, term()}
@callback get(state, name :: String.t()) :: {:ok, Cubi.Provider.Instance.t()} | {:error, :not_found | term()}
@callback set_script(state, Cubi.Provider.Instance.t(), script :: String.t()) :: :ok | {:error, term()}
@callback reboot(state, Cubi.Provider.Instance.t()) :: :ok | {:error, term()}
@callback destroy(state, Cubi.Provider.Instance.t()) :: :ok | {:error, term()}
```

- `spec()` is `%{name, script, size, region, firmware: :bios | :uefi}`;
  `size` and `region` are the provider's own strings, passed through.
  `Instance` is `%{id, name, status, addresses, image, provider: map()}`;
  `image` is the URL of the stored script's `set base` line, so
  `mix cubi.instances` shows what each node boots without asking it.
- **The provider is the inventory.** Instances are named and tagged `cubi`,
  and `list/1` returns only those. There is no local state file to lose or get
  out of step. Names are unique per provider: `create/2` on a taken name is an
  error.
- **The script goes in as content**, never as a URL (§2.12.2). Whatever the
  provider stores alongside it (a startup script object, user data) is removed
  by `destroy/2`.
- **Credentials come from the environment**, never from a config file:

  ```elixir
  # the operator's project, config/config.exs
  config :cubi_tools, :providers,
    qemu: {Cubi.Provider.Qemu, []},
    vultr: {Cubi.Provider.Vultr, api_key: {:env, "VULTR_API_KEY"}, region: "cdg", size: "vc2-1c-1gb"}
  ```

- **Upgrade is still a reboot** (§2.7): `set_script/3` with the new version's
  URL and rootfs hash, then `reboot/2`. A provider that must stop the instance
  to change its script does so inside `set_script/3`. Instances are diskless,
  so a reboot drops the deployed release (§2.11.6) and the operator deploys it
  again.
- Every provider module runs one shared conformance suite,
  `Cubi.Provider.Case`.

Providers:

| Module | What |
| --- | --- |
| `Cubi.Provider.Qemu` | local, for development and for the harness: background QEMU processes (`-daemonize`, so they outlive the Mix task), BIOS or UEFI, state under `_build/cubi/qemu/<name>/`. The script is the one thing it stores, and QEMU's user-mode TFTP delivers it, as [phase 4](phase4.md)'s `:tftp` boots do; the images come from whatever URL the script names, a local server being `http://10.0.2.2:<port>` to the guest. ssh is forwarded to a host port, and a reboot is a cold restart of QEMU |
| `Cubi.Provider.Vultr` | its REST API (`Req`), which stores a `pxe` startup script and boots an instance from it **(verify)** |
| AWS (not in milestone 2) | the ipxe.org EC2 image, which runs its user data as the script **(verify)**; needs the `ena` and `nvme` drivers in the kernel (§2.5) |

Instances are diskless; storage nodes in the cloud are open
([questions.md](questions.md)).

#### 2.12.4 Mix tasks

All in `apps/cubi_tools`:

| Task | Does |
| --- | --- |
| `mix cubi.boot_script [--image <version\|url>] [--local <dir>] [--ca <dir>] [--ssh <file>…] [--no-ssh] [--cmdline <args>] [--output <file>]` | renders the private script to stdout (§2.12.2); on any refusal, exits non-zero and prints nothing on stdout |
| `mix cubi.provision <name> --provider <p> [--size] [--region] [--image]` | renders, `create/2`, waits until the instance runs and answers ssh, prints its addresses and the CA fingerprint it pins |
| `mix cubi.instances [--provider <p>]` | `list/1`: name, status, addresses, image version |
| `mix cubi.upgrade <name> --image <version>` | `set_script/3` + `reboot/2`, waits for ssh, checks the node reports the new version's firmware UUID (§2.6) |
| `mix cubi.destroy <name> [--yes]` | `destroy/2`, after confirmation |

`--image` defaults to the version matching `cubi_tools`', at the project's
release URL (`config :cubi_tools, :image_base`). `mix cubi.deploy <name>
--provider <p>` resolves the name through `get/2` instead of taking a host
(§2.11.5). `--provider` may be left out when one provider is configured.

- **Host keys are not checked** for a provider's instances
  (`StrictHostKeyChecking=no`, no known-hosts file): a diskless node makes a
  new host key at every boot, so a pinned one would refuse it after its first
  reboot. Nothing secret is sent to a node, and what it runs is decided by
  the release's signature, not by which host received it.
- **`mix cubi.upgrade` waits for the firmware UUID**, not only for ssh: a
  cloud reboot may not have started when ssh first answers.

## 3. Phases

One file per phase. Phases run in order; each ends with its acceptance, automated as described in [testing.md](testing.md).

| Phase | Scope |
| --- | --- |
| [0](phase0.md) | confirm the assumptions (half a day) |
| [1](phase1.md) | boot by hand, no iPXE |
| [2](phase2.md) | the system fork |
| [3](phase3.md) | `mix firmware.ipxe` |
| [4](phase4.md) | network boot in QEMU |
| [5](phase5.md) | hardened boot chain |
| [6](phase6.md) | storage |
| [M1](milestone1.md) | signed releases on standalone nodes, no distribution (§2.11) |
| [M2](milestone2.md) | cloud instances from public images and a private iPXE script |
| [7](phase7.md) | the cluster layer ([cluster.md](cluster.md)) |
| [8](phase8.md) | real hardware |
