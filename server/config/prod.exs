import Config

# TLS is terminated by traefik on the host. The redirect-to-https middleware
# in mug's compose.yml already 301s plain HTTP to HTTPS at the edge.
#
# We deliberately do NOT enable Phoenix's force_ssl here: Plug.SSL only
# treats X-Forwarded-Proto: https as secure, but traefik forwards "wss"
# for WebSocket upgrades, which would 301 our /socket/websocket handshake
# into an infinite loop.
config :logger, level: :info
