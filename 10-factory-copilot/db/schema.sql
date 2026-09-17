-- =====================================================================
--  Factory Copilot — PostgreSQL 16 schema (standalone deployment)
--  DDS-10-Copilot v1.0 (Draft) · 2026-09-17 · Suphot N.
--
--  Sections 1–9 are EXTRACTED VERBATIM from ../../00-factorybrain-platform/db/schema.sql
--  (extensions, helpers, enums, the whole core / vision / quality / knowledge / agent
--  sections, audit, their indexes, triggers and views). TEST-10 TC-002 diffs every block
--  against the platform file; a difference is a defect in this file, never in the platform's.
--  Sections 10–17 are the Copilot extension (schema copilot, migration copilot_0001).
--
--  Platform mode (SAD-10 §9): apply ONLY sections 10–17 (migration copilot_0001) on the
--  platform database; sections 1–9 already exist there.
--
--  NOT EXECUTED on the authoring machine (no PostgreSQL) — TEST-10 TC-009.
-- =====================================================================

-- =====================================================================
-- 1. EXTENSIONS  [platform lines 23–26]
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_bytes, digest
CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector: embeddings
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- trigram search (hybrid retrieval)
CREATE EXTENSION IF NOT EXISTS btree_gin;     -- composite GIN indexes

-- =====================================================================
-- 2. SCHEMAS
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS vision;
CREATE SCHEMA IF NOT EXISTS quality;
CREATE SCHEMA IF NOT EXISTS knowledge;
CREATE SCHEMA IF NOT EXISTS agent;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS copilot;

COMMENT ON SCHEMA copilot IS
  'Factory Copilot extension (SRS-10). Conversations, messages, runs, tool calls and feedback stay in the platform schema agent; copilot holds understanding, evidence, sandbox, sharing, curation and evaluation.';

-- =====================================================================
-- 3. HELPER FUNCTIONS  [platform lines 63–104]
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
-- 4. ENUMERATED TYPES  [platform section 4 — the types the extracted sections use]
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
CREATE TYPE agent.run_outcome      AS ENUM ('ok', 'partial', 'refused', 'grounding_failed', 'error', 'budget_exceeded');
CREATE TYPE agent.finding_status   AS ENUM ('new', 'acknowledged', 'in_progress', 'resolved', 'expired', 'dismissed');
CREATE TYPE agent.message_role     AS ENUM ('user', 'assistant', 'system', 'tool');
COMMENT ON TYPE vision.verdict IS
  'NO_READ = frame rejected by the quality gate (blur/exposure). Distinct from PASS: nothing was actually judged.';
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
-- 6. VISION — inspection records  [platform section 6, verbatim]
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
-- 7. QUALITY — SPC, capability, cases, FMEA  [platform section 7, verbatim]
--    Needed because knowledge.case_record references quality.case and because
--    get_signals / get_case / get_hypotheses (QE-Agent) read these tables.
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
-- 8. KNOWLEDGE — documents, embeddings, cases, glossary, TM  [platform section 9, verbatim]
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
-- 9. AGENT — tools, conversations, messages, runs, tool calls, findings, feedback  [platform section 10, verbatim]
--    agent.run is SRS-10 §5 turn_trace; agent.conversation / agent.message / agent.feedback are the SRS tables of the same name.
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
-- 9a. AUDIT  [platform section 13, verbatim]
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
-- 9b. PLATFORM INDEXES, TRIGGERS AND VIEWS  [verbatim]
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

-- knowledge: vector + lexical (hybrid retrieval)
CREATE INDEX idx_chunk_embedding ON knowledge.chunk
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_case_chunk_embedding ON knowledge.case_chunk
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_tm_embedding ON knowledge.tm_segment
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

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

-- Approved knowledge only: unapproved AI drafts must never become precedent (P-3)
CREATE OR REPLACE VIEW knowledge.v_citable_case AS
SELECT cr.*
FROM knowledge.case_record cr
WHERE cr.verified_at IS NOT NULL;

COMMENT ON VIEW knowledge.v_citable_case IS
  'Retrieval for agent citation reads this view, not the base table, so an unverified extraction cannot be quoted as established fact.';

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
-- 10. COPILOT — types
-- =====================================================================

CREATE TYPE copilot.intent         AS ENUM ('data_lookup', 'trend_comparison', 'cause_analysis', 'document_lookup', 'image_lookup', 'how_to');
CREATE TYPE copilot.evidence_kind  AS ENUM ('tool', 'document', 'curated', 'hypothesis', 'sql', 'image');
CREATE TYPE copilot.share_format   AS ENUM ('link', 'png', 'pdf');
CREATE TYPE copilot.index_state    AS ENUM ('queued', 'running', 'done', 'failed', 'skipped');
CREATE TYPE copilot.flag_status    AS ENUM ('open', 'corrected', 'dismissed');
CREATE TYPE copilot.run_mode       AS ENUM ('full', 'dashboards_only');

COMMENT ON TYPE copilot.intent IS 'SRS-10 FR-04. cause_analysis is delegated to QE-Agent (FR-21) — see trg_cause_delegated.';

-- Normalise text for alias matching: lower-case, fullwidth digits/letters → ASCII, Thai digits → ASCII, collapse spaces.
CREATE OR REPLACE FUNCTION copilot.norm_text(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(
             lower(translate(coalesce(t, ''),
                   '０１２３４５６７８９๐๑๒๓๔๕๖๗๘๙ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ',
                   '01234567890123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz')),
             '\s+', '', 'g');
$$;

-- Injection flag on platform chunks (AI-07 / AC-05): data-only marking, never an instruction.
ALTER TABLE knowledge.chunk ADD COLUMN suspicious boolean NOT NULL DEFAULT false;
ALTER TABLE knowledge.chunk ADD COLUMN suspicious_reason text;

-- =====================================================================
-- 11. COPILOT — configuration and policy tables
-- =====================================================================

CREATE TABLE copilot.migration (
    id          text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    note        text
);

CREATE TABLE copilot.feature_flag (
    key         text PRIMARY KEY CHECK (key IN ('text_to_sql', 'discord', 'external_model', 'image_similarity')),
    enabled     boolean     NOT NULL DEFAULT false,
    enabled_by  uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    enabled_at  timestamptz,
    reason      text,
    CONSTRAINT flag_enable_is_recorded CHECK (NOT enabled OR (enabled_by IS NOT NULL AND enabled_at IS NOT NULL AND reason IS NOT NULL))
);

COMMENT ON TABLE copilot.feature_flag IS
  'Everything that changes where data goes or what the model may execute is a recorded admin decision (C-04, C-05). text_to_sql additionally needs a passed sql_eval_run (trg_sql_flag).';

CREATE TABLE copilot.tool_policy (
    tool_id      uuid PRIMARY KEY REFERENCES agent.tool(id) ON DELETE CASCADE,
    provider     text        NOT NULL,                       -- 'platform' | 'shiftbrief' | 'machinesense' | 'qe_agent' | 'genba_memory' | 'vision' | 'copilot'
    enabled      boolean     NOT NULL DEFAULT true,
    min_role     text        NOT NULL DEFAULT 'viewer' CHECK (min_role IN ('viewer','inspector','engineer','manager','admin')),
    scope_param  text        NOT NULL DEFAULT 'lines',       -- the argument that carries the caller's line predicate (FR-22)
    max_rows     integer     NOT NULL DEFAULT 1000 CHECK (max_rows BETWEEN 1 AND 10000),
    timeout_ms   integer     NOT NULL DEFAULT 10000 CHECK (timeout_ms BETWEEN 100 AND 10000),
    intents      copilot.intent[] NOT NULL DEFAULT '{}',
    updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE copilot.tool_policy IS
  'Which registry tools Copilot exposes, to whom, with which scope argument. Only kind = read tools may be enabled (C-01, trg_tool_policy_read_only).';

CREATE TABLE copilot.sql_whitelist (
    relation     text PRIMARY KEY,                           -- schema.view
    columns_json jsonb       NOT NULL DEFAULT '[]'::jsonb,
    scope_column text,                                       -- the column the sandbox filters by line scope
    note         text,
    CONSTRAINT whitelist_never_users CHECK (relation NOT IN ('core.app_user', 'core.user_line_scope', 'audit.log', 'audit.auth_event'))
);

CREATE TABLE copilot.masking_rule (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    field_kind        text        NOT NULL CHECK (field_kind IN ('operator_name', 'employee_id', 'email', 'phone')),
    min_role_unmasked text        NOT NULL DEFAULT 'manager' CHECK (min_role_unmasked IN ('inspector','engineer','manager','admin')),
    replacement       text        NOT NULL DEFAULT '***',
    active            boolean     NOT NULL DEFAULT true
);

CREATE TABLE copilot.prompt_template (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind         text        NOT NULL CHECK (kind IN ('planner', 'composer', 'clarify', 'suggest')),
    version      text        NOT NULL,
    path         text        NOT NULL,
    checksum     text        NOT NULL,
    temperature  numeric(3,2) NOT NULL CHECK (temperature >= 0 AND temperature <= 0.3),
    active       boolean     NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT prompt_version_unique UNIQUE (kind, version)
);

CREATE TABLE copilot.entity_alias (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind         text        NOT NULL CHECK (kind IN ('line', 'machine', 'sku', 'defect', 'mould')),
    canonical_id uuid        NOT NULL,
    alias        text        NOT NULL,
    alias_norm   text        GENERATED ALWAYS AS (copilot.norm_text(alias)) STORED,
    lang         core.language_code,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT alias_unique UNIQUE (kind, alias_norm)
);

COMMENT ON TABLE copilot.entity_alias IS
  'SRS-10 §5 entity_alias. FR-03: "ไลน์ 3", "ライン3", "line 3", "L3" resolve to the same core.line. Resolution: exact on alias_norm, then trigram (resolve_entity).';

CREATE TABLE copilot.user_pref (
    user_id      uuid PRIMARY KEY REFERENCES core.app_user(id) ON DELETE CASCADE,
    answer_lang  core.language_code,                         -- NULL = answer in the question's language (FR-01)
    show_numbers boolean     NOT NULL DEFAULT false,
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE copilot.channel_binding (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    channel          text        NOT NULL CHECK (channel IN ('discord', 'line', 'embed')),
    external_user_id text        NOT NULL,
    user_id          uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE CASCADE,
    verified_at      timestamptz,
    allowed_channels_json jsonb  NOT NULL DEFAULT '[]'::jsonb,
    CONSTRAINT binding_unique UNIQUE (channel, external_user_id)
);

COMMENT ON TABLE copilot.channel_binding IS
  'A Discord identity is authorised only through a verified binding to a platform user (ICD-00 IF-08: chat presence is not authentication).';

CREATE TABLE copilot.doc_source (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind         text        NOT NULL CHECK (kind IN ('sop', 'eight_d', 'fmea', 'manual', 'work_instruction', 'mixed')),
    uri          text        NOT NULL UNIQUE,
    acl_json     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    watch        boolean     NOT NULL DEFAULT true,
    scan_interval_s integer  NOT NULL DEFAULT 300 CHECK (scan_interval_s BETWEEN 60 AND 86400),
    last_scan_at timestamptz,
    active       boolean     NOT NULL DEFAULT true
);

CREATE TABLE copilot.index_job (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    source_id    uuid        REFERENCES copilot.doc_source(id) ON DELETE SET NULL,
    document_id  uuid        REFERENCES knowledge.document(id) ON DELETE SET NULL,
    uri          text        NOT NULL,
    sha256       text        NOT NULL,
    state        copilot.index_state NOT NULL DEFAULT 'queued',
    reason       text        NOT NULL CHECK (reason IN ('new', 'changed', 'manual', 'reembed')),
    queued_at    timestamptz NOT NULL DEFAULT now(),
    started_at   timestamptz,
    finished_at  timestamptz,
    chunks       integer,
    error        text
);

COMMENT ON TABLE copilot.index_job IS
  'FR-12: the watcher compares sha256 per file; unchanged files are skipped, changed files re-chunked and re-embedded.';

-- =====================================================================
-- 12. COPILOT — turns, evidence, sandbox
-- =====================================================================

CREATE TABLE copilot.turn (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id              uuid        NOT NULL UNIQUE REFERENCES agent.run(id) ON DELETE CASCADE,
    conversation_id     uuid        NOT NULL REFERENCES agent.conversation(id) ON DELETE CASCADE,
    question_message_id uuid        NOT NULL REFERENCES agent.message(id) ON DELETE CASCADE,
    answer_message_id   uuid        REFERENCES agent.message(id) ON DELETE SET NULL,
    user_id             uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    user_role           text        NOT NULL CHECK (user_role IN ('viewer','inspector','engineer','manager','admin')),
    channel             text        NOT NULL DEFAULT 'web' CHECK (channel IN ('web', 'discord', 'api', 'embed')),
    mode                copilot.run_mode NOT NULL DEFAULT 'full',
    lang_detected       core.language_code NOT NULL,
    answer_lang         core.language_code NOT NULL,
    intent              copilot.intent NOT NULL,
    entities_json       jsonb       NOT NULL DEFAULT '[]'::jsonb,       -- [{kind, canonical_id, alias, method}]
    time_expr           text,
    time_from           timestamptz,
    time_to             timestamptz,
    time_resolution     text,                                           -- how: 'relative:yesterday' | 'shift:B' | 'explicit' | 'context'
    context_json        jsonb       NOT NULL DEFAULT '{}'::jsonb,       -- FR-06: slots reused from the previous turn
    clarification_asked text,
    clarification_reply text,
    plan_json           jsonb       NOT NULL DEFAULT '[]'::jsonb,       -- typed plan validated against the registry
    evidence_bundle_json jsonb,                                         -- IF-56 — the composer's only input
    bundle_digest       text,
    sources_json        jsonb       NOT NULL DEFAULT '[]'::jsonb,       -- FR-15
    confidence_note     text,                                           -- FR-16
    partial             boolean     NOT NULL DEFAULT false,
    partial_reason      text,
    masked              boolean     NOT NULL DEFAULT false,             -- FR-26
    delegated_signal_id uuid        REFERENCES quality.signal(id) ON DELETE SET NULL,   -- FR-21
    delegated_case_id   uuid        REFERENCES quality.case(id)   ON DELETE SET NULL,
    charts_json         jsonb       NOT NULL DEFAULT '[]'::jsonb,       -- FR-14 Vega-Lite specs referencing bundle facts
    images_json         jsonb       NOT NULL DEFAULT '[]'::jsonb,       -- FR-10 signed image refs
    suggestions_json    jsonb       NOT NULL DEFAULT '[]'::jsonb,       -- FR-20
    queue_wait_ms       integer     NOT NULL DEFAULT 0,
    first_token_ms      integer,
    created_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT turn_partial_has_reason CHECK (NOT partial OR partial_reason IS NOT NULL),
    CONSTRAINT turn_time_ordered CHECK (time_from IS NULL OR time_to IS NULL OR time_to > time_from),
    CONSTRAINT turn_clarification_pair CHECK (clarification_reply IS NULL OR clarification_asked IS NOT NULL)
);

COMMENT ON TABLE copilot.turn IS
  'One row per question. Together with agent.run (model, prompt, tokens, latency, grounding) and agent.tool_call this is SRS-10 FR-23: question, plan, tool calls, sources, answer, latency, model.';
COMMENT ON COLUMN copilot.turn.evidence_bundle_json IS
  'Validated against deploy/schemas/evidence-bundle.schema.json (IF-56). Every number the answer may contain is here with an evidence id; the grounding post-check matches against it.';

CREATE TABLE copilot.sql_query (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    turn_id        uuid        NOT NULL REFERENCES copilot.turn(id) ON DELETE CASCADE,
    sql_text       text        NOT NULL,
    parser_ok      boolean     NOT NULL DEFAULT false,
    whitelist_ok   boolean     NOT NULL DEFAULT false,
    reject_reason  text,
    limit_applied  integer     NOT NULL CHECK (limit_applied BETWEEN 1 AND 1000),
    timeout_ms     integer     NOT NULL DEFAULT 5000 CHECK (timeout_ms BETWEEN 100 AND 5000),
    executed_as    text        NOT NULL DEFAULT 'copilot_sql_ro',
    executed       boolean     NOT NULL DEFAULT false,
    row_count      integer,
    duration_ms    integer,
    result_digest  text,
    error          text,
    created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE copilot.sql_query IS
  'FR-08 / C-05 / AC-07. Stored whether or not it executed, so "show the SQL" and the audit see exactly what the model proposed and what ran. trg_sql_safe and trg_sql_flag guard execution.';

CREATE TABLE copilot.term_check (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    turn_id      uuid        NOT NULL REFERENCES copilot.turn(id) ON DELETE CASCADE,
    term_id      uuid        REFERENCES knowledge.glossary_term(id) ON DELETE SET NULL,
    found        text        NOT NULL,
    expected     text        NOT NULL,
    position     integer,
    resolved     boolean     NOT NULL DEFAULT false
);

CREATE TABLE copilot.queue_status (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts           timestamptz NOT NULL DEFAULT now(),
    depth        integer     NOT NULL CHECK (depth >= 0),
    max_wait_ms  integer     NOT NULL CHECK (max_wait_ms >= 0),
    gpu_wait_ms  integer,
    mode         copilot.run_mode NOT NULL DEFAULT 'full'
);

COMMENT ON TABLE copilot.queue_status IS 'NFR-03: queueing is acceptable only when visible. Snapshots every 10 s feed the UI status and /metrics.';

-- =====================================================================
-- 13. COPILOT — sharing, curation, evaluation
-- =====================================================================

CREATE TABLE copilot.saved_question (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id      uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE CASCADE,
    text         text        NOT NULL,
    lang         core.language_code NOT NULL,
    slots_json   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    direct_url   text,                                       -- NFR-06: usable as a dashboard link when the model is down
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE copilot.share (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    turn_id      uuid        NOT NULL REFERENCES copilot.turn(id) ON DELETE CASCADE,
    format       copilot.share_format NOT NULL,
    token        text        NOT NULL UNIQUE,
    object_uri   text,
    created_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    revoked_at   timestamptz,
    CONSTRAINT share_expiry_bounded CHECK (expires_at > created_at AND expires_at <= created_at + interval '30 days')
);

CREATE TABLE copilot.pin (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    turn_id      uuid        NOT NULL REFERENCES copilot.turn(id) ON DELETE CASCADE,
    user_id      uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE CASCADE,
    dashboard    text        NOT NULL DEFAULT 'my',
    position     integer     NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pin_unique UNIQUE (turn_id, user_id, dashboard)
);

CREATE TABLE copilot.curated_qa (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    question       text        NOT NULL,
    answer         text        NOT NULL,
    lang           core.language_code NOT NULL,
    author_id      uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    approved_by    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    approved_at    timestamptz,
    source_turn_id uuid        REFERENCES copilot.turn(id) ON DELETE SET NULL,
    sources_json   jsonb       NOT NULL DEFAULT '[]'::jsonb,
    embedding      vector(1024),
    embedding_version text,
    active         boolean     NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT curated_approval_complete CHECK ((approved_by IS NULL AND approved_at IS NULL) OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);

COMMENT ON TABLE copilot.curated_qa IS
  'SRS-10 §5 curated_qa / FR-25. Searched first by the retriever and cited as "curated answer (approved by …)". Active only when approved by role >= engineer and embedded (trg_curated_approved).';

CREATE TABLE copilot.answer_flag (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    turn_id       uuid        NOT NULL REFERENCES copilot.turn(id) ON DELETE CASCADE,
    flagged_by    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    reason        text        NOT NULL,
    status        copilot.flag_status NOT NULL DEFAULT 'open',
    reviewed_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    reviewed_at   timestamptz,
    curated_qa_id uuid        REFERENCES copilot.curated_qa(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT flag_corrected_has_qa CHECK (status <> 'corrected' OR curated_qa_id IS NOT NULL)
);

CREATE TABLE copilot.eval_question (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ordinal           integer     NOT NULL UNIQUE,
    lang              core.language_code NOT NULL,
    intent            copilot.intent NOT NULL,
    question          text        NOT NULL,
    expected_json     jsonb       NOT NULL,                  -- ground truth numbers / document ids
    expected_sources_json jsonb   NOT NULL DEFAULT '[]'::jsonb,
    active            boolean     NOT NULL DEFAULT true
);

CREATE TABLE copilot.eval_run (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ran_at             timestamptz NOT NULL DEFAULT now(),
    model              text        NOT NULL,
    prompt_version     text        NOT NULL,
    embedding_version  text        NOT NULL,
    tool_schema_version text       NOT NULL,
    questions          integer     NOT NULL CHECK (questions >= 0),
    correct            integer     NOT NULL CHECK (correct >= 0),
    citations_correct  integer     NOT NULL CHECK (citations_correct >= 0),
    fabricated         integer     NOT NULL CHECK (fabricated >= 0),
    langs_covered      smallint    NOT NULL CHECK (langs_covered BETWEEN 0 AND 3),
    intents_covered    smallint    NOT NULL CHECK (intents_covered BETWEEN 0 AND 6),
    accuracy           numeric(5,4),
    citation_rate      numeric(5,4),
    passed             boolean,
    release_blocked    boolean,
    notes              text,
    CONSTRAINT eval_counts_bounded CHECK (correct <= questions AND citations_correct <= questions)
);

COMMENT ON TABLE copilot.eval_run IS
  'AI-05 / AC-01 release gate: >= 60 questions across 3 languages and 6 intents; accuracy >= 90 %, citation correctness >= 95 %, fabricated numbers = 0. passed / release_blocked are computed by trg_eval_gate, never typed.';

CREATE TABLE copilot.eval_result (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    eval_run_id      uuid        NOT NULL REFERENCES copilot.eval_run(id) ON DELETE CASCADE,
    question_id      uuid        NOT NULL REFERENCES copilot.eval_question(id) ON DELETE CASCADE,
    run_id           uuid        REFERENCES agent.run(id) ON DELETE SET NULL,
    correct          boolean     NOT NULL,
    citation_correct boolean     NOT NULL,
    fabricated_numbers integer   NOT NULL DEFAULT 0 CHECK (fabricated_numbers >= 0),
    latency_ms       integer,
    CONSTRAINT eval_result_unique UNIQUE (eval_run_id, question_id)
);

CREATE TABLE copilot.sql_eval_run (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ran_at         timestamptz NOT NULL DEFAULT now(),
    model          text        NOT NULL,
    prompt_version text        NOT NULL,
    questions      integer     NOT NULL CHECK (questions >= 0),
    correct        integer     NOT NULL CHECK (correct >= 0),
    accuracy       numeric(5,4),
    passed         boolean,
    notes          text,
    CONSTRAINT sql_eval_bounded CHECK (correct <= questions)
);

COMMENT ON TABLE copilot.sql_eval_run IS
  'AI-06: text-to-SQL is evaluated separately (>= 30 questions, execution accuracy >= 85 %); otherwise the feature stays behind the flag (trg_sql_flag).';

INSERT INTO copilot.migration (id, note) VALUES ('copilot_0001', 'Factory Copilot extension — DDS-10 v1.0');

-- =====================================================================
-- 14. COPILOT — functions (twins of the deterministic logic; TEST-10 TC-005 re-derives them in Python)
-- =====================================================================

-- FR-01: script-based language detection. Thai block, Japanese kana/kanji, Latin letters; dominant script wins; Thai on a tie.
CREATE OR REPLACE FUNCTION copilot.detect_lang(t text) RETURNS core.language_code
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    n_th int := length(regexp_replace(coalesce(t, ''), '[^ก-๛]', '', 'g'));
    n_ja int := length(regexp_replace(coalesce(t, ''), '[^ぁ-ヿ一-鿿]', '', 'g'));
    n_en int := length(regexp_replace(coalesce(t, ''), '[^A-Za-z]', '', 'g'));
BEGIN
    IF n_th > 0 AND n_th >= n_ja AND n_th >= n_en THEN RETURN 'th'; END IF;
    IF n_ja > 0 AND n_ja >= n_en THEN RETURN 'ja'; END IF;
    RETURN 'en';
END;
$$;

-- FR-02: relative time expressions → concrete ranges in the plant's timezone using the versioned shift calendar.
-- Returns time_from (inclusive), time_to (exclusive) and how it was resolved. Unknown expressions return NULLs (the planner then asks or uses context).
CREATE OR REPLACE FUNCTION copilot.resolve_time(expr text, p_plant uuid, p_now timestamptz)
RETURNS TABLE (time_from timestamptz, time_to timestamptz, resolution text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    tz    text;
    e     text := copilot.norm_text(expr);
    lnow  timestamp;
    d     date;
    s     record;
BEGIN
    SELECT p.timezone INTO tz FROM core.plant p WHERE p.id = p_plant;
    tz := coalesce(tz, 'Asia/Bangkok');
    lnow := p_now AT TIME ZONE tz;
    d := lnow::date;
    IF e IN ('yesterday', 'เมื่อวาน', 'เมื่อวานนี้', '昨日', 'きのう') THEN
        RETURN QUERY SELECT ((d - 1)::timestamp AT TIME ZONE tz), (d::timestamp AT TIME ZONE tz), 'relative:yesterday'; RETURN;
    ELSIF e IN ('today', 'วันนี้', '今日', 'きょう') THEN
        RETURN QUERY SELECT (d::timestamp AT TIME ZONE tz), ((d + 1)::timestamp AT TIME ZONE tz), 'relative:today'; RETURN;
    ELSIF e IN ('lastweek', 'สัปดาห์ที่แล้ว', 'อาทิตย์ที่แล้ว', '先週', 'せんしゅう') THEN
        RETURN QUERY SELECT ((date_trunc('week', d::timestamp) - interval '7 days') AT TIME ZONE tz),
                            (date_trunc('week', d::timestamp) AT TIME ZONE tz), 'relative:last_week'; RETURN;
    ELSIF e IN ('thisweek', 'สัปดาห์นี้', 'อาทิตย์นี้', '今週') THEN
        RETURN QUERY SELECT (date_trunc('week', d::timestamp) AT TIME ZONE tz), ((d + 1)::timestamp AT TIME ZONE tz), 'relative:this_week'; RETURN;
    ELSIF e IN ('lastmonth', 'เดือนที่แล้ว', '先月') THEN
        RETURN QUERY SELECT ((date_trunc('month', d::timestamp) - interval '1 month') AT TIME ZONE tz),
                            (date_trunc('month', d::timestamp) AT TIME ZONE tz), 'relative:last_month'; RETURN;
    ELSIF e IN ('thismonth', 'เดือนนี้', '今月') THEN
        RETURN QUERY SELECT (date_trunc('month', d::timestamp) AT TIME ZONE tz), ((d + 1)::timestamp AT TIME ZONE tz), 'relative:this_month'; RETURN;
    ELSIF e IN ('thisshift', 'กะนี้', 'このシフト', '今のシフト', '当直') THEN
        -- the shift whose window contains local now; overnight shifts (ends_at < starts_at) wrap midnight
        SELECT sc.shift, sc.starts_at, sc.ends_at INTO s
        FROM core.shift_calendar sc
        WHERE sc.plant_id = p_plant AND sc.valid_from <= d AND (sc.valid_to IS NULL OR sc.valid_to >= d)
          AND ((sc.starts_at <= sc.ends_at AND lnow::time >= sc.starts_at AND lnow::time < sc.ends_at)
            OR (sc.starts_at >  sc.ends_at AND (lnow::time >= sc.starts_at OR lnow::time < sc.ends_at)))
        LIMIT 1;
        IF s IS NULL THEN RETURN; END IF;
        IF s.starts_at <= s.ends_at THEN
            RETURN QUERY SELECT ((d + s.starts_at)::timestamp AT TIME ZONE tz), ((d + s.ends_at)::timestamp AT TIME ZONE tz), 'shift:' || s.shift::text;
        ELSIF lnow::time >= s.starts_at THEN
            RETURN QUERY SELECT ((d + s.starts_at)::timestamp AT TIME ZONE tz), ((d + 1 + s.ends_at)::timestamp AT TIME ZONE tz), 'shift:' || s.shift::text;
        ELSE
            RETURN QUERY SELECT ((d - 1 + s.starts_at)::timestamp AT TIME ZONE tz), ((d + s.ends_at)::timestamp AT TIME ZONE tz), 'shift:' || s.shift::text;
        END IF;
        RETURN;
    END IF;
    RETURN;
END;
$$;

-- FR-03: entity resolution through the alias table — exact on the normalised alias, then trigram similarity >= 0.5.
CREATE OR REPLACE FUNCTION copilot.resolve_entity(txt text, p_kind text DEFAULT NULL)
RETURNS TABLE (kind text, canonical_id uuid, alias text, method text, similarity real)
LANGUAGE sql STABLE AS $$
    WITH q AS (SELECT copilot.norm_text(txt) AS n)
    SELECT a.kind, a.canonical_id, a.alias, 'exact', 1.0::real
    FROM copilot.entity_alias a, q
    WHERE a.alias_norm = q.n AND (p_kind IS NULL OR a.kind = p_kind)
    UNION ALL
    SELECT a.kind, a.canonical_id, a.alias, 'trigram', similarity(a.alias_norm, q.n)
    FROM copilot.entity_alias a, q
    WHERE a.alias_norm <> q.n AND (p_kind IS NULL OR a.kind = p_kind) AND similarity(a.alias_norm, q.n) >= 0.5
    ORDER BY 5 DESC, 3
    LIMIT 3;
$$;

-- AI-04: numeric tokens of an answer. Thousands separators removed, fullwidth/Thai digits normalised,
-- "118/187" yields both parts, "14:20" is kept as a time token, "5.82 %" yields 5.82.
CREATE OR REPLACE FUNCTION copilot.extract_numbers(t text) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(array_agg(tok ORDER BY ord), '{}')
    FROM (
        SELECT ord,
               CASE WHEN m[1] ~ ':' THEN m[1] ELSE regexp_replace(m[1], ',', '', 'g') END AS tok
        FROM regexp_matches(
               translate(coalesce(t, ''), '０１２３４５６７８９๐๑๒๓๔๕๖๗๘๙', '01234567890123456789'),
               '(\d{1,2}:\d{2}|\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)', 'g') WITH ORDINALITY AS r(m, ord)
    ) x;
$$;

-- Every scalar leaf of a JSON document as text (numbers and strings), for grounding.
CREATE OR REPLACE FUNCTION copilot.json_leaves(j jsonb) RETURNS SETOF text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(v) = 'string' THEN v #>> '{}' ELSE v::text END
    FROM jsonb_path_query(j, 'strict $.**') v
    WHERE jsonb_typeof(v) IN ('number', 'string');
$$;

-- AI-04 post-check (ADR-013): each numeric token in the answer must match a bundle value.
-- A numeric token matches when a numeric leaf equals it within 0.005 absolute or 0.5 % relative (rounding tolerance),
-- or when the token text appears inside a string leaf (times, ids). Years 1900–2100 are ignored.
CREATE OR REPLACE FUNCTION copilot.grounding_check(answer text, bundle jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    toks      text[] := copilot.extract_numbers(answer);
    unmatched text[] := '{}';
    tok       text;
    ok        boolean;
    nums      numeric[];
    strs      text[];
BEGIN
    SELECT coalesce(array_agg(l::numeric), '{}') INTO nums FROM copilot.json_leaves(bundle) l WHERE l ~ '^-?\d+(\.\d+)?$';
    SELECT coalesce(array_agg(l), '{}')          INTO strs FROM copilot.json_leaves(bundle) l WHERE l !~ '^-?\d+(\.\d+)?$';
    FOREACH tok IN ARRAY toks LOOP
        IF tok ~ '^\d{4}$' AND tok::int BETWEEN 1900 AND 2100 THEN CONTINUE; END IF;
        IF tok ~ ':' THEN
            ok := EXISTS (SELECT 1 FROM unnest(strs) s WHERE position(tok IN s) > 0);
        ELSE
            ok := EXISTS (SELECT 1 FROM unnest(nums) n
                          WHERE abs(n - tok::numeric) <= 0.005 OR abs(n - tok::numeric) <= 0.005 * abs(n))
               OR EXISTS (SELECT 1 FROM unnest(strs) s WHERE position(tok IN s) > 0);
        END IF;
        IF NOT ok THEN unmatched := unmatched || tok; END IF;
    END LOOP;
    RETURN jsonb_build_object('numbers_found', to_jsonb(toks), 'unmatched', to_jsonb(unmatched),
                              'all_matched', coalesce(array_length(unmatched, 1), 0) = 0);
END;
$$;

-- C-05 / FR-08: the sandbox's static rules (the production sandbox uses a real SQL parser; this is its executable twin).
CREATE OR REPLACE FUNCTION copilot.sql_is_safe(sql text) RETURNS TABLE (ok boolean, reason text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    s    text := btrim(regexp_replace(coalesce(sql, ''), ';\s*$', ''));
    rel  text;
    lim  text;
BEGIN
    IF s = '' THEN RETURN QUERY SELECT false, 'empty'; RETURN; END IF;
    IF position(';' IN s) > 0 THEN RETURN QUERY SELECT false, 'multiple statements'; RETURN; END IF;
    IF s ~ '(--|/\*)' THEN RETURN QUERY SELECT false, 'comments not allowed'; RETURN; END IF;
    IF s !~* '^\s*(select|with)\b' THEN RETURN QUERY SELECT false, 'not a SELECT'; RETURN; END IF;
    IF s ~* '\m(insert|update|delete|merge|drop|alter|create|truncate|grant|revoke|copy|call|do|execute|set|reset|vacuum|analyze|listen|notify|lock|refresh|pg_sleep|pg_read_file|pg_ls_dir|lo_import|lo_export|dblink|current_setting|set_config|pg_terminate_backend)\M' THEN
        RETURN QUERY SELECT false, 'forbidden keyword'; RETURN;
    END IF;
    IF s ~* '\mfor\s+(update|share)\M' THEN RETURN QUERY SELECT false, 'row locking not allowed'; RETURN; END IF;
    FOR rel IN SELECT DISTINCT lower(m[1]) FROM regexp_matches(s, '\m(?:from|join)\s+([a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)', 'gi') m LOOP
        IF NOT EXISTS (SELECT 1 FROM copilot.sql_whitelist w WHERE w.relation = rel) THEN
            RETURN QUERY SELECT false, 'relation not whitelisted: ' || rel; RETURN;
        END IF;
    END LOOP;
    IF s ~* '\m(?:from|join)\s+[a-z_][a-z0-9_]*\s' AND s !~* '\m(?:from|join)\s+[a-z_][a-z0-9_]*\.[a-z_]' THEN
        RETURN QUERY SELECT false, 'relation without schema'; RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM regexp_matches(s, '\m(?:from|join)\s+[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*', 'gi')) THEN
        RETURN QUERY SELECT false, 'no whitelisted relation referenced'; RETURN;
    END IF;
    lim := (SELECT m[1] FROM regexp_matches(s, '\mlimit\s+(\d+)\s*$', 'i') m LIMIT 1);
    IF lim IS NULL THEN RETURN QUERY SELECT false, 'LIMIT required'; RETURN; END IF;
    IF lim::int > 1000 THEN RETURN QUERY SELECT false, 'LIMIT above 1000'; RETURN; END IF;
    RETURN QUERY SELECT true, NULL::text;
END;
$$;

-- AI-03: reciprocal rank fusion of the lexical and vector rankings (k = 60). A NULL rank contributes 0.
CREATE OR REPLACE FUNCTION copilot.rrf_fuse(bm25_rank integer, vector_rank integer, k integer DEFAULT 60) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round((CASE WHEN bm25_rank   IS NULL THEN 0 ELSE 1.0 / (k + bm25_rank)   END)
               + (CASE WHEN vector_rank IS NULL THEN 0 ELSE 1.0 / (k + vector_rank) END), 6);
$$;

-- FR-26: names are replaced unless the caller's role is at or above the rule's threshold.
CREATE OR REPLACE FUNCTION copilot.role_rank(r text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE r WHEN 'viewer' THEN 1 WHEN 'inspector' THEN 2 WHEN 'engineer' THEN 3 WHEN 'manager' THEN 4 WHEN 'admin' THEN 5 ELSE 0 END;
$$;

CREATE OR REPLACE FUNCTION copilot.mask_names(t text, caller_role text, names text[]) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    threshold text;
    repl      text;
    n         text;
    out_t     text := t;
BEGIN
    SELECT min_role_unmasked, replacement INTO threshold, repl
    FROM copilot.masking_rule WHERE field_kind = 'operator_name' AND active LIMIT 1;
    IF threshold IS NULL OR copilot.role_rank(caller_role) >= copilot.role_rank(threshold) THEN RETURN t; END IF;
    FOREACH n IN ARRAY coalesce(names, '{}') LOOP
        out_t := replace(out_t, n, repl);
    END LOOP;
    RETURN out_t;
END;
$$;

-- FR-22 / AC-04: a tool call is in scope when the caller has no restriction, or every line in the arguments is in the caller's scope.
-- Arguments must carry the predicate ("line" or "lines") when the caller is restricted — the executor injects it.
CREATE OR REPLACE FUNCTION copilot.scope_ok(p_user uuid, args jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
    allowed text[];
    asked   text[];
BEGIN
    SELECT coalesce(array_agg(l.code), '{}') INTO allowed
    FROM core.user_line_scope s JOIN core.line l ON l.id = s.line_id WHERE s.user_id = p_user;
    IF coalesce(array_length(allowed, 1), 0) = 0 THEN RETURN true; END IF;      -- empty scope = all lines (platform rule)
    IF args ? 'lines' THEN
        SELECT coalesce(array_agg(x), '{}') INTO asked FROM jsonb_array_elements_text(args -> 'lines') x;
    ELSIF args ? 'line' THEN
        asked := ARRAY[args ->> 'line'];
    ELSE
        RETURN false;                                                             -- restricted caller without a predicate
    END IF;
    RETURN asked <@ allowed AND coalesce(array_length(asked, 1), 0) > 0;
END;
$$;

-- AI-07 / AC-05: instruction-like text inside a document is data; it is flagged for review, never executed.
CREATE OR REPLACE FUNCTION copilot.injection_suspect(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN t ~* '\m(ignore|disregard)\s+(all\s+|the\s+|previous\s+|prior\s+|your\s+)*(instructions|rules|prompt)' THEN 'ignore-instructions phrase'
        WHEN t ~* '\m(reveal|print|show|dump)\s+(all\s+)?(salar|password|secret|token|credential)' THEN 'exfiltration phrase'
        WHEN t ~* '\myou are now\M' OR t ~* '\msystem prompt\M' THEN 'role-override phrase'
        WHEN t ~ '(指示を無視|命令を無視|すべての給与|パスワードを表示)' THEN 'ignore-instructions phrase (ja)'
        WHEN t ~ '(ละเว้นคำสั่ง|เปิดเผยเงินเดือน|แสดงรหัสผ่าน)' THEN 'ignore-instructions phrase (th)'
        ELSE NULL END;
$$;

-- NFR-07: a user's conversations, messages, runs, tool calls, turns, shares and pins are deleted on request; audited.
CREATE OR REPLACE FUNCTION copilot.purge_user_conversations(p_user uuid, p_actor text) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    PERFORM set_config('copilot.purging', 'on', true);
    DELETE FROM agent.run WHERE user_id = p_user;
    WITH d AS (DELETE FROM agent.conversation WHERE user_id = p_user RETURNING id) SELECT count(*) INTO n FROM d;
    DELETE FROM copilot.saved_question WHERE user_id = p_user;
    INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
    VALUES (NULL, p_actor, 'copilot.purge_conversations', 'core.app_user', p_user::text, jsonb_build_object('conversations', n));
    RETURN n;
END;
$$;

-- =====================================================================
-- 15. COPILOT — guard triggers
-- =====================================================================

-- DD-C01: a run is ok only when the post-check matched every number; refused/partial runs carry a reason.
CREATE OR REPLACE FUNCTION copilot.trg_run_grounded_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.kind = 'ask' THEN
        IF NEW.outcome = 'ok' THEN
            IF NEW.grounding_json IS NULL OR coalesce((NEW.grounding_json ->> 'all_matched')::boolean, false) = false THEN
                RAISE EXCEPTION 'GROUNDING_FAILED: run % cannot be ok — grounding_json.all_matched is not true (unmatched: %)',
                    NEW.id, NEW.grounding_json -> 'unmatched';
            END IF;
        ELSIF NEW.outcome IN ('refused', 'partial', 'budget_exceeded') THEN
            IF coalesce(NEW.grounding_json ->> 'reason', '') = '' THEN
                RAISE EXCEPTION 'REASON_REQUIRED: a % run must state why in grounding_json.reason (FR-16, FR-17)', NEW.outcome;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_run_grounded BEFORE INSERT OR UPDATE ON agent.run
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_run_grounded_fn();

-- DD-C02: generated SQL executes only if it passes the static rules and runs as the sandbox role.
CREATE OR REPLACE FUNCTION copilot.trg_sql_safe_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM copilot.sql_is_safe(NEW.sql_text);
    NEW.parser_ok := r.ok; NEW.whitelist_ok := r.ok; NEW.reject_reason := r.reason;
    IF NEW.executed THEN
        IF NOT r.ok THEN RAISE EXCEPTION 'SQL_REJECTED: %', r.reason; END IF;
        IF NEW.executed_as <> 'copilot_sql_ro' THEN RAISE EXCEPTION 'SQL_ROLE: generated SQL executes only as copilot_sql_ro (C-05)'; END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sql_safe BEFORE INSERT OR UPDATE ON copilot.sql_query
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_sql_safe_fn();

-- DD-C02: ... and only while the feature flag is on and the latest SQL evaluation passed (AI-06).
CREATE OR REPLACE FUNCTION copilot.trg_sql_flag_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE flag_on boolean; last_pass boolean;
BEGIN
    IF NEW.executed THEN
        SELECT enabled INTO flag_on FROM copilot.feature_flag WHERE key = 'text_to_sql';
        SELECT passed INTO last_pass FROM copilot.sql_eval_run ORDER BY ran_at DESC LIMIT 1;
        IF NOT coalesce(flag_on, false) THEN RAISE EXCEPTION 'SQL_FLAG_OFF: text_to_sql is disabled'; END IF;
        IF NOT coalesce(last_pass, false) THEN RAISE EXCEPTION 'SQL_EVAL_GATE: latest sql_eval_run did not pass (AI-06)'; END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sql_flag BEFORE INSERT OR UPDATE ON copilot.sql_query
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_sql_flag_fn();

-- DD-C03: every tool call on a Copilot run carries the caller's scope predicate.
CREATE OR REPLACE FUNCTION copilot.trg_tool_scope_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    SELECT user_id, kind INTO r FROM agent.run WHERE id = NEW.run_id;
    IF r.kind = 'ask' AND r.user_id IS NOT NULL AND NOT copilot.scope_ok(r.user_id, NEW.args_json) THEN
        RAISE EXCEPTION 'SCOPE_VIOLATION: tool % called outside the caller''s line scope (args %)', NEW.tool_name, NEW.args_json;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_tool_scope BEFORE INSERT ON agent.tool_call
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_tool_scope_fn();

-- DD-C04: Copilot exposes read tools only (C-01).
CREATE OR REPLACE FUNCTION copilot.trg_tool_policy_read_only_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE k text;
BEGIN
    SELECT kind INTO k FROM agent.tool WHERE id = NEW.tool_id;
    IF NEW.enabled AND k <> 'read' THEN
        RAISE EXCEPTION 'READ_ONLY: tool % is kind=% and cannot be exposed by Copilot (C-01)', NEW.tool_id, k;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_tool_policy_read_only BEFORE INSERT OR UPDATE ON copilot.tool_policy
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_tool_policy_read_only_fn();

-- DD-C05: curated answers are citable only when approved by an engineer or above and embedded.
CREATE OR REPLACE FUNCTION copilot.trg_curated_approved_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
    IF NEW.approved_by IS NOT NULL THEN
        SELECT role INTO r FROM core.app_user WHERE id = NEW.approved_by;
        IF copilot.role_rank(r) < copilot.role_rank('engineer') THEN
            RAISE EXCEPTION 'ROLE_INSUFFICIENT: curated Q&A must be approved by engineer or above (got %)', r;
        END IF;
    END IF;
    IF NEW.active AND (NEW.approved_at IS NULL OR NEW.embedding IS NULL) THEN
        RAISE EXCEPTION 'NOT_CITABLE: curated Q&A is active only when approved and embedded';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_curated_approved BEFORE INSERT OR UPDATE ON copilot.curated_qa
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_curated_approved_fn();

-- DD-C06: only grounded answers can be shared or exported.
CREATE OR REPLACE FUNCTION copilot.trg_share_grounded_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE o agent.run_outcome;
BEGIN
    SELECT r.outcome INTO o FROM copilot.turn t JOIN agent.run r ON r.id = t.run_id WHERE t.id = NEW.turn_id;
    IF o IS DISTINCT FROM 'ok' THEN
        RAISE EXCEPTION 'NOT_SHAREABLE: turn % has outcome % — only grounded (ok) answers can be shared', NEW.turn_id, o;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_share_grounded BEFORE INSERT ON copilot.share
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_share_grounded_fn();

-- DD-C07: the evaluation gates are computed, never typed.
CREATE OR REPLACE FUNCTION copilot.trg_eval_gate_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.accuracy      := CASE WHEN NEW.questions > 0 THEN round(NEW.correct::numeric / NEW.questions, 4) END;
    NEW.citation_rate := CASE WHEN NEW.questions > 0 THEN round(NEW.citations_correct::numeric / NEW.questions, 4) END;
    NEW.passed := NEW.questions >= 60 AND NEW.langs_covered = 3 AND NEW.intents_covered = 6
                  AND NEW.accuracy >= 0.90 AND NEW.citation_rate >= 0.95 AND NEW.fabricated = 0;
    NEW.release_blocked := NOT NEW.passed;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_eval_gate BEFORE INSERT OR UPDATE ON copilot.eval_run
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_eval_gate_fn();

CREATE OR REPLACE FUNCTION copilot.trg_sql_eval_gate_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.accuracy := CASE WHEN NEW.questions > 0 THEN round(NEW.correct::numeric / NEW.questions, 4) END;
    NEW.passed   := NEW.questions >= 30 AND NEW.accuracy >= 0.85;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sql_eval_gate BEFORE INSERT OR UPDATE ON copilot.sql_eval_run
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_sql_eval_gate_fn();

-- DD-C08: a turn answered for a role below the masking threshold is masked; cause analysis is delegated.
CREATE OR REPLACE FUNCTION copilot.trg_turn_rules_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE threshold text; o agent.run_outcome;
BEGIN
    SELECT min_role_unmasked INTO threshold FROM copilot.masking_rule WHERE field_kind = 'operator_name' AND active LIMIT 1;
    IF threshold IS NOT NULL AND copilot.role_rank(NEW.user_role) < copilot.role_rank(threshold) AND NOT NEW.masked THEN
        RAISE EXCEPTION 'MASKING_REQUIRED: role % is below % — the turn must be masked (FR-26)', NEW.user_role, threshold;
    END IF;
    SELECT outcome INTO o FROM agent.run WHERE id = NEW.run_id;
    IF NEW.intent = 'cause_analysis' AND o = 'ok' AND NEW.delegated_signal_id IS NULL AND NEW.delegated_case_id IS NULL THEN
        RAISE EXCEPTION 'CAUSE_NOT_DELEGATED: a cause_analysis answer must reference a QE-Agent signal or case (FR-21)';
    END IF;
    IF NEW.mode = 'dashboards_only' AND o = 'ok' THEN
        RAISE EXCEPTION 'MODE_MISMATCH: no grounded answer is produced in dashboards_only mode';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_turn_rules BEFORE INSERT OR UPDATE ON copilot.turn
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_turn_rules_fn();

-- DD-C09 (AI-07): flag instruction-like chunk text on ingest.
CREATE OR REPLACE FUNCTION copilot.trg_chunk_injection_flag_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE why text := copilot.injection_suspect(NEW.text);
BEGIN
    NEW.suspicious := why IS NOT NULL;
    NEW.suspicious_reason := why;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_chunk_injection_flag BEFORE INSERT OR UPDATE OF text ON knowledge.chunk
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_chunk_injection_flag_fn();

-- Messages are immutable; deletion only through the purge function (NFR-07).
CREATE OR REPLACE FUNCTION copilot.trg_message_immutable_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'IMMUTABLE: agent.message rows cannot be edited (FR-23)'; END IF;
    IF current_setting('copilot.purging', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'IMMUTABLE: agent.message rows are deleted only by copilot.purge_user_conversations (NFR-07)';
    END IF;
    RETURN OLD;
END;
$$;
CREATE TRIGGER trg_message_immutable BEFORE UPDATE OR DELETE ON agent.message
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_message_immutable_fn();

-- Discord identities must be verified before they act (IF-08).
CREATE OR REPLACE FUNCTION copilot.trg_binding_verified_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.channel = 'discord' AND NEW.verified_at IS NULL AND jsonb_array_length(NEW.allowed_channels_json) > 0 THEN
        RAISE EXCEPTION 'UNVERIFIED_BINDING: channels may be allowed only after the binding is verified';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_binding_verified BEFORE INSERT OR UPDATE ON copilot.channel_binding
    FOR EACH ROW EXECUTE FUNCTION copilot.trg_binding_verified_fn();

-- =====================================================================
-- 16. COPILOT — indexes and views
-- =====================================================================

CREATE INDEX idx_turn_conversation   ON copilot.turn (conversation_id, created_at);
CREATE INDEX idx_turn_user_created   ON copilot.turn (user_id, created_at DESC);
CREATE INDEX idx_turn_intent         ON copilot.turn (intent, created_at DESC);
CREATE INDEX idx_turn_delegated      ON copilot.turn (delegated_signal_id) WHERE delegated_signal_id IS NOT NULL;
CREATE INDEX idx_sql_query_turn      ON copilot.sql_query (turn_id);
CREATE INDEX idx_sql_query_executed  ON copilot.sql_query (executed, created_at DESC);
CREATE INDEX idx_alias_kind_norm     ON copilot.entity_alias (kind, alias_norm);
CREATE INDEX idx_alias_norm_trgm     ON copilot.entity_alias USING gin (alias_norm gin_trgm_ops);
CREATE INDEX idx_curated_embedding   ON copilot.curated_qa USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_curated_active      ON copilot.curated_qa (active, lang);
CREATE INDEX idx_flag_status         ON copilot.answer_flag (status, created_at);
CREATE INDEX idx_share_token         ON copilot.share (token) WHERE revoked_at IS NULL;
CREATE INDEX idx_share_expiry        ON copilot.share (expires_at);
CREATE INDEX idx_index_job_state     ON copilot.index_job (state, queued_at);
CREATE INDEX idx_index_job_sha       ON copilot.index_job (sha256);
CREATE INDEX idx_eval_result_run     ON copilot.eval_result (eval_run_id);
CREATE INDEX idx_eval_run_ran        ON copilot.eval_run (ran_at DESC);
CREATE INDEX idx_queue_status_ts     ON copilot.queue_status (ts DESC);
CREATE INDEX idx_chunk_suspicious    ON knowledge.chunk (document_id) WHERE suspicious;

-- Conversation board: one row per turn with outcome and latency (FR-23)
CREATE OR REPLACE VIEW copilot.v_conversation_board AS
SELECT c.id AS conversation_id, c.channel, c.lang, c.title, c.started_at,
       u.username, t.id AS turn_id, t.created_at, t.intent, t.lang_detected, t.answer_lang,
       r.outcome, r.latency_ms, t.first_token_ms, t.queue_wait_ms, r.tool_call_count, t.partial, t.masked,
       (t.delegated_signal_id IS NOT NULL OR t.delegated_case_id IS NOT NULL) AS delegated
FROM copilot.turn t
JOIN agent.run r ON r.id = t.run_id
JOIN agent.conversation c ON c.id = t.conversation_id
LEFT JOIN core.app_user u ON u.id = t.user_id;

-- Full trace of a turn: question, plan, tool calls, sources, answer, grounding (FR-18, FR-23)
CREATE OR REPLACE VIEW copilot.v_turn_trace AS
SELECT t.id AS turn_id, t.created_at, t.intent, t.lang_detected, t.answer_lang,
       qm.content AS question, am.content AS answer,
       t.time_expr, t.time_from, t.time_to, t.time_resolution, t.entities_json, t.context_json,
       t.plan_json, t.sources_json, t.confidence_note, t.partial_reason,
       r.model, r.prompt_version, r.tokens_in, r.tokens_out, r.latency_ms, r.outcome, r.grounding_json,
       (SELECT jsonb_agg(jsonb_build_object('ordinal', tc.ordinal, 'tool', tc.tool_name, 'args', tc.args_json,
                                            'rows', tc.row_count, 'ms', tc.duration_ms, 'ok', tc.ok, 'digest', tc.result_digest) ORDER BY tc.ordinal)
          FROM agent.tool_call tc WHERE tc.run_id = r.id) AS tool_calls,
       (SELECT jsonb_agg(jsonb_build_object('sql', q.sql_text, 'executed', q.executed, 'rows', q.row_count, 'reason', q.reject_reason))
          FROM copilot.sql_query q WHERE q.turn_id = t.id) AS sql_queries
FROM copilot.turn t
JOIN agent.run r ON r.id = t.run_id
JOIN agent.message qm ON qm.id = t.question_message_id
LEFT JOIN agent.message am ON am.id = t.answer_message_id;

-- Daily operational picture (OPS-10 §9)
CREATE OR REPLACE VIEW copilot.v_copilot_daily AS
SELECT date_trunc('day', t.created_at)::date AS day,
       count(*) AS turns,
       count(*) FILTER (WHERE r.outcome = 'ok') AS ok,
       count(*) FILTER (WHERE r.outcome = 'refused') AS refused,
       count(*) FILTER (WHERE r.outcome = 'grounding_failed') AS grounding_failed,
       count(*) FILTER (WHERE r.outcome = 'partial') AS partial,
       count(*) FILTER (WHERE t.mode = 'dashboards_only') AS dashboards_only,
       count(*) FILTER (WHERE t.clarification_asked IS NOT NULL) AS clarifications,
       count(*) FILTER (WHERE t.delegated_signal_id IS NOT NULL OR t.delegated_case_id IS NOT NULL) AS delegated,
       round(avg(t.first_token_ms)) AS avg_first_token_ms,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY r.latency_ms) AS p95_latency_ms,
       round(avg(r.tool_call_count), 2) AS avg_tool_calls,
       count(*) FILTER (WHERE t.lang_detected = 'th') AS th,
       count(*) FILTER (WHERE t.lang_detected = 'ja') AS ja,
       count(*) FILTER (WHERE t.lang_detected = 'en') AS en
FROM copilot.turn t JOIN agent.run r ON r.id = t.run_id
GROUP BY 1;

-- Generated SQL audit (C-05, AC-07)
CREATE OR REPLACE VIEW copilot.v_sql_audit AS
SELECT q.id, q.created_at, t.id AS turn_id, u.username, q.executed, q.executed_as, q.parser_ok, q.whitelist_ok,
       q.reject_reason, q.limit_applied, q.timeout_ms, q.row_count, q.duration_ms, q.sql_text
FROM copilot.sql_query q JOIN copilot.turn t ON t.id = q.turn_id LEFT JOIN core.app_user u ON u.id = t.user_id;

-- Scope audit: every tool call with the caller's scope and the lines asked (AC-04, NFR-05)
CREATE OR REPLACE VIEW copilot.v_scope_audit AS
SELECT tc.id AS tool_call_id, r.ts, u.username, u.role, tc.tool_name,
       coalesce(tc.args_json -> 'lines', jsonb_build_array(tc.args_json -> 'line')) AS lines_asked,
       (SELECT coalesce(jsonb_agg(l.code), '[]'::jsonb) FROM core.user_line_scope s JOIN core.line l ON l.id = s.line_id WHERE s.user_id = r.user_id) AS scope,
       copilot.scope_ok(r.user_id, tc.args_json) AS in_scope
FROM agent.tool_call tc JOIN agent.run r ON r.id = tc.run_id LEFT JOIN core.app_user u ON u.id = r.user_id
WHERE r.kind = 'ask';

-- Evaluation summary (AI-05 / AI-06 release gates)
CREATE OR REPLACE VIEW copilot.v_eval_summary AS
SELECT 'answer' AS suite, e.ran_at, e.model, e.prompt_version, e.questions, e.correct, e.accuracy, e.citation_rate, e.fabricated, e.passed, e.release_blocked
FROM copilot.eval_run e
UNION ALL
SELECT 'sql', s.ran_at, s.model, s.prompt_version, s.questions, s.correct, s.accuracy, NULL, NULL, s.passed, NOT s.passed
FROM copilot.sql_eval_run s;

-- Review queue for flagged answers (FR-25)
CREATE OR REPLACE VIEW copilot.v_flag_queue AS
SELECT f.id AS flag_id, f.created_at, f.status, f.reason, fu.username AS flagged_by, t.id AS turn_id, t.intent, t.lang_detected,
       qm.content AS question, am.content AS answer, r.outcome, f.curated_qa_id
FROM copilot.answer_flag f
JOIN copilot.turn t ON t.id = f.turn_id
JOIN agent.run r ON r.id = t.run_id
JOIN agent.message qm ON qm.id = t.question_message_id
LEFT JOIN agent.message am ON am.id = t.answer_message_id
LEFT JOIN core.app_user fu ON fu.id = f.flagged_by;

-- Index status per source (FR-12)
CREATE OR REPLACE VIEW copilot.v_index_status AS
SELECT s.id AS source_id, s.kind, s.uri, s.watch, s.last_scan_at,
       count(j.id) AS jobs,
       count(j.id) FILTER (WHERE j.state = 'done') AS done,
       count(j.id) FILTER (WHERE j.state = 'failed') AS failed,
       count(j.id) FILTER (WHERE j.state = 'skipped') AS skipped,
       max(j.finished_at) AS last_finished_at,
       (SELECT count(*) FROM knowledge.chunk c JOIN knowledge.document d ON d.id = c.document_id WHERE d.source_system = s.uri AND c.suspicious) AS suspicious_chunks
FROM copilot.doc_source s LEFT JOIN copilot.index_job j ON j.source_id = s.id
GROUP BY s.id;

-- Queue picture (NFR-03)
CREATE OR REPLACE VIEW copilot.v_queue AS
SELECT ts, depth, max_wait_ms, gpu_wait_ms, mode FROM copilot.queue_status ORDER BY ts DESC LIMIT 60;

-- =====================================================================
-- 17. ROLES AND GRANTS (standalone; platform mode keeps the platform's roles and adds copilot_sql_ro + indexer_rw)
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')         THEN CREATE ROLE app_rw         NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')         THEN CREATE ROLE app_ro         NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_ro')       THEN CREATE ROLE agent_ro       NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'copilot_sql_ro') THEN CREATE ROLE copilot_sql_ro NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'indexer_rw')     THEN CREATE ROLE indexer_rw     NOLOGIN; END IF;
END
$$;
-- Login passwords are SET_AT_BOOTSTRAP from secret files (OPS-10 §4.2); never in this file.

COMMENT ON ROLE copilot_sql_ro IS 'Text-to-SQL sandbox. SELECT on the whitelisted views only; statement_timeout 5 s; no users, no scope table, no audit (C-05).';
COMMENT ON ROLE indexer_rw     IS 'Document ingestion. Writes knowledge.document/chunk and copilot.index_job only.';

GRANT USAGE ON SCHEMA core, vision, quality, knowledge, agent, copilot TO app_rw, app_ro;
GRANT USAGE ON SCHEMA audit TO app_rw, app_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, vision, quality, knowledge, agent, copilot TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit, copilot TO app_rw;

GRANT SELECT ON ALL TABLES IN SCHEMA core, vision, quality, knowledge, agent, copilot, audit TO app_ro;

-- agent_ro (platform tool layer): read-only and never on users, scope or audit
GRANT USAGE ON SCHEMA core, vision, quality, knowledge, agent TO agent_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, vision, quality, knowledge TO agent_ro;
REVOKE SELECT ON core.app_user       FROM agent_ro;
REVOKE SELECT ON core.user_line_scope FROM agent_ro;
GRANT SELECT ON agent.finding, agent.briefing TO agent_ro;

-- copilot_sql_ro: the narrowest role — whitelisted views only (the whitelist rows name exactly these)
GRANT USAGE ON SCHEMA core, vision TO copilot_sql_ro;
GRANT SELECT ON core.v_kpi_daily, core.v_defect_pareto, vision.v_inspection_daily TO copilot_sql_ro;
ALTER ROLE copilot_sql_ro SET statement_timeout = '5s';
ALTER ROLE copilot_sql_ro SET default_transaction_read_only = on;

-- indexer_rw: documents and chunks in, jobs updated
GRANT USAGE ON SCHEMA knowledge, copilot TO indexer_rw;
GRANT SELECT, INSERT, UPDATE ON knowledge.document, knowledge.chunk TO indexer_rw;
GRANT SELECT ON copilot.doc_source TO indexer_rw;
GRANT SELECT, INSERT, UPDATE ON copilot.index_job TO indexer_rw;

-- Future objects inherit the same posture
ALTER DEFAULT PRIVILEGES IN SCHEMA core, vision, quality, knowledge, agent, copilot
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, vision, quality, knowledge, agent, copilot
    GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT INSERT, SELECT ON TABLES TO app_rw;

-- =====================================================================
-- END — DDS-10-Copilot v1.0
-- =====================================================================
