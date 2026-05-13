defmodule ZoniaWeb.Presence do
  use Phoenix.Presence,
    otp_app: :zonia,
    pubsub_server: Zonia.PubSub
end
