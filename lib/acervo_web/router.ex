defmodule AcervoWeb.Router do
  use AcervoWeb, :router

  import AcervoWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug AcervoWeb.Locale
    plug :put_root_layout, html: {AcervoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
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
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AcervoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", AcervoWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{AcervoWeb.UserAuth, :require_authenticated}, AcervoWeb.Locale] do
      live "/", ArchiveLive, :home
      live "/inbox", ArchiveLive, :inbox
      live "/all", ArchiveLive, :all
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end
  end

  scope "/", AcervoWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{AcervoWeb.UserAuth, :mount_current_scope}, AcervoWeb.Locale] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
