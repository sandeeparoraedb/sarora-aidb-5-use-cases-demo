-- App Intelligence: proactive billing-anomaly detection (scan -> AI
-- diagnosis -> human approve/reject -> measured $ benefit), the same shape
-- as Ops Copilot's scan/diagnose/approve/reject flow, aimed at revenue
-- leakage instead of query latency. Classification, masking, and redaction
-- (below) remain available and back the "how this stays safe" governance
-- callout in the rebuilt flow, with every model call logged to
-- ai_audit_log.
--
-- Idempotent -- safe to re-run any time (this bind-mounts read/write from
-- the host at /opt/demos, so edits take effect on the next re-run with no
-- image rebuild or volume reset needed):
--   docker compose exec epas psql -U postgres -d mydb -f /opt/demos/03-app-intelligence/app_intelligence.sql

\c mydb

ALTER TABLE billing_events ADD COLUMN IF NOT EXISTS dispute_category TEXT;
ALTER TABLE billing_events ADD COLUMN IF NOT EXISTS dispute_risk TEXT;
ALTER TABLE billing_events ADD COLUMN IF NOT EXISTS dispute_risk_rationale TEXT;
-- Set once a proactively-caught anomaly is approved -- the corrected amount
-- and what kind of correction it was (credit issued / revenue recovered /
-- duplicate voided). NULL until then; billing_events.amount_usd itself is
-- never overwritten, so the original bill is always still visible.
ALTER TABLE billing_events ADD COLUMN IF NOT EXISTS corrected_usd NUMERIC;
ALTER TABLE billing_events ADD COLUMN IF NOT EXISTS correction_status TEXT;

-- Governance: every in-database model call this demo makes is logged here --
-- "every agent query and action logged and attributable" per the seed
-- deck's governance discovery slide.
CREATE TABLE IF NOT EXISTS ai_audit_log (
    id             BIGSERIAL PRIMARY KEY,
    called_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    function_name  TEXT NOT NULL,
    model_name     TEXT NOT NULL,
    subject_id     TEXT,
    input_summary  TEXT,
    output_summary TEXT
);

-- ── 1. Classification + risk scoring (the LLM-appropriate tasks) ────────
-- One model call, structured JSON response, applied to a single dispute.
-- Billing/finance analyst persona: "revenue per move, demurrage & penalty
-- exposure, invoice queries" -- this is that triage done automatically as
-- disputes land, instead of an analyst reading every complaint by hand.
CREATE OR REPLACE FUNCTION classify_and_score_dispute(p_invoice_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_reason   TEXT;
    v_amount   NUMERIC;
    v_raw      TEXT;
    v_result   JSONB;
BEGIN
    SELECT dispute_reason, amount_usd INTO v_reason, v_amount
    FROM billing_events WHERE invoice_id = p_invoice_id;

    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'Invoice % has no dispute_reason on file', p_invoice_id;
    END IF;

    v_raw := aidb.decode_text('my_summarizer',
        'Classify this container-terminal billing dispute. Respond with ONLY a single-line '
        || 'JSON object, no markdown, no commentary, matching exactly this shape: '
        || '{"category": "<one of: Demurrage Dispute, Duplicate Charge, Weighbridge Discrepancy, Damage Claim, Other>", '
        || '"risk": "<one of: Low, Medium, High>", '
        || '"rationale": "<one sentence, under 25 words>"}'
        || E'\n\nInvoice amount (USD): ' || v_amount
        || E'\nCustomer dispute text: ' || v_reason
    );

    -- Models sometimes wrap JSON in a markdown code fence despite being told
    -- not to -- strip that defensively before casting.
    v_result := regexp_replace(trim(v_raw), '^```(json)?\s*|\s*```$', '', 'gi')::JSONB;

    UPDATE billing_events
    SET dispute_category = v_result->>'category',
        dispute_risk = v_result->>'risk',
        dispute_risk_rationale = v_result->>'rationale'
    WHERE invoice_id = p_invoice_id;

    INSERT INTO ai_audit_log (function_name, model_name, subject_id, input_summary, output_summary)
    VALUES ('classify_and_score_dispute', 'my_summarizer', p_invoice_id, v_reason, v_raw);

    RETURN v_result;
END;
$$;

-- Batch version: classify every open (unscored) dispute in one call, the
-- way this would actually run -- as a scheduled job or trigger, not
-- one-by-one by an analyst.
CREATE OR REPLACE PROCEDURE run_dispute_triage()
LANGUAGE plpgsql
AS $$
DECLARE
    v_invoice_id TEXT;
BEGIN
    FOR v_invoice_id IN
        SELECT invoice_id FROM billing_events
        WHERE dispute_flag = TRUE AND dispute_category IS NULL
    LOOP
        PERFORM classify_and_score_dispute(v_invoice_id);
    END LOOP;
END;
$$;

-- ── 2. Masking (deterministic -- the right tool for structured PII) ─────
-- Classification and risk-scoring need judgment, so they go through the
-- model. Masking a known, well-formed column like an email address does
-- not -- a deterministic function is faster, free, and 100% consistent, so
-- that's what this uses. (Compare to redact_free_text() below, where the
-- model earns its keep because the PII is buried in unstructured prose.)
CREATE OR REPLACE FUNCTION mask_customer_contact(p_name TEXT, p_email TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        regexp_replace(split_part(p_name, ' ', 1), '(?<=.).', '*', 'g')
        || ' ' ||
        regexp_replace(split_part(p_name, ' ', 2), '(?<=.).', '*', 'g')
        || '  <' ||
        left(split_part(p_email, '@', 1), 1) || repeat('*', greatest(length(split_part(p_email, '@', 1)) - 1, 0))
        || '@' || split_part(p_email, '@', 2) || '>';
$$;

CREATE OR REPLACE VIEW billing_events_masked AS
SELECT
    invoice_id, terminal_id, container_id, move_type, tariff_code, amount_usd,
    mask_customer_contact(customer_name, customer_email) AS customer_contact_masked,
    dispute_flag, dispute_category, dispute_risk, dispute_risk_rationale,
    created_ts
FROM billing_events;

-- ── 3. Redaction of unstructured free text (the AI-appropriate case) ────
-- A customer's written complaint can contain PII the schema never
-- anticipated -- a personal mobile number, a named individual, specifics of
-- a private commercial arrangement. That needs judgment, not a regex.
CREATE OR REPLACE FUNCTION redact_free_text(p_text TEXT, p_invoice_id TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_redacted TEXT;
BEGIN
    v_redacted := aidb.decode_text('my_summarizer',
        'Rewrite the text below, replacing any personal names, direct phone/email contacts, '
        || 'or specific commercial figures (prices, discounts) with [REDACTED], while keeping '
        || 'the substance of the complaint intact and readable. Respond with ONLY the rewritten text.'
        || E'\n\nText:\n' || p_text
    );

    INSERT INTO ai_audit_log (function_name, model_name, subject_id, input_summary, output_summary)
    VALUES ('redact_free_text', 'my_summarizer', p_invoice_id, p_text, v_redacted);

    RETURN v_redacted;
END;
$$;

-- ── 4. Proactive anomaly detection: scan -> diagnose -> approve/reject ──
-- This is the "catch billing errors before they cost money" mechanism --
-- unlike run_dispute_triage() above (which only classifies invoices a
-- customer already complained about), this finds billing errors nobody
-- has flagged yet, before they hit reconciliation.

-- Contracted/standard rate per terminal + tariff code. The scan's baseline
-- for "is this invoice priced right" -- ground truth, not a heuristic.
CREATE TABLE IF NOT EXISTS tariff_rates (
    terminal_id       TEXT NOT NULL REFERENCES terminals,
    tariff_code       TEXT NOT NULL,
    standard_rate_usd NUMERIC NOT NULL,
    PRIMARY KEY (terminal_id, tariff_code)
);

INSERT INTO tariff_rates (terminal_id, tariff_code, standard_rate_usd) VALUES
('JEA', 'DEM-STD', 620.00),
('JEA', 'STD-EXP', 540.00),
('JEA', 'STD-IMP', 480.00),
('JEA', 'WGT-ADJ', 310.00),
('JEA', 'DMG-HDL', 275.00),
('JEA', 'REHANDLE', 90.00)
ON CONFLICT DO NOTHING;

-- Every proactively-caught anomaly, its AI diagnosis, and its resolution --
-- mirrors ops_recommendations' shape (pending -> approved/rejected), but
-- the payoff column is a dollar benefit instead of a millisecond delta.
CREATE TABLE IF NOT EXISTS app_intel_recommendations (
    id                 BIGSERIAL PRIMARY KEY,
    invoice_id         TEXT NOT NULL REFERENCES billing_events(invoice_id),
    anomaly_type       TEXT NOT NULL,       -- 'rate_deviation' | 'duplicate_charge'
    billed_usd         NUMERIC NOT NULL,
    expected_usd       NUMERIC NOT NULL,
    variance_usd       NUMERIC NOT NULL,    -- billed - expected (signed: + overbilled, - underbilled); full amount for duplicates
    diagnosis          TEXT,
    recommended_action TEXT,
    status             TEXT NOT NULL DEFAULT 'pending',  -- pending | approved | rejected
    applied_credit_usd NUMERIC,
    reviewed_by         TEXT,
    detected_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at         TIMESTAMPTZ
);
ALTER TABLE app_intel_recommendations ADD COLUMN IF NOT EXISTS reviewed_by TEXT;

-- Background volume of ordinary, correctly-billed invoices (May-July 2026)
-- so the anomalies below have real statistical company to hide in --
-- proactive detection means nothing if there are only 7 rows and the
-- audience can already eyeball which ones are wrong.
INSERT INTO billing_events (invoice_id, terminal_id, container_id, move_type, tariff_code, amount_usd, customer_name, customer_email, dispute_flag, dispute_reason, created_ts)
SELECT
    'INV-' || (89000 + g)::text,
    'JEA',
    'CONTJEA' || lpad((1000 + g)::text, 4, '0'),
    m.move_type, m.tariff_code, m.rate,
    c.customer_name, c.customer_email,
    FALSE, NULL,
    ('2026-05-01 08:00+04'::timestamptz + (g * interval '30 hours'))
FROM generate_series(1, 55) AS g
CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
        ('discharge', 'STD-IMP', 480.00),
        ('load',      'STD-EXP', 540.00),
        ('yard_shift','REHANDLE', 90.00),
        ('discharge', 'WGT-ADJ', 310.00),
        ('discharge', 'DMG-HDL', 275.00)
    ) AS t(move_type, tariff_code, rate)
    OFFSET (g % 5) LIMIT 1
) m
CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
        ('Desert Star Logistics LLC',     'youssef.haddad@desertstarlogistics.example'),
        ('Continental Freight Partners',  'meilin.tan@continentalfreight.example'),
        ('Al Noor Shipping Agency',       'sara.idris@alnoorshipping.example'),
        ('TransGlobal Cargo',             'diego.fernandez@transglobalcargo.example'),
        ('Meridian Ocean Traders',        'amara.okafor@meridianocean.example')
    ) AS t(customer_name, customer_email)
    OFFSET (g % 5) LIMIT 1
) c
ON CONFLICT DO NOTHING;

-- Deliberately planted anomalies -- none of these are customer-flagged
-- disputes (dispute_flag stays FALSE), because the whole point is that
-- nobody has complained about them yet. The scan below has to find them.
INSERT INTO billing_events (invoice_id, terminal_id, container_id, move_type, tariff_code, amount_usd, customer_name, customer_email, dispute_flag, dispute_reason, created_ts) VALUES
-- Overbilled demurrage -- a peak-season surcharge that should have expired.
('INV-89100', 'JEA', 'CONTJEA2001', 'discharge', 'DEM-STD', 890.00,
 'Meridian Ocean Traders', 'amara.okafor@meridianocean.example',
 FALSE, NULL, '2026-06-10 10:00+04'),
-- Duplicate charge -- same container/move/tariff billed twice, a day apart.
('INV-89101', 'JEA', 'CONTJEA2002', 'load', 'STD-EXP', 540.00,
 'TransGlobal Cargo', 'diego.fernandez@transglobalcargo.example',
 FALSE, NULL, '2026-06-18 09:00+04'),
('INV-89102', 'JEA', 'CONTJEA2002', 'load', 'STD-EXP', 540.00,
 'TransGlobal Cargo', 'diego.fernandez@transglobalcargo.example',
 FALSE, NULL, '2026-06-19 09:00+04'),
-- Underbilled import move -- the other direction of leakage: revenue the
-- terminal is owed and hasn't collected.
('INV-89103', 'JEA', 'CONTJEA2003', 'discharge', 'STD-IMP', 340.00,
 'Al Noor Shipping Agency', 'sara.idris@alnoorshipping.example',
 FALSE, NULL, '2026-06-25 14:00+04'),
-- Overbilled weighbridge adjustment.
('INV-89104', 'JEA', 'CONTJEA2004', 'discharge', 'WGT-ADJ', 505.00,
 'Desert Star Logistics LLC', 'youssef.haddad@desertstarlogistics.example',
 FALSE, NULL, '2026-07-02 11:00+04'),
-- Overbilled rehandle -- looks like a double-counted move.
('INV-89105', 'JEA', 'CONTJEA2005', 'yard_shift', 'REHANDLE', 180.00,
 'Continental Freight Partners', 'meilin.tan@continentalfreight.example',
 FALSE, NULL, '2026-07-10 16:00+04')
ON CONFLICT DO NOTHING;

-- Proactive, no-manual-input scan: rate deviations (vs. contracted tariff_rates)
-- and duplicate charges, ranked by dollar impact -- the same "measure first,
-- no guessing" pattern as ops_copilot_scan(), aimed at revenue instead of ms.
CREATE OR REPLACE FUNCTION app_intel_scan()
RETURNS TABLE(
    invoice_id TEXT, anomaly_type TEXT, billed_usd NUMERIC, expected_usd NUMERIC,
    variance_usd NUMERIC, terminal_id TEXT, tariff_code TEXT, customer_name TEXT
)
LANGUAGE sql
AS $$
    SELECT be.invoice_id, 'rate_deviation'::text AS anomaly_type, be.amount_usd AS billed_usd,
           tr.standard_rate_usd AS expected_usd,
           abs(be.amount_usd - tr.standard_rate_usd) AS variance_usd,
           be.terminal_id, be.tariff_code, be.customer_name
    FROM billing_events be
    JOIN tariff_rates tr ON tr.terminal_id = be.terminal_id AND tr.tariff_code = be.tariff_code
    WHERE be.dispute_flag = FALSE
      AND abs(be.amount_usd - tr.standard_rate_usd) > GREATEST(50, tr.standard_rate_usd * 0.15)
      AND NOT EXISTS (SELECT 1 FROM app_intel_recommendations r WHERE r.invoice_id = be.invoice_id)

    UNION ALL

    SELECT b2.invoice_id, 'duplicate_charge'::text AS anomaly_type, b2.amount_usd AS billed_usd,
           0::numeric AS expected_usd,
           b2.amount_usd AS variance_usd, b2.terminal_id, b2.tariff_code, b2.customer_name
    FROM billing_events b1
    JOIN billing_events b2
      ON b1.terminal_id = b2.terminal_id AND b1.container_id = b2.container_id
     AND b1.move_type = b2.move_type AND b1.tariff_code = b2.tariff_code
     AND b1.invoice_id < b2.invoice_id
     AND abs(extract(epoch FROM (b2.created_ts - b1.created_ts))) < 14 * 86400
    WHERE b2.dispute_flag = FALSE
      AND NOT EXISTS (SELECT 1 FROM app_intel_recommendations r WHERE r.invoice_id = b2.invoice_id)

    ORDER BY variance_usd DESC
    LIMIT 10;
$$;

-- AI diagnosis for one flagged invoice -- explains the anomaly in plain
-- business language and records a pending recommendation for human
-- approve/reject. One model call, logged to ai_audit_log like every other
-- AI touch in this demo.
CREATE OR REPLACE FUNCTION app_intel_diagnose(p_invoice_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_terminal     TEXT;
    v_tariff       TEXT;
    v_customer     TEXT;
    v_container    TEXT;
    v_move_type    TEXT;
    v_billed       NUMERIC;
    v_expected     NUMERIC;
    v_variance     NUMERIC;
    v_anomaly_type TEXT;
    v_dup_invoice  TEXT;
    v_mech_action  TEXT;
    v_raw          TEXT;
    v_diagnosis    JSONB;
    v_rec_id       BIGINT;
BEGIN
    SELECT terminal_id, tariff_code, customer_name, container_id, move_type, amount_usd
      INTO v_terminal, v_tariff, v_customer, v_container, v_move_type, v_billed
      FROM billing_events WHERE invoice_id = p_invoice_id;

    IF v_terminal IS NULL THEN
        RAISE EXCEPTION 'Invoice % not found', p_invoice_id;
    END IF;

    SELECT b1.invoice_id INTO v_dup_invoice
    FROM billing_events b1
    WHERE b1.terminal_id = v_terminal AND b1.tariff_code = v_tariff
      AND b1.container_id = v_container AND b1.move_type = v_move_type
      AND b1.invoice_id < p_invoice_id
    LIMIT 1;

    IF v_dup_invoice IS NOT NULL THEN
        v_anomaly_type := 'duplicate_charge';
        v_expected := 0;
        v_variance := v_billed;
        v_mech_action := format('Void %s as a duplicate of %s and credit the customer $%s.', p_invoice_id, v_dup_invoice, v_billed);
    ELSE
        SELECT standard_rate_usd INTO v_expected FROM tariff_rates WHERE terminal_id = v_terminal AND tariff_code = v_tariff;
        v_variance := v_billed - v_expected;
        v_anomaly_type := 'rate_deviation';
        v_mech_action := CASE WHEN v_variance > 0
            THEN format('Overbilled by $%s vs. the standard %s rate ($%s) -- issue a credit down to $%s.', v_variance, v_tariff, v_expected, v_expected)
            ELSE format('Underbilled by $%s vs. the standard %s rate ($%s) -- recover the shortfall, correcting the invoice to $%s.', abs(v_variance), v_tariff, v_expected, v_expected)
        END;
    END IF;

    v_raw := aidb.decode_text('my_summarizer',
        'You are a billing/finance analyst copilot reviewing a container-terminal invoice anomaly '
        || 'that an automated scan caught before the customer ever disputed it. In 1-2 sentences '
        || '(under 40 words total), explain why this is worth correcting, in plain business '
        || 'language, then restate the recommended action clearly. Respond with ONLY a single-line '
        || 'JSON object, no markdown, no commentary, matching exactly this shape: '
        || '{"diagnosis": "...", "recommended_action": "..."}'
        || E'\n\nInvoice: ' || p_invoice_id
        || E'\nCustomer: ' || v_customer
        || E'\nTariff code: ' || v_tariff
        || E'\nBilled amount (USD): ' || v_billed
        || E'\nExpected/standard amount (USD): ' || v_expected
        || E'\nAnomaly type: ' || v_anomaly_type
        || E'\nMechanical recommendation: ' || v_mech_action
    );

    v_diagnosis := regexp_replace(trim(v_raw), '^```(json)?\s*|\s*```$', '', 'gi')::JSONB;

    INSERT INTO app_intel_recommendations
        (invoice_id, anomaly_type, billed_usd, expected_usd, variance_usd, diagnosis, recommended_action, status)
    VALUES
        (p_invoice_id, v_anomaly_type, v_billed, v_expected, v_variance,
         COALESCE(v_diagnosis->>'diagnosis', v_mech_action),
         COALESCE(v_diagnosis->>'recommended_action', v_mech_action), 'pending')
    RETURNING id INTO v_rec_id;

    INSERT INTO ai_audit_log (function_name, model_name, subject_id, input_summary, output_summary)
    VALUES ('app_intel_diagnose', 'my_summarizer', p_invoice_id, v_mech_action, v_raw);

    RETURN jsonb_build_object(
        'recommendation_id', v_rec_id, 'invoice_id', p_invoice_id, 'anomaly_type', v_anomaly_type,
        'billed_usd', v_billed, 'expected_usd', v_expected, 'variance_usd', v_variance,
        'diagnosis', COALESCE(v_diagnosis->>'diagnosis', v_mech_action),
        'recommended_action', COALESCE(v_diagnosis->>'recommended_action', v_mech_action)
    );
END;
$$;

-- Human-in-the-loop: apply the correction (issue a credit, recover a
-- shortfall, or void a duplicate) and record the real $ benefit realized --
-- nothing changes in billing_events until a human approves it here.
DROP FUNCTION IF EXISTS app_intel_approve(BIGINT);
DROP FUNCTION IF EXISTS app_intel_reject(BIGINT);

CREATE OR REPLACE FUNCTION app_intel_approve(p_id BIGINT, p_reviewer TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_invoice  TEXT;
    v_anomaly  TEXT;
    v_billed   NUMERIC;
    v_expected NUMERIC;
    v_variance NUMERIC;
    v_status   TEXT;
BEGIN
    SELECT invoice_id, anomaly_type, billed_usd, expected_usd, variance_usd, status
      INTO v_invoice, v_anomaly, v_billed, v_expected, v_variance, v_status
      FROM app_intel_recommendations WHERE id = p_id;

    IF v_invoice IS NULL THEN
        RAISE EXCEPTION 'Recommendation % not found', p_id;
    END IF;
    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'Recommendation % is already %, not pending', p_id, v_status;
    END IF;

    IF v_anomaly = 'duplicate_charge' THEN
        UPDATE billing_events SET corrected_usd = 0, correction_status = 'voided_duplicate' WHERE invoice_id = v_invoice;
    ELSE
        UPDATE billing_events SET corrected_usd = v_expected, correction_status = 'corrected' WHERE invoice_id = v_invoice;
    END IF;

    UPDATE app_intel_recommendations
    SET status = 'approved', applied_credit_usd = v_variance, reviewed_by = p_reviewer, resolved_at = now()
    WHERE id = p_id;

    INSERT INTO ai_audit_log (function_name, model_name, subject_id, input_summary, output_summary)
    VALUES ('app_intel_approve', 'system', v_invoice,
            format('billed $%s vs. expected $%s (reviewer: %s)', v_billed, v_expected, p_reviewer),
            format('approved -- $%s benefit realized', v_variance));

    RETURN jsonb_build_object('invoice_id', v_invoice, 'billed_usd', v_billed,
                              'expected_usd', v_expected, 'benefit_usd', v_variance);
END;
$$;

-- Reject gate -- leaves billing_events completely untouched, same
-- guarantee Ops Copilot gives for schema changes.
CREATE OR REPLACE FUNCTION app_intel_reject(p_id BIGINT, p_reviewer TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE app_intel_recommendations SET status = 'rejected', reviewed_by = p_reviewer, resolved_at = now()
    WHERE id = p_id AND status = 'pending';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recommendation % not found or not pending', p_id;
    END IF;

    INSERT INTO ai_audit_log (function_name, model_name, subject_id, input_summary, output_summary)
    VALUES ('app_intel_reject', 'system', (SELECT invoice_id FROM app_intel_recommendations WHERE id = p_id),
            format('human reviewer %s rejected the recommendation', p_reviewer), 'no change made to billing_events');
END;
$$;
