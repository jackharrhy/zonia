defmodule Zonia.Repo do
  use Ecto.Repo,
    otp_app: :zonia,
    adapter: Ecto.Adapters.SQLite3
end
