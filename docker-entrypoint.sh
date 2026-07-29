#!/bin/bash
# Runs as root. Fixes volume ownership, then drops to the enterprisedb
# user for the rest of the startup logic (in docker-entrypoint-inner.sh).
set -euo pipefail

PGDATA="${PGDATA:-/home/enterprisedb/data}"

mkdir -p "$PGDATA"
chown -R enterprisedb:enterprisedb /home/enterprisedb

exec su enterprisedb -s /bin/bash -c "/usr/local/bin/docker-entrypoint-inner.sh"
