defmodule Acervo.Library.BookmarkImports do
  @moduledoc """
  Imports a browser's bookmarks (parsed by `Acervo.Library.Bookmarks`) for
  one user, in the background.

  The preview (`existing_urls/2`, `rates/1`, `estimate/3`) writes nothing.
  `start/3` stores an `Acervo.Library.BookmarkImport` with the entries to
  save and enqueues `Acervo.Library.ImportBookmarks`, which saves them
  50 at a time (`run_batch/1`), each batch in one transaction with the
  import's progress, so a retried batch never saves anything twice.

  A new link is saved as `Acervo.Library.save_link/3` would, with the
  bookmark's title until its capture fills one in, and dated by the
  bookmark's `add_date` (its `inserted_at`, which orders the lists). A link
  going to a collection joins it and skips the inbox (`triaged_at` set); an
  inbox link waits there as usual. A link already saved is left as it is,
  except that it joins its folder's collection. Collections are matched by
  slug, so a folder named like an existing collection fills it.

  Captures are scheduled by `Acervo.Library.Bookmarks.schedule/2` and run,
  like their enrichments, at a lower priority than links saved by hand, so
  a large import never holds those up.

  Everything is scoped to the import's user, checked in the database.
  Broadcasts on `"links:<user_id>"`, after each batch commits:
  `{:links_created, links}`, `{:link_updated, link}` for saved links that
  joined a collection, `{:collections_changed}` and `{:import_updated, import}`.
  """

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI.Call
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library
  alias Acervo.Library.BookmarkImport
  alias Acervo.Library.Bookmarks
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.ImportBookmarks
  alias Acervo.Library.Link
  alias Acervo.Library.URL
  alias Acervo.Repo
  alias Acervo.Search.EmbedLink

  @batch 50
  # Below the default 0: imported links wait behind links saved by hand.
  @priority 2
  @embed_delay 5

  # Fallbacks when this user has no recent enrichment to average.
  @enrich_usd 0.02
  @enrich_seconds 20
  @embed_usd 0.00002
  @rate_days 30

  @type choice :: :collection | :inbox | :skip
  @type rates :: %{enrich_usd: float(), enrich_seconds: float(), ai_concurrency: pos_integer()}

  @doc "The batch size of `run_batch/1`."
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc """
  The scope's latest import, running or not, or nil.
  """
  @spec latest(Scope.t()) :: BookmarkImport.t() | nil
  def latest(%Scope{user: user}) do
    Repo.one(
      from i in BookmarkImport,
        where: i.user_id == ^user.id,
        order_by: [desc: i.inserted_at, desc: i.id],
        limit: 1
    )
  end

  @doc """
  The canonical URLs among `urls` the scope's user already saved, as a
  link's `canonical_url` or `resolved_url`, in one query.
  """
  @spec existing_urls(Scope.t(), [String.t()]) :: MapSet.t(String.t())
  def existing_urls(%Scope{}, []), do: MapSet.new()

  def existing_urls(%Scope{user: user}, urls) when is_list(urls) do
    wanted = MapSet.new(urls)

    from(l in Link,
      where: l.user_id == ^user.id and (l.canonical_url in ^urls or l.resolved_url in ^urls),
      select: {l.canonical_url, l.resolved_url}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {canonical, resolved} -> [canonical, resolved] end)
    |> Enum.filter(&MapSet.member?(wanted, &1))
    |> MapSet.new()
  end

  @doc """
  What enriching one link costs this user: the 75th percentile cost (pages
  vary a lot, and an estimate that runs low surprises more than one that runs
  high) and the average duration of their successful enrichments over the
  last #{@rate_days} days, falling back
  to $#{@enrich_usd} and #{@enrich_seconds} s, and the `ai` queue's
  concurrency.
  """
  @spec rates(Scope.t()) :: rates()
  def rates(%Scope{user: user}) do
    since = :second |> DateTime.utc_now() |> DateTime.shift(day: -@rate_days)

    {cost, duration} =
      Repo.one(
        from c in Call,
          where:
            c.user_id == ^user.id and c.operation == "enrich_link" and c.status == :ok and
              c.inserted_at >= ^since and not is_nil(c.cost_usd),
          select: {fragment("percentile_cont(0.75) WITHIN GROUP (ORDER BY ?)", c.cost_usd), avg(c.duration_ms)}
      )

    %{
      enrich_usd: if(cost, do: cost, else: @enrich_usd),
      enrich_seconds: if(duration, do: Decimal.to_float(duration) / 1000, else: @enrich_seconds),
      ai_concurrency: queue_concurrency(:ai)
    }
  end

  @doc """
  The estimated cost (USD) and duration (seconds) of importing `new_urls`:
  one enrichment and one embedding each, captured on the import's schedule
  and enriched as fast as the `ai` queue allows.
  """
  @spec estimate(rates(), [String.t()]) :: %{cost_usd: float(), seconds: non_neg_integer()}
  def estimate(%{enrich_usd: enrich_usd, enrich_seconds: enrich_seconds, ai_concurrency: concurrency}, new_urls) do
    count = length(new_urls)
    captures = new_urls |> Bookmarks.schedule() |> Enum.max(fn -> 0 end)
    enrichments = count * enrich_seconds / max(concurrency, 1)

    %{cost_usd: count * (enrich_usd + @embed_usd), seconds: round(max(captures, enrichments))}
  end

  defp queue_concurrency(queue) do
    :acervo |> Application.fetch_env!(Oban) |> Keyword.get(:queues, []) |> Keyword.get(queue, 1)
  end

  @doc """
  The URLs of `parsed` that `choices` (each folder's destination by its
  index in `parsed.folders`, and `:loose` for the loose links) do not skip.
  """
  @spec chosen_urls(Bookmarks.t(), %{(non_neg_integer() | :loose) => choice()}) :: [String.t()]
  def chosen_urls(parsed, choices) do
    for {links, key} <- groups(parsed), choices[key] != :skip, link <- links, do: link.url
  end

  defp groups(parsed) do
    parsed.folders
    |> Enum.with_index()
    |> Enum.map(fn {folder, index} -> {folder.links, index} end)
    |> Kernel.++([{parsed.loose, :loose}])
  end

  @doc """
  Starts importing `parsed` with `choices` (see `chosen_urls/2`; a missing
  choice skips). A folder chosen as a collection whose name has no letters
  or numbers goes to the inbox. Fails with `{:error, :running}` while another
  import of the user's runs.
  """
  @spec start(Scope.t(), Bookmarks.t(), %{(non_neg_integer() | :loose) => choice()}) ::
          {:ok, BookmarkImport.t()} | {:error, :running | :empty}
  def start(%Scope{user: user} = scope, parsed, choices) do
    {entries, collections} = plan(scope, parsed, choices)

    import = %BookmarkImport{
      user_id: user.id,
      status: :running,
      found: parsed.found,
      truncated: parsed.truncated,
      total: length(entries),
      choices: stored_choices(parsed, choices),
      collections: collections,
      entries: entries
    }

    if entries == [], do: {:error, :empty}, else: insert_and_enqueue(scope, import)
  end

  defp insert_and_enqueue(scope, import) do
    fn ->
      with {:ok, import} <- insert_running(import),
           {:ok, _job} <- Oban.insert(ImportBookmarks.new(%{"import_id" => import.id})) do
        {:ok, import}
      end
    end
    |> Repo.transact()
    |> tap(fn
      {:ok, import} -> broadcast(scope, {:import_updated, import})
      _error -> :ok
    end)
  end

  defp insert_running(import) do
    import
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:user_id, name: :bookmark_imports_one_running_index)
    |> Repo.insert()
    |> case do
      {:ok, import} -> {:ok, %{import | entries: []}}
      {:error, _changeset} -> {:error, :running}
    end
  end

  # The entries in folder order, then the loose links, and the collection
  # names they use, one per slug. New links get their capture's delay.
  defp plan(scope, parsed, choices) do
    chosen = for {links, key} <- groups(parsed), choice = choices[key], choice != :skip, do: {links, key, choice}
    existing = existing_urls(scope, Enum.flat_map(chosen, fn {links, _key, _choice} -> Enum.map(links, & &1.url) end))

    {collections, index_of} = collection_names(parsed, chosen)

    new_urls = for {links, _key, _choice} <- chosen, link <- links, not MapSet.member?(existing, link.url), do: link.url
    delays = new_urls |> Enum.zip(Bookmarks.schedule(new_urls)) |> Map.new()

    entries =
      for {links, key, choice} <- chosen, link <- links do
        %{
          "u" => link.url,
          "t" => link.title,
          "d" => link.add_date && DateTime.to_unix(link.add_date),
          "c" => if(choice == :collection, do: index_of[key]),
          "s" => delays[link.url]
        }
      end

    {entries, collections}
  end

  defp collection_names(parsed, chosen) do
    folders = parsed.folders |> Enum.with_index() |> Map.new(fn {folder, index} -> {index, folder} end)

    chosen
    |> Enum.filter(fn {_links, key, choice} -> choice == :collection and is_integer(key) end)
    |> Enum.reduce({[], %{}, %{}}, fn {_links, key, _choice}, {names, by_slug, index_of} ->
      name = folders[key].name

      slug = Collection.slugify(name)

      cond do
        slug == "" -> {names, by_slug, index_of}
        Map.has_key?(by_slug, slug) -> {names, by_slug, Map.put(index_of, key, by_slug[slug])}
        true -> {[name | names], Map.put(by_slug, slug, length(names)), Map.put(index_of, key, length(names))}
      end
    end)
    |> then(fn {names, _by_slug, index_of} -> {Enum.reverse(names), index_of} end)
  end

  defp stored_choices(parsed, choices) do
    folder_choices =
      parsed.folders
      |> Enum.with_index()
      |> Map.new(fn {folder, index} -> {Enum.join(folder.path, " / "), to_string(choices[index] || :skip)} end)

    if parsed.loose == [], do: folder_choices, else: Map.put(folder_choices, "", to_string(choices[:loose] || :skip))
  end

  @doc """
  Stops the scope's running import: entries not yet saved are dropped.
  """
  @spec cancel(Scope.t(), Ecto.UUID.t()) :: {:ok, BookmarkImport.t()} | {:error, :not_found}
  def cancel(%Scope{user: user} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {1, [import]} <-
           Repo.update_all(
             from(i in BookmarkImport,
               where: i.id == ^id and i.user_id == ^user.id and i.status == :running,
               select: i
             ),
             set: finished(:cancelled)
           ) do
      ended(import)
      broadcast(scope, {:import_updated, import})
      {:ok, import}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  # Marks a running import failed, when its worker gives up.
  @spec fail(Ecto.UUID.t()) :: :ok
  def fail(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      mark_failed(id)
    end

    :ok
  end

  defp mark_failed(id) do
    case Repo.update_all(
           from(i in BookmarkImport, where: i.id == ^id and i.status == :running, select: i),
           set: finished(:failed)
         ) do
      {1, [import]} ->
        ended(import)
        import = Repo.preload(import, :user)
        broadcast(Scope.for_user(import.user), {:import_updated, import})

      _ ->
        :ok
    end
  end

  defp finished(status) do
    [status: status, entries: [], collections: [], finished_at: now(), updated_at: now()]
  end

  @doc """
  Saves the import's next batch of entries and records the progress, in one
  transaction, enqueueing the next batch unless it was the last. An import
  that is gone or no longer running is left alone. Broadcasts after commit.
  """
  @spec run_batch(Ecto.UUID.t()) :: {:ok, :more | :done | :stopped}
  def run_batch(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> run_batch_of(id)
      :error -> {:ok, :stopped}
    end
  end

  defp run_batch_of(id) do
    case Repo.transact(fn -> lock_and_save(id) end) do
      {:ok, {:saved, scope, import, result}} ->
        announce(scope, import, result)
        if import.status == :done, do: {:ok, :done}, else: {:ok, :more}

      {:ok, :stopped} ->
        {:ok, :stopped}
    end
  end

  defp lock_and_save(id) do
    case Repo.one(from i in BookmarkImport, where: i.id == ^id, lock: "FOR UPDATE", preload: :user) do
      %BookmarkImport{status: :running} = import -> save_next(import)
      _gone_or_stopped -> {:ok, :stopped}
    end
  end

  defp save_next(import) do
    scope = Scope.for_user(import.user)
    entries = next_entries(import)
    result = save_entries(scope, import, entries)

    processed = import.processed + length(entries)
    done? = processed >= import.total or entries == []

    changes =
      [
        processed: processed,
        created: import.created + length(result.created),
        existing: import.existing + result.existing,
        failed: import.failed + result.failed
      ] ++ if(done?, do: finished(:done), else: [updated_at: now()])

    {1, [import]} =
      Repo.update_all(from(i in BookmarkImport, where: i.id == ^import.id, select: i), set: changes)

    if !done?, do: Oban.insert!(ImportBookmarks.new(%{"import_id" => import.id}))
    if done?, do: ended(import)

    {:ok, {:saved, scope, import, result}}
  end

  # Postgres arrays are 1-based; the slice is `cursor + 1 .. cursor + batch`.
  defp next_entries(import) do
    Repo.one(
      from i in BookmarkImport,
        where: i.id == ^import.id,
        select: type(fragment("?[?:?]", i.entries, ^(import.processed + 1), ^(import.processed + @batch)), {:array, :map})
    ) || []
  end

  defp save_entries(_scope, _import, []), do: %{created: [], existing: 0, failed: 0, joined: [], collections?: false}

  defp save_entries(%Scope{user: user}, import, entries) do
    saved = saved_links(user, Enum.map(entries, & &1["u"]))
    {collection_ids, created_collections?} = collections_for(user, import, entries)
    started = import.inserted_at

    {created, existing, failed, members} =
      Enum.reduce(entries, {[], 0, 0, []}, fn entry, acc ->
        save_entry(user, entry, entry["c"] && collection_ids[entry["c"]], saved[entry["u"]], started, acc)
      end)

    joined = join_collections(members)

    %{
      created: Enum.reverse(created),
      existing: existing,
      failed: failed,
      joined: joined,
      collections?: created_collections?
    }
  end

  defp save_entry(user, entry, collection_id, nil = _saved, started, {created, existing, failed, members}) do
    case insert_link(user, entry, collection_id, started) do
      {:ok, link} -> {[link.id | created], existing, failed, member(members, collection_id, link.id, :new)}
      :invalid -> {created, existing, failed + 1, members}
    end
  end

  defp save_entry(_user, _entry, collection_id, link_id, _started, {created, existing, failed, members}),
    do: {created, existing + 1, failed, member(members, collection_id, link_id, :existing)}

  defp member(members, nil, _link_id, _kind), do: members
  defp member(members, collection_id, link_id, kind), do: [{collection_id, link_id, kind} | members]

  # Links already saved, by canonical URL: a link saved under that exact URL
  # wins over one that resolved to it.
  defp saved_links(user, urls) do
    links =
      Repo.all(
        from l in Link,
          where: l.user_id == ^user.id and (l.canonical_url in ^urls or l.resolved_url in ^urls),
          order_by: [asc: l.inserted_at, asc: l.id],
          select: {l.id, l.canonical_url, l.resolved_url}
      )

    by_resolved = Enum.reduce(links, %{}, fn {id, _canonical, resolved}, acc -> Map.put_new(acc, resolved, id) end)
    Map.merge(by_resolved, Map.new(links, fn {id, canonical, _resolved} -> {canonical, id} end))
  end

  # The batch's collections, by index, matched by slug or created.
  defp collections_for(user, import, entries) do
    indexes = entries |> Enum.map(& &1["c"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Enum.reduce(indexes, {%{}, false}, fn index, {ids, created?} ->
      case import.collections |> Enum.at(index) |> collection(user) do
        {:ok, collection, new?} -> {Map.put(ids, index, collection.id), created? or new?}
        :error -> {ids, created?}
      end
    end)
  end

  defp collection(nil, _user), do: :error

  defp collection(name, user) do
    slug = Collection.slugify(name)

    case Repo.get_by(Collection, user_id: user.id, slug: slug) do
      %Collection{} = collection ->
        {:ok, collection, false}

      nil ->
        changeset = Collection.changeset(%Collection{user_id: user.id}, %{name: name})

        # A concurrent creation of the same slug wins: re-read it.
        case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:user_id, :slug]) do
          {:ok, inserted} ->
            collection = Repo.get_by!(Collection, user_id: user.id, slug: inserted.slug)
            {:ok, collection, collection.id == inserted.id}

          {:error, _changeset} ->
            :error
        end
    end
  end

  defp insert_link(user, entry, collection_id, started) do
    url = entry["u"]

    changeset =
      %Link{user_id: user.id}
      |> Link.create_changeset(%{url: url, canonical_url: url, source: URL.source(url)})
      |> Ecto.Changeset.put_change(:title, entry["t"] && String.slice(entry["t"], 0, 500))
      |> put_date(entry["d"])
      |> then(&if collection_id, do: Ecto.Changeset.put_change(&1, :triaged_at, now()), else: &1)

    if changeset.valid? do
      link = Repo.insert!(changeset)
      Oban.insert!(CaptureLink.new(%{"link_id" => link.id}, capture_options(started, entry["s"])))
      {:ok, link}
    else
      :invalid
    end
  end

  defp put_date(changeset, unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, date} -> Ecto.Changeset.put_change(changeset, :inserted_at, date)
      {:error, _reason} -> changeset
    end
  end

  defp put_date(changeset, _unix), do: changeset

  defp capture_options(started, delay) when is_integer(delay) do
    at = DateTime.shift(started, second: delay)

    if DateTime.after?(at, DateTime.utc_now()),
      do: [scheduled_at: at, priority: @priority],
      else: [priority: @priority]
  end

  defp capture_options(_started, _delay), do: [priority: @priority]

  # Adds the memberships, idempotently. Links saved before that joined a
  # collection are embedded again (search embeds collection names); new
  # links are embedded once enriched. Returns the former's ids.
  defp join_collections([]), do: []

  defp join_collections(members) do
    at = now()

    rows =
      members
      |> Enum.uniq_by(fn {collection_id, link_id, _kind} -> {collection_id, link_id} end)
      |> Enum.map(fn {collection_id, link_id, _kind} ->
        %{
          id: Ecto.UUID.generate(version: 7),
          collection_id: collection_id,
          link_id: link_id,
          source: :manual,
          inserted_at: at
        }
      end)

    {_count, inserted} =
      Repo.insert_all(CollectionLink, rows,
        on_conflict: :nothing,
        conflict_target: [:collection_id, :link_id],
        returning: [:link_id]
      )

    existing = for {_collection_id, link_id, :existing} <- members, into: MapSet.new(), do: link_id
    joined = inserted |> Enum.map(& &1.link_id) |> Enum.filter(&MapSet.member?(existing, &1)) |> Enum.uniq()

    {:ok, _count} = EmbedLink.enqueue_many(joined, delay: @embed_delay)
    joined
  end

  defp announce(scope, import, result) do
    if result.collections?, do: broadcast(scope, {:collections_changed})

    case Library.list_links_by_ids(scope, result.created) do
      [] -> :ok
      links -> broadcast(scope, {:links_created, links})
    end

    Enum.each(result.joined, &Library.broadcast_updated(scope, &1))
    broadcast(scope, {:import_updated, import})
  end

  defp ended(import) do
    :telemetry.execute(
      [:acervo, :bookmark_import, :stop],
      %{created: import.created, existing: import.existing},
      %{status: Atom.to_string(import.status)}
    )
  end

  defp broadcast(%Scope{user: user}, message) do
    Phoenix.PubSub.broadcast(Acervo.PubSub, "links:#{user.id}", message)
  end

  defp now, do: DateTime.utc_now(:second)
end
