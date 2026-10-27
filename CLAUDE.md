# kubex

Runs BEAM releases on a cluster without Kubernetes: nodes network-boot into BEAM,
join with a token, and keep membership in Khepri on ZFS.

**Status: design stage.** There is no code yet. The repository is documentation only.

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
