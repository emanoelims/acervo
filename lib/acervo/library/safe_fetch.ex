defmodule Acervo.Library.SafeFetch do
  @moduledoc """
  The only gateway for outbound HTTP in the capture pipeline.

  Users paste arbitrary URLs, so every request is guarded against SSRF:

    * only `http`/`https` on ports 80 and 443, without userinfo;
    * the host is resolved through `Acervo.Library.Resolver` and the request is
      refused if *any* address is private, loopback, link-local, multicast or
      otherwise internal (see `blocked_ip?/1`);
    * the connection is pinned to the vetted address: Req is given a URL whose
      host is the IP literal, while `connect_options: [hostname: host]` makes
      Mint use the real host for TLS SNI and certificate verification, and the
      `host` header carries it to the server. DNS is never consulted again, so
      a rebinding answer cannot redirect the connection;
    * redirects are followed by hand, re-running every check on each hop;
    * the body is streamed and abandoned past `:max_bytes`, and every hop has
      connect, receive and overall timeouts.

  Req starts one Finch instance per distinct set of connect options, and the
  instance name hashes `hostname`, so a pinned connection is only ever reused
  for the same host name, IP and port (Finch keys its pools by scheme, IP and
  port within an instance).
  """

  import Bitwise

  alias Acervo.Library.Resolver

  @default_user_agent "Mozilla/5.0 (compatible; AcervoBot/1.0; +https://acervo-app.fly.dev)"
  @allowed_ports [80, 443]
  @redirect_statuses [301, 302, 303, 307, 308]
  @connect_timeout 10_000
  @receive_timeout 10_000
  @request_timeout 30_000

  # {network, prefix length}
  @blocked_ipv4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4},
    {{255, 255, 255, 255}, 32}
  ]

  @blocked_ipv6 [
    # ::/96 covers :: and ::1 plus the deprecated IPv4-compatible block
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8},
    # NAT64 local-use prefix, which may translate to any internal IPv4
    {{0x64, 0xFF9B, 0x1, 0, 0, 0, 0, 0}, 48}
  ]

  @type response :: %{status: integer(), headers: map(), body: binary(), url: String.t()}
  @type reason ::
          :invalid_url
          | :blocked_address
          | :bad_port
          | :too_many_redirects
          | :too_large
          | :timeout
          | {:http, integer()}
          | {:transport, term()}

  @doc """
  Fetches `url` with GET, following redirects, and returns the final 2xx response.

  ## Options

    * `:max_bytes` - largest body accepted, default `3_000_000`
    * `:accept` - value of the `accept` header, omitted by default
    * `:user_agent` - value of the `user-agent` header
    * `:max_redirects` - redirects to follow before giving up, default `5`
  """
  @spec get(String.t(), keyword()) :: {:ok, response()} | {:error, reason()}
  def get(url, opts \\ []) when is_binary(url) do
    opts =
      Keyword.validate!(opts,
        max_bytes: 3_000_000,
        accept: nil,
        user_agent: @default_user_agent,
        max_redirects: 5
      )

    with {:ok, uri} <- parse(url) do
      follow(uri, opts, opts[:max_redirects])
    end
  end

  @doc """
  Returns whether `ip` is in a range the server must never reach.

  IPv4-mapped (`::ffff:a.b.c.d`), NAT64 (`64:ff9b::a.b.c.d`) and 6to4
  (`2002:AABB:CCDD::`) IPv6 addresses are judged by the IPv4 address they embed.
  """
  @spec blocked_ip?(:inet.ip_address()) :: boolean()
  def blocked_ip?({_, _, _, _} = ip) do
    value = ip_to_integer(ip)
    Enum.any?(@blocked_ipv4, fn {network, bits} -> in_network?(value, ip_to_integer(network), bits, 32) end)
  end

  def blocked_ip?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: blocked_ip?(embedded_ipv4(high, low))
  def blocked_ip?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: blocked_ip?(embedded_ipv4(high, low))
  def blocked_ip?({0x2002, high, low, _, _, _, _, _}), do: blocked_ip?(embedded_ipv4(high, low))

  def blocked_ip?({_, _, _, _, _, _, _, _} = ip) do
    value = ip_to_integer(ip)
    Enum.any?(@blocked_ipv6, fn {network, bits} -> in_network?(value, ip_to_integer(network), bits, 128) end)
  end

  ## Redirects

  defp follow(uri, opts, redirects_left) do
    with {:ok, ip} <- vet_host(uri.host),
         {:ok, response} <- request(uri, ip, opts) do
      handle_response(response, uri, opts, redirects_left)
    end
  end

  defp handle_response(%Req.Response{status: status} = response, uri, opts, redirects_left)
       when status in @redirect_statuses do
    case Req.Response.get_header(response, "location") do
      [_ | _] when redirects_left <= 0 ->
        {:error, :too_many_redirects}

      [location | _] ->
        with {:ok, next} <- resolve_location(uri, location) do
          follow(next, opts, redirects_left - 1)
        end

      [] ->
        {:error, {:http, status}}
    end
  end

  defp handle_response(%Req.Response{status: status} = response, uri, _opts, _redirects_left) when status in 200..299 do
    {:ok, %{status: status, headers: response.headers, body: response.body, url: URI.to_string(uri)}}
  end

  defp handle_response(%Req.Response{status: status}, _uri, _opts, _redirects_left) do
    {:error, {:http, status}}
  end

  defp resolve_location(base, location) do
    case URI.new(location) do
      {:ok, relative} -> base |> URI.merge(relative) |> validate()
      {:error, _} -> {:error, :invalid_url}
    end
  end

  ## URL and address checks

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> validate(uri)
      {:error, _} -> {:error, :invalid_url}
    end
  end

  defp validate(%URI{scheme: scheme, host: host, userinfo: nil, port: port} = uri)
       when scheme in ["http", "https"] and is_binary(host) and host != "" do
    if port in @allowed_ports, do: {:ok, %{uri | fragment: nil}}, else: {:error, :bad_port}
  end

  defp validate(%URI{}), do: {:error, :invalid_url}

  defp vet_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> vet_addresses([ip])
      {:error, _} -> host |> Resolver.resolve() |> vet_resolved()
    end
  end

  defp vet_resolved({:ok, [_ | _] = addresses}), do: vet_addresses(addresses)
  defp vet_resolved({:ok, []}), do: {:error, {:transport, :nxdomain}}
  defp vet_resolved({:error, reason}), do: {:error, {:transport, reason}}

  defp vet_addresses([first | _] = addresses) do
    if Enum.any?(addresses, &blocked_ip?/1), do: {:error, :blocked_address}, else: {:ok, first}
  end

  ## Request

  defp request(uri, ip, opts) do
    max_bytes = opts[:max_bytes]
    pinned_url = URI.to_string(%{uri | host: ip |> :inet.ntoa() |> to_string()})

    req_options =
      Keyword.merge(
        [
          method: :get,
          url: pinned_url,
          headers: request_headers(uri, opts),
          connect_options: [hostname: uri.host, timeout: @connect_timeout],
          receive_timeout: @receive_timeout,
          request_timeout: @request_timeout,
          redirect: false,
          retry: false,
          decode_body: false,
          into: &collect(&1, &2, max_bytes)
        ],
        Application.get_env(:acervo, :safe_fetch_req_options, [])
      )

    case Req.request(req_options) do
      {:ok, response} -> check_size(response, max_bytes)
      {:error, %{reason: :timeout}} -> {:error, :timeout}
      {:error, %{reason: reason}} -> {:error, {:transport, reason}}
      {:error, error} -> {:error, {:transport, error}}
    end
  end

  defp request_headers(uri, opts) do
    accept = if opts[:accept], do: [{"accept", opts[:accept]}], else: []
    [{"host", host_header(uri)}, {"user-agent", opts[:user_agent]} | accept]
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp collect({:data, chunk}, {request, response}, max_bytes) do
    if byte_size(response.body) + byte_size(chunk) > max_bytes or declared_too_large?(response, max_bytes) do
      {:halt, {request, Req.Response.put_private(response, :safe_fetch_too_large, true)}}
    else
      {:cont, {request, %{response | body: response.body <> chunk}}}
    end
  end

  defp check_size(response, max_bytes) do
    if Req.Response.get_private(response, :safe_fetch_too_large) || declared_too_large?(response, max_bytes) do
      {:error, :too_large}
    else
      {:ok, response}
    end
  end

  defp declared_too_large?(response, max_bytes) do
    with [value | _] <- Req.Response.get_header(response, "content-length"),
         {length, ""} <- Integer.parse(String.trim(value)) do
      length > max_bytes
    else
      _ -> false
    end
  end

  ## Bit helpers

  defp ip_to_integer({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp ip_to_integer({_, _, _, _, _, _, _, _} = ip) do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn segment, acc -> acc <<< 16 ||| segment end)
  end

  defp in_network?(value, network, bits, width) do
    shift = width - bits
    value >>> shift == network >>> shift
  end

  defp embedded_ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}
end
