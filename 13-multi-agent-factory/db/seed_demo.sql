-- =====================================================================
--  KaizenSwarm — demo seed  (DDS-13 §9; TEST-13 TC-005)
--  Reproduces SRS-13 Appendix A (run 411, 2026-09-10 Shift A) and AC-02…AC-09 on Plant 1, lines 1–3, 2026-09-07…11.
--  Apply after schema.sql:   psql -f seed_demo.sql
--  Every expected value below was re-derived in Python (TEST-13 TC-005); PostgreSQL itself was not executed on the
--  authoring machine (README-13 "Verification"). The 16 probes at the end must each FAIL inside their transaction.
--
--  Runs 405–410: routine shift runs (the M-07 bearing issue first seen in 407 → occurrences 5 by 411, AC-08)
--  Run 411: Appendix A — quality S-241 + maintenance M-07 compound on line 3 (0.84), material RAD-500-A (0.71), production line 1 (0.52)
--  Run 412: Maintenance runner killed → timeout → partial (AC-02); quality + material report lot LOT-2609-114 → one finding, two evidence sets (AC-03)
--  Run 413: Production over its tool-call budget → budget_exceeded, partial (AC-05); Maintenance CRITICAL M-12 → immediate push (FR-29)
--  Run 414: Maintenance returns malformed output twice → invalid_output, no finding written (AC-06); line 1 OEE expires (FR-27)
--  Run 415: ad-hoc question "Is line 3 at risk this shift?" (FR-21)
--  All numbers in the briefing texts are quoted from the findings — swarm.trg_briefing_grounded proves it (AC-07).
-- =====================================================================
SET TIME ZONE 'Asia/Bangkok';
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Settings, users, plant, lines, machines, SKU, lot, shifts
-- ---------------------------------------------------------------------
INSERT INTO swarm.setting (key, value_num, value_text, description) VALUES
 ('agent_timeout_s',          60,   NULL, 'NFR-02: per-agent timeout (active time: tools + phrasing; lease queue time excluded — ADR-K03)'),
 ('run_wall_s',               180,  NULL, 'NFR-01: full run wall clock'),
 ('max_attempts',             2,    NULL, 'AI-02: one retry on malformed output, then agent error'),
 ('backoff_base_ms',          2000, NULL, 'FR-05: transport-error backoff base'),
 ('backoff_cap_ms',           30000,NULL, 'FR-05: backoff cap'),
 ('circuit_threshold',        3,    NULL, 'FR-05: consecutive failures that open the circuit'),
 ('circuit_cooldown_min',     15,   NULL, 'FR-05: minutes before half-open'),
 ('freshness_threshold_min',  60,   NULL, 'AI-07: data older than this is flagged in the briefing'),
 ('top_n',                    3,    NULL, 'FR-19: briefing length'),
 ('expire_after_runs',        2,    NULL, 'FR-27: consecutive reporting runs without the issue before expiry'),
 ('semaphore_slots',          1,    NULL, 'C-05: one LLM inference at a time'),
 ('llm_max_params_b',         9,    NULL, 'AI-05: shared model size'),
 ('llm_temperature',          0.3,  NULL, 'AI-01: phrasing only'),
 ('scenario_gate_top3',       0.80, NULL, 'AI-06: release gate'),
 ('scenario_gate_fabricated', 0,    NULL, 'AI-06: zero fabricated findings'),
 ('retention_days',           365,  NULL, 'NFR-05'),
 ('model_name',               NULL, 'qwen2.5:7b-instruct-q4_K_M', 'AI-05: the one shared local model'),
 ('briefing_langs',           NULL, 'en,th,ja', 'FR-31');

INSERT INTO core.app_user (id, username, display_name, email, role, lang) VALUES
 ('d0000000-0000-4000-8000-000000000001', 'somchai', 'Somchai Jaidee (plant manager)', 'somchai@plant.local', 'manager',   'th'),
 ('d0000000-0000-4000-8000-000000000002', 'pranee',  'Pranee Srisuk (QE engineer)',      'pranee@plant.local',  'engineer',  'th'),
 ('d0000000-0000-4000-8000-000000000003', 'kenji',   'Kenji Sato (maintenance engineer)','kenji@plant.local',   'engineer',  'ja'),
 ('d0000000-0000-4000-8000-000000000004', 'wichai',  'Wichai Tong (shift leader A)',     'wichai@plant.local',  'inspector', 'th'),
 ('d0000000-0000-4000-8000-000000000005', 'admin',   'KaizenSwarm admin',                'admin@plant.local',   'admin',     'en');

INSERT INTO core.plant (id, code, name) VALUES ('20000000-0000-4000-8000-000000000001', 'P1', 'Plant 1');
INSERT INTO core.line (id, plant_id, code, name) VALUES
 ('20000000-0000-4000-8000-000000000101', '20000000-0000-4000-8000-000000000001', 'L1', 'Line 1'),
 ('20000000-0000-4000-8000-000000000102', '20000000-0000-4000-8000-000000000001', 'L2', 'Line 2'),
 ('20000000-0000-4000-8000-000000000103', '20000000-0000-4000-8000-000000000001', 'L3', 'Line 3');
INSERT INTO core.machine (id, line_id, code, name, machine_type, criticality) VALUES
 ('30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000101', 'M-01', 'Press 1',   'press',   'MEDIUM'),
 ('30000000-0000-4000-8000-000000000007', '20000000-0000-4000-8000-000000000103', 'M-07', 'Press 7',   'press',   'HIGH'),
 ('30000000-0000-4000-8000-000000000012', '20000000-0000-4000-8000-000000000102', 'M-12', 'Spindle 12','machining','HIGH');
INSERT INTO core.sku (id, code, name, customer) VALUES ('40000000-0000-4000-8000-000000000001', 'RAD-500-A', 'Radiator core 500 A', 'OEM-A');
INSERT INTO core.material_lot (id, lot_code, material_code, supplier, received_at) VALUES
 ('40000000-0000-4000-8000-000000000011', 'LOT-2609-114', 'AL-FIN-0.08', 'Supplier K', '2026-09-03 09:00');
INSERT INTO core.shift_calendar (plant_id, shift, starts_at, ends_at, valid_from) VALUES
 ('20000000-0000-4000-8000-000000000001', 'A', '06:00', '14:00', '2026-01-01'),
 ('20000000-0000-4000-8000-000000000001', 'B', '14:00', '22:00', '2026-01-01'),
 ('20000000-0000-4000-8000-000000000001', 'C', '22:00', '06:00', '2026-01-01');

-- ---------------------------------------------------------------------
-- 2. Tool registry (agent.tool — platform table; all read) and the agent registry (FR-01, C-03)
-- ---------------------------------------------------------------------
INSERT INTO agent.tool (id, name, kind, risk, schema_json, min_role, enabled) VALUES
 ('c0000000-0000-4000-8000-000000000001', 'get_signals',              'read', 'low', '{"type":"object","properties":{"line":{"type":"integer"},"status":{"type":"string"}},"required":["line"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000002', 'get_spc',                  'read', 'low', '{"type":"object","properties":{"characteristic":{"type":"string"},"line":{"type":"integer"}},"required":["characteristic"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000003', 'query_defects',            'read', 'low', '{"type":"object","properties":{"date_from":{"type":"string"},"date_to":{"type":"string"},"group_by":{"type":"string"}},"required":["date_from","date_to"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000004', 'get_case',                 'read', 'low', '{"type":"object","properties":{"case_id":{"type":"string"}},"required":["case_id"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000005', 'get_machine_health',       'read', 'low', '{"type":"object","properties":{"machine":{"type":"string"}},"required":["machine"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000006', 'get_alert_evidence',       'read', 'low', '{"type":"object","properties":{"alert_id":{"type":"integer"}},"required":["alert_id"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000007', 'get_trend',                'read', 'low', '{"type":"object","properties":{"machine":{"type":"string"},"signal":{"type":"string"},"days":{"type":"integer"}},"required":["machine","signal"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000008', 'get_machine_telemetry',    'read', 'low', '{"type":"object","properties":{"machine":{"type":"string"},"signal":{"type":"string"},"window":{"type":"string"}},"required":["machine","signal"]}', 'inspector', true),
 ('c0000000-0000-4000-8000-000000000009', 'get_pm_overdue',           'read', 'low', '{"type":"object","properties":{"line":{"type":"integer"}}}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000010', 'query_production',         'read', 'low', '{"type":"object","properties":{"date_from":{"type":"string"},"date_to":{"type":"string"},"line":{"type":"integer"}},"required":["date_from","date_to"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000011', 'get_oee',                  'read', 'low', '{"type":"object","properties":{"line":{"type":"integer"},"date_from":{"type":"string"},"date_to":{"type":"string"}},"required":["line"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000012', 'get_downtime_pareto',      'read', 'low', '{"type":"object","properties":{"line":{"type":"integer"},"days":{"type":"integer"}},"required":["line"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000013', 'get_schedule_risk',        'read', 'low', '{"type":"object","properties":{"line":{"type":"integer"},"shift":{"type":"string"}},"required":["line"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000014', 'get_stock_coverage',       'read', 'low', '{"type":"object","properties":{"sku":{"type":"string"}},"required":["sku"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000015', 'get_inbound_deliveries',   'read', 'low', '{"type":"object","properties":{"sku":{"type":"string"},"days":{"type":"integer"}},"required":["sku"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000016', 'get_lot_quality_history',  'read', 'low', '{"type":"object","properties":{"lot":{"type":"string"}},"required":["lot"]}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000017', 'get_shortage_risk',        'read', 'low', '{"type":"object","properties":{"line":{"type":"integer"},"days":{"type":"integer"}}}', 'viewer', true),
 ('c0000000-0000-4000-8000-000000000018', 'create_work_order',        'write','high','{"type":"object","properties":{"machine":{"type":"string"},"text":{"type":"string"}},"required":["machine","text"]}', 'manager', false);

INSERT INTO swarm.agent_registry (id, name, kind, display_name, version, description, module, output_schema, budget_json, schedule_cron, prompt_version, enabled) VALUES
 ('a0000000-0000-4000-8000-000000000001', 'quality',     'specialist', 'Quality Agent',     '1.2.0', 'SPC violations, defect-rate signals with significance, top defect classes, affected SKUs, open cases (FR-08) via QE-Agent tools', 'kaizenswarm.agents.quality',     'finding.v1', '{"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}', '0 6,14 * * *', 'specialist.v1', true),
 ('a0000000-0000-4000-8000-000000000002', 'maintenance', 'specialist', 'Maintenance Agent', '1.1.0', 'Degrading health index, open alerts with severity and lead time, overdue PM (FR-09) via MachineSense tools',                 'kaizenswarm.agents.maintenance', 'finding.v1', '{"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}', '0 6,14 * * *', 'specialist.v1', true),
 ('a0000000-0000-4000-8000-000000000003', 'production',  'specialist', 'Production Agent',  '1.1.0', 'Plan vs actual, OEE components, downtime Pareto, schedule risk (FR-10) via ShiftBrief tools',                              'kaizenswarm.agents.production',  'finding.v1', '{"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}', '0 6,14 * * *', 'specialist.v1', true),
 ('a0000000-0000-4000-8000-000000000004', 'material',    'specialist', 'Material Agent',    '1.0.0', 'Stock coverage, inbound delivery risk, lots with quality history, shortage risk (FR-11) via the IF-07 ERP read adapter',   'kaizenswarm.agents.material',    'finding.v1', '{"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}', '0 6,14 * * *', 'specialist.v1', true),
 ('a0000000-0000-4000-8000-000000000005', 'manager',     'manager',    'Manager Agent',     '1.2.0', 'Requests, deduplicates, relates, ranks, phrases (FR-15…FR-22); never a source of findings',                                'kaizenswarm.manager',            'briefing.v1', '{"tool_calls": 1, "tokens": 4000, "wall_ms": 40000}', NULL, 'manager_explain.v1', true),
 ('a0000000-0000-4000-8000-000000000006', 'logistics',   'specialist', 'Logistics Agent',   '0.1.0', 'Configuration-only placeholder (FR-06 / NFR-04): a fifth specialist added without Manager changes; disabled until its module ships', 'kaizenswarm.agents.logistics',   'finding.v1', '{"tool_calls": 8, "tokens": 4000, "wall_ms": 45000}', '0 6 * * *', 'specialist.v1', false);

INSERT INTO swarm.agent_domain (agent_id, domain) VALUES
 ('a0000000-0000-4000-8000-000000000001', 'quality'),
 ('a0000000-0000-4000-8000-000000000002', 'machine_health'),
 ('a0000000-0000-4000-8000-000000000003', 'production'),
 ('a0000000-0000-4000-8000-000000000004', 'material'),
 ('a0000000-0000-4000-8000-000000000006', 'logistics');

INSERT INTO swarm.agent_tool (agent_id, tool_id, ordinal) VALUES
 ('a0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001', 1),
 ('a0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002', 2),
 ('a0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003', 3),
 ('a0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000004', 4),
 ('a0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000016', 5),
 ('a0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000005', 1),
 ('a0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000006', 2),
 ('a0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000007', 3),
 ('a0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000008', 4),
 ('a0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000009', 5),
 ('a0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000010', 1),
 ('a0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000011', 2),
 ('a0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000012', 3),
 ('a0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000013', 4),
 ('a0000000-0000-4000-8000-000000000004', 'c0000000-0000-4000-8000-000000000014', 1),
 ('a0000000-0000-4000-8000-000000000004', 'c0000000-0000-4000-8000-000000000015', 2),
 ('a0000000-0000-4000-8000-000000000004', 'c0000000-0000-4000-8000-000000000016', 3),
 ('a0000000-0000-4000-8000-000000000004', 'c0000000-0000-4000-8000-000000000017', 4);

-- ---------------------------------------------------------------------
-- 3. Published scoring tables (FR-18 / AI-03) and relation rules (FR-17 / AI-04)
-- ---------------------------------------------------------------------
INSERT INTO swarm.scoring_weights (version, impact_json, likelihood_json, urgency_json, active, published_at, published_by, note) VALUES
 ('v1', '{"INFO": 0.2, "LOW": 0.4, "MEDIUM": 0.6, "HIGH": 0.8, "CRITICAL": 1.0}',
        '{"observed": 1.0, "trend": 0.8, "forecast": 0.6, "possible": 0.4}',
        '{"this_shift": 1.0, "today": 0.9, "within_3_days": 0.8, "this_week": 0.6, "later": 0.4}',
        true, '2026-09-01 09:00', 'd0000000-0000-4000-8000-000000000005', 'Initial published weights (IF-70). score = impact x likelihood x urgency x confidence; compound = 1 - prod(1 - s).');

INSERT INTO swarm.relation_rule (id, code, match_keys, min_domains, window_hours, enabled, description) VALUES
 ('e0000000-0000-4000-8000-000000000001', 'same_line',    '{line}',    2, 24, true, 'Findings from >= 2 domains on the same line within 24 h'),
 ('e0000000-0000-4000-8000-000000000002', 'same_lot',     '{lot}',     2, 72, true, 'Findings from >= 2 domains on the same material lot within 72 h'),
 ('e0000000-0000-4000-8000-000000000003', 'same_machine', '{machine}', 2, 24, true, 'Findings from >= 2 domains on the same machine within 24 h'),
 ('e0000000-0000-4000-8000-000000000004', 'same_sku',     '{sku}',     2, 48, true, 'Findings from >= 2 domains on the same SKU within 48 h');

-- ---------------------------------------------------------------------
-- 4. Routine runs 405–410 (shift start 06:00 / 14:00). Maintenance reports M-07 from run 407 on (AC-08).
--    Quality reports a line-2 scratch rate in 405 that is later dismissed as a false positive (FR-26).
-- ---------------------------------------------------------------------
DO $seed$
DECLARE
    rec      record;
    ag       record;
    run_id   uuid;
    ar_id    uuid;
    as_id    uuid;
    msg_id   uuid;
    t0       timestamptz;
    k        integer;
    lease_s  timestamptz;
    lease_e  timestamptz;
    payload  jsonb;
    budget   jsonb := '{"quality": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "maintenance": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "production": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "material": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}}'::jsonb;
    m07_pct  text;
    m07_days text;
    items    jsonb;
    txt      text;
    b_id     uuid;
BEGIN
    FOR rec IN SELECT * FROM (VALUES
        (405, '2026-09-07 06:00'::timestamptz, 'A', false, '0',    '0'),
        (406, '2026-09-07 14:00'::timestamptz, 'B', false, '0',    '0'),
        (407, '2026-09-08 06:00'::timestamptz, 'A', true,  '6.1',  '2'),
        (408, '2026-09-08 14:00'::timestamptz, 'B', true,  '7.9',  '3'),
        (409, '2026-09-09 06:00'::timestamptz, 'A', true,  '10.2', '4'),
        (410, '2026-09-09 14:00'::timestamptz, 'B', true,  '12.5', '5')) v(no, ts, shift, m07, pct, days)
    LOOP
        t0 := rec.ts;
        run_id := ('b0000000-0000-4000-8000-000000000' || rec.no)::uuid;
        INSERT INTO swarm.run (id, run_no, trigger, scope_json, weights_version, budget_json, agent_count, started_at, deadline_at, status)
        VALUES (run_id, rec.no, 'schedule', jsonb_build_object('plant', 1, 'shift', rec.shift, 'date', to_char(t0, 'YYYY-MM-DD')),
                'v1', budget, 4, t0, t0 + interval '180 seconds', 'running');
        k := 0;
        FOR ag IN SELECT a.id, a.name FROM swarm.agent_registry a WHERE a.kind = 'specialist' AND a.enabled ORDER BY a.id LOOP
            k := k + 1;
            INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
            VALUES (run_id, 'orchestrator', ag.name, 'RequestAssessment', 'agent.request.' || ag.name,
                    jsonb_build_object('run_no', rec.no, 'agent', ag.name, 'scope', jsonb_build_object('plant', 1, 'shift', rec.shift),
                                       'deadline_at', to_char(t0 + interval '61 seconds', 'YYYY-MM-DD"T"HH24:MI:SS+07:00'),
                                       'budget', budget -> ag.name),
                    rec.no::text, t0 + interval '1 second');
            INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
            VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name,
                    jsonb_build_object('status', 'started'), rec.no::text, t0 + interval '2 seconds');
            ar_id := ('a2000000-0000-4000-8000-000000' || rec.no || '00' || k)::uuid;
            INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
            VALUES (ar_id, t0 + interval '3 seconds', rec.no::text, 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1',
                    jsonb_build_object('scope', jsonb_build_object('plant', 1, 'shift', rec.shift), 'facts', 3), 900 + 40 * k, 180 + 10 * k, 12000 + 500 * k, 3, 'ok');
            INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
            SELECT ar_id, o, t.name, jsonb_build_object('line', o), md5(rec.no::text || ag.name || o::text), 10 * o, 800 + 100 * o, true
              FROM swarm.agent_tool at2 JOIN agent.tool t ON t.id = at2.tool_id, generate_series(1, 3) o
             WHERE at2.agent_id = ag.id AND at2.ordinal = LEAST(o, 3);
            lease_s := t0 + interval '35 seconds' + (k - 1) * interval '15 seconds';
            lease_e := lease_s + interval '12 seconds';
            INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
            VALUES (run_id, ag.id, ar_id, 'qwen2.5:7b-instruct-q4_K_M', lease_s, lease_e, 900 + 40 * k, 180 + 10 * k);
            IF ag.name = 'maintenance' AND rec.m07 THEN
                payload := jsonb_build_object(
                    'agent', 'maintenance', 'domain', 'machine_health', 'scope', jsonb_build_object('plant', 1, 'line', 3, 'machine', 'M-07'),
                    'issue_code', 'machine.degradation', 'title', 'Bearing temperature trending up on M-07',
                    'summary', format('Press M-07 drive-side bearing temperature +%s %% over %s days; alert 1184 open', rec.pct, rec.days),
                    'severity', 'HIGH', 'confidence', 0.70, 'likelihood_class', 'observed', 'horizon', 'within_3_days', 'freshness_min', 3,
                    'evidence', jsonb_build_array(jsonb_build_object('kind', 'metric', 'ref', 'telemetry:M-07:bearing_temp:2026-09-03..' || to_char(t0, 'DD')),
                                                  jsonb_build_object('kind', 'alert', 'ref', 'alert:1184')),
                    'recommended_action', 'Inspect M-07 drive-side bearing within 3 days', 'owner_suggestion', 'Maintenance',
                    'impact_estimate', jsonb_build_object('downtime_risk_h', 6, 'affected_lines', jsonb_build_array(3)));
            ELSIF ag.name = 'quality' AND rec.no = 405 THEN
                payload := jsonb_build_object(
                    'agent', 'quality', 'domain', 'quality', 'scope', jsonb_build_object('plant', 1, 'line', 2, 'shift', 'A'),
                    'issue_code', 'quality.defect_rate', 'title', 'Scratch rate 1.9 % on line 2 vs 1.2 % baseline',
                    'summary', 'Scratch rate 1.9 % on line 2 (n = 40) vs 1.2 % 7-day baseline; signal S-236',
                    'severity', 'MEDIUM', 'confidence', 0.55, 'likelihood_class', 'observed', 'horizon', 'today', 'freshness_min', 6,
                    'evidence', jsonb_build_array(jsonb_build_object('kind', 'signal', 'ref', 'signal:S-236')),
                    'recommended_action', 'Check sample size before acting; confirm with the next lot', 'owner_suggestion', 'QE',
                    'impact_estimate', jsonb_build_object('scrap_risk_pct', 1.9, 'affected_lines', jsonb_build_array(2)));
            ELSE
                payload := NULL;
            END IF;
            IF payload IS NOT NULL THEN
                INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
                VALUES (run_id, ag.name, 'orchestrator', 'Finding', 'agent.finding.' || ag.name, payload, rec.no::text, lease_e)
                RETURNING id INTO msg_id;
                INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
                VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name,
                        jsonb_build_object('status', 'done', 'usage', jsonb_build_object('tool_calls', 3, 'tokens', 1080 + 50 * k, 'wall_ms', 30000 + 1000 * k)),
                        rec.no::text, lease_e + interval '1 second');
                as_id := ('a1000000-0000-4000-8000-000000' || rec.no || '00' || k)::uuid;
                INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
                VALUES (as_id, run_id, ag.id, ar_id, 'findings', 1, (payload ->> 'confidence')::numeric, (payload ->> 'freshness_min')::numeric, 3, 1080 + 50 * k, 30000 + 1000 * k, t0 + interval '1 second', lease_e + interval '1 second');
                PERFORM swarm.upsert_finding(run_id, ag.name, payload, msg_id, as_id);
            ELSE
                INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
                VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name,
                        jsonb_build_object('status', 'nothing_significant', 'checked', jsonb_build_array('thresholds', 'baselines', 'open items'),
                                           'usage', jsonb_build_object('tool_calls', 3, 'tokens', 1080 + 50 * k, 'wall_ms', 30000 + 1000 * k), 'freshness_min', 4),
                        rec.no::text, lease_e + interval '1 second');
                as_id := ('a1000000-0000-4000-8000-000000' || rec.no || '00' || k)::uuid;
                INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
                VALUES (as_id, run_id, ag.id, ar_id, 'nothing_significant', 0, 0.9, 4, 3, 1080 + 50 * k, 30000 + 1000 * k, t0 + interval '1 second', lease_e + interval '1 second');
            END IF;
        END LOOP;
        PERFORM swarm.score_run(run_id);
        PERFORM swarm.detect_compounds(run_id);
        PERFORM swarm.rank_run(run_id);
        UPDATE swarm.run SET status = 'completed', finished_at = t0 + interval '100 seconds' WHERE id = run_id;
        PERFORM swarm.expire_findings(run_id);
        items := swarm.briefing_items(run_id, 3);
        SELECT COALESCE(string_agg(format('%s. [%s %s] %s → %s Evidence: %s', e ->> 'rank', e ->> 'severity', e ->> 'score', e ->> 'title',
                                          e ->> 'recommended_action', e ->> 'evidence'), E'\n' ORDER BY (e ->> 'rank')::int), 'No findings this run.')
          INTO txt FROM jsonb_array_elements(items) e;
        txt := format(E'🏭 Shift briefing — %s · Shift %s · Plant 1\nTOP 3 RISKS\n%s\nPartial: no. Run %s · %s · 4 agents · 12 tool calls.',
                      to_char(t0, 'YYYY-MM-DD'), rec.shift, txt, rec.no, swarm.wall_label(100000));
        b_id := ('a3000000-0000-4000-8000-000000' || rec.no || '001')::uuid;
        INSERT INTO agent.briefing (id, generated_at, scope_json, lang, top_risks_json, text, partial, partial_reason, delivered_at)
        VALUES (b_id, t0 + interval '101 seconds', jsonb_build_object('plant', 1, 'shift', rec.shift, 'date', to_char(t0, 'YYYY-MM-DD')), 'en', items, txt, false, NULL, t0 + interval '105 seconds');
        INSERT INTO swarm.briefing_run (briefing_id, run_id, top_n, rank_json, phrasing_attempts, template_fallback, model, tokens_in, tokens_out)
        VALUES (b_id, run_id, 3, swarm.rank_run(run_id), 1, false, 'qwen2.5:7b-instruct-q4_K_M', 700, 160);
        INSERT INTO swarm.delivery (kind, briefing_id, channel, status, scheduled_at, delivered_at, message_ref)
        VALUES ('briefing', b_id, 'discord', 'sent', t0 + interval '101 seconds', t0 + interval '105 seconds', 'discord:msg:' || rec.no);
    END LOOP;
END
$seed$;

-- The line-2 scratch signal of run 405 is dismissed by the QE engineer (false positive: n = 40) — feeds swarm.agent_precision() (FR-26)
INSERT INTO swarm.finding_action (finding_id, kind, actor_id, reason, dismiss_reason, ts)
SELECT fe.finding_id, 'dismiss', 'd0000000-0000-4000-8000-000000000002', 'n = 40 is below the 100-sample minimum for a rate signal', 'false_positive', '2026-09-07 17:30'
  FROM swarm.finding_ext fe WHERE fe.issue_key = 'quality.defect_rate|line=2,plant=1';

-- ---------------------------------------------------------------------
-- 5. Run 411 — SRS-13 Appendix A (2026-09-10 · Shift A · Plant 1): 4 agents · 23 tool calls · 2 min 14 s
-- ---------------------------------------------------------------------
DO $r411$
DECLARE
    run_id  uuid := 'b0000000-0000-4000-8000-000000000411';
    t0      timestamptz := '2026-09-10 06:00';
    budget  jsonb := '{"quality": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "maintenance": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "production": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "material": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}}'::jsonb;
    ag      record;
    ar_id   uuid;
    as_id   uuid;
    msg_id  uuid;
    payload jsonb;
    k       integer := 0;
    n_tools integer;
    tk_in   integer;
    tk_out  integer;
    t_tools interval;
    lease_s timestamptz;
    lease_e timestamptz;
    fresh   numeric;
    items   jsonb;
    b_id    uuid;
BEGIN
    INSERT INTO swarm.run (id, run_no, trigger, scope_json, weights_version, budget_json, agent_count, started_at, deadline_at, status)
    VALUES (run_id, 411, 'schedule', '{"plant": 1, "shift": "A", "date": "2026-09-10"}', 'v1', budget, 4, t0, t0 + interval '180 seconds', 'running');
    lease_e := t0 + interval '41 seconds';
    FOR ag IN SELECT a.id, a.name FROM swarm.agent_registry a WHERE a.kind = 'specialist' AND a.enabled ORDER BY a.id LOOP
        k := k + 1;
        n_tools := CASE ag.name WHEN 'quality' THEN 7 WHEN 'maintenance' THEN 6 ELSE 5 END;
        tk_in   := CASE ag.name WHEN 'quality' THEN 1420 WHEN 'maintenance' THEN 1180 WHEN 'production' THEN 1050 ELSE 990 END;
        tk_out  := CASE ag.name WHEN 'quality' THEN 310 WHEN 'maintenance' THEN 260 WHEN 'production' THEN 240 ELSE 230 END;
        t_tools := CASE ag.name WHEN 'quality' THEN interval '30 seconds' WHEN 'maintenance' THEN interval '28 seconds' WHEN 'production' THEN interval '25 seconds' ELSE interval '24 seconds' END;
        fresh   := CASE ag.name WHEN 'quality' THEN 5 WHEN 'maintenance' THEN 2 WHEN 'production' THEN 1 ELSE 360 END;
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, 'orchestrator', ag.name, 'RequestAssessment', 'agent.request.' || ag.name,
                jsonb_build_object('run_no', 411, 'agent', ag.name, 'scope', '{"plant": 1, "shift": "A", "date": "2026-09-10"}'::jsonb,
                                   'deadline_at', '2026-09-10T06:01:01+07:00', 'budget', budget -> ag.name), '411', t0 + interval '1 second');
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name, '{"status": "started"}', '411', t0 + interval '2 seconds');
        ar_id := ('a2000000-0000-4000-8000-000000411' || '00' || k)::uuid;
        INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
        VALUES (ar_id, t0 + interval '3 seconds', '411', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1',
                jsonb_build_object('scope', '{"plant": 1, "shift": "A"}'::jsonb, 'facts', n_tools), tk_in, tk_out, 0, n_tools, 'ok');
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name,
                jsonb_build_object('status', 'tools_done', 'usage', jsonb_build_object('tool_calls', n_tools, 'tokens', 0, 'wall_ms', EXTRACT(EPOCH FROM t_tools)::int * 1000)),
                '411', t0 + interval '3 seconds' + t_tools);
        -- the specialist's tool calls (platform agent.tool_call; AC-09)
        INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
        SELECT ar_id, o, t.name,
               CASE ag.name
                    WHEN 'quality'     THEN jsonb_build_object('line', ((o - 1) % 3) + 1, 'date_from', '2026-09-03', 'date_to', '2026-09-10')
                    WHEN 'maintenance' THEN jsonb_build_object('machine', CASE WHEN o <= 3 THEN 'M-07' ELSE 'M-12' END, 'signal', 'bearing_temp', 'days', 7)
                    WHEN 'production'  THEN jsonb_build_object('line', ((o - 1) % 3) + 1, 'date_from', '2026-09-08', 'date_to', '2026-09-10')
                    ELSE jsonb_build_object('sku', 'RAD-500-A', 'days', 3) END,
               md5('411' || ag.name || o::text), 5 * o, 600 + 90 * o, true
          FROM generate_series(1, n_tools) o
          JOIN swarm.agent_tool at2 ON at2.agent_id = ag.id AND at2.ordinal = ((o - 1) % (SELECT count(*) FROM swarm.agent_tool WHERE agent_id = ag.id)) + 1
          JOIN agent.tool t ON t.id = at2.tool_id;
        -- one phrasing call each, strictly sequential on the GPU lease (C-05)
        lease_s := lease_e;
        lease_e := lease_s + CASE ag.name WHEN 'quality' THEN interval '22 seconds' WHEN 'maintenance' THEN interval '19 seconds' ELSE interval '18 seconds' END;
        INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
        VALUES (run_id, ag.id, ar_id, 'qwen2.5:7b-instruct-q4_K_M', lease_s, lease_e, tk_in, tk_out);
        UPDATE agent.run SET latency_ms = EXTRACT(EPOCH FROM (lease_e - lease_s))::int * 1000 WHERE id = ar_id;
        payload := CASE ag.name
            WHEN 'quality' THEN jsonb_build_object(
                'agent', 'quality', 'domain', 'quality', 'scope', '{"plant": 1, "line": 3, "sku": "RAD-500-A", "shift": "A"}'::jsonb,
                'issue_code', 'quality.defect_rate', 'title', 'Defect rate 5.82 % on line 3 (+141 % vs 7-day)',
                'summary', 'Defect rate 5.82 % (+141 % vs 7-day baseline 2.41 %, p<0.001) on line 3, shift A; top class missing parts; signal S-241 open; affected SKU RAD-500-A, lot LOT-2609-114',
                'severity', 'HIGH', 'confidence', 0.85, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 5,
                'evidence', '[{"kind": "signal", "ref": "signal:S-241"}, {"kind": "metric", "ref": "defect_rate:line3:2026-09-10:A"}]'::jsonb,
                'recommended_action', 'Hold RAD-500-A lot LOT-2609-114 pending QE review; verify the missing-parts station on line 3',
                'owner_suggestion', 'QE', 'impact_estimate', '{"scrap_risk_pct": 5.82, "affected_lines": [3]}'::jsonb)
            WHEN 'maintenance' THEN jsonb_build_object(
                'agent', 'maintenance', 'domain', 'machine_health', 'scope', '{"plant": 1, "line": 3, "machine": "M-07"}'::jsonb,
                'issue_code', 'machine.degradation', 'title', 'Bearing temperature trending up on M-07',
                'summary', 'Press M-07 drive-side bearing temperature +13.8 % over 5 days (2026-09-05..10); alert 1184 open; health index 71',
                'severity', 'HIGH', 'confidence', 0.78, 'likelihood_class', 'observed', 'horizon', 'within_3_days', 'freshness_min', 2,
                'evidence', '[{"kind": "metric", "ref": "telemetry:M-07:bearing_temp:2026-09-03..10"}, {"kind": "alert", "ref": "alert:1184"}]'::jsonb,
                'recommended_action', 'Inspect M-07 drive-side bearing within 3 days',
                'owner_suggestion', 'Maintenance', 'impact_estimate', '{"downtime_risk_h": 6, "affected_lines": [3]}'::jsonb)
            WHEN 'production' THEN jsonb_build_object(
                'agent', 'production', 'domain', 'production', 'scope', '{"plant": 1, "line": 1}'::jsonb,
                'issue_code', 'production.performance_loss', 'title', 'OEE performance loss on Line 1',
                'summary', 'Performance 78 % vs 91 % baseline; micro-stops up 3× since 09-08 (changeover and unload station)',
                'severity', 'MEDIUM', 'confidence', 0.96, 'likelihood_class', 'observed', 'horizon', 'today', 'freshness_min', 1,
                'evidence', '[{"kind": "oee", "ref": "oee:line1:2026-09-08..10"}, {"kind": "downtime", "ref": "downtime:line1:2026-09-08..10"}]'::jsonb,
                'recommended_action', 'Observe changeover and unload station on Line 1',
                'owner_suggestion', 'Production', 'impact_estimate', '{"output_loss_pct": 13, "affected_lines": [1]}'::jsonb)
            ELSE jsonb_build_object(
                'agent', 'material', 'domain', 'material', 'scope', '{"plant": 1, "sku": "RAD-500-A"}'::jsonb,
                'issue_code', 'material.shortage', 'title', 'Coverage risk for SKU RAD-500-A',
                'summary', 'Stock coverage 1.4 days against the 3-day schedule; incoming delivery PO-2026-004821 confirmed only for 2026-09-14',
                'severity', 'HIGH', 'confidence', 0.89, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 360,
                'evidence', '[{"kind": "stock", "ref": "stock:RAD-500-A"}, {"kind": "po", "ref": "po:PO-2026-004821"}]'::jsonb,
                'recommended_action', 'Confirm supplier ETA today or re-sequence the schedule',
                'owner_suggestion', 'Purchasing', 'impact_estimate', '{"schedule_risk_days": 1.6, "affected_lines": [3]}'::jsonb)
            END;
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, ag.name, 'orchestrator', 'Finding', 'agent.finding.' || ag.name, payload, '411', lease_e)
        RETURNING id INTO msg_id;
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name,
                jsonb_build_object('status', 'done', 'usage', jsonb_build_object('tool_calls', n_tools, 'tokens', tk_in + tk_out,
                                   'wall_ms', (EXTRACT(EPOCH FROM t_tools) + EXTRACT(EPOCH FROM (lease_e - lease_s)))::int * 1000), 'freshness_min', fresh),
                '411', lease_e + interval '1 second');
        as_id := ('a1000000-0000-4000-8000-000000411' || '00' || k)::uuid;
        INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
        VALUES (as_id, run_id, ag.id, ar_id, 'findings', 1, (payload ->> 'confidence')::numeric, fresh, n_tools, tk_in + tk_out,
                (EXTRACT(EPOCH FROM t_tools) + EXTRACT(EPOCH FROM (lease_e - lease_s)))::int * 1000, t0 + interval '1 second', lease_e + interval '1 second');
        PERFORM swarm.upsert_finding(run_id, ag.name, payload, msg_id, as_id);
    END LOOP;
    -- Manager: score → relate → rank (FR-16…FR-18); the LLM is not involved
    PERFORM swarm.score_run(run_id);
    PERFORM swarm.detect_compounds(run_id);
    PERFORM swarm.rank_run(run_id);
    UPDATE swarm.run SET status = 'completed', finished_at = t0 + interval '134 seconds' WHERE id = run_id;
    PERFORM swarm.expire_findings(run_id);
    items := swarm.briefing_items(run_id, 3);
    -- The Manager's model phrases the briefing from top_risks_json only; every number is claim-checked on insert (AC-07)
    INSERT INTO agent.briefing (id, generated_at, scope_json, lang, top_risks_json, text, partial, partial_reason, delivered_at) VALUES
    ('a3000000-0000-4000-8000-000000411001', t0 + interval '135 seconds', '{"plant": 1, "shift": "A", "date": "2026-09-10"}', 'en', items,
E'🏭 Shift briefing — 2026-09-10 · Shift A · Plant 1
Data freshness: quality 5 min · maintenance 2 min · production 1 min · material 6 h ⚠

TOP 3 RISKS

1. [HIGH 0.84] Line 3 — compound risk: quality + maintenance
   Defect rate 5.82 % (+141 % vs 7-day, p<0.001) AND press M-07 bearing
   temperature +13.8 % over 5 days. Both concentrated on the same line/shift.
   → Inspect M-07 drive-side bearing today; hold RAD-500-A lot LOT-2609-114.
   Evidence: signal S-241 · alert 1184        Owner: Maintenance + QE

2. [HIGH 0.71] Material — coverage risk for SKU RAD-500-A
   Stock coverage 1.4 days against the 3-day schedule; incoming delivery
   confirmed only for 2026-09-14.
   → Confirm supplier ETA today or re-sequence the schedule.
   Evidence: stock:RAD-500-A · po:PO-2026-004821       Owner: Purchasing

3. [MEDIUM 0.52] Production — OEE performance loss on Line 1
   Performance 78 % vs 91 % baseline; micro-stops up 3× since 09-08.
   → Observe changeover and unload station on Line 1.
   Evidence: oee:line1:2026-09-08..10                  Owner: Production

Nothing significant reported by: (none — all domains reported)
Partial: no. Run 411 · 2 min 14 s · 4 agents · 23 tool calls.', false, NULL, t0 + interval '140 seconds'),
    ('a3000000-0000-4000-8000-000000411002', t0 + interval '150 seconds', '{"plant": 1, "shift": "A", "date": "2026-09-10"}', 'th', items,
E'🏭 สรุปความเสี่ยงต้นกะ — 2026-09-10 · กะ A · โรงงาน 1
ความสดของข้อมูล: คุณภาพ 5 min · ซ่อมบำรุง 2 min · ผลิต 1 min · วัตถุดิบ 6 h ⚠
3 ความเสี่ยงสูงสุด
1. [HIGH 0.84] ไลน์ 3 — ความเสี่ยงร่วม: คุณภาพ + ซ่อมบำรุง — อัตราของเสีย 5.82 % (+141 % เทียบ 7-day, p<0.001) และอุณหภูมิแบริ่งเครื่องปั๊ม M-07 +13.8 % ใน 5 days บนไลน์เดียวกัน → ตรวจแบริ่งด้านขับของ M-07 วันนี้; กักล็อต LOT-2609-114 ของ RAD-500-A · หลักฐาน: S-241 · alert 1184 · ผู้รับผิดชอบ: ซ่อมบำรุง + QE
2. [HIGH 0.71] วัตถุดิบ — สต็อก RAD-500-A ครอบคลุม 1.4 days เทียบแผน 3-day; ของเข้ายืนยันเฉพาะ 2026-09-14 → ยืนยัน ETA ผู้ขายวันนี้หรือจัดลำดับแผนใหม่ · หลักฐาน: stock:RAD-500-A · po:PO-2026-004821 · ผู้รับผิดชอบ: จัดซื้อ
3. [MEDIUM 0.52] ผลิต — OEE ไลน์ 1: Performance 78 % เทียบฐาน 91 %; micro-stops เพิ่ม 3× ตั้งแต่ 09-08 → สังเกตการเปลี่ยนรุ่นและสถานีปลดชิ้นงานไลน์ 1 · หลักฐาน: oee:line1:2026-09-08..10 · ผู้รับผิดชอบ: ผลิต
ทุกโดเมนรายงานครบ · ไม่ใช่รายงานบางส่วน · Run 411 · 2 min 14 s · 4 agents · 23 tool calls', false, NULL, t0 + interval '155 seconds'),
    ('a3000000-0000-4000-8000-000000411003', t0 + interval '165 seconds', '{"plant": 1, "shift": "A", "date": "2026-09-10"}', 'ja', items,
E'🏭 シフトブリーフィング — 2026-09-10 · シフト A · 工場 1
データ鮮度: 品質 5 min · 保全 2 min · 生産 1 min · 資材 6 h ⚠
上位 3 リスク
1. [HIGH 0.84] ライン 3 — 複合リスク: 品質 + 保全 — 不良率 5.82 %（7-day 比 +141 %、p<0.001）と プレス M-07 の軸受温度 +13.8 %（5 days）が同一ラインに集中 → 本日 M-07 駆動側軸受を点検; RAD-500-A ロット LOT-2609-114 を保留 · 根拠: S-241 · alert 1184 · 担当: 保全 + QE
2. [HIGH 0.71] 資材 — RAD-500-A の在庫カバー 1.4 days（計画 3-day）; 入荷確定は 2026-09-14 のみ → 本日サプライヤー ETA を確認、または計画を組み替え · 根拠: stock:RAD-500-A · po:PO-2026-004821 · 担当: 購買
3. [MEDIUM 0.52] 生産 — ライン 1 の OEE パフォーマンス低下: 78 %（基準 91 %）; 09-08 以降チョコ停 3× → ライン 1 の段取り替えと取り出しステーションを観察 · 根拠: oee:line1:2026-09-08..10 · 担当: 生産
全ドメイン報告済み · 部分結果ではない · Run 411 · 2 min 14 s · 4 agents · 23 tool calls', false, NULL, t0 + interval '170 seconds');
    INSERT INTO swarm.briefing_run (briefing_id, run_id, top_n, rank_json, phrasing_attempts, template_fallback, model, tokens_in, tokens_out) VALUES
    ('a3000000-0000-4000-8000-000000411001', run_id, 3, swarm.rank_run(run_id), 1, false, 'qwen2.5:7b-instruct-q4_K_M', 1210, 420),
    ('a3000000-0000-4000-8000-000000411002', run_id, 3, swarm.rank_run(run_id), 1, false, 'qwen2.5:7b-instruct-q4_K_M', 1290, 510),
    ('a3000000-0000-4000-8000-000000411003', run_id, 3, swarm.rank_run(run_id), 1, false, 'qwen2.5:7b-instruct-q4_K_M', 1290, 480);
    INSERT INTO swarm.delivery (kind, briefing_id, channel, status, scheduled_at, delivered_at, message_ref) VALUES
    ('briefing', 'a3000000-0000-4000-8000-000000411001', 'discord',   'sent', t0 + interval '135 seconds', t0 + interval '140 seconds', 'discord:msg:411-en'),
    ('briefing', 'a3000000-0000-4000-8000-000000411002', 'discord',   'sent', t0 + interval '150 seconds', t0 + interval '155 seconds', 'discord:msg:411-th'),
    ('briefing', 'a3000000-0000-4000-8000-000000411001', 'dashboard', 'sent', t0 + interval '135 seconds', t0 + interval '135 seconds', 'web:briefing:411');
END
$r411$;

-- People act on the blackboard (FR-25): acknowledge, assign, snooze — only through swarm.finding_action
INSERT INTO swarm.finding_action (finding_id, kind, actor_id, reason, ts)
SELECT fe.finding_id, 'acknowledge', 'd0000000-0000-4000-8000-000000000004', 'Seen at shift start', '2026-09-10 06:31'
  FROM swarm.finding_ext fe WHERE fe.issue_key = 'machine.degradation|machine=M-07,plant=1';
INSERT INTO swarm.finding_action (finding_id, kind, actor_id, reason, assignee_id, ts)
SELECT fe.finding_id, 'assign', 'd0000000-0000-4000-8000-000000000004', 'Bearing inspection today', 'd0000000-0000-4000-8000-000000000003', '2026-09-10 06:40'
  FROM swarm.finding_ext fe WHERE fe.issue_key = 'machine.degradation|machine=M-07,plant=1';
INSERT INTO swarm.finding_action (finding_id, kind, actor_id, reason, ts)
SELECT fe.finding_id, 'acknowledge', 'd0000000-0000-4000-8000-000000000004', 'Seen at shift start', '2026-09-10 06:32'
  FROM swarm.finding_ext fe WHERE fe.issue_key = 'quality.defect_rate|line=3,plant=1';
INSERT INTO swarm.finding_action (finding_id, kind, actor_id, reason, assignee_id, ts)
SELECT fe.finding_id, 'assign', 'd0000000-0000-4000-8000-000000000004', 'QE to review the missing-parts station', 'd0000000-0000-4000-8000-000000000002', '2026-09-10 06:41'
  FROM swarm.finding_ext fe WHERE fe.issue_key = 'quality.defect_rate|line=3,plant=1';
INSERT INTO swarm.finding_action (finding_id, kind, actor_id, reason, snooze_until, ts)
SELECT fe.finding_id, 'snooze', 'd0000000-0000-4000-8000-000000000001', 'Supplier call at 08:00 tomorrow', '2026-09-11 08:00', '2026-09-10 07:05'
  FROM swarm.finding_ext fe WHERE fe.issue_key = 'material.shortage|plant=1,sku=RAD-500-A';

-- ---------------------------------------------------------------------
-- 6. Run 412 — 2026-09-10 Shift B: Maintenance runner killed mid-run (AC-02); lot LOT-2609-114 reported by two agents (AC-03)
-- ---------------------------------------------------------------------
DO $r412$
DECLARE
    run_id  uuid := 'b0000000-0000-4000-8000-000000000412';
    t0      timestamptz := '2026-09-10 14:00';
    budget  jsonb := '{"quality": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "maintenance": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "production": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "material": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}}'::jsonb;
    a_q     uuid := 'a0000000-0000-4000-8000-000000000001';
    a_mt    uuid := 'a0000000-0000-4000-8000-000000000002';
    a_p     uuid := 'a0000000-0000-4000-8000-000000000003';
    a_m     uuid := 'a0000000-0000-4000-8000-000000000004';
    ag      record;
    msg_id  uuid;
    as_id   uuid;
    p_q1    jsonb;
    p_q2    jsonb;
    p_m1    jsonb;
    p_m2    jsonb;
    items   jsonb;
BEGIN
    INSERT INTO swarm.run (id, run_no, trigger, scope_json, weights_version, budget_json, agent_count, started_at, deadline_at, status)
    VALUES (run_id, 412, 'schedule', '{"plant": 1, "shift": "B", "date": "2026-09-10"}', 'v1', budget, 4, t0, t0 + interval '180 seconds', 'running');
    FOR ag IN SELECT a.id, a.name FROM swarm.agent_registry a WHERE a.kind = 'specialist' AND a.enabled ORDER BY a.id LOOP
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, 'orchestrator', ag.name, 'RequestAssessment', 'agent.request.' || ag.name,
                jsonb_build_object('run_no', 412, 'agent', ag.name, 'scope', '{"plant": 1, "shift": "B", "date": "2026-09-10"}'::jsonb,
                                   'deadline_at', '2026-09-10T14:01:01+07:00', 'budget', budget -> ag.name), '412', t0 + interval '1 second');
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name, '{"status": "started"}', '412', t0 + interval '2 seconds');
    END LOOP;
    -- quality: two findings (S-241 again; the lot's quality history)
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000412001', t0 + interval '3 seconds', '412', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 8}', 1560, 340, 21000, 8, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000412001', o, (ARRAY['get_signals','get_signals','get_signals','query_defects','get_case','get_lot_quality_history','get_spc','get_spc'])[o],
           jsonb_build_object('ordinal', o), md5('412quality' || o::text), 4 * o, 500 + 70 * o, true
      FROM generate_series(1, 8) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_q, 'a2000000-0000-4000-8000-000000412001', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '38 seconds', t0 + interval '59 seconds', 1560, 340);
    p_q1 := jsonb_build_object(
        'agent', 'quality', 'domain', 'quality', 'scope', '{"plant": 1, "line": 3, "sku": "RAD-500-A", "shift": "B"}'::jsonb,
        'issue_code', 'quality.defect_rate', 'title', 'Defect rate 5.82 % on line 3 (+141 % vs 7-day)',
        'summary', 'Defect rate 5.82 % (+141 % vs 7-day baseline 2.41 %, p<0.001) on line 3; signal S-241 still open; affected SKU RAD-500-A, lot LOT-2609-114',
        'severity', 'HIGH', 'confidence', 0.85, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 4,
        'evidence', '[{"kind": "signal", "ref": "signal:S-241"}, {"kind": "metric", "ref": "defect_rate:line3:2026-09-10:B"}]'::jsonb,
        'recommended_action', 'Hold RAD-500-A lot LOT-2609-114 pending QE review; verify the missing-parts station on line 3',
        'owner_suggestion', 'QE', 'impact_estimate', '{"scrap_risk_pct": 5.82, "affected_lines": [3]}'::jsonb);
    p_q2 := jsonb_build_object(
        'agent', 'quality', 'domain', 'quality', 'scope', '{"plant": 1, "line": 3, "sku": "RAD-500-A", "lot": "LOT-2609-114"}'::jsonb,
        'issue_code', 'lot.quality_history', 'title', 'Lot LOT-2609-114 has quality history',
        'summary', 'Lot LOT-2609-114 (RAD-500-A fin stock) has quality history: 2 rejections in 30 days; open case QC-0241 on line 3',
        'severity', 'MEDIUM', 'confidence', 0.80, 'likelihood_class', 'observed', 'horizon', 'this_week', 'freshness_min', 4,
        'evidence', '[{"kind": "lot", "ref": "lot:LOT-2609-114"}, {"kind": "case", "ref": "case:QC-0241"}]'::jsonb,
        'recommended_action', 'Hold lot LOT-2609-114; QE to review the lot history before release',
        'owner_suggestion', 'QE', 'impact_estimate', '{"scrap_risk_pct": 2.1, "affected_lines": [3]}'::jsonb);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'quality', 'orchestrator', 'Finding', 'agent.finding.quality', p_q1, '412', t0 + interval '59 seconds') RETURNING id INTO msg_id;
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000412001', run_id, a_q, 'a2000000-0000-4000-8000-000000412001', 'findings', 2, 0.85, 4, 8, 1900, 55000, t0 + interval '1 second', t0 + interval '60 seconds');
    PERFORM swarm.upsert_finding(run_id, 'quality', p_q1, msg_id, 'a1000000-0000-4000-8000-000000412001');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'quality', 'orchestrator', 'Finding', 'agent.finding.quality', p_q2, '412', t0 + interval '59 seconds') RETURNING id INTO msg_id;
    PERFORM swarm.upsert_finding(run_id, 'quality', p_q2, msg_id, 'a1000000-0000-4000-8000-000000412001');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'quality', 'orchestrator', 'StatusUpdate', 'agent.status.quality',
            '{"status": "done", "usage": {"tool_calls": 8, "tokens": 1900, "wall_ms": 55000}, "freshness_min": 4}', '412', t0 + interval '60 seconds');
    -- material: the same lot (AC-03) and the coverage risk again
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000412004', t0 + interval '3 seconds', '412', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 7}', 1210, 290, 18000, 7, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000412004', o, (ARRAY['get_stock_coverage','get_inbound_deliveries','get_lot_quality_history','get_shortage_risk','get_stock_coverage','get_inbound_deliveries','get_lot_quality_history'])[o],
           jsonb_build_object('ordinal', o), md5('412material' || o::text), 3 * o, 400 + 60 * o, true
      FROM generate_series(1, 7) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_m, 'a2000000-0000-4000-8000-000000412004', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '59 seconds', t0 + interval '77 seconds', 1210, 290);
    p_m1 := jsonb_build_object(
        'agent', 'material', 'domain', 'material', 'scope', '{"plant": 1, "sku": "RAD-500-A", "lot": "LOT-2609-114"}'::jsonb,
        'issue_code', 'lot.quality_history', 'title', 'Lot LOT-2609-114 has quality history',
        'summary', 'Lot LOT-2609-114 from Supplier K: 2 rejections in 30 days recorded against the lot; 640 kg still in stock',
        'severity', 'MEDIUM', 'confidence', 0.75, 'likelihood_class', 'observed', 'horizon', 'this_week', 'freshness_min', 20,
        'evidence', '[{"kind": "lot", "ref": "lot:LOT-2609-114"}, {"kind": "stock", "ref": "stock:LOT-2609-114"}]'::jsonb,
        'recommended_action', 'Quarantine the remaining 640 kg of lot LOT-2609-114 pending QE decision',
        'owner_suggestion', 'Purchasing', 'impact_estimate', '{"stock_at_risk_kg": 640, "affected_lines": [3]}'::jsonb);
    p_m2 := jsonb_build_object(
        'agent', 'material', 'domain', 'material', 'scope', '{"plant": 1, "sku": "RAD-500-A"}'::jsonb,
        'issue_code', 'material.shortage', 'title', 'Coverage risk for SKU RAD-500-A',
        'summary', 'Stock coverage 1.4 days against the 3-day schedule; incoming delivery PO-2026-004821 confirmed only for 2026-09-14',
        'severity', 'HIGH', 'confidence', 0.89, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 20,
        'evidence', '[{"kind": "stock", "ref": "stock:RAD-500-A"}, {"kind": "po", "ref": "po:PO-2026-004821"}]'::jsonb,
        'recommended_action', 'Confirm supplier ETA today or re-sequence the schedule',
        'owner_suggestion', 'Purchasing', 'impact_estimate', '{"schedule_risk_days": 1.6, "affected_lines": [3]}'::jsonb);
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000412004', run_id, a_m, 'a2000000-0000-4000-8000-000000412004', 'findings', 2, 0.89, 20, 7, 1500, 49000, t0 + interval '1 second', t0 + interval '78 seconds');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'material', 'orchestrator', 'Finding', 'agent.finding.material', p_m1, '412', t0 + interval '77 seconds') RETURNING id INTO msg_id;
    PERFORM swarm.upsert_finding(run_id, 'material', p_m1, msg_id, 'a1000000-0000-4000-8000-000000412004');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'material', 'orchestrator', 'Finding', 'agent.finding.material', p_m2, '412', t0 + interval '77 seconds') RETURNING id INTO msg_id;
    PERFORM swarm.upsert_finding(run_id, 'material', p_m2, msg_id, 'a1000000-0000-4000-8000-000000412004');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'material', 'orchestrator', 'StatusUpdate', 'agent.status.material',
            '{"status": "done", "usage": {"tool_calls": 7, "tokens": 1500, "wall_ms": 49000}, "freshness_min": 20}', '412', t0 + interval '78 seconds');
    -- production: nothing significant (FR-13 — an explicit outcome, never silence)
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000412003', t0 + interval '3 seconds', '412', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 6}', 980, 120, 13000, 6, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000412003', o, (ARRAY['query_production','get_oee','get_oee','get_oee','get_downtime_pareto','get_schedule_risk'])[o],
           jsonb_build_object('ordinal', o), md5('412production' || o::text), 3 * o, 450 + 50 * o, true
      FROM generate_series(1, 6) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_p, 'a2000000-0000-4000-8000-000000412003', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '77 seconds', t0 + interval '90 seconds', 980, 120);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'production', 'orchestrator', 'StatusUpdate', 'agent.status.production',
            '{"status": "nothing_significant", "checked": ["plan_vs_actual lines 1-3", "oee lines 1-3", "downtime pareto", "schedule risk shift B"], "usage": {"tool_calls": 6, "tokens": 1100, "wall_ms": 38000}, "freshness_min": 2}', '412', t0 + interval '91 seconds');
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000412003', run_id, a_p, 'a2000000-0000-4000-8000-000000412003', 'nothing_significant', 0, 0.9, 2, 6, 1100, 38000, t0 + interval '1 second', t0 + interval '91 seconds');
    -- maintenance: the runner was killed after "started" — no Finding, no StatusUpdate by the deadline (AC-02)
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, incomplete, finding_count, tool_calls_used, tokens_used, wall_ms, attempt_count, requested_at, responded_at, error)
    VALUES ('a1000000-0000-4000-8000-000000412002', run_id, a_mt, NULL, 'timeout', true, 0, 0, 0, 60000, 1, t0 + interval '1 second', NULL, 'no response within 60 s (runner process killed — fault injection TC-081)');
    INSERT INTO swarm.attempt (assessment_id, attempt_no, started_at, finished_at, outcome, backoff_ms, error)
    VALUES ('a1000000-0000-4000-8000-000000412002', 1, t0 + interval '1 second', t0 + interval '61 seconds', 'timeout', 0, 'deadline 14:01:01 passed without a reply');
    UPDATE swarm.circuit_state SET consecutive_failures = 1, last_outcome = 'timeout', last_change_at = t0 + interval '61 seconds' WHERE agent_id = a_mt;
    PERFORM swarm.score_run(run_id);
    PERFORM swarm.detect_compounds(run_id);
    PERFORM swarm.rank_run(run_id);
    UPDATE swarm.run SET status = 'partial', partial_reason = 'maintenance: timeout after 60 s', finished_at = t0 + interval '95 seconds' WHERE id = run_id;
    PERFORM swarm.expire_findings(run_id);
    items := swarm.briefing_items(run_id, 3);
    INSERT INTO agent.briefing (id, generated_at, scope_json, lang, top_risks_json, text, partial, partial_reason, delivered_at) VALUES
    ('a3000000-0000-4000-8000-000000412001', t0 + interval '96 seconds', '{"plant": 1, "shift": "B", "date": "2026-09-10"}', 'en', items,
E'🏭 Shift briefing — 2026-09-10 · Shift B · Plant 1
⚠ PARTIAL — maintenance: timeout after 60 s. Machine health was NOT assessed in this run; the morning's bearing finding remains open on the blackboard.
Data freshness: quality 4 min · production 2 min · material 20 min

TOP 3 RISKS

1. [HIGH 0.93] SKU RAD-500-A — compound risk: material + quality
   Stock coverage 1.4 days against the 3-day schedule AND defect rate 5.82 % on line 3 (+141 % vs 7-day) AND lot LOT-2609-114 has quality history (2 rejections in 30 days).
   → Confirm supplier ETA today; hold lot LOT-2609-114; quarantine the remaining 640 kg.
   Evidence: stock:RAD-500-A · po:PO-2026-004821 · signal S-241 · lot:LOT-2609-114 · case:QC-0241        Owner: Purchasing + QE

Nothing significant reported by: production
Partial: yes — maintenance (timeout after 60 s). Run 412 · 1 min 35 s · 4 agents · 21 tool calls.', true, 'maintenance: timeout after 60 s', t0 + interval '100 seconds');
    INSERT INTO swarm.briefing_run (briefing_id, run_id, top_n, rank_json, phrasing_attempts, template_fallback, model, tokens_in, tokens_out)
    VALUES ('a3000000-0000-4000-8000-000000412001', run_id, 3, swarm.rank_run(run_id), 1, false, 'qwen2.5:7b-instruct-q4_K_M', 1150, 380);
    INSERT INTO swarm.delivery (kind, briefing_id, channel, status, scheduled_at, delivered_at, message_ref)
    VALUES ('briefing', 'a3000000-0000-4000-8000-000000412001', 'discord', 'sent', t0 + interval '96 seconds', t0 + interval '100 seconds', 'discord:msg:412-en');
END
$r412$;

-- ---------------------------------------------------------------------
-- 7. Run 413 — 2026-09-11 Shift A: Production over its tool-call budget (AC-05); CRITICAL M-12 pushed immediately (FR-29)
-- ---------------------------------------------------------------------
DO $r413$
DECLARE
    run_id  uuid := 'b0000000-0000-4000-8000-000000000413';
    t0      timestamptz := '2026-09-11 06:00';
    budget  jsonb := '{"quality": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "maintenance": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "production": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "material": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}}'::jsonb;
    a_q     uuid := 'a0000000-0000-4000-8000-000000000001';
    a_mt    uuid := 'a0000000-0000-4000-8000-000000000002';
    a_p     uuid := 'a0000000-0000-4000-8000-000000000003';
    a_m     uuid := 'a0000000-0000-4000-8000-000000000004';
    ag      record;
    msg_id  uuid;
    p       jsonb;
    items   jsonb;
BEGIN
    INSERT INTO swarm.run (id, run_no, trigger, scope_json, weights_version, budget_json, agent_count, started_at, deadline_at, status)
    VALUES (run_id, 413, 'schedule', '{"plant": 1, "shift": "A", "date": "2026-09-11"}', 'v1', budget, 4, t0, t0 + interval '180 seconds', 'running');
    FOR ag IN SELECT a.id, a.name FROM swarm.agent_registry a WHERE a.kind = 'specialist' AND a.enabled ORDER BY a.id LOOP
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, 'orchestrator', ag.name, 'RequestAssessment', 'agent.request.' || ag.name,
                jsonb_build_object('run_no', 413, 'agent', ag.name, 'scope', '{"plant": 1, "shift": "A", "date": "2026-09-11"}'::jsonb,
                                   'deadline_at', '2026-09-11T06:01:01+07:00', 'budget', budget -> ag.name), '413', t0 + interval '1 second');
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name, '{"status": "started"}', '413', t0 + interval '2 seconds');
    END LOOP;
    -- quality: S-241 still open (occurrence 3)
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000413001', t0 + interval '3 seconds', '413', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 6}', 1300, 280, 20000, 6, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000413001', o, (ARRAY['get_signals','get_signals','get_signals','query_defects','get_case','get_spc'])[o], jsonb_build_object('ordinal', o), md5('413quality' || o::text), 4 * o, 500 + 70 * o, true FROM generate_series(1, 6) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_q, 'a2000000-0000-4000-8000-000000413001', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '36 seconds', t0 + interval '56 seconds', 1300, 280);
    p := jsonb_build_object(
        'agent', 'quality', 'domain', 'quality', 'scope', '{"plant": 1, "line": 3, "sku": "RAD-500-A", "shift": "A"}'::jsonb,
        'issue_code', 'quality.defect_rate', 'title', 'Defect rate 5.82 % on line 3 (+141 % vs 7-day)',
        'summary', 'Defect rate 5.82 % (+141 % vs 7-day baseline 2.41 %, p<0.001) on line 3; signal S-241 open, case QC-0241 in containment; lot LOT-2609-114 on hold',
        'severity', 'HIGH', 'confidence', 0.85, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 5,
        'evidence', '[{"kind": "signal", "ref": "signal:S-241"}, {"kind": "case", "ref": "case:QC-0241"}]'::jsonb,
        'recommended_action', 'Keep lot LOT-2609-114 on hold; verify the missing-parts station on line 3', 'owner_suggestion', 'QE',
        'impact_estimate', '{"scrap_risk_pct": 5.82, "affected_lines": [3]}'::jsonb);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'quality', 'orchestrator', 'Finding', 'agent.finding.quality', p, '413', t0 + interval '56 seconds') RETURNING id INTO msg_id;
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000413001', run_id, a_q, 'a2000000-0000-4000-8000-000000413001', 'findings', 1, 0.85, 5, 6, 1580, 50000, t0 + interval '1 second', t0 + interval '57 seconds');
    PERFORM swarm.upsert_finding(run_id, 'quality', p, msg_id, 'a1000000-0000-4000-8000-000000413001');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'quality', 'orchestrator', 'StatusUpdate', 'agent.status.quality', '{"status": "done", "usage": {"tool_calls": 6, "tokens": 1580, "wall_ms": 50000}, "freshness_min": 5}', '413', t0 + interval '57 seconds');
    -- maintenance: M-07 (occurrence 6) and a CRITICAL M-12 → immediate push
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000413002', t0 + interval '3 seconds', '413', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 7}', 1400, 330, 22000, 7, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000413002', o, (ARRAY['get_machine_health','get_alert_evidence','get_trend','get_machine_health','get_alert_evidence','get_machine_telemetry','get_pm_overdue'])[o], jsonb_build_object('ordinal', o), md5('413maintenance' || o::text), 4 * o, 500 + 70 * o, true FROM generate_series(1, 7) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_mt, 'a2000000-0000-4000-8000-000000413002', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '56 seconds', t0 + interval '78 seconds', 1400, 330);
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000413002', run_id, a_mt, 'a2000000-0000-4000-8000-000000413002', 'findings', 2, 0.91, 2, 7, 1730, 52000, t0 + interval '1 second', t0 + interval '79 seconds');
    p := jsonb_build_object(
        'agent', 'maintenance', 'domain', 'machine_health', 'scope', '{"plant": 1, "line": 3, "machine": "M-07"}'::jsonb,
        'issue_code', 'machine.degradation', 'title', 'Bearing temperature trending up on M-07',
        'summary', 'Press M-07 drive-side bearing temperature +14.6 % over 6 days (2026-09-05..11); alert 1184 open; inspection assigned',
        'severity', 'HIGH', 'confidence', 0.78, 'likelihood_class', 'observed', 'horizon', 'within_3_days', 'freshness_min', 2,
        'evidence', '[{"kind": "metric", "ref": "telemetry:M-07:bearing_temp:2026-09-03..11"}, {"kind": "alert", "ref": "alert:1184"}]'::jsonb,
        'recommended_action', 'Inspect M-07 drive-side bearing within 3 days', 'owner_suggestion', 'Maintenance',
        'impact_estimate', '{"downtime_risk_h": 6, "affected_lines": [3]}'::jsonb);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'maintenance', 'orchestrator', 'Finding', 'agent.finding.maintenance', p, '413', t0 + interval '78 seconds') RETURNING id INTO msg_id;
    PERFORM swarm.upsert_finding(run_id, 'maintenance', p, msg_id, 'a1000000-0000-4000-8000-000000413002');
    p := jsonb_build_object(
        'agent', 'maintenance', 'domain', 'machine_health', 'scope', '{"plant": 1, "line": 2, "machine": "M-12"}'::jsonb,
        'issue_code', 'machine.failure_imminent', 'title', 'M-12 spindle vibration 2.4× alarm threshold — imminent failure',
        'summary', 'Spindle vibration RMS 2.4× the alarm threshold on M-12 (line 2) since 05:10; health index 38; alert 1201',
        'severity', 'CRITICAL', 'confidence', 0.91, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 2,
        'evidence', '[{"kind": "metric", "ref": "telemetry:M-12:spindle_vib_rms:2026-09-11"}, {"kind": "alert", "ref": "alert:1201"}, {"kind": "health", "ref": "health:M-12"}]'::jsonb,
        'recommended_action', 'Stop M-12 at the next cycle end and inspect the spindle', 'owner_suggestion', 'Maintenance',
        'impact_estimate', '{"downtime_risk_h": 16, "affected_lines": [2]}'::jsonb);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'maintenance', 'orchestrator', 'Finding', 'agent.finding.maintenance', p, '413', t0 + interval '78 seconds') RETURNING id INTO msg_id;
    PERFORM swarm.upsert_finding(run_id, 'maintenance', p, msg_id, 'a1000000-0000-4000-8000-000000413002');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'maintenance', 'orchestrator', 'StatusUpdate', 'agent.status.maintenance', '{"status": "done", "usage": {"tool_calls": 7, "tokens": 1730, "wall_ms": 52000}, "freshness_min": 2}', '413', t0 + interval '79 seconds');
    UPDATE swarm.circuit_state SET consecutive_failures = 0, last_outcome = 'findings', last_change_at = t0 + interval '79 seconds' WHERE agent_id = a_mt;
    -- material: coverage risk again (occurrence 3)
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000413004', t0 + interval '3 seconds', '413', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 5}', 1000, 230, 18000, 5, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000413004', o, (ARRAY['get_stock_coverage','get_inbound_deliveries','get_lot_quality_history','get_shortage_risk','get_stock_coverage'])[o], jsonb_build_object('ordinal', o), md5('413material' || o::text), 3 * o, 400 + 60 * o, true FROM generate_series(1, 5) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_m, 'a2000000-0000-4000-8000-000000413004', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '78 seconds', t0 + interval '96 seconds', 1000, 230);
    p := jsonb_build_object(
        'agent', 'material', 'domain', 'material', 'scope', '{"plant": 1, "sku": "RAD-500-A"}'::jsonb,
        'issue_code', 'material.shortage', 'title', 'Coverage risk for SKU RAD-500-A',
        'summary', 'Stock coverage 0.9 days against the 2 remaining schedule days; PO-2026-004821 ETA 2026-09-14 unchanged',
        'severity', 'HIGH', 'confidence', 0.9, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 45,
        'evidence', '[{"kind": "stock", "ref": "stock:RAD-500-A"}, {"kind": "po", "ref": "po:PO-2026-004821"}]'::jsonb,
        'recommended_action', 'Re-sequence the schedule; expedite PO-2026-004821', 'owner_suggestion', 'Purchasing',
        'impact_estimate', '{"schedule_risk_days": 1.1, "affected_lines": [3]}'::jsonb);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'material', 'orchestrator', 'Finding', 'agent.finding.material', p, '413', t0 + interval '96 seconds') RETURNING id INTO msg_id;
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000413004', run_id, a_m, 'a2000000-0000-4000-8000-000000413004', 'findings', 1, 0.9, 45, 5, 1230, 42000, t0 + interval '1 second', t0 + interval '97 seconds');
    PERFORM swarm.upsert_finding(run_id, 'material', p, msg_id, 'a1000000-0000-4000-8000-000000413004');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'material', 'orchestrator', 'StatusUpdate', 'agent.status.material', '{"status": "done", "usage": {"tool_calls": 5, "tokens": 1230, "wall_ms": 42000}, "freshness_min": 45}', '413', t0 + interval '97 seconds');
    -- production: 13th tool call refused by the orchestrator (C-04 / AI-08 / AC-05) — no phrasing, no finding, explicit outcome
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000413003', t0 + interval '3 seconds', '413', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 12, "stopped": "budget"}', 0, 0, 0, 13, 'budget_exceeded');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok, error)
    SELECT 'a2000000-0000-4000-8000-000000413003', o, (ARRAY['query_production','query_production','query_production','get_oee','get_oee','get_oee','get_downtime_pareto','get_downtime_pareto','get_downtime_pareto','get_schedule_risk','get_schedule_risk','get_schedule_risk','get_oee'])[o],
           jsonb_build_object('ordinal', o), CASE WHEN o <= 12 THEN md5('413production' || o::text) END, CASE WHEN o <= 12 THEN 3 * o END, CASE WHEN o <= 12 THEN 450 + 50 * o ELSE 0 END, o <= 12,
           CASE WHEN o = 13 THEN 'refused by the orchestrator: budget tool_calls 13 > 12' END
      FROM generate_series(1, 13) o;
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'orchestrator', 'production', 'Clarification', 'agent.request.production',
            '{"kind": "budget_stop", "detail": "tool_calls 13 > 12 — budget exhausted; assessment recorded as budget_exceeded (incomplete)"}', '413', t0 + interval '48 seconds');
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, incomplete, finding_count, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at, error)
    VALUES ('a1000000-0000-4000-8000-000000413003', run_id, a_p, 'a2000000-0000-4000-8000-000000413003', 'budget_exceeded', true, 0, 13, 0, 47000, t0 + interval '1 second', t0 + interval '48 seconds', NULL);
    PERFORM swarm.score_run(run_id);
    PERFORM swarm.detect_compounds(run_id);
    PERFORM swarm.rank_run(run_id);
    UPDATE swarm.run SET status = 'partial', partial_reason = 'production: budget exceeded (tool_calls 13 > 12)', finished_at = t0 + interval '112 seconds' WHERE id = run_id;
    PERFORM swarm.expire_findings(run_id);
    items := swarm.briefing_items(run_id, 3);
    INSERT INTO agent.briefing (id, generated_at, scope_json, lang, top_risks_json, text, partial, partial_reason, delivered_at) VALUES
    ('a3000000-0000-4000-8000-000000413001', t0 + interval '113 seconds', '{"plant": 1, "shift": "A", "date": "2026-09-11"}', 'en', items,
E'🏭 Shift briefing — 2026-09-11 · Shift A · Plant 1
⚠ PARTIAL — production: budget exceeded (tool_calls 13 > 12). Production was NOT assessed in this run.
Data freshness: quality 5 min · maintenance 2 min · material 45 min

TOP 3 RISKS

1. [CRITICAL 0.91] M-12 spindle vibration 2.4× alarm threshold — imminent failure
   Spindle vibration RMS 2.4× the alarm threshold on M-12 (line 2) since 05:10; health index 38; alert 1201. Pushed to Discord immediately.
   → Stop M-12 at the next cycle end and inspect the spindle.
   Evidence: alert 1201 · telemetry:M-12:spindle_vib_rms:2026-09-11 · health:M-12        Owner: Maintenance

2. [HIGH 0.84] Line 3 — compound risk: quality + maintenance
   Defect rate 5.82 % (+141 % vs 7-day, p<0.001) AND press M-07 bearing temperature +14.6 % over 6 days.
   → Keep lot LOT-2609-114 on hold; inspect M-07 drive-side bearing within 3 days.
   Evidence: signal S-241 · case QC-0241 · alert 1184        Owner: Maintenance + QE

3. [HIGH 0.72] Material — coverage risk for SKU RAD-500-A
   Stock coverage 0.9 days against the 2 remaining schedule days; PO-2026-004821 ETA 2026-09-14 unchanged.
   → Re-sequence the schedule; expedite PO-2026-004821.
   Evidence: stock:RAD-500-A · po:PO-2026-004821        Owner: Purchasing

Nothing significant reported by: (none)
Partial: yes — production (budget exceeded: tool_calls 13 > 12). Run 413 · 1 min 52 s · 4 agents · 31 tool calls.', true, 'production: budget exceeded (tool_calls 13 > 12)', t0 + interval '118 seconds');
    INSERT INTO swarm.briefing_run (briefing_id, run_id, top_n, rank_json, phrasing_attempts, template_fallback, model, tokens_in, tokens_out)
    VALUES ('a3000000-0000-4000-8000-000000413001', run_id, 3, swarm.rank_run(run_id), 1, false, 'qwen2.5:7b-instruct-q4_K_M', 1300, 460);
    INSERT INTO swarm.delivery (kind, briefing_id, channel, status, scheduled_at, delivered_at, message_ref)
    VALUES ('briefing', 'a3000000-0000-4000-8000-000000413001', 'discord', 'sent', t0 + interval '113 seconds', t0 + interval '118 seconds', 'discord:msg:413-en');
    -- the immediate push created by swarm.trg_delivery_critical is marked sent by the deliverer
    UPDATE swarm.delivery SET status = 'sent', delivered_at = t0 + interval '80 seconds', message_ref = 'discord:msg:413-critical-M-12'
     WHERE kind = 'immediate' AND finding_id = (SELECT finding_id FROM swarm.finding_ext WHERE issue_key = 'machine.failure_imminent|machine=M-12,plant=1');
END
$r413$;

-- ---------------------------------------------------------------------
-- 8. Run 414 — 2026-09-11 Shift B: Maintenance returns malformed output twice (AC-06); line 1 OEE expires (FR-27)
-- ---------------------------------------------------------------------
DO $r414$
DECLARE
    run_id  uuid := 'b0000000-0000-4000-8000-000000000414';
    t0      timestamptz := '2026-09-11 14:00';
    budget  jsonb := '{"quality": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "maintenance": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "production": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "material": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}}'::jsonb;
    a_q     uuid := 'a0000000-0000-4000-8000-000000000001';
    a_mt    uuid := 'a0000000-0000-4000-8000-000000000002';
    a_p     uuid := 'a0000000-0000-4000-8000-000000000003';
    a_m     uuid := 'a0000000-0000-4000-8000-000000000004';
    ag      record;
    msg_id  uuid;
    p       jsonb;
    items   jsonb;
    n_before integer;
    n_after  integer;
BEGIN
    INSERT INTO swarm.run (id, run_no, trigger, scope_json, weights_version, budget_json, agent_count, started_at, deadline_at, status)
    VALUES (run_id, 414, 'schedule', '{"plant": 1, "shift": "B", "date": "2026-09-11"}', 'v1', budget, 4, t0, t0 + interval '180 seconds', 'running');
    FOR ag IN SELECT a.id, a.name FROM swarm.agent_registry a WHERE a.kind = 'specialist' AND a.enabled ORDER BY a.id LOOP
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, 'orchestrator', ag.name, 'RequestAssessment', 'agent.request.' || ag.name,
                jsonb_build_object('run_no', 414, 'agent', ag.name, 'scope', '{"plant": 1, "shift": "B", "date": "2026-09-11"}'::jsonb,
                                   'deadline_at', '2026-09-11T14:01:01+07:00', 'budget', budget -> ag.name), '414', t0 + interval '1 second');
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name, '{"status": "started"}', '414', t0 + interval '2 seconds');
    END LOOP;
    -- quality: S-241 (occurrence 4)
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000414001', t0 + interval '3 seconds', '414', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 5}', 1250, 270, 20000, 5, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000414001', o, (ARRAY['get_signals','get_signals','get_signals','query_defects','get_case'])[o], jsonb_build_object('ordinal', o), md5('414quality' || o::text), 4 * o, 500 + 70 * o, true FROM generate_series(1, 5) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_q, 'a2000000-0000-4000-8000-000000414001', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '58 seconds', t0 + interval '78 seconds', 1250, 270);
    p := jsonb_build_object(
        'agent', 'quality', 'domain', 'quality', 'scope', '{"plant": 1, "line": 3, "sku": "RAD-500-A", "shift": "B"}'::jsonb,
        'issue_code', 'quality.defect_rate', 'title', 'Defect rate 5.82 % on line 3 (+141 % vs 7-day)',
        'summary', 'Defect rate 5.82 % (+141 % vs 7-day baseline 2.41 %, p<0.001) on line 3; signal S-241 open, case QC-0241 in containment',
        'severity', 'HIGH', 'confidence', 0.85, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 5,
        'evidence', '[{"kind": "signal", "ref": "signal:S-241"}, {"kind": "case", "ref": "case:QC-0241"}]'::jsonb,
        'recommended_action', 'Keep lot LOT-2609-114 on hold; verify the missing-parts station on line 3', 'owner_suggestion', 'QE',
        'impact_estimate', '{"scrap_risk_pct": 5.82, "affected_lines": [3]}'::jsonb);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'quality', 'orchestrator', 'Finding', 'agent.finding.quality', p, '414', t0 + interval '78 seconds') RETURNING id INTO msg_id;
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000414001', run_id, a_q, 'a2000000-0000-4000-8000-000000414001', 'findings', 1, 0.85, 5, 5, 1520, 48000, t0 + interval '1 second', t0 + interval '79 seconds');
    PERFORM swarm.upsert_finding(run_id, 'quality', p, msg_id, 'a1000000-0000-4000-8000-000000414001');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'quality', 'orchestrator', 'StatusUpdate', 'agent.status.quality', '{"status": "done", "usage": {"tool_calls": 5, "tokens": 1520, "wall_ms": 48000}, "freshness_min": 5}', '414', t0 + interval '79 seconds');
    -- maintenance: two malformed outputs (AI-02 — one retry, then agent error); the blackboard is untouched (AC-06)
    SELECT count(*) INTO n_before FROM agent.finding;
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000414002', t0 + interval '3 seconds', '414', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 6}', 2900, 610, 44000, 6, 'error');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000414002', o, (ARRAY['get_machine_health','get_alert_evidence','get_trend','get_machine_health','get_machine_telemetry','get_pm_overdue'])[o], jsonb_build_object('ordinal', o), md5('414maintenance' || o::text), 4 * o, 500 + 70 * o, true FROM generate_series(1, 6) o;
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, incomplete, finding_count, tool_calls_used, tokens_used, wall_ms, attempt_count, requested_at, responded_at, error)
    VALUES ('a1000000-0000-4000-8000-000000414002', run_id, a_mt, 'a2000000-0000-4000-8000-000000414002', 'invalid_output', true, 0, 6, 3510, 55000, 2, t0 + interval '1 second', t0 + interval '58 seconds', 'invalid output after 2 attempts: Finding needs agent, domain, scope, title, severity, confidence, evidence, recommended_action, issue_code, likelihood_class, horizon, freshness_min (evidence missing)');
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_mt, 'a2000000-0000-4000-8000-000000414002', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '33 seconds', t0 + interval '40 seconds', 1400, 300);
    INSERT INTO swarm.attempt (assessment_id, attempt_no, started_at, finished_at, outcome, backoff_ms, error)
    VALUES ('a1000000-0000-4000-8000-000000414002', 1, t0 + interval '3 seconds', t0 + interval '40 seconds', 'invalid_output', 0, 'schema: evidence missing (fault injection TC-085: model returned prose)');
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_mt, 'a2000000-0000-4000-8000-000000414002', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '40 seconds', t0 + interval '58 seconds', 1500, 310);
    INSERT INTO swarm.attempt (assessment_id, attempt_no, started_at, finished_at, outcome, backoff_ms, error)
    VALUES ('a1000000-0000-4000-8000-000000414002', 2, t0 + interval '40 seconds', t0 + interval '58 seconds', 'invalid_output', 0, 'schema: evidence missing (retry with the validation error in the prompt)');
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'maintenance', 'orchestrator', 'Error', 'agent.status.maintenance',
            '{"code": "invalid_output", "detail": "output did not validate against finding.v1 (evidence missing) on 2 attempts", "attempt": 2}', '414', t0 + interval '58 seconds');
    UPDATE swarm.circuit_state SET consecutive_failures = 1, last_outcome = 'invalid_output', last_change_at = t0 + interval '58 seconds' WHERE agent_id = a_mt;
    SELECT count(*) INTO n_after FROM agent.finding;
    IF n_after <> n_before THEN RAISE EXCEPTION 'AC-06 violated: blackboard changed by a malformed agent output'; END IF;
    -- production and material: nothing significant
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000414003', t0 + interval '3 seconds', '414', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 5}', 950, 110, 12000, 5, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000414003', o, (ARRAY['query_production','get_oee','get_oee','get_downtime_pareto','get_schedule_risk'])[o], jsonb_build_object('ordinal', o), md5('414production' || o::text), 3 * o, 450 + 50 * o, true FROM generate_series(1, 5) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_p, 'a2000000-0000-4000-8000-000000414003', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '78 seconds', t0 + interval '90 seconds', 950, 110);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'production', 'orchestrator', 'StatusUpdate', 'agent.status.production',
            '{"status": "nothing_significant", "checked": ["plan_vs_actual lines 1-3", "oee lines 1-3 (line 1 performance back to 90 %)", "downtime pareto", "schedule risk shift B"], "usage": {"tool_calls": 5, "tokens": 1060, "wall_ms": 36000}, "freshness_min": 2}', '414', t0 + interval '92 seconds');
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000414003', run_id, a_p, 'a2000000-0000-4000-8000-000000414003', 'nothing_significant', 0, 0.9, 2, 5, 1060, 36000, t0 + interval '1 second', t0 + interval '92 seconds');
    INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
    VALUES ('a2000000-0000-4000-8000-000000414004', t0 + interval '3 seconds', '414', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"facts": 4}', 900, 100, 11000, 4, 'ok');
    INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
    SELECT 'a2000000-0000-4000-8000-000000414004', o, (ARRAY['get_stock_coverage','get_inbound_deliveries','get_lot_quality_history','get_shortage_risk'])[o], jsonb_build_object('ordinal', o), md5('414material' || o::text), 3 * o, 400 + 60 * o, true FROM generate_series(1, 4) o;
    INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
    VALUES (run_id, a_m, 'a2000000-0000-4000-8000-000000414004', 'qwen2.5:7b-instruct-q4_K_M', t0 + interval '90 seconds', t0 + interval '101 seconds', 900, 100);
    INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
    VALUES (run_id, 'material', 'orchestrator', 'StatusUpdate', 'agent.status.material',
            '{"status": "nothing_significant", "checked": ["stock coverage RAD-500-A 4.2 days after PO-2026-004821 partial delivery", "inbound 7 days", "lot history", "shortage risk"], "usage": {"tool_calls": 4, "tokens": 1000, "wall_ms": 34000}, "freshness_min": 15}', '414', t0 + interval '103 seconds');
    INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
    VALUES ('a1000000-0000-4000-8000-000000414004', run_id, a_m, 'a2000000-0000-4000-8000-000000414004', 'nothing_significant', 0, 0.9, 15, 4, 1000, 34000, t0 + interval '1 second', t0 + interval '103 seconds');
    PERFORM swarm.score_run(run_id);
    PERFORM swarm.detect_compounds(run_id);
    PERFORM swarm.rank_run(run_id);
    UPDATE swarm.run SET status = 'partial', partial_reason = 'maintenance: invalid output after 2 attempts', finished_at = t0 + interval '110 seconds' WHERE id = run_id;
    PERFORM swarm.expire_findings(run_id);   -- line 1 OEE: not reported by production in runs 412 and 414 → expired (FR-27)
    items := swarm.briefing_items(run_id, 3);
    INSERT INTO agent.briefing (id, generated_at, scope_json, lang, top_risks_json, text, partial, partial_reason, delivered_at) VALUES
    ('a3000000-0000-4000-8000-000000414001', t0 + interval '111 seconds', '{"plant": 1, "shift": "B", "date": "2026-09-11"}', 'en', items,
E'🏭 Shift briefing — 2026-09-11 · Shift B · Plant 1
⚠ PARTIAL — maintenance: invalid output after 2 attempts. Machine health was NOT assessed in this run; the morning's machine findings remain open on the blackboard.
Data freshness: quality 5 min · production 2 min · material 15 min

TOP 3 RISKS

1. [HIGH 0.68] Defect rate 5.82 % on line 3 (+141 % vs 7-day)
   Defect rate 5.82 % (+141 % vs 7-day baseline 2.41 %, p<0.001) on line 3; signal S-241 open, case QC-0241 in containment.
   → Keep lot LOT-2609-114 on hold; verify the missing-parts station on line 3.
   Evidence: signal S-241 · case QC-0241        Owner: QE

Nothing significant reported by: production, material
Partial: yes — maintenance (invalid output after 2 attempts). Run 414 · 1 min 50 s · 4 agents · 20 tool calls.', true, 'maintenance: invalid output after 2 attempts', t0 + interval '115 seconds');
    INSERT INTO swarm.briefing_run (briefing_id, run_id, top_n, rank_json, phrasing_attempts, template_fallback, model, tokens_in, tokens_out)
    VALUES ('a3000000-0000-4000-8000-000000414001', run_id, 3, swarm.rank_run(run_id), 1, false, 'qwen2.5:7b-instruct-q4_K_M', 900, 250);
    INSERT INTO swarm.delivery (kind, briefing_id, channel, status, scheduled_at, delivered_at, message_ref)
    VALUES ('briefing', 'a3000000-0000-4000-8000-000000414001', 'discord', 'sent', t0 + interval '111 seconds', t0 + interval '115 seconds', 'discord:msg:414-en');
END
$r414$;

-- Maintenance closes M-12 after the spindle inspection (FR-25 resolve)
INSERT INTO swarm.finding_action (finding_id, kind, actor_id, reason, ts)
SELECT fe.finding_id, 'resolve', 'd0000000-0000-4000-8000-000000000003', 'Spindle bearing replaced at 14:40; vibration RMS back to baseline', '2026-09-11 16:05'
  FROM swarm.finding_ext fe WHERE fe.issue_key = 'machine.failure_imminent|machine=M-12,plant=1';

-- ---------------------------------------------------------------------
-- 9. Run 415 — ad-hoc question (FR-21): "Is line 3 at risk this shift?" → targeted assessments, same pipeline, same claim check
-- ---------------------------------------------------------------------
DO $r415$
DECLARE
    run_id  uuid := 'b0000000-0000-4000-8000-000000000415';
    t0      timestamptz := '2026-09-11 15:30';
    budget  jsonb := '{"quality": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "maintenance": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "production": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}, "material": {"tool_calls": 12, "tokens": 6000, "wall_ms": 60000}}'::jsonb;
    ag      record;
    k       integer := 0;
    ar_id   uuid;
    as_id   uuid;
    msg_id  uuid;
    p       jsonb;
    lease_e timestamptz;
    items   jsonb;
    ids     uuid[];
    chk     jsonb;
    q_id    uuid;
    ans     text;
BEGIN
    INSERT INTO swarm.run (id, run_no, trigger, scope_json, weights_version, budget_json, agent_count, started_at, deadline_at, status, requested_by)
    VALUES (run_id, 415, 'question', '{"plant": 1, "line": 3, "shift": "B", "date": "2026-09-11"}', 'v1', budget, 4, t0, t0 + interval '180 seconds', 'running', 'd0000000-0000-4000-8000-000000000001');
    INSERT INTO swarm.question (run_id, asked_by, question, lang, scope_json, asked_at)
    VALUES (run_id, 'd0000000-0000-4000-8000-000000000001', 'Is line 3 at risk this shift?', 'en', '{"plant": 1, "line": 3, "shift": "B"}', t0) RETURNING id INTO q_id;
    lease_e := t0 + interval '30 seconds';
    FOR ag IN SELECT a.id, a.name FROM swarm.agent_registry a WHERE a.kind = 'specialist' AND a.enabled ORDER BY a.id LOOP
        k := k + 1;
        INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
        VALUES (run_id, 'manager', ag.name, 'RequestAssessment', 'agent.request.' || ag.name,
                jsonb_build_object('run_no', 415, 'agent', ag.name, 'scope', '{"plant": 1, "line": 3, "shift": "B"}'::jsonb,
                                   'deadline_at', '2026-09-11T15:31:01+07:00', 'budget', budget -> ag.name, 'question', 'Is line 3 at risk this shift?'), '415', t0 + interval '1 second');
        ar_id := ('a2000000-0000-4000-8000-000000415' || '00' || k)::uuid;
        INSERT INTO agent.run (id, ts, correlation_id, kind, model, prompt_version, facts_json, tokens_in, tokens_out, latency_ms, tool_call_count, outcome)
        VALUES (ar_id, t0 + interval '3 seconds', '415', 'specialist', 'qwen2.5:7b-instruct-q4_K_M', 'specialist.v1', '{"scope": {"line": 3}, "facts": 3}', 800 + 30 * k, 150 + 10 * k, 12000, 3, 'ok');
        INSERT INTO agent.tool_call (run_id, ordinal, tool_name, args_json, result_digest, row_count, duration_ms, ok)
        SELECT ar_id, o, t.name, jsonb_build_object('line', 3), md5('415' || ag.name || o::text), 4 * o, 500 + 60 * o, true
          FROM swarm.agent_tool at2 JOIN agent.tool t ON t.id = at2.tool_id, generate_series(1, 3) o
         WHERE at2.agent_id = ag.id AND at2.ordinal = o;
        INSERT INTO swarm.llm_lease (run_id, agent_id, agent_run_id, model, acquired_at, released_at, tokens_in, tokens_out)
        VALUES (run_id, ag.id, ar_id, 'qwen2.5:7b-instruct-q4_K_M', lease_e, lease_e + interval '12 seconds', 800 + 30 * k, 150 + 10 * k);
        lease_e := lease_e + interval '12 seconds';
        as_id := ('a1000000-0000-4000-8000-000000415' || '00' || k)::uuid;
        p := CASE ag.name
            WHEN 'quality' THEN jsonb_build_object(
                'agent', 'quality', 'domain', 'quality', 'scope', '{"plant": 1, "line": 3, "sku": "RAD-500-A", "shift": "B"}'::jsonb,
                'issue_code', 'quality.defect_rate', 'title', 'Defect rate 5.82 % on line 3 (+141 % vs 7-day)',
                'summary', 'Defect rate 5.82 % (+141 % vs 7-day baseline 2.41 %, p<0.001) on line 3; signal S-241 open, case QC-0241 in containment',
                'severity', 'HIGH', 'confidence', 0.85, 'likelihood_class', 'observed', 'horizon', 'this_shift', 'freshness_min', 3,
                'evidence', '[{"kind": "signal", "ref": "signal:S-241"}, {"kind": "case", "ref": "case:QC-0241"}]'::jsonb,
                'recommended_action', 'Keep lot LOT-2609-114 on hold; verify the missing-parts station on line 3', 'owner_suggestion', 'QE',
                'impact_estimate', '{"scrap_risk_pct": 5.82, "affected_lines": [3]}'::jsonb)
            WHEN 'maintenance' THEN jsonb_build_object(
                'agent', 'maintenance', 'domain', 'machine_health', 'scope', '{"plant": 1, "line": 3, "machine": "M-07"}'::jsonb,
                'issue_code', 'machine.degradation', 'title', 'Bearing temperature trending up on M-07',
                'summary', 'Press M-07 drive-side bearing temperature +14.6 % over 6 days (2026-09-05..11); alert 1184 open; inspection assigned',
                'severity', 'HIGH', 'confidence', 0.78, 'likelihood_class', 'observed', 'horizon', 'within_3_days', 'freshness_min', 2,
                'evidence', '[{"kind": "metric", "ref": "telemetry:M-07:bearing_temp:2026-09-03..11"}, {"kind": "alert", "ref": "alert:1184"}]'::jsonb,
                'recommended_action', 'Inspect M-07 drive-side bearing within 3 days', 'owner_suggestion', 'Maintenance',
                'impact_estimate', '{"downtime_risk_h": 6, "affected_lines": [3]}'::jsonb)
            ELSE NULL END;
        IF p IS NOT NULL THEN
            INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
            VALUES (run_id, ag.name, 'orchestrator', 'Finding', 'agent.finding.' || ag.name, p, '415', lease_e) RETURNING id INTO msg_id;
            INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
            VALUES (as_id, run_id, ag.id, ar_id, 'findings', 1, (p ->> 'confidence')::numeric, (p ->> 'freshness_min')::numeric, 3, 950 + 40 * k, 30000, t0 + interval '1 second', lease_e + interval '1 second');
            PERFORM swarm.upsert_finding(run_id, ag.name, p, msg_id, as_id);
            INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
            VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name,
                    jsonb_build_object('status', 'done', 'usage', jsonb_build_object('tool_calls', 3, 'tokens', 950 + 40 * k, 'wall_ms', 30000), 'freshness_min', (p ->> 'freshness_min')::numeric), '415', lease_e + interval '1 second');
        ELSE
            INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id, ts)
            VALUES (run_id, ag.name, 'orchestrator', 'StatusUpdate', 'agent.status.' || ag.name,
                    jsonb_build_object('status', 'nothing_significant', 'checked', jsonb_build_array('line 3 plan vs actual', 'line 3 schedule risk', 'RAD-500-A coverage'),
                                       'usage', jsonb_build_object('tool_calls', 3, 'tokens', 950 + 40 * k, 'wall_ms', 30000), 'freshness_min', 2), '415', lease_e + interval '1 second');
            INSERT INTO swarm.assessment (id, run_id, agent_id, agent_run_id, outcome, finding_count, confidence, freshness_min, tool_calls_used, tokens_used, wall_ms, requested_at, responded_at)
            VALUES (as_id, run_id, ag.id, ar_id, 'nothing_significant', 0, 0.9, 2, 3, 950 + 40 * k, 30000, t0 + interval '1 second', lease_e + interval '1 second');
        END IF;
    END LOOP;
    PERFORM swarm.score_run(run_id);
    PERFORM swarm.detect_compounds(run_id);
    PERFORM swarm.rank_run(run_id);
    UPDATE swarm.run SET status = 'completed', finished_at = t0 + interval '84 seconds' WHERE id = run_id;
    items := swarm.briefing_items(run_id, 3);
    SELECT COALESCE(array_agg(DISTINCT (x #>> '{}')::uuid), '{}') INTO ids FROM jsonb_array_elements(items) t, jsonb_array_elements(t -> 'finding_ids') x;
    ans := 'Yes — Line 3 carries a compound risk (0.84): defect rate 5.82 % (+141 % vs 7-day, p<0.001; signal S-241, case QC-0241) AND press M-07 bearing temperature +14.6 % over 6 days (alert 1184). Keep lot LOT-2609-114 on hold; inspect M-07 drive-side bearing within 3 days. Production and material report nothing significant for line 3. Run 415 · 4 agents · 12 tool calls.';
    chk := swarm.claim_check(ans, run_id, ids);
    IF jsonb_array_length(chk -> 'unmatched') > 0 THEN RAISE EXCEPTION 'FR-21 answer ungrounded: %', chk -> 'unmatched'; END IF;
    UPDATE swarm.question SET answer_json = jsonb_build_object('items', items, 'claim_check', chk), answer_text = ans, answered_at = t0 + interval '90 seconds' WHERE id = q_id;
END
$r415$;

-- ---------------------------------------------------------------------
-- 10. Metrics rollup (NFR-07), the scenario suite (AI-06 / AC-01), an export (NFR-05 / IF-72)
-- ---------------------------------------------------------------------
SELECT swarm.rollup_agent_metrics('2026-09-10');
SELECT swarm.rollup_agent_metrics('2026-09-11');

-- Scenario suite (AI-06 / AC-01) — identical to deploy/scenarios/suite.example.yaml (TEST-13 TC-006)
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-01', 'Appendix A — quality + maintenance on line 3, material coverage, line 1 OEE', '{"description": "Defect rate 5.82 % on line 3 with an open M-07 bearing alert; RAD-500-A coverage 1.4 d; line 1 performance loss"}'::jsonb, '[{"id": "F1", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 3, "sku": "RAD-500-A"}, "title": "Defect rate 5.82 % on line 3 (+141 % vs 7-day)", "severity": "HIGH", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.85, "issue_code": "quality.defect_rate"}, {"id": "F2", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 3, "machine": "M-07"}, "title": "Bearing temperature trending up on M-07", "severity": "HIGH", "likelihood_class": "observed", "horizon": "within_3_days", "confidence": 0.78, "issue_code": "machine.degradation"}, {"id": "F3", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "RAD-500-A"}, "title": "Coverage risk for SKU RAD-500-A", "severity": "HIGH", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.89, "issue_code": "material.shortage"}, {"id": "F4", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 1}, "title": "OEE performance loss on Line 1", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "today", "confidence": 0.96, "issue_code": "production.performance_loss"}]'::jsonb, '["C:F1+F2", "F3", "F4"]'::jsonb, 'twin-computed top-3: C:F1+F2, F3, F4');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-02', 'Quiet plant — two low-grade observations', '{"description": "Nothing crosses a threshold; the briefing must still rank what little there is"}'::jsonb, '[{"id": "F1", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 2}, "title": "Changeover 4 min over standard on Line 2", "severity": "LOW", "likelihood_class": "possible", "horizon": "later", "confidence": 0.5, "issue_code": "production.changeover"}, {"id": "F2", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 1}, "title": "Minor scratch cluster on Line 1", "severity": "INFO", "likelihood_class": "observed", "horizon": "this_week", "confidence": 0.9, "issue_code": "quality.defect_rate"}]'::jsonb, '["F2", "F1"]'::jsonb, 'twin-computed top-3: F2, F1');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-03', 'A CRITICAL machine outranks a compound', '{"description": "M-12 imminent failure on line 2 next to the Appendix A compound"}'::jsonb, '[{"id": "F1", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 2, "machine": "M-12"}, "title": "M-12 spindle vibration above alarm — imminent failure", "severity": "CRITICAL", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.9, "issue_code": "machine.failure_imminent"}, {"id": "F2", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 3, "sku": "RAD-500-A"}, "title": "Defect rate 5.82 % on line 3", "severity": "HIGH", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.85, "issue_code": "quality.defect_rate"}, {"id": "F3", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 3, "machine": "M-07"}, "title": "Bearing temperature trending up on M-07", "severity": "HIGH", "likelihood_class": "observed", "horizon": "within_3_days", "confidence": 0.78, "issue_code": "machine.degradation"}, {"id": "F4", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 1}, "title": "OEE performance loss on Line 1", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "today", "confidence": 0.96, "issue_code": "production.performance_loss"}]'::jsonb, '["F1", "C:F2+F3", "F4"]'::jsonb, 'twin-computed top-3: F1, C:F2+F3, F4');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-04', 'Duplicate lot report from two agents', '{"description": "Quality and Material both report the quality history of lot LOT-2609-114 — one finding, two evidence sets"}'::jsonb, '[{"id": "F1", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 3, "sku": "RAD-500-A", "lot": "LOT-2609-114"}, "title": "Lot LOT-2609-114 has quality history", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "this_week", "confidence": 0.8, "issue_code": "lot.quality_history"}, {"id": "F2", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "RAD-500-A", "lot": "LOT-2609-114"}, "title": "Lot LOT-2609-114 has quality history", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "this_week", "confidence": 0.75, "issue_code": "lot.quality_history"}, {"id": "F3", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 2}, "title": "Plan vs actual −9 % on Line 2", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "today", "confidence": 0.9, "issue_code": "production.plan_gap"}]'::jsonb, '["F3", "F1"]'::jsonb, 'twin-computed top-3: F3, F1');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-05', 'Three-way SKU compound', '{"description": "Defect rate, shortage and lot history all on RAD-500-A; a machine issue elsewhere"}'::jsonb, '[{"id": "F1", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 3, "sku": "RAD-500-A"}, "title": "Defect rate 5.82 % on line 3", "severity": "HIGH", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.85, "issue_code": "quality.defect_rate"}, {"id": "F2", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "RAD-500-A"}, "title": "Coverage risk for SKU RAD-500-A", "severity": "HIGH", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.89, "issue_code": "material.shortage"}, {"id": "F3", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 3, "sku": "RAD-500-A", "lot": "LOT-2609-114"}, "title": "Lot LOT-2609-114 has quality history", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "this_week", "confidence": 0.75, "issue_code": "lot.quality_history"}, {"id": "F4", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 2, "machine": "M-03"}, "title": "Health index declining on M-03", "severity": "HIGH", "likelihood_class": "trend", "horizon": "within_3_days", "confidence": 0.7, "issue_code": "machine.degradation"}]'::jsonb, '["C:F2+F1+F3", "F4"]'::jsonb, 'twin-computed top-3: C:F2+F1+F3, F4');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-06', 'Two lines, two compounds', '{"description": "Line 1 quality + maintenance; line 2 production + quality; a material forecast"}'::jsonb, '[{"id": "F1", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 1}, "title": "Defect rate up on Line 1", "severity": "HIGH", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.8, "issue_code": "quality.defect_rate"}, {"id": "F2", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 1, "machine": "M-01"}, "title": "M-01 alert open", "severity": "HIGH", "likelihood_class": "observed", "horizon": "today", "confidence": 0.7, "issue_code": "machine.degradation"}, {"id": "F3", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 2}, "title": "Scratch rate up on Line 2", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "today", "confidence": 0.9, "issue_code": "quality.defect_rate"}, {"id": "F4", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 2}, "title": "Micro-stops up on Line 2", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.95, "issue_code": "production.performance_loss"}, {"id": "F5", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "ZR-100"}, "title": "Coverage risk for SKU ZR-100 next week", "severity": "HIGH", "likelihood_class": "forecast", "horizon": "this_week", "confidence": 0.6, "issue_code": "material.shortage"}]'::jsonb, '["C:F1+F2", "C:F4+F3", "F5"]'::jsonb, 'twin-computed top-3: C:F1+F2, C:F4+F3, F5');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-07', 'Ties are broken by title', '{"description": "Two identical scores; the order must be stable and explainable"}'::jsonb, '[{"id": "F1", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 1}, "title": "Alpha — defect class cluster on Line 1", "severity": "LOW", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 1.0, "issue_code": "quality.defect_rate"}, {"id": "F2", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 2}, "title": "Beta — plan gap on Line 2", "severity": "LOW", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 1.0, "issue_code": "production.plan_gap"}, {"id": "F3", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "ZR-100"}, "title": "Gamma — possible delay for ZR-100", "severity": "MEDIUM", "likelihood_class": "possible", "horizon": "later", "confidence": 1.0, "issue_code": "material.shortage"}]'::jsonb, '["F1", "F2", "F3"]'::jsonb, 'twin-computed top-3: F1, F2, F3');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-08', 'Stale material data discounts confidence', '{"description": "Material data 8 h old — the agent reports a discounted confidence"}'::jsonb, '[{"id": "F1", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "RAD-500-A"}, "title": "Coverage risk for SKU RAD-500-A (data 8 h old)", "severity": "HIGH", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.6, "issue_code": "material.shortage"}, {"id": "F2", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 3}, "title": "Schedule risk on Line 3 this shift", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.97, "issue_code": "production.schedule_risk"}]'::jsonb, '["F2", "F1"]'::jsonb, 'twin-computed top-3: F2, F1');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-09', 'Machine compound with production', '{"description": "Maintenance alert on M-07 and the downtime Pareto on line 3 both point at M-07"}'::jsonb, '[{"id": "F1", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 3, "machine": "M-07"}, "title": "Bearing temperature trending up on M-07", "severity": "HIGH", "likelihood_class": "observed", "horizon": "within_3_days", "confidence": 0.78, "issue_code": "machine.degradation"}, {"id": "F2", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 3, "machine": "M-07"}, "title": "Downtime Pareto: M-07 unplanned stops on Line 3", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "today", "confidence": 0.9, "issue_code": "production.downtime"}, {"id": "F3", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 1}, "title": "Minor defect drift on Line 1", "severity": "LOW", "likelihood_class": "observed", "horizon": "today", "confidence": 0.8, "issue_code": "quality.defect_rate"}]'::jsonb, '["C:F1+F2", "F3"]'::jsonb, 'twin-computed top-3: C:F1+F2, F3');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-10', 'Nothing but INFO', '{"description": "Two informational items; ranking still deterministic"}'::jsonb, '[{"id": "F1", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 1}, "title": "SPC warning (rule 2) on Line 1", "severity": "INFO", "likelihood_class": "observed", "horizon": "today", "confidence": 0.9, "issue_code": "quality.spc_warning"}, {"id": "F2", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 2, "machine": "M-04"}, "title": "Health index slight decline on M-04", "severity": "INFO", "likelihood_class": "trend", "horizon": "today", "confidence": 0.9, "issue_code": "machine.degradation"}]'::jsonb, '["F1", "F2"]'::jsonb, 'twin-computed top-3: F1, F2');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-11', 'Recurring detection merges into one item', '{"description": "The same M-07 issue reported twice (earlier trend, later observed) merges with the strongest attributes"}'::jsonb, '[{"id": "F1", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 3, "machine": "M-07"}, "title": "Bearing temperature trending up on M-07", "severity": "HIGH", "likelihood_class": "trend", "horizon": "within_3_days", "confidence": 0.7, "issue_code": "machine.degradation"}, {"id": "F2", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 3, "machine": "M-07"}, "title": "Bearing temperature trending up on M-07 (alert open)", "severity": "HIGH", "likelihood_class": "observed", "horizon": "within_3_days", "confidence": 0.78, "issue_code": "machine.degradation"}, {"id": "F3", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 2}, "title": "Scratch rate up on Line 2", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "today", "confidence": 0.8, "issue_code": "quality.defect_rate"}]'::jsonb, '["F1", "F3"]'::jsonb, 'twin-computed top-3: F1, F3');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-12', 'Forecast versus observed', '{"description": "A high-severity forecast ranks below observed lower-severity issues"}'::jsonb, '[{"id": "F1", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "ZR-100"}, "title": "Coverage risk for ZR-100 next week", "severity": "HIGH", "likelihood_class": "forecast", "horizon": "this_week", "confidence": 0.9, "issue_code": "material.shortage"}, {"id": "F2", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 2}, "title": "Plan gap on Line 2 this shift", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.6, "issue_code": "production.plan_gap"}, {"id": "F3", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 1}, "title": "Defect class cluster on Line 1", "severity": "LOW", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.99, "issue_code": "quality.defect_rate"}]'::jsonb, '["F3", "F2", "F1"]'::jsonb, 'twin-computed top-3: F3, F2, F1');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-13', 'Five findings, top-3 cut', '{"description": "CRITICAL machine, a line 3 compound, and three singles"}'::jsonb, '[{"id": "F1", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 2, "machine": "M-12"}, "title": "M-12 imminent failure", "severity": "CRITICAL", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.9, "issue_code": "machine.failure_imminent"}, {"id": "F2", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 3}, "title": "Defect rate up on Line 3", "severity": "HIGH", "likelihood_class": "observed", "horizon": "today", "confidence": 0.8, "issue_code": "quality.defect_rate"}, {"id": "F3", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 3}, "title": "Schedule risk on Line 3", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.9, "issue_code": "production.schedule_risk"}, {"id": "F4", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "ZR-100"}, "title": "Coverage risk for ZR-100", "severity": "HIGH", "likelihood_class": "forecast", "horizon": "within_3_days", "confidence": 0.7, "issue_code": "material.shortage"}, {"id": "F5", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 1}, "title": "Minor defect drift on Line 1", "severity": "LOW", "likelihood_class": "observed", "horizon": "today", "confidence": 0.9, "issue_code": "quality.defect_rate"}]'::jsonb, '["F1", "C:F2+F3", "F5"]'::jsonb, 'twin-computed top-3: F1, C:F2+F3, F5');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-14', 'SKU compound, not line', '{"description": "Quality on line 1 and material on the same SKU compound; maintenance on line 2 stays single"}'::jsonb, '[{"id": "F1", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 1, "sku": "RAD-500-A"}, "title": "Defect rate up on Line 1 (RAD-500-A)", "severity": "HIGH", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.8, "issue_code": "quality.defect_rate"}, {"id": "F2", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "RAD-500-A"}, "title": "Coverage risk for SKU RAD-500-A", "severity": "HIGH", "likelihood_class": "observed", "horizon": "today", "confidence": 0.85, "issue_code": "material.shortage"}, {"id": "F3", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 2, "machine": "M-05"}, "title": "M-05 alert open", "severity": "HIGH", "likelihood_class": "observed", "horizon": "today", "confidence": 0.8, "issue_code": "machine.degradation"}]'::jsonb, '["C:F1+F2", "F3"]'::jsonb, 'twin-computed top-3: C:F1+F2, F3');
INSERT INTO swarm.scenario (code, title, plant_state_json, findings_json, expected_top_json, notes) VALUES ('SC-15', 'Engineer''s judgement differs (known miss)', '{"description": "The engineer expects the HIGH trend on M-09 and the HIGH forecast above a LOW observed item; the published tables rank otherwise. Kept in the suite deliberately — see TEST-13 TC-070."}'::jsonb, '[{"id": "F1", "agent": "production", "domain": "production", "scope": {"plant": 1, "line": 1}, "title": "Plan gap on Line 1 this shift", "severity": "MEDIUM", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.95, "issue_code": "production.plan_gap"}, {"id": "F2", "agent": "material", "domain": "material", "scope": {"plant": 1, "sku": "ZR-100"}, "title": "Coverage risk for ZR-100 next week", "severity": "HIGH", "likelihood_class": "forecast", "horizon": "this_week", "confidence": 0.7, "issue_code": "material.shortage"}, {"id": "F3", "agent": "quality", "domain": "quality", "scope": {"plant": 1, "line": 2}, "title": "Defect class cluster on Line 2", "severity": "LOW", "likelihood_class": "observed", "horizon": "this_shift", "confidence": 0.9, "issue_code": "quality.defect_rate"}, {"id": "F4", "agent": "maintenance", "domain": "machine_health", "scope": {"plant": 1, "line": 3, "machine": "M-09"}, "title": "Health index declining on M-09", "severity": "HIGH", "likelihood_class": "trend", "horizon": "today", "confidence": 0.6, "issue_code": "machine.degradation"}]'::jsonb, '["F1", "F4", "F2"]'::jsonb, 'twin-computed top-3: F1, F3, F4; deliberate mismatch');


-- The deterministic half of the scenario suite (AI-06 / AC-01): 15 scenarios → 14 matches (SC-15 is a deliberate disagreement)
SELECT swarm.run_suite('v1', 'deterministic');

-- An auditable export of run 411 (NFR-05 / IF-72): hash over the ordered message log
INSERT INTO swarm.export (id, kind, run_id, requested_by, from_ts, to_ts, row_count, sha256, uri)
SELECT '90000000-0000-4000-8000-000000000411', 'run', 'b0000000-0000-4000-8000-000000000411', 'd0000000-0000-4000-8000-000000000005',
       '2026-09-10 06:00', '2026-09-10 06:02:14', count(*),
       encode(digest(string_agg(m.seq || '|' || m.type::text || '|' || m.from_agent || '|' || m.to_agent, E'\n' ORDER BY m.seq), 'sha256'), 'hex'),
       's3://kaizenswarm-exports/run-411.json'
  FROM swarm.message m WHERE m.run_id = 'b0000000-0000-4000-8000-000000000411';

INSERT INTO audit.log (ts, user_id, action, entity, entity_id, correlation_id, detail)
VALUES ('2026-09-11 17:00', 'd0000000-0000-4000-8000-000000000005', 'export.run', 'swarm.export', '90000000-0000-4000-8000-000000000411', '411', '{"kind": "run", "run_no": 411}');

COMMIT;

-- =====================================================================
-- EXPECTED VALUES (DDS-13 §9; re-derived in Python — TEST-13 TC-005)
-- =====================================================================
\echo '=== runs ==='
SELECT run_no, trigger, status, partial_reason, swarm.wall_label(wall_ms) AS wall, agent_count, tool_call_count, token_count FROM swarm.run ORDER BY run_no;
\echo 'expected: 11 runs 405..415; 411 completed 2 min 14 s 4 agents 23 tool calls; 412 partial "maintenance: timeout after 60 s" 1 min 35 s 21 calls; 413 partial "production: budget exceeded (tool_calls 13 > 12)" 1 min 52 s 31 calls; 414 partial "maintenance: invalid output after 2 attempts" 1 min 50 s 20 calls; 415 question completed'
\echo '=== run 411 scores (FR-18) ==='
SELECT f.agent_name, f.title, rs.impact, rs.likelihood, rs.urgency, rs.confidence, rs.score, rs.rank, (rs.absorbed_by IS NOT NULL) AS absorbed
  FROM swarm.risk_score rs JOIN agent.finding f ON f.id = rs.finding_id JOIN swarm.run r ON r.id = rs.run_id WHERE r.run_no = 411 ORDER BY rs.score DESC;
\echo 'expected: quality 0.800 x 1.000 x 1.000 x 0.850 = 0.6800 (absorbed); material 0.800 x 1.000 x 1.000 x 0.890 = 0.7120 rank 2; production 0.600 x 1.000 x 0.900 x 0.960 = 0.5184 rank 3; maintenance 0.800 x 1.000 x 0.800 x 0.780 = 0.4992 (absorbed)'
\echo '=== run 411 compound (FR-17 / AC-04) ==='
SELECT c.rank, c.score, c.title, rr.code, c.shared_key_json, c.owner_suggestion FROM swarm.compound_risk c JOIN swarm.relation_rule rr ON rr.id = c.rule_id JOIN swarm.run r ON r.id = c.run_id WHERE r.run_no = 411;
\echo 'expected: rank 1 score 0.8397 "Line 3 — compound risk: quality + maintenance" same_line {"rule": "same_line", "key": "line=3"} owner "Maintenance + QE"; 0.8397 = 1 - (1 - 0.6800)(1 - 0.4992) >= both components'
\echo '=== run 411 briefing (FR-19 / FR-31 / AC-07) ==='
SELECT b.lang, b.partial, br.claim_check_json ->> 'checked' AS checked, br.claim_check_json ->> 'matched' AS matched, br.claim_check_json -> 'unmatched' AS unmatched, jsonb_array_length(b.top_risks_json) AS items
  FROM agent.briefing b JOIN swarm.briefing_run br ON br.briefing_id = b.id JOIN swarm.run r ON r.id = br.run_id WHERE r.run_no = 411 ORDER BY b.lang;
\echo 'expected: en/ja/th, partial false, 3 items, unmatched [] for all three (en checked 31 matched 31; th checked 31; ja checked 31)'
\echo '=== AC-08 recurrence: the M-07 issue through run 411 ==='
SELECT f.occurrences, f.first_seen, f.last_seen, f.status, (SELECT count(*) FROM swarm.finding_occurrence o JOIN swarm.run r ON r.id = o.run_id WHERE o.finding_id = f.id AND r.run_no <= 411) AS occurrences_through_411,
       (SELECT count(*) FROM agent.finding x JOIN swarm.finding_ext xe ON xe.finding_id = x.id WHERE xe.issue_code = 'machine.degradation' AND xe.scope_machine = 'M-07') AS rows_for_m07
  FROM agent.finding f JOIN swarm.finding_ext fe ON fe.finding_id = f.id WHERE fe.issue_key = 'machine.degradation|machine=M-07,plant=1';
\echo 'expected: occurrences 7 (runs 407..411, 413, 415), first_seen 2026-09-08 06:00, status in_progress, occurrences_through_411 = 5, rows_for_m07 = 1'
\echo '=== AC-03 dedupe: lot LOT-2609-114 reported by quality and material in run 412 ==='
SELECT f.agent_name AS first_reporter, f.occurrences, jsonb_array_length(f.evidence_json) AS evidence_items, f.status,
       (SELECT string_agg(a.name, ',' ORDER BY a.name) FROM swarm.finding_occurrence o JOIN swarm.agent_registry a ON a.id = o.agent_id WHERE o.finding_id = f.id) AS reporters
  FROM agent.finding f JOIN swarm.finding_ext fe ON fe.finding_id = f.id WHERE fe.issue_key = 'lot.quality_history|lot=LOT-2609-114,plant=1';
\echo 'expected: first_reporter quality, occurrences 2, evidence_items 3 (the shared lot ref counted once: lot, case, stock), status expired ("condition cleared: not reported by material in runs 413, 414; quality in runs 413, 414"), reporters material,quality'
\echo '=== run 412 (AC-02 partial) ==='
SELECT a.name, s.outcome, s.incomplete, s.tool_calls_used, s.wall_ms, s.error FROM swarm.assessment s JOIN swarm.agent_registry a ON a.id = s.agent_id JOIN swarm.run r ON r.id = s.run_id WHERE r.run_no = 412 ORDER BY a.name;
SELECT c.score, c.title FROM swarm.compound_risk c JOIN swarm.run r ON r.id = c.run_id WHERE r.run_no = 412;
\echo 'expected: maintenance timeout incomplete 0 calls 60000 ms; material findings 7; production nothing_significant 6; quality findings 8 — compound 0.9327 "SKU RAD-500-A — compound risk: material + quality" (1 - 0.32 x 0.73 x 0.288)'
\echo '=== run 413 (AC-05 budget, FR-29 CRITICAL) ==='
SELECT * FROM swarm.v_budget_usage WHERE run_no = 413 ORDER BY agent;
SELECT d.kind, d.channel, d.status, d.scheduled_at, d.delivered_at FROM swarm.delivery d JOIN agent.finding f ON f.id = d.finding_id WHERE d.kind = 'immediate';
\echo 'expected: production budget_exceeded incomplete 13/12 violation "tool_calls 13 > 12"; one immediate discord delivery for M-12 scheduled 2026-09-11 06:00 (last_seen = run 413 start) sent 06:01:20'
\echo '=== run 414 (AC-06 invalid output; FR-27 expiry) ==='
SELECT att.attempt_no, att.outcome, att.backoff_ms FROM swarm.attempt att JOIN swarm.assessment s ON s.id = att.assessment_id JOIN swarm.run r ON r.id = s.run_id WHERE r.run_no = 414 ORDER BY 1;
SELECT f.status, f.resolution FROM agent.finding f JOIN swarm.finding_ext fe ON fe.finding_id = f.id WHERE fe.issue_key = 'production.performance_loss|line=1,plant=1';
\echo 'expected: attempts 1 invalid_output 0, 2 invalid_output 0; line-1 OEE expired "condition cleared: not reported by production in runs 412, 414"'
\echo '=== blackboard (FR-23) ==='
SELECT agent_name, issue_key, severity, status, occurrences, reporting_agents, latest_score FROM swarm.v_blackboard ORDER BY first_seen, issue_key;
\echo 'expected: quality quality.defect_rate|line=2,plant=1 MEDIUM dismissed occ 1 reporters 1; maintenance machine.degradation|machine=M-07,plant=1 HIGH in_progress occ 7 reporters 1; material material.shortage|plant=1,sku=RAD-500-A HIGH new occ 3 reporters 1; production production.performance_loss|line=1,plant=1 MEDIUM expired occ 1 reporters 1; quality quality.defect_rate|line=3,plant=1 HIGH in_progress occ 5 reporters 1; quality lot.quality_history|lot=LOT-2609-114,plant=1 MEDIUM expired occ 2 reporters 2; maintenance machine.failure_imminent|machine=M-12,plant=1 CRITICAL resolved occ 1 reporters 1'
\echo '=== precision (FR-26) ==='
SELECT a.name, p.* FROM swarm.agent_registry a CROSS JOIN LATERAL swarm.agent_precision(a.id, '2026-09-01', '2026-09-30') p WHERE a.kind = 'specialist' AND a.enabled ORDER BY a.name;
\echo 'expected: maintenance 2/0/0/1.0000; material 2/0/0/1.0000; production 1/0/0/1.0000; quality findings 3 dismissed 1 false_positives 1 precision_rate 0.6667'
\echo '=== scenario suite (AI-06 / AC-01) ==='
SELECT scenarios, matches, match_rate, fabricated, passed, mismatches FROM swarm.v_scenario_gate;
\echo 'expected: 15 scenarios, 14 matches, 0.9333, 0 fabricated, passed true, mismatches SC-15'
\echo '=== trace (FR-07 / AC-09) ==='
SELECT kind, count(*) FROM swarm.run_trace('b0000000-0000-4000-8000-000000000411') GROUP BY kind ORDER BY kind;
\echo 'expected: attempt 0 rows (none recorded for run 411 — a single clean attempt per agent is implicit), lease 4, llm_run 4, message 20, tool_call 23'
\echo '=== export hash (NFR-05) ==='
SELECT row_count, sha256 FROM swarm.export WHERE run_id = 'b0000000-0000-4000-8000-000000000411';
\echo 'expected: 20 rows, sha256 9153967a44cc65efe99852663c4ecf92e6b6c050362c472d3530a0c0a639d636'
\echo '=== counts ==='
SELECT (SELECT count(*) FROM swarm.run) AS runs, (SELECT count(*) FROM swarm.message) AS messages, (SELECT count(*) FROM agent.finding) AS findings,
       (SELECT count(*) FROM swarm.finding_occurrence) AS occurrences, (SELECT count(*) FROM swarm.compound_risk) AS compounds, (SELECT count(*) FROM agent.briefing) AS briefings,
       (SELECT count(*) FROM agent.tool_call) AS tool_calls, (SELECT count(*) FROM swarm.llm_lease) AS leases, (SELECT count(*) FROM swarm.finding_action) AS actions;
\echo 'expected: runs 11, messages 151, findings 7, occurrences 20, compounds 4, briefings 12, tool_calls 179, leases 43, actions 7'

-- =====================================================================
-- PROBES — each must FAIL (TEST-13 TC-003). ON_ERROR_STOP is off so every probe runs.
-- =====================================================================
\set ON_ERROR_STOP off
\echo '--- P-01 finding without evidence -> finding_has_evidence (platform CHECK) / EVIDENCE_SHAPE'
BEGIN; INSERT INTO agent.finding (agent_name, domain, scope_json, title, severity, evidence_json) VALUES ('quality', 'quality', '{"plant": 1, "line": 1}', 'probe', 'LOW', '[]'); ROLLBACK;
\echo '--- P-02 the manager inserts a finding -> FINDING_AUTHOR (FR-22)'
BEGIN; INSERT INTO agent.finding (agent_name, domain, scope_json, title, severity, evidence_json) VALUES ('manager', 'quality', '{"plant": 1, "line": 1}', 'probe', 'LOW', '[{"kind": "metric", "ref": "x:1"}]'); ROLLBACK;
\echo '--- P-03 quality reports machine_health -> DOMAIN_VIOLATION (FR-14)'
BEGIN; INSERT INTO agent.finding (agent_name, domain, scope_json, title, severity, evidence_json) VALUES ('quality', 'machine_health', '{"plant": 1, "line": 1}', 'probe', 'LOW', '[{"kind": "metric", "ref": "x:1"}]'); ROLLBACK;
\echo '--- P-04 a supplied score that is not the function -> SCORE_NOT_COMPUTED (FR-18)'
BEGIN; UPDATE swarm.risk_score SET score = 0.9999 WHERE run_id = 'b0000000-0000-4000-8000-000000000411' AND finding_id = (SELECT finding_id FROM swarm.finding_ext WHERE issue_key = 'material.shortage|plant=1,sku=RAD-500-A'); ROLLBACK;
\echo '--- P-05 compound with one component -> COMPOUND_NEEDS_TWO'
BEGIN; INSERT INTO swarm.compound_risk (run_id, rule_id, finding_ids, shared_key_json, rationale, score, title) VALUES ('b0000000-0000-4000-8000-000000000411', 'e0000000-0000-4000-8000-000000000001', ARRAY[(SELECT finding_id FROM swarm.finding_ext WHERE issue_key = 'material.shortage|plant=1,sku=RAD-500-A')], '{}', 'probe', 0.9, 'probe'); ROLLBACK;
\echo '--- P-06 compound whose score is below noisy-OR -> COMPOUND_SCORE (AC-04)'
BEGIN; INSERT INTO swarm.compound_risk (run_id, rule_id, finding_ids, shared_key_json, rationale, score, title) VALUES ('b0000000-0000-4000-8000-000000000411', 'e0000000-0000-4000-8000-000000000001', ARRAY[(SELECT finding_id FROM swarm.finding_ext WHERE issue_key = 'quality.defect_rate|line=3,plant=1'), (SELECT finding_id FROM swarm.finding_ext WHERE issue_key = 'machine.degradation|machine=M-07,plant=1')], '{}', 'probe', 0.5000, 'probe'); ROLLBACK;
\echo '--- P-07 briefing with an invented number (6.10 %) -> BRIEFING_UNGROUNDED (AC-07)'
BEGIN; INSERT INTO agent.briefing (id, scope_json, lang, top_risks_json, text, partial) VALUES ('a3000000-0000-4000-8000-000000411009', '{"plant": 1}', 'en', (SELECT top_risks_json FROM agent.briefing WHERE id = 'a3000000-0000-4000-8000-000000411001'), 'Defect rate 6.10 % on line 3. Run 411.', false);
       INSERT INTO swarm.briefing_run (briefing_id, run_id, top_n, rank_json) VALUES ('a3000000-0000-4000-8000-000000411009', 'b0000000-0000-4000-8000-000000000411', 3, '[]'); ROLLBACK;
\echo '--- P-08 briefing for run 412 with partial = false -> BRIEFING_PARTIAL_MISMATCH (AC-02)'
BEGIN; INSERT INTO agent.briefing (id, scope_json, lang, top_risks_json, text, partial) VALUES ('a3000000-0000-4000-8000-000000412009', '{"plant": 1}', 'en', '[]', 'All good. Run 412.', false);
       INSERT INTO swarm.briefing_run (briefing_id, run_id, top_n, rank_json) VALUES ('a3000000-0000-4000-8000-000000412009', 'b0000000-0000-4000-8000-000000000412', 3, '[]'); ROLLBACK;
\echo '--- P-09 assessment "findings" with 13 tool calls -> BUDGET_SILENT_TRUNCATION (C-04 / AC-05)'
BEGIN; UPDATE swarm.assessment SET outcome = 'findings', finding_count = 1, incomplete = false WHERE id = 'a1000000-0000-4000-8000-000000413003'; ROLLBACK;
\echo '--- P-10 Finding message without evidence -> MESSAGE_SHAPE (FR-02)'
BEGIN; INSERT INTO swarm.message (run_id, from_agent, to_agent, type, subject, payload_json, correlation_id) VALUES ('b0000000-0000-4000-8000-000000000415', 'quality', 'orchestrator', 'Finding', 'agent.finding.quality', '{"agent": "quality", "domain": "quality", "scope": {"plant": 1}, "title": "probe", "severity": "LOW", "confidence": 0.5, "recommended_action": "x", "issue_code": "quality.probe", "likelihood_class": "observed", "horizon": "today", "freshness_min": 1}', '415'); ROLLBACK;
\echo '--- P-11 overlapping LLM lease -> GPU_SEMAPHORE (C-05)'
BEGIN; INSERT INTO swarm.llm_lease (run_id, agent_id, model, acquired_at, released_at) VALUES ('b0000000-0000-4000-8000-000000000411', 'a0000000-0000-4000-8000-000000000003', 'qwen2.5:7b-instruct-q4_K_M', '2026-09-10 06:00:50', '2026-09-10 06:01:10'); ROLLBACK;
\echo '--- P-12 binding a write tool to an agent -> TOOL_NOT_READ_ONLY (C-03)'
BEGIN; INSERT INTO swarm.agent_tool (agent_id, tool_id, ordinal) VALUES ('a0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000018', 9); ROLLBACK;
\echo '--- P-13 a third attempt -> MAX_ATTEMPTS (AI-02)'
BEGIN; INSERT INTO swarm.attempt (assessment_id, attempt_no, started_at, finished_at, outcome) VALUES ('a1000000-0000-4000-8000-000000414002', 3, '2026-09-11 14:01:00', '2026-09-11 14:01:20', 'invalid_output'); ROLLBACK;
\echo '--- P-14 direct UPDATE of a finding to dismissed -> ACTION_REQUIRED (FR-25)'
BEGIN; UPDATE agent.finding SET status = 'dismissed' WHERE id = (SELECT finding_id FROM swarm.finding_ext WHERE issue_key = 'material.shortage|plant=1,sku=RAD-500-A'); ROLLBACK;
\echo '--- P-15 editing a bus message -> MESSAGE_IMMUTABLE (C-01)'
BEGIN; UPDATE swarm.message SET payload_json = '{}' WHERE run_id = 'b0000000-0000-4000-8000-000000000411' AND seq = 1; ROLLBACK;
\echo '--- P-16 disabling the manager -> MANAGER_REQUIRED'
BEGIN; UPDATE swarm.agent_registry SET enabled = false WHERE name = 'manager'; ROLLBACK;
\set ON_ERROR_STOP on
