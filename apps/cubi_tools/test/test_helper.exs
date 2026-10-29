# Cubi.Provider.Qemu's tests start real QEMU processes (under TCG); the
# network ones reach real HTTPS servers, only with `--include network`.
exclude = if System.find_executable("qemu-system-x86_64"), do: [], else: [:qemu]
ExUnit.start(exclude: [:network | exclude])
