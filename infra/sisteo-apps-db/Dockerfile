# sisteo-apps-db: the running postgres-flex image, pinned by digest, plus pgvector
# from the PGDG apt repository already configured in the image.
FROM flyio/postgres-flex:18.1@sha256:f2aaf3666b0fbf07a1c5450fe3b615335bbe961102c9156e81efcbcc0ad3965f
RUN apt-get update \
    && apt-get install -y --no-install-recommends --no-upgrade postgresql-18-pgvector=0.8.6-1.pgdg24.04+1 \
    && rm -rf /var/lib/apt/lists/*
