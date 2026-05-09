# zonia — run targets

# Show available recipes.
default:
    @just --list

# Boot the Phoenix server (localhost:4000). Runs pending migrations first.
server:
    cd server && mix ecto.migrate && mix phx.server

# Launch the OpenTUI client. Optionally pass a name to spin up an isolated
# instance with its own data dir under tmp/clients/<name> (gitignored), so
# you can run several clients side-by-side for testing.
#
#   just client          → uses the real XDG data dir
#   just client alice    → uses tmp/clients/alice
client name="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{name}}" ]; then
        cd client && bun run dev
    else
        dir="$(pwd)/tmp/clients/{{name}}"
        mkdir -p "$dir"
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
