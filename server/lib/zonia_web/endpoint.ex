defmodule ZoniaWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :zonia

  @session_options [
    store: :cookie,
    key: "_zonia_key",
    signing_salt: "7grwIlIM",
    same_site: "Lax"
  ]

  plug Plug.Static,
    at: "/",
    from: :zonia,
    gzip: not code_reloading?,
    only: ZoniaWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :zonia
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ZoniaWeb.Router
end
