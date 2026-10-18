defmodule AcervoWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AcervoWeb.CoreComponents

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
end
