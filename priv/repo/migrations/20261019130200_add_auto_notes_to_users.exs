defmodule Acervo.Repo.Migrations.AddAutoNotesToUsers do
  use Ecto.Migration

  # When AI notes are written without asking: never (the default), for long
  # articles, or always. The notes worker reads it, so it lives on the user,
  # not in the browser.
  def change do
    alter table(:users) do
      add :auto_notes, :string, null: false, default: "never"
    end
  end
end
