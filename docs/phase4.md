# Phase 4 — network boot in QEMU

Part of the kubex node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

- [x] `-netdev user,id=n0,tftp=…,bootfile=boot.ipxe` for the simplest loop, then over HTTP.
      Done by hand on 2026-10-28 with QEMU 10.2's BIOS iPXE ROM (1.21.1+git-20250829), no disk, from the directory
      `mix firmware.ipxe` writes (`D=_build/x86_64_e2e/ipxe`):

      ```sh
      # TFTP: slirp's TFTP server serves $D; boot.ipxe's relative URLs resolve to tftp://10.0.2.2/
      qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 1024 -nographic \
        -netdev user,id=n0,tftp=$D,bootfile=boot.ipxe -device virtio-net-pci,netdev=n0 -boot n

      # HTTP: any server on host loopback; the DHCP filename is a URL, which iPXE fetches as is
      python3 -m http.server 8080 --bind 127.0.0.1 --directory $D &
      qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 1024 -nographic \
        -netdev user,id=n0,bootfile=http://10.0.2.2:8080/boot.ipxe -device virtio-net-pci,netdev=n0 -boot n
      ```

      Both reach IEx in about 8 s from QEMU start, with `firmware_validation_status/0` `:validated` and the served
      UUID. The same `boot.ipxe` works for both: its relative URLs follow the protocol it was fetched with (the
      HTTP server's log shows all four files; the HTTP run has no TFTP root at all).
- [x] Repeat under OVMF with `ipxe.efi`.
      Done by hand on 2026-10-28, OVMF (`OVMF_CODE_4M.fd`, a fresh `OVMF_VARS_4M.fd` copy), no disk. OVMF's own PXE
      client can only run an EFI binary, and pointing it at `ipxe.efi` alone loops: iPXE asks DHCP again and slirp
      answers `ipxe.efi` again. What breaks the loop: iPXE's EFI build (1.21+) fetches `autoexec.ipxe` from the TFTP
      server it was loaded from, before any DHCP of its own. So the TFTP root holds `ipxe.efi` (Ubuntu's `ipxe`
      package, `apt download ipxe`, until [phase 5](phase5.md) builds ours) and a two-line `autoexec.ipxe`:

      ```sh
      # TFTP throughout: $T = the served directory + ipxe.efi + autoexec.ipxe ("dhcp", "chain boot.ipxe")
      qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 1024 -nographic \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,file=vars.fd \
        -netdev user,id=n0,tftp=$T,bootfile=ipxe.efi -device virtio-net-pci,netdev=n0,bootindex=0

      # HTTP after the chainload: $T holds only ipxe.efi and autoexec.ipxe
      # ("dhcp", "chain http://10.0.2.2:8080/boot.ipxe"); the served directory is on the HTTP server
      ```

      Both reach IEx in about 9.5 s, `:validated`, with the kernel booted through its EFI stub (`efi: EFI v2.7 by
      … EDK II` in its log, and the image name in front of the cmdline, [phase 0](phase0.md)). In the HTTP run, only
      the chainload step is TFTP, as [§2.7](specs.md) wants; the HTTP server's log shows `boot.ipxe` and the three
      images.
- [x] Harness: `firmware: :uefi` with a per-VM OVMF vars copy; `:pxe` boot over user-mode TFTP and HTTP ([testing.md](testing.md) §4.1, §5).
      `boot: {:pxe, :tftp | :http, served_dir}` in `Kubex.E2E.VM`, `Kubex.E2E.HttpServer` (Bandit), and
      `mix kubex.e2e.ipxe` for `ipxe.efi`. Tested by `apps/kubex_e2e/test/phase4_netboot_test.exs`.

**Acceptance:** a cold QEMU VM with no disk boots to IEx, for both BIOS and UEFI.

Validated on 2026-10-28 by `phase4_netboot_test.exs`: BIOS and UEFI, each over TFTP and over HTTP. Each case also
checks that the node reports the served firmware's UUID, `:validated`, and which way the files came (the HTTP
server's log, or none at all for TFTP; `autoexec.ipxe` and an EFI-stub kernel under UEFI).

---

Previous: [phase 3](phase3.md) · Next: [phase 5](phase5.md)
