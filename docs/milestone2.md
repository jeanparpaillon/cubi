# Milestone 2 — cloud instances from public images

Part of the cubi node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

Provisioning a node on someone else's machines (a cloud VM, a VPS, a rented
bare-metal server) comes down to **one private iPXE script** that points at
**public cubi images** and names the operator's CA on the kernel cmdline. The
operator builds no image: the cubi project publishes one kernel, one stage-1
and one rootfs per version, identical for every operator. Everything that makes
a node *theirs* is in the script.

The operator drives it with Mix tasks, as in [milestone 1](milestone1.md). The
IaaS details sit behind a `Cubi.Provider` behaviour, one module per provider.
Still no Erlang distribution, no join ([phase 7](phase7.md)): each instance is a
standalone node that runs releases deployed with `mix cubi.deploy`.

```
public, per cubi version                    private, per instance
https://…/cubi/<version>/                   rendered by mix cubi.provision,
  vmlinuz                                   handed to the provider's API
  stage1.cpio.zst
  rootfs.squashfs   ◄── pinned by hash ──── #!ipxe
  base.json                                 set base https://…/cubi/<version>
  SHA256SUMS                                kernel ${base}/vmlinuz console=ttyS0 \
  *.sig                                       cubi.rootfs=sha256:<hex> \
                                              cubi.ca=sha256:<hex> \
                                              cubi.ssh=ssh-ed25519:<base64>
                                            initrd ${base}/stage1.cpio.zst
                                            initrd ${base}/rootfs.squashfs /rootfs.squashfs
                                            boot
```

## Design

Specified in [specs.md §2.12](specs.md): the public images (§2.12.1), the
private script and its cmdline pins (§2.12.2), the `Cubi.Provider` behaviour
and its providers (§2.12.3), and the Mix tasks (§2.12.4). It amends
[§2.4](specs.md) (the rootfs hash check in stage-1), [§2.11.2](specs.md),
[§2.11.3](specs.md) (`--base` takes a URL) and [§2.11.4](specs.md) step 1 (the
trusted root is `/etc/cubi/ca.pem` or the archive's `ca.pem` pinned by
`cubi.ca=`). Its open points are in [questions.md](questions.md), and its
**(verify)** points in [phase 0](phase0.md).

## Checklist

- [x] [specs.md](specs.md) §2.12 *Cloud instances*; §2.11.2 and §2.11.4 step 1 amended for `cubi.ca=` and the archive's `ca.pem`; README gains "Run it in the cloud"; [questions.md](questions.md) gets the open points; the **(verify)** points go into [phase 0](phase0.md).
      §2.12 in four parts (public images, the script and its cmdline, `Cubi.Provider`, the tasks). Also amended: §2.3 (`--public`), §2.4 (stage-1 checks `cubi.rootfs=` as its new step 2), §2.11.3 (`--base` takes a URL, checked against `SHA256SUMS`), §2.11.4 (`ca.pem` as a third signed member, allowed by step 3), §2.11.5 (authorized keys from `cubi.ssh=`). The open points (first hop of the boot, where images are hosted, cloud storage nodes) and the three **(verify)** checks were already in place.
- [x] Stage-1: `cubi.rootfs=sha256:` checked with busybox `sha256sum` before `losetup`; absent = no check, with a console warning. The C stage-1 of [phase 5](phase5.md) inherits it.
      In the system fork: `CONFIG_SHA256SUM` added to `package/cubi-stage1/busybox.fragment` (the archive stays ~109 KB), the check in `stage1/init` after the `/rootfs.squashfs` test. The last `cubi.rootfs=` counts; a malformed one (another algorithm, not 64 lowercase hex digits, empty) fails like a mismatch, never skips. `apps/cubi_e2e/test/milestone2_rootfs_pin_test.exs` covers the matching pin, a wrong pin, a one-byte change to the rootfs (both stop at stage-1, reboot, and never reach erlinit), the last-wins rule, four malformed pins and the absent-pin warning; validated on 2026-10-29. A changed busybox fragment needs `make cubi-stage1-dirclean` in the system's build directory: Buildroot does not see it.
- [ ] Node: `cubi.ssh=` into `nerves_ssh`'s authorized keys from `config/runtime.exs`; `cubi.ca=` read by the release verification, with the archive's `ca.pem` ([§2.11.4](specs.md)). `Cubi.Pki.Archive.verify` takes the trusted root as an argument rather than reading `/etc/cubi/ca.pem`.
- [ ] `mix cubi.sign` adds `ca.pem` (the signer directory's root) to the archive; `Cubi.Pki.Archive` accepts it as a known member.
- [ ] `mix firmware.ipxe --public`: no CA, no authorized keys, refuses if either is configured; still writes `base.json` and `SHA256SUMS`, and the `.sig` files when given the project's signer.
- [ ] `mix cubi.release --base <url>`: fetches `base.json` over HTTPS, checked against `SHA256SUMS`.
- [ ] `Cubi.Tools.BootScript` and `mix cubi.boot_script`: the pins, the 2048-byte limit, `--no-ssh`.
- [x] `Cubi.Provider` behaviour, `Instance`, provider config and `{:env, var}` resolution; a shared conformance suite (`Cubi.Provider.Case`) that every provider module runs.
      `Cubi.Provider` (`config/1` finds a provider by atom or `--provider` string without creating atoms, `init/1` resolves top-level `{:env, var}` options, an unset or empty variable failing before the module's `init/1`) and `Cubi.Provider.Instance` (`status` is `:pending`, `:running`, `:stopped` or `:unknown`) in `apps/cubi_tools/lib`. `Cubi.Provider.Case` is in `apps/cubi_tools/test/support`: `use Cubi.Provider.Case, provider: M`, options from the context's `:provider_opts`, and every instance a test created destroyed in `on_exit`, which fails loudly. It runs against `Cubi.Provider.Fake`, which keeps one file per instance and is meant for the task tests too.
- [x] `Cubi.Provider.Qemu`: VMs as background QEMU processes, BIOS and UEFI, booted from a local HTTP server serving a public directory and the per-instance script.
      `Cubi.Provider.Qemu` in `apps/cubi_tools`. QEMU runs with `-daemonize`, its pid checked against `/proc/<pid>/cmdline`, so instances outlive the Mix task. The per-instance script is **not** served over HTTP: an HTTP server would have to outlive the task too, so QEMU's own user-mode TFTP delivers it (`tftp/boot.ipxe`; UEFI through `ipxe.efi` and `autoexec.ipxe`), and the public directory is served by whoever runs it (the harness's `HttpServer`, `http://10.0.2.2:<port>` to the guest). A reboot stops QEMU and starts it again from `instance.json`. The conformance suite runs under TCG (`apps/cubi_tools/test/cubi/provider/qemu_test.exs`, tag `:qemu`); `apps/cubi_e2e/test/milestone2_qemu_provider_test.exs` boots the e2e image to IEx through it under BIOS and UEFI, validated on 2026-10-28.
- [ ] `mix cubi.provision`, `mix cubi.instances`, `mix cubi.upgrade`, `mix cubi.destroy`; `mix cubi.deploy --provider`.
- [ ] `Cubi.Provider.Vultr` over its REST API (`Req`), the conformance suite against a stubbed API (`Req.Test`), and one manual run on a real account.
- [ ] Publishing: build the public image for a version and upload it with its `SHA256SUMS` and `.sig` files (CI once the repository has a remote; by hand until then). The project's own CA is created with `mix cubi.gen_ca` and kept offline, like any operator's.
- [ ] Harness: two operator CAs and ssh keys in `apps/cubi_e2e/priv/`, one public directory built by the tests, `Cubi.Provider.Qemu` driving the VMs.

**Acceptance:**

- `unsquashfs -l` of the public `rootfs.squashfs` lists no `/etc/cubi/ca.pem`, and its `nerves_ssh` config holds no key.
- One public directory boots two QEMU instances with scripts for CA A and CA B. Each accepts `hello` signed under its own CA and refuses it signed under the other's; the refused node still runs its previous release.
- An archive whose `ca.pem` does not match `cubi.ca=` is refused, even when correctly signed under that `ca.pem`.
- A script whose `cubi.rootfs=` does not match the served rootfs, and a one-byte change to the served rootfs under a correct script, each stop the boot at stage-1 with the mismatch message; BEAM never starts.
- An instance logs in the key named by `cubi.ssh=` and refuses another key; with no `cubi.ssh=`, it refuses every key.
- `mix cubi.boot_script` with a cmdline over 2048 bytes exits non-zero and prints nothing on stdout.
- `mix cubi.provision n1 --provider qemu` returns once n1 answers ssh; `mix cubi.deploy n1 --provider qemu` of `hello` v1 returns 0 and `hello` answers.
- `mix cubi.provision n1` again fails and leaves n1 running.
- `mix cubi.instances` lists n1; `mix cubi.upgrade n1 --image <v2>` reboots it onto v2, which reports v2's firmware UUID, and runs only the base image until `hello` is deployed again.
- `mix cubi.destroy n1 --yes` leaves `mix cubi.instances` empty and no QEMU process behind.
- The Vultr module passes the conformance suite against the stubbed API. Run by hand on a real account: provision, deploy `hello`, reach it on the public address, destroy; the account then holds no instance and no startup script, and the script was never fetchable without the API key.

---

Previous: [milestone 1](milestone1.md) · Next: [phase 7](phase7.md)
