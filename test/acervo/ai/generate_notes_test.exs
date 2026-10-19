defmodule Acervo.AI.GenerateNotesTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI.Call
  alias Acervo.AI.GenerateNotes
  alias Acervo.FakeAIClient
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Search.EmbedLink

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

  defp object(summary \\ "Como fazer pão em casa.", points \\ ["Use farinha forte.", "Espere a massa crescer."]),
    do: %{"summary" => summary, "points" => points}

  defp stub_ok(object \\ object()), do: FakeAIClient.stub(fn _model, _context, _schema, _opts -> {:ok, object} end)
  defp stub_error(error), do: FakeAIClient.stub(fn _model, _context, _schema, _opts -> {:error, error} end)

  defp perform(link, opts \\ []), do: perform_job(GenerateNotes, %{"link_id" => link.id}, opts)

  test "stores the rendered notes, records the call, embeds again and broadcasts", %{scope: scope} do
    link = ready_link(scope)
    stub_ok()

    assert :ok = perform(link)

    assert %Link{
             ai_notes: "Como fazer pão em casa.\n\n- Use farinha forte.\n- Espere a massa crescer.",
             ai_notes_at: %DateTime{}
           } =
             Repo.get!(Link, link.id)

    assert [%Call{operation: "generate_notes", status: :ok, link_id: link_id, input_tokens: 1200}] = Repo.all(Call)
    assert link_id == link.id
    assert_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})

    id = link.id
    assert_receive {:link_updated, %Link{id: ^id, ai_notes: "Como fazer" <> _}}
  end

  test "reads the reader text and never the owner's note", %{scope: scope} do
    link = ready_link(scope)
    link |> Link.content_changeset(%{content_html: "<p>Sove por dez minutos.</p>"}) |> Repo.update!()
    {:ok, _} = Library.update_note(scope, link, %{note: "minha nota"})
    stub_ok()

    assert :ok = perform(link)

    [_system, %{content: [%{text: text}]}] = FakeAIClient.last_context().messages
    assert text =~ "Sove por dez minutos."
    refute text =~ "minha nota"
    assert %Link{note: "minha nota"} = Repo.get!(Link, link.id)
  end

  test "generating again replaces the notes, edited or not", %{scope: scope} do
    link = ready_link(scope)
    stub_ok()
    assert :ok = perform(link)
    {:ok, _} = Library.update_ai_notes(scope, Repo.get!(Link, link.id), %{ai_notes: "Editadas à mão"})

    stub_ok(object("Outro resumo.", ["Outro ponto."]))
    assert :ok = perform(link)

    assert %Link{ai_notes: "Outro resumo.\n\n- Outro ponto."} = Repo.get!(Link, link.id)
    assert Repo.aggregate(Call, :count) == 2
  end

  test "a link with nothing to read fails without a call", %{scope: scope} do
    link = link_fixture(scope)

    assert :ok = perform(link)

    assert Repo.all(Call) == []
    id = link.id
    assert_receive {:notes_failed, %Link{id: ^id}}
  end

  test "a deleted link is a no-op", %{scope: scope} do
    link = ready_link(scope)
    {:ok, _} = Library.delete_link(scope, link)

    assert :ok = perform(link)
  end

  test "transient errors retry and the last attempt says it failed", %{scope: scope} do
    link = ready_link(scope)
    stub_error({:http, 503})

    assert {:error, {:http, 503}} = perform(link, attempt: 1)
    refute_receive {:notes_failed, _}

    assert {:error, {:http, 503}} = perform(link, attempt: 4)
    id = link.id
    assert_receive {:notes_failed, %Link{id: ^id}}
    assert %Link{ai_notes: nil} = Repo.get!(Link, link.id)
    assert [%Call{status: :error, error: "http_503"}, _] = Repo.all(Call)
  end

  test "permanent errors cancel and say it failed", %{scope: scope} do
    link = ready_link(scope)
    stub_error(:unavailable)

    assert {:cancel, :unavailable} = perform(link, attempt: 1)
    assert_receive {:notes_failed, _}
  end

  test "an invalid object is retried", %{scope: scope} do
    link = ready_link(scope)
    stub_ok(%{"summary" => "", "points" => []})

    assert {:error, :invalid_response} = perform(link, attempt: 1)
  end

  test "a rate limit snoozes", %{scope: scope} do
    link = ready_link(scope)
    stub_error({:rate_limited, 30})

    assert {:snooze, 30} = perform(link, attempt: 1)
  end

  test "another user's failure reaches only its owner" do
    theirs = link_fixture(user_scope_fixture())

    assert :ok = perform(theirs)
    refute_receive {:notes_failed, _}
  end

  describe "enqueue/2" do
    test "one waiting job per link, at the given priority", %{scope: scope} do
      link = ready_link(scope)

      assert {:ok, %Oban.Job{conflict?: false}} = GenerateNotes.enqueue(link, priority: 2)
      assert {:ok, %Oban.Job{conflict?: true}} = GenerateNotes.enqueue(link)
      assert_enqueued(worker: GenerateNotes, args: %{"link_id" => link.id}, priority: 2, queue: :ai)
    end
  end

  describe "Library.request_notes/2" do
    test "enqueues the scope's link, never another user's", %{scope: scope} do
      link = ready_link(scope)
      assert {:ok, _job} = Library.request_notes(scope, link)
      assert_enqueued(worker: GenerateNotes, args: %{"link_id" => link.id})

      other = user_scope_fixture()
      assert {:error, :not_found} = Library.request_notes(other, link)
    end
  end
end
