defmodule Zonia.Accounts do
  @moduledoc """
  Identity for zonia.

  Names are unique (case-insensitive) and forever. On registration we mint a
  256-bit random key, return it to the caller exactly once, and persist only
  its SHA-256 hash. The key is the bearer token used to authenticate later
  socket connections.
  """

  import Ecto.Query

  alias Zonia.Accounts.User
  alias Zonia.Repo

  @name_regex ~r/\A[A-Za-z0-9_-]{2,24}\z/

  @reserved_names MapSet.new(~w(
    system admin administrator mod moderator server zonia
    root null undefined me you everyone here bot
  ))

  @typedoc "An opaque registration result. The raw key is only ever returned at registration time."
  @type registration :: %{user: User.t(), key: String.t()}

  @doc """
  Register a new user. Returns `{:ok, %{user, key}}` or `{:error, reason}`.

  Reasons:
    * `:name_invalid` — fails regex (length / charset)
    * `:name_reserved`
    * `:name_taken`
  """
  @spec register(String.t()) :: {:ok, registration()} | {:error, atom()}
  def register(name) when is_binary(name) do
    with :ok <- validate_name(name),
         normalized <- String.downcase(name),
         :ok <- check_reserved(normalized),
         key <- mint_key(),
         {:ok, user} <- insert_user(name, normalized, hash_key(key)) do
      {:ok, %{user: user, key: key}}
    end
  end

  def register(_), do: {:error, :name_invalid}

  @doc """
  Look up a user by their bearer key. Returns `{:ok, user}` or `:error`.
  """
  @spec authenticate(String.t()) :: {:ok, User.t()} | :error
  def authenticate(key) when is_binary(key) and byte_size(key) > 0 do
    hash = hash_key(key)

    case Repo.one(from u in User, where: u.key_hash == ^hash) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  def authenticate(_), do: :error

  @doc "Returns the validation regex for clients/tests that want to mirror it."
  def name_regex, do: @name_regex

  ## Private

  defp validate_name(name) do
    if Regex.match?(@name_regex, name), do: :ok, else: {:error, :name_invalid}
  end

  defp check_reserved(normalized) do
    if MapSet.member?(@reserved_names, normalized),
      do: {:error, :name_reserved},
      else: :ok
  end

  defp mint_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  defp insert_user(name, normalized, key_hash) do
    %User{}
    |> Ecto.Changeset.cast(
      %{name: name, name_normalized: normalized, key_hash: key_hash},
      [:name, :name_normalized, :key_hash]
    )
    |> Ecto.Changeset.unique_constraint(:name_normalized)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :name_normalized),
          do: {:error, :name_taken},
          else: {:error, :insert_failed}
    end
  end
end
