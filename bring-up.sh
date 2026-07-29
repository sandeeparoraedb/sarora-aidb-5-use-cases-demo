#!/usr/bin/env bash
# One-shot local bring-up for the NorthStar Terminals EDB Postgres AI demos --
# database, seed data, all four demos' functions, AND the Streamlit
# frontend, each step checked before moving to the next.
#
# Usage:
#   bash bring-up.sh          # bring everything up
#   bash bring-up.sh --down   # stop the frontend and the containers
#
# Prerequisites:
#   - Docker Desktop running
#   - Your EDB token saved at ~/.edb_token
#   - Your OpenRouter API key saved at ~/.openrouter_key (get one at
#     https://openrouter.ai/keys) -- used for both my_summarizer (text
#     generation) and my_embedder (embeddings); see sql/02-aidb-models.sql.
#     No local model inference runs on this machine at all.
#   - Python 3 (for the frontend)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Distinct from the other local track's ports (5432 /
# 8501) so both tracks can run at the same time without colliding --
# matches the "5433:5432" host mapping in this track's docker-compose.yml.
STREAMLIT_PORT=8502
PIDFILE="frontend/.streamlit.pid"
CURRENT_STEP="startup"
trap 'echo ""; echo "!! FAILED during: $CURRENT_STEP" >&2; echo "!! See the output above for the actual error." >&2' ERR

step() { CURRENT_STEP="$1"; echo ""; echo "==> $1"; }

psql_exec() { docker compose exec -T epas psql -U postgres -d mydb -tA "$@"; }

# ── Teardown mode ────────────────────────────────────────────────────────
if [ "${1:-}" = "--down" ] || [ "${1:-}" = "down" ]; then
    step "Stopping frontend"
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        SPID="$(cat "$PIDFILE")"
        kill "$SPID" 2>/dev/null || true
        # kill only *sends* the signal -- confirm it actually exits before
        # declaring victory, and escalate if it's still hanging around.
        DEAD=0
        for i in 1 2 3 4 5; do
            if ! kill -0 "$SPID" 2>/dev/null; then DEAD=1; break; fi
            sleep 1
        done
        if [ "$DEAD" = "1" ]; then
            echo "    stopped Streamlit (pid $SPID)."
        else
            kill -9 "$SPID" 2>/dev/null || true
            echo "    Streamlit (pid $SPID) didn't stop gracefully -- force-killed."
        fi
    else
        echo "    Streamlit wasn't running."
    fi
    rm -f "$PIDFILE"

    step "Stopping containers"
    docker compose down
    echo ""
    echo "==> Everything stopped. Run 'bash bring-up.sh' again to bring it back up."
    exit 0
fi

# ── 0. Preflight ─────────────────────────────────────────────────────────
step "Preflight checks"

command -v docker >/dev/null 2>&1 || { echo "Docker not found -- install/start Docker Desktop first." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable -- is Docker Desktop running?" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose (v2) not found -- update Docker Desktop." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found -- install Python 3 (e.g. from python.org) and re-run." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not found (unexpected on macOS) -- please install it." >&2; exit 1; }
[ -f "$HOME/.edb_token" ] || { echo "$HOME/.edb_token not found -- create it (echo YOUR_TOKEN > ~/.edb_token) and re-run." >&2; exit 1; }
[ -f "$HOME/.openrouter_key" ] || { echo "$HOME/.openrouter_key not found -- create it (echo YOUR_KEY > ~/.openrouter_key). Get a key at https://openrouter.ai/keys and re-run." >&2; exit 1; }

echo "    docker, docker compose, python3, curl, ~/.edb_token, ~/.openrouter_key -- all present."

# ── 1. EDB token + registry login ───────────────────────────────────────
step "EDB registry login"
cp "$HOME/.edb_token" ./edb_token.txt
docker login docker.enterprisedb.com -u k8s --password-stdin < "$HOME/.edb_token"

# ── 2. .env -- Postgres password + OpenRouter key ───────────────────────
# my_summarizer (text generation) runs on OpenRouter by default -- see
# sql/02-aidb-models.sql. OPENAI_API_KEY is only needed if you've switched
# that file to the commented-out OpenAI-backed alternative.
step ".env (Postgres password + OpenRouter key)"
OPENROUTER_API_KEY_FROM_FILE="$(tr -d '\n' < "$HOME/.openrouter_key")"
if [ ! -f .env ]; then
    printf "Postgres password (hidden, press enter for default 'postgres'): "
    read -rs PG_PASS
    echo
    cat > .env <<EOF
OPENROUTER_API_KEY=${OPENROUTER_API_KEY_FROM_FILE}
OPENAI_API_KEY=
POSTGRES_PASSWORD=${PG_PASS:-postgres}
EOF
    unset PG_PASS
    echo "    .env written."
else
    # Keep OPENROUTER_API_KEY in sync with ~/.openrouter_key even when .env
    # already existed (e.g. from before this repo used OpenRouter, or if
    # you rotated the key) -- everything else in .env is left as-is.
    if grep -q '^OPENROUTER_API_KEY=' .env; then
        grep -v '^OPENROUTER_API_KEY=' .env > .env.tmp
        echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY_FROM_FILE}" >> .env.tmp
        mv .env.tmp .env
    else
        echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY_FROM_FILE}" >> .env
    fi
    echo "    .env already existed -- synced OPENROUTER_API_KEY from ~/.openrouter_key."
fi
unset OPENROUTER_API_KEY_FROM_FILE
set -a; source .env; set +a

# ── 3. Build and start ───────────────────────────────────────────────────
step "Building image (first run pulls EDB packages -- can take a few minutes)"
docker compose build

step "Starting containers"
docker compose up -d

# The entrypoint always starts Postgres *twice* on every boot: a temporary
# local-socket-only instance to run the init/seed SQL, then it stops that
# and execs the real foreground instance that's actually reachable. Checking
# "does psql connect" alone can catch the temporary instance moments before
# it shuts down -- so wait for the entrypoint's own "foreground" log line.
#
# Scope the log search to the container's actual last start time (not "now",
# the moment we called `up -d`) -- if the container was already running from
# a previous invocation, `up -d` is a no-op and no *new* log line will ever
# appear, even though it's already fully up. Using the real StartedAt makes
# both cases correct: a fresh boot waits for its own new line; an
# already-running container immediately finds its (older) line and passes.
CID="$(docker compose ps -q epas)"
[ -n "$CID" ] || { echo "Could not find the epas container after 'up -d'." >&2; exit 1; }
STARTED_AT="$(docker inspect -f '{{.State.StartedAt}}' "$CID")"

step "Waiting for the container's startup sequence to finish"
FOREGROUND=0
for i in $(seq 1 150); do
    if docker compose logs --since "$STARTED_AT" epas 2>&1 | grep -q "Starting Postgres in foreground"; then
        FOREGROUND=1
        break
    fi
    sleep 2
done
[ "$FOREGROUND" = "1" ] || { echo "Container never reached its foreground startup. Check: docker compose logs epas" >&2; exit 1; }
echo "    Entrypoint reached the foreground Postgres instance."

step "Waiting for Postgres to accept connections"
READY=0
for i in $(seq 1 30); do
    if docker compose exec -T epas psql -U postgres -d mydb -c "select 1" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 2
done
[ "$READY" = "1" ] || { echo "Postgres never became ready. Check: docker compose logs epas" >&2; exit 1; }
echo "    Postgres is up."

# The check above connects over the container's local Unix socket, which
# ignores whatever TCP port Postgres is actually listening on -- so it can
# pass even if a port/listen_addresses mismatch means nothing outside the
# container (the frontend, or you at a psql prompt) can actually reach it.
# Confirm the same TCP path the frontend uses.
step "Verifying Postgres is reachable over TCP (the same path the frontend uses)"
if ! docker compose exec -T epas env PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" \
        psql -h 127.0.0.1 -p 5432 -U postgres -d mydb -c "select 1" >/dev/null 2>&1; then
    echo "Postgres answers on its local socket but not on 127.0.0.1:5432 -- check for a port/listen_addresses mismatch:" >&2
    echo "  docker compose exec epas grep -n '^port\|^listen_addresses' /home/enterprisedb/data/postgresql.conf" >&2
    exit 1
fi
echo "    TCP connection on port 5432 confirmed."

# ── 4. Verify schema + seed data actually landed ────────────────────────
step "Verifying extensions and schema"
docker compose exec -T epas psql -U postgres -d mydb -c "\dx"
docker compose exec -T epas psql -U postgres -d mydb -c "\dt"

step "Verifying seed data landed"
WO_COUNT=$(psql_exec -c "SELECT count(*) FROM work_orders;" | tr -d '[:space:]')
CM_COUNT=$(psql_exec -c "SELECT count(*) FROM container_moves;" | tr -d '[:space:]')
echo "    work_orders: $WO_COUNT (expect 3)"
echo "    container_moves: $CM_COUNT (expect ~300,000+)"
[ "$WO_COUNT" = "3" ] || { echo "Seed data looks wrong (work_orders != 3) -- check sql/04-terminal-seed.sql ran cleanly." >&2; exit 1; }
[ "$CM_COUNT" -gt 100000 ] || { echo "Seed data looks wrong (container_moves too low) -- check sql/04-terminal-seed.sql ran cleanly." >&2; exit 1; }

# ── 5. Ingest docs + install the three demo function sets ──────────────
step "Ingesting docs/ for Enterprise Search"
docker compose exec -T epas /opt/scripts/ingest.sh
INGESTED=$(psql_exec -c "SELECT count(*) FROM policies WHERE status = 'ingested';" | tr -d '[:space:]')
echo "    chunks ingested: $INGESTED"
[ "$INGESTED" -gt 0 ] || { echo "Nothing was ingested -- check docs/ has files and re-run ingest.sh manually to see the error." >&2; exit 1; }

step "Installing Ops Copilot functions"
docker compose exec -T epas psql -U postgres -d mydb -f /opt/demos/02-ops-copilot/ops_copilot.sql >/dev/null
[ "$(psql_exec -c "SELECT count(*) FROM pg_proc WHERE proname = 'ops_copilot_diagnose';" | tr -d '[:space:]')" = "1" ] \
    || { echo "ops_copilot_diagnose() didn't get created." >&2; exit 1; }
echo "    installed."

step "Installing App Intelligence functions"
docker compose exec -T epas psql -U postgres -d mydb -f /opt/demos/03-app-intelligence/app_intelligence.sql >/dev/null
[ "$(psql_exec -c "SELECT count(*) FROM pg_proc WHERE proname = 'classify_and_score_dispute';" | tr -d '[:space:]')" = "1" ] \
    || { echo "classify_and_score_dispute() didn't get created." >&2; exit 1; }
echo "    installed."

step "Installing Text-to-Insights (Ask the Terminal) functions"
docker compose exec -T epas psql -U postgres -d mydb -f /opt/demos/04-text-to-insights/ask_terminal.sql >/dev/null
[ "$(psql_exec -c "SELECT count(*) FROM pg_proc WHERE proname = 'ask_terminal';" | tr -d '[:space:]')" = "1" ] \
    || { echo "ask_terminal() didn't get created." >&2; exit 1; }
echo "    installed."

# ── 6. Frontend ──────────────────────────────────────────────────────────
step "Setting up the frontend (Python virtualenv)"
if [ ! -d frontend/.venv ]; then
    python3 -m venv frontend/.venv
fi
# shellcheck disable=SC1091
source frontend/.venv/bin/activate
pip install --upgrade pip -q
pip install -r frontend/requirements.txt -q
echo "    dependencies installed in frontend/.venv"

step "Starting the Streamlit app"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "    Already running (pid $(cat "$PIDFILE"))."
else
    export PGPASSWORD="${POSTGRES_PASSWORD:-postgres}"   # pre-fills the sidebar password field
    export PGPORT=5433   # matches this track's "5433:5432" host port mapping
    # No 'cd' + subshell here on purpose -- combining backgrounding ('&') with
    # '&&' inside a subshell backgrounds the *whole* "cd && nohup ..." group,
    # so '$!' and any code after the '&' runs in the parent with the *original*
    # cwd, not frontend/ -- the pid file silently ends up one level up. Using
    # full paths from $SCRIPT_DIR and backgrounding only the single nohup
    # command avoids that trap entirely.
    nohup streamlit run "$SCRIPT_DIR/frontend/app.py" \
        --server.headless true --server.port "$STREAMLIT_PORT" \
        > "$SCRIPT_DIR/frontend/streamlit.log" 2>&1 &
    STREAMLIT_PID=$!
    disown "$STREAMLIT_PID" 2>/dev/null || true
    echo "$STREAMLIT_PID" > "$PIDFILE"
    echo "    launched (pid $STREAMLIT_PID)."
fi

step "Waiting for the frontend to respond"
UP=0
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${STREAMLIT_PORT}/" || true)
    if [ "$CODE" = "200" ]; then
        UP=1
        break
    fi
    sleep 1
done
if [ "$UP" != "1" ]; then
    echo "Streamlit didn't respond in time -- check frontend/streamlit.log" >&2
    exit 1
fi
echo "    Streamlit is serving on port $STREAMLIT_PORT."

open "http://localhost:${STREAMLIT_PORT}" 2>/dev/null || true

echo ""
echo "==================================================================="
echo " Everything is up:"
echo "   - Postgres + aidb + pgvector running (docker compose)"
echo "   - Enterprise Search docs ingested ($INGESTED chunks)"
echo "   - Ops Copilot, App Intelligence, Text-to-Insights installed"
echo "   - Frontend: http://localhost:${STREAMLIT_PORT}  (opened in your browser)"
echo ""
echo " To stop everything later:  bash bring-up.sh --down"
echo "==================================================================="
