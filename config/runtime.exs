import Config

# RingLogger is a dependency of :kubex_fw only; kubex_e2e runs without it.
if Code.ensure_loaded?(LoggerBackends) do
  Application.ensure_all_started(:logger_backends)
  LoggerBackends.add(RingLogger)
end

# Firmware metadata for Nerves.Runtime (docs/specs.md §2.6). `mix firmware.ipxe`
# appends /firmware.kv to the served rootfs, with what fwup would have written
# into the boot environment on a disk install: a diskless node has none. Only
# images built by that task have it; others keep the default backend.
if config_target() != :host do
  case File.read("/firmware.kv") do
    {:ok, text} ->
      contents =
        for line <- String.split(text, "\n", trim: true),
            [key, value] <- [String.split(line, "=", parts: 2)],
            into: %{},
            do: {key, value}

      config :nerves_runtime, kv_backend: {Nerves.Runtime.KVBackend.InMemory, contents: contents}

    {:error, _} ->
      :ok
  end
end
