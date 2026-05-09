# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian?tab=tags - for the release image
#
# Build context: this directory (server/). docker build -t zonia .

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.3
ARG DEBIAN_VERSION=bookworm-20260505-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install mix deps first so they get cached separately from app code.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config copied before deps.compile so a config change forces
# deps to recompile.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib

# Compile the application.
RUN mix compile

# runtime.exs is read at boot, not at compile, so it's copied late and
# changes to it don't trigger recompilation.
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# ── runtime stage ─────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set the locale so the BEAM can do its UTF-8 things.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

ENV MIX_ENV=prod

# Where the SQLite DB lives. The deployer should mount a volume here.
ENV ZONIA_DATABASE=/data/zonia.db

# Drop the release into the container with non-root ownership.
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/zonia ./

USER nobody

# Migrations run automatically on boot via Ecto.Migrator in the supervision
# tree (it's gated on RELEASE_NAME, which the release sets). Calling
# bin/migrate explicitly is also harmless if you want a belt-and-suspenders.
CMD ["/app/bin/server"]
