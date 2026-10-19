defmodule AcervoWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AcervoWeb.CoreComponents

  setup do
    Gettext.put_locale(AcervoWeb.Gettext, "en")
    :ok
  end

  test "button uses leitor's action classes" do
    assigns = %{}

    html =
      rendered_to_string(~H|<CoreComponents.button variant="primary">Go</CoreComponents.button>|)

    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.filter("button.action.action-primary") |> Enum.count() == 1
  end

  test "popover renders a details element with a Floating positioner and panel" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.popover id="p" label="Open">
        <:trigger>Open</:trigger>
        Panel
      </CoreComponents.popover>
      """)

    doc = LazyHTML.from_fragment(html)

    assert doc |> LazyHTML.query("details#p > #p-positioner[phx-hook=Floating]") |> Enum.count() == 1
    assert doc |> LazyHTML.query("details#p > #p-panel.popover-panel") |> Enum.count() == 1
  end

  test "acervo-mark icon renders the inline logo" do
    html = render_component(&CoreComponents.icon/1, name: "acervo-mark")
    assert html |> LazyHTML.from_fragment() |> LazyHTML.filter("svg.acervo-mark") |> Enum.count() == 1
  end

  test "input with an error sets aria-invalid and points aria-describedby at the error" do
    form = Phoenix.Component.to_form(%{"email" => ""}, errors: [email: {"can't be blank", []}])
    assigns = %{field: form[:email]}

    html = rendered_to_string(~H|<CoreComponents.input field={@field} type="email" />|)
    doc = LazyHTML.from_fragment(html)

    input = LazyHTML.query(doc, "input[type=email]")
    assert LazyHTML.attribute(input, "aria-invalid") == ["true"]
    [described_by] = LazyHTML.attribute(input, "aria-describedby")

    errors = LazyHTML.query(doc, "[id='#{described_by}'] .field-error")
    assert errors |> LazyHTML.text() |> String.contains?("can't be blank")
  end

  test "popover uses the caller-translated label for title and aria-label" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.popover id="p" label="Abrir">
        <:trigger>x</:trigger>
        Panel
      </CoreComponents.popover>
      """)

    summary = html |> LazyHTML.from_fragment() |> LazyHTML.query("summary#p-trigger")
    assert LazyHTML.attribute(summary, "title") == ["Abrir"]
    assert LazyHTML.attribute(summary, "aria-label") == ["Abrir"]
  end

  test "dropdown_item is a link with a destination and a button without one" do
    html = render_component(&CoreComponents.dropdown_item/1, icon: "lucide-keyboard", label: "Guide", navigate: "/guide")
    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.query("a.dropdown-item[role=menuitem]") |> LazyHTML.attribute("href") == ["/guide"]

    html = render_component(&CoreComponents.dropdown_item/1, icon: "lucide-trash-2", label: "Delete", danger: true)
    doc = LazyHTML.from_fragment(html)
    button = LazyHTML.query(doc, "button.dropdown-item.dropdown-item-danger[type=button][role=menuitem]")
    assert button |> LazyHTML.query(".dropdown-item-label") |> LazyHTML.text() == "Delete"
  end
end
