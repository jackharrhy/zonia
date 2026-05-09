defmodule ZoniaWeb.Presence do
  @moduledoc """
  Tracks who is currently in the world.
  """
  use Phoenix.Presence,
    otp_app: :zonia,
    pubsub_server: Zonia.PubSub
end
