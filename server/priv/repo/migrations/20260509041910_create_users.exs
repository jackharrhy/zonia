defmodule Zonia.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :name_normalized, :string, null: false
      add :key_hash, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:name_normalized])
  end
end
