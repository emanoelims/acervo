defmodule Acervo.AI.OpenRouterEmbedderTest do
  # Changes the :openrouter application env, so it cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Acervo.AI.OpenRouterEmbedder

  @model "openrouter:voyageai/voyage-4-lite"
  @text "Receita secreta de pão de queijo"
  @fixture Path.expand("../../support/fixtures/ai/embedding.json", __DIR__)

  setup do
    previous = Application.get_env(:acervo, :openrouter)
    Application.put_env(:acervo, :openrouter, api_key: "test-key")
    on_exit(fn -> Application.put_env(:acervo, :openrouter, previous) end)
  end

  defp call(opts \\ []) do
    test = self()

    OpenRouterEmbedder.embed(
      @model,
      @text,
      Keyword.merge([dimensions: 1024, input_type: :document, usage_callback: &send(test, {:usage, &1})], opts)
    )
  end

  defp stub(fun) do
    test = self()

    Req.Test.stub(OpenRouterEmbedder, fn conn ->
      send(test, :request)
      fun.(conn)
    end)
  end

  defp respond(conn, status, body), do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp with_length(length) do
    update_in(fixture(), ["data", Access.at(0), "embedding"], &Enum.take(Stream.cycle(&1), length))
  end

  defp error_body, do: %{"error" => %{"code" => 500, "message" => "failed: #{@text}"}}

  test "returns the vector and reports the usage" do
    test = self()

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, Jason.decode!(raw)})
      respond(conn, 200, fixture())
    end)

    assert {:ok, vector} = call()
    assert length(vector) == 1024
    assert Enum.all?(vector, &is_float/1)

    assert_received {:request, conn, body}
    assert conn.request_path == "/api/v1/embeddings"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
    assert body["model"] == "voyageai/voyage-4-lite"
    assert body["dimensions"] == 1024
    assert body["input_type"] == "document"
    assert body["input"] == @text

    assert_received {:usage, usage}
    assert usage.input_tokens == 14
    assert usage.output_tokens == 0
  end

  test "sends the query input type for searches" do
    test = self()

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:body, Jason.decode!(raw)})
      respond(conn, 200, fixture())
    end)

    assert {:ok, _vector} = call(input_type: :query)
    assert_received {:body, %{"input_type" => "query"}}
  end

  test "rejects a vector of the wrong length and still reports" do
    capture_log(fn ->
      stub(&respond(&1, 200, with_length(512)))
      assert {:error, :invalid_response} = call()
      # ReqLLM rejects the length before returning the usage.
      assert_received {:usage, %{}}

      stub(&respond(&1, 200, %{"data" => []}))
      assert {:error, :invalid_response} = call()
      assert_received {:usage, %{}}
    end)
  end

  test "makes exactly one request per call" do
    stub(&respond(&1, 500, error_body()))

    capture_log(fn -> assert {:error, {:http, 500}} = call() end)

    assert_received :request
    refute_received :request
  end

  test "maps rate limits and HTTP errors" do
    capture_log(fn ->
      stub(&respond(&1, 429, error_body()))
      assert {:error, {:rate_limited, nil}} = call()

      stub(&respond(&1, 500, error_body()))
      assert {:error, {:http, 500}} = call()

      stub(&respond(&1, 400, error_body()))
      assert {:error, {:http, 400}} = call()

      stub(&Req.Test.transport_error(&1, :timeout))
      assert {:error, :timeout} = call()
    end)
  end

  test "is unavailable without an API key and makes no request" do
    for key <- [nil, ""] do
      Application.put_env(:acervo, :openrouter, api_key: key)
      stub(fn _conn -> flunk("unexpected request") end)

      assert {:error, :unavailable} = call()
      refute_received :request
    end
  end

  test "rejects a model that cannot embed, with no request" do
    stub(fn _conn -> flunk("unexpected request") end)

    assert {:error, :provider_error} =
             OpenRouterEmbedder.embed("anthropic:claude-haiku-5-5", @text, dimensions: 1024)

    refute_received :request
  end

  test "logs neither the key nor the input text" do
    Logger.put_process_level(self(), :debug)

    log =
      capture_log([level: :debug], fn ->
        stub(&respond(&1, 200, fixture()))
        call()

        stub(&respond(&1, 200, with_length(3)))
        call()

        stub(&respond(&1, 500, error_body()))
        call()

        stub(&respond(&1, 429, error_body()))
        call()
      end)

    assert log =~ "HTTP 500"
    refute log =~ "test-key"
    refute log =~ @text
  after
    Logger.delete_process_level(self())
  end
end
