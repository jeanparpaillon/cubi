# Kubex node boot — open questions

Decisions not yet taken. Section numbers refer to [specs.md](specs.md).

- **The ZFS encryption key ([§2.10.4](specs.md)).** The options:
  - a `kubex.zfs.key=` argument, served over HTTPS like the token, with the same
    exposure;
  - sealed in a TPM, so storage nodes would need one;
  - leave the pool unencrypted and encrypt only `[kubex, pki, ca]` inside
    Khepri, which still leaves the question of where *that* key comes from.
- **Backups.** Khepri on ZFS survives node and whole-cluster restarts, but not
  losing a majority of pools. `zfs snapshot` of `<pool>/kubex/khepri`, plus
  `zfs send` off-cluster, is the obvious answer. It needs Ra's view of a
  consistent snapshot point **(verify)**.
- **Khepri before 1.0.** The API may change. Pin the version, and keep Khepri
  calls behind one kubex module so that an upgrade touches a single place.
- **ZFS licensing** for distributed images ([§2.10.5](specs.md)).
- **`kubex.join=` names one host.** If that node is down, joins fail. A list of
  hosts, or a DNS name kept up to date by the cluster, would avoid that.
- **Diskless nodes' logs and crash dumps** vanish with the RAM; storage nodes
  keep theirs in `<pool>/kubex/log`. Shipping logs from diskless nodes to a
  storage node over `logger` is the simple fix.
- **RAM floor.** Compressed rootfs + BEAM working set + tmpfs `/root`, from the
  [phase 0](phase0.md) measurement. This decides the minimum node spec.
- **Which squashfs compressor?** Boot time over a slow link favours xz/zstd-19.
  Compare with `marmoos_os` task 2.7.1.
