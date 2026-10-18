defmodule Acervo.PageFixtures do
  @moduledoc "Reads the hand-written HTML and JSON pages under `test/support/fixtures/pages`."

  @dir Path.expand("pages", __DIR__)

  def page(name), do: File.read!(Path.join(@dir, name))
end
