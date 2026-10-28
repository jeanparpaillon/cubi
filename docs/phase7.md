# Phase 7 — plug into cubi

Part of the cubi node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [ ] `cluster_boot` picks rejoin / join / bootstrap / restricted from the pool identity, the token file and the cmdline, refusing `join` + `bootstrap` together ([§2.8](specs.md)).
- [ ] Stage-1 moves `/cubi/token` to `/root/.cubi/token` (0400); `cluster_boot` deletes it after the attempt. `cubi.token=` accepted with a warning, for QEMU only ([§2.8.2](specs.md)).
- [ ] Bootstrap web server: HTTPS with a self-signed certificate and its fingerprint on the console, OTP check with rate-limiting, then CA + Khepri init + two role-scoped masters, shown once. Refused if the pool already holds a store ([§2.8.4](specs.md)).
- [ ] Copy from `nerves_hub_web`: NH1 verification (`DeviceLink.Authentication`), the key/secret generator, `NervesHub.Certificate`, and `NervesHub.SSL.decide/2`, with Khepri transactions and projections in place of Ecto ([§2.9.2](specs.md), [§2.10.1](specs.md)). Add `NOTICE`.
- [ ] Copy from `nerves_hub_link`: NH1 signing and the LocalCertKey-style `:ssl` mapping ([§2.9.3](specs.md)).
- [ ] Join endpoint (issuance): parse `kbxn_` key, derive node secret, NH1 verify, then a transaction for scope check, member upsert as `registered`, previous cert revocation and audit record. Wait for time sync first ([§2.8.1](specs.md), [§2.9.4](specs.md)).
- [ ] TLS distribution `verify_fun` (admission): `decide/2` pins the cert and marks the member `provisioned`.
- [ ] `Cluster.mint_token/1`, `Cluster.rotate_token/1` with overlap, revocation of masters, and certificate revocation (CRL) ([§2.8.1](specs.md)).
- [ ] Boot server ([§2.7](specs.md)): inventory, per-node derivation of `kbxn_` tokens, token file served only to diskless nodes and not-yet-provisioned storage nodes, inventory synced to `allowed_ids`, `cubi.bootstrap=` rendered once.
- [ ] ZFS key ([§2.10.4](specs.md)): generated at bootstrap; `GET /zfs-key` on the join listener, served only to the certificate pinned for a non-removed storage member, rate-limited and audited; the BEAM-side mTLS fetch (`cubi.join=` host, then `/cubi/identity/peers`) piped into `zfs load-key`; `<pool>/cubi/crypt` created at bootstrap and first join, unlocked at every boot.
- [ ] Cold-start unlock page when no source answers, `Cluster.export_zfs_key/0`, `Cluster.rotate_zfs_key/0`, and the `Cluster.status/1` warning while the key was never exported.
- [ ] Storage-role joins become Khepri voters (`khepri_cluster:join/2`) only after `Cluster.promote/1`; diskless nodes use the cubi API ([§2.8.1](specs.md), [§2.10.2](specs.md)).
- [ ] Stale diskless members left behind by a reboot are expired.
- [ ] Harness: `Cluster` fixture, fault injection and the `Leak` scanner ([testing.md](testing.md) §2, §6).

**Acceptance:**

- A storage QEMU node booted with `cubi.bootstrap=` creates a cluster from the web page.
- Two more storage nodes (promoted) and one diskless node boot with tokens derived by the boot server and form a TLS-distributed cluster with three voters.
- A wrong OTP, a second use of the right one, a token from a deactivated master and a join for a UUID outside the allowlist are all refused.
- Node A's token is refused when presented with node B's UUID, and a diskless-role token never yields a voter.
- No token appears in `/proc/cmdline`, the kernel log, or `/root` once the join ends.
- Restarting every node at once brings the cluster back with its state once the exported ZFS key is typed into one storage node's unlock page, and the storage nodes don't need a token to rejoin. Restarting the first node alone needs nothing: it fetches the key from a peer.
- `/zfs-key` refuses a request with no certificate, one from a diskless node, a certificate superseded by a later join, and one from a removed member. Every storage node's `<pool>/cubi/crypt` reports `keystatus=available` and `encryption=aes-256-gcm`.
- The exported key opens a storage node's pool with stock `zpool import` + `zfs load-key` outside cubi, and no disk image contains it.

---

Previous: [phase 6](phase6.md) · Next: [phase 8](phase8.md)
