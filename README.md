# EDB Postgres AI for NorthStar Terminals -- Five Capability Demos

One EPAS 18 + `aidb` + `pgvector` + `pgfs` Postgres instance, seeded with
synthetic terminal-operations data that reproduces specific moments from
the "AI Use Cases" seed deck (July 2026) and demonstrates the five
capabilities from the EDB Agent Factory sales training deck -- each mapped
to a concrete terminal business problem, not a generic one.

| # | Capability (AI Factory deck) | Business problem | Persona | Folder |
|---|---|---|---|---|
| 1 | Enterprise Search (AIDB + AI Pipelines + pgvector) | Maintenance work-order history is free text, scattered per terminal -- a repeat crane failure signature goes unrecognized until it's too late | Priya, maintenance planner | `demos/01-enterprise-search/` |
| 2 | Ops Copilot (AI Sidecar + AIDB) | Nobody proactively watches for the queries about to become a performance ticket; DBAs spend half their time firefighting after the fact | DBA / platform team | `demos/02-ops-copilot/` |
| 3 | App Intelligence (AIDB, in-DB inference) | Disputed invoices are triaged by hand; PII sits in both structured columns and free-text complaints | Billing / finance analyst | `demos/03-app-intelligence/` |
| 4 | Text-to-Insights (Semantic KB + pgvector + AIDB) | A cross-module operational question takes three hours and four systems to answer | Ana, terminal ops manager | `demos/04-text-to-insights/` |
| 5 | MCP Gateway (`pg-airman-mcp`, Streamable HTTP) | General-purpose AI tools (Claude, Cursor, internal agents) need safe, governed access to this same database without a custom integration per tool or a shared raw credential | Security / platform lead | Streamlit "MCP Gateway" step + `airman-mcp` service in `docker-compose.yml` |

All five run against the same seeded dataset (MCP Gateway queries the same live Postgres instance through pg-airman-mcp, in restricted/read-only mode), and several answers
deliberately cross-reference each other -- e.g. the crane 2 gearbox failure
that demo 1 pattern-matches is the same incident that forces the berth
replan referenced in demo 4's data, and the same incident behind one of the
disputed invoices in demo 3. Running them in order tells one connected
story, the way the seed deck itself intends ("ONE STORY -- descriptive →
predictive → prescriptive, all three run on data Zodiac already
generates").

## What's real vs. illustrative -- read this before you present

- Demos 1 (Enterprise Search) and 3 (App Intelligence) map directly to
  capabilities EDB ships today, unmodified.
- Demo 2 (Ops Copilot) demonstrates the scan → diagnose → human-approve/
  reject → apply → re-measure pattern; the underlying "seq scan on 300K
  rows" is a modest, honest stand-in for a production-scale problem, not a
  re-creation of any real customer incident. The before/after benefit
  numbers are real (a second live `EXPLAIN ANALYZE` after the index is
  created), not estimates.
- Demo 4 (Text-to-Insights) is the closest to the seed deck's actual request,
  but its SQL-safety guardrail is intentionally simple for a demo -- see
  that folder's README for the honest caveat about what production needs
  beyond this.
- None of these use any real customer data. Every vessel name, work order,
  invoice, and telemetry reading is synthetic, constructed to match the
  *narrative* in the two decks in this folder, not any real terminal's
  operational history.
- `pgfs` is installed (see `sql/01-init.sql`) but unused by any of these five
  capabilities -- nothing here reads from or writes to a real object store
  (S3, GCS, Azure Blob, etc.); all data lives in Postgres tables.
- Text generation and embeddings both run on a hosted model via OpenRouter
  (`gpt-4o-mini` / `text-embedding-3-small`, see `sql/02-aidb-models.sql`),
  not a locally-hosted model -- see that file for the fully-local alternative
  and why it is not the default.
- The workflow steps in each capability (scan -> diagnose -> human-approve/
  reject, triage, MCP tool calls, etc.) are built specifically for this demo
  narrative, not a shipped product workflow -- a real deployment would need
  custom coding around approval routing, audit retention, error handling,
  and integration with whatever ticketing/ERP system already owns that
  process today.

## Fast path: one script

If Docker Desktop is running and you have your EDB token saved at
`~/.edb_token` and your OpenRouter key saved at `~/.openrouter_key`, `bash
bring-up.sh` does everything below in order -- registry login, `.env`
setup, build, start, verifies the schema/seed data/functions all landed
correctly at each step, ingests `docs/`, installs all three demo function
sets, sets up the frontend's Python virtualenv, and launches it -- then
opens `http://localhost:8501` in your browser. `bash bring-up.sh --down`
stops the frontend and the containers. Everything below is what that
script automates, spelled out manually.

## One-time setup

- Docker Desktop for Mac (Apple Silicon or Intel -- image runs under
  `linux/amd64` via Rosetta emulation either way)
- An EDB account token: https://www.enterprisedb.com/docs/repos/getting_started/with_web/get_your_token/
- An OpenRouter API key: https://openrouter.ai/keys -- both `my_summarizer`
  (text generation, `openai/gpt-4o-mini`) and `my_embedder` (embeddings,
  `openai/text-embedding-3-small`) run on OpenRouter by default, so no
  local model inference runs on your machine at all. `gpt-4o-mini` is
  deliberately chosen over newer "reasoning" models like `gpt-5-mini`,
  which can spend their whole token budget on hidden internal reasoning
  and return no visible answer for these short, latency-sensitive prompts
  -- see `sql/02-aidb-models.sql` for details. See that same file for the
  fully-local alternative too (works with zero API cost, but consumes real
  CPU/RAM on the host, and the local TinyLlama model proved unreliable at
  strict instruction-following -- e.g. respecting "respond with ONLY the
  SQL statement" -- which is why OpenRouter is the default here).

```bash
cd search-demo-code

# 1. Log in to the EDB registry
docker login docker.enterprisedb.com
#   Username: k8s
#   Password: <your EDB token>

# 2. Put your EDB token in a file used only at build time (never baked
#    into the image or committed -- see .gitignore)
echo "YOUR_EDB_TOKEN" > edb_token.txt

# 3. Set a Postgres password and your OpenRouter key
cp .env.example .env
#   edit .env: set POSTGRES_PASSWORD and OPENROUTER_API_KEY (get one at
#   https://openrouter.ai/keys); leave OPENAI_API_KEY empty unless you've
#   switched sql/02-aidb-models.sql to the OpenAI-backed alternative
```

## Build and start

```bash
docker compose build
docker compose up -d
docker compose logs -f epas
```

First boot runs `initdb`, creates the `mydb` database, installs `aidb`,
`pgvector`, and `pgfs`, registers the `my_embedder` / `my_summarizer`
models, creates the terminal schema (`sql/03-terminal-schema.sql`), and
seeds the synthetic dataset (`sql/04-terminal-seed.sql`) -- including
~300K background container-move rows, so first boot takes a little longer
than a bare template would. All of this only happens once; subsequent
`docker compose up` runs just start Postgres against the existing volume.

Verify it worked:

```bash
docker compose exec epas psql -U postgres -d mydb -c "\dx"
docker compose exec epas psql -U postgres -d mydb -c "\dt"
```

## Frontend

`frontend/` has a lightweight Streamlit app that walks through all five
capabilities as one guided narrative (not separate tabs) -- each step shows the
business problem it solves, the exact EDB components/aidb calls
powering it, and a live status banner proving it's a real Postgres
instance, not mocked data. See `frontend/README.md` for details. It's a
separate step, after the containers above are up and the four demo SQL (MCP Gateway needs the airman-mcp container instead -- see below)
files are installed:

```bash
cd frontend
pip install -r requirements.txt
streamlit run app.py
```

See `frontend/README.md` for connection details.

## Running the demos (command-line version)

Each demo folder has its own README with the business framing and exact
commands. In brief:

```bash
# 1. Enterprise Search -- ingest the docs/ folder, then ask a question
docker compose exec epas /opt/scripts/ingest.sh
docker compose exec epas /opt/scripts/ask.sh "Crane 2's gearbox failed showing a vibration trend beforehand -- have we seen this before?"

# 2. Ops Copilot -- install, scan for tuning candidates, then diagnose the worst one
docker compose exec epas psql -U postgres -d mydb -f /opt/demos/02-ops-copilot/ops_copilot.sql
docker compose exec epas psql -U postgres -d mydb -c "SELECT * FROM ops_copilot_scan() ORDER BY exec_ms DESC;"
docker compose exec epas psql -U postgres -d mydb -c "SELECT ops_copilot_diagnose('SELECT * FROM container_moves WHERE container_id = ''CONT0001234''', 'Container lookup by ID');"

# 3. App Intelligence -- install, then triage all open disputes
docker compose exec epas psql -U postgres -d mydb -f /opt/demos/03-app-intelligence/app_intelligence.sql
docker compose exec epas psql -U postgres -d mydb -c "CALL run_dispute_triage();"

# 4. Text-to-Insights -- install, then ask Ana's exact question
docker compose exec epas psql -U postgres -d mydb -f /opt/demos/04-text-to-insights/ask_terminal.sql
docker compose exec epas psql -U postgres -d mydb -x -c "SELECT answer FROM ask_terminal('Why did gate turn times spike on Tuesday afternoon, and did it cost us berth productivity?');"
```

```bash
# 5. MCP Gateway -- start the pg-airman-mcp server, then point any MCP client at it
docker compose up -d airman-mcp
# host port 8011 -> container 8001; use the Streamlit "MCP Gateway" step, or
# any MCP client (Claude Desktop, Cursor, etc.) via http://localhost:8011/mcp
```

## The seeded story, for your own reference while presenting

- **Tue 2026-07-14, 13:00-18:00, Jebel Ali:** gate turn times spike ~42-55%
  above baseline; rehandles spike in the same window. Root cause: vessel
  "Neptune Voyager" overran berth 2 by six hours, pulling yard trucks off
  marshalling duty. (Demo 4, and the "before AI" contrast in demo 1's
  framing.)
- **2026-06-26 onward, Jebel Ali crane 2:** hoist-gearbox vibration begins
  drifting above baseline, accelerating sharply in the final 72 hours.
- **Wed 2026-07-15, 22:00:** crane 2's gearbox fails mid-call (working
  vessel "Camden Reach" at berth 2). Same signature as two prior fleet
  failures: WO-4411 (crane 7, London Gateway, 2025-11) and WO-5207 (crane 3,
  Santos, 2026-03). (Demo 1.)
- **Same night:** vessel "Aurora"'s ETA slips 8 hours just as crane 2 goes
  down -- forcing a berth replan onto berth 3 at 04:00 the next morning,
  while "Ionian Star" keeps its original window. (Referenced in demo 4's
  seed data as the berth-schedule record behind the incident.)
- **Days following:** a customer disputes the demurrage charge tied to that
  delay, alongside three unrelated billing disputes (duplicate charge,
  weighbridge discrepancy, damage claim). (Demo 3.)

## Starting over

```bash
docker compose down -v   # -v also drops the edb-data volume
docker compose up -d --build
```

## Repository layout

```
search-demo-code/
├── docker-compose.yml, Dockerfile, docker-entrypoint*.sh   -- shared substrate, plus the additive airman-mcp service (MCP Gateway)
├── sql/
│   ├── 01-init.sql              -- creates mydb, installs aidb/pgvector/pgfs
│   ├── 02-aidb-models.sql       -- registers my_embedder / my_summarizer
│   ├── 03-terminal-schema.sql   -- terminal operational tables (NEW)
│   └── 04-terminal-seed.sql     -- synthetic seed data, incident week (NEW)
├── docs/                        -- unstructured content for Enterprise Search to ingest
│   ├── wo-4411-crane7-lgw-gearbox.md
│   ├── wo-5207-crane3-ssz-gearbox.md
│   ├── wo-6688-crane2-jea-gearbox.md
│   └── sop-quay-crane-vibration-response.md
├── scripts/                      -- ingest.sh / ask.sh / chunk.py, unchanged
├── demos/
│   ├── 01-enterprise-search/README.md
│   ├── 02-ops-copilot/{README.md, ops_copilot.sql}
│   ├── 03-app-intelligence/{README.md, app_intelligence.sql}
│   └── 04-text-to-insights/{README.md, ask_terminal.sql}
└── frontend/                     -- Streamlit app covering all 5 capabilities (NEW)
    ├── app.py
    ├── airman_client.py         -- minimal MCP Streamable HTTP client (NEW)
    ├── requirements.txt
    └── README.md
```

## Notes / assumptions to double-check on your machine

- The base image's default cluster owner is `enterprisedb` (`$HOME =
  /home/enterprisedb`), matching the original manual install steps. If your
  actual image differs, adjust `HOME`/`PGDATA` in the Dockerfile.
- `initdb` with no special flags creates Postgres-mode (superuser
  `postgres`, database `postgres`), per EDB's own docs.
- The build uses a BuildKit secret (`--mount=type=secret`) so your EDB
  token never lands in an image layer. Requires Docker Desktop's default
  BuildKit builder (on by default in recent versions).
- `sql/04-terminal-seed.sql` generates ~300K synthetic `container_moves`
  rows purely so demo 2 (Ops Copilot) has a genuinely unindexed table to
  diagnose. If first boot feels slow, that INSERT is why -- it's still
  seconds, not minutes, on a laptop.
