-- Ops Copilot: proactively scan a watchlist of representative operational
-- queries, measure their REAL execution cost live, surface the worst as
-- tuning candidates, diagnose them with the in-database model, and --
-- with human approval -- apply the fix and re-measure to prove the benefit.
--
-- Run once to install:
--   docker compose exec epas psql -U postgres -d mydb -f /opt/demos/02-ops-copilot/ops_copilot.sql

\c mydb

-- ── Watchlist ────────────────────────────────────────────────────────────
-- The representative operational queries Ops Copilot watches. Three run
-- against container_moves (seeded to ~300K rows with NO supporting index --
-- see sql/03-terminal-schema.sql) and are genuinely slow; two run against
-- small reference tables and are already fine. ops_copilot_scan() below
-- measures all five live and ranks them -- nothing here is pre-labeled
-- "slow", the ranking is earned by an actual EXPLAIN ANALYZE every time.
CREATE TABLE IF NOT EXISTS ops_copilot_watchlist (
    id         SERIAL PRIMARY KEY,
    label      TEXT NOT NULL,
    query_text TEXT NOT NULL
);

INSERT INTO ops_copilot_watchlist (label, query_text)
SELECT * FROM (VALUES
    ('Container lookup by ID',
     $q$SELECT * FROM container_moves WHERE container_id = 'CONT0001234'$q$),
    ('Recent activity by terminal (7 days)',
     $q$SELECT * FROM container_moves WHERE terminal_id = 'JEA' AND event_ts > now() - interval '7 days' ORDER BY event_ts DESC$q$),
    ('Rehandle volume by crane (30 days)',
     $q$SELECT crane_id, count(*) FROM container_moves WHERE is_rehandle AND event_ts > now() - interval '30 days' GROUP BY crane_id ORDER BY count(*) DESC$q$),
    ('Terminal lookup by code',
     $q$SELECT * FROM terminals WHERE terminal_id = 'JEA'$q$),
    ('Work order lookup by ID',
     $q$SELECT * FROM work_orders WHERE wo_id = 'WO-6688'$q$)
) AS v(label, query_text)
WHERE NOT EXISTS (SELECT 1 FROM ops_copilot_watchlist);

CREATE TABLE IF NOT EXISTS ops_recommendations (
    id                 SERIAL PRIMARY KEY,
    label              TEXT,
    query_text         TEXT NOT NULL,
    explain_plan       TEXT NOT NULL,
    diagnosis          TEXT NOT NULL,
    recommended_ddl    TEXT,
    status             TEXT NOT NULL DEFAULT 'pending_approval',  -- pending_approval | applied | rejected
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_by        TEXT,
    reviewed_at        TIMESTAMPTZ,
    explain_plan_after TEXT,
    before_ms          NUMERIC,
    after_ms           NUMERIC
);

-- Captures the EXPLAIN ANALYZE plan for an arbitrary read-only query as a
-- single text blob (EXPLAIN returns one row per plan line under the
-- "QUERY PLAN" column). The plan text ends with a real "Execution Time: N
-- ms" line -- that's what every timing number in this demo is pulled from.
CREATE OR REPLACE FUNCTION ops_copilot_explain(p_query TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan TEXT := '';
    v_line RECORD;
BEGIN
    FOR v_line IN EXECUTE 'EXPLAIN (ANALYZE, FORMAT TEXT) ' || p_query LOOP
        v_plan := v_plan || v_line."QUERY PLAN" || E'\n';
    END LOOP;
    RETURN v_plan;
END;
$$;

-- Proactive scan: runs every query on the watchlist RIGHT NOW, pulls the
-- real "Execution Time" out of each live EXPLAIN ANALYZE, and returns every
-- candidate ranked worst-first. The app takes the top 3 as "needs tuning"
-- and shows the rest as already healthy -- the AI never invents severity,
-- it measures it.
CREATE OR REPLACE FUNCTION ops_copilot_scan()
RETURNS TABLE(watchlist_id INT, label TEXT, query_text TEXT, exec_ms NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    v_row  RECORD;
    v_plan TEXT;
BEGIN
    FOR v_row IN SELECT w.id, w.label, w.query_text FROM ops_copilot_watchlist w ORDER BY w.id LOOP
        v_plan := ops_copilot_explain(v_row.query_text);
        watchlist_id := v_row.id;
        label        := v_row.label;
        query_text   := v_row.query_text;
        exec_ms      := substring(v_plan FROM 'Execution Time:\s*([0-9.]+) ms')::numeric;
        RETURN NEXT;
    END LOOP;
    RETURN;
END;
$$;

-- Runs the query, asks the in-database model to diagnose the plan and
-- propose an index, and files the recommendation for a human to review.
-- Returns the new ops_recommendations.id. Does NOT create anything itself.
CREATE OR REPLACE FUNCTION ops_copilot_diagnose(p_query TEXT, p_label TEXT DEFAULT NULL)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan      TEXT;
    v_diagnosis TEXT;
    v_ddl       TEXT;
    v_id        INT;
BEGIN
    v_plan := ops_copilot_explain(p_query);

    v_diagnosis := aidb.decode_text('my_summarizer',
        'You are a PostgreSQL performance assistant for a container-terminal '
        || 'operations database. Given the query and its EXPLAIN ANALYZE plan '
        || 'below, explain in plain English, under 120 words: (1) the specific '
        || 'performance problem, (2) which column(s) an index would help, and '
        || '(3) the expected impact. Do not propose DDL syntax here -- that is '
        || 'captured separately.'
        || E'\n\nQuery:\n' || p_query
        || E'\n\nEXPLAIN ANALYZE plan:\n' || v_plan
    );

    v_ddl := aidb.decode_text('my_summarizer',
        'Given this query and EXPLAIN ANALYZE plan, respond with ONLY a single valid '
        || 'PostgreSQL CREATE INDEX statement that would address the problem -- no '
        || 'explanation, no markdown, no code fences, just the SQL statement ending in a '
        || 'semicolon.'
        || E'\n\nQuery:\n' || p_query
        || E'\n\nEXPLAIN ANALYZE plan:\n' || v_plan
    );

    -- Small local models routinely ignore "no explanation, no markdown" and
    -- wrap the statement in prose and/or a ```sql fence anyway. Pull the
    -- actual CREATE INDEX statement out defensively rather than trusting the
    -- instruction was followed literally -- ops_copilot_approve()'s own
    -- guard would otherwise reject every recommendation.
    -- Note: Postgres's regex flavor uses \y for a word boundary, not \b --
    -- \b there means a literal backspace character and silently never
    -- matches, which would make the whole extraction fail.
    v_ddl := coalesce(
        substring(v_ddl FROM '(?i)(CREATE\s+(?:UNIQUE\s+)?INDEX\y[^;]*;)'),
        trim(v_ddl)
    );

    INSERT INTO ops_recommendations (label, query_text, explain_plan, diagnosis, recommended_ddl, status)
    VALUES (p_label, p_query, v_plan, v_diagnosis, v_ddl, 'pending_approval')
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- Human-in-the-loop approval: a reviewer looks at ops_recommendations, and
-- only an explicit call to this procedure actually runs the DDL. Nothing in
-- ops_copilot_diagnose() above can alter the schema on its own. Once
-- applied, this procedure immediately re-runs the SAME query and captures a
-- real before/after execution-time comparison -- the "benefit" shown in the
-- app is a live re-measurement, not an estimate.
CREATE OR REPLACE PROCEDURE ops_copilot_approve(p_id INT, p_reviewer TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_ddl        TEXT;
    v_status     TEXT;
    v_query      TEXT;
    v_before_ms  NUMERIC;
    v_after_plan TEXT;
    v_after_ms   NUMERIC;
BEGIN
    SELECT recommended_ddl, status, query_text,
           substring(explain_plan FROM 'Execution Time:\s*([0-9.]+) ms')::numeric
    INTO v_ddl, v_status, v_query, v_before_ms
    FROM ops_recommendations WHERE id = p_id;

    IF v_ddl IS NULL THEN
        RAISE EXCEPTION 'No recommendation % found', p_id;
    END IF;
    IF v_status <> 'pending_approval' THEN
        RAISE EXCEPTION 'Recommendation % is not pending approval (status: %)', p_id, v_status;
    END IF;
    -- \y is Postgres's word-boundary escape -- \b here would mean a literal
    -- backspace character and never match, rejecting every valid statement.
    IF v_ddl !~* '^\s*CREATE\s+(UNIQUE\s+)?INDEX\y' THEN
        RAISE EXCEPTION 'Refusing to apply -- recommended_ddl does not look like a CREATE INDEX statement: %', v_ddl;
    END IF;

    BEGIN
        EXECUTE v_ddl;
    EXCEPTION
        WHEN duplicate_table THEN
            -- An index by this exact name already exists -- most likely a
            -- repeat diagnose() on the same query during a demo/rehearsal
            -- produced the same natural name again. The desired end state
            -- (an index on this column) already holds, so treat this as a
            -- no-op success rather than a hard failure that looks alarming
            -- live in front of an audience.
            RAISE NOTICE 'Index already existed -- treating recommendation % as already applied.', p_id;
    END;

    -- Prove it: re-run the exact same query and measure it again.
    v_after_plan := ops_copilot_explain(v_query);
    v_after_ms   := substring(v_after_plan FROM 'Execution Time:\s*([0-9.]+) ms')::numeric;

    UPDATE ops_recommendations
    SET status = 'applied', reviewed_by = p_reviewer, reviewed_at = now(),
        explain_plan_after = v_after_plan,
        before_ms = v_before_ms,
        after_ms = v_after_ms
    WHERE id = p_id;
END;
$$;

CREATE OR REPLACE PROCEDURE ops_copilot_reject(p_id INT, p_reviewer TEXT)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE ops_recommendations
    SET status = 'rejected', reviewed_by = p_reviewer, reviewed_at = now()
    WHERE id = p_id AND status = 'pending_approval';
END;
$$;
