defmodule Acervo.Library.SafeFetchTest do
  # The static hosts used here come from `config/test.exs`, so no test mutates
  # the application environment and the module can run async.
  use ExUnit.Case, async: true

  alias Acervo.Library.SafeFetch

  setup {Req.Test, :verify_on_exit!}

  describe "blocked_ip?/1" do
    test "blocks an address inside every private or internal range" do
      blocked = [
        {0, 1, 2, 3},
        {10, 0, 0, 5},
        {100, 64, 0, 1},
        {100, 127, 255, 254},
        {127, 0, 0, 1},
        {169, 254, 169, 254},
        {172, 16, 0, 1},
        {172, 31, 255, 254},
        {192, 0, 0, 8},
        {192, 168, 1, 1},
        {198, 18, 0, 1},
        {198, 19, 255, 254},
        {224, 0, 0, 1},
        {239, 255, 255, 250},
        {240, 0, 0, 1},
        {255, 255, 255, 255},
        {0, 0, 0, 0, 0, 0, 0, 0},
        {0, 0, 0, 0, 0, 0, 0, 1},
        {0xFC00, 0, 0, 0, 0, 0, 0, 1},
        {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1},
        {0xFE80, 0, 0, 0, 0, 0, 0, 1},
        {0xFEBF, 0, 0, 0, 0, 0, 0, 1},
        {0xFF02, 0, 0, 0, 0, 0, 0, 1},
        # ::ffff:127.0.0.1 and ::ffff:10.0.0.5, IPv4-mapped
        {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
        {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0005},
        # ::127.0.0.1, IPv4-compatible (deprecated)
        {0, 0, 0, 0, 0, 0, 0x7F00, 0x0001},
        # 64:ff9b::10.0.0.5, NAT64
        {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0005},
        # 2002:7f00:0001::, 6to4 wrapping 127.0.0.1
        {0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 1},
        # ::ffff:0:127.0.0.1, SIIT (0:0:0:0:ffff:0::/96)
        {0, 0, 0, 0, 0xFFFF, 0, 0x7F00, 0x0001},
        # 2001:0::, Teredo, blocked outright
        {0x2001, 0, 0x4136, 0xE378, 0x8000, 0x63BF, 0x3FFF, 0xFDD2},
        # 100::/64, discard-only
        {0x100, 0, 0, 0, 0, 0, 0, 1},
        # fec0::/10, deprecated site-local
        {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
        {0xFEFF, 0, 0, 0, 0, 0, 0, 1}
      ]

      for ip <- blocked do
        assert SafeFetch.blocked_ip?(ip), "expected #{inspect(ip)} to be blocked"
      end
    end

    test "allows public addresses" do
      allowed = [
        {8, 8, 8, 8},
        {93, 184, 216, 34},
        {100, 63, 255, 255},
        {100, 128, 0, 0},
        {172, 15, 255, 255},
        {172, 32, 0, 0},
        {198, 17, 255, 255},
        {223, 255, 255, 255},
        {0x2001, 0x4860, 0, 0, 0, 0, 0, 0x8888},
        {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808},
        {0, 0, 0, 0, 0xFFFF, 0, 0x0808, 0x0808},
        {0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808},
        {0x2001, 0x0DB9, 0, 0, 0, 0, 0, 1},
        {0x100, 0, 0, 1, 0, 0, 0, 1}
      ]

      for ip <- allowed do
        refute SafeFetch.blocked_ip?(ip), "expected #{inspect(ip)} to be allowed"
      end
    end
  end

  describe "get/2 address checks" do
    test "blocks a host that resolves to a private address without sending a request" do
      stub_and_report()

      assert {:error, :blocked_address} = SafeFetch.get("https://internal.test/")
      refute_received {:request, _conn}
    end

    test "blocks a host when any of its addresses is private" do
      stub_and_report()

      assert {:error, :blocked_address} = SafeFetch.get("https://mixed.test/")
      refute_received {:request, _conn}
    end

    test "blocks IP literals in private ranges" do
      stub_and_report()

      assert {:error, :blocked_address} = SafeFetch.get("http://127.0.0.1/")
      assert {:error, :blocked_address} = SafeFetch.get("http://[::1]/")
      assert {:error, :blocked_address} = SafeFetch.get("http://[::ffff:10.0.0.5]/")
      assert {:error, :blocked_address} = SafeFetch.get("http://169.254.169.254/latest/meta-data")
      refute_received {:request, _conn}
    end

    test "fails when the host does not resolve" do
      stub_and_report()

      assert {:error, {:transport, :nxdomain}} = SafeFetch.get("https://missing.test/")
      refute_received {:request, _conn}
    end
  end

  describe "get/2 URL checks" do
    test "rejects ports other than 80 and 443" do
      stub_and_report()

      assert {:error, :bad_port} = SafeFetch.get("https://public.test:8080/")
      assert {:error, :bad_port} = SafeFetch.get("http://public.test:22/")
      refute_received {:request, _conn}
    end

    test "rejects non-http schemes, userinfo and malformed URLs" do
      stub_and_report()

      assert {:error, :invalid_url} = SafeFetch.get("ftp://public.test")
      assert {:error, :invalid_url} = SafeFetch.get("file:///etc/passwd")
      assert {:error, :invalid_url} = SafeFetch.get("https://user:pw@public.test/")
      assert {:error, :invalid_url} = SafeFetch.get("https:///nohost")
      assert {:error, :invalid_url} = SafeFetch.get("not a url")
      refute_received {:request, _conn}
    end
  end

  describe "get/2 pinning" do
    test "connects to the vetted IP and sends the original host" do
      Req.Test.expect(SafeFetch, fn conn ->
        assert conn.host == "93.184.216.34"
        assert conn.scheme == :https
        assert conn.port == 443
        assert conn.request_path == "/a/b"
        assert conn.query_string == "q=1"
        assert Plug.Conn.get_req_header(conn, "host") == ["public.test"]
        assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
        assert user_agent =~ "AcervoBot"
        assert Plug.Conn.get_req_header(conn, "accept") == ["text/html"]

        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, %{status: 200, body: "ok", url: "https://public.test/a/b?q=1", headers: headers}} =
               SafeFetch.get("https://public.test/a/b?q=1", accept: "text/html")

      assert is_map(headers)
    end

    test "returns the fetched URL" do
      Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 200, "ok"))

      assert {:ok, %{status: 200, body: "ok", url: "https://public.test/"}} =
               SafeFetch.get("https://public.test/")
    end

    test "brackets IPv6 addresses in the pinned URL" do
      Req.Test.expect(SafeFetch, fn conn ->
        assert conn.host == "2001:4860::8888"
        assert Plug.Conn.get_req_header(conn, "host") == ["ipv6.test"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, %{status: 200, url: "https://ipv6.test/"}} = SafeFetch.get("https://ipv6.test/")
    end

    test "pins TLS to the original host through Finch conn_opts" do
      uri = URI.parse("https://public.test/a")
      opts = [max_bytes: 100, accept: nil, user_agent: "ua", max_redirects: 5]

      options = SafeFetch.req_options(uri, {93, 184, 216, 34}, opts)

      assert options[:url] == "https://93.184.216.34/a"
      assert {"host", "public.test"} in options[:headers]
      refute Keyword.has_key?(options, :connect_options)

      assert options[:finch] == [
               conn_opts: [hostname: "public.test", transport_opts: [timeout: 10_000]],
               pool_max_idle_time: 60_000
             ]

      ipv6_options = SafeFetch.req_options(URI.parse("https://ipv6.test/"), {0x2001, 0x4860, 0, 0, 0, 0, 0, 0x8888}, opts)

      assert ipv6_options[:url] == "https://[2001:4860::8888]/"
      assert {"host", "ipv6.test"} in ipv6_options[:headers]
      assert ipv6_options[:finch][:conn_opts][:hostname] == "ipv6.test"
      assert ipv6_options[:finch][:conn_opts][:transport_opts] == [timeout: 10_000, inet6: true]
    end
  end

  describe "get/2 redirects" do
    test "follows a redirect and re-checks the new host" do
      Req.Test.expect(SafeFetch, 2, fn
        %{request_path: "/start"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://other.test/end")
          |> Plug.Conn.send_resp(301, "")

        %{request_path: "/end"} = conn ->
          assert conn.host == "93.184.216.35"
          assert Plug.Conn.get_req_header(conn, "host") == ["other.test"]
          Plug.Conn.send_resp(conn, 200, "done")
      end)

      assert {:ok, %{status: 200, body: "done", url: "https://other.test/end"}} =
               SafeFetch.get("https://public.test/start")
    end

    test "resolves a relative location against the current URL" do
      Req.Test.expect(SafeFetch, 2, fn
        %{request_path: "/a/start"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "next?x=1")
          |> Plug.Conn.send_resp(302, "")

        %{request_path: "/a/next"} = conn ->
          assert conn.query_string == "x=1"
          Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, %{url: "https://public.test/a/next?x=1"}} = SafeFetch.get("https://public.test/a/start")
    end

    test "follows a protocol-relative location with the current scheme's default port" do
      Req.Test.expect(SafeFetch, 2, fn
        %{request_path: "/start"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "//other.test/next")
          |> Plug.Conn.send_resp(302, "")

        %{request_path: "/next"} = conn ->
          assert conn.host == "93.184.216.35"
          assert conn.port == 443
          assert Plug.Conn.get_req_header(conn, "host") == ["other.test"]
          Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, %{status: 200, url: "https://other.test/next"}} = SafeFetch.get("https://public.test/start")
    end

    test "blocks a protocol-relative location to a private host" do
      Req.Test.expect(SafeFetch, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "//internal.test/x")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :blocked_address} = SafeFetch.get("https://public.test/")
    end

    test "blocks a redirect to a private host" do
      Req.Test.expect(SafeFetch, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://internal.test/x")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :blocked_address} = SafeFetch.get("https://public.test/")
    end

    test "blocks a redirect to a private IP literal or a bad port" do
      Req.Test.expect(SafeFetch, 2, fn
        %{request_path: "/ip"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest")
          |> Plug.Conn.send_resp(307, "")

        %{request_path: "/port"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://public.test:6379/")
          |> Plug.Conn.send_resp(308, "")
      end)

      assert {:error, :blocked_address} = SafeFetch.get("https://public.test/ip")
      assert {:error, :bad_port} = SafeFetch.get("https://public.test/port")
    end

    test "gives up after max_redirects" do
      Req.Test.expect(SafeFetch, 6, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://public.test/loop")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :too_many_redirects} = SafeFetch.get("https://public.test/")
    end

    test "honours a custom max_redirects" do
      Req.Test.expect(SafeFetch, 2, fn
        %{request_path: "/"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "/next")
          |> Plug.Conn.send_resp(303, "")

        conn ->
          Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert {:ok, %{body: "ok"}} = SafeFetch.get("https://public.test/", max_redirects: 1)

      Req.Test.expect(SafeFetch, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/next")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :too_many_redirects} = SafeFetch.get("https://public.test/", max_redirects: 0)
    end

    test "treats a redirect without a location as an HTTP error" do
      Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 302, ""))

      assert {:error, {:http, 302}} = SafeFetch.get("https://public.test/")
    end
  end

  describe "get/2 limits and errors" do
    test "stops reading a body larger than max_bytes" do
      Req.Test.expect(SafeFetch, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("a", 60))
        {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("b", 60))
        conn
      end)

      assert {:error, :too_large} = SafeFetch.get("https://public.test/", max_bytes: 100)
    end

    test "rejects a declared content-length larger than max_bytes" do
      Req.Test.expect(SafeFetch, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-length", "5000000")
        |> Plug.Conn.send_resp(200, "small")
      end)

      assert {:error, :too_large} = SafeFetch.get("https://public.test/", max_bytes: 100)
    end

    test "accepts a body of exactly max_bytes" do
      Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 200, String.duplicate("a", 100)))

      assert {:ok, %{body: body}} = SafeFetch.get("https://public.test/", max_bytes: 100)
      assert byte_size(body) == 100
    end

    test "returns non-2xx statuses as errors" do
      Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 404, "not found"))

      assert {:error, {:http, 404}} = SafeFetch.get("https://public.test/")
    end

    test "maps timeouts and transport errors" do
      Req.Test.expect(SafeFetch, &Req.Test.transport_error(&1, :timeout))
      assert {:error, :timeout} = SafeFetch.get("https://public.test/")

      Req.Test.expect(SafeFetch, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, {:transport, :econnrefused}} = SafeFetch.get("https://public.test/")
    end
  end

  defp stub_and_report do
    test_pid = self()

    Req.Test.stub(SafeFetch, fn conn ->
      send(test_pid, {:request, conn})
      Plug.Conn.send_resp(conn, 200, "should not be reached")
    end)
  end
end

defmodule Acervo.Library.SafeFetchConfigTest do
  # Mutates the application environment, so it must not run alongside the
  # async SafeFetch tests.
  use ExUnit.Case, async: false

  alias Acervo.Library.SafeFetch

  setup do
    original = Application.get_env(:acervo, :safe_fetch_req_options)
    on_exit(fn -> Application.put_env(:acervo, :safe_fetch_req_options, original) end)
  end

  test "the test override can only inject a plug" do
    Application.put_env(:acervo, :safe_fetch_req_options,
      plug: {Req.Test, SafeFetch},
      url: "http://127.0.0.1/",
      connect_options: [hostname: "evil.test"],
      finch: [name: Req.Finch],
      redirect: true
    )

    options = SafeFetch.req_options(URI.parse("https://public.test/"), {93, 184, 216, 34}, max_bytes: 1)

    assert options[:plug] == {Req.Test, SafeFetch}
    assert options[:url] == "https://93.184.216.34/"
    assert options[:redirect] == false
    assert options[:finch][:conn_opts][:hostname] == "public.test"
    refute Keyword.has_key?(options, :connect_options)
    assert Keyword.get_values(options, :url) == ["https://93.184.216.34/"]
  end
end
