defmodule AcervoWeb.Format do
  @moduledoc """
  Formats dates, counts, prices and durations for the current Gettext locale
  (`pt_BR` or `en`). Plain functions, so components and LiveViews share them
  and they are tested on their own.
  """
  use Gettext, backend: AcervoWeb.Gettext

  @months_en ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @months_pt ~w(jan fev mar abr mai jun jul ago set out nov dez)

  @doc ~S'Formats a date for the current locale: "12 out 2026" or "Oct 12, 2026".'
  def date(%{year: year, month: month, day: day}) do
    case locale() do
      "en" -> "#{Enum.at(@months_en, month - 1)} #{day}, #{year}"
      _pt -> "#{day} #{Enum.at(@months_pt, month - 1)} #{year}"
    end
  end

  @doc ~S'Separates thousands as the locale writes them: "12.345" or "12,345".'
  def number(count) when is_integer(count) do
    separator = if locale() == "pt_BR", do: ".", else: ","

    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1#{separator}")
    |> String.reverse()
  end

  @doc ~S'An estimated price in dollars, never negative: "≈ US$ 0,42" or "≈ $0.42".'
  def usd(amount) when is_number(amount) do
    amount = :erlang.float_to_binary(max(amount, 0.0) * 1.0, decimals: 2)
    amount = if locale() == "pt_BR", do: String.replace(amount, ".", ","), else: amount
    gettext("≈ $%{amount}", amount: amount)
  end

  @doc ~S'A rough duration from seconds: "~1 min", "~12 min" or "~2 h".'
  def duration(seconds) when seconds < 90, do: gettext("~1 min")
  def duration(seconds) when seconds < 5400, do: gettext("~%{count} min", count: round(seconds / 60))
  def duration(seconds), do: gettext("~%{count} h", count: round(seconds / 3600))

  defp locale, do: Gettext.get_locale(AcervoWeb.Gettext)
end
