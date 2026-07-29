-- NorthStar Terminals operations schema.
-- Runs once, on first cluster initialization only (see Dockerfile: sql/ is
-- copied to /docker-entrypoint-initdb.d/ and executed in filename order).
--
-- Mirrors the "Data Map" in the seed use-cases deck (slide 19):
-- container moves, gate transactions, berth schedule, crane telemetry (IoT),
-- maintenance work orders, and billing events -- the entities Zodiac already
-- generates, now landing on Postgres. Kept intentionally denormalized/simple
-- (text codes instead of foreign-key-heavy dimension tables) so every demo
-- query reads clearly in front of an audience.

\c mydb

-- ── Terminals ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS terminals (
    terminal_id TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    country     TEXT NOT NULL
);

-- ── Berth & vessel schedule (Berth planning module) ─────────────────────
CREATE TABLE IF NOT EXISTS berth_calls (
    call_id                  SERIAL PRIMARY KEY,
    terminal_id              TEXT NOT NULL REFERENCES terminals,
    vessel_name              TEXT NOT NULL,
    berth_id                 TEXT NOT NULL,
    eta                      TIMESTAMPTZ,
    etd                      TIMESTAMPTZ,
    actual_arrival           TIMESTAMPTZ,
    actual_departure         TIMESTAMPTZ,
    cranes_assigned          TEXT,             -- comma-separated crane ids
    productivity_moves_per_hr NUMERIC,
    status                   TEXT NOT NULL DEFAULT 'scheduled',  -- scheduled | in_progress | completed | delayed | replanned
    notes                    TEXT
);

-- ── Gate transactions (Gate control module) ─────────────────────────────
CREATE TABLE IF NOT EXISTS gate_transactions (
    txn_id            SERIAL PRIMARY KEY,
    terminal_id       TEXT NOT NULL REFERENCES terminals,
    truck_id          TEXT NOT NULL,
    appointment_ts    TIMESTAMPTZ,
    gate_in_ts        TIMESTAMPTZ NOT NULL,
    gate_out_ts       TIMESTAMPTZ NOT NULL,
    turn_time_minutes NUMERIC NOT NULL,
    move_type         TEXT NOT NULL  -- import_pickup | export_drop | empty_return
);

-- ── Container moves & tracking (Container tracking module) ──────────────
-- Bulk-seeded to realistic volume in 04-terminal-seed.sql so the DBA Copilot
-- demo has a genuine "seq scan over hundreds of thousands of rows" problem
-- to diagnose -- deliberately created with NO index on container_id or
-- event_ts.
CREATE TABLE IF NOT EXISTS container_moves (
    move_id       BIGSERIAL PRIMARY KEY,
    terminal_id   TEXT NOT NULL REFERENCES terminals,
    container_id  TEXT NOT NULL,
    move_type     TEXT NOT NULL,   -- discharge | load | yard_shift | rehandle
    event_ts      TIMESTAMPTZ NOT NULL,
    yard_block    TEXT,
    crane_id      TEXT,
    berth_call_id INT REFERENCES berth_calls(call_id),
    is_rehandle   BOOLEAN NOT NULL DEFAULT FALSE
);

-- ── Crane telemetry (Crane automation module, IoT time-series) ──────────
CREATE TABLE IF NOT EXISTS crane_telemetry (
    reading_id   BIGSERIAL PRIMARY KEY,
    terminal_id  TEXT NOT NULL REFERENCES terminals,
    crane_id     TEXT NOT NULL,
    ts           TIMESTAMPTZ NOT NULL,
    vibration_g  NUMERIC NOT NULL,   -- baseline ~0.30-0.45g
    temperature_c NUMERIC NOT NULL,  -- baseline ~48-55C
    load_tonnes  NUMERIC
);

-- ── Maintenance work orders (Fleet management module) ───────────────────
CREATE TABLE IF NOT EXISTS work_orders (
    wo_id             TEXT PRIMARY KEY,   -- e.g. 'WO-4411'
    terminal_id       TEXT NOT NULL REFERENCES terminals,
    equipment_id      TEXT NOT NULL,
    fault_code        TEXT,
    opened_ts         TIMESTAMPTZ NOT NULL,
    closed_ts         TIMESTAMPTZ,
    technician_notes  TEXT,          -- free text -- this is what UC2's
                                      -- "free-text match" pattern-matches on
    parts_used        TEXT,
    labour_hours      NUMERIC,
    status            TEXT NOT NULL DEFAULT 'open'  -- open | closed
);

-- ── Billing events (Billing module) ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS billing_events (
    invoice_id     TEXT PRIMARY KEY,
    terminal_id    TEXT NOT NULL REFERENCES terminals,
    container_id   TEXT NOT NULL,
    move_type      TEXT NOT NULL,
    tariff_code    TEXT NOT NULL,
    amount_usd     NUMERIC NOT NULL,
    customer_name  TEXT NOT NULL,
    customer_email TEXT NOT NULL,
    dispute_flag   BOOLEAN NOT NULL DEFAULT FALSE,
    dispute_reason TEXT,             -- free text customer complaint
    created_ts     TIMESTAMPTZ NOT NULL
);

-- ── Business glossary (Semantic KB backbone for Text-to-Insights) ───────
-- The seed deck's own "Discovery" slide asks: "Does 'turn time' mean
-- the same at Santos and NorthStar Terminals? Resolve terms before the AI answers
-- with them." This table is that resolved glossary.
CREATE TABLE IF NOT EXISTS business_glossary (
    term                   TEXT PRIMARY KEY,
    definition             TEXT NOT NULL,
    terminal_variance_note TEXT
);

SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;
