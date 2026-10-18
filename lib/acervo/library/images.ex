defmodule Acervo.Library.Images do
  @moduledoc """
  Normalizes captured images to WebP, at most 1600px on the long side.

  Only JPEG, PNG, WebP, GIF and HEIF/AVIF are accepted; anything else libvips
  could load (SVG, TIFF, PDF and so on) is `:not_an_image`. Images too large
  to decode safely, by dimensions or by estimated decoded size, are refused
  from the header alone.
  """

  alias Vix.Vips.Image, as: Vimage
  alias Vix.Vips.Operation

  require Logger

  @max_input_bytes 15 * 1024 * 1024
  @max_side 1600
  @max_side_input 20_000
  @max_pixels 24_000_000
  @max_decoded_bytes 96_000_000
  @bytes_per_band %{
    VIPS_FORMAT_UCHAR: 1,
    VIPS_FORMAT_CHAR: 1,
    VIPS_FORMAT_USHORT: 2,
    VIPS_FORMAT_SHORT: 2,
    VIPS_FORMAT_UINT: 4,
    VIPS_FORMAT_INT: 4,
    VIPS_FORMAT_FLOAT: 4,
    VIPS_FORMAT_COMPLEX: 8,
    VIPS_FORMAT_DOUBLE: 8,
    VIPS_FORMAT_DPCOMPLEX: 16
  }
  @allowed_loaders ~w(jpegload_buffer pngload_buffer webpload_buffer gifload_buffer heifload_buffer)

  @type normalized :: %{
          bytes: binary(),
          content_type: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          sha256: String.t()
        }

  @spec normalize(binary()) :: {:ok, normalized()} | {:error, :not_an_image | :too_large}
  def normalize(binary) when byte_size(binary) > @max_input_bytes, do: {:error, :too_large}

  def normalize(binary) when is_binary(binary) do
    with {:ok, probe} <- open(binary),
         :ok <- check_loader(probe),
         :ok <- check_dimensions(probe),
         {:ok, image} <- shrink(binary),
         {:ok, bytes} <- Image.write(image, :memory, suffix: ".webp", quality: 80, strip_metadata: true) do
      {:ok,
       %{
         bytes: bytes,
         content_type: "image/webp",
         width: Image.width(image),
         height: Image.height(image),
         sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
       }}
    else
      {:error, :too_large} ->
        {:error, :too_large}

      {:error, :not_an_image} ->
        {:error, :not_an_image}

      {:error, reason} ->
        Logger.warning("image normalization failed: #{inspect(reason)}")
        {:error, :not_an_image}
    end
  end

  # libvips opens lazily: this reads the header only, no pixels are decoded.
  defp open(binary), do: Image.from_binary(binary)

  defp check_loader(image) do
    case Vimage.header_value(image, "vips-loader") do
      {:ok, loader} when loader in @allowed_loaders -> :ok
      _ -> {:error, :not_an_image}
    end
  end

  defp check_dimensions(image) do
    {w, h} = {Image.width(image), Image.height(image)}
    # An unknown band format counts as the widest one.
    bytes_per_band = Map.get(@bytes_per_band, Vimage.format(image), 16)
    decoded_bytes = w * h * Image.bands(image) * bytes_per_band

    if w > @max_side_input or h > @max_side_input or w * h > @max_pixels or decoded_bytes > @max_decoded_bytes,
      do: {:error, :too_large},
      else: :ok
  end

  # Shrink-on-load straight from the buffer; thumbnail autorotates by default.
  defp shrink(binary), do: Operation.thumbnail_buffer(binary, @max_side, size: :VIPS_SIZE_DOWN)
end
