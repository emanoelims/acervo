defmodule AcervoWeb.UIComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AcervoWeb.UIComponents
  alias Phoenix.LiveView.UploadConfig

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> find(selector) |> Enum.count()
  defp attribute(html, selector, name), do: html |> find(selector) |> LazyHTML.attribute(name)

  describe "column/1 and column_head/1" do
    test "a titled column has the up pill, the scroll hook and an h2 heading" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UIComponents.column id="c" title="All" key="1">
          <:actions><button id="act">A</button></:actions>
          <p id="body">Body</p>
        </UIComponents.column>
        """)

      assert count(html, "section#c.column > button#c-up.column-up") == 1
      assert attribute(html, "#c-scroll", "data-key") == ["1"]
      assert count(html, "#c-scroll > header.column-head > h2 > .column-title") == 1
      assert count(html, ".column-head > #act") == 1
      assert count(html, "#c-scroll > #body") == 1
    end

    test "a heading slot replaces the title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UIComponents.column id="c" title="All">
          <:heading>
            <form id="rename"></form>
          </:heading>
          Body
        </UIComponents.column>
        """)

      assert count(html, ".column-head > #rename") == 1
      assert count(html, ".column-head > h2") == 0
    end

    test "an untitled column has no header" do
      assigns = %{}
      html = rendered_to_string(~H|<UIComponents.column id="c">Body</UIComponents.column>|)
      assert count(html, ".column-head") == 0
      assert count(html, ".column-up") == 0
    end

    test "column_head/1 renders the page title as h1" do
      html = render_component(&UIComponents.column_head/1, title: "Acervo", level: "h1")
      assert html |> find("header.column-head > h1 > .column-title") |> LazyHTML.text() == "Acervo"
    end
  end

  test "nav_item/1 marks the active row and shows its count and dot" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <UIComponents.nav_item id="n" navigate="/inbox" active count={3} dot>Inbox</UIComponents.nav_item>
      """)

    assert attribute(html, "li > a#n.nav-item.is-active", "aria-current") == ["page"]
    assert attribute(html, "a#n", "data-phx-link") == ["patch"]
    assert html |> find(".nav-count") |> LazyHTML.text() == "3"
    assert count(html, ".nav-dot") == 1
  end

  describe "icon_button/1" do
    test "renders a labelled button by default" do
      html = render_component(&UIComponents.icon_button/1, icon: "lucide-check", label: "Done", id: "b")

      assert attribute(html, "button#b.round[type=button]", "aria-label") == ["Done"]
      assert attribute(html, "button#b", "title") == ["Done"]
      assert count(html, "button#b > .lucide-check.size-4") == 1
    end

    test "variants, sizes and states map to their classes" do
      html = render_component(&UIComponents.icon_button/1, icon: "lucide-check", label: "Done", size: "sm")
      assert count(html, "button.round.round-sm > .size-\\[15px\\]") == 1

      html = render_component(&UIComponents.icon_button/1, icon: "lucide-x", label: "Delete", danger: true, active: true)
      assert count(html, "button.round.round-danger.is-active") == 1

      for {variant, class} <- [{"head", "head-button"}, {"plain", "icon-button"}, {"nav", "nav-add"}] do
        html = render_component(&UIComponents.icon_button/1, icon: "lucide-x", label: "X", variant: variant)
        assert count(html, "button.#{class}") == 1
      end
    end

    test "renders a link with a destination and a label for a file input" do
      html = render_component(&UIComponents.icon_button/1, icon: "lucide-x", label: "Close", patch: "/all")
      assert attribute(html, "a.round", "href") == ["/all"]

      html = render_component(&UIComponents.icon_button/1, icon: "lucide-camera", label: "Shot", for: "upload-ref")
      assert attribute(html, "label.round", "for") == ["upload-ref"]
    end
  end

  test "pill_button/1 renders a link with its trailing icon" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <UIComponents.pill_button href="https://example.com" icon="lucide-arrow-up-right">Open</UIComponents.pill_button>
      """)

    assert attribute(html, "a.pill-button", "href") == ["https://example.com"]
    assert count(html, "a.pill-button > .lucide-arrow-up-right") == 1
  end

  describe "chips" do
    test "chip/1 takes its size and the suggestion style" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <UIComponents.chip id="c" size="sm" ai>Design</UIComponents.chip>
        """)

      assert html |> find("span#c.chip.chip-sm.ai") |> LazyHTML.text() |> String.trim() == "Design"
    end

    test "chip_remove/1 has its own tooltip and accessible name" do
      html = render_component(&UIComponents.chip_remove/1, label: "Dismiss Design", title: "Dismiss", id: "x")

      assert attribute(html, "button#x.chip-x", "aria-label") == ["Dismiss Design"]
      assert attribute(html, "button#x", "title") == ["Dismiss"]
    end

    test "waiting_chip/1 is a hidden dashed chip with a shimmer bar" do
      html = render_component(&UIComponents.waiting_chip/1, size: "sm")
      assert attribute(html, "span.chip.chip-sm.ai.is-waiting > .wait-bar", "class") == ["wait-bar"]
      assert attribute(html, "span.chip", "aria-hidden") == ["true"]
    end
  end

  test "float_pill/1 renders its icon, content and key hint" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <UIComponents.float_pill id="p" icon="lucide-search" loading role="search">
        <input id="q" />
        <:kbd>K</:kbd>
      </UIComponents.float_pill>
      """)

    assert attribute(html, "div#p.float", "role") == ["search"]
    assert count(html, "#p > .float-icon.lucide-search.is-loading") == 1
    assert count(html, "#p > input#q") == 1
    assert html |> find("#p > kbd.float-kbd") |> LazyHTML.text() == "K"
  end

  test "drop_zone/1 targets the upload and shows its translated errors" do
    upload = %UploadConfig{name: :file, ref: "phx-ref", entries: [], errors: [{"phx-ref", :too_many_files}]}
    assigns = %{upload: upload}

    html =
      rendered_to_string(~H"""
      <UIComponents.drop_zone
        id="d"
        upload={@upload}
        icon="lucide-file-up"
        hint="Drop it"
        error_id="d-error"
        error_message={&"error: #{&1}"}
      />
      """)

    assert attribute(html, "label#d.shot-drop", "for") == ["phx-ref"]
    assert attribute(html, "label#d", "phx-drop-target") == ["phx-ref"]
    assert html |> find(".shot-hint") |> LazyHTML.text() == "Drop it"
    assert html |> find("#d-error[role=alert]") |> LazyHTML.text() |> String.trim() == "error: too_many_files"
  end

  test "empty/1 renders a quiet line" do
    assigns = %{}
    html = rendered_to_string(~H|<UIComponents.empty id="e" class="x">Nothing.</UIComponents.empty>|)
    assert html |> find("p#e.empty.x") |> LazyHTML.text() == "Nothing."
  end

  test "mod_key/1 renders both keys, Ctrl with a plus when asked" do
    html = render_component(&UIComponents.mod_key/1, plus: true)
    assert html |> find(".key-mac") |> LazyHTML.text() == "⌘"
    assert html |> find(".key-other") |> LazyHTML.text() == "Ctrl+"
  end
end
