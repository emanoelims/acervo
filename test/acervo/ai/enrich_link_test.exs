defmodule Acervo.AI.EnrichLinkTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI.Call
  alias Acervo.AI.EnrichLink
  alias Acervo.Collections
  alias Acervo.Collections.Suggestion
  alias Acervo.FakeAIClient
  alias Acervo.Library
  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Search.EmbedLink
  alias Acervo.Storage

  setup do
    scope = user_scope_fixture()
    Library.subscribe(scope)
    %{scope: scope}
  end

  defp ready_link(scope, attrs \\ %{}) do
    scope
    |> link_fixture()
    |> Link.capture_changeset(Map.merge(%{status: :ready, title: "Pão de fermentação natural"}, attrs))
    |> Repo.update!()
  end

  defp put_image(scope, link) do
    {:ok, image} = Images.normalize(image_fixture("photo.jpg"))
    {:ok, _} = Storage.put(scope, link, Map.merge(image, %{kind: :preview, position: 0}))
  end

  defp object(attrs) do
    Map.merge(
      %{
        "image_description" => "Um pão sobre a mesa.",
        "language" => "pt",
        "suggestions" => [
          %{"collection" => "receitas", "new_name" => "", "reason" => "É uma receita"},
          %{"collection" => "", "new_name" => "Padaria", "reason" => "Sobre pão"}
        ]
      },
      attrs
    )
  end

  defp stub_ok(attrs \\ %{}), do: FakeAIClient.stub(fn _model, _context, _schema, _opts -> {:ok, object(attrs)} end)
  defp stub_error(error), do: FakeAIClient.stub(fn _model, _context, _schema, _opts -> {:error, error} end)

  defp perform(link, opts \\ []), do: perform_job(EnrichLink, %{"link_id" => link.id}, opts)

  defp suggestions(link), do: Repo.all(from s in Suggestion, where: s.link_id == ^link.id, order_by: s.inserted_at)

  describe "success" do
    test "stores the fields and the suggestions, records the call and broadcasts", %{scope: scope} do
      collection = collection_fixture(scope, %{name: "Receitas"})
      link = ready_link(scope)
      put_image(scope, link)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enrichment_status: :pending])
      stub_ok()

      assert :ok = perform(link)

      assert %Link{
               image_description: "Um pão sobre a mesa.",
               language: "pt",
               enrichment_status: :ready,
               enriched_at: %DateTime{},
               status: :ready,
               triaged_at: nil
             } = Repo.get!(Link, link.id)

      collection_id = collection.id

      assert [
               %Suggestion{collection_id: ^collection_id, proposed_name: nil, reason: "É uma receita", status: :pending},
               %Suggestion{collection_id: nil, proposed_name: "Padaria", reason: "Sobre pão"}
             ] = suggestions(link)

      assert [%Call{operation: "enrich_link", status: :ok, link_id: link_id}] = Repo.all(Call)
      assert link_id == link.id

      id = link.id
      assert_receive {:link_updated, %Link{id: ^id, enrichment_status: :ready, suggestions: [_, _]}}
    end

    test "an image description the owner edited survives", %{scope: scope} do
      link = ready_link(scope)
      put_image(scope, link)
      {:ok, _} = Library.update_image_description(scope, link, %{image_description: "Minha descrição"})
      stub_ok()

      assert :ok = perform(link)

      assert %Link{image_description: "Minha descrição", language: "pt", enrichment_status: :ready} =
               Repo.get!(Link, link.id)
    end

    test "never turns another user's collection into a suggestion", %{scope: scope} do
      other = user_scope_fixture()
      theirs = collection_fixture(other, %{name: "Segredos"})
      link = ready_link(scope)

      stub_ok(%{
        "suggestions" => [
          %{"collection" => theirs.slug, "new_name" => "", "reason" => "x"},
          %{"collection" => theirs.id, "new_name" => "", "reason" => "x"}
        ]
      })

      assert :ok = perform(link)
      assert suggestions(link) == []
      assert %Link{enrichment_status: :ready} = Repo.get!(Link, link.id)
    end

    test "a triaged link gets its language but no suggestions", %{scope: scope} do
      link = ready_link(scope)
      {:ok, link} = Library.mark_triaged(scope, link)
      collection_fixture(scope, %{name: "Receitas"})
      stub_ok()

      assert :ok = perform(link)

      assert %Link{language: "pt", enrichment_status: :ready} = Repo.get!(Link, link.id)
      assert suggestions(link) == []
    end

    test "a link triaged before the run finishes gets no suggestions", %{scope: scope} do
      link = ready_link(scope)
      collection_fixture(scope, %{name: "Receitas"})
      {:ok, _} = Collections.finish_triage(scope, link)
      stub_ok()

      assert :ok = perform(link)

      assert %Link{language: "pt", enrichment_status: :ready} = Repo.get!(Link, link.id)
      assert suggestions(link) == []
    end

    test "a language the model could not judge is stored as nil", %{scope: scope} do
      link = ready_link(scope)
      stub_ok(%{"language" => ""})

      assert :ok = perform(link)
      assert %Link{language: nil, enrichment_status: :ready} = Repo.get!(Link, link.id)
    end
  end

  describe "nothing to do" do
    test "a deleted link is a no-op", %{scope: scope} do
      link = ready_link(scope)
      Repo.delete!(link)

      assert :ok = perform(link)
      assert :ok = perform_job(EnrichLink, %{"link_id" => "not-a-uuid"})
    end

    test "a link with nothing to read resets its status without a call", %{scope: scope} do
      link = scope |> link_fixture() |> Link.capture_changeset(%{status: :ready}) |> Repo.update!()
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enrichment_status: :pending])

      assert :ok = perform(link)

      assert %Link{enrichment_status: nil} = Repo.get!(Link, link.id)
      assert Repo.all(Call) == []
      assert_receive {:link_updated, %Link{enrichment_status: nil}}
    end

    test "a link not captured yet is left for its capture", %{scope: scope} do
      link = link_fixture(scope)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enrichment_status: :pending])

      assert :ok = perform(link)
      assert %Link{status: :pending, enrichment_status: nil} = Repo.get!(Link, link.id)
      assert Repo.all(Call) == []
    end
  end

  describe "errors" do
    test "a rate limit snoozes with the provider's wait, clamped", %{scope: scope} do
      link = ready_link(scope)

      stub_error({:rate_limited, 30})
      assert {:snooze, 30} = perform(link)

      stub_error({:rate_limited, 5})
      assert {:snooze, 15} = perform(link)

      stub_error({:rate_limited, 9_999})
      assert {:snooze, 600} = perform(link)
    end

    test "a rate limit without a wait backs off by itself", %{scope: scope} do
      link = ready_link(scope)
      stub_error({:rate_limited, nil})

      assert {:snooze, 60} = perform(link)

      assert {:snooze, 240} = perform(link, meta: %{"snoozed" => 2})
      assert %Link{enrichment_status: nil} = Repo.get!(Link, link.id)
    end

    test "after five snoozes a rate limit is a transient error", %{scope: scope} do
      link = ready_link(scope)
      stub_error({:rate_limited, nil})

      assert {:error, {:rate_limited, nil}} = perform(link, meta: %{"snoozed" => 5}, attempt: 1)
    end

    test "transient errors retry and the last attempt marks the link failed", %{scope: scope} do
      errors = [{:http, 500}, {:http, 529}, {:http, 408}, {:http, 409}, :timeout, :provider_error, :invalid_response]

      for error <- errors do
        link = ready_link(scope)
        Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enrichment_status: :pending])
        stub_error(error)

        assert {:error, ^error} = perform(link, attempt: 1)
        assert %Link{enrichment_status: :pending} = Repo.get!(Link, link.id)

        assert {:error, ^error} = perform(link, attempt: 4)
        assert %Link{enrichment_status: :failed, status: :ready, triaged_at: nil} = Repo.get!(Link, link.id)
        id = link.id
        assert_receive {:link_updated, %Link{id: ^id, enrichment_status: :failed}}
      end
    end

    test "a response that does not normalize is invalid", %{scope: scope} do
      link = ready_link(scope)
      FakeAIClient.stub(fn _model, _context, _schema, _opts -> {:ok, %{"language" => "pt"}} end)

      assert {:error, :invalid_response} = perform(link, attempt: 1)
    end

    test "permanent errors cancel and mark the link failed", %{scope: scope} do
      for error <- [{:http, 400}, {:http, 401}, {:http, 404}, :unavailable] do
        link = ready_link(scope)
        stub_error(error)

        assert {:cancel, ^error} = perform(link, attempt: 1)
        assert %Link{enrichment_status: :failed, status: :ready} = Repo.get!(Link, link.id)
      end
    end

    @tag :capture_log
    test "a crash is transient", %{scope: scope} do
      link = ready_link(scope)
      FakeAIClient.stub(fn _model, _context, _schema, _opts -> raise "boom with the page's title" end)

      assert {:error, :crashed} = perform(link, attempt: 1)
      assert %Link{enrichment_status: nil} = Repo.get!(Link, link.id)
      assert {:error, :crashed} = perform(link, attempt: 4)
      assert %Link{enrichment_status: :failed} = Repo.get!(Link, link.id)
    end

    test "every failed call is recorded", %{scope: scope} do
      link = ready_link(scope)
      stub_error({:http, 500})

      assert {:error, _} = perform(link, attempt: 1)
      assert [%Call{status: :error, error: "http_500"}] = Repo.all(Call)
    end
  end

  describe "enqueue/1" do
    test "inserts one job per link and marks it pending", %{scope: scope} do
      link = ready_link(scope)

      assert {:ok, _job} = EnrichLink.enqueue(link)
      assert {:ok, _job} = EnrichLink.enqueue(link)

      assert [_] = all_enqueued(worker: EnrichLink, args: %{"link_id" => link.id})
      assert %Link{enrichment_status: :pending} = Repo.get!(Link, link.id)
    end

    test "a second enqueue while the first job is available conflicts", %{scope: scope} do
      link = ready_link(scope)

      assert {:ok, %Oban.Job{conflict?: false, state: "available"} = first} = EnrichLink.enqueue(link)
      assert {:ok, %Oban.Job{conflict?: true, id: id}} = EnrichLink.enqueue(link)
      assert id == first.id
    end

    test "the uniqueness never expires while the job waits", %{scope: scope} do
      link = ready_link(scope)
      {:ok, first} = EnrichLink.enqueue(link)

      # A backfill can keep a job waiting for far longer than any period.
      Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id),
        set: [inserted_at: DateTime.shift(DateTime.utc_now(), day: -1)]
      )

      assert {:ok, %Oban.Job{conflict?: true}} = EnrichLink.enqueue(link)
      assert [_] = all_enqueued(worker: EnrichLink, args: %{"link_id" => link.id})
    end

    test "a conflicting enqueue still marks the link pending", %{scope: scope} do
      link = ready_link(scope)
      {:ok, _first} = EnrichLink.enqueue(link)
      # The waiting job's link was settled meanwhile (say, by a finished run).
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enrichment_status: :ready])

      assert {:ok, %Oban.Job{conflict?: true}} = EnrichLink.enqueue(link)
      assert %Link{enrichment_status: :pending} = Repo.get!(Link, link.id)
    end
  end

  describe "search embedding" do
    defp assert_embedding_enqueued(link) do
      assert_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})
      assert %Link{embedding_status: :pending} = Repo.get!(Link, link.id)
    end

    test "a stored enrichment enqueues it", %{scope: scope} do
      link = ready_link(scope)
      stub_ok()

      assert :ok = perform(link)
      assert_embedding_enqueued(link)
    end

    test "a link with nothing to read enqueues it", %{scope: scope} do
      link = scope |> link_fixture() |> Link.capture_changeset(%{status: :ready}) |> Repo.update!()

      assert :ok = perform(link)
      assert_embedding_enqueued(link)
    end

    test "giving up enqueues it, a transient failure does not", %{scope: scope} do
      link = ready_link(scope)
      stub_error({:http, 500})

      assert {:error, _} = perform(link, attempt: 1)
      refute_enqueued(worker: EmbedLink)
      assert %Link{embedding_status: nil} = Repo.get!(Link, link.id)

      assert {:error, _} = perform(link, attempt: 4)
      assert_embedding_enqueued(link)

      cancelled = ready_link(scope)
      stub_error(:unavailable)
      assert {:cancel, _} = perform(cancelled)
      assert_embedding_enqueued(cancelled)
    end

    test "a snooze does not enqueue it", %{scope: scope} do
      link = ready_link(scope)
      stub_error({:rate_limited, nil})

      assert {:snooze, _} = perform(link)
      refute_enqueued(worker: EmbedLink)
    end
  end
end
