defmodule Acervo.AITest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI
  alias Acervo.AI.Call
  alias Acervo.AI.Rates
  alias Acervo.FakeAIClient

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
      assert Decimal.equal?(call.cost_usd, Decimal.new("0.0002"))
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

  describe "Rates.estimate/3" do
    test "prices Haiku 5.5 at the dated rates, with the long-context tier" do
      assert Decimal.equal?(Rates.estimate("anthropic:claude-haiku-5-5", 100_000, 0), Decimal.new("0.01"))
      assert Decimal.equal?(Rates.estimate("claude-haiku-5-5", 0, 1_000_000), Decimal.new("0.5"))
      assert Decimal.equal?(Rates.estimate("anthropic:claude-haiku-5-5", 200_000, 0), Decimal.new("0.1"))
      assert Decimal.equal?(Rates.estimate("anthropic:claude-sonnet-5-5", 1000, 1000), Decimal.new("0.012"))
    end

    test "returns nil for unknown models or missing tokens" do
      assert Rates.estimate("anthropic:claude-unknown", 10, 10) == nil
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
