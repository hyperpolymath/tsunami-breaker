defmodule TsunamiBreaker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TsunamiBreakerWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:tsunami_breaker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TsunamiBreaker.PubSub},
      {TsunamiBreaker.ViewerStore,
       path: Application.get_env(:tsunami_breaker, :viewer_store_path)},
      # Start a worker by calling: TsunamiBreaker.Worker.start_link(arg)
      # {TsunamiBreaker.Worker, arg},
      # Start to serve requests, typically the last entry
      TsunamiBreakerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TsunamiBreaker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TsunamiBreakerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
