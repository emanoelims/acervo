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
      {Oban, Application.fetch_env!(:acervo, Oban)},
      {DNSCluster, query: Application.get_env(:acervo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Acervo.PubSub},
      # Start a worker by calling: Acervo.Worker.start_link(arg)
      # {Acervo.Worker, arg},
      # Start to serve requests, typically the last entry
      AcervoWeb.Endpoint
    ]

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
