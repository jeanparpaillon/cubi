import Config

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
config :nerves_runtime, startup_guard_enabled: true

# The serial number is the machine ID that erlinit also uses for the hostname:
# the SMBIOS UUID, or the first MAC (cubi_system_x86_64's cubi-boardid,
# docs/specs.md §2.6).
config :nerves_runtime, boardid_path: "/usr/bin/cubi-boardid"

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit, update_clock: true

# Default to not starting so that the console logger isn't started. See
# runtime.exs for logger configuration.
config :logger, :default_handler, false

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
# * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

keys =
  if config_env() == :e2e do
    # The e2e firmware trusts the cubi_e2e harness key and nothing else
    # (docs/testing.md §3). The key is generated locally, never committed.
    harness_key = Path.expand("../apps/cubi_e2e/priv/harness_key/id_ed25519.pub", __DIR__)

    if not File.exists?(harness_key),
      do:
        Mix.raise("""
        No harness key at #{harness_key}.
        Run `mix cubi.e2e.key` first.
        """)

    [harness_key]
  else
    System.user_home!()
    |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
    |> Path.wildcard()
  end

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1),
  # nerves_ssh's default sftp, plus `ssh -s <node> cubi_deploy`
  # (docs/specs.md §2.11.5). Set here rather than added at runtime: nerves_ssh
  # rebuilds its daemon from this list whenever it restarts, which it does at
  # least once at boot. It adds `fwup` back by itself.
  subsystems: [
    {~c"sftp", {:ssh_sftpd, [cwd: ~c"/"]}},
    {~c"cubi_deploy", {Cubi.Deploy.Subsystem, []}}
  ]

# The root CA the node trusts for deployed releases, installed as
# /etc/cubi/ca.pem in the served rootfs, and the PKI whose signer signs the
# served images (docs/specs.md §2.11.2, `mix firmware.ipxe`).
if config_env() == :e2e do
  # The e2e firmware is signed by the harness's test CA, never the operator's
  # (docs/testing.md §3). Generated locally, never committed.
  pki = Path.expand("../apps/cubi_e2e/priv/pki", __DIR__)

  if not File.exists?(Path.join(pki, "signer.key")),
    do:
      Mix.raise("""
      No test CA in #{pki}.
      Run `mix cubi.e2e.key` first.
      """)

  config :cubi_fw, ca_cert: Path.join(pki, "ca.pem"), signer: pki
else
  # The operator's root (`mix cubi.gen_ca`), if there is one. Signing stays an
  # explicit `--signer`.
  ca = Path.join(System.get_env("CUBI_PKI_DIR") || Path.expand("~/.cubi/pki"), "ca.pem")
  if File.exists?(ca), do: config(:cubi_fw, ca_cert: ca)
end

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
