import Config

# RingLogger is a dependency of :kubex_fw only; kubex_e2e runs without it.
if Code.ensure_loaded?(LoggerBackends) do
  Application.ensure_all_started(:logger_backends)
  LoggerBackends.add(RingLogger)
end
