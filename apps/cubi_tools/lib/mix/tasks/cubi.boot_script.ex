defmodule Mix.Tasks.Cubi.BootScript do
  @shortdoc "Renders the private iPXE script for a public cubi image"
  @moduledoc """
  Prints the iPXE script that boots a public cubi image as one of your nodes
  (docs/specs.md §2.12.2, `Cubi.Tools.BootScript`):

      mix cubi.boot_script [--image VERSION|URL] [--local DIR] [--ca DIR]
                           [--ssh FILE]… [--no-ssh] [--cmdline ARGS] [--output FILE]

    * `--image` - a published image: its URL, or a version found under
      `config :cubi_tools, :image_base`. Default: the version of
      `cubi_tools` itself
    * `--local DIR` - the same image in a local directory (`mix
      firmware.ipxe --public`): the pins are read from it, and `--image` may
      then name a local server, such as `http://10.0.2.2:<port>` for a QEMU
      node
    * `--ca DIR` - the PKI directory whose root the node trusts for releases
      (`mix cubi.gen_ca`); default `CUBI_PKI_DIR`, else `~/.cubi/pki`
    * `--ssh FILE` - a public key allowed to log in, repeatable; default
      `~/.ssh/id_*.pub`
    * `--no-ssh` - a node nobody can log into, and so deploy to
    * `--cmdline ARGS` - kernel arguments before cubi's, default
      `console=ttyS0`
    * `--output FILE` - write the script there rather than on stdout, where
      Mix and Nerves may print banners of their own

  Exits non-zero, printing nothing on stdout, when it cannot render the
  script: no CA, no ssh key without `--no-ssh`, a rootfs missing from
  `SHA256SUMS`, or a cmdline over the kernel's 2048 bytes.

  The script holds no secret, but whoever writes it decides what the node
  runs and who logs in: give it to your provider's API, never publish it.
  """
  use Mix.Task

  alias Cubi.Tools.BootScript

  @switches [
    image: :string,
    local: :string,
    ca: :string,
    ssh: :keep,
    no_ssh: :boolean,
    cmdline: :string,
    output: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    render_opts =
      [
        image: image!(opts[:image]),
        ca: ca!(opts[:ca]),
        ssh_keys: ssh_keys!(Keyword.get_values(opts, :ssh), opts[:no_ssh] || false),
        no_ssh: opts[:no_ssh] || false,
        cmdline: opts[:cmdline] || "console=ttyS0"
      ] ++ if(opts[:local], do: [local: opts[:local]], else: [])

    case BootScript.render(render_opts) do
      {:ok, script} ->
        if output = opts[:output] do
          File.write!(output, script)
          File.chmod!(output, 0o600)
        else
          IO.write(script)
        end

      {:error, reason} ->
        Mix.raise("cannot render the boot script: #{message(reason)}")
    end
  end

  @doc false
  # A URL as is; a version under config :cubi_tools, :image_base.
  def image!(nil), do: image!(Application.spec(:cubi_tools, :vsn) |> to_string())

  def image!(image) do
    cond do
      String.contains?(image, "://") ->
        image

      base = Application.get_env(:cubi_tools, :image_base) ->
        String.trim_trailing(base, "/") <> "/" <> image

      true ->
        Mix.raise(
          "--image #{image} is a version, and config :cubi_tools, :image_base is not set: " <>
            "give the image's URL"
        )
    end
  end

  defp ca!(dir) do
    path = Cubi.Pki.paths(Cubi.Pki.dir(dir)).ca_cert

    case File.read(path) do
      {:ok, pem} -> pem
      {:error, _} -> Mix.raise("no #{path}: --ca names a directory from `mix cubi.gen_ca`")
    end
  end

  defp ssh_keys!([], true), do: []

  defp ssh_keys!(_files, true),
    do: Mix.raise("cannot render the boot script: --ssh and --no-ssh together")

  defp ssh_keys!([], false) do
    System.user_home!()
    |> Path.join(".ssh/id_*.pub")
    |> Path.wildcard()
    |> Enum.sort()
    |> ssh_keys!(false)
  end

  defp ssh_keys!(files, false) do
    for file <- files, line <- read_keys!(file), do: line
  end

  defp read_keys!(file) do
    case File.read(file) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.reject(&(&1 =~ ~r/^\s*#/))
      {:error, _} -> Mix.raise("no #{file}")
    end
  end

  defp message(:no_ssh_keys),
    do:
      "no ssh public key (--ssh FILE, or ~/.ssh/id_*.pub): the node would accept no login; --no-ssh if that is what you want"

  defp message(:ssh_keys_with_no_ssh), do: "--ssh and --no-ssh together"

  defp message({:cmdline_too_long, n, max}),
    do:
      "the kernel cmdline would take #{n} bytes, over its #{max}: fewer --ssh keys, or shorter ones (ed25519)"

  defp message({:not_https, url}),
    do: "#{url} is not https://: give --local DIR, the same image on disk, to read its pins from"

  defp message(reason), do: inspect(reason)
end
