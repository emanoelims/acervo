ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20261005-slim
ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM docker.io/node:22-trixie-slim AS assets
WORKDIR /assets
COPY assets/package.json assets/package-lock.json ./
RUN npm ci --ignore-scripts

FROM ${BUILDER_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
RUN mix tailwind.install --if-missing && mix esbuild.install --if-missing
COPY priv priv
COPY assets assets
COPY lib lib
RUN mix compile
COPY --from=assets /assets/node_modules assets/node_modules
RUN mix assets.deploy
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod
WORKDIR /app
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/acervo ./
USER nobody
CMD ["/app/bin/server"]
