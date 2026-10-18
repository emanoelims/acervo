defmodule AcervoWeb.I18n do
  @moduledoc "Runtime translation of dynamic UI labels."

  def t(message, bindings \\ %{})
  def t(nil, _bindings), do: nil

  def t(message, bindings) when is_binary(message), do: Gettext.gettext(AcervoWeb.Gettext, message, bindings)
end
