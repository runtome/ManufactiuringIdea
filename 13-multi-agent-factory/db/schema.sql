-- =====================================================================
--  KaizenSwarm — PostgreSQL 16 schema (standalone deployment)
--  DDS-13-KaizenSwarm v1.0 (Draft) · 2026-09-21 · Suphot N.
--
--  Sections 1–9 are EXTRACTED VERBATIM from ../../00-factorybrain-platform/db/schema.sql
--  (extensions, helpers, the enums the extracted sections use, the whole core and agent
--  sections, audit, their indexes, triggers and views). TEST-13 TC-002 diffs every block
--  against the platform file; a difference is a defect in this file, never in the platform's.
--  Sections 10–19 are the KaizenSwarm extension (schema swarm, migration swarm_0001).
--
--  Platform mode (SAD-13 §9): apply ONLY sections 10–19 (migration swarm_0001) on the
--  platform database; sections 1–9 already exist there. KaizenSwarm owns agent.finding and
--  agent.briefing and reuses agent.run / agent.tool_call / agent.tool.
--
--  NOT EXECUTED on the authoring machine (no PostgreSQL) — TEST-13 TC-009.
-- =====================================================================

-- =====================================================================
-- 1. EXTENSIONS  [platform section 1, verbatim]
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_bytes, digest
CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector: embeddings
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- trigram search (hybrid retrieval)
CREATE EXTENSION IF NOT EXISTS btree_gin;     -- composite GIN indexes

-- =====================================================================
-- 2. SCHEMAS
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS quality;     -- only the severity enum is used here (agent.finding.severity)
CREATE SCHEMA IF NOT EXISTS agent;
CREATE SCHEMA IF NOT EXISTS audit;

-- =====================================================================
-- 3. HELPER FUNCTIONS  [platform section 3, verbatim]
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
-- 4. ENUMERATED TYPES  [platform section 4 — the types the extracted sections use, verbatim lines]
-- =====================================================================

CREATE TYPE core.shift_code        AS ENUM ('A', 'B', 'C', 'OT');
CREATE TYPE core.language_code     AS ENUM ('th', 'ja', 'en');
CREATE TYPE quality.severity       AS ENUM ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL');
CREATE TYPE agent.run_outcome      AS ENUM ('ok', 'partial', 'refused', 'grounding_failed', 'error', 'budget_exceeded');
CREATE TYPE agent.finding_status   AS ENUM ('new', 'acknowledged', 'in_progress', 'resolved', 'expired', 'dismissed');
CREATE TYPE agent.message_role     AS ENUM ('user', 'assistant', 'system', 'tool');

COMMENT ON TYPE agent.run_outcome IS
  'grounding_failed = the post-check (ADR-013) found a number not present in tool results; the answer was withheld.';

-- =====================================================================
-- 5. CORE — master data and production facts  [platform section 5, verbatim]
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
-- 6. AGENT — tools, conversations, messages, runs, tool calls, findings, briefings, feedback  [platform section 10, verbatim]
-- KaizenSwarm OWNS agent.finding and agent.briefing (SAD-00 §13) and adds guard triggers on them in section 16.
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

CREATE TABLE agent.finding (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    agent_name         text        NOT NULL,
    domain             text        NOT NULL,
    scope_json         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    title              text        NOT NULL,
    summary            text,
    severity           quality.severity NOT NULL,
    confidence         numeric(4,3) CHECK (confidence >= 0 AND confidence <= 1),
    evidence_json      jsonb       NOT NULL DEFAULT '[]'::jsonb,
    recommended_action text,
    status             agent.finding_status NOT NULL DEFAULT 'new',
    owner_id           uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    first_seen         timestamptz NOT NULL DEFAULT now(),
    last_seen          timestamptz NOT NULL DEFAULT now(),
    occurrences        integer     NOT NULL DEFAULT 1,
    resolved_at        timestamptz,
    resolution         text,
    CONSTRAINT finding_has_evidence CHECK (jsonb_array_length(evidence_json) > 0)
);

COMMENT ON CONSTRAINT finding_has_evidence ON agent.finding IS
  'SRS-13 C-02: a finding without evidence is invalid and is rejected by the blackboard. Enforced in the database, not just in code.';

CREATE TABLE agent.briefing (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    generated_at timestamptz NOT NULL DEFAULT now(),
    scope_json   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    lang         core.language_code NOT NULL DEFAULT 'th',
    top_risks_json jsonb     NOT NULL DEFAULT '[]'::jsonb,
    text         text,
    partial      boolean     NOT NULL DEFAULT false,
    partial_reason text,
    delivered_at timestamptz
);

COMMENT ON COLUMN agent.briefing.partial IS
  'True when an agent failed or timed out. A partial picture must announce itself rather than look complete (SRS-13 FR-20).';

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
-- 7. AUDIT  [platform section 13, verbatim]
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
-- 8. PLATFORM INDEXES AND TRIGGERS  [verbatim]
-- =====================================================================

-- core
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
CREATE INDEX idx_finding_status     ON agent.finding (status, severity, last_seen DESC);
CREATE INDEX idx_finding_domain     ON agent.finding (domain, last_seen DESC);
CREATE INDEX idx_briefing_generated ON agent.briefing (generated_at DESC);

CREATE INDEX idx_audit_ts        ON audit.log (ts DESC);
CREATE INDEX idx_audit_entity    ON audit.log (entity, entity_id, ts DESC);
CREATE INDEX idx_audit_user      ON audit.log (user_id, ts DESC);
CREATE INDEX idx_audit_corr      ON audit.log (correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_auth_event_ts   ON audit.auth_event (ts DESC);

CREATE TRIGGER trg_plant_updated       BEFORE UPDATE ON core.plant
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_line_updated        BEFORE UPDATE ON core.line
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_sku_updated         BEFORE UPDATE ON core.sku
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_machine_updated     BEFORE UPDATE ON core.machine
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_user_updated        BEFORE UPDATE ON core.app_user
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_production_updated  BEFORE UPDATE ON core.production_fact
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =====================================================================
-- 9. PLATFORM VIEWS  [verbatim]
-- =====================================================================

-- Daily KPI rollup from production facts (ShiftBrief / dashboard)
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

-- OEE components (needs runtime/downtime and an ideal cycle time in sku.spec_json)
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

-- Agent grounding health (P-1 observability)
CREATE OR REPLACE VIEW agent.v_grounding_health AS
SELECT
    date_trunc('day', r.ts)                                             AS day,
    COUNT(*)                                                            AS runs,
    COUNT(*) FILTER (WHERE r.outcome = 'grounding_failed')              AS grounding_failed,
    COUNT(*) FILTER (WHERE r.outcome = 'refused')                       AS refused,
    COUNT(*) FILTER (WHERE r.outcome = 'partial')                       AS partial,
    ROUND(100.0 * COUNT(*) FILTER (WHERE r.outcome = 'grounding_failed')
          / NULLIF(COUNT(*), 0), 3)                                     AS grounding_failure_pct,
    ROUND(AVG(r.latency_ms))                                            AS avg_latency_ms
FROM agent.run r
GROUP BY 1;

COMMENT ON VIEW agent.v_grounding_health IS
  'Operational proof of P-1. A rising grounding_failure_pct means the model is drifting toward fabrication and must be investigated.';

-- =====================================================================
-- 10. SWARM — types  (extension of the platform's agent context; migration swarm_0001)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS swarm;

COMMENT ON SCHEMA swarm IS
  'KaizenSwarm extension (SRS-13). The findings blackboard and briefings stay in the platform schema agent (owned by this module); swarm holds the registry, runs, assessments, typed messages, leases, circuits, scores, compounds, claims, deliveries, metrics and the scenario suite.';

CREATE TYPE swarm.agent_kind         AS ENUM ('specialist', 'manager');
CREATE TYPE swarm.run_trigger        AS ENUM ('schedule', 'on_demand', 'question', 'scenario');
CREATE TYPE swarm.run_status         AS ENUM ('queued', 'running', 'completed', 'partial', 'failed', 'cancelled');
CREATE TYPE swarm.assessment_outcome AS ENUM ('findings', 'nothing_significant', 'timeout', 'budget_exceeded',
                                              'invalid_output', 'failed', 'circuit_open');
CREATE TYPE swarm.message_type       AS ENUM ('RequestAssessment', 'Finding', 'Clarification', 'Error', 'StatusUpdate');
CREATE TYPE swarm.likelihood_class   AS ENUM ('observed', 'trend', 'forecast', 'possible');
CREATE TYPE swarm.horizon            AS ENUM ('this_shift', 'today', 'within_3_days', 'this_week', 'later');
CREATE TYPE swarm.action_kind        AS ENUM ('acknowledge', 'assign', 'snooze', 'dismiss', 'start', 'resolve', 'reopen');
CREATE TYPE swarm.dismiss_reason     AS ENUM ('false_positive', 'duplicate', 'known', 'not_actionable', 'not_related');
CREATE TYPE swarm.circuit            AS ENUM ('closed', 'open', 'half_open');
CREATE TYPE swarm.delivery_kind      AS ENUM ('briefing', 'immediate');
CREATE TYPE swarm.delivery_status    AS ENUM ('pending', 'sent', 'failed', 'skipped');

COMMENT ON TYPE swarm.assessment_outcome IS
  'Every enabled specialist ends a run with exactly one assessment. nothing_significant is an explicit outcome (SRS-13 FR-13); timeout / budget_exceeded / invalid_output / failed / circuit_open make the briefing partial (C-04, C-06) and never abort the run.';

-- =====================================================================
-- 11. SWARM — settings, registry, weights, relation rules
-- =====================================================================

CREATE TABLE swarm.setting (
    key         text PRIMARY KEY,
    value_num   numeric,
    value_text  text,
    description text,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT setting_semaphore_one   CHECK (key <> 'semaphore_slots'      OR value_num = 1),
    CONSTRAINT setting_gate_top3       CHECK (key <> 'scenario_gate_top3'   OR value_num >= 0.80),
    CONSTRAINT setting_gate_fabricated CHECK (key <> 'scenario_gate_fabricated' OR value_num = 0),
    CONSTRAINT setting_temperature     CHECK (key <> 'llm_temperature'      OR value_num <= 0.3),
    CONSTRAINT setting_model_size      CHECK (key <> 'llm_max_params_b'     OR value_num <= 9),
    CONSTRAINT setting_attempts        CHECK (key <> 'max_attempts'         OR value_num = 2),
    CONSTRAINT setting_agent_timeout   CHECK (key <> 'agent_timeout_s'      OR value_num BETWEEN 1 AND 180),
    CONSTRAINT setting_run_wall        CHECK (key <> 'run_wall_s'           OR value_num BETWEEN 1 AND 180),
    CONSTRAINT setting_retention       CHECK (key <> 'retention_days'       OR value_num >= 365),
    CONSTRAINT setting_positive        CHECK (value_num IS NULL OR value_num >= 0)
);

COMMENT ON TABLE swarm.setting IS
  'Constants the SRS fixes (C-05 one inference at a time, AI-05 model <= 9 B, AI-06 gate >= 80 % and zero fabricated, NFR-01/02 wall clocks, NFR-05 retention) are CHECK constraints, not editable numbers.';

CREATE OR REPLACE FUNCTION swarm.setting_num(p_key text) RETURNS numeric
LANGUAGE sql STABLE AS $$ SELECT value_num FROM swarm.setting WHERE key = p_key $$;

CREATE TABLE swarm.agent_registry (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name           text        NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9_]{1,31}$'),
    kind           swarm.agent_kind NOT NULL DEFAULT 'specialist',
    display_name   text        NOT NULL,
    version        text        NOT NULL DEFAULT '1.0.0',
    description    text,
    module         text        NOT NULL,                         -- IF-68 tool module (e.g. kaizenswarm.agents.quality)
    output_schema  text        NOT NULL DEFAULT 'finding.v1',    -- message schema the agent's output is validated against
    budget_json    jsonb       NOT NULL,                          -- {tool_calls, tokens, wall_ms}
    schedule_cron  text,
    prompt_version text,
    enabled        boolean     NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agent_budget_shape CHECK (
        (budget_json ->> 'tool_calls')::int > 0 AND (budget_json ->> 'tokens')::int > 0 AND (budget_json ->> 'wall_ms')::int > 0),
    CONSTRAINT agent_manager_name CHECK ((kind = 'manager') = (name = 'manager'))
);

COMMENT ON TABLE swarm.agent_registry IS
  'SRS-13 FR-01: an agent is a row — name, domains (swarm.agent_domain), tools (swarm.agent_tool), output schema, budget, schedule, enabled. FR-06: adding an agent is a row plus a module implementing IF-68; the Manager iterates enabled specialists and names none.';

CREATE TABLE swarm.agent_domain (
    agent_id uuid NOT NULL REFERENCES swarm.agent_registry(id) ON DELETE CASCADE,
    domain   text NOT NULL CHECK (domain ~ '^[a-z][a-z0-9_]{1,63}$'),
    PRIMARY KEY (agent_id, domain)
);

CREATE TABLE swarm.agent_tool (
    agent_id uuid     NOT NULL REFERENCES swarm.agent_registry(id) ON DELETE CASCADE,
    tool_id  uuid     NOT NULL REFERENCES agent.tool(id) ON DELETE RESTRICT,
    ordinal  smallint NOT NULL,
    PRIMARY KEY (agent_id, tool_id),
    CONSTRAINT agent_tool_ordinal UNIQUE (agent_id, ordinal)
);

CREATE TABLE swarm.registry_change (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_id    uuid        NOT NULL,
    agent_name  text        NOT NULL,
    op          text        NOT NULL CHECK (op IN ('insert', 'update')),
    before_json jsonb,
    after_json  jsonb,
    changed_by  text        NOT NULL DEFAULT current_user,
    changed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE swarm.scoring_weights (
    version         text PRIMARY KEY CHECK (version ~ '^v[0-9]+$'),
    impact_json     jsonb NOT NULL,   -- {INFO, LOW, MEDIUM, HIGH, CRITICAL} in [0,1], monotone
    likelihood_json jsonb NOT NULL,   -- {observed, trend, forecast, possible}
    urgency_json    jsonb NOT NULL,   -- {this_shift, today, within_3_days, this_week, later}
    active          boolean NOT NULL DEFAULT false,
    published_at    timestamptz NOT NULL DEFAULT now(),
    published_by    uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    note            text,
    CONSTRAINT weights_impact_keys CHECK (impact_json ?& ARRAY['INFO','LOW','MEDIUM','HIGH','CRITICAL']),
    CONSTRAINT weights_likelihood_keys CHECK (likelihood_json ?& ARRAY['observed','trend','forecast','possible']),
    CONSTRAINT weights_urgency_keys CHECK (urgency_json ?& ARRAY['this_shift','today','within_3_days','this_week','later']),
    CONSTRAINT weights_impact_monotone CHECK (
        (impact_json ->> 'INFO')::numeric < (impact_json ->> 'LOW')::numeric AND
        (impact_json ->> 'LOW')::numeric < (impact_json ->> 'MEDIUM')::numeric AND
        (impact_json ->> 'MEDIUM')::numeric < (impact_json ->> 'HIGH')::numeric AND
        (impact_json ->> 'HIGH')::numeric <= (impact_json ->> 'CRITICAL')::numeric AND
        (impact_json ->> 'CRITICAL')::numeric <= 1 AND (impact_json ->> 'INFO')::numeric > 0),
    CONSTRAINT weights_likelihood_monotone CHECK (
        (likelihood_json ->> 'possible')::numeric < (likelihood_json ->> 'forecast')::numeric AND
        (likelihood_json ->> 'forecast')::numeric < (likelihood_json ->> 'trend')::numeric AND
        (likelihood_json ->> 'trend')::numeric <= (likelihood_json ->> 'observed')::numeric AND
        (likelihood_json ->> 'observed')::numeric <= 1),
    CONSTRAINT weights_urgency_monotone CHECK (
        (urgency_json ->> 'later')::numeric < (urgency_json ->> 'this_week')::numeric AND
        (urgency_json ->> 'this_week')::numeric < (urgency_json ->> 'within_3_days')::numeric AND
        (urgency_json ->> 'within_3_days')::numeric < (urgency_json ->> 'today')::numeric AND
        (urgency_json ->> 'today')::numeric <= (urgency_json ->> 'this_shift')::numeric AND
        (urgency_json ->> 'this_shift')::numeric <= 1)
);

CREATE UNIQUE INDEX idx_weights_active ON swarm.scoring_weights ((true)) WHERE active;

COMMENT ON TABLE swarm.scoring_weights IS
  'SRS-13 FR-18 / AI-03: the ranking is score = impact(severity) x likelihood(class) x urgency(horizon) x confidence with published, versioned tables. Exactly one version is active; swarm.trg_risk_score_computed recomputes every stored score from it.';

CREATE TABLE swarm.relation_rule (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code        text    NOT NULL UNIQUE CHECK (code ~ '^[a-z][a-z0-9_]{1,31}$'),
    match_keys  text[]  NOT NULL CHECK (array_length(match_keys, 1) >= 1),
    min_domains smallint NOT NULL DEFAULT 2 CHECK (min_domains >= 2),
    window_hours integer NOT NULL DEFAULT 24 CHECK (window_hours > 0),
    enabled     boolean NOT NULL DEFAULT true,
    description text,
    CONSTRAINT rule_keys_known CHECK (match_keys <@ ARRAY['plant','line','machine','sku','lot','shift'])
);

COMMENT ON TABLE swarm.relation_rule IS
  'SRS-13 FR-17 / AI-04: compound-risk detection is explicit — findings from >= min_domains different domains whose scope agrees on every match key within window_hours are related. Inspectable, testable, editable under the scenario gate (ADR-K10).';

-- =====================================================================
-- 12. SWARM — runs, assessments, attempts, messages, leases, circuits
-- =====================================================================

CREATE SEQUENCE swarm.run_no_seq;

CREATE TABLE swarm.run (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_no          bigint      NOT NULL UNIQUE DEFAULT nextval('swarm.run_no_seq'),
    trigger         swarm.run_trigger NOT NULL,
    scope_json      jsonb       NOT NULL DEFAULT '{}'::jsonb,   -- {plant, line?, shift?, date?}
    requested_by    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    weights_version text        NOT NULL REFERENCES swarm.scoring_weights(version),
    budget_json     jsonb       NOT NULL,                        -- snapshot of the per-agent budgets at run start {agent: {tool_calls,tokens,wall_ms}}
    agent_count     smallint    NOT NULL CHECK (agent_count >= 1),
    started_at      timestamptz NOT NULL DEFAULT now(),
    deadline_at     timestamptz NOT NULL,
    finished_at     timestamptz,
    status          swarm.run_status NOT NULL DEFAULT 'queued',
    partial_reason  text,
    tool_call_count integer     NOT NULL DEFAULT 0,
    token_count     integer     NOT NULL DEFAULT 0,
    wall_ms         integer,
    CONSTRAINT run_partial_reason CHECK ((status = 'partial') = (partial_reason IS NOT NULL)),
    CONSTRAINT run_finished CHECK (status IN ('queued', 'running') OR finished_at IS NOT NULL),
    CONSTRAINT run_deadline CHECK (deadline_at > started_at)
);

COMMENT ON COLUMN swarm.run.partial_reason IS
  'SRS-13 FR-20 / C-06: names every domain that failed, timed out, exceeded its budget or returned invalid output. A partial picture announces itself.';

CREATE TABLE swarm.assessment (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id          uuid        NOT NULL REFERENCES swarm.run(id) ON DELETE CASCADE,
    agent_id        uuid        NOT NULL REFERENCES swarm.agent_registry(id),
    agent_run_id    uuid        REFERENCES agent.run(id) ON DELETE SET NULL,   -- the specialist's LLM run (platform table)
    outcome         swarm.assessment_outcome NOT NULL,
    incomplete      boolean     NOT NULL DEFAULT false,
    finding_count   smallint    NOT NULL DEFAULT 0,
    confidence      numeric(4,3) CHECK (confidence BETWEEN 0 AND 1),
    freshness_min   numeric(8,1) CHECK (freshness_min >= 0),
    freshness_flag  boolean     NOT NULL DEFAULT false,
    tool_calls_used smallint    NOT NULL DEFAULT 0,
    tokens_used     integer     NOT NULL DEFAULT 0,
    wall_ms         integer     NOT NULL DEFAULT 0,
    attempt_count   smallint    NOT NULL DEFAULT 1,
    requested_at    timestamptz NOT NULL,
    responded_at    timestamptz,
    error           text,
    CONSTRAINT assessment_one_per_agent UNIQUE (run_id, agent_id),
    CONSTRAINT assessment_findings_count CHECK (
        (outcome = 'findings' AND finding_count > 0) OR
        (outcome = 'nothing_significant' AND finding_count = 0) OR
        outcome NOT IN ('findings', 'nothing_significant')),
    CONSTRAINT assessment_complete_ok CHECK (outcome NOT IN ('findings', 'nothing_significant') OR incomplete = false),
    CONSTRAINT assessment_budget_incomplete CHECK (outcome <> 'budget_exceeded' OR incomplete = true),
    CONSTRAINT assessment_failed_has_error CHECK (outcome IN ('findings', 'nothing_significant') OR error IS NOT NULL)
);

COMMENT ON TABLE swarm.assessment IS
  'One row per enabled specialist per run. The briefing''s partial flag is derived from these rows (swarm.trg_briefing_partial); an over-budget assessment cannot claim completeness (swarm.trg_assessment_budget).';

CREATE TABLE swarm.attempt (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    assessment_id uuid        NOT NULL REFERENCES swarm.assessment(id) ON DELETE CASCADE,
    attempt_no    smallint    NOT NULL CHECK (attempt_no >= 1),
    started_at    timestamptz NOT NULL,
    finished_at   timestamptz,
    outcome       text        NOT NULL CHECK (outcome IN ('ok', 'invalid_output', 'transport_error', 'timeout', 'nothing_significant')),
    backoff_ms    integer     NOT NULL DEFAULT 0 CHECK (backoff_ms >= 0),
    error         text,
    CONSTRAINT attempt_unique UNIQUE (assessment_id, attempt_no)
);

CREATE TABLE swarm.message (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id         uuid        NOT NULL REFERENCES swarm.run(id) ON DELETE CASCADE,
    seq            integer     NOT NULL,
    from_agent     text        NOT NULL,
    to_agent       text        NOT NULL,
    type           swarm.message_type NOT NULL,
    subject        text        NOT NULL,                       -- IF-17 subject, e.g. agent.finding.quality
    payload_json   jsonb       NOT NULL,
    correlation_id text        NOT NULL,
    ts             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT message_seq_unique UNIQUE (run_id, seq)
);

COMMENT ON TABLE swarm.message IS
  'SRS-13 C-01 / FR-02 / FR-07: every message that crossed the bus, typed and schema-checked (swarm.message_shape_ok), immutable. With agent.run and agent.tool_call it reconstructs a run (AC-09, swarm.run_trace).';

CREATE TABLE swarm.llm_lease (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id       uuid        NOT NULL REFERENCES swarm.run(id) ON DELETE CASCADE,
    agent_id     uuid        NOT NULL REFERENCES swarm.agent_registry(id),
    agent_run_id uuid        REFERENCES agent.run(id) ON DELETE SET NULL,
    model        text        NOT NULL,
    acquired_at  timestamptz NOT NULL,
    released_at  timestamptz,
    tokens_in    integer,
    tokens_out   integer,
    CONSTRAINT lease_order CHECK (released_at IS NULL OR released_at > acquired_at)
);

COMMENT ON TABLE swarm.llm_lease IS
  'SRS-13 C-05 / FR-04: the GPU semaphore, mirrored in the database. swarm.trg_llm_lease_exclusive refuses a lease that overlaps another one (semaphore_slots = 1 by CHECK).';

CREATE TABLE swarm.circuit_state (
    agent_id             uuid PRIMARY KEY REFERENCES swarm.agent_registry(id) ON DELETE CASCADE,
    state                swarm.circuit NOT NULL DEFAULT 'closed',
    consecutive_failures smallint NOT NULL DEFAULT 0 CHECK (consecutive_failures >= 0),
    opened_at            timestamptz,
    last_outcome         text,
    last_change_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT circuit_open_has_time CHECK (state <> 'open' OR opened_at IS NOT NULL)
);

CREATE TABLE swarm.circuit_event (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_id   uuid        NOT NULL REFERENCES swarm.agent_registry(id) ON DELETE CASCADE,
    run_id     uuid        REFERENCES swarm.run(id) ON DELETE SET NULL,
    from_state swarm.circuit NOT NULL,
    to_state   swarm.circuit NOT NULL,
    reason     text,
    ts         timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 13. SWARM — blackboard extension, scores, compounds, briefings, deliveries
-- =====================================================================

CREATE TABLE swarm.finding_ext (
    finding_id       uuid PRIMARY KEY REFERENCES agent.finding(id) ON DELETE CASCADE,
    agent_id         uuid        NOT NULL REFERENCES swarm.agent_registry(id),
    issue_code       text        NOT NULL CHECK (issue_code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    issue_key        text        NOT NULL,
    likelihood_class swarm.likelihood_class NOT NULL,
    horizon          swarm.horizon NOT NULL,
    freshness_min    numeric(8,1) CHECK (freshness_min >= 0),
    impact_json      jsonb,
    owner_suggestion text,
    scope_plant      text,
    scope_line       text,
    scope_machine    text,
    scope_sku        text,
    scope_lot        text,
    scope_shift      text,
    active           boolean     NOT NULL DEFAULT true,
    first_run_id     uuid        NOT NULL REFERENCES swarm.run(id),
    last_run_id      uuid        NOT NULL REFERENCES swarm.run(id),
    snoozed_until    timestamptz
);

CREATE UNIQUE INDEX idx_finding_ext_issue_active ON swarm.finding_ext (issue_key) WHERE active;

COMMENT ON COLUMN swarm.finding_ext.issue_key IS
  'SRS-13 FR-16 / FR-24: swarm.issue_key(issue_code, scope) — the same underlying issue, from any agent, in any run, maps to one active finding (occurrences, first/last seen); a duplicate is unrepresentable while the finding is active.';

CREATE TABLE swarm.finding_occurrence (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    finding_id    uuid        NOT NULL REFERENCES agent.finding(id) ON DELETE CASCADE,
    run_id        uuid        NOT NULL REFERENCES swarm.run(id) ON DELETE CASCADE,
    agent_id      uuid        NOT NULL REFERENCES swarm.agent_registry(id),
    assessment_id uuid        REFERENCES swarm.assessment(id) ON DELETE SET NULL,
    message_id    uuid        REFERENCES swarm.message(id) ON DELETE SET NULL,
    evidence_json jsonb       NOT NULL,
    confidence    numeric(4,3) CHECK (confidence BETWEEN 0 AND 1),
    freshness_min numeric(8,1),
    summary       text,
    ts            timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT occurrence_unique UNIQUE (finding_id, run_id, agent_id),
    CONSTRAINT occurrence_has_evidence CHECK (jsonb_typeof(evidence_json) = 'array' AND jsonb_array_length(evidence_json) > 0)
);

COMMENT ON TABLE swarm.finding_occurrence IS
  'Each detection of an issue by an agent in a run keeps its own evidence set (AC-03: one finding, both evidence sets; AC-08: five runs, one finding, five occurrences).';

CREATE TABLE swarm.finding_action (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    finding_id     uuid        NOT NULL REFERENCES agent.finding(id) ON DELETE CASCADE,
    kind           swarm.action_kind NOT NULL,
    actor_id       uuid        NOT NULL REFERENCES core.app_user(id),
    reason         text,
    dismiss_reason swarm.dismiss_reason,
    assignee_id    uuid        REFERENCES core.app_user(id),
    snooze_until   timestamptz,
    from_status    agent.finding_status NOT NULL,
    to_status      agent.finding_status NOT NULL,
    ts             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT action_dismiss_reason CHECK (kind <> 'dismiss' OR (dismiss_reason IS NOT NULL AND reason IS NOT NULL)),
    CONSTRAINT action_snooze_until   CHECK (kind <> 'snooze'  OR snooze_until IS NOT NULL),
    CONSTRAINT action_assignee       CHECK (kind <> 'assign'  OR assignee_id IS NOT NULL),
    CONSTRAINT action_resolve_reason CHECK (kind <> 'resolve' OR reason IS NOT NULL)
);

COMMENT ON TABLE swarm.finding_action IS
  'SRS-13 FR-25 / FR-26: acknowledge, assign, snooze, dismiss (with a reason code) — the only way a status changes by a person (swarm.trg_finding_lifecycle requires the action context). Dismissals feed swarm.agent_precision().';

CREATE TABLE swarm.risk_score (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id          uuid        NOT NULL REFERENCES swarm.run(id) ON DELETE CASCADE,
    finding_id      uuid        NOT NULL REFERENCES agent.finding(id) ON DELETE CASCADE,
    weights_version text        NOT NULL REFERENCES swarm.scoring_weights(version),
    impact          numeric(4,3),
    likelihood      numeric(4,3),
    urgency         numeric(4,3),
    confidence      numeric(4,3),
    score           numeric(6,4),
    rank            smallint,
    absorbed_by     uuid,                                       -- compound that lists this finding as a component
    CONSTRAINT risk_score_unique UNIQUE (run_id, finding_id)
);

COMMENT ON TABLE swarm.risk_score IS
  'The four factors and the product, per finding per run. swarm.trg_risk_score_computed fills them from swarm.score_finding() and refuses a supplied score that differs (SRS-13 FR-18, AI-03).';

CREATE TABLE swarm.compound_risk (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id             uuid        NOT NULL REFERENCES swarm.run(id) ON DELETE CASCADE,
    rule_id            uuid        NOT NULL REFERENCES swarm.relation_rule(id),
    finding_ids        uuid[]      NOT NULL,
    shared_key_json    jsonb       NOT NULL,
    rationale          text        NOT NULL,
    components_json    jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- [{finding_id, domain, score}]
    score              numeric(6,4) NOT NULL,
    rank               smallint,
    title              text        NOT NULL,
    recommended_action text,
    owner_suggestion   text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT compound_two_components CHECK (array_length(finding_ids, 1) >= 2)
);

COMMENT ON TABLE swarm.compound_risk IS
  'SRS-13 FR-17 / AI-04 / AC-04: >= 2 findings of the same run from >= 2 domains agreeing on the rule''s match keys; score = swarm.compound_score(component scores) (noisy-OR), which is >= every component by construction. swarm.trg_compound_components checks all of it.';

CREATE TABLE swarm.briefing_run (
    briefing_id        uuid PRIMARY KEY REFERENCES agent.briefing(id) ON DELETE CASCADE,
    run_id             uuid        NOT NULL REFERENCES swarm.run(id) ON DELETE CASCADE,
    top_n              smallint    NOT NULL CHECK (top_n >= 1),
    rank_json          jsonb       NOT NULL,      -- ordered [{rank, kind: finding|compound, id, score}]
    claims_json        jsonb,                     -- numeric tokens found in text
    claim_check_json   jsonb,                     -- {checked, matched, unmatched: []}
    phrasing_attempts  smallint    NOT NULL DEFAULT 1 CHECK (phrasing_attempts BETWEEN 0 AND 2),
    template_fallback  boolean     NOT NULL DEFAULT false,
    model              text,
    tokens_in          integer,
    tokens_out         integer,
    CONSTRAINT briefing_lang_per_run UNIQUE (run_id, briefing_id)
);

COMMENT ON TABLE swarm.briefing_run IS
  'Links a platform agent.briefing row to its run and stores the claim check. swarm.trg_briefing_grounded refuses a briefing whose text carries a number absent from the findings it cites (SRS-13 FR-22, AC-07); swarm.trg_briefing_partial refuses a partial flag that disagrees with the assessments (FR-20, AC-02).';

CREATE TABLE swarm.delivery (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind         swarm.delivery_kind NOT NULL,
    briefing_id  uuid        REFERENCES agent.briefing(id) ON DELETE CASCADE,
    finding_id   uuid        REFERENCES agent.finding(id) ON DELETE CASCADE,
    channel      text        NOT NULL CHECK (channel IN ('discord', 'webhook', 'email', 'dashboard')),
    status       swarm.delivery_status NOT NULL DEFAULT 'pending',
    scheduled_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz,
    message_ref  text,
    error        text,
    CONSTRAINT delivery_target CHECK (
        (kind = 'briefing'  AND briefing_id IS NOT NULL AND finding_id IS NULL) OR
        (kind = 'immediate' AND finding_id  IS NOT NULL AND briefing_id IS NULL))
);

CREATE TABLE swarm.question (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id      uuid        REFERENCES swarm.run(id) ON DELETE SET NULL,
    asked_by    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    question    text        NOT NULL,
    lang        core.language_code NOT NULL DEFAULT 'en',
    scope_json  jsonb       NOT NULL DEFAULT '{}'::jsonb,
    answer_json jsonb,
    answer_text text,
    asked_at    timestamptz NOT NULL DEFAULT now(),
    answered_at timestamptz
);

CREATE TABLE swarm.agent_metric (
    agent_id        uuid    NOT NULL REFERENCES swarm.agent_registry(id) ON DELETE CASCADE,
    metric_date     date    NOT NULL,
    runs            integer NOT NULL DEFAULT 0,
    failures        integer NOT NULL DEFAULT 0,
    timeouts        integer NOT NULL DEFAULT 0,
    budget_exceeded integer NOT NULL DEFAULT 0,
    findings        integer NOT NULL DEFAULT 0,
    dismissed       integer NOT NULL DEFAULT 0,
    false_positives integer NOT NULL DEFAULT 0,
    avg_latency_ms  integer,
    tokens          bigint  NOT NULL DEFAULT 0,
    tool_calls      integer NOT NULL DEFAULT 0,
    PRIMARY KEY (agent_id, metric_date)
);

-- =====================================================================
-- 14. SWARM — scenario suite, exports, migration
-- =====================================================================

CREATE TABLE swarm.scenario (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code             text  NOT NULL UNIQUE CHECK (code ~ '^SC-[0-9]{2}$'),
    title            text  NOT NULL,
    plant_state_json jsonb NOT NULL,
    findings_json    jsonb NOT NULL,
    expected_top_json jsonb NOT NULL,
    notes            text,
    CONSTRAINT scenario_findings_two CHECK (jsonb_typeof(findings_json) = 'array' AND jsonb_array_length(findings_json) >= 2),
    CONSTRAINT scenario_expected_one CHECK (jsonb_typeof(expected_top_json) = 'array' AND jsonb_array_length(expected_top_json) BETWEEN 1 AND 3)
);

COMMENT ON TABLE swarm.scenario IS
  'SRS-13 AI-06 / AC-01: a synthetic plant state as a set of specialist findings plus the expected top risks. swarm.run_scenario() runs the deterministic half (dedupe, compounds, scoring, ranking) in SQL; the LLM half runs in CI (TEST-13 TC-070).';

CREATE TABLE swarm.suite_run (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    weights_version text        NOT NULL REFERENCES swarm.scoring_weights(version),
    mode            text        NOT NULL CHECK (mode IN ('deterministic', 'full')),
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,
    scenarios       integer     NOT NULL DEFAULT 0,
    matches         integer     NOT NULL DEFAULT 0,
    match_rate      numeric(5,4),
    fabricated      integer     NOT NULL DEFAULT 0,
    passed          boolean,
    note            text
);

CREATE TABLE swarm.scenario_result (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    suite_run_id      uuid    NOT NULL REFERENCES swarm.suite_run(id) ON DELETE CASCADE,
    scenario_id       uuid    NOT NULL REFERENCES swarm.scenario(id) ON DELETE CASCADE,
    computed_top_json jsonb   NOT NULL,
    ranking_json      jsonb   NOT NULL,
    top3_match        boolean NOT NULL,
    fabricated_count  integer NOT NULL DEFAULT 0,
    tokens            integer,
    evaluated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT scenario_result_unique UNIQUE (suite_run_id, scenario_id)
);

CREATE TABLE swarm.export (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind         text        NOT NULL CHECK (kind IN ('run', 'findings', 'briefing', 'audit')),
    run_id       uuid        REFERENCES swarm.run(id) ON DELETE SET NULL,
    requested_by uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    from_ts      timestamptz,
    to_ts        timestamptz,
    row_count    integer     NOT NULL DEFAULT 0,
    sha256       text        NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    uri          text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE swarm.migration (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    description text
);

-- =====================================================================
-- 15. SWARM — functions (twins of the deterministic logic; TEST-13 TC-005 re-derives them in Python)
-- =====================================================================

CREATE OR REPLACE FUNCTION swarm.active_weights() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT version FROM swarm.scoring_weights WHERE active $$;

-- FR-18 / AI-03: the four factors and their product, from a published weights version.
CREATE OR REPLACE FUNCTION swarm.score_factors(p_severity quality.severity, p_lc swarm.likelihood_class,
                                               p_h swarm.horizon, p_conf numeric, p_version text)
RETURNS TABLE (impact numeric, likelihood numeric, urgency numeric, confidence numeric, score numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    w swarm.scoring_weights%ROWTYPE;
BEGIN
    SELECT * INTO w FROM swarm.scoring_weights sw WHERE sw.version = p_version;
    IF NOT FOUND THEN RAISE EXCEPTION 'WEIGHTS_UNKNOWN: %', p_version; END IF;
    IF p_conf IS NULL OR p_conf < 0 OR p_conf > 1 THEN RAISE EXCEPTION 'CONFIDENCE_RANGE: %', p_conf; END IF;
    impact     := (w.impact_json     ->> p_severity::text)::numeric;
    likelihood := (w.likelihood_json ->> p_lc::text)::numeric;
    urgency    := (w.urgency_json    ->> p_h::text)::numeric;
    confidence := round(p_conf, 3);
    score      := round(impact * likelihood * urgency * confidence, 4);
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION swarm.score_finding(p_severity quality.severity, p_lc swarm.likelihood_class,
                                               p_h swarm.horizon, p_conf numeric, p_version text)
RETURNS numeric
LANGUAGE sql STABLE AS $$ SELECT score FROM swarm.score_factors($1, $2, $3, $4, $5) $$;

-- FR-17 / AC-04: noisy-OR — 1 - prod(1 - s_i); always >= max(s_i).
CREATE OR REPLACE FUNCTION swarm.compound_score(p_scores numeric[]) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    acc numeric := 1;
    s   numeric;
BEGIN
    IF p_scores IS NULL OR array_length(p_scores, 1) < 2 THEN RAISE EXCEPTION 'COMPOUND_NEEDS_TWO'; END IF;
    FOREACH s IN ARRAY p_scores LOOP
        IF s < 0 OR s > 1 THEN RAISE EXCEPTION 'SCORE_RANGE: %', s; END IF;
        acc := acc * (1 - s);
    END LOOP;
    RETURN round(1 - acc, 4);
END;
$$;

-- FR-16 / FR-24: the dedupe key — issue code plus the scope entities that identify its family (IF-69 §3):
--   machine.*  → plant, machine     lot.* → plant, lot     sku.* / material.* → plant, sku     everything else → plant, line
-- Shift, dates and windows never enter the key: the same issue seen in another shift is the same issue.
CREATE OR REPLACE FUNCTION swarm.issue_key(p_issue_code text, p_scope jsonb) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    WITH fam AS (
        SELECT CASE split_part(p_issue_code, '.', 1)
                   WHEN 'machine'  THEN ARRAY['plant', 'machine']
                   WHEN 'lot'      THEN ARRAY['plant', 'lot']
                   WHEN 'sku'      THEN ARRAY['plant', 'sku']
                   WHEN 'material' THEN ARRAY['plant', 'sku']
                   ELSE ARRAY['plant', 'line'] END AS keys)
    SELECT p_issue_code || '|' || COALESCE((
        SELECT string_agg(x.k || '=' || x.v, ',' ORDER BY x.k)
        FROM (SELECT key AS k, value #>> '{}' AS v
              FROM jsonb_each(p_scope), fam
              WHERE key = ANY (fam.keys) AND jsonb_typeof(value) <> 'null') x), '')
$$;

-- AI-04: the relation key of a scope for a rule; NULL when any match key is absent.
CREATE OR REPLACE FUNCTION swarm.scope_key(p_scope jsonb, p_keys text[]) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    k     text;
    parts text[] := '{}';
BEGIN
    FOREACH k IN ARRAY p_keys LOOP
        IF p_scope ? k AND jsonb_typeof(p_scope -> k) <> 'null' THEN
            parts := parts || (k || '=' || (p_scope ->> k));
        ELSE
            RETURN NULL;
        END IF;
    END LOOP;
    RETURN array_to_string(parts, ',');
END;
$$;

CREATE OR REPLACE FUNCTION swarm.scope_label(p_key text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT string_agg(
        CASE split_part(kv, '=', 1)
            WHEN 'line'    THEN 'Line '    || split_part(kv, '=', 2)
            WHEN 'machine' THEN 'Machine ' || split_part(kv, '=', 2)
            WHEN 'sku'     THEN 'SKU '     || split_part(kv, '=', 2)
            WHEN 'lot'     THEN 'Lot '     || split_part(kv, '=', 2)
            WHEN 'plant'   THEN 'Plant '   || split_part(kv, '=', 2)
            WHEN 'shift'   THEN 'Shift '   || split_part(kv, '=', 2)
            ELSE kv END, ' / ' ORDER BY ord)
    FROM unnest(string_to_array(p_key, ',')) WITH ORDINALITY AS t(kv, ord)
$$;

-- C-02: every evidence item names its kind and a reference.
CREATE OR REPLACE FUNCTION swarm.evidence_ok(p_evidence jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    e jsonb;
BEGIN
    IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'array' THEN RETURN 'evidence must be an array'; END IF;
    IF jsonb_array_length(p_evidence) = 0 THEN RETURN 'evidence is empty'; END IF;
    FOR e IN SELECT * FROM jsonb_array_elements(p_evidence) LOOP
        IF jsonb_typeof(e) <> 'object' THEN RETURN 'evidence item is not an object'; END IF;
        IF NOT (e ? 'kind') OR (e ->> 'kind') NOT IN ('metric', 'alert', 'signal', 'case', 'oee', 'downtime', 'stock', 'po', 'lot', 'schedule', 'pm', 'health') THEN
            RETURN 'evidence kind unknown: ' || COALESCE(e ->> 'kind', '(none)');
        END IF;
        IF NOT (e ? 'ref') OR length(COALESCE(e ->> 'ref', '')) < 3 THEN RETURN 'evidence ref missing'; END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

-- FR-02 / C-01: shape of each typed message. NULL = well-formed; otherwise the first defect.
CREATE OR REPLACE FUNCTION swarm.message_shape_ok(p_type swarm.message_type, p_payload jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    err text;
BEGIN
    IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN RETURN 'payload must be an object'; END IF;
    CASE p_type
        WHEN 'RequestAssessment' THEN
            IF NOT (p_payload ?& ARRAY['run_no', 'agent', 'scope', 'deadline_at', 'budget']) THEN RETURN 'RequestAssessment needs run_no, agent, scope, deadline_at, budget'; END IF;
            IF jsonb_typeof(p_payload -> 'scope') <> 'object' THEN RETURN 'scope must be an object'; END IF;
            IF NOT ((p_payload -> 'budget') ?& ARRAY['tool_calls', 'tokens', 'wall_ms']) THEN RETURN 'budget needs tool_calls, tokens, wall_ms'; END IF;
        WHEN 'Finding' THEN
            IF NOT (p_payload ?& ARRAY['agent', 'domain', 'scope', 'title', 'severity', 'confidence', 'evidence',
                                        'recommended_action', 'issue_code', 'likelihood_class', 'horizon', 'freshness_min']) THEN
                RETURN 'Finding needs agent, domain, scope, title, severity, confidence, evidence, recommended_action, issue_code, likelihood_class, horizon, freshness_min';
            END IF;
            IF (p_payload ->> 'severity') NOT IN ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL') THEN RETURN 'severity outside the enum'; END IF;
            IF (p_payload ->> 'confidence')::numeric < 0 OR (p_payload ->> 'confidence')::numeric > 1 THEN RETURN 'confidence outside [0,1]'; END IF;
            IF (p_payload ->> 'likelihood_class') NOT IN ('observed', 'trend', 'forecast', 'possible') THEN RETURN 'likelihood_class unknown'; END IF;
            IF (p_payload ->> 'horizon') NOT IN ('this_shift', 'today', 'within_3_days', 'this_week', 'later') THEN RETURN 'horizon unknown'; END IF;
            IF (p_payload ->> 'freshness_min')::numeric < 0 THEN RETURN 'freshness_min negative'; END IF;
            err := swarm.evidence_ok(p_payload -> 'evidence');
            IF err IS NOT NULL THEN RETURN err; END IF;
        WHEN 'Clarification' THEN
            IF NOT (p_payload ?& ARRAY['kind', 'detail']) THEN RETURN 'Clarification needs kind, detail'; END IF;
            IF (p_payload ->> 'kind') NOT IN ('budget_stop', 'scope', 'deadline') THEN RETURN 'Clarification kind unknown'; END IF;
        WHEN 'Error' THEN
            IF NOT (p_payload ?& ARRAY['code', 'detail', 'attempt']) THEN RETURN 'Error needs code, detail, attempt'; END IF;
            IF (p_payload ->> 'code') NOT IN ('invalid_output', 'transport_error', 'timeout', 'tool_error', 'internal') THEN RETURN 'Error code unknown'; END IF;
        WHEN 'StatusUpdate' THEN
            IF NOT (p_payload ? 'status') THEN RETURN 'StatusUpdate needs status'; END IF;
            IF (p_payload ->> 'status') NOT IN ('started', 'tools_done', 'phrasing', 'done', 'nothing_significant') THEN RETURN 'status unknown'; END IF;
            IF (p_payload ->> 'status') IN ('done', 'nothing_significant') AND NOT ((p_payload -> 'usage') ?& ARRAY['tool_calls', 'tokens', 'wall_ms']) THEN
                RETURN 'done/nothing_significant needs usage{tool_calls,tokens,wall_ms}';
            END IF;
            IF (p_payload ->> 'status') = 'nothing_significant' AND NOT (p_payload ? 'checked') THEN RETURN 'nothing_significant must list what was checked'; END IF;
    END CASE;
    RETURN NULL;
END;
$$;

-- C-04 / AI-08: the first budget violation, or NULL.
CREATE OR REPLACE FUNCTION swarm.budget_check(p_usage jsonb, p_budget jsonb) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT (SELECT k || ' ' || (p_usage ->> k) || ' > ' || (p_budget ->> k)
            FROM unnest(ARRAY['tool_calls', 'tokens', 'wall_ms']) AS k
            WHERE (p_usage ->> k)::numeric > (p_budget ->> k)::numeric
            ORDER BY array_position(ARRAY['tool_calls', 'tokens', 'wall_ms'], k)
            LIMIT 1)
$$;

-- FR-05: exponential backoff, capped.
CREATE OR REPLACE FUNCTION swarm.backoff_ms(p_attempt integer) RETURNS integer
LANGUAGE sql STABLE AS $$
    SELECT LEAST(swarm.setting_num('backoff_base_ms') * power(2, GREATEST(p_attempt, 1) - 1),
                 swarm.setting_num('backoff_cap_ms'))::integer
$$;

-- FR-05: circuit breaker transition. p_ok NULL = a tick with no attempt (cool-down check).
CREATE OR REPLACE FUNCTION swarm.circuit_next_state(p_state swarm.circuit, p_ok boolean, p_failures integer,
                                                    p_opened_at timestamptz, p_now timestamptz)
RETURNS TABLE (state swarm.circuit, failures integer, opened_at timestamptz)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    threshold integer  := swarm.setting_num('circuit_threshold')::integer;
    cooldown  interval := make_interval(mins => swarm.setting_num('circuit_cooldown_min')::integer);
BEGIN
    IF p_state = 'closed' THEN
        IF p_ok IS NULL OR p_ok THEN RETURN QUERY SELECT 'closed'::swarm.circuit, CASE WHEN p_ok THEN 0 ELSE p_failures END, NULL::timestamptz;
        ELSIF p_failures + 1 >= threshold THEN RETURN QUERY SELECT 'open'::swarm.circuit, p_failures + 1, p_now;
        ELSE RETURN QUERY SELECT 'closed'::swarm.circuit, p_failures + 1, NULL::timestamptz;
        END IF;
    ELSIF p_state = 'open' THEN
        IF p_now >= p_opened_at + cooldown THEN RETURN QUERY SELECT 'half_open'::swarm.circuit, p_failures, p_opened_at;
        ELSE RETURN QUERY SELECT 'open'::swarm.circuit, p_failures, p_opened_at;
        END IF;
    ELSE -- half_open: one probe decides
        IF p_ok IS NULL THEN RETURN QUERY SELECT 'half_open'::swarm.circuit, p_failures, p_opened_at;
        ELSIF p_ok THEN RETURN QUERY SELECT 'closed'::swarm.circuit, 0, NULL::timestamptz;
        ELSE RETURN QUERY SELECT 'open'::swarm.circuit, p_failures + 1, p_now;
        END IF;
    END IF;
END;
$$;

-- AI-07: data older than the threshold is flagged in the briefing.
CREATE OR REPLACE FUNCTION swarm.freshness_flag(p_min numeric) RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT COALESCE(p_min > swarm.setting_num('freshness_threshold_min'), false) $$;

CREATE OR REPLACE FUNCTION swarm.freshness_label(p_min numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_min IS NULL THEN 'unknown'
                WHEN p_min < 60 THEN round(p_min)::text || ' min'
                ELSE round(p_min / 60)::text || ' h' END
$$;

CREATE OR REPLACE FUNCTION swarm.wall_label(p_ms integer) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_ms IS NULL THEN 'n/a'
                WHEN p_ms >= 60000 THEN (p_ms / 60000)::text || ' min ' || ((p_ms % 60000) / 1000)::text || ' s'
                ELSE (p_ms / 1000)::text || ' s' END
$$;

-- AC-07: numeric tokens of a text (thousands separators removed, lower case).
CREATE OR REPLACE FUNCTION swarm.num_tokens(p_text text) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT replace(m[1], ',', '')), '{}')
    FROM regexp_matches(lower(COALESCE(p_text, '')), '(\d+(?:[.,]\d+)*)', 'g') AS m
$$;

-- AC-07: everything a briefing may quote — the cited findings, the run's own metadata, its compounds and scores.
CREATE OR REPLACE FUNCTION swarm.claim_corpus(p_run_id uuid, p_finding_ids uuid[]) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    r      swarm.run%ROWTYPE;
    corpus text := '';
    i      integer;
BEGIN
    SELECT * INTO r FROM swarm.run WHERE id = p_run_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'RUN_UNKNOWN'; END IF;
    corpus := format('Run %s · %s · %s agents · %s tool calls · %s · %s',
                     r.run_no, swarm.wall_label(r.wall_ms), r.agent_count, r.tool_call_count,
                     to_char(r.started_at AT TIME ZONE 'Asia/Bangkok', 'YYYY-MM-DD HH24:MI'), r.scope_json::text);
    SELECT corpus || ' ' || COALESCE(string_agg(
               concat_ws(' ', f.title, f.summary, f.recommended_action, f.evidence_json::text, f.scope_json::text,
                         fe.impact_json::text, fe.issue_key, fe.owner_suggestion,
                         to_char(rs.score, 'FM0.00'), to_char(rs.score, 'FM0.0000'),
                         swarm.freshness_label(fe.freshness_min)), ' '), '')
      INTO corpus
      FROM agent.finding f
      JOIN swarm.finding_ext fe ON fe.finding_id = f.id
      LEFT JOIN swarm.risk_score rs ON rs.finding_id = f.id AND rs.run_id = p_run_id
     WHERE f.id = ANY (p_finding_ids);
    SELECT corpus || ' ' || COALESCE(string_agg(
               concat_ws(' ', c.title, c.rationale, c.recommended_action, c.owner_suggestion, c.shared_key_json::text,
                         c.components_json::text, to_char(c.score, 'FM0.00'), to_char(c.score, 'FM0.0000')), ' '), '')
      INTO corpus
      FROM swarm.compound_risk c WHERE c.run_id = p_run_id;
    SELECT corpus || ' ' || COALESCE(string_agg(
               concat_ws(' ', a.name, s.outcome::text, swarm.freshness_label(s.freshness_min), s.tool_calls_used::text,
                         s.tokens_used::text, swarm.wall_label(s.wall_ms), s.error), ' '), '')
      INTO corpus
      FROM swarm.assessment s JOIN swarm.agent_registry a ON a.id = s.agent_id WHERE s.run_id = p_run_id;
    FOR i IN 1 .. GREATEST(swarm.setting_num('top_n')::integer, 1) LOOP
        corpus := corpus || ' ' || i::text;
    END LOOP;
    RETURN corpus;
END;
$$;

CREATE OR REPLACE FUNCTION swarm.claim_check(p_text text, p_run_id uuid, p_finding_ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    txt    text[] := swarm.num_tokens(p_text);
    corp   text[] := swarm.num_tokens(swarm.claim_corpus(p_run_id, p_finding_ids));
    unmatched text[];
BEGIN
    SELECT COALESCE(array_agg(t ORDER BY t), '{}') INTO unmatched
      FROM unnest(txt) AS t WHERE NOT (t = ANY (corp));
    RETURN jsonb_build_object('checked', COALESCE(array_length(txt, 1), 0),
                              'matched', COALESCE(array_length(txt, 1), 0) - COALESCE(array_length(unmatched, 1), 0),
                              'unmatched', to_jsonb(unmatched));
END;
$$;

COMMENT ON FUNCTION swarm.claim_check(text, uuid, uuid[]) IS
  'SRS-13 FR-22 / AC-07: every number in a briefing text must occur in the findings it cites or in the run''s own metadata. The Manager may phrase; it may not add.';

-- The blackboard writer (FR-16, FR-24, C-02, FR-14, FR-22): validates a Finding payload, dedupes by issue key, records the occurrence.
CREATE OR REPLACE FUNCTION swarm.upsert_finding(p_run_id uuid, p_agent_name text, p_payload jsonb,
                                                p_message_id uuid DEFAULT NULL, p_assessment_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    a     swarm.agent_registry%ROWTYPE;
    r     swarm.run%ROWTYPE;
    err   text;
    key   text;
    fid   uuid;
    ev    jsonb;
BEGIN
    err := swarm.message_shape_ok('Finding', p_payload);
    IF err IS NOT NULL THEN RAISE EXCEPTION 'FINDING_SHAPE: %', err; END IF;
    SELECT * INTO a FROM swarm.agent_registry WHERE name = p_agent_name;
    IF NOT FOUND OR a.kind <> 'specialist' OR NOT a.enabled THEN RAISE EXCEPTION 'FINDING_AUTHOR: % is not an enabled specialist', p_agent_name; END IF;
    IF (p_payload ->> 'agent') <> p_agent_name THEN RAISE EXCEPTION 'FINDING_AUTHOR: payload agent % <> %', p_payload ->> 'agent', p_agent_name; END IF;
    SELECT * INTO r FROM swarm.run WHERE id = p_run_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'RUN_UNKNOWN'; END IF;
    key := swarm.issue_key(p_payload ->> 'issue_code', p_payload -> 'scope');
    SELECT finding_id INTO fid FROM swarm.finding_ext WHERE issue_key = key AND active;
    IF FOUND THEN
        SELECT COALESCE(jsonb_agg(e ORDER BY e::text), '[]'::jsonb) INTO ev
          FROM (SELECT DISTINCT e FROM (SELECT jsonb_array_elements(f.evidence_json) AS e FROM agent.finding f WHERE f.id = fid
                                        UNION ALL SELECT jsonb_array_elements(p_payload -> 'evidence')) u) d;
        UPDATE agent.finding
           SET occurrences        = occurrences + 1,
               last_seen          = r.started_at,
               evidence_json      = ev,
               severity           = GREATEST(severity, (p_payload ->> 'severity')::quality.severity),
               confidence         = (p_payload ->> 'confidence')::numeric,
               summary            = COALESCE(p_payload ->> 'summary', summary),
               recommended_action = COALESCE(p_payload ->> 'recommended_action', recommended_action)
         WHERE id = fid;
        UPDATE swarm.finding_ext
           SET last_run_id      = p_run_id,
               freshness_min    = (p_payload ->> 'freshness_min')::numeric,
               likelihood_class = (p_payload ->> 'likelihood_class')::swarm.likelihood_class,
               horizon          = (p_payload ->> 'horizon')::swarm.horizon,
               impact_json      = COALESCE(p_payload -> 'impact_estimate', impact_json),
               owner_suggestion = COALESCE(p_payload ->> 'owner_suggestion', owner_suggestion)
         WHERE finding_id = fid;
    ELSE
        INSERT INTO agent.finding (agent_name, domain, scope_json, title, summary, severity, confidence, evidence_json,
                                   recommended_action, first_seen, last_seen, occurrences)
        VALUES (p_agent_name, p_payload ->> 'domain', p_payload -> 'scope', p_payload ->> 'title', p_payload ->> 'summary',
                (p_payload ->> 'severity')::quality.severity, (p_payload ->> 'confidence')::numeric, p_payload -> 'evidence',
                p_payload ->> 'recommended_action', r.started_at, r.started_at, 1)
        RETURNING id INTO fid;
        INSERT INTO swarm.finding_ext (finding_id, agent_id, issue_code, issue_key, likelihood_class, horizon, freshness_min,
                                       impact_json, owner_suggestion, scope_plant, scope_line, scope_machine, scope_sku, scope_lot,
                                       scope_shift, first_run_id, last_run_id)
        VALUES (fid, a.id, p_payload ->> 'issue_code', key, (p_payload ->> 'likelihood_class')::swarm.likelihood_class,
                (p_payload ->> 'horizon')::swarm.horizon, (p_payload ->> 'freshness_min')::numeric,
                p_payload -> 'impact_estimate', p_payload ->> 'owner_suggestion',
                p_payload #>> '{scope,plant}', p_payload #>> '{scope,line}', p_payload #>> '{scope,machine}',
                p_payload #>> '{scope,sku}', p_payload #>> '{scope,lot}', p_payload #>> '{scope,shift}', p_run_id, p_run_id);
    END IF;
    INSERT INTO swarm.finding_occurrence (finding_id, run_id, agent_id, assessment_id, message_id, evidence_json, confidence,
                                          freshness_min, summary, ts)
    VALUES (fid, p_run_id, a.id, p_assessment_id, p_message_id, p_payload -> 'evidence', (p_payload ->> 'confidence')::numeric,
            (p_payload ->> 'freshness_min')::numeric, p_payload ->> 'summary', COALESCE(r.finished_at, r.started_at));
    RETURN fid;
END;
$$;

-- Scores every finding that occurred in the run (the trigger fills the factors).
CREATE OR REPLACE FUNCTION swarm.score_run(p_run_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO swarm.risk_score (run_id, finding_id, weights_version)
    SELECT DISTINCT o.run_id, o.finding_id, r.weights_version
      FROM swarm.finding_occurrence o JOIN swarm.run r ON r.id = o.run_id
     WHERE o.run_id = p_run_id
    ON CONFLICT (run_id, finding_id) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- FR-17 / AI-04: compounds from the enabled relation rules over the run's scored findings.
CREATE OR REPLACE FUNCTION swarm.detect_compounds(p_run_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    rule   swarm.relation_rule%ROWTYPE;
    g      record;
    scores numeric[];
    comps  jsonb;
    cid    uuid;
    n      integer := 0;
    agents text;
    actions text;
    owners text;
BEGIN
    FOR rule IN SELECT * FROM swarm.relation_rule WHERE enabled ORDER BY code LOOP
        FOR g IN
            WITH s AS (
                SELECT rs.finding_id, rs.score, f.title, f.domain, f.last_seen, swarm.scope_key(f.scope_json, rule.match_keys) AS k
                  FROM swarm.risk_score rs JOIN agent.finding f ON f.id = rs.finding_id
                 WHERE rs.run_id = p_run_id AND rs.absorbed_by IS NULL),
            dom AS (
                -- a finding's domain is its first reporter's domain; a merged finding is one domain (IF-69 §3)
                SELECT s.k, count(DISTINCT s.domain) AS nd FROM s WHERE s.k IS NOT NULL GROUP BY s.k)
            SELECT s.k, array_agg(s.finding_id ORDER BY s.score DESC, s.title) AS ids, dom.nd
              FROM s JOIN dom ON dom.k = s.k
             WHERE dom.nd >= rule.min_domains
             GROUP BY s.k, dom.nd
            HAVING count(*) >= 2 AND max(s.last_seen) - min(s.last_seen) <= make_interval(hours => rule.window_hours)
             ORDER BY s.k
        LOOP
            SELECT array_agg(rs.score ORDER BY rs.score DESC),
                   jsonb_agg(jsonb_build_object('finding_id', rs.finding_id, 'agent', f.agent_name, 'domain', f.domain,
                                                'title', f.title, 'score', rs.score) ORDER BY rs.score DESC, f.title),
                   (SELECT string_agg(z.agent_name, ' + ' ORDER BY z.best DESC, z.agent_name)
                      FROM (SELECT f2.agent_name, max(rs2.score) AS best
                              FROM swarm.risk_score rs2 JOIN agent.finding f2 ON f2.id = rs2.finding_id
                             WHERE rs2.run_id = p_run_id AND rs2.finding_id = ANY (g.ids)
                             GROUP BY f2.agent_name) z),
                   string_agg(f.recommended_action, '; ' ORDER BY rs.score DESC, f.title),
                   string_agg(DISTINCT fe.owner_suggestion, ' + ')
              INTO scores, comps, agents, actions, owners
              FROM swarm.risk_score rs
              JOIN agent.finding f ON f.id = rs.finding_id
              JOIN swarm.finding_ext fe ON fe.finding_id = f.id
             WHERE rs.run_id = p_run_id AND rs.finding_id = ANY (g.ids);
            INSERT INTO swarm.compound_risk (run_id, rule_id, finding_ids, shared_key_json, rationale, components_json, score,
                                             title, recommended_action, owner_suggestion)
            VALUES (p_run_id, rule.id, g.ids,
                    jsonb_build_object('rule', rule.code, 'key', g.k),
                    format('Rule %s: %s findings from %s domains (%s) share %s within %s h; score = noisy-OR of %s',
                           rule.code, array_length(g.ids, 1), g.nd, agents, g.k, rule.window_hours, array_to_string(scores, ', ')),
                    comps, swarm.compound_score(scores),
                    format('%s — compound risk: %s', swarm.scope_label(g.k), agents), actions, owners)
            RETURNING id INTO cid;
            UPDATE swarm.risk_score SET absorbed_by = cid WHERE run_id = p_run_id AND finding_id = ANY (g.ids);
            n := n + 1;
        END LOOP;
    END LOOP;
    RETURN n;
END;
$$;

-- FR-18 / FR-19: the ordered list — compounds plus unabsorbed findings; writes the rank columns; returns rank_json.
CREATE OR REPLACE FUNCTION swarm.rank_run(p_run_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_out jsonb;
BEGIN
    WITH items AS (
        SELECT 'compound' AS kind, c.id, c.score, c.title, c.finding_ids
          FROM swarm.compound_risk c WHERE c.run_id = p_run_id
        UNION ALL
        SELECT 'finding', rs.finding_id, rs.score, f.title, ARRAY[rs.finding_id]
          FROM swarm.risk_score rs JOIN agent.finding f ON f.id = rs.finding_id
         WHERE rs.run_id = p_run_id AND rs.absorbed_by IS NULL),
    ranked AS (
        SELECT row_number() OVER (ORDER BY score DESC, title) AS rank, * FROM items)
    SELECT jsonb_agg(jsonb_build_object('rank', rank, 'kind', kind, 'id', id, 'score', score, 'title', title,
                                        'finding_ids', to_jsonb(finding_ids)) ORDER BY rank)
      INTO v_out FROM ranked;
    UPDATE swarm.compound_risk c SET rank = x.rank
      FROM (SELECT (e.value ->> 'id')::uuid AS id, (e.value ->> 'rank')::smallint AS rank FROM jsonb_array_elements(v_out) e WHERE e.value ->> 'kind' = 'compound') x
     WHERE c.id = x.id AND c.run_id = p_run_id;
    UPDATE swarm.risk_score rs SET rank = x.rank
      FROM (SELECT (e.value ->> 'id')::uuid AS id, (e.value ->> 'rank')::smallint AS rank FROM jsonb_array_elements(v_out) e WHERE e.value ->> 'kind' = 'finding') x
     WHERE rs.finding_id = x.id AND rs.run_id = p_run_id;
    RETURN COALESCE(v_out, '[]'::jsonb);
END;
$$;

-- AI-06: the same pipeline over a synthetic set of findings, without touching the blackboard (used by the scenario suite).
CREATE OR REPLACE FUNCTION swarm.rank_findings(p_findings jsonb, p_version text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    rule   swarm.relation_rule%ROWTYPE;
    g      record;
    cid    text;
    scores numeric[];
    v_out  jsonb;
BEGIN
    DROP TABLE IF EXISTS pg_temp._sf;
    DROP TABLE IF EXISTS pg_temp._sc;
    CREATE TEMP TABLE _sf (
        id text, ids text[], agents text[], domains text[], scope jsonb, title text, severity quality.severity,
        lc swarm.likelihood_class, horizon swarm.horizon, conf numeric, score numeric, absorbed_by text);
    CREATE TEMP TABLE _sc (id text, ids text[], score numeric, title text, rule text, key text);
    -- 1. dedupe by issue key (merge: highest severity, strongest likelihood, nearest horizon, highest confidence)
    INSERT INTO _sf (id, ids, agents, domains, scope, title, severity, lc, horizon, conf)
    SELECT (array_agg(x.id ORDER BY x.ord))[1],
           array_agg(x.id ORDER BY x.ord),
           array_agg(x.agent ORDER BY x.ord),
           ARRAY[(array_agg(x.domain ORDER BY x.ord))[1]],
           (array_agg(x.scope ORDER BY x.ord))[1],
           (array_agg(x.title ORDER BY x.ord))[1],
           (array_agg(x.severity ORDER BY x.severity DESC))[1],
           (array_agg(x.lc ORDER BY x.lc ASC))[1],
           (array_agg(x.horizon ORDER BY x.horizon ASC))[1],
           max(x.conf)
      FROM (SELECT e ->> 'id' AS id, e ->> 'agent' AS agent, e ->> 'domain' AS domain, e -> 'scope' AS scope,
                   e ->> 'title' AS title, (e ->> 'severity')::quality.severity AS severity,
                   (e ->> 'likelihood_class')::swarm.likelihood_class AS lc, (e ->> 'horizon')::swarm.horizon AS horizon,
                   (e ->> 'confidence')::numeric AS conf, swarm.issue_key(e ->> 'issue_code', e -> 'scope') AS key, ord
              FROM jsonb_array_elements(p_findings) WITH ORDINALITY AS t(e, ord)) x
     GROUP BY x.key;
    -- 2. score
    UPDATE _sf SET score = swarm.score_finding(severity, lc, horizon, conf, p_version);
    -- 3. compounds
    FOR rule IN SELECT * FROM swarm.relation_rule WHERE enabled ORDER BY code LOOP
        FOR g IN
            WITH s AS (
                SELECT id, score, agents, domains, swarm.scope_key(scope, rule.match_keys) AS k
                  FROM _sf WHERE absorbed_by IS NULL),
            dom AS (
                SELECT s.k, count(DISTINCT d) AS nd FROM s, unnest(s.domains) AS d WHERE s.k IS NOT NULL GROUP BY s.k)
            SELECT s.k, array_agg(s.id ORDER BY s.score DESC, s.id) AS ids,
                   array_agg(s.score ORDER BY s.score DESC, s.id) AS scores,
                   (SELECT string_agg(z.agent, ' + ' ORDER BY z.best DESC, z.agent)
                      FROM (SELECT s2.agents[1] AS agent, max(s2.score) AS best FROM s s2 WHERE s2.k = s.k GROUP BY s2.agents[1]) z) AS agents
              FROM s JOIN dom ON dom.k = s.k
             WHERE dom.nd >= rule.min_domains
             GROUP BY s.k
            HAVING count(*) >= 2
             ORDER BY s.k
        LOOP
            cid := 'C:' || array_to_string(g.ids, '+');
            INSERT INTO _sc VALUES (cid, g.ids, swarm.compound_score(g.scores),
                                    format('%s — compound risk: %s', swarm.scope_label(g.k), g.agents), rule.code, g.k);
            UPDATE _sf SET absorbed_by = cid WHERE id = ANY (g.ids);
        END LOOP;
    END LOOP;
    -- 4. rank
    WITH items AS (
        SELECT 'compound' AS kind, id, score, title, ids FROM _sc
        UNION ALL
        SELECT 'finding', id, score, title, ids FROM _sf WHERE absorbed_by IS NULL),
    ranked AS (SELECT row_number() OVER (ORDER BY score DESC, title, id) AS rank, * FROM items)
    SELECT jsonb_agg(jsonb_build_object('rank', rank, 'kind', kind, 'id', id, 'score', score, 'title', title,
                                        'finding_ids', to_jsonb(ids)) ORDER BY rank)
      INTO v_out FROM ranked;
    RETURN COALESCE(v_out, '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION swarm.run_scenario(p_scenario_id uuid, p_suite_run_id uuid) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    sc       swarm.scenario%ROWTYPE;
    sr       swarm.suite_run%ROWTYPE;
    ranking  jsonb;
    top_n    integer := swarm.setting_num('top_n')::integer;
    computed text[];
    expected text[];
    matched  boolean;
BEGIN
    SELECT * INTO sc FROM swarm.scenario WHERE id = p_scenario_id;
    SELECT * INTO sr FROM swarm.suite_run WHERE id = p_suite_run_id;
    ranking := swarm.rank_findings(sc.findings_json, sr.weights_version);
    SELECT COALESCE(array_agg(e.value ->> 'id' ORDER BY (e.value ->> 'rank')::int), '{}') INTO computed
      FROM jsonb_array_elements(ranking) e WHERE (e.value ->> 'rank')::int <= top_n;
    SELECT COALESCE(array_agg(e.value #>> '{}'), '{}') INTO expected FROM jsonb_array_elements(sc.expected_top_json) e;
    matched := (SELECT COALESCE(array_agg(x ORDER BY x), '{}') FROM unnest(computed) x)
             = (SELECT COALESCE(array_agg(x ORDER BY x), '{}') FROM unnest(expected) x);
    INSERT INTO swarm.scenario_result (suite_run_id, scenario_id, computed_top_json, ranking_json, top3_match, fabricated_count)
    VALUES (p_suite_run_id, p_scenario_id, to_jsonb(computed), ranking, matched, 0);
    RETURN matched;
END;
$$;

CREATE OR REPLACE FUNCTION swarm.run_suite(p_version text, p_mode text DEFAULT 'deterministic') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    sid uuid;
    s   record;
    n   integer := 0;
    m   integer := 0;
BEGIN
    INSERT INTO swarm.suite_run (weights_version, mode) VALUES (p_version, p_mode) RETURNING id INTO sid;
    FOR s IN SELECT id FROM swarm.scenario ORDER BY code LOOP
        n := n + 1;
        IF swarm.run_scenario(s.id, sid) THEN m := m + 1; END IF;
    END LOOP;
    UPDATE swarm.suite_run
       SET finished_at = now(), scenarios = n, matches = m,
           match_rate = CASE WHEN n > 0 THEN round(m::numeric / n, 4) END,
           fabricated = (SELECT COALESCE(sum(fabricated_count), 0) FROM swarm.scenario_result WHERE suite_run_id = sid),
           passed = (n >= 15 AND round(m::numeric / n, 4) >= swarm.setting_num('scenario_gate_top3')
                     AND (SELECT COALESCE(sum(fabricated_count), 0) FROM swarm.scenario_result WHERE suite_run_id = sid) = 0)
     WHERE id = sid;
    RETURN sid;
END;
$$;

-- FR-27: an active issue expires when EVERY agent that ever reported it has since reported (findings or nothing_significant)
-- in expire_after_runs runs without it. A timeout, budget stop or invalid output is not a report and never clears an issue.
CREATE OR REPLACE FUNCTION swarm.expire_findings(p_run_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    f       record;
    rep     record;
    runs    bigint[];
    need    integer := swarm.setting_num('expire_after_runs')::integer;
    cur     swarm.run%ROWTYPE;
    n       integer := 0;
    ok      boolean;
    detail  text;
BEGIN
    SELECT * INTO cur FROM swarm.run WHERE id = p_run_id;
    IF cur.trigger <> 'schedule' THEN RETURN 0; END IF;   -- only scheduled plant-wide runs can clear an issue; a question run has a narrower scope
    FOR f IN
        SELECT af.id, lr.run_no AS last_no
          FROM agent.finding af
          JOIN swarm.finding_ext fe ON fe.finding_id = af.id
          JOIN swarm.run lr ON lr.id = fe.last_run_id
         WHERE af.status IN ('new', 'acknowledged', 'in_progress') AND fe.active AND fe.last_run_id <> p_run_id
    LOOP
        ok := true; detail := '';
        FOR rep IN SELECT DISTINCT o.agent_id, a.name FROM swarm.finding_occurrence o JOIN swarm.agent_registry a ON a.id = o.agent_id
                    WHERE o.finding_id = f.id ORDER BY a.name LOOP
            SELECT array_agg(r.run_no ORDER BY r.run_no) INTO runs
              FROM swarm.assessment s JOIN swarm.run r ON r.id = s.run_id
             WHERE s.agent_id = rep.agent_id AND s.outcome IN ('findings', 'nothing_significant')
               AND r.run_no > f.last_no AND r.run_no <= cur.run_no AND r.status IN ('completed', 'partial') AND r.trigger = 'schedule';
            IF COALESCE(array_length(runs, 1), 0) < need THEN ok := false; EXIT; END IF;
            detail := detail || CASE WHEN detail = '' THEN '' ELSE '; ' END || rep.name || ' in runs ' || array_to_string(runs, ', ');
        END LOOP;
        IF ok THEN
            UPDATE agent.finding
               SET status = 'expired', resolved_at = cur.started_at,
                   resolution = 'condition cleared: not reported by ' || detail
             WHERE id = f.id;
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END;
$$;

-- FR-26: precision per agent from dismissals.
CREATE OR REPLACE FUNCTION swarm.agent_precision(p_agent_id uuid, p_from date, p_to date)
RETURNS TABLE (findings integer, dismissed integer, false_positives integer, precision_rate numeric)
LANGUAGE sql STABLE AS $$
    WITH fs AS (
        SELECT DISTINCT o.finding_id
          FROM swarm.finding_occurrence o JOIN agent.finding f ON f.id = o.finding_id
         WHERE o.agent_id = p_agent_id AND f.first_seen::date BETWEEN p_from AND p_to),
    d AS (
        SELECT fs.finding_id,
               (SELECT dismiss_reason FROM swarm.finding_action fa WHERE fa.finding_id = fs.finding_id AND fa.kind = 'dismiss'
                 ORDER BY fa.ts DESC LIMIT 1) AS reason
          FROM fs JOIN agent.finding f ON f.id = fs.finding_id WHERE f.status = 'dismissed')
    SELECT (SELECT count(*) FROM fs)::integer,
           (SELECT count(*) FROM d)::integer,
           (SELECT count(*) FROM d WHERE reason = 'false_positive')::integer,
           CASE WHEN (SELECT count(*) FROM fs) > 0
                THEN round(1 - (SELECT count(*) FROM d WHERE reason = 'false_positive')::numeric / (SELECT count(*) FROM fs), 4) END
$$;

-- NFR-07: daily rollup per agent.
CREATE OR REPLACE FUNCTION swarm.rollup_agent_metrics(p_date date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO swarm.agent_metric (agent_id, metric_date, runs, failures, timeouts, budget_exceeded, findings, dismissed,
                                    false_positives, avg_latency_ms, tokens, tool_calls)
    SELECT s.agent_id, p_date,
           count(*),
           count(*) FILTER (WHERE s.outcome IN ('failed', 'invalid_output', 'circuit_open')),
           count(*) FILTER (WHERE s.outcome = 'timeout'),
           count(*) FILTER (WHERE s.outcome = 'budget_exceeded'),
           COALESCE(sum(s.finding_count), 0),
           (SELECT count(DISTINCT fa.finding_id) FROM swarm.finding_action fa JOIN swarm.finding_occurrence o ON o.finding_id = fa.finding_id
             WHERE o.agent_id = s.agent_id AND fa.kind = 'dismiss' AND fa.ts::date = p_date),
           (SELECT count(DISTINCT fa.finding_id) FROM swarm.finding_action fa JOIN swarm.finding_occurrence o ON o.finding_id = fa.finding_id
             WHERE o.agent_id = s.agent_id AND fa.kind = 'dismiss' AND fa.dismiss_reason = 'false_positive' AND fa.ts::date = p_date),
           round(avg(s.wall_ms))::integer,
           COALESCE(sum(s.tokens_used), 0),
           COALESCE(sum(s.tool_calls_used), 0)
      FROM swarm.assessment s JOIN swarm.run r ON r.id = s.run_id
     WHERE (r.started_at AT TIME ZONE 'Asia/Bangkok')::date = p_date
     GROUP BY s.agent_id
    ON CONFLICT (agent_id, metric_date) DO UPDATE
       SET runs = EXCLUDED.runs, failures = EXCLUDED.failures, timeouts = EXCLUDED.timeouts,
           budget_exceeded = EXCLUDED.budget_exceeded, findings = EXCLUDED.findings, dismissed = EXCLUDED.dismissed,
           false_positives = EXCLUDED.false_positives, avg_latency_ms = EXCLUDED.avg_latency_ms,
           tokens = EXCLUDED.tokens, tool_calls = EXCLUDED.tool_calls;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- FR-07 / AC-09: the run, replayed — messages, LLM runs, tool calls, leases and attempts in time order.
CREATE OR REPLACE FUNCTION swarm.run_trace(p_run_id uuid)
RETURNS TABLE (seq integer, ts timestamptz, kind text, agent text, detail jsonb)
LANGUAGE sql STABLE AS $$
    WITH ev AS (
        SELECT m.ts, 'message' AS kind, m.from_agent AS agent, 0 AS ord,
               jsonb_build_object('seq', m.seq, 'type', m.type, 'to', m.to_agent, 'subject', m.subject, 'payload', m.payload_json) AS detail
          FROM swarm.message m WHERE m.run_id = p_run_id
        UNION ALL
        SELECT ar.ts, 'llm_run', a.name, 0,
               jsonb_build_object('agent_run_id', ar.id, 'model', ar.model, 'prompt_version', ar.prompt_version,
                                  'tokens_in', ar.tokens_in, 'tokens_out', ar.tokens_out, 'latency_ms', ar.latency_ms,
                                  'tool_call_count', ar.tool_call_count, 'outcome', ar.outcome)
          FROM swarm.assessment s JOIN agent.run ar ON ar.id = s.agent_run_id JOIN swarm.agent_registry a ON a.id = s.agent_id
         WHERE s.run_id = p_run_id
        UNION ALL
        SELECT ar.ts, 'tool_call', a.name, tc.ordinal,
               jsonb_build_object('ordinal', tc.ordinal, 'tool', tc.tool_name, 'args', tc.args_json, 'digest', tc.result_digest,
                                  'rows', tc.row_count, 'duration_ms', tc.duration_ms, 'ok', tc.ok, 'error', tc.error)
          FROM swarm.assessment s JOIN agent.run ar ON ar.id = s.agent_run_id JOIN agent.tool_call tc ON tc.run_id = ar.id
          JOIN swarm.agent_registry a ON a.id = s.agent_id
         WHERE s.run_id = p_run_id
        UNION ALL
        SELECT l.acquired_at, 'lease', a.name, 0,
               jsonb_build_object('model', l.model, 'released_at', l.released_at, 'tokens_in', l.tokens_in, 'tokens_out', l.tokens_out)
          FROM swarm.llm_lease l JOIN swarm.agent_registry a ON a.id = l.agent_id WHERE l.run_id = p_run_id
        UNION ALL
        SELECT att.started_at, 'attempt', a.name, att.attempt_no,
               jsonb_build_object('attempt_no', att.attempt_no, 'outcome', att.outcome, 'backoff_ms', att.backoff_ms, 'error', att.error)
          FROM swarm.attempt att JOIN swarm.assessment s ON s.id = att.assessment_id JOIN swarm.agent_registry a ON a.id = s.agent_id
         WHERE s.run_id = p_run_id)
    SELECT row_number() OVER (ORDER BY ts, kind, ord)::integer, ts, kind, agent, detail FROM ev
$$;

-- Ranking to briefing items (the deterministic template the Manager phrases from; also the fallback text).
CREATE OR REPLACE FUNCTION swarm.briefing_items(p_run_id uuid, p_top_n integer) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH items AS (
        SELECT c.rank, c.score, 'compound' AS kind, c.id, c.title, c.recommended_action, c.owner_suggestion,
               c.finding_ids, (SELECT f.severity FROM agent.finding f WHERE f.id = ANY (c.finding_ids) ORDER BY f.severity DESC LIMIT 1) AS severity,
               (SELECT string_agg(e.value ->> 'ref', ' · ' ORDER BY e.value ->> 'ref') FROM agent.finding f, jsonb_array_elements(f.evidence_json) e
                 WHERE f.id = ANY (c.finding_ids)) AS evidence
          FROM swarm.compound_risk c WHERE c.run_id = p_run_id
        UNION ALL
        SELECT rs.rank, rs.score, 'finding', f.id, f.title, f.recommended_action, fe.owner_suggestion, ARRAY[f.id], f.severity,
               (SELECT string_agg(e.value ->> 'ref', ' · ' ORDER BY e.value ->> 'ref') FROM jsonb_array_elements(f.evidence_json) e)
          FROM swarm.risk_score rs JOIN agent.finding f ON f.id = rs.finding_id JOIN swarm.finding_ext fe ON fe.finding_id = f.id
         WHERE rs.run_id = p_run_id AND rs.absorbed_by IS NULL)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'rank', rank, 'score', round(score, 2), 'severity', severity, 'kind', kind, 'title', title,
               'finding_ids', to_jsonb(finding_ids), 'recommended_action', recommended_action, 'owner', owner_suggestion,
               'evidence', evidence) ORDER BY rank), '[]'::jsonb)
      FROM items WHERE rank <= p_top_n
$$;

-- =====================================================================
-- 16. SWARM — guard triggers (DDS-13 DD-K01…K09)
-- =====================================================================

-- FR-01 / FR-06: registry edits are audited; the manager cannot be disabled; kind is immutable.
CREATE OR REPLACE FUNCTION swarm.trg_registry_change_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.kind <> OLD.kind THEN RAISE EXCEPTION 'REGISTRY_KIND_IMMUTABLE'; END IF;
        IF NEW.name = 'manager' AND NOT NEW.enabled THEN RAISE EXCEPTION 'MANAGER_REQUIRED: the manager cannot be disabled'; END IF;
        NEW.updated_at := now();
        INSERT INTO swarm.registry_change (agent_id, agent_name, op, before_json, after_json)
        VALUES (NEW.id, NEW.name, 'update', to_jsonb(OLD) - 'updated_at', to_jsonb(NEW) - 'updated_at');
    ELSE
        INSERT INTO swarm.registry_change (agent_id, agent_name, op, before_json, after_json)
        VALUES (NEW.id, NEW.name, 'insert', NULL, to_jsonb(NEW) - 'updated_at');
        INSERT INTO swarm.circuit_state (agent_id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_registry_change BEFORE INSERT OR UPDATE ON swarm.agent_registry
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_registry_change_fn();

-- C-03 / NFR-06: an agent may be bound only to read tools.
CREATE OR REPLACE FUNCTION swarm.trg_tool_read_only_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    k text;
BEGIN
    SELECT kind INTO k FROM agent.tool WHERE id = NEW.tool_id;
    IF k IS DISTINCT FROM 'read' THEN RAISE EXCEPTION 'TOOL_NOT_READ_ONLY: agents are read-only towards production systems (C-03)'; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tool_read_only BEFORE INSERT OR UPDATE ON swarm.agent_tool
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_tool_read_only_fn();

-- Run status: partial needs a reason; completed needs every enabled specialist assessed and none failed.
CREATE OR REPLACE FUNCTION swarm.trg_run_status_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    n_assessed integer;
    n_failed   integer;
    failed_names text;
BEGIN
    IF NEW.status IN ('completed', 'partial', 'failed', 'cancelled') THEN
        NEW.finished_at := COALESCE(NEW.finished_at, now());
        NEW.wall_ms     := COALESCE(NEW.wall_ms, (EXTRACT(EPOCH FROM (NEW.finished_at - NEW.started_at)) * 1000)::integer);
        SELECT count(*) FILTER (WHERE s.outcome IN ('findings', 'nothing_significant')),
               count(*) FILTER (WHERE s.outcome NOT IN ('findings', 'nothing_significant')),
               string_agg(a.name, ', ' ORDER BY a.name) FILTER (WHERE s.outcome NOT IN ('findings', 'nothing_significant'))
          INTO n_assessed, n_failed, failed_names
          FROM swarm.assessment s JOIN swarm.agent_registry a ON a.id = s.agent_id
         WHERE s.run_id = NEW.id;
        IF NEW.status = 'completed' THEN
            IF n_failed > 0 THEN RAISE EXCEPTION 'RUN_NOT_COMPLETE: % failed (%); status must be partial', n_failed, failed_names; END IF;
            IF n_assessed < NEW.agent_count THEN RAISE EXCEPTION 'RUN_NOT_COMPLETE: % of % agents assessed', n_assessed, NEW.agent_count; END IF;
        ELSIF NEW.status = 'partial' THEN
            IF n_failed = 0 AND n_assessed >= NEW.agent_count THEN RAISE EXCEPTION 'RUN_NOT_PARTIAL: every agent reported'; END IF;
            IF failed_names IS NOT NULL AND position(split_part(failed_names, ',', 1) IN NEW.partial_reason) = 0 THEN
                RAISE EXCEPTION 'PARTIAL_REASON: must name the failed domain(s): %', failed_names;
            END IF;
        END IF;
        SELECT COALESCE(sum(s.tool_calls_used), 0), COALESCE(sum(s.tokens_used), 0)
          INTO NEW.tool_call_count, NEW.token_count
          FROM swarm.assessment s WHERE s.run_id = NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_run_status BEFORE UPDATE ON swarm.run
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_run_status_fn();

-- C-04 / AI-08 / AC-05: an assessment over budget cannot claim completeness; freshness flag computed; agent must be an enabled specialist.
CREATE OR REPLACE FUNCTION swarm.trg_assessment_budget_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    a    swarm.agent_registry%ROWTYPE;
    r    swarm.run%ROWTYPE;
    viol text;
    usage jsonb;
BEGIN
    SELECT * INTO a FROM swarm.agent_registry WHERE id = NEW.agent_id;
    IF a.kind <> 'specialist' THEN RAISE EXCEPTION 'ASSESSMENT_AUTHOR: only specialists assess'; END IF;
    SELECT * INTO r FROM swarm.run WHERE id = NEW.run_id;
    IF NEW.outcome = 'circuit_open' THEN
        NEW.incomplete := true;
    ELSE
        IF NOT a.enabled AND TG_OP = 'INSERT' THEN RAISE EXCEPTION 'ASSESSMENT_AUTHOR: % is disabled', a.name; END IF;
    END IF;
    usage := jsonb_build_object('tool_calls', NEW.tool_calls_used, 'tokens', NEW.tokens_used, 'wall_ms', NEW.wall_ms);
    viol  := swarm.budget_check(usage, COALESCE(r.budget_json -> a.name, a.budget_json));
    IF viol IS NOT NULL AND NEW.outcome IN ('findings', 'nothing_significant') THEN
        RAISE EXCEPTION 'BUDGET_SILENT_TRUNCATION: % but outcome %', viol, NEW.outcome;
    END IF;
    IF NEW.outcome = 'budget_exceeded' AND viol IS NULL THEN
        RAISE EXCEPTION 'BUDGET_NOT_EXCEEDED: outcome budget_exceeded without a violation';
    END IF;
    IF NEW.outcome = 'budget_exceeded' THEN NEW.error := COALESCE(NEW.error, 'budget: ' || viol); END IF;
    NEW.freshness_flag := swarm.freshness_flag(NEW.freshness_min);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_assessment_budget BEFORE INSERT OR UPDATE ON swarm.assessment
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_assessment_budget_fn();

-- FR-05 / AI-02 / AC-06: at most max_attempts; a retry only after invalid output or a transport error, with backoff.
CREATE OR REPLACE FUNCTION swarm.trg_attempt_policy_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    prev swarm.attempt%ROWTYPE;
BEGIN
    IF NEW.attempt_no > swarm.setting_num('max_attempts') THEN
        RAISE EXCEPTION 'MAX_ATTEMPTS: attempt % exceeds %', NEW.attempt_no, swarm.setting_num('max_attempts');
    END IF;
    IF NEW.attempt_no > 1 THEN
        SELECT * INTO prev FROM swarm.attempt WHERE assessment_id = NEW.assessment_id AND attempt_no = NEW.attempt_no - 1;
        IF NOT FOUND THEN RAISE EXCEPTION 'ATTEMPT_SEQUENCE: attempt % without attempt %', NEW.attempt_no, NEW.attempt_no - 1; END IF;
        IF prev.outcome NOT IN ('invalid_output', 'transport_error') THEN
            RAISE EXCEPTION 'RETRY_NOT_ALLOWED: previous attempt outcome %', prev.outcome;
        END IF;
        IF prev.outcome = 'transport_error' AND NEW.backoff_ms < swarm.backoff_ms(NEW.attempt_no - 1) THEN
            RAISE EXCEPTION 'BACKOFF_TOO_SHORT: % < %', NEW.backoff_ms, swarm.backoff_ms(NEW.attempt_no - 1);
        END IF;
        IF NEW.started_at < prev.finished_at + make_interval(secs => NEW.backoff_ms / 1000.0) THEN
            RAISE EXCEPTION 'BACKOFF_NOT_WAITED';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_attempt_policy BEFORE INSERT ON swarm.attempt
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_attempt_policy_fn();

-- FR-02 / C-01: typed, well-formed, addressed to registered parties, immutable.
CREATE OR REPLACE FUNCTION swarm.trg_message_typed_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    err text;
BEGIN
    IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'MESSAGE_IMMUTABLE'; END IF;
    err := swarm.message_shape_ok(NEW.type, NEW.payload_json);
    IF err IS NOT NULL THEN RAISE EXCEPTION 'MESSAGE_SHAPE: %', err; END IF;
    IF NEW.from_agent <> 'orchestrator' AND NOT EXISTS (SELECT 1 FROM swarm.agent_registry WHERE name = NEW.from_agent) THEN
        RAISE EXCEPTION 'MESSAGE_PARTY: unknown sender %', NEW.from_agent;
    END IF;
    IF NEW.to_agent NOT IN ('orchestrator', 'manager', '*') AND NOT EXISTS (SELECT 1 FROM swarm.agent_registry WHERE name = NEW.to_agent) THEN
        RAISE EXCEPTION 'MESSAGE_PARTY: unknown recipient %', NEW.to_agent;
    END IF;
    IF NEW.type IN ('Finding', 'StatusUpdate', 'Error') AND NEW.from_agent NOT IN (SELECT name FROM swarm.agent_registry WHERE kind = 'specialist') THEN
        RAISE EXCEPTION 'MESSAGE_PARTY: % may be sent only by a specialist', NEW.type;
    END IF;
    IF NEW.type IN ('RequestAssessment', 'Clarification') AND NEW.from_agent NOT IN ('orchestrator', 'manager') THEN
        RAISE EXCEPTION 'MESSAGE_PARTY: % may be sent only by the orchestrator/manager', NEW.type;
    END IF;
    IF NEW.seq IS NULL THEN
        SELECT COALESCE(max(seq), 0) + 1 INTO NEW.seq FROM swarm.message WHERE run_id = NEW.run_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_message_typed BEFORE INSERT OR UPDATE OR DELETE ON swarm.message
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_message_typed_fn();

-- C-05 / FR-04: exactly one LLM inference at a time.
CREATE OR REPLACE FUNCTION swarm.trg_llm_lease_exclusive_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n
      FROM swarm.llm_lease l
     WHERE l.id <> NEW.id
       AND l.acquired_at < COALESCE(NEW.released_at, 'infinity'::timestamptz)
       AND COALESCE(l.released_at, 'infinity'::timestamptz) > NEW.acquired_at;
    IF n >= swarm.setting_num('semaphore_slots') THEN
        RAISE EXCEPTION 'GPU_SEMAPHORE: % lease(s) already held for [%, %]', n, NEW.acquired_at, NEW.released_at;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_llm_lease_exclusive BEFORE INSERT OR UPDATE ON swarm.llm_lease
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_llm_lease_exclusive_fn();

-- FR-05: only the transitions swarm.circuit_next_state() produces; every change is an event.
CREATE OR REPLACE FUNCTION swarm.trg_circuit_transition_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    threshold integer := swarm.setting_num('circuit_threshold')::integer;
    cooldown  interval := make_interval(mins => swarm.setting_num('circuit_cooldown_min')::integer);
BEGIN
    IF NEW.state = OLD.state AND NEW.consecutive_failures = OLD.consecutive_failures THEN RETURN NEW; END IF;
    IF OLD.state = 'closed' AND NEW.state = 'open' AND NEW.consecutive_failures < threshold THEN
        RAISE EXCEPTION 'CIRCUIT_TRANSITION: closed→open needs % consecutive failures', threshold;
    END IF;
    IF OLD.state = 'open' AND NEW.state = 'closed' THEN
        RAISE EXCEPTION 'CIRCUIT_TRANSITION: open→closed must pass through half_open';
    END IF;
    IF OLD.state = 'open' AND NEW.state = 'half_open' AND NEW.last_change_at < OLD.opened_at + cooldown THEN
        RAISE EXCEPTION 'CIRCUIT_TRANSITION: open→half_open before the cool-down';
    END IF;
    IF OLD.state = 'half_open' AND NEW.state = 'closed' AND NEW.consecutive_failures <> 0 THEN
        RAISE EXCEPTION 'CIRCUIT_TRANSITION: half_open→closed resets failures';
    END IF;
    IF NEW.state = 'open' AND NEW.opened_at IS NULL THEN NEW.opened_at := NEW.last_change_at; END IF;
    IF NEW.state = 'closed' THEN NEW.opened_at := NULL; END IF;
    IF NEW.state <> OLD.state THEN
        INSERT INTO swarm.circuit_event (agent_id, from_state, to_state, reason, ts)
        VALUES (NEW.agent_id, OLD.state, NEW.state, NEW.last_outcome, NEW.last_change_at);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_circuit_transition BEFORE UPDATE ON swarm.circuit_state
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_circuit_transition_fn();

-- FR-22 / FR-14 / C-02: findings come only from enabled specialists, inside their domains, with well-formed evidence.
CREATE OR REPLACE FUNCTION swarm.trg_finding_author_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    a   swarm.agent_registry%ROWTYPE;
    err text;
BEGIN
    SELECT * INTO a FROM swarm.agent_registry WHERE name = NEW.agent_name;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINDING_AUTHOR: % is not registered', NEW.agent_name; END IF;
    IF a.kind <> 'specialist' THEN RAISE EXCEPTION 'FINDING_AUTHOR: the manager may aggregate, relate and rank — never invent (FR-22)'; END IF;
    IF NOT a.enabled THEN RAISE EXCEPTION 'FINDING_AUTHOR: % is disabled', NEW.agent_name; END IF;
    IF NOT EXISTS (SELECT 1 FROM swarm.agent_domain d WHERE d.agent_id = a.id AND d.domain = NEW.domain) THEN
        RAISE EXCEPTION 'DOMAIN_VIOLATION: % may not report on % (FR-14)', NEW.agent_name, NEW.domain;
    END IF;
    err := swarm.evidence_ok(NEW.evidence_json);
    IF err IS NOT NULL THEN RAISE EXCEPTION 'EVIDENCE_SHAPE: %', err; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_finding_author BEFORE INSERT ON agent.finding
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_finding_author_fn();

-- FR-23 / FR-25 / FR-27: lifecycle transitions; person-driven transitions need an action; terminal ones need a resolution.
CREATE OR REPLACE FUNCTION swarm.trg_finding_lifecycle_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    ctx text := current_setting('swarm.action_ctx', true);
    ok  boolean;
    err text;
BEGIN
    IF NEW.agent_name <> OLD.agent_name OR NEW.domain <> OLD.domain THEN RAISE EXCEPTION 'FINDING_IMMUTABLE: author and domain'; END IF;
    err := swarm.evidence_ok(NEW.evidence_json);
    IF err IS NOT NULL THEN RAISE EXCEPTION 'EVIDENCE_SHAPE: %', err; END IF;
    IF NEW.status = OLD.status THEN RETURN NEW; END IF;
    ok := CASE OLD.status
            WHEN 'new'          THEN NEW.status IN ('acknowledged', 'in_progress', 'resolved', 'expired', 'dismissed')
            WHEN 'acknowledged' THEN NEW.status IN ('in_progress', 'resolved', 'expired', 'dismissed')
            WHEN 'in_progress'  THEN NEW.status IN ('resolved', 'expired', 'dismissed')
            ELSE NEW.status = 'new'   -- resolved / expired / dismissed → reopen only
          END;
    IF NOT ok THEN RAISE EXCEPTION 'LIFECYCLE_TRANSITION: % → % is not allowed', OLD.status, NEW.status; END IF;
    IF NEW.status IN ('acknowledged', 'in_progress', 'dismissed') OR (OLD.status IN ('resolved', 'expired', 'dismissed') AND NEW.status = 'new') THEN
        IF ctx IS DISTINCT FROM NEW.id::text THEN
            RAISE EXCEPTION 'ACTION_REQUIRED: % → % only through swarm.finding_action (FR-25)', OLD.status, NEW.status;
        END IF;
    END IF;
    IF NEW.status IN ('resolved', 'expired') THEN
        IF NEW.resolution IS NULL THEN RAISE EXCEPTION 'RESOLUTION_REQUIRED: % needs a resolution', NEW.status; END IF;
        NEW.resolved_at := COALESCE(NEW.resolved_at, now());
    END IF;
    IF NEW.status = 'new' THEN NEW.resolved_at := NULL; NEW.resolution := NULL; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_finding_lifecycle BEFORE UPDATE ON agent.finding
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_finding_lifecycle_fn();

-- Keeps the dedupe window (finding_ext.active) in step with the status.
CREATE OR REPLACE FUNCTION swarm.trg_finding_ext_active_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE swarm.finding_ext SET active = (NEW.status IN ('new', 'acknowledged', 'in_progress')) WHERE finding_id = NEW.id;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_finding_ext_active AFTER UPDATE OF status ON agent.finding
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_finding_ext_active_fn();

-- FR-25: an action carries the transition and performs it inside the action context.
CREATE OR REPLACE FUNCTION swarm.trg_finding_action_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    f agent.finding%ROWTYPE;
BEGIN
    SELECT * INTO f FROM agent.finding WHERE id = NEW.finding_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINDING_UNKNOWN'; END IF;
    NEW.from_status := f.status;
    NEW.to_status := CASE NEW.kind
                        WHEN 'acknowledge' THEN 'acknowledged'::agent.finding_status
                        WHEN 'assign'      THEN 'in_progress'
                        WHEN 'start'       THEN 'in_progress'
                        WHEN 'snooze'      THEN f.status
                        WHEN 'dismiss'     THEN 'dismissed'
                        WHEN 'resolve'     THEN 'resolved'
                        WHEN 'reopen'      THEN 'new'
                     END;
    IF NEW.kind = 'snooze' AND NEW.snooze_until <= NEW.ts THEN RAISE EXCEPTION 'SNOOZE_UNTIL: must be in the future'; END IF;
    IF NEW.kind = 'reopen' AND f.status NOT IN ('resolved', 'expired', 'dismissed') THEN RAISE EXCEPTION 'REOPEN_ONLY_TERMINAL'; END IF;
    PERFORM set_config('swarm.action_ctx', NEW.finding_id::text, true);
    UPDATE agent.finding
       SET status      = NEW.to_status,
           owner_id    = CASE WHEN NEW.kind = 'assign' THEN NEW.assignee_id ELSE owner_id END,
           resolution  = CASE WHEN NEW.kind = 'resolve' THEN NEW.reason
                              WHEN NEW.kind = 'dismiss' THEN 'dismissed (' || NEW.dismiss_reason::text || '): ' || NEW.reason
                              WHEN NEW.kind = 'reopen' THEN NULL ELSE resolution END,
           resolved_at = CASE WHEN NEW.kind IN ('resolve', 'dismiss') THEN NEW.ts WHEN NEW.kind = 'reopen' THEN NULL ELSE resolved_at END
     WHERE id = NEW.finding_id;
    IF NEW.kind = 'snooze' THEN UPDATE swarm.finding_ext SET snoozed_until = NEW.snooze_until WHERE finding_id = NEW.finding_id; END IF;
    IF NEW.kind = 'reopen' THEN UPDATE swarm.finding_ext SET snoozed_until = NULL WHERE finding_id = NEW.finding_id; END IF;
    PERFORM set_config('swarm.action_ctx', '', true);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_finding_action BEFORE INSERT ON swarm.finding_action
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_finding_action_fn();

-- FR-18 / AI-03: the score is computed here from the published tables; a supplied score that differs is refused.
CREATE OR REPLACE FUNCTION swarm.trg_risk_score_computed_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    f  agent.finding%ROWTYPE;
    fe swarm.finding_ext%ROWTYPE;
    x  record;
BEGIN
    SELECT * INTO f  FROM agent.finding WHERE id = NEW.finding_id;
    SELECT * INTO fe FROM swarm.finding_ext WHERE finding_id = NEW.finding_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINDING_EXT_MISSING'; END IF;
    IF NOT EXISTS (SELECT 1 FROM swarm.finding_occurrence o WHERE o.finding_id = NEW.finding_id AND o.run_id = NEW.run_id) THEN
        RAISE EXCEPTION 'SCORE_FOREIGN_FINDING: finding did not occur in this run';
    END IF;
    SELECT * INTO x FROM swarm.score_factors(f.severity, fe.likelihood_class, fe.horizon, f.confidence, NEW.weights_version);
    IF NEW.score IS NOT NULL AND NEW.score <> x.score THEN
        RAISE EXCEPTION 'SCORE_NOT_COMPUTED: supplied % <> computed % (FR-18: the ranking is a function, not a judgement)', NEW.score, x.score;
    END IF;
    NEW.impact := x.impact; NEW.likelihood := x.likelihood; NEW.urgency := x.urgency; NEW.confidence := x.confidence; NEW.score := x.score;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_risk_score_computed BEFORE INSERT OR UPDATE ON swarm.risk_score
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_risk_score_computed_fn();

-- FR-17 / AI-04 / AC-04: a compound is >= 2 findings of the run from >= 2 domains sharing the rule's keys; score = noisy-OR >= every component.
CREATE OR REPLACE FUNCTION swarm.trg_compound_components_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    rule    swarm.relation_rule%ROWTYPE;
    scores  numeric[];
    n_dom   integer;
    n_keys  integer;
    n_found integer;
    expected numeric;
BEGIN
    SELECT * INTO rule FROM swarm.relation_rule WHERE id = NEW.rule_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'RULE_UNKNOWN'; END IF;
    IF (SELECT count(DISTINCT x) FROM unnest(NEW.finding_ids) x) < 2 THEN RAISE EXCEPTION 'COMPOUND_NEEDS_TWO'; END IF;
    SELECT count(*), count(DISTINCT f.domain), count(DISTINCT swarm.scope_key(f.scope_json, rule.match_keys)),
           array_agg(rs.score ORDER BY rs.score DESC)
      INTO n_found, n_dom, n_keys, scores
      FROM swarm.risk_score rs JOIN agent.finding f ON f.id = rs.finding_id
     WHERE rs.run_id = NEW.run_id AND rs.finding_id = ANY (NEW.finding_ids);
    IF n_found <> array_length(NEW.finding_ids, 1) THEN RAISE EXCEPTION 'COMPOUND_FOREIGN_FINDING: components must be scored findings of this run'; END IF;
    IF n_dom < rule.min_domains THEN RAISE EXCEPTION 'COMPOUND_SINGLE_DOMAIN: % domain(s), rule % needs %', n_dom, rule.code, rule.min_domains; END IF;
    IF n_keys <> 1 OR EXISTS (SELECT 1 FROM agent.finding f WHERE f.id = ANY (NEW.finding_ids) AND swarm.scope_key(f.scope_json, rule.match_keys) IS NULL) THEN
        RAISE EXCEPTION 'COMPOUND_KEY_MISMATCH: components do not share % ', rule.match_keys;
    END IF;
    expected := swarm.compound_score(scores);
    IF NEW.score <> expected THEN RAISE EXCEPTION 'COMPOUND_SCORE: supplied % <> noisy-OR %', NEW.score, expected; END IF;
    IF NEW.score < (SELECT max(s) FROM unnest(scores) s) THEN RAISE EXCEPTION 'COMPOUND_BELOW_COMPONENT'; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_compound_components BEFORE INSERT OR UPDATE ON swarm.compound_risk
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_compound_components_fn();

-- FR-22 / AC-07 and FR-20 / AC-02: a briefing is grounded in its run's findings, and its partial flag matches the assessments.
CREATE OR REPLACE FUNCTION swarm.trg_briefing_run_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    b        agent.briefing%ROWTYPE;
    r        swarm.run%ROWTYPE;
    ids      uuid[];
    chk      jsonb;
    n_failed integer;
    failed_names text;
BEGIN
    SELECT * INTO b FROM agent.briefing WHERE id = NEW.briefing_id;
    SELECT * INTO r FROM swarm.run WHERE id = NEW.run_id;
    IF r.status NOT IN ('completed', 'partial') THEN RAISE EXCEPTION 'BRIEFING_RUN_STATUS: run % is %', r.run_no, r.status; END IF;
    -- every finding the briefing cites must belong to this run
    SELECT COALESCE(array_agg(DISTINCT (x.value #>> '{}')::uuid), '{}') INTO ids
      FROM jsonb_array_elements(b.top_risks_json) t, jsonb_array_elements(t.value -> 'finding_ids') x;
    IF EXISTS (SELECT 1 FROM unnest(ids) i WHERE NOT EXISTS (SELECT 1 FROM swarm.risk_score rs WHERE rs.run_id = NEW.run_id AND rs.finding_id = i)) THEN
        RAISE EXCEPTION 'BRIEFING_FOREIGN_FINDING: a cited finding was not scored in run %', r.run_no;
    END IF;
    -- partial flag
    SELECT count(*), string_agg(a.name, ', ' ORDER BY a.name)
      INTO n_failed, failed_names
      FROM swarm.assessment s JOIN swarm.agent_registry a ON a.id = s.agent_id
     WHERE s.run_id = NEW.run_id AND s.outcome NOT IN ('findings', 'nothing_significant');
    IF b.partial <> (n_failed > 0) THEN
        RAISE EXCEPTION 'BRIEFING_PARTIAL_MISMATCH: % failed assessment(s) but partial = %', n_failed, b.partial;
    END IF;
    IF n_failed > 0 AND (b.partial_reason IS NULL OR position(split_part(failed_names, ',', 1) IN b.partial_reason) = 0) THEN
        RAISE EXCEPTION 'BRIEFING_PARTIAL_REASON: must name %', failed_names;
    END IF;
    -- claim check (FR-22 / AC-07)
    chk := swarm.claim_check(b.text, NEW.run_id, ids);
    NEW.claims_json      := chk;
    NEW.claim_check_json := chk;
    IF jsonb_array_length(chk -> 'unmatched') > 0 THEN
        RAISE EXCEPTION 'BRIEFING_UNGROUNDED: numbers not in the cited findings: %', chk -> 'unmatched';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_briefing_grounded BEFORE INSERT OR UPDATE ON swarm.briefing_run
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_briefing_run_fn();

COMMENT ON TRIGGER trg_briefing_grounded ON swarm.briefing_run IS
  'Two guards in one function: the claim check (BRIEFING_UNGROUNDED, FR-22/AC-07) and the partial-flag consistency (BRIEFING_PARTIAL_MISMATCH / BRIEFING_PARTIAL_REASON, FR-20/AC-02). DDS-13 refers to the latter as trg_briefing_partial.';

-- FR-29: a CRITICAL finding is pushed immediately.
CREATE OR REPLACE FUNCTION swarm.trg_delivery_critical_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.severity = 'CRITICAL' AND (TG_OP = 'INSERT' OR OLD.severity <> 'CRITICAL') THEN
        INSERT INTO swarm.delivery (kind, finding_id, channel, scheduled_at)
        VALUES ('immediate', NEW.id, 'discord', NEW.last_seen);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_delivery_critical AFTER INSERT OR UPDATE OF severity ON agent.finding
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_delivery_critical_fn();

-- Occurrences are append-only history.
CREATE OR REPLACE FUNCTION swarm.trg_append_only_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'APPEND_ONLY: % is history', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_occurrence_append_only BEFORE UPDATE OR DELETE ON swarm.finding_occurrence
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_append_only_fn();
CREATE TRIGGER trg_action_append_only BEFORE UPDATE OR DELETE ON swarm.finding_action
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_append_only_fn();
CREATE TRIGGER trg_attempt_append_only BEFORE UPDATE OR DELETE ON swarm.attempt
    FOR EACH ROW EXECUTE FUNCTION swarm.trg_append_only_fn();

-- =====================================================================
-- 17. SWARM — indexes and views
-- =====================================================================

CREATE INDEX idx_swarm_run_started      ON swarm.run (started_at DESC);
CREATE INDEX idx_swarm_run_status       ON swarm.run (status, started_at DESC);
CREATE INDEX idx_swarm_assessment_run   ON swarm.assessment (run_id);
CREATE INDEX idx_swarm_assessment_agent ON swarm.assessment (agent_id, requested_at DESC);
CREATE INDEX idx_swarm_message_run      ON swarm.message (run_id, seq);
CREATE INDEX idx_swarm_message_type     ON swarm.message (type, ts DESC);
CREATE INDEX idx_swarm_lease_time       ON swarm.llm_lease (acquired_at, released_at);
CREATE INDEX idx_swarm_occ_finding      ON swarm.finding_occurrence (finding_id, ts DESC);
CREATE INDEX idx_swarm_occ_run          ON swarm.finding_occurrence (run_id, agent_id);
CREATE INDEX idx_swarm_action_finding   ON swarm.finding_action (finding_id, ts DESC);
CREATE INDEX idx_swarm_score_run_rank   ON swarm.risk_score (run_id, rank);
CREATE INDEX idx_swarm_compound_run     ON swarm.compound_risk (run_id, rank);
CREATE INDEX idx_swarm_briefing_run     ON swarm.briefing_run (run_id);
CREATE INDEX idx_swarm_delivery_pending ON swarm.delivery (status, scheduled_at) WHERE status = 'pending';
CREATE INDEX idx_swarm_ext_scope_line   ON swarm.finding_ext (scope_line) WHERE active;
CREATE INDEX idx_swarm_ext_snoozed      ON swarm.finding_ext (snoozed_until) WHERE snoozed_until IS NOT NULL;
CREATE INDEX idx_swarm_scenario_result  ON swarm.scenario_result (suite_run_id, top3_match);
CREATE INDEX idx_swarm_metric_date      ON swarm.agent_metric (metric_date DESC);

-- FR-23 / FR-30: the blackboard as people read it.
CREATE OR REPLACE VIEW swarm.v_blackboard AS
SELECT f.id, f.agent_name, f.domain, fe.issue_code, fe.issue_key, f.title, f.summary, f.severity, f.confidence,
       fe.likelihood_class, fe.horizon, fe.freshness_min, swarm.freshness_flag(fe.freshness_min) AS stale,
       f.status, f.owner_id, u.display_name AS owner, f.first_seen, f.last_seen, f.occurrences, fe.snoozed_until,
       fe.scope_line, fe.scope_machine, fe.scope_sku, fe.scope_lot, f.recommended_action, fe.owner_suggestion,
       (SELECT rs.score FROM swarm.risk_score rs JOIN swarm.run r ON r.id = rs.run_id
         WHERE rs.finding_id = f.id ORDER BY r.run_no DESC LIMIT 1) AS latest_score,
       (SELECT count(*) FROM swarm.finding_occurrence o WHERE o.finding_id = f.id) AS occurrence_rows,
       (SELECT count(DISTINCT o.agent_id) FROM swarm.finding_occurrence o WHERE o.finding_id = f.id) AS reporting_agents,
       f.resolved_at, f.resolution
  FROM agent.finding f
  JOIN swarm.finding_ext fe ON fe.finding_id = f.id
  LEFT JOIN core.app_user u ON u.id = f.owner_id;

-- AC-03: every evidence set, per agent and run.
CREATE OR REPLACE VIEW swarm.v_finding_evidence AS
SELECT o.finding_id, r.run_no, a.name AS agent, o.confidence, o.freshness_min, o.summary, e.value ->> 'kind' AS kind,
       e.value ->> 'ref' AS ref, o.ts
  FROM swarm.finding_occurrence o
  JOIN swarm.run r ON r.id = o.run_id
  JOIN swarm.agent_registry a ON a.id = o.agent_id
  CROSS JOIN LATERAL jsonb_array_elements(o.evidence_json) e;

-- FR-30: run board.
CREATE OR REPLACE VIEW swarm.v_run_board AS
SELECT r.id, r.run_no, r.trigger, r.scope_json, r.status, r.partial_reason, r.started_at, r.finished_at,
       swarm.wall_label(r.wall_ms) AS wall, r.wall_ms, r.agent_count, r.tool_call_count, r.token_count, r.weights_version,
       (SELECT count(*) FROM swarm.assessment s WHERE s.run_id = r.id AND s.outcome = 'findings') AS agents_with_findings,
       (SELECT count(*) FROM swarm.assessment s WHERE s.run_id = r.id AND s.outcome = 'nothing_significant') AS agents_nothing,
       (SELECT string_agg(a.name || ':' || s.outcome::text, ', ' ORDER BY a.name) FROM swarm.assessment s JOIN swarm.agent_registry a ON a.id = s.agent_id
         WHERE s.run_id = r.id AND s.outcome NOT IN ('findings', 'nothing_significant')) AS failed_agents,
       (SELECT count(*) FROM swarm.finding_occurrence o WHERE o.run_id = r.id) AS occurrences,
       (SELECT count(*) FROM swarm.compound_risk c WHERE c.run_id = r.id) AS compounds,
       (SELECT count(*) FROM swarm.briefing_run br WHERE br.run_id = r.id) AS briefings
  FROM swarm.run r;

-- FR-07 / AC-09: message trace per run.
CREATE OR REPLACE VIEW swarm.v_run_trace AS
SELECT r.run_no, m.seq, m.ts, m.from_agent, m.to_agent, m.type, m.subject, m.correlation_id, m.payload_json
  FROM swarm.message m JOIN swarm.run r ON r.id = m.run_id;

-- FR-19 / FR-28: the latest briefing per scope and language.
CREATE OR REPLACE VIEW swarm.v_briefing_latest AS
SELECT DISTINCT ON (b.scope_json, b.lang)
       b.id, r.run_no, b.generated_at, b.scope_json, b.lang, b.partial, b.partial_reason, b.top_risks_json, b.text,
       b.delivered_at, br.claim_check_json, br.template_fallback
  FROM agent.briefing b JOIN swarm.briefing_run br ON br.briefing_id = b.id JOIN swarm.run r ON r.id = br.run_id
 ORDER BY b.scope_json, b.lang, b.generated_at DESC;

-- FR-30 / NFR-07: per-agent health.
CREATE OR REPLACE VIEW swarm.v_agent_health AS
SELECT a.id, a.name, a.kind, a.version, a.enabled, a.budget_json, a.schedule_cron, a.prompt_version,
       c.state AS circuit, c.consecutive_failures, c.opened_at,
       (SELECT string_agg(d.domain, ', ' ORDER BY d.domain) FROM swarm.agent_domain d WHERE d.agent_id = a.id) AS domains,
       (SELECT count(*) FROM swarm.agent_tool t WHERE t.agent_id = a.id) AS tools,
       (SELECT s.outcome FROM swarm.assessment s JOIN swarm.run r ON r.id = s.run_id WHERE s.agent_id = a.id ORDER BY r.run_no DESC LIMIT 1) AS last_outcome,
       (SELECT round(avg(s.wall_ms)) FROM swarm.assessment s WHERE s.agent_id = a.id) AS avg_wall_ms,
       (SELECT round(avg(s.tokens_used)) FROM swarm.assessment s WHERE s.agent_id = a.id) AS avg_tokens,
       (SELECT round(avg(s.tool_calls_used), 1) FROM swarm.assessment s WHERE s.agent_id = a.id) AS avg_tool_calls,
       (SELECT count(*) FROM swarm.assessment s WHERE s.agent_id = a.id AND s.outcome NOT IN ('findings', 'nothing_significant')) AS failures
  FROM swarm.agent_registry a
  LEFT JOIN swarm.circuit_state c ON c.agent_id = a.id;

-- FR-26: precision per agent over the last 90 days.
CREATE OR REPLACE VIEW swarm.v_agent_precision AS
SELECT a.name, p.findings, p.dismissed, p.false_positives, p.precision_rate
  FROM swarm.agent_registry a
  CROSS JOIN LATERAL swarm.agent_precision(a.id, (current_date - 90), current_date) p
 WHERE a.kind = 'specialist';

-- FR-17: why a compound exists, with each component's factors.
CREATE OR REPLACE VIEW swarm.v_compound_explain AS
SELECT r.run_no, c.id AS compound_id, c.rank, c.score, c.title, rr.code AS rule, c.shared_key_json, c.rationale,
       f.id AS finding_id, f.agent_name, f.domain, f.title AS component_title,
       rs.impact, rs.likelihood, rs.urgency, rs.confidence, rs.score AS component_score
  FROM swarm.compound_risk c
  JOIN swarm.run r ON r.id = c.run_id
  JOIN swarm.relation_rule rr ON rr.id = c.rule_id
  JOIN LATERAL unnest(c.finding_ids) WITH ORDINALITY AS u(fid, ord) ON true
  JOIN agent.finding f ON f.id = u.fid
  JOIN swarm.risk_score rs ON rs.finding_id = f.id AND rs.run_id = c.run_id;

-- C-04 / NFR-07: usage against budget per assessment.
CREATE OR REPLACE VIEW swarm.v_budget_usage AS
SELECT r.run_no, a.name AS agent, s.outcome, s.incomplete, s.tool_calls_used, (COALESCE(r.budget_json -> a.name, a.budget_json) ->> 'tool_calls')::int AS tool_calls_budget,
       s.tokens_used, (COALESCE(r.budget_json -> a.name, a.budget_json) ->> 'tokens')::int AS tokens_budget,
       s.wall_ms, (COALESCE(r.budget_json -> a.name, a.budget_json) ->> 'wall_ms')::int AS wall_budget_ms,
       swarm.budget_check(jsonb_build_object('tool_calls', s.tool_calls_used, 'tokens', s.tokens_used, 'wall_ms', s.wall_ms),
                          COALESCE(r.budget_json -> a.name, a.budget_json)) AS violation
  FROM swarm.assessment s JOIN swarm.run r ON r.id = s.run_id JOIN swarm.agent_registry a ON a.id = s.agent_id;

-- AI-06: the gate.
CREATE OR REPLACE VIEW swarm.v_scenario_gate AS
SELECT sr.id, sr.weights_version, sr.mode, sr.started_at, sr.scenarios, sr.matches, sr.match_rate, sr.fabricated, sr.passed,
       swarm.setting_num('scenario_gate_top3') AS gate_top3,
       (SELECT string_agg(sc.code, ', ' ORDER BY sc.code) FROM swarm.scenario_result x JOIN swarm.scenario sc ON sc.id = x.scenario_id
         WHERE x.suite_run_id = sr.id AND NOT x.top3_match) AS mismatches
  FROM swarm.suite_run sr;

-- =====================================================================
-- 18. ROLES AND GRANTS (standalone; platform mode keeps the platform's roles and adds orchestrator_rw + auditor_ro)
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')          THEN CREATE ROLE app_rw          NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')          THEN CREATE ROLE app_ro          NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'orchestrator_rw') THEN CREATE ROLE orchestrator_rw NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor_ro')      THEN CREATE ROLE auditor_ro      NOLOGIN; END IF;
END
$$;

COMMENT ON ROLE orchestrator_rw IS 'The one writer of the blackboard (ADR-K08). Inserts runs, assessments, attempts, messages, leases, occurrences, scores, compounds, briefings; never updates or deletes history.';
COMMENT ON ROLE auditor_ro      IS 'Runs, messages, assessments, findings, occurrences, briefings, exports and the audit log — read only (NFR-05).';

GRANT USAGE ON SCHEMA core, agent, swarm TO app_rw, app_ro, orchestrator_rw;
GRANT USAGE ON SCHEMA audit TO app_rw, app_ro, orchestrator_rw, auditor_ro;
GRANT USAGE ON SCHEMA swarm, agent, core TO auditor_ro;

-- app_rw (api): people's actions, registry, rules, weights, scenarios, exports; findings only through actions
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core TO app_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA agent TO app_rw;
GRANT INSERT, UPDATE ON agent.tool TO app_rw;
GRANT UPDATE ON agent.finding TO app_rw;                       -- status/owner through swarm.finding_action only (trg_finding_lifecycle)
GRANT SELECT ON ALL TABLES IN SCHEMA swarm TO app_rw;
GRANT INSERT, UPDATE ON swarm.agent_registry, swarm.agent_domain, swarm.agent_tool, swarm.relation_rule, swarm.scoring_weights,
                        swarm.scenario, swarm.setting, swarm.question, swarm.export, swarm.delivery TO app_rw;
GRANT DELETE ON swarm.agent_domain, swarm.agent_tool TO app_rw;
GRANT INSERT ON swarm.run, swarm.finding_action, swarm.suite_run, swarm.scenario_result, swarm.registry_change, swarm.circuit_event TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit, swarm TO app_rw;

-- orchestrator_rw: the writer of runs; history is append-only
GRANT SELECT ON ALL TABLES IN SCHEMA core TO orchestrator_rw;
REVOKE SELECT ON core.app_user, core.user_line_scope FROM orchestrator_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA swarm TO orchestrator_rw;
GRANT SELECT, INSERT ON agent.run, agent.tool_call, agent.finding, agent.briefing TO orchestrator_rw;
GRANT SELECT ON agent.tool TO orchestrator_rw;
GRANT UPDATE ON agent.run, agent.finding, agent.briefing TO orchestrator_rw;
GRANT INSERT ON swarm.run, swarm.assessment, swarm.attempt, swarm.message, swarm.llm_lease, swarm.circuit_event,
                swarm.finding_ext, swarm.finding_occurrence, swarm.risk_score, swarm.compound_risk, swarm.briefing_run,
                swarm.delivery, swarm.question, swarm.agent_metric, swarm.suite_run, swarm.scenario_result TO orchestrator_rw;
GRANT UPDATE ON swarm.run, swarm.assessment, swarm.llm_lease, swarm.circuit_state, swarm.finding_ext, swarm.risk_score,
                swarm.compound_risk, swarm.delivery, swarm.question, swarm.agent_metric, swarm.suite_run TO orchestrator_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA swarm TO orchestrator_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO orchestrator_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO orchestrator_rw;

-- app_ro (dashboard): read only, no credentials
GRANT SELECT ON ALL TABLES IN SCHEMA core, agent, swarm, audit TO app_ro;
REVOKE SELECT ON core.app_user FROM app_ro;
GRANT SELECT (id, display_name, role) ON core.app_user TO app_ro;

-- auditor_ro: history only
GRANT SELECT ON swarm.run, swarm.assessment, swarm.attempt, swarm.message, swarm.llm_lease, swarm.circuit_event,
                swarm.finding_ext, swarm.finding_occurrence, swarm.finding_action, swarm.risk_score, swarm.compound_risk,
                swarm.briefing_run, swarm.delivery, swarm.export, swarm.registry_change, swarm.agent_registry,
                swarm.scoring_weights, swarm.relation_rule TO auditor_ro;
GRANT SELECT ON agent.run, agent.tool_call, agent.finding, agent.briefing, agent.tool TO auditor_ro;
GRANT SELECT ON audit.log, audit.auth_event TO auditor_ro;
GRANT SELECT (id, display_name, role) ON core.app_user TO auditor_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA swarm GRANT SELECT ON TABLES TO app_ro, app_rw, orchestrator_rw;

-- =====================================================================
-- 19. SCHEMA VERSION
-- =====================================================================

INSERT INTO swarm.migration (version, description)
VALUES ('swarm_0001', 'KaizenSwarm extension of the platform agent context (DDS-13 v1.0): registry, runs, assessments, typed messages, leases, circuits, blackboard extension, scores, compounds, claim-checked briefings, deliveries, metrics, scenario suite')
ON CONFLICT (version) DO NOTHING;
