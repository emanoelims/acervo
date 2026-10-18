defmodule AcervoWeb.Locale do
  @moduledoc """
  Resolves the interface locale from the `acervo_locale` cookie (default
  `pt_BR`) for controllers and LiveViews.
  """
  import Plug.Conn

  @locales ~w(pt_BR en)
  @default "pt_BR"
  @cookie "acervo_locale"

  def locales, do: @locales
  def cookie, do: @cookie

  def normalize(locale) when locale in @locales, do: locale
  def normalize(_), do: @default

  def html_lang("pt_BR"), do: "pt-BR"
  def html_lang(locale), do: locale

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    locale = normalize(conn.cookies[@cookie])
    Gettext.put_locale(AcervoWeb.Gettext, locale)
    conn |> put_session(:locale, locale) |> assign(:locale, locale)
  end

  def on_mount(:default, _params, session, socket) do
    locale = normalize(session["locale"])
    Gettext.put_locale(AcervoWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end
end
