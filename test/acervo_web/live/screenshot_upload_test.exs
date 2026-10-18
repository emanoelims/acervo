defmodule AcervoWeb.ScreenshotUploadTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo

  setup :register_and_log_in_user

  defp blocked_link(scope) do
    scope
    |> link_fixture("https://www.instagram.com/p/xyz/")
    |> Link.capture_changeset(%{status: :failed, capture_error: "blocked"})
    |> Repo.update!()
  end

  defp screenshot(view, name, content, type) do
    file_input(view, "#screenshot-form", :screenshot, [%{name: name, content: content, type: type}])
  end

  test "a link without images offers the drop zone and the camera action", %{conn: conn, scope: scope} do
    link = blocked_link(scope)

    {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

    assert has_element?(view, "#column-link #screenshot-drop[phx-drop-target]")
    assert has_element?(view, "#column-link label#link-screenshot")
  end

  test "a link with a captured preview keeps only the camera action", %{conn: conn, scope: scope} do
    link = scope |> link_fixture() |> Link.capture_changeset(%{status: :ready}) |> Repo.update!()
    Acervo.CollectionsFixtures.collection_link_image_fixture(link)

    {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

    refute has_element?(view, "#screenshot-drop")
    assert has_element?(view, "label#link-screenshot")
  end

  test "uploading an image stores it first, clears the error and updates the column and card", %{
    conn: conn,
    scope: scope
  } do
    link = blocked_link(scope)
    {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

    upload = screenshot(view, "photo.jpg", image_fixture("photo.jpg"), "image/jpeg")
    render_upload(upload, "photo.jpg")

    link = Library.get_link!(scope, link.id)
    assert link.capture_error == nil
    assert link.status == :ready
    assert [%{kind: :screenshot, position: 0}] = link.images

    refute has_element?(view, "#screenshot-drop")
    assert has_element?(view, "#column-link .glow img[src^='/images/']")
    assert has_element?(view, "#link-#{link.id} .glow img[src^='/images/']")
  end

  test "a file that is not an image flashes an error and changes nothing", %{conn: conn, scope: scope} do
    link = blocked_link(scope)
    {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

    upload = screenshot(view, "photo.jpg", image_fixture("not_image.txt"), "image/jpeg")
    html = render_upload(upload, "photo.jpg")

    assert html =~ "That file isn&#39;t an image."
    assert Library.get_link!(scope, link.id).images == []
  end

  test "a disallowed extension shows the error inline in the drop zone", %{conn: conn, scope: scope} do
    link = blocked_link(scope)
    {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

    upload = screenshot(view, "notes.txt", "hello", "text/plain")

    assert {:error, [[_ref, :not_accepted]]} = render_upload(upload, "notes.txt")
    assert has_element?(view, "#screenshot-drop #screenshot-error")
  end
end
