defmodule Acervo.Library.ImagesTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures

  alias Acervo.Accounts.Scope
  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Storage.Database

  @fixtures Path.expand("../../support/fixtures/images", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "normalize/1" do
    test "converts to WebP limited to 1600px on the long side" do
      assert {:ok, image} = Images.normalize(fixture("photo.jpg"))

      assert image.content_type == "image/webp"
      assert image.width == 1600
      assert image.height == 800
      assert image.sha256 == Base.encode16(:crypto.hash(:sha256, image.bytes), case: :lower)
      assert {:ok, decoded} = Image.from_binary(image.bytes)
      assert Image.width(decoded) == 1600
    end

    test "does not enlarge small images" do
      assert {:ok, image} = Images.normalize(fixture("wide.png"))

      assert {image.width, image.height} == {300, 100}
    end

    test "rejects data that is not an image" do
      assert Images.normalize(fixture("not_image.txt")) == {:error, :not_an_image}
    end

    test "rejects input over 15 MB" do
      assert Images.normalize(:binary.copy(<<0>>, 15 * 1024 * 1024 + 1)) == {:error, :too_large}
    end
  end

  describe "Storage.Database" do
    setup do
      owner = user_fixture()

      link =
        Repo.insert!(%Link{user_id: owner.id, url: "https://e.com", canonical_url: "https://e.com", source: :generic})

      {:ok, normalized} = Images.normalize(fixture("wide.png"))
      %{owner: Scope.for_user(owner), link: link, attrs: Map.merge(normalized, %{kind: :preview, position: 0})}
    end

    test "put/3 stores and fetch/2 returns it for the owner", %{owner: scope, link: link, attrs: attrs} do
      assert {:ok, stored} = Database.put(scope, link, attrs)
      assert {:ok, fetched} = Database.fetch(scope, stored.id)
      assert fetched.bytes == attrs.bytes
    end

    test "fetch/2 returns :error for another user's image", %{owner: scope, link: link, attrs: attrs} do
      {:ok, stored} = Database.put(scope, link, attrs)

      assert Database.fetch(Scope.for_user(user_fixture()), stored.id) == :error
    end

    test "put/3 refuses a link of another user", %{link: link, attrs: attrs} do
      other = Scope.for_user(user_fixture())

      assert_raise Ecto.NoResultsError, fn -> Database.put(other, link, attrs) end
    end

    test "put/3 returns a changeset error for invalid attrs", %{owner: scope, link: link} do
      assert {:error, %Ecto.Changeset{}} = Database.put(scope, link, %{})
    end
  end
end
