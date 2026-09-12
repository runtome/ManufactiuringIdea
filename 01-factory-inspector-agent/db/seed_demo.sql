-- =====================================================================
-- VisionOps — Deterministic demo / test dataset
-- Document : DDS-01-VisionOps section 10
-- Version  : 1.0
-- Date     : 2026-09-11
--
-- Apply AFTER schema.sql:
--   psql -v ON_ERROR_STOP=1 -f schema.sql
--   psql -v ON_ERROR_STOP=1 -f seed_demo.sql
--
-- PURPOSE
--   Reproduce SRS-01 Appendix A EXACTLY so the narrative agent, the KPI
--   views and the test suite can assert against known numbers:
--
--     Line 2 — 2026-09-10
--     1,240 units inspected · 37 defects · defect rate 2.98 %
--     +42 % vs 7-day avg 2.10 %
--     Main defect: missing fin (19 pcs)
--     Most affected SKU: RAD-500-A
--     Possible correlation: Shift B (31 of 37) · feeder station ST3 (27 of 37)
--     Coincident with material lot LOT-2609-114 entering at 14:05
--
--   Everything is computed from FIXED POSITION LISTS — no random(), no
--   modulo rules (a modulo rule in the platform seed once silently
--   miscounted verdicts; explicit lists cannot overlap by accident).
--
-- LAYOUT
--   Line L2 · stations ST1/ST2/ST3 (n mod 3 = 1/2/0) · shifts A 06-14, B 14-22
--   Inspection n on day D is at 06:00 + (n-1) x 46 s (plant time, +07)
--   n <= 626 -> shift A · n >= 627 -> shift B
--
--   Days 1-5 (09-04..09-08): 1,190 rows, 25 FAIL          -> 2.101 %
--   Day 6    (09-09)       : 1,190 judged + 8 REVIEW + 4 NO_READ = 1,202 rows
--   Day 7    (09-10)       : 1,240 rows, 37 FAIL, 0 REVIEW -> 2.984 %  (PLANTED)
--
--   Total rows: 5 x 1,190 + 1,202 + 1,240 = 8,392
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM vision.inspection LIMIT 1) THEN
        RAISE EXCEPTION
          'vision.inspection is not empty. Refusing to seed: this script assumes an empty database and its assertions depend on exact totals.';
    END IF;
END
$$;

-- Deterministic timestamp for inspection n on a given day (dropped at the end)
CREATE FUNCTION pg_temp.seed_ts(d date, n int) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
    SELECT (d::text || ' 06:00:00+07')::timestamptz + ((n - 1) * 46) * interval '1 second';
$$;

-- ---------------------------------------------------------------------
-- 1. Master data (fixed UUIDs — tests reference them by literal)
-- ---------------------------------------------------------------------

INSERT INTO core.plant (id, code, name, timezone) VALUES
  ('00000000-0000-7000-8000-000000000001', 'P1', 'Demo Plant 1', 'Asia/Bangkok');

INSERT INTO core.line (id, plant_id, code, name) VALUES
  ('00000000-0000-7000-8000-00000000000b', '00000000-0000-7000-8000-000000000001', 'L2', 'Assembly Line 2');

INSERT INTO core.sku (id, code, name, customer, spec_json) VALUES
  ('00000000-0000-7000-8000-000000000101', 'RAD-500-A', 'Radiator Core 500A', 'Customer-J', '{"ideal_cycle_s": 12.0}'),
  ('00000000-0000-7000-8000-000000000102', 'RAD-500-B', 'Radiator Core 500B', 'Customer-J', '{"ideal_cycle_s": 12.5}');

INSERT INTO core.defect_type (id, code, name_th, name_ja, name_en, category, is_critical) VALUES
  ('00000000-0000-7000-8000-000000000201', 'MISSING_COMPONENT', 'ชิ้นส่วนขาด', '部品欠品',   'Missing Component', 'assembly', true),
  ('00000000-0000-7000-8000-000000000202', 'SCRATCH',           'รอยขีดข่วน',  'キズ',       'Scratch',           'surface',  false),
  ('00000000-0000-7000-8000-000000000203', 'MISSING_FIN',       'ฟินขาด',      'フィン欠品', 'Missing Fin',       'assembly', true),
  ('00000000-0000-7000-8000-000000000204', 'DENT',              'รอยบุบ',      'へこみ',     'Dent',              'surface',  false);

INSERT INTO core.material_lot (id, lot_code, material_code, supplier, received_at) VALUES
  ('00000000-0000-7000-8000-000000000402', 'LOT-2609-102', 'MAT-AL-3003', 'Supplier-A', '2026-09-01 08:00+07'),
  ('00000000-0000-7000-8000-000000000403', 'LOT-2609-114', 'MAT-AL-3003', 'Supplier-B', '2026-09-09 08:00+07');

INSERT INTO core.shift_calendar (plant_id, shift, starts_at, ends_at, valid_from) VALUES
  ('00000000-0000-7000-8000-000000000001', 'A', '06:00', '14:00', '2026-01-01'),
  ('00000000-0000-7000-8000-000000000001', 'B', '14:00', '22:00', '2026-01-01');

-- No usable credential ships in this file (OPS section 3.4 sets real hashes).
INSERT INTO core.app_user (id, username, display_name, role, lang, password_hash) VALUES
  ('00000000-0000-7000-8000-000000000501', 'demo.viewer',    'Demo Viewer',    'viewer',    'th', 'SET_AT_BOOTSTRAP'),
  ('00000000-0000-7000-8000-000000000502', 'demo.inspector', 'Demo Inspector', 'inspector', 'th', 'SET_AT_BOOTSTRAP'),
  ('00000000-0000-7000-8000-000000000503', 'demo.engineer',  'Demo Engineer',  'engineer',  'en', 'SET_AT_BOOTSTRAP'),
  ('00000000-0000-7000-8000-000000000504', 'demo.manager',   'Demo Manager',   'manager',   'ja', 'SET_AT_BOOTSTRAP'),
  ('00000000-0000-7000-8000-000000000505', 'demo.admin',     'Demo Admin',     'admin',     'en', 'SET_AT_BOOTSTRAP');

-- ---------------------------------------------------------------------
-- 2. Stations, models, cameras, calibration, recipe, edge node
-- ---------------------------------------------------------------------

INSERT INTO vision.station (id, line_id, code, name, position, trigger_mode, plc_io_json) VALUES
  ('00000000-0000-7000-8000-000000000601', '00000000-0000-7000-8000-00000000000b', 'ST1', 'Fin insert',   1, 'hardware',
   '{"ready":"Q0.0","pass":"Q0.1","fail":"Q0.2","review":"Q0.3","fault":"Q0.4","trigger":"I0.0","pulse_ms":200}'),
  ('00000000-0000-7000-8000-000000000602', '00000000-0000-7000-8000-00000000000b', 'ST2', 'Tank braze',   2, 'hardware',
   '{"ready":"Q1.0","pass":"Q1.1","fail":"Q1.2","review":"Q1.3","fault":"Q1.4","trigger":"I1.0","pulse_ms":200}'),
  ('00000000-0000-7000-8000-000000000603', '00000000-0000-7000-8000-00000000000b', 'ST3', 'Feeder #3 out', 3, 'hardware',
   '{"ready":"Q2.0","pass":"Q2.1","fail":"Q2.2","review":"Q2.3","fault":"Q2.4","trigger":"I2.0","pulse_ms":200}');

INSERT INTO vision.model_registry
      (id, name, version, sha256, task, input_size, class_map, metrics_json, stage, trained_from, promoted_by, promoted_at)
VALUES
  ('00000000-0000-7000-8000-000000000701', 'defect-yolo11s', '1.0.0', repeat('a', 64), 'detection', 640,
   '{"0":"MISSING_COMPONENT","1":"SCRATCH","2":"MISSING_FIN","3":"DENT"}',
   '{"map50":0.871,"recall_critical":0.982,"false_alarm_rate":0.021,"holdout_images":512}',
   'active', 'snap-2026-08-r1', '00000000-0000-7000-8000-000000000505', '2026-08-01 10:00+07'),
  ('00000000-0000-7000-8000-000000000702', 'defect-yolo11s', '1.1.0', repeat('b', 64), 'detection', 640,
   '{"0":"MISSING_COMPONENT","1":"SCRATCH","2":"MISSING_FIN","3":"DENT"}',
   '{"map50":0.884,"recall_critical":0.985,"false_alarm_rate":0.019,"holdout_images":512}',
   'shadow', 'snap-2026-09-r1', NULL, NULL),
  ('00000000-0000-7000-8000-000000000703', 'patchcore-rad500', '1.0.0', repeat('c', 64), 'anomaly', 256,
   '{}', '{"auroc":0.93}', 'active', NULL, '00000000-0000-7000-8000-000000000505', '2026-08-01 10:00+07');

INSERT INTO ops.edge_node (id, node_code, line_id, hardware, state, app_version, model_versions, last_heartbeat, buffer_depth) VALUES
  ('00000000-0000-7000-8000-000000000801', 'L2-ST1', '00000000-0000-7000-8000-00000000000b', 'Jetson Orin Nano 8GB', 'online', '1.0.0',
   '{"defect-yolo11s":"1.0.0","patchcore-rad500":"1.0.0"}', now(), 0),
  ('00000000-0000-7000-8000-000000000802', 'L2-ST2', '00000000-0000-7000-8000-00000000000b', 'Jetson Orin Nano 8GB', 'online', '1.0.0',
   '{"defect-yolo11s":"1.0.0","patchcore-rad500":"1.0.0"}', now(), 0),
  ('00000000-0000-7000-8000-000000000803', 'L2-ST3', '00000000-0000-7000-8000-00000000000b', 'Jetson Orin Nano 8GB', 'online', '1.0.0',
   '{"defect-yolo11s":"1.0.0","patchcore-rad500":"1.0.0"}', now(), 0);

INSERT INTO vision.camera (id, line_id, station, model, resolution, calib_px_per_mm, node_id) VALUES
  ('00000000-0000-7000-8000-000000000901', '00000000-0000-7000-8000-00000000000b', 'ST1', 'Basler acA2440', '2448x2048', 18.4200, '00000000-0000-7000-8000-000000000801'),
  ('00000000-0000-7000-8000-000000000902', '00000000-0000-7000-8000-00000000000b', 'ST2', 'Basler acA2440', '2448x2048', 18.3900, '00000000-0000-7000-8000-000000000802'),
  ('00000000-0000-7000-8000-000000000903', '00000000-0000-7000-8000-00000000000b', 'ST3', 'Basler acA2440', '2448x2048', 18.4200, '00000000-0000-7000-8000-000000000803');

-- One valid calibration per camera (30-repeat gauge verification, all within 0.2 mm)
INSERT INTO vision.calibration
      (id, camera_id, version, method, px_per_mm, hardware_fingerprint, target_type,
       gauge_nominal_mm, gauge_repeats, gauge_mean_mm, gauge_sigma_mm, gauge_max_err_mm, tolerance_mm,
       performed_by, performed_at)
VALUES
  ('00000000-0000-7000-8000-000000000a01', '00000000-0000-7000-8000-000000000901', 1, 'intrinsics_scale', 18.4200,
   'acA2440:40123401|lens:C2514|mount:M-ST1', 'checkerboard-9x6-10mm',
   25.000, 30, 25.011, 0.029, 0.08, 0.2, '00000000-0000-7000-8000-000000000503', '2026-08-15 09:00+07'),
  ('00000000-0000-7000-8000-000000000a02', '00000000-0000-7000-8000-000000000902', 1, 'intrinsics_scale', 18.3900,
   'acA2440:40123402|lens:C2514|mount:M-ST2', 'checkerboard-9x6-10mm',
   25.000, 30, 24.994, 0.033, 0.10, 0.2, '00000000-0000-7000-8000-000000000503', '2026-08-15 09:30+07'),
  ('00000000-0000-7000-8000-000000000a03', '00000000-0000-7000-8000-000000000903', 1, 'intrinsics_scale', 18.4200,
   'acA2440:40123403|lens:C2514|mount:M-ST3', 'checkerboard-9x6-10mm',
   25.000, 30, 25.012, 0.031, 0.09, 0.2, '00000000-0000-7000-8000-000000000503', '2026-08-15 10:00+07');

-- An INVALID calibration (unverified) — proves v_current_calibration ignores it (TC-032)
INSERT INTO vision.calibration
      (id, camera_id, version, method, px_per_mm, hardware_fingerprint, target_type,
       gauge_nominal_mm, gauge_repeats, gauge_mean_mm, gauge_sigma_mm, gauge_max_err_mm, tolerance_mm,
       performed_by, performed_at)
VALUES
  ('00000000-0000-7000-8000-000000000a04', '00000000-0000-7000-8000-000000000903', 2, 'intrinsics_scale', 18.5100,
   'acA2440:40123403|lens:C2514|mount:M-ST3', 'checkerboard-9x6-10mm',
   NULL, NULL, NULL, NULL, NULL, 0.2, '00000000-0000-7000-8000-000000000503', '2026-09-10 21:50+07');

INSERT INTO vision.recipe (id, sku_id, version, rules_json, review_threshold, created_by, active_from) VALUES
  ('00000000-0000-7000-8000-000000000b01', '00000000-0000-7000-8000-000000000101', 1,
   '{"schema_version":1,
     "quality_gate":{"min_blur_variance":120,"exposure_range":[40,220]},
     "rules":[
       {"kind":"class_present","classes":{"MISSING_FIN":0.60,"MISSING_COMPONENT":0.60}},
       {"kind":"class_present","classes":{"SCRATCH":0.75},"verdict":"REVIEW"},
       {"kind":"class_count","class":"DENT","max":2,"min_confidence":0.5},
       {"kind":"measurement","name":"fin_pitch","usl":3.2,"lsl":2.8,"requires_calibration":true},
       {"kind":"ocr_match","pattern":"^LOT-[0-9]{4}-[0-9]{3}$","on_mismatch":"REVIEW"}],
     "conflict_policy":"review",
     "anomaly":{"threshold":0.82,"action":"review"}}',
   0.550, '00000000-0000-7000-8000-000000000503', '2026-08-01 00:00+07'),
  ('00000000-0000-7000-8000-000000000b02', '00000000-0000-7000-8000-000000000102', 1,
   '{"schema_version":1,
     "quality_gate":{"min_blur_variance":120,"exposure_range":[40,220]},
     "rules":[
       {"kind":"class_present","classes":{"MISSING_FIN":0.60,"MISSING_COMPONENT":0.60}},
       {"kind":"class_count","class":"DENT","max":2,"min_confidence":0.5}],
     "conflict_policy":"review"}',
   0.550, '00000000-0000-7000-8000-000000000503', '2026-08-01 00:00+07');

-- ---------------------------------------------------------------------
-- 3. Inspections — 7 days from fixed position lists
-- ---------------------------------------------------------------------

WITH day_plan (insp_date, n_rows, fail_pos, review_pos, noread_pos) AS (
  VALUES
    (DATE '2026-09-04', 1190,
     ARRAY[37,88,141,190,243,296,349,402,455,508,561,614,667,720,773,826,879,932,985,1038,1091,1130,1150,1170,1185],
     ARRAY[]::int[], ARRAY[]::int[]),
    (DATE '2026-09-05', 1190,
     ARRAY[37,88,141,190,243,296,349,402,455,508,561,614,667,720,773,826,879,932,985,1038,1091,1130,1150,1170,1185],
     ARRAY[]::int[], ARRAY[]::int[]),
    (DATE '2026-09-06', 1190,
     ARRAY[37,88,141,190,243,296,349,402,455,508,561,614,667,720,773,826,879,932,985,1038,1091,1130,1150,1170,1185],
     ARRAY[]::int[], ARRAY[]::int[]),
    (DATE '2026-09-07', 1190,
     ARRAY[37,88,141,190,243,296,349,402,455,508,561,614,667,720,773,826,879,932,985,1038,1091,1130,1150,1170,1185],
     ARRAY[]::int[], ARRAY[]::int[]),
    (DATE '2026-09-08', 1190,
     ARRAY[37,88,141,190,243,296,349,402,455,508,561,614,667,720,773,826,879,932,985,1038,1091,1130,1150,1170,1185],
     ARRAY[]::int[], ARRAY[]::int[]),
    (DATE '2026-09-09', 1202,
     ARRAY[37,88,141,190,243,296,349,402,455,508,561,614,667,720,773,826,879,932,985,1038,1091,1130,1150,1170,1185],
     ARRAY[150,450,750,1050,1191,1194,1197,1200],
     ARRAY[1192,1195,1198,1201]),
    -- PLANTED DAY: 6 fails in shift A, 31 in shift B (25 of them at ST3, after lot change at 14:05)
    (DATE '2026-09-10', 1240,
     ARRAY[ 50,199,345,500,562,612,
           639,660,684,702,726,750,771,795,816,840,861,885,906,930,951,975,996,1020,1041,
           1065,1086,1110,1131,1155,1176,
           700,901,1102,
           764,965,1166],
     ARRAY[]::int[], ARRAY[]::int[])
),
rows_ AS (
  SELECT
    p.insp_date, s.n,
    pg_temp.seed_ts(p.insp_date, s.n)                               AS ts,
    CASE s.n % 3 WHEN 1 THEN 'ST1' WHEN 2 THEN 'ST2' ELSE 'ST3' END AS station,
    CASE s.n % 3 WHEN 1 THEN '00000000-0000-7000-8000-000000000901'::uuid
                 WHEN 2 THEN '00000000-0000-7000-8000-000000000902'::uuid
                 ELSE        '00000000-0000-7000-8000-000000000903'::uuid END AS camera_id,
    CASE s.n % 3 WHEN 1 THEN '00000000-0000-7000-8000-000000000801'::uuid
                 WHEN 2 THEN '00000000-0000-7000-8000-000000000802'::uuid
                 ELSE        '00000000-0000-7000-8000-000000000803'::uuid END AS node_id,
    -- RAD-500-B runs at the start of shift A; RAD-500-A the rest of the day
    CASE WHEN s.n <= 300 THEN '00000000-0000-7000-8000-000000000102'::uuid
         ELSE               '00000000-0000-7000-8000-000000000101'::uuid END AS sku_id,
    CASE WHEN s.n <= 300 THEN '00000000-0000-7000-8000-000000000b02'::uuid
         ELSE               '00000000-0000-7000-8000-000000000b01'::uuid END AS recipe_id,
    -- Lot LOT-2609-114 enters on day 7 at 14:05 (n = 636)
    CASE WHEN p.insp_date = DATE '2026-09-10' AND s.n >= 636 THEN 'LOT-2609-114'
         ELSE 'LOT-2609-102' END                                    AS lot,
    CASE WHEN s.n = ANY (p.fail_pos)   THEN 'FAIL'::vision.verdict
         WHEN s.n = ANY (p.review_pos) THEN 'REVIEW'::vision.verdict
         WHEN s.n = ANY (p.noread_pos) THEN 'NO_READ'::vision.verdict
         ELSE 'PASS'::vision.verdict END                            AS verdict
  FROM day_plan p
  CROSS JOIN LATERAL generate_series(1, p.n_rows) AS s(n)
)
INSERT INTO vision.inspection
      (id, ts, line_id, sku_id, camera_id, station, lot, verdict, model_id, recipe_id,
       latency_ms, image_uri, overlay_uri, ocr_text, source, node_id)
SELECT
    public.uuid_generate_v7(),
    r.ts,
    '00000000-0000-7000-8000-00000000000b',
    r.sku_id, r.camera_id, r.station, r.lot, r.verdict,
    '00000000-0000-7000-8000-000000000701',
    r.recipe_id,
    92 + (r.n % 37),                                                    -- 92..128 ms
    CASE WHEN r.verdict IN ('FAIL','REVIEW') OR r.n % 50 = 0             -- PASS sampled 2 %
         THEN 's3://evidence/L2/' || r.insp_date::text || '/' || r.station || '/' || lpad(r.n::text, 4, '0') || '.jpg' END,
    CASE WHEN r.verdict IN ('FAIL','REVIEW')
         THEN 's3://evidence/L2/' || r.insp_date::text || '/' || r.station || '/' || lpad(r.n::text, 4, '0') || '_overlay.png' END,
    CASE WHEN r.verdict <> 'NO_READ' THEN r.lot END,
    'edge',
    r.node_id
FROM rows_ r;

-- ---------------------------------------------------------------------
-- 4. Detections
--    Days 1-6: class cycles by rank in the fail list (MC, SC, MF, DENT)
--    Day 7   : explicit class per position (19 MISSING_FIN concentrated at ST3/shift B)
-- ---------------------------------------------------------------------

-- Days 1-6
WITH fails AS (
  SELECT i.id, i.ts,
         array_position(
           ARRAY[37,88,141,190,243,296,349,402,455,508,561,614,667,720,773,826,879,932,985,1038,1091,1130,1150,1170,1185],
           (EXTRACT(epoch FROM (i.ts - ((i.ts AT TIME ZONE 'Asia/Bangkok')::date::text || ' 06:00:00+07')::timestamptz)) / 46)::int + 1
         ) AS rank
  FROM vision.inspection i
  WHERE i.verdict = 'FAIL'
    AND (i.ts AT TIME ZONE 'Asia/Bangkok')::date < DATE '2026-09-10'
)
INSERT INTO vision.detection (inspection_id, inspection_ts, defect_type_id, class_name, confidence, bbox_json, area_mm2)
SELECT f.id, f.ts, dt.id, dt.code,
       0.8000 + ((f.rank % 5) * 0.0300),
       '{"x":120,"y":240,"w":86,"h":74}', 18.5
FROM fails f
JOIN core.defect_type dt
  ON dt.code = (ARRAY['MISSING_COMPONENT','SCRATCH','MISSING_FIN','DENT'])[((f.rank - 1) % 4) + 1];

-- Day 7: explicit mapping
WITH plan (n, code) AS (
  VALUES
    -- shift A (6)
    (50,'SCRATCH'), (199,'DENT'), (345,'SCRATCH'), (500,'DENT'), (562,'SCRATCH'), (612,'SCRATCH'),
    -- shift B, ST3, after lot change: 19 MISSING_FIN then 6 MISSING_COMPONENT
    (639,'MISSING_FIN'), (660,'MISSING_FIN'), (684,'MISSING_FIN'), (702,'MISSING_FIN'), (726,'MISSING_FIN'),
    (750,'MISSING_FIN'), (771,'MISSING_FIN'), (795,'MISSING_FIN'), (816,'MISSING_FIN'), (840,'MISSING_FIN'),
    (861,'MISSING_FIN'), (885,'MISSING_FIN'), (906,'MISSING_FIN'), (930,'MISSING_FIN'), (951,'MISSING_FIN'),
    (975,'MISSING_FIN'), (996,'MISSING_FIN'), (1020,'MISSING_FIN'), (1041,'MISSING_FIN'),
    (1065,'MISSING_COMPONENT'), (1086,'MISSING_COMPONENT'), (1110,'MISSING_COMPONENT'),
    (1131,'MISSING_COMPONENT'), (1155,'MISSING_COMPONENT'), (1176,'MISSING_COMPONENT'),
    -- shift B, ST1 / ST2 (6)
    (700,'SCRATCH'), (901,'DENT'), (1102,'SCRATCH'),
    (764,'SCRATCH'), (965,'DENT'), (1166,'SCRATCH')
)
INSERT INTO vision.detection (inspection_id, inspection_ts, defect_type_id, class_name, confidence, bbox_json, area_mm2)
SELECT i.id, i.ts, dt.id, dt.code, 0.9100, '{"x":132,"y":251,"w":80,"h":70}', 21.0
FROM plan p
JOIN vision.inspection i ON i.ts = pg_temp.seed_ts(DATE '2026-09-10', p.n)
JOIN core.defect_type dt ON dt.code = p.code;

-- REVIEW rows on day 6: low-confidence SCRATCH (below the 0.75 rule threshold, above 0.55 review threshold)
INSERT INTO vision.detection (inspection_id, inspection_ts, defect_type_id, class_name, confidence, bbox_json)
SELECT i.id, i.ts, '00000000-0000-7000-8000-000000000202', 'SCRATCH', 0.6100, '{"x":300,"y":180,"w":40,"h":22}'
FROM vision.inspection i
WHERE i.verdict = 'REVIEW';

-- Anomaly scores for every day-7 ST3 inspection; the 6 MISSING_COMPONENT fails are flagged
INSERT INTO vision.anomaly_score (inspection_id, inspection_ts, model_id, score, threshold, heatmap_uri)
SELECT i.id, i.ts, '00000000-0000-7000-8000-000000000703',
       CASE WHEN d.class_name = 'MISSING_COMPONENT' THEN 0.9100 ELSE 0.3100 + ((EXTRACT(second FROM i.ts))::int % 7) * 0.02 END,
       0.8200,
       CASE WHEN d.class_name = 'MISSING_COMPONENT' THEN replace(i.overlay_uri, '_overlay', '_heat') END
FROM vision.inspection i
LEFT JOIN vision.detection d ON d.inspection_id = i.id AND d.inspection_ts = i.ts
WHERE i.station = 'ST3' AND (i.ts AT TIME ZONE 'Asia/Bangkok')::date = DATE '2026-09-10';

-- ---------------------------------------------------------------------
-- 5. Measurements — fin_pitch on the first 50 RAD-500-A parts of day 7
-- ---------------------------------------------------------------------

INSERT INTO vision.measurement (inspection_id, inspection_ts, parameter, value, unit, usl, lsl)
SELECT i.id, i.ts, 'fin_pitch',
       3.00 + ((row_number() OVER (ORDER BY i.ts) % 7) - 3) * 0.02,
       'mm', 3.2, 2.8
FROM vision.inspection i
WHERE (i.ts AT TIME ZONE 'Asia/Bangkok')::date = DATE '2026-09-10'
  AND i.sku_id = '00000000-0000-7000-8000-000000000101'
ORDER BY i.ts
LIMIT 50;

-- ---------------------------------------------------------------------
-- 6. Overrides — 10 human decisions
--    5 of the 8 day-6 REVIEW rows decided (3 PASS, 2 FAIL) -> queue depth 3
--    3 day-5 FAIL -> PASS (false alarms)   2 day-4 PASS -> FAIL (escapes found)
-- ---------------------------------------------------------------------

INSERT INTO vision.verdict_override (inspection_id, inspection_ts, old_verdict, new_verdict, user_id, reason_code, note, created_at)
SELECT i.id, i.ts, 'REVIEW', v.new_verdict::vision.verdict, '00000000-0000-7000-8000-000000000502', v.reason, v.note, i.ts + interval '35 minutes'
FROM (VALUES (150,'PASS','ACCEPTABLE_MARK','surface mark within customer limit'),
             (450,'PASS','ACCEPTABLE_MARK','handling mark, not a scratch'),
             (750,'FAIL','CONFIRMED_DEFECT','scratch 6 mm on tank face'),
             (1050,'PASS','ACCEPTABLE_MARK',NULL),
             (1191,'FAIL','CONFIRMED_DEFECT','deep scratch')) AS v(n, new_verdict, reason, note)
JOIN vision.inspection i ON i.ts = pg_temp.seed_ts(DATE '2026-09-09', v.n);

INSERT INTO vision.verdict_override (inspection_id, inspection_ts, old_verdict, new_verdict, user_id, reason_code, note, created_at)
SELECT i.id, i.ts, 'FAIL', 'PASS', '00000000-0000-7000-8000-000000000502', 'FALSE_ALARM', 'reflection misread as dent', i.ts + interval '20 minutes'
FROM (VALUES (190), (508), (826)) AS v(n)
JOIN vision.inspection i ON i.ts = pg_temp.seed_ts(DATE '2026-09-08', v.n);

INSERT INTO vision.verdict_override (inspection_id, inspection_ts, old_verdict, new_verdict, user_id, reason_code, note, created_at)
SELECT i.id, i.ts, 'PASS', 'FAIL', '00000000-0000-7000-8000-000000000503', 'ESCAPE_FOUND', 'found at final audit — missing fin at row 4', i.ts + interval '6 hours'
FROM (VALUES (300), (900)) AS v(n)
JOIN vision.inspection i ON i.ts = pg_temp.seed_ts(DATE '2026-09-07', v.n);

-- ---------------------------------------------------------------------
-- 7. Agreement statistic for days 4-6 (the overrides above)
-- ---------------------------------------------------------------------

INSERT INTO vision.agreement_stat
      (period_from, period_to, line_id, sku_id, class_name, model_id,
       reviewed, agreed, model_fail_human_pass, model_pass_human_fail)
VALUES
  ('2026-09-07 00:00+07', '2026-09-10 00:00+07', '00000000-0000-7000-8000-00000000000b', NULL, NULL,
   '00000000-0000-7000-8000-000000000701', 12, 7, 3, 2);

-- ---------------------------------------------------------------------
-- 8. Dataset snapshot (frozen) from the overrides — retraining hand-off
-- ---------------------------------------------------------------------

INSERT INTO vision.dataset_snapshot (id, name, purpose, label_version, class_map, item_count, export_format, export_uri, export_sha256, created_by, created_at)
VALUES ('00000000-0000-7000-8000-000000000c01', 'snap-2026-09-r1', 'retrain', 'labels-v3',
        '{"0":"MISSING_COMPONENT","1":"SCRATCH","2":"MISSING_FIN","3":"DENT"}', 0, NULL, NULL, NULL,
        '00000000-0000-7000-8000-000000000503', '2026-09-10 06:30+07');

INSERT INTO vision.dataset_item (snapshot_id, inspection_id, inspection_ts, label_source, labels_json, image_sha256)
SELECT '00000000-0000-7000-8000-000000000c01', o.inspection_id, o.inspection_ts, 'override',
       jsonb_build_object('verdict', o.new_verdict, 'reason', o.reason_code),
       encode(digest(o.inspection_id::text, 'sha256'), 'hex')
FROM vision.verdict_override o;

UPDATE vision.dataset_snapshot
   SET item_count = (SELECT count(*) FROM vision.dataset_item WHERE snapshot_id = '00000000-0000-7000-8000-000000000c01'),
       export_format = 'yolo',
       export_uri = 's3://models/datasets/snap-2026-09-r1.zip',
       export_sha256 = repeat('d', 64),
       frozen_at = '2026-09-10 06:45+07'
 WHERE id = '00000000-0000-7000-8000-000000000c01';

-- ---------------------------------------------------------------------
-- 9. Narrative agent — tool registry, one grounded run, one narrative
-- ---------------------------------------------------------------------

INSERT INTO agent.tool (name, kind, risk, min_role, schema_json) VALUES
  ('inspection_stats',  'read', 'low', 'viewer',
   '{"type":"object","required":["period_from","period_to"],"properties":{"period_from":{"type":"string","format":"date-time"},"period_to":{"type":"string","format":"date-time"},"line":{"type":"string"},"sku":{"type":"string"},"baseline_days":{"type":"integer","default":7}}}'),
  ('defect_pareto',     'read', 'low', 'viewer',
   '{"type":"object","required":["period_from","period_to"],"properties":{"period_from":{"type":"string"},"period_to":{"type":"string"},"line":{"type":"string"},"top_n":{"type":"integer","default":5}}}'),
  ('station_breakdown', 'read', 'low', 'viewer',
   '{"type":"object","required":["period_from","period_to"],"properties":{"period_from":{"type":"string"},"period_to":{"type":"string"},"line":{"type":"string"}}}'),
  ('shift_correlation', 'read', 'low', 'viewer',
   '{"type":"object","required":["period_from","period_to"],"properties":{"period_from":{"type":"string"},"period_to":{"type":"string"},"line":{"type":"string"},"factors":{"type":"array","items":{"enum":["shift","station","sku","lot"]}}}}'),
  ('similar_periods',   'read', 'low', 'viewer',
   '{"type":"object","required":["signature"],"properties":{"signature":{"type":"object"},"top_k":{"type":"integer","default":3}}}'),
  ('get_evidence',      'read', 'low', 'inspector',
   '{"type":"object","required":["inspection_ids"],"properties":{"inspection_ids":{"type":"array","items":{"type":"string"},"maxItems":20}}}'),
  ('send_discord',      'write','low', 'manager',
   '{"type":"object","required":["channel","message"],"properties":{"channel":{"type":"string"},"message":{"type":"string"}}}');

INSERT INTO agent.run
      (id, ts, user_id, correlation_id, kind, question, answer, model, prompt_version,
       facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome, grounding_json)
VALUES
  ('00000000-0000-7000-8000-000000000f01', '2026-09-10 22:05+07', NULL, 'seed-narr-0001', 'narrative',
   'shift narrative L2 2026-09-10',
   'Production line 2 — 2026-09-10. 1,240 units inspected, 37 defects, defect rate 2.98 % (+42 % vs 7-day average 2.10 %). '
   'Main defect: missing fin (19 pcs, 51 %). Most affected SKU: RAD-500-A. '
   'Possible correlation: 31 of 37 defects in Shift B and 27 of 37 at station ST3, coincident with lot LOT-2609-114 entering at 14:05 '
   '(defect rate 5.12 % on that lot vs 0.94 % before). Recommendation: inspect feeder station #3 and verify the incoming lot. '
   'Confidence: correlation only — not verified as root cause.',
   'qwen3:8b', 'narrative.v1.0',
   '{"inspected":1240,"defects":37,"defect_rate_pct":2.98,"baseline_7d_pct":2.10,"change_pct":42.0,"significant":true,"p_value":0.0011,
     "top_defect":{"class":"MISSING_FIN","count":19,"share_pct":51.4},"worst_sku":"RAD-500-A",
     "shift_b_defects":31,"station_st3_defects":27,"lot_after":{"lot":"LOT-2609-114","rate_pct":5.12},"lot_before":{"rate_pct":0.94}}',
   1380, 196, 9200, 4, 'ok',
   '{"numbers_found":["2","1240","37","2.98","42","2.10","19","51","31","37","27","5.12","0.94","14:05","3"],"all_matched":true}');

INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, row_count, duration_ms, ok) VALUES
  ('00000000-0000-7000-8000-000000000f01', 1, 'inspection_stats',
   '{"period_from":"2026-09-10T06:00:00+07:00","period_to":"2026-09-10T22:00:00+07:00","line":"L2","baseline_days":7}', 1, 38, true),
  ('00000000-0000-7000-8000-000000000f01', 2, 'defect_pareto',
   '{"period_from":"2026-09-10T06:00:00+07:00","period_to":"2026-09-10T22:00:00+07:00","line":"L2","top_n":5}', 4, 27, true),
  ('00000000-0000-7000-8000-000000000f01', 3, 'station_breakdown',
   '{"period_from":"2026-09-10T06:00:00+07:00","period_to":"2026-09-10T22:00:00+07:00","line":"L2"}', 3, 22, true),
  ('00000000-0000-7000-8000-000000000f01', 4, 'shift_correlation',
   '{"period_from":"2026-09-10T06:00:00+07:00","period_to":"2026-09-10T22:00:00+07:00","line":"L2","factors":["shift","station","lot"]}', 3, 61, true);

INSERT INTO vision.narrative
      (id, kind, period_from, period_to, line_id, shift, lang, run_id, facts_json, text, sources_json, grounding_json,
       significant, withheld, model, prompt_version, delivered_at)
SELECT '00000000-0000-7000-8000-000000000e01', 'daily',
       '2026-09-10 06:00+07', '2026-09-10 22:00+07',
       '00000000-0000-7000-8000-00000000000b', NULL, 'en',
       r.id, r.facts_json, r.answer,
       '[{"kind":"tool","tool":"inspection_stats","row_count":1},{"kind":"tool","tool":"defect_pareto","row_count":4},
         {"kind":"tool","tool":"station_breakdown","row_count":3},{"kind":"tool","tool":"shift_correlation","row_count":3}]',
       r.grounding_json, true, false, r.model, r.prompt_version, '2026-09-10 22:06+07'
FROM agent.run r WHERE r.id = '00000000-0000-7000-8000-000000000f01';

-- A WITHHELD narrative (grounding failed) — proves the no-text constraint and the health view (TC-073)
INSERT INTO agent.run (id, ts, correlation_id, kind, question, answer, model, prompt_version, facts_json,
                       tokens_in, tokens_out, latency_ms, tool_call_count, outcome, grounding_json)
VALUES ('00000000-0000-7000-8000-000000000f02', '2026-09-09 22:05+07', 'seed-narr-0002', 'narrative',
        'shift narrative L2 2026-09-09', NULL, 'qwen3:8b', 'narrative.v1.0',
        '{"inspected":1202,"defects":25,"defect_rate_pct":2.10,"significant":false}',
        1310, 180, 8800, 4, 'grounding_failed',
        '{"numbers_found":["1202","25","2.10","4.7"],"all_matched":false,"unmatched":["4.7"]}');

INSERT INTO vision.narrative
      (id, kind, period_from, period_to, line_id, lang, run_id, facts_json, text, sources_json, grounding_json,
       significant, withheld, withheld_reason, model, prompt_version)
VALUES ('00000000-0000-7000-8000-000000000e02', 'daily', '2026-09-09 06:00+07', '2026-09-09 22:00+07',
        '00000000-0000-7000-8000-00000000000b', 'en', '00000000-0000-7000-8000-000000000f02',
        '{"inspected":1202,"defects":25,"defect_rate_pct":2.10,"significant":false}',
        NULL, '[]', '{"all_matched":false,"unmatched":["4.7"]}',
        false, true, 'GROUNDING_FAILED: value 4.7 not present in any tool result', 'qwen3:8b', 'narrative.v1.0');

-- ---------------------------------------------------------------------
-- 10. Drift metric, config, jobs
-- ---------------------------------------------------------------------

INSERT INTO vision.drift_metric (ts, camera_id, model_id, metric, value, baseline, sigma, alerted) VALUES
  ('2026-09-10 12:00+07', '00000000-0000-7000-8000-000000000903', '00000000-0000-7000-8000-000000000701', 'mean_brightness', 118.4, 121.0, 0.9, false),
  ('2026-09-10 12:00+07', '00000000-0000-7000-8000-000000000903', '00000000-0000-7000-8000-000000000701', 'blur_variance',   214.0, 220.0, 0.4, false);

INSERT INTO ops.config (key, value_json, description) VALUES
  ('alert.defect_rate_pct',          '4.0',          'Threshold for the defect-rate alert (SRS-01 FR-24)'),
  ('alert.defect_rate_window_h',     '8',            'Evaluation window in hours'),
  ('alert.no_read_pct',              '2.0',          'NO_READ share above which the lighting/camera alert fires'),
  ('agent.max_tool_calls_per_turn',  '5',            'Budget enforced by the executor, not by the model'),
  ('agent.max_wall_seconds',         '60',           'Hard stop for one agent turn'),
  ('narrative.schedule_cron',        '"5 22 * * *"', 'Daily narrative after shift B'),
  ('retention.pass_image_days',      '30',           'SRS-01 section 5'),
  ('retention.fail_image_days',      '730',          'SRS-01 section 5'),
  ('evidence.pass_sample_rate',      '0.02',         'ADR-V09');

INSERT INTO ops.scheduled_job (name, cron, enabled) VALUES
  ('daily_narrative',    '5 22 * * *',  true),
  ('agreement_stats',    '0 23 * * *',  true),
  ('retention_sweep',    '0 2 * * *',   true),
  ('partition_maintain', '0 3 1 * *',   true),
  ('drift_check',        '0 */6 * * *', true),
  ('backup_full',        '0 1 * * *',   true);

DROP FUNCTION pg_temp.seed_ts(date, int);

COMMIT;

-- =====================================================================
-- 11. VERIFICATION — expected values the test suite asserts against
-- =====================================================================

\echo '--- Seed verification -------------------------------------------'

\echo 'Expect 8392 inspections total (5x1190 + 1202 + 1240):'
SELECT count(*) AS inspections FROM vision.inspection;

\echo 'Expect day 2026-09-10: inspected 1240, failed 37, defect_rate_pct 2.9839:'
SELECT insp_date, sum(inspected) AS inspected, sum(failed) AS failed,
       ROUND(100.0 * sum(failed) / (sum(inspected) - sum(in_review) - sum(no_read)), 4) AS defect_rate_pct
FROM vision.v_inspection_daily
WHERE insp_date = DATE '2026-09-10' GROUP BY 1;

\echo 'Expect 7-day baseline (09-04..09-09) = 2.1008 pct:'
SELECT ROUND(100.0 * sum(failed) / (sum(inspected) - sum(in_review) - sum(no_read)), 4) AS baseline_pct
FROM vision.v_inspection_daily WHERE insp_date BETWEEN DATE '2026-09-04' AND DATE '2026-09-09';

\echo 'Expect day-7 defect classes: MISSING_FIN 19, SCRATCH 8, MISSING_COMPONENT 6, DENT 4:'
SELECT class_name, sum(parts_affected) AS parts
FROM vision.v_defect_class_daily WHERE insp_date = DATE '2026-09-10'
GROUP BY 1 ORDER BY 2 DESC;

\echo 'Expect day-7 shift split: A 6, B 31:'
SELECT CASE WHEN (i.ts AT TIME ZONE 'Asia/Bangkok')::time < TIME '14:00' THEN 'A' ELSE 'B' END AS shift, count(*)
FROM vision.inspection i
WHERE i.verdict = 'FAIL' AND (i.ts AT TIME ZONE 'Asia/Bangkok')::date = DATE '2026-09-10'
GROUP BY 1 ORDER BY 1;

\echo 'Expect day-7 station split: ST3 27, ST1 5, ST2 5:'
SELECT station, sum(failed) AS failed FROM vision.v_station_daily
WHERE insp_date = DATE '2026-09-10' GROUP BY 1 ORDER BY 2 DESC;

\echo 'Expect lot rates on day 7: LOT-2609-114 = 5.12 pct, LOT-2609-102 = 0.94 pct:'
SELECT lot, count(*) AS parts, count(*) FILTER (WHERE verdict='FAIL') AS failed,
       ROUND(100.0 * count(*) FILTER (WHERE verdict='FAIL') / count(*), 2) AS rate_pct
FROM vision.inspection WHERE (ts AT TIME ZONE 'Asia/Bangkok')::date = DATE '2026-09-10'
GROUP BY 1 ORDER BY 1;

\echo 'Expect review queue depth = 3 (8 REVIEW, 5 decided):'
SELECT count(*) AS review_queue_depth FROM vision.v_review_queue;

\echo 'Expect 10 overrides:'
SELECT count(*) AS overrides FROM vision.verdict_override;

\echo 'Expect 3 valid current calibrations (the unverified v2 on ST3 must be ignored):'
SELECT count(*) AS valid_calibrations FROM vision.v_current_calibration;

\echo 'Expect frozen snapshot with 10 items:'
SELECT name, item_count, frozen_at IS NOT NULL AS frozen FROM vision.dataset_snapshot;

\echo 'Expect narrative health: 2 narratives, 1 withheld:'
SELECT sum(narratives) AS narratives, sum(withheld) AS withheld FROM vision.v_narrative_health;

\echo 'Expect grounding health: 2 runs, 1 grounding_failed:'
SELECT sum(runs) AS runs, sum(grounding_failed) AS grounding_failed FROM agent.v_grounding_health;

\echo '--- End seed verification ---------------------------------------'
