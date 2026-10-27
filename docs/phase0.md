# Phase 0 — confirm the assumptions (half a day)

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md).

- [ ] `unzip -l` a stock `nerves_system_x86_64` `.fw`: rootfs and kernel resource paths.
- [ ] Check the stock x86_64 kernel config for every symbol in [§2.5](specs.md).
- [ ] Check that iPXE's `initrd <url> <name>` cpio wrapping works in QEMU's built-in ROM and in `ipxe.efi` under OVMF.
- [ ] Measure the squashfs size of a hello-world Nerves app → minimum RAM per node.
- [ ] Buildroot `zfs` package in `nerves_system_br` 1.34.0, and the squashfs size with it ([§2.10.5](specs.md)).
- [ ] `/dev/disk/by-id` absent under Nerves; `spl_hostid` keeps imports `-f`-free across reboots ([§2.10.3](specs.md)).
- [ ] Khepri 0.19 projections, and `verify_fun` as `{M, F, State}` in the `inet_tls_dist` options file ([§2.9.4](specs.md)).

---

Next: [phase 1](phase1.md)
