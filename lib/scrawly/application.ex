defmodule Scrawly.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ScrawlyWeb.Telemetry,
      Scrawly.Repo,
      {DNSCluster, query: Application.get_env(:scrawly, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Scrawly.PubSub},
      # Start a worker by calling: Scrawly.Worker.start_link(arg)
      # {Scrawly.Worker, arg},
      # Start to serve requests, typically the last entry
      ScrawlyWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Scrawly.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ScrawlyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
