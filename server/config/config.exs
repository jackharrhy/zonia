import Config

config :zonia,
  ecto_repos: [Zonia.Repo],
  generators: [timestamp_type: :utc_datetime]

config :zonia, ZoniaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ZoniaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Zonia.PubSub,
  live_view: [signing_salt: "jbL7kg7r"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
