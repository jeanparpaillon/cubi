import Config

# Build-time only: a cubi release does not run config/runtime.exs
# (docs/specs.md §2.11.3).
config :cubi_hello, port: 8080

if config_env() == :test do
  config :cubi_hello, port: 4002
end
