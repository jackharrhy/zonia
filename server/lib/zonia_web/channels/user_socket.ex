defmodule ZoniaWeb.UserSocket do
  @moduledoc """
  The main user socket.

  Two flavors of connection:

    * Authenticated: `params["key"]` is present and valid. The user's id is
      stashed in socket assigns and `lobby:*` / `game:*` channels are
      joinable.

    * Unregistered: no key (or invalid key). Only the `register:lobby`
      channel is joinable, which exposes a single `register` event that mints
      a fresh identity. After registering, the client is expected to
      disconnect and reconnect with the new key.
  """
  use Phoenix.Socket

  alias Zonia.Accounts

  channel("register:lobby", ZoniaWeb.RegisterChannel)
  channel("lobby:main", ZoniaWeb.LobbyChannel)

  @impl true
  def connect(%{"key" => key}, socket, _connect_info) when is_binary(key) and key != "" do
    case Accounts.authenticate(key) do
      {:ok, user} ->
        {:ok,
         socket
         |> assign(:user_id, user.id)
         |> assign(:user_name, user.name)
         |> assign(:authenticated, true)}

      :error ->
        :error
    end
  end

  def connect(_params, socket, _connect_info) do
    {:ok, assign(socket, :authenticated, false)}
  end

  @impl true
  def id(%{assigns: %{user_id: user_id}}), do: "user:#{user_id}"
  def id(_socket), do: nil
end
