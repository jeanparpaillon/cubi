# Phase 2 — the system fork

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] Fork as `kubex_system_x86_64` and apply the [§2.5](specs.md) kernel delta, OpenZFS included ([§2.10.5](specs.md)).
      `apps/kubex_system_x86_64`, a submodule (branch `kubex` on upstream v1.34.0). Checked: every §2.5 option in
      the built kernel, `nvme`/`ahci` autoloaded from their modaliases, `modprobe spl spl_hostid=…` + `zfs` (2.4.1),
      and a pool created, exported and imported in QEMU.
- [x] Build stage-1 in Buildroot (a `post-image.sh` producing `images/stage1.cpio.zst`).
      `package/kubex-stage1` (static busybox, `gen_init_cpio`) and `stage1/mkstage1.sh`, called from
      `post-createfs.sh`; also `images/stage1-dev.cpio.zst`. The e2e suite now boots the system's kernel and
      stage-1 by default (`Kubex.E2E.Artifacts`).
- [ ] Apply the `erlinit.config` and `boardid` changes from [§2.6](specs.md).

**Acceptance:** the phase-1 QEMU command boots with artifacts from the fork alone.

---

Previous: [phase 1](phase1.md) · Next: [phase 3](phase3.md)
