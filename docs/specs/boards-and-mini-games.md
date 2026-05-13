# Boards & mini-games

The pivot from chat-room to Mario-Party-shaped party game. Branch:
`boards-and-mini-games`.

This spec is the plan of record. It captures decisions, hard constraints,
and the order of work. Read top-to-bottom; sections later in the doc
reference decisions made earlier.

## What we're building

A small terminal-multiplayer board game. Players join a named room (4-char
code), the host starts a game, everyone takes turns rolling a die and
moving around a hand-drawn ASCII board. Between rounds, a mini-game pits
everyone against each other for coins/stars. After N rounds (5–10,
host-configurable), the player with the most stars wins.

Boards are unicode art authored in vim, paired with a side-channel
`style.ex` module that classifies every character as `:tile`, `:edge_*`,
or decor. Adjacency is *inferred* — two `:tile` cells sharing an edge are
bidirectionally connected. Directional arrow characters override one way.

Players see a styled, colored rendering of the same characters they drew,
with their pawns overlaid as absolutely-positioned single-character
`TextRenderable`s on top of the board.

## What stays from today

This is a content pivot, not a project restart. These bones do not move:

- **Identity**: TOFU registration via `register:lobby`. `Zonia.Accounts`,
  the `users` Ecto schema, and `Zonia.Accounts.User` are untouched.
  Names remain unique-forever; the existing 4 reserved-name list stays.
- **Sockets**: `ZoniaWeb.UserSocket` with `params["key"]` auth. Auth
  path is unchanged.
- **Phoenix.Presence**: still used, but scoped to lobby + each game room
  instead of one global `world:lobby`.
- **Client identity store**: `bun:sqlite` under XDG, `PRAGMA
  user_version` migrations. The existing v1 `identity` table is **load-
  bearing for named clients in the wild** and must not change shape.
- **Self-hosted binaries**: `/releases/manifest.json` + `/releases/*`,
  the `zonia-world` launcher, the XDG cache, the Dockerfile build. None
  of this changes.
- **Theme module**: `client/src/lib/theme.ts` — the token system stays.
  We'll extend the palette with per-player pawn colors.
- **Infra**: Dockerfile, GHCR action, mug compose, SOPS secret.

## What's leaving

The "one global chat room" concept goes. Specifically:

- `ZoniaWeb.WorldChannel` — replaced by `LobbyChannel` and `GameChannel`.
  The `world:lobby` topic is retired.
- `client/src/scenes/chat.ts` — replaced by `scenes/lobby.ts` and
  `scenes/game.ts`. Chat survives as a **pane** inside both.
- The implicit assumption that there's one chat for everyone — replaced
  by per-channel scoping. Lobby chat is for everyone in the lobby; game
  chat is for everyone in that room.

## Hard constraints

These are non-negotiable; everything else is implementation detail.

1. **No client SQLite contract break.** The v1 schema is in the wild on
   named clients' machines. Any new tables go in **v2+ migrations**.
   The `identity` table must keep working for existing keys.
2. **Server is the only source of truth** for game state. Client is dumb;
   it renders what the server tells it.
3. **No mid-game persistence.** Games are in-memory. Server restart → all
   running games are lost. This is fine for v1.
4. **No bots in v1.** Hardcoded multiplayer-only. The player abstraction
   is built to accommodate bots later, but no bot implementation ships.
5. **Strict turn order.** It's alice's turn; everyone else watches. No
   simultaneous moves on the board. (Mini-games are exempt — they can
   be real-time or simultaneous.)
6. **`mix precommit` clean.** Every committed change passes
   `compile --warnings-as-errors`, `format`, `test`. Client passes
   `bunx tsc --noEmit`.

## Domain model

These are the nouns. Spelled out before any module names.

- **Player**: an authenticated identity (name + key from the existing
  `users` table). Identity persists across games.
- **Room**: a 4-char alphanumeric uppercase code (`BX7Q`). 2-4 players.
  Created by a host. Once filled and started, the room is mid-game.
  After a game ends, the room **resets in place** — same players, ready
  to start again. Empty rooms expire after a TTL (15 minutes idle).
- **Game**: one play-through of a board with a set of players. Has a
  board, a player list, a round counter, a current turn, a current phase.
- **Board**: a parsed graph from `priv/boards/<name>/`. Loaded once on
  server boot. Same board can underpin many concurrent games.
- **Tile**: a node in the board's graph. Has a kind (`:plain`,
  `:minigame`, `:mystery`, `:star_shop`, etc.) and a list of outgoing
  edges (directed). Bidirectional connections are stored as two directed
  edges in the graph.
- **Turn**: a player's roll + movement + tile-resolution.
- **Round**: one full pass through the turn order. Ends with a mini-game.
- **MiniGame**: a self-contained sub-process spawned by the game,
  routes player inputs, resolves to per-player rewards, dies.

## Server architecture

```
Zonia.Application
└── Zonia.GameSupervisor          (DynamicSupervisor)
    ├── Zonia.LobbyServer         (singleton GenServer — room list, matchmaking)
    └── (Game processes)
        ├── Zonia.GameServer @ {:via, GameRegistry, "BX7Q"}
        │   └── Zonia.MiniGames.Runner @ {:via, MiniGameRegistry, "BX7Q"}
        ├── Zonia.GameServer @ "MK9P"
        └── ...
```

### `Zonia.LobbyServer`

One process. Holds the list of currently-open (not-yet-started) rooms.

State:

```elixir
%{
  rooms: %{
    "BX7Q" => %{
      host_user_id: 7,
      players: [%{user_id: 7, name: "alice", joined_at: ~U[...]}, ...],
      board: "zonia-isle",
      total_rounds: 8,
      max_players: 4,
      created_at: ~U[...]
    }
  }
}
```

API:

- `LobbyServer.list_rooms/0` — returns open rooms for the lobby UI.
- `LobbyServer.create_room/2` — `(user, opts)` → `{:ok, code}` or
  `{:error, reason}`. Picks a fresh 4-char code, registers the host as
  player 1.
- `LobbyServer.join_room/2` — `(user, code)` → `:ok | {:error, :full |
  :not_found | :already_in_room}`.
- `LobbyServer.leave_room/2` — `(user, code)`. If host leaves, room
  closes.
- `LobbyServer.start_game/2` — `(user, code)`. Only the host can call.
  Spawns a `GameServer` via `GameSupervisor`, transfers room state to
  it, removes the room from the lobby list, broadcasts.

Broadcasts `room_listing_changed` on `lobby:main` whenever the list
changes (room created, joined, left, started, closed). Clients listen
and re-render.

### `Zonia.GameServer`

One process per room mid-game. Started by `LobbyServer.start_game/2`.

State:

```elixir
%{
  code: "BX7Q",
  board: %Zonia.Board{},        # the parsed graph
  players: [
    %{
      user_id: 7,
      name: "alice",
      pos: {3, 5},               # {row, col} on the board grid
      stars: 0,
      coins: 0,
      color_slot: 0              # for the client's per-player palette
    }, ...
  ],
  turn_order: [user_id, ...],
  current_turn_idx: 0,
  current_round: 1,
  total_rounds: 8,
  phase: :rolling | :moving | :branching | :resolving | :between_rounds | :minigame | :complete,
  pending_move: nil | %{remaining: 4, path: [...]},
  pending_branch: nil | %{user_id: 7, options: [:east, :south]},
  minigame_ref: nil | pid,
  afk_timer: nil | reference,
  reset_token: nil               # set after a game completes; "press start to play again"
}
```

API:

- `GameServer.snapshot/1` — `(code)` → the public-facing state for the
  channel to broadcast. Strips internal-only fields (timer refs, pids).
- `GameServer.roll/2` — `(code, user)` → `:ok | {:error, reason}`. Only
  valid for current-turn player in `:rolling` phase.
- `GameServer.choose_direction/3` — `(code, user, :east)` → `:ok | ...`.
- `GameServer.minigame_input/3` — `(code, user, input)` → routes to the
  current `MiniGames.Runner`.
- `GameServer.leave/2` — `(code, user)`. Drops player from game; if it
  was their turn, advances. If <2 players remain, game ends early.
- `GameServer.restart/2` — `(code, user)`. Only host. Resets the game
  with the same players, same board.

Behaviour:

- On start: assigns colors (0..N-1) from the theme module, places every
  player on the start tile, picks turn order at random, sets phase to
  `:rolling`, broadcasts initial snapshot.
- Roll: rolls 1-10 (configurable later), broadcasts `{:rolled, user, n}`,
  enters movement loop.
- Movement loop: for each step,
  - look up current tile's outgoing edges,
  - 1 edge → broadcast `{:moved, user, next_tile, remaining_after}`,
    sleep briefly server-side (or just rely on client animation pacing),
  - 2+ edges → set `pending_branch`, broadcast `{:branch, user, options}`,
    wait. On `choose_direction/3`, validate, commit, continue loop.
- After last step: resolve tile (no-op for `:plain`, mark intent for
  `:minigame` later, etc.), broadcast `{:turn_ended, user}`, advance turn.
- AFK: when a player's turn starts, set a 30s timer. If they don't act,
  auto-roll. If they're branching, pick the first option.
- End of round (every player has taken a turn): set phase `:minigame`,
  spawn `MiniGames.Runner`. When runner completes, credit rewards,
  return to `:rolling` for round+1. After `current_round > total_rounds`,
  phase becomes `:complete`, winner announced.

Broadcasts on `game:<code>`. Every state change emits a fresh `snapshot`
event. Clients render the latest snapshot — they don't try to merge
deltas.

### `Zonia.MiniGames`

A behaviour module + a small set of implementations.

```elixir
defmodule Zonia.MiniGame do
  @callback init(players :: [map()]) :: state
  @callback handle_input(user_id :: integer, input :: map(), state) ::
              {:ok, state} | {:done, results :: %{user_id => integer}, state}
  @callback tick(state) :: {:ok, state} | {:done, results, state}  # optional, for real-time games
  @callback public_state(state) :: map()                            # what to send clients
  @optional_callbacks tick: 1
end
```

Implementations:

- `Zonia.MiniGames.RussianButtons` — 5 boxes, 2 bombs, 3 safe.
  Turn-based commit-and-reveal. Survivors split rewards.
- `Zonia.MiniGames.TypingOfTheDead` — real-time. Words spawn at top of
  screen, drift down, players race to type them first. 30s round.
- A registry: `Zonia.MiniGames.all/0` returns the list. Game picks
  randomly for v1.

The **runner** is the GenServer that owns a single mini-game's lifetime:

```elixir
Zonia.MiniGames.Runner @ {:via, MiniGameRegistry, room_code}
```

Spawned by `GameServer` with `(impl_module, players)`. Calls `init/1`
on the impl, listens for inputs on `minigame:<room_code>` (separate
channel to keep tick traffic off the game-board topic), routes them to
`impl.handle_input/3`, runs `impl.tick/1` on a timer if exported,
exits with results which `GameServer` collects via a monitor.

### Channels

- `LobbyChannel` at `lobby:main`. Authenticated only. Events out:
  `room_listing_changed`, `say`, `presence_state`, `presence_diff`.
  Events in: `create_room`, `join_room`, `leave_room`, `say`.
- `GameChannel` at `game:<code>`. Authenticated only, and only joinable
  if you're a player in that room. Events out: `snapshot`, `rolled`,
  `moved`, `branch`, `turn_ended`, `round_ended`, `complete`, `say`,
  `presence_*`. Events in: `roll`, `choose_direction`, `say`,
  `restart` (host only), `leave`.
- `MiniGameChannel` at `minigame:<code>`. Same auth as GameChannel —
  you have to be a player in that game. Events out: `tick`, `result`,
  `done`. Events in: depends on the mini-game (typed_char,
  picked_button, etc.).

Authorization for join is enforced in each channel's `join/3` by
asking the relevant GenServer if the user is part of the room/game.

## Boards

### File layout

```
server/priv/boards/
└── zonia-isle/
    ├── map.txt        # raw unicode art, drawn in vim
    └── style.ex       # Elixir module with the side-channel metadata
```

The directory form keeps related files close and gives us room to add
per-board metadata later without breaking the layout.

### `style.ex` shape

A literal `.ex` module, compiled into the release. **Not** `.exs` —
hot-reload during authoring is convenient, but the production server
shouldn't be parsing untrusted Elixir from disk at runtime, and compile-
time is also when we want a typo in the style to fail.

```elixir
defmodule Zonia.Boards.ZoniaIsle.Style do
  @moduledoc """
  Side-channel style metadata for the zonia-isle board.

  Each character that appears in map.txt must be classified here.
  Unknown characters fail the parser loudly.
  """

  def style do
    %{
      # Path tiles
      "●" => %{kind: :tile, color: :cyan},
      "M" => %{kind: :tile, color: :magenta, effect: :minigame},
      "?" => %{kind: :tile, color: :yellow, effect: :mystery},
      "★" => %{kind: :tile, color: :yellow, effect: :star_shop, start: true},

      # Directional one-way edges
      "→" => %{kind: :edge_east,  color: :cyan},
      "←" => %{kind: :edge_west,  color: :cyan},
      "↑" => %{kind: :edge_north, color: :cyan},
      "↓" => %{kind: :edge_south, color: :cyan},

      # Decor (parser ignores; client renders with these colors)
      "🌲" => %{kind: :decor, color: :green},
      "🌊" => %{kind: :decor, color: :blue},
      "△" => %{kind: :decor, color: :gray},
      " " => %{kind: :decor, color: :default}
    }
  end
end
```

`color: <atom>` resolves to a theme tone client-side. The server
forwards the atom raw; the client maps `:cyan → theme.c.path`, etc.
This keeps the palette centralized in `client/src/lib/theme.ts`.

### Parser: `Zonia.Board`

Reads `map.txt` + the style module, returns:

```elixir
%Zonia.Board{
  name: "zonia-isle",
  raw: "...\n...\n",                      # original text, for client rendering
  style: %{"●" => %{...}, ...},           # also forwarded to client
  width: 40,
  height: 20,
  tiles: %{
    {row, col} => %{
      char: "●",
      kind: :tile,
      effect: :minigame,                  # or nil
      outgoing: [{row, col, :east}, ...]  # neighbour tiles + direction
    }
  },
  start: {row, col}
}
```

Parsing rules:

1. Read `map.txt` as a 2D array of grapheme clusters (must handle wide
   chars and emoji correctly — graphemes, not bytes).
2. For every cell, look up the char in `style.style/0`. If unknown,
   raise during parse — fail-loud.
3. Build `tiles`: every cell with `kind: :tile` becomes a node.
4. For each tile cell:
   - Check 4-neighbour cells. If a neighbour is also `kind: :tile`, add
     a bidirectional edge (one entry each direction in `outgoing`).
   - If a neighbour is `kind: :edge_<dir>`, look one further in the
     same direction. If *that* cell is a tile, add a one-way edge from
     this tile to that tile in `dir`.
5. Look for `start: true` in the style. Exactly one tile must have it.
6. Validate: no orphan tiles (every tile has ≥1 outgoing edge).

The board is loaded **once on server boot** by a small loader called
from `Zonia.Application`. The list of board names is hardcoded in
`config/config.exs` (for v1: just `["zonia-isle"]`). Boards are passed
to `GameServer` by name; the server holds a `%{name => board}` map.

### What the client receives

When a client joins a game, the first `snapshot` includes:

```json
{
  "board": {
    "name": "zonia-isle",
    "raw": "...",
    "style": { "●": { "kind": "tile", "color": "cyan" }, ... }
  },
  "players": [{ "user_id": 7, "name": "alice", "pos": [3, 5], "stars": 0, "coins": 0, "color_slot": 0 }, ...],
  "current_turn": { "user_id": 7, "phase": "rolling" },
  "current_round": 1,
  "total_rounds": 8
}
```

The client **never sees the graph**. It only knows:
- The raw text (so it can paint characters with their style colors).
- Where each player is (so it can position pawns).
- What action it's currently allowed to take (from `current_turn.phase`).

When a branch happens, server sends `{:branch, user, [:east, :south]}`
and the client renders the available arrows in a bright/highlighted
state. The client never decides on its own which directions are
available.

## Client architecture

### Scene tree

```
boot
└── register scene (existing, unchanged contract)
    └── lobby scene (new)
        └── game scene (new)
            └── minigame overlay (new, scene-within-scene)
```

The existing scene-transition pattern (one scene `resolve`s, next scene
mounts) carries through. We add a `Scene` interface with explicit
`mount` / `unmount` so cleanup is uniform:

```ts
interface Scene {
  mount(renderer: CliRenderer): Promise<SceneResult>;
  // returns when the scene is done; result is passed to the next scene
}
```

### New files

- `client/src/scenes/lobby.ts` — room list, create-room, join-room.
  Chat pane on the side. On host's "start game" → transition to game
  scene with the room code.
- `client/src/scenes/game.ts` — the big one. Board render + pawn
  overlays + HUD + chat pane. Drives the turn UI based on
  `current_turn.phase` from snapshots.
- `client/src/scenes/minigame/typing.ts`, `minigame/buttons.ts` — one
  per mini-game. Mounted as a child of the game scene (full-screen
  takeover; game scene's renderables hidden until minigame finishes).
- `client/src/components/board.ts` — given `{raw, style, players}`,
  builds the styled `TextRenderable` for the board plus the absolute-
  positioned pawn overlays. Re-render on snapshot change.
- `client/src/components/chat-pane.ts` — reusable side panel.
  Takes a `Channel` and a topic; renders messages + input.
- `client/src/lib/socket.ts` — extend with helpers for the new channels
  (`joinLobby`, `joinGame`, `joinMiniGame`).

### Existing files that change

- `client/src/index.ts` — replace `runChatScene` with `runLobbyScene`.
- `client/src/lib/identity.ts` — **append** a v2 migration. See next
  section. Existing v1 schema is untouched.
- `client/src/lib/theme.ts` — extend the palette with `pawn0` through
  `pawn3` tones for the four player colors (e.g., red/blue/green/
  yellow, deeper in light mode). The board renderer maps the server's
  color atoms (`:cyan`, `:magenta`, etc.) to theme tones.
- `client/src/scenes/register.ts` — **unchanged**. The register
  contract has gone out into the world; we don't touch it.

### Existing files that go away

- `client/src/scenes/chat.ts` — deleted in step 2.

## Client SQLite migrations

**Strict rule: existing clients on v1 must keep working.**

The current migration array has one entry (v1: create `identity`). We
**append** v2+ without ever touching the v1 entry. On first launch
after upgrade, the migration runner sees `PRAGMA user_version = 1` and
applies v2, v3, etc. in order.

For v1 of this pivot, the only new data is **last-seen game history**
(local leaderboard, "you played as alice in BX7Q and won"):

```ts
// v2: local game history
(db) => {
  db.run(`
    CREATE TABLE game_history (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      room_code   TEXT NOT NULL,
      finished_at TEXT NOT NULL,
      placement   INTEGER NOT NULL,     -- 1 = won, 2 = second, ...
      stars       INTEGER NOT NULL,
      coins       INTEGER NOT NULL,
      board       TEXT NOT NULL
    )
  `);
};
```

Writing to this table is best-effort (catch + log). The launcher and
identity flow don't depend on it.

If we later add more tables (saved preferences, chat history, etc.),
each becomes its own appended v3, v4, … entry. The migration ordering
contract is "every client ever runs the full prefix of migrations
they're missing."

## Order of work

Six steps. Each is a single landable commit with passing tests +
typecheck. Each step the thing demoably works.

### Step 1 — Board parser + standalone preview

Outcome: `just preview-board zonia-isle` opens the board in a TUI with
no players, no logic. Lets us iterate on the art and parser without
the server.

Adds:
- `server/lib/zonia/board.ex` — the parser + struct.
- `server/lib/zonia/boards.ex` — registry of loaded boards. Stub for now.
- `server/priv/boards/zonia-isle/{map.txt,style.ex}` — first board.
- `server/test/zonia/board_test.exs` — parser tests including:
  - Simple straight line of `●`s
  - 4-way branch
  - One-way arrow edges
  - Decor characters ignored
  - Unknown character → parse error
  - Start tile required
- `client/src/components/board.ts` — render `{raw, style}` (no players
  yet) as a styled `TextRenderable`.
- `client/src/scenes/preview-board.ts` — load a static fixture and
  render via the board component.
- `justfile` recipe `preview-board <name>` that reads a server-side
  JSON dump of the parsed board (or just the raw + style — preview
  doesn't need the graph) and feeds it to the client.

For preview-board to not require the server running, we generate the
fixture from a `mix zonia.dump_board <name>` task that writes
`tmp/boards/<name>.json`. Cheap, lets art iteration happen without the
full stack.

Commit message: `step 1: board parser and preview scene`.

### Step 2 — Lobby + room create/join, no game

Outcome: register → land in lobby → see other people there → chat with
them → create/join rooms → see room listing update for everyone.
Starting a game does **nothing** yet (no GameServer); the host's
"start" button is wired but the channel just acknowledges and stays in
the lobby.

Adds:
- `server/lib/zonia_web/channels/lobby_channel.ex`
- `server/lib/zonia/lobby_server.ex` (LobbyServer GenServer)
- Update `Zonia.Application` to start LobbyServer
- `client/src/scenes/lobby.ts`
- `client/src/components/chat-pane.ts`
- v2 client migration: `game_history` table (writes are best-effort
  no-ops for now since no games complete; we add the table early so
  step 6 doesn't need a new migration)

Removes:
- `client/src/scenes/chat.ts`
- `server/lib/zonia_web/channels/world_channel.ex`
- All tests for `WorldChannel`. Replaced with `LobbyChannel` tests.

Wires `client/src/index.ts` to mount the lobby scene after registration.

Commit message: `step 2: lobby, rooms, chat-as-pane`.

### Step 3 — Game loop, no mini-games

Outcome: host starts a game → all players transition to game scene →
roll → animated movement → branch UI works → next player. 5 rounds
pass, "game over" screen shows, room resets to ready.

Tile effects do nothing (every tile is functionally `:plain`).
End-of-round → no minigame yet, just "round X complete" beat.

Adds:
- `server/lib/zonia/game_server.ex`
- `server/lib/zonia/game_supervisor.ex` (DynamicSupervisor)
- `server/lib/zonia/game_registry.ex` (Registry module — or just
  the `Registry` started directly in the application tree)
- `server/lib/zonia_web/channels/game_channel.ex`
- `client/src/scenes/game.ts`
- Tests: roll, movement, branch, AFK timeout, turn advance, leave
  during turn, game completion.

The pawn animation pacing: server broadcasts each step with a small
delay between (e.g., `Process.send_after(self(), :next_step, 200)`).
Client just paints whatever it gets, with a CSS-y eased transition
client-side over ~150ms. Movement feels rhythmic without the server
caring about render timing.

Commit message: `step 3: game loop with rolls and branching`.

### Step 4 — Mini-game framework + Russian Buttons

Outcome: end of round triggers `RussianButtons`. Players see 5 boxes,
pick one with arrow keys, hit enter to commit. Reveal: 2 bombs blow,
3 safe. Survivors get coins. Back to next round.

Adds:
- `server/lib/zonia/mini_game.ex` (behaviour)
- `server/lib/zonia/mini_games.ex` (registry of impls)
- `server/lib/zonia/mini_games/runner.ex`
- `server/lib/zonia/mini_games/russian_buttons.ex`
- `server/lib/zonia_web/channels/mini_game_channel.ex`
- `client/src/scenes/minigame/buttons.ts`
- Wire-up in GameServer to spawn/await the runner.

Commit message: `step 4: mini-game framework + russian buttons`.

### Step 5 — Typing of the Dead

Outcome: at end of (some) rounds, the typing mini-game runs. Words
fall, players type, real-time scoring. Proves the real-time path works.

Adds:
- `server/lib/zonia/mini_games/typing_of_the_dead.ex` — implements
  `tick/1`. State has active words with positions, drift velocities,
  spawn timers. Runner runs `tick/1` at 30Hz, broadcasts public state
  to clients.
- `client/src/scenes/minigame/typing.ts` — renders words at their
  positions, captures keystrokes, forwards each to the server.
- Server picks randomly between the two mini-games at end of each
  round. We can weight or rotate later.

Commit message: `step 5: typing of the dead mini-game`.

### Step 6 — Polish

Outcome: results screen at game end shows final standings, a snappy
celebration line. Client writes to `game_history` SQLite table. Lobby
shows "your last 5 games" for the current player.

Adds:
- Final standings UI in game scene.
- Client-side `game_history` writes.
- Lobby sidebar showing local history.
- Tile effects: `:mystery` (draws a card with a small effect — gain/lose
  a coin), `:star_shop` (spend N coins → gain a star). Effects are
  declarative in the GameServer; only a couple to start.

This step is the "make it feel good" pass. Specific polish items get
pulled in based on how the first 5 steps feel.

Commit message: `step 6: results, history, tile effects`.

## Open questions deferred to implementation

These can shake out as we go; flagging them so they don't surprise me
later:

- **Reconnection.** What happens if alice's connection drops mid-game?
  The phoenix client auto-reconnects; the channel rejoin happens; the
  GameServer's state hasn't changed. Just push a fresh snapshot on
  rejoin and the client re-syncs. Probably free.
- **Spectators?** Not in v1. Game channel rejects non-players.
- **Pawn animation interleaving on multi-player moves.** A single move
  is one player at a time (strict turn order), so this isn't an issue
  for the board. Mini-games are different — `TypingOfTheDead` has
  simultaneous state changes, and the snapshot/tick model handles that.
- **Configurable die.** v1 hardcodes `1-10`. Can later be set per-board
  in the style module's metadata.
- **Power tools / chaos.** No items, no cards, no special abilities in
  v1. Adds tons of design space but isn't needed for the engine to be
  fun.

## Verification per step

Every step ends with:

1. `mix precommit` clean (server).
2. `bunx tsc --noEmit` clean (client).
3. Manual smoke: start the server, run two `just client alice` / `just
   client bob` terminals, exercise the new path.
4. Commit on `boards-and-mini-games` branch.

After all 6 steps are in: rebase / squash if needed, open a PR to
`main`, deploy.

## What we are explicitly not doing now

- Bots. Future.
- Spectator mode. Future.
- Mid-game persistence. Future.
- Multiple concurrent game sessions for the same player. By design — you're in one room at a time.
- More than 4 players per game. By design for v1.
- Map editor inside the TUI. Vim is the editor.
- Animations beyond movement easing and minigame state updates. No
  particles, no flair pass. Get the loop right first.

---

End of spec. When this branch ships, zonia is a Mario-Party-ish board
game with two mini-games, hand-drawable boards, real-time multiplayer,
named persistent identities, self-updating clients, and a deployment
pipeline that ships fixes within minutes of a push to `main`.
