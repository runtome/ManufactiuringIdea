-- =====================================================================
-- MachineSense (AI Predictive Maintenance Agent) — Database Schema
-- Document : DDS-06-MachineSense (see docs/DDS-MachineSense-Database-Design.md)
-- Version  : 1.0
-- Date     : 2026-09-13
-- Target   : PostgreSQL 16 + TimescaleDB 2.x (hypertables applied when the
--            extension is present; native range partitioning otherwise — ADR-P01)
--
-- Apply with:
--   psql -v ON_ERROR_STOP=1 -f schema.sql
--
-- STANDALONE deployment schema. In platform mode this file is NOT applied;
-- the platform schema (00/db/schema.sql) already contains every shared
-- object below, byte-identical, and section 10 (the MachineSense extension
-- of the telemetry schema) is applied as migration machinesense_0001.
--
-- BYTE-IDENTITY RULE: sections marked "byte-identical to the platform" are
-- copied verbatim from 00/db/schema.sql and checked by TEST-06 TC-002.
-- =====================================================================

\set ON_ERROR_STOP on

-- =====================================================================
-- 1. EXTENSIONS  (byte-identical statements; vector kept for platform-mode compatibility)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_bytes, digest
CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector: embeddings
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- trigram search (hybrid retrieval)
CREATE EXTENSION IF NOT EXISTS btree_gin;     -- composite GIN indexes
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;   -- optional: the DO block in section 15 tolerates absence

-- =====================================================================
-- 2. SCHEMAS
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS core;       -- master data (byte-identical subset of platform core)
CREATE SCHEMA IF NOT EXISTS quality;    -- only the severity enum (shared type)
CREATE SCHEMA IF NOT EXISTS telemetry;  -- machine signals, health, alerts — MachineSense owns this schema
CREATE SCHEMA IF NOT EXISTS agent;      -- runs, tool calls (byte-identical subset)
CREATE SCHEMA IF NOT EXISTS ops;        -- jobs, config, data quality (byte-identical subset)
CREATE SCHEMA IF NOT EXISTS audit;      -- append-only audit trail

-- =====================================================================
-- 3. HELPER FUNCTIONS  (byte-identical to the platform)
-- =====================================================================

-- UUIDv7 (time-ordered) — ADR-012.
-- PostgreSQL 18 ships uuidv7() natively; this shim keeps PG16 compatible.
CREATE OR REPLACE FUNCTION public.uuid_generate_v7()
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    unix_ts_ms  bigint;
    uuid_bytes  bytea;
BEGIN
    unix_ts_ms := (extract(epoch FROM clock_timestamp()) * 1000)::bigint;

    -- Layout: 48-bit big-endian millisecond timestamp, then random bits.
    -- int8send gives 8 bytes big-endian; bytes 3..8 are the low 48 bits.
    uuid_bytes := overlay(gen_random_bytes(16)
                          PLACING substring(int8send(unix_ts_ms) FROM 3 FOR 6)
                          FROM 1 FOR 6);

    -- Byte 6 high nibble = version 7  -> 0x70 | (random & 0x0F)
    uuid_bytes := set_byte(uuid_bytes, 6,
                           112 | (get_byte(uuid_bytes, 6) & 15));

    -- Byte 8 high bits = RFC 4122 variant 10xx -> 0x80 | (random & 0x3F)
    uuid_bytes := set_byte(uuid_bytes, 8,
                           128 | (get_byte(uuid_bytes, 8) & 63));

    RETURN encode(uuid_bytes, 'hex')::uuid;
END;
$$;

COMMENT ON FUNCTION public.uuid_generate_v7() IS
  'Time-ordered UUIDv7 (ADR-012). Preserves B-tree locality unlike uuidv4. Replace with native uuidv7() on PG18+.';

-- Generic updated_at trigger
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- =====================================================================
-- 4. ENUMERATED TYPES  (byte-identical to the platform)
-- =====================================================================

CREATE TYPE core.shift_code        AS ENUM ('A', 'B', 'C', 'OT');
CREATE TYPE core.language_code     AS ENUM ('th', 'ja', 'en');

CREATE TYPE quality.severity       AS ENUM ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL');

CREATE TYPE telemetry.alert_status AS ENUM ('open', 'acknowledged', 'snoozed', 'resolved', 'dismissed');

CREATE TYPE agent.run_outcome      AS ENUM ('ok', 'partial', 'refused', 'grounding_failed', 'error', 'budget_exceeded');
CREATE TYPE agent.finding_status   AS ENUM ('new', 'acknowledged', 'in_progress', 'resolved', 'expired', 'dismissed');
CREATE TYPE agent.message_role     AS ENUM ('user', 'assistant', 'system', 'tool');

CREATE TYPE ops.node_state         AS ENUM ('provisioning', 'online', 'degraded', 'offline', 'retired');
CREATE TYPE ops.dq_severity        AS ENUM ('info', 'warning', 'error');

COMMENT ON TYPE agent.run_outcome IS
  'grounding_failed = the post-check (ADR-013) found a number not present in tool results; the answer was withheld.';

-- =====================================================================
-- 5. CORE — plant, line, machine, users  (byte-identical to the platform)
--    Omitted vs platform: sku, production facts, shift calendar
-- =====================================================================

CREATE TABLE core.plant (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code        text        NOT NULL UNIQUE,
    name        text        NOT NULL,
    timezone    text        NOT NULL DEFAULT 'Asia/Bangkok',
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.line (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    plant_id    uuid        NOT NULL REFERENCES core.plant(id) ON DELETE RESTRICT,
    code        text        NOT NULL,
    name        text        NOT NULL,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT line_code_unique_per_plant UNIQUE (plant_id, code)
);

CREATE TABLE core.machine (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    line_id       uuid        REFERENCES core.line(id) ON DELETE SET NULL,
    code          text        NOT NULL UNIQUE,
    name          text        NOT NULL,
    machine_type  text,
    criticality   quality.severity NOT NULL DEFAULT 'MEDIUM',
    installed_on  date,
    active        boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.app_user (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    username       text        NOT NULL UNIQUE,
    display_name   text        NOT NULL,
    email          text,
    role           text        NOT NULL
                   CHECK (role IN ('viewer','inspector','engineer','manager','admin')),
    lang           core.language_code NOT NULL DEFAULT 'th',
    password_hash  text,
    mfa_secret     text,
    active         boolean     NOT NULL DEFAULT true,
    last_login_at  timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN core.app_user.role IS
  'Five roles per SRS FR-S-01, ordered viewer < inspector < engineer < manager < admin. Enforced at the tool/query layer (SAD 5.1).';

-- Row-level scope: which lines a user may see (SEC RBAC)
CREATE TABLE core.user_line_scope (
    user_id  uuid NOT NULL REFERENCES core.app_user(id) ON DELETE CASCADE,
    line_id  uuid NOT NULL REFERENCES core.line(id)     ON DELETE CASCADE,
    PRIMARY KEY (user_id, line_id)
);

COMMENT ON TABLE core.user_line_scope IS
  'Empty scope = all lines. Non-empty = restricted. Applied as a predicate inside tools, never as response filtering (SAD 5.1).';

-- =====================================================================
-- 6. TELEMETRY — machine signals  (byte-identical to the platform, section 8 there)
-- =====================================================================

CREATE TABLE telemetry.sensor (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id     uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    signal         text        NOT NULL,
    unit           text,
    sample_rate_hz numeric(10,3),
    source         text        NOT NULL DEFAULT 'mqtt'
                   CHECK (source IN ('mqtt','opcua','modbus','csv','derived')),
    active         boolean     NOT NULL DEFAULT true,
    last_seen_at   timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sensor_signal_unique_per_machine UNIQUE (machine_id, signal)
);

-- Native range partitioning; converts to a TimescaleDB hypertable in section 13.
CREATE TABLE telemetry.sample (
    ts        timestamptz NOT NULL,
    sensor_id uuid        NOT NULL REFERENCES telemetry.sensor(id) ON DELETE CASCADE,
    value     double precision NOT NULL,
    quality   smallint    NOT NULL DEFAULT 192,
    PRIMARY KEY (sensor_id, ts)
) PARTITION BY RANGE (ts);

COMMENT ON COLUMN telemetry.sample.quality IS 'OPC-UA style status code. 192 = Good.';

CREATE TABLE telemetry.sample_2026_08 PARTITION OF telemetry.sample
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE telemetry.sample_2026_09 PARTITION OF telemetry.sample
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE telemetry.sample_2026_10 PARTITION OF telemetry.sample
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE telemetry.sample_default PARTITION OF telemetry.sample DEFAULT;

CREATE TABLE telemetry.feature (
    ts         timestamptz NOT NULL,
    sensor_id  uuid        NOT NULL REFERENCES telemetry.sensor(id) ON DELETE CASCADE,
    window_s   integer     NOT NULL,
    context    text        NOT NULL DEFAULT 'running'
               CHECK (context IN ('running','idle','changeover','stopped','startup')),
    name       text        NOT NULL,
    value      double precision NOT NULL,
    PRIMARY KEY (sensor_id, ts, window_s, name)
);

COMMENT ON TABLE telemetry.feature IS
  'RMS, kurtosis, crest factor, FFT band energies. Features are computed per machine context: comparing a running machine to an idle baseline is meaningless.';

CREATE TABLE telemetry.baseline (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sensor_id  uuid        NOT NULL REFERENCES telemetry.sensor(id) ON DELETE CASCADE,
    context    text        NOT NULL,
    name       text        NOT NULL,
    mean       double precision NOT NULL,
    std        double precision NOT NULL CHECK (std >= 0),
    p95        double precision,
    window_from timestamptz NOT NULL,
    window_to   timestamptz NOT NULL,
    version     integer     NOT NULL DEFAULT 1,
    confirmed_by uuid       REFERENCES core.app_user(id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT baseline_unique UNIQUE (sensor_id, context, name, version)
);

COMMENT ON COLUMN telemetry.baseline.confirmed_by IS
  'An engineer must confirm the healthy window. A baseline captured during an already-degraded period silently normalises the fault (SRS-06 risk).';

CREATE TABLE telemetry.health_index (
    ts              timestamptz NOT NULL,
    machine_id      uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    value           numeric(5,2) NOT NULL CHECK (value >= 0 AND value <= 100),
    components_json jsonb       NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (machine_id, ts)
);

CREATE TABLE telemetry.alert (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    opened_at           timestamptz NOT NULL DEFAULT now(),
    machine_id          uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    severity            quality.severity NOT NULL,
    signals_json        jsonb       NOT NULL DEFAULT '[]'::jsonb,
    evidence_json       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    suspected_component text,
    recommendation      text        NOT NULL,
    rul_low_days        numeric(8,2),
    rul_high_days       numeric(8,2),
    status              telemetry.alert_status NOT NULL DEFAULT 'open',
    closed_at           timestamptz,
    CONSTRAINT rul_interval_ordered CHECK (
        rul_low_days IS NULL OR rul_high_days IS NULL OR rul_high_days >= rul_low_days
    )
);

COMMENT ON COLUMN telemetry.alert.rul_low_days IS
  'RUL is stored as an interval, never a point estimate (SRS-06 C-04/AI-04). NULL means insufficient history — say so rather than guessing.';

CREATE TABLE telemetry.alert_feedback (
    alert_id      uuid PRIMARY KEY REFERENCES telemetry.alert(id) ON DELETE CASCADE,
    outcome       text        NOT NULL CHECK (outcome IN ('true_positive','false_positive','unknown')),
    actual_finding text,
    technician_id uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE telemetry.alert_feedback IS
  'Closes the loop: without outcome feedback there is no way to compute alert precision, and alert fatigue kills adoption.';

CREATE TABLE telemetry.maintenance_event (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id  uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    ts          timestamptz NOT NULL,
    kind        text        NOT NULL,
    description text,
    parts_json  jsonb,
    downtime_min numeric(10,2),
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 7. AGENT — runs and tools  (byte-identical to the platform)
--    Omitted vs platform: agent.finding, agent.briefing
-- =====================================================================

CREATE TABLE agent.tool (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name        text        NOT NULL UNIQUE,
    kind        text        NOT NULL CHECK (kind IN ('read','write')),
    risk        text        NOT NULL DEFAULT 'low' CHECK (risk IN ('low','medium','high')),
    schema_json jsonb       NOT NULL,
    min_role    text        NOT NULL DEFAULT 'viewer'
                CHECK (min_role IN ('viewer','inspector','engineer','manager','admin')),
    enabled     boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE agent.tool IS
  'The tool registry IS the agent capability boundary (ADR-005). There is deliberately no free-form shell or SQL tool.';

CREATE TABLE agent.conversation (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    channel    text        NOT NULL DEFAULT 'web' CHECK (channel IN ('web','discord','api')),
    lang       core.language_code NOT NULL DEFAULT 'th',
    title      text,
    started_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agent.message (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    conversation_id uuid        NOT NULL REFERENCES agent.conversation(id) ON DELETE CASCADE,
    role            agent.message_role NOT NULL,
    content         text        NOT NULL,
    ts              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agent.run (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ts              timestamptz NOT NULL DEFAULT now(),
    user_id         uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    conversation_id uuid        REFERENCES agent.conversation(id) ON DELETE SET NULL,
    correlation_id  text,
    kind            text        NOT NULL DEFAULT 'ask',
    question        text,
    answer          text,
    model           text        NOT NULL,
    prompt_version  text,
    facts_json      jsonb,
    tokens_in       integer,
    tokens_out      integer,
    latency_ms      integer,
    tool_call_count smallint    NOT NULL DEFAULT 0,
    outcome         agent.run_outcome NOT NULL DEFAULT 'ok',
    grounding_json  jsonb
);

COMMENT ON COLUMN agent.run.facts_json IS
  'The structured facts object handed to the model. Together with grounding_json this makes P-1 auditable after the fact.';
COMMENT ON COLUMN agent.run.grounding_json IS
  'Post-check result (ADR-013): numeric tokens found in the answer and whether each was matched to a tool result.';

CREATE TABLE agent.tool_call (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id        uuid        NOT NULL REFERENCES agent.run(id) ON DELETE CASCADE,
    ordinal       smallint    NOT NULL,
    tool_name     text        NOT NULL,
    args_json     jsonb       NOT NULL,
    result_digest text,
    row_count     integer,
    duration_ms   integer,
    ok            boolean     NOT NULL DEFAULT true,
    error         text,
    CONSTRAINT tool_call_ordinal_unique UNIQUE (run_id, ordinal)
);

CREATE TABLE agent.action_proposal (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id      uuid        REFERENCES agent.run(id) ON DELETE CASCADE,
    tool_name   text        NOT NULL,
    args_json   jsonb       NOT NULL,
    args_hash   text        NOT NULL,
    risk        text        NOT NULL CHECK (risk IN ('low','medium','high')),
    status      text        NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','approved','denied','expired','executed','failed')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    approver_id uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    decided_at  timestamptz,
    result_json jsonb
);

COMMENT ON TABLE agent.action_proposal IS
  'P-3 gate for write-capable tools (SRS FR-A-07). Approval binds to args_hash and expires, so a stale approval cannot execute different arguments.';

CREATE TABLE agent.feedback (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id     uuid        REFERENCES agent.run(id) ON DELETE CASCADE,
    message_id uuid        REFERENCES agent.message(id) ON DELETE CASCADE,
    user_id    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    rating     smallint    NOT NULL CHECK (rating IN (-1, 1)),
    reason     text,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 8. OPS — jobs, config, data quality  (byte-identical to the platform)
-- =====================================================================

CREATE TABLE ops.scheduled_job (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name         text        NOT NULL UNIQUE,
    cron         text        NOT NULL,
    enabled      boolean     NOT NULL DEFAULT true,
    last_run_at  timestamptz,
    last_status  text,
    last_error   text,
    next_run_at  timestamptz
);

CREATE TABLE ops.config (
    key         text PRIMARY KEY,
    value_json  jsonb       NOT NULL,
    description text,
    updated_by  uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE ops.config IS
  'Runtime-tunable settings only (thresholds, schedules). Secrets and infrastructure settings live in environment variables, never here.';

CREATE TABLE ops.data_quality_event (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ts          timestamptz NOT NULL DEFAULT now(),
    source      text        NOT NULL,
    severity    ops.dq_severity NOT NULL DEFAULT 'warning',
    entity      text,
    entity_id   text,
    message     text        NOT NULL,
    detail_json jsonb
);

COMMENT ON TABLE ops.data_quality_event IS
  'Clock skew, stuck sensor values, missing files, schema drift. Data problems are made visible instead of silently poisoning analysis.';

-- =====================================================================
-- 9. AUDIT — append-only  (byte-identical to the platform)
-- =====================================================================

CREATE TABLE audit.log (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts             timestamptz NOT NULL DEFAULT now(),
    user_id        uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    actor          text,
    correlation_id text,
    action         text        NOT NULL,
    entity         text        NOT NULL,
    entity_id      text,
    before_json    jsonb,
    after_json     jsonb,
    ip             inet,
    user_agent     text
);

COMMENT ON TABLE audit.log IS
  'Append-only. app_rw is granted INSERT and SELECT only; there is no UPDATE or DELETE grant anywhere (SEC).';

CREATE TABLE audit.auth_event (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts         timestamptz NOT NULL DEFAULT now(),
    username   text,
    user_id    uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    event      text NOT NULL CHECK (event IN ('login_ok','login_fail','logout','token_refresh',
                                              'password_change','mfa_fail','locked','key_rotated')),
    ip         inet,
    detail     text
);

-- =====================================================================
-- 10. TELEMETRY EXTENSION — MachineSense-only objects (migration machinesense_0001)
--     Everything here is additive to the platform's telemetry schema. In platform
--     mode this section is applied as the migration; nothing above it is.
-- =====================================================================

-- 10.1 Per-machine state: baseline lifecycle, re-baseline requirement (AI-07), rebaseline reason
CREATE TABLE telemetry.machine_state (
    machine_id            uuid PRIMARY KEY REFERENCES core.machine(id) ON DELETE CASCADE,
    rebaseline_required   boolean     NOT NULL DEFAULT false,
    rebaseline_reason     text,
    alerts_enabled        boolean     NOT NULL DEFAULT false,   -- AI-01: only after a confirmed baseline covering all contexts
    current_context       text        CHECK (current_context IN ('running','idle','changeover','stopped','startup')),
    context_since         timestamptz,
    last_scored_at        timestamptz,
    updated_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN telemetry.machine_state.rebaseline_required IS
  'Set by a maintenance_event of kind component_replaced or a confirmed failure repair (AI-07). While true, alerts for the machine are downgraded to WATCH until a new baseline is confirmed (ADR-P03).';

-- 10.2 Context classification rules and the resulting timeline (FR-05)
CREATE TABLE telemetry.context_rule (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id  uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    context     text        NOT NULL CHECK (context IN ('running','idle','changeover','stopped','startup')),
    expression  text        NOT NULL,          -- safe expression over signals / PLC tags, e.g. "rpm > 200 and motor_current > 5"
    priority    smallint    NOT NULL DEFAULT 10,
    hysteresis_s integer    NOT NULL DEFAULT 60 CHECK (hysteresis_s BETWEEN 0 AND 3600),
    config_version text     NOT NULL,
    CONSTRAINT context_rule_unique UNIQUE (machine_id, context)
);

CREATE TABLE telemetry.machine_context (
    machine_id  uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    ts          timestamptz NOT NULL,
    context     text        NOT NULL CHECK (context IN ('running','idle','changeover','stopped','startup')),
    until_ts    timestamptz,
    PRIMARY KEY (machine_id, ts)
);

-- 10.3 Derived signals (FR-06): expressions evaluated by the feature worker, never by the database or the LLM
CREATE TABLE telemetry.derived_signal (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sensor_id    uuid        NOT NULL UNIQUE REFERENCES telemetry.sensor(id) ON DELETE CASCADE,   -- the sensor row with source = 'derived'
    expression   text        NOT NULL,          -- e.g. "bearing_temp - ambient_temp"
    inputs_json  jsonb       NOT NULL,          -- ["bearing_temp","ambient_temp"] — validated against the machine's sensors at load
    config_version text     NOT NULL
);

-- 10.4 Machine alarm / error log, normalised (FR-07)
CREATE TABLE telemetry.alarm_event (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id  uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    ts          timestamptz NOT NULL,
    code        text        NOT NULL,
    severity    quality.severity NOT NULL DEFAULT 'MEDIUM',
    text        text,
    active      boolean     NOT NULL DEFAULT true,
    cleared_at  timestamptz,
    source      text        NOT NULL DEFAULT 'mqtt' CHECK (source IN ('mqtt','opcua','modbus','csv'))
);

-- 10.5 Anomaly models — versioned, metric-gated promotion (AI-02, AI-06, ADR-P06)
CREATE TABLE telemetry.anomaly_model (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id      uuid        REFERENCES core.machine(id) ON DELETE CASCADE,   -- NULL = fleet model per machine_type
    machine_type    text,
    algorithm       text        NOT NULL CHECK (algorithm IN ('isolation_forest','autoencoder','lstm_ae')),
    version         integer     NOT NULL,
    features_json   jsonb       NOT NULL,       -- ordered feature vector definition
    params_json     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    artefact_sha256 text        NOT NULL CHECK (length(artefact_sha256) = 64),
    trained_from    timestamptz NOT NULL,
    trained_to      timestamptz NOT NULL,
    precision       numeric(4,3) CHECK (precision BETWEEN 0 AND 1),   -- on the retrospective failure set
    lead_time_days  numeric(6,2) CHECK (lead_time_days >= 0),
    false_alerts_per_machine_month numeric(6,3),
    stage           text        NOT NULL DEFAULT 'candidate' CHECK (stage IN ('candidate','active','retired')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    promoted_at     timestamptz,
    CONSTRAINT anomaly_model_scope CHECK ((machine_id IS NOT NULL) <> (machine_type IS NOT NULL)),
    CONSTRAINT anomaly_model_unique UNIQUE (machine_id, machine_type, algorithm, version),
    CONSTRAINT anomaly_model_window CHECK (trained_to > trained_from)
);

CREATE UNIQUE INDEX ux_anomaly_model_active_machine ON telemetry.anomaly_model (machine_id, algorithm) WHERE stage = 'active' AND machine_id IS NOT NULL;
CREATE UNIQUE INDEX ux_anomaly_model_active_type    ON telemetry.anomaly_model (machine_type, algorithm) WHERE stage = 'active' AND machine_type IS NOT NULL;

-- 10.6 Anomaly scores with attribution (FR-10, AI-05)
CREATE TABLE telemetry.anomaly_score (
    ts                 timestamptz NOT NULL,
    machine_id         uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    model_id           uuid        NOT NULL REFERENCES telemetry.anomaly_model(id) ON DELETE RESTRICT,
    context            text        NOT NULL,
    score              numeric(5,4) NOT NULL CHECK (score BETWEEN 0 AND 1),
    contributions_json jsonb       NOT NULL,     -- {"bearing_temp_mean": 0.41, "vib_rms": 0.33, ...} sums to ~1
    PRIMARY KEY (machine_id, ts)
);

-- 10.7 Trend / degradation estimates with confidence intervals (FR-11, C-04)
CREATE TABLE telemetry.trend_estimate (
    ts            timestamptz NOT NULL,
    sensor_id     uuid        NOT NULL REFERENCES telemetry.sensor(id) ON DELETE CASCADE,
    feature       text        NOT NULL,
    context       text        NOT NULL,
    window_days   smallint    NOT NULL CHECK (window_days BETWEEN 1 AND 90),
    slope_per_day double precision NOT NULL,
    slope_ci_low  double precision NOT NULL,
    slope_ci_high double precision NOT NULL,
    pct_change    numeric(7,3),                  -- (now - start) / start * 100 over the window
    consecutive_rising_days smallint NOT NULL DEFAULT 0,
    PRIMARY KEY (sensor_id, feature, context, ts),
    CONSTRAINT trend_ci_ordered CHECK (slope_ci_high >= slope_ci_low)
);

-- 10.8 Alert grouping into incidents (FR-18, ADR-P10) and lifecycle transitions (FR-19)
CREATE TABLE telemetry.alert_group (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id          uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    suspected_component text        NOT NULL,
    opened_at           timestamptz NOT NULL DEFAULT now(),
    closed_at           timestamptz,
    max_severity        quality.severity NOT NULL,
    status              telemetry.alert_status NOT NULL DEFAULT 'open',
    title               text        NOT NULL,
    incident_summary    text,                     -- post-incident summary (generated from rows, not model text)
    genba_case_id       text                      -- link to Genba Memory (SRS-15) when the incident is filed as a case
);

CREATE UNIQUE INDEX ux_alert_group_open ON telemetry.alert_group (machine_id, suspected_component) WHERE closed_at IS NULL;

ALTER TABLE telemetry.alert
    ADD COLUMN group_id            uuid REFERENCES telemetry.alert_group(id) ON DELETE SET NULL,
    ADD COLUMN health_index        numeric(5,2) CHECK (health_index BETWEEN 0 AND 100),
    ADD COLUMN model_id            uuid REFERENCES telemetry.anomaly_model(id) ON DELETE SET NULL,
    ADD COLUMN consecutive_windows smallint,
    ADD COLUMN rule_code           text,
    ADD COLUMN rul_confidence      numeric(3,2) CHECK (rul_confidence BETWEEN 0.5 AND 0.99),
    ADD COLUMN rul_reason          text,
    ADD COLUMN suppressed          boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN telemetry.alert.rul_reason IS
  'When rul_low_days/high are NULL this says why — e.g. "insufficient history (1 of 3 comparable failures)" (AC-07). Never a number.';

CREATE TABLE telemetry.alert_transition (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alert_id    uuid        NOT NULL REFERENCES telemetry.alert(id) ON DELETE CASCADE,
    ts          timestamptz NOT NULL DEFAULT now(),
    from_status telemetry.alert_status,
    to_status   telemetry.alert_status NOT NULL,
    actor_id    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    channel     text        NOT NULL DEFAULT 'web' CHECK (channel IN ('web','discord','api','system')),
    snooze_until timestamptz,
    note        text
);

-- 10.9 Maintenance windows (FR-14) and failure events (FR-15)
CREATE TABLE telemetry.maintenance_window (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id  uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    starts_at   timestamptz NOT NULL,
    ends_at     timestamptz NOT NULL,
    kind        text        NOT NULL CHECK (kind IN ('planned_service','changeover','warmup','commissioning')),
    reason      text,
    declared_by uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT maintenance_window_ordered CHECK (ends_at > starts_at)
);

CREATE TABLE telemetry.failure_event (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id    uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    ts            timestamptz NOT NULL,
    failure_mode  text        NOT NULL,          -- e.g. bearing_wear, lubrication_loss, misalignment
    component     text        NOT NULL,
    downtime_min  numeric(10,2),
    cost          numeric(12,2),
    detected_by_alert_id uuid REFERENCES telemetry.alert(id) ON DELETE SET NULL,
    lead_time_days numeric(6,2),                 -- alert opened_at → failure ts (NULL if not detected)
    labelled_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- 10.10 RUL estimates: interval or nothing, gated (C-04, AI-04, ADR-P05)
CREATE TABLE telemetry.rul_estimate (
    ts               timestamptz NOT NULL,
    machine_id       uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    failure_mode     text        NOT NULL,
    low_days         numeric(8,2),
    high_days        numeric(8,2),
    confidence       numeric(3,2) CHECK (confidence BETWEEN 0.5 AND 0.99),
    comparable_failures smallint NOT NULL DEFAULT 0,
    reason           text,                       -- required when low/high are NULL
    method           text        NOT NULL DEFAULT 'empirical_ttf' CHECK (method IN ('empirical_ttf','trend_extrapolation')),
    PRIMARY KEY (machine_id, failure_mode, ts),
    CONSTRAINT rul_interval_or_nothing CHECK (
        (low_days IS NULL AND high_days IS NULL AND confidence IS NULL AND reason IS NOT NULL)
        OR (low_days IS NOT NULL AND high_days IS NOT NULL AND confidence IS NOT NULL AND high_days >= low_days)
    )
);

-- 10.11 Retraining runs (AI-06)
CREATE TABLE telemetry.retrain_run (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    trigger       text        NOT NULL CHECK (trigger IN ('schedule','confirmed_failure','manual')),
    machine_id    uuid        REFERENCES core.machine(id) ON DELETE SET NULL,
    candidate_model_id uuid   REFERENCES telemetry.anomaly_model(id) ON DELETE SET NULL,
    baseline_model_id  uuid   REFERENCES telemetry.anomaly_model(id) ON DELETE SET NULL,
    outcome       text        CHECK (outcome IN ('promoted','rejected','failed')),
    metrics_json  jsonb,
    note          text
);

-- 10.12 Work-order drafts (FR-21) — exported via IF-37, never posted automatically
CREATE TABLE telemetry.workorder_draft (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    alert_id       uuid        NOT NULL REFERENCES telemetry.alert(id) ON DELETE CASCADE,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    symptom        text        NOT NULL,
    evidence_json  jsonb       NOT NULL,
    tasks_json     jsonb       NOT NULL,          -- ["Check drive-side bearing lubrication", ...]
    parts_json     jsonb       NOT NULL DEFAULT '[]'::jsonb,
    priority       text        NOT NULL CHECK (priority IN ('low','medium','high','urgent')),
    due_within_days smallint,
    exported_at    timestamptz,
    export_ref     text                            -- CMMS id / file name
);

-- 10.13 Sensor health (sensor faults look like machine faults — SRS-06 risk)
CREATE TABLE telemetry.sensor_health (
    sensor_id      uuid PRIMARY KEY REFERENCES telemetry.sensor(id) ON DELETE CASCADE,
    checked_at     timestamptz NOT NULL DEFAULT now(),
    status         text        NOT NULL CHECK (status IN ('ok','gap','stuck','out_of_range','skew','offline')),
    gap_count_24h  integer     NOT NULL DEFAULT 0,
    stuck_count_24h integer    NOT NULL DEFAULT 0,
    range_count_24h integer    NOT NULL DEFAULT 0,
    last_good_at   timestamptz,
    detail         text
);

-- 10.14 One-minute rollup (retention: raw 90 d → 1-min 2 y). A continuous aggregate on TimescaleDB;
--        a plain table filled by the scheduler on native PostgreSQL.
CREATE TABLE telemetry.sample_1m (
    bucket     timestamptz NOT NULL,
    sensor_id  uuid        NOT NULL REFERENCES telemetry.sensor(id) ON DELETE CASCADE,
    n          integer     NOT NULL,
    avg        double precision NOT NULL,
    min        double precision NOT NULL,
    max        double precision NOT NULL,
    stddev     double precision,
    good_pct   numeric(5,2) NOT NULL DEFAULT 100,
    PRIMARY KEY (sensor_id, bucket)
);

-- 10.15 Configuration versions (sensor map, alert rules) loaded from deploy/*.yaml
CREATE TABLE telemetry.config_version (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind        text        NOT NULL CHECK (kind IN ('sensor_map','alert_rules')),
    version     text        NOT NULL,
    sha256      text        NOT NULL CHECK (length(sha256) = 64),
    loaded_at   timestamptz NOT NULL DEFAULT now(),
    loaded_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    content_json jsonb      NOT NULL,
    CONSTRAINT config_version_unique UNIQUE (kind, version)
);

-- 10.16 Baseline lifecycle: a baseline is inert until confirmed (ADR-P03)
ALTER TABLE telemetry.baseline
    ADD COLUMN active     boolean NOT NULL DEFAULT false,
    ADD COLUMN sample_n   integer,
    ADD COLUMN contexts_covered_json jsonb;

CREATE UNIQUE INDEX ux_baseline_active ON telemetry.baseline (sensor_id, context, name) WHERE active;

-- =====================================================================
-- 10.17 TRIGGERS — the constraints that carry the weight
-- =====================================================================

-- C-05 / AI-05 (P-6): an alert without a component, an inspection and attribution is not an alert
CREATE OR REPLACE FUNCTION telemetry.trg_alert_actionable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.suppressed THEN RETURN NEW; END IF;   -- suppressed rows record a would-be alert (FR-14) and need no recommendation
    IF NEW.suspected_component IS NULL OR btrim(NEW.suspected_component) = '' THEN
        RAISE EXCEPTION 'alert must name a suspected component (C-05)';
    END IF;
    IF NEW.recommendation IS NULL OR btrim(NEW.recommendation) = '' THEN
        RAISE EXCEPTION 'alert must carry a recommended inspection (C-05)';
    END IF;
    IF NOT (NEW.evidence_json ? 'attribution') OR jsonb_typeof(NEW.evidence_json->'attribution') <> 'array'
       OR jsonb_array_length(NEW.evidence_json->'attribution') = 0 THEN
        RAISE EXCEPTION 'alert must carry non-empty feature attribution (AI-05)';
    END IF;
    IF NEW.rul_low_days IS NULL AND NEW.rul_high_days IS NULL AND (NEW.rul_reason IS NULL OR btrim(NEW.rul_reason) = '') THEN
        RAISE EXCEPTION 'alert without a RUL interval must state the reason (C-04 / AI-04)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER alert_actionable BEFORE INSERT OR UPDATE ON telemetry.alert
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_alert_actionable();

-- FR-14: an alert cannot open inside an active maintenance window for its machine — it is recorded as suppressed
CREATE OR REPLACE FUNCTION telemetry.trg_alert_suppression() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NOT NEW.suppressed AND EXISTS (
        SELECT 1 FROM telemetry.maintenance_window w
        WHERE w.machine_id = NEW.machine_id AND NEW.opened_at >= w.starts_at AND NEW.opened_at < w.ends_at) THEN
        RAISE EXCEPTION 'alert falls inside a maintenance window for this machine — insert it with suppressed = true (FR-14)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER alert_suppression BEFORE INSERT ON telemetry.alert
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_alert_suppression();

-- ADR-P03: a baseline can only become active when an engineer confirmed it; one active per (sensor, context, name)
CREATE OR REPLACE FUNCTION telemetry.trg_baseline_activate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.active AND NEW.confirmed_by IS NULL THEN
        RAISE EXCEPTION 'baseline cannot be activated without engineer confirmation (SRS-06 risk: degraded baseline)';
    END IF;
    IF NEW.active AND (NEW.window_to - NEW.window_from) < interval '28 days' THEN
        RAISE EXCEPTION 'baseline window must cover at least 4 weeks (AI-01)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER baseline_activate BEFORE INSERT OR UPDATE OF active, confirmed_by ON telemetry.baseline
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_baseline_activate();

-- ADR-P05: a RUL interval requires >= 3 comparable failures (same machine type + failure mode)
CREATE OR REPLACE FUNCTION telemetry.trg_rul_gate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    IF NEW.low_days IS NOT NULL THEN
        SELECT count(*) INTO n
        FROM telemetry.failure_event f JOIN core.machine m ON m.id = f.machine_id
        WHERE f.failure_mode = NEW.failure_mode
          AND m.machine_type = (SELECT machine_type FROM core.machine WHERE id = NEW.machine_id)
          AND f.ts < NEW.ts;
        IF n < 3 THEN
            RAISE EXCEPTION 'RUL interval refused: % comparable failure(s), 3 required (AI-04)', n;
        END IF;
        NEW.comparable_failures := n;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER rul_gate BEFORE INSERT OR UPDATE ON telemetry.rul_estimate
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_rul_gate();

-- ADR-P06: promotion to active requires metrics >= the currently active model of the same scope
CREATE OR REPLACE FUNCTION telemetry.trg_model_promote() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cur telemetry.anomaly_model%ROWTYPE;
BEGIN
    IF NEW.stage = 'active' AND (TG_OP = 'INSERT' OR OLD.stage <> 'active') THEN
        IF NEW.precision IS NULL OR NEW.lead_time_days IS NULL THEN
            RAISE EXCEPTION 'model cannot be promoted without retrospective metrics (AI-06)';
        END IF;
        SELECT * INTO cur FROM telemetry.anomaly_model
        WHERE stage = 'active' AND algorithm = NEW.algorithm AND id <> NEW.id
          AND machine_id IS NOT DISTINCT FROM NEW.machine_id AND machine_type IS NOT DISTINCT FROM NEW.machine_type;
        IF FOUND AND (NEW.precision < cur.precision OR NEW.lead_time_days < cur.lead_time_days) THEN
            RAISE EXCEPTION 'model promotion refused: metrics below the active version (precision % < % or lead time % < %)',
                NEW.precision, cur.precision, NEW.lead_time_days, cur.lead_time_days;
        END IF;
        IF FOUND THEN UPDATE telemetry.anomaly_model SET stage = 'retired' WHERE id = cur.id; END IF;
        NEW.promoted_at := COALESCE(NEW.promoted_at, now());
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER model_promote BEFORE INSERT OR UPDATE OF stage ON telemetry.anomaly_model
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_model_promote();

-- AI-07: component replacement or a confirmed failure repair requires re-baselining
CREATE OR REPLACE FUNCTION telemetry.trg_maintenance_rebaseline() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.kind IN ('component_replaced','overhaul','failure_repair') THEN
        INSERT INTO telemetry.machine_state (machine_id, rebaseline_required, rebaseline_reason, updated_at)
        VALUES (NEW.machine_id, true, NEW.kind || ': ' || COALESCE(NEW.description, ''), now())
        ON CONFLICT (machine_id) DO UPDATE
            SET rebaseline_required = true, rebaseline_reason = EXCLUDED.rebaseline_reason, updated_at = now();
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER maintenance_rebaseline AFTER INSERT ON telemetry.maintenance_event
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_maintenance_rebaseline();

-- FR-20: feedback is written once; corrections are new rows on the alert transition log, not edits
CREATE OR REPLACE FUNCTION telemetry.trg_feedback_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'alert_feedback is immutable (FR-20)'; END $$;
CREATE TRIGGER feedback_immutable BEFORE UPDATE OR DELETE ON telemetry.alert_feedback
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_feedback_immutable();

-- FR-19: every status change is logged (AFTER, so the alert row exists for the FK); closed_at is set BEFORE
CREATE OR REPLACE FUNCTION telemetry.trg_alert_close_stamp() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('resolved','dismissed') THEN NEW.closed_at := COALESCE(NEW.closed_at, now()); END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER alert_close_stamp BEFORE INSERT OR UPDATE OF status ON telemetry.alert
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_alert_close_stamp();

CREATE OR REPLACE FUNCTION telemetry.trg_alert_transition_log() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO telemetry.alert_transition (alert_id, from_status, to_status, channel)
        VALUES (NEW.id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status, 'system');
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER alert_transition_log AFTER INSERT OR UPDATE OF status ON telemetry.alert
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_alert_transition_log();

-- Machine rows get a state row automatically
CREATE OR REPLACE FUNCTION telemetry.trg_machine_state_init() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO telemetry.machine_state (machine_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
    RETURN NEW;
END $$;
CREATE TRIGGER machine_state_init AFTER INSERT ON core.machine
    FOR EACH ROW EXECUTE FUNCTION telemetry.trg_machine_state_init();

-- updated_at
CREATE TRIGGER machine_updated_at BEFORE UPDATE ON core.machine FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER app_user_updated_at BEFORE UPDATE ON core.app_user FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER machine_state_updated_at BEFORE UPDATE ON telemetry.machine_state FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =====================================================================
-- 11. INDEXES
-- =====================================================================

-- telemetry (byte-identical statements)
CREATE INDEX idx_feature_lookup       ON telemetry.feature (sensor_id, name, ts DESC);
CREATE INDEX idx_health_index_ts      ON telemetry.health_index (ts DESC);
CREATE INDEX idx_alert_status         ON telemetry.alert (status, opened_at DESC);
CREATE INDEX idx_alert_machine        ON telemetry.alert (machine_id, opened_at DESC);
CREATE INDEX idx_maintenance_machine  ON telemetry.maintenance_event (machine_id, ts DESC);

-- ops (byte-identical statement)
CREATE INDEX idx_dq_event_ts     ON ops.data_quality_event (ts DESC, severity);

-- MachineSense extension
CREATE INDEX idx_sample_1m_lookup        ON telemetry.sample_1m (sensor_id, bucket DESC);
CREATE INDEX idx_machine_context_lookup  ON telemetry.machine_context (machine_id, ts DESC);
CREATE INDEX idx_alarm_event_machine     ON telemetry.alarm_event (machine_id, ts DESC);
CREATE INDEX idx_anomaly_score_ts        ON telemetry.anomaly_score (ts DESC);
CREATE INDEX idx_trend_estimate_ts       ON telemetry.trend_estimate (ts DESC);
CREATE INDEX idx_alert_group_status      ON telemetry.alert_group (status, opened_at DESC);
CREATE INDEX idx_alert_group_machine     ON telemetry.alert_group (machine_id, opened_at DESC);
CREATE INDEX idx_alert_transition_alert  ON telemetry.alert_transition (alert_id, ts);
CREATE INDEX idx_maintenance_window_mach ON telemetry.maintenance_window (machine_id, starts_at, ends_at);
CREATE INDEX idx_failure_event_machine   ON telemetry.failure_event (machine_id, ts DESC);
CREATE INDEX idx_failure_event_mode      ON telemetry.failure_event (failure_mode, ts DESC);
CREATE INDEX idx_rul_estimate_ts         ON telemetry.rul_estimate (ts DESC);
CREATE INDEX idx_workorder_alert         ON telemetry.workorder_draft (alert_id);
CREATE INDEX idx_dq_event_entity         ON ops.data_quality_event (entity, entity_id, ts DESC);
CREATE INDEX idx_agent_run_ts            ON agent.run (ts DESC);
CREATE INDEX idx_audit_log_ts            ON audit.log (ts DESC);
CREATE INDEX idx_audit_log_entity        ON audit.log (entity, entity_id);

-- =====================================================================
-- 12. VIEWS
-- =====================================================================

-- Latest health per machine with the alert-enabled flag and re-baseline state
CREATE VIEW telemetry.v_machine_health_latest AS
SELECT m.id AS machine_id, m.code, m.name, m.machine_type, m.criticality, l.code AS line_code,
       h.ts AS health_ts, h.value AS health_index, h.components_json,
       s.alerts_enabled, s.rebaseline_required, s.current_context,
       (SELECT count(*) FROM telemetry.alert_group g WHERE g.machine_id = m.id AND g.closed_at IS NULL) AS open_incidents
FROM core.machine m
LEFT JOIN core.line l ON l.id = m.line_id
LEFT JOIN telemetry.machine_state s ON s.machine_id = m.id
LEFT JOIN LATERAL (SELECT ts, value, components_json FROM telemetry.health_index hi WHERE hi.machine_id = m.id ORDER BY ts DESC LIMIT 1) h ON true
WHERE m.active;

-- FR-22: ranked "top risks this week" — health level, 7-day health drop, open incidents, criticality
CREATE VIEW telemetry.v_top_risks_week AS
WITH latest AS (
    SELECT machine_id, value AS health_now, ts
    FROM (SELECT machine_id, value, ts, row_number() OVER (PARTITION BY machine_id ORDER BY ts DESC) rn FROM telemetry.health_index) x WHERE rn = 1
), week_ago AS (
    SELECT DISTINCT ON (hi.machine_id) hi.machine_id, hi.value AS health_week_ago
    FROM telemetry.health_index hi JOIN latest l ON l.machine_id = hi.machine_id
    WHERE hi.ts <= l.ts - interval '7 days' ORDER BY hi.machine_id, hi.ts DESC
)
SELECT m.id AS machine_id, m.code, m.name, m.criticality,
       l.health_now, w.health_week_ago, (w.health_week_ago - l.health_now) AS health_drop_7d,
       (SELECT count(*) FROM telemetry.alert_group g WHERE g.machine_id = m.id AND g.closed_at IS NULL) AS open_incidents,
       (SELECT max_severity FROM telemetry.alert_group g WHERE g.machine_id = m.id AND g.closed_at IS NULL ORDER BY max_severity DESC LIMIT 1) AS top_severity,
       ROUND((100 - l.health_now) * 0.5 + COALESCE(w.health_week_ago - l.health_now, 0) * 1.5
             + CASE m.criticality WHEN 'CRITICAL' THEN 20 WHEN 'HIGH' THEN 10 WHEN 'MEDIUM' THEN 5 ELSE 0 END, 1) AS risk_score
FROM core.machine m JOIN latest l ON l.machine_id = m.id LEFT JOIN week_ago w ON w.machine_id = m.id
WHERE m.active
ORDER BY risk_score DESC;

-- AC-08 / AI-03: alert precision from technician feedback, per machine and month
CREATE VIEW telemetry.v_alert_precision AS
SELECT m.code AS machine_code, date_trunc('month', a.opened_at) AS month,
       count(f.alert_id) AS judged,
       sum(CASE WHEN f.outcome = 'true_positive' THEN 1 ELSE 0 END) AS true_positive,
       sum(CASE WHEN f.outcome = 'false_positive' THEN 1 ELSE 0 END) AS false_positive,
       sum(CASE WHEN f.outcome = 'unknown' THEN 1 ELSE 0 END) AS unknown,
       ROUND(sum(CASE WHEN f.outcome = 'true_positive' THEN 1 ELSE 0 END)::numeric
             / NULLIF(sum(CASE WHEN f.outcome IN ('true_positive','false_positive') THEN 1 ELSE 0 END), 0), 3) AS precision
FROM telemetry.alert a JOIN core.machine m ON m.id = a.machine_id JOIN telemetry.alert_feedback f ON f.alert_id = a.id
WHERE NOT a.suppressed
GROUP BY m.code, date_trunc('month', a.opened_at);

CREATE VIEW telemetry.v_open_incidents AS
SELECT g.id AS group_id, m.code AS machine_code, m.name AS machine_name, g.suspected_component, g.max_severity, g.status, g.opened_at, g.title,
       (SELECT count(*) FROM telemetry.alert a WHERE a.group_id = g.id) AS alerts,
       (SELECT max(a.opened_at) FROM telemetry.alert a WHERE a.group_id = g.id) AS last_alert_at,
       (SELECT a.rul_low_days FROM telemetry.alert a WHERE a.group_id = g.id ORDER BY a.opened_at DESC LIMIT 1) AS rul_low_days,
       (SELECT a.rul_high_days FROM telemetry.alert a WHERE a.group_id = g.id ORDER BY a.opened_at DESC LIMIT 1) AS rul_high_days
FROM telemetry.alert_group g JOIN core.machine m ON m.id = g.machine_id
WHERE g.closed_at IS NULL;

CREATE VIEW telemetry.v_sensor_health AS
SELECT s.id AS sensor_id, m.code AS machine_code, s.signal, s.unit, s.source, s.active, s.last_seen_at,
       COALESCE(h.status, 'ok') AS status, h.gap_count_24h, h.stuck_count_24h, h.range_count_24h, h.checked_at
FROM telemetry.sensor s JOIN core.machine m ON m.id = s.machine_id LEFT JOIN telemetry.sensor_health h ON h.sensor_id = s.id;

CREATE VIEW telemetry.v_baseline_current AS
SELECT b.sensor_id, m.code AS machine_code, s.signal, b.context, b.name, b.mean, b.std, b.p95, b.version, b.window_from, b.window_to, b.confirmed_by, b.created_at
FROM telemetry.baseline b JOIN telemetry.sensor s ON s.id = b.sensor_id JOIN core.machine m ON m.id = s.machine_id
WHERE b.active;

-- Data-quality summary for the last 24 h
CREATE VIEW telemetry.v_data_quality_24h AS
SELECT source, severity, count(*) AS events, min(ts) AS first_ts, max(ts) AS last_ts
FROM ops.data_quality_event WHERE ts >= now() - interval '24 hours'
GROUP BY source, severity;

-- =====================================================================
-- 13. ROLES AND GRANTS
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')       THEN CREATE ROLE app_rw       NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')       THEN CREATE ROLE app_ro       NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_ro')     THEN CREATE ROLE agent_ro     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'telemetry_ingest') THEN CREATE ROLE telemetry_ingest NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_ro') THEN CREATE ROLE analytics_ro NOLOGIN; END IF;
END
$$;

COMMENT ON ROLE telemetry_ingest IS
  'Ingest workers only: INSERT on sample, alarm_event and data-quality events; SELECT on sensor. Cannot read alerts, users or anything else. Narrowest role (SEC-P30).';
COMMENT ON ROLE agent_ro IS
  'Agent tool layer: SELECT on telemetry views and tables and core master data; never on app_user, audit or OT configuration (SEC-P41).';

GRANT USAGE ON SCHEMA core, quality, telemetry, agent, ops TO app_rw, app_ro;
GRANT USAGE ON SCHEMA audit TO app_rw, app_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, telemetry, agent, ops TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA telemetry, audit TO app_rw;

GRANT SELECT ON ALL TABLES IN SCHEMA core, telemetry, agent, ops, audit TO app_ro;
GRANT USAGE ON SCHEMA core, quality, telemetry TO analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, telemetry TO analytics_ro;

-- agent_ro: read-only, never on credentials, audit or OT configuration
GRANT USAGE ON SCHEMA core, quality, telemetry, agent TO agent_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, telemetry TO agent_ro;
REVOKE SELECT ON core.app_user        FROM agent_ro;
REVOKE SELECT ON core.user_line_scope FROM agent_ro;
REVOKE SELECT ON telemetry.config_version FROM agent_ro;   -- contains OT endpoints and register maps

-- telemetry_ingest: narrowest role
GRANT USAGE ON SCHEMA telemetry, ops, core TO telemetry_ingest;
GRANT SELECT ON telemetry.sensor, core.machine TO telemetry_ingest;
GRANT INSERT ON telemetry.sample, telemetry.alarm_event, ops.data_quality_event TO telemetry_ingest;
GRANT UPDATE (last_seen_at) ON telemetry.sensor TO telemetry_ingest;

ALTER DEFAULT PRIVILEGES IN SCHEMA core, telemetry, agent, ops GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, telemetry, agent, ops GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT INSERT, SELECT ON TABLES TO app_rw;

-- =====================================================================
-- 14. RETENTION helpers (SRS-06 §5): raw 90 d → 1-min 2 y; features 2 y; alerts/events 5 y
-- =====================================================================
CREATE OR REPLACE FUNCTION telemetry.rollup_1m(p_from timestamptz, p_to timestamptz) RETURNS integer
LANGUAGE sql AS $$
    INSERT INTO telemetry.sample_1m (bucket, sensor_id, n, avg, min, max, stddev, good_pct)
    SELECT date_trunc('minute', ts), sensor_id, count(*), avg(value), min(value), max(value), stddev_samp(value),
           ROUND(100.0 * sum(CASE WHEN quality >= 192 THEN 1 ELSE 0 END) / count(*), 2)
    FROM telemetry.sample WHERE ts >= p_from AND ts < p_to
    GROUP BY 1, 2
    ON CONFLICT (sensor_id, bucket) DO UPDATE SET n = EXCLUDED.n, avg = EXCLUDED.avg, min = EXCLUDED.min, max = EXCLUDED.max, stddev = EXCLUDED.stddev, good_pct = EXCLUDED.good_pct
    RETURNING 1;
$$;

CREATE VIEW telemetry.v_retention_due AS
SELECT 'sample' AS what, count(*) AS rows_due FROM telemetry.sample WHERE ts < now() - interval '90 days'
UNION ALL SELECT 'sample_1m', count(*) FROM telemetry.sample_1m WHERE bucket < now() - interval '2 years'
UNION ALL SELECT 'feature', count(*) FROM telemetry.feature WHERE ts < now() - interval '2 years'
UNION ALL SELECT 'anomaly_score', count(*) FROM telemetry.anomaly_score WHERE ts < now() - interval '2 years'
UNION ALL SELECT 'alert', count(*) FROM telemetry.alert WHERE opened_at < now() - interval '5 years';

-- =====================================================================
-- 15. TimescaleDB — hypertables, compression, continuous aggregate, retention (ADR-P01)
--     Executes only when the extension is installed; the schema is complete without it.
-- =====================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        -- telemetry.sample is declared with native partitions above (byte-identical to the platform). On a fresh
        -- MachineSense database the partitions are empty, so they are dropped and the parent becomes a hypertable.
        -- On an existing platform database use OPS-00 RB-12 instead of this block.
        DROP TABLE IF EXISTS telemetry.sample_2026_08, telemetry.sample_2026_09, telemetry.sample_2026_10, telemetry.sample_default;
        PERFORM create_hypertable('telemetry.sample', 'ts', chunk_time_interval => interval '1 day', migrate_data => true, if_not_exists => true);
        PERFORM create_hypertable('telemetry.feature', 'ts', chunk_time_interval => interval '7 days', migrate_data => true, if_not_exists => true);
        PERFORM create_hypertable('telemetry.anomaly_score', 'ts', chunk_time_interval => interval '30 days', migrate_data => true, if_not_exists => true);
        PERFORM create_hypertable('telemetry.health_index', 'ts', chunk_time_interval => interval '30 days', migrate_data => true, if_not_exists => true);
        ALTER TABLE telemetry.sample SET (timescaledb.compress, timescaledb.compress_segmentby = 'sensor_id', timescaledb.compress_orderby = 'ts DESC');
        PERFORM add_compression_policy('telemetry.sample', interval '7 days', if_not_exists => true);
        PERFORM add_retention_policy('telemetry.sample', interval '90 days', if_not_exists => true);
        PERFORM add_retention_policy('telemetry.feature', interval '2 years', if_not_exists => true);
        RAISE NOTICE 'TimescaleDB: hypertables, compression (7 d) and retention (90 d raw / 2 y features) configured; sample_1m is filled by telemetry.rollup_1m() from the scheduler (a continuous aggregate may replace it — OPS-06 §5.3).';
    ELSE
        RAISE NOTICE 'TimescaleDB not present — telemetry uses native partitioning; the scheduler runs rollup_1m() and retention jobs (supported configuration, ADR-P01).';
    END IF;
END
$$;

-- =====================================================================
-- 16. SCHEMA VERSION
-- =====================================================================
CREATE TABLE IF NOT EXISTS ops.schema_version (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    description text
);

INSERT INTO ops.schema_version (version, description)
VALUES ('machinesense_0001', 'MachineSense v1.0 standalone schema (DDS-06 v1.0): platform subset byte-identical + telemetry extension')
ON CONFLICT (version) DO NOTHING;
