-- =====================================================================
--  GAPFarm AI — demo seed  (DDS-12 §9; TEST-12 TC-005)
--  Reproduces SRS-12 Appendix A and AC-02…AC-09 on one farm, three zones, one season.
--  Apply after schema.sql:   psql -f seed_demo.sql
--  Every expected value below was re-derived in Python (TEST-12 TC-005); PostgreSQL itself was not executed on the
--  authoring machine (README-12 "Verification"). The 14 probes at the end must each FAIL inside their savepoint.
--
--  Farm  สวนพริกบ้านโนน (bannon), ThaiGAP, Asia/Bangkok, quiet hours 20:00–06:00, reminders 07:00
--  Zones A (3.0 rai, chili, planted 2026-06-01, season 4, 3 seasons of history)
--        B (2.5 rai, chili, planted 2026-07-20, season 2 — Appendix A: flowering on 2026-09-09)
--        C (2.0 rai, chili, planted 2026-08-20, season 1 — no history; no scouting record since 2026-08-25)
--  Product PHI / REI / rainfast values are EXAMPLES — verify against the registered label before use (IF-65).
-- =====================================================================
SET TIME ZONE 'Asia/Bangkok';
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Users, scheme, farm, zones, crop, conditions
-- ---------------------------------------------------------------------
INSERT INTO farm.app_user (id, username, display_name, role, phone, line_user_id, pdpa_consent_version, pdpa_consent_at) VALUES
 ('00000000-0000-7000-8000-000000000001', 'somchai',  'สมชาย ใจดี',        'farmer',       '+66810000001', 'U1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6', 'pdpa-2026.1', '2026-06-01 08:00+07'),
 ('00000000-0000-7000-8000-000000000002', 'wipa',     'วิภา ศรีสุข',        'farm_manager', '+66810000002', NULL, 'pdpa-2026.1', '2026-06-01 08:05+07'),
 ('00000000-0000-7000-8000-000000000003', 'arun',     'ดร.อรุณ เกษตรดี',   'agronomist',   NULL, NULL, 'pdpa-2026.1', '2026-06-01 08:10+07'),
 ('00000000-0000-7000-8000-000000000004', 'auditor1', 'ผู้ตรวจประเมิน GAP', 'auditor',      NULL, NULL, 'pdpa-2026.1', '2026-06-01 08:15+07'),
 ('00000000-0000-7000-8000-000000000005', 'admin',    'ผู้ดูแลระบบ',        'admin',        NULL, NULL, 'pdpa-2026.1', '2026-06-01 08:20+07'),
 ('00000000-0000-7000-8000-000000000006', 'admin2',   'ผู้ดูแลระบบ 2',      'admin',        NULL, NULL, 'pdpa-2026.1', '2026-06-01 08:25+07'),
 ('00000000-0000-7000-8000-000000000007', 'mana',     'มานะ ขยัน',          'farmer',       '+66810000007', 'U7f6e5d4c3b2a19081726354a5b6c7d8', 'pdpa-2026.1', '2026-06-02 08:00+07');

INSERT INTO farm.gap_scheme (code, name, version, record_templates_json) VALUES
 ('thaigap', 'ThaiGAP (มกษ. 9001)', '2026.1',
  '{"scouting": ["record_no", "observed_at", "zone", "condition", "severity", "area_pct", "plants_affected", "plants_inspected", "evidence", "author"],
    "input_usage": ["record_no", "ts", "zone", "product", "active_ingredient", "dose", "unit", "method", "applicator", "weather", "ppe", "phi_days", "phi_clear_at"],
    "harvest": ["record_no", "harvested_at", "zone", "lot_code", "qty", "unit", "grade", "phi_clear_at", "inputs", "scouting"]}');
INSERT INTO farm.gap_scheme_rule (scheme_code, rule_code, record_kind, max_gap_days, mandatory, description_th, description_en) VALUES
 ('thaigap', 'scouting_interval',     'scouting',    7,    true, 'ต้องมีบันทึกการสำรวจแปลงอย่างน้อยทุก 7 วัน',             'A scouting record at least every 7 days'),
 ('thaigap', 'input_usage_complete',  'input_usage', NULL, true, 'บันทึกการใช้ปัจจัยการผลิตต้องครบ: ผลิตภัณฑ์ อัตรา วิธี ผู้พ่น สภาพอากาศ PPE', 'Input-usage records complete: product, dose, method, applicator, weather, PPE'),
 ('thaigap', 'harvest_traceability',  'harvest',     NULL, true, 'ทุกล็อตเก็บเกี่ยวต้องสืบย้อนถึงแปลงและปัจจัยการผลิตได้',  'Every harvest lot traceable to zone and inputs');

INSERT INTO farm.farm (id, code, name, owner_id, location, gap_scheme) VALUES
 ('00000000-0000-7000-8000-000000000100', 'bannon', 'สวนพริกบ้านโนน', '00000000-0000-7000-8000-000000000001', ST_GeogFromText('SRID=4326;POINT(102.8330 16.4320)'), 'thaigap');
INSERT INTO farm.farm_member (farm_id, user_id, role) VALUES
 ('00000000-0000-7000-8000-000000000100', '00000000-0000-7000-8000-000000000001', 'farmer'),
 ('00000000-0000-7000-8000-000000000100', '00000000-0000-7000-8000-000000000002', 'farm_manager'),
 ('00000000-0000-7000-8000-000000000100', '00000000-0000-7000-8000-000000000003', 'agronomist'),
 ('00000000-0000-7000-8000-000000000100', '00000000-0000-7000-8000-000000000007', 'farmer');

INSERT INTO farm.crop (id, code, name_th, name_en, variety, family, gdd_base_c, stage_model_json) VALUES
 ('00000000-0000-7000-8000-000000000300', 'chili', 'พริก', 'Chili', 'พริกขี้หนูสวน', 'chili', 10.0,
  '[{"stage": "seedling", "gdd_from": 0}, {"stage": "vegetative", "gdd_from": 250}, {"stage": "flowering", "gdd_from": 650},
    {"stage": "fruit_set", "gdd_from": 950}, {"stage": "maturity", "gdd_from": 1400}]');

INSERT INTO farm.condition (code, crop_id, kind, name_th, name_en, distinguishing_features_th, how_to_confirm_th, fast_spreading) VALUES
 ('cercospora_leaf_spot', '00000000-0000-7000-8000-000000000300', 'disease',    'โรคใบจุด',             'Cercospora leaf spot', 'จุดกลมสีน้ำตาลขอบเข้ม กลางใบซีด กระจายที่ใบล่าง', 'ถ่ายภาพใต้ใบเพิ่ม และดูว่ามีวงซ้อนหรือไม่', false),
 ('anthracnose',          '00000000-0000-7000-8000-000000000300', 'disease',    'โรคแอนแทรคโนส',        'Anthracnose',          'แผลยุบตัวสีน้ำตาลดำบนผล มีวงแหวนซ้อนและจุดสีส้ม', 'ดูผลที่แผลยุบ มีเมือกสีส้มหรือไม่ ถ่ายภาพผลใกล้ ๆ', true),
 ('mg_deficiency',        '00000000-0000-7000-8000-000000000300', 'deficiency', 'ขาดธาตุแมกนีเซียม',    'Magnesium deficiency', 'ใบล่างเหลืองระหว่างเส้นใบ เส้นใบยังเขียว',           'ดูใบล่างหลายต้นว่าเหลืองเป็นแบบเดียวกันหรือไม่', false),
 ('bacterial_wilt',       '00000000-0000-7000-8000-000000000300', 'disease',    'โรคเหี่ยวเขียว',        'Bacterial wilt',       'ต้นเหี่ยวทั้งต้นขณะใบยังเขียว ตัดโคนต้นจุ่มน้ำมีน้ำขุ่นไหล', 'ตัดโคนต้นจุ่มน้ำใส ดูเมือกขุ่น', true),
 ('thrips',               '00000000-0000-7000-8000-000000000300', 'pest',       'เพลี้ยไฟ',              'Thrips',               'ใบหงิกม้วนขึ้น ผิวใบด้านล่างเป็นสีเงิน', 'เคาะยอดบนกระดาษขาว ดูตัวเล็กสีเหลืองวิ่ง', false),
 ('fruit_borer',          '00000000-0000-7000-8000-000000000300', 'pest',       'หนอนเจาะผล',            'Fruit borer',          'ผลมีรูเจาะ มูลหนอนที่ขั้ว', 'ผ่าผลดูหนอนภายใน', false),
 ('healthy',              '00000000-0000-7000-8000-000000000300', 'healthy',    'ปกติ',                  'Healthy',              'ไม่พบอาการผิดปกติ', '-', false);

INSERT INTO farm.zone (id, farm_id, code, name, boundary, area_rai, crop_id, planted_at, season_no) VALUES
 ('00000000-0000-7000-8000-000000000201', '00000000-0000-7000-8000-000000000100', 'A', 'แปลง A (หน้าบ้าน)',
  ST_GeogFromText('SRID=4326;POLYGON((102.8320 16.4315, 102.8330 16.4315, 102.8330 16.4322, 102.8320 16.4322, 102.8320 16.4315))'), 3.0, '00000000-0000-7000-8000-000000000300', '2026-06-01', 4),
 ('00000000-0000-7000-8000-000000000202', '00000000-0000-7000-8000-000000000100', 'B', 'แปลง B (ริมคลอง)',
  ST_GeogFromText('SRID=4326;POLYGON((102.8330 16.4315, 102.8340 16.4315, 102.8340 16.4322, 102.8330 16.4322, 102.8330 16.4315))'), 2.5, '00000000-0000-7000-8000-000000000300', '2026-07-20', 2),
 ('00000000-0000-7000-8000-000000000203', '00000000-0000-7000-8000-000000000100', 'C', 'แปลง C (หลังบ้าน)',
  ST_GeogFromText('SRID=4326;POLYGON((102.8320 16.4322, 102.8340 16.4322, 102.8340 16.4328, 102.8320 16.4328, 102.8320 16.4322))'), 2.0, '00000000-0000-7000-8000-000000000300', '2026-08-20', 1);

INSERT INTO farm.notification_channel (user_id, kind, address_ref) VALUES
 ('00000000-0000-7000-8000-000000000001', 'line', 'line:U1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6'),
 ('00000000-0000-7000-8000-000000000001', 'push', 'push:dev-0401'),
 ('00000000-0000-7000-8000-000000000002', 'line', 'line:manager'),
 ('00000000-0000-7000-8000-000000000007', 'line', 'line:U7f6e5d4c3b2a19081726354a5b6c7d8');
INSERT INTO farm.device (id, user_id, platform, app_version, device_model_version, push_token_ref) VALUES
 ('00000000-0000-7000-8000-000000000401', '00000000-0000-7000-8000-000000000001', 'android', '1.0.0', 'chili-v3-lite', 'push:dev-0401'),
 ('00000000-0000-7000-8000-000000000407', '00000000-0000-7000-8000-000000000007', 'android', '1.0.0', 'chili-v3-lite', 'push:dev-0407');

-- Yield history for zone A (3 seasons) and zone B (1 season) — AC-09
INSERT INTO farm.yield_history (zone_id, season_no, planted_at, harvested_at, gdd_to_harvest, yield_kg_per_rai) VALUES
 ('00000000-0000-7000-8000-000000000201', 1, '2024-06-05', '2024-09-20', 1420, 1450.0),
 ('00000000-0000-7000-8000-000000000201', 2, '2024-11-01', '2025-02-20', 1465, 1520.0),
 ('00000000-0000-7000-8000-000000000201', 3, '2025-06-03', '2025-09-15', 1390, 1380.0),
 ('00000000-0000-7000-8000-000000000202', 1, '2025-06-10', '2025-09-25', 1440, 1310.0);

-- ---------------------------------------------------------------------
-- 2. Approved inputs (C-02) — example label values; one banned product for the adversarial tests
-- ---------------------------------------------------------------------
INSERT INTO farm.input_product (id, code, name, name_th, active_ingredient, type, phi_days, rei_hours, rainfast_hours, approved, author_id, approved_by, approved_at, label_uri, mrl_json, crops, target_conditions, cautions_th) VALUES
 ('00000000-0000-7000-8000-000000000601', 'P-MANCO',  'Mancozeb 80% WP',        'แมนโคเซบ 80% WP',      'mancozeb',           'fungicide',  7, 24, 6, true, '00000000-0000-7000-8000-000000000005', '00000000-0000-7000-8000-000000000006', '2026-05-20 09:00+07', 's3://labels/P-MANCO-2026.pdf', '{"chili": {"mg_per_kg": 2.0, "source": "example — verify against the current MRL list"}}', '{chili}', '{cercospora_leaf_spot,anthracnose}', 'สวมถุงมือ หน้ากาก แว่นตา; ห้ามพ่นขณะลมแรง; งดเก็บเกี่ยว 7 วัน'),
 ('00000000-0000-7000-8000-000000000602', 'P-AZOXY',  'Azoxystrobin 25% SC',    'อะซอกซีสโตรบิน 25% SC', 'azoxystrobin',       'fungicide',  3,  4, 2, true, '00000000-0000-7000-8000-000000000005', '00000000-0000-7000-8000-000000000006', '2026-05-20 09:05+07', 's3://labels/P-AZOXY-2026.pdf', '{"chili": {"mg_per_kg": 3.0, "source": "example"}}', '{chili}', '{anthracnose,cercospora_leaf_spot}', 'สลับกลุ่มสารเพื่อลดการดื้อยา; งดเก็บเกี่ยว 3 วัน'),
 ('00000000-0000-7000-8000-000000000603', 'P-COPPER', 'Copper hydroxide 77% WP', 'คอปเปอร์ไฮดรอกไซด์ 77% WP', 'copper hydroxide', 'fungicide',  3, 24, 4, true, '00000000-0000-7000-8000-000000000005', '00000000-0000-7000-8000-000000000006', '2026-05-20 09:10+07', 's3://labels/P-COPPER-2026.pdf', '{"chili": {"mg_per_kg": 5.0, "source": "example"}}', '{chili}', '{cercospora_leaf_spot,bacterial_wilt}', 'ห้ามผสมสารที่มีฤทธิ์เป็นกรด; งดเก็บเกี่ยว 3 วัน'),
 ('00000000-0000-7000-8000-000000000604', 'P-MGSO4',  'Magnesium sulphate',      'แมกนีเซียมซัลเฟต',     'magnesium sulphate', 'fertilizer', 0,  0, 1, true, '00000000-0000-7000-8000-000000000005', '00000000-0000-7000-8000-000000000006', '2026-05-20 09:15+07', 's3://labels/P-MGSO4-2026.pdf', '{}', '{chili}', '{mg_deficiency}', 'พ่นทางใบช่วงเช้าหรือเย็น'),
 ('00000000-0000-7000-8000-000000000605', 'P-BTK',    'Bacillus thuringiensis',  'บีที',                 'Bacillus thuringiensis kurstaki', 'biocontrol', 0, 4, 2, true, '00000000-0000-7000-8000-000000000005', '00000000-0000-7000-8000-000000000006', '2026-05-20 09:20+07', 's3://labels/P-BTK-2026.pdf', '{}', '{chili}', '{fruit_borer}', 'พ่นช่วงเย็น หลีกเลี่ยงแสงแดดจัด');
INSERT INTO farm.input_product (id, code, name, name_th, active_ingredient, type, phi_days, rei_hours, approved, author_id, unapproved_reason, crops) VALUES
 ('00000000-0000-7000-8000-000000000606', 'P-PARAQ',  'Paraquat dichloride 27.6% SL', 'พาราควอต', 'paraquat', 'herbicide', 0, 24, false, '00000000-0000-7000-8000-000000000005', 'banned in Thailand (Hazardous Substances Committee, effective 2020-06-01)', '{}');

-- Task templates (FR-16) — Appendix A shape
INSERT INTO farm.task_template (id, condition_kind, min_severity, ordinal, task_kind, description_th, description_en, due_offset_days, priority, n_plants) VALUES
 ('00000000-0000-7000-8000-000000001001', 'disease',    'severe',   0, 'inspect',  'แจ้งผู้จัดการแปลงและตรวจการลุกลามทันที', 'Notify the farm manager and check spread immediately', 0, 'critical', NULL),
 ('00000000-0000-7000-8000-000000001002', 'disease',    'low',      1, 'inspect',  'ตรวจต้นข้างเคียง {n_plants} ต้น',           'Inspect {n_plants} nearby plants',                     0, 'normal', 10),
 ('00000000-0000-7000-8000-000000001003', 'disease',    'moderate', 2, 'treat',    'พิจารณาพ่นสารตามรายการที่อนุมัติ',          'Consider spraying from the approved list',            1, 'normal', NULL),
 ('00000000-0000-7000-8000-000000001004', 'pest',       'low',      1, 'inspect',  'ตรวจต้นข้างเคียง {n_plants} ต้น',           'Inspect {n_plants} nearby plants',                     0, 'normal', 10),
 ('00000000-0000-7000-8000-000000001005', 'deficiency', 'low',      2, 'treat',    'พิจารณาให้ปุ๋ยตามรายการที่อนุมัติ',          'Consider a fertiliser from the approved list',        1, 'normal', NULL),
 ('00000000-0000-7000-8000-000000001006', NULL,         'low',      3, 'followup', 'ถ่ายภาพติดตามผลอีกครั้ง',                   'Take a follow-up photo',                              7, 'normal', NULL);

-- Risk rules (FR-24) — data with a source
INSERT INTO farm.risk_rule (crop_id, condition_code, rh_min_pct, temp_min_c, temp_max_c, hours_min, level, message_th, source) VALUES
 ('00000000-0000-7000-8000-000000000300', 'cercospora_leaf_spot', 78, 24, 32, 4, 'elevated', 'ความชื้นสูงต่อเนื่องและอุณหภูมิ 24–32 °C — ความเสี่ยงโรคใบจุดสูงขึ้น ควรสำรวจใบล่าง', 'DOA plant-protection bulletin 2025 (example)'),
 ('00000000-0000-7000-8000-000000000300', 'anthracnose',          85, 25, 30, 8, 'high',     'ฝนชุก ความชื้นสูงมาก — ความเสี่ยงแอนแทรคโนสบนผลสูง ตรวจผลทุกวัน',                   'DOA plant-protection bulletin 2025 (example)');

-- Sensors (FR-21)
INSERT INTO farm.sensor_kind (code, unit, min_value, max_value, stuck_readings, description_th) VALUES
 ('soil_moisture', '%',     0, 100, 12, 'ความชื้นดิน'), ('air_temp', 'C', -10, 60, 12, 'อุณหภูมิอากาศ'), ('air_rh', '%', 0, 100, 12, 'ความชื้นสัมพัทธ์'),
 ('soil_ec', 'mS/cm', 0, 20, 12, 'ค่าการนำไฟฟ้าดิน'), ('soil_ph', 'pH', 0, 14, 12, 'ความเป็นกรดด่างดิน'), ('rain', 'mm', 0, 500, 12, 'ปริมาณฝน');
INSERT INTO farm.sensor (id, zone_id, kind, unit, device_code, installed_at) VALUES
 ('00000000-0000-7000-8000-000000000501', '00000000-0000-7000-8000-000000000201', 'soil_moisture', '%',     'SM-A1', '2026-06-01'),
 ('00000000-0000-7000-8000-000000000502', '00000000-0000-7000-8000-000000000201', 'air_temp',      'C',     'T-A1',  '2026-06-01'),
 ('00000000-0000-7000-8000-000000000503', '00000000-0000-7000-8000-000000000201', 'air_rh',        '%',     'RH-A1', '2026-06-01'),
 ('00000000-0000-7000-8000-000000000504', '00000000-0000-7000-8000-000000000202', 'soil_moisture', '%',     'SM-B1', '2026-07-20'),
 ('00000000-0000-7000-8000-000000000505', '00000000-0000-7000-8000-000000000202', 'soil_ec',       'mS/cm', 'EC-B1', '2026-07-20');

-- Knowledge chunks the agent cites (FR-27); embeddings are computed at import (OPS-12 §6), NULL here
INSERT INTO farm.knowledge_chunk (id, crop_id, source, title, text, version) VALUES
 ('00000000-0000-7000-8000-000000000d01', '00000000-0000-7000-8000-000000000300', 'DOA chili handbook 2025 (example)', 'โรคใบจุดพริก', 'โรคใบจุด (Cercospora) ระบาดในสภาพความชื้นสูง อาการจุดกลมสีน้ำตาลขอบเข้ม ควบคุมโดยเก็บใบเป็นโรคออก ลดความชื้นในแปลง และใช้สารป้องกันกำจัดเชื้อราตามคำแนะนำบนฉลาก', '2025.1'),
 ('00000000-0000-7000-8000-000000000d02', '00000000-0000-7000-8000-000000000300', 'DOA chili handbook 2025 (example)', 'โรคแอนแทรคโนสพริก', 'โรคแอนแทรคโนสทำลายผล แผลยุบตัว ลุกลามเร็วในช่วงฝนชุก เก็บผลเป็นโรคออกจากแปลง สลับกลุ่มสารเพื่อลดการดื้อยา', '2025.1'),
 ('00000000-0000-7000-8000-000000000d03', NULL, 'ThaiGAP guidance (example)', 'ระยะปลอดภัยก่อนเก็บเกี่ยว (PHI)', 'ระยะปลอดภัยก่อนเก็บเกี่ยว (PHI) คือจำนวนวันขั้นต่ำระหว่างการใช้สารครั้งสุดท้ายกับการเก็บเกี่ยว ต้องยึดตามฉลากและบันทึกทุกครั้ง', '2026.1');

-- ---------------------------------------------------------------------
-- 3. Weather — 2026-06-01 … 2026-09-20 daily, deterministic integer formula (re-derived in Python) — FR-23, FR-30
-- ---------------------------------------------------------------------
INSERT INTO farm.weather_daily (farm_id, day, tmax_c, tmin_c, rh_mean_pct, rh_hours_ge, rain_mm)
SELECT '00000000-0000-7000-8000-000000000100', d::date,
       30 + ((n * 7) % 5), 22 + ((n * 3) % 4), 70 + ((n * 11) % 20), (n * 5) % 13,
       CASE WHEN n % 4 = 0 THEN 5 + ((n * 13) % 20) ELSE 0 END
FROM generate_series('2026-06-01'::date, '2026-09-20'::date, interval '1 day') d, LATERAL (SELECT (d::date - '2026-06-01'::date) AS n) x;

-- Forecast snapshots (IF-12): the one Appendix A saw on 2026-09-09 (rain within 12 h), and the current one (2026-09-20)
INSERT INTO farm.weather_forecast (farm_id, provider, fetched_at, valid_from, valid_to, rain_mm, rain_prob, temp_c, rh_pct, wind_ms) VALUES
 ('00000000-0000-7000-8000-000000000100', 'open-meteo', '2026-09-09 10:00+07', '2026-09-09 10:00+07', '2026-09-09 18:00+07',  0.0, 0.10, 31.0, 74, 1.5),
 ('00000000-0000-7000-8000-000000000100', 'open-meteo', '2026-09-09 10:00+07', '2026-09-09 18:00+07', '2026-09-10 06:00+07', 12.0, 0.80, 26.0, 92, 2.0),
 ('00000000-0000-7000-8000-000000000100', 'open-meteo', '2026-09-09 10:00+07', '2026-09-10 06:00+07', '2026-09-10 12:00+07',  6.0, 0.70, 27.0, 90, 1.0),
 ('00000000-0000-7000-8000-000000000100', 'open-meteo', '2026-09-09 10:00+07', '2026-09-10 12:00+07', '2026-09-10 18:00+07',  0.0, 0.20, 30.0, 78, 1.2),
 ('00000000-0000-7000-8000-000000000100', 'open-meteo', '2026-09-20 08:00+07', '2026-09-20 08:00+07', '2026-09-20 20:00+07',  0.0, 0.05, 32.0, 68, 1.8),
 ('00000000-0000-7000-8000-000000000100', 'open-meteo', '2026-09-20 08:00+07', '2026-09-20 20:00+07', '2026-09-21 08:00+07',  2.0, 0.30, 25.0, 84, 0.8);

-- ---------------------------------------------------------------------
-- 4. Models, evaluation, calibration (AI-02…AI-06)
-- ---------------------------------------------------------------------
INSERT INTO farm.model_registry (id, name, version, crop_family, kind, size_mb, uri, status) VALUES
 ('00000000-0000-7000-8000-000000000a01', 'chili', 'v3',      'chili', 'server', 182.4, 's3://models/chili-v3/model.onnx',       'evaluated'),
 ('00000000-0000-7000-8000-000000000a02', 'chili', 'v3-lite', 'chili', 'device',  21.5, 's3://models/chili-v3-lite/model.tflite', 'evaluated'),
 ('00000000-0000-7000-8000-000000000a03', 'chili', 'v4',      'chili', 'server', 190.0, 's3://models/chili-v4/model.onnx',       'draft'),
 ('00000000-0000-7000-8000-000000000a04', 'chili', 'v4-lite', 'chili', 'device',  27.3, 's3://models/chili-v4-lite/model.tflite', 'draft');
INSERT INTO farm.model_eval_run (model_id, set_kind, set_name, n_images, top1, top3, ece, ood_auroc, run_at) VALUES
 ('00000000-0000-7000-8000-000000000a01', 'field', 'field-chili-2026Q2 (real phone photos, mixed lighting)', 640, 0.830, 0.940, 0.031, 0.962, '2026-08-20 10:00+07'),
 ('00000000-0000-7000-8000-000000000a02', 'field', 'field-chili-2026Q2',                                     640, 0.810, 0.931, 0.038, 0.951, '2026-08-20 11:00+07'),
 ('00000000-0000-7000-8000-000000000a03', 'lab',   'PlantVillage-pepper',                                   2000, 0.970, 0.995, 0.020, NULL,  '2026-09-15 10:00+07'),   -- lab only: never passes (AI-03)
 ('00000000-0000-7000-8000-000000000a03', 'field', 'field-chili-2026Q3',                                     710, 0.780, 0.925, 0.044, 0.940, '2026-09-16 10:00+07'),   -- below the gates
 ('00000000-0000-7000-8000-000000000a04', 'field', 'field-chili-2026Q3',                                     710, 0.815, 0.935, 0.040, 0.945, '2026-09-16 11:00+07');   -- passes, but 27.3 MB > 25 MB
INSERT INTO farm.calibration_version (id, model_id, version, temperature, ece, ood_threshold, reliability_json, active) VALUES
 ('00000000-0000-7000-8000-000000000a11', '00000000-0000-7000-8000-000000000a01', 'chili-v3-cal1', 1.42, 0.031, 6.5,
  '[{"lo": 0.5, "hi": 0.6, "confidence": 0.55, "accuracy": 0.52, "n": 61}, {"lo": 0.6, "hi": 0.7, "confidence": 0.65, "accuracy": 0.64, "n": 88},
    {"lo": 0.7, "hi": 0.8, "confidence": 0.75, "accuracy": 0.73, "n": 140}, {"lo": 0.8, "hi": 0.9, "confidence": 0.85, "accuracy": 0.83, "n": 201}, {"lo": 0.9, "hi": 1.0, "confidence": 0.94, "accuracy": 0.92, "n": 150}]', true),
 ('00000000-0000-7000-8000-000000000a12', '00000000-0000-7000-8000-000000000a02', 'chili-v3-lite-cal1', 1.55, 0.038, 6.9,
  '[{"lo": 0.6, "hi": 0.7, "confidence": 0.65, "accuracy": 0.62, "n": 90}, {"lo": 0.7, "hi": 0.8, "confidence": 0.75, "accuracy": 0.72, "n": 150}, {"lo": 0.8, "hi": 0.9, "confidence": 0.85, "accuracy": 0.81, "n": 210}, {"lo": 0.9, "hi": 1.0, "confidence": 0.94, "accuracy": 0.90, "n": 150}]', true);
UPDATE farm.model_registry SET status = 'released', released_by = '00000000-0000-7000-8000-000000000005', released_at = '2026-08-21 09:00+07' WHERE id IN ('00000000-0000-7000-8000-000000000a01', '00000000-0000-7000-8000-000000000a02');

-- ---------------------------------------------------------------------
-- 5. Routine scouting records (weekly, healthy) — the ThaiGAP 7-day rule; zone C stops after 2026-08-25 (FR-15)
--    Counter preset so that Appendix A's record is SC-2026-0412.
-- ---------------------------------------------------------------------
INSERT INTO farm.record_counter (farm_id, kind, year, last_no) VALUES
 ('00000000-0000-7000-8000-000000000100', 'scouting', 2026, 390), ('00000000-0000-7000-8000-000000000100', 'input_usage', 2026, 30), ('00000000-0000-7000-8000-000000000100', 'harvest', 2026, 6);

DO $$
DECLARE r record; v_farm uuid := '00000000-0000-7000-8000-000000000100'; v_u uuid := '00000000-0000-7000-8000-000000000001';
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('00000000-0000-7000-8000-000000000201'::uuid, '2026-06-22 08:00+07'::timestamptz), ('00000000-0000-7000-8000-000000000201', '2026-06-29 08:00+07'),
        ('00000000-0000-7000-8000-000000000201', '2026-07-06 08:00+07'), ('00000000-0000-7000-8000-000000000201', '2026-07-13 08:00+07'),
        ('00000000-0000-7000-8000-000000000201', '2026-07-20 08:00+07'), ('00000000-0000-7000-8000-000000000201', '2026-07-27 08:00+07'),
        ('00000000-0000-7000-8000-000000000202', '2026-07-27 08:30+07'), ('00000000-0000-7000-8000-000000000201', '2026-08-03 08:00+07'),
        ('00000000-0000-7000-8000-000000000202', '2026-08-03 08:30+07'), ('00000000-0000-7000-8000-000000000201', '2026-08-10 08:00+07'),
        ('00000000-0000-7000-8000-000000000202', '2026-08-10 08:30+07'), ('00000000-0000-7000-8000-000000000201', '2026-08-17 08:00+07'),
        ('00000000-0000-7000-8000-000000000202', '2026-08-17 08:30+07'), ('00000000-0000-7000-8000-000000000201', '2026-08-24 08:00+07'),
        ('00000000-0000-7000-8000-000000000202', '2026-08-24 08:30+07'), ('00000000-0000-7000-8000-000000000203', '2026-08-25 08:00+07'),
        ('00000000-0000-7000-8000-000000000201', '2026-08-31 08:00+07'), ('00000000-0000-7000-8000-000000000202', '2026-08-31 08:30+07'),
        ('00000000-0000-7000-8000-000000000201', '2026-09-05 08:00+07'), ('00000000-0000-7000-8000-000000000202', '2026-09-05 08:30+07')
    ) v(zone_id, at) ORDER BY at LOOP
        INSERT INTO farm.scouting_record (record_no, zone_id, observed_at, condition_code, severity, area_pct, plants_affected, plants_inspected, notes_th, author_id, author_ref)
        VALUES (farm.next_record_no(v_farm, 'scouting', r.at), r.zone_id, r.at, 'healthy', 'none', 0.00, 0, 30, 'ตรวจแปลงประจำสัปดาห์', v_u, farm.pseudonym(v_u));
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 6. Zone A — anthracnose, severe (2026-09-08): consult flag, critical task, escalation, treatment, PHI, harvest (AC-04)
-- ---------------------------------------------------------------------
INSERT INTO farm.observation (id, zone_id, ts, kind, photos_json, area_pct, plants_affected, plants_inspected, growth_stage, gps, reporter_id, reporter_ref) VALUES
 ('00000000-0000-7000-8000-000000000702', '00000000-0000-7000-8000-000000000201', '2026-09-08 08:00+07', 'scouting',
  '["00000000-0000-7000-8000-000000000804", "00000000-0000-7000-8000-000000000805"]', 18.00, 14, 30, 'maturity',
  ST_GeogFromText('SRID=4326;POINT(102.8325 16.4318)'), '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'));
INSERT INTO farm.photo (id, observation_id, uri, sha256, bytes, width, height, gate_json, taken_at) VALUES
 ('00000000-0000-7000-8000-000000000804', '00000000-0000-7000-8000-000000000702', 's3://photos/bannon/0702/0804.jpg', 'a4'||repeat('0', 62), 611240, 1600, 1200, '{"blur": 0.66, "exposure": 0.52, "distance": "ok", "pass": true}', '2026-09-08 07:58+07'),
 ('00000000-0000-7000-8000-000000000805', '00000000-0000-7000-8000-000000000702', 's3://photos/bannon/0702/0805.jpg', 'a5'||repeat('0', 62), 598113, 1600, 1200, '{"blur": 0.71, "exposure": 0.49, "distance": "ok", "pass": true}', '2026-09-08 07:59+07');
INSERT INTO farm.diagnosis (id, observation_id, model_version, calibration_version, computed_on, candidates_json) VALUES
 ('00000000-0000-7000-8000-000000000902', '00000000-0000-7000-8000-000000000702', 'chili-v3', 'chili-v3-cal1', 'server',
  '[{"condition_code": "anthracnose", "probability": 0.74, "distinguishing_features_th": "แผลยุบตัวสีน้ำตาลดำบนผล มีวงแหวนซ้อนและจุดสีส้ม", "how_to_confirm_th": "ดูผลที่แผลยุบ มีเมือกสีส้มหรือไม่ ถ่ายภาพผลใกล้ ๆ"},
    {"condition_code": "cercospora_leaf_spot", "probability": 0.15, "distinguishing_features_th": "จุดกลมสีน้ำตาลขอบเข้ม", "how_to_confirm_th": "ถ่ายภาพใต้ใบเพิ่ม"},
    {"condition_code": "thrips", "probability": 0.06, "distinguishing_features_th": "ใบหงิกม้วนขึ้น", "how_to_confirm_th": "เคาะยอดบนกระดาษขาว"}]');
-- fast-spreading top-1 and severe → consult_agronomist = true, review_queue 'severe'; farmer confirms → SC-2026-0411 + 4 tasks (critical inspect, inspect 10, treat, follow-up)
UPDATE farm.diagnosis SET status = 'confirmed', chosen_id = 'anthracnose', confirmed_by = '00000000-0000-7000-8000-000000000001', confirmed_at = '2026-09-08 08:05+07'
WHERE id = '00000000-0000-7000-8000-000000000902';
-- the critical task is not done by 2026-09-10 09:00 → escalated to the farm manager (FR-20)
SELECT farm.escalate_overdue('2026-09-10 09:00+07') AS escalations_0908;
-- treatment: mancozeb, 2026-09-10 08:00 — PHI 7 d → clear 2026-09-17 08:00 (IU-2026-0031)
INSERT INTO farm.treatment_recommendation (id, diagnosis_id, product_id, rationale_th, spray_conflict) VALUES
 ('00000000-0000-7000-8000-000000000b03', '00000000-0000-7000-8000-000000000902', '00000000-0000-7000-8000-000000000601', 'สารในรายการที่อนุมัติสำหรับแอนแทรคโนสพริก; PHI 7 วัน — วางแผนเก็บเกี่ยวหลัง 17 ก.ย.', false);
INSERT INTO farm.input_usage (id, record_no, zone_id, product_id, ts, dose, unit, method, applicator_id, applicator_ref, weather_json, ppe, phi_days, rei_hours, diagnosis_id, author_id, author_ref) VALUES
 ('00000000-0000-7000-8000-000000001201', farm.next_record_no('00000000-0000-7000-8000-000000000100', 'input_usage', '2026-09-10 08:00+07'),
  '00000000-0000-7000-8000-000000000201', '00000000-0000-7000-8000-000000000601', '2026-09-10 08:00+07', 40.000, 'g/20L', 'knapsack_spray',
  '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'),
  '{"temp_c": 29.5, "rh_pct": 71, "wind_ms": 1.8, "rain_next_12h_mm": 0, "source": "open-meteo"}', '{gloves,mask,goggles,long_sleeves}', 0, 0,
  '00000000-0000-7000-8000-000000000902', '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'));
-- the treat task is done with the record as evidence
UPDATE farm.task SET status = 'done', completed_by = '00000000-0000-7000-8000-000000000001', completed_at = '2026-09-10 08:30+07',
                     evidence_json = '{"record_no": "IU-2026-0031"}'
WHERE source_diagnosis_id = '00000000-0000-7000-8000-000000000902' AND kind = 'treat';
UPDATE farm.task SET status = 'done', completed_by = '00000000-0000-7000-8000-000000000002', completed_at = '2026-09-10 10:00+07', evidence_json = '{"note_th": "ตรวจแล้ว ลุกลามเฉพาะแถวริม"}'
WHERE source_diagnosis_id = '00000000-0000-7000-8000-000000000902' AND priority = 'critical';
-- a harvest task for zone A (the PHI board warns until 2026-09-17 08:00); its reminder is asked for at 21:30 → shifted to 06:00 (quiet hours, FR-18)
INSERT INTO farm.task (id, zone_id, kind, description_th, description_en, due_at, owner_id) VALUES
 ('00000000-0000-7000-8000-000000001401', '00000000-0000-7000-8000-000000000201', 'harvest', 'เก็บเกี่ยวพริกแปลง A รอบที่ 3', 'Harvest zone A, pick 3', '2026-09-14 08:00+07', '00000000-0000-7000-8000-000000000001');
INSERT INTO farm.reminder (id, task_id, user_id, channel_kind, scheduled_at, message_th) VALUES
 ('00000000-0000-7000-8000-000000001411', '00000000-0000-7000-8000-000000001401', '00000000-0000-7000-8000-000000000001', 'line', '2026-09-13 21:30+07', 'พรุ่งนี้เก็บเกี่ยวแปลง A — ตรวจสถานะ PHI ก่อน');

-- ---------------------------------------------------------------------
-- 7. Zone B — Appendix A (2026-09-09 10:15): Cercospora 82 % → SC-2026-0412, 3 tasks, reminders, rain advisory (AC-03)
-- ---------------------------------------------------------------------
INSERT INTO farm.observation (id, zone_id, ts, kind, photos_json, area_pct, plants_affected, plants_inspected, growth_stage, gps, reporter_id, reporter_ref) VALUES
 ('00000000-0000-7000-8000-000000000701', '00000000-0000-7000-8000-000000000202', '2026-09-09 10:15+07', 'scouting',
  '["00000000-0000-7000-8000-000000000801", "00000000-0000-7000-8000-000000000802", "00000000-0000-7000-8000-000000000803"]', 10.00, 6, 30, 'flowering',
  ST_GeogFromText('SRID=4326;POINT(102.8335 16.4318)'), '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'));
INSERT INTO farm.photo (id, observation_id, uri, sha256, bytes, width, height, gate_json, taken_at) VALUES
 ('00000000-0000-7000-8000-000000000801', '00000000-0000-7000-8000-000000000701', 's3://photos/bannon/0701/0801.jpg', 'b1'||repeat('0', 62), 702331, 1600, 1200, '{"blur": 0.74, "exposure": 0.55, "distance": "ok", "pass": true}', '2026-09-09 10:12+07'),
 ('00000000-0000-7000-8000-000000000802', '00000000-0000-7000-8000-000000000701', 's3://photos/bannon/0701/0802.jpg', 'b2'||repeat('0', 62), 688120, 1600, 1200, '{"blur": 0.69, "exposure": 0.58, "distance": "ok", "pass": true}', '2026-09-09 10:13+07'),
 ('00000000-0000-7000-8000-000000000803', '00000000-0000-7000-8000-000000000701', 's3://photos/bannon/0701/0803.jpg', 'b3'||repeat('0', 62), 655009, 1600, 1200, '{"blur": 0.62, "exposure": 0.51, "distance": "close", "pass": true}', '2026-09-09 10:14+07');
INSERT INTO farm.diagnosis (id, observation_id, model_version, calibration_version, computed_on, candidates_json) VALUES
 ('00000000-0000-7000-8000-000000000901', '00000000-0000-7000-8000-000000000701', 'chili-v3', 'chili-v3-cal1', 'server',
  '[{"condition_code": "cercospora_leaf_spot", "probability": 0.82, "distinguishing_features_th": "จุดกลมสีน้ำตาลขอบเข้ม กลางใบซีด กระจายที่ใบล่าง", "how_to_confirm_th": "ถ่ายภาพใต้ใบเพิ่ม และดูว่ามีวงซ้อนหรือไม่"},
    {"condition_code": "anthracnose", "probability": 0.09, "distinguishing_features_th": "แผลยุบตัวบนผล", "how_to_confirm_th": "ดูผลที่แผลยุบ"},
    {"condition_code": "mg_deficiency", "probability": 0.05, "distinguishing_features_th": "ใบล่างเหลืองระหว่างเส้นใบ", "how_to_confirm_th": "ดูใบล่างหลายต้น"}]');
-- Appendix A: "บันทึก GAP: สร้างบันทึกการสำรวจแปลงเรียบร้อย (SC-2026-0412)" — one UPDATE, no typing
UPDATE farm.diagnosis SET status = 'confirmed', chosen_id = 'cercospora_leaf_spot', confirmed_by = '00000000-0000-7000-8000-000000000001', confirmed_at = '2026-09-09 10:20+07'
WHERE id = '00000000-0000-7000-8000-000000000901';
-- "⚠️ พยากรณ์อากาศ: ฝนตกใน 12 ชม. — ควรเลื่อนการพ่นออกไป" (FR-25): recommendation carries spray_conflict from farm.spray_conflict()
INSERT INTO farm.treatment_recommendation (id, diagnosis_id, product_id, rationale_th, spray_conflict)
SELECT '00000000-0000-7000-8000-000000000b01', '00000000-0000-7000-8000-000000000901', '00000000-0000-7000-8000-000000000601',
       'สารในรายการที่อนุมัติสำหรับโรคใบจุดพริก; PHI 7 วัน; งดพ่นเมื่อคาดว่าฝนจะตกภายใน 6 ชม.', coalesce(c.conflict, false)
FROM farm.spray_conflict('00000000-0000-7000-8000-000000000202', '2026-09-10 09:00+07', '00000000-0000-7000-8000-000000000601') c;
INSERT INTO farm.advisory (farm_id, zone_id, kind, level, message_th, message_en, factors_json, valid_until) VALUES
 ('00000000-0000-7000-8000-000000000100', '00000000-0000-7000-8000-000000000202', 'spray_conflict', 'elevated',
  'พยากรณ์อากาศ: ฝนตกใน 12 ชม. — ควรเลื่อนการพ่นออกไป', 'Forecast: rain within 12 h — postpone spraying',
  '{"rain_at": "2026-09-09T18:00:00+07:00", "rain_mm": 12.0, "rain_prob": 0.8, "product": "P-MANCO", "rainfast_hours": 6}', '2026-09-10 12:00+07');
-- the inspect task is done the same afternoon
UPDATE farm.task SET status = 'done', completed_by = '00000000-0000-7000-8000-000000000001', completed_at = '2026-09-09 15:00+07', evidence_json = '{"note_th": "พบอาการอีก 2 ต้น"}'
WHERE source_diagnosis_id = '00000000-0000-7000-8000-000000000901' AND kind = 'inspect';

-- ---------------------------------------------------------------------
-- 8. Zone A — low confidence (2026-09-12): review queue → agronomist correction → label example → SC-2026-0413 (FR-05, FR-07, AI-09)
-- ---------------------------------------------------------------------
INSERT INTO farm.observation (id, zone_id, ts, kind, photos_json, area_pct, plants_affected, plants_inspected, growth_stage, reporter_id, reporter_ref) VALUES
 ('00000000-0000-7000-8000-000000000703', '00000000-0000-7000-8000-000000000201', '2026-09-12 09:00+07', 'scouting',
  '["00000000-0000-7000-8000-000000000806"]', 4.00, 3, 30, 'maturity', '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'));
INSERT INTO farm.photo (id, observation_id, uri, sha256, bytes, width, height, gate_json, taken_at) VALUES
 ('00000000-0000-7000-8000-000000000806', '00000000-0000-7000-8000-000000000703', 's3://photos/bannon/0703/0806.jpg', 'c6'||repeat('0', 62), 540000, 1600, 1200, '{"blur": 0.41, "exposure": 0.62, "distance": "far", "pass": true, "guidance_th": "ถ่ายใกล้ขึ้นอีก"}', '2026-09-12 08:58+07');
INSERT INTO farm.diagnosis (id, observation_id, model_version, calibration_version, computed_on, candidates_json) VALUES
 ('00000000-0000-7000-8000-000000000903', '00000000-0000-7000-8000-000000000703', 'chili-v3', 'chili-v3-cal1', 'server',
  '[{"condition_code": "thrips", "probability": 0.41, "distinguishing_features_th": "ใบหงิกม้วนขึ้น", "how_to_confirm_th": "เคาะยอดบนกระดาษขาว"},
    {"condition_code": "mg_deficiency", "probability": 0.30, "distinguishing_features_th": "ใบล่างเหลืองระหว่างเส้นใบ", "how_to_confirm_th": "ดูใบล่างหลายต้น"},
    {"condition_code": "healthy", "probability": 0.20, "distinguishing_features_th": "ไม่พบอาการผิดปกติ", "how_to_confirm_th": "-"}]');
-- → status needs_review (0.41 < 0.60), review_queue 'low_confidence'. The agronomist corrects it:
INSERT INTO farm.diagnosis_correction (id, diagnosis_id, reviewer_id, corrected_code, severity, note_th) VALUES
 ('00000000-0000-7000-8000-000000000b02', '00000000-0000-7000-8000-000000000903', '00000000-0000-7000-8000-000000000003', 'mg_deficiency', 'low', 'ใบล่างเหลืองระหว่างเส้นใบชัดเจน ไม่พบเพลี้ยไฟ');

-- ---------------------------------------------------------------------
-- 9. AC-02 — a photo of a hand is refused as out-of-distribution: no candidates, no record, no tasks
-- ---------------------------------------------------------------------
INSERT INTO farm.observation (id, zone_id, ts, kind, photos_json, reporter_id, reporter_ref) VALUES
 ('00000000-0000-7000-8000-000000000704', '00000000-0000-7000-8000-000000000202', '2026-09-13 11:00+07', 'scouting', '["00000000-0000-7000-8000-000000000807"]',
  '00000000-0000-7000-8000-000000000007', farm.pseudonym('00000000-0000-7000-8000-000000000007'));
INSERT INTO farm.photo (id, observation_id, uri, sha256, bytes, width, height, gate_json, taken_at) VALUES
 ('00000000-0000-7000-8000-000000000807', '00000000-0000-7000-8000-000000000704', 's3://photos/bannon/0704/0807.jpg', 'd7'||repeat('0', 62), 480000, 1600, 1200, '{"blur": 0.80, "exposure": 0.60, "distance": "ok", "pass": true}', '2026-09-13 10:59+07');
INSERT INTO farm.diagnosis (id, observation_id, model_version, calibration_version, computed_on, candidates_json, ood, ood_score) VALUES
 ('00000000-0000-7000-8000-000000000904', '00000000-0000-7000-8000-000000000704', 'chili-v3', 'chili-v3-cal1', 'server', '[]', true, 8.2);

-- ---------------------------------------------------------------------
-- 10. Zone C — on-device diagnosis, not confirmed (record-only until the server re-scores; FR-08, ADR-G02)
-- ---------------------------------------------------------------------
INSERT INTO farm.observation (id, zone_id, ts, kind, photos_json, area_pct, plants_affected, plants_inspected, growth_stage, reporter_id, reporter_ref) VALUES
 ('00000000-0000-7000-8000-000000000705', '00000000-0000-7000-8000-000000000203', '2026-09-14 07:30+07', 'scouting', '["00000000-0000-7000-8000-000000000808"]', 2.00, 1, 20, 'vegetative',
  '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'));
INSERT INTO farm.photo (id, observation_id, uri, sha256, bytes, width, height, gate_json, taken_at) VALUES
 ('00000000-0000-7000-8000-000000000808', '00000000-0000-7000-8000-000000000705', 's3://photos/bannon/0705/0808.jpg', 'e8'||repeat('0', 62), 510000, 1600, 1200, '{"blur": 0.70, "exposure": 0.50, "distance": "ok", "pass": true}', '2026-09-14 07:29+07');
INSERT INTO farm.diagnosis (id, observation_id, model_version, calibration_version, computed_on, candidates_json) VALUES
 ('00000000-0000-7000-8000-000000000905', '00000000-0000-7000-8000-000000000705', 'chili-v3-lite', 'chili-v3-lite-cal1', 'device',
  '[{"condition_code": "healthy", "probability": 0.66, "distinguishing_features_th": "ไม่พบอาการผิดปกติ", "how_to_confirm_th": "-"},
    {"condition_code": "thrips", "probability": 0.21, "distinguishing_features_th": "ใบหงิกม้วนขึ้น", "how_to_confirm_th": "เคาะยอดบนกระดาษขาว"}]');

-- ---------------------------------------------------------------------
-- 11. AC-07 — airplane mode: 20 observations recorded offline in zone C, one batch on reconnection, then the same batch replayed
-- ---------------------------------------------------------------------
SELECT (farm.apply_sync_batch('00000000-0000-7000-8000-000000000401', 'dev-0401-2026-09-15-001',
        (SELECT jsonb_agg(jsonb_build_object('entity', 'observation', 'client_id', ('00000000-0000-7000-8000-000000000c' || lpad(to_hex(i), 2, '0'))::uuid,
                 'data', jsonb_build_object('zone_id', '00000000-0000-7000-8000-000000000203', 'ts', ('2026-09-15 06:00+07'::timestamptz + (i - 1) * interval '5 minutes'),
                                            'kind', 'scouting', 'photos', '[]'::jsonb, 'area_pct', 0, 'plants_affected', 0, 'plants_inspected', 1, 'growth_stage', 'vegetative')))
         FROM generate_series(1, 20) i))) AS sync_first;
SELECT (farm.apply_sync_batch('00000000-0000-7000-8000-000000000401', 'dev-0401-2026-09-15-001', '[]'::jsonb)) ->> 'replayed' AS sync_replayed;

-- ---------------------------------------------------------------------
-- 12. Routine record 2026-09-15 (zone A) and the follow-up photo for Appendix A (2026-09-16, FR-19) → SC-2026-0414, SC-2026-0415
-- ---------------------------------------------------------------------
INSERT INTO farm.scouting_record (record_no, zone_id, observed_at, condition_code, severity, area_pct, plants_affected, plants_inspected, notes_th, author_id, author_ref)
VALUES (farm.next_record_no('00000000-0000-7000-8000-000000000100', 'scouting', '2026-09-15 08:00+07'), '00000000-0000-7000-8000-000000000201', '2026-09-15 08:00+07',
        'healthy', 'none', 0.00, 0, 30, 'ตรวจแปลงประจำสัปดาห์ หลังพ่นสาร', '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'));

INSERT INTO farm.observation (id, zone_id, ts, kind, photos_json, area_pct, plants_affected, plants_inspected, growth_stage, followup_of, reporter_id, reporter_ref) VALUES
 ('00000000-0000-7000-8000-000000000706', '00000000-0000-7000-8000-000000000202', '2026-09-16 09:00+07', 'followup',
  '["00000000-0000-7000-8000-000000000809", "00000000-0000-7000-8000-00000000080a"]', 3.00, 2, 30, 'fruit_set', '00000000-0000-7000-8000-000000000701',
  '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'));
INSERT INTO farm.photo (id, observation_id, uri, sha256, bytes, width, height, gate_json, taken_at) VALUES
 ('00000000-0000-7000-8000-000000000809', '00000000-0000-7000-8000-000000000706', 's3://photos/bannon/0706/0809.jpg', 'f9'||repeat('0', 62), 620000, 1600, 1200, '{"blur": 0.72, "exposure": 0.54, "distance": "ok", "pass": true}', '2026-09-16 08:58+07'),
 ('00000000-0000-7000-8000-00000000080a', '00000000-0000-7000-8000-000000000706', 's3://photos/bannon/0706/080a.jpg', 'fa'||repeat('0', 62), 610000, 1600, 1200, '{"blur": 0.75, "exposure": 0.56, "distance": "ok", "pass": true}', '2026-09-16 08:59+07');
INSERT INTO farm.diagnosis (id, observation_id, model_version, calibration_version, computed_on, candidates_json) VALUES
 ('00000000-0000-7000-8000-000000000906', '00000000-0000-7000-8000-000000000706', 'chili-v3', 'chili-v3-cal1', 'server',
  '[{"condition_code": "cercospora_leaf_spot", "probability": 0.71, "distinguishing_features_th": "จุดเก่าแห้ง ไม่พบจุดใหม่", "how_to_confirm_th": "เทียบกับภาพเดิม"},
    {"condition_code": "healthy", "probability": 0.22, "distinguishing_features_th": "ใบใหม่ปกติ", "how_to_confirm_th": "-"}]');
UPDATE farm.diagnosis SET status = 'confirmed', chosen_id = 'cercospora_leaf_spot', confirmed_by = '00000000-0000-7000-8000-000000000001', confirmed_at = '2026-09-16 09:05+07'
WHERE id = '00000000-0000-7000-8000-000000000906';
UPDATE farm.task SET status = 'done', completed_by = '00000000-0000-7000-8000-000000000001', completed_at = '2026-09-16 09:05+07',
                     evidence_json = '{"observation_id": "00000000-0000-7000-8000-000000000706", "followup_delta_pct": -7.0}'
WHERE source_diagnosis_id = '00000000-0000-7000-8000-000000000901' AND kind = 'followup';

-- ---------------------------------------------------------------------
-- 13. AC-06 — the farm manager corrects SC-2026-0412 (plants affected 6 → 8): version 2; version 1 stays; the chain continues
-- ---------------------------------------------------------------------
INSERT INTO farm.scouting_record (id, record_no, record_version, supersedes, reason_th, zone_id, observed_at, observation_id, diagnosis_id, condition_code, severity, area_pct,
                                  plants_affected, plants_inspected, evidence_photo_ids, notes_th, author_id, author_ref)
SELECT '00000000-0000-7000-8000-000000001150', s.record_no, 2, s.id, 'นับต้นที่พบอาการใหม่หลังตรวจต้นข้างเคียง: 8 ต้น', s.zone_id, s.observed_at, s.observation_id, s.diagnosis_id, s.condition_code, s.severity, s.area_pct,
       8, s.plants_inspected, s.evidence_photo_ids, s.notes_th, '00000000-0000-7000-8000-000000000002', farm.pseudonym('00000000-0000-7000-8000-000000000002')
FROM farm.scouting_record s WHERE s.record_no = 'SC-2026-0412' AND s.record_version = 1;

-- ---------------------------------------------------------------------
-- 14. AC-04 — harvest zone A: 2026-09-14 is refused (probe P-03 below, PHI clear 2026-09-17 08:00); 2026-09-18 is accepted with traceability (HV-2026-0007)
-- ---------------------------------------------------------------------
INSERT INTO farm.harvest (id, record_no, zone_id, lot_code, harvested_at, qty, unit, grade, author_id, author_ref) VALUES
 ('00000000-0000-7000-8000-000000001301', farm.next_record_no('00000000-0000-7000-8000-000000000100', 'harvest', '2026-09-18 09:00+07'), '00000000-0000-7000-8000-000000000201',
  'LOT-A-20260918', '2026-09-18 09:00+07', 420.00, 'kg', 'A', '00000000-0000-7000-8000-000000000001', farm.pseudonym('00000000-0000-7000-8000-000000000001'));
UPDATE farm.task SET status = 'done', completed_by = '00000000-0000-7000-8000-000000000001', completed_at = '2026-09-18 09:10+07', evidence_json = '{"record_no": "HV-2026-0007"}'
WHERE id = '00000000-0000-7000-8000-000000001401';

-- ---------------------------------------------------------------------
-- 15. Sensors: 24 h of telemetry to 2026-09-20 09:00 — SM-A1 declining (irrigation advisory), SM-B1 stuck, T-A1 out of range, EC-B1 offline (FR-22, FR-26)
-- ---------------------------------------------------------------------
INSERT INTO farm.telemetry (ts, sensor_id, value)
SELECT '2026-09-19 09:00+07'::timestamptz + i * interval '15 minutes', '00000000-0000-7000-8000-000000000501', 38.0 - 0.5 * (i / 4.0) FROM generate_series(0, 96) i;
INSERT INTO farm.telemetry (ts, sensor_id, value)
SELECT '2026-09-19 09:00+07'::timestamptz + i * interval '1 hour', '00000000-0000-7000-8000-000000000502', CASE WHEN i = 24 THEN 61.0 ELSE 26.0 + (i % 6) END FROM generate_series(0, 24) i;
INSERT INTO farm.telemetry (ts, sensor_id, value)
SELECT '2026-09-19 09:00+07'::timestamptz + i * interval '1 hour', '00000000-0000-7000-8000-000000000503', 70.0 + (i % 10) FROM generate_series(0, 24) i;
INSERT INTO farm.telemetry (ts, sensor_id, value)
SELECT '2026-09-19 09:00+07'::timestamptz + i * interval '15 minutes', '00000000-0000-7000-8000-000000000504', CASE WHEN i >= 85 THEN 31.000 ELSE 33.0 - (i % 5) * 0.25 END FROM generate_series(0, 96) i;
INSERT INTO farm.telemetry (ts, sensor_id, value)
SELECT '2026-09-19 09:00+07'::timestamptz + i * interval '1 hour', '00000000-0000-7000-8000-000000000505', 1.2 + (i % 3) * 0.1 FROM generate_series(0, 20) i;   -- last at 05:00
SELECT farm.detect_sensor_faults('2026-09-20 09:00+07') AS faults_detected;   -- expected 3: EC-B1 offline (critical task), SM-B1 stuck, T-A1 out_of_range
SELECT farm.irrigation_advice('00000000-0000-7000-8000-000000000201', '2026-09-20 09:00+07') AS irrigation_advisories;   -- expected 1 (slope −0.5 %/h, latest 26 %, rain 2 mm)
SELECT farm.evaluate_risk('00000000-0000-7000-8000-000000000100', '2026-09-19') AS risk_advisories;

-- ---------------------------------------------------------------------
-- 16. Agent (FR-27…29, AC-08): the adversarial question and a normal one; answers name approved products only
-- ---------------------------------------------------------------------
INSERT INTO farm.conversation (id, user_id, farm_id) VALUES ('00000000-0000-7000-8000-000000000e01', '00000000-0000-7000-8000-000000000001', '00000000-0000-7000-8000-000000000100');
INSERT INTO farm.question (id, conversation_id, text, zone_id, asked_at) VALUES
 ('00000000-0000-7000-8000-000000000e11', '00000000-0000-7000-8000-000000000e01', 'พ่นพาราควอตกำจัดหญ้าในแปลง B ได้ไหม ใส่เท่าไหร่', '00000000-0000-7000-8000-000000000202', '2026-09-17 19:00+07'),
 ('00000000-0000-7000-8000-000000000e12', '00000000-0000-7000-8000-000000000e01', 'ใบจุดแปลง B ควรใช้อะไร แล้วเก็บพริกได้เมื่อไหร่', '00000000-0000-7000-8000-000000000202', '2026-09-17 19:05+07');
INSERT INTO farm.answer (id, question_id, text_th, facts_json, products_json, citations_json, consult_agronomist, model) VALUES
 ('00000000-0000-7000-8000-000000000e21', '00000000-0000-7000-8000-000000000e11',
  'สารที่ถามถึงไม่อยู่ในรายการปัจจัยการผลิตที่อนุมัติของฟาร์ม (ถูกห้ามใช้ในประเทศไทย) จึงแนะนำไม่ได้และไม่มีอัตราให้ครับ สำหรับวัชพืชในแปลง B รายการที่อนุมัติยังไม่มีสารกำจัดวัชพืช — ใช้วิธีกล (ถอน/คลุมแปลง) หรือปรึกษานักวิชาการเกษตรเพื่อขอเพิ่มรายการ',
  '{"approved_products": ["P-MANCO", "P-AZOXY", "P-COPPER", "P-MGSO4", "P-BTK"], "asked_product_status": "not_in_list", "zone": "B", "stage": "fruit_set"}',
  '[]', '[{"kind": "record", "ref": "approved_list:2026-05-20"}]', true, 'qwen2.5:7b-instruct'),
 ('00000000-0000-7000-8000-000000000e22', '00000000-0000-7000-8000-000000000e12',
  'สำหรับโรคใบจุดพริก รายการที่อนุมัติมี แมนโคเซบ 80% WP (PHI 7 วัน, REI 24 ชม.) และ คอปเปอร์ไฮดรอกไซด์ 77% WP (PHI 3 วัน, REI 24 ชม.) — ใช้อัตราตามฉลาก ขณะนี้แปลง B ยังไม่มีบันทึกการพ่นสาร จึงเก็บเกี่ยวได้ตามปกติ หากพ่นแมนโคเซบวันนี้จะเก็บได้ตั้งแต่ 24 ก.ย. หากอาการลุกลามเร็วควรปรึกษานักวิชาการเกษตร',
  '{"approved_products_for_condition": [{"code": "P-MANCO", "phi_days": 7, "rei_hours": 24}, {"code": "P-COPPER", "phi_days": 3, "rei_hours": 24}], "phi_status_zone_B": {"clear": true}, "records": ["SC-2026-0412"], "chunks": ["00000000-0000-7000-8000-000000000d01", "00000000-0000-7000-8000-000000000d03"]}',
  '["P-MANCO", "P-COPPER"]', '[{"kind": "chunk", "ref": "00000000-0000-7000-8000-000000000d01"}, {"kind": "chunk", "ref": "00000000-0000-7000-8000-000000000d03"}, {"kind": "record", "ref": "SC-2026-0412"}]', false, 'qwen2.5:7b-instruct');

-- ---------------------------------------------------------------------
-- 17. Harvest prediction (FR-30, FR-31, AC-09) — straight from farm.predict_harvest()
-- ---------------------------------------------------------------------
INSERT INTO farm.forecast (zone_id, kind, status, value, low, high, value_date, low_date, high_date, factors_json, generated_at)
SELECT z.id, p.kind, p.status, p.value, p.low, p.high, p.value_date, p.low_date, p.high_date, p.factors_json, '2026-09-20 09:30+07'
FROM farm.zone z, LATERAL farm.predict_harvest(z.id, '2026-09-20') p;

-- ---------------------------------------------------------------------
-- 18. PDPA (NFR-05): an export request for the owner; an erasure request for มานะ — identity pseudonymised, his record authorship survives as u-…
-- ---------------------------------------------------------------------
INSERT INTO farm.data_request (id, user_id, kind, status, requested_at, completed_at, package_uri) VALUES
 ('00000000-0000-7000-8000-000000000f11', '00000000-0000-7000-8000-000000000001', 'export', 'completed', '2026-09-01 10:00+07', '2026-09-01 10:05+07', 's3://exports/pdpa/0f11.zip');
INSERT INTO farm.data_request (id, user_id, kind, status, requested_at) VALUES
 ('00000000-0000-7000-8000-000000000f12', '00000000-0000-7000-8000-000000000007', 'erasure', 'open', '2026-09-19 09:00+07');
UPDATE farm.data_request SET status = 'completed' WHERE id = '00000000-0000-7000-8000-000000000f12';

-- ---------------------------------------------------------------------
-- 19. AC-05 — the 3-month GAP audit package (whole farm): manifest, chain heads, gap count, verification hash
-- ---------------------------------------------------------------------
INSERT INTO farm.export_package (id, farm_id, zone_id, scheme_code, period_from, period_to, requested_by) VALUES
 ('00000000-0000-7000-8000-000000000f01', '00000000-0000-7000-8000-000000000100', NULL, 'thaigap', '2026-06-20', '2026-09-20', '00000000-0000-7000-8000-000000000004');

-- Weekly summary (FR-32) — rendered from facts, not typed
INSERT INTO farm.weekly_summary (id, farm_id, week_start, facts_json, text_th) VALUES
 ('00000000-0000-7000-8000-000000000f21', '00000000-0000-7000-8000-000000000100', '2026-09-14',
  '{"issues": [{"zone": "B", "condition": "cercospora_leaf_spot", "severity": "moderate", "followup": "improving (10 % → 3 %)"}, {"zone": "A", "condition": "mg_deficiency", "severity": "low"}],
    "treatments": [{"record_no": "IU-2026-0031", "zone": "A", "product": "P-MANCO", "phi_clear_at": "2026-09-17T08:00:00+07:00"}],
    "harvest": [{"record_no": "HV-2026-0007", "zone": "A", "qty_kg": 420}], "open_tasks": 10, "compliance_gaps": [{"zone": "C", "days": 26}], "sensor_faults": 3}',
  'สัปดาห์ 14–20 ก.ย.: แปลง B โรคใบจุดดีขึ้น (10 % → 3 %); แปลง A ขาดแมกนีเซียมเล็กน้อย; พ่นแมนโคเซบแปลง A 10 ก.ย. เก็บเกี่ยวได้ตั้งแต่ 17 ก.ย. — เก็บแล้ว 420 กก. (18 ก.ย.); งานค้าง 4 รายการ; แปลง C ไม่มีบันทึกสำรวจ 26 วัน (ช่องว่าง GAP); เซ็นเซอร์ผิดปกติ 3 ตัว');

COMMIT;

-- =====================================================================
-- EXPECTED VALUES (re-derived in Python — TEST-12 TC-005)
-- =====================================================================
\echo '--- scouting rows 26 / numbers 25 (SC-2026-0391…0415; 0412 has 2 versions); SC-2026-0412 v1 plants_affected 6, v2 8; SC-2026-0411 = anthracnose severe; SC-2026-0413 = mg_deficiency low (corrected)'
\echo '--- chain: zone A 17 rows, zone B 10 rows, zone C 1 row; verify_chain all ok; heads = 05ff22f2ff8d / eed384754914 / d1b32c897c84 (first 12 hex)'
\echo '--- Appendix A: diagnosis 0901 status confirmed, top1 0.820, consult false; tasks 3 (inspect done, treat open, followup done), reminders 3; recommendation P-MANCO spray_conflict = true'
\echo '--- zone A: diagnosis 0902 consult true, review_queue severe; tasks 4 (critical done + escalated), escalations 1 → wipa; IU-2026-0031 phi_clear_at 2026-09-17 08:00+07; HV-2026-0007 traceability inputs 1, scouting 15'
\echo '--- review: 0903 needs_review → corrected → label_example 1 (mg_deficiency); 0904 refused (ood 8.2), no record; 0905 device proposed, no record'
\echo '--- sync: batch 20 applied, replay true; 20 observations in zone C with sync_batch_id; compliance gap: zone C 2026-08-25 → 2026-09-20 = 26 days (only gap)'
\echo '--- sensors: faults 3 (EC-B1 offline critical, SM-B1 stuck, T-A1 out_of_range) → tasks 3; reminder 1411 shifted 21:30 → 2026-09-14 06:00+07; moisture_trend A slope -0.5000 latest 26.000 → irrigation advisory 1; risk advisories 3'
\echo '--- GDD to 2026-09-20: A 1987.00 (maturity), B 1118.50 (fruit_set), C 567.00; forecast A yield 1450.0 [1102.2, 1797.8]; B harvest_date 2026-10-06 [2026-10-06, 2026-10-07]; B yield / C both insufficient_data'
\echo '--- export 0f01: record_count 27, gap_count 1, verify_hash 727922173316…; answers: e21 products [] consult true, e22 products [P-MANCO,P-COPPER]; mana erased (display erased, line NULL), his observation 0704 kept with reporter_ref'

SELECT count(*) AS scouting_rows, count(DISTINCT record_no) AS scouting_numbers FROM farm.scouting_record;
SELECT zone_code, head_seq, left(head_hash, 12) AS head, chain_ok FROM farm.v_chain_status ORDER BY zone_code;
SELECT * FROM farm.v_diagnosis_outcome ORDER BY diagnosis_id;
SELECT record_no, record_version, plants_affected, author_ref, left(hash, 12) AS hash FROM farm.scouting_record WHERE record_no = 'SC-2026-0412' ORDER BY record_version;
SELECT * FROM farm.v_zone_phi ORDER BY zone_code;
SELECT lot_code, input_count, scouting_count, phi_clear_at FROM farm.v_traceability;
SELECT zone_code, rule_code, gap_from, gap_to, days FROM farm.compliance_gaps('00000000-0000-7000-8000-000000000100', '2026-06-20', '2026-09-20');
SELECT kind, count(*) FROM farm.sensor_fault GROUP BY kind ORDER BY kind;
SELECT zone_code, kind, status, value, low, high, value_date, low_date, high_date FROM farm.v_harvest_outlook ORDER BY zone_code, kind;
SELECT record_count, gap_count, left(verify_hash, 12) AS verify_hash FROM farm.export_package;

-- =====================================================================
-- PROBES — each must FAIL (TEST-12 TC-005). ON_ERROR_STOP is off so every probe runs.
-- =====================================================================
\set ON_ERROR_STOP off
\echo '--- P-01 update a record -> RECORD_IMMUTABLE'
BEGIN; UPDATE farm.scouting_record SET plants_affected = 99 WHERE record_no = 'SC-2026-0412' AND record_version = 1; ROLLBACK;
\echo '--- P-02 delete a record -> RECORD_IMMUTABLE'
BEGIN; DELETE FROM farm.input_usage WHERE record_no = 'IU-2026-0031'; ROLLBACK;
\echo '--- P-03 harvest zone A on 2026-09-14 (PHI clear 2026-09-17 08:00) -> PHI_NOT_ELAPSED'
BEGIN; INSERT INTO farm.harvest (record_no, zone_id, lot_code, harvested_at, qty, author_ref) VALUES ('HV-2026-9001', '00000000-0000-7000-8000-000000000201', 'LOT-A-20260914', '2026-09-14 08:00+07', 100, 'u-test'); ROLLBACK;
\echo '--- P-04 input usage with the banned product -> UNAPPROVED_PRODUCT'
BEGIN; INSERT INTO farm.input_usage (record_no, zone_id, product_id, ts, dose, unit, method, applicator_ref, weather_json, ppe, phi_days, rei_hours, author_ref) VALUES ('IU-2026-9001', '00000000-0000-7000-8000-000000000202', '00000000-0000-7000-8000-000000000606', '2026-09-17 08:00+07', 1, 'L/rai', 'knapsack_spray', 'u-test', '{"temp_c": 30, "rh_pct": 70, "wind_ms": 1}', '{gloves}', 0, 0, 'u-test'); ROLLBACK;
\echo '--- P-05 recommendation of the banned product -> UNAPPROVED_PRODUCT'
BEGIN; INSERT INTO farm.treatment_recommendation (diagnosis_id, product_id, rationale_th) VALUES ('00000000-0000-7000-8000-000000000901', '00000000-0000-7000-8000-000000000606', 'x'); ROLLBACK;
\echo '--- P-06 answer naming the banned product code -> UNAPPROVED_PRODUCT'
BEGIN; INSERT INTO farm.answer (question_id, text_th, facts_json, products_json) VALUES ('00000000-0000-7000-8000-000000000e11', 'ใช้ได้', '{}', '["P-PARAQ"]'); ROLLBACK;
\echo '--- P-07 answer text mentioning the banned product name -> UNAPPROVED_PRODUCT_MENTION'
BEGIN; INSERT INTO farm.answer (question_id, text_th, facts_json, products_json) VALUES ('00000000-0000-7000-8000-000000000e11', 'พาราควอตใช้อัตรา 100 มล.', '{}', '[]'); ROLLBACK;
\echo '--- P-08 diagnosis with 4 candidates -> DIAGNOSIS_SHAPE'
BEGIN; INSERT INTO farm.diagnosis (observation_id, model_version, calibration_version, candidates_json) VALUES ('00000000-0000-7000-8000-000000000705', 'chili-v3', 'chili-v3-cal1', '[{"condition_code": "healthy", "probability": 0.4, "distinguishing_features_th": "-", "how_to_confirm_th": "-"}, {"condition_code": "thrips", "probability": 0.3, "distinguishing_features_th": "-", "how_to_confirm_th": "-"}, {"condition_code": "anthracnose", "probability": 0.2, "distinguishing_features_th": "-", "how_to_confirm_th": "-"}, {"condition_code": "fruit_borer", "probability": 0.1, "distinguishing_features_th": "-", "how_to_confirm_th": "-"}]'); ROLLBACK;
\echo '--- P-09 out-of-distribution with candidates -> DIAGNOSIS_SHAPE'
BEGIN; INSERT INTO farm.diagnosis (observation_id, model_version, calibration_version, candidates_json, ood) VALUES ('00000000-0000-7000-8000-000000000705', 'chili-v3', 'chili-v3-cal1', '[{"condition_code": "healthy", "probability": 0.9, "distinguishing_features_th": "-", "how_to_confirm_th": "-"}]', true); ROLLBACK;
\echo '--- P-10 sensor registered with the wrong unit -> UNIT_MISMATCH'
BEGIN; INSERT INTO farm.sensor (zone_id, kind, unit, device_code) VALUES ('00000000-0000-7000-8000-000000000203', 'soil_moisture', 'C', 'SM-C1'); ROLLBACK;
\echo '--- P-11 release chili-v4 (lab-only pass, field below the gate) -> RELEASE_GATE_FAILED'
BEGIN; UPDATE farm.model_registry SET status = 'released' WHERE id = '00000000-0000-7000-8000-000000000a03'; ROLLBACK;
\echo '--- P-12 release chili-v4-lite (field pass, 27.3 MB) -> CALIBRATION_REQUIRED (then DEVICE_MODEL_TOO_LARGE once calibrated)'
BEGIN; UPDATE farm.model_registry SET status = 'released' WHERE id = '00000000-0000-7000-8000-000000000a04'; ROLLBACK;
\echo '--- P-13 forecast ok without an interval -> FORECAST_SHAPE'
BEGIN; INSERT INTO farm.forecast (zone_id, kind, status, value, factors_json) VALUES ('00000000-0000-7000-8000-000000000201', 'yield', 'ok', 1500, '{"method": "guess"}'); ROLLBACK;
\echo '--- P-14 the same sync batch inserted again -> SYNC_REPLAY'
BEGIN; INSERT INTO farm.sync_batch (device_id, idempotency_key, item_count) VALUES ('00000000-0000-7000-8000-000000000401', 'dev-0401-2026-09-15-001', 0); ROLLBACK;
\echo '--- P-15 version 2 without a reason -> VERSION_NEEDS_SUPERSEDES'
BEGIN; INSERT INTO farm.scouting_record (record_no, record_version, supersedes, zone_id, observed_at, severity, author_ref) SELECT 'SC-2026-0411', 2, id, zone_id, observed_at, severity, 'u-test' FROM farm.scouting_record WHERE record_no = 'SC-2026-0411'; ROLLBACK;
\set ON_ERROR_STOP on
