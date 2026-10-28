# Milestone 1 — signed releases on standalone nodes

Part of the cubi node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

A first usable cubi that needs **no Erlang distribution**: no join, no Khepri, no
cluster ([phase 7](phase7.md) stays out). Each node is standalone. The operator
owns a root CA; the boot images are signed with it, and so is every application
release pushed onto a running node. The base image is still upgraded by
rebooting; applications are deployed without a reboot and roll back by
themselves when they fail.

The procedure mimics Nerves firmware signing and `mix upload`:

| Nerves | cubi |
| --- | --- |
| `mix firmware.gen.key` → `fwup-key.{pub,priv}` (ed25519) | `mix cubi.gen_ca` → root CA + a signer certificate issued by it |
| public keys compiled into the firmware (`fwup --public-key`) | CA certificate baked into the rootfs, `/etc/cubi/ca.pem` |
| `mix firmware.sign` → signature added inside the `.fw` zip | `mix cubi.sign` → signature added inside the release archive |
| `mix upload <host>` → `ssh_subsystem_fwup` | `mix cubi.deploy <node>` → a `cubi_deploy` ssh subsystem |
| `Nerves.Runtime.validate_firmware/0`, revert to the other slot | shoehorn handler, revert to the previous release |

## Design

Specified in [specs.md §2.11](specs.md): the PKI (§2.11.1), signed boot images
(§2.11.2), the release archive (§2.11.3), its signature (§2.11.4), deploy over
ssh (§2.11.5), loading on the node (§2.11.6) and rollback through shoehorn
(§2.11.7). Its open points are in [questions.md](questions.md).

## Checklist

- [x] [specs.md](specs.md) §2.11 *Releases on a running node* ; README: "Deploy and upgrade" gains the in-place path; [questions.md](questions.md) gets the open points. The two **(verify)** points are in [phase 0](phase0.md).
- [x] `apps/cubi_pki`: CA and signer generation, CMS signing for the boot images (shells out to `openssl` on the host), manifest signing and verification with `:public_key`. Host and target; unit-tested on the host.
      `Cubi.Pki` (`gen_ca!/2`, `gen_signer!/2`, `sign/2`, `verify/5` = [§2.11.4](specs.md) steps 1–2), `Cubi.Pki.Cms` (`sign!/2`, `verify/3`). The archive checks (steps 3–5) belong to the node step.
- [x] `mix cubi.gen_ca` (in a host-only `apps/cubi_tools`, which user projects add as a `runtime: false` dependency, as `cubi_fw` does with `cubi_ipxe`).
      `--dir`, `--name`, `--signer-only`; prints the root's SHA-256 fingerprint. The default directory is `Cubi.Pki.dir/1`, shared with the tasks to come.
- [x] Firmware: `/etc/cubi/ca.pem` copied into the rootfs from the configured CA (`config :cubi_fw, :ca_cert`); `mix firmware.ipxe --signer <dir>` writes the three `.sig` files and `base.json` ([§2.11.2](specs.md), [§2.11.3](specs.md)).
      Added to the served rootfs by `Cubi.Ipxe`, like `/etc/firmware.kv`. `mix cubi.e2e.key` now also creates the test CA (pulled forward from the harness step), and `MIX_ENV=e2e` builds are signed by it; `apps/cubi_e2e/test/phase3_firmware_ipxe_test.exs` checks the signatures, the CA in the rootfs and `base.json`.
- [x] Custom iPXE with `TRUST=` the CA and `imgverify` on the three images, and `mix firmware.ipxe --imgverify` rendering `boot.ipxe` with the `imgverify` lines. Pulled forward from [phase 5](phase5.md); the rest of phase 5 (HTTPS, per-node scripts, C stage-1) stays there.
      Written: `mix cubi.ipxe` (`Cubi.Tools.Ipxe`), `--imgverify`, the harness's `ipxe: :trusted` VMs, built by `mix cubi.e2e.ipxe`, and `apps/cubi_e2e/test/milestone1_imgverify_test.exs`.
      Validated on 2026-10-28 with iPXE 2.0.0: BIOS and UEFI boot the signed directory; a one-byte change to the rootfs, another CA's signatures and a stock iPXE are all refused. The build needs `CERT=` the root besides `TRUST=` ([§2.11.2](specs.md)).
- [x] `mix cubi.release`: from a user's Mix project, build the release with the base image's OTP, drop the applications the base image already ships (`--base <ipxe dir>`, from its `base.json`), write the archive with `manifest.json` ([§2.11.3](specs.md)).
      `Cubi.Tools.Release`. OTP's applications are never shipped (the host's patch version differs from the system's: 29.0.3 against 29.0.2 here); the image's others become the manifest's `requires`. Only the shipped applications' config is kept. Checked on `examples/cubi_hello` against the e2e image: ships Bandit, Plug, `eex` and their deps, requires `elixir`, `logger`, `iex`.
- [x] `mix cubi.sign <archive>`: add `manifest.sig` and `signer.pem` in place.
      `Cubi.Pki.Archive` in `apps/cubi_pki` holds the archive format for both sides: read (regular files with safe paths only), write, sign, and verify = [§2.11.4](specs.md) steps 1–3, which the node step reuses. Checked on `examples/cubi_hello`.
- [x] Node: `cubi_deploy` ssh subsystem → verify, check OTP and app conflicts, unpack to `/cubi/releases/<version>/`, then `Cubi.Deploy.install/1`: stop `current`, load and start the new one, wait the settle period, `current` → `previous` ([§2.11.5](specs.md), [§2.11.6](specs.md)). `<pool>/cubi/releases` on storage nodes, a tmpfs on `/cubi` on diskless ones.
      `Cubi.Deploy` (+ `.Store`, `.Check`, `.Loader`, `.Subsystem`) in `apps/cubi_fw`, host-tested with fixture apps compiled and signed in the test and a real `:ssh` daemon; `apps/cubi_e2e/test/milestone1_deploy_node_test.exs` deploys a signed `examples/cubi_hello` to a diskless QEMU node over the subsystem. A failed install already rolls back and marks the version bad; what remains for the rollback step is the shoehorn handler, for failures after the settle period. The subsystem is registered through `config :nerves_ssh, subsystems:`, not at runtime ([§2.11.5](specs.md)).
- [ ] `mix cubi.deploy <node>`: stream the archive over ssh (`--port`, `--identity`), print the node's verdict, non-zero exit on refusal or rollback.
- [x] `Cubi.Deploy.ShoehornHandler` and the rollback path; `state.json` with `current`, `previous` and `bad` ([§2.11.7](specs.md)).
      `Cubi.Deploy.ShoehornHandler` only casts exits to `Cubi.Deploy` (a raise in a shoehorn handler halts the node); `Cubi.Deploy` rolls back when the exit concerns its release and the release is no longer all running, so a stale exit after a rollback during install is ignored. Host-tested, and on a QEMU node: a deployed `cubi_hello` killed after it settled is rolled back.
- [ ] Boot: after shoehorn's `init` list, `Cubi.Deploy` re-verifies `current`, signer dates excepted, and starts it.
- [ ] Harness: ~~`mix cubi.e2e.key` also generates a test CA and signer (gitignored)~~ (done in step 4); fixtures `hello` v1, v2 (good) and v3 (crashes in `start/2`) and v4 (crashes 5 s after start), built by the tests with `mix cubi.release`.

**Acceptance:**

- `mix cubi.gen_ca` twice into the same directory fails the second time and leaves the first CA intact.
- Every `.sig` in the served directory verifies with `openssl cms -verify` against the CA, and fails against another CA.
- With the custom iPXE, a node boots the signed directory, and a one-byte change to `rootfs.squashfs` makes it refuse to boot.
- `mix cubi.deploy` of signed `hello` v1 to a QEMU node returns 0 and `hello` answers, with no Erlang distribution running on the node (`:erlang.is_alive()` is false).
- An unsigned archive, one signed by another CA, one with a file changed after signing, and one built for another OTP major are each refused; the node still runs v1.
- A release that ships a base-image application at another version is refused.
- Deploying v2 replaces v1; the node never runs two versions of `hello` at once.
- Deploying v3 (crashes on start) leaves v2 running within 10 s, `mix cubi.deploy` exits non-zero, and re-deploying v3 is refused as bad.
- v4 (crashes after start) is rolled back to v2 the same way, and the base image's applications never restart.
- A storage node rebooted after deploying v2 runs v2 again; a diskless node rebooted runs only the base image.

---

Previous: [phase 6](phase6.md) · Next: [milestone 2](milestone2.md)
