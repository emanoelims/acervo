defmodule Acervo.Library.Sanitizer do
  @moduledoc """
  Rebuilds untrusted HTML from an allowlist, for the reader view.

  Nothing is copied from the input as markup: every element in the output is
  one of the allowed tags below, rebuilt with only the attributes allowed for
  it, and every text and attribute value is escaped. Its output is the only
  HTML `Acervo.Library.Link`'s `content_html` holds, and the reader view
  renders it raw.

    * Blocks: `p`, `h2`–`h6` (an `h1` becomes `h2`), `ul`, `ol`, `li`,
      `blockquote`, `pre`, `hr`, `figure`, `figcaption` and tables (`table`,
      `thead`, `tbody`, `tr`, `th`, `td`).
    * Inline: `a`, `code`, `em`, `strong`, `b`, `i`, `u`, `s` (also for `del`
      and `strike`), `sup`, `sub`, `br` and `img`. A disabled checkbox (a
      Markdown task list) becomes ☑ or ☐.
    * `a` keeps only an absolute `http(s)` `href`, resolved against the base
      URL, and always opens in a new tab without referrer or opener. A link
      inside another link is unwrapped.
    * `img` keeps `src` (or, when `src` is missing or a placeholder, its lazy
      `data-src`/`srcset` source), `alt`, `width` and `height`. The `:image`
      option decides its final `src`.
    * `th`/`td` keep `colspan`/`rowspan`, and `pre`/`code` a plain
      `language-*` class.

  Scripts, styles, frames, forms, embedded SVG and MathML, comments, and
  elements that are `hidden` or `aria-hidden` are dropped with their content.
  Any other element is unwrapped, keeping its children; one that is a block
  in the source still separates paragraphs. Bare text between blocks is
  wrapped in paragraphs, and blocks left empty are dropped.

  Tables come wrapped in a `div.table-wrap`, the one attribute the output
  adds besides a link's `target` and `rel`.

  The output stops at a top-level block boundary before #{300_000} bytes,
  and keeps at most #{20} distinct images.
  """

  @max_bytes 300_000
  @max_images 20
  @max_url 2048

  # Dropped with everything inside.
  @dropped ~w(script style noscript iframe frame frameset object embed applet form button input select
              textarea option optgroup datalist svg math template canvas audio video source track map
              area nav aside footer head title meta link base dialog portal slot)

  @headings ~w(h2 h3 h4 h5 h6)
  @flow_blocks ~w(p ul ol li blockquote pre hr figure figcaption table thead tbody tr th td) ++ @headings
  @inline ~w(a code em strong b i u s sup sub br img)
  @renamed %{"h1" => "h2", "del" => "s", "strike" => "s", "tfoot" => "tbody"}

  # Unknown elements that are blocks in the source: unwrapped, they still
  # separate the text around them.
  @block_like ~w(div section article main header address center details summary dl dt dd hgroup
                 fieldset legend caption search menu body html)

  # Containers whose loose text becomes paragraphs once they hold a block.
  @flow_containers ~w(blockquote li td th)

  @lazy_sources ~w(data-src data-lazy-src data-original data-url)
  @lazy_srcsets ~w(data-srcset data-lazy-srcset srcset)
  @language ~r/\Alanguage-[a-z0-9_+#.-]{1,30}\z/i

  @type image_fun :: (String.t() -> {:ok, %{src: String.t(), width: integer() | nil, height: integer() | nil}} | :drop)

  @doc """
  Sanitizes `tree` (a `LazyHTML.Tree`) and returns the HTML with the images
  it kept, in order.

  ## Options

    * `:image` - called with each image's absolute URL; returns
      `{:ok, %{src: src, width: w, height: h}}` to render it, or `:drop`.
      Defaults to keeping the absolute URL and the source's dimensions.
  """
  @spec sanitize(LazyHTML.Tree.t(), String.t(), keyword()) :: {String.t(), [String.t()]}
  def sanitize(tree, base_url, opts \\ []) when is_list(tree) and is_binary(base_url) do
    ctx = %{
      base: URI.parse(base_url),
      image: Keyword.get(opts, :image),
      in_a: false,
      in_pre: false
    }

    tree
    |> Enum.flat_map(&node(&1, ctx))
    |> flow(:top)
    |> serialize()
  end

  @doc "Parses a fragment of HTML and sanitizes it with `sanitize/3`."
  @spec sanitize_html(String.t(), String.t(), keyword()) :: {String.t(), [String.t()]}
  def sanitize_html(html, base_url, opts \\ []) when is_binary(html) do
    html |> String.replace_invalid() |> LazyHTML.from_fragment() |> LazyHTML.to_tree() |> sanitize(base_url, opts)
  end

  @doc """
  Resolves `url` against `base` and returns it when it is an absolute
  `http(s)` URL with a host, else `nil`. Tabs and line breaks are removed,
  as browsers do, before the scheme is read.
  """
  @spec safe_url(String.t() | nil, URI.t() | String.t()) :: String.t() | nil
  def safe_url(nil, _base), do: nil

  def safe_url(url, base) when is_binary(url) do
    url =
      url
      |> String.replace(~r/[\t\n\r]/, "")
      |> String.trim(<<0::8>>)
      |> String.trim()
      |> String.replace(" ", "%20")

    with false <- url == "" or String.match?(url, ~r/[\x00-\x1f\x7f]/),
         {:ok, relative} <- URI.new(url),
         %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) and host != "" <-
           URI.merge(base, relative),
         true <- String.downcase(scheme) in ["http", "https"],
         string when byte_size(string) <= @max_url <- URI.to_string(%{uri | scheme: String.downcase(scheme)}) do
      string
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  ## Nodes

  # Returns a list of output nodes: `{:el, tag, attrs, children}`,
  # `{:text, text}` or `:break`, which marks an unwrapped block.
  defp node(text, %{in_pre: true}) when is_binary(text), do: [{:text, String.replace_invalid(text)}]

  defp node(text, _ctx) when is_binary(text),
    do: [{:text, text |> String.replace_invalid() |> String.replace(~r/[ \t\r\n\f]+/, " ")}]

  defp node({:comment, _}, _ctx), do: []

  defp node({tag, attrs, children}, ctx) do
    tag = Map.get(@renamed, tag, tag)

    cond do
      hidden?(attrs) -> []
      tag == "input" -> checkbox(attrs)
      tag in @dropped -> []
      tag in @flow_blocks or tag in @inline -> element(tag, attrs, children, ctx)
      tag in @block_like -> unwrap_block(children, ctx)
      true -> children(children, ctx)
    end
  end

  defp children(children, ctx), do: Enum.flat_map(children, &node(&1, ctx))

  defp unwrap_block(children, %{in_pre: true} = ctx) do
    kids = children(children, ctx)
    if ends_with_newline?(kids), do: kids, else: kids ++ [{:text, "\n"}]
  end

  defp unwrap_block(children, ctx), do: [:break | children(children, ctx)] ++ [:break]

  defp ends_with_newline?(kids) do
    case List.last(kids) do
      {:text, text} -> String.ends_with?(text, "\n")
      _ -> false
    end
  end

  defp checkbox(attrs) do
    if attr(attrs, "type") == "checkbox" and has_attr?(attrs, "disabled") do
      [{:text, if(has_attr?(attrs, "checked"), do: "☑", else: "☐")}]
    else
      []
    end
  end

  defp hidden?(attrs) do
    has_attr?(attrs, "hidden") or
      String.downcase(attr(attrs, "aria-hidden") || "") == "true" or
      hidden_style?(attr(attrs, "style"))
  end

  defp hidden_style?(nil), do: false

  defp hidden_style?(style) do
    style = style |> String.downcase() |> String.replace(~r/\s+/, "")
    String.contains?(style, "display:none") or String.contains?(style, "visibility:hidden")
  end

  ## Elements

  defp element("a", attrs, children, ctx) do
    kids = children(children, %{ctx | in_a: true})

    case {ctx.in_a, safe_url(attr(attrs, "href"), ctx.base)} do
      # A link around blocks (a card) can't sit inside a paragraph.
      {false, href} when is_binary(href) ->
        if Enum.any?(kids, &block?/1), do: kids, else: inline("a", [{"href", href}], kids)

      _ ->
        kids
    end
  end

  defp element("img", attrs, _children, ctx) do
    with src when is_binary(src) <- image_url(attrs, ctx.base),
         false <- tracking_pixel?(attrs),
         {:ok, image} <- image(ctx.image, src, attrs) do
      [{:el, "img", img_attrs(image, attrs), []}]
    else
      _ -> []
    end
  end

  defp element(tag, _attrs, _children, _ctx) when tag in ["br", "hr"], do: [{:el, tag, [], []}]

  defp element("pre", attrs, children, ctx) do
    kids = children |> children(%{ctx | in_pre: true}) |> inline_only("\n")
    if blank?(kids), do: [], else: [{:el, "pre", language(attrs), kids}]
  end

  defp element("code", attrs, children, ctx) do
    kids = children |> children(ctx) |> inline_only(if(ctx.in_pre, do: "\n", else: " "))
    inline("code", language(attrs), kids)
  end

  defp element(tag, attrs, children, ctx) when tag in ["td", "th"] do
    kids = children |> children(ctx) |> flow(tag)
    [{:el, tag, spans(attrs), trim_run(kids)}]
  end

  defp element(tag, _attrs, children, ctx) when tag in ["ul", "ol"] do
    kids = structural(children, ctx)
    if Enum.any?(kids, &match?({:el, "li", _, _}, &1)), do: [{:el, tag, [], kids}], else: loose(kids)
  end

  defp element("table", _attrs, children, ctx), do: rows("table", children, ctx)
  defp element(tag, _attrs, children, ctx) when tag in ["thead", "tbody"], do: rows(tag, children, ctx)

  defp element("tr", _attrs, children, ctx) do
    kids = structural(children, ctx)
    if Enum.any?(kids, &match?({:el, cell, _, _} when cell in ["td", "th"], &1)), do: [{:el, "tr", [], kids}], else: []
  end

  defp element("figure", _attrs, children, ctx) do
    kids = structural(children, ctx)
    if blank?(kids), do: [], else: [{:el, "figure", [], kids}]
  end

  defp element(tag, _attrs, children, ctx) when tag in @flow_containers do
    kids = children |> children(ctx) |> flow(tag)
    if blank?(kids), do: [], else: [{:el, tag, [], trim_run(kids)}]
  end

  defp element(tag, _attrs, children, ctx) when tag in ["p", "figcaption" | @headings] do
    kids = children |> children(ctx) |> inline_only(" ")
    if blank?(kids), do: [], else: [{:el, tag, [], trim_run(kids)}]
  end

  defp element(tag, _attrs, children, ctx) when tag in @inline do
    inline(tag, [], children |> children(ctx) |> inline_only(" "))
  end

  # Lists, tables and figures hold elements; whitespace between them goes.
  defp structural(children, ctx) do
    children |> children(ctx) |> Enum.reject(&(&1 == :break or whitespace?(&1)))
  end

  # An inline element without content leaves its whitespace, if any.
  defp inline(tag, attrs, kids) do
    if blank?(kids), do: Enum.filter(kids, &match?({:text, _}, &1)), else: [{:el, tag, attrs, kids}]
  end

  defp rows(tag, children, ctx) do
    kids = structural(children, ctx)
    if Enum.any?(kids, &has_row?/1), do: [{:el, tag, [], kids}], else: []
  end

  defp has_row?({:el, "tr", _, _}), do: true
  defp has_row?({:el, tag, _, kids}) when tag in ["thead", "tbody"], do: Enum.any?(kids, &has_row?/1)
  defp has_row?(_node), do: false

  # A list without items keeps its content as loose nodes.
  defp loose(kids), do: [:break | kids] ++ [:break]

  defp inline_only(kids, separator), do: Enum.map(kids, &if(&1 == :break, do: {:text, separator}, else: &1))

  ## Flow

  # Loose text and inline elements next to blocks become paragraphs. At the
  # top level they always do.
  defp flow(kids, container) do
    if container == :top or Enum.any?(kids, &block?/1) do
      kids
      |> Enum.chunk_by(&inline?/1)
      |> Enum.flat_map(&paragraph/1)
    else
      kids
    end
  end

  defp paragraph([first | _] = run) do
    cond do
      not inline?(first) -> Enum.reject(run, &(&1 == :break))
      blank?(run) -> []
      true -> [{:el, "p", [], trim_run(run)}]
    end
  end

  # Drops whitespace and line breaks at both ends, and trims the text there.
  defp trim_run(run) do
    run
    |> Enum.drop_while(&whitespace?/1)
    |> trim_first(&String.trim_leading/1)
    |> Enum.reverse()
    |> Enum.drop_while(&whitespace?/1)
    |> trim_first(&String.trim_trailing/1)
    |> Enum.reverse()
  end

  defp trim_first([{:text, text} | rest], trim), do: [{:text, trim.(text)} | rest]
  defp trim_first(run, _trim), do: run

  defp whitespace?({:text, text}), do: String.trim(text) == ""
  defp whitespace?({:el, "br", _, _}), do: true
  defp whitespace?(_node), do: false

  defp block?(:break), do: true
  defp block?({:el, tag, _, _}), do: tag in @flow_blocks
  defp block?(_node), do: false

  defp inline?(node), do: not block?(node)

  defp blank?(kids), do: not Enum.any?(kids, &content?/1)

  defp content?({:text, text}), do: String.trim(text) != ""
  defp content?({:el, tag, _, _}) when tag in ["img", "hr"], do: true
  defp content?({:el, _tag, _, kids}), do: Enum.any?(kids, &content?/1)
  defp content?(:break), do: false

  ## Attributes

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp has_attr?(attrs, name), do: List.keymember?(attrs, name, 0)

  defp language(attrs) do
    attrs
    |> attr("class")
    |> Kernel.||("")
    |> String.split()
    |> Enum.find(&Regex.match?(@language, &1))
    |> case do
      nil -> []
      class -> [{"class", String.downcase(class)}]
    end
  end

  defp spans(attrs) do
    Enum.flat_map(["colspan", "rowspan"], fn name ->
      case small_int(attr(attrs, name), 1..100) do
        nil -> []
        value -> [{name, Integer.to_string(value)}]
      end
    end)
  end

  defp small_int(nil, _range), do: nil

  defp small_int(value, range) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> if int in range, do: int
      _ -> nil
    end
  end

  ## Images

  defp image_url(attrs, base) do
    src = attr(attrs, "src")

    candidates =
      if placeholder?(src),
        do: Enum.map(@lazy_sources, &attr(attrs, &1)) ++ Enum.map(@lazy_srcsets, &best_source(attr(attrs, &1))),
        else: [src]

    Enum.find_value(candidates, &safe_url(&1, base))
  end

  defp placeholder?(nil), do: true

  defp placeholder?(src) do
    src = String.trim(src)

    src == "" or String.starts_with?(String.downcase(src), "data:") or
      Regex.match?(~r/(placeholder|blank|spacer|transparent|lazy|pixel)[^\/]*\.(gif|png|svg)/i, src)
  end

  # The srcset candidate closest to 1600px wide, the largest stored size.
  defp best_source(nil), do: nil

  defp best_source(srcset) do
    candidates =
      srcset
      |> String.split(~r/,\s+/, trim: true)
      |> Enum.map(fn candidate ->
        case String.split(String.trim(candidate), ~r/\s+/, parts: 2) do
          [url, descriptor] -> {url, width(descriptor)}
          [url] -> {url, 0}
        end
      end)

    {fitting, larger} = Enum.split_with(candidates, fn {_url, width} -> width <= 1600 end)

    case {Enum.max_by(fitting, &elem(&1, 1), fn -> nil end), Enum.min_by(larger, &elem(&1, 1), fn -> nil end)} do
      {{url, _}, _} -> url
      {nil, {url, _}} -> url
      {nil, nil} -> nil
    end
  end

  defp width(descriptor) do
    case Integer.parse(descriptor) do
      {w, "w"} -> w
      {x, "x"} -> x * 800
      _ -> 0
    end
  end

  defp tracking_pixel?(attrs) do
    Enum.any?(["width", "height"], fn name -> small_int(attr(attrs, name), 0..2) != nil end)
  end

  defp image(nil, src, attrs) do
    {:ok,
     %{src: src, width: small_int(attr(attrs, "width"), 1..20_000), height: small_int(attr(attrs, "height"), 1..20_000)}}
  end

  defp image(fun, src, _attrs) when is_function(fun, 1), do: fun.(src)

  defp img_attrs(image, attrs) do
    alt = attrs |> attr("alt") |> Kernel.||("") |> String.replace_invalid()

    [{"src", image.src}, {"alt", alt}] ++
      for {name, value} <- [width: image.width, height: image.height],
          is_integer(value),
          do: {Atom.to_string(name), Integer.to_string(value)}
  end

  ## Serialization

  # Top-level blocks are kept while they fit, and images past the limit are
  # left out, so the HTML and its image list agree.
  defp serialize(blocks) do
    state = %{size: 0, images: [], seen: MapSet.new()}

    {html, state} =
      Enum.reduce_while(blocks, {[], state}, fn block, {acc, state} ->
        {iodata, next} = render(block, state)
        size = state.size + IO.iodata_length(iodata)

        if size > @max_bytes, do: {:halt, {acc, state}}, else: {:cont, {[acc, iodata], %{next | size: size}}}
      end)

    {IO.iodata_to_binary(html), Enum.reverse(state.images)}
  end

  defp render({:text, text}, state), do: {escape(text), state}

  defp render({:el, "img", attrs, []}, state) do
    src = attr(attrs, "src")

    cond do
      MapSet.member?(state.seen, src) ->
        {tag("img", attrs, nil), state}

      MapSet.size(state.seen) < @max_images ->
        {tag("img", attrs, nil), %{state | seen: MapSet.put(state.seen, src), images: [src | state.images]}}

      true ->
        {[], state}
    end
  end

  defp render({:el, tag, [], []}, state) when tag in ["br", "hr"], do: {tag(tag, [], nil), state}

  # A table scrolls sideways inside its wrapper.
  defp render({:el, "table", attrs, kids}, state) do
    {inner, state} = Enum.map_reduce(kids, state, &render/2)
    {tag("div", [{"class", "table-wrap"}], tag("table", attrs, inner)), state}
  end

  defp render({:el, tag, attrs, kids}, state) do
    {inner, state} = Enum.map_reduce(kids, state, &render/2)
    {tag(tag, extra_attrs(tag, attrs), inner), state}
  end

  defp extra_attrs("a", attrs), do: attrs ++ [{"target", "_blank"}, {"rel", "noopener noreferrer nofollow"}]
  defp extra_attrs(_tag, attrs), do: attrs

  defp tag(name, attrs, nil), do: ["<", name, Enum.map(attrs, &attribute/1), ">"]
  defp tag(name, attrs, inner), do: ["<", name, Enum.map(attrs, &attribute/1), ">", inner, "</", name, ">"]

  defp attribute({name, value}), do: [" ", name, "=\"", escape(value), "\""]

  defp escape(text), do: Plug.HTML.html_escape_to_iodata(text)
end
