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

## Design

Specified in [specs.md §2.11](specs.md): the PKI (§2.11.1), signed boot images
(§2.11.2), the release archive (§2.11.3), its signature (§2.11.4), deploy over
ssh (§2.11.5), loading on the node (§2.11.6) and rollback through shoehorn
(§2.11.7). Its open points are in [questions.md](questions.md).

## Checklist

- [x] [specs.md](specs.md) §2.11 *Releases on a running node* ; README: "Deploy and upgrade" gains the in-place path; [questions.md](questions.md) gets the open points. The two **(verify)** points are in [phase 0](phase0.md).
- [x] `apps/kubex_pki`: CA and signer generation, CMS signing for the boot images (shells out to `openssl` on the host), manifest signing and verification with `:public_key`. Host and target; unit-tested on the host.
      `Kubex.Pki` (`gen_ca!/2`, `gen_signer!/2`, `sign/2`, `verify/5` = [§2.11.4](specs.md) steps 1–2), `Kubex.Pki.Cms` (`sign!/2`, `verify/3`). The archive checks (steps 3–5) belong to the node step.
- [x] `mix kubex.gen_ca` (in a host-only `apps/kubex_tools`, which user projects add as a `runtime: false` dependency, as `kubex_fw` does with `kubex_ipxe`).
      `--dir`, `--name`, `--signer-only`; prints the root's SHA-256 fingerprint. The default directory is `Kubex.Pki.dir/1`, shared with the tasks to come.
- [ ] Firmware: `/etc/kubex/ca.pem` copied into the rootfs from the configured CA (`config :kubex_fw, :ca_cert`); `mix firmware.ipxe --signer <dir>` writes the three `.sig` files and `base.json` ([§2.11.2](specs.md), [§2.11.3](specs.md)).
- [ ] Custom iPXE with `TRUST=` the CA and `imgverify` on the three images, and `mix firmware.ipxe --imgverify` rendering `boot.ipxe` with the `imgverify` lines. Pulled forward from [phase 5](phase5.md); the rest of phase 5 (HTTPS, per-node scripts, C stage-1) stays there.
- [ ] `mix kubex.release`: from a user's Mix project, build the release with the base image's OTP, drop the applications the base image already ships (`--base <ipxe dir>`, from its `base.json`), write the archive with `manifest.json` ([§2.11.3](specs.md)).
- [ ] `mix kubex.sign <archive>`: add `manifest.sig` and `signer.pem` in place.
- [ ] Node: `kubex_deploy` ssh subsystem → verify, check OTP and app conflicts, unpack to `/kubex/releases/<version>/`, then `Kubex.Deploy.install/1`: stop `current`, load and start the new one, wait the settle period, `current` → `previous` ([§2.11.5](specs.md), [§2.11.6](specs.md)). `<pool>/kubex/releases` on storage nodes, a tmpfs on `/kubex` on diskless ones.
- [ ] `mix kubex.deploy <node>`: stream the archive over ssh (`--port`, `--identity`), print the node's verdict, non-zero exit on refusal or rollback.
- [ ] `Kubex.Deploy.ShoehornHandler` and the rollback path; `state.json` with `current`, `previous` and `bad` ([§2.11.7](specs.md)).
- [ ] Boot: after shoehorn's `init` list, `Kubex.Deploy` re-verifies `current`, signer dates excepted, and starts it.
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

---

Previous: [phase 6](phase6.md) · Next: [phase 7](phase7.md)
