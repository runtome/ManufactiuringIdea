-- =====================================================================
-- FactoryBrain AI Platform — Deterministic demo / test dataset
-- Document : DDS-00-FactoryBrain section 11
-- Version  : 1.0
-- Date     : 2026-09-10
--
-- Apply AFTER schema.sql:
--   psql -v ON_ERROR_STOP=1 -f schema.sql
--   psql -v ON_ERROR_STOP=1 -f seed_demo.sql
--
-- PURPOSE
--   This dataset is DETERMINISTIC. Every row is computed from a fixed
--   formula seeded by date, so totals are known in advance and test cases
--   can assert exact numbers (TEST TC-011, TC-031, TC-041).
--
--   It deliberately contains a PLANTED ANOMALY so that detection logic has
--   something true to find, and so that a test can prove the system does
--   NOT raise an alert on the normal days.
--
-- PLANTED SCENARIO
--   Window        : 2026-08-12 .. 2026-09-10 (30 days)
--   Lines         : L1, L2, L3            Shifts: A, B
--   Baseline rate : ~2.0 % on L1/L2, ~2.4 % on L3
--   ANOMALY       : from 2026-09-08, LINE 3 / SHIFT B defect rate jumps to
--                   ~6 % driven by defect code MISSING_COMPONENT, coincident
--                   with material lot LOT-2609-114 entering at 14:12.
--   Everything else stays inside normal variation.
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

-- Refuse to seed a database that already has production data.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM core.production_fact LIMIT 1) THEN
        RAISE EXCEPTION
          'core.production_fact is not empty. Refusing to seed: this script assumes an empty database and its assertions depend on exact totals.';
    END IF;
END
$$;

-- ---------------------------------------------------------------------
-- 1. Master data (fixed UUIDs so tests can reference them by literal)
-- ---------------------------------------------------------------------

INSERT INTO core.plant (id, code, name, timezone) VALUES
  ('00000000-0000-7000-8000-000000000001', 'P1', 'Demo Plant 1', 'Asia/Bangkok');

INSERT INTO core.line (id, plant_id, code, name) VALUES
  ('00000000-0000-7000-8000-00000000000a', '00000000-0000-7000-8000-000000000001', 'L1', 'Assembly Line 1'),
  ('00000000-0000-7000-8000-00000000000b', '00000000-0000-7000-8000-000000000001', 'L2', 'Assembly Line 2'),
  ('00000000-0000-7000-8000-00000000000c', '00000000-0000-7000-8000-000000000001', 'L3', 'Assembly Line 3');

INSERT INTO core.sku (id, code, name, customer, spec_json) VALUES
  ('00000000-0000-7000-8000-000000000101', 'RAD-500-A', 'Radiator Core 500A', 'Customer-J', '{"ideal_cycle_s": 12.0}'),
  ('00000000-0000-7000-8000-000000000102', 'RAD-500-B', 'Radiator Core 500B', 'Customer-J', '{"ideal_cycle_s": 12.5}'),
  ('00000000-0000-7000-8000-000000000103', 'CND-220-X', 'Condenser 220X',     'Customer-T', '{"ideal_cycle_s": 9.0}');

INSERT INTO core.defect_type (id, code, name_th, name_ja, name_en, category, is_critical) VALUES
  ('00000000-0000-7000-8000-000000000201', 'MISSING_COMPONENT', 'ชิ้นส่วนขาด',   '部品欠品',   'Missing Component', 'assembly', true),
  ('00000000-0000-7000-8000-000000000202', 'SCRATCH',           'รอยขีดข่วน',    'キズ',       'Scratch',           'surface',  false),
  ('00000000-0000-7000-8000-000000000203', 'MISSING_FIN',       'ฟินขาด',        'フィン欠品', 'Missing Fin',       'assembly', true),
  ('00000000-0000-7000-8000-000000000204', 'DENT',              'รอยบุบ',        'へこみ',     'Dent',              'surface',  false),
  ('00000000-0000-7000-8000-000000000205', 'LEAK',              'รั่ว',           '漏れ',       'Leak',              'function', true);

INSERT INTO core.machine (id, line_id, code, name, machine_type, criticality) VALUES
  ('00000000-0000-7000-8000-000000000301', '00000000-0000-7000-8000-00000000000a', 'M-01', 'Press 1',   'press',    'MEDIUM'),
  ('00000000-0000-7000-8000-000000000302', '00000000-0000-7000-8000-00000000000b', 'M-04', 'Press 4',   'press',    'HIGH'),
  ('00000000-0000-7000-8000-000000000303', '00000000-0000-7000-8000-00000000000c', 'M-07', 'Assembler 7','assembly','HIGH');

INSERT INTO core.material_lot (id, lot_code, material_code, supplier, received_at) VALUES
  ('00000000-0000-7000-8000-000000000401', 'LOT-2608-091', 'MAT-AL-3003', 'Supplier-A', '2026-08-11 08:00+07'),
  ('00000000-0000-7000-8000-000000000402', 'LOT-2609-102', 'MAT-AL-3003', 'Supplier-A', '2026-09-01 08:00+07'),
  ('00000000-0000-7000-8000-000000000403', 'LOT-2609-114', 'MAT-AL-3003', 'Supplier-B', '2026-09-07 08:00+07');

-- NOTE: LOT-2609-114 (Supplier-B) is the planted correlate of the
--       2026-09-08 defect spike. Correlation analysis is expected to find it.

INSERT INTO core.shift_calendar (plant_id, shift, starts_at, ends_at, valid_from) VALUES
  ('00000000-0000-7000-8000-000000000001', 'A', '06:00', '14:00', '2026-01-01'),
  ('00000000-0000-7000-8000-000000000001', 'B', '14:00', '22:00', '2026-01-01');

-- Users. password_hash is a placeholder; the demo stack sets real hashes at
-- bootstrap (OPS section 3.4). No usable credential ships in this file.
INSERT INTO core.app_user (id, username, display_name, role, lang, password_hash, active) VALUES
  ('00000000-0000-7000-8000-000000000501', 'demo.viewer',    'Demo Viewer',    'viewer',    'th', 'SET_AT_BOOTSTRAP', true),
  ('00000000-0000-7000-8000-000000000502', 'demo.inspector', 'Demo Inspector', 'inspector', 'th', 'SET_AT_BOOTSTRAP', true),
  ('00000000-0000-7000-8000-000000000503', 'demo.engineer',  'Demo Engineer',  'engineer',  'en', 'SET_AT_BOOTSTRAP', true),
  ('00000000-0000-7000-8000-000000000504', 'demo.manager',   'Demo Manager',   'manager',   'ja', 'SET_AT_BOOTSTRAP', true),
  ('00000000-0000-7000-8000-000000000505', 'demo.admin',     'Demo Admin',     'admin',     'en', 'SET_AT_BOOTSTRAP', true);

-- Restricted user for the permission test (TC-091): sees ONLY line L1.
INSERT INTO core.user_line_scope (user_id, line_id) VALUES
  ('00000000-0000-7000-8000-000000000501', '00000000-0000-7000-8000-00000000000a');

-- ---------------------------------------------------------------------
-- 2. Ingest batch (production facts are attributed to this batch)
-- ---------------------------------------------------------------------

INSERT INTO core.ingest_batch (id, source, filename, sha256, rows_total, rows_ok,
                               rows_quarantined, status, finished_at)
VALUES ('00000000-0000-7000-8000-000000000601', 'seed', 'seed_demo.sql',
        repeat('0', 64), 180, 180, 0, 'succeeded', now());

-- ---------------------------------------------------------------------
-- 3. Production facts — 30 days x 3 lines x 2 shifts
--
--    Deterministic formulas (no random()):
--      qty_produced = base(line) + 40 * ((day_index * 7 + shift_ord * 3) % 5)
--      defect rate  = baseline(line) + small deterministic wobble
--      ANOMALY      : L3 / shift B from 2026-09-08 -> ~6 %
-- ---------------------------------------------------------------------

WITH days AS (
    SELECT d::date                                        AS prod_date,
           (d::date - DATE '2026-08-12')                  AS day_index
    FROM generate_series(DATE '2026-08-12', DATE '2026-09-10', INTERVAL '1 day') d
),
grid AS (
    SELECT
        dd.prod_date,
        dd.day_index,
        l.line_id,
        l.line_ord,
        s.shift,
        s.shift_ord,
        sk.sku_id
    FROM days dd
    CROSS JOIN (VALUES
        ('00000000-0000-7000-8000-00000000000a'::uuid, 1),
        ('00000000-0000-7000-8000-00000000000b'::uuid, 2),
        ('00000000-0000-7000-8000-00000000000c'::uuid, 3)
    ) AS l(line_id, line_ord)
    CROSS JOIN (VALUES
        ('A'::core.shift_code, 1),
        ('B'::core.shift_code, 2)
    ) AS s(shift, shift_ord)
    CROSS JOIN LATERAL (
        SELECT CASE l.line_ord
                 WHEN 1 THEN '00000000-0000-7000-8000-000000000101'::uuid
                 WHEN 2 THEN '00000000-0000-7000-8000-000000000102'::uuid
                 ELSE      '00000000-0000-7000-8000-000000000101'::uuid
               END AS sku_id
    ) sk
),
computed AS (
    SELECT
        g.*,
        -- Deterministic volume: 1800/2000/2200 base plus a 5-step cycle
        (1600 + g.line_ord * 200
              + 40 * ((g.day_index * 7 + g.shift_ord * 3) % 5))::int AS qty_produced,
        -- Deterministic defect rate in basis points
        CASE
          WHEN g.line_ord = 3 AND g.shift = 'B' AND g.prod_date >= DATE '2026-09-08'
            THEN 580 + 20 * ((g.day_index) % 3)          -- PLANTED ANOMALY ~5.8-6.2 %
          WHEN g.line_ord = 3
            THEN 235 + 10 * ((g.day_index + g.shift_ord) % 3)
          ELSE 195 + 10 * ((g.day_index * 3 + g.shift_ord) % 4)
        END AS rate_bp
    FROM grid g
)
INSERT INTO core.production_fact
      (prod_date, shift, line_id, sku_id, qty_produced, qty_ng,
       runtime_min, downtime_min, batch_id)
SELECT
    c.prod_date,
    c.shift,
    c.line_id,
    c.sku_id,
    c.qty_produced,
    GREATEST(0, ROUND(c.qty_produced * c.rate_bp / 10000.0))::int AS qty_ng,
    440.0 - 5 * ((c.day_index + c.line_ord) % 6)                  AS runtime_min,
    40.0  + 5 * ((c.day_index + c.line_ord) % 6)                  AS downtime_min,
    '00000000-0000-7000-8000-000000000601'
FROM computed c;

-- ---------------------------------------------------------------------
-- 4. Defect facts — split each shift's NG across defect types
--
--    Normal split : MISSING_COMPONENT 30 %, SCRATCH 25 %, MISSING_FIN 20 %,
--                   DENT 15 %, LEAK 10 %
--    Anomaly split (L3/B from 09-08): MISSING_COMPONENT dominates at ~63 %
--    Remainder is assigned to SCRATCH so the sum always equals qty_ng exactly.
-- ---------------------------------------------------------------------

WITH src AS (
    SELECT
        pf.prod_date, pf.shift, pf.line_id, pf.sku_id, pf.qty_ng,
        (l.code = 'L3' AND pf.shift = 'B' AND pf.prod_date >= DATE '2026-09-08') AS is_anomaly
    FROM core.production_fact pf
    JOIN core.line l ON l.id = pf.line_id
),
alloc AS (
    SELECT
        s.*,
        CASE WHEN s.is_anomaly THEN ROUND(s.qty_ng * 0.63) ELSE ROUND(s.qty_ng * 0.30) END::int AS q_missing_comp,
        CASE WHEN s.is_anomaly THEN ROUND(s.qty_ng * 0.12) ELSE ROUND(s.qty_ng * 0.20) END::int AS q_missing_fin,
        CASE WHEN s.is_anomaly THEN ROUND(s.qty_ng * 0.10) ELSE ROUND(s.qty_ng * 0.15) END::int AS q_dent,
        CASE WHEN s.is_anomaly THEN ROUND(s.qty_ng * 0.05) ELSE ROUND(s.qty_ng * 0.10) END::int AS q_leak
    FROM src s
),
final AS (
    SELECT
        a.*,
        -- Scratch absorbs the rounding remainder so SUM(defect) = qty_ng exactly
        GREATEST(0, a.qty_ng - a.q_missing_comp - a.q_missing_fin - a.q_dent - a.q_leak)::int AS q_scratch
    FROM alloc a
)
INSERT INTO core.defect_fact
      (prod_date, shift, line_id, sku_id, defect_type_id, qty, batch_id)
SELECT prod_date, shift, line_id, sku_id, dt.id, v.qty,
       '00000000-0000-7000-8000-000000000601'
FROM final f
CROSS JOIN LATERAL (VALUES
    ('MISSING_COMPONENT', f.q_missing_comp),
    ('SCRATCH',           f.q_scratch),
    ('MISSING_FIN',       f.q_missing_fin),
    ('DENT',              f.q_dent),
    ('LEAK',              f.q_leak)
) AS v(code, qty)
JOIN core.defect_type dt ON dt.code = v.code
WHERE v.qty > 0;

-- ---------------------------------------------------------------------
-- 5. Timeline events — the correlate the analysis is supposed to find
-- ---------------------------------------------------------------------

INSERT INTO quality.timeline_event (ts, line_id, machine_id, kind, detail_json) VALUES
  ('2026-09-08 14:12+07', '00000000-0000-7000-8000-00000000000c',
   '00000000-0000-7000-8000-000000000303', 'material_lot_change',
   '{"from":"LOT-2609-102","to":"LOT-2609-114","supplier":"Supplier-B"}'),
  ('2026-09-01 09:00+07', '00000000-0000-7000-8000-00000000000b',
   '00000000-0000-7000-8000-000000000302', 'maintenance',
   '{"kind":"preventive","description":"6-month PM completed"}'),
  ('2026-08-20 10:30+07', '00000000-0000-7000-8000-00000000000a',
   '00000000-0000-7000-8000-000000000301', 'parameter_change',
   '{"parameter":"press_force","from":118,"to":121,"unit":"kN","by":"demo.engineer"}');

-- ---------------------------------------------------------------------
-- 6. Vision — model registry, camera, recipe, and one day of inspections
-- ---------------------------------------------------------------------

INSERT INTO vision.model_registry
      (id, name, version, sha256, task, input_size, class_map, metrics_json, stage, promoted_at)
VALUES
  ('00000000-0000-7000-8000-000000000701', 'defect-yolo11s', '1.0.0', repeat('a', 64),
   'detection', 640,
   '{"0":"MISSING_COMPONENT","1":"SCRATCH","2":"MISSING_FIN","3":"DENT"}',
   '{"map50":0.871,"recall_critical":0.982,"false_alarm_rate":0.021}',
   'active', '2026-08-01 10:00+07'),
  ('00000000-0000-7000-8000-000000000702', 'defect-yolo11s', '1.1.0', repeat('b', 64),
   'detection', 640,
   '{"0":"MISSING_COMPONENT","1":"SCRATCH","2":"MISSING_FIN","3":"DENT"}',
   '{"map50":0.884,"recall_critical":0.985,"false_alarm_rate":0.019}',
   'shadow', NULL);

INSERT INTO ops.edge_node (id, node_code, line_id, hardware, state, app_version,
                           model_versions, last_heartbeat, buffer_depth) VALUES
  ('00000000-0000-7000-8000-000000000801', 'L3-ST3', '00000000-0000-7000-8000-00000000000c',
   'Jetson Orin Nano 8GB', 'online', '1.0.0',
   '{"defect-yolo11s":"1.0.0"}', now(), 0);

INSERT INTO vision.camera (id, line_id, station, model, resolution, calib_px_per_mm, node_id) VALUES
  ('00000000-0000-7000-8000-000000000901', '00000000-0000-7000-8000-00000000000c',
   'ST3', 'Basler acA2440', '2448x2048', 18.4200,
   '00000000-0000-7000-8000-000000000801');

INSERT INTO vision.recipe (id, sku_id, version, rules_json, review_threshold, created_by) VALUES
  ('00000000-0000-7000-8000-000000000a01', '00000000-0000-7000-8000-000000000101', 1,
   '{"fail_if":{"class_present":["MISSING_COMPONENT","MISSING_FIN"]},
     "measurements":[{"name":"fin_pitch","usl":3.2,"lsl":2.8}]}',
   0.550, '00000000-0000-7000-8000-000000000503');

-- 200 inspections on 2026-09-09 for line L3: 183 PASS, 12 FAIL, 5 REVIEW.
-- Verdicts are assigned from explicit, disjoint position lists rather than a
-- modulo expression: modulo rules overlap silently and would quietly change
-- the counts that TC-031 and TC-034 assert against.
INSERT INTO vision.inspection
      (id, ts, line_id, sku_id, camera_id, station, lot, verdict, model_id,
       recipe_id, latency_ms, image_uri, source, node_id)
SELECT
    public.uuid_generate_v7(),
    TIMESTAMPTZ '2026-09-09 14:00+07' + (n || ' seconds')::interval * 30,
    '00000000-0000-7000-8000-00000000000c',
    '00000000-0000-7000-8000-000000000101',
    '00000000-0000-7000-8000-000000000901',
    'ST3',
    'LOT-2609-114',
    CASE
      WHEN n = ANY (ARRAY[10, 60, 110, 160, 200])
        THEN 'REVIEW'::vision.verdict                      -- exactly 5
      WHEN n = ANY (ARRAY[5, 15, 25, 35, 45, 55, 65, 75, 85, 95, 105, 115])
        THEN 'FAIL'::vision.verdict                        -- exactly 12
      ELSE 'PASS'::vision.verdict                          -- the remaining 183
    END,
    '00000000-0000-7000-8000-000000000701',
    '00000000-0000-7000-8000-000000000a01',
    95 + (n % 40),
    's3://evidence/demo/2026-09-09/' || lpad(n::text, 4, '0') || '.jpg',
    'edge',
    '00000000-0000-7000-8000-000000000801'
FROM generate_series(1, 200) AS n;

-- Detections for the FAIL rows
INSERT INTO vision.detection
      (inspection_id, inspection_ts, defect_type_id, class_name, confidence, bbox_json)
SELECT
    i.id, i.ts,
    '00000000-0000-7000-8000-000000000201',
    'MISSING_COMPONENT',
    0.9100,
    '{"x":120,"y":240,"w":86,"h":74}'
FROM vision.inspection i
WHERE i.verdict = 'FAIL';

-- Low-confidence detections for the REVIEW rows (below the 0.55 threshold)
INSERT INTO vision.detection
      (inspection_id, inspection_ts, defect_type_id, class_name, confidence, bbox_json)
SELECT
    i.id, i.ts,
    '00000000-0000-7000-8000-000000000202',
    'SCRATCH',
    0.4800,
    '{"x":300,"y":180,"w":40,"h":22}'
FROM vision.inspection i
WHERE i.verdict = 'REVIEW';

-- Measurements on the first 50 inspections (feeds SPC / Cpk tests)
INSERT INTO vision.measurement
      (inspection_id, inspection_ts, parameter, value, unit, usl, lsl)
SELECT
    i.id, i.ts, 'fin_pitch',
    -- Deterministic values centred on 3.00 with +/-0.06 spread
    3.00 + ((row_number() OVER (ORDER BY i.ts) % 7) - 3) * 0.02,
    'mm', 3.2, 2.8
FROM vision.inspection i
ORDER BY i.ts
LIMIT 50;

-- ---------------------------------------------------------------------
-- 7. Quality — characteristic and an open signal for the planted anomaly
-- ---------------------------------------------------------------------

INSERT INTO quality.characteristic
      (id, sku_id, name, unit, usl, lsl, target, chart_type, subgroup_rule) VALUES
  ('00000000-0000-7000-8000-000000000b01', '00000000-0000-7000-8000-000000000101',
   'fin_pitch', 'mm', 3.2, 2.8, 3.0, 'xbar_r', '{"kind":"fixed_n","n":5}');

INSERT INTO quality.control_limits
      (characteristic_id, line_id, ucl, cl, lcl, baseline_from, baseline_to,
       sample_size, reason, created_by)
VALUES
  ('00000000-0000-7000-8000-000000000b01', '00000000-0000-7000-8000-00000000000c',
   3.0620, 3.0000, 2.9380, '2026-08-12 00:00+07', '2026-09-05 00:00+07',
   50, 'Initial baseline from seed dataset', '00000000-0000-7000-8000-000000000503');

INSERT INTO quality.signal
      (id, opened_at, kind, line_id, sku_id, scope_json, statistic_json, severity, status)
VALUES
  ('00000000-0000-7000-8000-000000000c01', '2026-09-09 08:00+07', 'defect_rate_shift',
   '00000000-0000-7000-8000-00000000000c', '00000000-0000-7000-8000-000000000101',
   '{"line":"L3","shift":"B"}',
   '{"current_pct":5.80,"baseline_pct":2.41,"p_value":0.0004,"n":2140,
     "change_point":"2026-09-08T14:20:00+07:00","test":"two_proportion_z"}',
   'HIGH', 'open');

-- ---------------------------------------------------------------------
-- 8. Telemetry — a machine with a deterministic upward temperature trend
-- ---------------------------------------------------------------------

INSERT INTO telemetry.sensor (id, machine_id, signal, unit, sample_rate_hz, source) VALUES
  ('00000000-0000-7000-8000-000000000d01', '00000000-0000-7000-8000-000000000303',
   'bearing_temp', 'degC', 1.0, 'mqtt'),
  ('00000000-0000-7000-8000-000000000d02', '00000000-0000-7000-8000-000000000303',
   'vib_rms', 'mm/s', 100.0, 'mqtt');

-- Hourly samples for the last 10 days: flat, then a deliberate ramp.
INSERT INTO telemetry.sample (ts, sensor_id, value, quality)
SELECT
    g.ts,
    '00000000-0000-7000-8000-000000000d01',
    CASE
      WHEN g.ts < TIMESTAMPTZ '2026-09-05 00:00+07' THEN 68.9
      ELSE 68.9 + 1.9 * EXTRACT(epoch FROM (g.ts - TIMESTAMPTZ '2026-09-05 00:00+07')) / 86400.0
    END
    + 0.4 * ((EXTRACT(hour FROM g.ts)::int % 5) - 2),   -- deterministic diurnal wobble
    192
FROM generate_series(TIMESTAMPTZ '2026-09-01 00:00+07',
                     TIMESTAMPTZ '2026-09-10 23:00+07',
                     INTERVAL '1 hour') AS g(ts);

INSERT INTO telemetry.baseline
      (sensor_id, context, name, mean, std, p95, window_from, window_to, confirmed_by)
VALUES
  ('00000000-0000-7000-8000-000000000d01', 'running', 'mean',
   68.9, 2.1, 72.4, '2026-08-12 00:00+07', '2026-09-04 00:00+07',
   '00000000-0000-7000-8000-000000000503');

INSERT INTO telemetry.alert
      (id, opened_at, machine_id, severity, signals_json, evidence_json,
       suspected_component, recommendation, rul_low_days, rul_high_days, status)
VALUES
  ('00000000-0000-7000-8000-000000000e01', '2026-09-10 06:00+07',
   '00000000-0000-7000-8000-000000000303', 'HIGH',
   '["bearing_temp","vib_rms"]',
   '{"bearing_temp":{"now":78.4,"baseline":68.9,"sigma":4.5},
     "vib_rms":{"now":4.9,"baseline":2.9,"sigma":2.1}}',
   'drive-side bearing',
   'Inspect drive-side bearing lubrication and take a vibration spectrum reading within 3 days.',
   12.0, 30.0, 'open');

-- ---------------------------------------------------------------------
-- 9. Agent — tool registry (the capability boundary) and a sample run
-- ---------------------------------------------------------------------

INSERT INTO agent.tool (name, kind, risk, min_role, schema_json) VALUES
  ('query_production',      'read',  'low',    'viewer',
   '{"type":"object","properties":{"date_from":{"type":"string","format":"date"},
     "date_to":{"type":"string","format":"date"},"line":{"type":"string"},
     "sku":{"type":"string"},"shift":{"type":"string"}},"required":["date_from","date_to"]}'),
  ('query_defects',         'read',  'low',    'viewer',
   '{"type":"object","properties":{"date_from":{"type":"string","format":"date"},
     "date_to":{"type":"string","format":"date"},"group_by":{"type":"string"}},
     "required":["date_from","date_to"]}'),
  ('get_spc',               'read',  'low',    'engineer',
   '{"type":"object","properties":{"characteristic":{"type":"string"},
     "line":{"type":"string"},"window":{"type":"string"}},"required":["characteristic"]}'),
  ('search_memory',         'read',  'low',    'viewer',
   '{"type":"object","properties":{"text":{"type":"string"},"top_k":{"type":"integer"}},
     "required":["text"]}'),
  ('get_machine_telemetry', 'read',  'low',    'engineer',
   '{"type":"object","properties":{"machine_id":{"type":"string"},"signal":{"type":"string"},
     "window":{"type":"string"}},"required":["machine_id","signal"]}'),
  ('get_inspection_images', 'read',  'low',    'inspector',
   '{"type":"object","properties":{"record_ids":{"type":"array","items":{"type":"string"}}},
     "required":["record_ids"]}'),
  ('create_draft_report',   'write', 'medium', 'engineer',
   '{"type":"object","properties":{"type":{"type":"string"},"payload":{"type":"object"}},
     "required":["type","payload"]}'),
  ('send_discord',          'write', 'low',    'manager',
   '{"type":"object","properties":{"channel":{"type":"string"},"message":{"type":"string"}},
     "required":["channel","message"]}');

INSERT INTO agent.run
      (id, ts, user_id, correlation_id, kind, question, answer, model, prompt_version,
       facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome, grounding_json)
VALUES
  ('00000000-0000-7000-8000-000000000f01', '2026-09-10 07:05+07',
   '00000000-0000-7000-8000-000000000503', 'seed-corr-0001', 'ask',
   'Why did the defect rate increase on line 3 yesterday?',
   'Line 3 defect rate was 5.80 % on 2026-09-09 against a 7-day baseline of 2.41 % (p = 0.0004, n = 2140). '
   'Missing Component accounts for 63 % of the defects and the change point is 2026-09-08 14:20, which coincides '
   'with material lot LOT-2609-114 entering production at 14:12. This is a correlation; the root cause is not verified.',
   'qwen3:8b', 'ask.v1.2',
   '{"current_pct":5.80,"baseline_pct":2.41,"p_value":0.0004,"n":2140,"top_defect_share_pct":63}',
   1420, 210, 8400, 3, 'ok',
   '{"numbers_found":["5.80","2.41","0.0004","2140","63"],"all_matched":true}');

INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, row_count, duration_ms, ok) VALUES
  ('00000000-0000-7000-8000-000000000f01', 1, 'query_defects',
   '{"date_from":"2026-09-09","date_to":"2026-09-09","group_by":"defect_type"}', 5, 42, true),
  ('00000000-0000-7000-8000-000000000f01', 2, 'query_production',
   '{"date_from":"2026-09-02","date_to":"2026-09-09","line":"L3"}', 16, 31, true),
  ('00000000-0000-7000-8000-000000000f01', 3, 'search_memory',
   '{"text":"missing component line 3","top_k":5}', 3, 118, true);

-- ---------------------------------------------------------------------
-- 10. Knowledge — one verified past case (embeddings left NULL)
--
--     Embeddings are intentionally NULL: they depend on the deployed
--     embedding model. The bootstrap job populates them (OPS section 6.3).
-- ---------------------------------------------------------------------

INSERT INTO knowledge.document (id, sha256, kind, title, lang, uri, source_system) VALUES
  ('00000000-0000-7000-8000-000000001001', repeat('c', 64), '8d',
   '8D Report — M-07 overload 2024-08', 'en', 's3://docs/8D_M07_2024-08.pdf', 'seed');

INSERT INTO knowledge.case_record
      (id, title, opened_at, closed_at, scope_json, symptom_text, cause_text,
       action_text, verification_text, outcome, verified_by, verified_at, extracted_by)
VALUES
  ('00000000-0000-7000-8000-000000001101',
   'M-07 overload alarm, motor not rotating',
   '2024-08-21 09:00+07', '2024-09-02 17:00+07',
   '{"machine":"M-07","line":"L3"}',
   'Machine overload alarm, motor not rotating, intermittent, worse when hot.',
   'Proximity sensor abnormal — output drifted at elevated temperature.',
   'Replaced proximity sensor; added the sensor to the 6-month PM checklist.',
   'No recurrence observed for 14 months after the replacement.',
   'resolved',
   '00000000-0000-7000-8000-000000000503', '2024-09-03 10:00+07', 'human');

INSERT INTO knowledge.case_source (case_record_id, document_id, page_range) VALUES
  ('00000000-0000-7000-8000-000000001101', '00000000-0000-7000-8000-000000001001', '2-4');

-- An UNVERIFIED extraction: proves the citable-case view filters it out (TC-102)
INSERT INTO knowledge.case_record
      (id, title, opened_at, scope_json, symptom_text, outcome, extracted_by)
VALUES
  ('00000000-0000-7000-8000-000000001102',
   'Motor stop, no alarm recorded',
   '2023-12-11 14:00+07', '{"machine":"M-07"}',
   'Motor stopped with no alarm recorded in the log.',
   'unknown', 'llm:qwen3:8b');

INSERT INTO knowledge.glossary_term (ja, ja_reading, th, en, domain, approved_by) VALUES
  ('不良率', 'ふりょうりつ', 'อัตราของเสีย', 'defect rate', 'quality',
   '00000000-0000-7000-8000-000000000503'),
  ('成形条件', 'せいけいじょうけん', 'เงื่อนไขการขึ้นรูป', 'molding conditions', 'molding',
   '00000000-0000-7000-8000-000000000503'),
  ('水平展開', 'すいへいてんかい', 'การขยายผล', 'horizontal deployment', 'quality',
   '00000000-0000-7000-8000-000000000503');

-- ---------------------------------------------------------------------
-- 11. Operational config
-- ---------------------------------------------------------------------

INSERT INTO ops.config (key, value_json, description) VALUES
  ('alert.defect_rate_pct',        '4.0',    'Threshold for the defect-rate alert (SRS FR-U-04)'),
  ('alert.defect_rate_window_h',   '8',      'Evaluation window in hours'),
  ('agent.max_tool_calls_per_turn','5',      'Budget enforced by the executor, not by the model'),
  ('agent.max_wall_seconds',       '60',     'Hard stop for one agent turn'),
  ('brief.schedule_cron',          '"0 7 * * *"', 'Daily brief posting time'),
  ('retention.pass_image_days',    '30',     'SRS section 6.2'),
  ('retention.fail_image_days',    '730',    'SRS section 6.2');

INSERT INTO ops.scheduled_job (name, cron, enabled) VALUES
  ('daily_brief',        '0 7 * * *',   true),
  ('retention_sweep',    '0 2 * * *',   true),
  ('partition_maintain', '0 3 1 * *',   true),
  ('drift_check',        '0 */6 * * *', true),
  ('backup_full',        '0 1 * * *',   true);

COMMIT;

-- =====================================================================
-- 12. VERIFICATION — expected values the test suite asserts against
--
--     Run these after seeding. If any figure changes, either the seed or
--     an aggregation view has drifted, and the affected test cases in
--     docs/TEST-FactoryBrain-Test-Plan.md must be re-baselined.
-- =====================================================================

\echo '--- Seed verification -------------------------------------------'

\echo 'Expect 180 production_fact rows (30 days x 3 lines x 2 shifts):'
SELECT count(*) AS production_rows FROM core.production_fact;

\echo 'Expect defect_fact totals to equal production_fact qty_ng exactly:'
SELECT
    (SELECT COALESCE(SUM(qty_ng), 0) FROM core.production_fact) AS ng_from_production,
    (SELECT COALESCE(SUM(qty), 0)    FROM core.defect_fact)     AS ng_from_defects,
    ((SELECT COALESCE(SUM(qty_ng), 0) FROM core.production_fact) =
     (SELECT COALESCE(SUM(qty), 0)    FROM core.defect_fact))   AS totals_match;

\echo 'Expect L3/shift B defect rate to jump from ~2.4 pct to ~6 pct on 2026-09-08:'
SELECT
    pf.prod_date,
    ROUND(100.0 * SUM(pf.qty_ng) / NULLIF(SUM(pf.qty_produced), 0), 2) AS defect_rate_pct
FROM core.production_fact pf
JOIN core.line l ON l.id = pf.line_id
WHERE l.code = 'L3' AND pf.shift = 'B'
  AND pf.prod_date BETWEEN DATE '2026-09-05' AND DATE '2026-09-10'
GROUP BY pf.prod_date
ORDER BY pf.prod_date;

\echo 'Expect 200 inspections: 183 PASS, 12 FAIL, 5 REVIEW:'
SELECT verdict, count(*) FROM vision.inspection GROUP BY verdict ORDER BY verdict;

\echo 'Expect exactly 5 rows in the review queue:'
SELECT count(*) AS review_queue_depth FROM vision.v_review_queue;

\echo 'Expect 1 citable case (the unverified one must be excluded):'
SELECT count(*) AS citable_cases FROM knowledge.v_citable_case;

\echo 'Expect grounding health: 1 run, 0 grounding failures:'
SELECT runs, grounding_failed, grounding_failure_pct FROM agent.v_grounding_health;

\echo '--- End seed verification ---------------------------------------'
