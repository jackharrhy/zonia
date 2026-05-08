import Config

config :zonia, Zonia.Repo,
  database: Path.expand("../zonia_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :zonia, ZoniaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Dlq3jl9lC0kqYYgHlJ5L7E6jOtl5n/ZPAvwSArwlW3Uza2UJQLwmXbx/ES455QL+",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix,
  sort_verified_routes_query_params: true
