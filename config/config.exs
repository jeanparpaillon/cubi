# This file is responsible for configuring your umbrella and **all
# applications** and their dependencies with the help of the Config module.
#
# All applications in the umbrella share this configuration. cubi_e2e is
# host-only and is never part of the firmware.
import Config

# Enable the Nerves integration with Mix. Not in cubi_e2e, cubi_pki or
# cubi_tools: nerves_bootstrap refuses to start in a project without a :nerves
# dependency, and none has one (the harness and the tools are host-only, the
# PKI a plain library).
if Mix.Project.config()[:app] not in [:cubi_e2e, :cubi_pki, :cubi_tools] do
  Application.start(:nerves_bootstrap)
end

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.
#
# The overlay belongs to :cubi_fw. `mix firmware` is run from apps/cubi_fw,
# but this config is shared by the whole umbrella, so use an absolute path.
config :nerves, :firmware, rootfs_overlay: Path.expand("../apps/cubi_fw/rootfs_overlay", __DIR__)

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1793111724"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
