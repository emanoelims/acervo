defmodule Acervo.Library.SanitizerTest do
  use ExUnit.Case, async: true

  import Acervo.PageFixtures

  alias Acervo.Library.Sanitizer

  @base "https://example.com/posts/bees"

  defp clean(html, opts \\ []), do: html |> Sanitizer.sanitize_html(@base, opts) |> elem(0)

  defp hrefs(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> LazyHTML.attribute("href")
  end

  # Every element and attribute in the output, to check against the allowlist.
  defp elements(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.to_tree()
    |> LazyHTML.Tree.prereduce([], fn
      {tag, attrs, _children}, acc -> [{tag, Enum.map(attrs, &elem(&1, 0))} | acc]
      _node, acc -> acc
    end)
  end

  @allowed %{
    "p" => [],
    "h2" => [],
    "h3" => [],
    "h4" => [],
    "h5" => [],
    "h6" => [],
    "ul" => [],
    "ol" => [],
    "li" => [],
    "blockquote" => [],
    "pre" => ["class"],
    "code" => ["class"],
    "em" => [],
    "strong" => [],
    "b" => [],
    "i" => [],
    "u" => [],
    "s" => [],
    "sup" => [],
    "sub" => [],
    "br" => [],
    "hr" => [],
    "a" => ["href", "target", "rel"],
    "img" => ["src", "alt", "width", "height"],
    "figure" => [],
    "figcaption" => [],
    "div" => ["class"],
    "table" => [],
    "thead" => [],
    "tbody" => [],
    "tr" => [],
    "th" => ["colspan", "rowspan"],
    "td" => ["colspan", "rowspan"]
  }

  defp assert_allowlisted(html) do
    for {tag, attrs} <- elements(html) do
      assert Map.has_key?(@allowed, tag), "unexpected <#{tag}> in #{html}"
      assert attrs -- @allowed[tag] == [], "unexpected #{inspect(attrs)} on <#{tag}>"
    end
  end

  describe "links" do
    test "drop javascript:, data: and vbscript: URLs in any disguise" do
      for href <- [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "&#106;avascript:alert(1)",
            "&#x6A;&#x61;vascript:alert(1)",
            "javascript&colon;alert(1)",
            "java&#x09;script:alert(1)",
            "java\nscript:alert(1)",
            " \u0001javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "DATA:text/html,x",
            "vbscript:msgbox(1)",
            "VBScript:msgbox(1)",
            "file:///etc/passwd",
            "mailto:a@example.com",
            "https:",
            "http://"
          ] do
        html = clean(~s(<p><a href="#{href}">link</a> text</p>))
        assert hrefs(html) == [], "#{inspect(href)} kept: #{html}"
        assert html =~ "link"
      end
    end

    test "resolve relative URLs against the base and open in a new tab" do
      html =
        clean(
          ~s(<p><a href="../about">a</a> <a href="//cdn.example.org/x">b</a> <a href="#notes">c</a> <a href="HTTPS://Example.com/Up">d</a></p>)
        )

      assert hrefs(html) == [
               "https://example.com/about",
               "https://cdn.example.org/x",
               "https://example.com/posts/bees#notes",
               "https://Example.com/Up"
             ]

      assert html =~ ~s(target="_blank" rel="noopener noreferrer nofollow")
    end

    test "nested links are flattened, keeping their text" do
      tree = [
        {"p", [],
         [{"a", [{"href", "https://outer.test"}], ["outer ", {"a", [{"href", "https://inner.test"}], ["inner"]}]}]}
      ]

      {html, _images} = Sanitizer.sanitize(tree, @base)

      assert hrefs(html) == ["https://outer.test"]
      assert html =~ "outer inner"
    end
  end

  describe "markup" do
    test "drops event handlers, styles, ids and classes" do
      html =
        clean(
          ~s|<p id="x" class="lead" style="color:red" onclick="alert(1)" onmouseover="x">Hi <b onmouseover="x">there</b></p>|
        )

      assert html == "<p>Hi <b>there</b></p>"
    end

    test "drops script, style, svg and math payloads with their content" do
      html =
        clean("""
        <p>before</p>
        <script>alert(1)</script><style>p{}</style>
        <svg><script>alert(1)</script><a xlink:href="javascript:alert(1)"><text>svg text</text></a></svg>
        <math><mtext><table><mglyph><style><img src=x onerror=alert(1)></style></mglyph></table></mtext></math>
        <iframe src="https://evil.test"></iframe><object data="x"></object><embed src="x">
        <form><input name="q"><button>Go</button></form><textarea><b>x</b></textarea>
        <p>after</p>
        """)

      assert html == "<p>before</p><p>after</p>"
    end

    test "drops comments and CDATA, which HTML reads as a comment up to the first >" do
      html = clean("<p>a<!-- <img src=x onerror=alert(1)> -->b</p><![CDATA[ <script>alert(1)</script> ]]>")
      assert html == "<p>ab</p><p>alert(1) ]]&gt;</p>"
    end

    test "drops hidden and aria-hidden elements" do
      html =
        clean(
          ~s(<p hidden>h</p><div aria-hidden="true">a</div><div style="display: none">d</div><p style="visibility:hidden">v</p><p>shown</p>)
        )

      assert html == "<p>shown</p>"
    end

    test "escapes all text and attribute values" do
      html =
        clean(
          ~s|<p>&lt;script&gt;alert(1)&lt;/script&gt; "q" & 'a'</p><p><img src="/a.png" alt="&quot; onerror=&quot;alert(1)"></p>|
        )

      assert html =~ "<p>&lt;script&gt;alert(1)&lt;/script&gt; &quot;q&quot; &amp; &#39;a&#39;</p>"
      assert html =~ ~s|alt="&quot; onerror=&quot;alert(1)"|
      refute html =~ "<script"
    end

    test "demotes h1, unwraps unknown tags and keeps their text in paragraphs" do
      html =
        clean(
          "<h1>Title</h1><div><span>first</span></div><section>second <em>part</em></section><custom-el>third</custom-el>"
        )

      assert html == "<h2>Title</h2><p>first</p><p>second <em>part</em></p><p>third</p>"
    end

    test "drops empty blocks" do
      assert clean("<p></p><p>  </p><p><br></p><ul><li></li></ul><blockquote> </blockquote><h2> </h2><p>x</p>") ==
               "<p>x</p>"
    end

    test "keeps lists, quotes, code, tables and rules" do
      html =
        clean("""
        <ul><li>one</li><li>two <ol><li>a</li></ol></li></ul>
        <blockquote><p>quote</p></blockquote>
        <pre class="highlight"><code class="language-elixir">  def x,
            do: 1</code></pre>
        <pre><code class="makeup elixir"><span class="kd">x</span></code></pre>
        <hr>
        <table><tr><th rowspan="2" style="x">H</th><td colspan="3" onclick="x">D</td><td colspan="9999">E</td></tr></table>
        <p>H<sub>2</sub>O and x<sup>2</sup>, <del>old</del> <s>gone</s> <u>u</u></p>
        """)

      assert html =~ "<ul><li>one</li><li><p>two</p><ol><li>a</li></ol></li></ul>"
      assert html =~ "<blockquote><p>quote</p></blockquote>"
      assert html =~ ~s(<pre><code class="language-elixir">  def x,\n    do: 1</code></pre>)
      assert html =~ "<pre><code>x</code></pre>"
      assert html =~ "<hr>"

      assert html =~
               ~s(<div class="table-wrap"><table><tbody><tr><th rowspan="2">H</th><td colspan="3">D</td><td>E</td></tr></tbody></table></div>)

      assert html =~ "H<sub>2</sub>O and x<sup>2</sup>, <s>old</s> <s>gone</s> <u>u</u>"
    end

    test "turns a Markdown task list's checkboxes into marks" do
      html =
        clean(
          ~s(<ul><li><input type="checkbox" checked disabled> done</li><li><input type="checkbox" disabled> todo</li></ul>)
        )

      assert html == "<ul><li>☑ done</li><li>☐ todo</li></ul>"
    end

    test "the malicious page keeps only allowlisted markup" do
      html = clean(page("reader/malicious.html"))

      assert_allowlisted(html)
      refute html =~ ~r/javascript|vbscript|data:|onerror|onload|onclick|alert\(1\)<\/script/i
      refute html =~ ~r/secret hidden|aria hidden|display none|noscript|template|svg text|evil\.swf|<script/
      # The parser closes the outer link where the inner one starts.
      assert hrefs(html) == [
               "https://evil.example/x",
               "https://example.com/safe",
               "https://outer.example",
               "https://inner.example"
             ]

      assert html =~ "Inside details."
    end
  end

  describe "images" do
    test "keeps src, alt and size, resolving relative URLs" do
      {html, images} =
        Sanitizer.sanitize_html(
          ~s(<p><img src="/a.png" alt="A" width="640" height="480" class="x" loading="lazy" onerror="x"></p>),
          @base
        )

      assert html == ~s(<p><img src="https://example.com/a.png" alt="A" width="640" height="480"></p>)
      assert images == ["https://example.com/a.png"]
    end

    test "picks the lazy source when src is a placeholder" do
      {_html, images} =
        Sanitizer.sanitize_html(
          """
          <p><img src="data:image/gif;base64,R0" data-src="/one.jpg"></p>
          <p><img src="/spacer.gif" data-srcset="/two-400.jpg 400w, /two-1600.jpg 1600w, /two-3200.jpg 3200w"></p>
          <p><img srcset="/three-1x.jpg 1x, /three-2x.jpg 2x"></p>
          <picture><source srcset="/four.avif"><img src="/four.jpg"></picture>
          """,
          @base
        )

      assert images == [
               "https://example.com/one.jpg",
               "https://example.com/two-1600.jpg",
               "https://example.com/three-2x.jpg",
               "https://example.com/four.jpg"
             ]
    end

    test "drops images without a safe source and tracking pixels" do
      {html, images} =
        Sanitizer.sanitize_html(
          ~s|<p>x <img src="javascript:alert(1)"> <img src="data:image/png;base64,AA"> <img> <img src="/p.gif" width="1" height="1"></p>|,
          @base
        )

      assert images == []
      refute html =~ "<img"
    end

    test "keeps at most 20 distinct images" do
      imgs = Enum.map_join(1..25, &~s(<p><img src="/#{&1}.png"></p>))
      {html, images} = Sanitizer.sanitize_html(imgs <> ~s(<p><img src="/1.png"></p>), @base)

      assert length(images) == 20
      assert html |> LazyHTML.from_fragment() |> LazyHTML.query("img") |> Enum.count() == 21
    end

    test "the :image option decides the final source" do
      image = fn
        "https://example.com/posts/keep.png" -> {:ok, %{src: "/images/abc", width: 10, height: 20}}
        _url -> :drop
      end

      {html, _images} =
        Sanitizer.sanitize_html(~s(<p><img src="keep.png" alt="k"><img src="drop.png"></p>), @base, image: image)

      assert html == ~s(<p><img src="/images/abc" alt="k" width="10" height="20"></p>)
    end
  end

  test "stops at a block boundary under 300 KB" do
    paragraph = "<p>" <> String.duplicate("bees ", 2000) <> "</p>"
    {html, _images} = Sanitizer.sanitize_html(String.duplicate(paragraph, 40), @base)

    assert byte_size(html) <= 300_000
    assert String.ends_with?(html, "</p>")
    assert html |> String.split("<p>", trim: true) |> length() == div(300_000, byte_size(paragraph) - 1)
  end

  test "safe_url/2 accepts only absolute http(s) URLs" do
    assert Sanitizer.safe_url("/a b", @base) == "https://example.com/a%20b"
    assert Sanitizer.safe_url("http://other.test", @base) == "http://other.test"
    assert Sanitizer.safe_url("javascript:x", @base) == nil
    assert Sanitizer.safe_url("ftp://x.test/a", @base) == nil
    assert Sanitizer.safe_url("https://" <> String.duplicate("a", 3000) <> ".test", @base) == nil
    assert Sanitizer.safe_url(nil, @base) == nil
  end
end
