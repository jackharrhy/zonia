defmodule ZoniaWeb.GameChannelTest do
  # async: false because we touch shared singletons (GameSupervisor,
  # GameRegistry) and use Phoenix.Presence which shares state across
  # processes for a given topic.
  use ZoniaWeb.ChannelCase, async: false

  alias Zonia.Accounts
  alias Zonia.GameServer
  alias ZoniaWeb.GameChannel
  alias ZoniaWeb.UserSocket

  ## ── Helpers ────────────────────────────────────────────────────────────

  defp setup_game(name_prefix \\ "p") do
    ts = System.unique_integer([:positive])
    {:ok, %{user: u1, key: k1}} = Accounts.register("#{name_prefix}a#{ts}")
    {:ok, %{user: u2, key: k2}} = Accounts.register("#{name_prefix}b#{ts}")
    code = "G#{ts |> Integer.to_string() |> String.slice(-3, 3)}"

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Zonia.GameSupervisor,
        {GameServer,
         [
           code: code,
           board: "zonia-isle",
           total_rounds: 8,
           players: [
             %{user_id: u1.id, name: u1.name},
             %{user_id: u2.id, name: u2.name}
           ]
         ]}
      )

    # Tear down at end of test no matter what — leave the GameServer dead.
    on_exit(fn ->
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 -> :ok
        end
      end
    end)

    {:ok, s1} = connect(UserSocket, %{"key" => k1})
    {:ok, s2} = connect(UserSocket, %{"key" => k2})
    %{code: code, u1: u1, k1: k1, s1: s1, u2: u2, k2: k2, s2: s2, pid: pid}
  end

  defp drain_initial_pushes do
    assert_push "presence_state", _
    assert_push "snapshot", _
    :ok
  end

  ## ── Join: auth + membership ────────────────────────────────────────────

  describe "join game:<code>" do
    test "authenticated member can join and receives presence_state and snapshot" do
      %{code: code, s1: s1} = setup_game()

      assert {:ok, _reply, _socket} =
               subscribe_and_join(s1, GameChannel, "game:" <> code)

      assert_push "presence_state", _state

      assert_push "snapshot", %{game: snap}
      assert snap.code == code
      assert snap.phase == "idle"
      assert is_list(snap.players)
    end

    test "unauthenticated socket is rejected" do
      %{code: code} = setup_game()

      {:ok, anon} = connect(UserSocket, %{})

      assert {:error, %{reason: "unauthenticated"}} =
               subscribe_and_join(anon, GameChannel, "game:" <> code)
    end

    test "authenticated user not in the game is rejected" do
      %{code: code} = setup_game()

      # A fresh user, not in the roster.
      ts = System.unique_integer([:positive])
      {:ok, %{key: k3}} = Accounts.register("outsider#{ts}")
      {:ok, s3} = connect(UserSocket, %{"key" => k3})

      assert {:error, %{reason: "not_in_game"}} =
               subscribe_and_join(s3, GameChannel, "game:" <> code)
    end

    test "join flips a previously-disconnected member back to :active in the next snapshot" do
      %{code: code, u1: u1, s1: s1} = setup_game()

      # Confirm a non-member is not seen as a member (sanity vs. the
      # member?/2 contract).
      ts = System.unique_integer([:positive])
      {:ok, %{user: u3}} = Accounts.register("nonmember#{ts}")
      refute GameServer.member?(code, u3.id)

      # Mark our real member disconnected, then have them join: the
      # snapshot pushed after_join should show them as "active" again.
      :ok = GameServer.mark_disconnected(code, u1.id)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(s1, GameChannel, "game:" <> code)

      assert_push "presence_state", _state

      assert_push "snapshot", %{game: snap}
      player = Enum.find(snap.players, fn p -> p.user_id == u1.id end)
      assert player.status == "active"
    end
  end

  ## ── Chat ───────────────────────────────────────────────────────────────

  describe "say" do
    test "broadcasts a say event to other subscribers" do
      %{code: code, u1: u1, s1: s1, s2: s2} = setup_game()

      {:ok, _, sock1} = subscribe_and_join(s1, GameChannel, "game:" <> code)
      drain_initial_pushes()

      {:ok, _, _sock2} = subscribe_and_join(s2, GameChannel, "game:" <> code)
      drain_initial_pushes()

      ref = push(sock1, "say", %{"body" => "hello game"})
      assert_reply ref, :ok, _

      assert_broadcast "say", %{name: name, body: body, at: at}
      assert name == u1.name
      assert body == "hello game"
      assert is_integer(at)
    end

    test "empty body replies :error empty" do
      %{code: code, s1: s1} = setup_game()
      {:ok, _, sock} = subscribe_and_join(s1, GameChannel, "game:" <> code)
      drain_initial_pushes()

      ref = push(sock, "say", %{"body" => "   "})
      assert_reply ref, :error, %{reason: "empty"}
    end

    test "body longer than 500 chars replies :error too_long" do
      %{code: code, s1: s1} = setup_game()
      {:ok, _, sock} = subscribe_and_join(s1, GameChannel, "game:" <> code)
      drain_initial_pushes()

      long_body = String.duplicate("x", 501)
      ref = push(sock, "say", %{"body" => long_body})
      assert_reply ref, :error, %{reason: "too_long"}
    end

    test "missing body replies :error bad_payload" do
      %{code: code, s1: s1} = setup_game()
      {:ok, _, sock} = subscribe_and_join(s1, GameChannel, "game:" <> code)
      drain_initial_pushes()

      ref = push(sock, "say", %{})
      assert_reply ref, :error, %{reason: "bad_payload"}
    end

    test "non-string body replies :error bad_payload" do
      %{code: code, s1: s1} = setup_game()
      {:ok, _, sock} = subscribe_and_join(s1, GameChannel, "game:" <> code)
      drain_initial_pushes()

      ref = push(sock, "say", %{"body" => 123})
      assert_reply ref, :error, %{reason: "bad_payload"}
    end
  end

  ## ── leave_game ─────────────────────────────────────────────────────────

  describe "leave_game" do
    test "happy path: reply :ok and the player is removed from the roster" do
      %{code: code, u1: u1, s1: s1, s2: s2} = setup_game()

      # Both members in the game so the leaver isn't the last one.
      {:ok, _, sock1} = subscribe_and_join(s1, GameChannel, "game:" <> code)
      drain_initial_pushes()

      {:ok, _, _sock2} = subscribe_and_join(s2, GameChannel, "game:" <> code)
      drain_initial_pushes()

      ref = push(sock1, "leave_game", %{})
      assert_reply ref, :ok, _

      refute GameServer.member?(code, u1.id)
    end

    test "last player leaving: reply :ok, game_ended is pushed to the leaver, GameServer dies" do
      # One-player game so the join target is also the last player.
      ts = System.unique_integer([:positive])
      {:ok, %{user: u, key: k}} = Accounts.register("solo#{ts}")
      code = "S#{ts |> Integer.to_string() |> String.slice(-3, 3)}"

      {:ok, game_pid} =
        DynamicSupervisor.start_child(
          Zonia.GameSupervisor,
          {GameServer,
           [
             code: code,
             board: "zonia-isle",
             total_rounds: 8,
             players: [%{user_id: u.id, name: u.name}]
           ]}
        )

      monitor = Process.monitor(game_pid)

      {:ok, sock} = connect(UserSocket, %{"key" => k})
      {:ok, _, channel} = subscribe_and_join(sock, GameChannel, "game:" <> code)
      drain_initial_pushes()

      ref = push(channel, "leave_game", %{})
      assert_reply ref, :ok, _

      assert_push "game_ended", %{}

      assert_receive {:DOWN, ^monitor, :process, ^game_pid, _reason}, 500
    end
  end

  ## ── terminate (disconnect, not leave_game) ─────────────────────────────

  describe "terminate" do
    test "channel exit without leave_game flips player status to :disconnected" do
      %{code: code, u1: u1, s1: s1, s2: s2} = setup_game()

      # Both members in the game; u1's channel exits "uncleanly".
      {:ok, _, sock1} = subscribe_and_join(s1, GameChannel, "game:" <> code)
      drain_initial_pushes()

      {:ok, _, _sock2} = subscribe_and_join(s2, GameChannel, "game:" <> code)
      drain_initial_pushes()

      channel_pid = sock1.channel_pid
      ref = Process.monitor(channel_pid)
      Process.unlink(channel_pid)
      :ok = close(sock1)

      assert_receive {:DOWN, ^ref, :process, ^channel_pid, _}, 500

      # mark_disconnected is a synchronous call from terminate/2, so by
      # the time the channel pid is :DOWN the GameServer has already
      # applied the status change.

      # Still a member (seat held), but status flipped.
      assert GameServer.member?(code, u1.id)
      {:ok, snap} = GameServer.snapshot(code)
      player = Enum.find(snap.players, fn p -> p.user_id == u1.id end)
      assert player.status == "disconnected"
    end
  end
end
