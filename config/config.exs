# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :acervo, Acervo.Mailer, adapter: Swoosh.Adapters.Local
config :acervo, Acervo.Repo, types: Acervo.PostgrexTypes

# Configure the endpoint
config :acervo, AcervoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AcervoWeb.ErrorHTML, json: AcervoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Acervo.PubSub,
  live_view: [signing_salt: "+6cU70Fy"]

config :acervo, AcervoWeb.Gettext, default_locale: "pt_BR", locales: ~w(pt_BR en)

config :acervo, Oban,
  engine: Oban.Engines.Basic,
  repo: Acervo.Repo,
  queues: [capture: 2, ai: 2, embed: 4, content: 1],
  # Below the 30 s kill_timeout in fly.toml, so jobs can finish before SIGKILL.
  shutdown_grace_period: to_timeout(second: 20),
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Above the longest job timeout (CaptureLink, 3 minutes).
    {Oban.Plugins.Lifeline, rescue_after: to_timeout(minute: 5)},
    {Oban.Plugins.Cron, crontab: [{"*/10 * * * *", Acervo.Library.ReapStuckCaptures}]}
  ]

# The model client; tests use `Acervo.FakeAIClient` (see config/test.exs).
config :acervo, :ai_client, Acervo.AI.Claude

# Registration is open in dev and test; production restricts it to
# ACERVO_ALLOWED_EMAILS (see config/runtime.exs).
config :acervo, :allowed_emails, :all

# The embedding client; tests use `Acervo.FakeEmbedder` (see config/test.exs).
config :acervo, :embedder, Acervo.AI.OpenRouterEmbedder
config :acervo, :mail_from, {"Acervo", "contato@localhost"}

# Prometheus metrics (`AcervoWeb.Metrics`): localhost only, except in
# production (see config/runtime.exs, which also reads METRICS_PORT).
config :acervo, :metrics, ip: {127, 0, 0, 1}, port: 9568

config :acervo, :scopes,
  user: [
    default: true,
    module: Acervo.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Acervo.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

# Search (`Acervo.Search`). `embed_timeout` is the whole wait for the query
# vector before falling back to text-only results flagged partial; the query
# call itself gives up after `query_receive_timeout`, so a late answer still
# fills the cache for the next keystroke. Vector hits farther than
# `max_distance` (cosine distance, so similarity below 0.27) are dropped; text
# hits are always kept.
config :acervo, :search, embed_timeout: 3_000, query_receive_timeout: 10_000, max_distance: 0.73

config :acervo,
  ecto_repos: [Acervo.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  acervo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  acervo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
