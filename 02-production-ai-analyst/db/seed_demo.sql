-- =====================================================================
-- ShiftBrief — Deterministic demo / test dataset
-- Document : DDS-02-ShiftBrief section 10
-- Version  : 1.0
-- Date     : 2026-09-12
--
-- Apply AFTER schema.sql:
--   psql -v ON_ERROR_STOP=1 -f schema.sql
--   psql -v ON_ERROR_STOP=1 -f seed_demo.sql
--
-- PURPOSE
--   Reproduce SRS-02 Appendix A so the analytics engine, the brief and the
--   test suite can assert against known numbers:
--
--     2026-09-10  Production 12,430 pcs · Defects 382 · Defect rate 3.07 %
--                 7-day avg 2.59 % · +18.4 % · significant (p ≈ 0.002)
--                 Top defect: Missing Component — 41 % (157)
--                 Worst line: Line 3 — 5.82 % · abnormal growth in Shift B (8.82 %)
--
--   NOTE ON THE SRS FIGURE "n = 2,140": no integer NG count gives 5.82 % of
--   2,140. This seed uses n = 2,147 with 125 NG = 5.822 %. The SRS appendix
--   is recorded as internally inconsistent in the README; it is not edited.
--
--   Everything is computed from EXPLICIT per-line/per-shift quantities —
--   no random(), no modulo rules.
--
-- LAYOUT
--   30 days 2026-08-12 .. 2026-09-10 · lines L1/L2/L3 · shifts A/B
--   Days 1-29 (baseline): 11,986 produced / 311 NG per day = 2.5947 %
--   Day 30   (planted)  : 12,430 produced / 382 NG          = 3.0732 %
--   One corrected file re-covers 2026-08-20 (L2/B NG 60 -> 62): facts v1 + v2,
--   brief + REVISED brief. Outside the 7-day window so the baseline is unchanged.
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM core.production_fact LIMIT 1) THEN
        RAISE EXCEPTION
          'core.production_fact is not empty. Refusing to seed: this script assumes an empty database and its assertions depend on exact totals.';
    END IF;
END
$$;

-- ---------------------------------------------------------------------
-- 1. Master data (fixed UUIDs)
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
  ('00000000-0000-7000-8000-000000000201', 'MISSING_COMPONENT', 'ชิ้นส่วนขาด', '部品欠品',   'Missing Component', 'assembly', true),
  ('00000000-0000-7000-8000-000000000202', 'SCRATCH',           'รอยขีดข่วน',  'キズ',       'Scratch',           'surface',  false),
  ('00000000-0000-7000-8000-000000000203', 'MISSING_FIN',       'ฟินขาด',      'フィン欠品', 'Missing Fin',       'assembly', true),
  ('00000000-0000-7000-8000-000000000204', 'DENT',              'รอยบุบ',      'へこみ',     'Dent',              'surface',  false),
  ('00000000-0000-7000-8000-000000000205', 'LEAK',              'รั่ว',        '漏れ',       'Leak',              'function', true);

INSERT INTO core.shift_calendar (plant_id, shift, starts_at, ends_at, valid_from) VALUES
  ('00000000-0000-7000-8000-000000000001', 'A', '06:00', '14:00', '2026-01-01'),
  ('00000000-0000-7000-8000-000000000001', 'B', '14:00', '22:00', '2026-01-01');

-- No usable credential ships in this file (OPS section 3.4 sets real hashes).
INSERT INTO core.app_user (id, username, display_name, role, lang, password_hash) VALUES
  ('00000000-0000-7000-8000-000000000501', 'demo.viewer',   'Demo Viewer',   'viewer',   'th', 'SET_AT_BOOTSTRAP'),
  ('00000000-0000-7000-8000-000000000503', 'demo.engineer', 'Demo Engineer', 'engineer', 'en', 'SET_AT_BOOTSTRAP'),
  ('00000000-0000-7000-8000-000000000504', 'demo.manager',  'Demo Manager',  'manager',  'ja', 'SET_AT_BOOTSTRAP'),
  ('00000000-0000-7000-8000-000000000505', 'demo.admin',    'Demo Admin',    'admin',    'en', 'SET_AT_BOOTSTRAP');

-- Restricted viewer: sees L1 only (TC-081)
INSERT INTO core.user_line_scope (user_id, line_id) VALUES
  ('00000000-0000-7000-8000-000000000501', '00000000-0000-7000-8000-00000000000a');

-- ---------------------------------------------------------------------
-- 2. Intake source, mapping, expectation
-- ---------------------------------------------------------------------

INSERT INTO analytics.source (id, code, name, kind, location, file_pattern, encoding, plant_id) VALUES
  ('00000000-0000-7000-8000-000000000601', 'mes_daily', 'MES daily production export', 'folder',
   '/data/incoming/mes', 'production_*.csv', 'utf-8', '00000000-0000-7000-8000-000000000001');

INSERT INTO analytics.source_mapping (id, source_id, version, mapping_yaml, header_fingerprint, reason, created_by, active_from) VALUES
  ('00000000-0000-7000-8000-000000000611', '00000000-0000-7000-8000-000000000601', 1,
$yaml$schema_version: 1
source: mes_daily
delimiter: ","
date_format: "%Y-%m-%d"
columns:
  prod_date:     { from: "Date" }
  shift:         { from: "Shift",     map: { "1": "A", "2": "B", "A": "A", "B": "B" } }
  line:          { from: "Line",      map: { "Line 1": "L1", "Line 2": "L2", "Line 3": "L3" } }
  sku:           { from: "Item Code" }
  qty_produced:  { from: "Output Qty", type: int, min: 0 }
  qty_ng:        { from: "NG Qty",     type: int, min: 0 }
  defect_code:   { from: "Defect",     optional: true }
  defect_qty:    { from: "Defect Qty", type: int, optional: true }
  runtime_min:   { from: "Run Min",    type: number, optional: true }
  downtime_min:  { from: "Down Min",   type: number, optional: true }
  operator_id:   { from: "Operator",   optional: true, pii: pseudonymise }
rules:
  - qty_ng <= qty_produced
  - line in known_lines
  - sku in known_skus
  - defect_code in known_defect_codes
$yaml$,
   encode(digest('date|shift|line|item code|output qty|ng qty|defect|defect qty|run min|down min|operator', 'sha256'), 'hex'),
   'Initial mapping for the MES export as delivered 2026-08-11',
   '00000000-0000-7000-8000-000000000503', '2026-08-11 00:00+07');

INSERT INTO analytics.file_expectation (source_id, cadence, expected_by, grace_minutes) VALUES
  ('00000000-0000-7000-8000-000000000601', 'daily', '09:00', 30);

-- ---------------------------------------------------------------------
-- 3. Ingest batches
--    B1 initial 30-day load: 183 rows, 180 ok, 3 quarantined (committed)
--    B2 a bad file: 24 rows, 3 quarantined = 12.5 % (REJECTED, nothing committed)
--    B3 corrected file for 2026-08-20: 6 rows ok (committed, supersedes B1 for that date)
-- ---------------------------------------------------------------------

INSERT INTO core.ingest_batch (id, source, filename, sha256, rows_total, rows_ok, rows_quarantined, status, reject_reason, archive_uri, started_at, finished_at) VALUES
  ('00000000-0000-7000-8000-000000000701', 'mes_daily', 'production_2026-08-12_2026-09-10.csv', repeat('1', 64),
   183, 180, 3, 'succeeded', NULL, 's3://archives/mes_daily/2026-09-10/production_2026-08-12_2026-09-10.csv',
   '2026-09-10 22:41+07', '2026-09-10 22:43+07'),
  ('00000000-0000-7000-8000-000000000702', 'mes_daily', 'production_2026-09-11_bad.csv', repeat('2', 64),
   24, 0, 3, 'rejected', '3 of 24 rows invalid (12.5 %) exceeds the 5 % threshold; nothing committed',
   's3://archives/mes_daily/2026-09-11/production_2026-09-11_bad.csv',
   '2026-09-11 06:41+07', '2026-09-11 06:41+07'),
  ('00000000-0000-7000-8000-000000000703', 'mes_daily', 'production_2026-08-20_corrected.csv', repeat('3', 64),
   6, 6, 0, 'succeeded', NULL, 's3://archives/mes_daily/2026-08-21/production_2026-08-20_corrected.csv',
   '2026-08-21 11:30+07', '2026-08-21 11:30+07');

INSERT INTO analytics.batch_detail (batch_id, source_id, mapping_id, disposition, dates_covered, supersedes_batch_id, header_seen) VALUES
  ('00000000-0000-7000-8000-000000000701', '00000000-0000-7000-8000-000000000601', '00000000-0000-7000-8000-000000000611',
   'committed', daterange('2026-08-12', '2026-09-10', '[]'), NULL,
   ARRAY['Date','Shift','Line','Item Code','Output Qty','NG Qty','Defect','Defect Qty','Run Min','Down Min','Operator']),
  ('00000000-0000-7000-8000-000000000702', '00000000-0000-7000-8000-000000000601', '00000000-0000-7000-8000-000000000611',
   'rejected', daterange('2026-09-11', '2026-09-11', '[]'), NULL,
   ARRAY['Date','Shift','Line','Item Code','Output Qty','NG Qty','Defect','Defect Qty','Run Min','Down Min','Operator']),
  ('00000000-0000-7000-8000-000000000703', '00000000-0000-7000-8000-000000000601', '00000000-0000-7000-8000-000000000611',
   'committed', daterange('2026-08-20', '2026-08-20', '[]'), '00000000-0000-7000-8000-000000000701',
   ARRAY['Date','Shift','Line','Item Code','Output Qty','NG Qty','Defect','Defect Qty','Run Min','Down Min','Operator']);

-- Quarantined rows: reasons written for the data owner, not the developer
INSERT INTO core.quarantine_row (batch_id, row_no, raw_json, reason) VALUES
  ('00000000-0000-7000-8000-000000000701', 181,
   '{"Date":"2026-09-10","Shift":"B","Line":"Line 3","Item Code":"CND-220-X","Output Qty":"40","NG Qty":"48"}',
   'row 181: NG Qty (48) exceeds Output Qty (40)'),
  ('00000000-0000-7000-8000-000000000701', 182,
   '{"Date":"2026-09-10","Shift":"A","Line":"Line 4","Item Code":"RAD-500-A","Output Qty":"120","NG Qty":"2"}',
   'row 182: Line "Line 4" is not a known line (known: Line 1, Line 2, Line 3)'),
  ('00000000-0000-7000-8000-000000000701', 183,
   '{"Date":"10/09/2026","Shift":"A","Line":"Line 1","Item Code":"RAD-500-A","Output Qty":"100","NG Qty":"1"}',
   'row 183: Date "10/09/2026" does not match the expected format YYYY-MM-DD'),
  ('00000000-0000-7000-8000-000000000702', 3,
   '{"Date":"2026-09-11","Shift":"A","Line":"Line 1","Item Code":"RAD-500-A","Output Qty":"-5","NG Qty":"0"}',
   'row 3: Output Qty (-5) must be >= 0'),
  ('00000000-0000-7000-8000-000000000702', 9,
   '{"Date":"2026-09-11","Shift":"C","Line":"Line 2","Item Code":"RAD-500-B","Output Qty":"900","NG Qty":"20"}',
   'row 9: Shift "C" is not defined in the shift calendar for 2026-09-11'),
  ('00000000-0000-7000-8000-000000000702', 17,
   '{"Date":"2026-09-11","Shift":"B","Line":"Line 3","Item Code":"XYZ-1","Output Qty":"500","NG Qty":"10"}',
   'row 17: Item Code "XYZ-1" is not a known SKU');

-- ---------------------------------------------------------------------
-- 4. Production facts — 30 days x 3 lines x 2 shifts from explicit quantities
-- ---------------------------------------------------------------------

WITH days AS (
    SELECT d::date AS prod_date, (d::date = DATE '2026-09-10') AS is_planted
    FROM generate_series(DATE '2026-08-12', DATE '2026-09-10', INTERVAL '1 day') d
),
plan (line_code, shift, base_produced, base_ng, d30_produced, d30_ng) AS (
    VALUES
      ('L1', 'A'::core.shift_code, 2451, 58, 2570, 63),
      ('L1', 'B'::core.shift_code, 2451, 60, 2570, 65),
      ('L2', 'A'::core.shift_code, 2471, 60, 2572, 64),
      ('L2', 'B'::core.shift_code, 2471, 60, 2571, 65),
      ('L3', 'A'::core.shift_code, 1071, 36, 1070, 30),
      ('L3', 'B'::core.shift_code, 1071, 37, 1077, 95)    -- planted: Shift B on Line 3
)
INSERT INTO core.production_fact
      (prod_date, shift, line_id, sku_id, qty_produced, qty_ng, runtime_min, downtime_min, batch_id)
SELECT
    dd.prod_date, p.shift, l.id,
    CASE p.line_code WHEN 'L1' THEN '00000000-0000-7000-8000-000000000101'::uuid
                     WHEN 'L2' THEN '00000000-0000-7000-8000-000000000102'::uuid
                     ELSE          '00000000-0000-7000-8000-000000000103'::uuid END,
    CASE WHEN dd.is_planted THEN p.d30_produced ELSE p.base_produced END,
    CASE WHEN dd.is_planted THEN p.d30_ng       ELSE p.base_ng       END,
    440.0, 40.0,
    '00000000-0000-7000-8000-000000000701'
FROM days dd
CROSS JOIN plan p
JOIN core.line l ON l.code = p.line_code;

-- ---------------------------------------------------------------------
-- 5. Defect facts — explicit per (line, shift, code) quantities
--    Every (line, shift) code sum equals that shift's qty_ng.
-- ---------------------------------------------------------------------

WITH days AS (
    SELECT d::date AS prod_date, (d::date = DATE '2026-09-10') AS is_planted
    FROM generate_series(DATE '2026-08-12', DATE '2026-09-10', INTERVAL '1 day') d
),
plan (line_code, shift, code, base_qty, d30_qty) AS (
    VALUES
      -- L1 / A  (base 58, day30 63)
      ('L1','A','MISSING_COMPONENT',17,19), ('L1','A','SCRATCH',15,18), ('L1','A','MISSING_FIN',12,14), ('L1','A','DENT',9,7),  ('L1','A','LEAK',5,5),
      -- L1 / B  (base 60, day30 65)
      ('L1','B','MISSING_COMPONENT',18,20), ('L1','B','SCRATCH',15,18), ('L1','B','MISSING_FIN',12,14), ('L1','B','DENT',9,8),  ('L1','B','LEAK',6,5),
      -- L2 / A  (base 60, day30 64)
      ('L2','A','MISSING_COMPONENT',18,19), ('L2','A','SCRATCH',15,18), ('L2','A','MISSING_FIN',12,14), ('L2','A','DENT',9,8),  ('L2','A','LEAK',6,5),
      -- L2 / B  (base 60, day30 65)
      ('L2','B','MISSING_COMPONENT',18,20), ('L2','B','SCRATCH',15,18), ('L2','B','MISSING_FIN',12,14), ('L2','B','DENT',9,8),  ('L2','B','LEAK',6,5),
      -- L3 / A  (base 36, day30 30)
      ('L3','A','MISSING_COMPONENT',11,12), ('L3','A','SCRATCH',9,7),   ('L3','A','MISSING_FIN',7,6),   ('L3','A','DENT',5,3),  ('L3','A','LEAK',4,2),
      -- L3 / B  (base 37, day30 95)  <- planted concentration of MISSING_COMPONENT
      ('L3','B','MISSING_COMPONENT',11,67), ('L3','B','SCRATCH',9,11),  ('L3','B','MISSING_FIN',7,8),   ('L3','B','DENT',6,6),  ('L3','B','LEAK',4,3)
)
INSERT INTO core.defect_fact (prod_date, shift, line_id, sku_id, defect_type_id, qty, batch_id)
SELECT
    dd.prod_date, p.shift::core.shift_code, l.id,
    CASE p.line_code WHEN 'L1' THEN '00000000-0000-7000-8000-000000000101'::uuid
                     WHEN 'L2' THEN '00000000-0000-7000-8000-000000000102'::uuid
                     ELSE          '00000000-0000-7000-8000-000000000103'::uuid END,
    dt.id,
    CASE WHEN dd.is_planted THEN p.d30_qty ELSE p.base_qty END,
    '00000000-0000-7000-8000-000000000701'
FROM days dd
CROSS JOIN plan p
JOIN core.line l ON l.code = p.line_code
JOIN core.defect_type dt ON dt.code = p.code;

-- Corrected file (batch B3): 2026-08-20 L2/B NG 60 -> 62, SCRATCH 15 -> 17.
UPDATE core.production_fact
   SET qty_ng = 62, batch_id = '00000000-0000-7000-8000-000000000703'
 WHERE prod_date = DATE '2026-08-20' AND shift = 'B' AND line_id = '00000000-0000-7000-8000-00000000000b';
UPDATE core.defect_fact
   SET qty = 17, batch_id = '00000000-0000-7000-8000-000000000703'
 WHERE prod_date = DATE '2026-08-20' AND shift = 'B' AND line_id = '00000000-0000-7000-8000-00000000000b'
   AND defect_type_id = '00000000-0000-7000-8000-000000000202';

-- ---------------------------------------------------------------------
-- 6. Agent tool registry (the capability boundary) — ADR-S07
-- ---------------------------------------------------------------------

INSERT INTO agent.tool (name, kind, risk, min_role, enabled, schema_json) VALUES
  ('kpi_summary',          'read',  'low',    'viewer',   true,
   '{"type":"object","required":["date_from","date_to"],"properties":{"date_from":{"type":"string","format":"date"},"date_to":{"type":"string","format":"date"},"line":{"type":"string"},"shift":{"type":"string"},"sku":{"type":"string"},"baseline_days":{"type":"integer","default":7}}}'),
  ('defect_pareto',        'read',  'low',    'viewer',   true,
   '{"type":"object","required":["date_from","date_to"],"properties":{"date_from":{"type":"string"},"date_to":{"type":"string"},"line":{"type":"string"},"top_n":{"type":"integer","default":5}}}'),
  ('line_shift_breakdown', 'read',  'low',    'viewer',   true,
   '{"type":"object","required":["date_from","date_to"],"properties":{"date_from":{"type":"string"},"date_to":{"type":"string"}}}'),
  ('trend',                'read',  'low',    'viewer',   true,
   '{"type":"object","required":["date_to"],"properties":{"date_to":{"type":"string"},"days":{"type":"integer","default":30},"line":{"type":"string"}}}'),
  ('significance',         'read',  'low',    'viewer',   true,
   '{"type":"object","required":["date"],"properties":{"date":{"type":"string"},"line":{"type":"string"},"baseline_days":{"type":"integer","default":7}}}'),
  ('oee',                  'read',  'low',    'viewer',   true,
   '{"type":"object","required":["date_from","date_to"],"properties":{"date_from":{"type":"string"},"date_to":{"type":"string"},"line":{"type":"string"}}}'),
  ('compare_periods',      'read',  'low',    'viewer',   true,
   '{"type":"object","required":["a_from","a_to","b_from","b_to"],"properties":{"a_from":{"type":"string"},"a_to":{"type":"string"},"b_from":{"type":"string"},"b_to":{"type":"string"},"line":{"type":"string"}}}'),
  ('get_facts',            'read',  'low',    'viewer',   true,
   '{"type":"object","required":["date"],"properties":{"date":{"type":"string"},"line":{"type":"string"}}}'),
  ('run_sql',              'read',  'medium', 'engineer', false,
   '{"type":"object","required":["question"],"properties":{"question":{"type":"string"}},"x-note":"Disabled by default (ENABLE_TEXT_TO_SQL). SELECT-only over whitelisted views as agent_ro with LIMIT and statement_timeout."}'),
  ('send_discord',         'write', 'low',    'manager',  true,
   '{"type":"object","required":["channel","message"],"properties":{"channel":{"type":"string"},"message":{"type":"string"}}}');

-- ---------------------------------------------------------------------
-- 7. Facts objects (the product) — hashed at insert
-- ---------------------------------------------------------------------

-- Day 30, plant-wide (the Appendix A brief is written from this row)
INSERT INTO analytics.facts (id, fact_date, line_id, facts_version, facts_json, facts_sha256, significant, p_value, data_complete, source_batches, computed_at)
SELECT '00000000-0000-7000-8000-000000000a01', DATE '2026-09-10', NULL, '1.0', j,
       encode(digest(j::text, 'sha256'), 'hex'), true, 0.00196, true,
       ARRAY['00000000-0000-7000-8000-000000000701'::uuid], '2026-09-10 22:44+07'
FROM (SELECT $j$
{
  "facts_version": "1.0",
  "date": "2026-09-10",
  "scope": {"plant": "P1", "line": null},
  "totals": {"produced": 12430, "ng": 382, "defect_rate_pct": 3.0732},
  "baseline": {
    "d1":  {"produced": 11986, "ng": 311,  "defect_rate_pct": 2.5947},
    "d7":  {"produced": 83902, "ng": 2177, "defect_rate_pct": 2.5947},
    "d30": {"produced": 347594, "ng": 9021, "defect_rate_pct": 2.5953}
  },
  "change": {"vs_d1_pct": 18.4, "vs_d7_pct": 18.4, "vs_d30_pct": 18.4},
  "significance": {"test": "two_proportion_z", "vs": "d7", "z": 3.096, "p_value": 0.00196, "alpha": 0.05, "significant": true},
  "by_line": [
    {"line": "L1", "produced": 5140, "ng": 128, "defect_rate_pct": 2.4903, "rankable": true},
    {"line": "L2", "produced": 5143, "ng": 129, "defect_rate_pct": 2.5083, "rankable": true},
    {"line": "L3", "produced": 2147, "ng": 125, "defect_rate_pct": 5.8221, "rankable": true}
  ],
  "by_shift": [
    {"shift": "A", "produced": 6212, "ng": 157, "defect_rate_pct": 2.5274},
    {"shift": "B", "produced": 6218, "ng": 225, "defect_rate_pct": 3.6185}
  ],
  "by_line_shift": [
    {"line": "L3", "shift": "A", "produced": 1070, "ng": 30, "defect_rate_pct": 2.8037},
    {"line": "L3", "shift": "B", "produced": 1077, "ng": 95, "defect_rate_pct": 8.8208}
  ],
  "pareto": [
    {"code": "MISSING_COMPONENT", "qty": 157, "share_pct": 41.1, "cumulative_pct": 41.1, "is_critical": true},
    {"code": "SCRATCH",           "qty": 90,  "share_pct": 23.6, "cumulative_pct": 64.7, "is_critical": false},
    {"code": "MISSING_FIN",       "qty": 70,  "share_pct": 18.3, "cumulative_pct": 83.0, "is_critical": true},
    {"code": "DENT",              "qty": 40,  "share_pct": 10.5, "cumulative_pct": 93.5, "is_critical": false},
    {"code": "LEAK",              "qty": 25,  "share_pct": 6.5,  "cumulative_pct": 100.0,"is_critical": true}
  ],
  "worst": {
    "line":  {"line": "L3", "defect_rate_pct": 5.8221, "n": 2147, "baseline_pct": 3.408},
    "shift": {"shift": "B", "defect_rate_pct": 3.6185},
    "sku":   {"sku": "CND-220-X", "defect_rate_pct": 5.8221},
    "line_shift": {"line": "L3", "shift": "B", "defect_rate_pct": 8.8208, "top_code": "MISSING_COMPONENT", "top_code_share_pct": 70.5}
  },
  "trend": {"consecutive_rise_days": 1, "level_shift": false, "outlier_3sigma": true},
  "oee": {"availability_pct": 91.67, "quality_pct": 96.93, "performance_pct": null},
  "completeness": {"expected_shifts": 6, "present_shifts": 6, "complete": true},
  "meta": {"computed_at": "2026-09-10T22:44:00+07:00", "source_batches": ["00000000-0000-7000-8000-000000000701"]}
}
$j$::jsonb AS j) x;

-- Day 30, Line 3 only
INSERT INTO analytics.facts (id, fact_date, line_id, facts_version, facts_json, facts_sha256, significant, p_value, data_complete, source_batches, computed_at)
SELECT '00000000-0000-7000-8000-000000000a02', DATE '2026-09-10', '00000000-0000-7000-8000-00000000000c', '1.0', j,
       encode(digest(j::text, 'sha256'), 'hex'), true, 0.00012, true,
       ARRAY['00000000-0000-7000-8000-000000000701'::uuid], '2026-09-10 22:44+07'
FROM (SELECT $j$
{"facts_version":"1.0","date":"2026-09-10","scope":{"plant":"P1","line":"L3"},
 "totals":{"produced":2147,"ng":125,"defect_rate_pct":5.8221},
 "baseline":{"d7":{"produced":14994,"ng":511,"defect_rate_pct":3.4080}},
 "change":{"vs_d7_pct":70.8},
 "significance":{"test":"two_proportion_z","vs":"d7","z":3.85,"p_value":0.00012,"alpha":0.05,"significant":true},
 "by_shift":[{"shift":"A","produced":1070,"ng":30,"defect_rate_pct":2.8037},{"shift":"B","produced":1077,"ng":95,"defect_rate_pct":8.8208}],
 "pareto":[{"code":"MISSING_COMPONENT","qty":79,"share_pct":63.2,"cumulative_pct":63.2,"is_critical":true},{"code":"SCRATCH","qty":18,"share_pct":14.4,"cumulative_pct":77.6,"is_critical":false},{"code":"MISSING_FIN","qty":14,"share_pct":11.2,"cumulative_pct":88.8,"is_critical":true},{"code":"DENT","qty":9,"share_pct":7.2,"cumulative_pct":96.0,"is_critical":false},{"code":"LEAK","qty":5,"share_pct":4.0,"cumulative_pct":100.0,"is_critical":true}],
 "worst":{"shift":{"shift":"B","defect_rate_pct":8.8208}},
 "completeness":{"expected_shifts":2,"present_shifts":2,"complete":true},
 "meta":{"computed_at":"2026-09-10T22:44:00+07:00","source_batches":["00000000-0000-7000-8000-000000000701"]}}
$j$::jsonb AS j) x;

-- Day 29 (2026-09-09), plant-wide: a normal day -> not significant
INSERT INTO analytics.facts (id, fact_date, line_id, facts_version, facts_json, facts_sha256, significant, p_value, data_complete, source_batches, computed_at)
SELECT '00000000-0000-7000-8000-000000000a03', DATE '2026-09-09', NULL, '1.0', j,
       encode(digest(j::text, 'sha256'), 'hex'), false, 1.0, true,
       ARRAY['00000000-0000-7000-8000-000000000701'::uuid], '2026-09-09 22:44+07'
FROM (SELECT $j$
{"facts_version":"1.0","date":"2026-09-09","scope":{"plant":"P1","line":null},
 "totals":{"produced":11986,"ng":311,"defect_rate_pct":2.5947},
 "baseline":{"d7":{"produced":83902,"ng":2177,"defect_rate_pct":2.5947}},
 "change":{"vs_d7_pct":0.0},
 "significance":{"test":"two_proportion_z","vs":"d7","z":0.0,"p_value":1.0,"alpha":0.05,"significant":false},
 "pareto":[{"code":"MISSING_COMPONENT","qty":93,"share_pct":29.9,"cumulative_pct":29.9,"is_critical":true}],
 "completeness":{"expected_shifts":6,"present_shifts":6,"complete":true},
 "meta":{"computed_at":"2026-09-09T22:44:00+07:00","source_batches":["00000000-0000-7000-8000-000000000701"]}}
$j$::jsonb AS j) x;

-- Day 9 (2026-08-20): v1 from the original file, v2 after the corrected file
INSERT INTO analytics.facts (id, fact_date, line_id, facts_version, facts_json, facts_sha256, significant, p_value, data_complete, source_batches, computed_at)
SELECT '00000000-0000-7000-8000-000000000a04', DATE '2026-08-20', NULL, '1.0', j,
       encode(digest(j::text, 'sha256'), 'hex'), false, 0.97, true,
       ARRAY['00000000-0000-7000-8000-000000000701'::uuid], '2026-08-20 22:44+07'
FROM (SELECT $j$
{"facts_version":"1.0","date":"2026-08-20","scope":{"plant":"P1","line":null},
 "totals":{"produced":11986,"ng":311,"defect_rate_pct":2.5947},
 "significance":{"test":"two_proportion_z","vs":"d7","p_value":0.97,"significant":false},
 "completeness":{"expected_shifts":6,"present_shifts":6,"complete":true},
 "meta":{"computed_at":"2026-08-20T22:44:00+07:00","source_batches":["00000000-0000-7000-8000-000000000701"],"revision":1}}
$j$::jsonb AS j) x;

INSERT INTO analytics.facts (id, fact_date, line_id, facts_version, facts_json, facts_sha256, significant, p_value, data_complete, source_batches, computed_at)
SELECT '00000000-0000-7000-8000-000000000a05', DATE '2026-08-20', NULL, '1.0-r2', j,
       encode(digest(j::text, 'sha256'), 'hex'), false, 0.95, true,
       ARRAY['00000000-0000-7000-8000-000000000701'::uuid, '00000000-0000-7000-8000-000000000703'::uuid], '2026-08-21 11:31+07'
FROM (SELECT $j$
{"facts_version":"1.0-r2","date":"2026-08-20","scope":{"plant":"P1","line":null},
 "totals":{"produced":11986,"ng":313,"defect_rate_pct":2.6114},
 "significance":{"test":"two_proportion_z","vs":"d7","p_value":0.95,"significant":false},
 "completeness":{"expected_shifts":6,"present_shifts":6,"complete":true},
 "meta":{"computed_at":"2026-08-21T11:31:00+07:00","source_batches":["00000000-0000-7000-8000-000000000701","00000000-0000-7000-8000-000000000703"],"revision":2,"supersedes":"00000000-0000-7000-8000-000000000a04"}}
$j$::jsonb AS j) x;

-- Day 28 (2026-09-08): facts for the withheld brief
INSERT INTO analytics.facts (id, fact_date, line_id, facts_version, facts_json, facts_sha256, significant, p_value, data_complete, source_batches, computed_at)
SELECT '00000000-0000-7000-8000-000000000a06', DATE '2026-09-08', NULL, '1.0', j,
       encode(digest(j::text, 'sha256'), 'hex'), false, 1.0, true,
       ARRAY['00000000-0000-7000-8000-000000000701'::uuid], '2026-09-08 22:44+07'
FROM (SELECT $j$
{"facts_version":"1.0","date":"2026-09-08","scope":{"plant":"P1","line":null},
 "totals":{"produced":11986,"ng":311,"defect_rate_pct":2.5947},
 "significance":{"test":"two_proportion_z","vs":"d7","p_value":1.0,"significant":false},
 "completeness":{"expected_shifts":6,"present_shifts":6,"complete":true},
 "meta":{"computed_at":"2026-09-08T22:44:00+07:00","source_batches":["00000000-0000-7000-8000-000000000701"]}}
$j$::jsonb AS j) x;

-- ---------------------------------------------------------------------
-- 8. Agent runs and briefs
-- ---------------------------------------------------------------------

INSERT INTO agent.run (id, ts, user_id, correlation_id, kind, question, answer, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome, grounding_json) VALUES
  ('00000000-0000-7000-8000-000000000f01', '2026-09-10 23:00+07', NULL, 'seed-brief-0910-en', 'brief', 'daily brief 2026-09-10 en',
   'Production Report — 2026-09-10. Production: 12,430 pcs. Defects: 382 pcs. Defect rate: 3.07 % (7-day avg 2.59 %, +18.4 %, p = 0.002 → significant). '
   'Top defect: Missing Component — 41 %. Worst line: Line 3 — 5.82 % (n = 2,147). '
   'Line 3 shows abnormal defect growth during Shift B (8.82 % vs 2.80 % in Shift A); Missing Component accounts for 63 % of Line 3 defects. Other lines are within normal variation. '
   'Recommended action: 1. Check the component feeder on Line 3. 2. Review Shift B changeover records on Line 3. Note: correlation only; root cause not verified.',
   'qwen3:8b', 'brief.v1.2', (SELECT facts_json FROM analytics.facts WHERE id = '00000000-0000-7000-8000-000000000a01'),
   1510, 220, 41000, 0, 'ok',
   '{"numbers_found":["2026-09-10","12430","382","3.07","2.59","18.4","0.002","41","3","5.82","2147","8.82","2.80","63","1","2"],"all_matched":true}'),
  ('00000000-0000-7000-8000-000000000f02', '2026-09-09 23:00+07', NULL, 'seed-brief-0909-en', 'brief', 'daily brief 2026-09-09 en',
   'Production Report — 2026-09-09. Production: 11,986 pcs. Defects: 311 pcs. Defect rate: 2.59 %, within normal variation versus the 7-day average (2.59 %, p = 1.00). No action recommended.',
   'qwen3:8b', 'brief.v1.2', (SELECT facts_json FROM analytics.facts WHERE id = '00000000-0000-7000-8000-000000000a03'),
   980, 70, 22000, 0, 'ok', '{"numbers_found":["2026-09-09","11986","311","2.59","2.59","1.00"],"all_matched":true}'),
  ('00000000-0000-7000-8000-000000000f03', '2026-09-08 23:00+07', NULL, 'seed-brief-0908-en', 'brief', 'daily brief 2026-09-08 en',
   NULL, 'qwen3:8b', 'brief.v1.2', (SELECT facts_json FROM analytics.facts WHERE id = '00000000-0000-7000-8000-000000000a06'),
   980, 88, 24000, 0, 'grounding_failed', '{"numbers_found":["11986","311","2.59","4.7"],"all_matched":false,"unmatched":["4.7"]}'),
  ('00000000-0000-7000-8000-000000000f04', '2026-09-11 08:12+07', '00000000-0000-7000-8000-000000000504', 'seed-ask-0001', 'ask',
   'Why did the defect rate increase yesterday?',
   'The defect rate on 2026-09-10 was 3.07 % against a 7-day average of 2.59 % (+18.4 %, p = 0.002, significant). '
   'The increase is concentrated on Line 3 (5.82 %), specifically Shift B (8.82 % vs 2.80 % in Shift A), where Missing Component is 63 % of defects. '
   'Lines 1 and 2 are within normal variation. This is an association; I cannot see machine or material data to say why.',
   'qwen3:8b', 'ask.v1.1', NULL, 1620, 140, 12400, 3, 'ok',
   '{"numbers_found":["2026-09-10","3.07","2.59","18.4","0.002","3","5.82","8.82","2.80","63","1","2"],"all_matched":true}');

INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, row_count, duration_ms, ok) VALUES
  ('00000000-0000-7000-8000-000000000f04', 1, 'significance',        '{"date":"2026-09-10","baseline_days":7}', 1, 21, true),
  ('00000000-0000-7000-8000-000000000f04', 2, 'line_shift_breakdown','{"date_from":"2026-09-10","date_to":"2026-09-10"}', 6, 18, true),
  ('00000000-0000-7000-8000-000000000f04', 3, 'defect_pareto',       '{"date_from":"2026-09-10","date_to":"2026-09-10","line":"L3","top_n":5}', 5, 16, true);

INSERT INTO analytics.brief (id, kind, brief_date, line_id, lang, tone, facts_id, run_id, text, sources_json, grounding_json, withheld, withheld_reason, model, prompt_version, revised_of, delivered_at, delivery_json) VALUES
  -- Day 30 EN (Appendix A)
  ('00000000-0000-7000-8000-000000000b01', 'daily', DATE '2026-09-10', NULL, 'en', 'short',
   '00000000-0000-7000-8000-000000000a01', '00000000-0000-7000-8000-000000000f01',
   (SELECT answer FROM agent.run WHERE id = '00000000-0000-7000-8000-000000000f01'),
   '[{"kind":"facts","facts_id":"00000000-0000-7000-8000-000000000a01","facts_version":"1.0"}]',
   (SELECT grounding_json FROM agent.run WHERE id = '00000000-0000-7000-8000-000000000f01'),
   false, NULL, 'qwen3:8b', 'brief.v1.2', NULL, '2026-09-11 07:00+07', '{"discord_message_id":"1290000000000000001","channel":"#production"}'),
  -- Day 30 TH
  ('00000000-0000-7000-8000-000000000b02', 'daily', DATE '2026-09-10', NULL, 'th', 'short',
   '00000000-0000-7000-8000-000000000a01', NULL,
   'รายงานการผลิต — 2026-09-10 · ผลิต 12,430 ชิ้น · ของเสีย 382 ชิ้น · อัตราของเสีย 3.07 % (ค่าเฉลี่ย 7 วัน 2.59 %, +18.4 %, p = 0.002 → มีนัยสำคัญ) · ของเสียหลัก: ชิ้นส่วนขาด 41 % · ไลน์ที่แย่ที่สุด: ไลน์ 3 — 5.82 % (n = 2,147) · ไลน์ 3 กะ B สูงผิดปกติ (8.82 %) · ข้อเสนอแนะ: ตรวจสอบเครื่องป้อนชิ้นส่วนไลน์ 3 และบันทึกการเปลี่ยนกะ B · หมายเหตุ: เป็นความสัมพันธ์เท่านั้น ยังไม่ยืนยันสาเหตุ',
   '[{"kind":"facts","facts_id":"00000000-0000-7000-8000-000000000a01","facts_version":"1.0"}]',
   '{"numbers_found":["2026-09-10","12430","382","3.07","2.59","18.4","0.002","41","3","5.82","2147","8.82"],"all_matched":true}',
   false, NULL, 'qwen3:8b', 'brief.v1.2', NULL, '2026-09-11 07:00+07', '{"discord_message_id":"1290000000000000002","channel":"#production-th"}'),
  -- Day 29: within normal variation
  ('00000000-0000-7000-8000-000000000b03', 'daily', DATE '2026-09-09', NULL, 'en', 'short',
   '00000000-0000-7000-8000-000000000a03', '00000000-0000-7000-8000-000000000f02',
   (SELECT answer FROM agent.run WHERE id = '00000000-0000-7000-8000-000000000f02'),
   '[{"kind":"facts","facts_id":"00000000-0000-7000-8000-000000000a03","facts_version":"1.0"}]',
   (SELECT grounding_json FROM agent.run WHERE id = '00000000-0000-7000-8000-000000000f02'),
   false, NULL, 'qwen3:8b', 'brief.v1.2', NULL, '2026-09-10 07:00+07', '{"discord_message_id":"1290000000000000003","channel":"#production"}'),
  -- Day 9 original
  ('00000000-0000-7000-8000-000000000b04', 'daily', DATE '2026-08-20', NULL, 'en', 'short',
   '00000000-0000-7000-8000-000000000a04', NULL,
   'Production Report — 2026-08-20. Production: 11,986 pcs. Defects: 311 pcs. Defect rate: 2.59 %, within normal variation versus the 7-day average. No action recommended.',
   '[{"kind":"facts","facts_id":"00000000-0000-7000-8000-000000000a04","facts_version":"1.0"}]',
   '{"numbers_found":["2026-08-20","11986","311","2.59"],"all_matched":true}',
   false, NULL, 'qwen3:8b', 'brief.v1.2', NULL, '2026-08-21 07:00+07', '{"discord_message_id":"1290000000000000004","channel":"#production"}'),
  -- Day 9 REVISED after the corrected file
  ('00000000-0000-7000-8000-000000000b05', 'daily', DATE '2026-08-20', NULL, 'en', 'short',
   '00000000-0000-7000-8000-000000000a05', NULL,
   'REVISED — Production Report — 2026-08-20. A corrected file was received 2026-08-21 11:30. Defects: 313 pcs (was 311). Defect rate: 2.61 % (was 2.59 %), still within normal variation versus the 7-day average. No action recommended.',
   '[{"kind":"facts","facts_id":"00000000-0000-7000-8000-000000000a05","facts_version":"1.0-r2"},{"kind":"facts","facts_id":"00000000-0000-7000-8000-000000000a04","facts_version":"1.0","role":"previous"}]',
   '{"numbers_found":["2026-08-20","2026-08-21","11","30","313","311","2.61","2.59"],"all_matched":true}',
   false, NULL, 'qwen3:8b', 'brief.v1.2', '00000000-0000-7000-8000-000000000b04', '2026-08-21 11:35+07', '{"discord_message_id":"1290000000000000005","channel":"#production"}'),
  -- Day 28 WITHHELD (grounding failed): stores no text
  ('00000000-0000-7000-8000-000000000b06', 'daily', DATE '2026-09-08', NULL, 'en', 'short',
   '00000000-0000-7000-8000-000000000a06', '00000000-0000-7000-8000-000000000f03',
   NULL,
   '[]', '{"all_matched":false,"unmatched":["4.7"]}',
   true, 'GROUNDING_FAILED: value 4.7 not present in the facts object', 'qwen3:8b', 'brief.v1.2', NULL, NULL, NULL);

INSERT INTO analytics.subscription (channel, target, lang, tone, kinds, created_by) VALUES
  ('discord', '#production',    'en', 'short', '{daily}', '00000000-0000-7000-8000-000000000505'),
  ('discord', '#production-th', 'th', 'short', '{daily}', '00000000-0000-7000-8000-000000000505'),
  ('email',   'plant-manager@example.local', 'ja', 'long', '{daily}', '00000000-0000-7000-8000-000000000505');

INSERT INTO analytics.alert_event (ts, kind, severity, fact_date, line_id, detail_json, delivered_at) VALUES
  ('2026-09-10 22:45+07', 'defect_rate_change', 'warning', DATE '2026-09-10', '00000000-0000-7000-8000-00000000000c',
   '{"line":"L3","defect_rate_pct":5.8221,"baseline_pct":3.408,"change_pct":70.8,"p_value":0.00012}', '2026-09-10 22:46+07'),
  ('2026-09-11 06:41+07', 'batch_rejected', 'critical', DATE '2026-09-11', NULL,
   '{"batch_id":"00000000-0000-7000-8000-000000000702","invalid_pct":12.5,"threshold_pct":5}', '2026-09-11 06:41+07'),
  ('2026-09-08 23:00+07', 'brief_withheld', 'warning', DATE '2026-09-08', NULL,
   '{"brief_id":"00000000-0000-7000-8000-000000000b06","unmatched":["4.7"]}', '2026-09-08 23:01+07'),
  ('2026-08-21 11:35+07', 'brief_revised', 'info', DATE '2026-08-20', NULL,
   '{"brief_id":"00000000-0000-7000-8000-000000000b05","revised_of":"00000000-0000-7000-8000-000000000b04","ng_before":311,"ng_after":313}', '2026-08-21 11:35+07');

-- ---------------------------------------------------------------------
-- 9. Ops config and jobs
-- ---------------------------------------------------------------------

INSERT INTO ops.config (key, value_json, description) VALUES
  ('alert.defect_rate_pct',         '4.0',         'Absolute threshold alert (SRS-02 FR-28)'),
  ('alert.defect_rate_change_pct',  '25.0',        'Relative-change alert vs 7-day baseline'),
  ('analytics.min_rank_volume',     '100',         'ADR-S04: groups below this are never ranked "worst"'),
  ('analytics.significance_alpha',  '0.05',        'Two-proportion z-test alpha'),
  ('analytics.baseline_days',       '7',           'Primary baseline window'),
  ('ingest.quarantine_threshold_pct','5',          'SRS-02 FR-04: above this the batch is rejected'),
  ('brief.schedule_cron',           '"0 7 * * *"', 'Daily brief delivery time'),
  ('brief.generate_cron',           '"45 6 * * *"','Generation starts earlier on CPU profiles (ADR-S06)'),
  ('ask.enable_text_to_sql',        'false',       'ADR-S07: off until the eval gate passes');

INSERT INTO ops.scheduled_job (name, cron, enabled) VALUES
  ('intake_watch',       '* * * * *',   true),
  ('file_expectation',   '*/15 * * * *',true),
  ('facts_rebuild',      '40 22 * * *', true),
  ('daily_brief',        '45 6 * * *',  true),
  ('retention_sweep',    '0 2 * * *',   true),
  ('backup_full',        '0 1 * * *',   true);

COMMIT;

-- =====================================================================
-- 10. VERIFICATION — expected values the test suite asserts against
-- =====================================================================

\echo '--- Seed verification -------------------------------------------'

\echo 'Expect 180 production_fact rows and 900 defect_fact rows:'
SELECT (SELECT count(*) FROM core.production_fact) AS production_rows,
       (SELECT count(*) FROM core.defect_fact)     AS defect_rows;

\echo 'Expect defect_fact totals to equal production_fact qty_ng for every (date, shift, line):'
SELECT count(*) AS mismatched_cells FROM (
  SELECT pf.prod_date, pf.shift, pf.line_id, pf.qty_ng, COALESCE(SUM(df.qty),0) AS defect_sum
  FROM core.production_fact pf
  LEFT JOIN core.defect_fact df USING (prod_date, shift, line_id, sku_id)
  GROUP BY 1,2,3,4 HAVING pf.qty_ng <> COALESCE(SUM(df.qty),0)) x;

\echo 'Expect 2026-09-10: produced 12430, ng 382, defect_rate_pct 3.0732:'
SELECT sum(qty_produced) AS produced, sum(qty_ng) AS ng,
       ROUND(100.0*sum(qty_ng)/sum(qty_produced),4) AS defect_rate_pct
FROM core.production_fact WHERE prod_date = DATE '2026-09-10';

\echo 'Expect 7-day baseline (09-03..09-09) = 2.5947 pct and change +18.4 pct:'
SELECT baseline_7d_pct, ROUND(100.0*(defect_rate_pct/baseline_7d_pct - 1), 1) AS change_pct
FROM analytics.v_trend_daily WHERE prod_date = DATE '2026-09-10';

\echo 'Expect Line 3 on 2026-09-10: 2147 / 125 = 5.8221 pct; shift B 1077 / 95 = 8.8208 pct:'
SELECT line_code, shift, qty_produced, qty_ng, defect_rate_pct
FROM analytics.v_line_shift_daily WHERE prod_date = DATE '2026-09-10' AND line_code = 'L3' ORDER BY shift;

\echo 'Expect top defect on 2026-09-10: MISSING_COMPONENT 157 = 41.10 pct:'
SELECT defect_code, sum(qty) AS qty
FROM core.v_defect_pareto WHERE prod_date = DATE '2026-09-10' GROUP BY 1 ORDER BY 2 DESC LIMIT 1;

\echo 'Expect corrected day 2026-08-20 ng = 313 (was 311):'
SELECT sum(qty_ng) AS ng FROM core.production_fact WHERE prod_date = DATE '2026-08-20';

\echo 'Expect intake health: 3 batches, 2 committed, 1 rejected, 6 quarantined rows:'
SELECT batches, committed, rejected, rows_quarantined FROM analytics.v_intake_health;

\echo 'Expect 6 facts rows; every stored sha256 equals the recomputed digest:'
SELECT count(*) AS facts_rows,
       count(*) FILTER (WHERE facts_sha256 = encode(digest(facts_json::text,'sha256'),'hex')) AS hash_ok
FROM analytics.facts;

\echo 'Expect 6 briefs, 1 withheld, 1 revision:'
SELECT sum(briefs) AS briefs, sum(withheld) AS withheld, sum(revisions) AS revisions FROM analytics.v_brief_health;

\echo 'Expect grounding health: 3 brief runs + 1 ask, 1 grounding_failed:'
SELECT sum(runs) AS runs, sum(grounding_failed) AS grounding_failed FROM agent.v_grounding_health;

\echo '--- End seed verification ---------------------------------------'
