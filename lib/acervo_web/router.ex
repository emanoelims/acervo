defmodule AcervoWeb.Router do
  use AcervoWeb, :router

  import AcervoWeb.UserAuth

  @content_security_policy Enum.join(
                             [
                               "default-src 'self'",
                               "img-src 'self' data: blob:",
                               "script-src 'self'",
                               "style-src 'self' 'unsafe-inline'",
                               "font-src 'self'",
                               "connect-src 'self' ws: wss:",
                               "frame-ancestors 'self'",
                               "base-uri 'self'",
                               "form-action 'self'"
                             ],
                             "; "
                           )

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug AcervoWeb.Locale
    plug :put_root_layout, html: {AcervoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
    plug :fetch_current_scope_for_user
  end

  # Dev tools (LiveDashboard, mailbox) ship inline scripts, so they skip the strict CSP.
  pipeline :dev_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug AcervoWeb.Locale
    plug :put_root_layout, html: {AcervoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Private resources answer 404 without a user, never a login redirect.
  pipeline :private_resource do
    plug :fetch_session
    plug :fetch_current_scope_for_user
    plug :require_user_or_not_found
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Readiness probe for Fly: no pipeline, because the check sends no cookies or CSRF token.
  scope "/", AcervoWeb do
    get "/health", HealthController, :show
  end

  scope "/", AcervoWeb do
    pipe_through :browser

    get "/locale/:locale", LocaleController, :update
  end

  # The controller still scopes each image to its owner.
  scope "/", AcervoWeb do
    pipe_through :private_resource

    get "/images/:id", ImageController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", AcervoWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:acervo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :dev_browser

      live_dashboard "/dashboard", metrics: AcervoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", AcervoWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [AcervoWeb.Locale, {AcervoWeb.UserAuth, :require_authenticated}] do
      live "/", ArchiveLive, :home
      live "/inbox", ArchiveLive, :inbox
      live "/inbox/l/:id", ArchiveLive, :inbox_link
      live "/all", ArchiveLive, :all
      live "/all/l/:id", ArchiveLive, :all_link
      live "/c/:slug", ArchiveLive, :collection
      live "/c/:slug/l/:id", ArchiveLive, :collection_link
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end
  end

  scope "/", AcervoWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [AcervoWeb.Locale, {AcervoWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
