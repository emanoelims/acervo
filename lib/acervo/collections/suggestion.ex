defmodule Acervo.Collections.Suggestion do
  @moduledoc """
  A collection suggested for a link: either one of the user's collections
  (`collection_id`) or a new collection name (`proposed_name`), with a short
  reason. Suggestions come from the model and are untrusted; they never apply
  on their own. Only one suggestion per link and target can be pending.
  """
  use Acervo.Schema

  import Ecto.Changeset

  alias Acervo.Accounts.User
  alias Acervo.Collections.Collection
  alias Acervo.Library.Link

  schema "collection_suggestions" do
    field :proposed_name, :string
    field :normalized_name, :string
    field :reason, :string
    field :status, Ecto.Enum, values: [:pending, :accepted, :dismissed], default: :pending

    belongs_to :user, User
    belongs_to :link, Link
    belongs_to :collection, Collection

    timestamps()
  end

  @doc """
  Casts the target and reason. `normalized_name` is derived from
  `proposed_name` with `Collection.slugify/1`; NUL bytes are stripped.
  """
  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, [:collection_id, :proposed_name, :reason])
    |> update_change(:proposed_name, &clean/1)
    |> update_change(:reason, &clean/1)
    |> put_normalized_name()
    |> validate_length(:proposed_name, max: 80)
    |> validate_length(:normalized_name, max: 120)
    |> validate_length(:reason, max: 140)
    |> validate_target()
    |> check_constraint(:collection_id, name: :target)
    |> unique_constraint(:collection_id, name: :collection_suggestions_pending_collection_index)
    |> unique_constraint(:normalized_name, name: :collection_suggestions_pending_name_index)
    |> foreign_key_constraint(:collection_id)
    |> foreign_key_constraint(:link_id)
  end

  defp clean(value) when is_binary(value) do
    case value |> String.replace(<<0>>, "") |> String.trim() do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp clean(value), do: value

  defp put_normalized_name(changeset) do
    case get_field(changeset, :proposed_name) do
      name when is_binary(name) ->
        case Collection.slugify(name) do
          "" -> put_change(changeset, :normalized_name, nil)
          slug -> put_change(changeset, :normalized_name, slug)
        end

      nil ->
        put_change(changeset, :normalized_name, nil)
    end
  end

  defp validate_target(changeset) do
    if get_field(changeset, :collection_id) || get_field(changeset, :normalized_name) do
      changeset
    else
      add_error(changeset, :collection_id, "needs a collection or a new name")
    end
  end
end
