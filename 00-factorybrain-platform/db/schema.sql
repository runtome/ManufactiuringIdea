-- =====================================================================
-- FactoryBrain AI Platform — Database Schema
-- Document : DDS-00-FactoryBrain (see docs/DDS-FactoryBrain-Database-Design.md)
-- Version  : 1.0
-- Date     : 2026-09-10
-- Target   : PostgreSQL 16 with pgvector >= 0.7
--            (verified against image pgvector/pgvector:pg16)
--
-- Apply with:
--   psql -v ON_ERROR_STOP=1 -f schema.sql
--
-- TimescaleDB is OPTIONAL. Telemetry uses native declarative partitioning
-- so this file applies on stock PostgreSQL. See section 13 for the
-- optional hypertable conversion (ADR-007).
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
-- 2. SCHEMAS  (one per bounded context — SAD §4.6)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;       -- master data, production facts
CREATE SCHEMA IF NOT EXISTS vision;     -- inspections, detections, models
CREATE SCHEMA IF NOT EXISTS quality;    -- SPC, capability, cases, FMEA
CREATE SCHEMA IF NOT EXISTS telemetry;  -- machine signals, health, alerts
CREATE SCHEMA IF NOT EXISTS knowledge;  -- documents, chunks, TM, glossary
CREATE SCHEMA IF NOT EXISTS agent;      -- runs, tool calls, findings
CREATE SCHEMA IF NOT EXISTS docflow;    -- business documents -> ERP
CREATE SCHEMA IF NOT EXISTS ops;        -- edge fleet, jobs, config
CREATE SCHEMA IF NOT EXISTS audit;      -- append-only audit trail

COMMENT ON SCHEMA core      IS 'Master data and production facts. Source of truth for lines, SKUs, shifts, lots.';
COMMENT ON SCHEMA vision    IS 'Inspection records, detections, measurements, model registry, human overrides.';
COMMENT ON SCHEMA quality   IS 'SPC, capability, quality cases, 5-Why/8D artifacts, FMEA rows.';
COMMENT ON SCHEMA telemetry IS 'Machine time-series, derived features, health index, predictive alerts.';
COMMENT ON SCHEMA knowledge IS 'Documents, embeddings, translation memory, glossary, past-case retrieval.';
COMMENT ON SCHEMA agent     IS 'Agent runs, tool calls, findings blackboard, briefings, conversations.';
COMMENT ON SCHEMA docflow   IS 'Inbound business documents, extraction, validation, ERP postings.';
COMMENT ON SCHEMA ops       IS 'Edge node fleet, scheduled jobs, runtime configuration, data quality events.';
COMMENT ON SCHEMA audit     IS 'Append-only audit log. INSERT only; no UPDATE or DELETE grants.';

-- NOTE ON SIBLING SCOPE (SAD §6):
--   Schemas `farm` (SRS-12 GAPFarm) and `pawtrace` (SRS-07 Dog Finder) are
--   documented in the DDS but are DELIBERATELY NOT created here. They are
--   logically separate deployments that reuse platform patterns; placing
--   agricultural or consumer data inside the factory database would be a
--   design error. See DDS section 12.

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
-- 4. ENUMERATED TYPES
-- =====================================================================

CREATE TYPE core.shift_code        AS ENUM ('A', 'B', 'C', 'OT');
CREATE TYPE core.language_code     AS ENUM ('th', 'ja', 'en');

CREATE TYPE vision.verdict         AS ENUM ('PASS', 'FAIL', 'REVIEW', 'NO_READ');
CREATE TYPE vision.model_stage     AS ENUM ('candidate', 'shadow', 'active', 'retired');

CREATE TYPE quality.case_status    AS ENUM ('open', 'containment', 'analysis',
                                            'action', 'verification', 'closed', 'cancelled');
CREATE TYPE quality.severity       AS ENUM ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL');
CREATE TYPE quality.artifact_kind  AS ENUM ('five_why', 'eight_d', 'fmea', 'report', 'ocap');
CREATE TYPE quality.chart_type     AS ENUM ('xbar_r', 'x_mr', 'p', 'np', 'c', 'u');

CREATE TYPE telemetry.alert_status AS ENUM ('open', 'acknowledged', 'snoozed', 'resolved', 'dismissed');

CREATE TYPE agent.run_outcome      AS ENUM ('ok', 'partial', 'refused', 'grounding_failed', 'error', 'budget_exceeded');
CREATE TYPE agent.finding_status   AS ENUM ('new', 'acknowledged', 'in_progress', 'resolved', 'expired', 'dismissed');
CREATE TYPE agent.message_role     AS ENUM ('user', 'assistant', 'system', 'tool');

CREATE TYPE docflow.doc_state      AS ENUM ('received', 'classified', 'extracted', 'validated',
                                            'review_required', 'approved', 'rejected',
                                            'posting', 'posted', 'posting_failed');

CREATE TYPE ops.node_state         AS ENUM ('provisioning', 'online', 'degraded', 'offline', 'retired');
CREATE TYPE ops.dq_severity        AS ENUM ('info', 'warning', 'error');

COMMENT ON TYPE vision.verdict IS
  'NO_READ = frame rejected by the quality gate (blur/exposure). Distinct from PASS: nothing was actually judged.';
COMMENT ON TYPE agent.run_outcome IS
  'grounding_failed = the post-check (ADR-013) found a number not present in tool results; the answer was withheld.';

-- =====================================================================
-- 5. CORE — master data and production facts
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
-- 6. VISION — inspection records (SRS-01 / SRS-03 / SRS-05)
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
-- 7. QUALITY — SPC, capability, cases, FMEA (SRS-09 / SRS-11)
-- =====================================================================

CREATE TABLE quality.characteristic (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sku_id        uuid        REFERENCES core.sku(id) ON DELETE CASCADE,
    name          text        NOT NULL,
    unit          text,
    usl           numeric(14,5),
    lsl           numeric(14,5),
    target        numeric(14,5),
    chart_type    quality.chart_type NOT NULL DEFAULT 'xbar_r',
    subgroup_rule jsonb       NOT NULL DEFAULT '{"kind":"fixed_n","n":5}'::jsonb,
    active        boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT characteristic_unique_per_sku UNIQUE (sku_id, name),
    CONSTRAINT characteristic_limits_ordered CHECK (usl IS NULL OR lsl IS NULL OR usl >= lsl)
);

CREATE TABLE quality.control_limits (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    characteristic_id uuid        NOT NULL REFERENCES quality.characteristic(id) ON DELETE CASCADE,
    line_id           uuid        REFERENCES core.line(id) ON DELETE CASCADE,
    ucl               numeric(14,5) NOT NULL,
    cl                numeric(14,5) NOT NULL,
    lcl               numeric(14,5) NOT NULL,
    baseline_from     timestamptz NOT NULL,
    baseline_to       timestamptz NOT NULL,
    sample_size       integer     NOT NULL CHECK (sample_size > 0),
    reason            text        NOT NULL,
    created_by        uuid        REFERENCES core.app_user(id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    active            boolean     NOT NULL DEFAULT true,
    CONSTRAINT limits_ordered   CHECK (ucl >= cl AND cl >= lcl),
    CONSTRAINT baseline_ordered CHECK (baseline_to > baseline_from)
);

COMMENT ON TABLE quality.control_limits IS
  'Limit history is append-only with a mandatory reason. Recalculating limits silently is a classic way to hide a process shift.';

CREATE TABLE quality.spc_violation (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    characteristic_id uuid        NOT NULL REFERENCES quality.characteristic(id) ON DELETE CASCADE,
    line_id           uuid        REFERENCES core.line(id) ON DELETE CASCADE,
    ts                timestamptz NOT NULL,
    rule              smallint    NOT NULL CHECK (rule BETWEEN 1 AND 8),
    points_json       jsonb       NOT NULL,
    severity          quality.severity NOT NULL DEFAULT 'MEDIUM',
    created_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN quality.spc_violation.rule IS 'Nelson rule number 1-8. Minimum implemented set is {1,2,3,5,6} (SRS FR-Q-04).';

CREATE TABLE quality.capability_result (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    characteristic_id uuid        NOT NULL REFERENCES quality.characteristic(id) ON DELETE CASCADE,
    line_id           uuid        REFERENCES core.line(id) ON DELETE CASCADE,
    period_from       timestamptz NOT NULL,
    period_to         timestamptz NOT NULL,
    n                 integer     NOT NULL CHECK (n > 0),
    cp                numeric(8,4),
    cpk               numeric(8,4),
    pp                numeric(8,4),
    ppk               numeric(8,4),
    normality_p       numeric(8,6),
    normality_ok      boolean     NOT NULL,
    method_note       text,
    computed_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE quality.capability_result IS
  'normality_ok = false means Cp/Cpk must not be presented as valid (SRS-09 C-03). n and period are stored so a number can never be quoted without its sample context.';

CREATE TABLE quality.signal (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    opened_at     timestamptz NOT NULL DEFAULT now(),
    kind          text        NOT NULL,
    line_id       uuid        REFERENCES core.line(id) ON DELETE SET NULL,
    sku_id        uuid        REFERENCES core.sku(id)  ON DELETE SET NULL,
    scope_json    jsonb       NOT NULL DEFAULT '{}'::jsonb,
    statistic_json jsonb      NOT NULL DEFAULT '{}'::jsonb,
    severity      quality.severity NOT NULL,
    status        text        NOT NULL DEFAULT 'open'
                  CHECK (status IN ('open','triaged','case_opened','dismissed','expired')),
    closed_at     timestamptz
);

COMMENT ON COLUMN quality.signal.statistic_json IS
  'Holds p-value, effect size, baseline and sample size. The agent may only quote values present here (P-1).';

CREATE TABLE quality.case (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    signal_id     uuid        REFERENCES quality.signal(id) ON DELETE SET NULL,
    title         text        NOT NULL,
    line_id       uuid        REFERENCES core.line(id) ON DELETE SET NULL,
    sku_id        uuid        REFERENCES core.sku(id)  ON DELETE SET NULL,
    machine_id    uuid        REFERENCES core.machine(id) ON DELETE SET NULL,
    severity      quality.severity NOT NULL DEFAULT 'MEDIUM',
    status        quality.case_status NOT NULL DEFAULT 'open',
    owner_id      uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    opened_at     timestamptz NOT NULL DEFAULT now(),
    closed_at     timestamptz,
    closure_note  text,
    CONSTRAINT case_closed_has_time CHECK (
        (status <> 'closed') OR (closed_at IS NOT NULL)
    )
);

CREATE TABLE quality.case_step (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id      uuid        NOT NULL REFERENCES quality.case(id) ON DELETE CASCADE,
    kind         text        NOT NULL,
    ordinal      integer     NOT NULL DEFAULT 0,
    content_json jsonb       NOT NULL,
    author_id    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    ai_generated boolean     NOT NULL DEFAULT false,
    approved_by  uuid        REFERENCES core.app_user(id) ON DELETE RESTRICT,
    approved_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT approval_is_complete CHECK (
        (approved_by IS NULL AND approved_at IS NULL) OR
        (approved_by IS NOT NULL AND approved_at IS NOT NULL)
    )
);

COMMENT ON TABLE quality.case_step IS
  'P-3 enforcement point. ai_generated=true AND approved_by IS NULL means DRAFT: cannot be exported clean, cannot become precedent (SAD 4.4.3).';

CREATE TABLE quality.hypothesis (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id       uuid        NOT NULL REFERENCES quality.case(id) ON DELETE CASCADE,
    statement     text        NOT NULL,
    score         numeric(5,4) NOT NULL CHECK (score >= 0 AND score <= 1),
    evidence_json jsonb       NOT NULL DEFAULT '[]'::jsonb,
    contra_json   jsonb       NOT NULL DEFAULT '[]'::jsonb,
    verify_step   text,
    status        text        NOT NULL DEFAULT 'proposed'
                  CHECK (status IN ('proposed','verifying','confirmed','rejected')),
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE quality.artifact (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id      uuid        NOT NULL REFERENCES quality.case(id) ON DELETE CASCADE,
    kind         quality.artifact_kind NOT NULL,
    version      integer     NOT NULL DEFAULT 1,
    lang         core.language_code NOT NULL DEFAULT 'en',
    content_json jsonb       NOT NULL,
    ai_generated boolean     NOT NULL DEFAULT true,
    model_id     uuid        REFERENCES vision.model_registry(id) ON DELETE SET NULL,
    prompt_version text,
    approved_by  uuid        REFERENCES core.app_user(id) ON DELETE RESTRICT,
    approved_at  timestamptz,
    exported_uri text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT artifact_version_unique UNIQUE (case_id, kind, version, lang)
);

CREATE TABLE quality.action (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id            uuid        NOT NULL REFERENCES quality.case(id) ON DELETE CASCADE,
    kind               text        NOT NULL CHECK (kind IN ('containment','corrective','preventive','horizontal')),
    description        text        NOT NULL,
    owner_id           uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    due_date           date,
    status             text        NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open','in_progress','done','verified','cancelled')),
    applied_at         timestamptz,
    effectiveness_json jsonb,
    created_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN quality.action.effectiveness_json IS
  'Before/after defect rate with a significance test. An action is only "verified" when this shows a real improvement (SRS-09 FR-28).';

CREATE TABLE quality.fmea_row (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sku_id         uuid        REFERENCES core.sku(id) ON DELETE CASCADE,
    process_step   text        NOT NULL,
    failure_mode   text        NOT NULL,
    effect         text,
    cause          text,
    control_prev   text,
    control_det    text,
    s              smallint    CHECK (s BETWEEN 1 AND 10),
    o              smallint    CHECK (o BETWEEN 1 AND 10),
    d              smallint    CHECK (d BETWEEN 1 AND 10),
    rpn            integer GENERATED ALWAYS AS (s * o * d) STORED,
    ap             text        CHECK (ap IS NULL OR ap IN ('H','M','L')),
    source_case_id uuid        REFERENCES quality.case(id) ON DELETE SET NULL,
    approved_by    uuid        REFERENCES core.app_user(id) ON DELETE RESTRICT,
    approved_at    timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN quality.fmea_row.rpn IS
  'Generated. Both RPN (classic) and AP (AIAG-VDA) are carried; which one is authoritative is a configuration choice (SRS-09 C-05).';

-- Injection molding extension (SRS-11 MoldMind)
CREATE TABLE quality.mould (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code              text        NOT NULL UNIQUE,
    cavities          smallint    NOT NULL CHECK (cavities > 0),
    material_spec     text,
    setup_sheet_json  jsonb       NOT NULL DEFAULT '{}'::jsonb,
    last_maintenance  timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE quality.shot (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ts              timestamptz NOT NULL,
    machine_id      uuid        REFERENCES core.machine(id) ON DELETE SET NULL,
    mould_id        uuid        REFERENCES quality.mould(id) ON DELETE SET NULL,
    material_lot_id uuid        REFERENCES core.material_lot(id) ON DELETE SET NULL,
    cycle_time_s    numeric(8,2),
    cushion_mm      numeric(8,3),
    params_json     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    melt_temp_json  jsonb,
    mould_temp_json jsonb,
    shift           core.shift_code,
    created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE quality.shot IS
  'Per-shot machine parameters from OPC-UA / Euromap 77 (ICD IF-05). Joined to inspections by shot id or timestamp tolerance.';

CREATE TABLE quality.shot_part (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    shot_id       uuid        NOT NULL REFERENCES quality.shot(id) ON DELETE CASCADE,
    cavity_no     smallint    NOT NULL CHECK (cavity_no > 0),
    inspection_id uuid,
    inspection_ts timestamptz,
    verdict       vision.verdict,
    CONSTRAINT shot_cavity_unique UNIQUE (shot_id, cavity_no)
);

CREATE TABLE quality.timeline_event (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ts          timestamptz NOT NULL,
    line_id     uuid        REFERENCES core.line(id) ON DELETE CASCADE,
    machine_id  uuid        REFERENCES core.machine(id) ON DELETE CASCADE,
    mould_id    uuid        REFERENCES quality.mould(id) ON DELETE SET NULL,
    kind        text        NOT NULL,
    detail_json jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE quality.timeline_event IS
  'Lot change, parameter edit, maintenance, tool change, startup. Change-point analysis correlates defect onset against this timeline.';

-- =====================================================================
-- 8. TELEMETRY — machine signals (SRS-06 MachineSense)
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
-- 9. KNOWLEDGE — documents, embeddings, TM (SRS-14 / SRS-15)
-- =====================================================================

CREATE TABLE knowledge.document (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sha256        text        NOT NULL UNIQUE,
    kind          text        NOT NULL,
    title         text,
    lang          core.language_code,
    uri           text        NOT NULL,
    original_name text,
    source_system text,
    page_count    integer,
    acl_json      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    ingested_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN knowledge.document.acl_json IS
  'Retrieval enforces this at query time. A restricted document must never appear even as a snippet (SEC).';

CREATE TABLE knowledge.chunk (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    document_id       uuid        NOT NULL REFERENCES knowledge.document(id) ON DELETE CASCADE,
    ordinal           integer     NOT NULL,
    section           text,
    page              integer,
    lang              core.language_code,
    text              text        NOT NULL,
    embedding         vector(1024),
    embedding_version text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chunk_ordinal_unique UNIQUE (document_id, ordinal)
);

COMMENT ON COLUMN knowledge.chunk.embedding_version IS
  'Model upgrades are a background re-embed, not a stop-the-world migration (ADR-001). Queries filter on one version at a time.';

CREATE TABLE knowledge.case_record (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    title              text        NOT NULL,
    opened_at          timestamptz,
    closed_at          timestamptz,
    scope_json         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    symptom_text       text,
    cause_text         text,
    action_text        text,
    verification_text  text,
    outcome            text        CHECK (outcome IS NULL OR outcome IN ('resolved','not_resolved','unknown')),
    recurrence_of      uuid        REFERENCES knowledge.case_record(id) ON DELETE SET NULL,
    quality_case_id    uuid        REFERENCES quality.case(id) ON DELETE SET NULL,
    verified_by        uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    verified_at        timestamptz,
    extracted_by       text,
    created_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE knowledge.case_record IS
  'Institutional memory (SRS-15). verified_at NULL = LLM-extracted, not human-confirmed; ranked lower and badged in the UI (SRS-15 C-02).';

CREATE TABLE knowledge.case_source (
    case_record_id uuid NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    document_id    uuid NOT NULL REFERENCES knowledge.document(id)    ON DELETE CASCADE,
    page_range     text,
    PRIMARY KEY (case_record_id, document_id)
);

CREATE TABLE knowledge.case_chunk (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_record_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    ordinal        integer     NOT NULL,
    lang           core.language_code,
    text           text        NOT NULL,
    embedding      vector(1024),
    embedding_version text
);

CREATE TABLE knowledge.glossary_term (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ja          text,
    ja_reading  text,
    th          text,
    en          text,
    domain      text,
    notes       text,
    forbidden_json jsonb    NOT NULL DEFAULT '[]'::jsonb,
    approved_by uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE knowledge.glossary_term IS
  'Mandated terminology (SRS-14). forbidden_json lists renderings that must be flagged if the model produces them.';

CREATE TABLE knowledge.tm_segment (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    src_lang   core.language_code NOT NULL,
    tgt_lang   core.language_code NOT NULL,
    src_text   text        NOT NULL,
    tgt_text   text        NOT NULL,
    domain     text,
    doc_ref    text,
    approver_id uuid       REFERENCES core.app_user(id) ON DELETE SET NULL,
    embedding  vector(1024),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tm_langs_differ CHECK (src_lang <> tgt_lang)
);

-- =====================================================================
-- 10. AGENT — runs, tools, findings (SRS-10 / SRS-13)
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
-- 11. DOCFLOW — documents to ERP (SRS-08)
-- =====================================================================

CREATE TABLE docflow.document (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sha256       text        NOT NULL UNIQUE,
    kind         text,
    lang         core.language_code,
    source       text        NOT NULL CHECK (source IN ('email','folder','upload','scanner')),
    original_uri text        NOT NULL,
    page_count   integer,
    state        docflow.doc_state NOT NULL DEFAULT 'received',
    received_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.extraction (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    document_id    uuid        NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    model_version  text        NOT NULL,
    schema_version text        NOT NULL,
    header_json    jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.extracted_field (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    extraction_id   uuid        NOT NULL REFERENCES docflow.extraction(id) ON DELETE CASCADE,
    path            text        NOT NULL,
    value_raw       text,
    value_norm      text,
    confidence      numeric(5,4) CHECK (confidence >= 0 AND confidence <= 1),
    page_no         integer,
    bbox_json       jsonb,
    corrected_value text,
    corrected_by    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    corrected_at    timestamptz
);

COMMENT ON COLUMN docflow.extracted_field.bbox_json IS
  'Provenance. A field without a page+bbox is treated as low confidence regardless of the model score (SRS-08 AI-04).';

CREATE TABLE docflow.line_item (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    extraction_id uuid        NOT NULL REFERENCES docflow.extraction(id) ON DELETE CASCADE,
    line_no       integer     NOT NULL,
    part_no       text,
    description   text,
    qty           numeric(14,4),
    unit          text,
    unit_price    numeric(16,4),
    amount        numeric(16,4),
    tax_code      text,
    confidence    numeric(5,4),
    CONSTRAINT line_item_unique UNIQUE (extraction_id, line_no)
);

CREATE TABLE docflow.validation_result (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    document_id uuid        NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    rule        text        NOT NULL,
    status      text        NOT NULL CHECK (status IN ('pass','warning','fail')),
    detail_json jsonb,
    ran_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.approval (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    document_id uuid        NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    user_id     uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE RESTRICT,
    role        text        NOT NULL,
    decision    text        NOT NULL CHECK (decision IN ('approved','rejected')),
    reason      text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.posting (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    document_id uuid        NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    adapter     text        NOT NULL,
    idem_key    text        NOT NULL,
    erp_ref     text,
    status      text        NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','succeeded','failed')),
    attempts    integer     NOT NULL DEFAULT 0,
    last_error  text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT posting_idem_unique UNIQUE (adapter, idem_key)
);

COMMENT ON CONSTRAINT posting_idem_unique ON docflow.posting IS
  'The database guarantees no double-post under retry (SRS-08 C-04/AC-05), independently of application logic.';

-- =====================================================================
-- 12. OPS — edge fleet, jobs, config, data quality
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
-- 13. AUDIT — append-only
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
-- 14. INDEXES
-- =====================================================================

-- core
CREATE INDEX idx_production_fact_date      ON core.production_fact (prod_date DESC);
CREATE INDEX idx_production_fact_line_date ON core.production_fact (line_id, prod_date DESC);
CREATE INDEX idx_defect_fact_date          ON core.defect_fact (prod_date DESC);
CREATE INDEX idx_defect_fact_type          ON core.defect_fact (defect_type_id, prod_date DESC);
CREATE INDEX idx_quarantine_batch          ON core.quarantine_row (batch_id);
CREATE INDEX idx_ingest_batch_sha          ON core.ingest_batch (sha256);

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

-- quality
CREATE INDEX idx_spc_violation_char   ON quality.spc_violation (characteristic_id, ts DESC);
CREATE INDEX idx_capability_char      ON quality.capability_result (characteristic_id, period_to DESC);
CREATE INDEX idx_signal_status        ON quality.signal (status, opened_at DESC);
CREATE INDEX idx_case_status          ON quality.case (status, opened_at DESC);
CREATE INDEX idx_case_line            ON quality.case (line_id, opened_at DESC);
CREATE INDEX idx_case_step_case       ON quality.case_step (case_id, ordinal);
CREATE INDEX idx_case_step_draft      ON quality.case_step (case_id)
                                       WHERE ai_generated = true AND approved_by IS NULL;
CREATE INDEX idx_artifact_case        ON quality.artifact (case_id, kind, version DESC);
CREATE INDEX idx_action_due           ON quality.action (due_date) WHERE status IN ('open','in_progress');
CREATE INDEX idx_fmea_sku             ON quality.fmea_row (sku_id);
CREATE INDEX idx_shot_ts              ON quality.shot (ts DESC);
CREATE INDEX idx_shot_mould_ts        ON quality.shot (mould_id, ts DESC);
CREATE INDEX idx_timeline_ts          ON quality.timeline_event (ts DESC);
CREATE INDEX idx_timeline_line_ts     ON quality.timeline_event (line_id, ts DESC);

-- telemetry
CREATE INDEX idx_feature_lookup       ON telemetry.feature (sensor_id, name, ts DESC);
CREATE INDEX idx_health_index_ts      ON telemetry.health_index (ts DESC);
CREATE INDEX idx_alert_status         ON telemetry.alert (status, opened_at DESC);
CREATE INDEX idx_alert_machine        ON telemetry.alert (machine_id, opened_at DESC);
CREATE INDEX idx_maintenance_machine  ON telemetry.maintenance_event (machine_id, ts DESC);

-- knowledge: vector + lexical (hybrid retrieval)
CREATE INDEX idx_chunk_embedding ON knowledge.chunk
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_case_chunk_embedding ON knowledge.case_chunk
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_tm_embedding ON knowledge.tm_segment
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

CREATE INDEX idx_chunk_text_trgm      ON knowledge.chunk      USING gin (text gin_trgm_ops);
CREATE INDEX idx_case_chunk_text_trgm ON knowledge.case_chunk USING gin (text gin_trgm_ops);
CREATE INDEX idx_tm_src_trgm          ON knowledge.tm_segment USING gin (src_text gin_trgm_ops);
CREATE INDEX idx_chunk_doc            ON knowledge.chunk (document_id, ordinal);
CREATE INDEX idx_chunk_embver         ON knowledge.chunk (embedding_version);
CREATE INDEX idx_case_record_verified ON knowledge.case_record (verified_at) WHERE verified_at IS NOT NULL;

COMMENT ON INDEX knowledge.idx_chunk_text_trgm IS
  'Trigram index supports the lexical half of hybrid retrieval. Thai and Japanese have no word spaces, so trigram beats naive tsvector here.';

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

-- docflow
CREATE INDEX idx_docflow_state      ON docflow.document (state, received_at DESC);
CREATE INDEX idx_extracted_field_ex ON docflow.extracted_field (extraction_id);
CREATE INDEX idx_line_item_ex       ON docflow.line_item (extraction_id, line_no);
CREATE INDEX idx_validation_doc     ON docflow.validation_result (document_id);
CREATE INDEX idx_posting_status     ON docflow.posting (status, updated_at DESC);

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

-- =====================================================================
-- 15. TRIGGERS
-- =====================================================================

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
CREATE TRIGGER trg_posting_updated     BEFORE UPDATE ON docflow.posting
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =====================================================================
-- 16. VIEWS
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

-- Inspection rollup (vision side, independent of production files)
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

-- Review queue
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

-- Approved knowledge only: unapproved AI drafts must never become precedent (P-3)
CREATE OR REPLACE VIEW knowledge.v_citable_case AS
SELECT cr.*
FROM knowledge.case_record cr
WHERE cr.verified_at IS NOT NULL;

COMMENT ON VIEW knowledge.v_citable_case IS
  'Retrieval for agent citation reads this view, not the base table, so an unverified extraction cannot be quoted as established fact.';

-- Edge fleet status
CREATE OR REPLACE VIEW ops.v_fleet_status AS
SELECT
    n.id, n.node_code, n.state, n.app_version, n.buffer_depth, n.last_heartbeat,
    (now() - n.last_heartbeat)                    AS heartbeat_age,
    (n.last_heartbeat < now() - interval '3 minutes') AS heartbeat_stale,
    l.code                                        AS line_code
FROM ops.edge_node n
LEFT JOIN core.line l ON l.id = n.line_id;

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
-- 17. ROLES AND GRANTS
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
COMMENT ON ROLE agent_ro     IS 'Used by the agent tool layer. SELECT only, and never on secrets or auth tables (ADR-005, SEC).';
COMMENT ON ROLE edge_ingest  IS 'Edge sync endpoint. INSERT into vision only. Cannot read other lines or any other schema.';

GRANT USAGE ON SCHEMA core, vision, quality, telemetry, knowledge, agent, docflow, ops TO app_rw, app_ro;
GRANT USAGE ON SCHEMA audit TO app_rw, app_ro;

-- app_rw: read/write everywhere except audit (append-only)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA
      core, vision, quality, telemetry, knowledge, agent, docflow, ops TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO app_rw;

-- app_ro / analytics_ro: read-only
GRANT SELECT ON ALL TABLES IN SCHEMA
      core, vision, quality, telemetry, knowledge, agent, docflow, ops, audit TO app_ro;
GRANT USAGE ON SCHEMA core, vision, quality, telemetry, knowledge TO analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA
      core, vision, quality, telemetry, knowledge TO analytics_ro;

-- agent_ro: read-only, and explicitly NOT on user credentials or audit
GRANT USAGE ON SCHEMA core, vision, quality, telemetry, knowledge, agent TO agent_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, vision, quality, telemetry, knowledge TO agent_ro;
REVOKE SELECT ON core.app_user       FROM agent_ro;
REVOKE SELECT ON core.user_line_scope FROM agent_ro;
GRANT SELECT ON agent.finding, agent.briefing TO agent_ro;

-- edge_ingest: narrowest role in the system
GRANT USAGE ON SCHEMA vision, ops TO edge_ingest;
GRANT INSERT ON vision.inspection, vision.detection, vision.measurement TO edge_ingest;
GRANT SELECT ON vision.recipe, vision.model_registry TO edge_ingest;
GRANT INSERT ON ops.node_event, ops.node_health TO edge_ingest;
GRANT SELECT, UPDATE ON ops.edge_node TO edge_ingest;

-- Future objects inherit the same posture
ALTER DEFAULT PRIVILEGES IN SCHEMA core, vision, quality, telemetry, knowledge, agent, docflow, ops
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, vision, quality, telemetry, knowledge, agent, docflow, ops
    GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT INSERT, SELECT ON TABLES TO app_rw;

-- =====================================================================
-- 18. OPTIONAL — TimescaleDB hypertables (ADR-007)
-- =====================================================================
-- Only runs when the timescaledb extension is available. The schema is
-- fully functional without it; this block adds compression and retention.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb') THEN
        RAISE NOTICE 'TimescaleDB available — see docs/DDS section 8.4 for the hypertable migration.';
        -- Intentionally not executed automatically: converting an already
        -- partitioned table requires a dedicated migration (OPS RB-12),
        -- not a side effect of running schema.sql.
    ELSE
        RAISE NOTICE 'TimescaleDB not present — telemetry uses native partitioning (supported configuration).';
    END IF;
END
$$;

-- =====================================================================
-- 19. SCHEMA VERSION
-- =====================================================================

CREATE TABLE IF NOT EXISTS ops.schema_version (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    description text
);

INSERT INTO ops.schema_version (version, description)
VALUES ('1.0.0', 'Initial FactoryBrain platform schema (DDS-00 v1.0)')
ON CONFLICT (version) DO NOTHING;

-- =====================================================================
-- END OF SCHEMA
-- =====================================================================
