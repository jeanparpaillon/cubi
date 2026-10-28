import Config

# Build-time, so it ships in the release's sys.config: `ok`, `crash_on_start`
# (start/2 fails) or `crash_later` (the application dies 5 s after starting).
config :hello, mode: String.to_atom(System.get_env("HELLO_MODE", "ok"))
