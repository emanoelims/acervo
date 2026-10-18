defmodule AcervoWeb.PageController do
  use AcervoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
