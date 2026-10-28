# Phase 2 — the system fork

Part of the cubi node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] Fork as `cubi_system_x86_64` and apply the [§2.5](specs.md) kernel delta, OpenZFS included ([§2.10.5](specs.md)).
      `apps/cubi_system_x86_64`, a submodule (branch `cubi` on upstream v1.34.0). Checked: every §2.5 option in
      the built kernel, `nvme`/`ahci` autoloaded from their modaliases, `modprobe spl spl_hostid=…` + `zfs` (2.4.1),
      and a pool created, exported and imported in QEMU.
- [x] Build stage-1 in Buildroot (a `post-image.sh` producing `images/stage1.cpio.zst`).
      `package/cubi-stage1` (static busybox, `gen_init_cpio`) and `stage1/mkstage1.sh`, called from
      `post-createfs.sh`; also `images/stage1-dev.cpio.zst`. The e2e suite now boots the system's kernel and
      stage-1 by default (`Cubi.E2E.Artifacts`).
- [x] Apply the `erlinit.config` and `boardid` changes from [§2.6](specs.md).
      In the system: no `-m` mounts, `-d /usr/bin/cubi-boardid` and `-n %s`; `nerves_runtime`'s
      `:boardid_path` points at the same script (`config/target.exs`). Tested by
      `apps/cubi_e2e/test/phase2_system_fork_test.exs`, which also automates the step 1 checks.

**Acceptance:** the phase-1 QEMU command boots with artifacts from the fork alone.

---

Previous: [phase 1](phase1.md) · Next: [phase 3](phase3.md)
