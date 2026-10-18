defmodule Acervo.Library.Images do
  @moduledoc "Normalizes captured images to WebP, at most 1600px on the long side."

  alias Vix.Vips.Operation

  require Logger

  @max_input_bytes 15 * 1024 * 1024
  @max_side 1600
  @max_side_input 20_000
  @max_pixels 50_000_000

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

      {:error, reason} ->
        Logger.warning("image normalization failed: #{inspect(reason)}")
        {:error, :not_an_image}
    end
  end

  # libvips opens lazily: this reads the header only, no pixels are decoded.
  defp open(binary), do: Image.from_binary(binary)

  defp check_dimensions(image) do
    {w, h} = {Image.width(image), Image.height(image)}

    if w > @max_side_input or h > @max_side_input or w * h > @max_pixels,
      do: {:error, :too_large},
      else: :ok
  end

  # Shrink-on-load straight from the buffer; thumbnail autorotates by default.
  defp shrink(binary), do: Operation.thumbnail_buffer(binary, @max_side, size: :VIPS_SIZE_DOWN)
end
