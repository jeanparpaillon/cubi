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

To fold into [specs.md](specs.md) as §2.12 (first checklist item). The points
below are the decisions; the spec gives them their full form.

**The public image is generic.** It carries no CA, no ssh key and no signer.
`mix firmware.ipxe --public` builds it: no `/etc/cubi/ca.pem`, no
`nerves_ssh` authorized keys compiled in, and the build fails if either is
configured. The project publishes one directory per version (vmlinuz,
stage1, rootfs, `base.json`, `SHA256SUMS`, and `.sig` files signed by the
**cubi project's** CA, for operators who run a custom iPXE that trusts it).
`base.json` is what `mix cubi.release --base` reads, so `--base` accepts that
URL as well as a local directory.

**The operator's configuration moves to the cmdline**, read with
`Cubi.Cmdline`:

| Argument | What | Read by |
| --- | --- | --- |
| `cubi.rootfs=sha256:<hex>` | the SHA-256 of `rootfs.squashfs` | stage-1, before `losetup`: a mismatch prints `cubi stage-1: rootfs hash mismatch` and reboots, like any stage-1 failure ([§2.4](specs.md)) |
| `cubi.ca=sha256:<hex>` | the SHA-256 of the operator's root certificate (DER) | `Cubi.Deploy`, when verifying a release ([§2.11.4](specs.md) step 1) |
| `cubi.ssh=<type>:<base64>` | one ssh authorized key, repeatable; the space of the `authorized_keys` line becomes `:`, the comment is dropped | `config/runtime.exs`, into `nerves_ssh`'s `authorized_keys` |

- **A pin, not the certificate.** An RSA-3072 root is ~0.9 KB of DER, ~1.2 KB
  in base64, out of x86's 2048-byte `COMMAND_LINE_SIZE`, which phase 7's
  `cubi.join=` and §2.10.3's `cubi.vdevs=` also need. So the cmdline pins the
  root's fingerprint, and the certificate travels **in the release archive**:
  `mix cubi.sign` adds `ca.pem` next to `signer.pem`. Step 1 of
  [§2.11.4](specs.md) becomes: the trusted root is `/etc/cubi/ca.pem` if the
  image has one, else the archive's `ca.pem` if its SHA-256 equals
  `cubi.ca=`. If the image has a CA *and* the cmdline pins one, they must be
  the same certificate, or every release is refused (logged at boot). With
  neither, every release is refused, as in milestone 1.
- **Nothing in the script is secret.** `/proc/cmdline` is world-readable and
  that is fine for a fingerprint, a hash and public keys. The script is
  **private because it is the trust anchor**: whoever writes it decides what
  the node runs and who may log in. It therefore travels only through the
  provider's authenticated API (user data, a stored PXE script), never at a
  public or guessable URL. A provider that can only boot a script from a URL
  is out of scope. Tokens stay off the cmdline in phase 7, as
  [§2.8.2](specs.md) says.
- **What the chain rests on.** A cloud's iPXE is stock, so it cannot
  `imgverify` against any of our CAs. The kernel and stage-1 are protected by
  HTTPS to the publisher only (stock iPXE checks the web PKI through its
  cross-signed root **(verify)**). From stage-1 on, the private script's pins
  take over: the rootfs by hash, releases by CA. Closing the first gap needs
  a cubi-built iPXE per provider image ([questions.md](questions.md)).
- **No `cubi.ssh=`, no ssh.** The node then accepts no login, and so no
  deploy. The render task refuses to write such a script unless `--no-ssh`.
- `mix cubi.boot_script` refuses a cmdline over 2048 bytes rather than let the
  kernel truncate it silently.

**`Cubi.Provider`**, in `apps/cubi_tools`:

```elixir
@callback init(opts :: keyword()) :: {:ok, state} | {:error, term()}
@callback create(state, spec()) :: {:ok, Cubi.Provider.Instance.t()} | {:error, term()}
@callback list(state) :: {:ok, [Cubi.Provider.Instance.t()]} | {:error, term()}
@callback get(state, name :: String.t()) :: {:ok, Cubi.Provider.Instance.t()} | {:error, :not_found | term()}
@callback set_script(state, Cubi.Provider.Instance.t(), script :: String.t()) :: :ok | {:error, term()}
@callback reboot(state, Cubi.Provider.Instance.t()) :: :ok | {:error, term()}
@callback destroy(state, Cubi.Provider.Instance.t()) :: :ok | {:error, term()}
```

- `spec()` is `%{name, script, size, region, firmware: :bios | :uefi}`;
  `size` and `region` are the provider's own strings, passed through.
  `Instance` is `%{id, name, status, addresses, provider: map()}`.
- **The provider is the inventory.** Instances are named and tagged `cubi`;
  `list/1` returns only those. No local state file to lose or get out of step.
  Names are unique per provider: `create/2` on a taken name is an error.
- **The script goes in as content**, never as a URL (above). Whatever the
  provider stores alongside (a startup script object, user data) is removed by
  `destroy/2`.
- **Credentials come from the environment**, never from a config file:

  ```elixir
  # the operator's project, config/config.exs
  config :cubi_tools, :providers,
    qemu: {Cubi.Provider.Qemu, []},
    vultr: {Cubi.Provider.Vultr, api_key: {:env, "VULTR_API_KEY"}, region: "cdg", size: "vc2-1c-1gb"}
  ```

- **Upgrade is still a reboot** ([§2.7](specs.md)): `set_script/3` with the new
  version's URL and rootfs hash, then `reboot/2`. A provider that must stop
  the instance to change its script does so inside `set_script/3`. Instances
  are diskless, so a reboot drops the deployed release
  ([§2.11.6](specs.md)) and the operator deploys it again.

Providers in this milestone: **`Cubi.Provider.Qemu`**, local, for development
and for the harness (state under `_build/cubi/qemu/<name>/`, the script served
to iPXE the way phase 4's tests do), and **one cloud, Vultr**, whose API stores
a `pxe` startup script and boots an instance from it **(verify)**. AWS (the
ipxe.org EC2 image, which runs its user data as the script **(verify)**) is the
natural second, and needs the `ena` and `nvme` drivers in the kernel.

**Mix tasks**, all in `apps/cubi_tools`:

| Task | Does |
| --- | --- |
| `mix cubi.boot_script [--image <version\|url>] [--ca <dir>] [--ssh <file>…]` | renders the private script to stdout: fetches `SHA256SUMS` for the rootfs pin, computes the CA's fingerprint, reads the ssh public keys (default `~/.ssh/id_*.pub`). The provisioning tasks call the same `Cubi.Tools.BootScript` |
| `mix cubi.provision <name> --provider <p> [--size] [--region] [--image]` | renders, `create/2`, waits until the instance runs and answers ssh, prints its addresses and the CA fingerprint it pins |
| `mix cubi.instances [--provider <p>]` | `list/1`: name, status, addresses, image version |
| `mix cubi.upgrade <name> --image <version>` | `set_script/3` + `reboot/2`, waits for ssh, checks the node reports the new version's firmware UUID |
| `mix cubi.destroy <name> [--yes]` | `destroy/2`, after confirmation |

`--image` defaults to the version matching `cubi_tools`', at the project's
release URL (`config :cubi_tools, :image_base`). `mix cubi.deploy <name>
--provider <p>` resolves the name through `get/2` instead of taking a host.

## Checklist

- [ ] [specs.md](specs.md) §2.12 *Cloud instances* from the design above; §2.11.2 and §2.11.4 step 1 amended for `cubi.ca=` and the archive's `ca.pem`; README gains "Run it in the cloud"; [questions.md](questions.md) gets the open points; the **(verify)** points go into [phase 0](phase0.md).
- [ ] Stage-1: `cubi.rootfs=sha256:` checked with busybox `sha256sum` before `losetup`; absent = no check, with a console warning. The C stage-1 of [phase 5](phase5.md) inherits it.
- [ ] Node: `cubi.ssh=` into `nerves_ssh`'s authorized keys from `config/runtime.exs`; `cubi.ca=` read by the release verification, with the archive's `ca.pem` ([§2.11.4](specs.md)). `Cubi.Pki.Archive.verify` takes the trusted root as an argument rather than reading `/etc/cubi/ca.pem`.
- [ ] `mix cubi.sign` adds `ca.pem` (the signer directory's root) to the archive; `Cubi.Pki.Archive` accepts it as a known member.
- [ ] `mix firmware.ipxe --public`: no CA, no authorized keys, refuses if either is configured; still writes `base.json` and `SHA256SUMS`, and the `.sig` files when given the project's signer.
- [ ] `mix cubi.release --base <url>`: fetches `base.json` over HTTPS, checked against `SHA256SUMS`.
- [ ] `Cubi.Tools.BootScript` and `mix cubi.boot_script`: the pins, the 2048-byte limit, `--no-ssh`.
- [ ] `Cubi.Provider` behaviour, `Instance`, provider config and `{:env, var}` resolution; a shared conformance suite (`Cubi.Provider.Case`) that every provider module runs.
- [ ] `Cubi.Provider.Qemu`: VMs as background QEMU processes, BIOS and UEFI, booted from a local HTTP server serving a public directory and the per-instance script.
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
