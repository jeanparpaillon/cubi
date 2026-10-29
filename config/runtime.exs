import Config

# RingLogger is a dependency of :cubi_fw only; cubi_e2e runs without it.
if Code.ensure_loaded?(LoggerBackends) do
  Application.ensure_all_started(:logger_backends)
  LoggerBackends.add(RingLogger)
end

# Firmware metadata for Nerves.Runtime (docs/specs.md §2.6). `mix firmware.ipxe`
# puts /etc/firmware.kv in the served rootfs, with what fwup would have written
# into the boot environment on a disk install: a diskless node has none. Only
# images built by that task have it; others keep the default backend.
if config_target() != :host do
  case File.read("/etc/firmware.kv") do
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

  # cubi.ssh=<type>:<base64> on the cmdline adds authorized keys to those
  # compiled into the image (docs/specs.md §2.12.2): a public image has none,
  # so they are its only way in. Release boot has loaded the applications by
  # now, so the compiled-in keys are in the application environment.
  if Code.ensure_loaded?(Cubi.Cmdline) and File.exists?("/proc/cmdline") do
    case Cubi.Cmdline.ssh_keys(Cubi.Cmdline.read()) do
      [] ->
        :ok

      keys ->
        compiled = Application.get_env(:nerves_ssh, :authorized_keys, [])
        config :nerves_ssh, authorized_keys: Enum.uniq(compiled ++ keys)
    end
  end
end
