defmodule AcervoWeb.ImageControllerTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.AccountsFixtures

  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Repo
  alias Acervo.Storage.Database

  setup :register_and_log_in_user

  setup %{scope: scope} do
    link =
      Repo.insert!(%Link{user_id: scope.user.id, url: "https://e.com", canonical_url: "https://e.com", source: :generic})

    bytes = File.read!(Path.expand("../../support/fixtures/images/wide.png", __DIR__))
    {:ok, normalized} = Images.normalize(bytes)
    {:ok, image} = Database.put(scope, link, Map.merge(normalized, %{kind: :preview, position: 0}))
    %{image: image}
  end

  test "serves the owner's image privately", %{conn: conn, image: image} do
    conn = get(conn, ~p"/images/#{image.id}")

    assert response(conn, 200) == image.bytes
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/webp"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    assert get_resp_header(conn, "etag") == [~s("#{image.sha256}")]
  end

  test "returns 304 when if-none-match matches the etag", %{conn: conn, image: image} do
    conn =
      conn
      |> put_req_header("if-none-match", ~s("#{image.sha256}"))
      |> get(~p"/images/#{image.id}")

    assert response(conn, 304) == ""
  end

  test "returns 404 for another user's image", %{image: image} do
    conn = log_in_user(build_conn(), user_fixture())

    assert conn |> get(~p"/images/#{image.id}") |> response(404)
  end

  test "returns 404 for a missing image", %{conn: conn} do
    assert conn |> get(~p"/images/#{Ecto.UUID.generate()}") |> response(404)
  end

  test "returns 404 for a malformed id", %{conn: conn} do
    assert conn |> get("/images/not-a-uuid") |> response(404)
  end

  test "redirects visitors to log in", %{image: image} do
    conn = get(build_conn(), ~p"/images/#{image.id}")

    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
