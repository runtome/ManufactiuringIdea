-- =====================================================================
--  QE-Agent — demo / test seed  (DDS-09 §9)
--  Deterministic (no random()). Reproduces SRS-09 Appendix A and the acceptance criteria THROUGH the real functions and triggers:
--    App. A  Signal S-241 · scratch on Line 4 · 0.52 % (80/15,400, 30-day baseline) → 3.18 % (70/2,200, last 24 h) · two_proportion_z p < 0.001
--            change point 2026-09-08 14:20 ± 40 min · hypotheses: lot LOT-2609-114 (46/940 = 4.89 % vs 6/940 = 0.64 %, n = 1,880, Fisher p < 0.001, RR 7.67) score 0.71;
--            mould M-12 (last polished 2026-07-08 = 62 d before, plan 45; 2.10 % vs 1.00 % = 2.1×) score 0.38; shift B (68 % of defects, 61 % of volume) score 0.19;
--            machine / operator group / ambient: no meaningful association; similar cases #212 and #178
--    AC-01   X̄-R limits and Cp/Cpk/Pp/Ppk of characteristic C1 computed by quality.xbar_r_limits() / capability_indices() from 125 deterministic measurements
--    AC-02   the constructed 40-point series for C3 through quality.nelson_rules(): rule 1 {5}, rule 2 {10..18}, rule 3 {20..25}, rule 5 {28,29}, rule 6 {33,34,36,37}
--    AC-03   C2 capability with normality_ok = false and a method note (a note-less row is probe 6)
--    AC-05   8D artefact A1: 12 claims, all traced after hypothesis H1 is confirmed; 5-Why A2 with one untraced number → grounding failed (probe 1)
--    AC-06   A2 exported only with the DRAFT watermark (probe 2 tries 'APPROVED'); A1 exported APPROVED with version and approver stamps
--    AC-07   JA report A3: one glossary violation (修正措置 → 是正処置) blocks approval until resolved
--    AC-08   action "quarantine lot + re-polish M-12": 70/2,200 → 12/2,180, z 6.31, p 2.7e-10 → verified; control action 15/2,500 vs 14/2,400 → z 0 (continuity-corrected), p 1.0 → not improved → stays done
--    AC-09   analysis_run in statistics_only mode with llm_available = false: tests 7, hypotheses 3, artifacts 0
--    AI-05   golden run 1: 13/20 top-3 = 65 % , 0 fabricated → not blocked; run 2: 11/20 → release_blocked
--    AI-07   FMEA proposal S 7 / O 4 / D 5 confirmed against criteria rows → fmea_row with AP = M (from the AP table)
--    FR-06   limits recalculated with a reason → previous row deactivated, kept; audit row
--    FR-11   a signal with n = 25 (< 50) and a signal inside a declared trial run are dismissed with a reason
--    FR-29/30 case QC-0230 closed → knowledge.case_record + horizontal candidates
--
--  Run after schema.sql:   psql -v ON_ERROR_STOP=1 -f seed_demo.sql
--  Re-run guard: aborts if quality.case already has rows.
--
--  EXPECTED VALUES (TEST-09 TC-005 — re-derived in Python; PostgreSQL execution pending, README-09)
--    users 6 · lines 4 · skus 2 · machines 2 · moulds 3 · lots 3 · defect types 2 · characteristics 4 · measurements 125 + 40 · subgroups 25
--    C1 (n = 5, 25 subgroups): value = 2.500 + 0.020·sin(1.3·seq + 0.7·k) + 0.005·cos(2.1·k) → X̿ 2.498951, R̄ 0.031497
--        UCLx 2.517125, LCLx 2.480778, UCLr 0.066584, LCLr 0; sd_within = R̄/2.326 = 0.013541; sd_overall 0.014536 → Cp 2.4616, Cpk 2.4358, Pp 2.2932, Ppk 2.2692 (± 1e-4 from numeric rounding)
--    control_limits 2 for C1 (first deactivated by the recalculation), 1 for C3 · spc_violation 5 rows (one per rule) with the point lists above
--    capability_result 2 (C1 normality ok; C2 normality_ok false with method note)
--    signals 4: S-241 open→case_opened score 0.5600 (0.35·0.6 + 0.25·0.4 + 0.20·0.35 + 0.20·0.9); S-242 dismissed (n 25 < 50); S-243 dismissed (trial run); S-230 case_opened (older)
--    S-241 two_proportion_z(70, 2200, 80, 15400): p1 0.031818, p2 0.005195, z 12.5832, p ≈ 2.6e-36 (< 0.001)
--    correlation p-values (Python twin): lot Fisher 6.72e-9 (BH 4.70e-8), mould z 3.3386 p 8.42e-4 (BH 2.95e-3), shift z 1.1954 p 0.2319 (BH 0.541), machine 0.9033, operator 0.5436, ambient 0.71, parameter 1.0
--    change_point 1 · correlation_test 7 (lot, mould, shift meaningful = true, true, false; machine, operator, ambient, parameter false)
--    evidence 14 (E-01..E-14) · hypotheses 3 (ranks 1..3; H1 confirmed by the engineer after verification) · hypothesis_evidence 9
--    cases 2: QC-0241 (analysis → action, open) · QC-0230 (closed → case_record + 2 horizontal candidates)
--    artifacts 4: A1 eight_d en approved (claims 12/0 untraced, revision 2) · A2 five_why en draft grounding failed (claims 5/1) · A3 report ja draft (term violation resolved → 0) · A4 fmea en draft
--    exports 3: A1 docx APPROVED v1.2 · A2 pdf DRAFT — AI generated v1.1 · A3 docx DRAFT — AI generated v1.1
--    fmea_proposal 1 confirmed → fmea_row 1 (rpn 140, ap M) · ocap_suggestion 1 · actions 6 (QC-0241: 4; QC-0230: 2) · effectiveness_check 3 · escalations 2
--    golden_incident 20 · golden_run 2 (65 % not blocked; 55 % blocked) · golden_result 20 · analysis_run 3 (2 full, 1 statistics_only)
--    knowledge.case_record 3 (#212, #178 seeded; QC-0230 by the closure trigger) · glossary_term 3 · term_check 1 (resolved)
--    audit.log ≥ 9 (limits 3 + approval 1 + exports 3 + fmea 1 + case closed 1)
--    8 constraint probes at the end all fail inside their savepoint
-- =====================================================================
\set ON_ERROR_STOP on

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM quality.case) THEN RAISE EXCEPTION 'seed_demo: quality.case is not empty — refusing to seed'; END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. Master data and users
-- ---------------------------------------------------------------------
INSERT INTO core.plant (id, code, name) VALUES ('11111111-0000-7000-8000-000000000001', 'BKK-1', 'Bangkok Plant 1');
INSERT INTO core.line (id, plant_id, code, name) VALUES
    ('22222222-0000-7000-8000-000000000001', '11111111-0000-7000-8000-000000000001', 'L1', 'Line 1'),
    ('22222222-0000-7000-8000-000000000002', '11111111-0000-7000-8000-000000000001', 'L2', 'Line 2'),
    ('22222222-0000-7000-8000-000000000003', '11111111-0000-7000-8000-000000000001', 'L3', 'Line 3'),
    ('22222222-0000-7000-8000-000000000004', '11111111-0000-7000-8000-000000000001', 'L4', 'Line 4');
INSERT INTO core.sku (id, code, name, customer) VALUES
    ('33333333-0000-7000-8000-000000000001', 'PNL-220', 'Door panel 220', 'Customer J'),
    ('33333333-0000-7000-8000-000000000002', 'PNL-240', 'Door panel 240', 'Customer J');
INSERT INTO core.machine (id, line_id, code, name, machine_type) VALUES
    ('44444444-0000-7000-8000-000000000041', '22222222-0000-7000-8000-000000000004', 'M-41', 'Press 41', 'press'),
    ('44444444-0000-7000-8000-000000000042', '22222222-0000-7000-8000-000000000004', 'M-42', 'Press 42', 'press');
INSERT INTO core.defect_type (id, code, name_th, name_ja, name_en, category, is_critical) VALUES
    ('55555555-0000-7000-8000-000000000001', 'SCR', 'รอยขีดข่วน', 'キズ', 'Scratch', 'surface', false),
    ('55555555-0000-7000-8000-000000000002', 'FLS', 'ครีบ', 'バリ', 'Flash', 'dimensional', false);
INSERT INTO core.material_lot (id, lot_code, material_code, supplier, received_at) VALUES
    ('66666666-0000-7000-8000-000000000101', 'LOT-2609-101', 'SPCC-10', 'Siam Steel', '2026-09-01 08:00+07'),
    ('66666666-0000-7000-8000-000000000108', 'LOT-2609-108', 'SPCC-10', 'Siam Steel', '2026-09-05 08:00+07'),
    ('66666666-0000-7000-8000-000000000114', 'LOT-2609-114', 'SPCC-10', 'Siam Steel', '2026-09-08 09:00+07');
INSERT INTO quality.mould (id, code, cavities, material_spec, last_maintenance) VALUES
    ('77777777-0000-7000-8000-000000000012', 'M-12', 2, 'SPCC-10', '2026-07-08 10:00+07'),     -- 62 days before 2026-09-08 (plan: 45)
    ('77777777-0000-7000-8000-000000000013', 'M-13', 2, 'SPCC-10', '2026-08-20 10:00+07'),
    ('77777777-0000-7000-8000-000000000014', 'M-14', 2, 'SPCC-10', '2026-08-25 10:00+07');
INSERT INTO core.app_user (id, username, display_name, email, role, lang) VALUES
    ('aaaaaaaa-0000-7000-8000-000000000001', 'nattaya', 'Nattaya (quality engineer)',    'nattaya@example.co.th', 'engineer',  'th'),
    ('aaaaaaaa-0000-7000-8000-000000000002', 'somsak',  'Somsak (QC supervisor)',        'somsak@example.co.th',  'inspector', 'th'),
    ('aaaaaaaa-0000-7000-8000-000000000003', 'kenji',   'Kenji (production engineer)',   'kenji@example.co.jp',   'engineer',  'ja'),
    ('aaaaaaaa-0000-7000-8000-000000000004', 'yuki',    'Yuki (quality manager)',        'yuki@example.co.jp',    'manager',   'ja'),
    ('aaaaaaaa-0000-7000-8000-000000000005', 'admin',   'QE-Agent admin',                'admin@example.co.th',   'admin',     'en'),
    ('aaaaaaaa-0000-7000-8000-000000000006', 'viewer',  'Customer QA (read-only)',       'cqa@example.com',       'viewer',    'en');

-- ---------------------------------------------------------------------
-- 2. Configuration: ranking, FMEA standard + criteria, prompts, glossary
-- ---------------------------------------------------------------------
INSERT INTO quality.ranking_config (version, weights_json, min_sample, baseline_days, active, set_by)
VALUES ('2026-09', '{"impact": 0.35, "criticality": 0.25, "volume": 0.20, "slope": 0.20}', 50, '{7,30}', true, 'aaaaaaaa-0000-7000-8000-000000000005');
INSERT INTO quality.fmea_config (standard, ap_table_json, active, set_by)
VALUES ('aiag_vda_ap', '{"7-4-5": "M", "8-5-6": "H", "7-4-2": "L", "9-6-7": "H", "5-3-4": "L"}', true, 'aaaaaaaa-0000-7000-8000-000000000005');
INSERT INTO quality.sod_criteria (id, standard, dimension, rating, criteria_text)
SELECT ('5c000000-0000-7000-8000-' || lpad(((CASE d.dim WHEN 'S' THEN 100 WHEN 'O' THEN 200 ELSE 300 END) + r)::text, 12, '0'))::uuid, 'aiag_vda_ap', d.dim, r,   -- decimal digits are valid hex: S7 = …000107, O4 = …000204, D5 = …000305
       CASE d.dim WHEN 'S' THEN (ARRAY['no effect','very minor','minor','moderate, no loss of function','moderate, degraded','significant, loss of secondary function','high, loss of primary function','very high, safety with warning','extreme, safety without warning','catastrophic'])[r]
                  WHEN 'O' THEN (ARRAY['< 0.001 per 1000','0.01 per 1000','0.1 per 1000','0.5 per 1000','2 per 1000','5 per 1000','10 per 1000','20 per 1000','50 per 1000','> 100 per 1000'])[r]
                  ELSE (ARRAY['error prevented','detection at source, automatic','detection at source','detection in station, automatic','detection in station','detection downstream, automatic','detection downstream','detection at final inspection','detection by chance','no detection'])[r] END
  FROM (VALUES ('S'), ('O'), ('D')) AS d(dim) CROSS JOIN generate_series(1, 10) r;
INSERT INTO quality.prompt_template (id, kind, lang, version, path, checksum, temperature, active) VALUES
    ('7e000000-0000-7000-8000-000000000001', 'five_why', 'en', 'v1', 'deploy/prompts/five_why.en.v1.md', 'sha256:5why-en-v1', 0.2, true),
    ('7e000000-0000-7000-8000-000000000002', 'eight_d',  'en', 'v1', 'deploy/prompts/eight_d.en.v1.md',  'sha256:8d-en-v1',   0.2, true),
    ('7e000000-0000-7000-8000-000000000003', 'report',   'ja', 'v1', 'deploy/prompts/report.ja.v1.md',   'sha256:rep-ja-v1',  0.2, true),
    ('7e000000-0000-7000-8000-000000000004', 'fmea',     'en', 'v1', 'deploy/prompts/fmea.en.v1.md',     'sha256:fmea-en-v1', 0.2, true);
INSERT INTO knowledge.glossary_term (id, ja, ja_reading, th, en, domain, forbidden_json, approved_by) VALUES
    ('91055a00-0000-7000-8000-000000000001', '不良率', 'ふりょうりつ', 'อัตราของเสีย', 'defect rate', 'quality', '["欠陥率"]', 'aaaaaaaa-0000-7000-8000-000000000004'),
    ('91055a00-0000-7000-8000-000000000002', '是正処置', 'ぜせいしょち', 'การแก้ไข', 'corrective action', 'quality', '["修正措置", "修正処置"]', 'aaaaaaaa-0000-7000-8000-000000000004'),
    ('91055a00-0000-7000-8000-000000000003', '水平展開', 'すいへいてんかい', 'การขยายผล', 'horizontal deployment', 'quality', '["横展開"]', 'aaaaaaaa-0000-7000-8000-000000000004');

-- ---------------------------------------------------------------------
-- 3. Characteristics, deterministic measurements, subgroups, limits (through the SQL twins), violations, capability
-- ---------------------------------------------------------------------
INSERT INTO quality.characteristic (id, sku_id, name, unit, usl, lsl, target, chart_type, subgroup_rule) VALUES
    ('c1000000-0000-7000-8000-000000000001', '33333333-0000-7000-8000-000000000001', 'panel thickness', 'mm', 2.60, 2.40, 2.50, 'xbar_r', '{"kind": "fixed_n", "n": 5}'),
    ('c1000000-0000-7000-8000-000000000002', '33333333-0000-7000-8000-000000000001', 'flash height',    'mm', 0.30, NULL, 0.00, 'x_mr',   '{"kind": "fixed_n", "n": 1}'),
    ('c1000000-0000-7000-8000-000000000003', '33333333-0000-7000-8000-000000000002', 'weld current',    'A',  110,  90,   100,  'x_mr',   '{"kind": "fixed_n", "n": 1}'),
    ('c1000000-0000-7000-8000-000000000004', '33333333-0000-7000-8000-000000000002', 'panel thickness', 'mm', 2.60, 2.40, 2.50, 'xbar_r', '{"kind": "fixed_n", "n": 5}');   -- same characteristic name on PNL-240 → horizontal candidate (FR-30)
INSERT INTO quality.rule_config (characteristic_id, enabled_rules, updated_by) VALUES
    ('c1000000-0000-7000-8000-000000000001', '{1,2,3,5,6}', 'aaaaaaaa-0000-7000-8000-000000000005'),
    ('c1000000-0000-7000-8000-000000000003', '{1,2,3,4,5,6,7,8}', 'aaaaaaaa-0000-7000-8000-000000000005');

-- C1: 25 subgroups × 5, deterministic formula (Python reference recomputes everything from this formula, TC-005)
INSERT INTO quality.subgroup (id, characteristic_id, line_id, seq, ts_from, ts_to, n, mean, range, sd)
SELECT ('5b000000-0000-7000-8000-' || lpad(to_hex(seq), 12, '0'))::uuid, 'c1000000-0000-7000-8000-000000000001', '22222222-0000-7000-8000-000000000004', seq,
       timestamptz '2026-08-01 08:00+07' + (seq - 1) * interval '1 day', timestamptz '2026-08-01 08:00+07' + (seq - 1) * interval '1 day' + interval '1 hour', 5, 0, 0, 0
  FROM generate_series(1, 25) seq;
INSERT INTO quality.measurement (ts, characteristic_id, line_id, subgroup_id, value, lot_id, machine_id, shift, source)
SELECT timestamptz '2026-08-01 08:00+07' + (seq - 1) * interval '1 day' + (k - 1) * interval '10 minutes', 'c1000000-0000-7000-8000-000000000001', '22222222-0000-7000-8000-000000000004',
       ('5b000000-0000-7000-8000-' || lpad(to_hex(seq), 12, '0'))::uuid,
       round((2.500 + 0.020 * sin(1.3 * seq + 0.7 * k) + 0.005 * cos(2.1 * k))::numeric, 5),
       '66666666-0000-7000-8000-000000000101', CASE WHEN seq % 2 = 0 THEN '44444444-0000-7000-8000-000000000041' ELSE '44444444-0000-7000-8000-000000000042' END, 'A', 'inspection'
  FROM generate_series(1, 25) seq CROSS JOIN generate_series(1, 5) k;
UPDATE quality.subgroup sg SET mean = m.mean, range = m.range, sd = m.sd
  FROM (SELECT subgroup_id, round(avg(value), 5) AS mean, round(max(value) - min(value), 5) AS range, round(stddev_samp(value), 6) AS sd FROM quality.measurement GROUP BY subgroup_id) m
 WHERE sg.id = m.subgroup_id;

-- limits from the baseline (all 25 subgroups) through quality.xbar_r_limits(); an earlier provisional row first, then the recalculation (FR-06)
INSERT INTO quality.control_limits (id, characteristic_id, line_id, ucl, cl, lcl, baseline_from, baseline_to, sample_size, reason, created_by, active)
VALUES ('c1111111-0000-7000-8000-000000000001', 'c1000000-0000-7000-8000-000000000001', '22222222-0000-7000-8000-000000000004', 2.5400, 2.5000, 2.4600,
        '2026-07-01', '2026-07-31', 100, 'provisional limits from July trial data', 'aaaaaaaa-0000-7000-8000-000000000001', true);
INSERT INTO quality.control_limits (id, characteristic_id, line_id, ucl, cl, lcl, baseline_from, baseline_to, sample_size, reason, created_by, active)
SELECT 'c1111111-0000-7000-8000-000000000002', 'c1000000-0000-7000-8000-000000000001', '22222222-0000-7000-8000-000000000004', l.ucl_x, l.cl_x, l.lcl_x,
       '2026-08-01 08:00+07', '2026-08-25 09:00+07', 125, 'baseline August 2026: 25 subgroups of 5 after the July setup change', 'aaaaaaaa-0000-7000-8000-000000000001', true
  FROM (SELECT avg(mean) xbb, avg(range) rb FROM quality.subgroup WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000001') b
  CROSS JOIN LATERAL quality.xbar_r_limits(b.xbb, b.rb, 5) l;
-- C3 limits: CL 100, sigma 2 (X-mR twin: fixed for the constructed series)
INSERT INTO quality.control_limits (id, characteristic_id, line_id, ucl, cl, lcl, baseline_from, baseline_to, sample_size, reason, created_by, active)
VALUES ('c1111111-0000-7000-8000-000000000003', 'c1000000-0000-7000-8000-000000000003', '22222222-0000-7000-8000-000000000002', 106, 100, 94,
        '2026-06-01', '2026-06-30', 200, 'X-mR baseline June 2026 (sigma 2.0)', 'aaaaaaaa-0000-7000-8000-000000000001', true);

-- capability C1 (normality ok) through capability_indices(); C2 non-normal with a method note (AC-03)
INSERT INTO quality.capability_result (id, characteristic_id, line_id, period_from, period_to, n, cp, cpk, pp, ppk, normality_p, normality_ok, method_note)
SELECT 'ca000000-0000-7000-8000-000000000001', 'c1000000-0000-7000-8000-000000000001', '22222222-0000-7000-8000-000000000004', '2026-08-01 08:00+07', '2026-08-25 09:00+07', 125,
       c.cp, c.cpk, c.pp, c.ppk, 0.42, true, 'Anderson–Darling p = 0.42 (engine); sd_within = R̄/d2, sd_overall = sample sd of 125 values'
  FROM (SELECT avg(value) mu, stddev_samp(value) sdo FROM quality.measurement WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000001') s
  CROSS JOIN (SELECT avg(range) rb FROM quality.subgroup WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000001') b
  CROSS JOIN LATERAL quality.capability_indices(s.mu, b.rb / quality.spc_constant(5, 'd2'), s.sdo, 2.60, 2.40) c;
INSERT INTO quality.capability_result (id, characteristic_id, line_id, period_from, period_to, n, cp, cpk, pp, ppk, normality_p, normality_ok, method_note)
VALUES ('ca000000-0000-7000-8000-000000000002', 'c1000000-0000-7000-8000-000000000002', '22222222-0000-7000-8000-000000000004', '2026-08-01', '2026-08-31', 310,
        NULL, NULL, NULL, 1.08, 0.003, false, 'Anderson–Darling p = 0.003: non-normal (one-sided, bounded at 0). Box-Cox λ = 0.2 recommended; percentile-based Ppk 1.08 reported instead of Cpk (FR-05)');

-- C3: the constructed Nelson series (40 points) → measurements, then violations THROUGH quality.nelson_rules() (AC-02)
INSERT INTO quality.measurement (ts, characteristic_id, line_id, value, machine_id, shift, source)
SELECT timestamptz '2026-09-01 08:00+07' + (i - 1) * interval '30 minutes', 'c1000000-0000-7000-8000-000000000003', '22222222-0000-7000-8000-000000000002', v, NULL, 'A', 'gauge'
  FROM unnest(ARRAY[100.2, 99.4, 100.8, 99.1, 107.5, 100.3, 99.6, 100.9, 98.8, 100.6, 101.1, 100.8, 101.5, 100.9, 101.7, 100.4, 101.2, 101.8, 99.5, 98.0,
                    99.0, 100.0, 101.0, 102.0, 103.0, 100.1, 99.7, 104.5, 104.8, 101.0, 99.8, 100.4, 102.5, 102.6, 100.5, 102.8, 102.9, 99.9, 100.2, 99.6]::numeric[]) WITH ORDINALITY AS t(v, i);
INSERT INTO quality.spc_violation (characteristic_id, line_id, ts, rule, points_json, severity)
SELECT 'c1000000-0000-7000-8000-000000000003', '22222222-0000-7000-8000-000000000002',
       timestamptz '2026-09-01 08:00+07' + (r.points[array_length(r.points, 1)] - 1) * interval '30 minutes', r.rule, to_jsonb(r.points),
       CASE WHEN r.rule = 1 THEN 'HIGH' ELSE 'MEDIUM' END::quality.severity
  FROM (SELECT array_agg(value ORDER BY ts) vals FROM quality.measurement WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000003') s
  CROSS JOIN LATERAL quality.nelson_rules(s.vals, 100, 2) r;

-- ---------------------------------------------------------------------
-- 4. Timeline events, trial run, signals (S-241 Appendix A; S-242 below minimum sample; S-243 inside a trial run; S-230 older)
-- ---------------------------------------------------------------------
INSERT INTO quality.timeline_event (id, ts, line_id, machine_id, mould_id, kind, detail_json) VALUES
    ('7e110000-0000-7000-8000-000000000001', '2026-09-08 14:12+07', '22222222-0000-7000-8000-000000000004', NULL, NULL, 'lot_change', '{"lot": "LOT-2609-114", "previous": "LOT-2609-108"}'),
    ('7e110000-0000-7000-8000-000000000002', '2026-07-08 10:00+07', '22222222-0000-7000-8000-000000000004', NULL, '77777777-0000-7000-8000-000000000012', 'maintenance', '{"action": "cavity polish", "plan_interval_days": 45}'),
    ('7e110000-0000-7000-8000-000000000003', '2026-09-07 06:00+07', '22222222-0000-7000-8000-000000000004', '44444444-0000-7000-8000-000000000041', NULL, 'startup', '{"after": "weekend"}');
INSERT INTO quality.trial_run (id, line_id, sku_id, ts_from, ts_to, reason, declared_by)
VALUES ('7a000000-0000-7000-8000-000000000001', '22222222-0000-7000-8000-000000000004', '33333333-0000-7000-8000-000000000001', '2026-09-12 08:00+07', '2026-09-12 12:00+07', 'new gate design trial', 'aaaaaaaa-0000-7000-8000-000000000003');

-- S-241: statistic through two_proportion_z(70, 2200, 80, 15400); score through ranking_score()
INSERT INTO quality.signal (id, opened_at, kind, line_id, sku_id, defect_code, scope_json, statistic_json, severity, status, score, rank_components)
SELECT '51000000-0000-7000-8000-000000000241', '2026-09-09 06:00+07', 'defect_rate_shift', '22222222-0000-7000-8000-000000000004', '33333333-0000-7000-8000-000000000001', 'SCR',
       '{"window": "2026-09-08T06:00+07/2026-09-09T06:00+07", "baseline": "30d"}',
       jsonb_build_object('n', 2200, 'x', 70, 'rate', t.p1, 'baseline_n', 15400, 'baseline_x', 80, 'baseline_rate', t.p2, 'test', 'two_proportion_z', 'z', t.z, 'p_value', t.p_value),
       'HIGH', 'open', quality.ranking_score(0.6, 0.4, 0.35, 0.9), '{"impact": 0.6, "criticality": 0.4, "volume": 0.35, "slope": 0.9}'
  FROM quality.two_proportion_z(70, 2200, 80, 15400) t;
INSERT INTO quality.change_point (signal_id, estimated_ts, window_minutes, method, statistic_json)
VALUES ('51000000-0000-7000-8000-000000000241', '2026-09-08 14:20+07', 40, 'cusum+binseg', '{"cusum_max": 38.2, "binseg_cost_drop": 0.61, "hourly_points": 48}');
-- S-242: n = 25 → dismissed by trg_signal_admissible (FR-11)
INSERT INTO quality.signal (id, opened_at, kind, line_id, sku_id, defect_code, statistic_json, severity, status)
VALUES ('51000000-0000-7000-8000-000000000242', '2026-09-09 06:00+07', 'defect_rate_shift', '22222222-0000-7000-8000-000000000001', '33333333-0000-7000-8000-000000000002', 'FLS', '{"n": 25, "x": 3, "rate": 0.12}', 'LOW', 'open');
-- S-243: inside the declared trial → dismissed
INSERT INTO quality.signal (id, opened_at, kind, line_id, sku_id, defect_code, statistic_json, severity, status)
VALUES ('51000000-0000-7000-8000-000000000243', '2026-09-12 09:00+07', 'defect_rate_shift', '22222222-0000-7000-8000-000000000004', '33333333-0000-7000-8000-000000000001', 'FLS', '{"n": 400, "x": 20, "rate": 0.05}', 'MEDIUM', 'open');
-- S-230: the older scratch signal on Line 2 (case QC-0230, closed in §8)
INSERT INTO quality.signal (id, opened_at, kind, line_id, sku_id, defect_code, statistic_json, severity, status, score, closed_at)
VALUES ('51000000-0000-7000-8000-000000000230', '2026-08-12 06:00+07', 'defect_rate_shift', '22222222-0000-7000-8000-000000000002', '33333333-0000-7000-8000-000000000001', 'SCR',
        '{"n": 2600, "x": 41, "rate": 0.0158, "baseline_rate": 0.0060, "p_value": 0.00002}', 'HIGH', 'case_opened', 0.48, '2026-09-05');

-- ---------------------------------------------------------------------
-- 5. Case QC-0241: analysis run, correlation tests, EVIDENCE, hypotheses (Appendix A)
-- ---------------------------------------------------------------------
INSERT INTO quality.case (id, signal_id, title, line_id, sku_id, severity, status, owner_id, opened_at)
VALUES ('ca5e0000-0000-7000-8000-000000000241', '51000000-0000-7000-8000-000000000241', 'QC-0241 Scratch rise on Line 4 (PNL-220)', '22222222-0000-7000-8000-000000000004', '33333333-0000-7000-8000-000000000001', 'HIGH', 'analysis', 'aaaaaaaa-0000-7000-8000-000000000001', '2026-09-09 06:01+07');
UPDATE quality.signal SET status = 'case_opened', owner_id = 'aaaaaaaa-0000-7000-8000-000000000001' WHERE id = '51000000-0000-7000-8000-000000000241';
INSERT INTO quality.escalation (case_id, signal_id, kind, channel, recipient, sent_at) VALUES ('ca5e0000-0000-7000-8000-000000000241', '51000000-0000-7000-8000-000000000241', 'high_signal', 'discord', '#quality-signals', '2026-09-09 06:01+07');

INSERT INTO quality.analysis_run (id, case_id, signal_id, mode, llm_available, model_version, prompt_version, started_at, finished_at, duration_ms, tests_run, hypotheses, artifacts)
VALUES ('a0000000-0000-7000-8000-000000000241', 'ca5e0000-0000-7000-8000-000000000241', '51000000-0000-7000-8000-000000000241', 'full', true, 'qwen2.5:7b-instruct-q4_K_M', 'p-2026.09', '2026-09-09 08:00:00+07', '2026-09-09 08:00:18.4+07', 18400, 7, 3, 2);

-- correlation tests (statistics as the engine writes them; p-values re-derived in TC-005; BH adjusted over the 7 tests)
INSERT INTO quality.correlation_test (id, signal_id, case_id, run_id, factor, level, test, statistic, p_value, p_adjusted, effect_measure, effect_size, ci_low, ci_high, n, table_json, meaningful) VALUES
    ('c0110000-0000-7000-8000-000000000001', '51000000-0000-7000-8000-000000000241', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 'material_lot', 'LOT-2609-114', 'fisher_exact', NULL, 0.0000000067, 0.0000000470, 'risk_ratio', 7.6667, 3.31, 17.76, 1880, '{"lot": [46, 940], "others": [6, 940]}', true),
    ('c0110000-0000-7000-8000-000000000002', '51000000-0000-7000-8000-000000000241', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 'mould', 'M-12', 'two_proportion', 3.3386, 0.0008420, 0.0029470, 'rate_ratio', 2.1017, 1.37, 3.22, 5950, '{"M-12": [62, 2950], "others": [30, 3000], "window_days": 30}', true),
    ('c0110000-0000-7000-8000-000000000003', '51000000-0000-7000-8000-000000000241', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 'shift', 'B', 'two_proportion', 1.1954, 0.2319, 0.5411, 'risk_ratio', 1.3949, 0.85, 2.29, 2200, '{"B": [48, 1342], "others": [22, 858], "defect_share_B": 0.686, "volume_share_B": 0.61}', false),
    ('c0110000-0000-7000-8000-000000000004', '51000000-0000-7000-8000-000000000241', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 'machine', 'M-41', 'two_proportion', 0.1215, 0.9033, 1.0000, 'risk_ratio', 1.0588, 0.67, 1.68, 2200, '{"M-41": [36, 1100], "M-42": [34, 1100]}', false),
    ('c0110000-0000-7000-8000-000000000005', '51000000-0000-7000-8000-000000000241', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 'operator_group', 'G2', 'two_proportion', 0.6074, 0.5436, 0.9513, 'risk_ratio', 1.1875, 0.75, 1.88, 2200, '{"G2": [38, 1100], "G1": [32, 1100]}', false),
    ('c0110000-0000-7000-8000-000000000006', '51000000-0000-7000-8000-000000000241', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 'ambient', '>30C', 'rate_ratio', NULL, 0.7100, 0.9940, 'rate_ratio', 1.0500, 0.66, 1.67, 2200, '{"hot_hours": [37, 1150], "other_hours": [33, 1050]}', false),
    ('c0110000-0000-7000-8000-000000000007', '51000000-0000-7000-8000-000000000241', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 'parameter_change', NULL, 'rate_ratio', NULL, 1.0000, 1.0000, 'rate_ratio', 1.0000, NULL, NULL, 2200, '{"parameter_edits_in_window": 0}', false);

-- the evidence registry for the case (digest computed in SQL; TC-005 recomputes it)
INSERT INTO quality.evidence (id, case_id, signal_id, code, kind, value_json, source_query, source_ref, digest)
SELECT ('e0000000-0000-7000-8000-' || lpad(to_hex(n), 12, '0'))::uuid, 'ca5e0000-0000-7000-8000-000000000241', '51000000-0000-7000-8000-000000000241', 'E-' || lpad(n::text, 2, '0'), kind::quality.evidence_kind, v::jsonb, q, ref,
       encode(public.digest(v::jsonb::text, 'sha256'), 'hex')
  FROM (VALUES
    (1,  'test',         '{"defect": "SCR", "line": "L4", "rate_now_pct": 3.18, "rate_baseline_pct": 0.52, "x": 70, "n": 2200, "baseline_x": 80, "baseline_n": 15400, "test": "two_proportion_z", "p_value_lt": 0.001}', 'signal 51000000-…-241 statistic_json', 'signal:S-241'),
    (2,  'change_point', '{"estimated_ts": "2026-09-08T14:20:00+07:00", "window_minutes": 40, "method": "cusum+binseg"}', 'change_point for S-241', 'change_point'),
    (3,  'query',        '{"baseline_days": 30, "baseline_rate_pct": 0.52, "baseline_n": 15400}', 'SELECT … FROM core.defect_fact WHERE line = L4 AND ts >= now() - 30d', 'defect_fact'),
    (4,  'correlation',  '{"factor": "material_lot", "level": "LOT-2609-114", "rate_lot_pct": 4.89, "rate_others_pct": 0.64, "n": 1880, "test": "fisher_exact", "p_value_lt": 0.001, "risk_ratio": 7.67}', 'correlation_test c0110000-…-001', 'c0110000-0000-7000-8000-000000000001'),
    (5,  'timeline',     '{"event": "lot_change", "ts": "2026-09-08T14:12:00+07:00", "lot": "LOT-2609-114"}', 'timeline_event 7e110000-…-001', '7e110000-0000-7000-8000-000000000001'),
    (6,  'query',        '{"incoming_inspection": "LOT-2609-114", "result": "no abnormality recorded"}', 'SELECT … FROM docflow/inspection certificate', 'incoming_inspection'),
    (7,  'timeline',     '{"mould": "M-12", "last_polish": "2026-07-08", "days_since": 62, "plan_interval_days": 45}', 'timeline_event 7e110000-…-002; quality.mould.last_maintenance', '7e110000-0000-7000-8000-000000000002'),
    (8,  'correlation',  '{"factor": "mould", "level": "M-12", "rate_ratio": 2.1, "window_days": 30, "p_value": 0.000842}', 'correlation_test c0110000-…-002', 'c0110000-0000-7000-8000-000000000002'),
    (9,  'correlation',  '{"factor": "shift", "level": "B", "defect_share_pct": 68, "volume_share_pct": 61, "risk_ratio": 1.39, "p_value": 0.2319, "meaningful": false}', 'correlation_test c0110000-…-003', 'c0110000-0000-7000-8000-000000000003'),
    (10, 'query',        '{"multiple_comparison": "Benjamini-Hochberg over 7 factors", "surviving": ["material_lot", "mould"]}', 'correlator BH step', 'bh'),
    (11, 'correlation',  '{"no_meaningful_association": ["machine", "operator_group", "ambient", "parameter_change"]}', 'correlation_test c0110000-…-004..007', 'c0110000-0000-7000-8000-000000000004'),
    (12, 'case',         '{"case": "#212", "date": "2025-03", "summary": "material contamination", "outcome": "confirmed", "similarity": 0.83}', 'search_memory(scratch line 4 lot change)', 'case_record:#212'),
    (13, 'case',         '{"case": "#178", "date": "2024-11", "summary": "mould polish overdue", "outcome": "confirmed", "similarity": 0.71}', 'search_memory(scratch mould polish)', 'case_record:#178'),
    (14, 'timeline',     '{"action": "corrective", "planned_ts": "2026-09-09", "description": "replace the lot; re-polish M-12"}', 'quality.action planned for QC-0241', 'action')
  ) AS e(n, kind, v, q, ref);

INSERT INTO quality.hypothesis (id, case_id, run_id, rank, statement, score, factor, level, effect_size, p_adjusted, verify_step, status, evidence_json, contra_json) VALUES
    ('a1000000-0000-7000-8000-000000000001', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 1,
     'Material lot change to LOT-2609-114 at 14:12 coincides with the rise — hypothesis to verify: surface condition of the incoming coil', 0.71, 'material_lot', 'LOT-2609-114', 7.6667, 0.0000000470,
     'Re-inspect the retained sample of LOT-2609-114 for surface condition (incoming inspection recorded no abnormality)', 'proposed', '["E-04", "E-05", "E-12"]', '["E-06"]'),
    ('a1000000-0000-7000-8000-000000000002', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 2,
     'Mould M-12 cavity surface condition (polish 62 days ago, plan 45) — hypothesis to verify', 0.38, 'mould', 'M-12', 2.1017, 0.0029470,
     'Inspect mould M-12 cavity surface for wear and scoring', 'proposed', '["E-07", "E-08", "E-13"]', '["E-02"]'),
    ('a1000000-0000-7000-8000-000000000003', 'ca5e0000-0000-7000-8000-000000000241', 'a0000000-0000-7000-8000-000000000241', 3,
     'Shift B part handling at the unload station — hypothesis to verify (weak: Shift B also ran 61 % of the volume)', 0.19, 'shift', 'B', 1.3949, 0.5411,
     'Observe part handling at the unload station on Shift B', 'proposed', '["E-09"]', '["E-09", "E-10"]');
INSERT INTO quality.hypothesis_evidence (hypothesis_id, evidence_id, role) VALUES
    ('a1000000-0000-7000-8000-000000000001', 'e0000000-0000-7000-8000-000000000004', 'supporting'), ('a1000000-0000-7000-8000-000000000001', 'e0000000-0000-7000-8000-000000000005', 'supporting'),
    ('a1000000-0000-7000-8000-000000000001', 'e0000000-0000-7000-8000-00000000000c', 'supporting'), ('a1000000-0000-7000-8000-000000000001', 'e0000000-0000-7000-8000-000000000006', 'contra'),
    ('a1000000-0000-7000-8000-000000000002', 'e0000000-0000-7000-8000-000000000007', 'supporting'), ('a1000000-0000-7000-8000-000000000002', 'e0000000-0000-7000-8000-000000000008', 'supporting'),
    ('a1000000-0000-7000-8000-000000000002', 'e0000000-0000-7000-8000-000000000002', 'contra'),
    ('a1000000-0000-7000-8000-000000000003', 'e0000000-0000-7000-8000-000000000009', 'supporting'), ('a1000000-0000-7000-8000-000000000003', 'e0000000-0000-7000-8000-000000000009', 'contra');

-- past cases in the knowledge base (#212, #178) — retrieved as E-12 / E-13
INSERT INTO knowledge.case_record (id, title, opened_at, closed_at, scope_json, symptom_text, cause_text, action_text, verification_text, outcome, verified_by, verified_at, extracted_by) VALUES
    ('c0de0000-0000-7000-8000-000000000212', '#212 Scratch on door panels after lot change', '2025-03-04', '2025-03-20', '{"line": "L4", "sku": "PNL-220"}', 'scratch rate 0.5 % → 2.9 %', 'material contamination (oil residue on incoming coil, lot LOT-2503-071)', 'lot quarantined; supplier cleaning process corrected', '2.9 % → 0.4 % (p < 0.001)', 'resolved', 'aaaaaaaa-0000-7000-8000-000000000001', '2025-03-21', 'qe-agent/closure'),
    ('c0de0000-0000-7000-8000-000000000178', '#178 Scratch on PNL-240 Line 2', '2024-11-02', '2024-11-18', '{"line": "L2", "sku": "PNL-240"}', 'scratch rate 0.6 % → 1.8 %', 'mould polish overdue (M-13, 70 days)', 'polish schedule shortened to 45 days', '1.8 % → 0.5 % (p < 0.001)', 'resolved', 'aaaaaaaa-0000-7000-8000-000000000001', '2024-11-19', 'qe-agent/closure');

-- ---------------------------------------------------------------------
-- 6. Artefacts: A1 8D (traced, approved after verification), A2 5-Why (untraced number), A3 JA report (term check), A4 FMEA
-- ---------------------------------------------------------------------
INSERT INTO quality.artifact (id, case_id, kind, version, lang, content_json, ai_generated, prompt_version, prompt_template_id, run_id, facts_digest) VALUES
    ('a7000000-0000-7000-8000-000000000001', 'ca5e0000-0000-7000-8000-000000000241', 'eight_d', 1, 'en',
     '{"D1": "Team: Nattaya (QE), Kenji (PE), Somsak (QC)", "D2": "Scratch defects on PNL-220 Line 4 rose from 0.52 % to 3.18 % in the 24 h from 2026-09-08 (n = 2,200; p < 0.001).", "D3": "Containment: 100 % visual sort of stock produced since 2026-09-08 14:00; lot LOT-2609-114 quarantined.", "D4": "Hypothesis to verify: the lot change to LOT-2609-114 at 14:12 coincides with the change point 2026-09-08 14:20 (± 40 min); the lot shows 4.89 % vs 0.64 % on other lots (n = 1,880, Fisher p < 0.001, RR 7.67). Mould M-12 (polished 62 days ago, plan 45; 2.1× other moulds) is the second hypothesis.", "D5": "Corrective action: replace the lot; re-polish M-12.", "D6": "Implementation: 2026-09-09.", "D7": "Prevention: add incoming surface inspection for SPCC-10 coils; 45-day polish schedule enforced.", "D8": "Closure: pending effectiveness verification."}',
     true, 'eight_d.en.v1', '7e000000-0000-7000-8000-000000000002', 'a0000000-0000-7000-8000-000000000241', 'sha256:facts-0241-v1'),
    ('a7000000-0000-7000-8000-000000000002', 'ca5e0000-0000-7000-8000-000000000241', 'five_why', 1, 'en',
     '{"why1": "Scratches rose to 3.18 % after 2026-09-08 14:20.", "why2": "Hypothesis to verify: parts from LOT-2609-114 scratch (4.89 % vs 0.64 %).", "why3": "Hypothesis to verify: coil surface carries residue.", "why4": "Incoming inspection recorded no abnormality.", "why5": "After the lot was replaced the rate fell to 0.3 %."}',
     true, 'five_why.en.v1', '7e000000-0000-7000-8000-000000000001', 'a0000000-0000-7000-8000-000000000241', 'sha256:facts-0241-v1'),
    ('a7000000-0000-7000-8000-000000000003', 'ca5e0000-0000-7000-8000-000000000241', 'report', 1, 'ja',
     '{"現象": "ライン4 PNL-220 のキズ不良率が 0.52 % から 3.18 % に上昇（n = 2,200、p < 0.001）。", "原因": "検証中の仮説: 材料ロット LOT-2609-114 への切替（14:12）と変化点 14:20 が一致。", "対策": "暫定修正措置: ロット隔離、全数選別。", "効果確認": "対策後の不良率で検証予定。", "水平展開": "ライン3 の同一 SKU を確認。"}',
     true, 'report.ja.v1', '7e000000-0000-7000-8000-000000000003', 'a0000000-0000-7000-8000-000000000241', 'sha256:facts-0241-v1'),
    ('a7000000-0000-7000-8000-000000000004', 'ca5e0000-0000-7000-8000-000000000241', 'fmea', 1, 'en',
     '{"rows": [{"process_step": "coil unloading", "failure_mode": "surface scratch", "effect": "visible defect, customer rejection", "cause": "residue on incoming coil", "s": 7, "o": 4, "d": 5}]}',
     true, 'fmea.en.v1', '7e000000-0000-7000-8000-000000000004', 'a0000000-0000-7000-8000-000000000241', 'sha256:facts-0241-v1');
INSERT INTO quality.artifact_revision (artifact_id, revision, content_json, edited_by) SELECT id, 1, content_json, NULL FROM quality.artifact;

-- A1 claims (12): numbers → evidence; the D4 causal-free wording is 'other'; the D4 hypothesis claim is 'causal' and traced only once H1 is confirmed
INSERT INTO quality.artifact_claim (artifact_id, ordinal, section, sentence, kind, evidence_id, hypothesis_id) VALUES
    ('a7000000-0000-7000-8000-000000000001', 1,  'D2', 'rose from 0.52 % to 3.18 %', 'numeric', 'e0000000-0000-7000-8000-000000000001', NULL),
    ('a7000000-0000-7000-8000-000000000001', 2,  'D2', 'in the 24 h from 2026-09-08', 'date', 'e0000000-0000-7000-8000-000000000001', NULL),
    ('a7000000-0000-7000-8000-000000000001', 3,  'D2', 'n = 2,200; p < 0.001', 'count', 'e0000000-0000-7000-8000-000000000001', NULL),
    ('a7000000-0000-7000-8000-000000000001', 4,  'D3', 'stock produced since 2026-09-08 14:00', 'date', 'e0000000-0000-7000-8000-000000000002', NULL),
    ('a7000000-0000-7000-8000-000000000001', 5,  'D4', 'the lot change to LOT-2609-114 at 14:12', 'date', 'e0000000-0000-7000-8000-000000000005', NULL),
    ('a7000000-0000-7000-8000-000000000001', 6,  'D4', 'change point 2026-09-08 14:20 (± 40 min)', 'date', 'e0000000-0000-7000-8000-000000000002', NULL),
    ('a7000000-0000-7000-8000-000000000001', 7,  'D4', '4.89 % vs 0.64 % on other lots', 'numeric', 'e0000000-0000-7000-8000-000000000004', NULL),
    ('a7000000-0000-7000-8000-000000000001', 8,  'D4', 'n = 1,880, Fisher p < 0.001, RR 7.67', 'count', 'e0000000-0000-7000-8000-000000000004', NULL),
    ('a7000000-0000-7000-8000-000000000001', 9,  'D4', 'polished 62 days ago, plan 45', 'count', 'e0000000-0000-7000-8000-000000000007', NULL),
    ('a7000000-0000-7000-8000-000000000001', 10, 'D4', '2.1× other moulds', 'numeric', 'e0000000-0000-7000-8000-000000000008', NULL),
    ('a7000000-0000-7000-8000-000000000001', 11, 'D4', 'the lot change … coincides with the change point (hypothesis)', 'causal', NULL, 'a1000000-0000-7000-8000-000000000001'),
    ('a7000000-0000-7000-8000-000000000001', 12, 'D6', 'Implementation: 2026-09-09', 'date', 'e0000000-0000-7000-8000-00000000000e', NULL);
-- A2 claims (5): the last one has no evidence → grounding failed (AC-05)
INSERT INTO quality.artifact_claim (artifact_id, ordinal, section, sentence, kind, evidence_id) VALUES
    ('a7000000-0000-7000-8000-000000000002', 1, 'why1', 'rose to 3.18 % after 2026-09-08 14:20', 'numeric', 'e0000000-0000-7000-8000-000000000001'),
    ('a7000000-0000-7000-8000-000000000002', 2, 'why1', 'after 2026-09-08 14:20', 'date', 'e0000000-0000-7000-8000-000000000002'),
    ('a7000000-0000-7000-8000-000000000002', 3, 'why2', '4.89 % vs 0.64 %', 'numeric', 'e0000000-0000-7000-8000-000000000004'),
    ('a7000000-0000-7000-8000-000000000002', 4, 'why4', 'Incoming inspection recorded no abnormality', 'other', 'e0000000-0000-7000-8000-000000000006'),
    ('a7000000-0000-7000-8000-000000000002', 5, 'why5', 'the rate fell to 0.3 %', 'numeric', NULL);
-- A3 claims (3) all traced; one glossary violation (修正措置 → 是正処置), resolved by the engineer after editing
INSERT INTO quality.artifact_claim (artifact_id, ordinal, section, sentence, kind, evidence_id) VALUES
    ('a7000000-0000-7000-8000-000000000003', 1, '現象', '0.52 % から 3.18 %', 'numeric', 'e0000000-0000-7000-8000-000000000001'),
    ('a7000000-0000-7000-8000-000000000003', 2, '現象', 'n = 2,200、p < 0.001', 'count', 'e0000000-0000-7000-8000-000000000001'),
    ('a7000000-0000-7000-8000-000000000003', 3, '原因', '切替（14:12）と変化点 14:20', 'date', 'e0000000-0000-7000-8000-000000000002');
INSERT INTO quality.term_check (artifact_id, term_id, found_text, expected_text, position) VALUES
    ('a7000000-0000-7000-8000-000000000003', '91055a00-0000-7000-8000-000000000002', '修正措置', '是正処置', 1);
-- A4 claims (3) traced
INSERT INTO quality.artifact_claim (artifact_id, ordinal, section, sentence, kind, evidence_id) VALUES
    ('a7000000-0000-7000-8000-000000000004', 1, 'row1', 'S 7: visible defect, customer rejection', 'other', NULL),
    ('a7000000-0000-7000-8000-000000000004', 2, 'row1', 'O 4: 4.89 % on the affected lot', 'numeric', 'e0000000-0000-7000-8000-000000000004'),
    ('a7000000-0000-7000-8000-000000000004', 3, 'row1', 'D 5: detected at final visual inspection', 'other', NULL);

-- the engineer verifies H1 (retained sample re-inspected: contamination confirmed) → the D4 causal claim becomes traceable
UPDATE quality.hypothesis SET status = 'verifying' WHERE id = 'a1000000-0000-7000-8000-000000000001';
UPDATE quality.hypothesis SET status = 'confirmed', verified_by = 'aaaaaaaa-0000-7000-8000-000000000001', verified_at = '2026-09-09 15:30+07',
       verify_result = 'Retained sample of LOT-2609-114 re-inspected: oil residue on the coil surface (photo IMG-2609-77); cause verified'
 WHERE id = 'a1000000-0000-7000-8000-000000000001';
UPDATE quality.artifact_claim SET hypothesis_id = hypothesis_id WHERE artifact_id = 'a7000000-0000-7000-8000-000000000001' AND kind = 'causal';   -- re-evaluates traced → passed
-- engineer edits D3 (revision 2 with diff), then approves A1 (role engineer, grounding passed) → audit; export APPROVED
INSERT INTO quality.artifact_revision (artifact_id, revision, content_json, diff_json, edited_by, note)
SELECT id, 2, content_json || '{"D3": "Containment: 100 % visual sort of stock produced since 2026-09-08 14:00; lot LOT-2609-114 quarantined; 2 pallets (1,200 pcs) returned from customer dock."}'::jsonb,
       '[{"path": "D3", "op": "replace", "from": "…quarantined.", "to": "…quarantined; 2 pallets (1,200 pcs) returned from customer dock."}]', 'aaaaaaaa-0000-7000-8000-000000000001', 'added the returned pallets'
  FROM quality.artifact WHERE id = 'a7000000-0000-7000-8000-000000000001';
UPDATE quality.artifact SET approved_by = 'aaaaaaaa-0000-7000-8000-000000000001', approved_at = '2026-09-09 16:00+07' WHERE id = 'a7000000-0000-7000-8000-000000000001';
INSERT INTO quality.export (artifact_id, format, template, uri, sha256, watermark, version_stamp, exported_by)
VALUES ('a7000000-0000-7000-8000-000000000001', 'docx', '8d.en.company-v3', 'exports/QC-0241/8D-v1.2.docx', 'sha256:8d-docx', 'APPROVED', 'pending', 'aaaaaaaa-0000-7000-8000-000000000001');
-- A2 stays a draft (grounding failed); its PDF export must carry the DRAFT watermark (AC-06)
INSERT INTO quality.export (artifact_id, format, template, uri, sha256, watermark, version_stamp, exported_by)
VALUES ('a7000000-0000-7000-8000-000000000002', 'pdf', '5why.en.company-v2', 'exports/QC-0241/5WHY-draft.pdf', 'sha256:5why-pdf', 'DRAFT — AI generated', 'pending', 'aaaaaaaa-0000-7000-8000-000000000001');
-- A3: the engineer fixes the term (revision) and resolves the check; still awaiting native review → exported as DRAFT
INSERT INTO quality.artifact_revision (artifact_id, revision, content_json, diff_json, edited_by, note)
SELECT id, 2, jsonb_set(content_json, '{対策}', '"暫定是正処置: ロット隔離、全数選別。"'), '[{"path": "対策", "op": "replace", "from": "修正措置", "to": "是正処置"}]', 'aaaaaaaa-0000-7000-8000-000000000003', 'glossary term'
  FROM quality.artifact WHERE id = 'a7000000-0000-7000-8000-000000000003';
UPDATE quality.term_check SET resolved = true WHERE artifact_id = 'a7000000-0000-7000-8000-000000000003';
INSERT INTO quality.export (artifact_id, format, template, uri, sha256, watermark, version_stamp, exported_by)
VALUES ('a7000000-0000-7000-8000-000000000003', 'docx', 'report.ja.company-v5', 'exports/QC-0241/品質報告書-draft.docx', 'sha256:rep-docx', 'DRAFT — AI generated', 'pending', 'aaaaaaaa-0000-7000-8000-000000000003');

-- FMEA proposal (AI-07): S 7 / O 4 / D 5 against criteria rows, each confirmed by the engineer → fmea_row (AP from the table)
INSERT INTO quality.fmea_proposal (id, case_id, artifact_id, sku_id, process_step, failure_mode, effect, cause, control_prev, control_det, s, o, d, s_criteria_id, o_criteria_id, d_criteria_id, o_evidence_id)
VALUES ('f0000000-0000-7000-8000-000000000001', 'ca5e0000-0000-7000-8000-000000000241', 'a7000000-0000-7000-8000-000000000004', '33333333-0000-7000-8000-000000000001',
        'coil unloading', 'surface scratch', 'visible defect, customer rejection', 'residue on incoming coil', 'supplier cleaning spec; incoming surface check', 'final visual inspection',
        7, 4, 5, '5c000000-0000-7000-8000-000000000107', '5c000000-0000-7000-8000-000000000204', '5c000000-0000-7000-8000-000000000305', 'e0000000-0000-7000-8000-000000000004');
UPDATE quality.fmea_proposal SET s_confirmed_by = 'aaaaaaaa-0000-7000-8000-000000000001', o_confirmed_by = 'aaaaaaaa-0000-7000-8000-000000000001', d_confirmed_by = 'aaaaaaaa-0000-7000-8000-000000000001'
 WHERE id = 'f0000000-0000-7000-8000-000000000001';
UPDATE quality.fmea_proposal SET status = 'confirmed' WHERE id = 'f0000000-0000-7000-8000-000000000001';
INSERT INTO quality.ocap_suggestion (case_id, characteristic_id, suggestion, evidence_id)
VALUES ('ca5e0000-0000-7000-8000-000000000241', 'c1000000-0000-7000-8000-000000000001', 'On a scratch signal above 1 % on Line 4: check the current coil lot and mould polish date before adjusting the press', 'e0000000-0000-7000-8000-000000000004');

-- ---------------------------------------------------------------------
-- 7. Actions and effectiveness on QC-0241 (AC-08 real improvement); case moves to action
-- ---------------------------------------------------------------------
INSERT INTO quality.action (id, case_id, kind, description, owner_id, due_date, status, applied_at) VALUES
    ('ac000000-0000-7000-8000-000000000001', 'ca5e0000-0000-7000-8000-000000000241', 'containment', '100 % visual sort of stock since 2026-09-08 14:00', 'aaaaaaaa-0000-7000-8000-000000000002', '2026-09-09', 'done', '2026-09-09 08:00+07'),
    ('ac000000-0000-7000-8000-000000000002', 'ca5e0000-0000-7000-8000-000000000241', 'corrective', 'Quarantine LOT-2609-114; re-polish mould M-12', 'aaaaaaaa-0000-7000-8000-000000000003', '2026-09-09', 'done', '2026-09-09 12:00+07'),
    ('ac000000-0000-7000-8000-000000000003', 'ca5e0000-0000-7000-8000-000000000241', 'preventive', 'Add incoming surface inspection for SPCC-10 coils', 'aaaaaaaa-0000-7000-8000-000000000001', '2026-10-01', 'open', NULL),
    ('ac000000-0000-7000-8000-000000000004', 'ca5e0000-0000-7000-8000-000000000241', 'horizontal', 'Check PNL-220 on Line 3 for the same lot', 'aaaaaaaa-0000-7000-8000-000000000002', '2026-09-12', 'in_progress', NULL);   -- overdue (FR-31)
INSERT INTO quality.effectiveness_check (action_id, before_from, before_to, before_x, before_n, after_from, after_to, after_x, after_n, test, z, p_value, rate_before, rate_after, improved)
SELECT 'ac000000-0000-7000-8000-000000000002', '2026-09-08 06:00+07', '2026-09-09 06:00+07', 70, 2200, '2026-09-10 06:00+07', '2026-09-11 06:00+07', 12, 2180, 'two_proportion_z', t.z, t.p_value, t.p1, t.p2, (t.p_value < 0.05 AND t.p2 < t.p1)
  FROM quality.two_proportion_z(70, 2200, 12, 2180) t;
UPDATE quality.action SET status = 'verified' WHERE id = 'ac000000-0000-7000-8000-000000000002';
UPDATE quality.case SET status = 'action' WHERE id = 'ca5e0000-0000-7000-8000-000000000241';
INSERT INTO quality.escalation (case_id, action_id, kind, channel, recipient) VALUES ('ca5e0000-0000-7000-8000-000000000241', 'ac000000-0000-7000-8000-000000000004', 'overdue_action', 'email', 'somsak@example.co.th');

-- ---------------------------------------------------------------------
-- 8. Case QC-0230 (older): statistics-only run (AC-09), control action with no improvement (AC-08), closure → case_record + horizontal candidates
-- ---------------------------------------------------------------------
INSERT INTO quality.case (id, signal_id, title, line_id, sku_id, severity, status, owner_id, opened_at)
VALUES ('ca5e0000-0000-7000-8000-000000000230', '51000000-0000-7000-8000-000000000230', 'QC-0230 Scratch on Line 2 (PNL-220)', '22222222-0000-7000-8000-000000000002', '33333333-0000-7000-8000-000000000001', 'HIGH', 'action', 'aaaaaaaa-0000-7000-8000-000000000001', '2026-08-12 06:05+07');
INSERT INTO quality.analysis_run (id, case_id, signal_id, mode, llm_available, model_version, started_at, finished_at, duration_ms, tests_run, hypotheses, artifacts)
VALUES ('a0000000-0000-7000-8000-000000000230', 'ca5e0000-0000-7000-8000-000000000230', '51000000-0000-7000-8000-000000000230', 'statistics_only', false, NULL, '2026-08-12 08:00+07', '2026-08-12 08:00:16+07', 16000, 7, 3, 0);
INSERT INTO quality.hypothesis (case_id, run_id, rank, statement, score, factor, level, verify_step, status, verified_by, verified_at, verify_result) VALUES
    ('ca5e0000-0000-7000-8000-000000000230', 'a0000000-0000-7000-8000-000000000230', 1, 'Mould M-13 polish interval exceeded — hypothesis to verify', 0.62, 'mould', 'M-13', 'Inspect M-13 cavity', 'confirmed', 'aaaaaaaa-0000-7000-8000-000000000001', '2026-08-14', 'cavity scoring found; polished'),
    ('ca5e0000-0000-7000-8000-000000000230', 'a0000000-0000-7000-8000-000000000230', 2, 'Operator handling on Line 2 — hypothesis to verify', 0.21, 'operator_group', 'G1', 'Observe unload station', 'rejected', NULL, NULL, NULL);
INSERT INTO quality.action (id, case_id, kind, description, owner_id, due_date, status, applied_at) VALUES
    ('ac000000-0000-7000-8000-000000000011', 'ca5e0000-0000-7000-8000-000000000230', 'corrective', 'Polish M-13; set polish interval to 45 days', 'aaaaaaaa-0000-7000-8000-000000000003', '2026-08-15', 'done', '2026-08-15 10:00+07'),
    ('ac000000-0000-7000-8000-000000000012', 'ca5e0000-0000-7000-8000-000000000230', 'preventive', 'Operator retraining on unload handling', 'aaaaaaaa-0000-7000-8000-000000000002', '2026-08-20', 'done', '2026-08-20 10:00+07');
INSERT INTO quality.effectiveness_check (action_id, before_from, before_to, before_x, before_n, after_from, after_to, after_x, after_n, test, z, p_value, rate_before, rate_after, improved)
SELECT 'ac000000-0000-7000-8000-000000000011', '2026-08-05', '2026-08-15', 41, 2600, '2026-08-16', '2026-08-26', 13, 2700, 'two_proportion_z', t.z, t.p_value, t.p1, t.p2, (t.p_value < 0.05 AND t.p2 < t.p1)
  FROM quality.two_proportion_z(41, 2600, 13, 2700) t;
-- the control case: retraining → 15/2,500 (0.60 %) vs 14/2,400 (0.58 %) → no significant improvement; the action stays 'done'
INSERT INTO quality.effectiveness_check (action_id, before_from, before_to, before_x, before_n, after_from, after_to, after_x, after_n, test, z, p_value, rate_before, rate_after, improved)
SELECT 'ac000000-0000-7000-8000-000000000012', '2026-08-10', '2026-08-20', 15, 2500, '2026-08-21', '2026-08-31', 14, 2400, 'two_proportion_z', t.z, t.p_value, t.p1, t.p2, (t.p_value < 0.05 AND t.p2 < t.p1)
  FROM quality.two_proportion_z(15, 2500, 14, 2400) t;
UPDATE quality.action SET status = 'verified' WHERE id = 'ac000000-0000-7000-8000-000000000011';
UPDATE quality.case SET status = 'verification' WHERE id = 'ca5e0000-0000-7000-8000-000000000230';
UPDATE quality.case SET status = 'closed', closure_note = 'Mould polish interval was the cause; 1.58 % → 0.48 % verified; retraining showed no measurable effect and is recorded as such.'
 WHERE id = 'ca5e0000-0000-7000-8000-000000000230';

-- ---------------------------------------------------------------------
-- 9. Golden set (AI-05): 20 incidents; run 1 (active prompt) 13/20 → 65 %; run 2 (candidate prompt) 11/20 → blocked
-- ---------------------------------------------------------------------
INSERT INTO quality.golden_incident (id, code, title, true_cause, true_factor, added_by)
SELECT ('90000000-0000-7000-8000-' || lpad(to_hex(n), 12, '0'))::uuid, 'G-' || lpad(n::text, 2, '0'), 'Golden incident ' || n,
       (ARRAY['material lot contamination','mould polish overdue','parameter drift after maintenance','operator handling','shift changeover','tool wear','ambient humidity','supplier change'])[1 + (n % 8)],
       (ARRAY['material_lot','mould','parameter_change','operator_group','shift','machine','ambient','material_lot'])[1 + (n % 8)]::quality.factor_kind, 'aaaaaaaa-0000-7000-8000-000000000001'
  FROM generate_series(1, 20) n;
INSERT INTO quality.golden_run (id, model_version, prompt_version, ranking_version, n, top3_hits, top1_hits, fabricated, notes)
VALUES ('91000000-0000-7000-8000-000000000001', 'qwen2.5:7b-instruct-q4_K_M', 'p-2026.09', '2026-09', 20, 13, 7, 0, 'release candidate 1.0'),
       ('91000000-0000-7000-8000-000000000002', 'qwen2.5:7b-instruct-q4_K_M', 'p-2026.10-rc1', '2026-09', 20, 11, 6, 0, 'candidate prompt — blocked');
INSERT INTO quality.golden_result (run_id, incident_id, rank_of_true_cause, fabricated_claims)
SELECT '91000000-0000-7000-8000-000000000001', ('90000000-0000-7000-8000-' || lpad(to_hex(n), 12, '0'))::uuid,
       CASE WHEN n <= 7 THEN 1 WHEN n <= 11 THEN 2 WHEN n <= 13 THEN 3 WHEN n <= 17 THEN 5 ELSE NULL END, 0
  FROM generate_series(1, 20) n;

-- =====================================================================
-- 10. VERIFICATION  (compare with the header)
-- =====================================================================
\echo '--- C1 limits through xbar_r_limits() (active row) and capability through capability_indices()'
SELECT ucl, cl, lcl, sample_size, reason, active FROM quality.control_limits WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000001' ORDER BY created_at;
SELECT n, cp, cpk, pp, ppk, normality_ok FROM quality.capability_result WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000001';
SELECT round(avg(mean), 6) AS xbarbar, round(avg(range), 6) AS rbar FROM quality.subgroup WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000001';
\echo '--- AC-02: Nelson violations (expect rule 1 [5]; 2 [10..18]; 3 [20..25]; 5 [28,29]; 6 [33,34,36,37])'
SELECT rule, points_json FROM quality.spc_violation WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000003' ORDER BY rule;
\echo '--- AC-03: C2 non-normal with method note'
SELECT normality_ok, ppk, method_note FROM quality.capability_result WHERE characteristic_id = 'c1000000-0000-7000-8000-000000000002';
\echo '--- Appendix A: S-241 statistic (two_proportion_z), score 0.5600, change point; signals dismissed by FR-11'
SELECT statistic_json->>'rate' AS rate, statistic_json->>'baseline_rate' AS baseline, statistic_json->>'z' AS z, statistic_json->>'p_value' AS p, score, status FROM quality.signal WHERE id = '51000000-0000-7000-8000-000000000241';
SELECT id, status, suppressed_reason FROM quality.signal WHERE id IN ('51000000-0000-7000-8000-000000000242', '51000000-0000-7000-8000-000000000243');
SELECT estimated_ts, window_minutes FROM quality.change_point;
\echo '--- Appendix A: hypotheses (ranks 1..3; H1 confirmed) and the evidence registry (14 rows)'
SELECT rank, score, status, factor, level, left(statement, 70) AS statement FROM quality.hypothesis WHERE case_id = 'ca5e0000-0000-7000-8000-000000000241' ORDER BY rank;
SELECT count(*) AS evidence, count(*) FILTER (WHERE digest = encode(public.digest(value_json::text, 'sha256'), 'hex')) AS digests_ok FROM quality.evidence;
SELECT factor, meaningful, p_value, p_adjusted, effect_size FROM quality.correlation_test ORDER BY p_value;
\echo '--- AC-05 / NFR-05: A1 approved (12/0), A2 grounding failed (5/1), A3 term violations 0, A4 draft'
SELECT kind, lang, version, revision, grounding_status, claims_total, claims_untraced, term_violations, approved_by IS NOT NULL AS approved FROM quality.v_evidence_audit ORDER BY kind;
SELECT untraced_claims FROM quality.v_evidence_audit WHERE artifact_id = 'a7000000-0000-7000-8000-000000000002';
\echo '--- AC-06: exports and watermarks (A1 APPROVED v1.2; A2, A3 DRAFT)'
SELECT kind, format, watermark, version_stamp, approved_by, artifact_is_draft FROM quality.v_export_watermark ORDER BY kind;
\echo '--- AI-07: FMEA row from the confirmed proposal (rpn 140, ap M)'
SELECT p.status, r.s, r.o, r.d, r.rpn, r.ap, r.approved_by IS NOT NULL AS approved FROM quality.fmea_proposal p JOIN quality.fmea_row r ON r.id = p.fmea_row_id;
\echo '--- AC-08: effectiveness (QC-0241 corrective improved; QC-0230 polish improved; retraining not improved)'
SELECT action_kind, rate_before, rate_after, z, p_value, improved, action_status FROM quality.v_effectiveness ORDER BY computed_at;
\echo '--- FR-29/30: QC-0230 closed → case_record and horizontal candidates; FR-31 overdue'
SELECT title, outcome, quality_case_id IS NOT NULL AS linked FROM knowledge.case_record ORDER BY closed_at;
SELECT target_kind, target_code, reason FROM quality.v_horizontal_candidates ORDER BY target_kind, target_code;
SELECT description, days_overdue FROM quality.v_action_overdue;
\echo '--- AI-05 golden runs; AC-09 statistics-only run'
SELECT prompt_version, n, top3_hits, top3_rate, fabricated, release_blocked, block_reason FROM quality.v_golden_summary ORDER BY ran_at;
SELECT mode, llm_available, tests_run, hypotheses, artifacts FROM quality.v_statistics_only;
\echo '--- FR-06 limit history and audit'
SELECT name, ucl, cl, lcl, reason, active FROM quality.v_limit_history WHERE name = 'panel thickness';
SELECT action, count(*) FROM audit.log GROUP BY action ORDER BY action;

-- =====================================================================
-- 11. CONSTRAINT PROBES — each must FAIL (TEST-09 TC-003)
-- =====================================================================
\set ON_ERROR_STOP off
BEGIN;
\echo '--- probe 1: approving A2 with an untraced number (AI-04) — expect GROUNDING_FAILED'
SAVEPOINT p1;
UPDATE quality.artifact SET approved_by = 'aaaaaaaa-0000-7000-8000-000000000001' WHERE id = 'a7000000-0000-7000-8000-000000000002';
ROLLBACK TO SAVEPOINT p1;
\echo '--- probe 2: exporting the unapproved A2 without the DRAFT watermark (C-01, AC-06) — expect DRAFT_WATERMARK'
SAVEPOINT p2;
INSERT INTO quality.export (artifact_id, format, template, uri, sha256, watermark, version_stamp) VALUES ('a7000000-0000-7000-8000-000000000002', 'pdf', 't', 'x', 'x', 'APPROVED', 'x');
ROLLBACK TO SAVEPOINT p2;
\echo '--- probe 3: a viewer approving A3 (NFR-05) — expect ROLE_INSUFFICIENT'
SAVEPOINT p3;
UPDATE quality.artifact SET approved_by = 'aaaaaaaa-0000-7000-8000-000000000006' WHERE id = 'a7000000-0000-7000-8000-000000000003';
ROLLBACK TO SAVEPOINT p3;
\echo '--- probe 4: changing the approval of A1 (NFR-05) — expect APPROVAL_IMMUTABLE'
SAVEPOINT p4;
UPDATE quality.artifact SET approved_by = 'aaaaaaaa-0000-7000-8000-000000000004' WHERE id = 'a7000000-0000-7000-8000-000000000001';
ROLLBACK TO SAVEPOINT p4;
\echo '--- probe 5: a proposed hypothesis with causal wording (C-04) — expect CAUSAL_WORDING'
SAVEPOINT p5;
INSERT INTO quality.hypothesis (case_id, rank, statement, score, verify_step) VALUES ('ca5e0000-0000-7000-8000-000000000241', 4, 'The scratches are caused by the new lot', 0.5, 'n/a');
ROLLBACK TO SAVEPOINT p5;
\echo '--- probe 6: a non-normal capability without a method note (C-03) — expect CAPABILITY_METHOD_NOTE'
SAVEPOINT p6;
INSERT INTO quality.capability_result (characteristic_id, period_from, period_to, n, cpk, normality_p, normality_ok) VALUES ('c1000000-0000-7000-8000-000000000002', '2026-09-01', '2026-09-10', 120, 1.33, 0.01, false);
ROLLBACK TO SAVEPOINT p6;
\echo '--- probe 7: confirming an FMEA proposal before every rating is confirmed (AI-07) — expect RATINGS_NOT_CONFIRMED'
SAVEPOINT p7;
INSERT INTO quality.fmea_proposal (id, case_id, sku_id, process_step, failure_mode, s, o, d, s_criteria_id, o_criteria_id, d_criteria_id, s_confirmed_by)
VALUES ('f0000000-0000-7000-8000-000000000009', 'ca5e0000-0000-7000-8000-000000000241', '33333333-0000-7000-8000-000000000001', 'press', 'flash', 5, 3, 4, '5c000000-0000-7000-8000-000000000105', '5c000000-0000-7000-8000-000000000203', '5c000000-0000-7000-8000-000000000304', 'aaaaaaaa-0000-7000-8000-000000000001');
UPDATE quality.fmea_proposal SET status = 'confirmed' WHERE id = 'f0000000-0000-7000-8000-000000000009';
ROLLBACK TO SAVEPOINT p7;
\echo '--- probe 8: closing QC-0241 with open actions (FR-27) — expect ACTIONS_OPEN'
SAVEPOINT p8;
UPDATE quality.case SET status = 'closed', closure_note = 'premature closure attempt' WHERE id = 'ca5e0000-0000-7000-8000-000000000241';
ROLLBACK TO SAVEPOINT p8;
COMMIT;
\echo '--- seed complete'
