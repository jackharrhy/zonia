# Step 3a — game shell

Branch: `step-3a-game-shell`. Carve-out of the bigger step 3 from the
boards-and-mini-games spec.

This step gets every player from the lobby into a "game scene" that
shows the board with their pawns at the start tile, a chat pane, and a
placeholder hotbar. **No game logic** — no rolling, no movement, no
turns, no rounds, no mini-games, no scoring. Step 3b adds those.

What this proves: the lobby→game transition works, the GameServer
process lifecycle works, multi-client state sync works, reconnection
works. The "game" itself is a husk we can poke at.

## Outcome

- Host clicks "start" in the lobby.
- LobbyServer.start_game/3 actually spawns a `Zonia.GameServer`.
- All players in that room receive a `game_started` event over the
  lobby channel.
- Their clients tear down the lobby scene and mount the game scene.
- Game scene renders: the board with everyone's pawn on the start
  tile, a chat pane, a players panel (names + 0 stars + 0 coins),
  top bar (round 1 of 8, turn placeholder), hotbar
  ("waiting for the game loop to be implemented").
- Players can chat with each other in the game (separate from lobby
  chat).
- Player presses `q` → leaves the game, mounts lobby scene.
- If a player's terminal dies (Ctrl-C without `q`), their seat is
  held. They reconnect → land back in the game scene with everyone
  still there.

## Hard constraints

1. **No game logic of any kind.** GameServer holds state, broadcasts
   snapshots, and that's it. No phase transitions, no timers, no
   turn advancement.
2. **Disconnect ≠ leave.** A dropped connection holds the seat for
   the lifetime of the game. Only `q` removes a player.
3. **mix precommit + bunx tsc --noEmit clean.**
4. **Existing 97 tests still passing.**
5. **No mid-server-restart persistence.** Game state is in-memory.
   Server restart = all games lost. Acceptable for v1.

## Domain additions

- **Game**: a `GameServer` GenServer instance, one per in-progress
  room. Holds:
  - `code` — the original room code (carried over from the lobby)
  - `board` — parsed `Zonia.Board` struct (loaded once on start)
  - `players` — list of player maps:
    - `user_id`, `name`, `pos` (grid coord on board.start initially),
      `stars: 0`, `coins: 0`, `color_slot` (0..3 by join order),
      `status: :active | :disconnected`
  - `total_rounds` — carried from the room
  - `current_round: 1`
  - `current_turn_idx: 0` (placeholder — no turns yet)
  - `phase: :idle` (placeholder)
- **Seat**: a player's slot in a game. Identified by `user_id`.
  Seats are durable for the lifetime of the GameServer process.

## Server architecture additions

```
Zonia.Application
├── (existing) Zonia.LobbyServer
├── Zonia.GameRegistry       (Registry, keys: :unique, key = room code → game pid)
├── Zonia.GameSupervisor     (DynamicSupervisor)
│   └── Zonia.GameServer @ {:via, Zonia.GameRegistry, code}
│       └── (no children for now)
└── (existing) ZoniaWeb.Endpoint
```

### `Zonia.GameRegistry`

A plain `Registry` with `keys: :unique`. The key is the game's room
code. Started in the application tree before `GameSupervisor`.

### `Zonia.GameSupervisor`

`DynamicSupervisor`. Spawns `GameServer` children on demand. Children
are transient — if a GameServer crashes, it doesn't auto-restart (game
state was in-memory anyway; no point bringing back an empty server).

### `Zonia.GameServer`

```elixir
@type player :: %{
  user_id: integer(),
  name: String.t(),
  pos: {non_neg_integer(), non_neg_integer()},
  stars: non_neg_integer(),
  coins: non_neg_integer(),
  color_slot: 0..3,
  status: :active | :disconnected
}

@type state :: %{
  code: String.t(),
  board: Zonia.Board.t(),
  players: [player()],
  total_rounds: pos_integer(),
  current_round: pos_integer(),
  current_turn_idx: non_neg_integer(),
  phase: :idle
}
```

API:

- `start_link(opts)` — `opts: [code: String.t(), board: String.t(),
  total_rounds: pos_integer(), players: [%{user_id, name}]]`. Loads
  the board, places every player at `board.start`, assigns
  color_slots in order, sets phase to `:idle`.
- `snapshot/1` — `(code)` → public state map for client consumption.
- `roster/1` — `(code)` → `[%{user_id, name, status}]`. Used by
  GameChannel for membership checks.
- `member?/2` — `(code, user_id)` → `boolean()`. Same as roster but
  cheaper for single lookups.
- `find_for_user/1` — `(user_id)` → `{:ok, code} | :error`. Iterates
  all alive GameServers via the Registry to find which game the user
  is currently in. Used by LobbyChannel on after_join for
  "you're already in game X" rejoin logic.
- `mark_disconnected/2` — `(code, user_id)` → `:ok`. Called by
  GameChannel.terminate when the channel dies. Flips that player's
  status to `:disconnected`. Broadcasts new snapshot.
- `mark_active/2` — `(code, user_id)` → `:ok`. Called by
  GameChannel.join when the player rejoins. Status back to `:active`.
  Broadcasts new snapshot.
- `leave/2` — `(code, user_id)` → `:ok | :game_ended`. Intentional
  leave (player pressed `q`). Removes the player. If no players
  remain, GameServer shuts down and returns `:game_ended`.

GameServer broadcasts `:snapshot` on the PubSub topic
`game:<code>:snapshots` whenever state changes. GameChannel
subscribes when a player joins and pushes the snapshot down to its
socket.

The `find_for_user/1` query is O(N) over all live games. For v1 that's
fine — concurrent game count is small. If it ever becomes a hotspot
we can maintain a separate user_id → code index.

### `LobbyServer.start_game/3` — real implementation

Currently a stub that just removes the room from the lobby listing.
Real behavior:

1. Validate host + min_players (existing).
2. Spawn a GameServer via `GameSupervisor.start_child/2` with the
   room's data.
3. Broadcast `{:game_started, code}` on the per-room PubSub topic
   `lobby:room:<code>`. Every LobbyChannel subscribed to that topic
   pushes a `game_started` event down to its socket.
4. Remove the room from `state.rooms` (existing).
5. Broadcast `:room_listing_changed` (existing).

If GameServer spawn fails, leave the room in place and return
`{:error, :spawn_failed}`. The host's client can show the error.

### `Zonia.LobbyServer.room_topic/1`

```elixir
def room_topic(code), do: "lobby:room:" <> code
```

Public helper so LobbyChannel can subscribe/unsubscribe.

### `ZoniaWeb.LobbyChannel`

Two changes from step 2:

1. **On join_room/leave_room**: subscribe to / unsubscribe from
   `LobbyServer.room_topic(code)`. So when LobbyServer broadcasts
   `:game_started` on that topic, this channel sees it.
2. **handle_info `{:game_started, code}`**: push `game_started`
   (`%{code: code}`) down to the socket.
3. **after_join**: check `Zonia.GameServer.find_for_user(user_id)`.
   If `{:ok, code}`, push `game_started` immediately so the client
   transitions before it ever paints the lobby.

### `ZoniaWeb.GameChannel`

New channel at `game:<code>`. Auth required (existing socket auth).
Membership check on join.

Events out:
- `snapshot` — `%{game: %{code, board (public_view), players,
  current_round, total_rounds, current_turn: nil, phase: "idle"}}`.
  Pushed on join and on every state change.
- `say` — `%{name, body, at}`. Chat broadcast within the game.
- `presence_state`, `presence_diff` — `Phoenix.Presence`.

Events in:
- `say` — chat.
- `leave_game` — `%{}`. Replies `:ok` (or `:game_ended` if you were
  the last). Channel terminates afterward; client transitions back
  to lobby.

`terminate/2`: if exit wasn't via a `leave_game` reply (i.e., the
client just dropped), call `GameServer.mark_disconnected/2`. We can
tell which path we're in by tracking a `leaving: true` flag in
`socket.assigns` set during the `leave_game` handler.

`join/3`:
- Reject if not authenticated.
- Reject if `not GameServer.member?(code, user_id)`.
- Otherwise: mark active, send :after_join.

`handle_info(:after_join, socket)`:
- Subscribe to `game:<code>:snapshots`.
- Track Presence.
- Push initial snapshot.

`handle_info(:snapshot, socket)`:
- Re-fetch and push.

## Client architecture additions

### `client/src/scenes/game.ts` (new)

The big new file. Layout:

```
┌──────────────────────────────────────────────────────────────┐
│ zonia · alice · round 1/8 · turn: —                          │  top bar
├──────────────────────────────────────────────┬───────────────┤
│                                              │ players       │
│                                              │ · alice ★0 ¢0 │
│             [board, centered]                │ · bob   ★0 ¢0 │
│                                              ├───────────────┤
│                                              │ chat          │
│                                              │ [12:30] hi    │
│                                              │ > _           │
├──────────────────────────────────────────────┴───────────────┤
│ hotbar: waiting for the game loop to be implemented · [q] leave │
└──────────────────────────────────────────────────────────────┘
```

State:
- `snapshot` — the latest GameServer snapshot.
- `mode: "hotkeys" | "chat"` — same mode pattern as lobby.

Hotkeys (only the leave one for now):
- `q` → push `leave_game`. On `:ok`, tear down + resolve back to
  caller (which transitions to lobby). Consumes the key.
- `t` → switch to chat-typing mode.

`game_ended` event from server → tear down + transition back.

Reuses:
- `mountBoard(renderer, parent, board, players)` from
  `components/board.ts`. Players prop now has real data.
- `mountChatPane(renderer, parent, {channel, selfName})` for chat.

New components needed:
- A simple "players panel" — could be a function in this file, no
  reusable abstraction yet.
- A "hotbar" — also just inline.

### Scene transition wiring

`index.ts` already mounts the lobby scene after registration. We need
the lobby → game transition + the reverse.

The cleanest shape: a small scene loop at the top level.

```ts
let next: { kind: "lobby" } | { kind: "game"; code: string } = { kind: "lobby" };
while (true) {
  if (next.kind === "lobby") {
    next = await runLobbyScene(renderer, identity);
    // runLobbyScene now resolves with {kind: "game", code} when it
    // receives a game_started event, and never resolves otherwise.
  } else {
    next = await runGameScene(renderer, identity, next.code);
    // runGameScene resolves with {kind: "lobby"} after leave_game.
  }
}
```

`runLobbyScene` currently returns `Promise<void>`. Change to
`Promise<{kind: "game"; code: string}>` — it resolves when the lobby
channel pushes `game_started`. The scene tears down its renderables
before resolving.

`runGameScene(renderer, identity, code)` returns
`Promise<{kind: "lobby"}>` when the player leaves.

### Snapshot type

```ts
export interface GameSnapshot {
  code: string;
  board: BoardData;          // already used by mountBoard
  players: GamePlayer[];
  current_round: number;
  total_rounds: number;
  current_turn: { user_id: number; phase: string } | null;
  phase: string;             // "idle" for step 3a
}

export interface GamePlayer {
  user_id: number;
  name: string;
  pos: [number, number];
  stars: number;
  coins: number;
  color_slot: 0 | 1 | 2 | 3;
  status: "active" | "disconnected";
}
```

The `BoardPlayer` type that `mountBoard` already takes is structurally
compatible with `GamePlayer` — we just pass it through.

Status `"disconnected"` could affect rendering (dim the pawn? show a
marker?). For step 3a I'd render them at slightly reduced contrast in
the players panel (theme tone `muted` instead of `fg`). The pawn on
the board itself stays the same.

## What I'm explicitly not doing

- Round/turn UI elements beyond placeholders.
- Roll/move/branch handlers.
- Mini-games.
- TTL on disconnected seats.
- Spectator mode.
- Per-round-end mini-game triggers.
- Game results / leaderboard writes.

All of those land in step 3b+.

## Order of work

Six units. After tier A lands, tiers B/C run in parallel.

### Tier A — server (sequential, foundation)

A1. `Zonia.GameRegistry` + `Zonia.GameSupervisor` modules. Wire into
    `Zonia.Application`'s supervision tree.
A2. `Zonia.GameServer` GenServer. All the API listed above.
A3. `Zonia.LobbyServer.start_game/3` real implementation. Spawn
    GameServer, broadcast on the room topic. Add `room_topic/1`.
A4. `ZoniaWeb.LobbyChannel` updates: subscribe to room topic on
    join_room, unsubscribe on leave_room, handle `:game_started`,
    push `game_started`. Also after_join rejoin check.
A5. `ZoniaWeb.GameChannel`. Auth, membership, snapshot push, say,
    leave_game, presence, terminate.

### Tier B — client (after A; can run as one subagent)

B1. `client/src/scenes/game.ts` with the layout, hotkeys, snapshot
    handling.
B2. `client/src/lib/socket.ts` — extend if needed with a
    `connectGameChannel(code)` helper.
B3. `client/src/index.ts` — the lobby↔game loop.
B4. `client/src/scenes/lobby.ts` — resolve with
    `{kind: "game", code}` when `game_started` is received.

### Tier C — tests (parallel with B)

C1. `Zonia.GameServer` tests (start, snapshot, member?,
    find_for_user, mark_disconnected/active, leave).
C2. `Zonia.LobbyServer.start_game/3` updated tests — real GameServer
    spawn, room topic broadcast.
C3. `ZoniaWeb.LobbyChannel` updated tests — `game_started` event
    fan-out, after_join rejoin check.
C4. `ZoniaWeb.GameChannel` tests — auth, membership, snapshot push,
    leave_game, terminate marks disconnected.

### Tier D — verification

D1. mix precommit clean. bunx tsc --noEmit clean.
D2. Manual smoke: two `just client` sessions, host starts a game,
    both transition to the game scene, both see the board with two
    pawns at the start tile. Ctrl-C one, restart, watch it rejoin
    the same game with both pawns still visible. Press `q` to leave
    properly.
D3. Manual smoke: solo player starts a game (alice is alone in the
    room, hits start) — should fail with `:not_enough_players`
    (existing behavior). Verify.

## Decisions inherited from earlier specs

- 4-char room codes, 2-4 players, 5-10 rounds — already in LobbyServer.
- Single board (`zonia-isle`) — already loaded.
- Names case-insensitive unique, 256-bit random key, sha256 hash —
  unchanged.
- Auto-reconnect via phoenix client (Channel.push buffers while
  disconnected) — unchanged.
- Self-update launcher — unchanged.

## Risk register

- **find_for_user iteration cost**: O(N) over alive games. If N
  grows large, this is on every lobby join. Cap on alive games
  is implicitly the BEAM's process count. We're not going to hit
  it.
- **Race between LobbyServer dropping room and GameServer
  registering with code**: if a second `start_game` arrives in the
  same instant on a different room, both might try to spawn. Each
  has a different code, so no Registry collision. Fine.
- **Stale snapshot pushes**: if a client reconnects while we're
  broadcasting, they get the snapshot via after_join AND via the
  subscription. Idempotent — clients render whatever they last got.
  Fine.

## When this branch is done

Tier D passes, commit, merge into main like step-2. The repo is then
in a state where two players can be in a synced game view together,
walking around the board mentally but not actually moving. Step 3b
opens with adding rolls + per-cell movement.
