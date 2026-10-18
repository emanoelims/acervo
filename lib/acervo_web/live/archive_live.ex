defmodule AcervoWeb.ArchiveLive do
  @moduledoc "The column browser: root navigation plus the selected section."
  use AcervoWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, inbox_count: 0, total_count: 0, collections_count: 0)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     assign(socket,
       return_to: return_to(uri),
       page_title: title(socket.assigns.live_action)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="columns" class="columns">
        <.column id="column-root" class="column-root">
          <h1 class="root-title">Acervo</h1>
          <p class="lead">
            {gettext("Good things I find on the internet.")}
            {links_count(@total_count)} · {collections_count(@collections_count)}.
          </p>
          <ul class="nav">
            <.nav_item
              id="nav-inbox"
              navigate={~p"/inbox"}
              active={@live_action == :inbox}
              dot={@inbox_count > 0}
              count={@inbox_count}
            >
              {gettext("Inbox")}
            </.nav_item>
            <.nav_item
              id="nav-all"
              navigate={~p"/all"}
              active={@live_action == :all}
              count={@total_count}
            >
              {gettext("All")}
            </.nav_item>
          </ul>
        </.column>

        <.column :if={@live_action == :inbox} id="column-inbox" title={gettext("Inbox")}>
          <.empty>{gettext("Nothing waiting.")}</.empty>
        </.column>

        <.column :if={@live_action == :all} id="column-all" title={gettext("All")}>
          <.empty>{gettext("Nothing saved yet.")}</.empty>
        </.column>
      </div>
      <.dock
        active={if @live_action == :inbox, do: :inbox, else: :home}
        inbox_count={@inbox_count}
        locale={@locale}
        return_to={@return_to}
      />
    </Layouts.app>
    """
  end

  # pt_BR treats 0 as singular, so zero gets its own wording.
  defp return_to(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    path <> if(query, do: "?" <> query, else: "")
  end

  defp links_count(0), do: gettext("No links")
  defp links_count(count), do: ngettext("One link", "%{count} links", count)

  defp collections_count(0), do: gettext("no collections")
  defp collections_count(count), do: ngettext("one collection", "%{count} collections", count)

  defp title(:inbox), do: gettext("Inbox")
  defp title(:all), do: gettext("All")
  defp title(:home), do: "Acervo"
end
