defmodule Zonia.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ZoniaWeb.Telemetry,
      Zonia.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:zonia, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:zonia, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Zonia.PubSub},
      ZoniaWeb.Presence,
      Zonia.LobbyServer,
      # GameRegistry maps a room code → GameServer pid. Keys are unique;
      # one game per code.
      {Registry, keys: :unique, name: Zonia.GameRegistry},
      # GameSupervisor spawns GameServer processes on demand. Children
      # are transient — if a GameServer crashes, the game is gone.
      {DynamicSupervisor, name: Zonia.GameSupervisor, strategy: :one_for_one},
      ZoniaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Zonia.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ZoniaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end
end
