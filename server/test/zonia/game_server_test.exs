defmodule Zonia.GameServerTest do
  # async: false — GameRegistry and GameSupervisor are application-level
  # singletons. Each test uses a unique code so we don't collide on the
  # Registry, but we still don't want the Registry select-scan in
  # find_for_user/1 to race with sibling tests.
  use ExUnit.Case, async: false

  alias Phoenix.PubSub
  alias Zonia.GameServer

  @pubsub Zonia.PubSub

  defp unique_code(prefix \\ "T") do
    # 4-char-ish unique code. Keep it short but distinct per test.
    suffix = System.unique_integer([:positive]) |> Integer.to_string()
    "#{prefix}#{String.slice(suffix, -3, 3)}"
  end

  defp start_game!(opts) do
    code = Keyword.fetch!(opts, :code)
    pid = start_supervised!({GameServer, opts}, id: {:game_server, code})
    pid
  end

  defp default_players do
    [
      %{user_id: 1001, name: "alice"},
      %{user_id: 1002, name: "bob"}
    ]
  end

  defp default_opts(code, players \\ nil) do
    [
      code: code,
      board: "zonia-isle",
      total_rounds: 8,
      players: players || default_players()
    ]
  end

  describe "start_link/1" do
    test "places every player at the board's start coord, assigns color slots in order, all :active, phase :idle, round 1" do
      code = unique_code()

      players = [
        %{user_id: 11, name: "alice"},
        %{user_id: 12, name: "bob"},
        %{user_id: 13, name: "carol"}
      ]

      _pid = start_game!(default_opts(code, players))

      {:ok, snap} = GameServer.snapshot(code)

      # Start coord from the board's public view.
      start = snap.board.start
      assert is_list(start)

      assert Enum.map(snap.players, & &1.user_id) == [11, 12, 13]
      assert Enum.map(snap.players, & &1.name) == ["alice", "bob", "carol"]

      # All players placed at start.
      for p <- snap.players do
        assert p.pos == start
        assert p.status == "active"
        assert p.stars == 0
        assert p.coins == 0
      end

      # Color slots assigned in order.
      assert Enum.map(snap.players, & &1.color_slot) == [0, 1, 2]

      # Phase + round.
      assert snap.phase == "idle"
      assert snap.current_round == 1
      assert snap.total_rounds == 8
      assert snap.current_turn == nil
      assert snap.code == code
    end
  end

  describe "snapshot/1" do
    test "encodes pos as [r, c] lists, phase as \"idle\", status as \"active\"" do
      code = unique_code()
      _pid = start_game!(default_opts(code))

      {:ok, snap} = GameServer.snapshot(code)

      assert snap.phase == "idle"

      for p <- snap.players do
        assert match?([r, c] when is_integer(r) and is_integer(c), p.pos)
        assert p.status == "active"
      end
    end

    test "returns :error for an unknown code" do
      assert :error = GameServer.snapshot("NO_SUCH_GAME_CODE")
    end
  end

  describe "roster/1" do
    test "returns [%{user_id, name, status}] for each player" do
      code = unique_code()

      players = [
        %{user_id: 21, name: "alice"},
        %{user_id: 22, name: "bob"}
      ]

      _pid = start_game!(default_opts(code, players))

      assert {:ok, roster} = GameServer.roster(code)

      assert roster == [
               %{user_id: 21, name: "alice", status: :active},
               %{user_id: 22, name: "bob", status: :active}
             ]
    end
  end

  describe "member?/2" do
    test "returns true for registered players, false otherwise" do
      code = unique_code()

      players = [
        %{user_id: 31, name: "alice"},
        %{user_id: 32, name: "bob"}
      ]

      _pid = start_game!(default_opts(code, players))

      assert GameServer.member?(code, 31)
      assert GameServer.member?(code, 32)
      refute GameServer.member?(code, 999)
      refute GameServer.member?("NO_SUCH_GAME_CODE", 31)
    end
  end

  describe "find_for_user/1" do
    test "finds the user in their game" do
      code = unique_code()
      players = [%{user_id: 41, name: "alice"}, %{user_id: 42, name: "bob"}]
      _pid = start_game!(default_opts(code, players))

      assert {:ok, ^code} = GameServer.find_for_user(41)
      assert {:ok, ^code} = GameServer.find_for_user(42)
    end

    test "returns :error if the user is not in any game" do
      # Spawn a game with users that are NOT the one we're looking for,
      # to make sure scan-and-skip works.
      code = unique_code()
      players = [%{user_id: 51, name: "alice"}, %{user_id: 52, name: "bob"}]
      _pid = start_game!(default_opts(code, players))

      # Pick an id that's not in any game.
      assert :error = GameServer.find_for_user(-999_999)
    end

    test "works across multiple games — each user is found in their own" do
      code_a = unique_code("A")
      code_b = unique_code("B")

      players_a = [%{user_id: 61, name: "alice"}, %{user_id: 62, name: "bob"}]
      players_b = [%{user_id: 71, name: "carol"}, %{user_id: 72, name: "dave"}]

      _pid_a = start_game!(default_opts(code_a, players_a))
      _pid_b = start_game!(default_opts(code_b, players_b))

      assert {:ok, ^code_a} = GameServer.find_for_user(61)
      assert {:ok, ^code_a} = GameServer.find_for_user(62)
      assert {:ok, ^code_b} = GameServer.find_for_user(71)
      assert {:ok, ^code_b} = GameServer.find_for_user(72)
    end
  end

  describe "mark_disconnected/2" do
    test "flips status and broadcasts a :snapshot on the snapshots topic" do
      code = unique_code()
      players = [%{user_id: 81, name: "alice"}, %{user_id: 82, name: "bob"}]
      _pid = start_game!(default_opts(code, players))

      :ok = PubSub.subscribe(@pubsub, GameServer.snapshots_topic(code))

      assert :ok = GameServer.mark_disconnected(code, 81)
      assert_receive :snapshot, 500

      {:ok, snap} = GameServer.snapshot(code)
      alice = Enum.find(snap.players, fn p -> p.user_id == 81 end)
      bob = Enum.find(snap.players, fn p -> p.user_id == 82 end)
      assert alice.status == "disconnected"
      assert bob.status == "active"
    end
  end

  describe "mark_active/2" do
    test "flips status back to :active and broadcasts" do
      code = unique_code()
      players = [%{user_id: 91, name: "alice"}, %{user_id: 92, name: "bob"}]
      _pid = start_game!(default_opts(code, players))

      :ok = GameServer.mark_disconnected(code, 91)

      :ok = PubSub.subscribe(@pubsub, GameServer.snapshots_topic(code))

      assert :ok = GameServer.mark_active(code, 91)
      assert_receive :snapshot, 500

      {:ok, snap} = GameServer.snapshot(code)
      alice = Enum.find(snap.players, fn p -> p.user_id == 91 end)
      assert alice.status == "active"
    end
  end

  describe "leave/2" do
    test "non-host leaving with others remaining returns :ok, removes the player, broadcasts" do
      code = unique_code()

      players = [
        %{user_id: 101, name: "alice"},
        %{user_id: 102, name: "bob"},
        %{user_id: 103, name: "carol"}
      ]

      _pid = start_game!(default_opts(code, players))

      :ok = PubSub.subscribe(@pubsub, GameServer.snapshots_topic(code))

      assert :ok = GameServer.leave(code, 102)
      assert_receive :snapshot, 500

      {:ok, snap} = GameServer.snapshot(code)
      user_ids = Enum.map(snap.players, & &1.user_id)
      assert user_ids == [101, 103]
      refute GameServer.member?(code, 102)
    end

    test "last player leaving returns :game_ended and the GameServer process exits" do
      code = unique_code()
      players = [%{user_id: 111, name: "solo"}]

      # Start directly via the supervisor so we can have a single-player
      # game for this teardown case (LobbyServer wouldn't allow it, but
      # GameServer doesn't enforce min players on its own).
      pid = start_game!(default_opts(code, players))
      ref = Process.monitor(pid)

      assert :game_ended = GameServer.leave(code, 111)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    end

    test "leaving as a non-player returns :error" do
      code = unique_code()
      players = [%{user_id: 121, name: "alice"}, %{user_id: 122, name: "bob"}]
      _pid = start_game!(default_opts(code, players))

      assert :error = GameServer.leave(code, 999_999)
    end
  end
end
