defmodule Acervo.Library.Article do
  @moduledoc """
  Finds a page's article and turns it into reader HTML with
  `Acervo.Library.Sanitizer`. Pure: nothing here touches the network.

  The article is the longest `article`, `main` or `[role=main]` block by
  text, as in `Acervo.Library.HtmlMeta`. When none holds at least #{200}
  characters, it is the element with the most paragraph text, a simple
  readability-style score, with navigation, headers, footers, asides and
  forms left out.

  Before sanitizing, boilerplate is dropped: scripts, styles, frames, forms,
  buttons, SVG, navigation, asides and footers, plus blocks whose class or id
  says they hold sharing buttons, comments, a newsletter signup, related posts
  or breadcrumbs, and blocks that open with a "Related posts" heading.
  """

  alias Acervo.Library.Sanitizer

  @type content :: %{html: String.t(), images: [String.t()]}

  @min_article 200
  @min_text 140
  @candidates "article, main, [role=main]"
  @boilerplate ~w(script style noscript template iframe form button svg math nav aside footer)
  @outside_article ~w(header)
  @hinted ~w(div section ul ol aside footer header nav form)
  @hints ~w(share sharing sharer social comment comments disqus newsletter subscribe subscription
             related relatedposts breadcrumb breadcrumbs)
  @related_headings ~r/\A(related (posts|articles|stories)|read next|more (posts|stories)|you (may|might) also like)\b/i
  @headings ~w(h2 h3 h4)
  @modifiers ~w(has with no is)
  @paragraphs ~w(p pre blockquote)
  @skipped_text ~w(script style noscript template)

  @markdown_options [
    extension: [
      table: true,
      strikethrough: true,
      autolink: true,
      tasklist: true,
      front_matter_delimiter: "---"
    ],
    render: [unsafe: false, escape: true],
    syntax_highlight: nil
  ]

  @doc """
  Extracts the article from `doc` (a `LazyHTML` document, or HTML) and returns
  its sanitized HTML with the absolute URLs of its images, or `:none` when
  there is too little to read. Relative URLs resolve against `base_url`, or
  the page's own `<base href>`.
  """
  @spec extract(LazyHTML.t() | String.t(), String.t()) :: {:ok, content()} | :none
  def extract(html, base_url) when is_binary(html),
    do: html |> String.replace_invalid() |> LazyHTML.from_document() |> extract(base_url)

  def extract(%LazyHTML{} = doc, base_url) when is_binary(base_url) do
    base = base_href(doc, base_url)

    doc
    |> main_block()
    |> Sanitizer.sanitize(base)
    |> result()
  end

  @doc """
  Renders `markdown` with MDEx, raw HTML escaped, and sanitizes it like a
  page. Relative URLs resolve against `base_url`, where the Markdown came from.
  """
  @spec from_markdown(String.t(), String.t()) :: {:ok, content()} | :none
  def from_markdown(markdown, base_url) when is_binary(markdown) and is_binary(base_url) do
    case MDEx.to_html(String.replace_invalid(markdown), @markdown_options) do
      {:ok, html} -> html |> Sanitizer.sanitize_html(base_url) |> result()
      {:error, _} -> :none
    end
  end

  @doc """
  Re-sanitizes stored reader HTML, handing each image's URL to `image_fun`
  (see the `:image` option of `Acervo.Library.Sanitizer.sanitize/3`).
  """
  @spec replace_images(String.t(), String.t(), Sanitizer.image_fun()) :: String.t()
  def replace_images(html, base_url, image_fun) when is_binary(html) and is_function(image_fun, 1) do
    {html, _images} = Sanitizer.sanitize_html(html, base_url, image: image_fun)
    html
  end

  defp result({html, images}) do
    if images == [] and text_length(html) < @min_text,
      do: :none,
      else: {:ok, %{html: html, images: images}}
  end

  defp text_length(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim() |> String.length()

  defp base_href(doc, page_url) do
    case doc |> LazyHTML.query("base[href]") |> LazyHTML.attribute("href") do
      [href | _] -> Sanitizer.safe_url(href, page_url) || page_url
      [] -> page_url
    end
  end

  ## Choosing the block

  defp main_block(doc) do
    article =
      doc
      |> LazyHTML.query(@candidates)
      |> LazyHTML.to_tree()
      |> Enum.map(&clean(&1, []))
      |> Enum.reject(&is_nil/1)
      |> Enum.max_by(&text_length_of/1, fn -> nil end)

    if article && text_length_of(article) >= @min_article do
      [article]
    else
      doc |> LazyHTML.query("body") |> LazyHTML.to_tree() |> Enum.map(&clean(&1, @outside_article)) |> best_scored()
    end
  end

  # The element with the most paragraph text: each paragraph counts for its
  # parent, and half for its grandparent.
  defp best_scored(tree) do
    {best, _score} =
      tree
      |> elements()
      |> Enum.map(&{&1, score(&1)})
      |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)

    case best do
      nil -> tree
      node -> [node]
    end
  end

  defp elements(nodes) do
    Enum.flat_map(nodes, fn
      {_tag, _attrs, children} = node -> [node | elements(children)]
      _ -> []
    end)
  end

  defp score({_tag, _attrs, children}) do
    Enum.reduce(children, 0, fn
      {tag, _, _} = child, acc when tag in @paragraphs -> acc + text_length_of(child)
      {_tag, _, grandchildren}, acc -> acc + paragraph_text(grandchildren) / 2
      _text, acc -> acc
    end)
  end

  defp paragraph_text(nodes) do
    Enum.reduce(nodes, 0, fn
      {tag, _, _} = node, acc when tag in @paragraphs -> acc + text_length_of(node)
      _node, acc -> acc
    end)
  end

  defp text_length_of(nil), do: 0
  defp text_length_of(text) when is_binary(text), do: text |> String.trim() |> String.length()
  defp text_length_of({:comment, _}), do: 0
  defp text_length_of({tag, _attrs, _children}) when tag in @skipped_text, do: 0
  defp text_length_of({_tag, _attrs, children}), do: Enum.reduce(children, 0, &(text_length_of(&1) + &2))

  ## Boilerplate

  defp clean({tag, attrs, children} = node, extra) do
    cond do
      tag in @boilerplate or tag in extra -> nil
      tag in ["pre", "code"] -> node
      tag in @hinted and (hinted?(attrs) or related?(children)) -> nil
      true -> {tag, attrs, children |> Enum.map(&clean(&1, extra)) |> Enum.reject(&is_nil/1)}
    end
  end

  defp clean(node, _extra), do: node

  # A block that opens with a "Related posts" heading.
  defp related?(children) do
    case Enum.find(children, &match?({_, _, _}, &1)) do
      {tag, _attrs, _children} = heading when tag in @headings ->
        heading
        |> List.wrap()
        |> LazyHTML.from_tree()
        |> LazyHTML.text()
        |> String.trim()
        |> String.match?(@related_headings)

      _ ->
        false
    end
  end

  defp hinted?(attrs) do
    attrs
    |> Enum.filter(fn {name, _} -> name in ["class", "id"] end)
    |> Enum.flat_map(fn {_, value} -> value |> String.downcase() |> String.split() end)
    |> Enum.any?(fn token ->
      case String.split(token, ["-", "_"], trim: true) do
        [modifier | _] when modifier in @modifiers -> false
        parts -> Enum.any?(parts, &(&1 in @hints))
      end
    end)
  end
end
