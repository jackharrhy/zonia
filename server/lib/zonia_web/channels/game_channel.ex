defmodule ZoniaWeb.GameChannel do
  @moduledoc """
  One channel per in-progress game, topic `game:<code>`.

  Authenticated sockets only, and only joinable by players in the
  game's roster (see `Zonia.GameServer.member?/2`). Joining marks
  the player `:active` (in case they're reconnecting); `terminate/2`
  marks them `:disconnected` unless they leave via the explicit
  `leave_game` event.

  ## Events out

    * `snapshot` — `%{game: <public_view>}`. Pushed on join and on
      every state change broadcast by the GameServer.
    * `say` — `%{name, body, at}`. Chat broadcast within the game.
    * `presence_state`, `presence_diff` — `Phoenix.Presence`.
    * `game_ended` — `%{}`. Pushed when the player's `leave_game`
      brings the GameServer down (they were the last). Clients use
      this to know the room is gone.

  ## Events in

    * `say` — `%{"body" => "hi"}`. Broadcast to all subscribers.
    * `leave_game` — `%{}`. Intentional leave. Replies `:ok` (or
      `:game_ended` if you were the last player). Channel terminates
      cleanly afterward; client transitions back to the lobby.

  Step 3a is a husk: no rolling, no movement, no turn logic. The
  channel just shovels snapshots back and forth.
  """
  use ZoniaWeb, :channel

  alias Phoenix.PubSub
  alias Zonia.GameServer
  alias ZoniaWeb.Presence

  @pubsub Zonia.PubSub
  @max_say_body 500

  @impl true
  def join("game:" <> code, _payload, %{assigns: %{authenticated: true}} = socket) do
    user_id = socket.assigns.user_id

    cond do
      not GameServer.member?(code, user_id) ->
        {:error, %{reason: "not_in_game"}}

      true ->
        socket =
          socket
          |> assign(:game_code, code)
          |> assign(:leaving, false)

        :ok = GameServer.mark_active(code, user_id)
        send(self(), :after_join)
        {:ok, socket}
    end
  end

  def join("game:" <> _code, _payload, _socket) do
    {:error, %{reason: "unauthenticated"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    code = socket.assigns.game_code

    {:ok, _ref} =
      Presence.track(socket, to_string(socket.assigns.user_id), %{
        name: socket.assigns.user_name,
        online_at: System.system_time(:second)
      })

    push(socket, "presence_state", Presence.list(socket))

    PubSub.subscribe(@pubsub, GameServer.snapshots_topic(code))
    push_snapshot(socket)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:snapshot, socket) do
    push_snapshot(socket)
    {:noreply, socket}
  end

  @impl true
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

  def handle_in("leave_game", _payload, socket) do
    code = socket.assigns.game_code
    user_id = socket.assigns.user_id

    case GameServer.leave(code, user_id) do
      :ok ->
        # Mark the socket as leaving so terminate/2 doesn't flip the
        # player back to :disconnected (we just removed them entirely).
        {:reply, :ok, assign(socket, :leaving, true)}

      :game_ended ->
        push(socket, "game_ended", %{})
        {:reply, :ok, assign(socket, :leaving, true)}

      :error ->
        {:reply, {:error, %{reason: "not_in_game"}}, socket}
    end
  end

  @impl true
  def terminate(_reason, %{assigns: %{game_code: code, user_id: user_id, leaving: leaving}}) do
    unless leaving do
      # Channel died without an explicit leave_game (client closed
      # terminal, network drop, crash). Hold the seat — only flip
      # status to :disconnected so other players see it.
      GameServer.mark_disconnected(code, user_id)
    end

    :ok
  end

  def terminate(_reason, _socket), do: :ok

  ## ── Helpers ────────────────────────────────────────────────────────────

  defp push_snapshot(socket) do
    code = socket.assigns.game_code

    case GameServer.snapshot(code) do
      {:ok, snap} -> push(socket, "snapshot", %{game: snap})
      :error -> push(socket, "game_ended", %{})
    end
  end
end
