# Demo frontend (Streamlit, guided-flow edition)

A single lightweight web app that walks through all four capability demos
as one connected narrative -- the same incident week at Jebel Ali -- rather
than four independent tabs, so you don't have to run `psql` commands live
in front of an audience. It talks directly to the Postgres instance started
by `docker compose up -d` in the parent folder -- no separate backend, no
API layer.

## Prerequisites

- The main stack must already be up: from `search-demo-code/`, run
  `docker compose up -d` and confirm it's healthy (see the top-level
  README). This app is a client of that database, not a replacement for it.
- Python 3.9+ on your Mac.

## Run it

```bash
cd search-demo-code/frontend
pip install -r requirements.txt
streamlit run app.py
```

Streamlit will print a local URL (usually `http://localhost:8501`) --
open it in your browser.

## Connecting

The sidebar defaults match this repo's `docker-compose.yml` (`localhost`,
port `5432`, database `mydb`, user `postgres`). The one field you need to
fill in is **Password** -- use the same `POSTGRES_PASSWORD` you set in
`../.env`. You can also export it before launching so the field pre-fills:

```bash
export PGPASSWORD="the password from your .env"
streamlit run app.py
```

If you restart the Docker containers while the app is open, click
**Reconnect** in the sidebar.

## What's different from a plain tabbed demo

Right below the title, a **live status banner** shows a real, freshly-queried
snapshot of the database (aidb/pgvector versions, row counts, ingested
chunk count) -- proof this is a running Postgres instance responding in
real time, not a canned screen recording or mocked data.

Each of the four steps below it opens with two things, before any button or
input field:

- **Business problem this solves** -- the persona and business problem from
  the top-level README's mapping table, so the audience always knows *why*
  this capability matters to NorthStar Terminals specifically, not just *what* it does.
- **Powered by** -- a row of chips naming the exact aidb functions, Postgres
  extensions, and model calls behind that step (e.g. `aidb.retrieve_text()`,
  `pgvector`, `OpenRouter: gpt-4o-mini`).

Every AI-driven answer also has a **"Show the SQL behind this"** expander --
the literal SQL/aidb call that produced it, plus the raw result set, so
anyone in the room (technical or not) can verify the answer really came from
a live query against this Postgres database, not a hardcoded response.

Step-to-step, a short italicized bridge line explicitly connects what you
just saw to what's coming next (e.g. the crane-2 failure in Enterprise
Search is the same incident behind a billing dispute in App Intelligence),
reinforcing the "one story" framing the source decks ask for. Use the
numbered buttons at the top or **Continue →** at the bottom of each step to
move through it; nothing stops you from jumping around out of order either.

1. **Enterprise Search** -- ask a plain-English question, see the AI's
   sourced answer plus the raw vector-search hits behind it.
2. **Ops Copilot** -- scan a watchlist of real operational queries, see
   the top 3 tuning candidates ranked by actual measured execution time,
   ask the AI to diagnose each and propose an index, then approve (or
   reject) before anything is actually created. Approving re-measures the
   same query automatically and shows the before/after benefit.
   Re-approving a recommendation that names an index that already exists
   (e.g. from an earlier rehearsal) is treated as a no-op success, not an
   error -- see `ops_copilot_approve()`.
3. **App Intelligence** -- run dispute triage over all open billing
   disputes, compare the masked vs. unmasked customer view, and try AI
   redaction on a piece of free text with embedded PII.
4. **Ask the Terminal** -- pick one of the suggested questions (or write
   your own) and get a sourced answer, with the generated SQL and raw
   result available in an expander. Ends with a recap of every EDB
   component used across all four steps.

## Notes

- This app executes real SQL against your local database, including the
  Ops Copilot's `CREATE INDEX` on approval -- it's meant for a live demo
  environment, not a shared/production database.
- Each demo's own README (`../demos/0X-*/README.md`) still has the
  psql-command version of the same walkthrough, useful for the more
  technical parts of the audience or for troubleshooting if something in
  the UI doesn't behave as expected.
