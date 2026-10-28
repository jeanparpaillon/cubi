# Phase 6 — storage

Part of the cubi node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] Parse `cubi.vdevs=` / `cubi.zpool=` / `cubi.zfs.create=`, and resolve by-id-style names from sysfs.
      `Cubi.Cmdline`, `Cubi.Storage.Args`, `Cubi.Storage.Devices` in `apps/cubi_fw`; unit-tested on fake sysfs trees and against the dev host's own `/dev/disk/by-id`.
- [x] Import, or guarded create, then the `<pool>/cubi` dataset tree with `refreservation`, mounted on `/cubi` ([§2.10.3](specs.md)). With no cluster yet there is no ZFS key, so `<pool>/cubi/crypt` is keyed from `cubi.zfs.testkey=` on the cmdline, accepted with a warning, for QEMU only; [phase 7](phase7.md) brings the real key ([§2.10.4](specs.md)).
      `Cubi.Storage.Pool` (the steps; commands injectable, unit-tested) run once at boot by `Cubi.Storage`, which
      reports on the console. The system gained util-linux `wipefs`. `cubi.zfs.testkey=` is compiled out of `:prod`.
      Checked by hand in QEMU: a virtio + NVMe mirror created; after a power-off without export, imported without
      `-f`, a synced file still there (an unsynced one written just before is lost, as it should be); without the
      key, `crypt` stays locked; a GPT disk and a missing `cubi.zfs.create=1` both refused, the disk untouched.
- [x] Harness: `Disk` fixtures (blank, dirty, kept across reboots) on virtio-blk and NVMe with explicit serials ([testing.md](testing.md) §5).
      `Cubi.E2E.Disk` and `restart_vm!/2`. `phase6_storage_test.exs` covers the acceptance below with an `O_SYNC`
      file standing in for Khepri until step 4, plus: no key leaves `crypt` locked, another pool name over a used
      disk is refused, and refused disks are byte-identical afterwards.
- [ ] Start Khepri on `/cubi/khepri` with node name `cubi@<UUID>`, and export the pool on shutdown.

**Acceptance:**

- A QEMU VM with two blank virtio disks and `cubi.vdevs=mirror,…` `cubi.zfs.create=1` creates the pool.
- Rebooting it imports the pool, and data written to Khepri is still there.
- The same VM with a disk that has a partition table, or without `cubi.zfs.create=1`, refuses to create.

---

Previous: [phase 5](phase5.md) · Next: [phase 7](phase7.md)
