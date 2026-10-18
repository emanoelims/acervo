defmodule Acervo.AI.ClaudeTest do
  # Changes the :anthropic application env, so it cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Acervo.AI.Claude
  alias ReqLLM.Error.API
  alias ReqLLM.Message.ContentPart

  @model "anthropic:claude-haiku-5-5"
  @title "Receita secreta de pão"
  @fixture Path.expand("../../support/fixtures/ai/message_object.json", __DIR__)

  @schema %{
    "type" => "object",
    "properties" => %{
      "language" => %{"type" => "string"},
      "image_description" => %{"type" => "string"}
    },
    "required" => ["language", "image_description"],
    "additionalProperties" => false
  }

  setup do
    previous = Application.get_env(:acervo, :anthropic)
    Application.put_env(:acervo, :anthropic, api_key: "test-key")
    on_exit(fn -> Application.put_env(:acervo, :anthropic, previous) end)

    webp = 64 |> Image.new!(64, color: [200, 30, 30]) |> Image.write!(:memory, suffix: ".webp")

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.system("Describe the page."),
        ReqLLM.Context.user([ContentPart.text("Title: #{@title}"), ContentPart.image(webp, "image/webp")])
      ])

    %{context: context}
  end

  defp call(context) do
    test = self()
    Claude.generate_object(@model, context, @schema, usage_callback: &send(test, {:usage, &1}))
  end

  defp stub(fun) do
    test = self()

    Req.Test.stub(Claude, fn conn ->
      send(test, :request)
      fun.(conn)
    end)
  end

  defp respond(conn, status, body, headers \\ []) do
    conn = Enum.reduce(headers, conn, fn {key, value}, conn -> Plug.Conn.put_resp_header(conn, key, value) end)
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp with_text(text), do: put_in(fixture(), ["content"], [%{"type" => "text", "text" => text}])

  defp error_body(type), do: %{"type" => "error", "error" => %{"type" => type, "message" => "failed"}}

  test "returns the validated object with string keys and reports the usage", %{context: context} do
    test = self()

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, Jason.decode!(raw)})
      respond(conn, 200, fixture())
    end)

    assert {:ok, %{"language" => "pt", "image_description" => "Um quadrado vermelho." <> _}} = call(context)

    assert_received {:request, conn, body}
    assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
    assert body["model"] == "claude-haiku-5-5"
    refute Map.has_key?(body, "temperature")
    assert [%{"role" => "user", "content" => content}] = body["messages"]
    assert %{"source" => %{"media_type" => "image/webp"}} = Enum.find(content, &(&1["type"] == "image"))

    assert_received {:usage, usage}
    assert usage.input_tokens == 412
    assert usage.output_tokens == 57
  end

  test "makes exactly one request per call", %{context: context} do
    stub(&respond(&1, 500, error_body("api_error")))

    capture_log(fn -> assert {:error, {:http, 500}} = call(context) end)

    assert_received :request
    refute_received :request
  end

  test "maps rate limits, overload and HTTP errors", %{context: context} do
    capture_log(fn ->
      # ReqLLM 1.28 drops the headers of a non-2xx response, so retry-after
      # is lost end to end (see the map_error/1 test below).
      stub(&respond(&1, 429, error_body("rate_limit_error"), [{"retry-after", "30"}]))
      assert {:error, {:rate_limited, nil}} = call(context)

      stub(&respond(&1, 529, error_body("overloaded_error")))
      assert {:error, {:http, 529}} = call(context)

      stub(&respond(&1, 500, error_body("api_error")))
      assert {:error, {:http, 500}} = call(context)

      stub(&respond(&1, 400, error_body("invalid_request_error")))
      assert {:error, {:http, 400}} = call(context)

      stub(&respond(&1, 408, error_body("timeout_error")))
      assert {:error, :timeout} = call(context)

      stub(&Req.Test.transport_error(&1, :timeout))
      assert {:error, :timeout} = call(context)
    end)
  end

  test "reads retry-after from rate-limit errors that carry headers" do
    assert Claude.map_error(%API.Request{status: 429, headers: %{"retry-after" => ["30"]}}) == {:rate_limited, 30}
    assert Claude.map_error(%API.Request{status: 429, headers: [{"retry-after", "7"}]}) == {:rate_limited, 7}
    assert Claude.map_error(%API.Request{status: 429, headers: %{"retry-after" => ["soon"]}}) == {:rate_limited, nil}
    assert Claude.map_error(%API.Request{status: 429, headers: nil}) == {:rate_limited, nil}
    assert Claude.map_error(%API.Timeout{kind: :receive, timeout: 60_000}) == :timeout
    assert Claude.map_error(%API.Request{status: nil, cause: %Req.TransportError{reason: :timeout}}) == :timeout

    assert Claude.map_error(%API.Request{status: nil, cause: %Req.TransportError{reason: :econnrefused}}) ==
             :provider_error

    assert Claude.map_error(:boom) == :provider_error
  end

  test "rejects text that is not a valid object and still reports the usage", %{context: context} do
    capture_log(fn ->
      stub(&respond(&1, 200, with_text("not json")))
      assert {:error, :invalid_response} = call(context)
      assert_received {:usage, %{input_tokens: 412, output_tokens: 57}}

      stub(&respond(&1, 200, with_text(~s({"language":"pt"}))))
      assert {:error, :invalid_response} = call(context)
      assert_received {:usage, %{input_tokens: 412}}
    end)
  end

  test "is unavailable without an API key and makes no request", %{context: context} do
    for key <- [nil, ""] do
      Application.put_env(:acervo, :anthropic, api_key: key)
      stub(fn _conn -> flunk("unexpected request") end)

      assert {:error, :unavailable} = call(context)
      refute_received :request
    end
  end

  test "logs neither the key nor page content", %{context: context} do
    Logger.put_process_level(self(), :debug)

    log =
      capture_log([level: :debug], fn ->
        stub(&respond(&1, 200, fixture()))
        call(context)

        stub(&respond(&1, 200, with_text(~s({"oops":"#{@title}"}))))
        call(context)

        stub(&respond(&1, 500, error_body("api_error")))
        call(context)

        stub(&respond(&1, 429, error_body("rate_limit_error")))
        call(context)
      end)

    assert log =~ "HTTP 500"
    refute log =~ "test-key"
    refute log =~ @title
  after
    Logger.delete_process_level(self())
  end
end
