# Kubex node boot — open questions

Decisions not yet taken. Section numbers refer to [specs.md](specs.md).

- **Unattended cold start.** Proposed in [security.md](security.md) §4.3:
  Shamir shares of the ZFS key, sealed in each storage node's TPM, with
  k = a majority of voters. Still to agree, and then to fold into the spec
  (security.md §7). Machines without a TPM keep the unlock page.
- **Talking to the TPM from BEAM.** `ssl` with a TPM-held key needs an OpenSSL
  engine or provider that OTP 29's `crypto` can drive
  ([security.md](security.md) §3) **(verify)**.
- **Backups.** Khepri on ZFS survives node and whole-cluster restarts, but not
  losing a majority of pools. `zfs snapshot` of `<pool>/kubex/crypt/khepri`,
  plus a raw `zfs send -w` off-cluster, is the obvious answer. The blocks stay
  encrypted and the exported ZFS key opens them. It needs Ra's view of a
  consistent snapshot point **(verify)**.
- **Khepri before 1.0.** The API may change. Pin the version, and keep Khepri
  calls behind one kubex module so that an upgrade touches a single place.
- **ZFS licensing** for distributed images ([§2.10.5](specs.md)).
- **When is a deployed release good?** In milestone 1 any exit of a release's
  application rolls back, even long after the settle period
  ([§2.11.7](specs.md)). Nerves instead treats a firmware as good once
  validated. Alternative: once settled (or after an explicit validate), a
  later exit restarts the same version, and only repeated failures roll back.
- **Several releases per node.** Milestone 1 allows one ([§2.11.6](specs.md)).
  More needs per-name state and a conflict check between releases, not only
  against the base image.
- **Who may deploy.** Anyone with an authorized ssh key can *send* a release
  ([§2.11.5](specs.md)); the signature decides what runs. With
  [phase 7](phase7.md), the channel could require a cluster-CA client
  certificate instead.
- **`config/runtime.exs` in releases.** Not evaluated in milestone 1
  ([§2.11.3](specs.md)). `Config.Reader` is on the node, but runtime config
  read from the node's environment needs a decision on what that environment
  is.
- **Revocation of signers.** None in milestone 1 ([§2.11.1](specs.md)). A CRL in
  the image, or a signed revocation list deployed like a release, would let a
  leaked signer be cut off without a new root.
- **`kubex.join=` names one host.** If that node is down, joins fail. A list of
  hosts, or a DNS name kept up to date by the cluster, would avoid that.
- **Diskless nodes' logs and crash dumps** vanish with the RAM; storage nodes
  keep theirs in `<pool>/kubex/log`. Shipping logs from diskless nodes to a
  storage node over `logger` is the simple fix.
- **RAM floor.** Compressed rootfs + BEAM working set + tmpfs `/root`. From
  [phase 0](phase0.md), a hello-world image reaches IEx at 192 MB, with Ubuntu's
  kernel standing in for the Nerves one, and has ~127 MB in use at idle. That
  points to 512 MB minimum for a diskless node. Storage nodes add `zfs.ko`
  (11 MB) and the ARC, which defaults to half of RAM and must be capped
  (`zfs_arc_max`) so that it does not compete with the RAM-resident rootfs. The
  storage-node figure is still open.
- **Which squashfs compressor?** Boot time over a slow link favours xz/zstd-19.
  On the phase 0 hello rootfs: gzip 28.6, zstd-19 26.0, xz 24.3, xz + BCJ x86
  23.8 MB, so xz saves ~17 %. Either one needs a squashfs decompressor added to
  the kernel ([§2.5](specs.md)). The cost to weigh is decompression CPU on page
  faults, since the rootfs is read from RAM rather than over the network.
  Compare with `marmoos_os` task 2.7.1.
