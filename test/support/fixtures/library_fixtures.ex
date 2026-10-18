defmodule Acervo.LibraryFixtures do
  @moduledoc """
  Test helpers for `Acervo.Library`.
  """

  alias Acervo.Library

  @images_dir Path.expand("images", __DIR__)

  def unique_link_url, do: "https://example.com/posts/#{System.unique_integer([:positive])}"

  @doc "Saves a link through `Acervo.Library.save_link/2`, enqueueing its capture job."
  def link_fixture(scope, url \\ unique_link_url()) do
    {:ok, link, :created} = Library.save_link(scope, url)
    link
  end

  def image_fixture(name), do: File.read!(Path.join(@images_dir, name))
end
