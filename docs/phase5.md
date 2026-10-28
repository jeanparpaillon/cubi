# Phase 5 — hardened boot chain

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [ ] Custom iPXE build with HTTPS, embedded CA and `imgverify`. The embedded CA and `imgverify` are done in [milestone 1](milestone1.md) (`mix kubex.ipxe`); HTTPS remains, with the boot server's certificate under the same root ([§2.11.2](specs.md)).
- [ ] Per-node scripts selected by `${uuid}`.
- [ ] dnsmasq proxy-DHCP config.
- [ ] Stage-1 as a small static C program, and no busybox in the initramfs ([security.md](security.md) §5).
- [ ] Harness, tier 2: `Sandbox` (namespace, bridge, dnsmasq, boot server, NTP, pcap) and the boot server's misbehave modes ([testing.md](testing.md) §4.2).

**Acceptance:**

- A tampered `rootfs.squashfs` refuses to boot.
- `rdinit=/bin/busybox sh` on the cmdline does not give a shell.

---

Previous: [phase 4](phase4.md) · Next: [phase 6](phase6.md)
