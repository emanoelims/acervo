defmodule Acervo.AI.CostTest do
  # Changes the :embeddings application env, so it cannot run concurrently.
  use Acervo.DataCase, async: false

  import Acervo.AccountsFixtures

  alias Acervo.AI
  alias Acervo.AI.Call
  alias Acervo.FakeEmbedder

  setup do
    previous = Application.get_env(:acervo, :embeddings)
    Application.put_env(:acervo, :embeddings, model: "openrouter:openai/text-embedding-3-small")
    on_exit(fn -> Application.put_env(:acervo, :embeddings, previous) end)
    %{scope: user_scope_fixture()}
  end

  test "records the client's cost for a model without a dated rate", %{scope: scope} do
    FakeEmbedder.stub(fn _model, text, _opts -> {:ok, FakeEmbedder.vector(text)} end,
      usage: %{input_tokens: 500, output_tokens: 0, total_cost: 0.00001}
    )

    assert {:ok, _vector} = AI.embed(scope, %{operation: "embed_query", link_id: nil}, "praia")

    assert [%Call{model: "openrouter:openai/text-embedding-3-small", cost_usd: cost}] = Repo.all(Call)
    assert Decimal.equal?(cost, Decimal.new("0.00001"))
  end
end
