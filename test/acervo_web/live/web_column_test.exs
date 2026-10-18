defmodule AcervoWeb.WebColumnTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.AccountsFixtures
  alias Acervo.Collections
  alias Acervo.Library.Link
  alias Acervo.Library.SafeFetch
  alias Acervo.Repo

  setup :register_and_log_in_user

  defp capture(link, attrs) do
    link
    |> Link.capture_changeset(Enum.into(attrs, %{status: :ready}))
    |> Repo.update!()
  end

  defp with_image(link) do
    collection_link_image_fixture(link)
    link
  end

  describe "opening and closing" do
    test "clicking the image patches to the web view column; clicking again closes it", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> capture(title: "Bees", site_name: "Journal", embeddable: true) |> with_image()

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")
      refute has_element?(view, "#column-web")
      refute has_element?(view, "#link-web")

      view |> element("#link-web-toggle") |> render_click()
      assert_patch(view, ~p"/all/l/#{link.id}/web")
      assert has_element?(view, "#column-web .column-title", "Journal")
      assert has_element?(view, "#column-link")
      assert has_element?(view, "#link-web-toggle.is-open[aria-expanded=true]")

      view |> element("#link-web-toggle") |> render_click()
      assert_patch(view, ~p"/all/l/#{link.id}")
      refute has_element?(view, "#column-web")
    end

    test "a link without an image opens it from the globe action", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> capture(title: "Bees", embeddable: false)

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")
      refute has_element?(view, "#link-web-toggle")

      view |> element("#link-web") |> render_click()
      assert_patch(view, ~p"/inbox/l/#{link.id}/web")
      assert has_element?(view, "#link-web.is-active")

      view |> element("#web-close") |> render_click()
      assert_patch(view, ~p"/inbox/l/#{link.id}")
    end

    test "works inside a collection and Esc closes it", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> capture(embeddable: true)
      collection = collection_fixture(scope, %{name: "Elixir"})
      :ok = Collections.add_link(scope, collection, link)

      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}/l/#{link.id}/web")
      assert has_element?(view, "#column-collection")
      assert has_element?(view, "#web-close[href='/c/#{collection.slug}/l/#{link.id}']")

      render_hook(view, "close_web", %{})
      assert_patch(view, ~p"/c/#{collection.slug}/l/#{link.id}")
    end

    test "the head actions open the original safely", %{conn: conn, scope: scope} do
      link =
        scope |> link_fixture("https://example.com/a") |> capture(resolved_url: "https://example.com/b", embeddable: true)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}/web")

      assert has_element?(view, ~s|#web-open[href="https://example.com/b"][target=_blank][rel="noopener noreferrer"]|)
    end

    test "another user's link is not found", %{conn: conn} do
      other = link_fixture(AccountsFixtures.user_scope_fixture())

      assert {:error, {:live_redirect, %{to: "/all", flash: %{"error" => "Not found."}}}} =
               live(conn, ~p"/all/l/#{other.id}/web")
    end
  end

  describe "what it shows" do
    test "an embeddable page in a sandboxed frame without a referrer", %{conn: conn, scope: scope} do
      link = scope |> link_fixture("https://example.com/a") |> capture(title: "Bees", embeddable: true)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}/web")

      frame = ~s|#web-frame[src="https://example.com/a"][referrerpolicy=no-referrer][loading=lazy][title=Bees]|
      assert has_element?(view, frame)
      assert has_element?(view, "#web-frame[sandbox*=allow-scripts][sandbox*=allow-popups-to-escape-sandbox]")
      refute has_element?(view, "#web-reader")
    end

    test "YouTube, X and Instagram use their embeds", %{conn: conn, scope: scope} do
      for {url, src} <- [
            {"https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"},
            {"https://x.com/jack/status/20", "https://platform.twitter.com/embed/Tweet.html?id=20&dnt=true"},
            {"https://www.instagram.com/reel/DAYg2PHyQCu/", "https://www.instagram.com/p/DAYg2PHyQCu/embed"}
          ] do
        link = scope |> link_fixture(url) |> capture(embeddable: false)

        {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}/web")
        assert has_element?(view, ~s|#web-frame[src="#{src}"]|), url
      end
    end

    test "a page that can't be framed shows the reader view", %{conn: conn, scope: scope} do
      text = "Bees pollinate crops. They live in hives.\nHoney is their food."
      link = scope |> link_fixture() |> capture(text_excerpt: text, embeddable: false)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}/web")

      refute has_element?(view, "#web-frame")
      assert has_element?(view, "#web-reader #web-reader-open[target=_blank][rel='noopener noreferrer']")
      assert has_element?(view, "#web-reader-text p", "Bees pollinate crops. They live in hives.")
      assert has_element?(view, "#web-reader-text p", "Honey is their food.")
    end

    test "an http page shows the reader view, with just the hint when there's no text", %{conn: conn, scope: scope} do
      link = scope |> link_fixture("http://example.com/a") |> capture(embeddable: true)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}/web")

      assert has_element?(view, "#web-reader .web-hint")
      refute has_element?(view, "#web-reader-text")
    end
  end

  describe "links captured before embeddability was recorded" do
    test "are checked once, then framed", %{conn: conn, scope: scope} do
      link = scope |> link_fixture("https://example.com/a") |> capture(title: "Bees")
      Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 200, "<html></html>"))

      # The check starts once connected; until it answers, a quiet placeholder.
      assert conn |> get(~p"/all/l/#{link.id}/web") |> html_response(200) =~ ~s(id="web-loading")

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}/web")
      render_async(view)
      assert has_element?(view, ~s|#web-frame[src="https://example.com/a"]|)
      assert %Link{embeddable: true} = Repo.get!(Link, link.id)
    end

    test "show the reader view when the page refuses framing", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> capture(text_excerpt: "Bees pollinate crops.")

      Req.Test.stub(SafeFetch, fn conn ->
        conn |> Plug.Conn.put_resp_header("x-frame-options", "DENY") |> Plug.Conn.send_resp(200, "")
      end)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}/web")
      render_async(view)

      assert has_element?(view, "#web-reader-text", "Bees pollinate crops.")
      assert %Link{embeddable: false} = Repo.get!(Link, link.id)
    end

    test "show the reader view when the check fails, without storing anything", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> capture(title: "Bees")
      Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 503, ""))

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}/web")
      render_async(view)

      assert has_element?(view, "#web-reader")
      assert %Link{embeddable: nil} = Repo.get!(Link, link.id)
    end
  end
end
