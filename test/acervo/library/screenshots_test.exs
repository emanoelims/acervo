defmodule Acervo.Library.ScreenshotsTest do
  # Toggles the service's global config, so it can't run alongside other tests.
  use ExUnit.Case, async: false

  alias Acervo.Library.Screenshots

  @token String.duplicate("t", 64)

  setup do
    previous = Application.get_env(:acervo, Screenshots)
    Application.put_env(:acervo, Screenshots, url: "https://shots.test/", token: @token)
    on_exit(fn -> Application.put_env(:acervo, Screenshots, previous) end)
  end

  defp stub(status, body, content_type \\ "application/json") do
    Req.Test.stub(Screenshots, fn conn ->
      conn |> Plug.Conn.put_resp_content_type(content_type, nil) |> Plug.Conn.send_resp(status, body)
    end)
  end

  test "posts the url with the token and returns the JPEG" do
    test = self()

    Req.Test.stub(Screenshots, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), body})
      conn |> Plug.Conn.put_resp_content_type("image/jpeg", nil) |> Plug.Conn.send_resp(200, "jpeg bytes")
    end)

    assert {:ok, "jpeg bytes"} = Screenshots.take("https://example.com/a")

    assert_received {:request, "POST", "/shot", ["Bearer " <> @token], body}
    assert JSON.decode!(body) == %{"url" => "https://example.com/a"}
  end

  test "maps the service's errors to reasons" do
    for {status, reason} <- [
          {400, :rejected},
          {422, :rejected},
          {401, :unauthorized},
          {503, :busy},
          {500, {:http, 500}},
          {502, {:http, 502}}
        ] do
      stub(status, ~s({"error": "nope"}))
      assert Screenshots.take("https://example.com/a") == {:error, reason}
    end
  end

  test "transport errors and timeouts are transient" do
    Req.Test.stub(Screenshots, &Req.Test.transport_error(&1, :timeout))
    assert Screenshots.take("https://example.com/a") == {:error, {:transport, :timeout}}

    Req.Test.stub(Screenshots, &Req.Test.transport_error(&1, :econnrefused))
    assert Screenshots.take("https://example.com/a") == {:error, {:transport, :econnrefused}}
  end

  test "is off without a url or a token" do
    assert Screenshots.enabled?()

    for config <- [[url: nil, token: @token], [url: "https://shots.test", token: nil], [url: "", token: ""], nil] do
      Application.put_env(:acervo, Screenshots, config)
      refute Screenshots.enabled?()
      assert Screenshots.take("https://example.com/a") == {:error, :disabled}
    end
  end

  test "classifies reasons for retries" do
    for reason <- [:busy, {:transport, :timeout}, {:http, 500}], do: assert(Screenshots.classify(reason) == :transient)
    for reason <- [:rejected, :unauthorized, :disabled], do: assert(Screenshots.classify(reason) == :permanent)
  end
end
