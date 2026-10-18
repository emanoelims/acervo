defmodule Acervo.Repo do
  use Ecto.Repo,
    otp_app: :acervo,
    adapter: Ecto.Adapters.Postgres
end
