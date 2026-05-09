defmodule Zonia.Accounts.User do
  use Ecto.Schema

  schema "users" do
    field :name, :string
    field :name_normalized, :string
    field :key_hash, :string

    timestamps(type: :utc_datetime)
  end
end
