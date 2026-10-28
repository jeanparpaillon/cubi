defmodule Kubex.Storage.PoolTest do
  use ExUnit.Case, async: true

  alias Kubex.Storage.{Args, Pool}

  @moduletag :tmp_dir

  @key String.duplicate("ab", 32)

  # What the pool reports by default: on the disks kubex.vdevs names.
  @status [
    {~w(/usr/sbin/zpool status), {"\tmirror-0\n\t  /dev/vda ONLINE\n\t  /dev/vdb ONLINE\n", 0}}
  ]

  # A fake sysfs with two virtio disks, and a runner that answers from
  # `responses`, then @status (first matching prefix wins, default {"", 0}), and records
  # each call as {argv, stdin}.
  setup %{tmp_dir: dir} do
    for {disk, serial} <- [{"vda", "KBXD0"}, {"vdb", "KBXD1"}] do
      File.mkdir_p!(Path.join([dir, "sys/block", disk]))
      File.write!(Path.join([dir, "sys/block", disk, "serial"]), serial)
    end

    File.write!(Path.join(dir, "mounts"), "")
    {:ok, args} = Args.parse(Kubex.Cmdline.parse("kubex.vdevs=mirror,virtio-KBXD0,virtio-KBXD1"))
    %{args: args}
  end

  defp setup_pool(args, dir, responses, opts \\ []) do
    test = self()

    run = fn argv, input ->
      send(test, {:ran, argv, input})

      Enum.find_value(responses ++ @status, {"", 0}, fn {prefix, reply} ->
        List.starts_with?(argv, prefix) && reply
      end)
    end

    Pool.setup(
      args,
      [
        run: run,
        machine_id: "8a7e0f1c-0000-4000-8000-000000000001",
        sys: Path.join(dir, "sys"),
        mounts: Path.join(dir, "mounts"),
        mountpoint: Path.join(dir, "kubex")
      ] ++ opts
    )
  end

  defp ran() do
    receive do
      {:ran, [exe | args], input} -> [{[Path.basename(exe) | args], input} | ran()]
    after
      0 -> []
    end
  end

  defp commands(), do: for({argv, _} <- ran(), do: Enum.join(argv, " "))

  @not_found {"cannot import 'kubex': no such pool available\n", 1}
  @no_pool [{~w(/usr/sbin/zpool list), {"cannot open 'kubex': no such pool\n", 1}}]

  test "blank disks, create allowed: creates the pool, the tree and crypt", %{
    args: args,
    tmp_dir: dir
  } do
    args = %{args | create: true}
    hostid = Pool.hostid("8a7e0f1c-0000-4000-8000-000000000001")

    assert setup_pool(args, dir, @no_pool ++ [{~w(/usr/sbin/zpool import), @not_found}],
             key: @key
           ) ==
             {:ok, %{pool: "kubex", created: true, crypt: :mounted}}

    k = Path.join(dir, "kubex")

    assert commands() == [
             "modprobe spl spl_hostid=#{hostid}",
             "modprobe zfs",
             "zpool list -H -o name kubex",
             "zpool import -N -o cachefile=none -d /dev kubex",
             "wipefs --no-act --noheadings --output TYPE /dev/vda",
             "wipefs --no-act --noheadings --output TYPE /dev/vdb",
             "zpool create -o cachefile=none -O mountpoint=none kubex mirror /dev/vda /dev/vdb",
             "zfs list -H -o name -r kubex",
             "zfs create -o mountpoint=legacy -o compression=lz4 -o atime=off -o sync=standard -o refreservation=4G kubex/kubex",
             "zfs create kubex/kubex/identity",
             "mount.zfs kubex/kubex #{k}",
             "mount.zfs kubex/kubex/identity #{k}/identity",
             "zfs list -H -o name -r kubex",
             "zfs create -o encryption=aes-256-gcm -o keyformat=hex -o keylocation=prompt -o canmount=off -o kubex:testkey=on kubex/kubex/crypt",
             "zfs create kubex/kubex/crypt/khepri",
             "zfs create kubex/kubex/crypt/log",
             "mount.zfs kubex/kubex/crypt/khepri #{k}/khepri",
             "mount.zfs kubex/kubex/crypt/log #{k}/log"
           ]

    assert File.dir?(Path.join(k, "identity"))
  end

  test "the key goes on stdin, never in argv", %{args: args, tmp_dir: dir} do
    setup_pool(
      %{args | create: true},
      dir,
      @no_pool ++ [{~w(/usr/sbin/zpool import), @not_found}],
      key: @key
    )

    calls = ran()

    assert [{_, input}] = Enum.filter(calls, fn {_, input} -> input != nil end)
    assert input == @key <> "\n"
    refute Enum.any?(calls, fn {argv, _} -> Enum.any?(argv, &(&1 =~ @key)) end)
  end

  test "no pool and no kubex.zfs.create=1: refuses, writes nothing", %{args: args, tmp_dir: dir} do
    assert setup_pool(args, dir, @no_pool ++ [{~w(/usr/sbin/zpool import), @not_found}]) ==
             {:error, {:no_pool, "kubex"}}

    refute Enum.any?(commands(), &(&1 =~ ~r/^(wipefs|zpool create|zfs create)/))
  end

  test "a disk with a signature: refuses, creates nothing", %{args: args, tmp_dir: dir} do
    responses =
      @no_pool ++
        [
          {~w(/usr/sbin/zpool import), @not_found},
          {~w(/sbin/wipefs --no-act --noheadings --output TYPE /dev/vdb), {"PMBR\ngpt\n", 0}}
        ]

    assert setup_pool(%{args | create: true}, dir, responses) ==
             {:error, {:not_blank, [{"/dev/vdb", "PMBR"}, {"/dev/vdb", "gpt"}]}}

    refute Enum.any?(commands(), &(&1 =~ ~r/^(zpool create|zfs create)/))
  end

  test "an import that fails for another reason never creates", %{args: args, tmp_dir: dir} do
    foreign = {"cannot import 'kubex': pool was previously in use from another system.\n", 1}

    assert {:error, {:import, "kubex", _}} =
             setup_pool(
               %{args | create: true},
               dir,
               @no_pool ++ [{~w(/usr/sbin/zpool import), foreign}]
             )

    refute Enum.any?(commands(), &(&1 =~ ~r/^(wipefs|zpool create|zfs create)/))
  end

  test "an unknown disk name: refuses before touching ZFS beyond loading it", %{tmp_dir: dir} do
    {:ok, args} =
      Args.parse([{"kubex.vdevs", "mirror,virtio-KBXD0,virtio-NOPE"}, {"kubex.zfs.create", "1"}])

    assert {:error, {:unknown_device, "virtio-NOPE", _}} = setup_pool(args, dir, [])

    assert commands() == [
             "modprobe spl spl_hostid=#{Pool.hostid("8a7e0f1c-0000-4000-8000-000000000001")}",
             "modprobe zfs"
           ]
  end

  test "already imported and mounted (a BEAM restart): nothing to do", %{args: args, tmp_dir: dir} do
    k = Path.join(dir, "kubex")
    param = Path.join(dir, "sys/module/spl/parameters/spl_hostid")
    File.mkdir_p!(Path.dirname(param))
    File.write!(param, "#{Pool.hostid("8a7e0f1c-0000-4000-8000-000000000001")}\n")

    File.write!(Path.join(dir, "mounts"), """
    kubex/kubex #{k} zfs rw,noatime,xattr,noacl 0 0
    kubex/kubex/identity #{k}/identity zfs rw,noatime,xattr,noacl 0 0
    kubex/kubex/crypt/khepri #{k}/khepri zfs rw,noatime,xattr,noacl 0 0
    kubex/kubex/crypt/log #{k}/log zfs rw,noatime,xattr,noacl 0 0
    """)

    datasets =
      ~w(kubex kubex/kubex kubex/kubex/identity kubex/kubex/crypt kubex/kubex/crypt/khepri kubex/kubex/crypt/log)

    responses = [
      {~w(/usr/sbin/zfs list), {Enum.join(datasets, "\n") <> "\n", 0}},
      {~w(/usr/sbin/zfs get), {"available\n", 0}}
    ]

    assert setup_pool(args, dir, responses, key: @key) ==
             {:ok, %{pool: "kubex", created: false, crypt: :mounted}}

    assert commands() == [
             "modprobe zfs",
             "zpool list -H -o name kubex",
             "zpool status -P kubex",
             "zfs list -H -o name -r kubex",
             "zfs list -H -o name -r kubex",
             "zfs get -H -o value keystatus kubex/kubex/crypt"
           ]
  end

  test "spl loaded with another host ID is refused", %{args: args, tmp_dir: dir} do
    param = Path.join(dir, "sys/module/spl/parameters/spl_hostid")
    File.mkdir_p!(Path.dirname(param))
    File.write!(param, "0\n")

    assert setup_pool(args, dir, []) == {:error, {:spl_hostid, "0"}}
  end

  test "imported, crypt there: locked without a key, unlocked on stdin with one", %{
    args: args,
    tmp_dir: dir
  } do
    datasets = ~w(kubex kubex/kubex kubex/kubex/identity kubex/kubex/crypt)

    responses =
      [
        {~w(/usr/sbin/zpool import), {"", 0}},
        {~w(/usr/sbin/zfs list), {Enum.join(datasets, "\n"), 0}},
        {~w(/usr/sbin/zfs get), {"unavailable\n", 0}}
      ] ++ @no_pool

    assert {:ok, %{created: false, crypt: :locked}} = setup_pool(args, dir, responses)
    _ = ran()

    assert {:ok, %{crypt: :mounted}} = setup_pool(args, dir, responses, key: @key)
    assert {["zfs", "load-key", "-L", "prompt", "kubex/kubex/crypt"], @key <> "\n"} in ran()
  end

  test "a pool on other disks than kubex.vdevs is logged, not refused", %{
    args: args,
    tmp_dir: dir
  } do
    # zpool shows partitions; sysfs links each to its disk.
    for {disk, part} <- [{"vda", "vda1"}, {"vdc", "vdc1"}] do
      File.mkdir_p!(Path.join([dir, "sys/devices/pci0/block", disk, part]))
      File.write!(Path.join([dir, "sys/devices/pci0/block", disk, part, "partition"]), "1\n")
      File.mkdir_p!(Path.join(dir, "sys/class/block"))

      File.ln_s!(
        "../../devices/pci0/block/#{disk}/#{part}",
        Path.join([dir, "sys/class/block", part])
      )
    end

    responses = [
      {~w(/usr/sbin/zpool status),
       {"\tmirror-0\n\t  /dev/vda1 ONLINE\n\t  /dev/vdc1 ONLINE\n", 0}}
    ]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{created: false, crypt: :absent}} = setup_pool(args, dir, responses)
      end)

    assert log =~ "pool kubex is on vda vdc, kubex.vdevs names vda vdb"
  end

  test "hostid is 32 bits and never 0" do
    for id <- ["a", "b", "8a7e0f1c-0000-4000-8000-000000000001"] do
      h = Pool.hostid(id)
      assert h > 0 and h < 0x1_0000_0000
    end
  end
end
