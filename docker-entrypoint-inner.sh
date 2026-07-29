#!/bin/bash
# Runs as the enterprisedb user (invoked by docker-entrypoint.sh via su).
set -euo pipefail

PGDATA="${PGDATA:-$HOME/data}"
PGUSER="${POSTGRES_USER:-postgres}"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "==> No existing cluster found. Running initdb in $PGDATA"
  initdb -D "$PGDATA" -U "$PGUSER" --encoding=UTF8 --locale=C.UTF-8

  # Allow connections from outside the container (host, other containers).
  # NOTE: this build's compiled-in default port is 5444, not 5432 -- without
  # an explicit "port = 5432" here, Postgres listens on 5444 while
  # docker-compose.yml (and every script/README in this repo) assumes 5432.
  # `docker compose exec ... psql` still "works" in that case because it
  # connects over the local Unix socket, which ignores the port setting --
  # the bug only shows up on real TCP connections (the frontend, or psql
  # -h/-p from the host), so it's easy to miss during a smoke test.
  echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
  echo "port = 5432" >> "$PGDATA/postgresql.conf"
  echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
  echo "host all all ::/0 md5" >> "$PGDATA/pg_hba.conf"

  NEED_INIT=1
else
  echo "==> Existing cluster found in $PGDATA, skipping initdb"
  NEED_INIT=0
fi

echo "==> Starting Postgres temporarily (local socket only) to run init scripts"
pg_ctl start -D "$PGDATA" -w -l "$PGDATA/logfile" -o "-c listen_addresses=''"

if [ "$NEED_INIT" = "1" ]; then
  if [ -n "${POSTGRES_PASSWORD:-}" ]; then
    psql -U "$PGUSER" -v ON_ERROR_STOP=1 -c "ALTER USER $PGUSER WITH PASSWORD '${POSTGRES_PASSWORD}';"
  fi

  shopt -s nullglob
  for f in /docker-entrypoint-initdb.d/*.sql; do
    echo "==> Running init script: $f"
    psql -U "$PGUSER" -v ON_ERROR_STOP=1 \
         -v openai_api_key="${OPENAI_API_KEY:-}" \
         -v openrouter_api_key="${OPENROUTER_API_KEY:-}" \
         -f "$f"
  done
fi

echo "==> Stopping temporary Postgres instance"
pg_ctl stop -D "$PGDATA" -m fast

echo "==> Starting Postgres in foreground"
exec postgres -D "$PGDATA"
