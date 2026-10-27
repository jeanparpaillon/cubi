# Phase 1 — boot by hand, no iPXE

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md).

- [ ] Write stage-1 (busybox script) and build its cpio by hand.
- [ ] Extract `vmlinuz` and `rootfs.squashfs` from a stock `.fw`.
- [ ] `qemu-system-x86_64 -kernel vmlinuz -initrd stage1.cpio.zst,rootfs.cpio -append console=ttyS0 -nographic`
      reaches the IEx prompt.

**Acceptance:** `Nerves.Runtime.firmware_valid?/0` is true, and `/` is read-only.

---

Previous: [phase 0](phase0.md) · Next: [phase 2](phase2.md)
