defmodule Kubex.E2E.VM do
  @moduledoc """
  One QEMU machine, started under `MuonTrap` (docs/testing.md §2, §5).

  A spec is deterministic, so restarting it gives the same machine. The VM
  process owns QEMU, the serial console (`Kubex.E2E.Console`) and a QMP
  connection. QEMU is started paused (`-S`) and only resumed once the console
  is attached, so no early boot output is lost.

  Files live in the test directory (`console.log`, `qmp.log`, the UEFI vars).
  The QMP and console sockets live in a short private runtime directory
  instead: unix socket paths are limited to 108 bytes, and the harness
  connects to them too, so a relative path from QEMU's working directory is
  not enough.
  """
  use GenServer

  require Logger

  alias Kubex.E2E.Console

  @enforce_keys [:name, :boot]
  defstruct name: nil,
            uuid: nil,
            mac: nil,
            firmware: :bios,
            memory: 1024,
            disks: [],
            rtc: :host,
            boot: nil

  @type boot :: {:direct, Path.t(), [Kubex.E2E.Initrd.part()], String.t()} | :pxe
  @type disk :: {:virtio | :nvme, serial :: String.t(), file :: Path.t()}
  @type t :: %__MODULE__{
          name: String.t(),
          uuid: String.t() | nil,
          mac: String.t() | nil,
          firmware: :bios | :uefi,
          memory: pos_integer(),
          disks: [disk()],
          rtc: :host | {:skew, DateTime.t()},
          boot: boot()
        }

  @type paths :: %{
          dir: Path.t(),
          run_dir: Path.t(),
          ssh_port: :inet.port_number()
        }

  @ovmf_dir "/usr/share/OVMF"

  ## Spec → argv

  @doc """
  Fills in the derived fields: the UUID and the MAC come from the name, so a
  spec without them still describes the same machine on every run.
  """
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{} = spec) do
    digest = :crypto.hash(:sha256, "kubex-e2e:" <> spec.name)

    %{spec | uuid: spec.uuid || uuid_from(digest), mac: spec.mac || mac_from(digest)}
  end

  @doc "The QEMU argument list for a normalized spec."
  @spec argv(t(), paths()) :: [String.t()]
  def argv(%__MODULE__{} = spec, paths) do
    List.flatten([
      ["-name", spec.name],
      ["-machine", "q35,accel=kvm", "-cpu", "host", "-m", Integer.to_string(spec.memory)],
      ["-display", "none", "-monitor", "none", "-S"],
      ["-uuid", spec.uuid, "-smbios", "type=1,uuid=#{spec.uuid}"],
      firmware_args(spec.firmware, paths),
      rtc_args(spec.rtc),
      disk_args(spec.disks),
      net_args(spec, paths),
      boot_args(spec.boot, paths),
      ["-chardev", "socket,id=con,path=#{socket(paths, :console)},server=on,wait=off"],
      ["-serial", "chardev:con"],
      ["-qmp", "unix:#{socket(paths, :qmp)},server=on,wait=off"]
    ])
  end

  @doc false
  @spec socket(paths(), :console | :qmp) :: Path.t()
  def socket(paths, :console), do: Path.join(paths.run_dir, "con.sock")
  def socket(paths, :qmp), do: Path.join(paths.run_dir, "qmp.sock")

  defp firmware_args(:bios, _paths), do: []

  defp firmware_args(:uefi, paths) do
    ovmf = System.get_env("KUBEX_E2E_OVMF_DIR", @ovmf_dir)

    [
      ["-drive", "if=pflash,format=raw,readonly=on,file=#{Path.join(ovmf, "OVMF_CODE_4M.fd")}"],
      ["-drive", "if=pflash,format=raw,file=#{Path.join(paths.dir, "OVMF_VARS_4M.fd")}"]
    ]
  end

  defp rtc_args(:host), do: ["-rtc", "base=utc"]

  defp rtc_args({:skew, %DateTime{} = at}) do
    base = at |> DateTime.truncate(:second) |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    ["-rtc", "base=#{base}"]
  end

  defp disk_args(disks) do
    disks
    |> Enum.with_index()
    |> Enum.map(fn {{bus, serial, file}, i} ->
      id = "d#{i}"
      device = %{virtio: "virtio-blk-pci", nvme: "nvme"} |> Map.fetch!(bus)

      [
        ["-drive", "if=none,id=#{id},file=#{file},format=#{disk_format(file)}"],
        ["-device", "#{device},drive=#{id},serial=#{serial}"]
      ]
    end)
  end

  defp disk_format(file), do: if(Path.extname(file) == ".qcow2", do: "qcow2", else: "raw")

  defp net_args(spec, paths) do
    [
      ["-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:#{paths.ssh_port}-:22"],
      ["-device", "virtio-net-pci,netdev=n0,mac=#{spec.mac}"]
    ]
  end

  defp boot_args({:direct, kernel, initrds, cmdline}, paths),
    do: ["-kernel", kernel, "-initrd", initrd_path(initrds, paths), "-append", cmdline]

  defp boot_args(:pxe, _paths), do: raise(ArgumentError, "boot: :pxe arrives with phase 4")

  # QEMU's -initrd takes one file for a Linux kernel (docs/phase0.md), so
  # anything but a single plain file is assembled into the test directory.
  defp initrd_path([path], _paths) when is_binary(path), do: path
  defp initrd_path(_initrds, paths), do: Path.join(paths.dir, "initrd.img")

  defp uuid_from(<<a::32, b::16, _::4, c::12, _::2, d::14, e::48, _::binary>>) do
    # RFC 9562 version 8 (custom), so it never collides with a real v4 UUID.
    <<a::32, b::16, 8::4, c::12, 2::2, d::14, e::48>>
    |> Base.encode16(case: :lower)
    |> then(fn <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> ->
      Enum.join([p1, p2, p3, p4, p5], "-")
    end)
  end

  defp mac_from(<<_::binary-29, x, y, z>>) do
    [0x52, 0x54, 0x00, x, y, z]
    |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> String.downcase()
  end

  ## Process

  @doc """
  Starts the machine. Options:

    * `:spec` (required) - a `t:t/0`
    * `:dir` (required) - the test directory, created if missing
    * `:qemu` - the QEMU binary, default `qemu-system-x86_64`
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: {__MODULE__, opts[:spec].name}, start: {__MODULE__, :start_link, [opts]}}

  @doc "The normalized spec, the paths and the console pid."
  @spec info(GenServer.server()) :: %{spec: t(), paths: paths(), console: pid()}
  def info(vm), do: GenServer.call(vm, :info)

  @doc "Runs one QMP command and returns its `return` value."
  @spec qmp(GenServer.server(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def qmp(vm, command, arguments \\ %{}), do: GenServer.call(vm, {:qmp, command, arguments})

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    spec = opts |> Keyword.fetch!(:spec) |> normalize()
    dir = opts |> Keyword.fetch!(:dir) |> Path.expand()
    File.mkdir_p!(dir)

    paths = %{dir: dir, run_dir: make_run_dir(), ssh_port: free_port()}
    prepare_firmware(spec.firmware, paths)
    prepare_initrd(spec.boot, paths)

    args = argv(spec, paths)
    File.write!(Path.join(dir, "qemu.argv"), Enum.join(args, "\n") <> "\n")

    {:ok, qemu} =
      MuonTrap.Daemon.start_link(Keyword.get(opts, :qemu, "qemu-system-x86_64"), args,
        cd: dir,
        stderr_to_stdout: true,
        logger_fun: &log_qemu(spec.name, &1)
      )

    with {:ok, console} <-
           Console.start_link(socket(paths, :console), Path.join(dir, "console.log")),
         {:ok, qmp} <- qmp_connect(socket(paths, :qmp)),
         state = %{
           spec: spec,
           paths: paths,
           qemu: qemu,
           console: console,
           qmp: qmp,
           qmp_log: File.open!(Path.join(dir, "qmp.log"), [:append])
         },
         {:ok, _} <- qmp_command(state, "cont", %{}) do
      {:ok, state}
    else
      {:error, reason} ->
        GenServer.stop(qemu)
        File.rm_rf(paths.run_dir)
        {:stop, {:qemu_start_failed, reason, Path.join(dir, "qemu.argv")}}
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state),
    do: {:reply, %{spec: state.spec, paths: state.paths, console: state.console}, state}

  def handle_call({:qmp, command, arguments}, _from, state),
    do: {:reply, qmp_command(state, command, arguments), state}

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{qemu: pid} = state),
    do: {:stop, {:qemu_exited, reason}, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = qmp_command(state, "quit", %{})
    if Process.alive?(state.qemu), do: GenServer.stop(state.qemu)
    File.rm_rf(state.paths.run_dir)
  end

  defp make_run_dir() do
    base = System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!()
    dir = Path.join(base, "kbx-" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower))
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp free_port() do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp prepare_initrd({:direct, _kernel, [path], _cmdline}, _paths) when is_binary(path), do: :ok

  defp prepare_initrd({:direct, _kernel, initrds, _cmdline}, paths),
    do: Kubex.E2E.Initrd.assemble!(initrds, initrd_path(initrds, paths))

  defp prepare_initrd(:pxe, _paths), do: :ok

  defp prepare_firmware(:bios, _paths), do: :ok

  defp prepare_firmware(:uefi, paths) do
    vars = Path.join(paths.dir, "OVMF_VARS_4M.fd")
    ovmf = System.get_env("KUBEX_E2E_OVMF_DIR", @ovmf_dir)
    # Kept across restarts of the same machine, like real NVRAM.
    if not File.exists?(vars), do: File.cp!(Path.join(ovmf, "OVMF_VARS_4M.fd"), vars)
  end

  defp log_qemu(name, line), do: Logger.warning("qemu[#{name}]: #{String.trim_trailing(line)}")

  ## QMP

  defp qmp_connect(path) do
    with {:ok, socket} <- connect_unix(path, 5_000),
         {:ok, _greeting} <- :gen_tcp.recv(socket, 0, 5_000),
         :ok <- :gen_tcp.send(socket, JSON.encode!(%{execute: "qmp_capabilities"})),
         {:ok, _} <- :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, socket}
    end
  end

  defp qmp_command(state, command, arguments) do
    message =
      %{execute: command}
      |> then(&if(arguments == %{}, do: &1, else: Map.put(&1, :arguments, arguments)))

    with :ok <- :gen_tcp.send(state.qmp, JSON.encode!(message)) do
      qmp_reply(state)
    end
  end

  # Events arrive on the same socket, interleaved with replies: log them and
  # keep reading until the reply.
  defp qmp_reply(state) do
    case :gen_tcp.recv(state.qmp, 0, 10_000) do
      {:ok, line} ->
        IO.write(state.qmp_log, line)

        case JSON.decode!(line) do
          %{"return" => value} -> {:ok, value}
          %{"error" => error} -> {:error, error}
          %{"event" => _} -> qmp_reply(state)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # QEMU creates its sockets a few milliseconds after it starts.
  def connect_unix(path, timeout, opts \\ [packet: :line, active: false]) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_connect_unix(path, [:binary | opts], deadline)
  end

  defp do_connect_unix(path, opts, deadline) do
    case :gen_tcp.connect({:local, path}, 0, opts) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, {:connect, path, reason}}
        else
          Process.sleep(20)
          do_connect_unix(path, opts, deadline)
        end
    end
  end
end
