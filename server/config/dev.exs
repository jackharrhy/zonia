import Config

config :zonia, Zonia.Repo,
  database: Path.expand("../zonia_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :zonia, ZoniaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "Uj26MjHmbgpvc+gVxugeymviLn1bJSXvKE4cek/oBzoSmR18VOXHzYVEzHUti6ZG",
  watchers: []

config :zonia, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
