defmodule Cubi.Tools.Image do
  @moduledoc """
  A served image directory (docs/specs.md §2.3), local or published at an
  `https://` URL (§2.12.1): what `mix cubi.release --base` reads `base.json`
  from.

  A URL's files are fetched with `:httpc`, the server certificate verified
  against the system's CA store, redirects followed. Plain `http://` is
  refused: HTTPS to the publisher is the only thing vouching for a public
  image's files (§2.12.2), and `SHA256SUMS` fetched from an unauthenticated
  server would prove nothing. `base.json` is then checked against
  `SHA256SUMS`, so a truncated or mismatched file is never used.

  A local directory is read as is, as in milestone 1.

  Options of every function: `:get`, a `(url -> {:ok, binary} | {:error,
  term})` that replaces the HTTPS client, for tests.
  """

  @type source :: String.t()

  @doc "Whether `source` is a URL rather than a local directory."
  @spec url?(source()) :: boolean()
  def url?(source), do: String.contains?(source, "://")

  @doc "The decoded `base.json`; for a URL, checked against `SHA256SUMS`."
  @spec base(source(), keyword()) :: {:ok, map()} | {:error, term()}
  def base(source, opts \\ []) do
    with {:ok, data} <- fetch(source, "base.json", opts),
         :ok <- check_sum(source, "base.json", data, opts) do
      case JSON.decode(data) do
        {:ok, %{} = base} -> {:ok, base}
        _ -> {:error, {:bad_base_json, location(source, "base.json")}}
      end
    end
  end

  @doc "`SHA256SUMS`, as `%{name => lowercase hex}`."
  @spec sums(source(), keyword()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def sums(source, opts \\ []) do
    with {:ok, data} <- fetch(source, "SHA256SUMS", opts) do
      parse_sums(data)
    end
  end

  @doc """
  Parses `SHA256SUMS`: `<hex>  <name>` per line, as `sha256sum` writes it
  (a `*` before the name, binary mode, is accepted).
  """
  @spec parse_sums(binary()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def parse_sums(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case Regex.run(~r/\A([0-9a-fA-F]{64}) [ *](.+)\z/, line) do
        [_, hex, name] -> {:cont, {:ok, Map.put(acc, name, String.downcase(hex))}}
        nil -> {:halt, {:error, {:bad_sha256sums, line}}}
      end
    end)
  end

  @doc "One file of the directory, by name."
  @spec fetch(source(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch(source, name, opts \\ []) do
    cond do
      String.starts_with?(source, "https://") ->
        get = Keyword.get(opts, :get, &https_get/1)

        case get.(location(source, name)) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:fetch_failed, location(source, name), reason}}
        end

      url?(source) ->
        {:error, {:not_https, source}}

      true ->
        path = Path.join(source, name)

        case File.read(path) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:fetch_failed, path, reason}}
        end
    end
  end

  # Local directories are trusted as they are; URLs are checked.
  defp check_sum(source, name, data, opts) do
    if url?(source) do
      with {:ok, sums} <- sums(source, opts) do
        actual = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

        case Map.fetch(sums, name) do
          {:ok, ^actual} -> :ok
          {:ok, listed} -> {:error, {:sha256_mismatch, name, listed: listed, actual: actual}}
          :error -> {:error, {:not_in_sha256sums, name}}
        end
      end
    else
      :ok
    end
  end

  defp location(source, name), do: String.trim_trailing(source, "/") <> "/" <> name

  @doc false
  # A GET with the server's certificate checked against the system's CAs.
  def https_get(url) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    request = {String.to_charlist(url), [{~c"user-agent", ~c"cubi_tools"}]}

    case request(request, ssl) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # :httpc raises on some connection failures (a reset during the
  # handshake), rather than returning an error.
  defp request(request, ssl) do
    :httpc.request(:get, request, [ssl: ssl, timeout: 60_000, autoredirect: true],
      body_format: :binary
    )
  rescue
    e -> {:error, {:request_crashed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:request_crashed, reason}}
  end
end
