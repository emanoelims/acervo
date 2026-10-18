defmodule Acervo.Library.ImagesTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures

  alias Acervo.Accounts.Scope
  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Storage.Database
  alias Vix.Vips.MutableImage

  @fixtures Path.expand("../../support/fixtures/images", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # A real PNG whose IHDR claims other dimensions (and optionally another bit
  # depth or color type), with a valid CRC, so only the header is believable.
  defp lying_png(width, height, opts \\ []) do
    png = fixture("wide.png")

    <<sig::binary-size(8), 13::32, "IHDR", _w::32, _h::32, depth, color, rest::binary-size(3), _crc::32, tail::binary>> =
      png

    depth = Keyword.get(opts, :bit_depth, depth)
    color = Keyword.get(opts, :color_type, color)
    ihdr_body = <<width::32, height::32, depth, color, rest::binary>>
    crc = :erlang.crc32(["IHDR", ihdr_body])
    <<sig::binary, 13::32, "IHDR", ihdr_body::binary, crc::32, tail::binary>>
  end

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

    test "rejects images whose dimensions exceed the limits before decoding" do
      assert Images.normalize(lying_png(25_000, 25_000)) == {:error, :too_large}
    end

    test "rejects images over 24 megapixels before decoding" do
      assert Images.normalize(lying_png(6_000, 5_000)) == {:error, :too_large}
    end

    test "rejects images whose decoded size would exceed 96 MB before decoding" do
      # 20 megapixels, but 16-bit RGBA: 160 MB once decoded.
      assert Images.normalize(lying_png(5_000, 4_000, bit_depth: 16, color_type: 6)) == {:error, :too_large}
    end

    test "accepts JPEG, PNG, WebP and GIF" do
      source = Image.new!(40, 20, color: :red)

      for suffix <- [".jpg", ".png", ".webp", ".gif"] do
        binary = Image.write!(source, :memory, suffix: suffix)
        assert {:ok, %{content_type: "image/webp", width: 40, height: 20}} = Images.normalize(binary), suffix
      end
    end

    test "rejects formats other than the common ones, such as SVG and TIFF" do
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>)
      tiff = 10 |> Image.new!(10, color: :red) |> Image.write!(:memory, suffix: ".tif")

      assert Images.normalize(svg) == {:error, :not_an_image}
      assert Images.normalize(tiff) == {:error, :not_an_image}
    end

    test "strips EXIF metadata" do
      {:ok, source} = Image.new(64, 64, color: [200, 10, 10])

      {:ok, tagged} =
        Image.mutate(source, fn mut ->
          MutableImage.set(mut, "exif-ifd0-Artist", :gchararray, "Somebody")
        end)

      {:ok, jpeg} = Image.write(tagged, :memory, suffix: ".jpg")
      {:ok, reread} = Image.from_binary(jpeg)
      assert {:ok, %{artist: "Somebody"}} = Image.exif(reread)

      assert {:ok, normalized} = Images.normalize(jpeg)
      {:ok, out} = Image.from_binary(normalized.bytes)

      case Image.exif(out) do
        {:ok, exif} -> assert exif == %{}
        {:error, _} -> :ok
      end
    end

    test "rejects input over 15 MB" do
      assert Images.normalize(:binary.copy(<<0>>, 15 * 1024 * 1024 + 1)) == {:error, :too_large}
    end
  end

  describe "LinkImage.changeset/2" do
    test "only accepts image/webp" do
      attrs = %{
        kind: :preview,
        content_type: "image/png",
        bytes: "x",
        width: 1,
        height: 1,
        sha256: String.duplicate("a", 64)
      }

      changeset = LinkImage.changeset(%LinkImage{}, attrs)

      assert %{content_type: ["is invalid"]} = errors_on(changeset)
      assert LinkImage.changeset(%LinkImage{}, %{attrs | content_type: "image/webp"}).valid?
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
