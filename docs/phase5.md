# Phase 5 — hardened boot chain

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [ ] Custom iPXE build with HTTPS, embedded CA and `imgverify`.
- [ ] Per-node scripts selected by `${uuid}`.
- [ ] dnsmasq proxy-DHCP config.
- [ ] Harness, tier 2: `Sandbox` (namespace, bridge, dnsmasq, boot server, NTP, pcap) and the boot server's misbehave modes ([testing.md](testing.md) §4.2).

**Acceptance:** a tampered `rootfs.squashfs` refuses to boot.

---

Previous: [phase 4](phase4.md) · Next: [phase 6](phase6.md)
