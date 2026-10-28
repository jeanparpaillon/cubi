# Phase 3 — `mix firmware.ipxe`

Part of the cubi node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] Extract from the `.fw`, copy stage-1, render `boot.ipxe`, seed the InMemory KV from the release metadata.
      `apps/cubi_ipxe` (`Cubi.Ipxe`, `mix firmware.ipxe`); the served squashfs is rebuilt without `/boot`
      (the kernel is served as `vmlinuz`; 5.7 MB less per node) and with `/etc/firmware.kv`, which
      `config/runtime.exs` loads ([§2.3](specs.md), [§2.6](specs.md)).
- [x] Output in `_build/<target>_<env>/ipxe/`: `vmlinuz`, `stage1.cpio.zst`, `rootfs.squashfs`, `boot.ipxe`,
      `SHA256SUMS`. The e2e tests boot from this directory (`Cubi.E2E.Artifacts`).

**Acceptance:** one command turns a clean checkout into a served directory.

Validated on 2026-10-28 with `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware.ipxe` in `apps/cubi_fw`, from no
`_build/x86_64_e2e` at all, by `apps/cubi_e2e/test/phase3_firmware_ipxe_test.exs`. The system artifact was
cached: on a truly fresh machine the same command first builds `cubi_system_x86_64` (about an hour, with
`BR2_PRIMARY_SITE` set, see `CLAUDE.md`).

---

Previous: [phase 2](phase2.md) · Next: [phase 4](phase4.md)
