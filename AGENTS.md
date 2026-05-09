# zonia

## Repository layout

- `server/`: Phoenix + Ecto + SQLite (via `ecto_sqlite3`). Channels,
  Presence, Accounts. See `server/AGENTS.md` when working on the server / writing Elixir.
- `client/`: Bun + TypeScript + OpenTUI + the official `phoenix` JS client.
  Local identity in `bun:sqlite`. See `client/AGENTS.md` when working on the client / writing TypeScript.
- `README.txt`: always read this, this is the high level vibes of the project
