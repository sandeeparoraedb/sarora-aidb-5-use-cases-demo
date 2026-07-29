-- NorthStar Terminals synthetic operational data.
-- Runs once, on first cluster initialization only.
--
-- Reproduces the specific narrative beats from the seed use-cases
-- deck so that every demo's AI-generated answer lines up with a moment the
-- audience already recognizes from the slides:
--   * Tue 2026-07-14, 13:00-18:00 @ Jebel Ali: gate turn times spike ~42%
--     because "Neptune Voyager" overran berth 2 by 6 hours, pulling yard
--     trucks off marshalling duty; rehandles up ~31% in the same window.
--   * Crane 2's hoist gearbox: vibration drift starts 2026-06-26, trends up
--     for ~3 weeks, and the crane fails mid-vessel-call at 22:00 on
--     Wed 2026-07-15 -- the same signature as two prior fleet failures,
--     WO-4411 and WO-5207.
--   * That same Wed 22:00: vessel "Aurora" slips 8 hours AND crane 2 is down
--     until Thu 06:00 -- forcing the berth replan (moved to berth 3,
--     04:00 Thu, "Ionian Star" keeps its window).

\c mydb

-- ── Terminals ────────────────────────────────────────────────────────────
INSERT INTO terminals (terminal_id, name, country) VALUES
    ('JEA', 'Jebel Ali',      'United Arab Emirates'),
    ('LGW', 'London Gateway', 'United Kingdom'),
    ('SSZ', 'Santos',         'Brazil'),
    ('HKG', 'Hong Kong',      'Hong Kong SAR')
ON CONFLICT DO NOTHING;

-- ── Business glossary (Semantic KB backbone for Text-to-Insights) ───────
INSERT INTO business_glossary (term, definition, terminal_variance_note) VALUES
    ('turn_time',
     'Minutes elapsed from a truck''s gate-in scan to its gate-out scan for a single terminal visit.',
     'Jebel Ali and Hong Kong measure gate-in to gate-out. London Gateway historically measured appointment-time to gate-out, which runs longer -- resolve before comparing terminals head-to-head.'),
    ('dwell_time',
     'Hours a container sits in the yard between discharge (or gate-in, for exports) and its onward move (load, gate-out).',
     'Santos includes customs-hold time inside dwell; other terminals report customs-hold separately.'),
    ('rehandle',
     'A container move that repositions a box within the yard without progressing it toward load/discharge -- i.e. it was stacked in the way of the box actually needed. Rehandles are pure cost, not throughput.',
     NULL),
    ('demurrage',
     'Per-day penalty charged to a customer for a container held in the terminal beyond its free time.',
     NULL),
    ('berth_productivity',
     'Container moves per hour, per vessel call, across all cranes working that call.',
     NULL),
    ('teu',
     'Twenty-foot Equivalent Unit -- standard measure of container volume; a 40ft container counts as 2 TEU.',
     NULL),
    ('vessel_call',
     'One vessel''s single visit to the terminal, from berthing to departure.',
     NULL)
ON CONFLICT DO NOTHING;

-- ── Berth & vessel schedule ──────────────────────────────────────────────
-- Tuesday: Neptune Voyager overruns berth 2 by 6 hours (planned etd 12:00,
-- actual 18:00) -- the root cause Ana has to chase down in the Enterprise
-- Search / Text-to-Insights demos.
INSERT INTO berth_calls
    (terminal_id, vessel_name, berth_id, eta, etd, actual_arrival, actual_departure,
     cranes_assigned, productivity_moves_per_hr, status, notes)
VALUES
    ('JEA', 'Neptune Voyager', 'berth_2',
     '2026-07-14 05:00+04', '2026-07-14 12:00+04',
     '2026-07-14 05:10+04', '2026-07-14 18:00+04',
     'crane_2,crane_5', 22.0, 'completed',
     'Extended call -- yard trucks diverted from marshalling to support unload; overran plan by 6 hours.'),

    ('JEA', 'Silver Horizon', 'berth_1',
     '2026-07-14 07:00+04', '2026-07-14 15:00+04',
     '2026-07-14 07:05+04', '2026-07-14 15:20+04',
     'crane_1,crane_6', 31.0, 'completed', 'On plan.'),

    -- Wednesday night: the incident. Aurora slips 8 hours; crane 2 fails at
    -- 22:00 mid-call for a *different* vessel (Neptune Voyager's successor
    -- at berth 2 that night) and is down until Thu 06:00, forcing Aurora's
    -- replan onto berth 3.
    ('JEA', 'Camden Reach', 'berth_2',
     '2026-07-15 18:00+04', '2026-07-16 02:00+04',
     '2026-07-15 18:05+04', NULL,
     'crane_2,crane_5', 18.5, 'delayed',
     'Crane 2 hoist gearbox failed 22:00 mid-call. Berth 2 lost ~4 working hours; night shift improvised with crane_5 only.'),

    ('JEA', 'Aurora', 'berth_2',
     '2026-07-15 14:00+04', '2026-07-15 22:00+04',
     NULL, NULL,
     NULL, NULL, 'replanned',
     'ETA slipped 8 hours (new ETA 2026-07-15 22:00) just as crane 2 went down. Replanned -- see berth_3 call same vessel below. Option A (hold at berth 2) est. demurrage $118K; option C (displace Ionian Star) est. $96K; option B (this row) chosen, est. demurrage $41K.'),

    ('JEA', 'Aurora', 'berth_3',
     '2026-07-16 04:00+04', '2026-07-16 12:00+04',
     '2026-07-16 04:00+04', '2026-07-16 12:40+04',
     'crane_3,crane_4', 26.0, 'completed',
     'Replan option B, approved by duty manager 22:15 on 2026-07-15. 09:00 rail connection held. Gate impact minor (06:00-08:00).'),

    ('JEA', 'Ionian Star', 'berth_1',
     '2026-07-16 06:00+04', '2026-07-16 14:00+04',
     '2026-07-16 06:30+04', '2026-07-16 14:10+04',
     'crane_1,crane_6', 29.0, 'completed',
     'Kept its original window under replan option B.')
ON CONFLICT DO NOTHING;

-- ── Gate transactions ────────────────────────────────────────────────────
-- Baseline traffic across a 3-week window at Jebel Ali (~35 min average
-- turn time), then a superimposed spike block Tue 2026-07-14 13:00-18:00
-- (~42% higher) matching the deck's "gate turn times spiked 40%" trigger.
INSERT INTO gate_transactions (terminal_id, truck_id, appointment_ts, gate_in_ts, gate_out_ts, turn_time_minutes, move_type)
SELECT
    'JEA',
    'TRK-' || lpad((1000 + g)::text, 5, '0'),
    ts - interval '20 minutes',
    ts,
    ts + (make_interval(mins => round((28 + random() * 14)::numeric)::int)),
    round((28 + random() * 14)::numeric, 1),
    (ARRAY['import_pickup','export_drop','empty_return'])[1 + floor(random() * 3)::int]
FROM generate_series(1, 400) AS g,
     LATERAL (SELECT ('2026-07-01 06:00+04'::timestamptz
               + (g % 21) * interval '1 day'
               + (6 + (g % 12)) * interval '1 hour'
               + (random() * 50) * interval '1 minute') AS ts) t
WHERE NOT (ts::date = '2026-07-14' AND extract(hour FROM ts) BETWEEN 13 AND 18);

INSERT INTO gate_transactions (terminal_id, truck_id, appointment_ts, gate_in_ts, gate_out_ts, turn_time_minutes, move_type)
SELECT
    'JEA',
    'TRK-' || lpad((9000 + g)::text, 5, '0'),
    ts - interval '20 minutes',
    ts,
    ts + (make_interval(mins => round((44 + random() * 16)::numeric)::int)),
    round((44 + random() * 16)::numeric, 1),   -- ~42-55% above the ~35 min baseline
    (ARRAY['import_pickup','export_drop','empty_return'])[1 + floor(random() * 3)::int]
FROM generate_series(1, 55) AS g,
     LATERAL (SELECT ('2026-07-14 13:00+04'::timestamptz + (random() * 5) * interval '1 hour') AS ts) t;

-- Light background traffic at the other three terminals, for realism when
-- a demo question isn't terminal-scoped.
INSERT INTO gate_transactions (terminal_id, truck_id, appointment_ts, gate_in_ts, gate_out_ts, turn_time_minutes, move_type)
SELECT
    term,
    'TRK-' || term || '-' || lpad(g::text, 5, '0'),
    ts - interval '20 minutes',
    ts,
    ts + (make_interval(mins => round((30 + random() * 20)::numeric)::int)),
    round((30 + random() * 20)::numeric, 1),
    (ARRAY['import_pickup','export_drop','empty_return'])[1 + floor(random() * 3)::int]
FROM generate_series(1, 120) AS g,
     LATERAL (SELECT (ARRAY['LGW','SSZ','HKG'])[1 + floor(random() * 3)::int] AS term) tm,
     LATERAL (SELECT ('2026-07-01 06:00+00'::timestamptz + (random() * 20) * interval '1 day' + (random() * 12) * interval '1 hour') AS ts) t;

-- ── Container moves ──────────────────────────────────────────────────────
-- Bulk historical volume with NO index on container_id / event_ts -- the
-- deliberately-slow substrate for the DBA Copilot demo.
INSERT INTO container_moves (terminal_id, container_id, move_type, event_ts, yard_block, crane_id, is_rehandle)
SELECT
    (ARRAY['JEA','LGW','SSZ','HKG'])[1 + floor(random() * 4)::int],
    'CONT' || lpad((1 + floor(random() * 500000))::bigint::text, 7, '0'),
    (ARRAY['discharge','load','yard_shift','rehandle'])[1 + floor(random() * 4)::int],
    now() - (random() * interval '730 days'),
    'YB-' || (1 + floor(random() * 40))::text,
    'crane_' || (1 + floor(random() * 6))::text,
    (random() < 0.12)
FROM generate_series(1, 300000);

-- Narrative rehandle spike: Tue 2026-07-14, 13:00-18:00, tied to the
-- Neptune Voyager overrun at berth 2 (rehandles up ~31% in the window).
INSERT INTO container_moves (terminal_id, container_id, move_type, event_ts, yard_block, crane_id, berth_call_id, is_rehandle)
SELECT
    'JEA',
    'CONTJEA' || lpad(g::text, 4, '0'),
    'rehandle',
    ts,
    'YB-0' || (1 + (g % 3))::text,
    'crane_5',
    (SELECT call_id FROM berth_calls WHERE vessel_name = 'Neptune Voyager' LIMIT 1),
    TRUE
FROM generate_series(1, 40) AS g,
     LATERAL (SELECT ('2026-07-14 13:00+04'::timestamptz + (random() * 5) * interval '1 hour') AS ts) t;

-- ── Crane telemetry ──────────────────────────────────────────────────────
-- Crane 2 @ JEA: stable baseline through 2026-06-25, then a slow vibration
-- and temperature drift starting 2026-06-26 that accelerates into the
-- 2026-07-15 22:00 gearbox failure -- "detectable two to three weeks early."
INSERT INTO crane_telemetry (terminal_id, crane_id, ts, vibration_g, temperature_c, load_tonnes)
SELECT
    'JEA', 'crane_2', ts,
    round((CASE
        WHEN ts < '2026-06-26' THEN 0.32 + random() * 0.08
        ELSE 0.35 + (extract(epoch FROM (ts - '2026-06-26'::timestamptz)) / 86400.0) * 0.028 + random() * 0.06
    END)::numeric, 3),
    round((CASE
        WHEN ts < '2026-06-26' THEN 49 + random() * 3
        ELSE 50 + (extract(epoch FROM (ts - '2026-06-26'::timestamptz)) / 86400.0) * 0.7 + random() * 2
    END)::numeric, 1),
    round((18 + random() * 14)::numeric, 1)
FROM generate_series('2026-06-01 00:00+04'::timestamptz, '2026-07-15 22:00+04'::timestamptz, interval '4 hours') AS ts;

-- Healthy fleet baseline (last 14 days) for the other cranes, so "compare
-- crane 2 against the fleet" queries have something to compare against.
INSERT INTO crane_telemetry (terminal_id, crane_id, ts, vibration_g, temperature_c, load_tonnes)
SELECT
    'JEA', crane, ts,
    round((0.30 + random() * 0.10)::numeric, 3),
    round((48 + random() * 4)::numeric, 1),
    round((18 + random() * 14)::numeric, 1)
FROM unnest(ARRAY['crane_1','crane_3','crane_4','crane_5','crane_6']) AS crane,
     LATERAL generate_series('2026-07-01 00:00+04'::timestamptz, '2026-07-15 22:00+04'::timestamptz, interval '4 hours') AS ts;

-- ── Maintenance work orders ──────────────────────────────────────────────
-- WO-4411 and WO-5207: the two prior fleet failures with the same
-- signature the copilot pattern-matches against. WO-6688: tonight's.
INSERT INTO work_orders (wo_id, terminal_id, equipment_id, fault_code, opened_ts, closed_ts, technician_notes, parts_used, labour_hours, status) VALUES
('WO-4411', 'LGW', 'crane_7', 'GEARBOX-VIB',
 '2025-11-03 09:15+00', '2025-11-06 17:00+00',
 'Hoist gearbox on crane 7 showing rising vibration on daily walk-round checks over roughly three weeks -- driver reported "rougher" hoist feel on wet lifts before the numbers moved. Vibration climbed steadily then spiked sharply in the final 48 hours; bearing temperature followed the same curve about a day behind. Gearbox seized mid-lift on 11-03, no cargo drop, no injuries. Stripped down: primary bearing race spalled, consistent with slow-onset fatigue rather than a single shock load. Replaced hoist gearbox assembly and primary bearing set; re-instrumented vibration sensor mount (previous mount had drifted, may have delayed detection).',
 'hoist gearbox assembly; primary bearing set; vibration sensor mount', 22, 'closed'),

('WO-5207', 'SSZ', 'crane_3', 'GEARBOX-VIB',
 '2026-03-18 06:40-03', '2026-03-19 22:00-03',
 'Crane 3 hoist gearbox failure, same signature as WO-4411: vibration trending up over the prior 2-3 weeks, sharp acceleration in the last 2-3 days before failure, temperature drift lagging vibration by roughly a day. Failed mid-vessel-call, forced a crane swap and a 3-hour berth delay. Post-mortem: bearing race fatigue, likely accelerated by a run of back-to-back heavy lifts in the weeks prior. Replaced gearbox and bearing set. Recommend: flag any crane showing >2x baseline vibration sustained over 48+ hours for inspection, don''t wait for a fault code.',
 'hoist gearbox assembly; primary bearing set', 16, 'closed'),

('WO-6688', 'JEA', 'crane_2', 'GEARBOX-FAIL',
 '2026-07-15 22:00+04', NULL,
 'Crane 2 hoist gearbox failed mid-call at berth 2, 22:00, working Camden Reach (Aurora replanned to berth 3 as a result -- see berth schedule). Same signature as WO-4411 (crane 7, 2025-11) and WO-5207 (crane 3, 2026-03): vibration had been trending above baseline for at least the prior three weeks, sharply elevated in the final 72 hours before failure. No injuries, no cargo drop, but berth 2 lost ~4 working hours on an already-delayed call. Recommend full gearbox and bearing inspection in the Thursday 04:00-09:00 vessel-call gap; pull vibration history back to 2026-06-26 for the post-mortem.',
 NULL, NULL, 'open')
ON CONFLICT DO NOTHING;

-- ── Billing events ───────────────────────────────────────────────────────
INSERT INTO billing_events (invoice_id, terminal_id, container_id, move_type, tariff_code, amount_usd, customer_name, customer_email, dispute_flag, dispute_reason, created_ts) VALUES
('INV-88214', 'JEA', 'CONTJEA0001', 'discharge', 'DEM-STD', 4100.00,
 'Desert Star Logistics LLC', 'youssef.haddad@desertstarlogistics.example',
 TRUE, 'Customer disputes the demurrage charge on this container, stating the delay was caused by the terminal (vessel/crane issue), not their collection failure, and is asking for the fee to be waived or reduced.',
 '2026-07-17 10:12+04'),

('INV-88215', 'JEA', 'CONTJEA0002', 'load', 'STD-EXP', 620.00,
 'Continental Freight Partners', 'meilin.tan@continentalfreight.example',
 TRUE, 'This invoice appears to duplicate INV-88190 billed last week for the same container and move -- requesting credit for the duplicate charge.',
 '2026-07-17 11:40+04'),

('INV-88216', 'JEA', 'CONTJEA0003', 'discharge', 'WGT-ADJ', 310.00,
 'Al Noor Shipping Agency', 'sara.idris@alnoorshipping.example',
 TRUE, 'The billed weight does not match the weight declared on the bill of lading -- requesting a re-weigh and invoice correction before payment.',
 '2026-07-18 09:05+04'),

('INV-88217', 'JEA', 'CONTJEA0004', 'discharge', 'DMG-HDL', 275.00,
 'TransGlobal Cargo', 'diego.fernandez@transglobalcargo.example',
 TRUE, 'Container arrived at the customer''s warehouse with visible exterior damage; customer disputes the handling fee and is filing a damage claim against the terminal.',
 '2026-07-18 14:22+04'),

('INV-88220', 'JEA', 'CONTJEA0005', 'load', 'STD-EXP', 540.00,
 'Desert Star Logistics LLC', 'youssef.haddad@desertstarlogistics.example',
 FALSE, NULL, '2026-07-19 08:00+04'),

('INV-88221', 'JEA', 'CONTJEA0006', 'discharge', 'STD-IMP', 480.00,
 'Continental Freight Partners', 'meilin.tan@continentalfreight.example',
 FALSE, NULL, '2026-07-19 09:30+04'),

('INV-88222', 'JEA', 'CONTJEA0007', 'yard_shift', 'REHANDLE', 90.00,
 'Al Noor Shipping Agency', 'sara.idris@alnoorshipping.example',
 FALSE, NULL, '2026-07-19 12:15+04')
ON CONFLICT DO NOTHING;

SELECT 'terminals' AS table_name, count(*) FROM terminals
UNION ALL SELECT 'berth_calls', count(*) FROM berth_calls
UNION ALL SELECT 'gate_transactions', count(*) FROM gate_transactions
UNION ALL SELECT 'container_moves', count(*) FROM container_moves
UNION ALL SELECT 'crane_telemetry', count(*) FROM crane_telemetry
UNION ALL SELECT 'work_orders', count(*) FROM work_orders
UNION ALL SELECT 'billing_events', count(*) FROM billing_events
UNION ALL SELECT 'business_glossary', count(*) FROM business_glossary;
