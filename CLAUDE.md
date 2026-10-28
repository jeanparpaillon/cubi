# kubex

Runs BEAM releases on a cluster without Kubernetes: nodes network-boot into BEAM,
join with a token, and keep membership in Khepri on ZFS.

**Status: phases 0–4 done; phase 6 step 1 done (phase 5 not started).** Code so far: the test harness, the firmware app and the forked Nerves system.

An umbrella project: `config/`, `deps/`, `_build/` and `mix.lock` are shared at
the root, and the apps live in `apps/`.

| App | What |
| --- | --- |
| `apps/kubex_fw` | The Nerves firmware app, on `kubex_system_x86_64`. Run `MIX_TARGET=x86_64 mix firmware` from this directory; the first build compiles the system (Buildroot, about an hour), cached in `~/.nerves/artifacts` afterwards. `MIX_ENV=e2e` trusts only the harness key. Node code lives under `lib/kubex/` (`Kubex.Cmdline`, `Kubex.Storage.*`); `mix test` here runs its host unit tests |
| `apps/kubex_system_x86_64` | The Nerves system, a **git submodule**: branch `kubex` = upstream `nerves_system_x86_64` v1.34.0 plus the kubex delta (kernel options, `package/kubex-zfs`, the stage-1 initramfs in `stage1/` + `package/kubex-stage1`). Remote `upstream` is the vanilla repo; no `origin` yet. Commit inside it, then stage the gitlink here. See its README |
| `apps/kubex_ipxe` | `mix firmware.ipxe` ([docs/specs.md](docs/specs.md) §2.3): runs `mix firmware`, then writes the served directory `_build/<target>_<env>/ipxe/`. A build-time dependency of `kubex_fw`, never in a release |
| `apps/kubex_e2e` | The host-only QEMU harness ([docs/testing.md](docs/testing.md) §2). Never a firmware dependency, and it has no `:nerves` dependency, so the shared config skips `nerves_bootstrap` for it. `mix test` runs unit tests; `mix test --only e2e:tier1` boots VMs from the served directory (run `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware.ipxe` in `apps/kubex_fw` first; `KUBEX_E2E_KERNEL` overrides the kernel) |

Run `mix kubex.e2e.key` in `apps/kubex_e2e` before building e2e firmware, and
`mix kubex.e2e.ipxe` once before the UEFI network-boot tests (it fetches
Ubuntu's `ipxe.efi`; `KUBEX_E2E_IPXE_EFI` overrides). Both are gitignored. Building the firmware needs the `nerves_bootstrap` archive,
and host builds of `kubex_fw` (a root `mix test`, for example) need
`libmnl-dev` for `nerves_uevent`. Build the system with
`BR2_PRIMARY_SITE=https://sources.buildroot.net` in the environment: some
upstream source URLs are dead (`libaio`) and the Nerves mirror does not carry
them; Buildroot still checks every hash.

## Entry points

Start with [README.md](README.md): what kubex is, how boot/join/state/upgrade work,
and the roadmap. Then [docs/](docs/):

| File | Contents |
| --- | --- |
| [docs/specs.md](docs/specs.md) | The node boot specification — the reference every other doc cites by `§` number |
| [docs/testing.md](docs/testing.md) | Test layers and the `kubex_e2e` QEMU harness |
| [docs/questions.md](docs/questions.md) | Open decisions, not yet taken |
| [docs/phase0.md](docs/phase0.md) … [docs/phase8.md](docs/phase8.md) | The work plan, one phase per file: checklist plus acceptance criteria |

## Editing the docs

- Cross-references into the spec are written `[§2.10.3](specs.md)`. If you renumber
  a section in `specs.md`, update every reference to it in the phase files,
  `questions.md` and `testing.md`.
- **(verify)** marks an assumption to be confirmed in phase 0. Adding one means
  adding the matching check to [docs/phase0.md](docs/phase0.md).
- Every phase file has the same frame: the `Part of the kubex node boot plan…`
  line under the title, a `- [ ]` checklist, an **Acceptance:** section, and the
  `Previous: … · Next: …` footer. Keep it when adding or splitting phases.
- Each acceptance bullet is meant to become an automated test (see
  [docs/testing.md](docs/testing.md)), so write them as observable outcomes.
- The roadmap table and the Documentation list in [README.md](README.md) must stay
  in sync with the files in `docs/`.
