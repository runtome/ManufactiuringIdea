-- =====================================================================
-- ShiftBrief (Production AI Analyst) — Database Schema
-- Document : DDS-02-ShiftBrief (see docs/DDS-ShiftBrief-Database-Design.md)
-- Version  : 1.0
-- Date     : 2026-09-12
-- Target   : PostgreSQL 16 (pgvector extension created for platform-mode
--            compatibility; ShiftBrief standalone does not use vectors)
--
-- Apply with:
--   psql -v ON_ERROR_STOP=1 -f schema.sql
--
-- STANDALONE deployment schema. In platform mode this file is NOT applied;
-- the platform schema (00/db/schema.sql) already contains every shared
-- table below, byte-identical, and the analytics schema in section 10 is
-- applied as migration shiftbrief_0001 instead (DDS-02 section 12).
--
-- BYTE-IDENTITY RULE: sections marked "byte-identical to the platform" are
-- copied verbatim from 00/db/schema.sql and checked by a CI diff.
-- =====================================================================

\set ON_ERROR_STOP on

-- =====================================================================
-- 1. EXTENSIONS
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_bytes, digest
CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector: embeddings
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- trigram search (hybrid retrieval)
CREATE EXTENSION IF NOT EXISTS btree_gin;     -- composite GIN indexes


-- =====================================================================
-- 2. SCHEMAS
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;       -- master data + production facts (byte-identical subset of platform core)
CREATE SCHEMA IF NOT EXISTS analytics;  -- ShiftBrief: sources, mappings, facts, briefs, alerts
CREATE SCHEMA IF NOT EXISTS agent;      -- ask/brief runs and tool calls (platform subset)
CREATE SCHEMA IF NOT EXISTS ops;        -- jobs, config, data quality
CREATE SCHEMA IF NOT EXISTS audit;      -- append-only audit trail

COMMENT ON SCHEMA core      IS 'Master data and production facts. Identical definitions to the platform; the platform adds machines and the vision/quality/telemetry schemas.';
COMMENT ON SCHEMA analytics IS 'ShiftBrief-owned: intake sources and versioned mappings, arrival expectations, the hashed facts object, briefs, alerts, subscriptions.';
COMMENT ON SCHEMA agent     IS 'Agent runs, tool calls, proposals. Subset of the platform agent schema.';
COMMENT ON SCHEMA ops       IS 'Scheduled jobs, runtime configuration, data-quality events, edge fleet (unused standalone, kept identical).';
COMMENT ON SCHEMA audit     IS 'Append-only audit log. INSERT only; no UPDATE or DELETE grants.';

-- =====================================================================
-- 3. HELPER FUNCTIONS
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

CREATE TYPE agent.run_outcome      AS ENUM ('ok', 'partial', 'refused', 'grounding_failed', 'error', 'budget_exceeded');
CREATE TYPE agent.message_role     AS ENUM ('user', 'assistant', 'system', 'tool');

CREATE TYPE ops.node_state         AS ENUM ('provisioning', 'online', 'degraded', 'offline', 'retired');
CREATE TYPE ops.dq_severity        AS ENUM ('info', 'warning', 'error');

COMMENT ON TYPE agent.run_outcome IS
  'grounding_failed = the post-check (ADR-013) found a number not present in tool results; the answer was withheld.';

-- =====================================================================
-- 5. CORE — master data and production facts  (byte-identical to the platform)
--    Omitted vs platform: core.machine
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

CREATE TABLE core.sku (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code        text        NOT NULL UNIQUE,
    name        text        NOT NULL,
    customer    text,
    spec_json   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.defect_type (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code        text        NOT NULL UNIQUE,
    name_th     text        NOT NULL,
    name_ja     text        NOT NULL,
    name_en     text        NOT NULL,
    category    text,
    is_critical boolean     NOT NULL DEFAULT false,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN core.defect_type.is_critical IS
  'Critical classes carry the recall >= 0.98 gate (SRS AI-03). A missed critical defect is worse than a false alarm.';

CREATE TABLE core.material_lot (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    lot_code      text        NOT NULL UNIQUE,
    material_code text        NOT NULL,
    supplier      text,
    received_at   timestamptz,
    attributes    jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.shift_calendar (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    plant_id    uuid        NOT NULL REFERENCES core.plant(id) ON DELETE CASCADE,
    shift       core.shift_code NOT NULL,
    starts_at   time        NOT NULL,
    ends_at     time        NOT NULL,
    valid_from  date        NOT NULL,
    valid_to    date,
    CONSTRAINT shift_period_valid CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

COMMENT ON TABLE core.shift_calendar IS
  'Shift boundaries are versioned by date. Required so that "yesterday, shift B" resolves correctly after a schedule change (SAD 5.8).';

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

-- ---------------------------------------------------------------------
-- Production facts (ShiftBrief / SRS-02)
-- ---------------------------------------------------------------------

CREATE TABLE core.ingest_batch (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    source             text        NOT NULL,
    filename           text,
    sha256             text        NOT NULL,
    rows_total         integer     NOT NULL DEFAULT 0,
    rows_ok            integer     NOT NULL DEFAULT 0,
    rows_quarantined   integer     NOT NULL DEFAULT 0,
    status             text        NOT NULL DEFAULT 'running'
                       CHECK (status IN ('running','succeeded','failed','rejected')),
    reject_reason      text,
    archive_uri        text,
    started_at         timestamptz NOT NULL DEFAULT now(),
    finished_at        timestamptz,
    CONSTRAINT ingest_rows_consistent CHECK (rows_ok + rows_quarantined <= rows_total)
);

COMMENT ON COLUMN core.ingest_batch.status IS
  'rejected = batch exceeded the >5% invalid-row threshold (SRS 6.3) and was not committed.';

CREATE TABLE core.production_fact (
    prod_date     date            NOT NULL,
    shift         core.shift_code NOT NULL,
    line_id       uuid            NOT NULL REFERENCES core.line(id) ON DELETE RESTRICT,
    sku_id        uuid            NOT NULL REFERENCES core.sku(id)  ON DELETE RESTRICT,
    qty_produced  integer         NOT NULL CHECK (qty_produced >= 0),
    qty_ng        integer         NOT NULL DEFAULT 0 CHECK (qty_ng >= 0),
    runtime_min   numeric(10,2)   CHECK (runtime_min  IS NULL OR runtime_min  >= 0),
    downtime_min  numeric(10,2)   CHECK (downtime_min IS NULL OR downtime_min >= 0),
    batch_id      uuid            REFERENCES core.ingest_batch(id) ON DELETE SET NULL,
    created_at    timestamptz     NOT NULL DEFAULT now(),
    updated_at    timestamptz     NOT NULL DEFAULT now(),
    PRIMARY KEY (prod_date, shift, line_id, sku_id),
    CONSTRAINT ng_not_exceeding_produced CHECK (qty_ng <= qty_produced)
);

COMMENT ON TABLE core.production_fact IS
  'Natural-key primary key makes re-ingest idempotent by UPSERT (SRS FR-P-05).';

CREATE TABLE core.defect_fact (
    prod_date      date            NOT NULL,
    shift          core.shift_code NOT NULL,
    line_id        uuid            NOT NULL REFERENCES core.line(id)        ON DELETE RESTRICT,
    sku_id         uuid            NOT NULL REFERENCES core.sku(id)         ON DELETE RESTRICT,
    defect_type_id uuid            NOT NULL REFERENCES core.defect_type(id) ON DELETE RESTRICT,
    qty            integer         NOT NULL CHECK (qty >= 0),
    batch_id       uuid            REFERENCES core.ingest_batch(id) ON DELETE SET NULL,
    created_at     timestamptz     NOT NULL DEFAULT now(),
    PRIMARY KEY (prod_date, shift, line_id, sku_id, defect_type_id)
);

CREATE TABLE core.quarantine_row (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    batch_id   uuid        NOT NULL REFERENCES core.ingest_batch(id) ON DELETE CASCADE,
    row_no     integer     NOT NULL,
    raw_json   jsonb       NOT NULL,
    reason     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN core.quarantine_row.reason IS
  'Human-readable. Must let a data owner fix the source file without reading code (SRS FR-P-02).';

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
--    ops.edge_node and its children are kept for identity; unused standalone.
--    The platform's ALTER TABLE vision.* statements are omitted (no vision schema here).
-- =====================================================================

CREATE TABLE ops.edge_node (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    node_code      text        NOT NULL UNIQUE,
    line_id        uuid        REFERENCES core.line(id) ON DELETE SET NULL,
    hardware       text,
    state          ops.node_state NOT NULL DEFAULT 'provisioning',
    app_version    text,
    model_versions jsonb       NOT NULL DEFAULT '{}'::jsonb,
    config_etag    text,
    last_heartbeat timestamptz,
    buffer_depth   integer     NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN ops.edge_node.buffer_depth IS
  'Unsynced records on the node. A rising buffer is the earliest signal of a connectivity or ingest problem (OPS RB-05).';

CREATE TABLE ops.node_event (
    id        uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    node_id   uuid        NOT NULL REFERENCES ops.edge_node(id) ON DELETE CASCADE,
    ts        timestamptz NOT NULL DEFAULT now(),
    kind      text        NOT NULL,
    detail_json jsonb     NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE ops.node_health (
    node_id     uuid        NOT NULL REFERENCES ops.edge_node(id) ON DELETE CASCADE,
    ts          timestamptz NOT NULL,
    cpu_pct     numeric(5,2),
    gpu_pct     numeric(5,2),
    mem_pct     numeric(5,2),
    disk_pct    numeric(5,2),
    temp_c      numeric(5,2),
    fps         numeric(8,2),
    buffer_depth integer,
    PRIMARY KEY (node_id, ts)
);

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
-- 10. ANALYTICS — ShiftBrief-only schema
--     Candidates for back-port into the platform when it adopts them.
-- =====================================================================

CREATE TYPE analytics.batch_disposition AS ENUM ('committed', 'rejected', 'held_drift');
CREATE TYPE analytics.brief_kind        AS ENUM ('daily', 'shift', 'adhoc');

CREATE TABLE analytics.source (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code          text        NOT NULL UNIQUE,
    name          text        NOT NULL,
    kind          text        NOT NULL CHECK (kind IN ('folder','upload','imap','sftp')),
    location      text,
    file_pattern  text        NOT NULL DEFAULT '*.csv',
    encoding      text        NOT NULL DEFAULT 'utf-8',
    plant_id      uuid        REFERENCES core.plant(id) ON DELETE RESTRICT,
    active        boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE analytics.source IS
  'Where production files come from (IF-20). One source = one file contract = one mapping lineage.';

CREATE TABLE analytics.source_mapping (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    source_id          uuid        NOT NULL REFERENCES analytics.source(id) ON DELETE CASCADE,
    version            integer     NOT NULL,
    mapping_yaml       text        NOT NULL,
    header_fingerprint text        NOT NULL,
    reason             text        NOT NULL,
    created_by         uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    active_from        timestamptz NOT NULL DEFAULT now(),
    active_to          timestamptz,
    CONSTRAINT source_mapping_version_unique UNIQUE (source_id, version),
    CONSTRAINT source_mapping_reason_present CHECK (length(reason) >= 5)
);

COMMENT ON TABLE analytics.source_mapping IS
  'Versioned column mapping (ADR-S02). header_fingerprint = sha256 of the normalised expected header; a file whose header does not match is HELD with MAPPING_DRIFT, never guessed.';

CREATE TABLE analytics.file_expectation (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    source_id     uuid        NOT NULL REFERENCES analytics.source(id) ON DELETE CASCADE,
    cadence       text        NOT NULL DEFAULT 'daily' CHECK (cadence IN ('daily','per_shift','weekly')),
    expected_by   time        NOT NULL,
    grace_minutes integer     NOT NULL DEFAULT 30 CHECK (grace_minutes >= 0),
    weekdays      smallint[]  NOT NULL DEFAULT '{1,2,3,4,5,6,7}',
    active        boolean     NOT NULL DEFAULT true,
    CONSTRAINT file_expectation_unique UNIQUE (source_id, cadence)
);

COMMENT ON TABLE analytics.file_expectation IS
  'When a file is due (SRS-02 FR-08). Past expected_by + grace with no batch → FILE_NOT_ARRIVED alert; the brief for that date is not generated from partial data.';

-- Intake outcome detail beyond core.ingest_batch.status
CREATE TABLE analytics.batch_detail (
    batch_id           uuid PRIMARY KEY REFERENCES core.ingest_batch(id) ON DELETE CASCADE,
    source_id          uuid        NOT NULL REFERENCES analytics.source(id) ON DELETE RESTRICT,
    mapping_id         uuid        REFERENCES analytics.source_mapping(id) ON DELETE SET NULL,
    disposition        analytics.batch_disposition NOT NULL,
    dates_covered      daterange,
    supersedes_batch_id uuid       REFERENCES core.ingest_batch(id) ON DELETE SET NULL,
    header_seen        text[],
    drift_detail       jsonb,
    pii_pseudonymised  boolean     NOT NULL DEFAULT true
);

COMMENT ON COLUMN analytics.batch_detail.supersedes_batch_id IS
  'Set when a corrected file re-covers dates already loaded. Downstream facts are recomputed as a new version and the brief is REVISED (ADR-S08).';

CREATE TABLE analytics.facts (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    fact_date        date        NOT NULL,
    line_id          uuid        REFERENCES core.line(id) ON DELETE CASCADE,   -- NULL = all lines
    facts_version    text        NOT NULL,
    facts_json       jsonb       NOT NULL,
    facts_sha256     text        NOT NULL,
    significant      boolean,
    p_value          numeric(10,8),
    data_complete    boolean     NOT NULL DEFAULT true,
    source_batches   uuid[]      NOT NULL DEFAULT '{}',
    computed_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT facts_unique_per_version UNIQUE NULLS NOT DISTINCT (fact_date, line_id, facts_version),
    CONSTRAINT facts_sha_len CHECK (length(facts_sha256) = 64)
);

COMMENT ON TABLE analytics.facts IS
  'THE product (ADR-S01). The sole numeric input to the LLM. Deterministic for (rows, facts_version); facts_sha256 lets a regeneration prove it reproduced the same object (FACTS_STALE otherwise).';
COMMENT ON COLUMN analytics.facts.line_id IS 'NULL means the plant-wide facts object for the date.';
COMMENT ON COLUMN analytics.facts.data_complete IS
  'False when an expected shift/line is missing for the date. The brief must state this before any comparison.';

CREATE TABLE analytics.brief (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind            analytics.brief_kind NOT NULL DEFAULT 'daily',
    brief_date      date        NOT NULL,
    line_id         uuid        REFERENCES core.line(id) ON DELETE CASCADE,
    lang            core.language_code NOT NULL DEFAULT 'th',
    tone            text        NOT NULL DEFAULT 'short' CHECK (tone IN ('short','long')),
    facts_id        uuid        NOT NULL REFERENCES analytics.facts(id) ON DELETE RESTRICT,
    run_id          uuid        REFERENCES agent.run(id) ON DELETE SET NULL,
    text            text,
    sources_json    jsonb       NOT NULL DEFAULT '[]'::jsonb,
    grounding_json  jsonb,
    withheld        boolean     NOT NULL DEFAULT false,
    withheld_reason text,
    model           text,
    prompt_version  text,
    revised_of      uuid        REFERENCES analytics.brief(id) ON DELETE SET NULL,
    delivered_at    timestamptz,
    delivery_json   jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT brief_withheld_has_reason  CHECK (NOT withheld OR withheld_reason IS NOT NULL),
    CONSTRAINT brief_withheld_has_no_text CHECK (NOT withheld OR text IS NULL),
    CONSTRAINT brief_not_self_revision    CHECK (revised_of IS NULL OR revised_of <> id)
);

COMMENT ON TABLE analytics.brief IS
  'Prose derived from exactly one facts row. A withheld brief stores NO text (constraint). revised_of links a corrected-file brief to the original, which is never overwritten (ADR-S08).';

CREATE TABLE analytics.alert_event (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ts          timestamptz NOT NULL DEFAULT now(),
    kind        text        NOT NULL
                CHECK (kind IN ('defect_rate_threshold','defect_rate_change','file_not_arrived',
                                'batch_rejected','mapping_drift','brief_withheld','brief_revised')),
    severity    text        NOT NULL DEFAULT 'warning' CHECK (severity IN ('info','warning','critical')),
    fact_date   date,
    line_id     uuid        REFERENCES core.line(id) ON DELETE SET NULL,
    detail_json jsonb       NOT NULL DEFAULT '{}'::jsonb,
    delivered_at timestamptz,
    acknowledged_by uuid    REFERENCES core.app_user(id) ON DELETE SET NULL,
    acknowledged_at timestamptz
);

CREATE TABLE analytics.subscription (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    channel     text        NOT NULL CHECK (channel IN ('discord','email')),
    target      text        NOT NULL,
    lang        core.language_code NOT NULL DEFAULT 'th',
    tone        text        NOT NULL DEFAULT 'short' CHECK (tone IN ('short','long')),
    line_id     uuid        REFERENCES core.line(id) ON DELETE CASCADE,
    kinds       text[]      NOT NULL DEFAULT '{daily}',
    active      boolean     NOT NULL DEFAULT true,
    created_by  uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE analytics.subscription IS
  'Who receives which brief where, in which language and length (SRS-02 FR-21/22/27).';

-- =====================================================================
-- 11. INDEXES
-- =====================================================================

-- core (byte-identical statements)
CREATE INDEX idx_production_fact_date      ON core.production_fact (prod_date DESC);
CREATE INDEX idx_production_fact_line_date ON core.production_fact (line_id, prod_date DESC);
CREATE INDEX idx_defect_fact_date          ON core.defect_fact (prod_date DESC);
CREATE INDEX idx_defect_fact_type          ON core.defect_fact (defect_type_id, prod_date DESC);
CREATE INDEX idx_quarantine_batch          ON core.quarantine_row (batch_id);
CREATE INDEX idx_ingest_batch_sha          ON core.ingest_batch (sha256);

-- agent
CREATE INDEX idx_run_ts             ON agent.run (ts DESC);
CREATE INDEX idx_run_user_ts        ON agent.run (user_id, ts DESC);
CREATE INDEX idx_run_outcome        ON agent.run (outcome, ts DESC);
CREATE INDEX idx_tool_call_run      ON agent.tool_call (run_id, ordinal);
CREATE INDEX idx_message_conv       ON agent.message (conversation_id, ts);
CREATE INDEX idx_proposal_pending   ON agent.action_proposal (status, expires_at)
                                     WHERE status = 'pending';

-- ops / audit
CREATE INDEX idx_node_event_ts   ON ops.node_event (node_id, ts DESC);
CREATE INDEX idx_dq_event_ts     ON ops.data_quality_event (ts DESC, severity);
CREATE INDEX idx_audit_ts        ON audit.log (ts DESC);
CREATE INDEX idx_audit_entity    ON audit.log (entity, entity_id, ts DESC);
CREATE INDEX idx_audit_user      ON audit.log (user_id, ts DESC);
CREATE INDEX idx_audit_corr      ON audit.log (correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_auth_event_ts   ON audit.auth_event (ts DESC);

-- analytics
CREATE INDEX idx_source_mapping_active  ON analytics.source_mapping (source_id) WHERE active_to IS NULL;
CREATE INDEX idx_batch_detail_source    ON analytics.batch_detail (source_id, disposition);
CREATE INDEX idx_batch_detail_dates     ON analytics.batch_detail USING gist (dates_covered);
CREATE INDEX idx_facts_date             ON analytics.facts (fact_date DESC, line_id);
CREATE INDEX idx_facts_significant      ON analytics.facts (fact_date DESC) WHERE significant;
CREATE INDEX idx_brief_date             ON analytics.brief (brief_date DESC, line_id, lang);
CREATE INDEX idx_brief_withheld         ON analytics.brief (created_at DESC) WHERE withheld;
CREATE INDEX idx_brief_revised          ON analytics.brief (revised_of) WHERE revised_of IS NOT NULL;
CREATE INDEX idx_alert_event_ts         ON analytics.alert_event (ts DESC, kind);
CREATE INDEX idx_alert_unacked          ON analytics.alert_event (ts DESC) WHERE acknowledged_at IS NULL;

-- =====================================================================
-- 12. TRIGGERS
-- =====================================================================

CREATE TRIGGER trg_plant_updated       BEFORE UPDATE ON core.plant
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_line_updated        BEFORE UPDATE ON core.line
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_sku_updated         BEFORE UPDATE ON core.sku
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_user_updated        BEFORE UPDATE ON core.app_user
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_production_updated  BEFORE UPDATE ON core.production_fact
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_source_updated      BEFORE UPDATE ON analytics.source
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Facts rows are immutable once written: a change is a new version, never an edit.
CREATE OR REPLACE FUNCTION analytics.reject_facts_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'analytics.facts is append-only: write a new facts_version instead of updating %', OLD.id;
END;
$$;
CREATE TRIGGER trg_facts_immutable BEFORE UPDATE OR DELETE ON analytics.facts
    FOR EACH ROW EXECUTE FUNCTION analytics.reject_facts_update();

COMMENT ON FUNCTION analytics.reject_facts_update() IS
  'ADR-S01: the facts object is the provenance of every brief. It cannot be edited or deleted; it can only be superseded by a new version.';

-- =====================================================================
-- 13. VIEWS
-- =====================================================================

-- ---- byte-identical to the platform (00) ----
CREATE OR REPLACE VIEW core.v_kpi_daily AS
SELECT
    pf.prod_date,
    pf.line_id,
    l.code                                     AS line_code,
    SUM(pf.qty_produced)                       AS qty_produced,
    SUM(pf.qty_ng)                             AS qty_ng,
    CASE WHEN SUM(pf.qty_produced) > 0
         THEN ROUND(100.0 * SUM(pf.qty_ng) / SUM(pf.qty_produced), 4)
         ELSE NULL END                         AS defect_rate_pct,
    SUM(pf.runtime_min)                        AS runtime_min,
    SUM(pf.downtime_min)                       AS downtime_min
FROM core.production_fact pf
JOIN core.line l ON l.id = pf.line_id
GROUP BY pf.prod_date, pf.line_id, l.code;

COMMENT ON VIEW core.v_kpi_daily IS
  'defect_rate_pct is NULL (not zero) when nothing was produced. Zero would be a false claim of perfect quality.';

-- Defect Pareto with cumulative share
CREATE OR REPLACE VIEW core.v_defect_pareto AS
SELECT
    df.prod_date,
    df.line_id,
    dt.code        AS defect_code,
    dt.name_en,
    dt.name_th,
    dt.name_ja,
    SUM(df.qty)    AS qty,
    ROUND(100.0 * SUM(df.qty) /
          NULLIF(SUM(SUM(df.qty)) OVER (PARTITION BY df.prod_date, df.line_id), 0), 2) AS share_pct,
    ROUND(100.0 * SUM(SUM(df.qty)) OVER (
              PARTITION BY df.prod_date, df.line_id
              ORDER BY SUM(df.qty) DESC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) /
          NULLIF(SUM(SUM(df.qty)) OVER (PARTITION BY df.prod_date, df.line_id), 0), 2) AS cumulative_pct
FROM core.defect_fact df
JOIN core.defect_type dt ON dt.id = df.defect_type_id
GROUP BY df.prod_date, df.line_id, dt.code, dt.name_en, dt.name_th, dt.name_ja;


CREATE OR REPLACE VIEW core.v_oee_daily AS
SELECT
    pf.prod_date,
    pf.line_id,
    SUM(pf.runtime_min)                                        AS runtime_min,
    SUM(pf.runtime_min + COALESCE(pf.downtime_min, 0))         AS planned_min,
    ROUND(100.0 * SUM(pf.runtime_min)
          / NULLIF(SUM(pf.runtime_min + COALESCE(pf.downtime_min, 0)), 0), 2) AS availability_pct,
    ROUND(100.0 * SUM(pf.qty_produced - pf.qty_ng)
          / NULLIF(SUM(pf.qty_produced), 0), 2)                AS quality_pct
FROM core.production_fact pf
WHERE pf.runtime_min IS NOT NULL
GROUP BY pf.prod_date, pf.line_id;

COMMENT ON VIEW core.v_oee_daily IS
  'Performance component is intentionally omitted: it requires a validated ideal cycle time per SKU. Reporting a 2-of-3 OEE is honest; inventing the third factor is not.';


-- ---- ShiftBrief-specific ----

-- Line x shift heatmap for a date range
CREATE OR REPLACE VIEW analytics.v_line_shift_daily AS
SELECT
    pf.prod_date,
    pf.line_id,
    l.code                                     AS line_code,
    pf.shift,
    SUM(pf.qty_produced)                       AS qty_produced,
    SUM(pf.qty_ng)                             AS qty_ng,
    CASE WHEN SUM(pf.qty_produced) > 0
         THEN ROUND(100.0 * SUM(pf.qty_ng) / SUM(pf.qty_produced), 4)
         ELSE NULL END                         AS defect_rate_pct,
    (SUM(pf.qty_produced) >= 100)              AS rankable
FROM core.production_fact pf
JOIN core.line l ON l.id = pf.line_id
GROUP BY pf.prod_date, pf.line_id, l.code, pf.shift;

COMMENT ON VIEW analytics.v_line_shift_daily IS
  'rankable=false below 100 pcs (ADR-S04): the cell is shown but never headlined as "worst".';

-- Plant-wide daily series with 7-day and 30-day trailing baselines (excluding the day itself)
CREATE OR REPLACE VIEW analytics.v_trend_daily AS
WITH d AS (
    SELECT prod_date, SUM(qty_produced) AS produced, SUM(qty_ng) AS ng
    FROM core.production_fact GROUP BY prod_date
)
SELECT
    d.prod_date,
    d.produced,
    d.ng,
    CASE WHEN d.produced > 0 THEN ROUND(100.0 * d.ng / d.produced, 4) END          AS defect_rate_pct,
    (SELECT ROUND(100.0 * SUM(ng) / NULLIF(SUM(produced), 0), 4) FROM d b
      WHERE b.prod_date BETWEEN d.prod_date - 7  AND d.prod_date - 1)             AS baseline_7d_pct,
    (SELECT ROUND(100.0 * SUM(ng) / NULLIF(SUM(produced), 0), 4) FROM d b
      WHERE b.prod_date BETWEEN d.prod_date - 30 AND d.prod_date - 1)             AS baseline_30d_pct,
    (SELECT SUM(produced) FROM d b WHERE b.prod_date BETWEEN d.prod_date - 7 AND d.prod_date - 1) AS baseline_7d_produced,
    (SELECT SUM(ng)       FROM d b WHERE b.prod_date BETWEEN d.prod_date - 7 AND d.prod_date - 1) AS baseline_7d_ng
FROM d;

COMMENT ON VIEW analytics.v_trend_daily IS
  'Baselines exclude the day itself and are pooled (sum of ng / sum of produced), which is what the two-proportion z-test in the facts builder compares against.';

-- Latest facts row per (date, line)
CREATE OR REPLACE VIEW analytics.v_latest_facts AS
SELECT DISTINCT ON (f.fact_date, f.line_id)
    f.*
FROM analytics.facts f
ORDER BY f.fact_date, f.line_id, f.computed_at DESC;

-- Latest brief per (date, line, lang), with revision flag
CREATE OR REPLACE VIEW analytics.v_latest_brief AS
SELECT DISTINCT ON (b.brief_date, b.line_id, b.lang, b.kind)
    b.*,
    (b.revised_of IS NOT NULL) AS is_revision
FROM analytics.brief b
ORDER BY b.brief_date, b.line_id, b.lang, b.kind, b.created_at DESC;

-- Brief health (P-1 observability)
CREATE OR REPLACE VIEW analytics.v_brief_health AS
SELECT
    date_trunc('day', b.created_at)                                    AS day,
    COUNT(*)                                                           AS briefs,
    COUNT(*) FILTER (WHERE b.withheld)                                 AS withheld,
    COUNT(*) FILTER (WHERE b.revised_of IS NOT NULL)                   AS revisions,
    COUNT(*) FILTER (WHERE f.significant IS false)                     AS within_normal_variation,
    ROUND(100.0 * COUNT(*) FILTER (WHERE b.withheld) / NULLIF(COUNT(*), 0), 3) AS withheld_pct
FROM analytics.brief b
JOIN analytics.facts f ON f.id = b.facts_id
GROUP BY 1;

-- Intake health per source
CREATE OR REPLACE VIEW analytics.v_intake_health AS
SELECT
    s.code                                                        AS source_code,
    COUNT(bd.batch_id)                                            AS batches,
    COUNT(*) FILTER (WHERE bd.disposition = 'committed')          AS committed,
    COUNT(*) FILTER (WHERE bd.disposition = 'rejected')           AS rejected,
    COUNT(*) FILTER (WHERE bd.disposition = 'held_drift')         AS held_drift,
    COALESCE(SUM(ib.rows_quarantined), 0)                         AS rows_quarantined,
    MAX(ib.finished_at)                                           AS last_batch_at
FROM analytics.source s
LEFT JOIN analytics.batch_detail bd ON bd.source_id = s.id
LEFT JOIN core.ingest_batch ib ON ib.id = bd.batch_id
GROUP BY s.code;

-- =====================================================================
-- 14. ROLES AND GRANTS
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')      THEN CREATE ROLE app_rw      NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')      THEN CREATE ROLE app_ro      NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_ro')    THEN CREATE ROLE agent_ro    NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_ro')THEN CREATE ROLE analytics_ro NOLOGIN; END IF;
END
$$;

COMMENT ON ROLE agent_ro IS
  'Narrative tools AND text-to-SQL run as this role. SELECT on whitelisted views only; statement_timeout is set per session by the executor (ADR-S07).';

GRANT USAGE ON SCHEMA core, analytics, agent, ops TO app_rw, app_ro;
GRANT USAGE ON SCHEMA audit TO app_rw, app_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, analytics, agent, ops TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO app_rw;

GRANT SELECT ON ALL TABLES IN SCHEMA core, analytics, agent, ops, audit TO app_ro;
GRANT USAGE ON SCHEMA core, analytics TO analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, analytics TO analytics_ro;

-- agent_ro: deliberately NARROW. Views only for the text-to-SQL path; no base
-- tables with row-level detail, no users, no scope, no archives.
GRANT USAGE ON SCHEMA core, analytics, agent TO agent_ro;
GRANT SELECT ON core.line, core.sku, core.defect_type, core.shift_calendar, core.plant TO agent_ro;
GRANT SELECT ON core.v_kpi_daily, core.v_defect_pareto, core.v_oee_daily TO agent_ro;
GRANT SELECT ON analytics.v_line_shift_daily, analytics.v_trend_daily,
                analytics.v_latest_facts, analytics.v_latest_brief TO agent_ro;
GRANT SELECT ON agent.run, agent.tool_call TO agent_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA core, analytics, agent, ops
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, analytics, agent, ops
    GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT INSERT, SELECT ON TABLES TO app_rw;

-- =====================================================================
-- 15. SCHEMA VERSION
-- =====================================================================

CREATE TABLE IF NOT EXISTS ops.schema_version (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    description text
);

INSERT INTO ops.schema_version (version, description)
VALUES ('1.0.0-shiftbrief', 'ShiftBrief standalone schema (DDS-02 v1.0). core.* shared tables identical to platform 1.0.0.')
ON CONFLICT (version) DO NOTHING;

-- =====================================================================
-- END OF SCHEMA
-- =====================================================================
