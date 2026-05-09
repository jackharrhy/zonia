defmodule ZoniaWeb.Plugs.Releases do
  @moduledoc """
  Serves prebuilt client binaries + manifest.json under `/releases/*`.

  The directory is configured at runtime via
  `config :zonia, :releases_dir, "/path/to/dir"`.

  Wraps `Plug.Static` so the path can be picked up from runtime config (the
  baked-in `:from` arg of a normal `plug Plug.Static, ...` is resolved at
  compile time).
  """

  @behaviour Plug

  @impl true
  def init(_opts), do: nil

  @impl true
  def call(conn, _opts) do
    case Application.get_env(:zonia, :releases_dir) do
      nil ->
        conn

      dir when is_binary(dir) ->
        opts =
          Plug.Static.init(
            at: "/releases",
            from: dir,
            gzip: false,
            cache_control_for_etags: "public, max-age=300",
            cache_control_for_vsn_requests: "public, max-age=31536000"
          )

        Plug.Static.call(conn, opts)
    end
  end
end
