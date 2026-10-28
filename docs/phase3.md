# Phase 3 — `mix firmware.ipxe`

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] Extract from the `.fw`, copy stage-1, render `boot.ipxe`, seed the InMemory KV from the release metadata.
      `apps/kubex_ipxe` (`Kubex.Ipxe`, `mix firmware.ipxe`); the KV travels as `/firmware.kv` appended to the
      served squashfs and is loaded by `config/runtime.exs` ([§2.3](specs.md), [§2.6](specs.md)).
- [x] Output in `_build/<target>_<env>/ipxe/`: `vmlinuz`, `stage1.cpio.zst`, `rootfs.squashfs`, `boot.ipxe`,
      `SHA256SUMS`. The e2e tests boot from this directory (`Kubex.E2E.Artifacts`).

**Acceptance:** one command turns a clean checkout into a served directory.

Validated on 2026-10-28 with `MIX_TARGET=x86_64 MIX_ENV=e2e mix firmware.ipxe` in `apps/kubex_fw`, from no
`_build/x86_64_e2e` at all, by `apps/kubex_e2e/test/phase3_firmware_ipxe_test.exs`. The system artifact was
cached: on a truly fresh machine the same command first builds `kubex_system_x86_64` (about an hour, with
`BR2_PRIMARY_SITE` set, see `CLAUDE.md`).

---

Previous: [phase 2](phase2.md) · Next: [phase 4](phase4.md)
