defmodule Acervo.Library.Bookmarks do
  @moduledoc """
  Reads browser bookmark exports: the Netscape Bookmark File format that
  Chrome, Edge, Brave, Arc, Safari and Firefox write. Pure: no database, no
  network.

  The file is parsed as HTML with `LazyHTML`, so the format's quirks (`<DL><p>`
  wrappers, unclosed `<DT>` and `<p>`, Safari's top level without a `<DL>`)
  come out as an ordinary tree. A folder is an `<H3>` followed by the `<DL>`
  that holds its contents; a bookmark is an `<A HREF>`.

  Only http(s) links are kept, in the canonical form `Acervo.Library.URL`
  gives saved links, and each appears once, in the first folder where the
  file has it. Everything else (`javascript:`, `place:`, `chrome://`,
  `file:`, Firefox's feed bookmarks and folders) counts as skipped. At most
  5,000 links are kept, in the file's order; the rest count as truncated.

  Browser root containers (the bookmarks bar, Other bookmarks, Firefox's
  Bookmarks Menu and Toolbar, Safari's Favorites) are not folders here: their
  direct links are loose, and their subfolders are listed with the root in
  their path. Safari's Reading List is a folder of kind `:reading_list`.

  Names and titles are untrusted text: control characters (NUL included) and
  bidirectional overrides are removed, whitespace is collapsed, folder names
  are cut to 80 characters and titles to 500.
  """

  alias Acervo.Library.URL

  @max_links 5_000
  @max_name 80
  @max_title 500
  @max_url_bytes 2048

  # Root containers, by the attributes browsers mark them with or, failing
  # that, by their English and Portuguese names (compared in lowercase).
  @root_attributes ~w(personal_toolbar_folder unfiled_bookmarks_folder)
  @root_names [
    "bookmarks bar",
    "bookmarks toolbar",
    "bookmarks menu",
    "other bookmarks",
    "mobile bookmarks",
    "favorites bar",
    "favourites bar",
    "other favorites",
    "other favourites",
    "favorites",
    "barra de favoritos",
    "outros favoritos",
    "favoritos móveis",
    "menu de favoritos",
    "favoritos"
  ]
  @reading_list_id "com.apple.readinglist"
  @reading_list_names ["reading list", "lista de leitura"]

  # Capture spacing (see `schedule/2`).
  @spacing 3
  @host_gap 20

  @type link :: %{url: String.t(), href: String.t(), title: String.t() | nil, add_date: DateTime.t() | nil}
  @type folder :: %{path: [String.t()], name: String.t(), kind: :folder | :reading_list, links: [link()]}
  @type t :: %{
          folders: [folder()],
          loose: [link()],
          found: non_neg_integer(),
          skipped: non_neg_integer(),
          duplicates: non_neg_integer(),
          truncated: non_neg_integer()
        }

  @doc "The most links one import keeps."
  @spec max_links() :: pos_integer()
  def max_links, do: @max_links

  @doc """
  Parses a bookmarks export into its folders (in the order the file first
  uses them) and its loose links.

    * `found` - distinct http(s) links in the file, before the cap
    * `skipped` - links that are not http(s), or not valid
    * `duplicates` - repeats of a link already found
    * `truncated` - links left out by the #{@max_links} cap

  Folders without links are left out. `:now` (for tests) bounds `add_date`:
  a date after it is dropped.
  """
  @spec parse(binary(), keyword()) :: t()
  def parse(html, opts \\ []) when is_binary(html) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    items =
      html
      |> String.replace_invalid()
      |> LazyHTML.from_document()
      |> LazyHTML.to_tree(skip_whitespace_nodes: true)
      |> walk([], {[], nil})
      |> elem(0)
      |> Enum.reverse()

    {links, counts} = keep_links(items, now)
    kept = Enum.take(links, @max_links)

    {folders, loose} = group(kept)

    Map.merge(counts, %{folders: folders, loose: loose, truncated: length(links) - length(kept)})
  end

  ## Walking the tree

  # Collects `{:link, path, attrs, text}` in reverse document order. `pending`
  # is the folder whose `<H3>` was seen and whose `<DL>` hasn't come yet; it
  # carries over from a `<DT>` to its siblings, for files where the `<DL>`
  # ends up outside it.
  defp walk(nodes, path, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &walk_node(&1, path, &2))

  defp walk_node({"a", attrs, children}, path, {items, _pending}) do
    {[{:link, path, attrs, text(children)} | items], nil}
  end

  defp walk_node({"h3", attrs, children}, _path, {items, _pending}) do
    {items, %{name: clean(text(children), @max_name), attrs: attrs}}
  end

  defp walk_node({"dl", _attrs, children}, path, {items, pending}) do
    {items, _pending} = walk(children, folder_path(path, pending), {items, nil})
    {items, nil}
  end

  defp walk_node({tag, _attrs, _children}, _path, acc) when tag in ~w(head title script style template), do: acc
  defp walk_node({_tag, _attrs, children}, path, acc), do: walk(children, path, acc)
  defp walk_node(_text_or_comment, _path, acc), do: acc

  defp folder_path(path, nil), do: path
  defp folder_path(path, folder), do: path ++ [folder]

  defp text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &text/1)
  defp text(binary) when is_binary(binary), do: binary
  defp text({_tag, _attrs, children}), do: text(children)
  defp text(_comment), do: ""

  ## Links

  defp keep_links(items, now) do
    {links, _seen, counts} =
      Enum.reduce(items, {[], MapSet.new(), %{found: 0, skipped: 0, duplicates: 0}}, &keep_link(&1, &2, now))

    {Enum.reverse(links), counts}
  end

  defp keep_link({:link, path, attrs, text}, {links, seen, counts}, now) do
    case link(path, attrs, text, now) do
      :skip ->
        {links, seen, %{counts | skipped: counts.skipped + 1}}

      %{url: url} = link ->
        if MapSet.member?(seen, url),
          do: {links, seen, %{counts | duplicates: counts.duplicates + 1}},
          else: {[{path, link} | links], MapSet.put(seen, url), %{counts | found: counts.found + 1}}
    end
  end

  defp link(path, attrs, text, now) do
    with false <- feed?(path, attrs),
         {:ok, href, url} <- http_url(attr(attrs, "href")) do
      %{url: url, href: href, title: blank_to_nil(clean(text, @max_title)), add_date: add_date(attrs, now)}
    else
      _skip -> :skip
    end
  end

  # Firefox's live bookmarks: a feed, as an `<A FEEDURL>` or a folder.
  defp feed?(path, attrs), do: attr(attrs, "feedurl") != nil or Enum.any?(path, &(attr(&1.attrs, "feedurl") != nil))

  defp http_url(nil), do: :skip

  defp http_url(href) do
    href = String.trim(href)

    with true <- String.match?(href, ~r/\Ahttps?:\/\//i),
         true <- byte_size(href) <= @max_url_bytes,
         {:ok, url} when byte_size(url) <= @max_url_bytes <- URL.normalize(href) do
      {:ok, href, url}
    else
      _ -> :skip
    end
  end

  # Unix seconds; some tools write milliseconds or microseconds instead.
  defp add_date(attrs, now) do
    with value when is_binary(value) <- attr(attrs, "add_date"),
         {seconds, ""} when seconds > 0 <- Integer.parse(String.trim(value)),
         {:ok, date} <- seconds |> to_seconds() |> DateTime.from_unix(),
         :lt <- DateTime.compare(date, now) do
      date
    else
      _ -> nil
    end
  end

  defp to_seconds(value) when value >= 100_000_000_000_000, do: div(value, 1_000_000)
  defp to_seconds(value) when value >= 100_000_000_000, do: div(value, 1_000)
  defp to_seconds(value), do: value

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  ## Folders

  # Groups links by folder, in the order folders are first used. A root
  # container's own links are loose.
  defp group(links) do
    {order, by_path, loose} = Enum.reduce(links, {[], %{}, []}, &group_link/2)

    folders =
      order
      |> Enum.reverse()
      |> Enum.map(fn {names, kind} ->
        %{path: names, name: List.last(names), kind: kind, links: Enum.reverse(by_path[names])}
      end)

    {folders, Enum.reverse(loose)}
  end

  defp group_link({path, link}, {order, by_path, loose}) do
    case folder_of(path) do
      nil ->
        {order, by_path, [link | loose]}

      {names, kind} ->
        order = if Map.has_key?(by_path, names), do: order, else: [{names, kind} | order]
        {order, Map.update(by_path, names, [link], &[link | &1]), loose}
    end
  end

  defp folder_of([]), do: nil

  defp folder_of([first | rest] = path) do
    names = Enum.map(path, & &1.name)

    cond do
      reading_list?(first) -> {names, :reading_list}
      root?(first) and rest == [] -> nil
      true -> {names, :folder}
    end
  end

  defp reading_list?(%{name: name, attrs: attrs}) do
    String.downcase(attr(attrs, "id") || "") == @reading_list_id or String.downcase(name) in @reading_list_names
  end

  defp root?(%{name: name, attrs: attrs}) do
    Enum.any?(@root_attributes, &(attr(attrs, &1) != nil)) or String.downcase(name) in @root_names
  end

  @doc """
  A folder's path for display, as `"Bookmarks bar / Dev / Elixir"`. Paths
  deeper than three keep their first and last two names around an ellipsis.
  An unnamed folder shows as `"…"`.
  """
  @spec display_path([String.t()]) :: String.t()
  def display_path(path) when is_list(path) do
    path
    |> Enum.map(&if(&1 == "", do: "…", else: &1))
    |> shorten()
    |> Enum.join(" / ")
  end

  defp shorten([first | rest]) when length(rest) > 2, do: [first, "…" | Enum.take(rest, -2)]
  defp shorten(path), do: path

  ## Untrusted text

  @bidi ~r/[\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  defp clean(text, max) do
    text
    |> String.replace(~r/\p{Cc}/u, " ")
    |> String.replace(@bidi, "")
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, max)
    |> String.trim()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  ## Capture schedule

  @doc """
  Seconds after the import starts at which each URL's capture runs, in the
  order given.

  Captures are #{@spacing} s apart, so an import never adds more than one
  capture every few seconds to the capture queue, and a host gets at most
  one every #{@host_gap} s. Hosts are taken in turns (each URL keeps its
  place among its host's), so a file with hundreds of links to one site
  spreads them over the whole import instead of delaying everything after
  them.
  """
  @spec schedule([String.t()], keyword()) :: [non_neg_integer()]
  def schedule(urls, opts \\ []) when is_list(urls) do
    spacing = Keyword.get(opts, :spacing, @spacing)
    host_gap = Keyword.get(opts, :host_gap, @host_gap)

    {slots, _state} =
      urls
      |> Enum.with_index()
      |> in_host_turns()
      |> Enum.map_reduce({0, %{}}, fn {url, index}, {cursor, last} ->
        host = URI.parse(url).host
        at = if last[host], do: max(cursor, last[host] + host_gap), else: cursor
        {{index, at}, {at + spacing, Map.put(last, host, at)}}
      end)

    slots |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  # Round-robin over hosts, in the order each host first appears.
  defp in_host_turns(indexed) do
    groups =
      indexed
      |> Enum.group_by(fn {url, _index} -> URI.parse(url).host end)
      |> Map.values()
      |> Enum.sort_by(fn [{_url, first} | _] -> first end)

    turns(groups, [])
  end

  defp turns([], acc), do: Enum.reverse(acc)

  defp turns(groups, acc) do
    {heads, rests} =
      Enum.reduce(groups, {acc, []}, fn [head | rest], {heads, rests} -> {[head | heads], [rest | rests]} end)

    rests |> Enum.reverse() |> Enum.reject(&(&1 == [])) |> turns(heads)
  end
end
