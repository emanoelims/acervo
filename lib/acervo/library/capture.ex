defmodule Acervo.Library.Capture do
  @moduledoc """
  The preview of a link produced by an extractor. Every field is optional.

  `canonical_url` is the page's own `<link rel="canonical">` and `final_url`
  the URL the page was fetched from after redirects.
  """

  @type t :: %__MODULE__{
          title: String.t() | nil,
          description: String.t() | nil,
          author: String.t() | nil,
          site_name: String.t() | nil,
          published_at: DateTime.t() | nil,
          text: String.t() | nil,
          image_urls: [String.t()],
          canonical_url: String.t() | nil,
          final_url: String.t() | nil
        }

  defstruct title: nil,
            description: nil,
            author: nil,
            site_name: nil,
            published_at: nil,
            text: nil,
            image_urls: [],
            canonical_url: nil,
            final_url: nil
end
