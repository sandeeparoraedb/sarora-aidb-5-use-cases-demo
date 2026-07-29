# Demo 2 -- Ops Copilot

**EDB capability:** AI Sidecar + AIDB
**AI Factory framing:** "AI proactively scans for tuning candidates, explains slow queries, and recommends a fix, with human approval before anything changes -- then proves the benefit."

## The problem this solves

Persona: **NorthStar Terminals' DBA / platform team.**

Nobody proactively looks for the queries about to become a problem --
performance tickets get filed only after a lookup that used to be instant
starts timing out in production. Per the AI Factory deck: *"Our DBAs spend
half their time on performance tickets."* Ops Copilot flips that: it
watches a set of representative operational queries, measures them live,
and surfaces the ones that need attention before they turn into a ticket.

This demo runs that scan against `container_moves` (seeded with ~300K
historical rows and, deliberately, no supporting index) alongside two
small reference-table lookups that are already fine -- so the "top 3"
worth tuning are a real, measured result, not a scripted list.

## What it demonstrates

- **Proactive identification, not a manual query box.** `ops_copilot_scan()`
  runs a live `EXPLAIN ANALYZE` against every query on the watchlist right
  now and ranks them by actual execution time -- the app takes the worst 3
  as "needs tuning" and shows the rest as already healthy.
- In-database diagnosis: each candidate's plan is read and summarized in
  plain English by the in-database model, with no data or query plan ever
  leaving Postgres.
- A concrete `CREATE INDEX` recommendation per candidate, captured
  separately from the narrative explanation.
- **Human approval before any change executes, with a reject path** --
  `ops_copilot_diagnose()` only ever inserts a row into
  `ops_recommendations`. Nothing is created until a reviewer explicitly
  runs `ops_copilot_approve()` (which double-checks the recommendation
  actually looks like a `CREATE INDEX` statement before running it), or
  `ops_copilot_reject()` to decline it -- no schema change either way
  without that explicit call.
- **Proof of benefit, automatically.** The instant `ops_copilot_approve()`
  applies the index, it re-runs the exact same query and captures a real
  before/after execution-time comparison (`before_ms` / `after_ms` on
  `ops_recommendations`) -- the improvement shown is a live re-measurement,
  not an estimate.

## Running it

Install the functions once:

```bash
docker compose exec epas psql -U postgres -d mydb -f /opt/demos/02-ops-copilot/ops_copilot.sql
```

1. **Scan for tuning candidates:**

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT * FROM ops_copilot_scan() ORDER BY exec_ms DESC;"
   ```

   The three `container_moves` queries should sort to the top (dozens to
   hundreds of ms on a real sequential scan across ~300K rows); the two
   reference-table lookups should sort to the bottom (sub-millisecond,
   already indexed by primary key).

2. **Ask the copilot to diagnose the worst one:**

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT ops_copilot_diagnose('SELECT * FROM container_moves WHERE container_id = ''CONT0001234''', 'Container lookup by ID');"
   ```

   Note the returned `id` (e.g. `1`). Repeat for the other two candidates
   from the scan to build out all three recommendations.

3. **Review the recommendation** -- this is the "surfaced for human
   approval" step:

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT id, label, diagnosis, recommended_ddl, status FROM ops_recommendations WHERE id = 1;"
   ```

4. **Approve it** (swap `1` for your id, and use your own name/handle):

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c \
     "CALL ops_copilot_approve(1, 'sandeep.arora');"
   ```

5. **See the benefit** -- `before_ms` vs. `after_ms` is captured
   automatically by the approval procedure itself:

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT label, before_ms, after_ms, round((before_ms - after_ms) / before_ms * 100, 1) AS improvement_pct FROM ops_recommendations WHERE id = 1;"
   ```

To show the rejection path instead of approval, run
`CALL ops_copilot_reject(<id>, '<reviewer>');` at step 4 -- the
recommendation is marked `rejected` and nothing is touched (no
before/after measurement is taken either, since nothing changed).

## Talking points for the room

- Nothing here required exporting a query plan to an external tuning tool
  or opening a ticket with a DBA-as-a-service vendor -- it ran where the
  data and the query already live.
- Lead with "proactive": this isn't waiting for someone to type in a slow
  query, it's a standing watchlist that gets measured on demand (and could
  be scheduled) -- the AI surfaces the priority order, a human decides.
- The approval gate is the point: this is designed to be shown to a
  DBA/platform-admin buyer specifically because "runs on existing Postgres,
  approval before any change, no disruption to current workloads" is
  exactly what that persona needs to hear.
- The benefit number is earned, not claimed -- it's a second live
  `EXPLAIN ANALYZE` against the same query, not a marketing estimate.
