# This file is responsible for configuring your umbrella and **all
# applications** and their dependencies with the help of the Config module.
#
# All applications in the umbrella share this configuration. kubex_e2e is
# host-only and is never part of the firmware.
import Config

# Enable the Nerves integration with Mix. Not in kubex_e2e: nerves_bootstrap
# refuses to start in a project without a :nerves dependency, and the harness
# is host-only, so it has none.
if Mix.Project.config()[:app] != :kubex_e2e do
  Application.start(:nerves_bootstrap)
end

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.
#
# The overlay belongs to :kubex_fw. `mix firmware` is run from apps/kubex_fw,
# but this config is shared by the whole umbrella, so use an absolute path.
config :nerves, :firmware, rootfs_overlay: Path.expand("../apps/kubex_fw/rootfs_overlay", __DIR__)

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1793111724"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
