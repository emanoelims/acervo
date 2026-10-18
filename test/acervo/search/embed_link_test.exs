defmodule Acervo.Search.EmbedLinkTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI
  alias Acervo.AI.Call
  alias Acervo.FakeEmbedder
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Search.Document
  alias Acervo.Search.EmbedLink

  setup do
    %{scope: user_scope_fixture()}
  end

  defp ready_link(scope, attrs \\ []) do
    link = link_fixture(scope)
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: Keyword.merge([status: :ready, title: "Bees"], attrs))
    Repo.get!(Link, link.id)
  end

  defp perform(link, opts \\ []), do: perform_job(EmbedLink, %{"link_id" => link.id}, opts)

  defp mark_pending(link),
    do: Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [embedding_status: :pending])

  defp stored(link) do
    Repo.one!(
      from l in Link,
        where: l.id == ^link.id,
        select: %{
          embedding: l.embedding,
          digest: l.embedding_digest,
          model: l.embedding_model,
          status: l.embedding_status,
          embedded_at: l.embedded_at
        }
    )
  end

  defp stub_error(error), do: FakeEmbedder.stub(fn _model, _text, _opts -> {:error, error} end)

  defp embed_jobs(link), do: all_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})

  describe "success" do
    test "stores the vector, the model, the digest and the status, and records the call", %{scope: scope} do
      link = ready_link(scope)
      mark_pending(link)

      assert :ok = perform(link)

      model = AI.embedding_model()
      {:ok, text} = Document.build(scope, link)
      digest = Document.digest(model, text)

      assert %{embedding: embedding, digest: ^digest, model: ^model, status: :ready, embedded_at: %DateTime{}} =
               stored(link)

      # Stored as float4.
      vector = Pgvector.to_list(embedding)
      assert length(vector) == 1024

      for {stored, expected} <- Enum.zip(vector, FakeEmbedder.vector(text)) do
        assert_in_delta stored, expected, 1.0e-6
      end

      assert [%Call{operation: "embed_link", status: :ok, link_id: link_id, model: ^model}] = Repo.all(Call)
      assert link_id == link.id
    end

    test "an unchanged document is not embedded again", %{scope: scope} do
      link = ready_link(scope)
      assert :ok = perform(link)
      assert FakeEmbedder.calls() == 1

      mark_pending(link)
      assert :ok = perform(link)

      assert FakeEmbedder.calls() == 1
      assert %{status: :ready} = stored(link)
      assert [_] = Repo.all(Call)
    end

    test "a changed note is embedded again", %{scope: scope} do
      link = ready_link(scope)
      assert :ok = perform(link)
      before = stored(link)

      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [note: "for the garden"])
      assert :ok = perform(link)

      assert FakeEmbedder.calls() == 2
      assert %{status: :ready, digest: digest} = stored(link)
      refute digest == before.digest
    end

    test "a changed model is embedded again", %{scope: scope} do
      link = ready_link(scope)
      assert :ok = perform(link)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [embedding_model: "openrouter:old/model"])

      assert :ok = perform(link)
      assert FakeEmbedder.calls() == 2
      assert %{model: "openrouter:voyageai/voyage-4-lite"} = stored(link)
    end
  end

  describe "changes during the call" do
    test "a text edited during the call keeps the old vector, stays pending and is enqueued again", %{scope: scope} do
      link = ready_link(scope)
      assert :ok = perform(link)
      before = stored(link)

      # A writer with no enqueue of its own changes the text mid-call.
      FakeEmbedder.stub(fn _model, text, _opts ->
        Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [note: "edited meanwhile"])
        {:ok, FakeEmbedder.vector(text)}
      end)

      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [description: "A new description"])
      assert :ok = perform(link)

      assert %{status: :pending, digest: digest, embedding: embedding} = stored(link)
      assert digest == before.digest
      assert embedding == before.embedding
      assert [_] = embed_jobs(link)
    end

    test "an owner edit during the call leaves one job, the edit's own", %{scope: scope} do
      link = ready_link(scope)

      FakeEmbedder.stub(fn _model, text, _opts ->
        {:ok, _} = Library.update_note(scope, link, %{note: "edited meanwhile"})
        {:ok, FakeEmbedder.vector(text)}
      end)

      assert :ok = perform(link)

      assert %{status: :pending, embedding: nil} = stored(link)
      assert [%Oban.Job{state: "scheduled"}] = embed_jobs(link)

      # The next run embeds the edited text.
      FakeEmbedder.stub(fn _model, text, _opts -> {:ok, FakeEmbedder.vector(text)} end)
      assert :ok = perform(link)

      {:ok, text} = Document.build(scope, Repo.get!(Link, link.id))
      assert text =~ "edited meanwhile"
      assert %{status: :ready, digest: digest} = stored(link)
      assert digest == Document.digest(AI.embedding_model(), text)
    end

    test "a link deleted during the call is a no-op", %{scope: scope} do
      link = ready_link(scope)

      FakeEmbedder.stub(fn _model, text, _opts ->
        Repo.delete_all(from l in Link, where: l.id == ^link.id)
        {:ok, FakeEmbedder.vector(text)}
      end)

      assert :ok = perform(link)
      assert [%Call{status: :ok, link_id: nil}] = Repo.all(Call)
    end
  end

  describe "nothing to do" do
    test "a deleted link or a bad id is a no-op", %{scope: scope} do
      link = ready_link(scope)
      Repo.delete!(link)

      assert :ok = perform(link)
      assert :ok = perform_job(EmbedLink, %{"link_id" => "not-a-uuid"})
      assert FakeEmbedder.calls() == 0
    end

    test "a link not captured yet resets its status without a call", %{scope: scope} do
      link = link_fixture(scope)
      mark_pending(link)

      assert :ok = perform(link)

      assert %{status: nil} = stored(link)
      assert FakeEmbedder.calls() == 0
    end

    test "a link with nothing to embed resets its status and drops an old vector", %{scope: scope} do
      link = ready_link(scope, title: nil, note: "only a note")
      assert :ok = perform(link)
      assert %{status: :ready, embedding: %Pgvector{}} = stored(link)

      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [note: nil])
      mark_pending(link)
      assert :ok = perform(link)

      assert %{status: nil, embedding: nil, digest: nil, model: nil, embedded_at: nil} = stored(link)
      assert FakeEmbedder.calls() == 1
    end
  end

  describe "errors" do
    @tag :capture_log
    test "a vector of the wrong length cancels and marks the link failed", %{scope: scope} do
      link = ready_link(scope)
      mark_pending(link)
      FakeEmbedder.stub(fn _model, _text, _opts -> {:ok, List.duplicate(0.1, 512)} end)

      assert {:cancel, :invalid_response} = perform(link)
      assert %{status: :failed, embedding: nil} = stored(link)
    end

    test "transient errors retry and the last attempt marks the link failed", %{scope: scope} do
      for error <- [{:http, 500}, {:http, 408}, :timeout, :provider_error] do
        link = ready_link(scope)
        mark_pending(link)
        stub_error(error)

        assert {:error, ^error} = perform(link, attempt: 1)
        assert %{status: :pending} = stored(link)

        assert {:error, ^error} = perform(link, attempt: 5)
        assert %{status: :failed} = stored(link)
      end
    end

    test "permanent errors cancel and mark the link failed", %{scope: scope} do
      for error <- [:unavailable, {:http, 400}, {:http, 401}] do
        link = ready_link(scope)
        mark_pending(link)
        stub_error(error)

        assert {:cancel, ^error} = perform(link, attempt: 1)
        assert %{status: :failed} = stored(link)
      end
    end

    test "a rate limit snoozes with the provider's wait, clamped, or its own backoff", %{scope: scope} do
      link = ready_link(scope)
      mark_pending(link)

      stub_error({:rate_limited, 30})
      assert {:snooze, 30} = perform(link)

      stub_error({:rate_limited, 5})
      assert {:snooze, 15} = perform(link)

      stub_error({:rate_limited, nil})
      assert {:snooze, 60} = perform(link)
      assert {:snooze, 240} = perform(link, meta: %{"snoozed" => 2})
      assert {:snooze, 600} = perform(link, meta: %{"snoozed" => 4})

      assert %{status: :pending} = stored(link)
    end

    test "after five snoozes a rate limit is a transient error", %{scope: scope} do
      link = ready_link(scope)
      stub_error({:rate_limited, nil})

      assert {:error, {:rate_limited, nil}} = perform(link, meta: %{"snoozed" => 5}, attempt: 1)
      assert {:error, {:rate_limited, nil}} = perform(link, meta: %{"snoozed" => 5}, attempt: 5)
      assert %{status: :failed} = stored(link)
    end

    @tag :capture_log
    test "a crash is transient", %{scope: scope} do
      link = ready_link(scope)
      mark_pending(link)
      FakeEmbedder.stub(fn _model, _text, _opts -> raise "boom with the page's title" end)

      assert {:error, :crashed} = perform(link, attempt: 1)
      assert %{status: :pending} = stored(link)
      assert {:error, :crashed} = perform(link, attempt: 5)
      assert %{status: :failed} = stored(link)
    end

    test "every failed call is recorded", %{scope: scope} do
      link = ready_link(scope)
      stub_error({:http, 500})

      assert {:error, _} = perform(link, attempt: 1)
      assert [%Call{operation: "embed_link", status: :error, error: "http_500"}] = Repo.all(Call)
    end
  end

  describe "enqueue/2" do
    test "marks the link pending and inserts one job", %{scope: scope} do
      link = ready_link(scope)

      assert {:ok, %Oban.Job{conflict?: false, state: "available"}} = EmbedLink.enqueue(link)
      assert {:ok, %Oban.Job{conflict?: true}} = EmbedLink.enqueue(link.id)

      assert [_] = embed_jobs(link)
      assert %{status: :pending} = stored(link)
    end

    test "a conflicting enqueue still marks the link pending", %{scope: scope} do
      link = ready_link(scope)
      {:ok, _first} = EmbedLink.enqueue(link)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [embedding_status: :ready])

      assert {:ok, %Oban.Job{conflict?: true}} = EmbedLink.enqueue(link)
      assert %{status: :pending} = stored(link)
    end

    test "a delay schedules the job, and a burst collapses into it", %{scope: scope} do
      link = ready_link(scope)

      assert {:ok, %Oban.Job{state: "scheduled", scheduled_at: at}} = EmbedLink.enqueue(link, delay: 5)
      assert DateTime.diff(at, DateTime.utc_now()) in 3..5

      assert {:ok, %Oban.Job{conflict?: true}} = EmbedLink.enqueue(link, delay: 5)
      assert {:ok, %Oban.Job{conflict?: true}} = EmbedLink.enqueue(link)
      assert [_] = embed_jobs(link)
    end

    test "the uniqueness never expires while the job waits", %{scope: scope} do
      link = ready_link(scope)
      {:ok, first} = EmbedLink.enqueue(link)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id),
        set: [inserted_at: DateTime.shift(DateTime.utc_now(), day: -1)]
      )

      assert {:ok, %Oban.Job{conflict?: true}} = EmbedLink.enqueue(link)
    end

    test "a running job does not block a new one", %{scope: scope} do
      link = ready_link(scope)
      {:ok, first} = EmbedLink.enqueue(link)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [state: "executing"])

      assert {:ok, %Oban.Job{conflict?: false}} = EmbedLink.enqueue(link)
    end
  end

  describe "enqueue_many/2" do
    test "marks every link pending and inserts one job each", %{scope: scope} do
      links = for _ <- 1..3, do: ready_link(scope)
      ids = Enum.map(links, & &1.id)
      {:ok, _} = EmbedLink.enqueue(hd(links))

      assert {:ok, 3} = EmbedLink.enqueue_many(ids ++ ids, delay: 5)

      for link <- links do
        assert [_] = embed_jobs(link)
        assert %{status: :pending} = stored(link)
      end
    end

    test "skips ids of links that are gone", %{scope: scope} do
      link = ready_link(scope)

      assert {:ok, 1} = EmbedLink.enqueue_many([link.id, Ecto.UUID.generate()])
      assert {:ok, 0} = EmbedLink.enqueue_many([])
    end
  end
end
