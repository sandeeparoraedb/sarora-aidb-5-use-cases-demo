# syntax=docker/dockerfile:1
FROM --platform=linux/amd64 docker.enterprisedb.com/k8s/edb-postgres-advanced:18

USER root

# EDB_TOKEN is passed in as a BuildKit secret so it never gets baked into
# an image layer or shows up in `docker history`.
RUN --mount=type=secret,id=edb_token \
    EDB_TOKEN="$(cat /run/secrets/edb_token)" && \
    curl -1sLf "https://downloads.enterprisedb.com/${EDB_TOKEN}/enterprise/setup.rpm.sh" | bash && \
    dnf install -y edb-as18-aidb edb-as18-pgfs edb-as18-pgvector0 && \
    dnf clean all

# Entrypoint handles first-run initdb + running our init SQL once.
# Starts as root to fix volume ownership, then drops to enterprisedb.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker-entrypoint-inner.sh /usr/local/bin/docker-entrypoint-inner.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint-inner.sh

# Init scripts, run once (in order) the very first time the cluster is created.
# This repo lives on a Google-Drive-synced folder, which doesn't preserve
# real Unix group/other permission bits (everything shows up owner-only) --
# these get read by the enterprisedb user (dropped-privilege, not root), so
# make them explicitly world-readable regardless of what the host reports.
COPY sql/ /docker-entrypoint-initdb.d/
RUN chmod -R a+rX /docker-entrypoint-initdb.d/

ENV HOME=/home/enterprisedb
ENV PGDATA=/home/enterprisedb/data
# This build's compiled-in default port is 5444, not 5432 (see
# docker-entrypoint-inner.sh for where the server itself is pinned to
# 5432). Without this, every psql call made without an explicit -p --
# init scripts, `docker compose exec epas psql ...`, ingest.sh, ask.sh --
# would fall back to the compiled default and fail to find the socket.
ENV PGPORT=5432

EXPOSE 5432

ENTRYPOINT ["docker-entrypoint.sh"]
