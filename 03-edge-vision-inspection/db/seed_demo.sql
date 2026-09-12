-- =====================================================================
-- EdgeGuard — Deterministic demo / test dataset  (SQLite)
-- Document : DDS-03-EdgeGuard section 9
-- Version  : 1.0
-- Date     : 2026-09-12
--
-- Apply AFTER schema.sql:
--   sqlite3 edgeguard.db < schema.sql
--   sqlite3 edgeguard.db < seed_demo.sql
--
-- SCENARIO — node L2-ST3, 2026-09-10, one shift's worth of a backlog:
--   2,000 inspections from 06:00, 30 s apart (n = 1..2000)
--     verdicts from EXPLICIT position lists (no modulo, no random):
--       FAIL    : 40  · REVIEW : 12 · NO_READ : 8 · PASS : 1,940
--   Sync state: rows n <= 1850 synced; n >= 1851 UNSYNCED (150-record backlog:
--               the central went unreachable at 21:25). Among the unsynced:
--       5 FAIL, 2 REVIEW, 2 NO_READ, 141 PASS
--   Images: FAIL/REVIEW always cached; PASS sampled at 2 % = n multiple of 50.
--           76 images cached in total; 16 still queued for upload (every image
--           of a record with n > 1700 — the image window had not reopened).
--   Overrides: 3 (two synced, one unsynced)
--   Models: defect-yolo11s 1.0.0 active, 0.9.2 previous, 1.1.0 shadow (84/200 frames)
--   Disk policy: 82 % used → free 18 % > 15 % reserve → PASS images enabled
--   Events: boot after power loss (store recovered), model change, sync_backlog
-- =====================================================================

PRAGMA foreign_keys = ON;
BEGIN;

-- Re-seed guard: node_info is the first insert and its single-row trigger
-- aborts the whole transaction if the store was already provisioned.
-- (SQLite allows RAISE() only inside triggers, so the guard lives there.)

-- ---------------------------------------------------------------------
-- 1. Node identity, config, calibration, models
-- ---------------------------------------------------------------------

INSERT INTO node_info (id, node_code, line_code, station_code, plant_code, app_version, hardware, sync_url, lang, provisioned_at)
VALUES (1, 'L2-ST3', 'L2', 'ST3', 'P1', '1.0.0', 'Jetson Orin Nano 8GB / JetPack 6.0',
        'https://visionops.local:8443', 'th', '2026-08-15T09:00:00.000+07:00');

INSERT INTO config_cache (id, etag, bundle_json, source, validated, applied_at) VALUES
 (1, 'W/"cfg-2026-09-08-v7"',
  '{"etag":"W/\"cfg-2026-09-08-v7\"","recipes":[{"sku":"RAD-500-A","version":1,"review_threshold":0.55,"rules":{"schema_version":1,"rules":[{"kind":"class_present","classes":{"MISSING_FIN":0.60,"MISSING_COMPONENT":0.60}},{"kind":"measurement","name":"fin_pitch","usl":3.2,"lsl":2.8,"requires_calibration":true}]}}],"models":[{"name":"defect-yolo11s","version":"1.0.0","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}],"stations":[{"code":"ST3","trigger_mode":"hardware","plc_io":{"ready":17,"pass":27,"fail":22,"review":23,"fault":24,"trigger":4,"pulse_ms":200}}],"sync":{"batch_size":500,"image_window":"22:00-05:00","bandwidth_kbps":2000,"pass_image_sample_rate":0.02}}',
  'central', 1, '2026-09-08T14:20:00.000+07:00');

INSERT INTO calibration_cache (camera_id, version, method, px_per_mm, hardware_fingerprint, valid, fingerprint_ok, checked_at) VALUES
 ('cam0', 1, 'intrinsics_scale', 18.42, 'acA2440:40123403|lens:C2514|mount:M-ST3', 1, 1, '2026-09-10T05:58:30.000+07:00');

INSERT INTO model_cache (id, name, version, task, sha256, artefact_path, engine_path, engine_key, precision, class_map_json, stage, verified_at, shadow_frames, shadow_disagree, activated_at) VALUES
 (1, 'defect-yolo11s', '0.9.2', 'detection', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  '/models/defect-yolo11s-0.9.2.onnx', '/models/cache/orin-nano|r36.3|defect-yolo11s|0.9.2|fp16.plan',
  'orin-nano|r36.3|defect-yolo11s|0.9.2|fp16', 'fp16',
  '{"0":"MISSING_COMPONENT","1":"SCRATCH","2":"MISSING_FIN","3":"DENT"}', 'previous', '2026-07-20T10:00:00.000+07:00', 0, 0, '2026-07-20T10:05:00.000+07:00'),
 (2, 'defect-yolo11s', '1.0.0', 'detection', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  '/models/defect-yolo11s-1.0.0.onnx', '/models/cache/orin-nano|r36.3|defect-yolo11s|1.0.0|fp16.plan',
  'orin-nano|r36.3|defect-yolo11s|1.0.0|fp16', 'fp16',
  '{"0":"MISSING_COMPONENT","1":"SCRATCH","2":"MISSING_FIN","3":"DENT"}', 'active', '2026-08-01T09:40:00.000+07:00', 0, 0, '2026-08-01T10:00:00.000+07:00'),
 (3, 'defect-yolo11s', '1.1.0', 'detection', 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  '/models/defect-yolo11s-1.1.0.onnx', '/models/cache/orin-nano|r36.3|defect-yolo11s|1.1.0|fp16.plan',
  'orin-nano|r36.3|defect-yolo11s|1.1.0|fp16', 'fp16',
  '{"0":"MISSING_COMPONENT","1":"SCRATCH","2":"MISSING_FIN","3":"DENT"}', 'shadow', '2026-09-09T22:10:00.000+07:00', 84, 3, NULL),
 (4, 'patchcore-rad500', '1.0.0', 'anomaly', 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  '/models/patchcore-rad500-1.0.0.onnx', NULL, NULL, 'fp16', '{}', 'active', '2026-08-01T09:41:00.000+07:00', 0, 0, '2026-08-01T10:00:00.000+07:00');

-- ---------------------------------------------------------------------
-- 2. Inspections — 2,000 rows via a recursive CTE; verdicts from lists
--    ts(n) = 2026-09-10T06:00:00+07:00 + (n-1)*30 s   →  n=2000 at 22:39:30
--    synced_at set for n <= 1850 (central unreachable from 21:25)
-- ---------------------------------------------------------------------

WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 2000),
lists AS (
  SELECT
    -- 40 FAIL positions (all distinct, none in the other lists)
    '|37|88|141|190|243|296|349|402|455|508|561|614|667|720|773|826|879|932|985|1038|1091|1144|1197|1250|1303|1356|1409|1462|1515|1568|1621|1674|1727|1780|1833|1861|1902|1944|1971|1993|' AS fail_pos,
    -- 12 REVIEW positions
    '|150|450|750|1050|1350|1650|1700|1750|1800|1850|1875|1990|' AS review_pos,
    -- 8 NO_READ positions
    '|300|600|900|1200|1500|1799|1888|1999|' AS noread_pos
),
rows_ AS (
  SELECT
    s.n,
    printf('01991c00-%04x-7000-8000-%012x', s.n, s.n)                       AS id,
    strftime('%Y-%m-%dT%H:%M:%S', '2026-09-10 06:00:00', '+' || ((s.n-1)*30) || ' seconds') || '.000+07:00' AS ts,
    CASE
      WHEN instr(l.fail_pos,   '|' || s.n || '|') > 0 THEN 'FAIL'
      WHEN instr(l.review_pos, '|' || s.n || '|') > 0 THEN 'REVIEW'
      WHEN instr(l.noread_pos, '|' || s.n || '|') > 0 THEN 'NO_READ'
      ELSE 'PASS'
    END AS verdict
  FROM seq s CROSS JOIN lists l
)
INSERT INTO inspection (id, ts, line, station, camera_id, sku, lot, verdict, no_read_reason, model_version, recipe_version,
                        latency_ms, ocr_text, image_path, overlay_path, image_sha256, frame_id, device_ts, source,
                        created_at, synced_at, sync_attempts, last_sync_error, image_synced_at)
SELECT
  r.id, r.ts, 'L2', 'ST3', 'cam0', 'RAD-500-A',
  CASE WHEN r.n < 1000 THEN 'LOT-2609-102' ELSE 'LOT-2609-114' END,
  r.verdict,
  CASE WHEN r.verdict = 'NO_READ' THEN (CASE WHEN r.n % 2 = 0 THEN 'BLUR' ELSE 'EXPOSURE' END) END,
  'defect-yolo11s:1.0.0', 1,
  CASE WHEN r.verdict = 'NO_READ' THEN 21 ELSE 92 + (r.n % 37) END,
  CASE WHEN r.verdict <> 'NO_READ' THEN (CASE WHEN r.n < 1000 THEN 'LOT-2609-102' ELSE 'LOT-2609-114' END) END,
  -- image cached for FAIL/REVIEW always; PASS only when n is a multiple of 50 (2 % sampling)
  CASE WHEN r.verdict IN ('FAIL','REVIEW') OR (r.verdict = 'PASS' AND r.n % 50 = 0)
       THEN '/var/lib/edgeguard/images/2026-09-10/' || printf('%04d', r.n) || '.jpg' END,
  CASE WHEN r.verdict IN ('FAIL','REVIEW')
       THEN '/var/lib/edgeguard/images/2026-09-10/' || printf('%04d', r.n) || '_overlay.png' END,
  CASE WHEN r.verdict IN ('FAIL','REVIEW') OR (r.verdict = 'PASS' AND r.n % 50 = 0)
       THEN printf('%064x', r.n) END,                                           -- deterministic 64-hex
  100000 + r.n,
  r.ts,
  'edge',
  r.ts,
  CASE WHEN r.n <= 1850 THEN strftime('%Y-%m-%dT%H:%M:%S', '2026-09-10 06:00:00', '+' || ((r.n-1)*30 + 45) || ' seconds') || '.000+07:00' END,
  CASE WHEN r.n <= 1850 THEN 1 ELSE (CASE WHEN r.n <= 1900 THEN 4 ELSE 0 END) END,
  CASE WHEN r.n > 1850 AND r.n <= 1900 THEN 'connect timeout: visionops.local:8443' END,
  -- image synced only for records synced before the 22:00 image window closed the previous night → keep simple: synced records with images before n=1700
  CASE WHEN r.n <= 1700 AND (r.verdict IN ('FAIL','REVIEW') OR (r.verdict = 'PASS' AND r.n % 50 = 0))
       THEN strftime('%Y-%m-%dT%H:%M:%S', '2026-09-10 06:00:00', '+' || ((r.n-1)*30 + 120) || ' seconds') || '.000+07:00' END
FROM rows_ r;

-- Detections for FAIL rows: class by rank within the FAIL list (MF, MC, SC, DENT cycle)
INSERT INTO detection (inspection_id, class_name, confidence, bbox_json, area_mm2)
SELECT i.id,
       CASE ((row_number() OVER (ORDER BY i.ts)) - 1) % 4
            WHEN 0 THEN 'MISSING_FIN' WHEN 1 THEN 'MISSING_COMPONENT' WHEN 2 THEN 'SCRATCH' ELSE 'DENT' END,
       0.91, '{"x":132,"y":251,"w":80,"h":70}', 21.0
FROM inspection i WHERE i.verdict = 'FAIL';

-- REVIEW rows: low-confidence SCRATCH (between review 0.55 and rule 0.75)
INSERT INTO detection (inspection_id, class_name, confidence, bbox_json, area_mm2)
SELECT i.id, 'SCRATCH', 0.61, '{"x":300,"y":180,"w":40,"h":22}', 6.5
FROM inspection i WHERE i.verdict = 'REVIEW';

-- Measurements on the first 50 judged parts (fin_pitch), deterministic values
INSERT INTO measurement (inspection_id, parameter, value, unit, usl, lsl, in_spec, calibration_version)
SELECT id, 'fin_pitch',
       round(3.00 + (((row_number() OVER (ORDER BY ts)) % 7) - 3) * 0.02, 2), 'mm', 3.2, 2.8, 1, 1
FROM inspection WHERE verdict IN ('PASS','FAIL') ORDER BY ts LIMIT 50;

-- Anomaly scores on every judged row of the last 200 (the shadow/anomaly window)
INSERT INTO anomaly_score (inspection_id, model_version, score, threshold, flagged)
SELECT id, 'patchcore-rad500:1.0.0',
       CASE WHEN verdict = 'FAIL' THEN 0.91 ELSE 0.31 END, 0.82,
       CASE WHEN verdict = 'FAIL' THEN 1 ELSE 0 END
FROM inspection WHERE verdict IN ('PASS','FAIL') ORDER BY ts DESC LIMIT 200;

-- ---------------------------------------------------------------------
-- 3. Overrides — 3 (two synced, one unsynced), PIN-attributed
-- ---------------------------------------------------------------------

INSERT INTO override (id, inspection_id, old_verdict, new_verdict, user_ref, reason_code, note, created_at, synced_at) VALUES
 ('01991c00-a001-7000-8000-000000000001', '01991c00-0096-7000-8000-000000000096', 'REVIEW', 'PASS', 'BADGE-0412', 'ACCEPTABLE_MARK', 'handling mark', '2026-09-10T07:20:00.000+07:00', '2026-09-10T07:20:45.000+07:00'),   -- n=150
 ('01991c00-a002-7000-8000-000000000002', '01991c00-02ee-7000-8000-0000000002ee', 'REVIEW', 'FAIL', 'BADGE-0412', 'CONFIRMED_DEFECT', 'scratch 6 mm', '2026-09-10T12:20:00.000+07:00', '2026-09-10T12:20:40.000+07:00'),   -- n=750
 ('01991c00-a003-7000-8000-000000000003', '01991c00-0753-7000-8000-000000000753', 'REVIEW', 'PASS', 'BADGE-0417', 'ACCEPTABLE_MARK', NULL, '2026-09-10T21:40:00.000+07:00', NULL);                                        -- n=1875 (unsynced)

-- ---------------------------------------------------------------------
-- 4. Queues — records n >= 1851 (150) + the unsynced override; images for
--    unsynced FAIL/REVIEW/sampled-PASS and for synced records after n=1700
-- ---------------------------------------------------------------------

INSERT INTO sync_queue (entity, entity_id, priority, attempts, next_retry_at, last_error)
SELECT 'inspection', id,
       CASE WHEN verdict IN ('FAIL','REVIEW') THEN 1 ELSE 5 END,
       sync_attempts,
       '2026-09-10T22:45:00.000+07:00',
       last_sync_error
FROM inspection WHERE synced_at IS NULL;

INSERT INTO sync_queue (entity, entity_id, priority, attempts, next_retry_at)
VALUES ('override', '01991c00-a003-7000-8000-000000000003', 1, 0, '2026-09-10T22:45:00.000+07:00');

INSERT INTO image_queue (inspection_id, kind, path, sha256, bytes, attempts, next_retry_at)
SELECT id, 'original', image_path, image_sha256, 1843200, 0, '2026-09-10T22:00:00.000+07:00'
FROM inspection WHERE image_path IS NOT NULL AND image_synced_at IS NULL;

-- ---------------------------------------------------------------------
-- 5. Node state: faults, disk policy, events, heartbeats, counters
-- ---------------------------------------------------------------------

-- No blocking fault right now; one non-blocking alarm (sync backlog)
INSERT INTO fault_state (source, reason, since, blocks_ready) VALUES
 ('config', 'SYNC_TARGET_UNREACHABLE', '2026-09-10T21:25:10.000+07:00', 0);

INSERT INTO disk_policy_state (id, disk_total_bytes, disk_free_bytes, free_pct, min_free_pct, pass_images_enabled, last_purge_at, last_purged_bytes)
VALUES (1, 256000000000, 46080000000, 18.0, 15.0, 1, '2026-09-10T02:00:00.000+07:00', 1932000000);

INSERT INTO node_event (ts, kind, severity, detail_json, synced_at) VALUES
 ('2026-09-10T05:57:02.000+07:00', 'boot',            'warning',  '{"cause":"power_loss","wal_recovered":true,"quick_check":"ok","ready_after_s":71}', '2026-09-10T06:01:00.000+07:00'),
 ('2026-09-10T05:58:13.000+07:00', 'fault_cleared',   'info',     '{"source":"selftest","after_s":71}', '2026-09-10T06:01:00.000+07:00'),
 ('2026-09-09T22:10:00.000+07:00', 'model_change',    'info',     '{"name":"defect-yolo11s","version":"1.1.0","stage":"shadow","engine_build_s":214}', '2026-09-09T22:15:00.000+07:00'),
 ('2026-09-10T21:25:10.000+07:00', 'sync_backlog',    'warning',  '{"records_unsynced":1,"error":"connect timeout"}', NULL),
 ('2026-09-10T21:40:00.000+07:00', 'pin_failed',      'warning',  '{"attempts":2,"user_ref":"BADGE-0417"}', NULL),
 ('2026-09-10T02:00:05.000+07:00', 'disk_policy',     'info',     '{"purged_bytes":1932000000,"free_pct_after":18.0}', '2026-09-10T02:01:00.000+07:00');

INSERT INTO heartbeat_log (ts, sent, http_status, buffer_depth, cpu_pct, gpu_pct, mem_pct, disk_pct, temp_c, fps, camera_state, calibration_valid) VALUES
 ('2026-09-10T21:24:00.000+07:00', 1, 204, 0,   41.0, 58.0, 62.0, 82.0, 61.5, 2.0, 'ok', 1),
 ('2026-09-10T21:25:00.000+07:00', 0, NULL, 1,  40.0, 57.0, 62.0, 82.0, 61.7, 2.0, 'ok', 1),
 ('2026-09-10T22:39:00.000+07:00', 0, NULL, 150, 39.0, 55.0, 62.0, 82.0, 60.9, 2.0, 'ok', 1);

INSERT INTO shift_counter (shift_date, shift, verdict, count)
SELECT '2026-09-10',
       CASE WHEN ts < '2026-09-10T14:00:00' THEN 'A' ELSE 'B' END,
       verdict, count(*)
FROM inspection GROUP BY 2, 3;

COMMIT;

-- =====================================================================
-- 6. VERIFICATION — expected values (asserted by TEST-03 TC-005 and run
--    by the authoring check in Python)
-- =====================================================================
-- inspections total                 : 2000
-- verdict counts                    : PASS 1940 · FAIL 40 · REVIEW 12 · NO_READ 8
-- unsynced records                  : 150   (n 1851..2000)
-- unsynced by verdict               : FAIL 5 · REVIEW 2 · NO_READ 2 · PASS 141
-- v_backlog.records_unsynced        : 150 ; overrides_unsynced 1 ; images_queued 16 ; records_stuck 0
-- sync_queue rows                   : 151 (150 inspections + 1 override); priority-1 rows 8 (5 FAIL + 2 REVIEW + 1 override)
-- image_queue rows                  : 16 ; images cached 76 ; v_purge_candidates 60 (= 76 - 16 queued)
-- v_purge_candidates                : contains NO unsynced row and NO queued image
-- overrides                         : 3 ; v_effective_verdict effective REVIEW count 9 (12 - 3 overridden)
-- v_ready.ready                     : 1  (alarm present, nothing blocking)
-- v_active_models                   : 2 (detection 1.0.0, anomaly 1.0.0)
-- model_cache stages                : active 2 · previous 1 · shadow 1
-- detections                        : 52 (40 FAIL + 12 REVIEW)
-- measurements                      : 50 ; anomaly_score 200
-- shift_counter                     : A+B totals per verdict equal the verdict counts
