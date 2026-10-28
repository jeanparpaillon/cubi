import Config

# Build-time only: a kubex release does not run config/runtime.exs
# (docs/specs.md §2.11.3).
config :kubex_hello, port: 8080

if config_env() == :test do
  config :kubex_hello, port: 4002
end
