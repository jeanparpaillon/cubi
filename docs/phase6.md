# Phase 6 — storage

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] Parse `kubex.vdevs=` / `kubex.zpool=` / `kubex.zfs.create=`, and resolve by-id-style names from sysfs.
      `Kubex.Cmdline`, `Kubex.Storage.Args`, `Kubex.Storage.Devices` in `apps/kubex_fw`; unit-tested on fake sysfs trees and against the dev host's own `/dev/disk/by-id`.
- [ ] Import, or guarded create, then the `<pool>/kubex` dataset tree with `refreservation`, mounted on `/kubex` ([§2.10.3](specs.md)). With no cluster yet there is no ZFS key, so `<pool>/kubex/crypt` is keyed from `kubex.zfs.testkey=` on the cmdline, accepted with a warning, for QEMU only; [phase 7](phase7.md) brings the real key ([§2.10.4](specs.md)).
- [ ] Harness: `Disk` fixtures (blank, dirty, kept across reboots) on virtio-blk and NVMe with explicit serials ([testing.md](testing.md) §5).
- [ ] Start Khepri on `/kubex/khepri` with node name `kubex@<UUID>`, and export the pool on shutdown.

**Acceptance:**

- A QEMU VM with two blank virtio disks and `kubex.vdevs=mirror,…` `kubex.zfs.create=1` creates the pool.
- Rebooting it imports the pool, and data written to Khepri is still there.
- The same VM with a disk that has a partition table, or without `kubex.zfs.create=1`, refuses to create.

---

Previous: [phase 5](phase5.md) · Next: [phase 7](phase7.md)
