# Milestone 1 — signed releases on standalone nodes

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

A first usable kubex that needs **no Erlang distribution**: no join, no Khepri, no
cluster ([phase 7](phase7.md) stays out). Each node is standalone. The operator
owns a root CA; the boot images are signed with it, and so is every application
release pushed onto a running node. The base image is still upgraded by
rebooting; applications are deployed without a reboot and roll back by
themselves when they fail.

The procedure mimics Nerves firmware signing and `mix upload`:

| Nerves | kubex |
| --- | --- |
| `mix firmware.gen.key` → `fwup-key.{pub,priv}` (ed25519) | `mix kubex.gen_ca` → root CA + a signer certificate issued by it |
| public keys compiled into the firmware (`fwup --public-key`) | CA certificate baked into the rootfs, `/etc/kubex/ca.pem` |
| `mix firmware.sign` → signature added inside the `.fw` zip | `mix kubex.sign` → signature added inside the release archive |
| `mix upload <host>` → `ssh_subsystem_fwup` | `mix kubex.deploy <node>` → a `kubex_deploy` ssh subsystem |
| `Nerves.Runtime.validate_firmware/0`, revert to the other slot | shoehorn handler, revert to the previous release |

## Design decisions

These need to land in [specs.md](specs.md) as a new §2.11 before the code.

- **One PKI, offline.** `mix kubex.gen_ca` writes a root CA key and certificate,
  plus a **signer** key and certificate issued by it with the `codeSigning`
  extended key usage, which iPXE requires. Default directory `~/.kubex/pki/`,
  overridden by `--dir` or `KUBEX_PKI_DIR`; refuses to overwrite. The CA key is
  only needed again to issue a new signer ([security.md](security.md) §2: the
  image signing key stays with the operator). Built with the `x509` package, as
  [§2.9.3](specs.md) already plans. RSA-3072 rather than ECDSA, because iPXE
  `imgverify` must accept it **(verify)**.
- **Boot images: detached CMS signatures.** `mix firmware.ipxe` writes
  `vmlinuz.sig`, `stage1.cpio.zst.sig` and `rootfs.squashfs.sig` (`openssl cms
  -sign -binary -noattr -outform DER`, the format `imgverify` reads), and lists
  them in `SHA256SUMS`. It refuses to run without a signer unless `MIX_ENV=dev`.
- **The CA is in the image.** The firmware build copies the CA certificate (not
  the signer, not a key) into the rootfs as `/etc/kubex/ca.pem`. It is what the
  node verifies releases against, so a rootfs signed by that CA can only accept
  releases signed by the same CA.
- **Releases are loaded into the node's BEAM**, not run as a second BEAM. That
  is what lets shoehorn watch them. Consequences:
  - A kubex release is the set of OTP applications the base image does not
    already have: their `ebin/` and `priv/`, plus a `manifest.json` (name,
    version, applications with versions and SHA-256 of each file, the OTP and
    ERTS versions it was built for, the start order).
  - It is built against the base image's ERTS and OTP. The node refuses a
    release built for another OTP major.
  - An application present in both the release and the base image must have the
    same version; it is then skipped. A different version is refused at deploy,
    never loaded over the base image's copy.
- **Release signature.** `mix kubex.sign` signs `manifest.json` (which hashes
  every file) with the signer key, and adds `manifest.sig` and `signer.pem` to
  the archive. The node checks, with `:public_key` only: `signer.pem` is
  path-valid against `/etc/kubex/ca.pem` with `codeSigning`, the signature over
  the manifest is good, and every file matches its hash. No OpenSSL on the node.
- **Transport: ssh, like `mix upload`.** `nerves_ssh` already runs on the node
  and already decides who may log in. A `kubex_deploy` subsystem receives the
  archive; the signature, not the ssh session, decides whether it is installed.
  Erlang distribution stays off.
- **Where releases live.** `/kubex/releases/<name>/<version>/` on storage nodes
  (a `<pool>/kubex/releases` dataset next to the ones [phase 6](phase6.md)
  creates), a tmpfs on diskless nodes, so they lose deployed releases on reboot
  and run only the base image. Two pointers per release name: `current` and
  `previous`, plus a `bad` list. The signature is checked again at every boot
  before a release is loaded.
- **Rollback is a shoehorn handler.** Release applications are started
  `:temporary`, so their death never takes the node down; shoehorn's logger
  filter reports the exit to `Kubex.Deploy.ShoehornHandler`
  (`config :shoehorn, handler: …`). The handler returns `{:continue, state}`
  for every application (the base image keeps running) and, when the exited app
  belongs to `current`, casts a rollback to `Kubex.Deploy`: stop the release's
  remaining apps, purge their modules, remove their code paths, add `current` to
  `bad`, swap `previous` in, start it. With no `previous`, the release is just
  stopped. A `bad` version is never started again, at boot or by a re-deploy of
  the same archive; a new version clears nothing.

## Checklist

- [ ] [specs.md](specs.md) §2.11 *Releases on a running node* from the decisions above; README: "Deploy and upgrade" gains the in-place path; [questions.md](questions.md) gets the open points below.
- [ ] `apps/kubex_pki`: CA and signer generation, CMS signing for the boot images (shells out to `openssl` on the host), manifest signing and verification with `:public_key`. Host and target; unit-tested on the host.
- [ ] `mix kubex.gen_ca` (in a host-only `apps/kubex_tools`, which user projects add as a `runtime: false` dependency, as `kubex_fw` does with `kubex_ipxe`).
- [ ] Firmware: `/etc/kubex/ca.pem` copied into the rootfs from the configured CA (`config :kubex_fw, :ca_cert`); `mix firmware.ipxe --signer <dir>` writes the three `.sig` files.
- [ ] Custom iPXE with `TRUST=` the CA and `imgverify` on the three images, and `boot.ipxe` rendered with the `imgverify` lines. Pulled forward from [phase 5](phase5.md); the rest of phase 5 (HTTPS, per-node scripts, C stage-1) stays there.
- [ ] `mix kubex.release`: from a user's Mix project, build the release with the base image's OTP, drop the applications the base image already ships (read from the `.fw` or its manifest), write the archive with `manifest.json`.
- [ ] `mix kubex.sign <archive>`: add `manifest.sig` and `signer.pem` in place.
- [ ] Node: `kubex_deploy` ssh subsystem → verify, check OTP and app conflicts, unpack to `/kubex/releases/<name>/<version>/`, then `Kubex.Deploy.install/1`: stop `current`, load and start the new one, `current` → `previous`.
- [ ] `mix kubex.deploy <node>`: stream the archive over ssh (`--port`, `--identity`), print the node's verdict, non-zero exit on refusal or rollback.
- [ ] `Kubex.Deploy.ShoehornHandler` and the rollback path; `bad` list persisted next to the pointers.
- [ ] Boot: after shoehorn's `init` list, `Kubex.Deploy` re-verifies and starts every `current` release.
- [ ] Harness: `mix kubex.e2e.key` also generates a test CA and signer (gitignored); fixtures `hello` v1, v2 (good) and v3 (crashes in `start/2`) and v4 (crashes 5 s after start), built by the tests with `mix kubex.release`.

**Acceptance:**

- `mix kubex.gen_ca` twice into the same directory fails the second time and leaves the first CA intact.
- Every `.sig` in the served directory verifies with `openssl cms -verify` against the CA, and fails against another CA.
- With the custom iPXE, a node boots the signed directory, and a one-byte change to `rootfs.squashfs` makes it refuse to boot.
- `mix kubex.deploy` of signed `hello` v1 to a QEMU node returns 0 and `hello` answers, with no Erlang distribution running on the node (`:erlang.is_alive()` is false).
- An unsigned archive, one signed by another CA, one with a file changed after signing, and one built for another OTP major are each refused; the node still runs v1.
- A release that ships a base-image application at another version is refused.
- Deploying v2 replaces v1; the node never runs two versions of `hello` at once.
- Deploying v3 (crashes on start) leaves v2 running within 10 s, `mix kubex.deploy` exits non-zero, and re-deploying v3 is refused as bad.
- v4 (crashes after start) is rolled back to v2 the same way, and the base image's applications never restart.
- A storage node rebooted after deploying v2 runs v2 again; a diskless node rebooted runs only the base image.

## Open questions

- **Rollback window.** As written, *any* exit of a `current` app rolls back, even
  days later. Nerves instead treats a firmware as good once validated. Option: a
  release is validated after N seconds up (or by an explicit call), and a later
  exit restarts the same version instead of rolling back.
- **More than one release per node?** The pointers are per release name, which
  allows several; their applications then must not conflict with each other
  either. Simplest is one release per node for this milestone.
- **ssh trust.** Who may deploy is whoever has an authorized ssh key. Fine for
  M1; with phase 7 it could become a cluster-CA client certificate.
- **CMS without OpenSSL on the build host?** `:public_key` can't write CMS, so
  `mix firmware.ipxe` gains a host dependency on `openssl`.

---

Previous: [phase 6](phase6.md) · Next: [phase 7](phase7.md)
