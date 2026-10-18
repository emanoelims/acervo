defmodule Acervo.Accounts.Allowlist do
  @moduledoc """
  Restricts registration to configured emails. `:all` (dev and test default)
  allows anyone; production requires `ACERVO_ALLOWED_EMAILS`.
  """

  @spec allowed?(String.t()) :: boolean()
  def allowed?(email) when is_binary(email) do
    case Application.get_env(:acervo, :allowed_emails, :all) do
      :all -> true
      emails when is_list(emails) -> normalize(email) in emails
    end
  end

  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(value) when is_binary(value) do
    value |> String.split(",") |> Enum.map(&normalize/1) |> Enum.reject(&(&1 == ""))
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
