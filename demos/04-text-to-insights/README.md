# Demo 4 -- Text-to-Insights ("Ask the Terminal")

**EDB capability:** Semantic KB + pgvector + AIDB
**AI Factory framing:** "Non-technical users query Postgres in plain English via text-to-SQL, powered by Semantic KB for domain accuracy. No BI tool required."

## The business problem this solves

Persona: **Ana, terminal ops manager** (UC1 in the seed use-cases deck --
"Ask the Terminal").

This demo recreates the deck's own worked example almost exactly. Monday
7:45am, the Regional COO messages Ana: *"Gate turn times spiked 40% on
Tuesday -- why, and did it cost us berth productivity?"* As-is, per the
deck, that question costs three hours and four systems: the gate module,
the yard module, the berth module, and a phone call to whoever was on
shift -- reconciled by hand in Excel.

The data behind that story is seeded in this repo exactly as described:
Tuesday 2026-07-14, 13:00-18:00 at Jebel Ali, gate turn times ran ~42-55%
above the ~35-minute baseline, rehandles spiked in the same window, and the
root cause was "Neptune Voyager" overrunning berth 2 by six hours and
pulling yard trucks off marshalling duty. `ask_terminal()` answers Ana's
exact question, sourced, in seconds.

## What it demonstrates

- A **business glossary** (`business_glossary`) resolving terminal-specific
  terms -- turn time, dwell, rehandle, demurrage, berth productivity --
  before the model ever writes SQL. This is the deck's own discovery
  question answered concretely: *"Does 'turn time' mean the same at Santos
  and NorthStar Terminals? Resolve terms before the AI answers with them."*
- **Text-to-SQL grounded in that glossary**, not a generic NL-to-SQL prompt
  -- the model is told which tables exist and how NorthStar Terminals defines each
  term before it writes a query.
- A **safety gate** (`is_safe_select()`) that rejects anything that isn't a
  single read-only `SELECT` before it's ever executed -- see the governance
  note below.
- A full **audit trail** (`ask_terminal_log`) of every question asked, the
  SQL generated, and the answer given.

## Running it

Install:

```bash
docker compose exec epas psql -U postgres -d mydb -f /opt/demos/04-text-to-insights/ask_terminal.sql
```

Ask Ana's exact question:

```bash
docker compose exec epas psql -U postgres -d mydb -x -c \
  "SELECT answer, generated_sql FROM ask_terminal('Why did gate turn times spike on Tuesday afternoon, and did it cost us berth productivity?');"
```

(`-x` turns on expanded output so the generated SQL and the answer are both
readable rather than truncated in a table column.)

Good follow-up questions to show the same-thread, no-BI-tool-needed
experience the deck describes:

```bash
docker compose exec epas psql -U postgres -d mydb -x -c \
  "SELECT answer FROM ask_terminal('Which vessel call caused that, and by how many hours did it overrun its plan?');"

docker compose exec epas psql -U postgres -d mydb -x -c \
  "SELECT answer FROM ask_terminal('Has berth 2 had an extended call like this before this month?');"

docker compose exec epas psql -U postgres -d mydb -x -c \
  "SELECT answer FROM ask_terminal('How much revenue is currently disputed across open invoices, and what''s the highest-risk one?');"
```

Show the audit trail:

```bash
docker compose exec epas psql -U postgres -d mydb -c \
  "SELECT asked_at, question, generated_sql FROM ask_terminal_log ORDER BY asked_at DESC LIMIT 5;"
```

## Talking points for the room -- and an honest caveat

- This is the single biggest lift of the four demos, on purpose: it's the
  seed deck's flagship UC1 example, reproduced close to verbatim.
- Be upfront about the gap between this and production: `is_safe_select()`
  is a simple, explainable regex guardrail for a demo. A real deployment
  needs a proper SQL parser/allowlist, row-level security tied to the
  asking user's role, and very likely a human-review step for anything
  beyond routine reporting -- exactly the kind of question the deck's own
  "Which actions need human sign-off?" governance slide raises. Naming that
  gap out loud tends to land better than pretending it doesn't exist.
- The glossary table is small on purpose (~7 terms) -- the real conversation
  with NorthStar Terminals is "which ~10 terms do we need to resolve first," per the
  deck's own recommended next steps ("Draft the glossary -- resolve ~10 key
  terms").
