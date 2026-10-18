defmodule Acervo.AI.Call do
  @moduledoc """
  One model call: its operation, model, outcome, tokens, cost and duration.
  No prompt or response content is stored. `error` holds only an error code
  such as `"http_500"`.
  """
  use Acervo.Schema

  import Ecto.Changeset

  alias Acervo.Accounts.User
  alias Acervo.Library.Link

  schema "ai_calls" do
    field :operation, :string
    field :model, :string
    field :status, Ecto.Enum, values: [:ok, :error]
    field :error, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost_usd, :decimal
    field :duration_ms, :integer

    belongs_to :user, User
    belongs_to :link, Link

    timestamps(updated_at: false)
  end

  @fields [:operation, :model, :status, :error, :input_tokens, :output_tokens, :cost_usd, :duration_ms, :link_id]

  def changeset(call, attrs) do
    call
    |> cast(attrs, @fields)
    |> validate_required([:operation, :model, :status, :duration_ms])
    |> validate_length(:error, max: 60)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:link_id)
  end
end
