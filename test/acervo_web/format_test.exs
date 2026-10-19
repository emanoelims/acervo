defmodule AcervoWeb.FormatTest do
  use ExUnit.Case, async: true

  alias AcervoWeb.Format

  defp in_locale(locale, fun) do
    Gettext.put_locale(AcervoWeb.Gettext, locale)
    fun.()
  end

  describe "date/1" do
    test "writes the day first in Portuguese and the month first in English" do
      assert in_locale("pt_BR", fn -> Format.date(~D[2026-10-12]) end) == "12 out 2026"
      assert in_locale("en", fn -> Format.date(~U[2026-10-12 08:00:00Z]) end) == "Oct 12, 2026"
    end
  end

  describe "number/1" do
    test "separates thousands for the locale" do
      assert in_locale("pt_BR", fn -> Format.number(1_234_567) end) == "1.234.567"
      assert in_locale("en", fn -> Format.number(12_345) end) == "12,345"
      assert in_locale("en", fn -> Format.number(999) end) == "999"
    end
  end

  describe "usd/1" do
    test "rounds to cents with the locale's decimal mark and never goes negative" do
      assert in_locale("pt_BR", fn -> Format.usd(0.4249) end) == "≈ US$ 0,42"
      assert in_locale("en", fn -> Format.usd(3) end) == "≈ $3.00"
      assert in_locale("en", fn -> Format.usd(-1.0) end) == "≈ $0.00"
    end
  end

  describe "duration/1" do
    test "rounds to a minute, minutes or hours" do
      in_locale("en", fn ->
        assert Format.duration(10) == "~1 min"
        assert Format.duration(720) == "~12 min"
        assert Format.duration(7200) == "~2 h"
      end)
    end
  end
end
