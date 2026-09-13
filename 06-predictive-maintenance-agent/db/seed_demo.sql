-- =====================================================================
--  MachineSense — demo / test seed  (DDS-06 §9)
--  Deterministic. Reproduces SRS-06 Appendix A (Machine #7 — Injection press B, HIGH, health 61/100)
--  on 2026-09-10 08:04+07 with 30 days of 1-minute rollups for three machines, and the rows every
--  acceptance criterion needs (AC-03 synthetic ramp, AC-06 suppression, AC-07 RUL insufficient,
--  AC-08 precision from 24 judged alerts).
--
--  Run after schema.sql:   psql -v ON_ERROR_STOP=1 -f seed_demo.sql      (~ 3 s; 780 k rollup rows)
--  Re-run guard: aborts if core.machine already has rows.
--
--  EXPECTED VALUES (TEST-06 TC-005 — arithmetic re-derived in Python; Postgres execution pending, README-06)
--    machines 3 (M-04 healthy, M-07 degrading, M-11 one failure) · sensors 19 (18 physical + 1 derived) · users 4
--    sample_1m: 30 d × 1440 min × 19 sensors (incl. derived delta_t) = 820,800 rows · raw sample (last hour, M-07, 6 sensors × 3600) = 21,600
--    feature: 720 hourly windows × 19 sensors × 3 names (mean, std, rms) = 41,040 · health_index 721 hourly points × 3 = 2,163 · anomaly_score 241
--    baselines active 18 (window 2026-07-01 → 2026-08-01, 31 d, confirmed by the engineer) · anomaly_model 3 (1 active)
--    Appendix A alert (M-07, HIGH, health 60.87 → "61/100"):
--        bearing_temp now 78.4, baseline 68.9 ± 2.1 → σ = 4.524 ("4.5"), pct_change +13.79 % over 5 d ("+13.8 %")
--        vib_rms now 4.9, baseline 2.9 ± 0.9 → σ = 2.222   ← SRS Appendix A prints 2.1; the arithmetic gives 2.22 (README-06 gap)
--        vib_band_2x now 1.1, baseline 0.6 ± 0.2 → σ = 2.5 ; motor_current 41.4 vs 41.0 ± 1.5 → σ = 0.267 (within baseline)
--        anomaly 0.75 · attribution [bearing_temp_mean .41, vib_rms .33, vib_band_2x .18, motor_current_mean .08]
--        health = 100 − Σ w·f(σ) − w_a·anomaly·100 with f(σ) = 100·clamp((σ−1)/7, 0, 1), weights .35/.25/.10/.10/.20 → 60.87
--        RUL 12–30 d @ 0.80 from 3 comparable failures (injection_press + bearing_wear before 2026-09-10) — trigger-gated
--    alerts 26 = 24 judged historical (17 TP / 6 FP / 1 unknown → precision 17/23 = 0.739) + Appendix A (open, acknowledged) + 1 suppressed (M-04 in window)
--    alert_group 1 open · alert_transition ≥ 27 (one per insert by trigger + 1 ack) · workorder_draft 1
--    failure_event 4 (3 bearing_wear on injection presses: M-04 2024-11-02, M-04 2025-03-18 = case #212, M-07 2025-07-09; M-11 belt_wear 2026-02-14)
--    rul_estimate 2 (M-07 interval 12–30; M-11 NULL "insufficient history (1 of 3 comparable failures)")
--    maintenance_window 1 (M-04 2026-09-05 08:00–12:00) · maintenance_event 4 (each sets rebaseline_required via trigger; all cleared when the engineer confirmed the July baselines)
--    data_quality_event 4 · alarm_event 3 · context_rule 9 · retrain_run 1 · config_version 2
-- =====================================================================

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM core.machine) THEN RAISE EXCEPTION 'seed_demo.sql: core.machine is not empty — refusing to re-seed'; END IF;
END $$;

BEGIN;

-- ---------------------------------------------------------------------
-- 1. MASTER DATA
-- ---------------------------------------------------------------------
INSERT INTO core.plant (id, code, name, timezone) VALUES ('01990600-0000-7000-8000-000000000001','BKK-1','Bangkok Plant 1','Asia/Bangkok');
INSERT INTO core.line (id, plant_id, code, name) VALUES
 ('01990600-0001-7000-8000-000000000001','01990600-0000-7000-8000-000000000001','L1','Injection line 1'),
 ('01990600-0001-7000-8000-000000000002','01990600-0000-7000-8000-000000000001','L2','Assembly line 2');

INSERT INTO core.app_user (id, username, display_name, email, role, lang) VALUES
 ('01990600-0002-7000-8000-000000000001','reliab.eng','Reliability Engineer','reliab@example.local','engineer','en'),
 ('01990600-0002-7000-8000-000000000002','tech.somchai','Somchai (Maintenance)','somchai@example.local','engineer','th'),
 ('01990600-0002-7000-8000-000000000003','planner.k','Maintenance Planner','planner@example.local','manager','th'),
 ('01990600-0002-7000-8000-000000000004','admin','Admin','admin@example.local','admin','en');

INSERT INTO core.machine (id, line_id, code, name, machine_type, criticality, installed_on) VALUES
 ('01990600-0003-7000-8000-000000000004','01990600-0001-7000-8000-000000000001','M-04','Injection press A','injection_press','HIGH','2019-05-10'),
 ('01990600-0003-7000-8000-000000000007','01990600-0001-7000-8000-000000000001','M-07','Injection press B','injection_press','CRITICAL','2020-02-18'),
 ('01990600-0003-7000-8000-000000000011','01990600-0001-7000-8000-000000000002','M-11','Conveyor C','conveyor','MEDIUM','2021-09-01');

-- machine_state rows were created by trigger; enable alerts (baselines below are confirmed)
UPDATE telemetry.machine_state SET alerts_enabled = true;

-- Sensors: 6 physical per machine (ids …-00MM-…-0000000000SS) + derived delta_t on M-07
INSERT INTO telemetry.sensor (id, machine_id, signal, unit, sample_rate_hz, source, active, last_seen_at)
SELECT ('01990600-0004-7000-8000-' || lpad(m.n::text, 4, '0') || lpad(s.n::text, 8, '0'))::uuid,
       ('01990600-0003-7000-8000-' || lpad(m.n::text, 12, '0'))::uuid,
       s.signal, s.unit, s.hz, s.src, true, '2026-09-10 01:00:00+00'
FROM (VALUES (4),(7),(11)) AS m(n)
CROSS JOIN (VALUES (1,'bearing_temp_ds','degC',1.0,'mqtt'), (2,'ambient_temp','degC',0.1,'mqtt'), (3,'vib_rms_ds','mm/s',1.0,'mqtt'),
                   (4,'vib_band_2x','mm/s',1.0,'mqtt'), (5,'motor_current','A',1.0,'opcua'), (6,'rpm','rpm',1.0,'opcua')) AS s(n, signal, unit, hz, src);

INSERT INTO telemetry.sensor (id, machine_id, signal, unit, sample_rate_hz, source, active) VALUES
 ('01990600-0004-7000-8000-000700000007','01990600-0003-7000-8000-000000000007','delta_t','degC',1.0,'derived',true);
INSERT INTO telemetry.derived_signal (sensor_id, expression, inputs_json, config_version) VALUES
 ('01990600-0004-7000-8000-000700000007','bearing_temp_ds - ambient_temp','["bearing_temp_ds","ambient_temp"]','2026-09-01');

INSERT INTO telemetry.context_rule (machine_id, context, expression, priority, hysteresis_s, config_version)
SELECT ('01990600-0003-7000-8000-' || lpad(m.n::text, 12, '0'))::uuid, c.context, c.expr, c.prio, 60, '2026-09-01'
FROM (VALUES (4),(7),(11)) AS m(n)
CROSS JOIN (VALUES ('running','rpm > 200 and motor_current > 5',10), ('idle','rpm > 0 and rpm <= 200',20), ('stopped','rpm = 0',30)) AS c(context, expr, prio);

INSERT INTO telemetry.config_version (kind, version, sha256, content_json, loaded_by) VALUES
 ('sensor_map','2026-09-01', repeat('a', 64), '{"file":"deploy/sensors.example.yaml"}', '01990600-0002-7000-8000-000000000004'),
 ('alert_rules','2026-09-01', repeat('b', 64), '{"file":"deploy/alert-rules.example.yaml","weights":{"bearing_temp_mean":0.35,"vib_rms":0.25,"vib_band_2x":0.10,"motor_current_mean":0.10,"anomaly":0.20},"f":"100*clamp((sigma-1)/7,0,1)","consecutive_windows":3}', '01990600-0002-7000-8000-000000000004');

-- ---------------------------------------------------------------------
-- 2. BASELINES (active, confirmed; window 2026-07-01 → 2026-08-01 = 31 days)  — running context, feature "mean" per sensor
-- ---------------------------------------------------------------------
INSERT INTO telemetry.baseline (sensor_id, context, name, mean, std, p95, window_from, window_to, version, confirmed_by, active, sample_n, contexts_covered_json)
SELECT s.id, 'running', 'mean',
       CASE s.signal WHEN 'bearing_temp_ds' THEN 68.9 WHEN 'ambient_temp' THEN 31.0 WHEN 'vib_rms_ds' THEN 2.9 WHEN 'vib_band_2x' THEN 0.6 WHEN 'motor_current' THEN 41.0 ELSE 1450 END,
       CASE s.signal WHEN 'bearing_temp_ds' THEN 2.1  WHEN 'ambient_temp' THEN 1.8  WHEN 'vib_rms_ds' THEN 0.9 WHEN 'vib_band_2x' THEN 0.2 WHEN 'motor_current' THEN 1.5  ELSE 12 END,
       CASE s.signal WHEN 'bearing_temp_ds' THEN 72.4 WHEN 'ambient_temp' THEN 34.0 WHEN 'vib_rms_ds' THEN 4.4 WHEN 'vib_band_2x' THEN 0.93 WHEN 'motor_current' THEN 43.5 ELSE 1470 END,
       '2026-07-01 00:00+07', '2026-08-01 00:00+07', 1, '01990600-0002-7000-8000-000000000001', true, 44640, '["running","idle","stopped"]'
FROM telemetry.sensor s WHERE s.source <> 'derived';

-- ---------------------------------------------------------------------
-- 3. ANOMALY MODELS (fleet models per machine_type) — v1 retired, v2 active (promotion gated by trigger), AE candidate
-- ---------------------------------------------------------------------
INSERT INTO telemetry.anomaly_model (id, machine_type, algorithm, version, features_json, artefact_sha256, trained_from, trained_to, precision, lead_time_days, false_alerts_per_machine_month, stage, promoted_at) VALUES
 ('01990600-0005-7000-8000-000000000001','injection_press','isolation_forest',1,'["bearing_temp_mean","vib_rms","vib_band_2x","motor_current_mean","delta_t_mean"]', repeat('1',64), '2026-03-01 00:00+07','2026-06-01 00:00+07', 0.68, 3.9, 1.4, 'active', '2026-06-05 09:00+07');
INSERT INTO telemetry.anomaly_model (id, machine_type, algorithm, version, features_json, artefact_sha256, trained_from, trained_to, precision, lead_time_days, false_alerts_per_machine_month, stage) VALUES
 ('01990600-0005-7000-8000-000000000002','injection_press','isolation_forest',2,'["bearing_temp_mean","vib_rms","vib_band_2x","motor_current_mean","delta_t_mean"]', repeat('2',64), '2026-03-01 00:00+07','2026-08-01 00:00+07', 0.74, 4.5, 0.8, 'candidate'),
 ('01990600-0005-7000-8000-000000000003','injection_press','autoencoder',1,'["bearing_temp_mean","vib_rms","vib_band_2x","motor_current_mean","delta_t_mean"]', repeat('3',64), '2026-03-01 00:00+07','2026-08-01 00:00+07', 0.71, 4.1, 0.9, 'candidate');
-- promote v2 (metrics >= v1) → trigger retires v1
UPDATE telemetry.anomaly_model SET stage = 'active' WHERE id = '01990600-0005-7000-8000-000000000002';
INSERT INTO telemetry.retrain_run (started_at, finished_at, trigger, candidate_model_id, baseline_model_id, outcome, metrics_json) VALUES
 ('2026-08-03 02:00+07','2026-08-03 02:41+07','schedule','01990600-0005-7000-8000-000000000002','01990600-0005-7000-8000-000000000001','promoted','{"precision":{"v1":0.68,"v2":0.74},"lead_time_days":{"v1":3.9,"v2":4.5},"retrospective_failures":5,"detected":4}');

-- ---------------------------------------------------------------------
-- 4. FAILURE HISTORY (FR-15) — 3 comparable bearing_wear failures on injection presses; 1 belt_wear on the conveyor
-- ---------------------------------------------------------------------
INSERT INTO telemetry.failure_event (id, machine_id, ts, failure_mode, component, downtime_min, cost, lead_time_days, labelled_by) VALUES
 ('01990600-0006-7000-8000-000000000001','01990600-0003-7000-8000-000000000004','2024-11-02 14:20+07','bearing_wear','drive-side bearing',540,182000,NULL,'01990600-0002-7000-8000-000000000001'),
 ('01990600-0006-7000-8000-000000000002','01990600-0003-7000-8000-000000000004','2025-03-18 09:05+07','bearing_wear','drive-side bearing',420,150000,3.5,'01990600-0002-7000-8000-000000000001'),  -- Genba case #212
 ('01990600-0006-7000-8000-000000000003','01990600-0003-7000-8000-000000000007','2025-07-09 22:40+07','bearing_wear','drive-side bearing',610,205000,4.2,'01990600-0002-7000-8000-000000000001'),
 ('01990600-0006-7000-8000-000000000004','01990600-0003-7000-8000-000000000011','2026-02-14 11:15+07','belt_wear','main belt',180,32000,NULL,'01990600-0002-7000-8000-000000000001');

INSERT INTO telemetry.maintenance_event (machine_id, ts, kind, description, parts_json, downtime_min) VALUES
 ('01990600-0003-7000-8000-000000000004','2025-03-18 18:30+07','failure_repair','Drive-side bearing replaced (case #212)','["6310-2RS bearing","grease"]',420),
 ('01990600-0003-7000-8000-000000000007','2025-07-10 06:00+07','failure_repair','Drive-side bearing replaced','["6310-2RS bearing"]',610),
 ('01990600-0003-7000-8000-000000000004','2026-06-14 09:00+07','component_replaced','Coupling replaced during planned service','["coupling"]',120),   -- sets rebaseline_required on M-04 (AI-07)
 ('01990600-0003-7000-8000-000000000011','2026-02-14 14:15+07','failure_repair','Belt replaced','["belt 1200 mm"]',180);
-- The July baselines above (confirmed 2026-08-02) post-date every repair → the engineer cleared the re-baseline flags then
UPDATE telemetry.machine_state SET rebaseline_required = false, rebaseline_reason = NULL;

-- ---------------------------------------------------------------------
-- 5. 30 DAYS OF 1-MINUTE ROLLUPS  (2026-08-11 08:00+07 → 2026-09-10 08:00+07)
--    Deterministic formulas. M-07: bearing temp ramps linearly over the last 5 days from 68.9 to 78.4;
--    vib_rms rises over the last 6 days from 2.9 to 4.9; vib_band_2x from 0.6 to 1.1. M-04 healthy. M-11 healthy.
-- ---------------------------------------------------------------------
INSERT INTO telemetry.sample_1m (bucket, sensor_id, n, avg, min, max, stddev, good_pct)
SELECT b, s.id, 60,
       v.val, v.val - 0.05 * abs(v.val) * 0.01, v.val + 0.05 * abs(v.val) * 0.01, 0.02 * abs(v.val), 100
FROM generate_series('2026-08-11 08:00+07'::timestamptz, '2026-09-10 07:59+07'::timestamptz, interval '1 minute') AS b
CROSS JOIN telemetry.sensor s
JOIN core.machine m ON m.id = s.machine_id
CROSS JOIN LATERAL (
    SELECT CASE s.signal
        WHEN 'bearing_temp_ds' THEN
            CASE WHEN m.code = 'M-07' AND b >= '2026-09-05 08:00+07' THEN 68.9 + 9.5 * (EXTRACT(epoch FROM (b - '2026-09-05 08:00+07'::timestamptz)) / (5*86400.0))
                 ELSE 68.9 END + 0.3 * sin(EXTRACT(epoch FROM b) / 3600.0)
        WHEN 'ambient_temp'  THEN 31.0 + 2.0 * sin(EXTRACT(epoch FROM b) / 86400.0 * 2 * pi())
        WHEN 'vib_rms_ds'    THEN
            CASE WHEN m.code = 'M-07' AND b >= '2026-09-04 08:00+07' THEN 2.9 + 2.0 * (EXTRACT(epoch FROM (b - '2026-09-04 08:00+07'::timestamptz)) / (6*86400.0))
                 ELSE 2.9 END + 0.1 * sin(EXTRACT(epoch FROM b) / 900.0)
        WHEN 'vib_band_2x'   THEN
            CASE WHEN m.code = 'M-07' AND b >= '2026-09-04 08:00+07' THEN 0.6 + 0.5 * (EXTRACT(epoch FROM (b - '2026-09-04 08:00+07'::timestamptz)) / (6*86400.0))
                 ELSE 0.6 END + 0.02 * sin(EXTRACT(epoch FROM b) / 900.0)
        WHEN 'motor_current' THEN CASE WHEN m.code = 'M-07' THEN 41.4 ELSE 41.0 END + 0.4 * sin(EXTRACT(epoch FROM b) / 600.0)
        WHEN 'rpm'           THEN 1450 + 5 * sin(EXTRACT(epoch FROM b) / 300.0)
        ELSE (CASE WHEN m.code = 'M-07' AND b >= '2026-09-05 08:00+07' THEN 68.9 + 9.5 * (EXTRACT(epoch FROM (b - '2026-09-05 08:00+07'::timestamptz)) / (5*86400.0)) ELSE 68.9 END)
             - (31.0 + 2.0 * sin(EXTRACT(epoch FROM b) / 86400.0 * 2 * pi()))     -- delta_t
    END AS val
) v
WHERE s.source <> 'derived' OR m.code = 'M-07';

-- The final minute of the ramp is exactly the Appendix A "now" values (sin terms are zeroed for that bucket):
UPDATE telemetry.sample_1m SET avg = 78.4, min = 78.3, max = 78.5, stddev = 0.05
 WHERE bucket = '2026-09-10 07:59+07' AND sensor_id = '01990600-0004-7000-8000-000700000001';
UPDATE telemetry.sample_1m SET avg = 4.9,  min = 4.85, max = 4.95, stddev = 0.03
 WHERE bucket = '2026-09-10 07:59+07' AND sensor_id = '01990600-0004-7000-8000-000700000003';
UPDATE telemetry.sample_1m SET avg = 1.1,  min = 1.08, max = 1.12, stddev = 0.01
 WHERE bucket = '2026-09-10 07:59+07' AND sensor_id = '01990600-0004-7000-8000-000700000004';
UPDATE telemetry.sample_1m SET avg = 41.4, min = 41.0, max = 41.8, stddev = 0.2
 WHERE bucket = '2026-09-10 07:59+07' AND sensor_id = '01990600-0004-7000-8000-000700000005';

-- Raw samples for the last hour of M-07 (exercise rollup_1m and the ingest path) — 6 sensors × 3600 s
INSERT INTO telemetry.sample (ts, sensor_id, value, quality)
SELECT t, s.id,
       CASE s.signal WHEN 'bearing_temp_ds' THEN 78.4 WHEN 'ambient_temp' THEN 31.2 WHEN 'vib_rms_ds' THEN 4.9 WHEN 'vib_band_2x' THEN 1.1 WHEN 'motor_current' THEN 41.4 ELSE 1450 END
       + 0.01 * sin(EXTRACT(epoch FROM t)),
       192
FROM generate_series('2026-09-10 07:00+07'::timestamptz, '2026-09-10 07:59:59+07'::timestamptz, interval '1 second') AS t
CROSS JOIN telemetry.sensor s WHERE s.machine_id = '01990600-0003-7000-8000-000000000007' AND s.source <> 'derived';

-- Machine context timeline: running throughout (one row per machine; until_ts NULL)
INSERT INTO telemetry.machine_context (machine_id, ts, context) SELECT id, '2026-08-11 08:00+07', 'running' FROM core.machine;
UPDATE telemetry.machine_state SET current_context = 'running', context_since = '2026-08-11 08:00+07', last_scored_at = '2026-09-10 08:00+07';

-- ---------------------------------------------------------------------
-- 6. HOURLY FEATURES (600 s windows, running context): mean, std, rms per sensor — from the rollups
-- ---------------------------------------------------------------------
INSERT INTO telemetry.feature (ts, sensor_id, window_s, context, name, value)
SELECT h, r.sensor_id, 600, 'running', f.name,
       CASE f.name WHEN 'mean' THEN avg(r.avg) WHEN 'std' THEN COALESCE(stddev_samp(r.avg), 0) ELSE sqrt(avg(r.avg * r.avg)) END
FROM generate_series('2026-08-11 08:00+07'::timestamptz, '2026-09-10 07:00+07'::timestamptz, interval '1 hour') AS h
JOIN telemetry.sample_1m r ON r.bucket >= h AND r.bucket < h + interval '1 hour'
CROSS JOIN (VALUES ('mean'), ('std'), ('rms')) AS f(name)
GROUP BY h, r.sensor_id, f.name;

-- ---------------------------------------------------------------------
-- 7. ANOMALY SCORES (M-07 hourly over the last 10 days, rising to 0.75) and TREND ESTIMATES (at the alert time)
-- ---------------------------------------------------------------------
INSERT INTO telemetry.anomaly_score (ts, machine_id, model_id, context, score, contributions_json)
SELECT h, '01990600-0003-7000-8000-000000000007', '01990600-0005-7000-8000-000000000002', 'running',
       ROUND(LEAST(0.75, 0.05 + 0.70 * GREATEST(0, EXTRACT(epoch FROM (h - '2026-09-04 08:00+07'::timestamptz)) / (6*86400.0)))::numeric, 4),
       '{"bearing_temp_mean": 0.41, "vib_rms": 0.33, "vib_band_2x": 0.18, "motor_current_mean": 0.08}'
FROM generate_series('2026-08-31 08:00+07'::timestamptz, '2026-09-10 08:00+07'::timestamptz, interval '1 hour') AS h;

INSERT INTO telemetry.trend_estimate (ts, sensor_id, feature, context, window_days, slope_per_day, slope_ci_low, slope_ci_high, pct_change, consecutive_rising_days) VALUES
 ('2026-09-10 08:00+07','01990600-0004-7000-8000-000700000001','mean','running',5, 1.90, 1.62, 2.18, 13.79, 5),
 ('2026-09-10 08:00+07','01990600-0004-7000-8000-000700000003','mean','running',6, 0.333, 0.27, 0.40, 68.97, 6),
 ('2026-09-10 08:00+07','01990600-0004-7000-8000-000700000004','mean','running',6, 0.083, 0.06, 0.11, 83.33, 6),
 ('2026-09-10 08:00+07','01990600-0004-7000-8000-000700000005','mean','running',5, 0.00, -0.05, 0.05, 0.98, 0);

-- ---------------------------------------------------------------------
-- 8. HEALTH INDEX (hourly, 3 machines): M-04 92±, M-11 88±, M-07 92 → 60.87 over the last 6 days
-- ---------------------------------------------------------------------
INSERT INTO telemetry.health_index (ts, machine_id, value, components_json)
SELECT h, m.id,
       CASE m.code
         WHEN 'M-04' THEN ROUND((92 + 1.5 * sin(EXTRACT(epoch FROM h) / 7200.0))::numeric, 2)
         WHEN 'M-11' THEN ROUND((88 + 1.5 * sin(EXTRACT(epoch FROM h) / 7200.0))::numeric, 2)
         ELSE ROUND((92 - 31.13 * LEAST(1, GREATEST(0, EXTRACT(epoch FROM (h - '2026-09-04 08:00+07'::timestamptz)) / (6*86400.0))))::numeric, 2)
       END,
       CASE m.code WHEN 'M-07' THEN '{"formula":"100 - sum(w*f(sigma)) - w_a*anomaly*100","weights":{"bearing_temp_mean":0.35,"vib_rms":0.25,"vib_band_2x":0.10,"motor_current_mean":0.10,"anomaly":0.20}}'::jsonb ELSE '{}'::jsonb END
FROM generate_series('2026-08-11 08:00+07'::timestamptz, '2026-09-10 08:00+07'::timestamptz, interval '1 hour') AS h
CROSS JOIN core.machine m;
-- pin the final M-07 value to the computed 60.87
UPDATE telemetry.health_index SET value = 60.87,
  components_json = '{"bearing_temp_mean": {"sigma": 4.524, "penalty": 17.62}, "vib_rms": {"sigma": 2.222, "penalty": 4.37}, "vib_band_2x": {"sigma": 2.5, "penalty": 2.14}, "motor_current_mean": {"sigma": 0.267, "penalty": 0.0}, "anomaly": {"score": 0.75, "penalty": 15.0}, "formula": "100 - sum(w*f(sigma)) - w_a*anomaly*100", "f": "100*clamp((sigma-1)/7,0,1)", "weights": {"bearing_temp_mean": 0.35, "vib_rms": 0.25, "vib_band_2x": 0.10, "motor_current_mean": 0.10, "anomaly": 0.20}}'
WHERE machine_id = '01990600-0003-7000-8000-000000000007' AND ts = '2026-09-10 08:00+07';

-- ---------------------------------------------------------------------
-- 9. HISTORICAL ALERTS WITH FEEDBACK (AC-08): 24 judged alerts, 2026-06-15 … 2026-09-03 across the three machines
--    outcomes: n % 4 = 0 → false_positive (6: 4,8,12,16,20,24), n = 23 → unknown (1), else true_positive (17) → precision 17/23 = 0.739
-- ---------------------------------------------------------------------
INSERT INTO telemetry.alert (id, opened_at, machine_id, severity, signals_json, evidence_json, suspected_component, recommendation, status, closed_at, rule_code, consecutive_windows, health_index, model_id, rul_reason)
SELECT ('01990600-0007-7000-8000-' || lpad(n::text, 12, '0'))::uuid,
       '2026-06-15 09:00+07'::timestamptz + (n * interval '80 hours'),
       CASE n % 3 WHEN 0 THEN '01990600-0003-7000-8000-000000000004' WHEN 1 THEN '01990600-0003-7000-8000-000000000007' ELSE '01990600-0003-7000-8000-000000000011' END::uuid,
       CASE WHEN n % 5 = 0 THEN 'HIGH' ELSE 'MEDIUM' END::quality.severity,
       '["bearing_temp_ds"]',
       jsonb_build_object('sigma', 2.0 + (n % 7) * 0.3, 'attribution', jsonb_build_array(jsonb_build_object('feature','bearing_temp_mean','contribution',0.6), jsonb_build_object('feature','vib_rms','contribution',0.4))),
       'drive-side bearing', 'Check lubrication and take a hand-held temperature reading',
       'resolved', '2026-06-15 09:00+07'::timestamptz + (n * interval '80 hours') + interval '2 days',
       'SIGMA_WATCH', 3, 80 - (n % 7), '01990600-0005-7000-8000-000000000001', 'insufficient history at the time'
FROM generate_series(1, 24) AS n;

INSERT INTO telemetry.alert_feedback (alert_id, outcome, actual_finding, technician_id, created_at)
SELECT ('01990600-0007-7000-8000-' || lpad(n::text, 12, '0'))::uuid,
       CASE WHEN n = 23 THEN 'unknown' WHEN n % 4 = 0 THEN 'false_positive' ELSE 'true_positive' END,
       CASE WHEN n = 23 THEN 'Not inspected — machine retooled' WHEN n % 4 = 0 THEN 'No fault found; sensor bracket loose' ELSE 'Lubrication low; regreased' END,
       '01990600-0002-7000-8000-000000000002',
       '2026-06-15 09:00+07'::timestamptz + (n * interval '80 hours') + interval '2 days'
FROM generate_series(1, 24) AS n;

-- ---------------------------------------------------------------------
-- 10. AC-06: a would-be alert inside a maintenance window on M-04 is recorded as suppressed
-- ---------------------------------------------------------------------
INSERT INTO telemetry.maintenance_window (id, machine_id, starts_at, ends_at, kind, reason, declared_by) VALUES
 ('01990600-0008-7000-8000-000000000001','01990600-0003-7000-8000-000000000004','2026-09-05 08:00+07','2026-09-05 12:00+07','planned_service','Quarterly service','01990600-0002-7000-8000-000000000003');
INSERT INTO telemetry.alert (id, opened_at, machine_id, severity, signals_json, evidence_json, suspected_component, recommendation, status, rule_code, consecutive_windows, suppressed, rul_reason) VALUES
 ('01990600-0007-7000-8000-000000000101','2026-09-05 09:10+07','01990600-0003-7000-8000-000000000004','MEDIUM','["motor_current"]','{"sigma": 3.1, "attribution": [{"feature":"motor_current_mean","contribution":1.0}], "suppressed_by":"maintenance_window 01990600-0008-7000-8000-000000000001"}','(suppressed)','(suppressed)','dismissed','SIGMA_WATCH',3,true,'suppressed');

-- ---------------------------------------------------------------------
-- 11. THE APPENDIX A ALERT — M-07, 2026-09-10 08:04+07, HIGH, health 60.87 — with its incident, RUL, ack and work order
-- ---------------------------------------------------------------------
INSERT INTO telemetry.alert_group (id, machine_id, suspected_component, opened_at, max_severity, status, title) VALUES
 ('01990600-0009-7000-8000-000000000001','01990600-0003-7000-8000-000000000007','drive-side bearing','2026-09-10 08:04+07','HIGH','acknowledged','M-07 drive-side bearing degradation / lubrication loss');

INSERT INTO telemetry.rul_estimate (ts, machine_id, failure_mode, low_days, high_days, confidence, method) VALUES
 ('2026-09-10 08:04+07','01990600-0003-7000-8000-000000000007','bearing_wear',12,30,0.80,'empirical_ttf');           -- trigger counts 3 comparable failures
INSERT INTO telemetry.rul_estimate (ts, machine_id, failure_mode, reason, method) VALUES
 ('2026-09-10 08:04+07','01990600-0003-7000-8000-000000000011','belt_wear','insufficient history (1 of 3 comparable failures)','empirical_ttf');   -- AC-07

INSERT INTO telemetry.alert (id, opened_at, machine_id, severity, signals_json, evidence_json, suspected_component, recommendation, rul_low_days, rul_high_days, rul_confidence, status, group_id, health_index, model_id, consecutive_windows, rule_code) VALUES
 ('01990600-0007-7000-8000-000000000200','2026-09-10 08:04+07','01990600-0003-7000-8000-000000000007','HIGH',
  '["bearing_temp_ds","vib_rms_ds","vib_band_2x","motor_current"]',
  '{"machine": {"code": "M-07", "name": "Injection press B"}, "context": "running", "health_index": 60.87,
    "signals": {
      "bearing_temp_ds": {"now": 78.4, "baseline_mean": 68.9, "baseline_std": 2.1, "sigma": 4.524, "pct_change_5d": 13.79, "trend_slope_per_day": 1.90, "trend_ci_80": [1.62, 2.18], "unit": "degC"},
      "vib_rms_ds":      {"now": 4.9,  "baseline_mean": 2.9,  "baseline_std": 0.9, "sigma": 2.222, "consecutive_rising_days": 6, "unit": "mm/s"},
      "vib_band_2x":     {"now": 1.1,  "baseline_mean": 0.6,  "baseline_std": 0.2, "sigma": 2.5, "unit": "mm/s"},
      "motor_current":   {"now": 41.4, "baseline_mean": 41.0, "baseline_std": 1.5, "sigma": 0.267, "within_baseline": true, "unit": "A"}},
    "anomaly": {"model": "isolation_forest v2", "score": 0.75},
    "attribution": [{"feature": "bearing_temp_mean", "contribution": 0.41}, {"feature": "vib_rms", "contribution": 0.33}, {"feature": "vib_band_2x", "contribution": 0.18}, {"feature": "motor_current_mean", "contribution": 0.08}],
    "production_context": {"volume_change_pct_5d": -1.2},
    "rul": {"low_days": 12, "high_days": 30, "confidence": 0.80, "comparable_failures": 3},
    "similar_case": {"machine": "M-04", "date": "2025-03-18", "outcome": "bearing replaced", "genba_case": 212}}',
  'drive-side bearing',
  'Within 3 days: (1) check drive-side bearing lubrication and temperature by hand-held probe; (2) take a vibration spectrum reading, look for BPFO/BPFI peaks; (3) verify coupling alignment.',
  12, 30, 0.80, 'open', '01990600-0009-7000-8000-000000000001', 60.87, '01990600-0005-7000-8000-000000000002', 3, 'SIGMA_HIGH');

-- acknowledged by the technician from Discord at 08:11
UPDATE telemetry.alert SET status = 'acknowledged' WHERE id = '01990600-0007-7000-8000-000000000200';
UPDATE telemetry.alert_transition SET actor_id = '01990600-0002-7000-8000-000000000002', channel = 'discord', note = 'will inspect this afternoon'
 WHERE alert_id = '01990600-0007-7000-8000-000000000200' AND to_status = 'acknowledged';

INSERT INTO telemetry.workorder_draft (alert_id, created_by, symptom, evidence_json, tasks_json, parts_json, priority, due_within_days) VALUES
 ('01990600-0007-7000-8000-000000000200','01990600-0002-7000-8000-000000000003',
  'Drive-side bearing temperature 78.4 °C (+13.8 % over 5 days, σ 4.5); vibration RMS 4.9 mm/s rising 6 days; 2× RPM band energy rising',
  '{"from_alert": "01990600-0007-7000-8000-000000000200"}',
  '["Check drive-side bearing lubrication", "Hand-held temperature probe on drive-side housing", "Vibration spectrum: BPFO/BPFI peaks", "Verify coupling alignment"]',
  '["6310-2RS bearing (stock check)", "grease NLGI 2"]', 'high', 3);

-- ---------------------------------------------------------------------
-- 12. DATA QUALITY AND ALARM EVENTS, SENSOR HEALTH
-- ---------------------------------------------------------------------
INSERT INTO ops.data_quality_event (ts, source, severity, entity, entity_id, message, detail_json) VALUES
 ('2026-09-02 03:14+07','ingest-mqtt','warning','sensor','01990600-0004-7000-8000-000400000002','gap: no samples for 420 s (expected 10 s)','{"expected_interval_s":10,"gap_s":420}'),
 ('2026-09-06 14:02+07','ingest-modbus','warning','sensor','01990600-0004-7000-8000-001100000005','stuck value: 41.0 for 30 consecutive polls','{"n":30,"value":41.0}'),
 ('2026-09-08 09:30+07','ingest-opcua','warning','machine','01990600-0003-7000-8000-000000000011','clock skew 7.4 s vs NTP','{"skew_s":7.4}'),
 ('2026-09-09 22:45+07','ingest-mqtt','error','sensor','01990600-0004-7000-8000-000400000001','out of range: 412.0 degC (max 200)','{"value":412.0,"max":200}');

INSERT INTO telemetry.alarm_event (machine_id, ts, code, severity, text, active, cleared_at, source) VALUES
 ('01990600-0003-7000-8000-000000000007','2026-09-09 16:20+07','TMP-H1','MEDIUM','Bearing temperature high (warning)',false,'2026-09-09 16:35+07','opcua'),
 ('01990600-0003-7000-8000-000000000007','2026-09-10 07:52+07','TMP-H1','MEDIUM','Bearing temperature high (warning)',true,NULL,'opcua'),
 ('01990600-0003-7000-8000-000000000011','2026-09-04 11:10+07','OVL-01','HIGH','Overload',false,'2026-09-04 11:12+07','mqtt');

INSERT INTO telemetry.sensor_health (sensor_id, checked_at, status, gap_count_24h, stuck_count_24h, range_count_24h, last_good_at)
SELECT id, '2026-09-10 08:00+07', 'ok', 0, 0, 0, '2026-09-10 07:59+07' FROM telemetry.sensor;
UPDATE telemetry.sensor_health SET status = 'stuck', stuck_count_24h = 1 WHERE sensor_id = '01990600-0004-7000-8000-001100000005';

COMMIT;

-- ---------------------------------------------------------------------
-- 13. VERIFICATION (values in the header)
-- ---------------------------------------------------------------------
\echo '--- machines 3 / sensors 19 / users 4 / baselines active 18 / models 3 (active 1: v2)'
SELECT (SELECT count(*) FROM core.machine), (SELECT count(*) FROM telemetry.sensor), (SELECT count(*) FROM core.app_user),
       (SELECT count(*) FROM telemetry.baseline WHERE active), (SELECT count(*) FROM telemetry.anomaly_model), (SELECT version FROM telemetry.anomaly_model WHERE stage = 'active');
\echo '--- sample_1m 820800 / sample 21600 / feature 41040 / health_index 2163 / anomaly_score 241'
SELECT (SELECT count(*) FROM telemetry.sample_1m), (SELECT count(*) FROM telemetry.sample), (SELECT count(*) FROM telemetry.feature),
       (SELECT count(*) FROM telemetry.health_index), (SELECT count(*) FROM telemetry.anomaly_score);
\echo '--- Appendix A: now values 78.4 / 4.9 / 1.1 / 41.4 ; sigma from baselines 4.524 / 2.222 / 2.5 / 0.267 ; pct 13.79 ; health 60.87'
SELECT s.signal, r.avg AS now, b.mean, b.std, ROUND(((r.avg - b.mean) / b.std)::numeric, 3) AS sigma, ROUND(((r.avg - b.mean) / b.mean * 100)::numeric, 2) AS pct
FROM telemetry.sample_1m r JOIN telemetry.sensor s ON s.id = r.sensor_id JOIN telemetry.baseline b ON b.sensor_id = s.id AND b.active
WHERE r.bucket = '2026-09-10 07:59+07' AND s.machine_id = '01990600-0003-7000-8000-000000000007' AND s.signal IN ('bearing_temp_ds','vib_rms_ds','vib_band_2x','motor_current') ORDER BY s.signal;
SELECT value AS health_now FROM telemetry.health_index WHERE machine_id = '01990600-0003-7000-8000-000000000007' AND ts = '2026-09-10 08:00+07';
\echo '--- alerts 26 (judged 24: precision 0.739 ; suppressed 1 ; open/acknowledged 1) ; transitions >= 27 ; groups open 1 ; RUL rows 2 (one NULL with reason)'
SELECT (SELECT count(*) FROM telemetry.alert), (SELECT count(*) FROM telemetry.alert WHERE suppressed), (SELECT count(*) FROM telemetry.alert WHERE status = 'acknowledged'),
       (SELECT count(*) FROM telemetry.alert_transition), (SELECT count(*) FROM telemetry.alert_group WHERE closed_at IS NULL),
       (SELECT count(*) FROM telemetry.rul_estimate), (SELECT count(*) FROM telemetry.rul_estimate WHERE low_days IS NULL AND reason IS NOT NULL);
SELECT * FROM telemetry.v_alert_precision ORDER BY machine_code, month;
SELECT sum(true_positive) AS tp, sum(false_positive) AS fp, sum(unknown) AS unk, ROUND(sum(true_positive)::numeric / (sum(true_positive) + sum(false_positive)), 3) AS precision_overall FROM telemetry.v_alert_precision;
\echo '--- top risks: M-07 first ; M-04 rebaseline_required false ; failure_event 4 ; comparable failures for M-07 bearing_wear = 3'
SELECT code, health_now, health_drop_7d, open_incidents, risk_score FROM telemetry.v_top_risks_week;
SELECT machine_id, rebaseline_required FROM telemetry.machine_state ORDER BY machine_id;
SELECT comparable_failures FROM telemetry.rul_estimate WHERE machine_id = '01990600-0003-7000-8000-000000000007';
\echo '--- constraint probes (each statement must FAIL): alert without component; alert without attribution; RUL point estimate; RUL interval for M-11 (1 failure); baseline activate unconfirmed; model promote with lower precision; feedback update; alert in maintenance window not marked suppressed'
\set ON_ERROR_STOP off
INSERT INTO telemetry.alert (machine_id, severity, evidence_json, suspected_component, recommendation, rul_reason) VALUES ('01990600-0003-7000-8000-000000000004','MEDIUM','{"attribution":[{"feature":"x","contribution":1}]}','','Check','n/a');
INSERT INTO telemetry.alert (machine_id, severity, evidence_json, suspected_component, recommendation, rul_reason) VALUES ('01990600-0003-7000-8000-000000000004','MEDIUM','{}','bearing','Check','n/a');
INSERT INTO telemetry.alert (machine_id, severity, evidence_json, suspected_component, recommendation, rul_low_days) VALUES ('01990600-0003-7000-8000-000000000004','MEDIUM','{"attribution":[{"feature":"x","contribution":1}]}','bearing','Check', 20);
INSERT INTO telemetry.rul_estimate (ts, machine_id, failure_mode, low_days, high_days, confidence) VALUES (now(),'01990600-0003-7000-8000-000000000011','belt_wear',10,20,0.8);
UPDATE telemetry.baseline SET active = true, confirmed_by = NULL WHERE sensor_id = '01990600-0004-7000-8000-000400000001';
UPDATE telemetry.anomaly_model SET stage = 'active' WHERE id = '01990600-0005-7000-8000-000000000001';   -- v1 (0.68) below active v2 (0.74)
UPDATE telemetry.alert_feedback SET outcome = 'true_positive' WHERE alert_id = '01990600-0007-7000-8000-000000000004';
INSERT INTO telemetry.alert (opened_at, machine_id, severity, evidence_json, suspected_component, recommendation, rul_reason) VALUES ('2026-09-05 09:30+07','01990600-0003-7000-8000-000000000004','MEDIUM','{"attribution":[{"feature":"x","contribution":1}]}','bearing','Check','n/a');
\set ON_ERROR_STOP on
