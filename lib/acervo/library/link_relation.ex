defmodule Acervo.Library.LinkRelation do
  @moduledoc """
  Two of a user's links connected by hand. Symmetric: one row per pair, with
  `link_a_id < link_b_id`, so the pair reads the same from either link.
  """
  use Acervo.Schema

  import Ecto.Changeset

  alias Acervo.Accounts.User
  alias Acervo.Library.Link

  schema "link_relations" do
    belongs_to :user, User
    belongs_to :link_a, Link
    belongs_to :link_b, Link

    timestamps()
  end

  @doc "A relation between two link ids, stored in order."
  def changeset(relation, id, other_id) do
    {a, b} = if id < other_id, do: {id, other_id}, else: {other_id, id}

    relation
    |> change(link_a_id: a, link_b_id: b)
    |> check_constraint(:link_a_id, name: :link_relations_ordered)
    |> unique_constraint([:link_a_id, :link_b_id])
  end
end
