# Phase 0 — confirm the assumptions (half a day)

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] `unzip -l` a stock `nerves_system_x86_64` `.fw`: rootfs and kernel resource paths.
- [x] Check the stock x86_64 kernel config for every symbol in [§2.5](specs.md).
- [x] Check that iPXE's `initrd <url> <name>` cpio wrapping works in QEMU's built-in ROM and in `ipxe.efi` under OVMF.
- [x] Measure the squashfs size of a hello-world Nerves app → minimum RAM per node.
- [x] Buildroot `zfs` package in `nerves_system_br` 1.34.0, and the squashfs size with it ([§2.10.5](specs.md)).
- [x] `/dev/disk/by-id` absent under Nerves; `spl_hostid` keeps imports `-f`-free across reboots ([§2.10.3](specs.md)).
- [ ] Test infrastructure ([testing.md](testing.md) §4.2, §6, §8): AppArmor profile for unprivileged user namespaces, KVM inside the namespace, ACPI power button handling in Nerves, `/dev/kvm` on CI runners.
- [x] Khepri 0.19 projections, and `verify_fun` as `{M, F, State}` in the `inet_tls_dist` options file ([§2.9.4](specs.md)).

## Results

Run on 2026-10-27 against `nerves_system_x86_64` 1.34.0, the release that pins
`nerves_system_br` 1.34.0 (Buildroot 2026.05, Linux 6.18.36, OTP 29.0.2), with
QEMU 10.2.1 and iPXE 1.21.1+git-20250829 (Ubuntu `ipxe-qemu` / `ipxe`). The
stock kernel cannot load an initramfs (below), so every boot test used Ubuntu's
7.0 generic kernel in its place. The rootfs was the real Nerves one in all of them.

**`.fw` layout: no kernel resource.** `hello.fw` holds `meta.conf`,
`data/rootfs.img` (the squashfs), `data/grub.img`, `data/grub.cfg` and three
`data/grubenv_*`. GRUB loads `/boot/bzImage` from inside the rootfs partition,
so the kernel is only in the squashfs: `unsquashfs -cat rootfs.img boot/bzImage`,
identical to the system's `images/bzImage`. [§2.3](specs.md) is corrected.

**Kernel config: the stock system is a virtio-only QEMU target.** Read with
`extract-ikconfig` from `bzImage` (`IKCONFIG=y`):

| Symbol | Stock | Needed |
| --- | --- | --- |
| `BLK_DEV_INITRD` | **off** (so no `RD_*` at all) | `y`, with `RD_ZSTD` |
| `BLK_DEV_LOOP` | **off** | `y` |
| `EFI_STUB` | **off** (`EFI=y`) | `y` |
| `SQUASHFS` | `y`, zlib only | `y`, plus `SQUASHFS_XZ`/`_ZSTD` if the compressor changes |
| `DEVTMPFS`, `DEVTMPFS_MOUNT`, `TMPFS` | `y` | ok |
| `VIRTIO_NET`, `VIRTIO_BLK`, `SCSI_VIRTIO`, `BLK_DEV_SD` | `y` | ok |
| `E1000E`, `IGB`, `R8169`, `E1000` | **off** | `m` |
| `BLK_DEV_NVME`, `SATA_AHCI` | **off** | `m` |
| `MODULES` | `y`, but the only module is `efivarfs` | ok |

The kernel delta is therefore larger than [§2.5](specs.md) suggested. It covers
all of physical hardware, not only boot. A consequence is that
[phase 1](phase1.md) cannot boot the stock kernel with an initramfs.

**iPXE named initrds: work on both.** Script: `kernel vmlinuz …`, `initrd
stage1.cpio.zst`, `initrd rootfs.squashfs /rootfs.squashfs`, `initrd token
/kubex-token mode=400`, all over HTTP from `10.0.2.2`.

- BIOS (QEMU ROM, DHCP → TFTP script → HTTP) and UEFI (OVMF → `ipxe.efi` from
  a FAT disk, script as `autoexec.ipxe`): in both, stage-1 sees both files with
  matching sha256, `mode=400` is applied (`-r--------`), and the squashfs
  loop-mounts.
- Under UEFI the kernel gets the image name in front of the cmdline
  (`vmlinuz console=ttyS0 …`). Parse `kubex.*` by key, never by position.
- `autoexec.ipxe` runs before any DHCP, so it needs `dhcp` first. Production
  scripts are fetched after DHCP and don't care.
- **The self-wrapped fallback needs alignment.** A plain cpio appended after
  `stage1.cpio.zst` is silently ignored unless it starts on a 4-byte boundary.
  iPXE pads by itself; `cat` does not. Pad each piece (`truncate -s %4`) before
  concatenating.
- QEMU 10.2 rejects `-initrd a,b` for a Linux kernel. Phase 1 must concatenate.

**Stage-1 to IEx, measured.** The [§2.4](specs.md) script works as written, with
one addition: `mount --move /dev /newroot/dev` before `switch_root`, otherwise
erlinit has no `/dev/null` or console. erlinit warns about the two
`/dev/rootdisk0p*` mounts and the failing `boardid`, as expected until
[§2.6](specs.md) lands.

| | |
| --- | --- |
| hello squashfs (`nerves_pack` included, gzip, 128K) | 28.5 MB, 66 MB unpacked (5.3 MB of it is `/boot/bzImage`) |
| same tree, other compressors | lz4 37.9 · zstd-19 26.0 · xz 24.3 · xz + BCJ x86 23.8 MB |
| BEAM at idle IEx | 46.6 MB (`:erlang.memory(:total)`) |
| guest RAM in use at idle IEx, `-m 512` | ~127 MB (includes the squashfs held in the initramfs) |
| smallest `-m` that reaches IEx | 192 MB (17 MB left); 160 MB stalls; 128 MB OOM-panics |

Those numbers come from Ubuntu's generic kernel, which reserves far more than the
Nerves one will. It also enables kexec handover by default, and the KHO scratch
reservation sometimes takes ~400 MB before init; that was found in phase 1, and
those runs were made without `kho=off`, so the floor rows are pessimistic and
should be measured again on the forked kernel. Still, **512 MB is the minimum spec** for a diskless node,
and storage nodes need more for the ZFS module (11 MB) and ARC
([questions.md](questions.md)).

**Buildroot `zfs`: present, but not selectable as is.** Buildroot 2026.05 ships
OpenZFS **2.4.1**. Its `Config.in` `depends on BR2_PACKAGE_HAS_UDEV`, and the
stock system uses `BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_DEVTMPFS`, so the option is
hidden. OpenZFS's own configure treats libudev as optional (`user_libudev=no`).
The package also pulls in `libaio`, `libcurl` and `libtirpc`, the last because
musl has no native RPC. zlib, OpenSSL, `libblkid` and `libuuid` are already in
the stock rootfs. Size, estimated from Alpine's musl build of 2.3.9 with debug
info stripped: `zfs.ko` 11.4 MB, `spl.ko` 0.3 MB, plus `zpool`/`zfs`/`mount.zfs`
and their libraries ≈ 15 MB unpacked, **≈ +3.3 MB in the gzip squashfs**. The
exact number comes from the phase 2 build. The way out is in [§2.10.5](specs.md).

**Disks without udev.** `/dev/disk` does not exist (checked from IEx on the Nerves
rootfs, and from a bare initramfs). sysfs has what udev builds its by-id names
from:

| Bus | sysfs | Example |
| --- | --- | --- |
| NVMe | `/sys/block/nvme0n1/device/{model,serial}`, `/sys/block/nvme0n1/wwid` | `QEMU NVMe Ctrl` / `S4EWNX0R1234` |
| virtio-blk | `/sys/block/vda/serial` | `VIRT-0002` |
| SCSI/SATA | `/sys/block/sda/device/{model,wwid}`, `vpd_pg80` (binary, 4-byte header) | `naa.5000c500a1b2c3d4` |

Values are space-padded, so trim them.

**`spl_hostid`: confirmed.** Run in a musl VM (Alpine 6.12 LTS kernel, ZFS
2.3.9) on one virtio disk, with `insmod spl.ko spl_hostid=…`, no `/etc/hostid`,
`zpool import -N -o cachefile=none -d /dev kubex`, `multihost=off`:

| Previous boot | This boot | Import without `-f` |
| --- | --- | --- |
| created with hostid A, powered off without export | A | ok |
| same | B | refused: *previously in use from another system … hostid=8a3f1c2e* |
| same | none (`spl_hostid=0`) | refused, same message |
| refused twice, untouched | A | ok |
| imported and `zpool export`ed by A | B | ok |

So a node that reboots, even uncleanly, imports its own pool, a pool moved to
other hardware needs a deliberate `-f`, and a clean export makes the pool
portable. The hostid must never be 0, so derive it from the UUID and fall back
if the result is 0.

**Khepri 0.19.3 projections: confirmed** on a 3-member local cluster (OTP 29.0.3).

- `khepri:register_projection/3` with `khepri_projection:new(Name, fun(Path,
  Data) -> Record end, #{keypos => 1, read_concurrency => true})`, registered
  once, creates the ETS table on all three members.
- A `put` on any member shows up in every table. A `delete`, which is how a
  revocation would land, removes the row everywhere.
- A member that resets and rejoins gets the table back with current contents. A
  member restarted from its data directory rebuilds the table, including writes
  made while it was down.
- Gotchas:
  - The wildcard is `#if_name_matches{regex = any}` (`?KHEPRI_WILDCARD_STAR`),
    not `'_'`. With `'_'` the registration succeeds and the table stays empty.
  - While the store is stopped the table does not exist (`ets:whereis/1` →
    `undefined`), so `decide/2` must fail closed.
  - After `khepri_cluster:reset/1`, the store must be started again before
    `join/2`.

**`verify_fun` in TLS distribution: the spec had it backwards.** From OTP 29's
`ssl` 11.7.3 source, then tested over a real `inet_tls` connection between two
nodes:

- **`-ssl_dist_optfile`** is evaluated with `erl_eval`, and its options go
  straight to `ssl`. `{verify_fun, {fun kv:decide/3, State}}` works: called with
  `valid_peer` on both sides, then `pong`. `{verify_fun, {kv, decide, State}}`
  is rejected (`{error, {options, {verify_fun, …}}}` from `ssl:listen`), and
  distribution only answers `pang`. Nothing is logged.
- **`-ssl_dist_opt server_verify_fun "{M,F,State}"`** on the command line is the
  only place the `{M, F, State}` string form is parsed. It works, but that path
  accepts a fixed whitelist of options, which leaves out
  `server_name_indication`, for example.
- The callback is arity 3 (`OtpCert, Event, State`), so `decide/2` needs a thin
  wrapper. The subject CN arrives as a UTF-8 binary.

[§2.9.4](specs.md) is corrected.

**Test infrastructure: two of four confirmed, the rest blocked on a decision.**

- **Unprivileged namespaces are blocked here, as documented.** `unshare
  --user --map-root-user --net` fails writing `uid_map`. `bwrap` (which has a
  shipped AppArmor profile) does get a user and network namespace. Its profile
  drops `CAP_NET_ADMIN`, though, so `ip link add … type bridge` and `ip tuntap`
  both get EPERM. Tier 2 needs the harness's own `userns` profile, and
  installing that is a one-time `sudo`. It has not been written yet.
- **KVM inside the namespace: confirmed.** QEMU with `-enable-kvm` boots inside
  the `bwrap` user namespace, so the `/dev/kvm` ACL for the real user applies.
- **ACPI power button: Nerves ignores it.** The kernel registers
  `LNXPWRBN` (`ACPI_BUTTON=y`), but nothing in erlinit or `nerves_runtime`
  listens. Twenty-five seconds after QMP `system_powerdown`, the guest was still
  at IEx. See [testing.md](testing.md) §6.
- **`/dev/kvm` on GitHub runners: not checked.** That needs a workflow run on a
  repository with a remote, which this one doesn't have yet.
- `chronyd`, `tcpdump` and `dnsmasq` are all installed ([testing.md](testing.md) §9).

---

Next: [phase 1](phase1.md)
