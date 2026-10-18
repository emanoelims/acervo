defmodule Acervo.Library.Extractors.Instagram do
  @moduledoc """
  Extracts an Instagram post from its Open Graph tags, fetched as the
  Facebook crawler. Login walls are reported as `{:error, :blocked}`.
  """
  @behaviour Acervo.Library.Extractor

  alias Acervo.Library.Capture
  alias Acervo.Library.Extractors.Generic

  @hosts ["instagram.com", "www.instagram.com"]
  @user_agent "facebookexternalhit/1.1"

  @impl true
  def match?(%URI{host: host}), do: host in @hosts

  @impl true
  def extract(%URI{} = uri) do
    with {:ok, capture, final_url} <- Generic.fetch_page(uri, user_agent: @user_agent) do
      if login_wall?(capture, final_url), do: {:error, :blocked}, else: {:ok, capture}
    end
  end

  defp login_wall?(%Capture{image_urls: [_ | _]}, _url), do: false

  defp login_wall?(%Capture{} = capture, url) do
    login_redirect?(url) or (capture.title == "Instagram" and is_nil(capture.description))
  end

  defp login_redirect?(url), do: String.starts_with?(URI.parse(url).path || "", "/accounts/login")
end
