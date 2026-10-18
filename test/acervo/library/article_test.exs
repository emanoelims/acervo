defmodule Acervo.Library.ArticleTest do
  use ExUnit.Case, async: true

  import Acervo.PageFixtures

  alias Acervo.Library.Article

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()

  describe "extract/2" do
    test "keeps a blog's article without its navigation, sharing, signup and comments" do
      assert {:ok, %{html: html, images: images}} =
               Article.extract(page("reader/blog.html"), "https://hive.test/posts/bees")

      assert html =~ "<h2>Why bees matter</h2>"
      assert html =~ "<em>apples</em>, <strong>almonds</strong>"
      assert html =~ "<h2>A short history</h2>"
      assert html =~ "<h3>Modern hives</h3>"
      assert html =~ "<blockquote><p>The bee is more honored"
      assert html =~ "<ul><li>Langstroth hives</li><li>Top-bar hives</li></ul>"

      assert html =~
               ~s(<figure><img src="https://hive.test/images/hive.jpg" alt="A hive at dawn" width="1200" height="800">)

      assert html =~ "<figcaption>A hive at dawn.</figcaption>"
      assert html =~ ~s(<a href="https://hive.test/authors/jane")
      assert html =~ "<table>"

      text = text(html)

      for boilerplate <- [
            "Home",
            "About",
            "Popular",
            "Share on X",
            "Copy link",
            "newsletter",
            "3 comments",
            "Great post",
            "©"
          ] do
        refute text =~ boilerplate
      end

      assert images == ["https://hive.test/images/hive.jpg"]
    end

    test "takes lazy images' real source and drops tracking pixels" do
      assert {:ok, %{images: images}} = Article.extract(page("reader/lazy.html"), "https://photos.test/gallery")

      assert images == [
               "https://photos.test/img/one.jpg",
               "https://photos.test/img/two-1600.jpg",
               "https://photos.test/img/three.jpg"
             ]
    end

    test "finds the docs content by paragraph text, resolving against <base href>" do
      assert {:ok, %{html: html}} = Article.extract(page("reader/docs.html"), "https://docs.example.com/elixir/Enum.html")

      assert html =~ "<h2>Enum behaviour</h2>"

      assert html =~ "<pre><code>iex&gt; Enum.map([1, 2, 3], fn x -&gt; x * 2 end)\n[2, 4, 6]</code></pre>"
      assert html =~ ~s(<pre class="language-shell"><code class="language-shell">mix test --only enum</code></pre>)
      assert html =~ ~s(<a href="https://docs.example.com/elixir/Enum.html#reduce/3")
      assert html =~ "<code>reduce/3</code>"
      refute text(html) =~ "Kernel"
    end

    test "returns :none when there is too little to read" do
      assert Article.extract("<html><body><nav><a href=/>Home</a></nav><p>Hi.</p></body></html>", "https://a.test/") ==
               :none

      assert Article.extract("", "https://a.test/") == :none
    end

    test "falls back to the body's richest block when the article is tiny" do
      html = """
      <html><body>
        <article class="author-bio"><p>Jane writes about bees.</p></article>
        <div class="post"><p>#{String.duplicate("Bees are wonderful. ", 20)}</p><p>#{String.duplicate("Honey is sweet. ", 20)}</p></div>
      </body></html>
      """

      assert {:ok, %{html: html}} = Article.extract(html, "https://a.test/")
      assert html =~ "Honey is sweet."
      refute html =~ "Jane writes"
    end
  end

  describe "from_markdown/2" do
    test "renders GFM and sanitizes it, resolving against the Markdown's URL" do
      markdown = """
      ---
      title: Bees
      ---
      # Bees

      Bees are **great**, ~~wasps~~ less so. See https://bees.test and [the guide](guide.md).

      | Crop | Share |
      |------|-------|
      | Almonds | 100% |

      - [x] pollinate
      - [ ] sting

      ```elixir
      Enum.map([1], & &1)
      ```

      ![A hive](img/hive.png)
      """

      assert {:ok, %{html: html, images: images}} = Article.from_markdown(markdown, "https://docs.test/en/bees.md")

      refute html =~ "title: Bees"
      assert html =~ "<h2>Bees</h2>"
      assert html =~ "<strong>great</strong>, <s>wasps</s>"
      assert html =~ ~s(<a href="https://bees.test")
      assert html =~ ~s(<a href="https://docs.test/en/guide.md")
      assert html =~ ~s(<div class="table-wrap"><table><thead><tr><th>Crop</th>)
      assert html =~ "<li>☑ pollinate</li>"
      assert html =~ "<li>☐ sting</li>"
      assert html =~ ~s|<pre><code class="language-elixir">Enum.map([1], &amp; &amp;1)\n</code></pre>|
      assert images == ["https://docs.test/en/img/hive.png"]
    end

    test "escapes or drops raw HTML and drops javascript: links" do
      markdown = """
      # Trap

      <script>alert(1)</script>

      Inline <img src=x onerror=alert(1)> and <b onclick="x">bold</b>.

      [click](javascript:alert(1)) [data](data:text/html,x) [ok](https://ok.test)

      <iframe src="https://evil.test"></iframe>
      """

      assert {:ok, %{html: html}} = Article.from_markdown(markdown, "https://docs.test/trap.md")

      refute html =~ ~r/<script|<img|<iframe|<b |javascript:|data:/
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ ~s(<a href="https://ok.test")
      assert html =~ "click"
    end
  end

  test "replace_images/3 rewrites or drops each image" do
    html =
      ~s(<p><img src="https://a.test/1.png" alt="one"></p><figure><img src="https://a.test/2.png"><figcaption>two</figcaption></figure>)

    out =
      Article.replace_images(html, "https://a.test/", fn
        "https://a.test/1.png" -> {:ok, %{src: "/images/one", width: 4, height: 3}}
        _ -> :drop
      end)

    assert out ==
             ~s(<p><img src="/images/one" alt="one" width="4" height="3"></p><figure><figcaption>two</figcaption></figure>)
  end
end
