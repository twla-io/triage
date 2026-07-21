# Multi-stage build for the triage Haskell/Servant backend only.
# Frontend hosting is a separate, not-yet-made decision — not handled here.

# ── Build stage ──────────────────────────────────────────────────────────
FROM haskell:9.10.3-slim-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq-dev \
      liblzma-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Dependencies first, so source edits don't bust the dependency cache.
COPY triage.cabal cabal.project ./
RUN cabal update && cabal build lib:triage --only-dependencies -j

COPY . .
RUN cabal build exe:triage-server -j

# Locate the built binary and copy it out to a known, fixed path.
RUN cp "$(cabal list-bin exe:triage-server)" /build/triage-server

# ── Runtime stage ────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --shell /usr/sbin/nologin triage

COPY --from=build /build/triage-server /usr/local/bin/triage-server

USER triage

# TRIAGE_DB_URL and TRIAGE_PORT are read from the environment at startup
# (see Api.hs's loadConfig) — intentionally not set here.
#
# Migrations (migrations/0001_init.sql) are a deliberate separate
# manual/external step, never run at container startup.
CMD ["triage-server"]
