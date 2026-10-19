defmodule AcervoWeb.Styleguide.CSS do
  @moduledoc """
  Extracts a dev page's `<style :type={AcervoWeb.Styleguide.CSS}>` into the
  colocated CSS bundle as is. Only dev and test compile `dev/`, so these
  styles never reach production's `app.css`.
  """
  use Phoenix.LiveView.ColocatedCSS

  @impl true
  def transform("style", _attrs, css, _meta), do: {:ok, css, []}
end
