defmodule Acervo.Library.BookmarkImportsTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI.Call
  alias Acervo.Collections
  alias Acervo.Collections.Collection
  alias Acervo.Library
  alias Acervo.Library.BookmarkImport
  alias Acervo.Library.BookmarkImports
  alias Acervo.Library.Bookmarks
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.ImportBookmarks
  alias Acervo.Library.Link
  alias Acervo.Search.EmbedLink

  @fixtures Path.expand("../../support/fixtures/bookmarks", __DIR__)

  # Chrome's folders: 0 "Bookmarks bar / Dev", 1 "… / Dev / Elixir",
  # 2 "Receitas & Viagens", then the loose links.
  defp chrome, do: @fixtures |> Path.join("chrome.html") |> File.read!() |> Bookmarks.parse()

  defp all_collections(choice \\ :collection), do: %{0 => choice, 1 => choice, 2 => choice, :loose => :inbox}

  defp links(scope), do: Library.list_links(scope, limit: 500)

  defp by_url(scope), do: Map.new(links(scope), &{&1.canonical_url, &1})

  defp run_all(import) do
    assert %{failure: 0} = Oban.drain_queue(queue: :import, with_recursion: true, with_safety: false)
    Repo.get!(BookmarkImport, import.id)
  end

  # `count` links on as many hosts, in one folder, plus nothing loose.
  defp many(count) do
    links =
      for i <- 1..count do
        %{url: "https://h#{i}.example.com/p", href: "https://h#{i}.example.com/p", title: "P#{i}", add_date: nil}
      end

    %{
      folders: [%{path: ["Many"], name: "Many", kind: :folder, links: links}],
      loose: [],
      found: count,
      skipped: 0,
      duplicates: 0,
      truncated: 0
    }
  end

  setup do
    %{scope: user_scope_fixture()}
  end

  describe "preview" do
    test "existing_urls finds saved links by canonical or resolved URL, only the scope's", %{scope: scope} do
      link_fixture(scope, "https://elixir-lang.org/")

      resolved = link_fixture(scope, "https://short.example.com/x")
      resolved |> Link.capture_changeset(%{resolved_url: "https://hexdocs.pm/elixir/Kernel.html"}) |> Repo.update!()

      link_fixture(user_scope_fixture(), "https://www.seriouseats.com/the-food-lab")

      urls = BookmarkImports.chosen_urls(chrome(), all_collections())

      assert BookmarkImports.existing_urls(scope, urls) ==
               MapSet.new(["https://elixir-lang.org/", "https://hexdocs.pm/elixir/Kernel.html"])
    end

    test "chosen_urls leaves skipped folders out", %{scope: _scope} do
      urls = BookmarkImports.chosen_urls(chrome(), %{0 => :skip, 1 => :inbox, 2 => :skip, :loose => :skip})
      assert urls == ["https://hexdocs.pm/elixir/Kernel.html", "https://elixirforum.com/"]
    end

    test "rates fall back to $0.02 and 20 s per link without recent enrichments", %{scope: scope} do
      assert %{enrich_usd: 0.02, enrich_seconds: 20, ai_concurrency: 2} = BookmarkImports.rates(scope)
    end

    test "rates take the 75th percentile cost and average duration of recent successful enrichments", %{scope: scope} do
      for {cost, ms} <- [{"0.01", 10_000}, {"0.03", 30_000}] do
        Repo.insert!(%Call{
          user_id: scope.user.id,
          operation: "enrich_link",
          model: "anthropic:claude-opus-5-5",
          status: :ok,
          cost_usd: Decimal.new(cost),
          duration_ms: ms
        })
      end

      Repo.insert!(%Call{
        user_id: scope.user.id,
        operation: "enrich_link",
        model: "m",
        status: :error,
        cost_usd: Decimal.new("9"),
        duration_ms: 1
      })

      rates = BookmarkImports.rates(scope)
      # percentile_cont(0.75) of 0.01 and 0.03 interpolates to 0.025.
      assert_in_delta rates.enrich_usd, 0.025, 1.0e-9
      assert_in_delta rates.enrich_seconds, 20.0, 1.0e-9
      # Another user's calls don't count.
      assert BookmarkImports.rates(user_scope_fixture()).enrich_usd == 0.02
    end

    test "the estimate adds an enrichment and an embedding per new link", %{scope: _scope} do
      rates = %{enrich_usd: 0.02, enrich_seconds: 20, ai_concurrency: 2}
      urls = for i <- 1..10, do: "https://h#{i}.example.com/"

      assert %{cost_usd: cost, seconds: 100} = BookmarkImports.estimate(rates, urls)
      assert_in_delta cost, 10 * 0.02002, 1.0e-9
      assert %{cost_usd: +0.0, seconds: 0} = BookmarkImports.estimate(rates, [])
    end

    test "previewing writes nothing", %{scope: scope} do
      parsed = chrome()
      _ = BookmarkImports.existing_urls(scope, BookmarkImports.chosen_urls(parsed, all_collections()))
      _ = BookmarkImports.rates(scope)

      assert links(scope) == []
      assert Collections.list_collections(scope) == []
      refute BookmarkImports.latest(scope)
    end
  end

  describe "start/3" do
    test "stores the entries and choices, and enqueues the first batch", %{scope: scope} do
      assert {:ok, import} = BookmarkImports.start(scope, chrome(), %{0 => :collection, 1 => :inbox, 2 => :skip})

      assert import.status == :running
      assert import.total == 3
      assert import.found == 6
      assert import.collections == ["Dev"]

      assert import.choices == %{
               "Bookmarks bar / Dev" => "collection",
               "Bookmarks bar / Dev / Elixir" => "inbox",
               "Receitas & Viagens" => "skip",
               "" => "skip"
             }

      assert_enqueued(worker: ImportBookmarks, args: %{"import_id" => import.id}, queue: :import)
      assert links(scope) == []
    end

    test "one import runs at a time per user", %{scope: scope} do
      assert {:ok, _import} = BookmarkImports.start(scope, chrome(), all_collections())
      assert {:error, :running} = BookmarkImports.start(scope, chrome(), all_collections())
      assert {:ok, _import} = BookmarkImports.start(user_scope_fixture(), chrome(), all_collections())
    end

    test "nothing chosen is nothing to import", %{scope: scope} do
      assert {:error, :empty} =
               BookmarkImports.start(scope, chrome(), :skip |> all_collections() |> Map.put(:loose, :skip))
    end
  end

  describe "the worker" do
    test "saves new links with their title and date, folders as collections, loose links in the inbox", %{
      scope: scope
    } do
      {:ok, import} = BookmarkImports.start(scope, chrome(), all_collections())
      import = run_all(import)

      assert import.status == :done
      assert %{processed: 6, created: 6, existing: 0, failed: 0} = import
      assert import.finished_at
      assert Repo.one(from i in BookmarkImport, where: i.id == ^import.id, select: i.entries) == []

      saved = by_url(scope)
      assert map_size(saved) == 6

      kernel = saved["https://hexdocs.pm/elixir/Kernel.html"]
      assert kernel.title == "Kernel — Elixir v1.20"
      assert kernel.url == "https://hexdocs.pm/elixir/Kernel.html"
      assert kernel.inserted_at == ~U[2023-07-10 14:51:40Z]
      assert kernel.triaged_at
      assert Enum.map(kernel.collections, & &1.name) == ["Elixir"]

      # Loose links wait in the inbox, in no collection.
      elixir = saved["https://elixir-lang.org/"]
      assert elixir.triaged_at == nil
      assert elixir.collections == []

      assert scope |> Collections.list_collections() |> Enum.map(&{&1.name, &1.link_count}) |> Enum.sort() == [
               {"Dev", 1},
               {"Elixir", 2},
               {"Receitas & Viagens", 1}
             ]

      assert Library.count_inbox(scope) == 2
    end

    test "inbox folders stay untriaged, skipped folders are not saved", %{scope: scope} do
      {:ok, import} =
        BookmarkImports.start(scope, chrome(), %{0 => :inbox, 1 => :skip, 2 => :collection, :loose => :skip})

      run_all(import)

      saved = by_url(scope)

      assert saved |> Map.keys() |> Enum.sort() == [
               "https://hexdocs.pm/phoenix/overview.html",
               "https://www.seriouseats.com/the-food-lab"
             ]

      assert saved["https://hexdocs.pm/phoenix/overview.html"].triaged_at == nil
      assert saved["https://www.seriouseats.com/the-food-lab"].triaged_at
    end

    test "a folder fills the collection with its slug instead of creating one", %{scope: scope} do
      dev = collection_fixture(scope, %{name: "DEV"})

      {:ok, import} = BookmarkImports.start(scope, chrome(), all_collections())
      run_all(import)

      assert Repo.aggregate(from(c in Collection, where: c.user_id == ^scope.user.id and c.slug == "dev"), :count) == 1
      [link] = Library.list_links(scope, filter: {:collection, dev.id})
      assert link.canonical_url == "https://hexdocs.pm/phoenix/overview.html"
    end

    test "folders with the same name share one collection", %{scope: scope} do
      parsed = %{
        many(2)
        | folders: [
            %{path: ["A", "News"], name: "News", kind: :folder, links: [hd(hd(many(2).folders).links)]},
            %{path: ["B", "news"], name: "news", kind: :folder, links: [List.last(hd(many(2).folders).links)]}
          ]
      }

      {:ok, import} = BookmarkImports.start(scope, parsed, %{0 => :collection, 1 => :collection})
      assert import.collections == ["News"]
      run_all(import)

      assert [%{name: "News", link_count: 2}] = Collections.list_collections(scope)
    end

    test "saved links are not duplicated, keep their triage and join their folder's collection", %{scope: scope} do
      existing = link_fixture(scope, "https://hexdocs.pm/elixir/Kernel.html")
      before = Repo.get!(Link, existing.id)

      {:ok, import} = BookmarkImports.start(scope, chrome(), all_collections())
      import = run_all(import)

      assert %{created: 5, existing: 1} = import
      assert Repo.aggregate(from(l in Link, where: l.user_id == ^scope.user.id), :count) == 6

      link = Library.get_link!(scope, existing.id)
      assert Enum.map(link.collections, & &1.name) == ["Elixir"]
      assert link.triaged_at == nil
      assert link.inserted_at == before.inserted_at
      assert link.title == before.title

      # Search embeds collection names, so the saved link is embedded again.
      assert_enqueued(worker: EmbedLink, args: %{"link_id" => existing.id})
    end

    test "processes entries in batches of 50, each enqueueing the next", %{scope: scope} do
      {:ok, import} = BookmarkImports.start(scope, many(120), %{0 => :inbox})
      assert BookmarkImports.batch_size() == 50

      # Run the first batch by hand, in place of its job.
      Repo.delete_all(Oban.Job)
      assert :ok = perform_job(ImportBookmarks, %{"import_id" => import.id})
      assert %{processed: 50, created: 50, status: :running} = Repo.get!(BookmarkImport, import.id)
      assert [_next] = all_enqueued(worker: ImportBookmarks, args: %{"import_id" => import.id})

      import = run_all(import)
      assert %{processed: 120, created: 120, status: :done} = import
      assert length(links(scope)) == 120
    end

    test "spreads captures over time, at a lower priority than links saved by hand", %{scope: scope} do
      {:ok, import} = BookmarkImports.start(scope, many(5), %{0 => :inbox})
      run_all(import)

      jobs = all_enqueued(worker: CaptureLink)
      assert length(jobs) == 5
      assert Enum.all?(jobs, &(&1.priority == 2))

      delays =
        jobs
        |> Enum.map(&DateTime.diff(&1.scheduled_at, import.inserted_at))
        |> Enum.sort()

      # Five hosts, 3 s apart; the first runs right away.
      assert Enum.at(delays, 0) <= 1
      assert Enum.at(delays, 4) >= 12
      assert delays |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> b - a >= 2 end)
    end

    test "broadcasts the new links, the collections and the progress", %{scope: scope} do
      Library.subscribe(scope)
      {:ok, import} = BookmarkImports.start(scope, chrome(), all_collections())
      import_id = import.id

      assert_receive {:import_updated, %BookmarkImport{id: ^import_id, status: :running, processed: 0}}
      run_all(import)

      assert_receive {:collections_changed}
      assert_receive {:links_created, links}
      assert length(links) == 6
      assert Enum.all?(links, &is_list(&1.collections))
      assert_receive {:import_updated, %BookmarkImport{id: ^import_id, status: :done, processed: 6, entries: []}}
    end

    test "cancel stops the remaining entries", %{scope: scope} do
      {:ok, import} = BookmarkImports.start(scope, many(120), %{0 => :inbox})
      perform_job(ImportBookmarks, %{"import_id" => import.id})

      assert {:ok, %{status: :cancelled}} = BookmarkImports.cancel(scope, import.id)
      import = run_all(import)

      assert %{status: :cancelled, processed: 50} = import
      assert length(links(scope)) == 50
      assert {:error, :not_found} = BookmarkImports.cancel(scope, import.id)
    end

    test "another user can't cancel an import", %{scope: scope} do
      {:ok, import} = BookmarkImports.start(scope, chrome(), all_collections())

      assert {:error, :not_found} = BookmarkImports.cancel(user_scope_fixture(), import.id)
      assert {:error, :not_found} = BookmarkImports.cancel(scope, "not-a-uuid")
      assert Repo.get!(BookmarkImport, import.id).status == :running
    end

    test "a batch saved again (a retry) saves each link once", %{scope: scope} do
      {:ok, import} = BookmarkImports.start(scope, many(60), %{0 => :collection})
      perform_job(ImportBookmarks, %{"import_id" => import.id})

      # As if the progress of the first batch had not been recorded.
      Repo.update_all(from(i in BookmarkImport, where: i.id == ^import.id), set: [processed: 0, created: 0])
      import = run_all(import)

      assert %{status: :done, processed: 60, created: 10, existing: 50} = import
      assert length(links(scope)) == 60
      assert [%{link_count: 60}] = Collections.list_collections(scope)
    end

    test "a job for an import that is gone or stopped does nothing", %{scope: scope} do
      assert :ok = perform_job(ImportBookmarks, %{"import_id" => Ecto.UUID.generate()})
      assert :ok = perform_job(ImportBookmarks, %{"import_id" => "nope"})

      {:ok, import} = BookmarkImports.start(scope, chrome(), all_collections())
      BookmarkImports.cancel(scope, import.id)
      assert :ok = perform_job(ImportBookmarks, %{"import_id" => import.id})
      assert links(scope) == []
    end

    test "a failed import is marked so, and frees the user to start another", %{scope: scope} do
      {:ok, import} = BookmarkImports.start(scope, chrome(), all_collections())
      assert :ok = BookmarkImports.fail(import.id)

      assert Repo.get!(BookmarkImport, import.id).status == :failed
      assert {:ok, _import} = BookmarkImports.start(scope, chrome(), all_collections())
    end
  end
end
