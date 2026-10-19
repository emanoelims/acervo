defmodule Acervo.Library.BookmarksTest do
  use ExUnit.Case, async: true

  alias Acervo.Library.Bookmarks

  @fixtures Path.expand("../../support/fixtures/bookmarks", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Bookmarks.parse()

  defp folder(parsed, path), do: Enum.find(parsed.folders, &(&1.path == path))
  defp urls(links), do: Enum.map(links, & &1.url)

  defp wrap(body) do
    """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
    #{body}
    </DL><p>
    """
  end

  describe "Chrome export" do
    setup do: %{parsed: fixture("chrome.html")}

    test "the bookmarks bar is a root: its links are loose, its subfolders listed with it in their path", %{
      parsed: parsed
    } do
      assert Enum.map(parsed.folders, & &1.path) == [
               ["Bookmarks bar", "Dev"],
               ["Bookmarks bar", "Dev", "Elixir"],
               ["Receitas & Viagens"]
             ]

      assert urls(parsed.loose) == ["https://elixir-lang.org/", "https://www.instagram.com/p/C0ffee"]
    end

    test "nested folders keep only their own links, named after their own name", %{parsed: parsed} do
      dev = folder(parsed, ["Bookmarks bar", "Dev"])
      elixir = folder(parsed, ["Bookmarks bar", "Dev", "Elixir"])

      assert dev.name == "Dev"
      assert urls(dev.links) == ["https://hexdocs.pm/phoenix/overview.html"]
      assert elixir.name == "Elixir"
      assert urls(elixir.links) == ["https://hexdocs.pm/elixir/Kernel.html", "https://elixirforum.com/"]
    end

    test "links are normalized like saved links and keep their title and date", %{parsed: parsed} do
      [link] = folder(parsed, ["Bookmarks bar", "Dev"]).links

      assert link.url == "https://hexdocs.pm/phoenix/overview.html"
      assert link.href == "https://hexdocs.pm/phoenix/overview.html?utm_source=newsletter"
      assert link.title == "Overview — Phoenix v1.8"
      assert link.add_date == ~U[2023-07-10 14:46:40Z]
    end

    test "an empty title is nil", %{parsed: parsed} do
      forum = Enum.find(folder(parsed, ["Bookmarks bar", "Dev", "Elixir"]).links, &(&1.url == "https://elixirforum.com/"))
      assert forum.title == nil
    end

    test "javascript: and chrome:// links are skipped, empty folders left out, repeats counted once", %{
      parsed: parsed
    } do
      assert parsed.skipped == 2
      assert parsed.duplicates == 1
      assert parsed.found == 6
      assert parsed.truncated == 0
      refute Enum.any?(parsed.folders, &(&1.name == "Empty"))
      # The repeat (with a fragment) stays where the file had it first.
      assert urls(folder(parsed, ["Receitas & Viagens"]).links) == ["https://www.seriouseats.com/the-food-lab"]
    end
  end

  describe "Safari export" do
    setup do: %{parsed: fixture("safari.html")}

    test "Favorites is a root, and the top level needs no <DL>", %{parsed: parsed} do
      assert urls(parsed.loose) == ["https://www.apple.com/"]

      assert urls(folder(parsed, ["Favorites", "Design"]).links) == [
               "https://developer.apple.com/design/human-interface-guidelines"
             ]

      assert folder(parsed, ["Receitas"]).kind == :folder
    end

    test "the Reading List is its own kind, its descriptions ignored and its repeats dropped", %{parsed: parsed} do
      reading = folder(parsed, ["Reading List"])

      assert reading.kind == :reading_list
      assert urls(reading.links) == ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://daringfireball.net/2024/01"]
      assert hd(reading.links).title == "Never Gonna Give You Up"
      assert hd(reading.links).add_date == nil
      assert parsed.duplicates == 1
    end

    test "the empty Bookmarks Menu is left out", %{parsed: parsed} do
      refute Enum.any?(parsed.folders, &(&1.name == "Bookmarks Menu"))
    end
  end

  describe "Firefox export" do
    setup do: %{parsed: fixture("firefox.html")}

    test "the menu's own links, the toolbar's and Other Bookmarks' are loose", %{parsed: parsed} do
      assert urls(parsed.loose) == [
               "https://developer.mozilla.org/en-US",
               "https://news.ycombinator.com/",
               "http://example.com/path"
             ]
    end

    test "folders under the menu and the toolbar are listed", %{parsed: parsed} do
      assert Enum.map(parsed.folders, & &1.path) == [["Mozilla Firefox"], ["Bookmarks Toolbar", "Leitura"]]
    end

    test "place:, file: and feed bookmarks and folders are skipped", %{parsed: parsed} do
      # place:, file:, the live bookmark and the feed folder's post.
      assert parsed.skipped == 4
      refute Enum.any?(parsed.folders, &(&1.name == "Old feed folder"))
    end

    test "dates in milliseconds become seconds", %{parsed: parsed} do
      [essay] = folder(parsed, ["Bookmarks Toolbar", "Leitura"]).links
      assert essay.add_date == ~U[2022-04-15 05:20:11Z]
    end
  end

  describe "quirks" do
    test "Other bookmarks as a folder (Edge, Brave) is a root too" do
      parsed =
        """
        <DT><H3>Other bookmarks</H3>
        <DL><p>
          <DT><A HREF="https://a.example.com/">A</A>
          <DT><H3>Sub</H3>
          <DL><p><DT><A HREF="https://b.example.com/">B</A></DL><p>
        </DL><p>
        <DT><H3>Favorites bar</H3>
        <DL><p><DT><A HREF="https://c.example.com/">C</A></DL><p>
        """
        |> wrap()
        |> Bookmarks.parse()

      assert urls(parsed.loose) == ["https://a.example.com/", "https://c.example.com/"]
      assert Enum.map(parsed.folders, & &1.path) == [["Other bookmarks", "Sub"]]
    end

    test "unclosed <DT> and <p>, lowercase tags and a missing </DL> still nest" do
      parsed =
        Bookmarks.parse("""
        <dl><p>
        <dt><h3>One</h3>
        <dl><p>
        <dt><a href="https://one.example.com/">1</a>
        <dt><h3>Two</h3>
        <dl><p>
        <dt><a href="https://two.example.com/">2</a>
        </dl>
        <dt><a href="https://three.example.com/">3</a>
        """)

      assert Enum.map(parsed.folders, &{&1.path, urls(&1.links)}) == [
               {["One"], ["https://one.example.com/", "https://three.example.com/"]},
               {["One", "Two"], ["https://two.example.com/"]}
             ]
    end

    test "deep paths are shortened for display; unnamed folders show an ellipsis" do
      assert Bookmarks.display_path(["Bookmarks bar", "Dev"]) == "Bookmarks bar / Dev"
      assert Bookmarks.display_path(["Bookmarks bar", "Dev", "Elixir"]) == "Bookmarks bar / Dev / Elixir"
      assert Bookmarks.display_path(["A", "B", "C", "D", "E"]) == "A / … / D / E"
      assert Bookmarks.display_path(["", "x"]) == "… / x"
    end

    test "folder names are untrusted: control characters, NUL and bidi overrides go, 80 characters at most" do
      name = "Evil\u0000 \u202Efolder\u0007\n  name " <> String.duplicate("x", 200)

      parsed = Bookmarks.parse(wrap(~s|<DT><H3>#{name}</H3><DL><p><DT><A HREF="https://x.example.com/">x</A></DL><p>|))
      [folder] = parsed.folders

      assert String.starts_with?(folder.name, "Evil folder name xxx")
      assert String.length(folder.name) == 80
      refute folder.name =~ ~r/[\x00-\x1F\x{202E}]/u
    end

    test "markup in names and titles is text, never HTML" do
      parsed =
        Bookmarks.parse(
          wrap(
            ~s|<DT><H3>&lt;script&gt;x&lt;/script&gt;</H3><DL><p><DT><A HREF="https://x.example.com/"><b>Bold</b></A></DL>|
          )
        )

      [folder] = parsed.folders
      assert folder.name == "<script>x</script>"
      assert hd(folder.links).title == "Bold"
    end

    test "invalid URLs, other schemes and overlong URLs are skipped" do
      long = "https://x.example.com/" <> String.duplicate("a", 2100)

      parsed =
        """
        <DT><A HREF="file:///etc/passwd">f</A>
        <DT><A HREF="ftp://x.example.com/">ftp</A>
        <DT><A HREF="data:text/html,hi">data</A>
        <DT><A HREF="https://">empty</A>
        <DT><A>no href</A>
        <DT><A HREF="#{long}">long</A>
        <DT><A HREF="example.com">bare</A>
        <DT><A HREF="  HTTPS://Keep.Example.com/  ">ok</A>
        """
        |> wrap()
        |> Bookmarks.parse()

      assert urls(parsed.loose) == ["https://keep.example.com/"]
      assert parsed.skipped == 7
    end

    test "add dates that are zero, garbage or in the future are dropped" do
      now = ~U[2026-10-18 00:00:00Z]

      parsed =
        """
        <DT><A HREF="https://a.example.com/" ADD_DATE="0">a</A>
        <DT><A HREF="https://b.example.com/" ADD_DATE="soon">b</A>
        <DT><A HREF="https://c.example.com/" ADD_DATE="4102444800">c</A>
        <DT><A HREF="https://d.example.com/" ADD_DATE="1600000000000000">d</A>
        """
        |> wrap()
        |> Bookmarks.parse(now: now)

      assert Enum.map(parsed.loose, & &1.add_date) == [nil, nil, nil, ~U[2020-09-13 12:26:40Z]]
    end

    test "invalid UTF-8 does not crash" do
      parsed = Bookmarks.parse(wrap(~s|<DT><H3>Caf\xE9</H3><DL><p><DT><A HREF="https://x.example.com/">x</A></DL>|))
      assert [%{name: name}] = parsed.folders
      assert String.valid?(name)
    end

    test "a huge file keeps the first 5,000 links and says how many were left out" do
      body =
        Enum.map_join(1..12_000, "\n", fn i ->
          folder = if rem(i, 1000) == 1, do: ~s|</DL><p><DT><H3>F#{div(i, 1000)}</H3><DL><p>|, else: ""
          ~s|#{folder}<DT><A HREF="https://site#{rem(i, 40)}.example.com/p/#{i}" ADD_DATE="1600000000">P #{i}</A>|
        end)

      parsed = Bookmarks.parse(wrap(~s|<DT><H3>Start</H3><DL><p>#{body}</DL><p>|))
      kept = Enum.sum(Enum.map(parsed.folders, &length(&1.links))) + length(parsed.loose)

      assert parsed.found == 12_000
      assert kept == 5_000
      assert parsed.truncated == 7_000
    end

    test "not a bookmarks file yields nothing" do
      parsed = Bookmarks.parse("hello, world")
      assert parsed.folders == [] and parsed.loose == [] and parsed.found == 0
    end
  end

  describe "schedule/2" do
    test "spaces captures out and gives each host a longer gap" do
      urls = [
        "https://a.example.com/1",
        "https://a.example.com/2",
        "https://b.example.com/1",
        "https://a.example.com/3"
      ]

      offsets = Bookmarks.schedule(urls, spacing: 3, host_gap: 20)

      # Hosts take turns: a1 0, b1 3, a2 20, a3 40.
      assert offsets == [0, 20, 3, 40]
    end

    test "no two captures share a slot, and a host never gets two within its gap" do
      urls = for i <- 1..300, do: "https://site#{rem(i, 7)}.example.com/#{i}"
      offsets = Bookmarks.schedule(urls)

      assert offsets |> Enum.uniq() |> length() == 300

      urls
      |> Enum.zip(offsets)
      |> Enum.group_by(fn {url, _at} -> URI.parse(url).host end, fn {_url, at} -> at end)
      |> Enum.each(fn {_host, times} ->
        times |> Enum.sort() |> Enum.chunk_every(2, 1, :discard) |> Enum.each(fn [a, b] -> assert b - a >= 20 end)
      end)
    end

    test "nothing to schedule" do
      assert Bookmarks.schedule([]) == []
    end
  end
end
