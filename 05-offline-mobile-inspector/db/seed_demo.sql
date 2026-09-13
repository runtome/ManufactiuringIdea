-- =====================================================================
--  PocketQC — demo / test seed  (DDS-05 §9)   — EXECUTED with Python sqlite3; values below were read back
--
--  Models tablet TAB-07 on 2026-09-11: AC-01 exactly — 50 complete inspections in airplane mode with the
--  20-step checklist RAD-500-A-incoming v3 — plus the edge cases every other AC needs:
--    · 3 sessions with a REVIEW step decided by the inspector (FR-10)      sessions 12, 29, 44 (step 6 / 10 / 4)
--    · 8 model-vs-human overrides (FR-11, AI-07): 5 false alarms (suggested FAIL → human PASS) in sessions
--      3, 15, 22, 37, 46; 3 missed defects (suggested PASS → human FAIL) in sessions 33, 41, 49
--    · FAIL sessions 7, 18, 26 (model and human agree), 33, 41, 49 (human override), 22 (supervisor re-judge)
--    · 1 supervisor PIN re-judge of a finished session (FR-19) — session 22 PASS → FAIL, audited, exercised
--      in this seed through the trigger
--    · 1 in-progress session (51) at step 7 of 20 — the AC-03 resume case
--    · sync state after the first Wi-Fi contact on 2026-09-12: sessions 1–30 synced; images of 1–25 uploaded,
--      images of 26–30 pending (80); sessions 31–50 unsynced (20); model 1.1.0 downloaded but self-test FAILED
--
--  Run after schema.sql. Re-run guard: device_info single-row PRIMARY KEY CHECK (id = 1) makes a second seed fail.
--
--  EXPECTED VALUES (read back after execution — TEST-05 TC-005)
--    sessions 51 = finished 50 (PASS 43 / FAIL 7) + in_progress 1 (current_step 7, steps done 6)
--    step_result 1,006 = 50×20 + 6 · measurement 150 · image 804 = 50×16 + 4 (session 51: steps 3–6 carry images)
--    review steps 3 · overrides 8 · manual_mode_steps 0 · undecided steps in finished sessions 0
--    synced sessions 30 · unsynced finished 20 · images uploaded 400 (25×16) · not uploaded 404
--    v_pending_sync: sessions_pending 20 · in_progress 1 · images_pending 80 (only for synced sessions) · stuck 0
--    sync_queue 100 = 20 sessions (priority 1) + 80 images (priority 5)
--    v_purge_candidates 0 (retention 60 d, nothing that old; 0 unsynced rows in it) · v_low_space_candidates 397
--    model_asset 4 (active 2: defect-yolo11n-int8 1.0.0, ocr-lotcode 1.0.0; previous 1: 0.9.0; failed self-test 1: 1.1.0)
--    audit_event 6 · sync_log 5 · purge_log 0 · checklists 3 · skus 12 · defect codes 15
--    low-space candidates = PASS-step images of synced, uploaded sessions 1–25: 25×16 = 400 minus the 3 FAIL-step
--          images (sessions 7, 18 step 8; 18 step 17) → 397; every candidate verified synced + uploaded + PASS
--    OCR one-tap corrections (raw 'L26O911' → 'L260911'): 5 (sessions 9, 18, 27, 36, 45)
--    constraint probes (TEST-05 TC-003), each rejected: finish with undecided REVIEW; second active model; activate
--          after failed self-test; insert active without self-test; model > 25 MB; verdict change without audit;
--          audit update/delete; delete a referenced image; finished without verdict; second device_info row
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. DEVICE, USER, POLICY, BOOTSTRAP STATE
-- ---------------------------------------------------------------------
INSERT INTO device_info (id, device_id, device_model, android_sdk, app_version, schema_version, delegate, delegate_probed_at, lang, server_url, provisioned_at) VALUES
 (1, 'TAB-07', 'Samsung Galaxy Tab Active4 Pro', 34, '1.0.3', 1, 'nnapi', '2026-09-01T08:12:00.000Z', 'th', 'https://factorybrain.plant.local', '2026-09-01T08:10:00.000Z');

INSERT INTO auth_state (id, user_id, username, display_name, role, token_ref, online_login_at, offline_valid_until, supervisor_pin_ref) VALUES
 (1, 'u-0192', 'somchai.k', 'Somchai K. (QC)', 'inspector', 'ks:token:u-0192', '2026-09-10T07:55:00.000Z', '2026-10-10T07:55:00.000Z', 'ks:pin:sup-01');

INSERT INTO policy_cache (id, retention_days, sync_network, image_max_edge_px, image_jpeg_quality, pass_image_upload, gps_enabled, offline_days, low_space_warn_pct, low_space_crit_pct, wipe_requested, etag, fetched_at) VALUES
 (1, 60, 'wifi', 1600, 85, 1, 0, 30, 20, 10, 0, 'W/"pol-14"', '2026-09-12T07:31:05.000Z');

INSERT INTO bootstrap_state (id, etag, fetched_at, last_sync_ok_at, last_sync_error) VALUES
 (1, 'W/"boot-2026-09-08-3"', '2026-09-12T07:31:02.000Z', '2026-09-12T07:34:40.000Z', NULL);

-- ---------------------------------------------------------------------
-- 2. MASTER DATA CACHES
-- ---------------------------------------------------------------------
INSERT INTO checklist_cache (checklist_id, version, sku_pattern, title_th, title_ja, title_en, definition_json, step_count, active) VALUES
 ('RAD-500-A-incoming', 3, '^RAD-500-A', 'ตรวจรับหม้อน้ำ RAD-500-A', 'RAD-500-A 受入検査', 'RAD-500-A incoming inspection',
  '{"checklist":"RAD-500-A-incoming","version":3,"steps":[{"no":1,"kind":"barcode"},{"no":2,"kind":"ocr","pattern":"^L[0-9]{6}-[0-9]{2}$"},{"no":3,"kind":"photo_ai","model":"defect-yolo11n-int8","classes":["scratch","dent","missing_fin"],"accept":{"no_class_above":{"scratch":0.4,"dent":0.4,"missing_fin":0.25}}},{"no":4,"kind":"photo_ai"},{"no":5,"kind":"photo_ai"},{"no":6,"kind":"photo_ai"},{"no":7,"kind":"photo_ai"},{"no":8,"kind":"photo_ai"},{"no":9,"kind":"photo_ai"},{"no":10,"kind":"photo_ai"},{"no":11,"kind":"photo_ai"},{"no":12,"kind":"photo_ai"},{"no":13,"kind":"photo_ai"},{"no":14,"kind":"photo_ai"},{"no":15,"kind":"photo_ai"},{"no":16,"kind":"measure","name":"fin_pitch","usl":3.2,"lsl":2.8,"unit":"mm","method":"aruco_reference"},{"no":17,"kind":"measure","name":"fin_height","usl":16.5,"lsl":15.5,"unit":"mm","method":"aruco_reference"},{"no":18,"kind":"measure","name":"core_width","usl":402,"lsl":398,"unit":"mm","method":"aruco_reference"},{"no":19,"kind":"check","title_en":"Packaging intact"},{"no":20,"kind":"check","title_en":"Label matches PO"}],"verdict_rule":"FAIL if any step FAIL; REVIEW if any step REVIEW; else PASS"}',
  20, 1),
 ('PCB-A-final', 1, '^PCB-A', 'ตรวจขั้นสุดท้าย PCB-A', 'PCB-A 最終検査', 'PCB-A final inspection',
  '{"checklist":"PCB-A-final","version":1,"steps":[{"no":1,"kind":"barcode"},{"no":2,"kind":"photo_ai","model":"defect-yolo11n-int8","classes":["solder_bridge","missing_component"],"accept":{"no_class_above":{"solder_bridge":0.3,"missing_component":0.3}}},{"no":3,"kind":"photo_ai"},{"no":4,"kind":"photo_ai"},{"no":5,"kind":"photo"},{"no":6,"kind":"ocr","pattern":"^SN[0-9]{8}$"},{"no":7,"kind":"check"},{"no":8,"kind":"check"}],"verdict_rule":"FAIL if any step FAIL; REVIEW if any step REVIEW; else PASS"}',
  8, 1),
 ('HOSE-CLAMP-visual', 2, '^HC-', 'ตรวจสายรัดท่อ', 'ホースクランプ外観', 'Hose clamp visual',
  '{"checklist":"HOSE-CLAMP-visual","version":2,"steps":[{"no":1,"kind":"barcode"},{"no":2,"kind":"photo"},{"no":3,"kind":"photo"},{"no":4,"kind":"check"},{"no":5,"kind":"check"}],"verdict_rule":"FAIL if any step FAIL; REVIEW if any step REVIEW; else PASS"}',
  5, 1);

INSERT INTO sku_cache (sku, name, family, checklist_id) VALUES
 ('RAD-500-A-01','Radiator 500 A rev1','RAD-500-A','RAD-500-A-incoming'), ('RAD-500-A-02','Radiator 500 A rev2','RAD-500-A','RAD-500-A-incoming'),
 ('RAD-500-A-03','Radiator 500 A rev3','RAD-500-A','RAD-500-A-incoming'), ('RAD-500-A-04','Radiator 500 A rev4','RAD-500-A','RAD-500-A-incoming'),
 ('PCB-A-100','Controller PCB A','PCB-A','PCB-A-final'), ('PCB-A-110','Controller PCB A+','PCB-A','PCB-A-final'),
 ('PCB-A-120','Controller PCB A2','PCB-A','PCB-A-final'), ('HC-20','Hose clamp 20 mm','HC','HOSE-CLAMP-visual'),
 ('HC-25','Hose clamp 25 mm','HC','HOSE-CLAMP-visual'), ('HC-32','Hose clamp 32 mm','HC','HOSE-CLAMP-visual'),
 ('MOLD-A12','Molded cover A12','MOLD',NULL), ('MOLD-B07','Molded cover B07','MOLD',NULL);

INSERT INTO defect_code_cache (code, name_th, name_ja, name_en, severity_default) VALUES
 ('SCRATCH','รอยขีดข่วน','傷','Scratch','minor'), ('DENT','รอยบุบ','へこみ','Dent','major'), ('MISSING_FIN','ครีบหาย','フィン欠け','Missing fin','major'),
 ('BENT_FIN','ครีบงอ','フィン曲がり','Bent fin','minor'), ('LEAK','รั่ว','漏れ','Leak','critical'), ('CORROSION','สนิม','腐食','Corrosion','major'),
 ('SOLDER_BRIDGE','ตะกั่วเชื่อมติดกัน','ハンダブリッジ','Solder bridge','critical'), ('MISSING_COMPONENT','ชิ้นส่วนหาย','部品欠品','Missing component','critical'),
 ('LABEL_WRONG','ฉลากผิด','ラベル誤り','Wrong label','major'), ('PACKAGING','บรรจุภัณฑ์เสียหาย','包装破損','Packaging damaged','minor'),
 ('DIMENSION','ขนาดไม่ได้','寸法不良','Out of dimension','major'), ('CONTAMINATION','สิ่งปนเปื้อน','異物','Contamination','major'),
 ('CRACK','ร้าว','割れ','Crack','critical'), ('DISCOLOR','สีเพี้ยน','変色','Discoloration','minor'), ('OTHER','อื่นๆ','その他','Other','minor');

-- ---------------------------------------------------------------------
-- 3. MODELS  (0.9.0 previous · 1.0.0 active · 1.1.0 downloaded, self-test FAILED · ocr active)
-- ---------------------------------------------------------------------
INSERT INTO model_asset (name, version, task, sha256, size_bytes, path, class_map_json, input_size, installed_at, verified_at, selftest_passed_at, selftest_json, active, previous) VALUES
 ('defect-yolo11n-int8','0.9.0','detection', printf('%064x', 900), 21400000, 'models/defect-yolo11n-int8/0.9.0.tflite', '{"0":"scratch","1":"dent","2":"missing_fin"}', 640,
  '2026-08-05T09:00:00.000Z','2026-08-05T09:00:20.000Z','2026-08-05T09:00:35.000Z','{"recall_samples":0.97,"latency_p95_ms":412,"delegate":"nnapi"}', 0, 1),
 ('defect-yolo11n-int8','1.0.0','detection', printf('%064x', 1000), 22100000, 'models/defect-yolo11n-int8/1.0.0.tflite', '{"0":"scratch","1":"dent","2":"missing_fin","3":"bent_fin"}', 640,
  '2026-09-02T10:15:00.000Z','2026-09-02T10:15:22.000Z','2026-09-02T10:15:41.000Z','{"recall_samples":0.98,"latency_p95_ms":388,"delegate":"nnapi"}', 1, 0),
 ('defect-yolo11n-int8','1.1.0','detection', printf('%064x', 1100), 23800000, 'models/defect-yolo11n-int8/1.1.0.tflite', '{"0":"scratch","1":"dent","2":"missing_fin","3":"bent_fin","4":"corrosion"}', 640,
  '2026-09-12T07:33:10.000Z','2026-09-12T07:33:31.000Z', NULL, '{"recall_samples":0.80,"latency_p95_ms":455,"delegate":"nnapi","failed":"recall 0.80 < 0.95"}', 0, 0),
 ('ocr-lotcode','1.0.0','ocr', printf('%064x', 2000), 6200000, 'models/ocr-lotcode/1.0.0.tflite', '{"charset":"A-Z0-9-"}', 320,
  '2026-08-05T09:01:00.000Z','2026-08-05T09:01:10.000Z','2026-08-05T09:01:18.000Z','{"char_acc_samples":0.97,"latency_p95_ms":140}', 1, 0);

-- ---------------------------------------------------------------------
-- 4. SESSIONS  (n = 1..50 finished on 2026-09-11 from 08:00 local (+07) every 8 min; n = 51 in progress)
--    FAIL: n in {7,18,26,33,41,49}; session 22 becomes FAIL by re-judge in §7.
--    synced: n <= 30 (at 2026-09-12 07:32 + n s)
-- ---------------------------------------------------------------------
WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 51)
INSERT INTO session (uuid, checklist_id, checklist_version, sku, lot, started_at, finished_at, verdict, current_step, user_id, device_id, lang, synced_at, sync_attempts)
SELECT printf('01991c50-%04x-7000-8000-%012x', n, n),
       'RAD-500-A-incoming', 3,
       printf('RAD-500-A-%02d', 1 + (n % 4)),
       printf('L260911-%02d', 1 + (n / 10)),
       strftime('%Y-%m-%dT%H:%M:%S.000+07:00', '2026-09-11 08:00:00', '+' || ((n-1)*8) || ' minutes'),
       CASE WHEN n <= 50 THEN strftime('%Y-%m-%dT%H:%M:%S.000+07:00', '2026-09-11 08:00:00', '+' || ((n-1)*8) || ' minutes', '+' || (190 + (n*17) % 40) || ' seconds') END,
       CASE WHEN n > 50 THEN NULL WHEN n IN (7,18,26,33,41,49) THEN 'FAIL' ELSE 'PASS' END,
       CASE WHEN n <= 50 THEN 21 ELSE 7 END,
       'u-0192', 'TAB-07', 'th',
       CASE WHEN n <= 30 THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', '2026-09-12 07:32:00', '+' || n || ' seconds') END,
       CASE WHEN n <= 30 THEN 1 ELSE 0 END
FROM s;

-- ---------------------------------------------------------------------
-- 5. IMAGES  for photo_ai (k 3..15) and measure (k 16..18) steps: 16 per finished session, 4 for session 51 (k 3..6)
--    uploaded for n <= 25
-- ---------------------------------------------------------------------
WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 51),
               k(k) AS (SELECT 3 UNION ALL SELECT k+1 FROM k WHERE k < 18)
INSERT INTO image (uuid, path_encrypted, sha256, width, height, bytes, captured_at, torch_on, quality_json, burst_index, upload_offset, uploaded_at)
SELECT printf('01991c51-%04x-7000-8000-%012x', n, k),
       printf('img/%s.enc', printf('01991c51-%04x-7000-8000-%012x', n, k)),
       printf('%064x', n*100 + k),
       1600, 1200,
       180000 + ((n*13 + k*7) % 50) * 1000,
       strftime('%Y-%m-%dT%H:%M:%S.000+07:00', '2026-09-11 08:00:00', '+' || ((n-1)*8) || ' minutes', '+' || (k*10) || ' seconds'),
       CASE WHEN (n + k) % 6 = 0 THEN 1 ELSE 0 END,
       printf('{"blur_var": %d, "exposure_mean": %d, "glare_ratio": 0.0%d}', 180 + (n*k) % 120, 95 + (n + k) % 60, (n*k) % 9),
       CASE WHEN k % 4 = 0 THEN 1 + (n % 5) ELSE NULL END,
       CASE WHEN n <= 25 THEN 180000 + ((n*13 + k*7) % 50) * 1000 ELSE 0 END,
       CASE WHEN n <= 25 THEN strftime('%Y-%m-%dT%H:%M:%S.000Z', '2026-09-12 07:35:00', '+' || (n*16 + k) || ' seconds') END
FROM s, k
WHERE n <= 50 OR k <= 6;

-- ---------------------------------------------------------------------
-- 6. STEP RESULTS  (20 per finished session; 6 for session 51)
-- ---------------------------------------------------------------------
WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 51),
               k(k) AS (SELECT 1 UNION ALL SELECT k+1 FROM k WHERE k < 20)
INSERT INTO step_result (uuid, session_uuid, step_no, kind, model_name, model_version, model_result_json, suggested_result, human_result, decided_at, note, defect_code, severity, text_value, text_raw, image_uuid, latency_ms, created_at)
SELECT printf('01991c52-%04x-7000-8000-%012x', n, k),
       printf('01991c50-%04x-7000-8000-%012x', n, n),
       k,
       CASE WHEN k = 1 THEN 'barcode' WHEN k = 2 THEN 'ocr' WHEN k BETWEEN 3 AND 15 THEN 'photo_ai' WHEN k BETWEEN 16 AND 18 THEN 'measure' ELSE 'check' END,
       CASE WHEN k BETWEEN 3 AND 15 THEN 'defect-yolo11n-int8' WHEN k = 2 THEN 'ocr-lotcode' END,
       CASE WHEN k BETWEEN 3 AND 15 THEN '1.0.0' WHEN k = 2 THEN '1.0.0' END,
       CASE
         WHEN k = 1 THEN printf('{"format":"CODE128","raw":"RAD-500-A-%02d;L260911-%02d"}', 1 + (n % 4), 1 + (n / 10))
         WHEN k = 2 THEN printf('{"raw":"L260911-%02d","char_conf_min":0.%02d}', 1 + (n / 10), 91 + (n % 8))
         -- FAIL sessions: the defect is on step 8. Model agrees for 7,18,26; misses it for 33,41,49.
         WHEN k = 8 AND n IN (7,18,26)  THEN '{"detections":[{"class":"scratch","conf":0.83,"box":[412,300,610,398]}]}'
         WHEN k = 8 AND n IN (33,41,49) THEN '{"detections":[{"class":"dent","conf":0.21,"box":[300,220,340,260]}]}'
         -- REVIEW band: sessions 12/29/44 at steps 6/10/4
         WHEN (n,k) IN ((12,6),(29,10),(44,4)) THEN '{"detections":[{"class":"scratch","conf":0.38,"box":[520,410,560,440]}]}'
         -- false alarms: model says FAIL, human PASS
         WHEN (n,k) IN ((3,5),(15,9),(22,11),(37,7),(46,13)) THEN '{"detections":[{"class":"dent","conf":0.52,"box":[100,90,140,130]}]}'
         WHEN k BETWEEN 3 AND 15 THEN '{"detections":[]}'
         WHEN k BETWEEN 16 AND 18 THEN '{"marker_id":7,"px_per_mm":9.84}'
       END,
       CASE
         WHEN k = 8 AND n IN (7,18,26) THEN 'FAIL'
         WHEN (n,k) IN ((12,6),(29,10),(44,4)) THEN 'REVIEW'
         WHEN (n,k) IN ((3,5),(15,9),(22,11),(37,7),(46,13)) THEN 'FAIL'
         WHEN k BETWEEN 3 AND 15 THEN 'PASS'
         WHEN k BETWEEN 16 AND 18 THEN CASE WHEN (n,k) = (18,17) THEN 'FAIL' ELSE 'PASS' END
         ELSE NULL
       END,
       CASE
         WHEN k IN (1,2) THEN NULL
         WHEN k = 8 AND n IN (7,18,26,33,41,49) THEN 'FAIL'
         WHEN (n,k) = (18,17) THEN 'FAIL'
         ELSE 'PASS'
       END,
       CASE WHEN k IN (1,2) THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%S.000+07:00', '2026-09-11 08:00:00', '+' || ((n-1)*8) || ' minutes', '+' || (k*10 + 4) || ' seconds') END,
       CASE WHEN (n,k) IN ((3,5),(15,9),(22,11),(37,7),(46,13)) THEN 'false alarm — reflection'
            WHEN k = 8 AND n IN (33,41,49) THEN 'model missed it — small dent at left edge'
            WHEN (n,k) IN ((12,6),(29,10),(44,4)) THEN 'borderline mark, within spec' END,
       CASE WHEN k = 8 AND n IN (7,18,26) THEN 'SCRATCH' WHEN k = 8 AND n IN (33,41,49) THEN 'DENT' WHEN (n,k) = (18,17) THEN 'DIMENSION' END,
       CASE WHEN k = 8 AND n IN (7,18,26) THEN 'major' WHEN k = 8 AND n IN (33,41,49) THEN 'major' WHEN (n,k) = (18,17) THEN 'major' END,
       CASE WHEN k = 1 THEN printf('RAD-500-A-%02d;L260911-%02d', 1 + (n % 4), 1 + (n / 10)) WHEN k = 2 THEN printf('L260911-%02d', 1 + (n / 10)) END,
       CASE WHEN k = 2 AND n % 9 = 0 THEN printf('L26O911-%02d', 1 + (n / 10)) WHEN k = 2 THEN printf('L260911-%02d', 1 + (n / 10)) END,   -- OCR read O for 0 every 9th session; corrected by one tap
       CASE WHEN k BETWEEN 3 AND 18 THEN printf('01991c51-%04x-7000-8000-%012x', n, k) END,
       CASE WHEN k BETWEEN 3 AND 15 THEN 300 + (n*k) % 150 WHEN k = 2 THEN 120 + n % 40 END,
       strftime('%Y-%m-%dT%H:%M:%S.000+07:00', '2026-09-11 08:00:00', '+' || ((n-1)*8) || ' minutes', '+' || (k*10 + 5) || ' seconds')
FROM s, k
WHERE n <= 50 OR k <= 6;

-- ---------------------------------------------------------------------
-- 7. MEASUREMENTS (k 16..18 for n <= 50): 3 per session = 150; (18,17) out of spec
-- ---------------------------------------------------------------------
WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 50),
               k(k) AS (SELECT 16 UNION ALL SELECT k+1 FROM k WHERE k < 18)
INSERT INTO measurement (uuid, step_uuid, name, value, unit, usl, lsl, tolerance, in_spec, method, marker_id, px_per_mm)
SELECT printf('01991c53-%04x-7000-8000-%012x', n, k),
       printf('01991c52-%04x-7000-8000-%012x', n, k),
       CASE k WHEN 16 THEN 'fin_pitch' WHEN 17 THEN 'fin_height' ELSE 'core_width' END,
       CASE k WHEN 16 THEN round(3.0 + (((n*7) % 9) - 4) * 0.03, 2)
              WHEN 17 THEN CASE WHEN n = 18 THEN 16.9 ELSE round(16.0 + (((n*5) % 7) - 3) * 0.1, 2) END
              ELSE round(400.0 + (((n*3) % 5) - 2) * 0.5, 1) END,
       'mm',
       CASE k WHEN 16 THEN 3.2 WHEN 17 THEN 16.5 ELSE 402 END,
       CASE k WHEN 16 THEN 2.8 WHEN 17 THEN 15.5 ELSE 398 END,
       CASE k WHEN 16 THEN 0.12 WHEN 17 THEN 0.15 ELSE 0.4 END,
       CASE WHEN n = 18 AND k = 17 THEN 0 ELSE 1 END,
       'aruco_reference', 7, 9.84
FROM s, k;

-- ---------------------------------------------------------------------
-- 8. SYNC QUEUE: unsynced finished sessions (31..50, priority 1) + images of synced-but-not-uploaded sessions 26..30 (priority 5)
-- ---------------------------------------------------------------------
INSERT INTO sync_queue (entity, entity_uuid, priority, attempts, next_retry_at, enqueued_at)
SELECT 'session', uuid, 1, 0, '2026-09-11T10:00:00.000Z', finished_at FROM session WHERE finished_at IS NOT NULL AND synced_at IS NULL;

INSERT INTO sync_queue (entity, entity_uuid, priority, attempts, next_retry_at, enqueued_at)
SELECT 'image', i.uuid, 5, 0, '2026-09-12T07:40:00.000Z', se.synced_at
FROM image i JOIN step_result s ON s.image_uuid = i.uuid JOIN session se ON se.uuid = s.session_uuid
WHERE se.synced_at IS NOT NULL AND i.uploaded_at IS NULL;

INSERT INTO sync_log (ts, kind, ok, http_status, accepted, duplicate, rejected, bytes, duration_ms, detail) VALUES
 ('2026-09-12T07:31:02.000Z','bootstrap',1,200,NULL,NULL,NULL,48210,610,'etag changed → caches replaced (3 checklists, 12 skus, 15 defect codes, 1 new model manifest)'),
 ('2026-09-12T07:31:05.000Z','policy',1,200,NULL,NULL,NULL,412,90,'retention 60 d; wifi only'),
 ('2026-09-12T07:32:30.000Z','sessions',1,207,30,0,0,196400,2900,'batch of 30 (first contact): 30 accepted'),
 ('2026-09-12T07:33:31.000Z','models',0,200,NULL,NULL,NULL,23800000,21000,'defect-yolo11n-int8 1.1.0 downloaded, sha256 ok, SELF-TEST FAILED recall 0.80 — not activated'),
 ('2026-09-12T07:34:40.000Z','images',1,201,400,0,0,88000000,71000,'400 images uploaded (sessions 1–25); Wi-Fi lost before 26–30');

-- ---------------------------------------------------------------------
-- 9. AUDIT + the supervisor re-judge of session 22 (exercises trg_session_rejudge_requires_audit)
-- ---------------------------------------------------------------------
INSERT INTO audit_event (ts, user_id, event, session_uuid, detail_json, synced_at) VALUES
 ('2026-09-10T07:55:00.000Z','u-0192','login_online',NULL,'{"offline_valid_until":"2026-10-10T07:55:00.000Z"}','2026-09-12T07:32:31.000Z'),
 ('2026-09-11T07:58:10.000Z','u-0192','login_offline',NULL,'{"days_left":29}','2026-09-12T07:32:31.000Z'),
 ('2026-09-02T10:15:41.000Z','u-0192','model_activate',NULL,'{"model":"defect-yolo11n-int8","version":"1.0.0","previous":"0.9.0"}','2026-09-12T07:32:31.000Z'),
 ('2026-09-12T07:33:31.000Z','u-0192','selftest_failed',NULL,'{"model":"defect-yolo11n-int8","version":"1.1.0","recall_samples":0.80}',NULL);

-- Supervisor PIN → re-judge session 22 (a false-alarm session) after a second look at the photos: PASS → FAIL
INSERT INTO audit_event (ts, user_id, event, session_uuid, detail_json, synced_at) VALUES
 (strftime('%Y-%m-%dT%H:%M:%fZ','now'), 'sup-01', 'pin_ok',  '01991c50-0016-7000-8000-000000000016', '{"purpose":"rejudge"}', NULL),
 (strftime('%Y-%m-%dT%H:%M:%fZ','now'), 'sup-01', 'rejudge', '01991c50-0016-7000-8000-000000000016', '{"from":"PASS","to":"FAIL","reason":"dent visible on step 11 photo on second look"}', NULL);
UPDATE session SET verdict = 'FAIL', note = 're-judged by supervisor sup-01' WHERE uuid = '01991c50-0016-7000-8000-000000000016';

COMMIT;

-- ---------------------------------------------------------------------
-- 10. VERIFICATION (executed; values in the header)
-- ---------------------------------------------------------------------
-- sessions: finished / verdicts / in progress
SELECT count(*) AS sessions, sum(finished_at IS NOT NULL) AS finished, sum(verdict='PASS') AS pass, sum(verdict='FAIL') AS fail, sum(finished_at IS NULL) AS in_progress FROM session;
SELECT current_step, (SELECT count(*) FROM step_result WHERE session_uuid = s.uuid) AS steps_done FROM session s WHERE finished_at IS NULL;
SELECT (SELECT count(*) FROM step_result) AS steps, (SELECT count(*) FROM measurement) AS measurements, (SELECT count(*) FROM image) AS images;
SELECT sum(review_steps) AS review_steps, sum(overrides) AS overrides, sum(manual_mode_steps) AS manual_mode, sum(CASE WHEN finished_at IS NOT NULL THEN undecided_steps ELSE 0 END) AS undecided_in_finished FROM v_session_summary;
SELECT sum(synced_at IS NOT NULL) AS synced, sum(finished_at IS NOT NULL AND synced_at IS NULL) AS unsynced_finished FROM session;
SELECT sum(uploaded_at IS NOT NULL) AS uploaded, sum(uploaded_at IS NULL) AS not_uploaded FROM image;
SELECT * FROM v_pending_sync;
SELECT priority, count(*) FROM sync_queue GROUP BY priority;
SELECT (SELECT count(*) FROM v_purge_candidates) AS purge_candidates, (SELECT count(*) FROM v_low_space_candidates) AS low_space_candidates;
SELECT count(*) AS models, sum(active) AS active, sum(previous) AS previous, sum(verified_at IS NOT NULL AND selftest_passed_at IS NULL) AS selftest_failed FROM model_asset;
SELECT (SELECT count(*) FROM audit_event), (SELECT count(*) FROM sync_log), (SELECT count(*) FROM purge_log), (SELECT count(*) FROM checklist_cache), (SELECT count(*) FROM sku_cache), (SELECT count(*) FROM defect_code_cache);
