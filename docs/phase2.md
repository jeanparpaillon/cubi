# Phase 2 — the system fork

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [ ] Fork as `kubex_system_x86_64` and apply the [§2.5](specs.md) kernel delta, OpenZFS included ([§2.10.5](specs.md)).
- [ ] Build stage-1 in Buildroot (a `post-image.sh` producing `images/stage1.cpio.zst`).
- [ ] Apply the `erlinit.config` and `boardid` changes from [§2.6](specs.md).

**Acceptance:** the phase-1 QEMU command boots with artifacts from the fork alone.

---

Previous: [phase 1](phase1.md) · Next: [phase 3](phase3.md)
