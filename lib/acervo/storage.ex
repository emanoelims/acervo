defmodule Acervo.Storage do
  @moduledoc """
  Behaviour for storing captured images. The active implementation is
  configured with `config :acervo, :storage`, defaulting to `Acervo.Storage.Database`.
  """

  alias Acervo.Accounts.Scope
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage

  @callback put(Scope.t(), Link.t(), attrs :: map()) :: {:ok, LinkImage.t()} | {:error, Ecto.Changeset.t()}
  @callback fetch(Scope.t(), id :: Ecto.UUID.t()) :: {:ok, LinkImage.t()} | :error

  def put(scope, link, attrs), do: impl().put(scope, link, attrs)
  def fetch(scope, id), do: impl().fetch(scope, id)

  defp impl, do: Application.get_env(:acervo, :storage, Acervo.Storage.Database)
end
