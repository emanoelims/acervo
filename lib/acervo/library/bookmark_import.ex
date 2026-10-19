defmodule Acervo.Library.BookmarkImport do
  @moduledoc """
  One bookmarks import (see `Acervo.Library.BookmarkImports`).

    * `found` and `truncated` - links in the file, and those left out by the cap
    * `total` - entries to save (links in skipped folders are not entries)
    * `processed`, `created`, `existing`, `failed` - progress so far
    * `choices` - each folder's destination, by its full path joined with
      `" / "` (`""` for loose links): `"collection"`, `"inbox"` or `"skip"`
    * `collections` - the collection names entries refer to by index
    * `entries` - what is left to save, cleared when the import ends. Each is
      `%{"u" => url, "t" => title, "d" => add_date_unix, "c" => collection_index,
      "s" => capture_delay_seconds}`; every key but `"u"` may be nil.
  """
  use Acervo.Schema

  alias Acervo.Accounts.User

  schema "bookmark_imports" do
    field :status, Ecto.Enum, values: [:running, :done, :cancelled, :failed]
    field :found, :integer, default: 0
    field :truncated, :integer, default: 0
    field :total, :integer, default: 0
    field :processed, :integer, default: 0
    field :created, :integer, default: 0
    field :existing, :integer, default: 0
    field :failed, :integer, default: 0
    field :choices, :map, default: %{}
    field :collections, {:array, :string}, default: []
    # Up to 5,000 entries: read a batch at a time, never with the record.
    field :entries, {:array, :map}, default: [], load_in_query: false
    field :finished_at, :utc_datetime

    belongs_to :user, User

    timestamps()
  end

  @type t :: %__MODULE__{}
end
