defmodule Acervo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AcervoWeb.Telemetry,
      Acervo.Repo,
      {DNSCluster, query: Application.get_env(:acervo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Acervo.PubSub},
      {Oban, Application.fetch_env!(:acervo, Oban)},
      # Query embeddings run here, unlinked, so a slow one outlives its search.
      {Task.Supervisor, name: Acervo.TaskSupervisor},
      Acervo.Search.QueryCache
    ]

    # Prometheus metrics on their own port, only where the endpoint serves.
    children = if AcervoWeb.Metrics.enabled?(), do: children ++ [AcervoWeb.Metrics], else: children

    # Start to serve requests, typically the last entry
    children = children ++ [AcervoWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Acervo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AcervoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
