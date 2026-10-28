# Phase 6 — storage

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] Parse `kubex.vdevs=` / `kubex.zpool=` / `kubex.zfs.create=`, and resolve by-id-style names from sysfs.
      `Kubex.Cmdline`, `Kubex.Storage.Args`, `Kubex.Storage.Devices` in `apps/kubex_fw`; unit-tested on fake sysfs trees and against the dev host's own `/dev/disk/by-id`.
- [x] Import, or guarded create, then the `<pool>/kubex` dataset tree with `refreservation`, mounted on `/kubex` ([§2.10.3](specs.md)). With no cluster yet there is no ZFS key, so `<pool>/kubex/crypt` is keyed from `kubex.zfs.testkey=` on the cmdline, accepted with a warning, for QEMU only; [phase 7](phase7.md) brings the real key ([§2.10.4](specs.md)).
      `Kubex.Storage.Pool` (the steps; commands injectable, unit-tested) run once at boot by `Kubex.Storage`, which
      reports on the console. The system gained util-linux `wipefs`. `kubex.zfs.testkey=` is compiled out of `:prod`.
      Checked by hand in QEMU: a virtio + NVMe mirror created; after a power-off without export, imported without
      `-f`, a synced file still there (an unsynced one written just before is lost, as it should be); without the
      key, `crypt` stays locked; a GPT disk and a missing `kubex.zfs.create=1` both refused, the disk untouched.
- [x] Harness: `Disk` fixtures (blank, dirty, kept across reboots) on virtio-blk and NVMe with explicit serials ([testing.md](testing.md) §5).
      `Kubex.E2E.Disk` and `restart_vm!/2`. `phase6_storage_test.exs` covers the acceptance below with an `O_SYNC`
      file standing in for Khepri until step 4, plus: no key leaves `crypt` locked, another pool name over a used
      disk is refused, and refused disks are byte-identical afterwards.
- [ ] Start Khepri on `/kubex/khepri` with node name `kubex@<UUID>`, and export the pool on shutdown.

**Acceptance:**

- A QEMU VM with two blank virtio disks and `kubex.vdevs=mirror,…` `kubex.zfs.create=1` creates the pool.
- Rebooting it imports the pool, and data written to Khepri is still there.
- The same VM with a disk that has a partition table, or without `kubex.zfs.create=1`, refuses to create.

---

Previous: [phase 5](phase5.md) · Next: [phase 7](phase7.md)
