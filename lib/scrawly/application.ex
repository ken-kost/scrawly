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
      # Registry and DynamicSupervisor for RoomServer processes
      {Registry, keys: :unique, name: Scrawly.RoomRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Scrawly.RoomSupervisor},
      # Presence tracking for game channels
      ScrawlyWeb.Presence,
      # Round timer for game flow management
      Scrawly.Games.RoundTimer,
      # Shared canvas for the home-page demo board
      Scrawly.Games.DemoBoardServer,
      # Start to serve requests, typically the last entry
      ScrawlyWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :scrawly]}
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
