# cubi

Runs BEAM releases on a cluster without Kubernetes: nodes network-boot into BEAM,
join with a token, and keep membership in Khepri on ZFS.

**Status: phases 0–4 done; phase 6 steps 1–3 done (phase 5 not started); [milestone 1](docs/milestone1.md) done: signed images, and signed releases deployed onto running nodes.** Code so far: the test harness, the firmware app, the forked Nerves system, the PKI and the operator's tasks.

An umbrella project: `config/`, `deps/`, `_build/` and `mix.lock` are shared at
the root, and the apps live in `apps/`.

| App | What |
| --- | --- |
| `apps/cubi_fw` | The Nerves firmware app, on `cubi_system_x86_64`. Run `MIX_TARGET=x86_64 mix firmware` from this directory; the first build compiles the system (Buildroot, about an hour), cached in `~/.nerves/artifacts` afterwards. `MIX_ENV=e2e` trusts only the harness key. Node code lives under `lib/cubi/` (`Cubi.Cmdline`, `Cubi.Storage.*`, `Cubi.Deploy.*`); `mix test` here runs its host unit tests, which load and start fixture applications in the test BEAM (`test/support/deploy_fixtures.ex`) |
| `apps/cubi_system_x86_64` | The Nerves system, a **git submodule**: branch `cubi` = upstream `nerves_system_x86_64` v1.34.0 plus the cubi delta (kernel options, `package/cubi-zfs`, the stage-1 initramfs in `stage1/` + `package/cubi-stage1`). Remote `upstream` is the vanilla repo; no `origin` yet. Commit inside it, then stage the gitlink here. See its README |
| `apps/cubi_ipxe` | `mix firmware.ipxe` ([docs/specs.md](docs/specs.md) §2.3): runs `mix firmware`, then writes the served directory `_build/<target>_<env>/ipxe/`. A build-time dependency of `cubi_fw`, never in a release |
| `apps/cubi_pki` | The operator's PKI ([docs/specs.md](docs/specs.md) §2.11.1, §2.11.4): `Cubi.Pki` generates the root CA and signer, signs and verifies with `:public_key` only, so it runs on the node too; `Cubi.Pki.Archive` reads, writes, signs and verifies release archives for both sides; `Cubi.Pki.Cms` writes the boot images' CMS signatures with `openssl`, host-only. No `:nerves` dependency, so the shared config skips `nerves_bootstrap` for it, like `cubi_e2e` |
| `apps/cubi_tools` | The operator's Mix tasks ([docs/specs.md](docs/specs.md) §2.11): `mix cubi.gen_ca`, `mix cubi.ipxe`, `mix cubi.release`, `mix cubi.sign`, `mix cubi.deploy`; and the `Cubi.Provider` behaviour for cloud instances (§2.12.3), whose conformance suite `Cubi.Provider.Case` and file-backed `Cubi.Provider.Fake` are in `test/support`. Host-only, a `runtime: false` dependency of user projects, never in a release; skipped by `nerves_bootstrap` like `cubi_pki` |
| `apps/cubi_e2e` | The host-only QEMU harness ([docs/testing.md](docs/testing.md) §2). Never a firmware dependency, and it has no `:nerves` dependency, so the shared config skips `nerves_bootstrap` for it. `mix test` runs unit tests; `mix test --only e2e:tier1` boots VMs from the served directory (run `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware.ipxe` in `apps/cubi_fw` first; `CUBI_E2E_KERNEL` overrides the kernel). `fixtures/hello` is a standalone release project the milestone 1 tests build in several versions (`Cubi.E2E.Hello`) |

`examples/` holds standalone Mix projects (own `deps/` and `_build/`, outside the
umbrella), meant as releases to deploy onto a node ([docs/specs.md](docs/specs.md)
§2.11): `examples/cubi_hello` is a one-page Bandit app that prints its version.

Run `mix cubi.e2e.key` in `apps/cubi_e2e` before building e2e firmware (it
creates the harness ssh key and the test CA that signs e2e images), and
`mix cubi.e2e.ipxe` once before the network-boot tests (it fetches
Ubuntu's `ipxe.efi`, `CUBI_E2E_IPXE_EFI` overrides; and builds cubi's own
iPXE trusting the test CA into `priv/ipxe/trusted/`, with `mix cubi.ipxe`,
`CUBI_E2E_IPXE_TRUSTED` overrides). Both are gitignored. Building the firmware needs the `nerves_bootstrap` archive,
and host builds of `cubi_fw` (a root `mix test`, for example) need
`libmnl-dev` for `nerves_uevent`. Build the system with
`BR2_PRIMARY_SITE=https://sources.buildroot.net` in the environment: some
upstream source URLs are dead (`libaio`) and the Nerves mirror does not carry
them; Buildroot still checks every hash.

## Entry points

Start with [README.md](README.md): what cubi is, how boot/join/state/upgrade work,
and the roadmap. Then [docs/](docs/):

| File | Contents |
| --- | --- |
| [docs/specs.md](docs/specs.md) | The node boot specification — the reference every other doc cites by `§` number |
| [docs/testing.md](docs/testing.md) | Test layers and the `cubi_e2e` QEMU harness |
| [docs/questions.md](docs/questions.md) | Open decisions, not yet taken |
| [docs/phase0.md](docs/phase0.md) … [docs/phase8.md](docs/phase8.md) | The work plan, one phase per file: checklist plus acceptance criteria |

## Editing the docs

- Cross-references into the spec are written `[§2.10.3](specs.md)`. If you renumber
  a section in `specs.md`, update every reference to it in the phase files,
  `questions.md` and `testing.md`.
- **(verify)** marks an assumption to be confirmed in phase 0. Adding one means
  adding the matching check to [docs/phase0.md](docs/phase0.md).
- Every phase file has the same frame: the `Part of the cubi node boot plan…`
  line under the title, a `- [ ]` checklist, an **Acceptance:** section, and the
  `Previous: … · Next: …` footer. Keep it when adding or splitting phases.
- Each acceptance bullet is meant to become an automated test (see
  [docs/testing.md](docs/testing.md)), so write them as observable outcomes.
- The roadmap table and the Documentation list in [README.md](README.md) must stay
  in sync with the files in `docs/`.
