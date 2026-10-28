defmodule Cubi.Storage.ArgsTest do
  use ExUnit.Case, async: true

  alias Cubi.Storage.Args

  defp parse(cmdline), do: cmdline |> Cubi.Cmdline.parse() |> Args.parse()

  test "no cubi.vdevs: a diskless node" do
    assert parse("console=ttyS0") == {:ok, %Args{vdevs: nil, pool: "cubi", create: false}}
  end

  test "a mirror, a named pool, create allowed" do
    assert parse("cubi.vdevs=mirror,virtio-A,virtio-B cubi.zpool=tank cubi.zfs.create=1") ==
             {:ok,
              %Args{
                vdevs: [keyword: "mirror", device: "virtio-A", device: "virtio-B"],
                pool: "tank",
                create: true
              }}
  end

  test "classes, groups and dRAID are keywords" do
    assert {:ok, %Args{vdevs: vdevs}} =
             parse("cubi.vdevs=draid2:4d:1s,a,b,c,d,e,f,g,log,mirror,h,i,cache,j,spare,k")

    assert for({:keyword, k} <- vdevs, do: k) ==
             ~w(draid2:4d:1s log mirror cache spare)
  end

  test "cubi.zfs.create takes 1 or 0 only" do
    assert {:ok, %Args{create: false}} = parse("cubi.vdevs=a cubi.zfs.create=0")
    assert parse("cubi.vdevs=a cubi.zfs.create=yes") == {:error, {:create, "yes"}}
    assert parse("cubi.vdevs=a cubi.zfs.create") == {:error, {:create, nil}}
  end

  test "an argument given twice is refused" do
    assert parse("cubi.vdevs=a cubi.vdevs=b") == {:error, {:duplicate, "cubi.vdevs"}}

    assert parse("cubi.vdevs=a cubi.zfs.create=0 cubi.zfs.create=1") ==
             {:error, {:duplicate, "cubi.zfs.create"}}
  end

  test "malformed vdevs are refused" do
    for {spec, reason} <- [
          {"", :empty_name},
          {"mirror,a,,b", :empty_name},
          {"mirror,a,b,", :empty_name},
          {"mirror,log", :no_device},
          {"mirror,a,a", {:duplicate_device, "a"}},
          {"mirror,a,b,log", {:dangling_keyword, "log"}},
          {"mirror,raidz,a,b", {:dangling_keyword, "mirror"}},
          {"log,cache,a", {:dangling_keyword, "log"}}
        ] do
      assert parse("cubi.vdevs=#{spec}") == {:error, {:vdevs, reason, spec}}
    end

    assert parse("cubi.vdevs") == {:error, {:vdevs, :empty_name, nil}}
  end

  test "pool names follow zpool's rules" do
    for name <- ~w(1pool p/ool -p),
        do:
          assert({:error, {:zpool, :invalid, ^name}} = parse("cubi.vdevs=a cubi.zpool=#{name}"))

    for name <- ~w(mirror log raidz2x draidz c0d0),
        do:
          assert(
            {:error, {:zpool, :reserved, ^name}} = parse("cubi.vdevs=a cubi.zpool=#{name}")
          )

    assert {:error, {:zpool, :invalid, nil}} = parse("cubi.vdevs=a cubi.zpool")

    assert {:ok, %Args{pool: "k8s_pool.1:a-b"}} =
             parse("cubi.vdevs=a cubi.zpool=k8s_pool.1:a-b")
  end
end
