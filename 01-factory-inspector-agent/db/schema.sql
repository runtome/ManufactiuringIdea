-- =====================================================================
-- VisionOps (AI Factory Inspector Agent) — Database Schema
-- Document : DDS-01-VisionOps (see docs/DDS-VisionOps-Database-Design.md)
-- Version  : 1.0
-- Date     : 2026-09-11
-- Target   : PostgreSQL 16 with pgvector >= 0.7
--            (verified against image pgvector/pgvector:pg16)
--
-- Apply with:
--   psql -v ON_ERROR_STOP=1 -f schema.sql
--
-- STANDALONE deployment schema. In platform mode this file is NOT applied;
-- the platform's schema (00/db/schema.sql) already contains every shared
-- table below, byte-identical, and the VisionOps-only additions in
-- section 10 are applied as a migration instead (DDS-01 section 12).
--
-- BYTE-IDENTITY RULE (ADR-V10): sections marked "byte-identical to the
-- platform" are copied verbatim from 00/db/schema.sql and checked by a CI
-- diff. Edit them in 01 first, then copy to 00 — never diverge.
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

CREATE SCHEMA IF NOT EXISTS core;       -- minimal master data (subset of platform core)
CREATE SCHEMA IF NOT EXISTS vision;     -- inspections, detections, models — VisionOps owns this
CREATE SCHEMA IF NOT EXISTS agent;      -- narrative agent runs and tool calls
CREATE SCHEMA IF NOT EXISTS ops;        -- edge fleet, jobs, config, data quality
CREATE SCHEMA IF NOT EXISTS audit;      -- append-only audit trail

COMMENT ON SCHEMA core      IS 'Minimal master data: plant, line, sku, defect_type, material_lot, shift_calendar, users. Identical definitions to the platform; the platform adds production facts and machines.';
COMMENT ON SCHEMA vision    IS 'Inspection records, detections, measurements, model registry, overrides, plus VisionOps-only: station, calibration, anomaly, dataset snapshots, agreement, narrative.';
COMMENT ON SCHEMA agent     IS 'Narrative agent: tool registry, runs, tool calls, proposals. Subset of the platform agent schema (no findings/briefings).';
COMMENT ON SCHEMA ops       IS 'Edge node fleet, scheduled jobs, runtime configuration, data quality events.';
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

CREATE TYPE vision.verdict         AS ENUM ('PASS', 'FAIL', 'REVIEW', 'NO_READ');
CREATE TYPE vision.model_stage     AS ENUM ('candidate', 'shadow', 'active', 'retired');

CREATE TYPE agent.run_outcome      AS ENUM ('ok', 'partial', 'refused', 'grounding_failed', 'error', 'budget_exceeded');
CREATE TYPE agent.message_role     AS ENUM ('user', 'assistant', 'system', 'tool');

CREATE TYPE ops.node_state         AS ENUM ('provisioning', 'online', 'degraded', 'offline', 'retired');
CREATE TYPE ops.dq_severity        AS ENUM ('info', 'warning', 'error');

COMMENT ON TYPE vision.verdict IS
  'NO_READ = frame rejected by the quality gate (blur/exposure). Distinct from PASS: nothing was actually judged.';
COMMENT ON TYPE agent.run_outcome IS
  'grounding_failed = the post-check (ADR-013) found a number not present in tool results; the answer was withheld.';

-- =====================================================================
-- 5. CORE — minimal master data  (byte-identical to the platform)
--    Omitted vs platform: core.machine, core.ingest_batch,
--    core.production_fact, core.defect_fact, core.quarantine_row
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

-- =====================================================================
-- 6. VISION — inspection records  (byte-identical to the platform)
-- =====================================================================

CREATE TABLE vision.model_registry (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name           text        NOT NULL,
    version        text        NOT NULL,
    sha256         text        NOT NULL,
    task           text        NOT NULL CHECK (task IN ('detection','segmentation','classification','ocr','anomaly','embedding')),
    input_size     integer,
    class_map      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    metrics_json   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    stage          vision.model_stage NOT NULL DEFAULT 'candidate',
    trained_from   text,
    promoted_by    uuid        REFERENCES core.app_user(id),
    promoted_at    timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT model_name_version_unique UNIQUE (name, version)
);

COMMENT ON TABLE vision.model_registry IS
  'Every model that has ever been deployed. metrics_json holds hold-out results used for the promotion gate (SRS AI-03, SAD 4.4.4).';

CREATE TABLE vision.camera (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    line_id          uuid        NOT NULL REFERENCES core.line(id) ON DELETE RESTRICT,
    station          text        NOT NULL,
    model            text,
    resolution       text,
    calib_px_per_mm  numeric(10,4),
    node_id          uuid,               -- FK added after ops.edge_node exists
    active           boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT camera_station_unique_per_line UNIQUE (line_id, station)
);

CREATE TABLE vision.recipe (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sku_id            uuid        NOT NULL REFERENCES core.sku(id) ON DELETE CASCADE,
    version           integer     NOT NULL,
    rules_json        jsonb       NOT NULL,
    review_threshold  numeric(4,3) NOT NULL DEFAULT 0.550
                      CHECK (review_threshold > 0 AND review_threshold < 1),
    active_from       timestamptz NOT NULL DEFAULT now(),
    active_to         timestamptz,
    created_by        uuid        REFERENCES core.app_user(id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT recipe_sku_version_unique UNIQUE (sku_id, version)
);

COMMENT ON COLUMN vision.recipe.review_threshold IS
  'Confidence below this routes to REVIEW (SRS FR-V-02). Per-SKU because tolerance for false alarms differs by customer.';

-- Partitioned by month: 100k inspections/day (NFR-05) makes retention and
-- vacuum unmanageable on a single heap.
CREATE TABLE vision.inspection (
    id              uuid        NOT NULL DEFAULT public.uuid_generate_v7(),
    ts              timestamptz NOT NULL,
    line_id         uuid        NOT NULL REFERENCES core.line(id) ON DELETE RESTRICT,
    sku_id          uuid        REFERENCES core.sku(id) ON DELETE RESTRICT,
    camera_id       uuid        REFERENCES vision.camera(id) ON DELETE SET NULL,
    station         text,
    lot             text,
    verdict         vision.verdict NOT NULL,
    model_id        uuid        REFERENCES vision.model_registry(id) ON DELETE SET NULL,
    recipe_id       uuid        REFERENCES vision.recipe(id) ON DELETE SET NULL,
    latency_ms      integer     CHECK (latency_ms IS NULL OR latency_ms >= 0),
    image_uri       text,
    overlay_uri     text,
    ocr_text        text,
    source          text        NOT NULL DEFAULT 'edge'
                    CHECK (source IN ('edge','server','mobile','manual')),
    node_id         uuid,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);

COMMENT ON TABLE vision.inspection IS
  'One row per judged part. id is client-generated UUIDv7 (ADR-012) so edge nodes can create records offline and dedup on sync (SAD 5.7).';

-- Initial partitions. OPS RB-13 creates future partitions on schedule.
CREATE TABLE vision.inspection_2026_08 PARTITION OF vision.inspection
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE vision.inspection_2026_09 PARTITION OF vision.inspection
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE vision.inspection_2026_10 PARTITION OF vision.inspection
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE vision.inspection_default PARTITION OF vision.inspection DEFAULT;

COMMENT ON TABLE vision.inspection_default IS
  'Catch-all so an out-of-range timestamp never fails an insert. OPS alert fires if it is non-empty (RB-13).';

CREATE TABLE vision.detection (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    inspection_id  uuid        NOT NULL,
    inspection_ts  timestamptz NOT NULL,
    defect_type_id uuid        REFERENCES core.defect_type(id) ON DELETE RESTRICT,
    class_name     text        NOT NULL,
    confidence     numeric(5,4) NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    bbox_json      jsonb,
    mask_uri       text,
    area_mm2       numeric(12,4),
    created_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (inspection_id, inspection_ts)
        REFERENCES vision.inspection(id, ts) ON DELETE CASCADE
);

CREATE TABLE vision.measurement (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    inspection_id  uuid        NOT NULL,
    inspection_ts  timestamptz NOT NULL,
    parameter      text        NOT NULL,
    value          numeric(14,5) NOT NULL,
    unit           text        NOT NULL DEFAULT 'mm',
    usl            numeric(14,5),
    lsl            numeric(14,5),
    in_spec        boolean GENERATED ALWAYS AS (
                       (usl IS NULL OR value <= usl) AND
                       (lsl IS NULL OR value >= lsl)
                   ) STORED,
    created_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (inspection_id, inspection_ts)
        REFERENCES vision.inspection(id, ts) ON DELETE CASCADE,
    CONSTRAINT spec_limits_ordered CHECK (usl IS NULL OR lsl IS NULL OR usl >= lsl)
);

COMMENT ON COLUMN vision.measurement.in_spec IS
  'Generated column: spec conformance is derived, never written by an application, so it cannot drift from the limits.';

CREATE TABLE vision.verdict_override (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    inspection_id  uuid        NOT NULL,
    inspection_ts  timestamptz NOT NULL,
    old_verdict    vision.verdict NOT NULL,
    new_verdict    vision.verdict NOT NULL,
    user_id        uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE RESTRICT,
    reason_code    text,
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (inspection_id, inspection_ts)
        REFERENCES vision.inspection(id, ts) ON DELETE CASCADE,
    CONSTRAINT override_changes_verdict CHECK (old_verdict <> new_verdict)
);

COMMENT ON TABLE vision.verdict_override IS
  'Human judgement always wins and is always recorded (SRS FR-V-03). This table is also the retraining dataset source (FR-V-04).';

CREATE TABLE vision.drift_metric (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ts           timestamptz NOT NULL DEFAULT now(),
    camera_id    uuid        REFERENCES vision.camera(id) ON DELETE CASCADE,
    model_id     uuid        REFERENCES vision.model_registry(id) ON DELETE SET NULL,
    metric       text        NOT NULL,
    value        numeric(14,5) NOT NULL,
    baseline     numeric(14,5),
    sigma        numeric(8,3),
    alerted      boolean     NOT NULL DEFAULT false
);

COMMENT ON TABLE vision.drift_metric IS
  'Input drift monitoring (SRS AI-07): brightness, blur, class distribution. sigma > 3 triggers an alert.';

-- =====================================================================
-- 7. AGENT — narrative runs and tools  (byte-identical to the platform)
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
-- 8. OPS — edge fleet, jobs, config, data quality  (byte-identical)
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

ALTER TABLE vision.camera
    ADD CONSTRAINT camera_node_fk FOREIGN KEY (node_id)
    REFERENCES ops.edge_node(id) ON DELETE SET NULL;

ALTER TABLE vision.inspection
    ADD CONSTRAINT inspection_node_fk FOREIGN KEY (node_id)
    REFERENCES ops.edge_node(id) ON DELETE SET NULL;

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
-- 10. VISION — VisionOps-only extensions
-- =====================================================================

-- ---------------------------------------------------------------------
-- VisionOps-only tables (not yet in the platform schema).
-- Candidates for back-port into 00/db/schema.sql when the platform
-- adopts them. Everything ABOVE this line in section 6 is byte-identical
-- to the platform's vision schema (ADR-V10).
-- ---------------------------------------------------------------------

CREATE TABLE vision.station (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    line_id     uuid        NOT NULL REFERENCES core.line(id) ON DELETE RESTRICT,
    code        text        NOT NULL,
    name        text        NOT NULL,
    position    smallint,
    trigger_mode text       NOT NULL DEFAULT 'hardware'
                CHECK (trigger_mode IN ('hardware','software','freerun')),
    plc_io_json jsonb       NOT NULL DEFAULT '{}'::jsonb,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT station_code_unique_per_line UNIQUE (line_id, code)
);

COMMENT ON TABLE vision.station IS
  'A fixed inspection position on a line. vision.camera.station and vision.inspection.station carry the code (text) so the platform schema stays unchanged; this table is the master record.';
COMMENT ON COLUMN vision.station.plc_io_json IS
  'Signal assignment for IF-03: {"ready":"Q0.0","pass":"Q0.1","fail":"Q0.2","review":"Q0.3","fault":"Q0.4","trigger":"I0.0","pulse_ms":200}. Must match the panel drawing.';

CREATE TABLE vision.calibration (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    camera_id           uuid        NOT NULL REFERENCES vision.camera(id) ON DELETE CASCADE,
    version             integer     NOT NULL,
    method              text        NOT NULL
                        CHECK (method IN ('scale','intrinsics_scale','homography')),
    px_per_mm           numeric(12,6),
    intrinsics_json     jsonb,
    homography_json     jsonb,
    hardware_fingerprint text       NOT NULL,
    target_type         text,
    gauge_nominal_mm    numeric(12,4),
    gauge_repeats       integer     CHECK (gauge_repeats IS NULL OR gauge_repeats >= 10),
    gauge_mean_mm       numeric(12,4),
    gauge_sigma_mm      numeric(12,5),
    gauge_max_err_mm    numeric(12,4),
    tolerance_mm        numeric(12,4) NOT NULL DEFAULT 0.2,
    valid               boolean GENERATED ALWAYS AS (
                            gauge_max_err_mm IS NOT NULL AND gauge_max_err_mm <= tolerance_mm
                        ) STORED,
    performed_by        uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    performed_at        timestamptz NOT NULL DEFAULT now(),
    invalidated_at      timestamptz,
    invalidated_reason  text,
    CONSTRAINT calibration_version_unique UNIQUE (camera_id, version)
);

COMMENT ON TABLE vision.calibration IS
  'Per-camera, versioned, gauge-verified pixel-to-mm calibration (ADR-V06). `valid` is generated from the gauge verification: a calibration that was never verified, or whose max error exceeds tolerance, cannot emit measurements.';
COMMENT ON COLUMN vision.calibration.hardware_fingerprint IS
  'camera serial + lens id + mount id. A mismatch at runtime invalidates the calibration and measurements become NO_READ / CALIBRATION_STALE.';
COMMENT ON COLUMN vision.calibration.gauge_repeats IS
  'Minimum 10 repeat measurements of the gauge artefact (SRS-01 AC-03 uses 30).';

CREATE TABLE vision.anomaly_score (
    inspection_id  uuid        NOT NULL,
    inspection_ts  timestamptz NOT NULL,
    model_id       uuid        REFERENCES vision.model_registry(id) ON DELETE SET NULL,
    score          numeric(8,5) NOT NULL,
    threshold      numeric(8,5) NOT NULL,
    flagged        boolean GENERATED ALWAYS AS (score > threshold) STORED,
    heatmap_uri    text,
    PRIMARY KEY (inspection_id, inspection_ts),
    FOREIGN KEY (inspection_id, inspection_ts)
        REFERENCES vision.inspection(id, ts) ON DELETE CASCADE
);

COMMENT ON TABLE vision.anomaly_score IS
  'Out-of-distribution score per frame (SRS-01 AI-06). flagged=true escalates the verdict to REVIEW only, never to FAIL (ADR-V05).';

CREATE TABLE vision.dataset_snapshot (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name           text        NOT NULL UNIQUE,
    purpose        text        NOT NULL DEFAULT 'retrain'
                   CHECK (purpose IN ('retrain','holdout','validation')),
    label_version  text        NOT NULL,
    class_map      jsonb       NOT NULL,
    item_count     integer     NOT NULL DEFAULT 0,
    export_format  text        CHECK (export_format IS NULL OR export_format IN ('coco','yolo')),
    export_uri     text,
    export_sha256  text,
    created_by     uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    frozen_at      timestamptz
);

COMMENT ON TABLE vision.dataset_snapshot IS
  'Immutable labelled set exported for training (SRS-01 FR-15, AI-08). model_registry.trained_from references snapshot.name so every model traces to its exact data. Once frozen_at is set, items may not change.';

CREATE TABLE vision.dataset_item (
    snapshot_id    uuid        NOT NULL REFERENCES vision.dataset_snapshot(id) ON DELETE CASCADE,
    inspection_id  uuid        NOT NULL,
    inspection_ts  timestamptz NOT NULL,
    label_source   text        NOT NULL
                   CHECK (label_source IN ('override','confirmed_review','sampled_pass','manual')),
    labels_json    jsonb       NOT NULL,
    image_sha256   text        NOT NULL,
    PRIMARY KEY (snapshot_id, inspection_id, inspection_ts),
    FOREIGN KEY (inspection_id, inspection_ts)
        REFERENCES vision.inspection(id, ts) ON DELETE RESTRICT
);

COMMENT ON COLUMN vision.dataset_item.image_sha256 IS
  'Hash of the evidence image at snapshot time. The retention sweep must not delete an image referenced by a frozen snapshot (ON DELETE RESTRICT on the inspection is the DB half of that rule).';

CREATE TABLE vision.agreement_stat (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    period_from    timestamptz NOT NULL,
    period_to      timestamptz NOT NULL,
    line_id        uuid        REFERENCES core.line(id) ON DELETE CASCADE,
    sku_id         uuid        REFERENCES core.sku(id) ON DELETE CASCADE,
    class_name     text,
    model_id       uuid        REFERENCES vision.model_registry(id) ON DELETE SET NULL,
    reviewed       integer     NOT NULL,
    agreed         integer     NOT NULL,
    model_fail_human_pass integer NOT NULL DEFAULT 0,
    model_pass_human_fail integer NOT NULL DEFAULT 0,
    agreement_pct  numeric(6,3) GENERATED ALWAYS AS (
                       CASE WHEN reviewed > 0 THEN ROUND(100.0 * agreed / reviewed, 3) ELSE NULL END
                   ) STORED,
    computed_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agreement_counts_consistent CHECK (agreed <= reviewed),
    CONSTRAINT agreement_period_ordered CHECK (period_to > period_from)
);

COMMENT ON TABLE vision.agreement_stat IS
  'Model-vs-human agreement per class and period (SRS-01 FR-16). model_pass_human_fail is the escape-relevant cell and drives the recall gate discussion.';

CREATE TABLE vision.narrative (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind            text        NOT NULL CHECK (kind IN ('shift','daily','adhoc')),
    period_from     timestamptz NOT NULL,
    period_to       timestamptz NOT NULL,
    line_id         uuid        REFERENCES core.line(id) ON DELETE CASCADE,
    shift           core.shift_code,
    lang            core.language_code NOT NULL DEFAULT 'th',
    run_id          uuid        REFERENCES agent.run(id) ON DELETE SET NULL,
    facts_json      jsonb       NOT NULL,
    text            text,
    sources_json    jsonb       NOT NULL DEFAULT '[]'::jsonb,
    grounding_json  jsonb,
    significant     boolean,
    withheld        boolean     NOT NULL DEFAULT false,
    withheld_reason text,
    model           text,
    prompt_version  text,
    delivered_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT narrative_period_ordered CHECK (period_to > period_from),
    CONSTRAINT narrative_withheld_has_reason CHECK (NOT withheld OR withheld_reason IS NOT NULL),
    CONSTRAINT narrative_withheld_has_no_text CHECK (NOT withheld OR text IS NULL)
);

COMMENT ON TABLE vision.narrative IS
  'Generated shift/daily narrative (SRS-01 FR-17..22). facts_json is the sole numeric input to the model; grounding_json is the post-check result. A withheld narrative stores NO text — the constraint makes it impossible to persist an ungrounded narrative and display it later.';
COMMENT ON COLUMN vision.narrative.significant IS
  'From inspection_stats: whether the change vs baseline passed the significance test. When false the narrative must say "within normal variation" and propose no cause (FR-21).';

-- =====================================================================
-- 11. INDEXES
-- =====================================================================

-- core (subset used here)
CREATE INDEX idx_defect_type_code      ON core.defect_type (code) WHERE active;

-- vision (indexes on a partitioned parent propagate to all partitions)
CREATE INDEX idx_inspection_ts        ON vision.inspection (ts DESC);
CREATE INDEX idx_inspection_line_ts   ON vision.inspection (line_id, ts DESC);
CREATE INDEX idx_inspection_verdict   ON vision.inspection (verdict, ts DESC);
CREATE INDEX idx_inspection_sku_ts    ON vision.inspection (sku_id, ts DESC);
CREATE INDEX idx_inspection_lot       ON vision.inspection (lot) WHERE lot IS NOT NULL;
CREATE INDEX idx_inspection_review    ON vision.inspection (ts DESC) WHERE verdict = 'REVIEW';
CREATE INDEX idx_detection_inspection ON vision.detection (inspection_id, inspection_ts);
CREATE INDEX idx_detection_class      ON vision.detection (class_name);
CREATE INDEX idx_measurement_param    ON vision.measurement (parameter, inspection_ts DESC);
CREATE INDEX idx_override_inspection  ON vision.verdict_override (inspection_id, inspection_ts);
CREATE INDEX idx_drift_metric_ts      ON vision.drift_metric (camera_id, ts DESC);

COMMENT ON INDEX vision.idx_inspection_review IS
  'Partial index: the review queue is a small, hot subset of a very large table.';

-- agent
CREATE INDEX idx_run_ts             ON agent.run (ts DESC);
CREATE INDEX idx_run_user_ts        ON agent.run (user_id, ts DESC);
CREATE INDEX idx_run_outcome        ON agent.run (outcome, ts DESC);
CREATE INDEX idx_tool_call_run      ON agent.tool_call (run_id, ordinal);
CREATE INDEX idx_message_conv       ON agent.message (conversation_id, ts);
CREATE INDEX idx_proposal_pending   ON agent.action_proposal (status, expires_at)
                                     WHERE status = 'pending';

-- ops / audit
CREATE INDEX idx_node_heartbeat  ON ops.edge_node (last_heartbeat DESC);
CREATE INDEX idx_node_health_ts  ON ops.node_health (node_id, ts DESC);
CREATE INDEX idx_node_event_ts   ON ops.node_event (node_id, ts DESC);
CREATE INDEX idx_dq_event_ts     ON ops.data_quality_event (ts DESC, severity);
CREATE INDEX idx_audit_ts        ON audit.log (ts DESC);
CREATE INDEX idx_audit_entity    ON audit.log (entity, entity_id, ts DESC);
CREATE INDEX idx_audit_user      ON audit.log (user_id, ts DESC);
CREATE INDEX idx_audit_corr      ON audit.log (correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_auth_event_ts   ON audit.auth_event (ts DESC);

-- VisionOps additions
CREATE INDEX idx_station_line          ON vision.station (line_id, position);
CREATE INDEX idx_calibration_camera    ON vision.calibration (camera_id, version DESC);
CREATE INDEX idx_calibration_valid     ON vision.calibration (camera_id) WHERE valid AND invalidated_at IS NULL;
CREATE INDEX idx_anomaly_flagged       ON vision.anomaly_score (inspection_ts DESC) WHERE flagged;
CREATE INDEX idx_dataset_item_snap     ON vision.dataset_item (snapshot_id);
CREATE INDEX idx_dataset_item_insp     ON vision.dataset_item (inspection_id, inspection_ts);
CREATE INDEX idx_agreement_period      ON vision.agreement_stat (line_id, period_to DESC);
CREATE INDEX idx_narrative_period      ON vision.narrative (line_id, period_to DESC);
CREATE INDEX idx_narrative_withheld    ON vision.narrative (created_at DESC) WHERE withheld;

COMMENT ON INDEX vision.idx_calibration_valid IS
  'Partial index: "the current valid calibration for this camera" is the hot lookup on every measurement.';

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
CREATE TRIGGER trg_station_updated     BEFORE UPDATE ON vision.station
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Frozen snapshots are immutable
CREATE OR REPLACE FUNCTION vision.reject_frozen_snapshot_change()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    frozen timestamptz;
BEGIN
    SELECT frozen_at INTO frozen FROM vision.dataset_snapshot
     WHERE id = COALESCE(NEW.snapshot_id, OLD.snapshot_id);
    IF frozen IS NOT NULL THEN
        RAISE EXCEPTION 'dataset snapshot % is frozen; items are immutable',
            COALESCE(NEW.snapshot_id, OLD.snapshot_id);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_dataset_item_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON vision.dataset_item
    FOR EACH ROW EXECUTE FUNCTION vision.reject_frozen_snapshot_change();

COMMENT ON FUNCTION vision.reject_frozen_snapshot_change() IS
  'SRS-01 AI-08: a model must be reproducible from its snapshot id. A snapshot that can change after export is not a snapshot.';

-- =====================================================================
-- 13. VIEWS
-- =====================================================================

-- ---- byte-identical to the platform (00) ----

CREATE OR REPLACE VIEW vision.v_inspection_daily AS
SELECT
    (i.ts AT TIME ZONE 'UTC')::date            AS insp_date,
    i.line_id,
    i.sku_id,
    COUNT(*)                                   AS inspected,
    COUNT(*) FILTER (WHERE i.verdict = 'FAIL')   AS failed,
    COUNT(*) FILTER (WHERE i.verdict = 'REVIEW') AS in_review,
    COUNT(*) FILTER (WHERE i.verdict = 'NO_READ') AS no_read,
    ROUND(100.0 * COUNT(*) FILTER (WHERE i.verdict = 'FAIL')
          / NULLIF(COUNT(*) FILTER (WHERE i.verdict IN ('PASS','FAIL')), 0), 4) AS defect_rate_pct,
    ROUND(AVG(i.latency_ms), 1)                AS avg_latency_ms
FROM vision.inspection i
GROUP BY 1, 2, 3;

COMMENT ON VIEW vision.v_inspection_daily IS
  'Defect rate excludes REVIEW and NO_READ from the denominator: only parts actually judged PASS or FAIL count.';

CREATE OR REPLACE VIEW vision.v_review_queue AS
SELECT
    i.id, i.ts, i.line_id, i.sku_id, i.lot, i.station,
    i.image_uri, i.overlay_uri, i.model_id,
    (SELECT MAX(d.confidence) FROM vision.detection d
      WHERE d.inspection_id = i.id AND d.inspection_ts = i.ts) AS top_confidence
FROM vision.inspection i
WHERE i.verdict = 'REVIEW'
  AND NOT EXISTS (
      SELECT 1 FROM vision.verdict_override o
      WHERE o.inspection_id = i.id AND o.inspection_ts = i.ts
  );

CREATE OR REPLACE VIEW ops.v_fleet_status AS
SELECT
    n.id, n.node_code, n.state, n.app_version, n.buffer_depth, n.last_heartbeat,
    (now() - n.last_heartbeat)                    AS heartbeat_age,
    (n.last_heartbeat < now() - interval '3 minutes') AS heartbeat_stale,
    l.code                                        AS line_code
FROM ops.edge_node n
LEFT JOIN core.line l ON l.id = n.line_id;

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

-- ---- VisionOps-specific ----

-- Effective verdict = human override if present, else model verdict
CREATE OR REPLACE VIEW vision.v_effective_verdict AS
SELECT
    i.id, i.ts, i.line_id, i.sku_id, i.station, i.lot, i.model_id, i.recipe_id,
    i.verdict                                        AS model_verdict,
    COALESCE(o.new_verdict, i.verdict)               AS effective_verdict,
    (o.id IS NOT NULL)                               AS overridden,
    o.user_id                                        AS overridden_by,
    o.created_at                                     AS overridden_at
FROM vision.inspection i
LEFT JOIN LATERAL (
    SELECT * FROM vision.verdict_override o
    WHERE o.inspection_id = i.id AND o.inspection_ts = i.ts
    ORDER BY o.created_at DESC LIMIT 1
) o ON true;

COMMENT ON VIEW vision.v_effective_verdict IS
  'The verdict of record. KPI views read this, not vision.inspection.verdict, so a human override is reflected everywhere without rewriting history (SRS-01 FR-13/14).';

-- Per-station defect share for a period (feeds station_breakdown tool)
CREATE OR REPLACE VIEW vision.v_station_daily AS
SELECT
    (e.ts AT TIME ZONE 'UTC')::date                     AS insp_date,
    e.line_id,
    e.station,
    COUNT(*) FILTER (WHERE e.effective_verdict IN ('PASS','FAIL')) AS judged,
    COUNT(*) FILTER (WHERE e.effective_verdict = 'FAIL')           AS failed,
    ROUND(100.0 * COUNT(*) FILTER (WHERE e.effective_verdict = 'FAIL')
          / NULLIF(COUNT(*) FILTER (WHERE e.effective_verdict IN ('PASS','FAIL')), 0), 4)
                                                        AS defect_rate_pct
FROM vision.v_effective_verdict e
GROUP BY 1, 2, 3;

-- Per-class defect counts for a period (feeds defect_pareto tool)
CREATE OR REPLACE VIEW vision.v_defect_class_daily AS
SELECT
    (i.ts AT TIME ZONE 'UTC')::date  AS insp_date,
    i.line_id,
    i.sku_id,
    d.class_name,
    COUNT(DISTINCT i.id)             AS parts_affected,
    COUNT(*)                         AS detections
FROM vision.inspection i
JOIN vision.detection d ON d.inspection_id = i.id AND d.inspection_ts = i.ts
JOIN vision.v_effective_verdict e ON e.id = i.id AND e.ts = i.ts
WHERE e.effective_verdict = 'FAIL'
GROUP BY 1, 2, 3, 4;

-- Current valid calibration per camera
CREATE OR REPLACE VIEW vision.v_current_calibration AS
SELECT DISTINCT ON (c.camera_id)
    c.camera_id, c.id AS calibration_id, c.version, c.method, c.px_per_mm,
    c.hardware_fingerprint, c.gauge_max_err_mm, c.tolerance_mm, c.performed_at
FROM vision.calibration c
WHERE c.valid AND c.invalidated_at IS NULL
ORDER BY c.camera_id, c.version DESC;

-- Narrative health
CREATE OR REPLACE VIEW vision.v_narrative_health AS
SELECT
    date_trunc('day', n.created_at)                          AS day,
    COUNT(*)                                                 AS narratives,
    COUNT(*) FILTER (WHERE n.withheld)                       AS withheld,
    COUNT(*) FILTER (WHERE n.significant IS false)           AS within_normal_variation,
    ROUND(100.0 * COUNT(*) FILTER (WHERE n.withheld) / NULLIF(COUNT(*), 0), 3) AS withheld_pct
FROM vision.narrative n
GROUP BY 1;

-- =====================================================================
-- 14. ROLES AND GRANTS
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')      THEN CREATE ROLE app_rw      NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')      THEN CREATE ROLE app_ro      NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_ro')    THEN CREATE ROLE agent_ro    NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'edge_ingest') THEN CREATE ROLE edge_ingest NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_ro')THEN CREATE ROLE analytics_ro NOLOGIN; END IF;
END
$$;

COMMENT ON ROLE app_rw       IS 'Application service account. Full DML except on audit (insert/select only).';
COMMENT ON ROLE agent_ro     IS 'Narrative agent tool layer. SELECT only; never on credentials or scope tables (ADR-V07, SEC).';
COMMENT ON ROLE edge_ingest  IS 'Edge sync endpoint. INSERT into vision only. Cannot read other lines or any other schema.';

GRANT USAGE ON SCHEMA core, vision, agent, ops TO app_rw, app_ro;
GRANT USAGE ON SCHEMA audit TO app_rw, app_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, vision, agent, ops TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO app_rw;

GRANT SELECT ON ALL TABLES IN SCHEMA core, vision, agent, ops, audit TO app_ro;
GRANT USAGE ON SCHEMA core, vision TO analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, vision TO analytics_ro;

-- agent_ro: the six narrative tools read these; never credentials or scope
GRANT USAGE ON SCHEMA core, vision, agent TO agent_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, vision TO agent_ro;
REVOKE SELECT ON core.app_user        FROM agent_ro;
REVOKE SELECT ON core.user_line_scope FROM agent_ro;
GRANT SELECT ON agent.run, agent.tool_call TO agent_ro;

-- edge_ingest: narrowest role in the system
GRANT USAGE ON SCHEMA vision, ops TO edge_ingest;
GRANT INSERT ON vision.inspection, vision.detection, vision.measurement, vision.anomaly_score TO edge_ingest;
GRANT SELECT ON vision.recipe, vision.model_registry, vision.v_current_calibration TO edge_ingest;
GRANT INSERT ON ops.node_event, ops.node_health TO edge_ingest;
GRANT SELECT, UPDATE ON ops.edge_node TO edge_ingest;

ALTER DEFAULT PRIVILEGES IN SCHEMA core, vision, agent, ops
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, vision, agent, ops
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
VALUES ('1.0.0-visionops', 'VisionOps standalone schema (DDS-01 v1.0). vision.* shared tables identical to platform 1.0.0.')
ON CONFLICT (version) DO NOTHING;

-- =====================================================================
-- END OF SCHEMA
-- =====================================================================
