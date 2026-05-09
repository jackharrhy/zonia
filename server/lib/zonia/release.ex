defmodule Zonia.Release do
  @moduledoc """
  Release tasks that can be run without Mix.

  Used by `rel/overlays/bin/migrate` for manual migration ops in production.
  Note: migrations also run automatically on boot via `Ecto.Migrator` in the
  supervision tree (gated by RELEASE_NAME), so this is rarely needed.

      # Run migrations
      bin/zonia eval "Zonia.Release.migrate"

      # Roll back to a specific version
      bin/zonia eval "Zonia.Release.rollback(Zonia.Repo, 20260509041910)"
  """

  @app :zonia

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
