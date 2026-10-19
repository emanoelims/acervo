defmodule Acervo.LibraryFixtures do
  @moduledoc """
  Test helpers for `Acervo.Library`.
  """

  alias Acervo.Library
  alias Acervo.Library.Screenshots

  @images_dir Path.expand("images", __DIR__)

  def unique_link_url, do: "https://example.com/posts/#{System.unique_integer([:positive])}"

  @doc "Saves a link through `Acervo.Library.save_link/2`, enqueueing its capture job."
  def link_fixture(scope, url \\ unique_link_url()) do
    {:ok, link, :created} = Library.save_link(scope, url)
    link
  end

  def image_fixture(name), do: File.read!(Path.join(@images_dir, name))

  @doc """
  Turns the screenshot service on for the test, restoring the config on
  exit. The config is global: only `async: false` tests may use it. Requests
  go to `Req.Test` stubs named `Acervo.Library.Screenshots`.
  """
  def enable_snapshots(_context \\ %{}) do
    previous = Application.get_env(:acervo, Screenshots)
    Application.put_env(:acervo, Screenshots, url: "https://shots.test", token: String.duplicate("t", 64))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:acervo, Screenshots, previous) end)
    :ok
  end
end
