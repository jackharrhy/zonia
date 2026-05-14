defmodule Zonia.LobbyServer do
  @moduledoc """
  In-memory matchmaking. Holds the list of currently-open rooms (rooms
  where a game has not yet started) and the players in them.

  One singleton process. State is volatile — a server restart wipes
  every room, by design. Mid-game persistence is explicitly out of
  scope for v1 (see `docs/specs/boards-and-mini-games.md`).

  Broadcasts `:room_listing_changed` on the Zonia.PubSub topic
  `"lobby:listing"` whenever any room's state changes. The LobbyChannel
  subscribes and pushes updates to its clients.
  """

  use GenServer

  @pubsub Zonia.PubSub
  @listing_topic "lobby:listing"

  # 4-char codes, visually-unambiguous alphabet (no 0/O/1/I/L).
  @code_alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  @code_length 4
  @code_max_attempts 16

  @default_board "zonia-isle"
  @default_rounds 8
  @default_max_players 4
  @min_players 2

  ## ── Types ───────────────────────────────────────────────────────────────

  @type user :: %{id: integer(), name: String.t()}

  @type player :: %{
          user_id: integer(),
          name: String.t(),
          joined_at: DateTime.t()
        }

  @type room :: %{
          code: String.t(),
          host_user_id: integer(),
          players: [player()],
          board: String.t(),
          total_rounds: pos_integer(),
          max_players: pos_integer(),
          created_at: DateTime.t()
        }

  @type create_error :: :code_exhausted
  @type join_error :: :not_found | :full | :already_in_room
  @type leave_error :: :not_in_room
  @type start_error :: :not_found | :not_host | :not_enough_players | :spawn_failed

  ## ── Public API ──────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc "Topic the LobbyChannel subscribes to for listing updates."
  @spec listing_topic() :: String.t()
  def listing_topic, do: @listing_topic

  @doc "Snapshot of every open room. Cheap; safe to call from a channel join."
  @spec list_rooms(GenServer.server()) :: [room()]
  def list_rooms(server \\ __MODULE__) do
    GenServer.call(server, :list_rooms)
  end

  @doc """
  Create a new room owned by `user`. The user becomes the first player.
  Returns the room on success, or `{:error, :code_exhausted}` if we
  couldn't generate a fresh code (vanishingly rare).

  Idempotent in spirit: if the user is already in a room as a host,
  that's not necessarily a contradiction — they could intentionally be
  hosting two. For v1 we allow it.
  """
  @spec create_room(GenServer.server(), user(), keyword()) ::
          {:ok, room()} | {:error, create_error()}
  def create_room(server \\ __MODULE__, user, opts \\ []) do
    GenServer.call(server, {:create_room, user, opts})
  end

  @doc """
  Add `user` to room `code`. Caller can't be already in a room.
  """
  @spec join_room(GenServer.server(), user(), String.t()) ::
          {:ok, room()} | {:error, join_error()}
  def join_room(server \\ __MODULE__, user, code) do
    GenServer.call(server, {:join_room, user, code})
  end

  @doc """
  Remove `user` from room `code`. If the host leaves, the room closes.
  If the last player leaves, the room is removed regardless.
  """
  @spec leave_room(GenServer.server(), user(), String.t()) ::
          :ok | {:error, leave_error()}
  def leave_room(server \\ __MODULE__, user, code) do
    GenServer.call(server, {:leave_room, user, code})
  end

  @doc """
  Remove `user` from every room they're currently in.

  Used by the LobbyChannel's `terminate/2` to clean up when a client
  disconnects without explicitly leaving — otherwise a hosted room
  would sit in the listing forever. Same host-leaves-closes-room
  semantics as `leave_room/3`.

  Returns the list of room codes the user was removed from, so the
  caller can log or audit the cleanup.
  """
  @spec leave_all(GenServer.server(), integer()) :: [String.t()]
  def leave_all(server \\ __MODULE__, user_id) do
    GenServer.call(server, {:leave_all, user_id})
  end

  @doc """
  Host-initiated game start.

  Validates host + min players, spawns a `Zonia.GameServer` for the
  room, broadcasts `:game_started` on the per-room PubSub topic so
  every player's LobbyChannel can push a `game_started` event down to
  its socket, then removes the room from the lobby listing.
  """
  @spec start_game(GenServer.server(), user(), String.t()) ::
          {:ok, room()} | {:error, start_error() | :spawn_failed}
  def start_game(server \\ __MODULE__, user, code) do
    GenServer.call(server, {:start_game, user, code})
  end

  @doc """
  PubSub topic a LobbyChannel subscribes to while a user is in
  room `code`. LobbyServer broadcasts `{:game_started, code}` here
  when the host starts the game.
  """
  @spec room_topic(String.t()) :: String.t()
  def room_topic(code) when is_binary(code), do: "lobby:room:" <> code

  @doc "Look up a room by code without mutating state."
  @spec fetch_room(GenServer.server(), String.t()) :: {:ok, room()} | :error
  def fetch_room(server \\ __MODULE__, code) do
    GenServer.call(server, {:fetch_room, code})
  end

  ## ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, %{rooms: %{}}}
  end

  @impl true
  def handle_call(:list_rooms, _from, state) do
    {:reply, Map.values(state.rooms), state}
  end

  def handle_call({:fetch_room, code}, _from, state) do
    {:reply, Map.fetch(state.rooms, code), state}
  end

  def handle_call({:create_room, user, opts}, _from, state) do
    case mint_code(state.rooms) do
      :error ->
        {:reply, {:error, :code_exhausted}, state}

      {:ok, code} ->
        now = DateTime.utc_now()

        room = %{
          code: code,
          host_user_id: user.id,
          players: [%{user_id: user.id, name: user.name, joined_at: now}],
          board: Keyword.get(opts, :board, @default_board),
          total_rounds: Keyword.get(opts, :total_rounds, @default_rounds),
          max_players: Keyword.get(opts, :max_players, @default_max_players),
          created_at: now
        }

        new_state = put_room(state, room)
        broadcast_change()
        {:reply, {:ok, room}, new_state}
    end
  end

  def handle_call({:join_room, user, code}, _from, state) do
    cond do
      in_any_room?(state, user.id) ->
        {:reply, {:error, :already_in_room}, state}

      true ->
        case Map.fetch(state.rooms, code) do
          :error ->
            {:reply, {:error, :not_found}, state}

          {:ok, room} when length(room.players) >= room.max_players ->
            {:reply, {:error, :full}, state}

          {:ok, room} ->
            new_room = %{
              room
              | players:
                  room.players ++
                    [%{user_id: user.id, name: user.name, joined_at: DateTime.utc_now()}]
            }

            new_state = put_room(state, new_room)
            broadcast_change()
            {:reply, {:ok, new_room}, new_state}
        end
    end
  end

  def handle_call({:leave_room, user, code}, _from, state) do
    case Map.fetch(state.rooms, code) do
      :error ->
        {:reply, {:error, :not_in_room}, state}

      {:ok, room} ->
        cond do
          not Enum.any?(room.players, fn p -> p.user_id == user.id end) ->
            {:reply, {:error, :not_in_room}, state}

          # Host leaving closes the room outright. Same effect as empty.
          room.host_user_id == user.id ->
            new_state = drop_room(state, code)
            broadcast_change()
            {:reply, :ok, new_state}

          true ->
            remaining = Enum.reject(room.players, fn p -> p.user_id == user.id end)

            new_state =
              if remaining == [] do
                drop_room(state, code)
              else
                put_room(state, %{room | players: remaining})
              end

            broadcast_change()
            {:reply, :ok, new_state}
        end
    end
  end

  def handle_call({:leave_all, user_id}, _from, state) do
    # Find every room the user is in. For each, apply leave semantics:
    # host-leaves drops the room, otherwise we drop just that player and
    # drop the room if empty.
    {new_state, left_codes} =
      Enum.reduce(state.rooms, {state, []}, fn {code, room}, {acc_state, acc_codes} ->
        cond do
          not Enum.any?(room.players, fn p -> p.user_id == user_id end) ->
            {acc_state, acc_codes}

          room.host_user_id == user_id ->
            {drop_room(acc_state, code), [code | acc_codes]}

          true ->
            remaining = Enum.reject(room.players, fn p -> p.user_id == user_id end)

            next_state =
              if remaining == [] do
                drop_room(acc_state, code)
              else
                put_room(acc_state, %{room | players: remaining})
              end

            {next_state, [code | acc_codes]}
        end
      end)

    if left_codes != [] do
      broadcast_change()
    end

    {:reply, Enum.reverse(left_codes), new_state}
  end

  def handle_call({:start_game, user, code}, _from, state) do
    case Map.fetch(state.rooms, code) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, room} ->
        cond do
          room.host_user_id != user.id ->
            {:reply, {:error, :not_host}, state}

          length(room.players) < @min_players ->
            {:reply, {:error, :not_enough_players}, state}

          true ->
            # Hand the room state to a fresh GameServer. If that fails
            # for some reason (process limit, board load error, …), we
            # leave the room in place so the host can retry.
            game_opts = [
              code: room.code,
              board: room.board,
              total_rounds: room.total_rounds,
              players: Enum.map(room.players, fn p -> %{user_id: p.user_id, name: p.name} end)
            ]

            case DynamicSupervisor.start_child(
                   Zonia.GameSupervisor,
                   {Zonia.GameServer, game_opts}
                 ) do
              {:ok, _pid} ->
                # Tell every player's LobbyChannel that the room they
                # were in just transitioned into a game.
                Phoenix.PubSub.broadcast(
                  Zonia.PubSub,
                  room_topic(code),
                  {:game_started, code}
                )

                new_state = drop_room(state, code)
                broadcast_change()
                {:reply, {:ok, room}, new_state}

              {:error, _reason} ->
                {:reply, {:error, :spawn_failed}, state}
            end
        end
    end
  end

  ## ── Internals ──────────────────────────────────────────────────────────

  defp put_room(state, room) do
    %{state | rooms: Map.put(state.rooms, room.code, room)}
  end

  defp drop_room(state, code) do
    %{state | rooms: Map.delete(state.rooms, code)}
  end

  defp in_any_room?(state, user_id) do
    Enum.any?(state.rooms, fn {_code, room} ->
      Enum.any?(room.players, fn p -> p.user_id == user_id end)
    end)
  end

  defp mint_code(rooms) do
    mint_code(rooms, @code_max_attempts)
  end

  defp mint_code(_rooms, 0), do: :error

  defp mint_code(rooms, attempts) do
    code = random_code()

    if Map.has_key?(rooms, code) do
      mint_code(rooms, attempts - 1)
    else
      {:ok, code}
    end
  end

  defp random_code do
    1..@code_length
    |> Enum.map(fn _ -> Enum.random(@code_alphabet) end)
    |> List.to_string()
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(@pubsub, @listing_topic, :room_listing_changed)
  end
end
