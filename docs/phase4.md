# Phase 4 — network boot in QEMU

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md).

- [ ] `-netdev user,id=n0,tftp=…,bootfile=boot.ipxe` for the simplest loop, then over HTTP.
- [ ] Repeat under OVMF with `ipxe.efi`.

**Acceptance:** a cold QEMU VM with no disk boots to IEx, for both BIOS and UEFI.

---

Previous: [phase 3](phase3.md) · Next: [phase 5](phase5.md)
