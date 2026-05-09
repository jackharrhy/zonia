import Config

if System.get_env("PHX_SERVER") do
  config :zonia, ZoniaWeb.Endpoint, server: true
end

config :zonia, ZoniaWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Directory of compiled client binaries + manifest.json. The Dockerfile
# stages these at /app/releases/. When unset, /releases/* is unmapped
# (the launcher will see a 404 and fall back to its cache or fail with a
# clear error).
if releases_dir = System.get_env("ZONIA_RELEASES_DIR") do
  config :zonia, :releases_dir, releases_dir
end

if config_env() == :prod do
  database_path =
    System.get_env("ZONIA_DATABASE") ||
      raise """
      environment variable ZONIA_DATABASE is missing.
      For example: /data/zonia.db
      """

  config :zonia, Zonia.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "zonia.harrhy.xyz"

  config :zonia, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :zonia, ZoniaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
