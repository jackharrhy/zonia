defmodule ZoniaWeb.LobbyChannelTest do
  # async: false because LobbyServer is a singleton started by the
  # application supervisor and its state is shared across tests. We use
  # unique user names per test to keep collisions to a minimum.
  use ZoniaWeb.ChannelCase, async: false

  alias Zonia.Accounts
  alias Zonia.LobbyServer
  alias ZoniaWeb.LobbyChannel
  alias ZoniaWeb.UserSocket

  ## ── Helpers ────────────────────────────────────────────────────────────

  defp unique_name(prefix \\ "user") do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp register_user(name \\ nil) do
    name = name || unique_name()
    {:ok, %{user: user, key: key}} = Accounts.register(name)
    %{user: user, key: key}
  end

  defp authed_socket(key) do
    {:ok, socket} = connect(UserSocket, %{"key" => key})
    socket
  end

  defp join_lobby do
    %{user: user, key: key} = register_user()
    socket = authed_socket(key)
    {:ok, _reply, socket} = subscribe_and_join(socket, LobbyChannel, "lobby:main")
    %{user: user, socket: socket}
  end

  defp drain_initial_pushes(_socket) do
    # The join handler sends both `presence_state` and `rooms` shortly
    # after join. Wait for both so later assertions only see new pushes.
    assert_push "presence_state", _
    assert_push "rooms", _
    :ok
  end

  defp create_room!(socket) do
    ref = push(socket, "create_room", %{})
    assert_reply ref, :ok, %{room: %{code: code}} = reply
    {code, reply}
  end

  ## ── Authentication ─────────────────────────────────────────────────────

  describe "join lobby:main" do
    test "unauthenticated socket is rejected" do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:error, %{reason: "unauthenticated"}} =
               subscribe_and_join(socket, LobbyChannel, "lobby:main")
    end

    test "authenticated socket joins successfully" do
      %{key: key} = register_user()
      socket = authed_socket(key)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, LobbyChannel, "lobby:main")
    end
  end

  ## ── After-join pushes ──────────────────────────────────────────────────

  describe "after join" do
    test "joiner receives a presence_state push" do
      %{socket: _socket} = join_lobby()
      assert_push "presence_state", _state
    end

    test "joiner receives a rooms push" do
      %{socket: _socket} = join_lobby()
      assert_push "rooms", %{rooms: rooms}
      assert is_list(rooms)
    end
  end

  ## ── Room actions ───────────────────────────────────────────────────────

  describe "create_room" do
    test "replies :ok with a room and broadcasts a fresh listing to subscribers" do
      %{user: user_a, socket: socket_a} = join_lobby()
      drain_initial_pushes(socket_a)

      %{socket: socket_b} = join_lobby()
      drain_initial_pushes(socket_b)

      ref = push(socket_a, "create_room", %{})

      assert_reply ref, :ok, %{room: room}
      assert is_binary(room.code)
      assert room.host_user_id == user_a.id
      assert [%{user_id: user_id, name: name}] = room.players
      assert user_id == user_a.id
      assert name == user_a.name

      # Both subscribers receive a refreshed listing that includes the new room.
      assert_push "rooms", %{rooms: rooms_a}
      assert Enum.any?(rooms_a, fn r -> r.code == room.code end)

      assert_push "rooms", %{rooms: rooms_b}
      assert Enum.any?(rooms_b, fn r -> r.code == room.code end)

      # Cleanup so subsequent tests see a clean listing.
      :ok = LobbyServer.leave_room(%{id: user_a.id, name: user_a.name}, room.code)
    end
  end

  describe "join_room" do
    test "happy path replies :ok with the updated room and re-pushes the listing" do
      %{user: host, socket: host_socket} = join_lobby()
      drain_initial_pushes(host_socket)

      {code, _} = create_room!(host_socket)
      # Drain the post-create `rooms` push on the host socket.
      assert_push "rooms", _

      %{user: joiner, socket: joiner_socket} = join_lobby()
      drain_initial_pushes(joiner_socket)

      ref = push(joiner_socket, "join_room", %{"code" => code})
      assert_reply ref, :ok, %{room: room}
      assert room.code == code
      player_ids = Enum.map(room.players, & &1.user_id)
      assert host.id in player_ids
      assert joiner.id in player_ids

      # Both sockets see a fresh listing reflecting the new player.
      assert_push "rooms", %{rooms: host_rooms}

      assert Enum.any?(host_rooms, fn r ->
               r.code == code and length(r.players) == 2
             end)

      assert_push "rooms", %{rooms: joiner_rooms}

      assert Enum.any?(joiner_rooms, fn r ->
               r.code == code and length(r.players) == 2
             end)

      # Cleanup.
      :ok = LobbyServer.leave_room(%{id: host.id, name: host.name}, code)
    end

    test "missing code replies :error bad_payload" do
      %{socket: socket} = join_lobby()
      drain_initial_pushes(socket)

      ref = push(socket, "join_room", %{})
      assert_reply ref, :error, %{reason: "bad_payload"}
    end

    test "unknown code replies :error not_found" do
      %{socket: socket} = join_lobby()
      drain_initial_pushes(socket)

      ref = push(socket, "join_room", %{"code" => "ZZZZ"})
      assert_reply ref, :error, %{reason: "not_found"}
    end
  end

  describe "leave_room" do
    test "non-host leaving the room replies :ok" do
      %{user: host, socket: host_socket} = join_lobby()
      drain_initial_pushes(host_socket)

      {code, _} = create_room!(host_socket)
      assert_push "rooms", _

      %{user: joiner, socket: joiner_socket} = join_lobby()
      drain_initial_pushes(joiner_socket)

      join_ref = push(joiner_socket, "join_room", %{"code" => code})
      assert_reply join_ref, :ok, _

      # Drain the listing pushes the join produced.
      assert_push "rooms", _
      assert_push "rooms", _

      leave_ref = push(joiner_socket, "leave_room", %{"code" => code})
      assert_reply leave_ref, :ok, _

      # Cleanup.
      :ok = LobbyServer.leave_room(%{id: host.id, name: host.name}, code)
      _ = joiner
    end

    test "host leaving removes the room from the listing for everyone" do
      %{user: host, socket: host_socket} = join_lobby()
      drain_initial_pushes(host_socket)

      {code, _} = create_room!(host_socket)
      assert_push "rooms", _

      %{socket: observer_socket} = join_lobby()
      drain_initial_pushes(observer_socket)

      leave_ref = push(host_socket, "leave_room", %{"code" => code})
      assert_reply leave_ref, :ok, _

      # Both sockets should now receive a listing that omits the room.
      assert_push "rooms", %{rooms: host_rooms}
      refute Enum.any?(host_rooms, fn r -> r.code == code end)

      assert_push "rooms", %{rooms: observer_rooms}
      refute Enum.any?(observer_rooms, fn r -> r.code == code end)

      _ = host
    end
  end

  describe "start_game" do
    test "host with 2+ players spawns a game, both sockets get game_started, room is removed" do
      %{user: host, socket: host_socket} = join_lobby()
      drain_initial_pushes(host_socket)

      {code, _} = create_room!(host_socket)
      assert_push "rooms", _

      %{user: joiner, socket: joiner_socket} = join_lobby()
      drain_initial_pushes(joiner_socket)

      join_ref = push(joiner_socket, "join_room", %{"code" => code})
      assert_reply join_ref, :ok, _

      # Drain join listing pushes.
      assert_push "rooms", _
      assert_push "rooms", _

      start_ref = push(host_socket, "start_game", %{"code" => code})
      assert_reply start_ref, :ok

      # Both sockets get game_started for the new game.
      assert_push "game_started", %{code: ^code}
      assert_push "game_started", %{code: ^code}

      # Room is removed from listing.
      assert_push "rooms", %{rooms: host_rooms}
      refute Enum.any?(host_rooms, fn r -> r.code == code end)

      assert_push "rooms", %{rooms: joiner_rooms}
      refute Enum.any?(joiner_rooms, fn r -> r.code == code end)

      # Clean up: tear down the spawned GameServer so subsequent tests
      # don't see a stale process.
      :ok = Zonia.GameServer.leave(code, joiner.id)
      :game_ended = Zonia.GameServer.leave(code, host.id)
    end

    test "non-host attempting to start replies :error not_host" do
      %{user: host, socket: host_socket} = join_lobby()
      drain_initial_pushes(host_socket)

      {code, _} = create_room!(host_socket)
      assert_push "rooms", _

      %{socket: joiner_socket} = join_lobby()
      drain_initial_pushes(joiner_socket)

      join_ref = push(joiner_socket, "join_room", %{"code" => code})
      assert_reply join_ref, :ok, _
      assert_push "rooms", _
      assert_push "rooms", _

      ref = push(joiner_socket, "start_game", %{"code" => code})
      assert_reply ref, :error, %{reason: "not_host"}

      # Cleanup.
      :ok = LobbyServer.leave_room(%{id: host.id, name: host.name}, code)
    end

    test "host with only themselves replies :error not_enough_players" do
      %{user: host, socket: host_socket} = join_lobby()
      drain_initial_pushes(host_socket)

      {code, _} = create_room!(host_socket)
      assert_push "rooms", _

      ref = push(host_socket, "start_game", %{"code" => code})
      assert_reply ref, :error, %{reason: "not_enough_players"}

      # Cleanup.
      :ok = LobbyServer.leave_room(%{id: host.id, name: host.name}, code)
    end
  end

  ## ── Chat ───────────────────────────────────────────────────────────────

  describe "say" do
    test "broadcasts a say event with name, body and integer at to other subscribers" do
      %{user: speaker, socket: speaker_socket} = join_lobby()
      drain_initial_pushes(speaker_socket)

      %{socket: listener_socket} = join_lobby()
      drain_initial_pushes(listener_socket)

      ref = push(speaker_socket, "say", %{"body" => "hello world"})
      assert_reply ref, :ok, _

      assert_broadcast "say", %{name: name, body: body, at: at}
      assert name == speaker.name
      assert body == "hello world"
      assert is_integer(at)
    end

    test "empty body replies :error empty" do
      %{socket: socket} = join_lobby()
      drain_initial_pushes(socket)

      ref = push(socket, "say", %{"body" => "   "})
      assert_reply ref, :error, %{reason: "empty"}
    end

    test "body longer than 500 chars replies :error too_long" do
      %{socket: socket} = join_lobby()
      drain_initial_pushes(socket)

      long_body = String.duplicate("x", 501)
      ref = push(socket, "say", %{"body" => long_body})
      assert_reply ref, :error, %{reason: "too_long"}
    end

    test "missing body replies :error bad_payload" do
      %{socket: socket} = join_lobby()
      drain_initial_pushes(socket)

      ref = push(socket, "say", %{})
      assert_reply ref, :error, %{reason: "bad_payload"}
    end

    test "non-string body replies :error bad_payload" do
      %{socket: socket} = join_lobby()
      drain_initial_pushes(socket)

      ref = push(socket, "say", %{"body" => 123})
      assert_reply ref, :error, %{reason: "bad_payload"}
    end
  end
end
