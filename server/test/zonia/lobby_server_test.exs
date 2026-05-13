defmodule Zonia.LobbyServerTest do
  use ExUnit.Case, async: true

  alias Zonia.LobbyServer

  # Documented visually-unambiguous alphabet — must mirror @code_alphabet in
  # the LobbyServer source. If this list ever drifts, the code-generator
  # tests should scream first.
  @code_alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @forbidden_chars ~c"0O1IL"

  setup do
    name = :"lobby_server_#{System.unique_integer([:positive])}"
    server = start_supervised!({LobbyServer, name: name})
    :ok = Phoenix.PubSub.subscribe(Zonia.PubSub, LobbyServer.listing_topic())
    %{server: server}
  end

  defp user(id, name) do
    %{id: id, name: name}
  end

  defp assert_broadcast! do
    assert_receive :room_listing_changed, 200
  end

  defp drain_broadcasts do
    receive do
      :room_listing_changed -> drain_broadcasts()
    after
      0 -> :ok
    end
  end

  describe "listing_topic/0" do
    test "returns the documented topic string" do
      assert LobbyServer.listing_topic() == "lobby:listing"
    end
  end

  describe "create_room/3" do
    test "mints a 4-char code from the documented alphabet", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))

      assert is_binary(room.code)
      assert String.length(room.code) == 4

      for ch <- String.to_charlist(room.code) do
        assert ch in @code_alphabet
        refute ch in @forbidden_chars
      end
    end

    test "host is the first (and only) player by default", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(7, "alice"))

      assert room.host_user_id == 7
      assert [%{user_id: 7, name: "alice"} = player] = room.players
      assert %DateTime{} = player.joined_at
    end

    test "uses default board, total_rounds, and max_players", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))

      assert room.board == "zonia-isle"
      assert room.total_rounds == 8
      assert room.max_players == 4
    end

    test "broadcasts :room_listing_changed", %{server: server} do
      {:ok, _room} = LobbyServer.create_room(server, user(1, "alice"))
      assert_broadcast!()
    end

    test "respects custom board/total_rounds/max_players opts", %{server: server} do
      {:ok, room} =
        LobbyServer.create_room(server, user(1, "alice"),
          board: "tundra",
          total_rounds: 12,
          max_players: 6
        )

      assert room.board == "tundra"
      assert room.total_rounds == 12
      assert room.max_players == 6
    end

    test "created_at is set to a DateTime", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))
      assert %DateTime{} = room.created_at
    end

    test "50 successive creates yield 50 unique codes", %{server: server} do
      codes =
        for i <- 1..50 do
          {:ok, room} = LobbyServer.create_room(server, user(i, "u#{i}"))
          room.code
        end

      assert length(codes) == 50
      assert codes |> Enum.uniq() |> length() == 50
    end
  end

  describe "join_room/3" do
    test "adds the joiner to the room's players list and broadcasts", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))
      drain_broadcasts()

      {:ok, joined} = LobbyServer.join_room(server, user(2, "bob"), room.code)

      assert length(joined.players) == 2
      assert Enum.any?(joined.players, fn p -> p.user_id == 2 and p.name == "bob" end)
      assert_broadcast!()
    end

    test "returns {:error, :not_found} for unknown code", %{server: server} do
      assert {:error, :not_found} = LobbyServer.join_room(server, user(1, "alice"), "ZZZZ")
    end

    test "returns {:error, :already_in_room} if user_id is in any room", %{server: server} do
      {:ok, room_a} = LobbyServer.create_room(server, user(1, "alice"))
      {:ok, _room_b} = LobbyServer.create_room(server, user(2, "bob"))

      # alice tries to join bob's room — already in her own as host
      assert {:error, :already_in_room} =
               LobbyServer.join_room(server, user(1, "alice"), room_a.code)
    end

    test "returns {:error, :full} when adding would exceed max_players", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"), max_players: 2)
      {:ok, _} = LobbyServer.join_room(server, user(2, "bob"), room.code)

      assert {:error, :full} =
               LobbyServer.join_room(server, user(3, "carol"), room.code)
    end

    test "different users with the same name are allowed", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "twin"))
      {:ok, joined} = LobbyServer.join_room(server, user(2, "twin"), room.code)

      assert length(joined.players) == 2
      assert Enum.all?(joined.players, fn p -> p.name == "twin" end)
    end

    test "joiner is appended to the end of players (preserves arrival order)",
         %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"), max_players: 4)
      {:ok, _} = LobbyServer.join_room(server, user(2, "bob"), room.code)
      {:ok, _} = LobbyServer.join_room(server, user(3, "carol"), room.code)
      {:ok, final} = LobbyServer.join_room(server, user(4, "dave"), room.code)

      assert Enum.map(final.players, & &1.user_id) == [1, 2, 3, 4]
    end
  end

  describe "leave_room/3" do
    test "removes the user from the player list and broadcasts", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"), max_players: 4)
      {:ok, _} = LobbyServer.join_room(server, user(2, "bob"), room.code)
      drain_broadcasts()

      assert :ok = LobbyServer.leave_room(server, user(2, "bob"), room.code)
      assert_broadcast!()

      {:ok, after_leave} = LobbyServer.fetch_room(server, room.code)
      assert Enum.map(after_leave.players, & &1.user_id) == [1]
    end

    test "host leaving removes the room entirely and broadcasts", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"), max_players: 4)
      {:ok, _} = LobbyServer.join_room(server, user(2, "bob"), room.code)
      drain_broadcasts()

      assert :ok = LobbyServer.leave_room(server, user(1, "alice"), room.code)
      assert_broadcast!()

      assert :error = LobbyServer.fetch_room(server, room.code)
      assert LobbyServer.list_rooms(server) == []
    end

    test "if the only player is the host leaving, room is removed", %{server: server} do
      # Host is always the only player here — leaving must remove the room.
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))
      drain_broadcasts()

      assert :ok = LobbyServer.leave_room(server, user(1, "alice"), room.code)
      assert_broadcast!()

      assert :error = LobbyServer.fetch_room(server, room.code)
    end

    test "returns {:error, :not_in_room} for an unknown code", %{server: server} do
      assert {:error, :not_in_room} =
               LobbyServer.leave_room(server, user(1, "alice"), "ZZZZ")
    end

    test "returns {:error, :not_in_room} for a user not in that specific room",
         %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))

      assert {:error, :not_in_room} =
               LobbyServer.leave_room(server, user(99, "ghost"), room.code)
    end
  end

  describe "start_game/3" do
    test "host can start with >=2 players; room is removed and broadcast fires",
         %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))
      {:ok, _} = LobbyServer.join_room(server, user(2, "bob"), room.code)
      drain_broadcasts()

      assert {:ok, started} = LobbyServer.start_game(server, user(1, "alice"), room.code)
      assert started.code == room.code

      assert_broadcast!()

      assert :error = LobbyServer.fetch_room(server, room.code)
      refute Enum.any?(LobbyServer.list_rooms(server), fn r -> r.code == room.code end)
    end

    test "non-host caller gets {:error, :not_host}", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))
      {:ok, _} = LobbyServer.join_room(server, user(2, "bob"), room.code)

      assert {:error, :not_host} =
               LobbyServer.start_game(server, user(2, "bob"), room.code)
    end

    test "host alone gets {:error, :not_enough_players}", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))

      assert {:error, :not_enough_players} =
               LobbyServer.start_game(server, user(1, "alice"), room.code)
    end

    test "unknown code returns {:error, :not_found}", %{server: server} do
      assert {:error, :not_found} =
               LobbyServer.start_game(server, user(1, "alice"), "ZZZZ")
    end
  end

  describe "list_rooms/1 and fetch_room/2" do
    test "list_rooms/1 returns [] on a fresh server", %{server: server} do
      assert LobbyServer.list_rooms(server) == []
    end

    test "list_rooms/1 returns all open rooms after creates", %{server: server} do
      {:ok, r1} = LobbyServer.create_room(server, user(1, "a"))
      {:ok, r2} = LobbyServer.create_room(server, user(2, "b"))
      {:ok, r3} = LobbyServer.create_room(server, user(3, "c"))

      codes =
        server
        |> LobbyServer.list_rooms()
        |> Enum.map(& &1.code)
        |> Enum.sort()

      assert codes == Enum.sort([r1.code, r2.code, r3.code])
    end

    test "fetch_room/2 returns {:ok, room} for an existing code", %{server: server} do
      {:ok, room} = LobbyServer.create_room(server, user(1, "alice"))

      assert {:ok, fetched} = LobbyServer.fetch_room(server, room.code)
      assert fetched.code == room.code
      assert fetched.host_user_id == 1
    end

    test "fetch_room/2 returns :error for unknown code", %{server: server} do
      assert :error = LobbyServer.fetch_room(server, "ZZZZ")
    end
  end

  describe "code generator (defensive)" do
    test "100 generated codes are 4-char and only contain the documented alphabet",
         %{server: server} do
      codes =
        for i <- 1..100 do
          {:ok, room} = LobbyServer.create_room(server, user(i, "u#{i}"))
          room.code
        end

      Enum.each(codes, fn code ->
        assert is_binary(code)
        assert String.length(code) == 4

        for ch <- String.to_charlist(code) do
          assert ch in @code_alphabet,
                 "char #{inspect(<<ch>>)} not in documented alphabet (code=#{code})"

          refute ch in @forbidden_chars,
                 "forbidden char #{inspect(<<ch>>)} appeared in code #{code}"
        end
      end)
    end
  end
end
