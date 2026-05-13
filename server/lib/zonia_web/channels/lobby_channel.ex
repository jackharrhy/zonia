defmodule ZoniaWeb.LobbyChannel do
  @moduledoc """
  The lobby. Players land here after registration. From here they
  create rooms, join other people's rooms, chat with everyone, and
  (eventually) transition into a game.

  Only authenticated sockets can join. The channel is a thin shim over
  `Zonia.LobbyServer` — it forwards client actions to the server,
  pushes back replies, and subscribes to room-listing broadcasts so all
  clients see room changes live.

  ## Events out

    * `rooms` — `%{rooms: [...]}`. The current room list. Pushed once
      on join and again whenever the listing changes.
    * `say` — `%{name, body, at}`. Chat broadcast.
    * `presence_state`, `presence_diff` — `Phoenix.Presence`.

  ## Events in

    * `create_room` — `%{}` (defaults used for v1). Replies
      `{:ok, %{room}}` or `{:error, %{reason}}`.
    * `join_room` — `%{"code" => "BX7Q"}`. Replies similarly.
    * `leave_room` — `%{"code" => "BX7Q"}`. Replies `:ok` or error.
    * `start_game` — `%{"code" => "BX7Q"}`. Step 2 just acks; step 3
      will actually transition the room into a game.
    * `say` — `%{"body" => "hi"}`. Broadcast to all subscribers.
  """
  use ZoniaWeb, :channel

  alias Phoenix.PubSub
  alias Zonia.LobbyServer
  alias ZoniaWeb.Presence

  @pubsub Zonia.PubSub
  @max_say_body 500

  @impl true
  def join("lobby:main", _payload, %{assigns: %{authenticated: true}} = socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  def join("lobby:main", _payload, _socket) do
    {:error, %{reason: "unauthenticated"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Track the user in Presence so other lobby clients can see them.
    {:ok, _ref} =
      Presence.track(socket, to_string(socket.assigns.user_id), %{
        name: socket.assigns.user_name,
        online_at: System.system_time(:second)
      })

    push(socket, "presence_state", Presence.list(socket))

    # Subscribe to room listing changes so we can push fresh snapshots.
    PubSub.subscribe(@pubsub, LobbyServer.listing_topic())
    push_rooms(socket)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:room_listing_changed, socket) do
    push_rooms(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_in("create_room", _payload, socket) do
    user = current_user(socket)

    case LobbyServer.create_room(user) do
      {:ok, room} ->
        {:reply, {:ok, %{room: encode_room(room)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("join_room", %{"code" => code}, socket) when is_binary(code) do
    user = current_user(socket)

    case LobbyServer.join_room(user, code) do
      {:ok, room} ->
        {:reply, {:ok, %{room: encode_room(room)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("join_room", _payload, socket) do
    {:reply, {:error, %{reason: "bad_payload"}}, socket}
  end

  def handle_in("leave_room", %{"code" => code}, socket) when is_binary(code) do
    user = current_user(socket)

    case LobbyServer.leave_room(user, code) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("leave_room", _payload, socket) do
    {:reply, {:error, %{reason: "bad_payload"}}, socket}
  end

  def handle_in("start_game", %{"code" => code}, socket) when is_binary(code) do
    user = current_user(socket)

    case LobbyServer.start_game(user, code) do
      {:ok, _room} ->
        # Step 2 stub. Step 3 will fan out a `game_started` event with
        # the new game id so clients can transition into the game scene.
        {:reply, {:ok, %{message: "game start not implemented"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("start_game", _payload, socket) do
    {:reply, {:error, %{reason: "bad_payload"}}, socket}
  end

  def handle_in("say", %{"body" => body}, socket) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" ->
        {:reply, {:error, %{reason: "empty"}}, socket}

      String.length(trimmed) > @max_say_body ->
        {:reply, {:error, %{reason: "too_long"}}, socket}

      true ->
        broadcast!(socket, "say", %{
          name: socket.assigns.user_name,
          body: trimmed,
          at: System.system_time(:second)
        })

        {:reply, :ok, socket}
    end
  end

  def handle_in("say", _payload, socket) do
    {:reply, {:error, %{reason: "bad_payload"}}, socket}
  end

  ## ── Helpers ────────────────────────────────────────────────────────────

  defp current_user(socket) do
    %{id: socket.assigns.user_id, name: socket.assigns.user_name}
  end

  defp push_rooms(socket) do
    rooms = LobbyServer.list_rooms() |> Enum.map(&encode_room/1)
    push(socket, "rooms", %{rooms: rooms})
  end

  defp encode_room(room) do
    %{
      code: room.code,
      host_user_id: room.host_user_id,
      players:
        Enum.map(room.players, fn p ->
          %{user_id: p.user_id, name: p.name}
        end),
      board: room.board,
      total_rounds: room.total_rounds,
      max_players: room.max_players
    }
  end
end
