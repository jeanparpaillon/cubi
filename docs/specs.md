# Kubex node boot — specification

Plan for booting kubex cluster nodes from the network: iPXE fetches a kernel and
an initramfs over HTTP(S), and the machine comes up straight into BEAM. The OS
lives in RAM. Anything that must survive a reboot lives on a ZFS pool whose
disks are named on the kernel cmdline, the way SmartOS does it (§2.10). There is
nothing to flash, and "updating a node" means serving new files and rebooting it.

Nothing here is built yet. Points marked **(verify)** are assumptions to confirm
in [phase 0](phase0.md) before anything depends on them. The work is split into phases
(§3, one file each), and open questions are in [questions.md](questions.md).
The threat model, and the recommended setup with a TPM on every machine, are
in [security.md](security.md).

---

## 1. What changes compared with a normal Nerves image

A standard Nerves firmware is tied to a block device at every layer:

| Layer | Standard Nerves | Diskless / iPXE |
| --- | --- | --- |
| Bootloader | U-Boot / GRUB from disk, A/B slot | iPXE from NIC ROM or chainloaded |
| Rootfs | squashfs on a partition, mounted read-only | squashfs **inside the initramfs**, loop-mounted |
| App data (`/root`) | ext4/f2fs partition | tmpfs |
| Cluster state, PKI | — | Khepri, on a ZFS dataset reserved for kubex, on nodes given disks with `kubex.vdevs=` (§2.10) |
| Firmware metadata | U-Boot env (`nerves_fw_*` KV) | `Nerves.Runtime.KVBackend.InMemory`, seeded at build time |
| Update | `fwup` writes the inactive slot | the iPXE server serves a new pair of files; the node reboots |
| Rollback / validate | `nerves_fw_validated` + slot switch | no-op locally: the boot server decides which version to serve |
| Node identity | serial number from `boardid` | a certificate issued on join: `kubex.join=` on the cmdline plus a per-node token delivered as an initrd file, or created by the first node from `kubex.bootstrap=<OTP>` (§2.8). Storage nodes keep it on their pool across reboots; diskless nodes rejoin on every boot (§2.8.3) |

Erlang distribution, `vintage_net`, `shoehorn` and `nerves_runtime` are unchanged
once BEAM is running. The changes are all below BEAM and in how firmware
metadata is reported.

## 2. Design decisions

### 2.1 Target: x86_64 first, by forking `nerves_system_x86_64`

iPXE is at home on x86 (legacy BIOS `undionly.kpxe` and UEFI `ipxe.efi`), and
QEMU ships an iPXE NIC ROM, so the whole loop can be tested on a laptop. Fork
`nerves_system_x86_64` the same way `marmoos_system_rpi3` was forked (see
`marmoos_os/docs/system.md` §2: kernel options cannot be added out of tree).
Working name: `kubex_system_x86_64`.

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
`mode=400` on the token's `initrd` line is honoured ([phase 0](phase0.md)). The
fallback is to wrap it ourselves with `cpio -o -H newc`, which costs nothing,
but every piece must then be padded to a 4-byte boundary before concatenation.
The kernel silently ignores a cpio that follows a compressed one unaligned;
iPXE pads by itself.

### 2.3 Build: post-process the `.fw`, don't fight `mix firmware`

The system tarball does not contain the application. `mix firmware` (rel2fw)
merges the OTP release into the squashfs and packs it into a `.fw`, which is a
zip. So the iPXE artifacts are derived from the `.fw`:

```
mix firmware  →  kubex.fw (zip)
                   └── data/rootfs.img      → rootfs.squashfs
                         └── /boot/bzImage  → vmlinuz
stage1.cpio.zst  (built once, by the system)
```

The `.fw` has no kernel resource: GRUB loads `/boot/bzImage` from the rootfs
partition, so the kernel is only inside the squashfs ([phase 0](phase0.md)). A
`mix firmware.ipxe` task (in a small `kubex_ipxe` Mix dep, or in the fw app
first) unzips `data/rootfs.img`, takes the kernel out of it with `unsquashfs
-cat rootfs.img boot/bzImage`, copies `stage1.cpio.zst` out of the system
artifact directory, writes a `boot.ipxe`, and puts everything in
`_build/<target>_<env>/ipxe/`. The kernel then ships twice, 5.3 MB of it inside
the squashfs, until the system fork drops `/boot` from the rootfs.

### 2.4 Stage-1 init

This is `/init` in a tiny cpio. For now it is a busybox `sh` script,
`stage1/init` in the system fork, built by Buildroot: `package/kubex-stage1`
makes a ~200 KB static busybox with only the applets the script uses, and
`post-createfs.sh` assembles `images/stage1.cpio.zst` and
`images/stage1-dev.cpio.zst` (~105 KB each) with the kernel's
`gen_init_cpio`. Production
needs a small static C program instead, because busybox in the initramfs is a
shell that `rdinit=` can reach ([security.md](security.md) §5). Its whole job:

1. Mount `proc`, `sys`, `devtmpfs`.
2. `losetup` + mount `/rootfs.squashfs` read-only on `/newroot`.
3. Mount a tmpfs on `/newroot/root` (`mode=0700,nodev,nosuid`). Persistence is
   not stage-1's concern: kubex imports its ZFS pool from BEAM (§2.10.3).
4. Move `/kubex/token`, if present, to `/newroot/root/.kubex/token`, mode
   `0400` (§2.8.2).
5. `mount --move /dev /newroot/dev`. erlinit expects a populated `/dev` and
   only remounts it; without the move it has no console and no `/dev/null`.
6. `exec env -i TERM=linux HOME=/ switch_root /newroot /sbin/init`: always
   erlinit, with no arguments and a clean environment. The kernel turns
   unknown `key=value` cmdline arguments into init's environment, and
   `ERL_AFLAGS=…` would otherwise reach the BEAM.

The archive also ships `/dev/console` and an empty `/kubex` directory. The
kernel does not create parent directories when it unpacks an initrd, so
iPXE's `initrd … /kubex/token` needs `/kubex` to exist in an earlier archive.
`gen_init_cpio` writes the device node without root, with owner 0 and mtime 0,
so the archive is reproducible.

`switch_root` empties the old rootfs, but the loop device keeps the squashfs
file alive. A failure at any step prints `kubex stage-1: …` on the console.
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

- Drop the `-m /dev/…:/root` mount: stage-1 owns `/root`.
- Replace `-d /usr/bin/boardid` with a small script that prints the SMBIOS UUID
  (falling back to the first MAC). This only gives a hostname for `erlinit -n`
  and the console, and the stable Erlang node name `kubex@<UUID>` that a Khepri
  member needs (§2.10.2). It is *not* the cluster identity, which is the
  certificate assigned on join (§2.8).
- `config :nerves_runtime, kv_backend: {Nerves.Runtime.KVBackend.InMemory,
  contents: %{…}}`, filled at build time with `nerves_fw_active`,
  `a.nerves_fw_version`, `a.nerves_fw_uuid` …, and `nerves_fw_validated: "1"`.
  This keeps `Nerves.Runtime.firmware_valid?/0` and friends truthful.
- Remove `ssh_subsystem_fwup` from the target deps. `mix upload` has nothing to
  write to, and a half-working update path is worse than none.

### 2.7 The iPXE side: the boot server

The boot server does more than serve files. It is the one component outside the
cluster that holds a join secret, so it is part of the trust boundary:

| Role | What it does |
| --- | --- |
| **Images** | Serves `vmlinuz`, `stage1.cpio.zst` and `rootfs.squashfs` per version. Choosing the version per node replaces A/B slots: promoting a version, canarying it or rolling it back is all server-side |
| **Per-node script** | Renders `https://boot.example/node/${uuid}.ipxe` for each machine in its **inventory**, the list of SMBIOS UUIDs it boots |
| **Token derivation** | Holds the master tokens (§2.8.1) and derives each node's token from them, so a node never receives a master |
| **Token file** | Serves `node/${uuid}/token` (§2.8.2), only while that node needs one: always for diskless nodes, and until the first successful join for storage nodes |
| **Bootstrap OTP** | Renders `kubex.bootstrap=` for the first node, exactly once (§2.8.4) |

A joining node's script:

```ipxe
#!ipxe
set base https://boot.example/kubex/${version}
kernel ${base}/vmlinuz console=ttyS0 kubex.join=${join} kubex.vdevs=${vdevs}
initrd ${base}/stage1.cpio.zst
initrd ${base}/rootfs.squashfs /rootfs.squashfs
initrd https://boot.example/node/${uuid}/token /kubex/token
boot
```

The script leaves out the `initrd …/token` line for a provisioned storage node,
and `kubex.vdevs=` for a diskless one (§2.10.3).

The boot server learns which storage nodes are provisioned from the cluster.
Either it calls `Cluster.status/1`, or the cluster pushes it the provisioned
UUIDs. The same feed keeps the cluster's allowlist (§2.8.1) in step with the
inventory, so the two agree on which machines exist.

- **Integrity.** Build a custom iPXE with `DOWNLOAD_PROTO_HTTPS`, an embedded
  `TRUST=` CA, and `imgverify` on the three image files (signed with
  `openssl cms`). The token file is per node and is not signed; HTTPS covers it.
  UEFI Secure Boot (shim + signed iPXE) is out of scope for v1.
- **Only the chainload step may use plain TFTP/HTTP.** Serving
  `undionly.kpxe` / `ipxe.efi` by client architecture from a dnsmasq proxy-DHCP
  config lets this coexist with an existing DHCP server, and that step carries no
  secret. Everything after it, scripts and token files, is HTTPS.
- **Its config is protected like a CA key.** It holds the masters.

### 2.8 Node credentials

A node gets everything it needs to join or create a cluster from three places:

| Source | Carries | Notes |
| --- | --- | --- |
| cmdline `kubex.join=<HOST>` | endpoint of an existing cluster: [architecture.md](architecture.md) §2's `bootstrap_endpoint` | not secret, fine to log |
| initrd file `/kubex/token` | this node's join token, `kbxn_<master id>.<uuid>:<secret>` (§2.8.1) | never on the cmdline (§2.8.2) |
| cmdline `kubex.bootstrap=<OTP>` | no cluster yet: this node creates one | single-use, spent minutes after boot (§2.8.4) |

The storage arguments (`kubex.vdevs=` and friends) are in §2.10.3. A storage
node that has already joined also has its key and certificate on its pool, in
`/kubex/identity`.

`cluster_boot` picks a mode at start:

| Has | Mode |
| --- | --- |
| identity on its pool | **rejoin**: straight to the distribution handshake, no token needed (§2.8.3) |
| `kubex.join=` + token file | **join** (§2.8.3) |
| `kubex.bootstrap=`, no `kubex.join=`, an empty pool | **bootstrap** (§2.8.4) |
| `kubex.bootstrap=` with a store already on the pool | refused: restarts its Khepri member instead (§2.10.3) |
| `kubex.join=` **and** `kubex.bootstrap=` | refused: logged, then restricted. Guessing here could split a cluster |
| none of the above | **restricted**: BEAM runs, the node does nothing cluster-wise. This is what booting by hand in QEMU does, so phases [1](phase1.md)–[6](phase6.md) don't need a cluster |

#### 2.8.1 Tokens: masters, per-node derivation, scopes

**Masters** are created by the bootstrap node, and later by
`Cluster.mint_token/1`. They are kept in Khepri at `[kubex, tokens, MasterId]`
(§2.10.1) and in the boot server's config. Nowhere else.

Each master is a `kbx_` key and a secret, in NervesHub's format (§2.9.2), plus a
scope:

| Scope | Effect |
| --- | --- |
| `role: storage \| diskless` | A diskless-role token can never produce a Khepri voter. A node becomes a voter only with a storage-role token **and** an operator's `Cluster.promote/1`, so no token alone changes quorum |
| `expires_at` | NH1 bounds each *request* to 90 s; this bounds the *master*. Rotating before expiry is routine |
| `max_joins` | Counted in the join transaction. For one-off masters handed out for a single new storage node |
| `allowed_ids` | Allowlist of SMBIOS UUIDs, kept in step with the boot server's inventory (§2.7). A join for an unlisted UUID fails even with a valid secret. This is NervesHub's non-JITP mode, `maybe_jitp_device/2` with `jitp: nil` → `:device_not_registered` |

**Per-node tokens** are derived from a master. Nothing is stored per node, and
only the boot server and the cluster can compute one:

```
node_secret = HMAC-SHA256(master_secret, "kubex:node-token:v1:" <> uuid)
node_key    = "kbxn_" <> master_id <> "." <> uuid
```

- **This is NervesHub's per-device level** (`Devices.SharedSecretAuth`, next to
  the per-product `nhp_`), with the device's secret computed rather than
  stored.
- **NH1 on the wire is unchanged.** `node_key` is the `x-nh-key` header, which
  NH1 already binds into the signed salt.
- **A leaked node token** works for that one UUID only, and with an allowlist
  only on that machine's own identity. Using it from another machine means
  impersonating that UUID, which the join audit (§2.8.5) shows.

**Lifecycle:**

- **Rotate:** `Cluster.rotate_token(master_id)` mints a successor with the same
  scope, and the boot server is updated. The old master stays valid until a
  short overlap ends, then it is deactivated. Deactivating a master invalidates
  every node token derived from it at once.
- **Revoke:** deactivate immediately, without the overlap. Joins in flight fail
  (§2.9.2's subscribe-before-lookup ordering).

#### 2.8.2 Delivering the token: an initrd file, never the cmdline

The kernel prints its command line to the kernel log at boot
(`Kernel command line: …`), and Nerves' `RingLogger` captures the kernel log.
`/proc/cmdline` stays world-readable for as long as the node runs. So the token
travels the way the squashfs does (§2.2): iPXE wraps the token file into the
initramfs as `/kubex/token`.

1. **Stage-1** moves `/kubex/token` to `/newroot/root/.kubex/token` (tmpfs, mode
   `0400`) before `switch_root` deletes the initramfs.
2. **`cluster_boot`** reads the file, then deletes it, once the join attempt
   ends either way.
3. **The token never appears** in the cmdline, the kernel log or `ps`, and it
   is never logged.

For hand-booted QEMU before the boot server exists (phases [1](phase1.md)–[6](phase6.md)),
`kubex.token=<key>:<secret>` on the cmdline is accepted with a warning. Nothing
else uses it.

#### 2.8.3 Join and rejoin

**Join (first time, and every boot of a diskless node).** `Cluster.join(join,
token)`, which follows §2.9.4. The cluster checks the node token against its
master's scope, and then issues a certificate whose CN is the node's UUID.

- **Diskless node:** the key and certificate live in RAM. The next boot is a
  fresh join with a fresh key, under the same UUID. The join replaces that
  member's certificate and revokes the old one, so no stale member is left
  behind.
- **Storage node:** the key and certificate are written to `/kubex/identity`.
  With that certificate it fetches the cluster's ZFS key and creates its
  encrypted datasets (§2.10.4). After the first join, the boot server stops
  serving it a token (§2.7).

**Rejoin (storage node, identity on its pool).** No token is needed. The node
fetches the ZFS key with its stored certificate and unlocks its pool
(§2.10.4), then goes straight to the handshake half of §2.9.4, and Ra catches
up from its log. A
storage node that has lost its pool is a forced removal of the old voter
([architecture.md](architecture.md) §3). The boot server serves it a token again, and it joins as new.

Either way, a node that never comes back is expired by failure detection
(forced removal, [architecture.md](architecture.md) §3).

#### 2.8.4 Bootstrap: the first node

The first node has nobody to join, so it proves its operator out of band. It
must be a storage node with an empty pool (§2.10.2).

1. The boot server renders this node's script with `kubex.bootstrap=<OTP>`, once.
   The operator who set it up knows the OTP.
2. The node starts BEAM and a **bootstrap web server**, and prints its address
   and the server's certificate fingerprint on the console. Nothing
   cluster-related runs yet: no distribution listener, no Khepri.
3. The operator opens the page, checks the fingerprint against the console, and
   types the OTP. The node compares it in constant time with the cmdline value.
4. On a match the node bootstraps:
   - It generates the cluster CA and its own node certificate, written to
     `/kubex/identity`.
   - It creates its pool, generates the cluster's ZFS key and creates
     `<pool>/kubex/crypt` with it (§2.10.4). The page does not show the key: it
     is exported separately, so that it never lands in the boot server's config
     with the masters.
   - It starts Khepri on `/kubex/khepri` with itself as the only member and
     voter (§2.10), and writes the CA there.
   - It starts TLS distribution.
   - It mints two masters, one per role, each with an expiry, and its own UUID
     on their allowlists.
5. The page shows the two masters and the `kubex.join=` value, once. **They go
   into the boot server's config, not onto any node.** The operator then adds
   the other machines' UUIDs to the boot server's inventory, which syncs them to
   the allowlists.
6. The bootstrap web server stops, and the OTP is spent. A second correct entry
   is refused. After a reboot, the store on the pool makes the node refuse
   `kubex.bootstrap=` altogether (§2.10.3). The boot server's render-once rule is
   a second line of defence.

Rules for the bootstrap web server:

- **HTTPS with a self-signed certificate.** Over plain HTTP, anyone on the
  segment reads the OTP as it is typed and the masters as they are displayed.
- **Rate-limit attempts** (for example 5, then exponential back-off). An OTP is
  short enough to type, which also makes it short enough to brute-force.
- **It never starts in any other mode.** The only way to reach it is
  `kubex.bootstrap=` on the cmdline, with an empty pool.

#### 2.8.5 Audit, and what stays exposed

- **Every join is recorded** in Khepri: node key, UUID, source address, result.
  Failures are flattened to `:invalid_auth` for the caller, with the detail in
  telemetry (§2.9.2).
- **The signal that a node token was copied:** a join for a UUID that is already
  `provisioned`, from a different address.
- **Log `kubex.join=` freely.** Never log a token, an OTP or a master.
- **What remains exposed:**

  | Secret | Where it lives | Its limit |
  | --- | --- | --- |
  | **masters** | the boot server and Khepri on every voter | at rest on voters: §2.10.4 |
  | **a node token** | one node's tmpfs, between stage-1 and the end of its join | one UUID, one role, until its master expires |
  | **the OTP** | one node's cmdline | spent minutes after boot |
  | **the ZFS key** | RAM of unlocked storage nodes, the operator's export | served only to the certificate pinned for a storage member: §2.10.4 |
  | **a storage node's identity key** | in clear on its pool | fetches the ZFS key until that member is removed: §2.10.4 |

### 2.9 What to reuse from NervesHub: client and server

Both halves are Elixir and Apache-2.0, and both were read:

- **client:** `nerves_hub_link` 2.12.0 (`marmoos_os/deps/nerves_hub_link`);
- **server:** `nerves_hub_web` at `4f7df5a` (2026-10-27).

Registration lives in the server, so most of what kubex needs comes from there.
Copied files keep their SPDX headers, and kubex gets a `NOTICE` naming both
projects.

#### 2.9.1 Two ways to use it

- **A. Run a real NervesHub as kubex's registration authority.** Nodes run
  `nerves_hub_link`, and kubex reads the device list from the NervesHub API.
  That makes an external server a hard dependency of `Cluster.join`, which
  contradicts the self-bootstrapping first node of §2.8.4. Half of what NervesHub
  does, firmware updates, cannot apply anyway, since boot images come from iPXE.
- **B. Copy both halves into kubex** (recommended). Every member runs the server
  half, with Khepri (§2.10) in place of NervesHub's Postgres. Joining nodes run
  the client half.

Plan for **B**, and keep the NH1 wire format unchanged so that A stays possible
later for observability.

#### 2.9.2 Server side: copied from `nerves_hub_web`

NervesHub registers a device in two ways, and kubex uses both, one after the
other:

| Piece | In `nerves_hub_web` | In kubex |
| --- | --- | --- |
| **NH1 verification** | `NervesHub.DeviceLink.Authentication.authenticate({:shared_secret, headers})` and `decode_from_headers/1`: rebuilds the salt, then `Plug.Crypto.verify(secret, salt, sig, max_age: 90)` returns the identifier | **Copy**, with one step changed: instead of looking up a stored secret, parse `kbxn_<master id>.<uuid>` from `x-nh-key`, load the master, and derive the node secret (§2.8.1). Then check that the verified identifier equals that UUID. Keep `cache: nil`: without it, Plug.Crypto caches one derived key per salt in ETS and never evicts, and NervesHub measured 41.5 MB after 12 days. Keep the failure flattening to `:invalid_auth` too |
| **Key/secret format** | `NervesHub.Products.SharedSecretAuth`: key `nhp_` + 43 chars, secret 43 chars, each `strong_rand_bytes(32)` base64 without padding; `deactivated_at` for revocation | **Copy the generator** for masters (`kbx_` prefix), with `deactivated_at` plus the scope fields of §2.8.1. Per-node `kbxn_` tokens are derived, not generated |
| **Per-device vs per-product secrets** | `Devices.SharedSecretAuth` (stored per device) next to `Products.SharedSecretAuth` (`nhp_`) | **Same two levels**, with the device level derived from the product level (§2.8.1), so nothing per node is stored |
| **Pre-registration** | `maybe_jitp_device/2` with `jitp: nil`: an identifier not created beforehand → `:device_not_registered` | **Copy** as the `allowed_ids` check (§2.8.1) |
| **Revocation racing a connect** | `DeviceSocket` subscribes to the key's topic *before* the lookup, so a deactivation racing a connect is never missed | **Same ordering** in the join endpoint, on the master's deactivation event (Khepri projection, §2.10.1) |
| **JITP at the TLS handshake** | `NervesHub.SSL.decide/2`, an `:ssl` `verify_fun`: find the signer by AKI → SKI, `:public_key.pkix_path_validation/3` against it, require a CN, look up the certificate by fingerprint, else the device by public-key fingerprint, else create the device from the CN; pin the certificate (fingerprint, serial, AKI/SKI, validity) | **Copy as the TLS distribution `verify_fun`** on every member. The CA lookup is the cluster CA, not a table, and "device" is the Khepri member record. A peer presenting a cluster-signed certificate becomes *provisioned* on its first distribution handshake: [architecture.md](architecture.md)'s "Report ready → Active membership", done in the handshake |
| **Safety rules in `decide/2`** | self-signed peer accepted only if pinned (`register: false`); deleted device → refused; one public key per device (`:unexpected_pubkey`); CN must match the existing device (`:mismatched_cert`) | **Keep all except one.** A new public key for a known UUID is a diskless reboot (§2.8.3). It is allowed only through a fresh NH1-authenticated join, which revokes the old certificate. The same key change arriving *without* a join is still refused |
| **`decide/2` needs no database** | split from `verify_fun/3` so that a TLS terminator with no database can ask over the cluster | **Fits as is.** On a storage node it reads Khepri projections locally (§2.10.1). A diskless node that accepts connections asks a storage node, the remote path NervesHub built it for |
| **`NervesHub.Certificate`** (176 lines) | AKI/SKI/CN/serial/validity/fingerprint/public-key-fingerprint helpers over `X509` | **Copy verbatim** |
| Ecto schemas, `Repo`, orgs/products, deployments, firmware, UI | — | **Leave behind.** `Devices.get_or_create_device/2` and `Certificates.*` become Khepri reads and transactions (§2.10.1) |

#### 2.9.3 Client side: from `nerves_hub_link`

| Piece | In `nerves_hub_link` | In kubex |
| --- | --- | --- |
| **NH1 signing** | `Configurator.SharedSecret.headers/1`: `Plug.Crypto.sign(secret, salt, identifier, signed_at: os_time)` | **Copy.** `key` is the node key and `secret` the node secret. The secret never goes on the wire; only a 90-second HMAC of the UUID does |
| **Identifier** | `Nerves.Runtime.serial_number/0` | The SMBIOS UUID from §2.6's `boardid`: the NH1 identifier, the UUID in the node key, and the CSR's CN, all three checked equal |
| **Cert/key → `:ssl` options** | `Configurator.LocalCertKey`: reads `nerves_hub_cert` / `nerves_hub_key` from `Nerves.Runtime.KV` | **Adapt.** The cert and key live in the InMemory KV (`KV.put/2` works on that backend), loaded from `/kubex/identity` on a storage node. The `:ssl` list feeds TLS distribution |
| **Configurator behaviour** | NervesKey → TPM → SharedSecret | **Copy the shape**: `Kubex.Credentials`, tried in order `PoolIdentity` (rejoin), `TokenFile`, `Cmdline` (QEMU only). TPM and NervesKey drop in later for nodes with a sealed key, which can go straight to the handshake |
| Socket, extensions, remote IEx, `UpdateManager` / `fwup` | | **Not applicable**: peers talk over distribution, and updates are iPXE-side |

Copy the code rather than depending on either project: the client drags in
`fwup` and `slipstream`, and the server is an application, not a library.
Depend on `x509` and `plug_crypto` directly. `x509` also does what NervesHub
leaves to its CLI: `X509.PrivateKey.new_ec/1` and `X509.CSR.new/2` on the node;
`X509.Certificate.self_signed/2` and `new/4` for the CA and for signing.

#### 2.9.4 The join, end to end

Two stages, matching NervesHub's two registration paths: **issuance**
(shared secret, over HTTPS) and then **admission** (JITP, in the distribution
handshake). A rejoining storage node skips issuance.

```mermaid
sequenceDiagram
    participant N as Joining node
    participant B as Join endpoint (any member)
    participant K as Khepri

    N->>N: Read and delete token file, EC key in RAM, CSR with CN = uuid
    N->>B: POST /join with CSR + NH1 headers (x-nh-key = kbxn_master.uuid)
    B->>K: Load master (projection)
    B->>B: Derive node secret, Plug.Crypto.verify → identifier
    B->>B: identifier == key uuid == CSR CN
    B->>K: Transaction: scope check (role, expiry, max_joins, allowlist), upsert member, revoke previous cert, audit
    K-->>B: Committed (status: registered)
    B-->>N: Certificate signed by cluster CA, CA chain, cluster config
    N->>N: KV.put cert/key (+ /kubex/identity on storage), build :ssl opts
    opt storage node
        N->>B: GET /zfs-key over mTLS with the new certificate (§2.10.4)
        B-->>N: ZFS key, if the cert is the one pinned for a storage member
        N->>N: create <pool>/kubex/crypt with it, mount khepri and log
    end
    N->>K: TLS distribution handshake
    K->>K: verify_fun = SSL.decide/2: path-valid, CN known, pin cert
    K-->>N: Connected (status: provisioned)
```

A few points:

- **The CSR is signed before the transaction.** Khepri transactions must be
  deterministic, so the transaction only records the signed certificate
  (§2.10.1). A transaction that aborts, on scope or a race, discards the
  certificate unissued.
- **The clock matters.** NH1 rejects signatures older than `max_age` (90 s), and
  scopes carry an expiry. Stage-1 doesn't set the time, so the join waits for
  `nerves_time` to sync, or trusts the RTC if the boot script says so. A wrong
  clock fails with a console message, not a silent retry loop.
- **`verify_fun` in TLS distribution** goes in the `-ssl_dist_optfile` as a
  fun, `{verify_fun, {fun 'Elixir.Kubex.SSL':verify/3, State}}`. OTP 29
  evaluates that file with `erl_eval` and hands it to `ssl` unchanged, so the
  `{Module, Function, State}` form is rejected there, and distribution then
  just fails to connect (`pang`) with nothing logged. That form is only parsed
  for `-ssl_dist_opt server_verify_fun` on the command line, which accepts a
  fixed whitelist of options and is not used ([phase 0](phase0.md)). The
  callback is arity 3, so `verify/3` is a thin wrapper over the stateless
  `decide/2`. The CN arrives as a UTF-8 binary.

### 2.10 Cluster state in Khepri, persisted on ZFS

This is the SmartOS model. The OS is a RAM image thrown away at every boot,
loaded from the network or a USB key. Everything that must survive lives on a
ZFS pool built from local disks. SmartOS calls its pool `zones` and keeps even
its own configuration there (`zones/usbkey`). In kubex:

- **the OS** is the iPXE image (§2.2);
- **the state** is a pool whose disks are named on the cmdline;
- **a node with no disks named** is diskless, exactly as in §2.8.

#### 2.10.1 Khepri is the store, and the Raft

[Khepri](https://github.com/rabbitmq/khepri) is a tree-structured database
replicated with Raft through Ra. It is licensed Apache-2.0 OR MPL-2.0. At
0.19.x it is the default metadata store of RabbitMQ 4.2 and the only one from
4.3, but its API is not frozen before 1.0. It *is* [architecture.md](architecture.md) §4's
consensus-backed membership: there is no separate Raft to build.

Everything §2.9 called "membership" is a path in one store:

```
[kubex, members, Id]                         status (registered | provisioned | removed), voter?, addresses
[kubex, members, Id, certs, Fingerprint]     pinned cert: der, serial, aki, ski, validity   (decide/2)
[kubex, pki, ca]                             CA certificate + key (key at rest: §2.10.4)
[kubex, pki, crl]
[kubex, tokens, MasterId]                    master secret, scope (role, expires_at, max_joins, allowed_ids), join count, deactivated_at
[kubex, joins, Seq]                          audit: node key, uuid, source address, result   (§2.8.5)
[kubex, zfs_key]                             SHA-256 of the ZFS key, created_at, exported_at; never the key   (§2.10.4)
[kubex, key_fetches, Seq]                    audit: uuid, cert fingerprint, source address, result   (§2.10.4)
[kubex, config]                              cluster config returned by a join
```

How the copied NervesHub code (§2.9.2) maps onto it:

- **Ecto queries** become `khepri:get/2`. The writes, including the uniqueness
  NervesHub left to `devices_identifier_index`, become `khepri:transaction/2`.
  Transaction funs must be deterministic, so certificate signing happens
  *before* the transaction, which only records the result.
- **`decide/2` lookups and the revocation ordering** use projections: ETS tables
  that Khepri keeps in sync on every member. That way the TLS handshake never
  waits on a Raft round-trip, and a revocation reaches every member's table.
  Checked on 0.19.3 ([phase 0](phase0.md)): a projection registered once exists
  on every member, a rejoining or restarted member rebuilds it, and a delete
  clears the row everywhere. The table does not exist while the local store is
  stopped, so `decide/2` fails closed when `ets:whereis/1` returns `undefined`.
  Path patterns use `?KHEPRI_WILDCARD_STAR`. `'_'` registers fine and matches
  nothing. Triggers don't fit here: they run only on the leader, at least once.
- **Projections are slightly stale.** A certificate revoked a few milliseconds
  ago can still pass one handshake. Registration stays exact, because it is a
  transaction.

At the Khepri level, a node that is going to vote calls
`khepri_cluster:join(StoreId, RemoteNode)` after its admission (§2.9.4). That
call resets the local store first, which is what we want for a new member.

#### 2.10.2 Only storage nodes vote

A Raft voter whose log does not survive a restart can forget votes and entries
it already acknowledged, and that breaks Raft's safety. Khepri's README states
the requirement: durable storage and stable node identities. So there are two
kinds of node:

| Node | Has | Khepri |
| --- | --- | --- |
| **storage** | `kubex.vdevs=` (§2.10.3) | runs a member and may be a voter. Its Erlang node name is stable: `kubex@<SMBIOS UUID>`, from §2.6's `boardid` |
| **diskless** | nothing | runs no member. It reads and writes the store through a kubex API over distribution, served by a storage node. Its identity is fresh on every boot (§2.8) |

Consequences:

- **The bootstrap node must be a storage node.** Tolerating one failure needs
  three storage nodes ([architecture.md](architecture.md) §4). A cluster of diskless nodes only is not
  supported.
- **A storage node that loses its pool** (for example after a disk swap) is a
  forced removal of the old voter ([architecture.md](architecture.md) §3), followed by a fresh token join.
  Khepri resyncs its data from the cluster on that join.

#### 2.10.3 ZFS: boot arguments, pool and reserved dataset

| Argument | Meaning |
| --- | --- |
| `kubex.vdevs=<SPEC>` | physical devices, in `zpool create` vdev syntax with commas for spaces, e.g. `mirror,nvme-SAMSUNG_…_S4EWNX0R,nvme-SAMSUNG_…_S4EWNX0T`. Absent = diskless node |
| `kubex.zpool=<NAME>` | pool name, default `kubex` |
| `kubex.zfs.create=1` | allows creating the pool if none is found |

`cluster_boot` handles the pool from BEAM, before Khepri starts. Doing it there
rather than in stage-1 keeps the ZFS modules and tools in the squashfs. The
steps:

1. **Load ZFS.** `modprobe spl spl_hostid=<H>`, then `modprobe zfs`, with `H`
   derived from the SMBIOS UUID: 32 bits, never 0. That is stable per machine,
   so the pool imports without `-f` across reboots, even after a power loss,
   while a pool moved to other hardware still needs a deliberate `-f`. A pool
   that was cleanly exported imports anywhere. A hostid of 0 is refused like
   any foreign one. All of this was checked on OpenZFS 2.3.9 ([phase 0](phase0.md)).
2. **Import.** `zpool import -N -o cachefile=none -d /dev <name>`:
   - `-N` because the rootfs is read-only, so nothing may automount;
   - `cachefile=none` because there is nowhere to keep one;
   - devices are found by scanning. Pool labels carry GUIDs, so device names
     don't matter for an import.
3. **Not found.** Create the pool only if `kubex.zfs.create=1` **and** every
   listed device has no partition table or filesystem signature (`wipefs -n`).
   Never use `-f`. Anything else refuses, with a console message, and the node
   drops to restricted mode. A typo in a boot argument must never wipe a disk.
4. **Imported, but with different vdevs than `kubex.vdevs`** (the pool was grown
   or repaired by hand): log it, continue.
5. **Reserved dataset `<pool>/kubex`.**
   - `refreservation=` (e.g. 4G) is space no other dataset can take, so
     workloads can never fill the cluster's own state. This is the SmartOS-style
     reserved volume.
   - `mountpoint=legacy`, mounted by kubex on `/kubex`, an empty directory
     shipped in the rootfs overlay.
   - `compression=lz4`, `atime=off`, and `sync=standard`. Ra fsyncs its WAL,
     so `sync=disabled` is never allowed.
   - Its children:

     | Dataset | Mounted on | Holds |
     | --- | --- | --- |
     | `<pool>/kubex/identity` | `/kubex/identity` | node key and certificate, CA chain, peer addresses. **In clear**: it is what fetches the key |
     | `<pool>/kubex/crypt` | — | encryption root, no data (§2.10.4) |
     | `<pool>/kubex/crypt/khepri` | `/kubex/khepri` | Ra's data directory: `khepri:start("/kubex/khepri")` |
     | `<pool>/kubex/crypt/log` | `/kubex/log` | logs and crash dumps, which can hold the key |

     `crypt` and its children exist only once there is a key: they are created
     at bootstrap or at a storage node's first join (§2.10.4). Before that, and
     in restricted mode, logs stay in RAM. For hand-booted QEMU with no cluster
     ([phase 6](phase6.md)), `kubex.zfs.testkey=<hex>` on the cmdline keys
     `crypt`, with a warning, like `kubex.token=` (§2.8.2). Bootstrap and join
     refuse a pool that was keyed this way.
6. **The rest of the pool** is left to workloads, later.

On a graceful leave or shutdown ([architecture.md](architecture.md) §3), kubex stops Khepri, then runs
`zpool export`.

**Device names.** Nerves runs no udev, so `/dev/disk/by-id/` does not exist
(checked in [phase 0](phase0.md)). `kubex.vdevs=` therefore takes by-id-*style*
names, and kubex resolves them itself from sysfs to `/dev/nvme0n1` and the like.
The sysfs sources:
`/sys/block/nvme*/device/{model,serial}` and `wwid` for NVMe,
`/sys/block/vd*/serial` for virtio-blk, and `/sys/block/sd*/device/{model,wwid}`
for SCSI and SATA. The values are space-padded. The alternative, adding eudev
to the system, is heavier for one lookup.

What the pool gives the boot flow:

- **Rejoin without a token** (§2.8.3): `/kubex/identity` holds the key and
  certificate, so the boot server stops serving the node a token (§2.7).
- **A local bootstrap guard** (§2.8.4): if `/kubex/khepri` already holds a store,
  `kubex.bootstrap=` is refused and the node restarts its member instead. A
  rebooted bootstrap node therefore can't create a second cluster.
- **A whole-cluster restart is recovery, not re-bootstrap.** Storage nodes
  import their pools, and Ra elects a leader once a majority is back. If every
  storage node went down, the first one back needs the exported ZFS key typed
  in (§2.10.4); partial restarts need nobody.

#### 2.10.4 Secrets at rest

The CA key and the token secrets sit on disk, on every voter. ZFS native
encryption closes that: `<pool>/kubex/crypt` is an encryption root
(`encryption=aes-256-gcm`, `keyformat=hex`, `keylocation=prompt`) holding
`khepri` and `log` (§2.10.3). Its key is **one key for the whole cluster**,
kept on no disk. A storage node fetches it over HTTPS from the first node,
authenticated by its own client certificate, and the operator exports it for
disaster recovery.

**Where the key lives:**

| Place | When |
| --- | --- |
| RAM of every unlocked storage node | from its `zfs load-key` until shutdown, held by one process (`Kubex.ZfsKey`), redacted in `format_status/1`, never logged |
| the operator's offline copy | after `Cluster.export_zfs_key/0` |
| nowhere else | not in Khepri, which it encrypts, nor the boot server, nor `/kubex/identity` |

**Lifecycle:**

1. **Created at bootstrap** (§2.8.4): `:crypto.strong_rand_bytes(32)`, then the
   encryption root is created with it. Khepri records only
   `[kubex, zfs_key]`: its SHA-256, `created_at`, `exported_at`.
2. **Fetched at join** (§2.8.3): once issuance has returned a certificate, a
   new storage node fetches the key and creates its encryption root with it.
3. **Fetched at every boot** of a storage node: import, mount
   `<pool>/kubex/identity`, fetch, `zfs load-key -L prompt`, mount the
   children, start Khepri. The key reaches `zfs` on a stdin pipe and never
   touches a file.
4. **Exported** with `Cluster.export_zfs_key/0` while the cluster runs, from
   any unlocked storage node: the 64 hex characters, plus an audit record
   and a warning in the log (without the key). `Cluster.status/1` warns as long
   as `exported_at` is unset. Do it right after bootstrap. Until then, a
   power loss on every storage node at once loses the cluster.

**The key endpoint.** `GET /zfs-key` on the join endpoint's HTTPS listener
(§2.9.4). Every member serves it once its own pool is unlocked. The listener
asks for a client certificate without requiring one (`verify: :verify_peer`,
`fail_if_no_peer_cert: false`), because `/join` callers don't have one yet.
`/zfs-key` serves the key only if all of these hold:

- the certificate is path-valid against the cluster CA and not in the CRL;
- its fingerprint is the one pinned for its CN in
  `[kubex, members, Id, certs, …]`. Issuance pins one certificate per UUID and
  revokes the previous one (§2.8.3), so each node has a unique client
  certificate, and that certificate is the credential;
- the member is a storage node, `registered` or `provisioned`, not `removed`.
  Diskless nodes have no pool and are always refused.

Every fetch is recorded like a join (§2.8.5), and attempts are rate-limited
per source address. A fetch for a UUID whose node is already connected over
distribution is the signal that a disk and its identity were copied.

**The client side** runs in BEAM, over `:ssl` with the identity's key and
certificate, and verifies the server against the cluster CA, never a system
store. It tries the `kubex.join=` host, the first node, then the peer
addresses that the cluster keeps in `/kubex/identity/peers`, in turn. This is
what makes the first node's own reboot work: it has no `kubex.join=`, and gets
the key from a peer. `keylocation=https://…` was the other option. It would fix
one URL into a dataset property, configure client certificates through
environment variables, and report failures as an exit code.

**Cold start.** After a power loss of every storage node, no member holds the
key, so nothing is unlocked and Khepri has no quorum. A storage node that gets
no answer from any source starts an **unlock page**, with the bootstrap web
server's rules (§2.8.4): HTTPS with a self-signed certificate whose fingerprint
is on the console, rate-limited attempts. The operator pastes the exported key.
The node checks it with `zfs load-key -n` and unlocks, and the others, which
kept retrying in the background, fetch the key from it and unlock in turn. Ra
elects a leader once a majority is back. The first node serves before any
quorum exists, so `/zfs-key` decides from the local projections, rebuilt as the
member replays its own log **(verify)**. If they only fill once a leader
exists, the fallback is a CA-signed list of pinned fingerprints kept next to
the identity.

**What this protects, and what it doesn't:**

- **A disk taken off the network** is unreadable: its identity alone yields
  nothing without a member to answer.
- **A disk plugged back in somewhere that reaches the cluster** gets the key
  with the identity stored in clear on it, until that member is removed. The
  forced removal (§2.8.3) revokes its certificate, and from then on its disks
  are dead. Sealing the identity key in a TPM (the `Kubex.Credentials` slot of
  §2.9.3) closes this.
- **Rotation** is `Cluster.rotate_zfs_key/0`: a new key, `zfs change-key` on
  every storage node (it rewraps the dataset keys, nothing is re-encrypted),
  and a new export. Older exports stop working.

**With the export, the pool opens without kubex.** On any Linux with OpenZFS:
`zpool import -N <pool>`, then
`zfs load-key -L prompt <pool>/kubex/crypt`. Raw sends (`zfs send -w`) of
`<pool>/kubex/crypt/khepri` stay encrypted off-cluster, and the same export
opens them.

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
- **Storage drivers** (`nvme`, `ahci`, `sd_mod`, `virtio_blk`, `virtio_scsi`)
  as modules, loaded before the import.
- **Licensing.** Shipping the CDDL ZFS module next to a GPL kernel in one image
  is the position Ubuntu takes, and it is still debated. Distributing kubex
  images needs that decision taken deliberately.

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
| [7](phase7.md) | plug into kubex |
| [8](phase8.md) | real hardware |
