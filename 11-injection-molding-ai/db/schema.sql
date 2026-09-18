-- =====================================================================
--  MoldMind — PostgreSQL 16 schema (standalone deployment)
--  DDS-11-MoldMind v1.0 (Draft) · 2026-09-18 · Suphot N.
--
--  Sections 1–9 are EXTRACTED VERBATIM from ../../00-factorybrain-platform/db/schema.sql
--  (extensions, helpers, enums, the whole core / vision / quality / knowledge sections, audit,
--  their indexes, triggers and views). TEST-11 TC-002 diffs every block against the platform file;
--  a difference is a defect in this file, never in the platform's.
--  Sections 10–17 are the MoldMind extension (schema moldmind, migration moldmind_0001).
--
--  Platform mode (SAD-11 §9): apply ONLY sections 10–17 (migration moldmind_0001) on the
--  platform database; sections 1–9 already exist there. MoldMind owns quality.mould, quality.shot,
--  quality.shot_part and quality.timeline_event (SAD-00 §13).
--
--  TimescaleDB is optional (SAD-00 ADR-007): quality.shot works on plain PostgreSQL; OPS-11 §10
--  shows the hypertable conversion.
--
--  NOT EXECUTED on the authoring machine (no PostgreSQL) — TEST-11 TC-009.
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
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS moldmind;

COMMENT ON SCHEMA moldmind IS
  'MoldMind extension (SRS-11). Shots, parts and the timeline stay in the platform schema quality; moldmind holds machine connections, shot context, alignment, defects, windows, the knowledge base, RCA sessions, suggestions and outcomes.';

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
COMMENT ON TYPE vision.verdict IS
  'NO_READ = frame rejected by the quality gate (blur/exposure). Distinct from PASS: nothing was actually judged.';

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
-- 7. QUALITY — SPC, capability, cases, FMEA, MOULDING  [platform section 7, verbatim]
--    quality.mould / shot / shot_part / timeline_event are MoldMind's (SRS-11 §5);
--    quality.case / hypothesis / artifact are QE-Agent's and receive the FR-26 8D handoff.
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
-- 8. KNOWLEDGE — documents, cases, glossary  [platform section 9, verbatim]
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
-- 9. AUDIT  [platform section 13, verbatim]
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
-- 9a. PLATFORM INDEXES, TRIGGERS AND VIEWS  [verbatim]
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

-- =====================================================================
-- 10. MOLDMIND — types
-- =====================================================================

CREATE TYPE moldmind.defect_class AS ENUM ('short_shot', 'flash', 'sink_mark', 'burn_mark', 'weld_line', 'silver_streak', 'warpage', 'contamination', 'colour_deviation', 'scratch');
CREATE TYPE moldmind.part_region  AS ENUM ('gate_area', 'far_end', 'rib', 'boss', 'parting_line', 'other');
CREATE TYPE moldmind.advice_kind  AS ENUM ('check', 'action');
CREATE TYPE moldmind.kb_status    AS ENUM ('draft', 'approved', 'retired');
CREATE TYPE moldmind.rca_status   AS ENUM ('open', 'dialogue', 'advised', 'acting', 'verifying', 'closed');
CREATE TYPE moldmind.closure_kind AS ENUM ('verified', 'design_cause', 'unresolved');
CREATE TYPE moldmind.outcome_kind AS ENUM ('effective', 'not_effective', 'inconclusive');

COMMENT ON TYPE moldmind.defect_class IS 'SRS-11 FR-06 — the ten injection-moulding classes. contamination = contamination / black spot.';

-- =====================================================================
-- 11. MOLDMIND — machine connections, buffering, shot context, alignment, defects
-- =====================================================================

CREATE TABLE moldmind.migration (
    id          text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    note        text
);

CREATE TABLE moldmind.machine_connection (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id       uuid        NOT NULL UNIQUE REFERENCES core.machine(id) ON DELETE CASCADE,
    protocol         text        NOT NULL CHECK (protocol IN ('opcua_euromap77', 'euromap63_file', 'mqtt')),
    endpoint         text        NOT NULL,
    security_policy  text        NOT NULL DEFAULT 'Basic256Sha256/SignAndEncrypt',
    credential_ref   text        NOT NULL,                       -- name of the secret file, never the secret
    credential_kind  text        NOT NULL DEFAULT 'read_only' CHECK (credential_kind IN ('read_only', 'read_write')),
    buffer_hours     integer     NOT NULL DEFAULT 24 CHECK (buffer_hours >= 24),
    active           boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE moldmind.machine_connection IS
  'ICD-11 IF-05. The account is read-only, enforced at the OPC-UA server; trg_machine_readonly refuses anything else (C-01, NFR-06).';

CREATE TABLE moldmind.node_map_version (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    connection_id  uuid        NOT NULL REFERENCES moldmind.machine_connection(id) ON DELETE CASCADE,
    version        text        NOT NULL,
    checksum       text        NOT NULL,
    nodes_json     jsonb       NOT NULL,                         -- [{node_id, signal, unit, access}]
    validated_at   timestamptz,
    active         boolean     NOT NULL DEFAULT false,
    CONSTRAINT node_map_version_unique UNIQUE (connection_id, version)
);

CREATE TABLE moldmind.gateway_batch (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    connection_id   uuid        NOT NULL REFERENCES moldmind.machine_connection(id) ON DELETE CASCADE,
    outage_from     timestamptz NOT NULL,
    outage_to       timestamptz NOT NULL,
    shots_buffered  integer     NOT NULL CHECK (shots_buffered >= 0),
    shots_inserted  integer     NOT NULL DEFAULT 0 CHECK (shots_inserted >= 0),
    duplicates      integer     NOT NULL DEFAULT 0 CHECK (duplicates >= 0),
    reconciled_at   timestamptz,
    reason          text,
    CONSTRAINT batch_window CHECK (outage_to > outage_from),
    CONSTRAINT batch_accounted CHECK (reconciled_at IS NULL OR shots_inserted + duplicates = shots_buffered)
);

COMMENT ON TABLE moldmind.gateway_batch IS 'NFR-05 / AC-09: shots buffered at the gateway during a connection loss and reconciled by shot id on reconnect.';

CREATE TABLE moldmind.startup_event (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id    uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    mould_id      uuid        REFERENCES quality.mould(id) ON DELETE SET NULL,
    ts            timestamptz NOT NULL,
    kind          text        NOT NULL CHECK (kind IN ('startup_after_stop', 'mould_change', 'purge', 'material_change')),
    stop_minutes  integer     CHECK (stop_minutes IS NULL OR stop_minutes >= 0),
    transient_shots integer   NOT NULL DEFAULT 20 CHECK (transient_shots BETWEEN 1 AND 200)
);

CREATE TABLE moldmind.shot_ext (
    shot_id            uuid PRIMARY KEY REFERENCES quality.shot(id) ON DELETE CASCADE,
    controller_shot_no bigint,
    sku_id             uuid        REFERENCES core.sku(id) ON DELETE SET NULL,
    cavity_count       smallint    NOT NULL CHECK (cavity_count > 0),
    regrind_pct        numeric(5,2) CHECK (regrind_pct IS NULL OR (regrind_pct >= 0 AND regrind_pct <= 100)),
    dryer_temp_c       numeric(6,1),
    dryer_hours        numeric(5,1),
    ambient_temp_c     numeric(5,1),
    ambient_rh_pct     numeric(5,1),
    operator_group     text,
    startup_event_id   uuid        REFERENCES moldmind.startup_event(id) ON DELETE SET NULL,
    seq_after_startup  integer,
    startup_transient  boolean     NOT NULL DEFAULT false,
    dq_flags_json      jsonb       NOT NULL DEFAULT '[]'::jsonb,     -- FR-05: ["missing_zone_temp:3", "stuck_value:cushion", "clock_skew:2.4s"]
    batch_id           uuid        REFERENCES moldmind.gateway_batch(id) ON DELETE SET NULL,
    created_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE moldmind.shot_ext IS
  'FR-02 shot context beyond the platform columns of quality.shot; FR-05 data-quality flags; FR-16 startup transient classification (trg_shot_transient).';

CREATE TABLE moldmind.image_alignment (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    shot_part_id   uuid        NOT NULL UNIQUE REFERENCES quality.shot_part(id) ON DELETE CASCADE,
    inspection_id  uuid        NOT NULL,
    inspection_ts  timestamptz NOT NULL,
    image_ts       timestamptz NOT NULL,
    shot_ts        timestamptz NOT NULL,
    delta_ms       integer     GENERATED ALWAYS AS ((extract(epoch FROM (image_ts - shot_ts)) * 1000)::integer) STORED,
    tolerance_ms   integer     NOT NULL DEFAULT 1500 CHECK (tolerance_ms BETWEEN 100 AND 30000),
    align_method   text        NOT NULL CHECK (align_method IN ('shot_id', 'timestamp')),
    cavity_method  text        NOT NULL CHECK (cavity_method IN ('ocr_marking', 'robot_position', 'sequence')),
    ocr_text       text,
    FOREIGN KEY (inspection_id, inspection_ts) REFERENCES vision.inspection(id, ts) ON DELETE CASCADE
);

COMMENT ON TABLE moldmind.image_alignment IS
  'FR-03 / FR-08 / AC-02 (ICD-11 IF-58): how each part image was tied to its shot (within tolerance) and its cavity (by which method). trg_alignment_tolerance refuses an image outside the tolerance.';

CREATE TABLE moldmind.colour_reference (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sku_id             uuid        NOT NULL REFERENCES core.sku(id) ON DELETE CASCADE,
    chart_id           text        NOT NULL,
    lab_l              numeric(6,2) NOT NULL,
    lab_a              numeric(6,2) NOT NULL,
    lab_b              numeric(6,2) NOT NULL,
    delta_e_threshold  numeric(4,2) NOT NULL DEFAULT 2.00 CHECK (delta_e_threshold > 0),
    lighting_ref       text,
    valid_from         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT colour_reference_unique UNIQUE (sku_id, chart_id, valid_from)
);

CREATE TABLE moldmind.shot_defect (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    shot_part_id    uuid        NOT NULL REFERENCES quality.shot_part(id) ON DELETE CASCADE,
    defect_class    moldmind.defect_class NOT NULL,
    confidence      numeric(5,4) NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    region          moldmind.part_region NOT NULL DEFAULT 'other',
    bbox_json       jsonb,
    delta_e         numeric(6,3) CHECK (delta_e IS NULL OR delta_e >= 0),
    anomaly_score   numeric(5,4) CHECK (anomaly_score IS NULL OR (anomaly_score >= 0 AND anomaly_score <= 1)),
    model_version   text        NOT NULL,
    review_required boolean     NOT NULL DEFAULT false,
    review_verdict  vision.verdict,
    reviewed_by     uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    reviewed_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT defect_review_complete CHECK ((review_verdict IS NULL AND reviewed_by IS NULL AND reviewed_at IS NULL) OR (review_verdict IS NOT NULL AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)),
    CONSTRAINT colour_has_delta_e CHECK (defect_class <> 'colour_deviation' OR delta_e IS NOT NULL)
);

COMMENT ON TABLE moldmind.shot_defect IS
  'SRS-11 §5 shot_defect. C-02: joinable to exactly one shot and one cavity through shot_part (NOT NULL FK + trg_defect_joinable). FR-11: review_required routes to the queue; the human verdict is stored here and in vision.verdict_override.';

CREATE TABLE moldmind.parameter_window (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    mould_id       uuid        NOT NULL REFERENCES quality.mould(id) ON DELETE CASCADE,
    material_grade text        NOT NULL,
    parameter      text        NOT NULL,
    unit           text        NOT NULL,
    lo             numeric(12,3) NOT NULL,
    hi             numeric(12,3) NOT NULL,
    source         text        NOT NULL,                          -- mould datasheet / material datasheet / process validation
    approved_by    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    CONSTRAINT window_ordered CHECK (hi > lo),
    CONSTRAINT window_unique UNIQUE (mould_id, material_grade, parameter)
);

COMMENT ON TABLE moldmind.parameter_window IS 'C-05 / AI-09: the documented mould × material limits. trg_suggestion_window blocks any suggestion outside.';

CREATE TABLE moldmind.setup_sheet_version (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    mould_id     uuid        NOT NULL REFERENCES quality.mould(id) ON DELETE CASCADE,
    version      integer     NOT NULL,
    params_json  jsonb       NOT NULL,                            -- {holding_pressure: {target, tol}, cushion: {target, lo, hi}, ...}
    material_grade text      NOT NULL,
    author_id    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    approved_by  uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    approved_at  timestamptz,
    active       boolean     NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT setup_version_unique UNIQUE (mould_id, version),
    CONSTRAINT setup_active_is_approved CHECK (NOT active OR approved_at IS NOT NULL)
);

COMMENT ON TABLE moldmind.setup_sheet_version IS 'FR-18 golden run: the approved setup sheet the current parameters are compared with; one active version per mould (idx_setup_active).';

CREATE TABLE moldmind.parameter_change (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    machine_id        uuid        NOT NULL REFERENCES core.machine(id) ON DELETE CASCADE,
    mould_id          uuid        REFERENCES quality.mould(id) ON DELETE SET NULL,
    ts                timestamptz NOT NULL,
    parameter         text        NOT NULL,
    old_value         numeric(12,3),
    new_value         numeric(12,3) NOT NULL,
    unit              text,
    changed_by        text,                                       -- controller user field or a named person
    source            text        NOT NULL DEFAULT 'controller' CHECK (source IN ('controller', 'manual_entry')),
    timeline_event_id uuid        REFERENCES quality.timeline_event(id) ON DELETE SET NULL
);

COMMENT ON TABLE moldmind.parameter_change IS 'FR-04: who/when/old/new. trg_parameter_change_event writes the quality.timeline_event(kind = parameter_edit) the analysers correlate against.';

-- =====================================================================
-- 12. MOLDMIND — knowledge base (C-03, FR-19, FR-25, AI-08, NFR-08)
-- =====================================================================

CREATE TABLE moldmind.kb_defect (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    class           moldmind.defect_class NOT NULL UNIQUE,
    description_th  text NOT NULL,
    description_ja  text NOT NULL,
    description_en  text NOT NULL
);

CREATE TABLE moldmind.kb_version (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    version      text        NOT NULL UNIQUE,
    status       moldmind.kb_status NOT NULL DEFAULT 'draft',
    author_id    uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE RESTRICT,
    approved_by  uuid        REFERENCES core.app_user(id) ON DELETE RESTRICT,
    approved_at  timestamptz,
    checksum     text        NOT NULL,                            -- sha256 of the YAML set (deploy/kb/*.yaml)
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT kb_approval_complete CHECK ((status <> 'approved') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);

COMMENT ON TABLE moldmind.kb_version IS
  'NFR-08 / AI-08: every knowledge-base change is a version with author and approver (process engineer, not the author). Approved versions are immutable (trg_kb_version_immutable); only approved versions rank (trg_rca_session_rules).';

CREATE TABLE moldmind.kb_cause (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    version_id          uuid        NOT NULL REFERENCES moldmind.kb_version(id) ON DELETE CASCADE,
    defect_id           uuid        NOT NULL REFERENCES moldmind.kb_defect(id) ON DELETE CASCADE,
    cause_code          text        NOT NULL,
    cause_th            text,
    cause_ja            text,
    cause_en            text        NOT NULL,
    prior_weight        numeric(4,3) NOT NULL CHECK (prior_weight > 0 AND prior_weight <= 1),
    typical_params_json jsonb       NOT NULL DEFAULT '{}'::jsonb,   -- {holding_pressure: "down", cushion: "low"}
    checks_json         jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- ["Verify cushion vs setup sheet (target 3–6 mm)", ...]
    actions_json        jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- [{param, direction, range, window_ref, side_effects}]
    side_effects        text,
    source              text        NOT NULL CHECK (length(btrim(source)) > 0),
    note                text,
    design_cause        boolean     NOT NULL DEFAULT false,         -- not correctable by parameters — route to engineering
    CONSTRAINT kb_cause_unique UNIQUE (version_id, defect_id, cause_code)
);

COMMENT ON COLUMN moldmind.kb_cause.source IS 'AI-08: textbook, supplier datasheet or internal case — mandatory. trg_kb_cause_shape also checks that every action carries direction, range, window_ref and side_effects (FR-23).';

CREATE TABLE moldmind.kb_case_evidence (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    cause_id        uuid        NOT NULL REFERENCES moldmind.kb_cause(id) ON DELETE CASCADE,
    rca_session_id  uuid        NOT NULL,                          -- FK added after rca_session exists
    outcome         moldmind.outcome_kind NOT NULL,
    action          text        NOT NULL,
    before_rate     numeric(6,4) NOT NULL,
    after_rate      numeric(6,4) NOT NULL,
    p_value         numeric(10,8) NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT kb_evidence_unique UNIQUE (cause_id, rca_session_id)
);

COMMENT ON TABLE moldmind.kb_case_evidence IS 'FR-25: verified cause–action–outcome triplets written back by trg_evidence_writeback; they feed the case component of cause_score().';

CREATE TABLE moldmind.scoring_config (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    version     text        NOT NULL UNIQUE,
    w_prior     numeric(4,3) NOT NULL CHECK (w_prior >= 0),
    w_delta     numeric(4,3) NOT NULL CHECK (w_delta >= 0),
    w_timeline  numeric(4,3) NOT NULL CHECK (w_timeline >= 0),
    w_case      numeric(4,3) NOT NULL CHECK (w_case >= 0),
    active      boolean     NOT NULL DEFAULT false,
    set_by      uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT weights_sum_one CHECK (abs(w_prior + w_delta + w_timeline + w_case - 1) < 0.0005)
);

COMMENT ON TABLE moldmind.scoring_config IS 'AI-05: the transparent scoring function score = w_prior·prior + w_delta·delta + w_timeline·timeline + w_case·case; weights sum to 1.';

-- =====================================================================
-- 13. MOLDMIND — RCA sessions, scores, dialogue, advice, suggestions, outcomes
-- =====================================================================

CREATE TABLE moldmind.rca_session (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    opened_at          timestamptz NOT NULL DEFAULT now(),
    opened_by          uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    defect_class       moldmind.defect_class NOT NULL,
    mould_id           uuid        NOT NULL REFERENCES quality.mould(id) ON DELETE CASCADE,
    machine_id         uuid        REFERENCES core.machine(id) ON DELETE SET NULL,
    window_from        timestamptz NOT NULL,
    window_to          timestamptz NOT NULL,
    kb_version_id      uuid        NOT NULL REFERENCES moldmind.kb_version(id) ON DELETE RESTRICT,
    scoring_config_id  uuid        NOT NULL REFERENCES moldmind.scoring_config(id) ON DELETE RESTRICT,
    lang               core.language_code NOT NULL DEFAULT 'th',
    status             moldmind.rca_status NOT NULL DEFAULT 'open',
    facts_json         jsonb,                                     -- ICD-11 IF-60: what the dialogue model receives
    verified_cause_id  uuid        REFERENCES moldmind.kb_cause(id) ON DELETE SET NULL,
    verified_by        uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    verified_at        timestamptz,
    closure_kind       moldmind.closure_kind,
    closed_at          timestamptz,
    qe_case_id         uuid        REFERENCES quality.case(id) ON DELETE SET NULL,   -- FR-26 handoff
    CONSTRAINT rca_window CHECK (window_to > window_from),
    CONSTRAINT rca_closed_complete CHECK ((status <> 'closed') OR (closed_at IS NOT NULL AND closure_kind IS NOT NULL)),
    CONSTRAINT rca_verified_complete CHECK ((verified_cause_id IS NULL) = (verified_by IS NULL) AND (verified_cause_id IS NULL) = (verified_at IS NULL))
);

ALTER TABLE moldmind.kb_case_evidence ADD CONSTRAINT kb_case_evidence_session_fk FOREIGN KEY (rca_session_id) REFERENCES moldmind.rca_session(id) ON DELETE CASCADE;

CREATE TABLE moldmind.rca_cause_score (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    session_id  uuid        NOT NULL REFERENCES moldmind.rca_session(id) ON DELETE CASCADE,
    cause_id    uuid        NOT NULL REFERENCES moldmind.kb_cause(id) ON DELETE CASCADE,
    turn_no     smallint    NOT NULL DEFAULT 0 CHECK (turn_no >= 0),
    prior_c     numeric(5,4) NOT NULL CHECK (prior_c >= 0 AND prior_c <= 1),
    delta_c     numeric(5,4) NOT NULL CHECK (delta_c >= 0 AND delta_c <= 1),
    timeline_c  numeric(5,4) NOT NULL CHECK (timeline_c >= 0 AND timeline_c <= 1),
    case_c      numeric(5,4) NOT NULL CHECK (case_c >= 0 AND case_c <= 1),
    score       numeric(5,4) NOT NULL,
    rank        smallint    NOT NULL CHECK (rank > 0),
    evidence_json jsonb     NOT NULL DEFAULT '[]'::jsonb,        -- why each component has its value
    CONSTRAINT cause_score_unique UNIQUE (session_id, cause_id, turn_no)
);

COMMENT ON TABLE moldmind.rca_cause_score IS
  'AI-05 / AI-06: the ranking is inspectable — every component is stored per cause per turn and trg_cause_score_transparent recomputes score from the session''s weights.';

CREATE TABLE moldmind.rca_turn (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    session_id    uuid        NOT NULL REFERENCES moldmind.rca_session(id) ON DELETE CASCADE,
    turn_no       smallint    NOT NULL CHECK (turn_no > 0),
    question_key  text        NOT NULL,                            -- KB check key, e.g. material_dried_per_spec
    question_text text        NOT NULL,
    lang          core.language_code NOT NULL,
    answer        text,
    answer_norm   text        CHECK (answer_norm IS NULL OR answer_norm IN ('yes', 'no', 'unknown', 'value')),
    answered_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    asked_at      timestamptz NOT NULL DEFAULT now(),
    answered_at   timestamptz,
    CONSTRAINT rca_turn_unique UNIQUE (session_id, turn_no)
);

CREATE TABLE moldmind.rca_advice (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    session_id      uuid        NOT NULL REFERENCES moldmind.rca_session(id) ON DELETE CASCADE,
    ordinal         smallint    NOT NULL CHECK (ordinal > 0),
    kind            moldmind.advice_kind NOT NULL,
    cause_id        uuid        REFERENCES moldmind.kb_cause(id) ON DELETE SET NULL,
    text_th         text,
    text_ja         text,
    text_en         text        NOT NULL,
    parameter       text,
    direction       text        CHECK (direction IS NULL OR direction IN ('up', 'down')),
    magnitude_range text,                                          -- "+5..+15 %"
    window_ref      text,                                          -- "setup_sheet v2" / parameter_window id
    side_effects    text,
    done            boolean     NOT NULL DEFAULT false,
    done_by         uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    done_at         timestamptz,
    CONSTRAINT advice_unique UNIQUE (session_id, ordinal),
    CONSTRAINT action_is_complete CHECK (kind = 'check' OR (parameter IS NOT NULL AND direction IS NOT NULL AND magnitude_range IS NOT NULL AND window_ref IS NOT NULL AND side_effects IS NOT NULL))
);

COMMENT ON TABLE moldmind.rca_advice IS
  'C-04 / FR-22 / FR-23: checks and parameter changes are different kinds; trg_advice_check_first refuses an action ordered before any check of the session; every action carries direction, magnitude range, window reference and side effects.';

CREATE TABLE moldmind.parameter_suggestion (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    session_id       uuid        NOT NULL REFERENCES moldmind.rca_session(id) ON DELETE CASCADE,
    advice_id        uuid        REFERENCES moldmind.rca_advice(id) ON DELETE SET NULL,
    parameter        text        NOT NULL,
    unit             text,
    current_value    numeric(12,3) NOT NULL,
    suggested_value  numeric(12,3) NOT NULL,
    direction        text        NOT NULL CHECK (direction IN ('up', 'down')),
    magnitude_pct    numeric(6,2) NOT NULL,
    window_id        uuid        REFERENCES moldmind.parameter_window(id) ON DELETE SET NULL,
    window_lo        numeric(12,3),
    window_hi        numeric(12,3),
    allowed          boolean     NOT NULL DEFAULT false,
    blocked          boolean     NOT NULL DEFAULT false,
    block_reason     text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT suggestion_state CHECK (allowed <> blocked),
    CONSTRAINT suggestion_blocked_has_reason CHECK (NOT blocked OR block_reason IS NOT NULL)
);

COMMENT ON TABLE moldmind.parameter_suggestion IS
  'C-05 / AI-09 / AC-05: trg_suggestion_window sets allowed/blocked from parameter_window; an out-of-window suggestion is stored blocked with an audit row and can never be allowed.';

CREATE TABLE moldmind.action_outcome (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    session_id   uuid        NOT NULL REFERENCES moldmind.rca_session(id) ON DELETE CASCADE,
    advice_id    uuid        REFERENCES moldmind.rca_advice(id) ON DELETE SET NULL,
    action       text        NOT NULL,
    applied_at   timestamptz NOT NULL,
    applied_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    before_x     integer     NOT NULL CHECK (before_x >= 0),
    before_n     integer     NOT NULL CHECK (before_n > 0),
    after_x      integer     NOT NULL CHECK (after_x >= 0),
    after_n      integer     NOT NULL CHECK (after_n > 0),
    before_rate  numeric(6,4),
    after_rate   numeric(6,4),
    z            numeric(8,4),
    p_value      numeric(10,8),
    effective    boolean,
    outcome      moldmind.outcome_kind,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT outcome_counts CHECK (before_x <= before_n AND after_x <= after_n)
);

COMMENT ON TABLE moldmind.action_outcome IS 'FR-24 / AC-07: before/after defect rates compared with the two-proportion test; trg_action_effective computes rate, z, p, effective and outcome — they are never typed.';

CREATE TABLE moldmind.cavity_flag (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    mould_id    uuid        NOT NULL REFERENCES quality.mould(id) ON DELETE CASCADE,
    defect_class moldmind.defect_class,
    window_from timestamptz NOT NULL,
    window_to   timestamptz NOT NULL,
    cavity_no   smallint    NOT NULL CHECK (cavity_no > 0),
    x           integer     NOT NULL CHECK (x >= 0),
    n           integer     NOT NULL CHECK (n > 0),
    others_x    integer     NOT NULL CHECK (others_x >= 0),
    others_n    integer     NOT NULL CHECK (others_n > 0),
    z           numeric(8,4),
    p_value     numeric(10,8),
    flagged     boolean,
    computed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE moldmind.scrap_cost_config (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sku_id        uuid        NOT NULL REFERENCES core.sku(id) ON DELETE CASCADE,
    unit_cost_thb numeric(10,2) NOT NULL CHECK (unit_cost_thb >= 0),
    valid_from    date        NOT NULL,
    CONSTRAINT scrap_cost_unique UNIQUE (sku_id, valid_from)
);

CREATE TABLE moldmind.vision_eval_run (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ran_at         timestamptz NOT NULL DEFAULT now(),
    model_version  text        NOT NULL,
    family         text        NOT NULL,
    holdout_n      integer     NOT NULL CHECK (holdout_n > 0),
    map50          numeric(5,4) NOT NULL CHECK (map50 >= 0 AND map50 <= 1),
    recall_json    jsonb       NOT NULL,                           -- {short_shot: 0.97, flash: 0.96, contamination: 0.95, ...}
    passed         boolean,
    notes          text
);

COMMENT ON TABLE moldmind.vision_eval_run IS 'AI-02 / AC-01: mAP@50 ≥ 0.80 and recall ≥ 0.95 for short_shot, flash and contamination; passed is computed by trg_vision_gate.';

CREATE TABLE moldmind.golden_run (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ran_at             timestamptz NOT NULL DEFAULT now(),
    kb_version_id      uuid        NOT NULL REFERENCES moldmind.kb_version(id) ON DELETE RESTRICT,
    scoring_config_id  uuid        NOT NULL REFERENCES moldmind.scoring_config(id) ON DELETE RESTRICT,
    incidents          integer     NOT NULL CHECK (incidents >= 0),
    top3_hits          integer     NOT NULL CHECK (top3_hits >= 0),
    top3_rate          numeric(5,4),
    passed             boolean,
    notes              text,
    CONSTRAINT golden_hits_bounded CHECK (top3_hits <= incidents)
);

COMMENT ON TABLE moldmind.golden_run IS 'AI-07 / AC-04: ≥ 15 historical incidents; true cause in top-3 for ≥ 70 %; passed computed by trg_golden_gate.';

CREATE TABLE moldmind.prompt_template (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind         text        NOT NULL CHECK (kind IN ('rca_question', 'explain')),
    lang         core.language_code,
    version      text        NOT NULL,
    path         text        NOT NULL,
    checksum     text        NOT NULL,
    temperature  numeric(3,2) NOT NULL CHECK (temperature >= 0 AND temperature <= 0.3),
    active       boolean     NOT NULL DEFAULT false,
    CONSTRAINT prompt_version_unique UNIQUE (kind, version)
);

INSERT INTO moldmind.migration (id, note) VALUES ('moldmind_0001', 'MoldMind extension — DDS-11 v1.0');

-- =====================================================================
-- 14. MOLDMIND — functions (twins of the analytics; TEST-11 TC-005 re-derives them in Python)
-- =====================================================================

-- Standard normal upper tail — Abramowitz–Stegun 7.1.26 (max abs error 7e-8).
CREATE OR REPLACE FUNCTION moldmind.norm_sf(z double precision) RETURNS double precision
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE x double precision := abs(z) / sqrt(2.0); t double precision := 1.0 / (1.0 + 0.3275911 * x); y double precision;
BEGIN
    y := 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
    RETURN CASE WHEN z >= 0 THEN (1.0 - y) / 2.0 ELSE 1.0 - (1.0 - y) / 2.0 END;
END;
$$;

-- Two-proportion z-test with continuity correction (two-sided p). FR-12 cavity vs others, FR-24 before/after.
CREATE OR REPLACE FUNCTION moldmind.two_proportion_z(x1 integer, n1 integer, x2 integer, n2 integer)
RETURNS TABLE (z numeric, p_value numeric)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE p1 double precision := x1::double precision / n1; p2 double precision := x2::double precision / n2;
        pp double precision := (x1 + x2)::double precision / (n1 + n2); se double precision; d double precision; zz double precision;
BEGIN
    se := sqrt(pp * (1 - pp) * (1.0 / n1 + 1.0 / n2));
    IF se = 0 THEN RETURN QUERY SELECT 0::numeric, 1::numeric; RETURN; END IF;
    d := abs(p1 - p2) - 0.5 * (1.0 / n1 + 1.0 / n2);
    IF d < 0 THEN d := 0; END IF;
    zz := sign(p1 - p2) * d / se;
    RETURN QUERY SELECT round(zz::numeric, 4), round((2 * moldmind.norm_sf(abs(zz)))::numeric, 8);
END;
$$;

-- Welch's t and Cohen's d (pooled sd) for a good-vs-defective parameter comparison (FR-13).
CREATE OR REPLACE FUNCTION moldmind.welch_t(m1 numeric, s1 numeric, n1 integer, m2 numeric, s2 numeric, n2 integer)
RETURNS TABLE (t numeric, df numeric)
LANGUAGE sql IMMUTABLE AS $$
    SELECT round(((m1 - m2) / sqrt(s1 * s1 / n1 + s2 * s2 / n2))::numeric, 4),
           round((power(s1 * s1 / n1 + s2 * s2 / n2, 2) / (power(s1 * s1 / n1, 2) / (n1 - 1) + power(s2 * s2 / n2, 2) / (n2 - 1)))::numeric, 2);
$$;

CREATE OR REPLACE FUNCTION moldmind.cohens_d(m1 numeric, s1 numeric, n1 integer, m2 numeric, s2 numeric, n2 integer) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round(((m1 - m2) / sqrt(((n1 - 1) * s1 * s1 + (n2 - 1) * s2 * s2) / (n1 + n2 - 2)))::numeric, 4);
$$;

-- Least-squares slope of a series against its index (FR-14 drift: units per shot).
CREATE OR REPLACE FUNCTION moldmind.drift_slope(vals numeric[]) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    WITH s AS (SELECT (ord - 1)::numeric AS x, v AS y FROM unnest(vals) WITH ORDINALITY AS u(v, ord)),
         m AS (SELECT avg(x) AS mx, avg(y) AS my FROM s)
    SELECT round(sum((x - mx) * (y - my)) / NULLIF(sum((x - mx) * (x - mx)), 0), 6) FROM s, m;
$$;

CREATE OR REPLACE FUNCTION moldmind.in_window(v numeric, lo numeric, hi numeric) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT v >= lo AND v <= hi; $$;

-- CIE76 colour difference (AI-04): the reference chart is in frame; ΔE is measured, not inferred.
CREATE OR REPLACE FUNCTION moldmind.delta_e76(l1 numeric, a1 numeric, b1 numeric, l2 numeric, a2 numeric, b2 numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round(sqrt(power(l1 - l2, 2) + power(a1 - a2, 2) + power(b1 - b2, 2))::numeric, 3);
$$;

-- AI-05: the transparent scoring function.
CREATE OR REPLACE FUNCTION moldmind.cause_score(prior_c numeric, delta_c numeric, timeline_c numeric, case_c numeric, cfg uuid) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT round(c.w_prior * prior_c + c.w_delta * delta_c + c.w_timeline * timeline_c + c.w_case * case_c, 4)
    FROM moldmind.scoring_config c WHERE c.id = cfg;
$$;

-- FR-16: a shot is a startup transient when it is within the event's transient window.
CREATE OR REPLACE FUNCTION moldmind.is_startup_transient(seq_after integer, transient_shots integer) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT seq_after IS NOT NULL AND seq_after >= 1 AND seq_after <= transient_shots; $$;

-- FR-17
CREATE OR REPLACE FUNCTION moldmind.scrap_cost(qty integer, unit_cost numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$ SELECT round(qty * unit_cost, 2); $$;

CREATE OR REPLACE FUNCTION moldmind.role_rank(r text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE r WHEN 'viewer' THEN 1 WHEN 'inspector' THEN 2 WHEN 'engineer' THEN 3 WHEN 'manager' THEN 4 WHEN 'admin' THEN 5 ELSE 0 END;
$$;

-- =====================================================================
-- 15. MOLDMIND — guard triggers
-- =====================================================================

-- DD-M01 (C-01 / NFR-06): the machine is read-only — credential and node map.
CREATE OR REPLACE FUNCTION moldmind.trg_machine_readonly_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.credential_kind <> 'read_only' THEN
        RAISE EXCEPTION 'MACHINE_READONLY: connection for machine % must use a read-only credential (C-01, NFR-06)', NEW.machine_id;
    END IF;
    IF NEW.security_policy !~* 'SignAndEncrypt' AND NEW.protocol = 'opcua_euromap77' THEN
        RAISE EXCEPTION 'MACHINE_SECURITY: OPC-UA connections require SignAndEncrypt (ICD-00 IF-05)';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_machine_readonly BEFORE INSERT OR UPDATE ON moldmind.machine_connection
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_machine_readonly_fn();

CREATE OR REPLACE FUNCTION moldmind.trg_node_map_readonly_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n jsonb;
BEGIN
    IF jsonb_typeof(NEW.nodes_json) <> 'array' OR jsonb_array_length(NEW.nodes_json) = 0 THEN
        RAISE EXCEPTION 'NODE_MAP_EMPTY: a node map needs at least one node';
    END IF;
    FOR n IN SELECT * FROM jsonb_array_elements(NEW.nodes_json) LOOP
        IF coalesce(n ->> 'access', 'read') <> 'read' THEN
            RAISE EXCEPTION 'NODE_MAP_WRITE: node % requests % access — only read is allowed (C-01)', n ->> 'node_id', n ->> 'access';
        END IF;
        IF n ->> 'signal' IS NULL OR n ->> 'unit' IS NULL OR n ->> 'node_id' IS NULL THEN
            RAISE EXCEPTION 'NODE_MAP_SHAPE: every node needs node_id, signal and unit';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_node_map_readonly BEFORE INSERT OR UPDATE ON moldmind.node_map_version
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_node_map_readonly_fn();

-- DD-M02 (C-02): a part belongs to a real cavity of its mould; a defect belongs to a part.
CREATE OR REPLACE FUNCTION moldmind.trg_shot_part_cavity_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE cav smallint;
BEGIN
    SELECT m.cavities INTO cav FROM quality.shot s JOIN quality.mould m ON m.id = s.mould_id WHERE s.id = NEW.shot_id;
    IF cav IS NULL THEN RAISE EXCEPTION 'SHOT_WITHOUT_MOULD: shot % has no mould — a part cannot be attributed (C-02)', NEW.shot_id; END IF;
    IF NEW.cavity_no > cav THEN RAISE EXCEPTION 'CAVITY_OUT_OF_RANGE: cavity % on a %-cavity mould (C-02)', NEW.cavity_no, cav; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_shot_part_cavity BEFORE INSERT OR UPDATE ON quality.shot_part
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_shot_part_cavity_fn();

CREATE OR REPLACE FUNCTION moldmind.trg_defect_joinable_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM quality.shot_part sp JOIN quality.shot s ON s.id = sp.shot_id WHERE sp.id = NEW.shot_part_id;
    IF n <> 1 THEN RAISE EXCEPTION 'DEFECT_NOT_JOINABLE: defect must reference exactly one shot part with a shot (C-02)'; END IF;
    IF NEW.review_required AND NEW.review_verdict IS NULL AND NEW.confidence >= 0.70 THEN
        NEW.review_required := false;   -- review is for low confidence only; higher confidence is auto-verdict
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_defect_joinable BEFORE INSERT OR UPDATE ON moldmind.shot_defect
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_defect_joinable_fn();

-- DD-M02 (FR-03): the image must lie within the configured tolerance of its shot.
CREATE OR REPLACE FUNCTION moldmind.trg_alignment_tolerance_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE d integer := (extract(epoch FROM (NEW.image_ts - NEW.shot_ts)) * 1000)::integer;
BEGIN
    IF abs(d) > NEW.tolerance_ms THEN
        RAISE EXCEPTION 'ALIGNMENT_TOLERANCE: image is % ms from the shot (tolerance % ms) — not aligned (FR-03)', d, NEW.tolerance_ms;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_alignment_tolerance BEFORE INSERT OR UPDATE ON moldmind.image_alignment
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_alignment_tolerance_fn();

-- DD-M03 (FR-16): startup transient classification from the startup event.
CREATE OR REPLACE FUNCTION moldmind.trg_shot_transient_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE ts_n integer;
BEGIN
    IF NEW.startup_event_id IS NOT NULL THEN
        SELECT transient_shots INTO ts_n FROM moldmind.startup_event WHERE id = NEW.startup_event_id;
        NEW.startup_transient := moldmind.is_startup_transient(NEW.seq_after_startup, ts_n);
    ELSE
        NEW.startup_transient := false;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_shot_transient BEFORE INSERT OR UPDATE ON moldmind.shot_ext
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_shot_transient_fn();

-- DD-M04 (FR-04): every parameter change is a timeline event.
CREATE OR REPLACE FUNCTION moldmind.trg_parameter_change_event_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE ev uuid; ln uuid;
BEGIN
    SELECT line_id INTO ln FROM core.machine WHERE id = NEW.machine_id;
    INSERT INTO quality.timeline_event (ts, line_id, machine_id, mould_id, kind, detail_json)
    VALUES (NEW.ts, ln, NEW.machine_id, NEW.mould_id, 'parameter_edit',
            jsonb_build_object('parameter', NEW.parameter, 'old', NEW.old_value, 'new', NEW.new_value, 'unit', NEW.unit, 'changed_by', NEW.changed_by, 'source', NEW.source))
    RETURNING id INTO ev;
    UPDATE moldmind.parameter_change SET timeline_event_id = ev WHERE id = NEW.id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_parameter_change_event AFTER INSERT ON moldmind.parameter_change
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_parameter_change_event_fn();

-- DD-M05 (C-03 / AI-08 / NFR-08): knowledge base shape, approval and immutability.
CREATE OR REPLACE FUNCTION moldmind.trg_kb_cause_shape_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a jsonb; st moldmind.kb_status;
BEGIN
    SELECT status INTO st FROM moldmind.kb_version WHERE id = NEW.version_id;
    IF st = 'approved' AND TG_OP = 'INSERT' THEN RAISE EXCEPTION 'KB_IMMUTABLE: version is approved — create a new version (NFR-08)'; END IF;
    IF jsonb_typeof(NEW.checks_json) <> 'array' THEN RAISE EXCEPTION 'KB_SHAPE: checks_json must be an array'; END IF;
    IF NOT NEW.design_cause AND jsonb_array_length(NEW.checks_json) = 0 THEN
        RAISE EXCEPTION 'KB_SHAPE: cause % needs at least one check (C-04 check-before-change)', NEW.cause_code;
    END IF;
    FOR a IN SELECT * FROM jsonb_array_elements(NEW.actions_json) LOOP
        IF a ->> 'param' IS NULL OR coalesce(a ->> 'direction', '') NOT IN ('up', 'down') OR a ->> 'range' IS NULL OR a ->> 'window_ref' IS NULL OR a ->> 'side_effects' IS NULL THEN
            RAISE EXCEPTION 'KB_ACTION_SHAPE: every action needs param, direction (up|down), range, window_ref and side_effects (FR-23)';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_kb_cause_shape BEFORE INSERT OR UPDATE ON moldmind.kb_cause
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_kb_cause_shape_fn();

CREATE OR REPLACE FUNCTION moldmind.trg_kb_version_rules_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
    IF NEW.status = 'approved' THEN
        IF NEW.approved_by = NEW.author_id THEN RAISE EXCEPTION 'KB_SELF_APPROVAL: author and approver must differ (AI-08)'; END IF;
        SELECT role INTO r FROM core.app_user WHERE id = NEW.approved_by;
        IF moldmind.role_rank(r) < moldmind.role_rank('engineer') THEN RAISE EXCEPTION 'ROLE_INSUFFICIENT: a process engineer (engineer+) approves knowledge (AI-08), got %', r; END IF;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status = 'approved' THEN
        IF NEW.status NOT IN ('approved', 'retired') OR NEW.checksum <> OLD.checksum OR NEW.approved_by IS DISTINCT FROM OLD.approved_by OR NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
            RAISE EXCEPTION 'KB_IMMUTABLE: approved version % cannot be changed — only retired (NFR-08)', OLD.version;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_kb_version_immutable BEFORE INSERT OR UPDATE ON moldmind.kb_version
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_kb_version_rules_fn();

-- DD-M06 (AI-05 / AI-06): scores are recomputed from the stored components and the session's weights.
CREATE OR REPLACE FUNCTION moldmind.trg_cause_score_transparent_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE cfg uuid; expected numeric;
BEGIN
    SELECT scoring_config_id INTO cfg FROM moldmind.rca_session WHERE id = NEW.session_id;
    expected := moldmind.cause_score(NEW.prior_c, NEW.delta_c, NEW.timeline_c, NEW.case_c, cfg);
    IF abs(NEW.score - expected) > 0.0001 THEN
        RAISE EXCEPTION 'SCORE_NOT_TRANSPARENT: stored score % differs from the scoring function (%) — the model does not rank (AI-05, AI-06)', NEW.score, expected;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_cause_score_transparent BEFORE INSERT OR UPDATE ON moldmind.rca_cause_score
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_cause_score_transparent_fn();

-- DD-M07 (C-03 / AI-08 / closure): a session ranks only with an approved KB version and closes only with a verdict.
CREATE OR REPLACE FUNCTION moldmind.trg_rca_session_rules_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE st moldmind.kb_status; act boolean;
BEGIN
    SELECT status INTO st FROM moldmind.kb_version WHERE id = NEW.kb_version_id;
    IF st <> 'approved' THEN RAISE EXCEPTION 'KB_NOT_APPROVED: RCA sessions use approved knowledge only (C-03, AI-08)'; END IF;
    SELECT active INTO act FROM moldmind.scoring_config WHERE id = NEW.scoring_config_id;
    IF NOT coalesce(act, false) THEN RAISE EXCEPTION 'SCORING_INACTIVE: the session must use the active scoring configuration'; END IF;
    IF NEW.status = 'closed' AND NEW.closure_kind = 'verified' AND NEW.verified_cause_id IS NULL THEN
        RAISE EXCEPTION 'CLOSURE_UNVERIFIED: a verified closure needs a verified cause';
    END IF;
    IF NEW.verified_cause_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM moldmind.rca_cause_score s WHERE s.session_id = NEW.id AND s.cause_id = NEW.verified_cause_id) THEN
        RAISE EXCEPTION 'CAUSE_NOT_RANKED: the verified cause must be one of the session''s ranked causes';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_rca_session_rules BEFORE INSERT OR UPDATE ON moldmind.rca_session
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_rca_session_rules_fn();

-- DD-M08 (C-04 / FR-22): checks before changes, structurally.
CREATE OR REPLACE FUNCTION moldmind.trg_advice_check_first_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE min_check smallint; n_checks int;
BEGIN
    IF NEW.kind = 'action' THEN
        SELECT count(*), min(ordinal) INTO n_checks, min_check FROM moldmind.rca_advice WHERE session_id = NEW.session_id AND kind = 'check' AND id <> NEW.id;
        IF n_checks = 0 THEN RAISE EXCEPTION 'CHECK_BEFORE_CHANGE: no check exists in the session yet — checks come first (C-04)'; END IF;
        IF EXISTS (SELECT 1 FROM moldmind.rca_advice WHERE session_id = NEW.session_id AND kind = 'check' AND ordinal > NEW.ordinal) THEN
            RAISE EXCEPTION 'CHECK_BEFORE_CHANGE: action ordinal % precedes a check of the session (C-04)', NEW.ordinal;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_advice_check_first BEFORE INSERT OR UPDATE ON moldmind.rca_advice
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_advice_check_first_fn();

-- DD-M09 (C-05 / AI-09 / AC-05): suggestions are validated against the documented window; outside → blocked + audit.
CREATE OR REPLACE FUNCTION moldmind.trg_suggestion_window_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE w record; mat text; mld uuid; asserted_allowed boolean := (NEW.allowed IS TRUE);
BEGIN
    SELECT s.mould_id INTO mld FROM moldmind.rca_session s WHERE s.id = NEW.session_id;
    SELECT ss.material_grade INTO mat FROM moldmind.setup_sheet_version ss WHERE ss.mould_id = mld AND ss.active LIMIT 1;
    SELECT * INTO w FROM moldmind.parameter_window pw WHERE pw.mould_id = mld AND pw.parameter = NEW.parameter AND (mat IS NULL OR pw.material_grade = mat) LIMIT 1;
    IF w IS NULL THEN
        NEW.allowed := false; NEW.blocked := true; NEW.block_reason := 'NO_WINDOW: no documented window for ' || NEW.parameter || ' — suggestion blocked (C-05)';
    ELSE
        NEW.window_id := w.id; NEW.window_lo := w.lo; NEW.window_hi := w.hi;
        IF moldmind.in_window(NEW.suggested_value, w.lo, w.hi) THEN
            NEW.allowed := true; NEW.blocked := false; NEW.block_reason := NULL;
        ELSE
            NEW.allowed := false; NEW.blocked := true;
            NEW.block_reason := format('OUT_OF_WINDOW: %s %s outside [%s, %s] %s (C-05, AI-09)', NEW.parameter, NEW.suggested_value, w.lo, w.hi, w.unit);
        END IF;
    END IF;
    NEW.magnitude_pct := round(100 * (NEW.suggested_value - NEW.current_value) / NULLIF(NEW.current_value, 0), 2);
    IF NEW.blocked AND asserted_allowed THEN
        RAISE EXCEPTION 'OUT_OF_WINDOW: % — a suggestion outside the documented window can never be allowed (C-05, AI-09, AC-05)', NEW.block_reason;
    END IF;
    IF NEW.blocked THEN
        INSERT INTO audit.log (actor, action, entity, entity_id, after_json)
        VALUES ('rca-agent', 'moldmind.suggestion.blocked', 'moldmind.parameter_suggestion', NEW.id::text,
                jsonb_build_object('session', NEW.session_id, 'parameter', NEW.parameter, 'suggested', NEW.suggested_value, 'reason', NEW.block_reason));
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_suggestion_window BEFORE INSERT OR UPDATE ON moldmind.parameter_suggestion
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_suggestion_window_fn();

-- DD-M09 (FR-24 / AC-07): effectiveness is computed, never typed; DD-M05 (FR-25): verified outcomes become knowledge.
CREATE OR REPLACE FUNCTION moldmind.trg_action_effective_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM moldmind.two_proportion_z(NEW.before_x, NEW.before_n, NEW.after_x, NEW.after_n);
    NEW.before_rate := round(NEW.before_x::numeric / NEW.before_n, 4);
    NEW.after_rate  := round(NEW.after_x::numeric / NEW.after_n, 4);
    NEW.z := r.z; NEW.p_value := r.p_value;
    IF NEW.effective IS NOT NULL AND NEW.effective <> (r.p_value < 0.05 AND NEW.after_rate < NEW.before_rate) THEN
        RAISE EXCEPTION 'EFFECTIVE_NOT_TYPED: effectiveness is computed from the test (p = %), not asserted (FR-24)', r.p_value;
    END IF;
    NEW.effective := (r.p_value < 0.05 AND NEW.after_rate < NEW.before_rate);
    NEW.outcome := CASE WHEN NEW.effective THEN 'effective' WHEN r.p_value < 0.05 THEN 'not_effective' ELSE 'inconclusive' END;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_action_effective BEFORE INSERT OR UPDATE ON moldmind.action_outcome
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_action_effective_fn();

CREATE OR REPLACE FUNCTION moldmind.trg_evidence_writeback_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE vc uuid;
BEGIN
    SELECT verified_cause_id INTO vc FROM moldmind.rca_session WHERE id = NEW.session_id;
    IF vc IS NOT NULL AND NEW.outcome IN ('effective', 'not_effective') THEN
        INSERT INTO moldmind.kb_case_evidence (cause_id, rca_session_id, outcome, action, before_rate, after_rate, p_value)
        VALUES (vc, NEW.session_id, NEW.outcome, NEW.action, NEW.before_rate, NEW.after_rate, NEW.p_value)
        ON CONFLICT (cause_id, rca_session_id) DO UPDATE SET outcome = EXCLUDED.outcome, after_rate = EXCLUDED.after_rate, p_value = EXCLUDED.p_value;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_evidence_writeback AFTER INSERT OR UPDATE ON moldmind.action_outcome
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_evidence_writeback_fn();

-- Cavity flag consistency (FR-12): z / p / flagged recomputed from the counts (α 0.01, n ≥ 200).
CREATE OR REPLACE FUNCTION moldmind.trg_cavity_flag_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    SELECT * INTO r FROM moldmind.two_proportion_z(NEW.x, NEW.n, NEW.others_x, NEW.others_n);
    NEW.z := r.z; NEW.p_value := r.p_value;
    NEW.flagged := (NEW.n + NEW.others_n >= 200 AND r.p_value < 0.01 AND NEW.x::numeric / NEW.n > NEW.others_x::numeric / NEW.others_n);
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_cavity_flag BEFORE INSERT OR UPDATE ON moldmind.cavity_flag
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_cavity_flag_fn();

-- Evaluation gates (AI-02, AI-07): computed.
CREATE OR REPLACE FUNCTION moldmind.trg_vision_gate_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.passed := NEW.map50 >= 0.80
              AND coalesce((NEW.recall_json ->> 'short_shot')::numeric, 0) >= 0.95
              AND coalesce((NEW.recall_json ->> 'flash')::numeric, 0) >= 0.95
              AND coalesce((NEW.recall_json ->> 'contamination')::numeric, 0) >= 0.95;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_vision_gate BEFORE INSERT OR UPDATE ON moldmind.vision_eval_run
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_vision_gate_fn();

CREATE OR REPLACE FUNCTION moldmind.trg_golden_gate_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.top3_rate := CASE WHEN NEW.incidents > 0 THEN round(NEW.top3_hits::numeric / NEW.incidents, 4) END;
    NEW.passed := NEW.incidents >= 15 AND NEW.top3_rate >= 0.70;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_golden_gate BEFORE INSERT OR UPDATE ON moldmind.golden_run
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_golden_gate_fn();

-- One active setup sheet per mould; an approved sheet is immutable.
CREATE OR REPLACE FUNCTION moldmind.trg_setup_sheet_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL AND NEW.params_json <> OLD.params_json THEN
        RAISE EXCEPTION 'SETUP_SHEET_IMMUTABLE: approved setup sheet v% cannot be edited — create a new version (FR-18)', OLD.version;
    END IF;
    IF NEW.active THEN
        UPDATE moldmind.setup_sheet_version SET active = false WHERE mould_id = NEW.mould_id AND id <> NEW.id AND active;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_setup_sheet BEFORE INSERT OR UPDATE ON moldmind.setup_sheet_version
    FOR EACH ROW EXECUTE FUNCTION moldmind.trg_setup_sheet_fn();

-- =====================================================================
-- 16. MOLDMIND — indexes and views
-- =====================================================================

CREATE INDEX idx_shot_ext_sku          ON moldmind.shot_ext (sku_id);
CREATE INDEX idx_shot_ext_transient    ON moldmind.shot_ext (startup_event_id) WHERE startup_transient;
CREATE INDEX idx_shot_defect_part      ON moldmind.shot_defect (shot_part_id);
CREATE INDEX idx_shot_defect_class     ON moldmind.shot_defect (defect_class, created_at DESC);
CREATE INDEX idx_shot_defect_review    ON moldmind.shot_defect (created_at DESC) WHERE review_required AND review_verdict IS NULL;
CREATE INDEX idx_alignment_inspection  ON moldmind.image_alignment (inspection_id, inspection_ts);
CREATE INDEX idx_param_change_machine  ON moldmind.parameter_change (machine_id, ts DESC);
CREATE INDEX idx_startup_machine       ON moldmind.startup_event (machine_id, ts DESC);
CREATE INDEX idx_window_lookup         ON moldmind.parameter_window (mould_id, material_grade, parameter);
CREATE UNIQUE INDEX idx_setup_active   ON moldmind.setup_sheet_version (mould_id) WHERE active;
CREATE INDEX idx_kb_cause_defect       ON moldmind.kb_cause (version_id, defect_id, prior_weight DESC);
CREATE INDEX idx_kb_evidence_cause     ON moldmind.kb_case_evidence (cause_id);
CREATE INDEX idx_rca_session_status    ON moldmind.rca_session (status, opened_at DESC);
CREATE INDEX idx_rca_session_mould     ON moldmind.rca_session (mould_id, defect_class, opened_at DESC);
CREATE INDEX idx_cause_score_session   ON moldmind.rca_cause_score (session_id, turn_no, rank);
CREATE INDEX idx_rca_turn_session      ON moldmind.rca_turn (session_id, turn_no);
CREATE INDEX idx_advice_session        ON moldmind.rca_advice (session_id, ordinal);
CREATE INDEX idx_suggestion_blocked    ON moldmind.parameter_suggestion (created_at DESC) WHERE blocked;
CREATE INDEX idx_outcome_session       ON moldmind.action_outcome (session_id);
CREATE INDEX idx_cavity_flag_mould     ON moldmind.cavity_flag (mould_id, computed_at DESC) WHERE flagged;
CREATE INDEX idx_gateway_batch_conn    ON moldmind.gateway_batch (connection_id, outage_from DESC);

-- Per-cavity defect rates in a window, startup transients excluded (FR-12, FR-16)
CREATE OR REPLACE VIEW moldmind.v_cavity_rates AS
SELECT s.mould_id, m.code AS mould_code, sp.cavity_no,
       count(*) AS parts,
       count(*) FILTER (WHERE sp.verdict = 'FAIL') AS failed,
       round(100.0 * count(*) FILTER (WHERE sp.verdict = 'FAIL') / count(*), 4) AS fail_rate_pct,
       min(s.ts) AS window_from, max(s.ts) AS window_to
FROM quality.shot_part sp
JOIN quality.shot s ON s.id = sp.shot_id
JOIN quality.mould m ON m.id = s.mould_id
LEFT JOIN moldmind.shot_ext e ON e.shot_id = s.id
WHERE NOT coalesce(e.startup_transient, false)
GROUP BY s.mould_id, m.code, sp.cavity_no;

-- Defect counts per class per cavity (transients excluded)
CREATE OR REPLACE VIEW moldmind.v_defect_by_cavity AS
SELECT s.mould_id, sp.cavity_no, d.defect_class, count(*) AS defects, min(s.ts) AS first_seen, max(s.ts) AS last_seen
FROM moldmind.shot_defect d
JOIN quality.shot_part sp ON sp.id = d.shot_part_id
JOIN quality.shot s ON s.id = sp.shot_id
LEFT JOIN moldmind.shot_ext e ON e.shot_id = s.id
WHERE NOT coalesce(e.startup_transient, false) AND (d.review_verdict IS NULL OR d.review_verdict = 'FAIL')
GROUP BY s.mould_id, sp.cavity_no, d.defect_class;

-- Good-vs-defective parameter comparison for a class (FR-13): one row per mould × class × parameter with effect size
CREATE OR REPLACE VIEW moldmind.v_parameter_delta AS
WITH parts AS (
    SELECT s.id AS shot_id, s.mould_id, s.ts, s.params_json, s.cushion_mm, s.cycle_time_s,
           EXISTS (SELECT 1 FROM moldmind.shot_defect d JOIN quality.shot_part sp ON sp.id = d.shot_part_id WHERE sp.shot_id = s.id AND d.defect_class = c.cls) AS defective,
           c.cls
    FROM quality.shot s
    LEFT JOIN moldmind.shot_ext e ON e.shot_id = s.id
    CROSS JOIN (SELECT unnest(enum_range(NULL::moldmind.defect_class)) AS cls) c
    WHERE NOT coalesce(e.startup_transient, false)
),
vals AS (
    SELECT mould_id, cls, defective, k.key AS parameter, (k.value)::numeric AS v
    FROM parts, LATERAL jsonb_each_text(params_json || jsonb_build_object('cushion_mm', cushion_mm, 'cycle_time_s', cycle_time_s)) k
    WHERE k.value ~ '^-?[0-9]+(\.[0-9]+)?$'
),
agg AS (
    SELECT mould_id, cls, parameter, defective, count(*) AS n, avg(v) AS mean, coalesce(stddev_samp(v), 0) AS sd
    FROM vals GROUP BY mould_id, cls, parameter, defective
)
SELECT g.mould_id, g.cls AS defect_class, g.parameter,
       b.n AS n_defective, round(b.mean, 3) AS mean_defective, round(b.sd, 3) AS sd_defective,
       g.n AS n_good, round(g.mean, 3) AS mean_good, round(g.sd, 3) AS sd_good,
       round(b.mean - g.mean, 3) AS delta,
       CASE WHEN g.n > 1 AND b.n > 1 AND (g.sd > 0 OR b.sd > 0) THEN moldmind.cohens_d(b.mean, b.sd, b.n, g.mean, g.sd, g.n) END AS cohens_d,
       CASE WHEN g.n > 1 AND b.n > 1 AND g.sd > 0 AND b.sd > 0 THEN (moldmind.welch_t(b.mean, b.sd, b.n, g.mean, g.sd, g.n)).t END AS welch_t
FROM agg g JOIN agg b ON b.mould_id = g.mould_id AND b.cls = g.cls AND b.parameter = g.parameter AND b.defective AND NOT g.defective;

-- Drift of the key parameters over the last 200 shots per mould (FR-14)
CREATE OR REPLACE VIEW moldmind.v_drift AS
WITH last AS (
    SELECT s.mould_id, s.ts, s.cushion_mm, s.cycle_time_s, (s.params_json ->> 'holding_pressure')::numeric AS holding_pressure,
           row_number() OVER (PARTITION BY s.mould_id ORDER BY s.ts DESC) AS rn
    FROM quality.shot s LEFT JOIN moldmind.shot_ext e ON e.shot_id = s.id WHERE NOT coalesce(e.startup_transient, false)
)
SELECT mould_id, count(*) AS shots,
       moldmind.drift_slope(array_agg(cushion_mm ORDER BY ts)) AS cushion_slope_mm_per_shot,
       moldmind.drift_slope(array_agg(cycle_time_s ORDER BY ts)) AS cycle_slope_s_per_shot,
       moldmind.drift_slope(array_agg(holding_pressure ORDER BY ts)) AS holding_slope_bar_per_shot
FROM last WHERE rn <= 200 GROUP BY mould_id;

-- Golden-run comparison: latest shot vs the active setup sheet (FR-18)
CREATE OR REPLACE VIEW moldmind.v_golden_diff AS
WITH latest AS (
    SELECT DISTINCT ON (mould_id) mould_id, ts, params_json || jsonb_build_object('cushion_mm', cushion_mm, 'cycle_time_s', cycle_time_s) AS p
    FROM quality.shot ORDER BY mould_id, ts DESC
)
SELECT ss.mould_id, ss.version AS setup_version, k.key AS parameter,
       (k.value ->> 'target')::numeric AS target, (k.value ->> 'tol')::numeric AS tolerance,
       (l.p ->> k.key)::numeric AS current_value,
       round((l.p ->> k.key)::numeric - (k.value ->> 'target')::numeric, 3) AS deviation,
       abs((l.p ->> k.key)::numeric - (k.value ->> 'target')::numeric) > (k.value ->> 'tol')::numeric AS out_of_tolerance,
       l.ts AS as_of
FROM moldmind.setup_sheet_version ss
JOIN latest l ON l.mould_id = ss.mould_id
CROSS JOIN LATERAL jsonb_each(ss.params_json) k
WHERE ss.active AND l.p ? k.key;

-- Timeline around a mould (FR-15)
CREATE OR REPLACE VIEW moldmind.v_timeline AS
SELECT t.id, t.ts, t.machine_id, t.mould_id, t.kind, t.detail_json FROM quality.timeline_event t
UNION ALL
SELECT se.id, se.ts, se.machine_id, se.mould_id, 'startup:' || se.kind, jsonb_build_object('stop_minutes', se.stop_minutes, 'transient_shots', se.transient_shots) FROM moldmind.startup_event se;

-- RCA board
CREATE OR REPLACE VIEW moldmind.v_rca_board AS
SELECT r.id, r.opened_at, r.defect_class, m.code AS mould_code, r.status, r.lang, r.closure_kind, r.closed_at,
       (SELECT c.cause_code FROM moldmind.rca_cause_score s JOIN moldmind.kb_cause c ON c.id = s.cause_id
         WHERE s.session_id = r.id ORDER BY s.turn_no DESC, s.rank LIMIT 1) AS top_cause,
       (SELECT count(*) FROM moldmind.rca_turn t WHERE t.session_id = r.id AND t.answered_at IS NOT NULL) AS answers,
       (SELECT count(*) FROM moldmind.parameter_suggestion p WHERE p.session_id = r.id AND p.blocked) AS blocked_suggestions,
       (SELECT bool_or(o.effective) FROM moldmind.action_outcome o WHERE o.session_id = r.id) AS effective,
       r.qe_case_id IS NOT NULL AS handed_off
FROM moldmind.rca_session r JOIN quality.mould m ON m.id = r.mould_id;

-- The ranking with its components — what the technician sees under "why this order" (AI-05)
CREATE OR REPLACE VIEW moldmind.v_cause_ranking AS
SELECT s.session_id, s.turn_no, s.rank, c.cause_code, c.cause_en, s.prior_c, s.delta_c, s.timeline_c, s.case_c, s.score,
       cfg.w_prior, cfg.w_delta, cfg.w_timeline, cfg.w_case, s.evidence_json
FROM moldmind.rca_cause_score s
JOIN moldmind.kb_cause c ON c.id = s.cause_id
JOIN moldmind.rca_session r ON r.id = s.session_id
JOIN moldmind.scoring_config cfg ON cfg.id = r.scoring_config_id;

-- Blocked suggestions (AC-05)
CREATE OR REPLACE VIEW moldmind.v_suggestion_audit AS
SELECT p.id, p.created_at, p.session_id, p.parameter, p.current_value, p.suggested_value, p.magnitude_pct, p.window_lo, p.window_hi, p.allowed, p.blocked, p.block_reason
FROM moldmind.parameter_suggestion p;

-- Effectiveness (FR-24)
CREATE OR REPLACE VIEW moldmind.v_effectiveness AS
SELECT o.session_id, o.action, o.applied_at, o.before_x, o.before_n, o.before_rate, o.after_x, o.after_n, o.after_rate, o.z, o.p_value, o.effective, o.outcome
FROM moldmind.action_outcome o;

-- Knowledge-base status (NFR-08)
CREATE OR REPLACE VIEW moldmind.v_kb_status AS
SELECT v.version, v.status, a.username AS author, b.username AS approver, v.approved_at,
       (SELECT count(*) FROM moldmind.kb_cause c WHERE c.version_id = v.id) AS causes,
       (SELECT count(DISTINCT c.defect_id) FROM moldmind.kb_cause c WHERE c.version_id = v.id) AS defects_covered,
       (SELECT count(*) FROM moldmind.kb_case_evidence e JOIN moldmind.kb_cause c ON c.id = e.cause_id WHERE c.version_id = v.id) AS evidence_rows
FROM moldmind.kb_version v LEFT JOIN core.app_user a ON a.id = v.author_id LEFT JOIN core.app_user b ON b.id = v.approved_by;

-- Data quality (FR-05)
CREATE OR REPLACE VIEW moldmind.v_data_quality AS
SELECT s.mould_id, date_trunc('day', s.ts)::date AS day, count(*) AS shots,
       count(*) FILTER (WHERE jsonb_array_length(e.dq_flags_json) > 0) AS flagged_shots,
       count(*) FILTER (WHERE e.startup_transient) AS transient_shots
FROM quality.shot s LEFT JOIN moldmind.shot_ext e ON e.shot_id = s.id
GROUP BY s.mould_id, 2;

-- Scrap cost per class per day (FR-17)
CREATE OR REPLACE VIEW moldmind.v_scrap_cost AS
SELECT date_trunc('day', s.ts)::date AS day, s.mould_id, e.sku_id, d.defect_class, count(*) AS defects,
       moldmind.scrap_cost(count(*)::integer, c.unit_cost_thb) AS cost_thb
FROM moldmind.shot_defect d
JOIN quality.shot_part sp ON sp.id = d.shot_part_id
JOIN quality.shot s ON s.id = sp.shot_id
JOIN moldmind.shot_ext e ON e.shot_id = s.id
JOIN LATERAL (SELECT unit_cost_thb FROM moldmind.scrap_cost_config sc WHERE sc.sku_id = e.sku_id AND sc.valid_from <= s.ts::date ORDER BY sc.valid_from DESC LIMIT 1) c ON true
WHERE (d.review_verdict IS NULL OR d.review_verdict = 'FAIL')
GROUP BY 1, 2, 3, 4, c.unit_cost_thb;

-- Gateway lag and buffering (NFR-05, AC-09)
CREATE OR REPLACE VIEW moldmind.v_gateway_lag AS
SELECT mc.machine_id, m.code AS machine_code, mc.protocol,
       (SELECT max(s.ts) FROM quality.shot s WHERE s.machine_id = mc.machine_id) AS last_shot_ts,
       (SELECT count(*) FROM moldmind.gateway_batch b WHERE b.connection_id = mc.id AND b.reconciled_at IS NULL) AS open_batches,
       (SELECT sum(b.shots_buffered) FROM moldmind.gateway_batch b WHERE b.connection_id = mc.id) AS shots_buffered_total,
       (SELECT sum(b.duplicates) FROM moldmind.gateway_batch b WHERE b.connection_id = mc.id) AS duplicates_total
FROM moldmind.machine_connection mc JOIN core.machine m ON m.id = mc.machine_id;

-- =====================================================================
-- 17. ROLES AND GRANTS (standalone; platform mode keeps the platform's roles and adds gateway_rw, vision_rw, kb_rw)
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')     THEN CREATE ROLE app_rw     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')     THEN CREATE ROLE app_ro     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_ro')   THEN CREATE ROLE agent_ro   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gateway_rw') THEN CREATE ROLE gateway_rw NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vision_rw')  THEN CREATE ROLE vision_rw  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kb_rw')      THEN CREATE ROLE kb_rw      NOLOGIN; END IF;
END
$$;
-- Login passwords are SET_AT_BOOTSTRAP from secret files (OPS-11 §4.2); never in this file.

COMMENT ON ROLE gateway_rw IS 'Machine gateway. Inserts shots, shot context, parameter changes, startup events and batches; reads mould/machine master data; nothing else.';
COMMENT ON ROLE vision_rw  IS 'Vision + aligner. Inserts inspections, detections, shot parts, alignments and defects; reads colour references and models.';
COMMENT ON ROLE kb_rw      IS 'Knowledge-base service. Writes kb_* and scoring_config; cannot touch sessions or outcomes.';

GRANT USAGE ON SCHEMA core, vision, quality, knowledge, moldmind TO app_rw, app_ro;
GRANT USAGE ON SCHEMA audit TO app_rw, app_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, vision, quality, knowledge, moldmind TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO app_rw;

GRANT SELECT ON ALL TABLES IN SCHEMA core, vision, quality, knowledge, moldmind, audit TO app_ro;

-- agent_ro (platform tool layer; Copilot's get_cavity_analysis etc.): read-only, never users/scope/audit
GRANT USAGE ON SCHEMA core, vision, quality, knowledge, moldmind TO agent_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, vision, quality, knowledge, moldmind TO agent_ro;
REVOKE SELECT ON core.app_user       FROM agent_ro;
REVOKE SELECT ON core.user_line_scope FROM agent_ro;
REVOKE SELECT ON moldmind.machine_connection FROM agent_ro;

-- gateway_rw: the narrowest write role
GRANT USAGE ON SCHEMA core, quality, moldmind TO gateway_rw;
GRANT SELECT ON core.machine, core.material_lot, core.sku, quality.mould TO gateway_rw;
GRANT SELECT ON moldmind.machine_connection, moldmind.node_map_version TO gateway_rw;
GRANT INSERT ON quality.shot, quality.timeline_event TO gateway_rw;
GRANT INSERT, UPDATE ON moldmind.shot_ext, moldmind.parameter_change, moldmind.startup_event, moldmind.gateway_batch TO gateway_rw;
GRANT UPDATE (validated_at) ON moldmind.node_map_version TO gateway_rw;

-- vision_rw: inspections, parts, alignments, defects
GRANT USAGE ON SCHEMA core, vision, quality, moldmind TO vision_rw;
GRANT SELECT ON core.sku, core.defect_type, quality.mould, quality.shot, vision.model_registry, vision.camera, vision.recipe, moldmind.colour_reference TO vision_rw;
GRANT INSERT ON vision.inspection, vision.detection, vision.measurement TO vision_rw;
GRANT INSERT, UPDATE ON quality.shot_part, moldmind.image_alignment, moldmind.shot_defect TO vision_rw;

-- kb_rw: knowledge only
GRANT USAGE ON SCHEMA core, moldmind TO kb_rw;
GRANT SELECT ON core.app_user TO kb_rw;
GRANT SELECT, INSERT, UPDATE ON moldmind.kb_defect, moldmind.kb_version, moldmind.kb_cause, moldmind.scoring_config, moldmind.prompt_template TO kb_rw;

ALTER DEFAULT PRIVILEGES IN SCHEMA core, vision, quality, knowledge, moldmind
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, vision, quality, knowledge, moldmind
    GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT INSERT, SELECT ON TABLES TO app_rw;

-- =====================================================================
-- END — DDS-11-MoldMind v1.0
-- =====================================================================
