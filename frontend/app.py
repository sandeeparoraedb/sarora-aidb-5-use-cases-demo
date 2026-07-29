"""
EDB Postgres AI -- NorthStar Terminals demo frontend (guided-flow edition).

A single lightweight Streamlit app that walks through all five AI Factory
capability demos as one connected narrative -- the same incident week at
Jebel Ali -- rather than five independent tabs. Every AI-driven answer is
shown alongside the exact aidb/SQL call that produced it and the
business problem it addresses, so the story stays grounded in what's
actually running inside Postgres.

Connects directly to the local Postgres instance started by
`docker compose up -d` (port 5432 on localhost) -- there is no separate
backend/API layer, Streamlit talks straight to the database.

Run:
    pip install -r requirements.txt
    streamlit run app.py

Then open the URL Streamlit prints (usually http://localhost:8501).
"""

import ast
import os
import json
from pathlib import Path

import pandas as pd
import psycopg2
import psycopg2.extras
import streamlit as st

from airman_client import AirmanClient, AirmanMCPError

# Branded for NorthStar Terminals -- the underlying seeded data,
# table names and incident narrative are unchanged; only the outer chrome
# (title, header, logo, "Powered by" badge) reflects the terminal brand.
COMPANY_NAME = "NorthStar Terminals"
LOGO_PATH = Path(__file__).parent / "assets" / "edb_postgres_ai_logo.png"

st.set_page_config(page_title=f"{COMPANY_NAME} -- AI Operations", layout="wide", page_icon="\U0001F6A2")

CSS = """
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;600;700&display=swap">
<style>
.dpw-usecase, .dpw-brief, .brand-title, .bridge, .sidebar-component-group {
    font-family: 'Roboto', sans-serif;
}
.dpw-usecase {
    background: rgba(20, 184, 166, 0.08);
    border-left: 4px solid #14b8a6;
    padding: 0.85rem 1.1rem;
    border-radius: 6px;
    margin: 0.6rem 0 1rem 0;
    font-size: 21px;
    line-height: 1.5;
}
.dpw-usecase .label {
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-size: 0.7rem;
    color: #94a3b8;
    margin-bottom: 0.25rem;
}
.dpw-usecase .persona {
    font-weight: 600;
    color: #5eead4;
}
.dpw-brief {
    color: #cbd5e1;
    font-size: 21px;
    line-height: 1.5;
    margin: 0.2rem 0 0.9rem 0;
}
.chip-row {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin: 0.4rem 0 1.1rem 0;
}
.chip {
    display: inline-block;
    background: #1e293b;
    border: 1px solid #334155;
    color: #cbd5e1;
    padding: 0.18rem 0.65rem;
    border-radius: 999px;
    font-size: 0.76rem;
    font-family: "SFMono-Regular", Consolas, monospace;
}
.chip-label {
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #94a3b8;
    margin-right: 0.4rem;
    align-self: center;
}
.bridge {
    border-top: 1px dashed #334155;
    margin-top: 1.4rem;
    padding-top: 0.8rem;
    color: #94a3b8;
    font-style: italic;
    font-size: 0.9rem;
}
.livebar {
    background: #16232f;
    border: 1px solid #14b8a6;
    border-radius: 6px;
    padding: 0.5rem 0.9rem;
    font-size: 0.82rem;
    color: #5eead4;
    margin-bottom: 1rem;
}
.livebar b { color: #2dd4bf; }
.brand-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 0.2rem;
}
.brand-title {
    font-size: 2.1rem;
    font-weight: 800;
    color: #e2e8f0;
    letter-spacing: -0.01em;
}
.powered-by-badge {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    background: #16232f;
    border: 1px solid #334155;
    border-radius: 8px;
    padding: 0.4rem 0.85rem;
    white-space: nowrap;
}
.powered-by-badge .pb-label {
    font-size: 0.68rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #2dd4bf;
    line-height: 1.1;
}
.sidebar-component-group {
    margin-bottom: 0.9rem;
}
.sidebar-component-group .sc-label {
    font-size: 0.72rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #14b8a6;
    font-weight: 600;
    margin-bottom: 0.3rem;
}
.sidebar-component-group .sc-item {
    font-size: 0.8rem;
    color: #cbd5e1;
    margin: 0.1rem 0;
    line-height: 1.35;
}
.sidebar-component-group .sc-item b { color: #e2e8f0; }
</style>
"""
st.markdown(CSS, unsafe_allow_html=True)


# ── Connection ───────────────────────────────────────────────────────────
# Cached so we don't open a fresh Postgres connection on every button click --
# Streamlit reruns the whole script on every interaction. Cache key is the
# connection params, so changing anything in the sidebar opens a new one.

@st.cache_resource(show_spinner="Connecting...")
def get_connection(host, port, dbname, user, password):
    conn = psycopg2.connect(
        host=host, port=port, dbname=dbname, user=user, password=password,
        connect_timeout=5,
    )
    conn.autocommit = False
    return conn


def run(conn, sql, params=None, fetch=True, commit=False):
    """Execute a statement and optionally return rows as a list of dicts."""
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql, params)
        rows = cur.fetchall() if fetch and cur.description else None
    if commit:
        conn.commit()
    return rows


@st.cache_data(ttl=30, show_spinner=False)
def live_status(_conn):
    """A real, live snapshot of the database -- proof this is a running
    Postgres instance, not a canned/mocked demo. Cached briefly so it
    doesn't re-run heavy counts on every single button click."""
    row = run(_conn, """
        SELECT
            (SELECT extversion FROM pg_extension WHERE extname = 'aidb') AS aidb_version,
            (SELECT extversion FROM pg_extension WHERE extname = 'vector') AS pgvector_version,
            (SELECT count(*) FROM container_moves) AS container_moves,
            (SELECT count(*) FROM work_orders) AS work_orders,
            (SELECT count(*) FROM billing_events WHERE dispute_flag) AS open_disputes,
            (SELECT count(*) FROM policies WHERE status = 'ingested') AS ingested_chunks,
            now() AS ts;
    """)[0]
    return row


# ── Sidebar: connection ──────────────────────────────────────────────────
with st.sidebar:
    st.markdown("### Connection")
    host = st.text_input("Host", value=os.environ.get("PGHOST", "localhost"))
    port = st.text_input("Port", value=os.environ.get("PGPORT", "5432"))
    dbname = st.text_input("Database", value=os.environ.get("PGDATABASE", "mydb"))
    user = st.text_input("User", value=os.environ.get("PGUSER", "postgres"))
    password = st.text_input(
        "Password", value=os.environ.get("PGPASSWORD", ""), type="password",
        help="Same value you put in .env as POSTGRES_PASSWORD",
    )
    st.caption("Defaults match this repo's docker-compose.yml. Change these "
               "only if you edited that file.")
    if st.button("Reconnect"):
        get_connection.clear()
        live_status.clear()
        st.rerun()

try:
    conn = get_connection(host, port, dbname, user, password)
    st.sidebar.success("Connected")
except Exception as e:
    st.sidebar.error(f"Could not connect: {e}")
    st.error(
        "Can't reach Postgres. Make sure `docker compose up -d` is running "
        "in search-demo-code/, and that the password above matches your .env."
    )
    st.stop()

with st.sidebar:
    st.markdown("### About this demo")
    st.caption(
        "All four panels run against one live EDB Postgres AI instance -- "
        "no mocked data, no cached answers. Every AI action shows the exact "
        "SQL/aidb call that produced it under **Show the SQL behind this**."
    )

    st.markdown("### Platform components")
    st.markdown(
        """<div class="sidebar-component-group">
            <div class="sc-label">Extensions</div>
            <div class="sc-item"><b>aidb</b> -- EDB's in-database AI extension; every
                decode_text() / retrieve_text() call in this demo runs through it</div>
            <div class="sc-item"><b>pgvector</b> -- embedding storage + similarity search
                behind Enterprise Search</div>
            <div class="sc-item"><b>pgfs</b> -- filesystem access used to ingest docs/
                straight into Postgres</div>
        </div>
        <div class="sidebar-component-group">
            <div class="sc-label">Knowledge bases</div>
            <div class="sc-item"><b>policies</b> -- ingested crane/asset maintenance
                documents, chunked and embedded for Enterprise Search</div>
            <div class="sc-item"><b>business_glossary</b> -- canonical term definitions
                grounding Ask the Terminal's NL-to-SQL</div>
        </div>
        <div class="sidebar-component-group">
            <div class="sc-label">Pipelines</div>
            <div class="sc-item">Ingest -> chunk -> embed -> <b>policies</b>
                (Enterprise Search)</div>
            <div class="sc-item">Question -> decode_text() -> guarded SQL -> execute
                (Ask the Terminal)</div>
            <div class="sc-item">Scan -> diagnose -> human approve/reject -> measured
                benefit (Ops Copilot, App Intelligence)</div>
        </div>
        <div class="sidebar-component-group">
            <div class="sc-label">MCP Gateway</div>
            <div class="sc-item"><b>pg-airman-mcp</b> -- open-source Postgres MCP server;
                exposes this instance to any MCP client over Streamable HTTP</div>
            <div class="sc-item">Restricted (read-only) access mode + purpose logging +
                session token tracing, visible live in pg_stat_activity</div>
        </div>""",
        unsafe_allow_html=True,
    )


# ── Title + live verification banner ─────────────────────────────────────
import base64  # noqa: E402

_logo_b64 = base64.b64encode(LOGO_PATH.read_bytes()).decode() if LOGO_PATH.exists() else ""
_company_mark = "\U0001F6A2 "

st.markdown(
    f"""<div class="brand-header">
        <div class="brand-title">{_company_mark}{COMPANY_NAME}</div>
        <div class="powered-by-badge">
            <div class="pb-label">Powered by</div>
            {'<img src="data:image/png;base64,' + _logo_b64 + '" height="22" />' if _logo_b64 else '<b>EDB Postgres AI</b>'}
        </div>
    </div>""",
    unsafe_allow_html=True,
)
st.caption(
    "One incident week at the Jebel Ali terminal, told through four AI Factory "
    "capabilities running on EDB Postgres AI. Step through in order, or jump to any step below."
)

try:
    status = live_status(conn)
    st.markdown(
        f"""<div class="livebar">
        &#9679; <b>Live</b> connection to Postgres &middot; database <b>{dbname}</b>
        &middot; aidb <b>{status['aidb_version']}</b> &middot; pgvector <b>{status['pgvector_version']}</b>
        &middot; <b>{status['container_moves']:,}</b> container moves &middot;
        <b>{status['work_orders']}</b> work orders &middot;
        <b>{status['open_disputes']}</b> open disputes &middot;
        <b>{status['ingested_chunks']}</b> doc chunks ingested
        &middot; as of {status['ts'].strftime('%H:%M:%S')}
        </div>""",
        unsafe_allow_html=True,
    )
except Exception as e:
    st.warning(f"Could not fetch live status (schema may not be installed yet): {e}")


# ── Step metadata ─────────────────────────────────────────────────────────
STEPS = [
    {
        "key": "ask",
        "num": 1,
        "title": "Ask the Terminal",
        "subtitle": "Text-to-Insights over structured operational data",
        "brief": (
            "Ask a plain-English operational question. The system grounds it against a "
            "business glossary, turns it into governed SQL with aidb.decode_text(), runs it "
            "safely, and returns a sourced answer in seconds -- no BI ticket, no waiting on "
            "a data team."
        ),
        "persona": "Ana, terminal ops manager",
        "problem": (
            "A cross-module operational question -- why did gate turn times spike, and did "
            "it cost berth productivity -- takes a terminal ops manager three hours and four "
            "separate systems to answer today."
        ),
        "components": [
            "aidb.decode_text() · NL-to-SQL", "business_glossary grounding",
            "is_safe_select() guardrail", "Dynamic SQL EXECUTE",
            "OpenRouter: gpt-4o-mini",
        ],
        "bridge": (
            "That question was about structured operational data across systems -- but the "
            "crane-2 failure behind Wednesday night's incident needs a different kind of "
            "search entirely: free-text maintenance history. That's Enterprise Search."
        ),
    },
    {
        "key": "search",
        "num": 2,
        "title": "Enterprise Search",
        "subtitle": "Predictive Maintenance",
        "brief": (
            "Search the fleet's maintenance history in plain English. aidb embeds the "
            "question, pgvector retrieves the most relevant work orders, and "
            "aidb.decode_text() summarizes the pattern across them -- surfacing a recurring "
            "failure signature nobody had manually connected."
        ),
        "persona": "Priya, maintenance planner",
        "problem": (
            "When a crane fails, “have we seen this before” gets answered by someone "
            "manually searching free-text work orders across whatever fleet history they "
            "can find or remember. Three prior failures share the same vibration-drift "
            "signature across three different terminals, and nobody had connected them."
        ),
        "components": [
            "aidb extension", "pgvector", "AI Pipelines · KnowledgeBase",
            "aidb.retrieve_text()", "aidb.decode_text()",
            "OpenRouter: text-embedding-3-small + gpt-4o-mini",
        ],
        "bridge": (
            "This same crane-2 gearbox failure is the root cause behind one of the billing "
            "disputes App Intelligence triages later -- but first, a look at how well the "
            "platform itself holds up under this kind of query load. That's Ops Copilot."
        ),
    },
    {
        "key": "dba",
        "num": 3,
        "title": "Ops Copilot",
        "subtitle": "Proactively find, tune, and prove the benefit of slow queries",
        "brief": (
            "No query typed by hand: a live EXPLAIN ANALYZE scan ranks real operational "
            "queries by actual execution time, aidb.decode_text() proposes a fix, and "
            "nothing changes in the schema until a human approves it -- then the same "
            "query is re-measured to prove the benefit."
        ),
        "persona": "DBA / platform team",
        "problem": (
            f"Nobody at {COMPANY_NAME} proactively watches for the queries about to become "
            "a performance ticket -- a lookup that used to be instant quietly turns into a "
            "full table scan as volume grows, and it's only noticed once it's already slow "
            "in production."
        ),
        "components": [
            "EXPLAIN ANALYZE", "aidb.decode_text()", "PL/pgSQL procedures",
            "Human-in-the-loop approval + reject gate", "OpenRouter: gpt-4o-mini",
        ],
        "bridge": (
            "With that index in place, the same proactive, no-manual-input pattern -- scan, "
            "diagnose, human approve/reject -- turns to a costlier target: billing errors "
            "nobody has caught yet. That's App Intelligence."
        ),
    },
    {
        "key": "app_intel",
        "num": 4,
        "title": "App Intelligence",
        "subtitle": "Catch billing errors before they cost money",
        "brief": (
            "No customer complaint required: a live scan checks every invoice against "
            "contracted tariff rates and recent charge history, aidb.decode_text() explains "
            "the anomaly in plain business language, and a human approves or rejects the "
            "fix -- with the real dollar benefit captured immediately."
        ),
        "persona": "Billing / finance analyst",
        "problem": (
            "Billing errors at NorthStar Terminals are only ever found the way the demurrage "
            "dispute tied to the Aurora berth replan was: a customer notices and complains. "
            "Nobody proactively checks whether an invoice was actually billed at the "
            "contracted rate, so both overcharges and undercharges sit quietly until "
            "reconciliation -- or until a customer's finance team catches it first."
        ),
        "components": [
            "Proactive rate/duplicate scan (SQL)", "aidb.decode_text() · diagnosis",
            "Human-in-the-loop approval + reject gate", "Deterministic masking + AI redaction",
            "ai_audit_log", "OpenRouter: gpt-4o-mini",
        ],
        "bridge": None,
    },
    {
        "key": "mcp_gateway",
        "num": 5,
        "title": "MCP Gateway",
        "subtitle": "Bring your own AI client, governed and audited",
        "brief": (
            "pg-airman-mcp exposes this same Postgres instance over MCP -- the open "
            "standard AI clients use to reach tools and data -- running in restricted "
            "(read-only) mode. Every connection is tagged with a purpose and a session ID "
            "that shows up live in pg_stat_activity, so any AI-originated query stays "
            "attributable after the fact, no custom integration required."
        ),
        "persona": "Security & platform lead",
        "problem": (
            "Every capability so far was purpose-built into this app. But teams also want "
            "to point general-purpose AI tools -- Claude, Cursor, an internal agent -- "
            "straight at production data, and today that usually means either a custom "
            "integration per tool or handing out broad, unaudited database credentials."
        ),
        "components": [
            "pg-airman-mcp · Streamable HTTP", "Restricted (read-only) access mode",
            "Purpose logging + session tracing", "aidb semantic KB · fleet_ops_kb",
            "pg_stat_activity governance trace",
        ],
        "bridge": None,
    },
]
STEP_BY_KEY = {s["key"]: s for s in STEPS}


def brief_box(step):
    st.markdown(f'<div class="dpw-brief">{step["brief"]}</div>', unsafe_allow_html=True)


def usecase_box(step):
    st.markdown(
        f"""<div class="dpw-usecase">
        <div class="label">Business problem this solves</div>
        <span class="persona">{step['persona']}</span> &mdash; {step['problem']}
        </div>""",
        unsafe_allow_html=True,
    )


def component_chips(step):
    chips = "".join(f'<span class="chip">{c}</span>' for c in step["components"])
    st.markdown(
        f'<div class="chip-row"><span class="chip-label">Powered by</span>{chips}</div>',
        unsafe_allow_html=True,
    )


def bridge_note(step):
    if step["bridge"]:
        st.markdown(f'<div class="bridge">→ {step["bridge"]}</div>', unsafe_allow_html=True)


# ── Stepper navigation ────────────────────────────────────────────────────
if "step" not in st.session_state:
    st.session_state.step = 1

nav_cols = st.columns(len(STEPS))
for i, s in enumerate(STEPS):
    with nav_cols[i]:
        label = f"{s['num']}. {s['title']}"
        if st.button(label, key=f"nav_{s['key']}", use_container_width=True,
                     type="primary" if st.session_state.step == s["num"] else "secondary"):
            st.session_state.step = s["num"]
            st.rerun()

st.progress(st.session_state.step / len(STEPS))
st.write("")

current = STEP_BY_KEY[[s for s in STEPS if s["num"] == st.session_state.step][0]["key"]]


def nav_footer(step_num):
    cols = st.columns([1, 1, 6])
    with cols[0]:
        if step_num > 1 and st.button("← Back", key=f"back_{step_num}"):
            st.session_state.step = step_num - 1
            st.rerun()
    with cols[1]:
        if step_num < len(STEPS) and st.button("Continue →", key=f"fwd_{step_num}"):
            st.session_state.step = step_num + 1
            st.rerun()


# ── Step 1: Enterprise Search ─────────────────────────────────────────────
if current["key"] == "search":
    st.subheader(f"{current['num']}. {current['title']} — {current['subtitle']}")
    usecase_box(current)
    brief_box(current)
    component_chips(current)

    default_q = (
        "Crane 2's hoist gearbox failed last night showing a vibration trend "
        "in the weeks before -- have we seen this failure signature before, "
        "and what did we do about it?"
    )
    question = st.text_area("Question", value=default_q, height=90, key="es_q")
    # "Chunks to retrieve" slider hidden for now per request -- fixed at a
    # sensible default instead of exposed as a control. Re-add
    # `top_k = st.slider("Chunks to retrieve", 1, 10, 5, key="es_k")` to bring it back.
    top_k = 5

    search_sql = """
        SELECT aidb.decode_text('my_summarizer',
            'Answer the question using only the context below. If the '
            'context does not contain the answer, say so.

Question: ' || %s || '

Context:
' ||
            (SELECT string_agg(value, E'\\n---\\n')
             FROM aidb.retrieve_text('policies_kb', %s, %s))
        ) AS answer;
    """

    if st.button("Search", key="es_btn", type="primary"):
        try:
            rows = run(conn, search_sql, (question, question, top_k))
            st.markdown("**Answer**")
            st.write(rows[0]["answer"])
            st.session_state["es_last_q"] = question
            st.session_state["es_last_k"] = top_k
        except Exception as e:
            conn.rollback()
            st.error(f"Query failed: {e}")

    if st.session_state.get("es_last_q"):
        with st.expander("Show the SQL behind this — proof this ran inside Postgres"):
            st.code(search_sql.strip(), language="sql")
            st.caption(
                "aidb.retrieve_text() does a pgvector similarity search over embeddings "
                "aidb.encode_text() generated when the docs were ingested; aidb.decode_text() "
                "then summarizes the retrieved chunks -- all in one SQL statement, no "
                "application code in between."
            )
            raw = run(conn, "SELECT * FROM aidb.retrieve_text('policies_kb', %s, %s);",
                      (st.session_state["es_last_q"], st.session_state["es_last_k"]))
            st.markdown("**Raw retrieval (`aidb.retrieve_text`)**")
            st.dataframe(pd.DataFrame(raw))

    bridge_note(current)
    nav_footer(current["num"])


# ── Step 2: Ops Copilot ───────────────────────────────────────────────────
elif current["key"] == "dba":
    st.subheader(f"{current['num']}. {current['title']} — {current['subtitle']}")
    usecase_box(current)
    brief_box(current)
    component_chips(current)

    st.markdown(
        "Scans a watchlist of real operational queries, measures each one live with "
        "`EXPLAIN ANALYZE`, and ranks them worst-first -- no query typed in by hand. The "
        "top 3 go to the in-database model for diagnosis; each fix only runs once you "
        "explicitly approve, and approving immediately re-measures the same query to "
        "prove the benefit."
    )

    if st.button("Scan for tuning candidates", key="ops_scan_btn", type="primary"):
        try:
            rows = run(conn, "SELECT * FROM ops_copilot_scan() ORDER BY exec_ms DESC;")
            st.session_state["ops_scan"] = rows
            st.session_state.pop("ops_rec_ids", None)
        except Exception as e:
            conn.rollback()
            st.error(f"Scan failed: {e}")

    scan = st.session_state.get("ops_scan")
    if scan:
        top3, rest = scan[:3], scan[3:]

        st.markdown("**Top 3 tuning candidates** (ranked by real, measured execution time)")
        st.dataframe(pd.DataFrame([
            {"label": r["label"], "query": r["query_text"], "exec_ms": r["exec_ms"]} for r in top3
        ]))
        if rest:
            with st.expander(f"Also scanned, already healthy ({len(rest)})"):
                st.dataframe(pd.DataFrame([
                    {"label": r["label"], "query": r["query_text"], "exec_ms": r["exec_ms"]} for r in rest
                ]))

        if st.button("Diagnose top 3 with AI", key="ops_diagnose_btn", type="primary"):
            rec_ids = dict(st.session_state.get("ops_rec_ids") or {})
            try:
                for r in top3:
                    if r["watchlist_id"] in rec_ids:
                        continue  # already diagnosed this scan -- don't file a duplicate
                    rows = run(conn, "SELECT ops_copilot_diagnose(%s, %s) AS id;",
                               (r["query_text"], r["label"]), commit=True)
                    rec_ids[r["watchlist_id"]] = rows[0]["id"]
                st.session_state["ops_rec_ids"] = rec_ids
            except Exception as e:
                conn.rollback()
                st.error(f"Diagnosis failed: {e}")

        rec_ids = st.session_state.get("ops_rec_ids")
        if rec_ids:
            reviewer = st.text_input("Your name (for the audit trail)", value="", key="ops_reviewer")
            st.write("")

            for i, r in enumerate(top3):
                rec_id = rec_ids.get(r["watchlist_id"])
                if not rec_id:
                    continue
                rec = run(conn, "SELECT * FROM ops_recommendations WHERE id = %s;", (rec_id,))[0]
                st.markdown(f"---\n**#{rec_id} — {rec['label']}** — status: `{rec['status']}`")
                st.write(rec["diagnosis"])
                st.code(rec["recommended_ddl"] or "(none captured)", language="sql")

                with st.expander(f"Show the SQL behind recommendation #{rec_id} — the exact query, plan, and prompt"):
                    st.markdown("**Query that was diagnosed**")
                    st.code(rec["query_text"], language="sql")
                    st.markdown("**EXPLAIN ANALYZE plan the AI actually saw**")
                    st.code(rec["explain_plan"], language="text")
                    st.caption(
                        "The diagnosis and recommended_ddl above came from two aidb.decode_text() "
                        "calls made against this exact query + plan -- see the full "
                        "ops_copilot_diagnose() source under 'Show the SQL behind this — all "
                        "recommendations on file' below for the literal prompts used."
                    )

                if rec["status"] == "pending_approval":
                    acol1, acol2 = st.columns(2)
                    with acol1:
                        if st.button("Approve and apply", key=f"ops_approve_btn_{i}",
                                     disabled=not reviewer, type="primary"):
                            try:
                                run(conn, "CALL ops_copilot_approve(%s, %s);", (rec_id, reviewer),
                                    fetch=False, commit=True)
                                st.rerun()
                            except Exception as e:
                                conn.rollback()
                                st.error(f"Approval failed: {e}")
                    with acol2:
                        if st.button("Reject", key=f"ops_reject_btn_{i}", disabled=not reviewer):
                            run(conn, "CALL ops_copilot_reject(%s, %s);", (rec_id, reviewer),
                                fetch=False, commit=True)
                            st.rerun()
                elif rec["status"] == "applied":
                    before_ms, after_ms = rec["before_ms"], rec["after_ms"]
                    if before_ms and after_ms and before_ms > 0:
                        improvement = round((before_ms - after_ms) / before_ms * 100, 1)
                        mcol1, mcol2, mcol3 = st.columns(3)
                        mcol1.metric("Before", f"{before_ms:g} ms")
                        mcol2.metric("After", f"{after_ms:g} ms", delta=f"-{improvement}%")
                        mcol3.metric("Reviewed by", rec["reviewed_by"] or "—")
                        st.caption(
                            "Before/after are two real EXPLAIN ANALYZE runs of the exact same "
                            "query, captured automatically by ops_copilot_approve() the moment "
                            "the index was created -- not an estimate."
                        )
                    else:
                        st.success(f"Applied by {rec['reviewed_by']}.")
                elif rec["status"] == "rejected":
                    st.info(f"Rejected by {rec['reviewed_by']} -- nothing was changed.")

    with st.expander("Show the SQL behind this — watchlist and all recommendations on file"):
        st.caption(
            "ops_copilot_scan() measures every query below live via EXPLAIN ANALYZE on each "
            "click -- nothing is pre-labeled slow. ops_copilot_diagnose() calls "
            "aidb.decode_text() twice (plain-English diagnosis, then a DDL-only extraction) "
            "and never alters the schema itself -- only ops_copilot_approve() runs the actual "
            "CREATE INDEX (and immediately re-measures), and only after this table shows a "
            "human reviewer's name."
        )
        st.markdown("**The watchlist Ops Copilot scans**")
        st.dataframe(pd.DataFrame(run(conn,
            "SELECT id, label, query_text FROM ops_copilot_watchlist ORDER BY id;"
        )))

        st.markdown("**Every recommendation on file** (query diagnosed, plan, and outcome)")
        st.dataframe(pd.DataFrame(run(conn,
            "SELECT id, label, status, query_text, recommended_ddl, before_ms, after_ms, "
            "reviewed_by, reviewed_at FROM ops_recommendations ORDER BY id DESC;"
        )))

        st.markdown(
            "**The live PL/pgSQL source of `ops_copilot_diagnose()`** -- pulled straight from "
            "Postgres's own catalog via `pg_get_functiondef()`, not a copy pasted into this app, "
            "so it's guaranteed to match what actually ran:"
        )
        try:
            fn_src = run(conn,
                "SELECT pg_get_functiondef('ops_copilot_diagnose(text,text)'::regprocedure) AS src;"
            )[0]["src"]
            st.code(fn_src, language="sql")
        except Exception as e:
            conn.rollback()
            st.error(f"Could not fetch function source: {e}")

    bridge_note(current)
    nav_footer(current["num"])


# ── Step 3: App Intelligence ──────────────────────────────────────────────
elif current["key"] == "app_intel":
    st.subheader(f"{current['num']}. {current['title']} — {current['subtitle']}")
    usecase_box(current)
    brief_box(current)
    component_chips(current)

    st.markdown(
        "Scans every billing line item against contracted tariff rates and recent charge "
        "history, and flags what's wrong before a customer ever complains -- no manual input, "
        "ranked worst-first by dollar impact. Each fix only runs once a human approves it, and "
        "approving immediately shows the real credit issued or revenue recovered."
    )

    if st.button("Scan for billing anomalies", key="ai_scan_btn", type="primary"):
        try:
            rows = run(conn, "SELECT * FROM app_intel_scan();")
            st.session_state["ai_scan"] = rows
            st.session_state.pop("ai_rec_ids", None)
        except Exception as e:
            conn.rollback()
            st.error(f"Scan failed: {e}")

    approved_total = run(conn,
        "SELECT COALESCE(sum(applied_credit_usd), 0) AS total, count(*) AS n "
        "FROM app_intel_recommendations WHERE status = 'approved';"
    )[0]
    if approved_total["n"]:
        st.metric("Billing leakage caught so far", f"${approved_total['total']:,.2f}",
                   help=f"Sum of applied_credit_usd across {approved_total['n']} approved recommendation(s).")

    scan = st.session_state.get("ai_scan")
    if scan is not None and len(scan) == 0:
        # app_intel_scan() excludes any invoice_id already in app_intel_recommendations,
        # so a real, successful scan can legitimately return zero *new* rows once every
        # seeded anomaly has already been flagged in a prior run. Without this branch the
        # button looked like it silently did nothing -- this is the fix for that.
        pending_n = run(conn,
            "SELECT count(*) AS n FROM app_intel_recommendations WHERE status = 'pending';"
        )[0]["n"]
        if pending_n:
            st.info(
                f"No *new* anomalies -- all seeded candidates are already flagged and waiting "
                f"for review below ({pending_n} pending). Open “Show the SQL behind this” "
                f"below or scroll down to act on them."
            )
        else:
            st.success("No anomalies found -- every invoice is within contracted tariff and no duplicates detected.")
    elif scan:
        st.markdown(f"**{len(scan)} anomaly candidate(s)** (ranked by real dollar variance vs. contracted rate)")
        st.dataframe(pd.DataFrame([
            {"invoice_id": r["invoice_id"], "type": r["anomaly_type"], "customer": r["customer_name"],
             "tariff_code": r["tariff_code"], "billed_usd": r["billed_usd"],
             "expected_usd": r["expected_usd"], "variance_usd": r["variance_usd"]}
            for r in scan
        ]))

        if st.button("Diagnose all with AI", key="ai_diagnose_btn", type="primary"):
            rec_ids = dict(st.session_state.get("ai_rec_ids") or {})
            try:
                for r in scan:
                    if r["invoice_id"] in rec_ids:
                        continue  # already diagnosed this scan -- don't file a duplicate
                    rows = run(conn, "SELECT (app_intel_diagnose(%s)->>'recommendation_id')::bigint AS id;",
                               (r["invoice_id"],), commit=True)
                    rec_ids[r["invoice_id"]] = rows[0]["id"]
                st.session_state["ai_rec_ids"] = rec_ids
            except Exception as e:
                conn.rollback()
                st.error(f"Diagnosis failed: {e}")

        rec_ids = st.session_state.get("ai_rec_ids")
        if rec_ids:
            reviewer = st.text_input("Your name (for the audit trail)", value="", key="ai_reviewer")
            st.write("")

            for i, r in enumerate(scan):
                rec_id = rec_ids.get(r["invoice_id"])
                if not rec_id:
                    continue
                rec = run(conn, "SELECT * FROM app_intel_recommendations WHERE id = %s;", (rec_id,))[0]
                st.markdown(f"---\n**#{rec_id} — {rec['invoice_id']} ({r['customer_name']})** — status: `{rec['status']}`")
                st.write(rec["diagnosis"])
                st.caption(rec["recommended_action"])

                with st.expander(f"Show the SQL behind #{rec_id} — the exact evidence and why it's flagged"):
                    if rec["anomaly_type"] == "rate_deviation":
                        evidence_sql = (
                            "SELECT be.invoice_id, be.terminal_id, be.tariff_code, be.amount_usd AS billed_usd,\n"
                            "       tr.standard_rate_usd, abs(be.amount_usd - tr.standard_rate_usd) AS variance_usd,\n"
                            "       GREATEST(50, tr.standard_rate_usd * 0.15) AS flag_threshold_usd\n"
                            "FROM billing_events be\n"
                            "JOIN tariff_rates tr ON tr.terminal_id = be.terminal_id AND tr.tariff_code = be.tariff_code\n"
                            f"WHERE be.invoice_id = '{rec['invoice_id']}';"
                        )
                        st.code(evidence_sql, language="sql")
                        evidence = run(conn, evidence_sql)[0]
                        st.dataframe(pd.DataFrame([evidence]))

                        variance = float(evidence["billed_usd"]) - float(evidence["standard_rate_usd"])
                        direction = "overcharged" if variance > 0 else "undercharged"
                        pct = abs(variance) / float(evidence["standard_rate_usd"]) * 100 if evidence["standard_rate_usd"] else 0
                        st.caption(
                            f"Plain English: the contracted rate for tariff code {evidence['tariff_code']} at "
                            f"terminal {evidence['terminal_id']} is ${float(evidence['standard_rate_usd']):,.2f}. "
                            f"This invoice billed ${float(evidence['billed_usd']):,.2f} -- a "
                            f"${abs(variance):,.2f} ({pct:.0f}%) {direction} -- which exceeds the flag threshold "
                            f"of ${float(evidence['flag_threshold_usd']):,.2f} (the greater of $50 or 15% of the "
                            f"standard rate). That threshold, not a guess, is why the scan caught this one and "
                            f"not the ~55 correctly-billed invoices around it."
                        )
                    elif rec["anomaly_type"] == "duplicate_charge":
                        evidence_sql = (
                            "SELECT b1.invoice_id AS earlier_invoice, b1.created_ts AS earlier_ts, b1.amount_usd AS earlier_amount,\n"
                            "       b2.invoice_id AS later_invoice, b2.created_ts AS later_ts, b2.amount_usd AS later_amount,\n"
                            "       b1.container_id, b1.move_type, b1.tariff_code\n"
                            "FROM billing_events b1\n"
                            "JOIN billing_events b2\n"
                            "  ON b1.terminal_id = b2.terminal_id AND b1.container_id = b2.container_id\n"
                            " AND b1.move_type = b2.move_type AND b1.tariff_code = b2.tariff_code\n"
                            " AND b1.invoice_id < b2.invoice_id\n"
                            f"WHERE b2.invoice_id = '{rec['invoice_id']}';"
                        )
                        st.code(evidence_sql, language="sql")
                        evidence = run(conn, evidence_sql)[0]
                        st.dataframe(pd.DataFrame([evidence]))

                        days_apart = (evidence["later_ts"] - evidence["earlier_ts"]).days
                        st.caption(
                            f"Plain English: invoice {evidence['later_invoice']} bills the exact same container "
                            f"({evidence['container_id']}), move type ({evidence['move_type']}), and tariff code "
                            f"({evidence['tariff_code']}) as invoice {evidence['earlier_invoice']}, billed "
                            f"{days_apart} day(s) earlier for the same ${float(evidence['earlier_amount']):,.2f}. "
                            f"Two charges for what looks like one physical container move -- that's the pattern "
                            f"the scan matches on, not a guess."
                        )
                    st.caption(
                        "This is the same query app_intel_scan() runs across every invoice -- re-run here "
                        "scoped to this one invoice so the evidence is visibly real, not asserted."
                    )

                if rec["status"] == "pending":
                    acol1, acol2 = st.columns(2)
                    with acol1:
                        if st.button("Approve and apply", key=f"ai_approve_btn_{i}",
                                     disabled=not reviewer, type="primary"):
                            try:
                                run(conn, "SELECT app_intel_approve(%s, %s);", (rec_id, reviewer), commit=True)
                                st.rerun()
                            except Exception as e:
                                conn.rollback()
                                st.error(f"Approval failed: {e}")
                    with acol2:
                        if st.button("Reject", key=f"ai_reject_btn_{i}", disabled=not reviewer):
                            run(conn, "SELECT app_intel_reject(%s, %s);", (rec_id, reviewer), commit=True)
                            st.rerun()
                elif rec["status"] == "approved":
                    benefit = rec["applied_credit_usd"] or 0
                    label = "Credit issued" if benefit >= 0 else "Revenue recovered"
                    mcol1, mcol2, mcol3 = st.columns(3)
                    mcol1.metric("Billed", f"${rec['billed_usd']:,.2f}")
                    mcol2.metric("Corrected to", f"${rec['expected_usd']:,.2f}")
                    mcol3.metric(label, f"${abs(benefit):,.2f}")
                    st.caption(f"Reviewed by {rec['reviewed_by']}. billing_events.amount_usd is untouched -- "
                               f"the correction lives in corrected_usd, so the original bill is always auditable.")
                elif rec["status"] == "rejected":
                    st.info(f"Rejected by {rec['reviewed_by']} -- nothing was changed in billing_events.")

    with st.expander("How this stays safe — masking, redaction, known disputes, and the audit log"):
        st.caption(
            "The anomaly scan above is the proactive, revenue-focused half of App Intelligence. "
            "This is the governance half: every one of those AI calls -- and everything below -- "
            "runs inside Postgres and is logged, so PII never has to leave the database to get an "
            "AI answer."
        )

        st.markdown("**Masked view** (what a support agent without billing-PII access sees)")
        st.dataframe(pd.DataFrame(run(conn,
            "SELECT invoice_id, customer_contact_masked, dispute_category FROM billing_events_masked "
            "WHERE dispute_flag ORDER BY invoice_id;"
        )))

        st.markdown("**AI redaction of unstructured text** (a sample analyst note referencing a real customer contact)")
        sample_text = (
            "Please call our contact Daniel Osei directly on +971 50 123 4567 to "
            "discuss -- we were quoted a 15% rebate on this lane last quarter and "
            "expect the same here."
        )
        free_text = st.text_area("Text to redact", value=sample_text, height=80, key="ai_redact_text")
        if st.button("Redact", key="ai_redact_btn"):
            try:
                rows = run(conn, "SELECT redact_free_text(%s) AS redacted;", (free_text,))
                st.write(rows[0]["redacted"])
            except Exception as e:
                conn.rollback()
                st.error(f"Redaction failed: {e}")

        st.markdown("**Known, customer-reported disputes** (a separate, smaller queue -- already flagged by "
                    "the customer, versus the proactive anomalies above that nobody has complained about yet)")
        if st.button("Run dispute triage (classify + score all open disputes)", key="ai_triage_btn"):
            try:
                run(conn, "CALL run_dispute_triage();", fetch=False, commit=True)
                st.success("Triage complete.")
            except Exception as e:
                conn.rollback()
                st.error(f"Triage failed: {e}")
        st.dataframe(pd.DataFrame(run(conn,
            "SELECT invoice_id, amount_usd, dispute_category, dispute_risk, dispute_risk_rationale "
            "FROM billing_events WHERE dispute_flag ORDER BY invoice_id;"
        )))

        st.markdown("**ai_audit_log** — every AI call above, on what input, when")
        st.dataframe(pd.DataFrame(run(conn,
            "SELECT called_at, function_name, subject_id, output_summary FROM ai_audit_log ORDER BY called_at DESC LIMIT 20;"
        )))

    bridge_note(current)
    nav_footer(current["num"])


# ── Step 4: Ask the Terminal ──────────────────────────────────────────────
elif current["key"] == "ask":
    st.subheader(f"{current['num']}. {current['title']} — {current['subtitle']}")
    usecase_box(current)
    brief_box(current)
    component_chips(current)

    suggestions = [
        "Why did gate turn times spike on Tuesday afternoon, and did it cost us berth productivity?",
        "Which vessel call caused that, and by how many hours did it overrun its plan?",
        "Has berth 2 had an extended call like this before this month?",
        "How much revenue is currently disputed across open invoices, and what's the highest-risk one?",
    ]
    def _apply_suggestion():
        # st.text_area's `value=` argument is only honored the FIRST time a
        # widget with a given `key` is created -- on every rerun after that,
        # Streamlit restores the widget's own remembered state and ignores
        # `value=` entirely. Since ask_q has a fixed key, just changing
        # `default_q` below silently did nothing after the first render --
        # picking a new suggestion never updated the Question box. Writing
        # directly into st.session_state["ask_q"] from the selectbox's
        # on_change callback is the correct way to push a new value into an
        # already-created keyed widget.
        sel = st.session_state["ask_suggestion"]
        st.session_state["ask_q"] = "" if sel == "(write my own)" else sel

    st.selectbox(
        "Try a suggested question, or write your own below",
        ["(write my own)"] + suggestions,
        key="ask_suggestion",
        on_change=_apply_suggestion,
    )
    ask_q = st.text_area("Question", height=80, key="ask_q")

    if st.button("Ask", key="ask_btn", type="primary") and ask_q.strip():
        try:
            rows = run(conn, "SELECT * FROM ask_terminal(%s);", (ask_q,), commit=True)
            row = rows[0]
            st.session_state["ask_last_result"] = dict(row)
        except Exception as e:
            conn.rollback()
            st.error(f"ask_terminal failed: {e}")

    if st.session_state.get("ask_last_result"):
        row = st.session_state["ask_last_result"]
        st.markdown("**Answer**")
        st.write(row["answer"])
        with st.expander("Show the SQL behind this — generated SQL + raw result"):
            st.caption(
                "This SQL was written by aidb.decode_text() from your plain-English question "
                "and the business glossary below -- then checked by is_safe_select() (read-"
                "only, single SELECT, no dangerous keywords) before it was ever executed."
            )
            st.markdown("**Generated SQL**")
            st.code(row["generated_sql"], language="sql")
            st.markdown("**Raw result**")
            data = row["result_json"]
            if isinstance(data, str):
                data = json.loads(data)
            if data:
                st.dataframe(pd.json_normalize(data))
            else:
                st.write("(no rows)")

    with st.expander("Business glossary this is grounded in"):
        st.dataframe(pd.DataFrame(run(conn,
            "SELECT term, definition, terminal_variance_note FROM business_glossary ORDER BY term;"
        )))

    with st.expander("Question history"):
        st.dataframe(pd.DataFrame(run(conn,
            "SELECT asked_at, question, generated_sql FROM ask_terminal_log ORDER BY asked_at DESC LIMIT 10;"
        )))

    nav_footer(current["num"])

    st.markdown("---")
    st.markdown("### That's the whole story")
    st.markdown(
        "One incident, one seeded dataset, five AI Factory capabilities -- all running as "
        "SQL (or, for MCP Gateway, an open protocol on top of it) inside a single EDB "
        "Postgres instance:"
    )
    all_components = sorted({c for s in STEPS for c in s["components"]})
    chips = "".join(f'<span class="chip">{c}</span>' for c in all_components)
    st.markdown(f'<div class="chip-row">{chips}</div>', unsafe_allow_html=True)


# ── Step 5: MCP Gateway ───────────────────────────────────────────────────
elif current["key"] == "mcp_gateway":
    st.subheader(f"{current['num']}. {current['title']} — {current['subtitle']}")
    usecase_box(current)
    brief_box(current)
    component_chips(current)

    def get_airman_client():
        if "airman_client" not in st.session_state:
            st.session_state["airman_client"] = AirmanClient()
        return st.session_state["airman_client"]

    client = get_airman_client()

    st.markdown(
        f'<div class="livebar"><b>MCP endpoint</b> {client.base_url} &nbsp;·&nbsp; '
        f'<b>access mode</b> restricted (read-only) &nbsp;·&nbsp; '
        f'<b>purpose</b> fleet-ops-copilot &nbsp;·&nbsp; '
        f'<b>this browser session</b> {client.session_short}</div>',
        unsafe_allow_html=True,
    )
    st.caption(
        "This session's calls go through the same pg-airman-mcp server any MCP client "
        "(Claude Desktop, Cursor, an internal agent) could connect to directly -- the tool "
        "calls below are just standing in for that external client so the demo is "
        "self-contained."
    )

    col_a, col_b = st.columns(2)

    with col_a:
        st.markdown("**Database health check**")
        st.caption("Calls the `analyze_db_health` tool -- no schema knowledge required.")
        if st.button("Check database health", key="mcp_health_btn"):
            try:
                st.session_state["mcp_health_result"] = client.call_tool(
                    "analyze_db_health", {"health_type": "all"}
                )
            except AirmanMCPError as e:
                st.error(str(e))
        if st.session_state.get("mcp_health_result"):
            st.code(st.session_state["mcp_health_result"], language=None)

    with col_b:
        st.markdown("**Semantic schema search**")
        st.caption(
            "Calls `search_kb` against the `fleet_ops_kb` semantic knowledge base -- finds "
            "the tables/columns relevant to a question, without anyone hand-writing SQL."
        )
        kb_query = st.text_input(
            "Natural-language question",
            value="billing disputes and disputed invoices",
            key="mcp_kb_query",
        )
        if st.button("Find matching tables & columns", key="mcp_kb_btn") and kb_query.strip():
            try:
                raw = client.call_tool(
                    "search_kb",
                    {"kb_name": "fleet_ops_kb", "query": kb_query, "min_similarity": 0.3, "limit": 8},
                )
                st.session_state["mcp_kb_result"] = ast.literal_eval(raw) if raw.strip() else []
            except AirmanMCPError as e:
                st.error(str(e))
            except (ValueError, SyntaxError) as e:
                st.error(f"Could not parse search_kb response: {e}")
        if st.session_state.get("mcp_kb_result") is not None:
            rows = st.session_state["mcp_kb_result"]
            if rows:
                st.dataframe(pd.DataFrame(rows))
            else:
                st.write("(no matches above the similarity threshold)")

    with st.expander("Show the governance trace — this session in pg_stat_activity"):
        st.caption(
            "Purpose Logging tags every connection from this Airman instance as "
            "airman:fleet-ops-copilot. Session Token Tracing adds this browser session's "
            "own ID on top, so a DBA can filter pg_stat_activity (or JSON/CSV logs) down to "
            "the exact AI session that ran a given query -- no extra instrumentation in the "
            "client required."
        )
        try:
            trace_rows = run(
                conn,
                "SELECT pid, application_name, state, left(query, 90) AS query "
                "FROM pg_stat_activity WHERE application_name LIKE 'airman:%' ORDER BY pid;",
            )
            st.dataframe(pd.DataFrame(trace_rows))
        except Exception as e:
            conn.rollback()
            st.error(f"Could not read pg_stat_activity: {e}")

    nav_footer(current["num"])
