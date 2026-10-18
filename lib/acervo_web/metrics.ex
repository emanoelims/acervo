defmodule AcervoWeb.Metrics do
  @moduledoc """
  Prometheus metrics, served at `/metrics` on their own port for Fly's
  scraper (`[metrics]` in `fly.toml`), never through the public endpoint.

  It runs only where the endpoint serves requests (`mix phx.server` or a
  release with `PHX_SERVER`), so tests, mix tasks and `bin/acervo eval` start
  none of it. `config :acervo, :metrics` sets the `:port` (`METRICS_PORT`,
  9568 by default) and the `:ip` (localhost in development, every interface
  in production).

  Labels come only from `allowed_tags/0`, bounded sets such as the AI
  operation or the Oban queue: never user ids, queries, URLs, titles or error
  messages. Counters reset on restart; dashboards use `increase()`/`rate()`.
  """
  use Supervisor

  import Telemetry.Metrics

  @reporter :acervo_metrics

  @allowed_tags [:operation, :model, :status, :queue, :worker, :state, :route, :partial, :cached, :scoped]

  # Seconds. AI calls span a 200 ms embedding to a minute-long enrichment.
  @ai_buckets [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20, 30, 60, 120]
  @search_buckets [0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5]
  @request_buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
  @job_buckets [0.01, 0.05, 0.1, 0.5, 1, 5, 10, 30, 60, 300]
  @query_buckets [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1]

  @doc "Whether the metrics server runs: only alongside a serving endpoint."
  @spec enabled?() :: boolean()
  def enabled?, do: Phoenix.Endpoint.server?(:acervo, AcervoWeb.Endpoint)

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :supervisor, __MODULE__))
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:acervo, :metrics, []), opts)
    reporter = Keyword.get(config, :reporter, @reporter)

    pollers =
      if Keyword.get(config, :pollers, true) do
        [
          {:telemetry_poller,
           name: :"#{reporter}_poller",
           period: to_timeout(second: 30),
           measurements: [
             {Acervo.Metrics, :dispatch_queue_depth, []},
             {Acervo.Metrics, :dispatch_link_totals, []}
           ]}
        ]
      else
        []
      end

    children =
      [
        {TelemetryMetricsPrometheus.Core, name: reporter, metrics: metrics()}
        | pollers
      ] ++
        [
          Supervisor.child_spec(
            {Bandit,
             plug: {AcervoWeb.Metrics.Plug, reporter: reporter},
             scheme: :http,
             ip: Keyword.get(config, :ip, {127, 0, 0, 1}),
             port: Keyword.get(config, :port, 9568),
             startup_log: false},
            id: :server
          )
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "The only tags a metric may use; anything else could carry user data."
  @spec allowed_tags() :: [atom()]
  def allowed_tags, do: @allowed_tags

  @doc "Every metric exported at `/metrics`."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics, do: ai() ++ search() ++ jobs() ++ web() ++ repo() ++ vm()

  defp ai do
    event = [:acervo, :ai, :call, :stop]

    [
      counter("acervo.ai.calls.total", event_name: event, tags: [:operation, :model, :status]),
      sum("acervo.ai.input_tokens.total", event_name: event, measurement: :input_tokens, tags: [:operation, :model]),
      sum("acervo.ai.output_tokens.total", event_name: event, measurement: :output_tokens, tags: [:operation, :model]),
      # The reporter's sums are integer counters: cost is kept in billionths of
      # a dollar, so a single query embedding still counts.
      sum("acervo.ai.cost.nanousd.total",
        event_name: event,
        measurement: &round(&1.cost_usd * 1_000_000_000),
        tags: [:operation, :model],
        description: "Estimated cost in billionths of a US dollar"
      ),
      distribution("acervo.ai.call.duration.seconds",
        event_name: event,
        measurement: :duration,
        unit: {:native, :second},
        tags: [:operation, :model],
        reporter_options: [buckets: @ai_buckets]
      )
    ]
  end

  defp search do
    event = [:acervo, :search, :stop]

    [
      counter("acervo.search.total", event_name: event, tags: [:partial, :cached, :scoped]),
      sum("acervo.search.results.total", event_name: event, measurement: :results),
      distribution("acervo.search.duration.seconds",
        event_name: event,
        measurement: :duration,
        unit: {:native, :second},
        reporter_options: [buckets: @search_buckets]
      )
    ]
  end

  defp jobs do
    [
      counter("oban.job.stop.count", tags: [:queue, :worker, :state]),
      counter("oban.job.exception.count", tags: [:queue, :worker, :state]),
      distribution("oban.job.stop.duration.seconds",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:queue, :worker],
        reporter_options: [buckets: @job_buckets]
      ),
      distribution("oban.job.stop.queue_time.seconds",
        event_name: [:oban, :job, :stop],
        measurement: :queue_time,
        unit: {:native, :second},
        tags: [:queue],
        reporter_options: [buckets: @job_buckets]
      ),
      last_value("acervo.oban.queue.depth", tags: [:queue, :state]),
      last_value("acervo.links.status.count", tags: [:status]),
      last_value("acervo.links.enrichment.count", tags: [:status]),
      last_value("acervo.links.embedding.count", tags: [:status])
    ]
  end

  defp web do
    [
      distribution("phoenix.endpoint.stop.duration.seconds",
        event_name: [:phoenix, :endpoint, :stop],
        measurement: :duration,
        unit: {:native, :second},
        reporter_options: [buckets: @request_buckets]
      ),
      distribution("phoenix.router_dispatch.stop.duration.seconds",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:route],
        reporter_options: [buckets: @request_buckets]
      ),
      distribution("phoenix.live_view.mount.stop.duration.seconds",
        event_name: [:phoenix, :live_view, :mount, :stop],
        measurement: :duration,
        unit: {:native, :second},
        reporter_options: [buckets: @request_buckets]
      ),
      distribution("phoenix.live_view.handle_event.stop.duration.seconds",
        event_name: [:phoenix, :live_view, :handle_event, :stop],
        measurement: :duration,
        unit: {:native, :second},
        reporter_options: [buckets: @request_buckets]
      )
    ]
  end

  defp repo do
    [
      distribution("acervo.repo.query.total_time.seconds",
        event_name: [:acervo, :repo, :query],
        measurement: :total_time,
        unit: {:native, :second},
        reporter_options: [buckets: @query_buckets]
      )
    ]
  end

  # From telemetry_poller's default poller, every 5 s.
  defp vm do
    [
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("vm.system_counts.process_count")
    ]
  end
end
