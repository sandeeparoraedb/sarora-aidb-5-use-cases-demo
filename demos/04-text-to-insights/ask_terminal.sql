-- Text-to-Insights: "Ask the Terminal" -- a plain-English question over
-- structured Zodiac-style tables, grounded by a business glossary,
-- answered via generated SQL that is safety-checked before it ever runs.
--
-- Run once to install:
--   docker compose exec epas psql -U postgres -d mydb -f /opt/demos/04-text-to-insights/ask_terminal.sql

\c mydb

CREATE TABLE IF NOT EXISTS ask_terminal_log (
    id             BIGSERIAL PRIMARY KEY,
    asked_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    question       TEXT NOT NULL,
    generated_sql  TEXT NOT NULL,
    row_count      INT,
    answer         TEXT NOT NULL
);

-- Guardrail before any generated SQL is executed. This is intentionally a
-- simple, explainable check for a demo -- a production deployment would
-- replace this with a proper parser/allowlist (see the README's governance
-- note) -- but it demonstrates the principle the seed deck.s own
-- governance slide asks about: "which actions need human sign-off / what
-- runs automatically."
CREATE OR REPLACE FUNCTION is_safe_select(p_sql TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    -- Note: \y is Postgres's word-boundary escape -- \b means a literal
    -- backspace character in this regex flavor and silently never matches,
    -- which would make the "must be a SELECT" check below always fail
    -- (and reject every query, valid or not).
    SELECT
        p_sql !~ ';'                                            -- no semicolons at all (blocks stacked statements)
        AND p_sql ~* '^\s*(with\y.*\)\s*)?select\y'              -- must be a SELECT, optionally after a leading CTE
        AND p_sql !~* '\y(insert|update|delete|drop|alter|truncate|grant|revoke|create|call|copy|vacuum|do|execute|merge|comment|pg_sleep)\y';
$$;

CREATE OR REPLACE FUNCTION ask_terminal(p_question TEXT)
RETURNS TABLE(answer TEXT, generated_sql TEXT, result_json JSONB)
LANGUAGE plpgsql
AS $$
DECLARE
    v_glossary       TEXT;
    v_schema_context TEXT;
    v_raw_sql        TEXT;
    v_clean_sql      TEXT;
    v_result         JSONB;
    v_answer         TEXT;
BEGIN
    SELECT string_agg(
        '- ' || term || ': ' || definition ||
        coalesce('  (Note: ' || terminal_variance_note || ')', ''),
        E'\n'
    ) INTO v_glossary
    FROM business_glossary;

    -- Includes the *actual* lowercase text values stored in status/category
    -- columns -- without this, the model has no way to know the real casing
    -- (e.g. it will confidently guess 'Completed' when the seed data always
    -- stores 'completed'), and an equality filter on the wrong casing
    -- returns zero rows with no error, which reads as "no data" rather than
    -- the grounding gap it actually is. Telling the model to prefer
    -- case-insensitive comparisons is a second line of defense for any
    -- enum-like column not explicitly listed here.
    v_schema_context :=
           '- terminals(terminal_id, name, country)' || E'\n'
        || '- gate_transactions(terminal_id, truck_id, appointment_ts, gate_in_ts, gate_out_ts, turn_time_minutes, move_type)' || E'\n'
        || '- berth_calls(call_id, terminal_id, vessel_name, berth_id, eta, etd, actual_arrival, actual_departure, cranes_assigned, productivity_moves_per_hr, status, notes)'
        || '  -- status values are lowercase, e.g. ''completed''' || E'\n'
        || '- container_moves(move_id, terminal_id, container_id, move_type, event_ts, yard_block, crane_id, berth_call_id, is_rehandle)' || E'\n'
        || '- crane_telemetry(reading_id, terminal_id, crane_id, ts, vibration_g, temperature_c, load_tonnes)' || E'\n'
        || '- work_orders(wo_id, terminal_id, equipment_id, fault_code, opened_ts, closed_ts, technician_notes, parts_used, labour_hours, status)'
        || '  -- status values are lowercase, e.g. ''open'', ''closed''' || E'\n'
        || '- billing_events(invoice_id, terminal_id, container_id, move_type, tariff_code, amount_usd, dispute_flag, dispute_reason, dispute_category, dispute_risk, created_ts)'
        || '  -- dispute_category/dispute_risk values are capitalized, e.g. ''Demurrage Dispute'', ''Medium''';

    v_raw_sql := aidb.decode_text('my_summarizer',
        'You translate a terminal operations manager''s plain-English question into a single '
        || 'read-only PostgreSQL SELECT statement over the tables listed below. Respond with '
        || 'ONLY the SQL statement: no markdown, no code fences, no commentary, no trailing '
        || 'semicolon, one statement only. Use the business glossary to resolve operational '
        || 'terms precisely before writing the query. Do not guess at dates -- the operational '
        || 'incident this dataset covers happened on Tuesday, 2026-07-14 (with related events in '
        || 'the surrounding days); resolve relative date references ("Tuesday", "that day", '
        || '"this month") against that date, not any other assumption. When filtering on a '
        || 'status/category/label column, match the exact casing shown in the table notes below '
        || 'if given -- otherwise prefer a case-insensitive comparison (ILIKE, or lower(col) = '
        || 'lower(''value'')) over a plain = comparison, since guessing the wrong casing silently '
        || 'returns zero rows instead of an error.'
        || E'\n\nTables:\n' || v_schema_context
        || E'\n\nBusiness glossary:\n' || v_glossary
        || E'\n\nQuestion: ' || p_question
    );

    -- Models sometimes wrap the SQL in a markdown code fence despite being
    -- told not to -- strip that, and any trailing semicolon, defensively.
    v_clean_sql := regexp_replace(trim(v_raw_sql), '^```(sql)?\s*|\s*```$', '', 'gi');
    v_clean_sql := regexp_replace(trim(v_clean_sql), ';\s*$', '');

    IF NOT is_safe_select(v_clean_sql) THEN
        RAISE EXCEPTION 'ask_terminal: generated SQL failed the safety check and was NOT executed: %', v_clean_sql;
    END IF;

    EXECUTE format('SELECT coalesce(jsonb_agg(t), ''[]''::jsonb) FROM (%s) t', v_clean_sql) INTO v_result;

    v_answer := aidb.decode_text('my_summarizer',
        'Answer the question in 2-4 plain-English sentences, using ONLY the JSON query result '
        || 'below as your source of truth -- do not invent any figure not present in it. State '
        || 'which table(s) the numbers came from. If the result is empty, say so plainly.'
        || E'\n\nQuestion: ' || p_question
        || E'\n\nQuery result (JSON):\n' || v_result::TEXT
    );

    INSERT INTO ask_terminal_log (question, generated_sql, row_count, answer)
    VALUES (p_question, v_clean_sql, jsonb_array_length(v_result), v_answer);

    RETURN QUERY SELECT v_answer, v_clean_sql, v_result;
END;
$$;
