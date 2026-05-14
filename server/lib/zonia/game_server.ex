defmodule Zonia.GameServer do
  @moduledoc """
  One process per in-progress game. Started from `Zonia.LobbyServer`
  when a host calls `start_game/3`, dies when every player has left
  (intentional leaves only — disconnects hold the seat).

  Step 3a is a husk: state is held, snapshots are broadcast, but no
  game logic runs. No phase transitions, no timers, no turn advancing.
  Rolls, movement, branching, and mini-games come in later steps.

  Registered as `{:via, Registry, {Zonia.GameRegistry, code}}` so it
  can be looked up by room code.

  Broadcasts `:snapshot` on the PubSub topic `game:<code>:snapshots`
  every time state changes. `ZoniaWeb.GameChannel` subscribes when a
  player joins and pushes the snapshot down to its socket.
  """

  use GenServer, restart: :transient

  alias Phoenix.PubSub
  alias Zonia.Board
  alias Zonia.Boards

  @pubsub Zonia.PubSub
  @registry Zonia.GameRegistry

  ## ── Types ───────────────────────────────────────────────────────────────

  @type user :: %{id: integer(), name: String.t()}

  @type player :: %{
          user_id: integer(),
          name: String.t(),
          pos: {non_neg_integer(), non_neg_integer()},
          stars: non_neg_integer(),
          coins: non_neg_integer(),
          color_slot: non_neg_integer(),
          status: :active | :disconnected
        }

  @type state :: %{
          code: String.t(),
          board: Board.t(),
          players: [player()],
          total_rounds: pos_integer(),
          current_round: pos_integer(),
          current_turn_idx: non_neg_integer(),
          phase: :idle
        }

  ## ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Start a GameServer for a freshly-started room.

  Opts:
    * `:code` — the room code (required, 4 chars)
    * `:board` — board name (required, must be in `Boards.names/0`)
    * `:total_rounds` — required
    * `:players` — list of `%{user_id, name}` maps (required, >=2)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    code = Keyword.fetch!(opts, :code)
    GenServer.start_link(__MODULE__, opts, name: via(code))
  end

  @doc "Public state snapshot suitable for sending to clients."
  @spec snapshot(String.t()) :: {:ok, map()} | :error
  def snapshot(code) do
    with {:ok, pid} <- whereis(code) do
      GenServer.call(pid, :snapshot)
    end
  end

  @doc "List of `%{user_id, name, status}` for membership and presence."
  @spec roster(String.t()) :: {:ok, [map()]} | :error
  def roster(code) do
    with {:ok, pid} <- whereis(code) do
      GenServer.call(pid, :roster)
    end
  end

  @doc "Is `user_id` a player in this game?"
  @spec member?(String.t(), integer()) :: boolean()
  def member?(code, user_id) do
    case whereis(code) do
      {:ok, pid} -> GenServer.call(pid, {:member?, user_id})
      :error -> false
    end
  end

  @doc """
  Find the game (if any) that `user_id` is currently a player in.

  O(N) over all live games. Fine for v1; the BEAM has bigger problems
  before this becomes a hotspot.
  """
  @spec find_for_user(integer()) :: {:ok, String.t()} | :error
  def find_for_user(user_id) when is_integer(user_id) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.find_value(:error, fn {code, pid} ->
      try do
        if GenServer.call(pid, {:member?, user_id}) do
          {:ok, code}
        end
      catch
        :exit, _ -> nil
      end
    end)
  end

  @doc """
  Mark a player as disconnected. Used by `GameChannel.terminate/2`
  when the channel dies without a clean `leave_game` call. Holds
  the seat indefinitely (step 3a has no TTL).
  """
  @spec mark_disconnected(String.t(), integer()) :: :ok | :error
  def mark_disconnected(code, user_id) do
    case whereis(code) do
      {:ok, pid} -> GenServer.call(pid, {:mark_disconnected, user_id})
      :error -> :error
    end
  end

  @doc "Mark a player as active again. Called on GameChannel join."
  @spec mark_active(String.t(), integer()) :: :ok | :error
  def mark_active(code, user_id) do
    case whereis(code) do
      {:ok, pid} -> GenServer.call(pid, {:mark_active, user_id})
      :error -> :error
    end
  end

  @doc """
  Intentional leave (player pressed `q`).

  Returns `:game_ended` if the last player just left; the GameServer
  shuts down after replying.
  """
  @spec leave(String.t(), integer()) :: :ok | :game_ended | :error
  def leave(code, user_id) do
    case whereis(code) do
      {:ok, pid} -> GenServer.call(pid, {:leave, user_id})
      :error -> :error
    end
  end

  @doc "PubSub topic snapshots are broadcast on."
  @spec snapshots_topic(String.t()) :: String.t()
  def snapshots_topic(code), do: "game:" <> code <> ":snapshots"

  ## ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    code = Keyword.fetch!(opts, :code)
    board_name = Keyword.fetch!(opts, :board)
    total_rounds = Keyword.fetch!(opts, :total_rounds)
    players_in = Keyword.fetch!(opts, :players)

    board = Boards.load!(board_name)

    players =
      players_in
      |> Enum.with_index()
      |> Enum.map(fn {p, idx} ->
        %{
          user_id: p.user_id,
          name: p.name,
          pos: board.start,
          stars: 0,
          coins: 0,
          color_slot: idx,
          status: :active
        }
      end)

    state = %{
      code: code,
      board: board,
      players: players,
      total_rounds: total_rounds,
      current_round: 1,
      current_turn_idx: 0,
      phase: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, public_view(state)}, state}
  end

  def handle_call(:roster, _from, state) do
    roster =
      Enum.map(state.players, fn p ->
        %{user_id: p.user_id, name: p.name, status: p.status}
      end)

    {:reply, {:ok, roster}, state}
  end

  def handle_call({:member?, user_id}, _from, state) do
    {:reply, has_player?(state, user_id), state}
  end

  def handle_call({:mark_disconnected, user_id}, _from, state) do
    set_status(state, user_id, :disconnected)
  end

  def handle_call({:mark_active, user_id}, _from, state) do
    set_status(state, user_id, :active)
  end

  def handle_call({:leave, user_id}, _from, state) do
    if has_player?(state, user_id) do
      new_players = Enum.reject(state.players, fn p -> p.user_id == user_id end)

      if new_players == [] do
        # Last player out — shut down. Reply first so the caller sees
        # :game_ended, then stop.
        {:stop, :normal, :game_ended, %{state | players: new_players}}
      else
        new_state = %{state | players: new_players}
        broadcast_snapshot(new_state)
        {:reply, :ok, new_state}
      end
    else
      {:reply, :error, state}
    end
  end

  ## ── Internals ──────────────────────────────────────────────────────────

  defp set_status(state, user_id, status) do
    if has_player?(state, user_id) do
      new_players =
        Enum.map(state.players, fn p ->
          if p.user_id == user_id, do: %{p | status: status}, else: p
        end)

      new_state = %{state | players: new_players}
      broadcast_snapshot(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, :error, state}
    end
  end

  defp has_player?(state, user_id) do
    Enum.any?(state.players, fn p -> p.user_id == user_id end)
  end

  defp via(code), do: {:via, Registry, {@registry, code}}

  defp whereis(code) do
    case Registry.lookup(@registry, code) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp broadcast_snapshot(state) do
    PubSub.broadcast(@pubsub, snapshots_topic(state.code), :snapshot)
  end

  defp public_view(state) do
    %{
      code: state.code,
      board: Board.public_view(state.board),
      players: Enum.map(state.players, &player_public/1),
      total_rounds: state.total_rounds,
      current_round: state.current_round,
      current_turn: nil,
      phase: Atom.to_string(state.phase)
    }
  end

  defp player_public(p) do
    {row, col} = p.pos

    %{
      user_id: p.user_id,
      name: p.name,
      pos: [row, col],
      stars: p.stars,
      coins: p.coins,
      color_slot: p.color_slot,
      status: Atom.to_string(p.status)
    }
  end
end
