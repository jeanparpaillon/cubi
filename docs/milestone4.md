# Milestone 4 — OVHcloud and EC2 providers

Part of the cubi node boot plan: design in [specs.md](specs.md), open questions in [questions.md](questions.md), tests in [testing.md](testing.md).

[Milestone 2](milestone2.md) built the provisioning side for QEMU and Vultr:
public images, a private iPXE script, the `Cubi.Provider` behaviour and the
`mix cubi.provision` family of tasks. This milestone adds three providers. All
of them boot the same public images from a private script. What differs
between them is how the script reaches the machine's iPXE:

| Module | Machines | How the script reaches iPXE | Changing it |
| --- | --- | --- | --- |
| `Cubi.Provider.Ec2` | EC2 instances | the ipxe.org AMI runs the instance's **user data** as its script, fetched from IMDS **(verify)** | user data can only change on a stopped instance: stop, `ModifyInstanceAttribute`, start |
| `Cubi.Provider.OvhCloud` | OVHcloud Public Cloud (OpenStack) instances | an **iPXE image uploaded to Glance** that reads the user data from the metadata service, as the EC2 build does **(verify)** | rebuild with new `user_data` (Nova microversion ≥ 2.57) **(verify)** |
| `Cubi.Provider.OvhMetal` | rented OVHcloud dedicated servers | a **stored iPXE script** on the OVH account, set as the server's netboot **(verify)** | replace the script, then reboot |

Still no Erlang distribution and no join ([phase 7](phase7.md)). Every
instance is a diskless standalone node, as in milestone 2.

**Depends on milestone 2.** It needs `mix cubi.provision`/`instances`/
`upgrade`/`destroy`, `mix cubi.deploy --provider` and the published public
images, all still open there. A cloud instance cannot reach
`http://10.0.2.2`, so a manual run needs a version published at an HTTPS URL.
This milestone also reuses the `Req` and `Req.Test` setup that the Vultr
module introduces. Whichever of the two lands first adds the dependency.

## Design

### EC2

- **API.** The EC2 Query API over `Req`, signed with Req's built-in
  `aws_sigv4:` step. Responses are XML, parsed with `:xmerl`, which is part of
  OTP. That adds no dependency beyond `Req`, so no `ex_aws`. Credentials come
  from `{:env, "AWS_ACCESS_KEY_ID"}`, `{:env, "AWS_SECRET_ACCESS_KEY"}` and an
  optional `AWS_SESSION_TOKEN`. There is no `~/.aws` profile parsing
  ([§2.12.3](specs.md): credentials come from the environment).
- **The image.** The ipxe.org public AMI for the region, chosen by `firmware`
  (BIOS or UEFI AMI). It is looked up with `DescribeImages` by owner account
  and name, or pinned with `ami:` in the config. A cubi-built AMI whose iPXE
  trusts the cubi project's CA would close the first hop
  ([questions.md](questions.md)). That is out of scope here.
- **`create/2`.** `RunInstances` with the script as `UserData` (16 KB limit,
  far above the 2048-byte cmdline), `TagSpecifications` `Name=<name>` and
  `cubi=true`, `size` as the instance type (default `t3.micro`, a Nitro type
  with ENA), and a public IPv4 address. It also sets
  `MetadataOptions.HttpTokens=optional` if stock iPXE only speaks IMDSv1
  **(verify)**. Accounts that default to IMDSv2-only would otherwise boot
  iPXE with no script.
- **Network setup belongs to the operator.** `subnet_id:` and
  `security_group_id:` (ssh open to the operator) come from the config. The
  module creates no security group, key pair or VPC, so `destroy/2` has
  nothing to clean up beyond the instance. The AMI's small EBS root volume has
  `DeleteOnTermination`.
- **`list/1` and `get/2`.** `DescribeInstances` filtered on `tag:cubi=true`,
  **excluding `terminated` and `shutting-down`**. A terminated instance stays
  visible for about an hour and would otherwise block its name.
  Status mapping: `pending` → `:pending`, `running` → `:running`,
  `stopping`/`stopped` → `:stopped`.
- **`set_script/3`.** Stop, wait for `stopped`, `ModifyInstanceAttribute
  UserData`, start. The spec already allows this
  ([§2.12.3](specs.md): "a provider that must stop the instance … does so
  inside `set_script/3`"). `reboot/2` on an instance that `set_script/3` just
  started is a no-op.
- **Kernel.** Nitro instances need `CONFIG_ENA_ETHERNET` for the node to have
  a network once Linux runs (iPXE has its own ENA driver). The serial console
  is `ttyS0`, as now. The diskless node does not use the EBS root, so NVMe is
  not required.

### OVHcloud Public Cloud

- **API.** OpenStack: Keystone v3 password auth (`OS_USERNAME`,
  `OS_PASSWORD`, `OS_PROJECT_ID`, `OS_AUTH_URL` from the environment, as in
  OVH's `openrc`), then Nova and Glance over `Req`. `region` is the OpenStack
  region (`GRA11`, `SBG5`, …) and `size` is the flavor name (default `d2-2`).
- **The image.** OpenStack has no network boot, so cubi uploads its own iPXE
  as a Glance image (`cubi-ipxe-<version>`, private, tagged `cubi`). It is
  built from iPXE's cloud configuration, whose embedded script chains
  `http://169.254.169.254/latest/user-data`. OpenStack's metadata service
  serves that EC2-compatible path **(verify)**. This is the per-provider iPXE
  that [questions.md](questions.md) asks about, so it can also
  `TRUST=` the cubi project's CA and `imgverify` the kernel and stage-1. A
  task, `mix cubi.ovh.image`, builds and uploads it once per project. Like the
  operator's network, the image is not created or deleted by
  `create/2`/`destroy/2`.
- **`create/2`.** `POST /servers` with `user_data` (base64), `metadata`
  `cubi=true`, the name, the image and the flavor, on `Ext-Net` for a public
  address. `list/1` filters on that metadata. Nova does not enforce unique
  names, so `create/2` checks first.
- **`set_script/3`.** A rebuild with the same image and the new `user_data`.
  A rebuild is a cold boot, so `reboot/2` after it is a no-op, as on EC2.
- **Kernel.** virtio, already in the defconfig.

### OVHcloud bare metal

- **API.** The OVH v1 API (`eu.api.ovh.com/1.0`), authenticated with an OAuth2
  service account (client credentials, `OVH_CLIENT_ID`/`OVH_CLIENT_SECRET`),
  which avoids hand-rolling the legacy `$1$` signature **(verify)** that
  service accounts are accepted on `/dedicated/server`.
- **A pool, not creation.** Dedicated servers are rented, not created per
  call. The config lists the servers cubi may use
  (`servers: ["ns1234567.ip-1-2-3.eu", …]`). `create/2` claims a free one (or
  the one named by `size`) by tagging it `cubi=<name>` with an IAM resource tag
  **(verify)**, stores the script with `POST /me/ipxeScript` as
  `cubi-<name>`, points the server's netboot at it and reboots it.
  `destroy/2` restores the server's previous boot (kept in the instance's
  `provider` map, then in the tag), deletes the stored script, removes the tag
  and reboots. The server stays rented. **[§2.12.3](specs.md) must say so**:
  for a pool provider, `destroy/2` means "release".
- **The stored script is account-wide.** Anyone with the account's API access
  can read it. That matches [§2.12.2](specs.md) (private, behind the
  provider's authenticated API) and leaves out the vendor's public-URL boot
  option.
- **Boot takes minutes.** POST and RAID controllers make a bare-metal reboot
  much slower than a VM's. `mix cubi.provision` and `mix cubi.upgrade` take
  their wait from the provider (a new optional callback,
  `boot_timeout/1`, default 5 min; OvhMetal answers 15).
- **Kernel.** OVH servers carry Intel (`igb`, `ixgbe`, `i40e`, `ice`),
  Broadcom (`bnxt_en`) and Mellanox (`mlx5_core`) NICs. The first three are
  already `=m`. `ice`, `bnxt_en` and `mlx5_core` are added, and the modules
  must load at boot on a diskless node. Their main IPv4 comes over DHCP. The
  serial console is IPMI SOL, which may sit on `ttyS1` **(verify)**, so the
  script takes `--cmdline` as usual. This overlaps [phase 8](phase8.md) (real
  hardware), which keeps disks and ZFS. Here the server stays diskless.

### Shared changes

- `Cubi.Provider.Case` gains a `:provider_kind` (`:cloud` or `:pool`). The pool
  variant runs the same assertions, except that `destroy/2` returns the server
  to the pool instead of deleting it, and `create/2` on a full pool fails with
  `{:error, :pool_exhausted}`.
- `firmware: :uefi` on a provider that cannot honour it is an error from
  `create/2`, never silently BIOS.
- An `addresses` list puts the public IPv4 first, so `mix cubi.deploy
  --provider` keeps taking the first address.

## Checklist

- [ ] [specs.md](specs.md) §2.12.3: the provider table gains `Ec2`, `OvhCloud` and `OvhMetal`; pool providers and `destroy/2` as release; the optional `boot_timeout/1`. [§2.5](specs.md): `ena`, `ice`, `bnxt_en`, `mlx5_core`. README "Run it in the cloud" names the new providers. The **(verify)** points go into [phase 0](phase0.md).
- [ ] Phase 0 checks, run by hand on real accounts before writing each module: the ipxe.org AMI runs user data under BIOS and UEFI, and whether it needs IMDSv1; OpenStack on OVH serves `/latest/user-data` to an uploaded iPXE; OVH's API stores an iPXE script and netboots a dedicated server from it; service-account auth and IAM tags on `/dedicated/server`; the SOL console's tty.
- [ ] Kernel: `CONFIG_ENA_ETHERNET`, `CONFIG_ICE`, `CONFIG_BNXT`, `CONFIG_MLX5_CORE` (+ `MLX5_CORE_EN`) in `linux-6.18.defconfig` of the system fork. Check that NIC modules are loaded at boot on a diskless node. Report the image size delta.
- [ ] `Cubi.Provider.Case`: `:provider_kind`, the pool variant, `boot_timeout/1` with its default in `Cubi.Provider`. The provisioning tasks read it.
- [ ] `Cubi.Provider.Ec2`: SigV4 through `Req`, `:xmerl` parsing, AMI lookup, the calls above. Conformance suite against `Req.Test` stubs built from recorded API responses (`test/fixtures/ec2/*.xml`).
- [ ] `Cubi.Provider.OvhCloud`: Keystone token (cached for its lifetime in the state), Nova/Glance calls. `mix cubi.ovh.image` builds iPXE with the cloud script (and `TRUST=` the project's CA when given `--signer`) and uploads it. Conformance suite against stubs.
- [ ] `Cubi.Provider.OvhMetal`: OAuth2 client credentials, pool claim/release, stored script lifecycle, boot restore. Conformance suite (pool variant) against stubs.
- [ ] Manual run per provider on a real account, recorded in this file with its date, the way milestone 2's steps are.
- [ ] Docs: one page per provider in the operator documentation planned in [milestone 3](milestone3.md), covering account setup, the minimal IAM policy (EC2), the OpenStack user (Public Cloud) and the API scopes (bare metal).

**Acceptance:**

- Each of the three modules passes `Cubi.Provider.Case` against its stubbed API, and its `on_exit` cleanup leaves no instance in the stub.
- `Ec2.list/1` does not report an instance that is `shutting-down` or `terminated`, and `create/2` with that instance's name then succeeds.
- `Ec2.set_script/3` on a running instance issues stop, `ModifyInstanceAttribute` and start in that order. The stub refuses `ModifyInstanceAttribute` on a running instance, as EC2 does.
- `create/2` with `firmware: :uefi` on a provider or image that has no UEFI variant returns an error and creates nothing.
- `OvhMetal.create/2` with every pooled server claimed returns `{:error, :pool_exhausted}`. `destroy/2` leaves the server untagged, with its previous netboot and no `cubi-<name>` script on the account.
- A diskless node built with the new defconfig brings up its network on an `ena` NIC (EC2 run) and on at least one of `ice`/`bnxt_en`/`mlx5_core` (OVH bare-metal run).
- Run by hand on each real account: `mix cubi.provision n1 --provider <p>` returns once n1 answers ssh. `mix cubi.deploy n1 --provider <p>` of `hello` answers on the public address. `mix cubi.upgrade n1 --image <v2>` reports v2's firmware UUID. `mix cubi.destroy n1 --yes` then leaves no instance, no stored script and no user data on the account (EC2, Public Cloud), or the server released to its previous boot (bare metal).

---

Previous: [milestone 3](milestone3.md) · Next: [phase 7](phase7.md)
