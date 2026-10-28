# Cubi.Provider.Qemu's tests start real QEMU processes (under TCG).
exclude = if System.find_executable("qemu-system-x86_64"), do: [], else: [:qemu]
ExUnit.start(exclude: exclude)
