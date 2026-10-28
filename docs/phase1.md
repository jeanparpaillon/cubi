# Phase 1 — boot by hand, no iPXE

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] `kubex_e2e` harness, tier 1: `VM`, `Console`, `Node`, and the `MIX_ENV=e2e` firmware ([testing.md](testing.md) §2–§3).
      In `apps/kubex_e2e` and `apps/kubex_fw`. The acceptance test is `apps/kubex_e2e/test/phase1_direct_boot_test.exs`. It takes
      the kernel from `KUBEX_E2E_KERNEL`, builds stage-1 from `stage1/`, and takes the rootfs from the
      e2e `.fw` in `_build/x86_64_e2e/` (`Kubex.E2E.Artifacts`).
- [x] Write stage-1 (busybox script) and build its cpio by hand: `stage1/init` and
      `elixir stage1/build.exs [--mode prod|dev]`. Tested by `apps/kubex_e2e/test/stage1_test.exs`.
      Since [phase 2](phase2.md), `init` lives in the system fork (`apps/kubex_system_x86_64/stage1/`) and Buildroot
      builds the archive; `build.exs` is gone.
- [x] Extract `rootfs.squashfs` from a stock `.fw`: `unzip -p kubex_fw.fw data/rootfs.img > rootfs.squashfs`,
      then `echo rootfs.squashfs | cpio -o -H newc --owner 0:0 > rootfs.cpio`. The stock kernel has no initramfs
      support ([phase 0](phase0.md)), so until [phase 2](phase2.md) the kernel is a borrowed one
      with `BLK_DEV_INITRD`, `BLK_DEV_LOOP` and `SQUASHFS` built in, for example
      Ubuntu's `linux-image-unsigned` (`apt download`, no root), as in phase 0.
- [x] Pad `stage1.cpio.zst` to a 4-byte boundary (`truncate -s %4`) and concatenate it with `rootfs.cpio`:
      QEMU's `-initrd` takes one file for a Linux kernel.
- [x] `qemu-system-x86_64 -enable-kvm -m 512 -kernel vmlinuz -initrd initrd.img -append "kho=off console=ttyS0" -nographic`
      reaches the IEx prompt. Without `-m`, QEMU's default 128 MiB panics before init. `kho=off` is for
      Ubuntu's kernel only: its kexec handover reservation sometimes takes ~400 MB at boot.

**Acceptance:** `Nerves.Runtime.firmware_valid?/0` is true, and `/` is read-only.

Validated on 2026-10-27, by hand on the `MIX_ENV=dev` image and by
`apps/kubex_e2e/test/phase1_direct_boot_test.exs` (BIOS and UEFI) on the e2e one.
`/` is the squashfs on `/dev/loop0`, mounted `ro`, and `/root` is a tmpfs.
`firmware_valid?/0` was true only by default at the time: the stock
`UBootEnv` KV backend finds no environment on a diskless boot, so the KV was
empty and nothing marked the image invalid. Since [phase 3](phase3.md), tests
boot what `mix firmware.ipxe` serves, whose KV is seeded, and
`firmware_validation_status/0` is `:validated` ([§2.6](specs.md)).

---

Previous: [phase 0](phase0.md) · Next: [phase 2](phase2.md)
