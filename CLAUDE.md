# kubex

Runs BEAM releases on a cluster without Kubernetes: nodes network-boot into BEAM,
join with a token, and keep membership in Khepri on ZFS.

**Status: phase 1.** Code so far: the test harness and a stock firmware app.

An umbrella project: `config/`, `deps/`, `_build/` and `mix.lock` are shared at
the root, and the apps live in `apps/`.

| App | What |
| --- | --- |
| `apps/kubex_fw` | The Nerves firmware app (`nerves_system_x86_64` 1.34.0 for now). Run `MIX_TARGET=x86_64 mix firmware` from this directory. `MIX_ENV=e2e` trusts only the harness key |
| `apps/kubex_e2e` | The host-only QEMU harness ([docs/testing.md](docs/testing.md) §2). Never a firmware dependency, and it has no `:nerves` dependency, so the shared config skips `nerves_bootstrap` for it. `mix test` runs unit tests; `mix test --only e2e:tier1` boots VMs (set `KUBEX_E2E_KERNEL`, and build the e2e firmware first) |
| `stage1/` | The stage-1 initramfs ([docs/specs.md](docs/specs.md) §2.4): the busybox `init` script and `build.exs`, run with `elixir stage1/build.exs`. Not an app: phase 2 moves it into the system fork |

Run `mix kubex.e2e.key` in `apps/kubex_e2e` before building e2e firmware. The
key is gitignored. Building the firmware needs the `nerves_bootstrap` archive,
and host builds of `kubex_fw` (a root `mix test`, for example) need
`libmnl-dev` for `nerves_uevent`.

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
