# zonia — run targets

# Show available recipes.
default:
    @just --list

# Boot the Phoenix server (localhost:4000) inside an iex REPL.
#
# Running under iex by default gives you an interactive shell in the
# same terminal — so you can poke at state without a remote session:
#
#   iex(1)> :sys.get_state(Zonia.LobbyServer)
#   iex(2)> Zonia.LobbyServer.list_rooms()
#
# The BEAM is named `zonia@127.0.0.1` with cookie `zoniadev` so
# `just remsh` and `just rpc` can attach over distributed Erlang from
# another terminal. Long names avoid macOS short-hostname weirdness.
server:
    cd server && mix ecto.migrate && iex --name zonia@127.0.0.1 --cookie zoniadev -S mix phx.server

# Attach a remote iex shell to a running `just server`. The server
# must already be up. Ctrl+C twice to leave the remote shell; the
# server keeps running.
remsh:
    iex --name remsh@127.0.0.1 --cookie zoniadev --remsh zonia@127.0.0.1

# Run a single Elixir expression against the running server and print
# the result. Non-interactive — useful for scripts or quick checks.
#
#   just rpc 'Zonia.LobbyServer.list_rooms()'
#   just rpc ':sys.get_state(Zonia.LobbyServer)'
#   just rpc 'Zonia.LobbyServer.leave_all(7)'
#
# The expression is evaluated on the remote node via :rpc.call into
# Code.eval_string/1, so any well-formed Elixir snippet works.
rpc expr:
    #!/usr/bin/env bash
    set -euo pipefail
    elixir --name rpc@127.0.0.1 --cookie zoniadev --eval "
      case :rpc.call(:\"zonia@127.0.0.1\", Code, :eval_string, [\"{{ expr }}\"], 5000) do
        {result, _bindings} -> IO.inspect(result)
        {:badrpc, reason} -> IO.puts(\"rpc failed: \" <> inspect(reason)); System.halt(1)
      end
    "

# Launch the OpenTUI client in dev mode.
#
# Always uses a repo-local data dir under tmp/clients/<name>/ so dev
# identities never collide with the production identity in your real
# XDG dir (~/.local/share/zonia/). The dev server has its own users
# table, so a prod-minted key would just fail to authenticate.
#
#   just client          → tmp/clients/dev/        (no auto-register)
#   just client alice    → tmp/clients/alice/      (auto-registers as alice)
client name="dev":
    #!/usr/bin/env bash
    set -euo pipefail
    dir="$(pwd)/tmp/clients/{{name}}"
    mkdir -p "$dir"
    if [ "{{name}}" = "dev" ]; then
        echo "→ dev client using data dir $dir (no --name)"
        cd client && ZONIA_DATA_DIR="$dir" bun run dev
    else
        echo "→ client '{{name}}' using data dir $dir"
        cd client && ZONIA_DATA_DIR="$dir" bun run dev -- --name {{name}}
    fi

# Run the server test suite.
test:
    cd server && mix test

# Run the full server precommit (compile, deps, format, test).
precommit:
    cd server && mix precommit

# Typecheck the client.
typecheck:
    cd client && bunx tsc --noEmit

# Preview a board in the TUI without running the full server / game stack.
# Dumps the parsed board to tmp/boards/<name>.json then launches the client's
# preview scene against it. Useful for iterating on map.txt + style.ex.
#
#   just preview-board zonia-isle
preview-board name:
    cd server && mix zonia.dump_board {{name}}
    cd client && bun run --watch src/preview.ts -- --fixture ../tmp/boards/{{name}}.json

# Build per-platform binaries and stage all npm packages into dist/npm/.
build-npm:
    bun scripts/prepare-npm.ts

# Publish all staged packages to npm. Run `just build-npm` first.
publish-npm: build-npm
    ./scripts/publish-npm.sh

# Build the server's prod docker image locally. Build context is the repo
# root so the same image bakes the Phoenix release AND all five client
# binaries from client/.
docker-build:
    docker build -f server/Dockerfile -t ghcr.io/jackharrhy/zonia:local .

# Run the server image via docker compose. Mounts server/data/ for the DB.
# Stop with ctrl-c (or `docker compose down` from server/).
docker-up:
    docker compose -f server/compose.yaml up --build

# Stop the compose stack.
docker-down:
    docker compose -f server/compose.yaml down

# Wipe a single throwaway client's local data so it can re-register.
reset-client name:
    rm -rf tmp/clients/{{name}}
    @echo "→ wiped tmp/clients/{{name}}"

# Wipe the entire server DB and all throwaway clients. The server must NOT be
# running. Useful when you want a totally clean slate for testing.
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    if lsof -ti :4000 > /dev/null 2>&1; then
        echo "✗ server is running on :4000 — stop it first"
        exit 1
    fi
    rm -f server/zonia_dev.db server/zonia_dev.db-shm server/zonia_dev.db-wal
    rm -rf tmp/clients
    echo "→ server DB wiped, all throwaway clients wiped"
    echo "→ run 'just server' to recreate (migrations run on boot)"
