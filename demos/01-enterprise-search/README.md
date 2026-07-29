# Demo 1 -- Enterprise Search

**EDB capability:** AIDB + AI Pipelines + pgvector
**AI Factory framing:** "Find anything across your Postgres data in plain English. Changes to source files and unstructured content automatically sync to vector embeddings." Called out as the easiest first sale.

## The business problem this solves

Persona: **Priya, maintenance planner** (crane & asset health, UC2 in the seed
use-cases deck).

Today, when a crane fails, the "have we seen this before" question is
answered by a human searching free-text notes across whatever fleet history
they can remember or find:

> 08:00 -- Search the work-order archive. Two similar gearbox failures in
> fleet history, same signature. The notes were free text; nobody connected
> them.

That's the exact gap this demo closes. Three maintenance work orders --
**WO-4411** (crane 7, London Gateway, 2025-11), **WO-5207** (crane 3, Santos,
2026-03), and **WO-6688** (crane 2, Jebel Ali, tonight) -- live in
`docs/` as free-text technician narratives, plus a crane vibration-response
SOP. None of them mention each other by name. A plain-language search finds
the pattern instantly, across terminals, without anyone having to remember
which work order to pull.

This is deliberately built as a generic **document/knowledge search**
capability, not a narrow "crane failures only" tool -- the same pipeline
would just as happily index safety bulletins, customs procedures, or
equipment manuals dropped into the same folder. That breadth is the pitch:
one search surface over anything unstructured that lands in Postgres.

## What it demonstrates

- Embeddings generated automatically from markdown dropped into `docs/`
  (`aidb` + `pgvector`, via the `policies_kb` pipeline already wired up in
  this repo).
- No separate vector database, no separate application code for embedding
  or retrieval -- `aidb.retrieve_text()` and `aidb.decode_text()` run
  inside SQL. (By default the actual embedding/generation calls go out to
  OpenRouter rather than running in-process -- see the top-level README --
  but the orchestration, storage, and retrieval never leave Postgres.)
- Re-running ingestion after adding new documents only embeds what's new
  ("Doc Ingestion [AI Pipelines]: auto-embed new docs added to source").

## Running it

```bash
docker compose exec epas /opt/scripts/ingest.sh
```

This ingests everything currently in `docs/`, including the three work
orders and the SOP. Then ask the exact question Priya would ask at 06:30 the
morning after a failure:

```bash
docker compose exec epas /opt/scripts/ask.sh \
  "Crane 2's hoist gearbox failed last night showing a vibration trend in the weeks before -- have we seen this failure signature before, and what did we do about it?"
```

Expect the answer to surface WO-4411 and WO-5207 by name, with the
vibration-drift-then-acceleration pattern called out, and the corrective
action taken (gearbox + bearing replacement) -- sourced back to the specific
work order, in seconds, instead of "nobody connected them."

Try a raw retrieval call too, to show the underlying vector search before
the summarization step:

```bash
docker compose exec epas psql -U postgres -d mydb -c \
  "SELECT * FROM aidb.retrieve_text('policies_kb', 'gearbox vibration trending up before failure', 5);"
```

## Talking points for the room

- This is the "easiest first sale" use case in the AI Factory training deck
  for a reason: no schema redesign, no new infrastructure, drop files in a
  folder and search them in plain English the same day.
- The value compounds with fleet size and terminal count -- NorthStar Terminals runs
  40+ countries' worth of maintenance history that today lives in
  disconnected, terminal-local free text.
- Point out this is exactly the "free-text match" mechanic called out on the
  UC2 slide (`Sources: crane_telemetry · work_orders (free-text match) ·
  berth_calls`) -- this demo is that mechanic, standalone and runnable today.
