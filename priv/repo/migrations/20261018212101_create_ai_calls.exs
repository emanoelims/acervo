defmodule Acervo.Repo.Migrations.CreateAiCalls do
  use Ecto.Migration

  # One row per model call, success or not: tokens, cost and duration. No
  # prompt or response content is stored. Null tokens or cost mean the
  # provider did not report them, never a measured zero.
  def change do
    create table(:ai_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :link_id, references(:links, type: :binary_id, on_delete: :nilify_all)
      add :operation, :string, null: false
      add :model, :string, null: false
      add :status, :string, null: false
      add :error, :string, size: 60
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cost_usd, :decimal, precision: 12, scale: 8
      add :duration_ms, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ai_calls, [:inserted_at])
    create index(:ai_calls, [:user_id])
    create index(:ai_calls, [:link_id])
  end
end
