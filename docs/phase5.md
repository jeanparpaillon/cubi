# Phase 5 — hardened boot chain

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md).

- [ ] Custom iPXE build with HTTPS, embedded CA and `imgverify`.
- [ ] Per-node scripts selected by `${uuid}`.
- [ ] dnsmasq proxy-DHCP config.

**Acceptance:** a tampered `rootfs.squashfs` refuses to boot.

---

Previous: [phase 4](phase4.md) · Next: [phase 6](phase6.md)
