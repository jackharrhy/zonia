# Build context: repo root. The image bakes both the Phoenix release and
# all five client binaries so the running server can hand them out.
#
#   docker build -f server/Dockerfile -t zonia .
#
# Image base options:
#   - https://hub.docker.com/r/hexpm/elixir/tags  (build image)
#   - https://hub.docker.com/_/debian?tab=tags    (release image)
#   - https://hub.docker.com/r/oven/bun/tags      (client compile image)

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.3
ARG DEBIAN_VERSION=bookworm-20260505-slim
ARG BUN_VERSION=1.3.9

ARG ELIXIR_BUILDER="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG BUN_BUILDER="oven/bun:${BUN_VERSION}-debian"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ─── stage 1: phoenix release ─────────────────────────────────────────────
FROM ${ELIXIR_BUILDER} AS server_builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV=prod

# Mix deps cached separately from app code.
COPY server/mix.exs server/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config copied before deps.compile so config changes force
# deps to recompile.
COPY server/config/config.exs server/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY server/priv priv
COPY server/lib lib
RUN mix compile

# runtime.exs is read at boot, not at compile, so it's copied late.
COPY server/config/runtime.exs config/

COPY server/rel rel
RUN mix release

# ─── stage 2: client binaries ─────────────────────────────────────────────
# Compiles all five `bun build --compile` targets and emits a manifest with
# sha256 + size for each. The runtime stage copies the result into
# /app/releases/ so the server can serve them.
FROM ${BUN_BUILDER} AS client_builder

WORKDIR /build

COPY client/package.json client/bun.lock ./

# `bun install` filters optionalDependencies by host platform. We force every
# target's @opentui/core-* native binary to materialize so cross-compile can
# resolve them at build time.
RUN bun install --os=darwin --cpu=arm64 \
 && bun install --os=darwin --cpu=x64   \
 && bun install --os=linux  --cpu=arm64 \
 && bun install --os=linux  --cpu=x64   \
 && bun install --os=win32  --cpu=x64

COPY client/tsconfig.json ./
COPY client/src ./src

# wss://zonia.harrhy.xyz/socket is baked in here. ZONIA_SERVER env var
# overrides at runtime.
ARG ZONIA_DEFAULT_SERVER="wss://zonia.harrhy.xyz/socket"

RUN mkdir -p /releases \
 && for target in \
        "darwin-arm64:bun-darwin-arm64:zonia-darwin-arm64" \
        "darwin-x64:bun-darwin-x64:zonia-darwin-x64" \
        "linux-x64:bun-linux-x64:zonia-linux-x64" \
        "linux-arm64:bun-linux-arm64:zonia-linux-arm64" \
        "win32-x64:bun-windows-x64:zonia-win32-x64.exe" \
    ; do \
        bun_target=$(echo "$target" | cut -d: -f2); \
        outfile=$(echo "$target" | cut -d: -f3); \
        echo "→ $outfile"; \
        bun build --compile \
            --target=$bun_target \
            --define=__ZONIA_BAKED_SERVER__="\"${ZONIA_DEFAULT_SERVER}\"" \
            --outfile=/releases/$outfile \
            src/index.ts; \
    done

# Generate releases/manifest.json with sha256 + size of every binary.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends jq coreutils \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN cd /releases \
 && manifest='{"version":"'"$(date -u +%Y%m%dT%H%M%SZ)"'","binaries":{}}' \
 && for f in zonia-*; do \
        plat=$(echo "$f" | sed 's/^zonia-//; s/\.exe$//'); \
        sha=$(sha256sum "$f" | cut -d' ' -f1); \
        size=$(stat -c%s "$f"); \
        manifest=$(echo "$manifest" | jq --arg p "$plat" --arg s "$sha" --argjson sz "$size" '.binaries[$p] = {sha256: $s, size: $sz}'); \
    done \
 && echo "$manifest" | jq . > manifest.json \
 && cat manifest.json

# ─── stage 3: runtime ─────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Locale so the BEAM's UTF-8 things behave.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
ENV MIX_ENV=prod

# Where the SQLite DB lives. Bind-mount a host volume here.
ENV ZONIA_DATABASE=/data/zonia.db

# Where compiled client binaries live. Plug.Static (see endpoint.ex) serves
# from this dir at /releases/*.
ENV ZONIA_RELEASES_DIR=/app/releases

# Phoenix release. We deliberately do NOT switch to USER nobody — the
# bind-mounted /data volume's host-side ownership matches the deploy user,
# and running as root inside avoids the UID-mismatch dance.
COPY --from=server_builder /app/_build/${MIX_ENV}/rel/zonia ./

# Client binaries + manifest.
COPY --from=client_builder /releases ./releases

# Migrations run on boot via Ecto.Migrator (gated on RELEASE_NAME, which the
# release sets). bin/migrate is also available for manual ops.
CMD ["/app/bin/server"]
