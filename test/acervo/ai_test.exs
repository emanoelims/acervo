defmodule Acervo.AITest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI
  alias Acervo.AI.Call
  alias Acervo.AI.Rates
  alias Acervo.FakeAIClient
  alias Acervo.FakeEmbedder

  @schema %{"type" => "object", "properties" => %{"language" => %{"type" => "string"}}}

  setup do
    scope = user_scope_fixture()
    %{scope: scope, context: ReqLLM.Context.new([ReqLLM.Context.user("Describe the page.")])}
  end

  # ReqLLM derives thinking options from LLMDB; an uncatalogued model receives
  # budgeted thinking, which Claude 5.5 models reject with HTTP 400.
  test "the configured model is catalogued with adaptive thinking" do
    assert {:ok, metadata} = ReqLLM.model(AI.model())
    assert ReqLLM.ModelHelpers.adaptive_thinking_required?(metadata)
  end

  test "the fake client raises without a stub", %{scope: scope, context: context} do
    assert_raise RuntimeError, "no AI stub", fn ->
      AI.generate_object(scope, %{operation: "enrich_link", link_id: nil}, context, @schema)
    end
  end

  describe "generate_object/4" do
    test "returns the object and records the call's tokens and cost", %{scope: scope, context: context} do
      link = link_fixture(scope)
      test = self()

      FakeAIClient.stub(fn model, context, schema, _opts ->
        send(test, {:called, model, context, schema})
        {:ok, %{"language" => "pt"}}
      end)

      assert {:ok, %{"language" => "pt"}} =
               AI.generate_object(scope, %{operation: "enrich_link", link_id: link.id}, context, @schema)

      assert_received {:called, "anthropic:claude-opus-5-5", ^context, @schema}
      assert FakeAIClient.last_context() == context

      assert [call] = Repo.all(Call)
      assert call.user_id == scope.user.id
      assert call.link_id == link.id
      assert call.operation == "enrich_link"
      assert call.model == "anthropic:claude-opus-5-5"
      assert call.status == :ok
      assert call.error == nil
      assert call.input_tokens == 1200
      assert call.output_tokens == 80
      # The dated rate wins over the client's cost: 1200 × $4/M + 80 × $20/M.
      assert Decimal.equal?(call.cost_usd, Decimal.new("0.0064"))
      assert call.duration_ms >= 0
    end

    test "records a failed call with its error code", %{scope: scope, context: context} do
      FakeAIClient.stub(fn _model, _context, _schema, _opts -> {:error, {:http, 500}} end)

      assert {:error, {:http, 500}} =
               AI.generate_object(scope, %{operation: "enrich_link", link_id: nil}, context, @schema)

      assert [%Call{status: :error, error: "http_500", link_id: nil}] = Repo.all(Call)
    end

    test "records missing usage as nil, never as zero", %{scope: scope, context: context} do
      FakeAIClient.stub(fn _model, _context, _schema, _opts -> {:error, :unavailable} end, usage: %{})

      assert {:error, :unavailable} =
               AI.generate_object(scope, %{operation: "enrich_link", link_id: nil}, context, @schema)

      assert [%Call{error: "unavailable", input_tokens: nil, output_tokens: nil, cost_usd: nil}] = Repo.all(Call)
    end

    test "estimates the cost when the client reports none", %{scope: scope, context: context} do
      FakeAIClient.stub(fn _model, _context, _schema, _opts -> {:ok, %{}} end,
        usage: %{input_tokens: 412, output_tokens: 57}
      )

      assert {:ok, _} = AI.generate_object(scope, %{operation: "enrich_link", link_id: nil}, context, @schema)
      assert [%Call{input_tokens: 412, output_tokens: 57, cost_usd: cost}] = Repo.all(Call)
      assert Decimal.equal?(cost, Decimal.new("0.002788"))
    end

    test "keeps the record when the link was deleted during the call", %{scope: scope, context: context} do
      link = link_fixture(scope)

      FakeAIClient.stub(fn _model, _context, _schema, _opts ->
        Repo.delete!(link)
        {:ok, %{"language" => "pt"}}
      end)

      assert {:ok, _} = AI.generate_object(scope, %{operation: "enrich_link", link_id: link.id}, context, @schema)
      assert [%Call{status: :ok, link_id: nil}] = Repo.all(Call)
    end
  end

  describe "embed/4" do
    test "returns the vector and records the call", %{scope: scope} do
      test = self()

      FakeEmbedder.stub(fn model, text, opts ->
        send(test, {:called, model, text, opts})
        {:ok, FakeEmbedder.axis(0)}
      end)

      assert {:ok, vector} =
               AI.embed(scope, %{operation: "embed_query", link_id: nil}, "praia",
                 input_type: :query,
                 receive_timeout: 900
               )

      assert vector == FakeEmbedder.axis(0)
      assert_received {:called, "openrouter:voyageai/voyage-4-lite", "praia", opts}
      assert opts[:dimensions] == 1024
      assert opts[:input_type] == :query
      assert opts[:receive_timeout] == 900
      assert is_function(opts[:usage_callback], 1)

      assert [call] = Repo.all(Call)
      assert call.user_id == scope.user.id
      assert call.operation == "embed_query"
      assert call.model == "openrouter:voyageai/voyage-4-lite"
      assert call.status == :ok
      assert call.input_tokens == 12
      assert call.output_tokens == 0
      assert Decimal.equal?(call.cost_usd, Decimal.new("0.00000024"))
    end

    test "records the link of a document embedding", %{scope: scope} do
      link = link_fixture(scope)

      assert {:ok, _vector} =
               AI.embed(scope, %{operation: "embed_link", link_id: link.id}, "texto", input_type: :document)

      assert [%Call{operation: "embed_link", link_id: link_id}] = Repo.all(Call)
      assert link_id == link.id
    end

    test "records a failed call with its error code", %{scope: scope} do
      FakeEmbedder.stub(fn _model, _text, _opts -> {:error, {:http, 500}} end)

      assert {:error, {:http, 500}} = AI.embed(scope, %{operation: "embed_query", link_id: nil}, "praia")
      assert [%Call{status: :error, error: "http_500", operation: "embed_query"}] = Repo.all(Call)
    end

    test "is counted in the cost summary", %{scope: scope} do
      assert {:ok, _vector} = AI.embed(scope, %{operation: "embed_query", link_id: nil}, "praia")

      assert [%{calls: 1, input_tokens: 12, output_tokens: 0, cost_usd: cost}] = AI.cost_summary(1)
      assert Decimal.equal?(cost, Decimal.new("0.00000024"))
    end

    test "uses the configured model and fixed dimensions" do
      assert AI.embedding_model() == "openrouter:voyageai/voyage-4-lite"
      assert AI.embedding_dimensions() == 1024
      assert {:ok, _model} = ReqLLM.Embedding.validate_model(AI.embedding_model())
    end
  end

  describe "FakeEmbedder" do
    test "gives the same unit vector for the same text" do
      vector = FakeEmbedder.vector("praia")

      assert length(vector) == 1024
      assert vector == FakeEmbedder.vector("praia")
      refute vector == FakeEmbedder.vector("montanha")
      assert_in_delta dot(vector, vector), 1.0, 1.0e-9
    end

    test "builds orthogonal axes and normalized blends" do
      assert dot(FakeEmbedder.axis(0), FakeEmbedder.axis(1)) == 0.0
      assert dot(FakeEmbedder.axis(3), FakeEmbedder.axis(3)) == 1.0

      blend = FakeEmbedder.blend([{0, 1.0}, {1, 1.0}])
      assert_in_delta dot(blend, blend), 1.0, 1.0e-9
      assert_in_delta dot(blend, FakeEmbedder.axis(0)), :math.sqrt(0.5), 1.0e-9
    end

    test "counts calls from the test process", %{scope: scope} do
      assert FakeEmbedder.calls() == 0

      task = Task.async(fn -> AI.embed(scope, %{operation: "embed_query", link_id: nil}, "praia") end)
      assert {:ok, _vector} = Task.await(task)

      assert FakeEmbedder.calls() == 1
    end
  end

  describe "Rates.estimate/3" do
    test "prices Haiku 5.5 at the dated rates, with the long-context tier" do
      assert Decimal.equal?(Rates.estimate("anthropic:claude-haiku-5-5", 100_000, 0), Decimal.new("0.01"))
      assert Decimal.equal?(Rates.estimate("anthropic:claude-haiku-5-5", 0, 1_000_000), Decimal.new("0.5"))
      assert Decimal.equal?(Rates.estimate("anthropic:claude-haiku-5-5", 200_000, 0), Decimal.new("0.1"))
      assert Decimal.equal?(Rates.estimate("anthropic:claude-sonnet-5-5", 1000, 1000), Decimal.new("0.012"))
    end

    test "prices voyage-4-lite at OpenRouter's listed rate" do
      assert Decimal.equal?(Rates.estimate("openrouter:voyageai/voyage-4-lite", 12, 0), Decimal.new("0.00000024"))
      assert Decimal.equal?(Rates.estimate("openrouter:voyageai/voyage-4-lite", 2000, 0), Decimal.new("0.00004"))
    end

    test "returns nil for unknown models, unprefixed specs or missing tokens" do
      assert Rates.estimate("anthropic:claude-unknown", 10, 10) == nil
      assert Rates.estimate("claude-haiku-5-5", 10, 10) == nil
      assert Rates.estimate("anthropic:claude-haiku-5-5", nil, 10) == nil
    end
  end

  describe "cost_summary/1" do
    test "groups calls by day, oldest first, within the window", %{scope: scope} do
      now = DateTime.utc_now(:second)
      yesterday = DateTime.shift(now, day: -1)

      insert_call(scope, yesterday, input_tokens: 100, output_tokens: 10, cost_usd: Decimal.new("0.001"))
      insert_call(scope, now, input_tokens: 200, output_tokens: 20, cost_usd: Decimal.new("0.002"))
      insert_call(scope, now, input_tokens: nil, output_tokens: nil, cost_usd: nil, status: :error)
      insert_call(scope, DateTime.shift(now, day: -40), input_tokens: 999, output_tokens: 99)

      assert [old, today] = AI.cost_summary(30)

      assert old.day == DateTime.to_date(yesterday)
      assert old.calls == 1
      assert old.input_tokens == 100

      assert today.day == DateTime.to_date(now)
      assert today.calls == 2
      assert today.input_tokens == 200
      assert today.output_tokens == 20
      assert Decimal.equal?(today.cost_usd, Decimal.new("0.002"))
    end

    test "returns nil cost for a day without costs", %{scope: scope} do
      insert_call(scope, DateTime.utc_now(:second), input_tokens: 5, output_tokens: 1, cost_usd: nil)

      assert [%{calls: 1, input_tokens: 5, cost_usd: nil}] = AI.cost_summary(1)
    end
  end

  defp dot(a, b), do: a |> Enum.zip_with(b, &(&1 * &2)) |> Enum.sum()

  defp insert_call(scope, inserted_at, attrs) do
    Repo.insert!(
      struct!(
        %Call{
          user_id: scope.user.id,
          operation: "enrich_link",
          model: "anthropic:claude-haiku-5-5",
          status: :ok,
          duration_ms: 900,
          inserted_at: inserted_at
        },
        attrs
      )
    )
  end
end
