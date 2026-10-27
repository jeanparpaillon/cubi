# Phase 1 — boot by hand, no iPXE

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [ ] `kubex_e2e` harness, tier 1: `VM`, `Console`, `Node`, and the `MIX_ENV=e2e` firmware ([testing.md](testing.md) §2–§3).
- [ ] Write stage-1 (busybox script) and build its cpio by hand.
- [ ] Extract `rootfs.squashfs` from a stock `.fw`. The stock kernel has no initramfs
      support ([phase 0](phase0.md)), so until [phase 2](phase2.md) the kernel is a borrowed one
      with `BLK_DEV_INITRD`, `BLK_DEV_LOOP` and `SQUASHFS` built in, for example
      Ubuntu's `linux-image-unsigned` (`apt download`, no root), as in phase 0.
- [ ] Pad `stage1.cpio.zst` to a 4-byte boundary and concatenate it with `rootfs.cpio`:
      QEMU's `-initrd` takes one file for a Linux kernel.
- [ ] `qemu-system-x86_64 -kernel vmlinuz -initrd initrd.img -append console=ttyS0 -nographic`
      reaches the IEx prompt.

**Acceptance:** `Nerves.Runtime.firmware_valid?/0` is true, and `/` is read-only.

---

Previous: [phase 0](phase0.md) · Next: [phase 2](phase2.md)
