defmodule AcervoWeb.Styleguide.Examples do
  @moduledoc """
  In-memory example data for `/dev/styleguide`: links of every kind,
  collections and suggestions, built as structs and never saved. Images are
  inline SVGs carrying their own `src` (see `AcervoWeb.LinkPresenter.image_src/1`),
  so nothing touches the database or the network.
  """
  alias Acervo.Collections.Collection
  alias Acervo.Collections.Suggestion
  alias Acervo.Library.Link

  @poster """
  <svg xmlns="http://www.w3.org/2000/svg" width="960" height="1200" viewBox="0 0 960 1200">
    <defs>
      <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#f6c48f"/><stop offset=".55" stop-color="#e98a6b"/><stop offset="1" stop-color="#6d4a7a"/>
      </linearGradient>
    </defs>
    <rect width="960" height="1200" fill="url(#sky)"/>
    <circle cx="640" cy="430" r="150" fill="#fbe3b0" opacity=".9"/>
    <path d="M0 860 L220 700 L400 820 L620 640 L960 880 L960 1200 L0 1200 Z" fill="#4a3557"/>
    <path d="M0 980 L300 860 L560 960 L820 860 L960 920 L960 1200 L0 1200 Z" fill="#2f2440"/>
  </svg>
  """

  @thumbnail """
  <svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
    <rect width="1280" height="720" fill="#1f2a36"/>
    <rect x="120" y="140" width="520" height="440" rx="28" fill="#2f4256"/>
    <rect x="700" y="140" width="460" height="200" rx="28" fill="#3d5a73"/>
    <rect x="700" y="380" width="460" height="200" rx="28" fill="#4f7391"/>
  </svg>
  """

  @screenshot """
  <svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760">
    <rect width="1200" height="760" fill="#f3f1ec"/>
    <rect x="80" y="80" width="560" height="40" rx="8" fill="#2b2a27"/>
    <rect x="80" y="160" width="1040" height="16" rx="8" fill="#c9c4b8"/>
    <rect x="80" y="196" width="980" height="16" rx="8" fill="#c9c4b8"/>
    <rect x="80" y="232" width="1010" height="16" rx="8" fill="#c9c4b8"/>
    <rect x="80" y="300" width="1040" height="380" rx="20" fill="#d9d3c5"/>
  </svg>
  """

  @doc "An example image: `:poster` (4:5), `:thumbnail` (16:9) or `:screenshot`."
  def image(:poster), do: %{id: "poster", src: data_uri(@poster), width: 960, height: 1200}
  def image(:thumbnail), do: %{id: "thumbnail", src: data_uri(@thumbnail), width: 1280, height: 720}
  def image(:screenshot), do: %{id: "screenshot", src: data_uri(@screenshot), width: 1200, height: 760}

  defp data_uri(svg), do: "data:image/svg+xml;base64," <> Base.encode64(svg)

  @doc "The example collections, with their link counts."
  def collections do
    [
      %Collection{id: uuid(101), name: "Design", slug: "design", link_count: 24},
      %Collection{id: uuid(102), name: "Type", slug: "type", link_count: 9},
      %Collection{id: uuid(103), name: "Reading", slug: "reading", link_count: 31}
    ]
  end

  defp collection(slug), do: Enum.find(collections(), &(&1.slug == slug))

  @doc "A pending suggestion of an existing collection and one of a new name."
  def suggestions do
    design = collection("design")

    [
      %Suggestion{
        id: uuid(201),
        collection: design,
        collection_id: design.id,
        reason: "A poster study in warm gradients.",
        status: :pending
      },
      %Suggestion{
        id: uuid(202),
        collection: nil,
        collection_id: nil,
        proposed_name: "Landscapes",
        reason: "Mountains at dusk, drawn flat.",
        status: :pending
      }
    ]
  end

  @doc """
  One link per card kind, keyed by name: `:pending`, `:text`, `:image`,
  `:generic_image`, `:video`, plus the inbox's `:suggested` and `:reading`.
  """
  def links do
    %{
      pending:
        link(1,
          canonical_url: "https://www.instagram.com/p/example",
          source: :instagram,
          status: :pending
        ),
      text:
        link(2,
          canonical_url: "https://example.org/essays/small-software",
          title: "The long tail of small software",
          description: "Why tools made for a handful of people tend to last longer than the ones made for everyone.",
          author: "Ana Lima",
          site_name: "Example Essays",
          capture_error: "The page blocked the preview.",
          embeddable: false,
          text_excerpt:
            "Small tools are written for someone in particular. They change slowly, because the people who use them are few and known. That is also why they last. A tool made for everyone has to keep up with everyone, and so it keeps changing until nobody recognizes it.",
          collections: [collection("reading")]
        ),
      image:
        link(3,
          canonical_url: "https://x.com/example/status/1",
          source: :x,
          title: "Dusk over the ridge",
          description: "A flat poster of mountains at dusk, warm gradient sky.",
          author: "@example",
          site_name: "X",
          images: [image(:poster), image(:screenshot)],
          collections: [collection("design")],
          suggestions: suggestions(),
          note: "Good reference for the onboarding illustration.",
          ai_notes:
            "A flat poster of a mountain range at dusk, built from a few layered shapes and a warm gradient.\n\n" <>
              "- Three ridges in purple, darkest in front, give depth without detail.\n" <>
              "- The sky runs from peach to violet; the sun is a pale disc.\n" <>
              "- Works as a calm, wordless header image.",
          ai_notes_at: ~U[2026-10-18 09:05:00Z],
          image_description: "Layered purple mountains under an orange sky with a pale sun."
        ),
      generic_image:
        link(4,
          canonical_url: "https://example.com/type-specimen",
          title: "A type specimen, set in one weight",
          description: "Every glyph of a grotesque, printed large.",
          images: [image(:screenshot)]
        ),
      video:
        link(5,
          canonical_url: "https://www.youtube.com/watch?v=example",
          source: :youtube,
          title: "Grids, from the ground up",
          images: [image(:thumbnail)]
        ),
      suggested:
        link(6,
          canonical_url: "https://example.net/poster-archive",
          title: "An archive of transit posters",
          description: "Scans of mid-century transit posters.",
          triaged_at: nil,
          collections: [collection("type")],
          suggestions: suggestions()
        ),
      reading:
        link(7,
          canonical_url: "https://example.io/notes/color",
          title: "Notes on color in interfaces",
          triaged_at: nil,
          enrichment_status: :pending
        )
    }
  end

  @doc """
  The open link's related section: the text link connected by hand, then
  two similar ones, with more to see.
  """
  def related do
    links = links()
    %{manual: [links.text], similar: [links.video, links.generic_image], more?: true}
  end

  defp link(n, attrs) do
    struct!(
      %Link{
        id: uuid(n),
        source: :generic,
        status: :ready,
        published_at: ~U[2026-10-12 09:00:00Z],
        inserted_at: ~U[2026-10-18 09:00:00Z],
        triaged_at: ~U[2026-10-18 10:00:00Z],
        enrichment_status: :ready,
        images: [],
        collections: [],
        suggestions: []
      },
      attrs
    )
  end

  defp uuid(n), do: "00000000-0000-7000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
