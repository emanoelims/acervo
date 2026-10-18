defmodule Acervo.Library.Images do
  @moduledoc "Normalizes captured images to WebP, at most 1600px on the long side."

  @max_input_bytes 15 * 1024 * 1024
  @max_side 1600

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
    with {:ok, image} <- Image.from_binary(binary),
         {:ok, {image, _flags}} <- Image.autorotate(image),
         {:ok, image} <- Image.thumbnail(image, @max_side, resize: :down),
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
      _ -> {:error, :not_an_image}
    end
  end
end
