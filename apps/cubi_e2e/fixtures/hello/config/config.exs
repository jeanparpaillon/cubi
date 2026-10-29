import Config

# Build-time, so it ships in the release's sys.config: `ok`, `crash_on_start`
# (start/2 fails) or `crash_later` (the application dies 5 s after starting).
config :hello, mode: String.to_atom(System.get_env("HELLO_MODE", "ok"))

# The e2e harness drives cubi's provider tasks from this project, as an
# operator would (docs/milestone2.md): QEMU instances under that directory.
if dir = System.get_env("CUBI_E2E_QEMU_DIR") do
  config :cubi_tools, providers: [qemu: {Cubi.Provider.Qemu, dir: dir}]
end
