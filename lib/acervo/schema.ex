defmodule Acervo.Schema do
  @moduledoc """
  Shared schema defaults: UUID v7 primary keys, binary foreign keys and UTC
  second-precision timestamps.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
