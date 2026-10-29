defmodule Cubi.Tools.BootScript do
  @moduledoc """
  Renders the private iPXE script that makes a node of a public image the
  operator's (docs/specs.md §2.12.2):

      #!ipxe
      set base https://…/cubi/<version>
      kernel ${base}/vmlinuz console=ttyS0 cubi.rootfs=sha256:<hex> cubi.ca=sha256:<hex> cubi.ssh=<type>:<base64>
      initrd ${base}/stage1.cpio.zst
      initrd ${base}/rootfs.squashfs /rootfs.squashfs
      boot

    * `cubi.rootfs=` is the image's own `rootfs.squashfs` entry in
      `SHA256SUMS`, read with `Cubi.Tools.Image`: over HTTPS from the image's
      URL, or from a local copy of the same directory (`:local`).
    * `cubi.ca=` is the SHA-256 of the operator's root certificate
      (`Cubi.Pki.cert_sha256/1`).
    * `cubi.ssh=` is one authorized key per argument, its comment dropped.

  **Nothing in it is secret**, but it is the node's trust anchor: hand it to
  the provider's API, never put it at a public URL.

  Refused: a script without ssh keys unless `no_ssh: true` (the node would
  accept no login, and so no deploy), and a cmdline that does not fit the
  kernel's 2048-byte `COMMAND_LINE_SIZE`. The kernel truncates silently, so
  the count is pessimistic: the image name iPXE puts in front under UEFI
  (`vmlinuz `, docs/phase0.md), the cmdline, and the terminating NUL.
  """

  @command_line_size 2048
  @uefi_prefix "vmlinuz "

  @doc """
  The script. Options:

    * `:image` (required) - the image directory's URL, written into the
      script
    * `:local` - the same image in a local directory, or another URL, to read
      `SHA256SUMS` from; default `:image`. Lets a script name a local server
      (`http://10.0.2.2:<port>`, which `Cubi.Tools.Image` would not fetch)
    * `:ca` (required) - the operator's root certificate, PEM
    * `:ssh_keys` - `authorized_keys` lines
    * `:no_ssh` - allow a script with no ssh key
    * `:cmdline` - kernel arguments before cubi's, default `"console=ttyS0"`
    * `:get` - passed to `Cubi.Tools.Image`
  """
  @spec render(keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(opts) do
    image = opts |> Keyword.fetch!(:image) |> String.trim_trailing("/")
    keys = Keyword.get(opts, :ssh_keys, [])

    with :ok <- check_ssh(keys, Keyword.get(opts, :no_ssh, false)),
         {:ok, ssh_args} <- ssh_args(keys),
         {:ok, rootfs} <- rootfs_sha256(Keyword.get(opts, :local, image), opts),
         {:ok, ca} <- ca_sha256(Keyword.fetch!(opts, :ca)),
         cmdline =
           Enum.join(
             [
               Keyword.get(opts, :cmdline, "console=ttyS0"),
               "cubi.rootfs=sha256:" <> rootfs,
               "cubi.ca=sha256:" <> ca | ssh_args
             ],
             " "
           ),
         :ok <- check_size(cmdline) do
      {:ok,
       """
       #!ipxe
       set base #{image}
       kernel ${base}/vmlinuz #{cmdline}
       initrd ${base}/stage1.cpio.zst
       initrd ${base}/rootfs.squashfs /rootfs.squashfs
       boot
       """}
    end
  end

  @doc """
  `type:base64` for an `authorized_keys` line, its comment dropped: the form
  `cubi.ssh=` takes, with no space for the cmdline to split on.
  """
  @spec ssh_arg(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ssh_arg(line) do
    case String.split(line) do
      [type, key | _comment] ->
        if type =~ ~r/\A[a-z0-9@.-]+\z/ and key =~ ~r/\A[A-Za-z0-9+\/]+={0,2}\z/,
          do: {:ok, "cubi.ssh=#{type}:#{key}"},
          else: {:error, {:bad_ssh_key, line}}

      _ ->
        {:error, {:bad_ssh_key, line}}
    end
  end

  @doc "How many bytes of the kernel's buffer `cmdline` takes, counted as `render/1` does."
  @spec cmdline_bytes(String.t()) :: non_neg_integer()
  def cmdline_bytes(cmdline), do: byte_size(@uefi_prefix) + byte_size(cmdline) + 1

  defp check_ssh([], false), do: {:error, :no_ssh_keys}
  defp check_ssh([_ | _], true), do: {:error, :ssh_keys_with_no_ssh}
  defp check_ssh(_keys, _no_ssh), do: :ok

  defp ssh_args(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn line, {:ok, acc} ->
      case ssh_arg(line) do
        {:ok, arg} -> {:cont, {:ok, acc ++ [arg]}}
        error -> {:halt, error}
      end
    end)
  end

  defp rootfs_sha256(source, opts) do
    with {:ok, sums} <- Cubi.Tools.Image.sums(source, Keyword.take(opts, [:get])) do
      case Map.fetch(sums, "rootfs.squashfs") do
        {:ok, hex} -> {:ok, hex}
        :error -> {:error, {:not_in_sha256sums, "rootfs.squashfs"}}
      end
    end
  end

  defp ca_sha256(pem) do
    case Cubi.Pki.cert_sha256(pem) do
      {:ok, hex} -> {:ok, hex}
      {:error, _} -> {:error, :bad_ca_certificate}
    end
  end

  defp check_size(cmdline) do
    case cmdline_bytes(cmdline) do
      n when n <= @command_line_size -> :ok
      n -> {:error, {:cmdline_too_long, n, @command_line_size}}
    end
  end
end
