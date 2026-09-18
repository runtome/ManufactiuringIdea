-- =====================================================================
--  MoldMind — demo / test seed  (DDS-11 §9; TEST-11 TC-005, TC-009)
--  Deterministic: no random(); every id and value is literal or derived by the schema's own functions and triggers.
--  Reproduces SRS-11 Appendix A (the sink-mark knowledge-base entry) and AC-02 … AC-09:
--    AC-03  2026-09-09 10:40 holding pressure 650 → 560 bar (technician somsak, from the controller)
--           before: 100 cycles × 4 cavities, sink marks 6/400 = 1.5 %  ·  after: 36/400 = 9.0 %  (z 4.5971, p 4.3e-6)
--           cavity 3 carries 20/100 vs 16/300 on the others (z 4.2366, p 2.3e-5) → flagged
--           RCA ranks insufficient_holding_pressure first (score 0.88); advice: 2 checks before 1 action (+10 % → 616 bar, window 500–750)
--    AC-05  a suggestion of 800 bar is stored blocked with an audit row; asserting it allowed is refused (probe 4)
--    AC-07  after 616 bar: 7/400 = 1.75 % vs 9.0 % → z 4.3896, p 1.1e-5 → effective; kb_case_evidence written back (FR-25)
--    AC-06  startup after a 2 h stop on 2026-09-08: first 20 shots are transients; no cavity flag from them
--    AC-09  OPC-UA lost 2026-09-08 15:00–16:00: 128 shots buffered at the gateway, reconciled, 0 duplicates
--    FR-09  ΔE76 (62.1, −4.3, 12.8) vs (60.9, −3.9, 14.1) = 1.814 (ok, threshold 2.0); (59.8, −3.1, 15.0) = 3.401 → colour_deviation
--    FR-11  a weld-line detection at 0.58 routed to review; human verdict FAIL stored
--    FR-26  8D handed off to QE-Agent: quality.case + artifact(eight_d) draft
--  NOT EXECUTED on the authoring machine (no PostgreSQL). Expected outputs of the \echo block: DDS-11 §9.
-- =====================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Master data, users, machine connection and node map (IF-05)
-- ---------------------------------------------------------------------
INSERT INTO core.plant (id, code, name, timezone) VALUES ('01000000-0000-7000-8000-000000000001', 'BKK-1', 'Bangkok Plant 1', 'Asia/Bangkok');
INSERT INTO core.line (id, plant_id, code, name) VALUES ('11111111-0000-7000-8000-000000000002', '01000000-0000-7000-8000-000000000001', 'L2', 'Line 2 — panel moulding');
INSERT INTO core.sku (id, code, name, customer, spec_json) VALUES
    ('22222222-0000-7000-8000-000000000002', 'PNL-220', 'Panel 220', 'Sakura Kogyo', '{"material_grade": "PP-H-2000", "wall_mm": 2.2}');
INSERT INTO core.machine (id, line_id, code, name, machine_type, criticality) VALUES
    ('33333333-0000-7000-8000-000000000003', '11111111-0000-7000-8000-000000000002', 'M-3', 'Machine 3 — 220 t press', 'injection', 'HIGH');
INSERT INTO core.defect_type (id, code, name_th, name_ja, name_en, category) VALUES
    ('44444444-0000-7000-8000-000000000011', 'SINK_MARK',  'รอยยุบ',       'ヒケ',           'sink mark',  'moulding'),
    ('44444444-0000-7000-8000-000000000012', 'SHORT_SHOT', 'ฉีดไม่เต็ม',    'ショートショット', 'short shot', 'moulding'),
    ('44444444-0000-7000-8000-000000000013', 'FLASH',      'ครีบ',          'バリ',           'flash',      'moulding'),
    ('44444444-0000-7000-8000-000000000014', 'WELD_LINE',  'รอยประสาน',     'ウェルドライン',  'weld line',  'moulding'),
    ('44444444-0000-7000-8000-000000000015', 'COLOUR_DEV', 'สีเพี้ยน',      '色差',           'colour deviation', 'appearance');
INSERT INTO core.material_lot (id, lot_code, material_code, supplier, received_at, attributes) VALUES
    ('55555555-0000-7000-8000-000000000201', 'LOT-2609-201', 'PP-H-2000', 'Thai Polymer', '2026-09-05 08:00+07', '{"moisture_pct": 0.04, "regrind_pct": 10}');

INSERT INTO core.app_user (id, username, display_name, role, lang) VALUES
    ('aaaaaaaa-0000-7000-8000-000000000001', 'admin',   'Platform Admin',            'admin',     'en'),
    ('aaaaaaaa-0000-7000-8000-000000000002', 'yuki',    'Yuki Tanaka (production mgr)', 'manager', 'ja'),
    ('aaaaaaaa-0000-7000-8000-000000000003', 'somsak',  'Somsak W. (molding technician)', 'inspector', 'th'),
    ('aaaaaaaa-0000-7000-8000-000000000004', 'prasit',  'Prasit K. (QC inspector)',  'inspector', 'th'),
    ('aaaaaaaa-0000-7000-8000-000000000005', 'nattaya', 'Nattaya S. (process engineer)', 'engineer', 'en'),
    ('aaaaaaaa-0000-7000-8000-000000000006', 'kenji',   'Kenji Sato (quality engineer)', 'engineer', 'ja'),
    ('aaaaaaaa-0000-7000-8000-000000000007', 'wichai',  'Wichai T. (mould maintenance)', 'inspector', 'th');

INSERT INTO quality.mould (id, code, cavities, material_spec, setup_sheet_json, last_maintenance) VALUES
    ('a0a0a0a0-0000-7000-8000-000000000417', 'MLD-0417', 4, 'PP-H-2000', '{"ref": "setup_sheet_version v2"}', '2026-08-20 10:00+07');

INSERT INTO moldmind.machine_connection (id, machine_id, protocol, endpoint, security_policy, credential_ref, credential_kind, buffer_hours) VALUES
    ('c0000000-0000-7000-8000-000000000003', '33333333-0000-7000-8000-000000000003', 'opcua_euromap77', 'opc.tcp://10.20.3.3:4840', 'Basic256Sha256/SignAndEncrypt', 'opcua_readonly_m3', 'read_only', 24);

INSERT INTO moldmind.node_map_version (id, connection_id, version, checksum, nodes_json, validated_at, active) VALUES
    ('c1000000-0000-7000-8000-000000000001', 'c0000000-0000-7000-8000-000000000003', 'v1', 'sha256:m3-nodemap-v1',
     '[{"node_id": "ns=2;s=Injection.HoldingPressure", "signal": "holding_pressure", "unit": "bar", "access": "read"},
       {"node_id": "ns=2;s=Injection.HoldingTime", "signal": "holding_time", "unit": "s", "access": "read"},
       {"node_id": "ns=2;s=Injection.Pressure", "signal": "injection_pressure", "unit": "bar", "access": "read"},
       {"node_id": "ns=2;s=Injection.Speed", "signal": "injection_speed", "unit": "mm/s", "access": "read"},
       {"node_id": "ns=2;s=Plasticising.BackPressure", "signal": "back_pressure", "unit": "bar", "access": "read"},
       {"node_id": "ns=2;s=Plasticising.ScrewSpeed", "signal": "screw_rpm", "unit": "rpm", "access": "read"},
       {"node_id": "ns=2;s=Injection.Cushion", "signal": "cushion_mm", "unit": "mm", "access": "read"},
       {"node_id": "ns=2;s=Temperature.Zone1", "signal": "melt_z1", "unit": "C", "access": "read"},
       {"node_id": "ns=2;s=Temperature.Zone2", "signal": "melt_z2", "unit": "C", "access": "read"},
       {"node_id": "ns=2;s=Temperature.Zone3", "signal": "melt_z3", "unit": "C", "access": "read"},
       {"node_id": "ns=2;s=Temperature.Zone4", "signal": "melt_z4", "unit": "C", "access": "read"},
       {"node_id": "ns=2;s=Mould.TempFixed", "signal": "mould_temp_fixed", "unit": "C", "access": "read"},
       {"node_id": "ns=2;s=Mould.TempMoving", "signal": "mould_temp_moving", "unit": "C", "access": "read"},
       {"node_id": "ns=2;s=Cycle.CoolingTime", "signal": "cooling_time", "unit": "s", "access": "read"},
       {"node_id": "ns=2;s=Cycle.Time", "signal": "cycle_time_s", "unit": "s", "access": "read"},
       {"node_id": "ns=2;s=Clamp.Force", "signal": "clamping_force", "unit": "kN", "access": "read"},
       {"node_id": "ns=2;s=Cycle.ShotCounter", "signal": "controller_shot_no", "unit": "count", "access": "read"}]',
     '2026-09-01 08:00+07', true);

-- ---------------------------------------------------------------------
-- 2. Setup sheets (golden run), parameter windows, colour reference, scrap cost, scoring, prompts, glossary
-- ---------------------------------------------------------------------
INSERT INTO moldmind.setup_sheet_version (id, mould_id, version, params_json, material_grade, author_id, approved_by, approved_at, active) VALUES
    ('55e70000-0000-7000-8000-000000000001', 'a0a0a0a0-0000-7000-8000-000000000417', 1,
     '{"holding_pressure": {"target": 640, "tol": 20}, "holding_time": {"target": 8, "tol": 1}, "cushion_mm": {"target": 4.5, "tol": 1.5}, "melt_temperature": {"target": 235, "tol": 5}, "mould_temperature": {"target": 60, "tol": 5}, "cooling_time": {"target": 12, "tol": 1}, "cycle_time_s": {"target": 28, "tol": 2}}',
     'PP-H-2000', 'aaaaaaaa-0000-7000-8000-000000000005', 'aaaaaaaa-0000-7000-8000-000000000006', '2026-06-01 09:00+07', false),
    ('55e70000-0000-7000-8000-000000000002', 'a0a0a0a0-0000-7000-8000-000000000417', 2,
     '{"holding_pressure": {"target": 650, "tol": 20}, "holding_time": {"target": 8, "tol": 1}, "cushion_mm": {"target": 4.5, "tol": 1.5}, "melt_temperature": {"target": 235, "tol": 5}, "mould_temperature": {"target": 60, "tol": 5}, "cooling_time": {"target": 12, "tol": 1}, "cycle_time_s": {"target": 28, "tol": 2}}',
     'PP-H-2000', 'aaaaaaaa-0000-7000-8000-000000000005', 'aaaaaaaa-0000-7000-8000-000000000006', '2026-08-01 09:00+07', true);

INSERT INTO moldmind.parameter_window (mould_id, material_grade, parameter, unit, lo, hi, source, approved_by) VALUES
    ('a0a0a0a0-0000-7000-8000-000000000417', 'PP-H-2000', 'holding_pressure',  'bar', 500, 750, 'mould datasheet MLD-0417 rev C; process validation 2026-08', 'aaaaaaaa-0000-7000-8000-000000000005'),
    ('a0a0a0a0-0000-7000-8000-000000000417', 'PP-H-2000', 'holding_time',      's',     5,  12, 'process validation 2026-08', 'aaaaaaaa-0000-7000-8000-000000000005'),
    ('a0a0a0a0-0000-7000-8000-000000000417', 'PP-H-2000', 'melt_temperature',  'C',   215, 255, 'material datasheet PP-H-2000', 'aaaaaaaa-0000-7000-8000-000000000005'),
    ('a0a0a0a0-0000-7000-8000-000000000417', 'PP-H-2000', 'mould_temperature', 'C',    40,  80, 'mould datasheet MLD-0417 rev C', 'aaaaaaaa-0000-7000-8000-000000000005'),
    ('a0a0a0a0-0000-7000-8000-000000000417', 'PP-H-2000', 'cooling_time',      's',     8,  20, 'process validation 2026-08', 'aaaaaaaa-0000-7000-8000-000000000005'),
    ('a0a0a0a0-0000-7000-8000-000000000417', 'PP-H-2000', 'cushion_mm',        'mm',    3,   6, 'setup sheet v2 (target 3–6 mm)', 'aaaaaaaa-0000-7000-8000-000000000005');

INSERT INTO moldmind.colour_reference (id, sku_id, chart_id, lab_l, lab_a, lab_b, delta_e_threshold, lighting_ref, valid_from) VALUES
    ('c01c0000-0000-7000-8000-000000000001', '22222222-0000-7000-8000-000000000002', 'XR-24-A7', 62.10, -4.30, 12.80, 2.00, 'D65 dome, station L2-OUT', '2026-08-01 00:00+07');

INSERT INTO moldmind.scrap_cost_config (sku_id, unit_cost_thb, valid_from) VALUES ('22222222-0000-7000-8000-000000000002', 42.00, '2026-01-01');

INSERT INTO moldmind.scoring_config (id, version, w_prior, w_delta, w_timeline, w_case, active, set_by) VALUES
    ('5c000000-0000-7000-8000-000000000001', '2026-09', 0.350, 0.300, 0.200, 0.150, true, 'aaaaaaaa-0000-7000-8000-000000000005');

INSERT INTO moldmind.prompt_template (kind, lang, version, path, checksum, temperature, active) VALUES
    ('rca_question', NULL, 'v1', 'deploy/prompts/rca_question.v1.md', 'sha256:rcaq-v1', 0.20, true),
    ('explain',      NULL, 'v1', 'deploy/prompts/explain.v1.md',      'sha256:expl-v1', 0.20, true);

INSERT INTO knowledge.glossary_term (id, ja, ja_reading, th, en, domain, forbidden_json, approved_by) VALUES
    ('91055a00-0000-7000-8000-000000000011', 'ヒケ',           'ひけ',           'รอยยุบ',      'sink mark',     'moulding', '["引け跡", "シンクマーク"]', 'aaaaaaaa-0000-7000-8000-000000000006'),
    ('91055a00-0000-7000-8000-000000000012', 'バリ',           'ばり',           'ครีบ',        'flash',         'moulding', '["フラッシュ"]',            'aaaaaaaa-0000-7000-8000-000000000006'),
    ('91055a00-0000-7000-8000-000000000013', 'ショートショット', 'しょーとしょっと', 'ฉีดไม่เต็ม', 'short shot',    'moulding', '["充填不足", "ショート不良"]', 'aaaaaaaa-0000-7000-8000-000000000006'),
    ('91055a00-0000-7000-8000-000000000014', 'ウェルドライン',   'うぇるどらいん',   'รอยประสาน',   'weld line',     'moulding', '["溶着線"]',                'aaaaaaaa-0000-7000-8000-000000000006'),
    ('91055a00-0000-7000-8000-000000000015', '保圧',           'ほあつ',          'แรงดันย้ำ',    'holding pressure', 'moulding', '["保持圧力"]',          'aaaaaaaa-0000-7000-8000-000000000006'),
    ('91055a00-0000-7000-8000-000000000016', 'クッション',      'くっしょん',      'คุชชั่น',      'cushion',       'moulding', '["残量"]',                  'aaaaaaaa-0000-7000-8000-000000000006');

-- ---------------------------------------------------------------------
-- 3. Knowledge base (C-03, AI-08, NFR-08): v1 approved (author nattaya, approver kenji), v2 draft
--    Appendix A sink-mark entry verbatim in deploy/kb/sink_mark.yaml (ICD-11 IF-59)
-- ---------------------------------------------------------------------
INSERT INTO moldmind.kb_defect (id, class, description_th, description_ja, description_en) VALUES
    ('d0000000-0000-7000-8000-000000000001', 'sink_mark',  'รอยยุบบนผิวจากการหดตัวของส่วนหนา', 'ヒケ — 厚肉部の体積収縮による表面のくぼみ', 'Surface depression from volumetric shrinkage at thick sections'),
    ('d0000000-0000-7000-8000-000000000002', 'short_shot', 'ฉีดไม่เต็มโพรงแม่พิมพ์', 'ショートショット — キャビティの充填不足', 'Incomplete filling of the cavity'),
    ('d0000000-0000-7000-8000-000000000003', 'flash',      'ครีบเกินที่รอยแบ่งแม่พิมพ์', 'バリ — パーティングラインの余剰樹脂', 'Excess material at the parting line');

INSERT INTO moldmind.kb_version (id, version, status, author_id, approved_by, approved_at, checksum, notes) VALUES
    ('4b000000-0000-7000-8000-000000000001', 'kb-2026.09.1', 'approved', 'aaaaaaaa-0000-7000-8000-000000000005', 'aaaaaaaa-0000-7000-8000-000000000006', '2026-09-02 10:00+07', 'sha256:kb-2026.09.1', 'sink_mark, short_shot, flash from the troubleshooting guide §4 + internal cases'),
    ('4b000000-0000-7000-8000-000000000002', 'kb-2026.09.2-draft', 'draft', 'aaaaaaaa-0000-7000-8000-000000000005', NULL, NULL, 'sha256:kb-2026.09.2-draft', 'adds weld_line and silver_streak — under review');

-- causes in v1 (sink_mark = Appendix A)
INSERT INTO moldmind.kb_cause (id, version_id, defect_id, cause_code, cause_en, cause_ja, cause_th, prior_weight, typical_params_json, checks_json, actions_json, side_effects, source, note, design_cause) VALUES
    ('ca000000-0000-7000-8000-000000000001', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000001', 'insufficient_holding_pressure', 'Insufficient holding pressure', '保圧不足', 'แรงดันย้ำไม่พอ', 0.300,
     '{"holding_pressure": "down", "cushion": "low"}',
     '["Verify cushion value vs setup sheet (target 3–6 mm)", "Check holding pressure trace against golden run"]',
     '[{"param": "holding_pressure", "direction": "up", "range": "+5..+15 %", "window_ref": "setup_sheet", "side_effects": "risk of flash, increased internal stress"}]',
     'risk of flash, increased internal stress', 'Internal case #178; molding troubleshooting guide §4.2', NULL, false),
    ('ca000000-0000-7000-8000-000000000002', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000001', 'holding_time_too_short', 'Holding time too short', '保圧時間不足', 'เวลาย้ำสั้นไป', 0.200,
     '{"holding_time": "down"}', '["Confirm gate seal time by gate-freeze study"]',
     '[{"param": "holding_time", "direction": "up", "range": "+1..+2 s", "window_ref": "setup_sheet", "side_effects": "longer cycle time"}]',
     'longer cycle time', 'molding troubleshooting guide §4.2', NULL, false),
    ('ca000000-0000-7000-8000-000000000003', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000001', 'melt_temperature_too_high', 'Melt temperature too high', '樹脂温度過高', 'อุณหภูมิหลอมสูงไป', 0.150,
     '{"melt_temperature": "up"}', '["Compare zone temperatures with the setup sheet"]',
     '[{"param": "melt_temperature", "direction": "down", "range": "-5..-10 C", "window_ref": "material_datasheet", "side_effects": "short shot risk, higher injection pressure"}]',
     'short shot risk', 'material datasheet PP-H-2000 §3', NULL, false),
    ('ca000000-0000-7000-8000-000000000004', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000001', 'mould_temperature_too_high_local', 'Mould temperature too high (local)', '金型温度局所過高', 'อุณหภูมิแม่พิมพ์สูงเฉพาะจุด', 0.150,
     '{"mould_temperature": "up"}', '["Measure mould surface temperature near the thick section"]',
     '[{"param": "mould_temperature", "direction": "down", "range": "-3..-8 C", "window_ref": "mould_datasheet", "side_effects": "weld line visibility, warpage"}]',
     'weld line visibility, warpage', 'molding troubleshooting guide §4.2; mould datasheet MLD-0417', NULL, false),
    ('ca000000-0000-7000-8000-000000000005', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000001', 'part_wall_thickness_design', 'Part wall thickness (design)', '肉厚設計', 'ความหนาผนังชิ้นงาน (การออกแบบ)', 0.100,
     '{}', '[]', '[]', NULL, 'design review DR-0417-02', 'Design cause — not correctable by parameters; route to engineering', true),
    ('ca000000-0000-7000-8000-000000000006', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000001', 'insufficient_cooling_time', 'Insufficient cooling time', '冷却時間不足', 'เวลาหล่อเย็นไม่พอ', 0.100,
     '{"cooling_time": "down"}', '["Compare cooling time with the setup sheet"]',
     '[{"param": "cooling_time", "direction": "up", "range": "+1..+3 s", "window_ref": "setup_sheet", "side_effects": "longer cycle time"}]',
     'longer cycle time', 'molding troubleshooting guide §4.2', NULL, false),
    -- short_shot and flash (abridged)
    ('ca000000-0000-7000-8000-000000000011', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000002', 'insufficient_injection_pressure', 'Insufficient injection pressure / speed', '射出圧・速度不足', 'แรงดันฉีดไม่พอ', 0.300,
     '{"injection_pressure": "down", "injection_speed": "down"}', '["Check whether the pressure limit was reached (peak pressure vs setpoint)"]',
     '[{"param": "injection_speed", "direction": "up", "range": "+5..+10 %", "window_ref": "setup_sheet", "side_effects": "burn marks at the far end, flash"}]',
     'burn marks, flash', 'molding troubleshooting guide §4.1', NULL, false),
    ('ca000000-0000-7000-8000-000000000012', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000002', 'melt_temperature_too_low', 'Melt temperature too low', '樹脂温度過低', 'อุณหภูมิหลอมต่ำไป', 0.250,
     '{"melt_temperature": "down"}', '["Compare zone temperatures with the setup sheet", "Check heater band alarms"]',
     '[{"param": "melt_temperature", "direction": "up", "range": "+5..+10 C", "window_ref": "material_datasheet", "side_effects": "sink marks, longer cooling"}]',
     'sink marks', 'material datasheet PP-H-2000 §3', NULL, false),
    ('ca000000-0000-7000-8000-000000000013', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000002', 'startup_transient', 'Startup transient (cold mould / purge)', '立ち上げ過渡', 'ช่วงเริ่มเดินเครื่อง', 0.250,
     '{}', '["Confirm the shot is within the first 20 after a startup event"]', '[]', NULL, 'internal cases #143, #151', 'Expected in the first shots after a stop; not a process fault', false),
    ('ca000000-0000-7000-8000-000000000021', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000003', 'clamping_force_too_low', 'Clamping force too low', '型締力不足', 'แรงปิดแม่พิมพ์ไม่พอ', 0.350,
     '{"clamping_force": "down", "injection_pressure": "up"}', '["Compare clamping force with the setup sheet", "Check parting-line contamination"]',
     '[{"param": "clamping_force", "direction": "up", "range": "+5..+10 %", "window_ref": "mould_datasheet", "side_effects": "mould wear, venting problems"}]',
     'mould wear', 'molding troubleshooting guide §4.3', NULL, false),
    ('ca000000-0000-7000-8000-000000000022', '4b000000-0000-7000-8000-000000000001', 'd0000000-0000-7000-8000-000000000003', 'holding_pressure_too_high', 'Holding pressure too high', '保圧過高', 'แรงดันย้ำสูงไป', 0.300,
     '{"holding_pressure": "up"}', '["Check holding pressure trace against golden run"]',
     '[{"param": "holding_pressure", "direction": "down", "range": "-5..-10 %", "window_ref": "setup_sheet", "side_effects": "sink marks"}]',
     'sink marks', 'molding troubleshooting guide §4.3', NULL, false);

-- a draft cause in v2 (not usable for ranking until approved)
INSERT INTO moldmind.kb_cause (version_id, defect_id, cause_code, cause_en, prior_weight, typical_params_json, checks_json, actions_json, source) VALUES
    ('4b000000-0000-7000-8000-000000000002', 'd0000000-0000-7000-8000-000000000001', 'gate_size_too_small', 'Gate freezes early (gate size)', 0.10, '{}', '["Gate-freeze study"]', '[]', 'design review DR-0417-03 (draft)');

-- ---------------------------------------------------------------------
-- 4. Shots (quality.shot + moldmind.shot_ext), startup transients (AC-06), gateway batch (AC-09)
--    cycle 28 s; before 2026-09-09 09:50 (100 cycles @ 650 bar) · parameter change 10:40 · after 10:40 (100 @ 560) · post-action 13:00 (100 @ 616)
--    holding pressure constant per phase; cushion = base + 0.1·sin(k) (deterministic)
-- ---------------------------------------------------------------------
INSERT INTO moldmind.startup_event (id, machine_id, mould_id, ts, kind, stop_minutes, transient_shots) VALUES
    ('57a00000-0000-7000-8000-000000000001', '33333333-0000-7000-8000-000000000003', 'a0a0a0a0-0000-7000-8000-000000000417', '2026-09-08 09:00+07', 'startup_after_stop', 120, 20);

INSERT INTO moldmind.gateway_batch (id, connection_id, outage_from, outage_to, shots_buffered, shots_inserted, duplicates, reconciled_at, reason) VALUES
    ('6a7c0000-0000-7000-8000-000000000001', 'c0000000-0000-7000-8000-000000000003', '2026-09-08 15:00+07', '2026-09-08 16:00+07', 128, 128, 0, '2026-09-08 16:02+07', 'OPC-UA session lost (network switch reboot)');

-- helper: one INSERT per phase through generate_series
CREATE TEMP TABLE _phase (phase text, start_ts timestamptz, n int, hold numeric, cushion_base numeric, startup uuid, batch uuid) ON COMMIT DROP;
INSERT INTO _phase VALUES
    ('startup',  '2026-09-08 09:00:28+07', 20,  650, 4.5, '57a00000-0000-7000-8000-000000000001', NULL),
    ('buffered', '2026-09-08 15:00:00+07', 128, 650, 4.5, NULL, '6a7c0000-0000-7000-8000-000000000001'),
    ('before',   '2026-09-09 09:50:00+07', 100, 650, 4.5, NULL, NULL),
    ('after',    '2026-09-09 10:40:00+07', 100, 560, 2.8, NULL, NULL),
    ('post',     '2026-09-09 13:00:00+07', 100, 616, 4.3, NULL, NULL);

INSERT INTO quality.shot (id, ts, machine_id, mould_id, material_lot_id, cycle_time_s, cushion_mm, params_json, melt_temp_json, mould_temp_json, shift)
SELECT ('5407' || lpad(CASE p.phase WHEN 'startup' THEN '1' WHEN 'buffered' THEN '2' WHEN 'before' THEN '3' WHEN 'after' THEN '4' ELSE '5' END, 4, '0') || '-0000-7000-8000-' || lpad(k::text, 12, '0'))::uuid,
       p.start_ts + (k - 1) * interval '28 seconds',
       '33333333-0000-7000-8000-000000000003', 'a0a0a0a0-0000-7000-8000-000000000417', '55555555-0000-7000-8000-000000000201',
       28.0 + CASE WHEN p.phase = 'after' THEN 0.2 ELSE 0 END,
       round(p.cushion_base + 0.1 * sin(k), 3),
       jsonb_build_object('holding_pressure', p.hold, 'holding_time', 8, 'injection_pressure', 1180, 'injection_speed', 45, 'back_pressure', 8, 'screw_rpm', 120,
                          'melt_temperature', 235, 'mould_temperature', 60, 'cooling_time', 12, 'clamping_force', 2100),
       CASE WHEN p.phase = 'before' AND k = 7 THEN '{"z1": 230, "z2": 235, "z3": null, "z4": 240}'::jsonb ELSE '{"z1": 230, "z2": 235, "z3": 238, "z4": 240}'::jsonb END,
       '{"fixed": 60, "moving": 58}',
       CASE WHEN p.start_ts::time < '14:00' THEN 'A' ELSE 'B' END::core.shift_code
FROM _phase p CROSS JOIN LATERAL generate_series(1, p.n) k;

INSERT INTO moldmind.shot_ext (shot_id, controller_shot_no, sku_id, cavity_count, regrind_pct, dryer_temp_c, dryer_hours, ambient_temp_c, ambient_rh_pct, operator_group, startup_event_id, seq_after_startup, dq_flags_json, batch_id)
SELECT s.id, 418000 + row_number() OVER (ORDER BY s.ts), '22222222-0000-7000-8000-000000000002', 4, 10.0, 90.0, 4.0, 31.5, 62.0, 'OG-A',
       CASE WHEN s.ts::date = DATE '2026-09-08' AND s.ts < '2026-09-08 12:00+07' THEN '57a00000-0000-7000-8000-000000000001' END,
       CASE WHEN s.ts::date = DATE '2026-09-08' AND s.ts < '2026-09-08 12:00+07' THEN row_number() OVER (PARTITION BY (s.ts < '2026-09-08 12:00+07') ORDER BY s.ts) END,
       CASE WHEN s.melt_temp_json ->> 'z3' IS NULL THEN '["missing_zone_temp:z3"]'::jsonb
            WHEN s.id = '54070003-0000-7000-8000-000000000008' THEN '["stuck_value:cushion_mm"]'::jsonb ELSE '[]'::jsonb END,
       CASE WHEN s.ts >= '2026-09-08 15:00+07' AND s.ts < '2026-09-08 16:00+07' THEN '6a7c0000-0000-7000-8000-000000000001' END
FROM quality.shot s;

-- ---------------------------------------------------------------------
-- 5. Parameter change (FR-04 → timeline event) and the applied action later
-- ---------------------------------------------------------------------
INSERT INTO moldmind.parameter_change (id, machine_id, mould_id, ts, parameter, old_value, new_value, unit, changed_by, source) VALUES
    ('9c000000-0000-7000-8000-000000000001', '33333333-0000-7000-8000-000000000003', 'a0a0a0a0-0000-7000-8000-000000000417', '2026-09-09 10:40:00+07', 'holding_pressure', 650, 560, 'bar', 'somsak (controller user 07)', 'controller'),
    ('9c000000-0000-7000-8000-000000000002', '33333333-0000-7000-8000-000000000003', 'a0a0a0a0-0000-7000-8000-000000000417', '2026-09-09 13:00:00+07', 'holding_pressure', 560, 616, 'bar', 'somsak (controller user 07)', 'controller');

-- ---------------------------------------------------------------------
-- 6. Inspections, shot parts, alignments (IF-58), defects — 4 cavities per cycle for the three 2026-09-09 phases and the startup phase
--    sink marks — before: cav1 k%33=0 (3), cav2 k=77 (1), cav3 k%50=0 (2) = 6
--                 after:  cav1 k%16=0 (6), cav2 k%20=0 (5), cav3 k%5=0 (20), cav4 k%19=0 (5) = 36
--                 post:   cav3 k%25=0 (4), cav1 k%40=0 (2), cav2 k=99 (1) = 7
--    startup: short shots on shots 1–8, all cavities → transients (AC-06)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE _part AS
SELECT s.id AS shot_id, s.ts, split_part(s.id::text, '-', 1) AS ph, (regexp_replace(split_part(s.id::text, '-', 5), '^0+', ''))::int AS k, c.cav
FROM quality.shot s CROSS JOIN generate_series(1, 4) c(cav)
WHERE split_part(s.id::text, '-', 1) IN ('54070001', '54070003', '54070004', '54070005');

CREATE TEMP TABLE _defect AS
SELECT p.*, CASE
    WHEN p.ph = '54070001' AND p.k <= 8 THEN 'short_shot'
    WHEN p.ph = '54070003' AND ((p.cav = 1 AND p.k % 33 = 0) OR (p.cav = 2 AND p.k = 77) OR (p.cav = 3 AND p.k % 50 = 0)) THEN 'sink_mark'
    WHEN p.ph = '54070004' AND ((p.cav = 1 AND p.k % 16 = 0) OR (p.cav = 2 AND p.k % 20 = 0) OR (p.cav = 3 AND p.k % 5 = 0) OR (p.cav = 4 AND p.k % 19 = 0)) THEN 'sink_mark'
    WHEN p.ph = '54070005' AND ((p.cav = 3 AND p.k % 25 = 0) OR (p.cav = 1 AND p.k % 40 = 0) OR (p.cav = 2 AND p.k = 99)) THEN 'sink_mark'
    WHEN p.ph = '54070004' AND p.cav = 2 AND p.k = 41 THEN 'weld_line'
    WHEN p.ph = '54070004' AND p.cav = 4 AND p.k = 12 THEN 'colour_deviation'
    END AS cls
FROM _part p;

INSERT INTO vision.inspection (id, ts, line_id, sku_id, station, lot, verdict, image_uri, source)
SELECT ('1a5' || substr(p.ph, 4, 5) || '-' || lpad(p.cav::text, 4, '0') || '-7000-8000-' || lpad(p.k::text, 12, '0'))::uuid,
       p.ts + interval '1200 milliseconds',
       '11111111-0000-7000-8000-000000000002', '22222222-0000-7000-8000-000000000002', 'L2-OUT', 'LOT-2609-201',
       CASE WHEN d.cls = 'weld_line' THEN 'REVIEW' WHEN d.cls IS NOT NULL THEN 'FAIL' ELSE 'PASS' END::vision.verdict,
       's3://images/M-3/' || to_char(p.ts, 'YYYY-MM-DD') || '/' || p.ph || '-' || p.k || '-c' || p.cav || '.jpg', 'edge'
FROM _part p JOIN _defect d ON d.shot_id = p.shot_id AND d.cav = p.cav;

INSERT INTO quality.shot_part (id, shot_id, cavity_no, inspection_id, inspection_ts, verdict)
SELECT ('5a7' || substr(p.ph, 4, 5) || '-' || lpad(p.cav::text, 4, '0') || '-7000-8000-' || lpad(p.k::text, 12, '0'))::uuid,
       p.shot_id, p.cav,
       ('1a5' || substr(p.ph, 4, 5) || '-' || lpad(p.cav::text, 4, '0') || '-7000-8000-' || lpad(p.k::text, 12, '0'))::uuid,
       p.ts + interval '1200 milliseconds',
       CASE WHEN d.cls = 'weld_line' THEN 'REVIEW' WHEN d.cls IS NOT NULL THEN 'FAIL' ELSE 'PASS' END::vision.verdict
FROM _part p JOIN _defect d ON d.shot_id = p.shot_id AND d.cav = p.cav;

INSERT INTO moldmind.image_alignment (shot_part_id, inspection_id, inspection_ts, image_ts, shot_ts, tolerance_ms, align_method, cavity_method, ocr_text)
SELECT sp.id, sp.inspection_id, sp.inspection_ts, sp.inspection_ts, s.ts, 1500,
       CASE WHEN p.k % 50 = 0 THEN 'timestamp' ELSE 'shot_id' END,
       CASE WHEN p.k % 50 = 0 THEN 'sequence' WHEN p.k = 41 THEN 'robot_position' ELSE 'ocr_marking' END,
       CASE WHEN p.k % 50 = 0 OR p.k = 41 THEN NULL ELSE 'C' || p.cav END
FROM quality.shot_part sp JOIN quality.shot s ON s.id = sp.shot_id
JOIN _part p ON p.shot_id = sp.shot_id AND p.cav = sp.cavity_no;

INSERT INTO moldmind.shot_defect (id, shot_part_id, defect_class, confidence, region, bbox_json, delta_e, model_version, review_required)
SELECT ('de' || substr(d.ph, 3, 6) || '-' || lpad(d.cav::text, 4, '0') || '-7000-8000-' || lpad(d.k::text, 12, '0'))::uuid,
       ('5a7' || substr(d.ph, 4, 5) || '-' || lpad(d.cav::text, 4, '0') || '-7000-8000-' || lpad(d.k::text, 12, '0'))::uuid,
       d.cls::moldmind.defect_class,
       CASE d.cls WHEN 'weld_line' THEN 0.58 WHEN 'colour_deviation' THEN 0.99 ELSE 0.91 END,
       CASE d.cls WHEN 'sink_mark' THEN 'boss' WHEN 'short_shot' THEN 'far_end' WHEN 'weld_line' THEN 'rib' ELSE 'other' END::moldmind.part_region,
       '{"x": 210, "y": 140, "w": 36, "h": 22}',
       CASE WHEN d.cls = 'colour_deviation' THEN moldmind.delta_e76(62.1, -4.3, 12.8, 59.8, -3.1, 15.0) END,
       'pnl-family-v3', d.cls = 'weld_line'
FROM _defect d WHERE d.cls IS NOT NULL;

-- FR-11: the low-confidence weld line is reviewed by the QC inspector → FAIL (stored here and as a platform override)
UPDATE moldmind.shot_defect SET review_verdict = 'FAIL', reviewed_by = 'aaaaaaaa-0000-7000-8000-000000000004', reviewed_at = '2026-09-09 11:05+07'
WHERE defect_class = 'weld_line';
INSERT INTO vision.verdict_override (inspection_id, inspection_ts, user_id, old_verdict, new_verdict, reason_code, note)
SELECT sp.inspection_id, sp.inspection_ts, 'aaaaaaaa-0000-7000-8000-000000000004', 'REVIEW', 'FAIL', 'confirmed_defect', 'weld line visible at the rib under low-angle light'
FROM moldmind.shot_defect d JOIN quality.shot_part sp ON sp.id = d.shot_part_id WHERE d.defect_class = 'weld_line';
UPDATE quality.shot_part sp SET verdict = 'FAIL' FROM moldmind.shot_defect d WHERE d.shot_part_id = sp.id AND d.defect_class = 'weld_line';

-- ---------------------------------------------------------------------
-- 7. Cavity flags (FR-12) for the after window: cavity 3 20/100 vs 16/300
-- ---------------------------------------------------------------------
INSERT INTO moldmind.cavity_flag (mould_id, defect_class, window_from, window_to, cavity_no, x, n, others_x, others_n)
SELECT 'a0a0a0a0-0000-7000-8000-000000000417', 'sink_mark', '2026-09-09 10:40+07', '2026-09-09 11:27+07', c.cav,
       (SELECT count(*) FROM _defect d WHERE d.ph = '54070004' AND d.cls = 'sink_mark' AND d.cav = c.cav)::int, 100,
       (SELECT count(*) FROM _defect d WHERE d.ph = '54070004' AND d.cls = 'sink_mark' AND d.cav <> c.cav)::int, 300
FROM generate_series(1, 4) c(cav);

-- ---------------------------------------------------------------------
-- 8. RCA session (AC-03): scores turn 0 and after the three answers (turn 3), dialogue, advice (checks first), suggestions (AC-05), outcome (AC-07), write-back (FR-25), handoff (FR-26)
-- ---------------------------------------------------------------------
INSERT INTO moldmind.rca_session (id, opened_at, opened_by, defect_class, mould_id, machine_id, window_from, window_to, kb_version_id, scoring_config_id, lang, status, facts_json) VALUES
    ('2ca00000-0000-7000-8000-000000000001', '2026-09-09 12:06+07', 'aaaaaaaa-0000-7000-8000-000000000003', 'sink_mark', 'a0a0a0a0-0000-7000-8000-000000000417', '33333333-0000-7000-8000-000000000003',
     '2026-09-09 10:40+07', '2026-09-09 11:30+07', '4b000000-0000-7000-8000-000000000001', '5c000000-0000-7000-8000-000000000001', 'th', 'dialogue',
     '{"schema_version": "rca-facts.v1", "lang": "th", "defect_class": "sink_mark", "mould": "MLD-0417", "machine": "M-3",
       "window": {"from": "2026-09-09T10:40:00+07:00", "to": "2026-09-09T11:30:00+07:00"},
       "trend": {"before_x": 6, "before_n": 400, "before_rate_pct": 1.5, "after_x": 36, "after_n": 400, "after_rate_pct": 9.0, "z": 4.5971, "p_value": 4.3e-6, "evidence": "E-01"},
       "cavities": [{"cavity": 3, "x": 20, "n": 100, "others_x": 16, "others_n": 300, "flagged": true, "evidence": "E-02"}],
       "parameter_deltas": [{"parameter": "holding_pressure", "unit": "bar", "defective_mean": 582.19, "good_mean": 625.25, "cohens_d": -1.2619, "direction": "down", "evidence": "E-03"},
                            {"parameter": "cushion_mm", "unit": "mm", "defective_mean": 3.293, "good_mean": 4.139, "cohens_d": -1.288, "direction": "down", "evidence": "E-04"}],
       "timeline": [{"ts": "2026-09-09T10:40:00+07:00", "kind": "parameter_edit", "parameter": "holding_pressure", "old": 650, "new": 560, "evidence": "E-05"}],
       "causes": [
         {"rank": 1, "code": "insufficient_holding_pressure", "score": 0.88, "components": {"prior": 1.0, "delta": 1.0, "timeline": 1.0, "case": 0.2}, "checks": ["Verify cushion value vs setup sheet (target 3–6 mm)", "Check holding pressure trace against golden run"], "actions": [{"param": "holding_pressure", "direction": "up", "range": "+5..+15 %", "window": [500, 750], "side_effects": "risk of flash, increased internal stress"}]},
         {"rank": 2, "code": "holding_time_too_short", "score": 0.2333, "components": {"prior": 0.6667, "delta": 0.0, "timeline": 0.0, "case": 0.0}},
         {"rank": 3, "code": "melt_temperature_too_high", "score": 0.175, "components": {"prior": 0.5, "delta": 0.0, "timeline": 0.0, "case": 0.0}},
         {"rank": 4, "code": "mould_temperature_too_high_local", "score": 0.175, "components": {"prior": 0.5, "delta": 0.0, "timeline": 0.0, "case": 0.0}},
         {"rank": 5, "code": "part_wall_thickness_design", "score": 0.1167, "components": {"prior": 0.3333, "delta": 0.0, "timeline": 0.0, "case": 0.0}, "design_cause": true},
         {"rank": 6, "code": "insufficient_cooling_time", "score": 0.1167, "components": {"prior": 0.3333, "delta": 0.0, "timeline": 0.0, "case": 0.0}}],
       "weights": {"prior": 0.35, "delta": 0.30, "timeline": 0.20, "case": 0.15},
       "questions": [{"key": "material_dried_per_spec", "en": "Was the material dried per spec?"}, {"key": "material_lot_changed", "ja": "材料ロットは変更しましたか？"}, {"key": "mould_maintenance_performed", "en": "Was mould maintenance performed?"}],
       "glossary": [{"ja": "ヒケ", "th": "รอยยุบ", "en": "sink mark"}, {"ja": "保圧", "th": "แรงดันย้ำ", "en": "holding pressure"}],
       "wording_rules": {"numbers_only_from_facts": true, "ranking_from_scoring_function": true, "checks_before_changes": true, "no_magnitude_outside_window": true}}');

-- turn 0 (initial ranking) and turn 3 (after the three answers — components unchanged, ranking confirmed)
INSERT INTO moldmind.rca_cause_score (session_id, cause_id, turn_no, prior_c, delta_c, timeline_c, case_c, score, rank, evidence_json)
SELECT '2ca00000-0000-7000-8000-000000000001', c.id, t.turn_no, v.prior_c, v.delta_c, v.timeline_c, v.case_c,
       moldmind.cause_score(v.prior_c, v.delta_c, v.timeline_c, v.case_c, '5c000000-0000-7000-8000-000000000001'), v.rank, v.ev::jsonb
FROM (VALUES
    ('insufficient_holding_pressure',    1.0000, 1.0000, 1.0000, 0.2000, 1, '["E-03 holding_pressure down (d ≫ 1)", "E-04 cushion low", "E-05 parameter_edit 10:40", "case #178"]'),
    ('holding_time_too_short',           0.6667, 0.0000, 0.0000, 0.0000, 2, '["no delta on holding_time"]'),
    ('melt_temperature_too_high',        0.5000, 0.0000, 0.0000, 0.0000, 3, '["no delta on melt_temperature"]'),
    ('mould_temperature_too_high_local', 0.5000, 0.0000, 0.0000, 0.0000, 4, '["no delta on mould_temperature"]'),
    ('part_wall_thickness_design',       0.3333, 0.0000, 0.0000, 0.0000, 5, '["design cause — not correctable by parameters"]'),
    ('insufficient_cooling_time',        0.3333, 0.0000, 0.0000, 0.0000, 6, '["no delta on cooling_time"]')
) v(code, prior_c, delta_c, timeline_c, case_c, rank, ev)
JOIN moldmind.kb_cause c ON c.cause_code = v.code AND c.version_id = '4b000000-0000-7000-8000-000000000001'
CROSS JOIN (VALUES (0), (3)) t(turn_no);

INSERT INTO moldmind.rca_turn (session_id, turn_no, question_key, question_text, lang, answer, answer_norm, answered_by, asked_at, answered_at) VALUES
    ('2ca00000-0000-7000-8000-000000000001', 1, 'material_dried_per_spec',     'วัสดุผ่านการอบแห้งตามสเปคหรือไม่ (90 °C / 4 ชม.)?', 'th', 'ใช่ อบ 4 ชม. ที่ 90 °C', 'yes', 'aaaaaaaa-0000-7000-8000-000000000003', '2026-09-09 12:06:10+07', '2026-09-09 12:06:40+07'),
    ('2ca00000-0000-7000-8000-000000000001', 2, 'material_lot_changed',        '材料ロットは変更しましたか？', 'ja', 'いいえ（LOT-2609-201 のまま）', 'no', 'aaaaaaaa-0000-7000-8000-000000000003', '2026-09-09 12:06:45+07', '2026-09-09 12:07:05+07'),
    ('2ca00000-0000-7000-8000-000000000001', 3, 'mould_maintenance_performed', 'มีการซ่อมบำรุงแม่พิมพ์ก่อนหน้านี้หรือไม่?', 'th', 'ไม่มี (ครั้งล่าสุด 2026-08-20)', 'no', 'aaaaaaaa-0000-7000-8000-000000000003', '2026-09-09 12:07:10+07', '2026-09-09 12:07:30+07');

INSERT INTO moldmind.rca_advice (id, session_id, ordinal, kind, cause_id, text_th, text_ja, text_en, parameter, direction, magnitude_range, window_ref, side_effects) VALUES
    ('ad000000-0000-7000-8000-000000000001', '2ca00000-0000-7000-8000-000000000001', 1, 'check', 'ca000000-0000-7000-8000-000000000001',
     'ตรวจค่าคุชชั่นเทียบกับ setup sheet (เป้าหมาย 3–6 มม.) — ปัจจุบัน 2.8 มม.', 'クッション値を条件表（目標 3–6 mm）と照合 — 現在 2.8 mm', 'Verify cushion value vs setup sheet (target 3–6 mm) — currently 2.8 mm', NULL, NULL, NULL, NULL, NULL),
    ('ad000000-0000-7000-8000-000000000002', '2ca00000-0000-7000-8000-000000000001', 2, 'check', 'ca000000-0000-7000-8000-000000000001',
     'เทียบกราฟแรงดันย้ำกับ golden run (650 bar)', '保圧波形をゴールデンランと比較（650 bar）', 'Check holding pressure trace against golden run (650 bar)', NULL, NULL, NULL, NULL, NULL),
    ('ad000000-0000-7000-8000-000000000003', '2ca00000-0000-7000-8000-000000000001', 3, 'action', 'ca000000-0000-7000-8000-000000000001',
     'เพิ่มแรงดันย้ำ +5..+15 % (ภายใน 500–750 bar) — ผลข้างเคียง: ครีบ, ความเค้นภายใน', '保圧を +5〜+15 % 上げる（500〜750 bar の範囲内）— 副作用: バリ、内部応力', 'Increase holding pressure +5..+15 % (within 500–750 bar) — side effects: flash, internal stress',
     'holding_pressure', 'up', '+5..+15 %', 'setup_sheet v2 / window MLD-0417 × PP-H-2000', 'risk of flash, increased internal stress');

-- suggestions: 616 bar allowed; 800 bar blocked (AC-05) — stored, audited, never allowed
INSERT INTO moldmind.parameter_suggestion (id, session_id, advice_id, parameter, unit, current_value, suggested_value, direction) VALUES
    ('5c9e0000-0000-7000-8000-000000000001', '2ca00000-0000-7000-8000-000000000001', 'ad000000-0000-7000-8000-000000000003', 'holding_pressure', 'bar', 560, 616, 'up'),
    ('5c9e0000-0000-7000-8000-000000000002', '2ca00000-0000-7000-8000-000000000001', 'ad000000-0000-7000-8000-000000000003', 'holding_pressure', 'bar', 560, 800, 'up');

UPDATE moldmind.rca_advice SET done = true, done_by = 'aaaaaaaa-0000-7000-8000-000000000003', done_at = '2026-09-09 12:20+07' WHERE ordinal IN (1, 2);
UPDATE moldmind.rca_advice SET done = true, done_by = 'aaaaaaaa-0000-7000-8000-000000000003', done_at = '2026-09-09 13:00+07' WHERE ordinal = 3;
UPDATE moldmind.rca_session SET status = 'acting' WHERE id = '2ca00000-0000-7000-8000-000000000001';

-- verified cause (process engineer) after the checks confirmed cushion 2.8 mm and the 10:40 edit
UPDATE moldmind.rca_session SET verified_cause_id = 'ca000000-0000-7000-8000-000000000001', verified_by = 'aaaaaaaa-0000-7000-8000-000000000005', verified_at = '2026-09-09 12:30+07', status = 'verifying'
WHERE id = '2ca00000-0000-7000-8000-000000000001';

-- AC-07: outcome computed by the trigger (36/400 → 7/400); write-back by trg_evidence_writeback
INSERT INTO moldmind.action_outcome (id, session_id, advice_id, action, applied_at, applied_by, before_x, before_n, after_x, after_n) VALUES
    ('0c000000-0000-7000-8000-000000000001', '2ca00000-0000-7000-8000-000000000001', 'ad000000-0000-7000-8000-000000000003', 'holding_pressure 560 → 616 bar (+10 %)', '2026-09-09 13:00+07', 'aaaaaaaa-0000-7000-8000-000000000003', 36, 400, 7, 400);

-- FR-26: 8D handoff → QE-Agent case and draft (ai_generated, unapproved)
INSERT INTO quality.case (id, title, line_id, sku_id, machine_id, severity, status, owner_id, opened_at) VALUES
    ('5ca5e000-0000-7000-8000-000000000417', 'QC-0417 Sink marks on PNL-220 / MLD-0417 after holding-pressure change (2026-09-09)',
     '11111111-0000-7000-8000-000000000002', '22222222-0000-7000-8000-000000000002', '33333333-0000-7000-8000-000000000003', 'HIGH', 'action', 'aaaaaaaa-0000-7000-8000-000000000006', '2026-09-09 14:40+07');
INSERT INTO quality.artifact (id, case_id, kind, version, lang, content_json, ai_generated, prompt_version) VALUES
    ('a8d00000-0000-7000-8000-000000000001', '5ca5e000-0000-7000-8000-000000000417', 'eight_d', 1, 'en',
     '{"source": "moldmind.rca_session 2ca00000-0000-7000-8000-000000000001", "d2_problem": "sink marks 1.5 % → 9.0 % on MLD-0417 after holding pressure 650 → 560 bar", "d4_root_cause": "insufficient holding pressure (verified by process engineer)", "d5_corrective": "holding pressure 616 bar; effectiveness 9.0 % → 1.75 % (p < 0.001)", "draft_notice": "DRAFT — AI generated"}',
     true, 'qe-eight_d.en.v1');
UPDATE moldmind.rca_session SET qe_case_id = '5ca5e000-0000-7000-8000-000000000417', status = 'closed', closure_kind = 'verified', closed_at = '2026-09-09 14:45+07'
WHERE id = '2ca00000-0000-7000-8000-000000000001';

-- ---------------------------------------------------------------------
-- 9. Evaluation runs (AI-02, AI-07)
-- ---------------------------------------------------------------------
INSERT INTO moldmind.vision_eval_run (ran_at, model_version, family, holdout_n, map50, recall_json, notes) VALUES
    ('2026-08-25 02:00+07', 'pnl-family-v2', 'PNL', 1200, 0.81, '{"short_shot": 0.96, "flash": 0.95, "contamination": 0.93, "sink_mark": 0.88, "weld_line": 0.84}', 'contamination recall below gate'),
    ('2026-09-01 02:00+07', 'pnl-family-v3', 'PNL', 1200, 0.83, '{"short_shot": 0.97, "flash": 0.96, "contamination": 0.95, "sink_mark": 0.90, "weld_line": 0.86}', 'released');
INSERT INTO moldmind.golden_run (ran_at, kb_version_id, scoring_config_id, incidents, top3_hits, notes) VALUES
    ('2026-09-02 03:00+07', '4b000000-0000-7000-8000-000000000001', '5c000000-0000-7000-8000-000000000001', 15, 11, 'kb-2026.09.1 — 73.3 %'),
    ('2026-08-20 03:00+07', '4b000000-0000-7000-8000-000000000001', '5c000000-0000-7000-8000-000000000001', 15, 9, 'earlier priors — 60 %, below gate');

COMMIT;

-- =====================================================================
-- Verification block (TEST-11 TC-009; expected values in DDS-11 §9)
-- =====================================================================
\echo '--- counts: shots 448 · parts 1280 · defects 32+6+36+7+1+1 = 83 · transient shots 20 · buffered 128'
SELECT (SELECT count(*) FROM quality.shot) AS shots, (SELECT count(*) FROM quality.shot_part) AS parts, (SELECT count(*) FROM moldmind.shot_defect) AS defects,
       (SELECT count(*) FROM moldmind.shot_ext WHERE startup_transient) AS transient_shots, (SELECT sum(shots_buffered) FROM moldmind.gateway_batch) AS buffered,
       (SELECT count(*) FROM moldmind.image_alignment) AS alignments, (SELECT count(*) FROM quality.timeline_event WHERE kind = 'parameter_edit') AS parameter_edits;
\echo '--- AC-03 trend: 6/400 vs 36/400 → z 4.5971 p 4.28e-6 ; post-action 36/400 vs 7/400 → z 4.3896 p 1.14e-5 ; control 15/400 vs 13/400 → p 0.847'
SELECT * FROM moldmind.two_proportion_z(36, 400, 6, 400);
SELECT * FROM moldmind.two_proportion_z(36, 400, 7, 400);
SELECT * FROM moldmind.two_proportion_z(15, 400, 13, 400);
\echo '--- cavity flags (after window): cavity 3 20/100 vs 16/300 → z 4.2366 p 2.27e-5 flagged; others not'
SELECT cavity_no, x, n, others_x, others_n, z, p_value, flagged FROM moldmind.cavity_flag ORDER BY cavity_no;
\echo '--- v_cavity_rates excludes the 20 transient shots (parts 1200 → 300 per cavity; fail counts by cavity)'
SELECT cavity_no, parts, failed, fail_rate_pct FROM moldmind.v_cavity_rates ORDER BY cavity_no;
\echo '--- parameter delta for sink_mark: holding_pressure defective n 42 mean 582.190 vs good n 386 mean 625.254, d -1.2619, Welch t -7.617 ; cushion_mm 3.293 vs 4.139, d -1.288'
SELECT parameter, n_defective, mean_defective, n_good, mean_good, delta, cohens_d, welch_t FROM moldmind.v_parameter_delta WHERE defect_class = 'sink_mark' AND parameter IN ('holding_pressure', 'cushion_mm') ORDER BY parameter;
\echo '--- drift over the last 200 shots (after 100 @ 2.8 then post 100 @ 4.3): cushion +0.011221 mm/shot, holding +0.420011 bar/shot, cycle -0.0015 s/shot'
SELECT * FROM moldmind.v_drift;
\echo '--- golden diff vs setup sheet v2 (latest shot 616 bar → deviation -34, out of tolerance ±20)'
SELECT parameter, target, tolerance, current_value, deviation, out_of_tolerance FROM moldmind.v_golden_diff ORDER BY parameter;
\echo '--- ΔE76: 1.814 (ok) and 3.401 (colour_deviation defect stored)'
SELECT moldmind.delta_e76(62.1, -4.3, 12.8, 60.9, -3.9, 14.1) AS de_ok, moldmind.delta_e76(62.1, -4.3, 12.8, 59.8, -3.1, 15.0) AS de_flagged, (SELECT delta_e FROM moldmind.shot_defect WHERE defect_class = 'colour_deviation') AS stored;
\echo '--- cause ranking (turn 3): 0.88 / 0.2333 / 0.175 / 0.175 / 0.1167 / 0.1167 with components'
SELECT rank, cause_code, prior_c, delta_c, timeline_c, case_c, score FROM moldmind.v_cause_ranking WHERE turn_no = 3 ORDER BY rank;
\echo '--- advice order: check, check, action ; suggestions: 616 allowed, 800 blocked (audit row)'
SELECT ordinal, kind, parameter, direction, magnitude_range FROM moldmind.rca_advice ORDER BY ordinal;
SELECT suggested_value, magnitude_pct, window_lo, window_hi, allowed, blocked, block_reason FROM moldmind.v_suggestion_audit ORDER BY suggested_value;
SELECT count(*) AS blocked_audit_rows FROM audit.log WHERE action = 'moldmind.suggestion.blocked';
\echo '--- AC-07 effectiveness: before 0.09 after 0.0175 z 4.3896 p 1.14e-5 effective true ; kb_case_evidence 1 row'
SELECT before_rate, after_rate, z, p_value, effective, outcome FROM moldmind.v_effectiveness;
SELECT c.cause_code, e.outcome, e.before_rate, e.after_rate FROM moldmind.kb_case_evidence e JOIN moldmind.kb_cause c ON c.id = e.cause_id;
\echo '--- RCA board: closed / verified / top cause insufficient_holding_pressure / 3 answers / 1 blocked / effective / handed off'
SELECT status, closure_kind, top_cause, answers, blocked_suggestions, effective, handed_off FROM moldmind.v_rca_board;
\echo '--- KB status: kb-2026.09.1 approved (11 causes, 3 defects, 1 evidence) ; draft version'
SELECT version, status, author, approver, causes, defects_covered, evidence_rows FROM moldmind.v_kb_status ORDER BY version;
\echo '--- evaluation gates: vision v2 failed (contamination 0.93), v3 passed ; golden 11/15 = 0.7333 passed, 9/15 = 0.6 failed'
SELECT model_version, map50, recall_json ->> 'contamination' AS contamination, passed FROM moldmind.vision_eval_run ORDER BY ran_at;
SELECT ran_at::date, incidents, top3_hits, top3_rate, passed FROM moldmind.golden_run ORDER BY ran_at;
\echo '--- data quality (FR-05): 1 shot missing z3, 1 stuck cushion ; gateway lag: 0 open batches, 128 buffered, 0 duplicates'
SELECT day, shots, flagged_shots, transient_shots FROM moldmind.v_data_quality ORDER BY day;
SELECT machine_code, protocol, open_batches, shots_buffered_total, duplicates_total FROM moldmind.v_gateway_lag;
\echo '--- scrap cost 2026-09-09 (sink_mark 49 × 42 = 2,058 THB; incident window 36 × 42 = 1,512)'
SELECT day, defect_class, defects, cost_thb FROM moldmind.v_scrap_cost ORDER BY day, defect_class;
SELECT moldmind.scrap_cost(36, 42.00) AS incident_window_thb;
\echo '--- twins: drift_slope([4.5,4.4,4.3,4.2]) = -0.1 ; is_startup_transient(20,20) true / (21,20) false ; cohens_d = -1.2619 ; welch t = -7.617'
SELECT moldmind.drift_slope(ARRAY[4.5, 4.4, 4.3, 4.2]) AS slope, moldmind.is_startup_transient(20, 20) AS t20, moldmind.is_startup_transient(21, 20) AS t21,
       moldmind.cohens_d(582.190, 34.876, 42, 625.254, 34.045, 386) AS d_example, (moldmind.welch_t(582.190, 34.876, 42, 625.254, 34.045, 386)).t AS t_example;

-- =====================================================================
-- Probes — each statement MUST fail with the named guard (TEST-11 TC-003)
-- =====================================================================
\set ON_ERROR_STOP off
\echo '--- probe 1: cavity 5 on a 4-cavity mould → CAVITY_OUT_OF_RANGE'
INSERT INTO quality.shot_part (shot_id, cavity_no) VALUES ('54070004-0000-7000-8000-000000000001', 5);
\echo '--- probe 2: defect without an existing shot part → FK violation (C-02)'
INSERT INTO moldmind.shot_defect (shot_part_id, defect_class, confidence, model_version) VALUES ('5a700000-0000-7000-8000-00000000ffff', 'flash', 0.9, 'x');
\echo '--- probe 3: image 8 s from its shot → ALIGNMENT_TOLERANCE'
INSERT INTO moldmind.image_alignment (shot_part_id, inspection_id, inspection_ts, image_ts, shot_ts, tolerance_ms, align_method, cavity_method)
SELECT sp.id, sp.inspection_id, sp.inspection_ts, s.ts + interval '8 seconds', s.ts, 1500, 'timestamp', 'sequence' FROM quality.shot_part sp JOIN quality.shot s ON s.id = sp.shot_id LIMIT 1;
\echo '--- probe 4: asserting an 800 bar suggestion as allowed → OUT_OF_WINDOW'
INSERT INTO moldmind.parameter_suggestion (session_id, parameter, unit, current_value, suggested_value, direction, allowed) VALUES ('2ca00000-0000-7000-8000-000000000001', 'holding_pressure', 'bar', 560, 800, 'up', true);
\echo '--- probe 5: typing effective = true with p 0.85 (15/400 vs 13/400) → EFFECTIVE_NOT_TYPED'
INSERT INTO moldmind.action_outcome (session_id, action, applied_at, before_x, before_n, after_x, after_n, effective) VALUES ('2ca00000-0000-7000-8000-000000000001', 'probe', now(), 15, 400, 13, 400, true);
\echo '--- probe 6: knowledge cause without a source → CHECK constraint (AI-08)'
INSERT INTO moldmind.kb_cause (version_id, defect_id, cause_code, cause_en, prior_weight, source) VALUES ('4b000000-0000-7000-8000-000000000002', 'd0000000-0000-7000-8000-000000000001', 'probe', 'probe', 0.1, '   ');
\echo '--- probe 7: RCA session on the draft KB version → KB_NOT_APPROVED'
INSERT INTO moldmind.rca_session (defect_class, mould_id, window_from, window_to, kb_version_id, scoring_config_id) VALUES ('sink_mark', 'a0a0a0a0-0000-7000-8000-000000000417', now() - interval '1 hour', now(), '4b000000-0000-7000-8000-000000000002', '5c000000-0000-7000-8000-000000000001');
\echo '--- probe 8: an action before any check in a new session → CHECK_BEFORE_CHANGE'
INSERT INTO moldmind.rca_session (id, defect_class, mould_id, window_from, window_to, kb_version_id, scoring_config_id) VALUES ('2ca00000-0000-7000-8000-0000000000f8', 'flash', 'a0a0a0a0-0000-7000-8000-000000000417', now() - interval '1 hour', now(), '4b000000-0000-7000-8000-000000000001', '5c000000-0000-7000-8000-000000000001');
INSERT INTO moldmind.rca_advice (session_id, ordinal, kind, text_en, parameter, direction, magnitude_range, window_ref, side_effects) VALUES ('2ca00000-0000-7000-8000-0000000000f8', 1, 'action', 'raise clamping force', 'clamping_force', 'up', '+5..+10 %', 'mould_datasheet', 'mould wear');
\echo '--- probe 9: machine connection with a read-write credential → MACHINE_READONLY'
INSERT INTO moldmind.machine_connection (machine_id, protocol, endpoint, credential_ref, credential_kind) VALUES ('33333333-0000-7000-8000-000000000003', 'mqtt', 'mqtt://gw', 'gw_rw', 'read_write');
\echo '--- probe 10: editing an approved KB version → KB_IMMUTABLE'
UPDATE moldmind.kb_version SET checksum = 'sha256:tampered' WHERE version = 'kb-2026.09.1';
\echo '--- probe 11: a stored score that the scoring function does not produce → SCORE_NOT_TRANSPARENT'
INSERT INTO moldmind.rca_cause_score (session_id, cause_id, turn_no, prior_c, delta_c, timeline_c, case_c, score, rank) VALUES ('2ca00000-0000-7000-8000-000000000001', 'ca000000-0000-7000-8000-000000000002', 9, 0.6667, 0, 0, 0, 0.99, 1);
\echo '--- probe 12: node map requesting write access → NODE_MAP_WRITE'
INSERT INTO moldmind.node_map_version (connection_id, version, checksum, nodes_json) VALUES ('c0000000-0000-7000-8000-000000000003', 'v-probe', 'x', '[{"node_id": "ns=2;s=Injection.HoldingPressure", "signal": "holding_pressure", "unit": "bar", "access": "write"}]');
\echo '--- probes done: expected 12 failures above'
