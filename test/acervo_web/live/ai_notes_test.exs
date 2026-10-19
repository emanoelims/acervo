defmodule AcervoWeb.AINotesTest do
  use AcervoWeb.ConnCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.Accounts
  alias Acervo.AI.GenerateNotes
  alias Acervo.FakeAIClient
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo

  setup :register_and_log_in_user

  defp ready_link(scope, attrs \\ %{}) do
    scope
    |> link_fixture()
    |> Link.capture_changeset(Map.merge(%{status: :ready, title: "Pão de fermentação natural"}, attrs))
    |> Repo.update!()
  end

  describe "generating" do
    test "shows progress until the notes arrive, then edits them like the note", %{conn: conn, scope: scope} do
      link = ready_link(scope)
      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      refute has_element?(view, "#ai-notes-form")
      assert has_element?(view, "#ai-notes-generate", "Generate notes")

      view |> element("#ai-notes-generate") |> render_click()

      assert_enqueued(worker: GenerateNotes, args: %{"link_id" => link.id})
      assert has_element?(view, "#ai-notes-generate[disabled][aria-busy=true]", "Writing notes…")

      # An update that brings no new notes keeps it busy.
      Library.broadcast_updated(scope, link.id)
      assert has_element?(view, "#ai-notes-generate[disabled]")

      FakeAIClient.stub(fn _model, _context, _schema, _opts ->
        {:ok, %{"summary" => "Como fazer pão.", "points" => ["Use farinha forte."]}}
      end)

      assert :ok = perform_job(GenerateNotes, %{"link_id" => link.id})

      refute has_element?(view, "#ai-notes-generate[disabled]")
      assert has_element?(view, "#ai-notes-generate", "Generate again")
      assert view |> element("#link-ai-notes") |> render() =~ "Como fazer pão.\n\n- Use farinha forte."
      assert has_element?(view, "#link-ai-notes[phx-blur=save_ai_notes][phx-hook]")

      view |> form("#ai-notes-form", %{"link" => %{"ai_notes" => "Minha versão"}}) |> render_submit()

      assert has_element?(view, "#ai-notes-status .note-saved")
      assert %Link{ai_notes: "Minha versão", note: nil} = Repo.get!(Link, link.id)
    end

    test "a failure stops the progress and says so", %{conn: conn, scope: scope} do
      link = ready_link(scope)
      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> element("#ai-notes-generate") |> render_click()
      Library.broadcast_notes_failed(scope, link.id)

      assert render(view) =~ "Couldn&#39;t write the notes."
      refute has_element?(view, "#ai-notes-generate[disabled]")
    end

    test "blurring the notes saves them", %{conn: conn, scope: scope} do
      link = ready_link(scope)
      {:ok, _} = Library.update_ai_notes(scope, link, %{ai_notes: "Antes"})
      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> element("#link-ai-notes") |> render_blur(%{"value" => "Depois"})

      assert %Link{ai_notes: "Depois"} = Repo.get!(Link, link.id)
    end
  end

  describe "automatic notes setting" do
    test "the dock settings choose never, long or always", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dock-settings #auto-notes-never[aria-pressed=true]")

      view |> element("#auto-notes-long") |> render_click()

      assert has_element?(view, "#auto-notes-long[aria-pressed=true]")
      assert has_element?(view, "#auto-notes-never[aria-pressed=false]")
      assert Accounts.get_user!(scope.user.id).auto_notes == :long

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#auto-notes-long[aria-pressed=true]")
    end

    test "an unknown value changes nothing", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "set_auto_notes", %{"value" => "sometimes"})

      assert has_element?(view, "#auto-notes-never[aria-pressed=true]")
      assert Accounts.get_user!(scope.user.id).auto_notes == :never
    end
  end
end
