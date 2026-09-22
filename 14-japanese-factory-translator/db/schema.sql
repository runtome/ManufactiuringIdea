-- =====================================================================
--  GenbaGo — PostgreSQL 16 schema (standalone deployment)
--  DDS-14-GenbaGo v1.0 (Draft) · 2026-09-22 · Suphot N.
--
--  Sections 1–9 are EXTRACTED VERBATIM from ../../00-factorybrain-platform/db/schema.sql
--  (extensions, helpers, the enums the extracted objects use, the whole core section, the knowledge
--  objects GenbaGo owns or reads — document, chunk, glossary_term, tm_segment — audit, their indexes,
--  triggers and views). TEST-14 TC-002 diffs every block and object against the platform file; a
--  difference is a defect in this file, never in the platform's. The knowledge.case_* tables are Genba
--  Memory's (SRS-15) and are not extracted.
--  Sections 10–19 are the GenbaGo extension (schema genba, migration genba_0001).
--
--  Platform mode (SAD-14 §9): apply ONLY sections 10–19 (migration genba_0001) on the platform
--  database; sections 1–9 already exist there. GenbaGo owns knowledge.glossary_term and
--  knowledge.tm_segment (SAD-00 §13) and attaches guard triggers to them in section 16.
--
--  NOT EXECUTED on the authoring machine (no PostgreSQL) — TEST-14 TC-009.
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
CREATE SCHEMA IF NOT EXISTS quality;     -- only the severity enum is used here (core.machine.criticality)
CREATE SCHEMA IF NOT EXISTS knowledge;
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
-- 4. ENUMERATED TYPES  [platform section 4 — the types the extracted objects use, verbatim lines]
-- =====================================================================

CREATE TYPE core.shift_code        AS ENUM ('A', 'B', 'C', 'OT');
CREATE TYPE core.language_code     AS ENUM ('th', 'ja', 'en');
CREATE TYPE quality.severity       AS ENUM ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL');

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
-- 6. KNOWLEDGE — document, chunk, glossary_term, tm_segment  [platform section 9, the four objects verbatim]
-- GenbaGo OWNS knowledge.glossary_term and knowledge.tm_segment (SAD-00 §13) and adds guard triggers on them in section 16.
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

CREATE INDEX idx_chunk_embedding ON knowledge.chunk
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_tm_embedding ON knowledge.tm_segment
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_chunk_text_trgm      ON knowledge.chunk      USING gin (text gin_trgm_ops);
CREATE INDEX idx_tm_src_trgm          ON knowledge.tm_segment USING gin (src_text gin_trgm_ops);
CREATE INDEX idx_chunk_doc            ON knowledge.chunk (document_id, ordinal);
CREATE INDEX idx_chunk_embver         ON knowledge.chunk (embedding_version);
COMMENT ON INDEX knowledge.idx_chunk_text_trgm IS
  'Trigram index supports the lexical half of hybrid retrieval. Thai and Japanese have no word spaces, so trigram beats naive tsvector here.';

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

-- =====================================================================
-- 10. GENBA — types  (extension of the platform's knowledge context; migration genba_0001)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS genba;

COMMENT ON SCHEMA genba IS
  'GenbaGo extension (SRS-14). The glossary and the translation memory stay in the platform schema knowledge (owned by this module); genba holds roles, glossary versions/aliases/candidates/usage, keywords and curated check items, jobs, segments and edits, TM matches, interpretations and readings, OCR pages/regions, test sets and evaluation runs.';

CREATE TYPE genba.role_kind      AS ENUM ('translator', 'reviewer', 'admin');
CREATE TYPE genba.job_kind       AS ENUM ('text', 'document', 'ocr', 'hmi', 'batch');
CREATE TYPE genba.job_status     AS ENUM ('queued', 'running', 'done', 'failed', 'cancelled');
CREATE TYPE genba.segment_status AS ENUM ('machine', 'blocked', 'flagged', 'edited', 'needs_review', 'approved');
CREATE TYPE genba.register       AS ENUM ('report', 'shopfloor', 'customer');
CREATE TYPE genba.process_kind   AS ENUM ('injection_molding', 'press', 'welding', 'assembly', 'painting', 'inspection', 'logistics', 'maintenance', 'other');
CREATE TYPE genba.message_kind   AS ENUM ('problem_report', 'instruction', 'spec_change', 'audit_finding', 'schedule', 'request', 'information');
CREATE TYPE genba.orientation    AS ENUM ('horizontal', 'vertical');
CREATE TYPE genba.provider_kind  AS ENUM ('local', 'cloud');
CREATE TYPE genba.doc_format     AS ENUM ('text', 'docx', 'xlsx', 'pptx', 'pdf', 'image');
CREATE TYPE genba.channel_kind   AS ENUM ('web', 'api', 'discord', 'tool', 'batch');
CREATE TYPE genba.match_method   AS ENUM ('exact', 'trigram', 'vector');
CREATE TYPE genba.candidate_status AS ENUM ('proposed', 'accepted', 'rejected');

COMMENT ON TYPE genba.segment_status IS
  'machine = MT or TM output not yet touched; blocked = a blocking check failed (numbers/codes, C-02) — cannot be approved; flagged = a flag (glossary, forbidden, ratio, untranslated, omission) is unresolved; edited = a person changed the text; needs_review = clean or resolved, waiting for a reviewer; approved = a reviewer approved and the segment was written to the TM (FR-24).';

-- =====================================================================
-- 11. GENBA — settings, roles, glossary extension, knowledge as data
-- =====================================================================

CREATE TABLE genba.setting (
    key         text PRIMARY KEY,
    value_num   numeric,
    value_text  text,
    description text,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT setting_fuzzy        CHECK (key <> 'tm_fuzzy_threshold'     OR value_num BETWEEN 0.85 AND 1),
    CONSTRAINT setting_ambiguity    CHECK (key <> 'ambiguity_threshold'    OR value_num BETWEEN 0.3 AND 0.9),
    CONSTRAINT setting_readings     CHECK (key <> 'max_readings'           OR value_num BETWEEN 2 AND 3),
    CONSTRAINT setting_gate_gloss   CHECK (key <> 'gate_glossary_min'      OR value_num >= 0.98),
    CONSTRAINT setting_gate_numbers CHECK (key <> 'gate_numbers_min'       OR value_num = 1),
    CONSTRAINT setting_gate_ped     CHECK (key <> 'gate_ped_max'           OR value_num <= 0.20),
    CONSTRAINT setting_gate_class   CHECK (key <> 'gate_class_min'         OR value_num >= 0.90),
    CONSTRAINT setting_regression   CHECK (key <> 'regression_pct'         OR value_num = 2),
    CONSTRAINT setting_ocr_gate     CHECK (key <> 'ocr_char_accuracy_min'  OR value_num >= 0.95),
    CONSTRAINT setting_model_size   CHECK (key <> 'llm_max_params_b'       OR value_num <= 9),
    CONSTRAINT setting_temperature  CHECK (key <> 'llm_temperature'        OR value_num <= 0.3),
    CONSTRAINT setting_confidential CHECK (key <> 'confidential_default'   OR value_num = 1),
    CONSTRAINT setting_retention    CHECK (key <> 'retention_days'         OR value_num >= 365),
    CONSTRAINT setting_positive     CHECK (value_num IS NULL OR value_num >= 0)
);

COMMENT ON TABLE genba.setting IS
  'Constants the SRS fixes are CHECK constraints: fuzzy >= 0.85 (FR-03), the AI-02 gates (glossary >= 0.98, numbers = 1, PED <= 0.20), AI-05 >= 0.90, AI-06 >= 0.95, AI-08 regression 2 %, model <= 9 B, confidential by default (C-03), retention >= 365 d.';

CREATE OR REPLACE FUNCTION genba.setting_num(p_key text) RETURNS numeric
LANGUAGE sql STABLE AS $$ SELECT value_num FROM genba.setting WHERE key = p_key $$;

CREATE TABLE genba.user_role (
    user_id    uuid PRIMARY KEY REFERENCES core.app_user(id) ON DELETE CASCADE,
    role       genba.role_kind NOT NULL,
    granted_by uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    granted_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE genba.user_role IS 'SRS-14 FR-30: translator (edit), reviewer (approve), admin (glossary). Checked by the guard triggers, not only by the API.';

CREATE OR REPLACE FUNCTION genba.has_role(p_user uuid, VARIADIC p_roles genba.role_kind[]) RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM genba.user_role r WHERE r.user_id = p_user AND r.role = ANY (p_roles)) $$;

-- NFR-08: every glossary change is a version with approver and effective date (written by genba.trg_glossary_version).
CREATE TABLE genba.term_version (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    term_id        uuid        NOT NULL REFERENCES knowledge.glossary_term(id) ON DELETE CASCADE,
    version_no     integer     NOT NULL CHECK (version_no >= 1),
    ja             text,
    ja_reading     text,
    th             text,
    en             text,
    domain         text,
    notes          text,
    forbidden_json jsonb       NOT NULL DEFAULT '[]'::jsonb,
    approved_by    uuid        NOT NULL REFERENCES core.app_user(id),
    effective_from date        NOT NULL,
    change_note    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT term_version_unique UNIQUE (term_id, version_no)
);

-- FR-22: abbreviations, internal jargon (社内用語), supplier terms — resolved to a glossary term before lookup.
CREATE TABLE genba.term_alias (
    id      uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    term_id uuid NOT NULL REFERENCES knowledge.glossary_term(id) ON DELETE CASCADE,
    alias   text NOT NULL,
    lang    core.language_code NOT NULL,
    kind    text NOT NULL CHECK (kind IN ('abbreviation', 'jargon', 'supplier', 'variant')),
    note    text,
    CONSTRAINT term_alias_unique UNIQUE (alias, lang)
);

-- FR-23: mined candidates awaiting an admin decision.
CREATE TABLE genba.term_candidate (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ja            text        NOT NULL,
    th            text,
    en            text,
    occurrences   integer     NOT NULL DEFAULT 1 CHECK (occurrences >= 1),
    source_job_id uuid,
    status        genba.candidate_status NOT NULL DEFAULT 'proposed',
    proposed_at   timestamptz NOT NULL DEFAULT now(),
    decided_by    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    decided_at    timestamptz,
    CONSTRAINT candidate_unique UNIQUE (ja)
);

-- FR-26: usage and inconsistency per term per day.
CREATE TABLE genba.term_usage (
    term_id         uuid    NOT NULL REFERENCES knowledge.glossary_term(id) ON DELETE CASCADE,
    usage_date      date    NOT NULL,
    count           integer NOT NULL DEFAULT 0,
    inconsistencies integer NOT NULL DEFAULT 0,
    PRIMARY KEY (term_id, usage_date)
);

-- The rule half of the interpretation classifier (FR-09, FR-10): weighted keywords per language.
CREATE TABLE genba.process_keyword (
    id      uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    process genba.process_kind NOT NULL,
    lang    core.language_code NOT NULL,
    keyword text    NOT NULL,
    weight  numeric(3,1) NOT NULL DEFAULT 1.0 CHECK (weight > 0 AND weight <= 3),
    CONSTRAINT process_keyword_unique UNIQUE (lang, keyword)
);

CREATE TABLE genba.message_keyword (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    message_type genba.message_kind NOT NULL,
    lang         core.language_code NOT NULL,
    keyword      text    NOT NULL,
    weight       numeric(3,1) NOT NULL DEFAULT 1.0 CHECK (weight > 0 AND weight <= 3),
    CONSTRAINT message_keyword_unique UNIQUE (lang, keyword)
);

-- FR-12: the curated "standard items to check" per process and message type (names shared with MoldMind's parameters).
CREATE TABLE genba.check_item (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    process        genba.process_kind NOT NULL,
    message_type   genba.message_kind NOT NULL,
    ordinal        smallint NOT NULL,
    item_ja        text NOT NULL,
    item_en        text NOT NULL,
    item_th        text NOT NULL,
    moldmind_param text,                                  -- MoldMind parameter name when the item maps to one (SRS-11); informational, no FK across deployments
    CONSTRAINT check_item_unique UNIQUE (process, message_type, ordinal)
);

-- FR-11: entity patterns (regex per language) — the deterministic extractor.
CREATE TABLE genba.entity_pattern (
    id      uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    entity  text NOT NULL CHECK (entity IN ('line', 'machine', 'mould', 'part_number', 'lot', 'defect_class', 'parameter', 'metric', 'quantity', 'date', 'role', 'direction')),
    lang    core.language_code,                            -- NULL = any
    pattern text NOT NULL,
    value_group smallint NOT NULL DEFAULT 1,
    canonical text,                                        -- for direction: 'up' / 'down'
    ordinal smallint NOT NULL DEFAULT 1,
    CONSTRAINT entity_pattern_unique UNIQUE (entity, pattern)
);

-- C-02 / AI-04: unit aliases across the three languages, canonicalised before number extraction.
CREATE TABLE genba.unit_alias (
    alias     text PRIMARY KEY,
    canonical text NOT NULL
);

-- AI-04: length-ratio bounds per language pair (tunable; documented in OPS-14 §6).
CREATE TABLE genba.ratio_bound (
    src_lang  core.language_code NOT NULL,
    tgt_lang  core.language_code NOT NULL,
    ratio_min numeric(4,2) NOT NULL CHECK (ratio_min > 0),
    ratio_max numeric(4,2) NOT NULL,
    PRIMARY KEY (src_lang, tgt_lang),
    CONSTRAINT ratio_order CHECK (ratio_max > ratio_min)
);

-- FR-13 / AI-09: tags on indexed documents — related documents come only from here.
CREATE TABLE genba.document_tag (
    document_id uuid NOT NULL REFERENCES knowledge.document(id) ON DELETE CASCADE,
    tag         text NOT NULL,
    PRIMARY KEY (document_id, tag)
);

-- FR-03 / NFR-03: exact-match index of the TM (normalised source, hash) — maintained by genba.trg_tm_index on knowledge.tm_segment.
CREATE TABLE genba.tm_index (
    tm_segment_id uuid PRIMARY KEY REFERENCES knowledge.tm_segment(id) ON DELETE CASCADE,
    src_lang      core.language_code NOT NULL,
    tgt_lang      core.language_code NOT NULL,
    src_norm      text NOT NULL,
    src_hash      text NOT NULL,
    CONSTRAINT tm_index_unique UNIQUE (src_lang, tgt_lang, src_hash)
);

COMMENT ON TABLE genba.tm_index IS
  'One approved target per normalised source and language pair: an exact match is unambiguous and reused verbatim (FR-03, AI-07 exact before vector).';

-- =====================================================================
-- 12. GENBA — jobs, segments, edits, matches
-- =====================================================================

CREATE TABLE genba.translation_job (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind          genba.job_kind NOT NULL,
    src_lang      core.language_code NOT NULL,
    tgt_lang      core.language_code NOT NULL,
    register      genba.register NOT NULL DEFAULT 'report',
    status        genba.job_status NOT NULL DEFAULT 'queued',
    confidential  boolean     NOT NULL DEFAULT true,
    provider      genba.provider_kind NOT NULL DEFAULT 'local',
    channel       genba.channel_kind NOT NULL DEFAULT 'web',
    format        genba.doc_format NOT NULL DEFAULT 'text',
    keep_layout   boolean     NOT NULL DEFAULT true,
    file_uri      text,
    result_uri    text,
    created_by    uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    started_at    timestamptz,
    finished_at   timestamptz,
    segment_count integer     NOT NULL DEFAULT 0,
    done_count    integer     NOT NULL DEFAULT 0,
    error         text,
    resumed_from_ordinal integer,
    parent_job_id uuid        REFERENCES genba.translation_job(id) ON DELETE SET NULL,
    CONSTRAINT job_langs_differ CHECK (src_lang <> tgt_lang),
    CONSTRAINT job_done_counts  CHECK (status <> 'done' OR done_count = segment_count),
    CONSTRAINT job_failed_error CHECK (status <> 'failed' OR error IS NOT NULL),
    CONSTRAINT job_confidential_local CHECK (NOT confidential OR (provider = 'local' AND channel <> 'discord'))
);

COMMENT ON CONSTRAINT job_confidential_local ON genba.translation_job IS
  'SRS-14 C-03 / NFR-04: a confidential job (the default) is processed locally and never through Discord.';

CREATE TABLE genba.job_file (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    job_id        uuid        NOT NULL REFERENCES genba.translation_job(id) ON DELETE CASCADE,
    ordinal       integer     NOT NULL,
    name          text        NOT NULL,
    uri           text        NOT NULL,
    format        genba.doc_format NOT NULL,
    status        genba.job_status NOT NULL DEFAULT 'queued',
    segment_count integer     NOT NULL DEFAULT 0,
    error         text,
    result_uri    text,
    CONSTRAINT job_file_unique UNIQUE (job_id, ordinal),
    CONSTRAINT job_file_failed_error CHECK (status <> 'failed' OR error IS NOT NULL)
);

CREATE TABLE genba.segment (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    job_id        uuid        NOT NULL REFERENCES genba.translation_job(id) ON DELETE CASCADE,
    ordinal       integer     NOT NULL,
    anchor        text,                                   -- paragraph / cell / run / region reference for layout preservation (FR-16)
    src_text      text        NOT NULL,
    mt_text       text,
    tm_match_id   uuid        REFERENCES knowledge.tm_segment(id) ON DELETE SET NULL,
    tm_score      numeric(4,3) CHECK (tm_score BETWEEN 0 AND 1),
    final_text    text,
    status        genba.segment_status NOT NULL DEFAULT 'machine',
    checks_json   jsonb,
    edit_distance numeric(5,4),
    reviewer_note text,
    approved_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    approved_at   timestamptz,
    tm_written_id uuid        REFERENCES knowledge.tm_segment(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT segment_unique UNIQUE (job_id, ordinal),
    CONSTRAINT segment_approved_fields CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND final_text IS NOT NULL))
);

COMMENT ON COLUMN genba.segment.checks_json IS
  'Computed by genba.run_checks() on every insert/update of the text (never supplied): {blocking: {numbers}, flags: {glossary, forbidden, length_ratio, untranslated, omission}, clean} — SRS-14 FR-28, AI-04, C-01, C-02, C-04.';

-- FR-29: every human edit with its normalised edit distance (append-only).
CREATE TABLE genba.segment_edit (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    segment_id    uuid        NOT NULL REFERENCES genba.segment(id) ON DELETE CASCADE,
    editor_id     uuid        NOT NULL REFERENCES core.app_user(id),
    before_text   text,
    after_text    text        NOT NULL,
    edit_distance numeric(5,4) NOT NULL CHECK (edit_distance BETWEEN 0 AND 1),
    ts            timestamptz NOT NULL DEFAULT now()
);

-- FR-03: fuzzy matches offered with a diff (never applied automatically).
CREATE TABLE genba.tm_match (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    segment_id    uuid        NOT NULL REFERENCES genba.segment(id) ON DELETE CASCADE,
    tm_segment_id uuid        NOT NULL REFERENCES knowledge.tm_segment(id) ON DELETE CASCADE,
    score         numeric(4,3) NOT NULL CHECK (score BETWEEN 0 AND 1),
    method        genba.match_method NOT NULL,
    diff_json     jsonb,
    CONSTRAINT tm_match_unique UNIQUE (segment_id, tm_segment_id),
    CONSTRAINT tm_match_threshold CHECK (method = 'exact' OR score >= 0.85)
);

-- =====================================================================
-- 13. GENBA — interpretation, readings, OCR
-- =====================================================================

CREATE TABLE genba.interpretation (
    id                    uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    segment_id            uuid        NOT NULL UNIQUE REFERENCES genba.segment(id) ON DELETE CASCADE,
    inferred              boolean     NOT NULL DEFAULT true CHECK (inferred = true),
    confidence            numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    ambiguous             boolean     NOT NULL DEFAULT false,
    process               genba.process_kind,
    message_type          genba.message_kind,
    entities_json         jsonb       NOT NULL DEFAULT '{}'::jsonb,
    timing_note           text,
    suggested_checks_json jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- [check_item id]
    related_docs_json     jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- [knowledge.document id]
    model                 text,
    prompt_version        text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT interpretation_asserts CHECK (ambiguous OR (process IS NOT NULL AND message_type IS NOT NULL))
);

COMMENT ON TABLE genba.interpretation IS
  'SRS-14 C-05 / FR-14: what the system INFERRED, in its own table — never a column of the translation. inferred is true by CHECK; ambiguity (FR-15) replaces the assertion with readings.';

-- FR-15 / AC-05: alternative readings when the source is ambiguous.
CREATE TABLE genba.reading (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    segment_id uuid     NOT NULL REFERENCES genba.segment(id) ON DELETE CASCADE,
    ordinal    smallint NOT NULL CHECK (ordinal BETWEEN 1 AND 3),
    reading_ja text     NOT NULL,
    th         text     NOT NULL,
    en         text     NOT NULL,
    usage_note text,
    CONSTRAINT reading_unique UNIQUE (segment_id, ordinal)
);

CREATE TABLE genba.ocr_page (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    job_id      uuid    NOT NULL REFERENCES genba.translation_job(id) ON DELETE CASCADE,
    page_no     integer NOT NULL CHECK (page_no >= 1),
    image_uri   text    NOT NULL,
    width_px    integer NOT NULL,
    height_px   integer NOT NULL,
    layout_mode text    NOT NULL DEFAULT 'side_by_side' CHECK (layout_mode IN ('side_by_side', 'overlay', 'keep_layout')),
    CONSTRAINT ocr_page_unique UNIQUE (job_id, page_no)
);

CREATE TABLE genba.ocr_region (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    page_id         uuid     NOT NULL REFERENCES genba.ocr_page(id) ON DELETE CASCADE,
    ordinal         integer  NOT NULL,
    bbox_json       jsonb    NOT NULL,                    -- {x, y, w, h} in pixels
    orientation     genba.orientation NOT NULL,
    text            text     NOT NULL,
    char_confidence numeric(4,3) NOT NULL CHECK (char_confidence BETWEEN 0 AND 1),
    handwriting     boolean  NOT NULL DEFAULT false,
    low_confidence  boolean  NOT NULL DEFAULT false,
    segment_id      uuid     REFERENCES genba.segment(id) ON DELETE SET NULL,
    CONSTRAINT ocr_region_unique UNIQUE (page_id, ordinal)
);

COMMENT ON COLUMN genba.ocr_region.low_confidence IS
  'Set by genba.trg_ocr_flag: handwriting, or character confidence below ocr_char_accuracy_min (SRS-14 FR-18, AI-06). Cannot be cleared by hand.';

-- =====================================================================
-- 14. GENBA — test sets, evaluation, exports, migration
-- =====================================================================

CREATE TABLE genba.test_set (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name        text    NOT NULL,
    version     integer NOT NULL CHECK (version >= 1),
    description text,
    frozen      boolean NOT NULL DEFAULT false,
    created_by  uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT test_set_unique UNIQUE (name, version)
);

CREATE TABLE genba.test_segment (
    id                    uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    test_set_id           uuid    NOT NULL REFERENCES genba.test_set(id) ON DELETE CASCADE,
    ordinal               integer NOT NULL,
    src_lang              core.language_code NOT NULL,
    tgt_lang              core.language_code NOT NULL,
    src_text              text    NOT NULL,
    reference_text        text    NOT NULL,
    expected_process      genba.process_kind,
    expected_message_type genba.message_kind,
    domain                text,
    CONSTRAINT test_segment_unique UNIQUE (test_set_id, ordinal)
);

CREATE TABLE genba.eval_run (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    test_set_id         uuid        NOT NULL REFERENCES genba.test_set(id),
    run_at              timestamptz NOT NULL DEFAULT now(),
    model               text        NOT NULL,
    prompt_version      text        NOT NULL,
    glossary_compliance numeric(5,4),
    numbers_preserved   numeric(5,4),
    mean_ped            numeric(5,4),
    class_accuracy      numeric(5,4),
    passed              boolean,
    investigate         boolean     NOT NULL DEFAULT false,
    note                text
);

CREATE TABLE genba.eval_result (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    eval_run_id     uuid    NOT NULL REFERENCES genba.eval_run(id) ON DELETE CASCADE,
    test_segment_id uuid    NOT NULL REFERENCES genba.test_segment(id) ON DELETE CASCADE,
    mt_text         text    NOT NULL,
    ped             numeric(5,4) NOT NULL CHECK (ped BETWEEN 0 AND 1),
    glossary_ok     boolean NOT NULL,
    numbers_ok      boolean NOT NULL,
    process_pred    genba.process_kind,
    message_pred    genba.message_kind,
    CONSTRAINT eval_result_unique UNIQUE (eval_run_id, test_segment_id)
);

CREATE TABLE genba.export_job (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind       text        NOT NULL CHECK (kind IN ('glossary_csv', 'glossary_tbx', 'tm_tmx', 'tm_csv', 'audit')),
    uri        text        NOT NULL,
    row_count  integer     NOT NULL DEFAULT 0,
    sha256     text        NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    created_by uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE genba.migration (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    description text
);

-- =====================================================================
-- 15. GENBA — functions (twins of the deterministic logic; TEST-14 TC-005 re-derives them in Python)
-- =====================================================================

-- FR-03: normalisation before memory lookup — full-width to half-width, ideographic space, whitespace, trim.
CREATE OR REPLACE FUNCTION genba.normalise_for_tm(p_text text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(
             translate(COALESCE(p_text, ''),
                       '０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ．，％（）－＋／　',
                       '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.,%()-+/ '),
             '\s+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION genba.tm_hash(p_text text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT md5(genba.normalise_for_tm(p_text)) $$;

-- C-02 / AI-04: unit aliases (มม., ミリ, ℃, +/-) become canonical before extraction; longest alias first.
CREATE OR REPLACE FUNCTION genba.canon_units(p_text text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    r record;
    t text := genba.normalise_for_tm(p_text);
BEGIN
    FOR r IN SELECT alias, canonical FROM genba.unit_alias ORDER BY length(alias) DESC, alias LOOP
        t := replace(t, r.alias, r.canonical);
    END LOOP;
    RETURN t;
END;
$$;

-- C-02 / FR-05: every number (with sign, tolerance and unit), code, lot and date as a canonical token; sorted.
CREATE OR REPLACE FUNCTION genba.extract_codes(p_text text) RETURNS text[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
    t      text := genba.canon_units(p_text);
    tokens text[] := '{}';
    m      text[];
BEGIN
    -- dates: 2026-09-14, 2026/09/14, 2026年9月14日 → YYYY-MM-DD
    FOR m IN SELECT regexp_matches(t, '([0-9]{4})[-/年]([0-9]{1,2})[-/月]([0-9]{1,2})日?', 'g') LOOP
        tokens := tokens || (m[1] || '-' || lpad(m[2], 2, '0') || '-' || lpad(m[3], 2, '0'));
    END LOOP;
    t := regexp_replace(t, '[0-9]{4}[-/年][0-9]{1,2}[-/月][0-9]{1,2}日?', ' ', 'g');
    -- codes: LOT-2609-114, RAD-500-A, M-07, QC-0241, PO-2026-004821
    FOR m IN SELECT regexp_matches(t, '([A-Z]+-[0-9]{2,}(?:-[A-Z0-9]+)*)', 'g') LOOP
        tokens := tokens || m[1];
    END LOOP;
    t := regexp_replace(t, '[A-Z]+-[0-9]{2,}(?:-[A-Z0-9]+)*', ' ', 'g');
    -- numbers with optional sign/tolerance, decimals and a canonical unit; internal spaces removed
    FOR m IN SELECT regexp_matches(t, '([±+-]?[0-9]+(?:\.[0-9]+)?(?:\s?(?:mm²|mm|cm|kg|MPa|bar|min|pcs|°C|g|%|h|s|m))?)', 'g') LOOP
        tokens := tokens || replace(m[1], ' ', '');
    END LOOP;
    RETURN (SELECT COALESCE(array_agg(x ORDER BY x), '{}') FROM unnest(tokens) x);
END;
$$;

COMMENT ON FUNCTION genba.extract_codes(text) IS
  'SRS-14 C-02: the multiset of numbers, units, tolerances, part numbers, lots, dates and codes. codes_preserved() compares source and target multisets; any difference is a BLOCKING error.';

CREATE OR REPLACE FUNCTION genba.codes_preserved(p_src text, p_tgt text) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    s text[] := genba.extract_codes(p_src);
    d text[] := genba.extract_codes(p_tgt);
    missing text[];
    extra   text[];
BEGIN
    SELECT COALESCE(array_agg(x ORDER BY x), '{}') INTO missing
      FROM (SELECT x FROM unnest(s) x EXCEPT ALL SELECT y FROM unnest(d) y) q;
    SELECT COALESCE(array_agg(x ORDER BY x), '{}') INTO extra
      FROM (SELECT y AS x FROM unnest(d) y EXCEPT ALL SELECT x FROM unnest(s) x) q;
    RETURN jsonb_build_object('ok', array_length(missing, 1) IS NULL AND array_length(extra, 1) IS NULL,
                              'source', to_jsonb(s), 'missing', to_jsonb(missing), 'extra', to_jsonb(extra));
END;
$$;

CREATE OR REPLACE FUNCTION genba.term_text(p_term knowledge.glossary_term, p_lang core.language_code) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_lang WHEN 'ja' THEN p_term.ja WHEN 'th' THEN p_term.th ELSE p_term.en END
$$;

-- C-01 / FR-04 / AC-03: mandated terms present in the source must appear in the target; forbidden renderings must not.
CREATE OR REPLACE FUNCTION genba.glossary_hits(p_src text, p_tgt text, p_src_lang core.language_code, p_tgt_lang core.language_code) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    t        knowledge.glossary_term%ROWTYPE;
    src_r    text;
    tgt_r    text;
    relevant boolean;
    applied  text[] := '{}';
    missing  text[] := '{}';
    forb     jsonb  := '[]'::jsonb;
    f        jsonb;
    src_l    text := lower(COALESCE(p_src, ''));
    tgt_l    text := lower(COALESCE(p_tgt, ''));
BEGIN
    FOR t IN SELECT * FROM knowledge.glossary_term ORDER BY ja LOOP
        src_r := genba.term_text(t, p_src_lang);
        tgt_r := genba.term_text(t, p_tgt_lang);
        relevant := src_r IS NOT NULL AND position(lower(src_r) IN src_l) > 0;
        -- longest match wins: a term whose source rendering is contained in another matching term's rendering is not counted separately
        IF relevant AND EXISTS (SELECT 1 FROM knowledge.glossary_term g2
                                 WHERE g2.id <> t.id AND genba.term_text(g2, p_src_lang) IS NOT NULL
                                   AND position(lower(src_r) IN lower(genba.term_text(g2, p_src_lang))) > 0
                                   AND position(lower(genba.term_text(g2, p_src_lang)) IN src_l) > 0) THEN
            relevant := false;
        END IF;
        IF NOT relevant THEN
            relevant := EXISTS (SELECT 1 FROM genba.term_alias a WHERE a.term_id = t.id AND a.lang = p_src_lang AND position(lower(a.alias) IN src_l) > 0);
        END IF;
        IF relevant AND tgt_r IS NOT NULL THEN
            IF position(lower(tgt_r) IN tgt_l) > 0 THEN applied := applied || COALESCE(t.ja, tgt_r);
            ELSE missing := missing || COALESCE(t.ja, tgt_r);
            END IF;
            FOR f IN SELECT * FROM jsonb_array_elements(t.forbidden_json) LOOP
                IF (f ->> 'lang') = p_tgt_lang::text AND position(lower(f ->> 'text') IN tgt_l) > 0 THEN
                    forb := forb || jsonb_build_object('term', COALESCE(t.ja, tgt_r), 'rendering', f ->> 'text', 'mandated', tgt_r);
                END IF;
            END LOOP;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('applied', to_jsonb(applied), 'missing', to_jsonb(missing), 'forbidden', forb);
END;
$$;

-- C-04: sentence counts per language for the omission check.
CREATE OR REPLACE FUNCTION genba.sentence_count(p_text text, p_lang core.language_code) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT GREATEST(1, (SELECT count(*) FROM unnest(
        CASE p_lang
            WHEN 'ja' THEN regexp_split_to_array(COALESCE(p_text, ''), '[。！？\n]+')
            WHEN 'th' THEN regexp_split_to_array(COALESCE(p_text, ''), '(\n+|  +|[.!?]+(?=\s|$))')
            ELSE           regexp_split_to_array(COALESCE(p_text, ''), '([.!?]+(?=\s|$)\s*|\n+)')
        END) s WHERE btrim(s) <> ''))::integer
$$;

CREATE OR REPLACE FUNCTION genba.length_ratio(p_src text, p_tgt text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round(char_length(COALESCE(p_tgt, ''))::numeric / NULLIF(char_length(COALESCE(p_src, '')), 0), 3)
$$;

-- AI-04: source script left in the target.
CREATE OR REPLACE FUNCTION genba.untranslated(p_tgt text, p_tgt_lang core.language_code) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_tgt_lang IN ('th', 'en') THEN COALESCE(p_tgt, '') ~ '[ぁ-ヿ一-龯]'
                ELSE COALESCE(p_tgt, '') ~ '[ก-๛]' END
$$;

-- FR-28 / AI-04: the check object stored on every segment. numbers is BLOCKING (C-02); the rest are flags (C-01, C-04).
CREATE OR REPLACE FUNCTION genba.run_checks(p_src text, p_tgt text, p_src_lang core.language_code, p_tgt_lang core.language_code) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    codes  jsonb := genba.codes_preserved(p_src, p_tgt);
    gl     jsonb := genba.glossary_hits(p_src, p_tgt, p_src_lang, p_tgt_lang);
    ratio  numeric := genba.length_ratio(p_src, p_tgt);
    b      genba.ratio_bound%ROWTYPE;
    ratio_ok boolean;
    sc_src integer := genba.sentence_count(p_src, p_src_lang);
    sc_tgt integer := genba.sentence_count(p_tgt, p_tgt_lang);
    untr   boolean := genba.untranslated(p_tgt, p_tgt_lang);
    flags  jsonb;
BEGIN
    SELECT * INTO b FROM genba.ratio_bound WHERE src_lang = p_src_lang AND tgt_lang = p_tgt_lang;
    ratio_ok := b.ratio_min IS NULL OR (ratio BETWEEN b.ratio_min AND b.ratio_max);
    flags := jsonb_build_object(
        'glossary',     jsonb_build_object('ok', jsonb_array_length(gl -> 'missing') = 0, 'missing', gl -> 'missing', 'applied', gl -> 'applied'),
        'forbidden',    jsonb_build_object('ok', jsonb_array_length(gl -> 'forbidden') = 0, 'hits', gl -> 'forbidden'),
        'length_ratio', jsonb_build_object('ok', ratio_ok, 'ratio', ratio, 'min', b.ratio_min, 'max', b.ratio_max),
        'untranslated', jsonb_build_object('ok', NOT untr),
        'omission',     jsonb_build_object('ok', sc_tgt >= sc_src, 'src_sentences', sc_src, 'tgt_sentences', sc_tgt));
    RETURN jsonb_build_object(
        'blocking', jsonb_build_object('numbers', codes),
        'flags', flags,
        'blocked', NOT (codes ->> 'ok')::boolean,
        'flagged', NOT ((flags #>> '{glossary,ok}')::boolean AND (flags #>> '{forbidden,ok}')::boolean AND (flags #>> '{length_ratio,ok}')::boolean
                        AND (flags #>> '{untranslated,ok}')::boolean AND (flags #>> '{omission,ok}')::boolean),
        'clean', (codes ->> 'ok')::boolean AND (flags #>> '{glossary,ok}')::boolean AND (flags #>> '{forbidden,ok}')::boolean
                 AND (flags #>> '{length_ratio,ok}')::boolean AND (flags #>> '{untranslated,ok}')::boolean AND (flags #>> '{omission,ok}')::boolean);
END;
$$;

-- FR-29: normalised Levenshtein distance over characters (no extension dependency, works on multibyte text).
CREATE OR REPLACE FUNCTION genba.edit_distance(p_a text, p_b text) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    a text[] := regexp_split_to_array(COALESCE(p_a, ''), '');
    b text[] := regexp_split_to_array(COALESCE(p_b, ''), '');
    la integer := COALESCE(array_length(a, 1), 0);
    lb integer := COALESCE(array_length(b, 1), 0);
    prev integer[];
    cur  integer[];
    i integer; j integer; cost integer;
BEGIN
    IF la = 0 AND lb = 0 THEN RETURN 0; END IF;
    prev := ARRAY(SELECT generate_series(0, lb));
    FOR i IN 1..la LOOP
        cur := ARRAY[i];
        FOR j IN 1..lb LOOP
            cost := CASE WHEN a[i] = b[j] THEN 0 ELSE 1 END;
            cur := cur || LEAST(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost);
        END LOOP;
        prev := cur;
    END LOOP;
    RETURN round(prev[lb + 1]::numeric / GREATEST(la, lb), 4);
END;
$$;

-- FR-03 fuzzy twin: character-trigram Jaccard similarity on the normalised text (the runtime also uses pg_trgm and vectors; this is the reference score).
CREATE OR REPLACE FUNCTION genba.trigrams(p_text text) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT substr(t, i, 3)), '{}')
      FROM (SELECT '  ' || lower(genba.normalise_for_tm(p_text)) || ' ' AS t) x,
           generate_series(1, GREATEST(char_length('  ' || lower(genba.normalise_for_tm(p_text)) || ' ') - 2, 1)) i
$$;

CREATE OR REPLACE FUNCTION genba.trigram_similarity(p_a text, p_b text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    WITH a AS (SELECT unnest(genba.trigrams(p_a)) g), b AS (SELECT unnest(genba.trigrams(p_b)) g)
    SELECT round((SELECT count(*) FROM (SELECT g FROM a INTERSECT SELECT g FROM b) i)::numeric
                 / NULLIF((SELECT count(*) FROM (SELECT g FROM a UNION SELECT g FROM b) u), 0), 3)
$$;

CREATE OR REPLACE FUNCTION genba.tm_lookup(p_text text, p_src_lang core.language_code, p_tgt_lang core.language_code)
RETURNS TABLE (tm_segment_id uuid, score numeric, method genba.match_method)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    h text := genba.tm_hash(p_text);
    thr numeric := genba.setting_num('tm_fuzzy_threshold');
BEGIN
    RETURN QUERY SELECT i.tm_segment_id, 1.000::numeric, 'exact'::genba.match_method
                   FROM genba.tm_index i WHERE i.src_lang = p_src_lang AND i.tgt_lang = p_tgt_lang AND i.src_hash = h;
    IF FOUND THEN RETURN; END IF;
    RETURN QUERY SELECT i.tm_segment_id, genba.trigram_similarity(p_text, i.src_norm), 'trigram'::genba.match_method
                   FROM genba.tm_index i
                  WHERE i.src_lang = p_src_lang AND i.tgt_lang = p_tgt_lang
                    AND genba.trigram_similarity(p_text, i.src_norm) >= thr
                  ORDER BY 2 DESC LIMIT 5;
END;
$$;

COMMENT ON FUNCTION genba.tm_lookup(text, core.language_code, core.language_code) IS
  'SRS-14 FR-03 / AI-07: exact (normalised hash) first and alone; otherwise fuzzy candidates >= tm_fuzzy_threshold, offered with a diff — never applied automatically.';

-- FR-09 / FR-10 / AI-05: the rule half of the classifier. Confidence = 0.5 + 0.1 x (top process + top message) - 0.1 x (runner-ups), capped 0.99.
CREATE OR REPLACE FUNCTION genba.classify(p_text text)
RETURNS TABLE (process genba.process_kind, process_score numeric, process_runner numeric,
               message_type genba.message_kind, message_score numeric, message_runner numeric, confidence numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    lt text := lower(COALESCE(p_text, ''));
    p  record; m record;
BEGIN
    SELECT k.process, sum(k.weight) AS s INTO p
      FROM genba.process_keyword k WHERE position(lower(k.keyword) IN lt) > 0 GROUP BY k.process ORDER BY s DESC, k.process LIMIT 1;
    SELECT k.message_type, sum(k.weight) AS s INTO m
      FROM genba.message_keyword k WHERE position(lower(k.keyword) IN lt) > 0 GROUP BY k.message_type ORDER BY s DESC, k.message_type LIMIT 1;
    process := p.process; process_score := COALESCE(p.s, 0);
    SELECT COALESCE(max(s), 0) INTO process_runner FROM (
        SELECT sum(k.weight) AS s FROM genba.process_keyword k WHERE position(lower(k.keyword) IN lt) > 0 AND k.process IS DISTINCT FROM p.process GROUP BY k.process) q;
    message_type := m.message_type; message_score := COALESCE(m.s, 0);
    SELECT COALESCE(max(s), 0) INTO message_runner FROM (
        SELECT sum(k.weight) AS s FROM genba.message_keyword k WHERE position(lower(k.keyword) IN lt) > 0 AND k.message_type IS DISTINCT FROM m.message_type GROUP BY k.message_type) q;
    confidence := round(LEAST(0.99, 0.5 + 0.1 * (process_score + message_score) - 0.1 * (process_runner + message_runner)), 2);
    RETURN NEXT;
END;
$$;

-- FR-11: entities from patterns and from glossary domains (defect / parameter / metric).
CREATE OR REPLACE FUNCTION genba.extract_entities(p_text text) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    r   record;
    m   text[];
    res jsonb := '{}'::jsonb;
    vals text[];
    t   knowledge.glossary_term%ROWTYPE;
BEGIN
    FOR r IN SELECT DISTINCT entity FROM genba.entity_pattern ORDER BY entity LOOP
        vals := '{}';
        FOR m IN SELECT regexp_matches(p_text, ep.pattern, 'g') FROM genba.entity_pattern ep WHERE ep.entity = r.entity ORDER BY ep.ordinal LOOP
            vals := vals || m[1];
        END LOOP;
        IF array_length(vals, 1) > 0 THEN
            IF r.entity = 'direction' THEN
                res := res || jsonb_build_object('direction', (SELECT ep.canonical FROM genba.entity_pattern ep WHERE ep.entity = 'direction' AND p_text ~ ep.pattern ORDER BY ep.ordinal LIMIT 1));
            ELSE
                res := res || jsonb_build_object(r.entity, (SELECT to_jsonb(array_agg(DISTINCT v ORDER BY v)) FROM unnest(vals) v));
            END IF;
        END IF;
    END LOOP;
    FOR t IN SELECT * FROM knowledge.glossary_term WHERE domain IN ('defect', 'parameter', 'metric') ORDER BY ja LOOP
        IF t.ja IS NOT NULL AND position(t.ja IN p_text) > 0 THEN
            res := jsonb_set(res, ARRAY[CASE t.domain WHEN 'defect' THEN 'defect_class' ELSE t.domain END],
                             COALESCE(res -> CASE t.domain WHEN 'defect' THEN 'defect_class' ELSE t.domain END, '[]'::jsonb) || to_jsonb(t.ja), true);
        END IF;
    END LOOP;
    RETURN res;
END;
$$;

-- FR-12: curated items only.
CREATE OR REPLACE FUNCTION genba.suggested_checks(p_process genba.process_kind, p_message genba.message_kind) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(c.id ORDER BY c.ordinal), '[]'::jsonb)
      FROM genba.check_item c WHERE c.process = p_process AND c.message_type = p_message
$$;

-- FR-13 / AI-09: related documents come only from the index, matched by tags.
CREATE OR REPLACE FUNCTION genba.related_docs(p_entities jsonb, p_process genba.process_kind) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH vals AS (
        SELECT lower(v.value #>> '{}') AS v FROM jsonb_each(COALESCE(p_entities, '{}'::jsonb)) e, jsonb_array_elements(CASE WHEN jsonb_typeof(e.value) = 'array' THEN e.value ELSE jsonb_build_array(e.value) END) v
        UNION SELECT lower(p_process::text))
    SELECT COALESCE(jsonb_agg(d.id ORDER BY d.title), '[]'::jsonb)
      FROM knowledge.document d
     WHERE EXISTS (SELECT 1 FROM genba.document_tag t JOIN vals ON lower(t.tag) = vals.v WHERE t.document_id = d.id)
$$;

-- FR-09…FR-15: build the interpretation of a segment from the rules; ambiguous below the threshold (readings must already exist).
CREATE OR REPLACE FUNCTION genba.interpret(p_segment_id uuid, p_model text DEFAULT 'rules', p_prompt_version text DEFAULT 'interpret.v1') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    s   genba.segment%ROWTYPE;
    c   record;
    ent jsonb;
    thr numeric := genba.setting_num('ambiguity_threshold');
    iid uuid;
    tn  text;
BEGIN
    SELECT * INTO s FROM genba.segment WHERE id = p_segment_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'SEGMENT_UNKNOWN'; END IF;
    SELECT * INTO c FROM genba.classify(s.src_text);
    ent := genba.extract_entities(s.src_text);
    tn := CASE WHEN s.src_text ~ '(た後|後に|後、|after|หลังจาก)' AND (ent ->> 'direction') IS NOT NULL
               THEN 'sequence stated: the change precedes the ' || CASE ent ->> 'direction' WHEN 'up' THEN 'increase' ELSE 'decrease' END || ' (causal claim implied, not verified)' END;
    IF c.confidence < thr OR c.process IS NULL OR c.message_type IS NULL THEN
        INSERT INTO genba.interpretation (segment_id, confidence, ambiguous, process, message_type, entities_json, timing_note, suggested_checks_json, related_docs_json, model, prompt_version)
        VALUES (p_segment_id, c.confidence, true, NULL, NULL, ent, tn, '[]', '[]', p_model, p_prompt_version) RETURNING id INTO iid;
    ELSE
        INSERT INTO genba.interpretation (segment_id, confidence, ambiguous, process, message_type, entities_json, timing_note, suggested_checks_json, related_docs_json, model, prompt_version)
        VALUES (p_segment_id, c.confidence, false, c.process, c.message_type, ent, tn,
                genba.suggested_checks(c.process, c.message_type), genba.related_docs(ent, c.process), p_model, p_prompt_version) RETURNING id INTO iid;
    END IF;
    RETURN iid;
END;
$$;

-- The worker's write path: TM first (exact reuse), then MT text supplied by the caller (the model), checks by trigger.
CREATE OR REPLACE FUNCTION genba.add_segment(p_job_id uuid, p_ordinal integer, p_src text, p_mt text, p_anchor text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    j   genba.translation_job%ROWTYPE;
    hit record;
    sid uuid;
    tgt text;
BEGIN
    SELECT * INTO j FROM genba.translation_job WHERE id = p_job_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'JOB_UNKNOWN'; END IF;
    SELECT * INTO hit FROM genba.tm_lookup(p_src, j.src_lang, j.tgt_lang) LIMIT 1;
    IF FOUND AND hit.method = 'exact' THEN
        SELECT tgt_text INTO tgt FROM knowledge.tm_segment WHERE id = hit.tm_segment_id;
        INSERT INTO genba.segment (job_id, ordinal, anchor, src_text, mt_text, tm_match_id, tm_score, status)
        VALUES (p_job_id, p_ordinal, p_anchor, p_src, tgt, hit.tm_segment_id, 1.000, 'machine') RETURNING id INTO sid;
        INSERT INTO genba.tm_match (segment_id, tm_segment_id, score, method) VALUES (sid, hit.tm_segment_id, 1.000, 'exact');
    ELSE
        INSERT INTO genba.segment (job_id, ordinal, anchor, src_text, mt_text, status)
        VALUES (p_job_id, p_ordinal, p_anchor, p_src, p_mt, 'machine') RETURNING id INTO sid;
        INSERT INTO genba.tm_match (segment_id, tm_segment_id, score, method, diff_json)
        SELECT sid, l.tm_segment_id, l.score, l.method,
               jsonb_build_object('tm_src', i.src_norm, 'query', genba.normalise_for_tm(p_src))
          FROM genba.tm_lookup(p_src, j.src_lang, j.tgt_lang) l JOIN genba.tm_index i ON i.tm_segment_id = l.tm_segment_id;
    END IF;
    UPDATE genba.translation_job
       SET segment_count = (SELECT count(*) FROM genba.segment WHERE job_id = p_job_id),
           done_count    = (SELECT count(*) FROM genba.segment WHERE job_id = p_job_id AND mt_text IS NOT NULL)
     WHERE id = p_job_id;
    RETURN sid;
END;
$$;

-- FR-29: a person edits — the only way final_text changes (the trigger requires this context).
CREATE OR REPLACE FUNCTION genba.edit_segment(p_segment_id uuid, p_editor uuid, p_text text, p_ts timestamptz DEFAULT now()) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    s genba.segment%ROWTYPE;
    d numeric;
BEGIN
    SELECT * INTO s FROM genba.segment WHERE id = p_segment_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SEGMENT_UNKNOWN'; END IF;
    IF NOT genba.has_role(p_editor, 'translator', 'reviewer', 'admin') THEN RAISE EXCEPTION 'EDITOR_ROLE: % may not edit', p_editor; END IF;
    IF s.status = 'approved' THEN RAISE EXCEPTION 'SEGMENT_APPROVED: approved segments are memory; reopen through a reviewer'; END IF;
    d := genba.edit_distance(COALESCE(s.final_text, s.mt_text), p_text);
    INSERT INTO genba.segment_edit (segment_id, editor_id, before_text, after_text, edit_distance, ts)
    VALUES (p_segment_id, p_editor, COALESCE(s.final_text, s.mt_text), p_text, d, p_ts);
    PERFORM set_config('genba.edit_ctx', p_segment_id::text, true);
    UPDATE genba.segment SET final_text = p_text, edit_distance = d, status = 'edited' WHERE id = p_segment_id;
    PERFORM set_config('genba.edit_ctx', '', true);
    RETURN d;
END;
$$;

-- FR-24 / FR-30: a reviewer approves — checks, role and TM write-back are enforced by the triggers.
CREATE OR REPLACE FUNCTION genba.approve_segment(p_segment_id uuid, p_reviewer uuid, p_note text DEFAULT NULL, p_at timestamptz DEFAULT now()) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    tm uuid;
BEGIN
    PERFORM set_config('genba.edit_ctx', p_segment_id::text, true);
    UPDATE genba.segment
       SET status = 'approved', approved_by = p_reviewer, approved_at = p_at,
           reviewer_note = COALESCE(p_note, reviewer_note),
           final_text = COALESCE(final_text, mt_text)
     WHERE id = p_segment_id;
    PERFORM set_config('genba.edit_ctx', '', true);
    SELECT tm_written_id INTO tm FROM genba.segment WHERE id = p_segment_id;
    RETURN tm;
END;
$$;

-- NFR-07 / FR-20: resume a failed job at the first unfinished item.
CREATE OR REPLACE FUNCTION genba.resume_job(p_job_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    first_ord integer;
BEGIN
    SELECT min(ordinal) INTO first_ord FROM genba.job_file WHERE job_id = p_job_id AND status <> 'done';
    IF first_ord IS NULL THEN
        SELECT min(ordinal) INTO first_ord FROM genba.segment WHERE job_id = p_job_id AND status = 'machine' AND mt_text IS NULL;
    END IF;
    UPDATE genba.translation_job SET status = 'running', resumed_from_ordinal = COALESCE(first_ord, 1), error = NULL, finished_at = NULL WHERE id = p_job_id AND status = 'failed';
    IF NOT FOUND THEN RAISE EXCEPTION 'JOB_NOT_FAILED: only a failed job can be resumed'; END IF;
    RETURN COALESCE(first_ord, 1);
END;
$$;

-- AI-02 / AI-05 / AI-08: metrics of an evaluation run from its results; the gate and the regression flag are applied by the trigger.
CREATE OR REPLACE FUNCTION genba.eval_finalize(p_run_id uuid) RETURNS void
LANGUAGE sql AS $$
    UPDATE genba.eval_run r
       SET glossary_compliance = m.g, numbers_preserved = m.n, mean_ped = m.p, class_accuracy = m.c
      FROM (SELECT round(avg(CASE WHEN glossary_ok THEN 1 ELSE 0 END), 4) AS g,
                   round(avg(CASE WHEN numbers_ok THEN 1 ELSE 0 END), 4) AS n,
                   round(avg(ped), 4) AS p,
                   round(avg(CASE WHEN x.process_pred IS NOT DISTINCT FROM t.expected_process AND x.message_pred IS NOT DISTINCT FROM t.expected_message_type THEN 1 ELSE 0 END), 4) AS c
              FROM genba.eval_result x JOIN genba.test_segment t ON t.id = x.test_segment_id WHERE x.eval_run_id = p_run_id) m
     WHERE r.id = p_run_id
$$;

-- FR-26: how consistently a term's mandated rendering appears in the approved memory.
CREATE OR REPLACE FUNCTION genba.term_consistency(p_term_id uuid)
RETURNS TABLE (segments integer, consistent integer, inconsistent integer)
LANGUAGE sql STABLE AS $$
    WITH s AS (SELECT m.*, genba.term_text(g, m.src_lang) AS src_r, genba.term_text(g, m.tgt_lang) AS tgt_r
                 FROM knowledge.tm_segment m, knowledge.glossary_term g
                WHERE g.id = p_term_id AND genba.term_text(g, m.src_lang) IS NOT NULL AND position(genba.term_text(g, m.src_lang) IN m.src_text) > 0)
    SELECT count(*)::integer, count(*) FILTER (WHERE tgt_r IS NOT NULL AND position(lower(tgt_r) IN lower(tgt_text)) > 0)::integer,
           count(*) FILTER (WHERE tgt_r IS NULL OR position(lower(tgt_r) IN lower(tgt_text)) = 0)::integer
      FROM s
$$;

-- FR-23: recurring Japanese terms in approved segments that the glossary does not know.
CREATE OR REPLACE FUNCTION genba.mine_candidates(p_job_id uuid, p_min_occurrences integer DEFAULT 2) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    n integer := 0;
    r record;
BEGIN
    FOR r IN
        WITH toks AS (
            SELECT (regexp_matches(s.src_text, '([ァ-ヴー]{3,}|[一-龯]{2,4})', 'g'))[1] AS tok
              FROM genba.segment s JOIN genba.translation_job j ON j.id = s.job_id
             WHERE s.job_id = p_job_id AND s.status = 'approved' AND j.src_lang = 'ja')
        SELECT tok, count(*) AS c FROM toks GROUP BY tok HAVING count(*) >= p_min_occurrences
    LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM knowledge.glossary_term g WHERE g.ja = r.tok OR position(r.tok IN COALESCE(g.ja, '')) > 0)
                   OR EXISTS (SELECT 1 FROM genba.term_alias a WHERE a.alias = r.tok);
        INSERT INTO genba.term_candidate (ja, occurrences, source_job_id) VALUES (r.tok, r.c, p_job_id)
        ON CONFLICT (ja) DO UPDATE SET occurrences = genba.term_candidate.occurrences + EXCLUDED.occurrences;
        n := n + 1;
    END LOOP;
    RETURN n;
END;
$$;

-- FR-26: daily usage rollup from approved segments.
CREATE OR REPLACE FUNCTION genba.rollup_term_usage(p_date date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO genba.term_usage (term_id, usage_date, count, inconsistencies)
    SELECT g.id, p_date,
           count(*) FILTER (WHERE position(genba.term_text(g, j.src_lang) IN s.src_text) > 0),
           count(*) FILTER (WHERE position(genba.term_text(g, j.src_lang) IN s.src_text) > 0 AND position(lower(genba.term_text(g, j.tgt_lang)) IN lower(s.final_text)) = 0)
      FROM knowledge.glossary_term g
      CROSS JOIN genba.segment s JOIN genba.translation_job j ON j.id = s.job_id
     WHERE s.status = 'approved' AND (s.approved_at AT TIME ZONE 'Asia/Bangkok')::date = p_date
       AND genba.term_text(g, j.src_lang) IS NOT NULL AND genba.term_text(g, j.tgt_lang) IS NOT NULL
     GROUP BY g.id
    HAVING count(*) FILTER (WHERE position(genba.term_text(g, j.src_lang) IN s.src_text) > 0) > 0
    ON CONFLICT (term_id, usage_date) DO UPDATE SET count = EXCLUDED.count, inconsistencies = EXCLUDED.inconsistencies;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- AC-08: the two-part rendering — translation first, interpretation in its own ruled block.
CREATE OR REPLACE FUNCTION genba.render_text(p_segment_id uuid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    s genba.segment%ROWTYPE;
    j genba.translation_job%ROWTYPE;
    i genba.interpretation%ROWTYPE;
    txt text;
    checks text;
    docs text;
    readings text;
BEGIN
    SELECT * INTO s FROM genba.segment WHERE id = p_segment_id;
    SELECT * INTO j FROM genba.translation_job WHERE id = s.job_id;
    txt := format(E'SOURCE (%s)\n%s\n\nTRANSLATION (%s)\n%s\n', upper(j.src_lang::text), s.src_text, upper(j.tgt_lang::text), COALESCE(s.final_text, s.mt_text));
    SELECT * INTO i FROM genba.interpretation WHERE segment_id = p_segment_id;
    IF FOUND THEN
        IF i.ambiguous THEN
            SELECT string_agg(format('  %s. %s — %s / %s%s', r.ordinal, r.reading_ja, r.th, r.en, COALESCE(' (' || r.usage_note || ')', '')), E'\n' ORDER BY r.ordinal) INTO readings FROM genba.reading r WHERE r.segment_id = p_segment_id;
            txt := txt || format(E'\n──────── POSSIBLE READINGS (inferred — confidence %s, ambiguous) ────────\n%s\n', to_char(i.confidence, 'FM0.00'), readings);
        ELSE
            SELECT string_agg(format('  ✓ %s (%s)', c.item_en, c.item_ja), E'\n' ORDER BY c.ordinal) INTO checks
              FROM genba.check_item c WHERE c.id IN (SELECT (x.value #>> '{}')::uuid FROM jsonb_array_elements(i.suggested_checks_json) x);
            SELECT string_agg('  · ' || d.title, E'\n' ORDER BY d.title) INTO docs
              FROM knowledge.document d WHERE d.id IN (SELECT (x.value #>> '{}')::uuid FROM jsonb_array_elements(i.related_docs_json) x);
            txt := txt || format(E'\n──────── INTERPRETATION (inferred — confidence %s) ────────\nProcess       : %s\nMessage type  : %s\nEntities      : %s\n%s\nStandard items to check\n%s\n\nRelated documents (found in index)\n%s\n',
                                 to_char(i.confidence, 'FM0.00'), i.process, i.message_type, i.entities_json::text,
                                 COALESCE('Timing        : ' || i.timing_note, ''), COALESCE(checks, '  (none)'), COALESCE(docs, '  (none)'));
        END IF;
    END IF;
    txt := txt || format(E'\nGlossary terms applied: %s\n', COALESCE((SELECT string_agg(x.value #>> '{}', ', ') FROM jsonb_array_elements(s.checks_json #> '{flags,glossary,applied}') x), '(none)'));
    RETURN txt;
END;
$$;

-- =====================================================================
-- 16. GENBA — guard triggers (DDS-14 DD-J01…J09)
-- =====================================================================

-- NFR-08 / FR-21 / FR-30: glossary edits by admins only; forbidden renderings may not be the mandated ones; every change is a version.
CREATE OR REPLACE FUNCTION genba.trg_glossary_guard_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    f jsonb;
BEGIN
    IF NEW.approved_by IS NULL OR NOT genba.has_role(NEW.approved_by, 'admin') THEN
        RAISE EXCEPTION 'GLOSSARY_APPROVER: glossary changes need an admin approver (FR-30, NFR-08)';
    END IF;
    IF NEW.ja IS NULL AND NEW.th IS NULL AND NEW.en IS NULL THEN RAISE EXCEPTION 'GLOSSARY_EMPTY'; END IF;
    FOR f IN SELECT * FROM jsonb_array_elements(COALESCE(NEW.forbidden_json, '[]'::jsonb)) LOOP
        IF NOT (f ? 'lang' AND f ? 'text') THEN RAISE EXCEPTION 'FORBIDDEN_SHAPE: {lang, text}'; END IF;
        IF lower(f ->> 'text') = lower(COALESCE(CASE f ->> 'lang' WHEN 'ja' THEN NEW.ja WHEN 'th' THEN NEW.th ELSE NEW.en END, '')) THEN
            RAISE EXCEPTION 'FORBIDDEN_IS_MANDATED: % is the mandated % rendering', f ->> 'text', f ->> 'lang';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_glossary_guard BEFORE INSERT OR UPDATE ON knowledge.glossary_term
    FOR EACH ROW EXECUTE FUNCTION genba.trg_glossary_guard_fn();

CREATE OR REPLACE FUNCTION genba.trg_glossary_version_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO genba.term_version (term_id, version_no, ja, ja_reading, th, en, domain, notes, forbidden_json, approved_by, effective_from, change_note)
    VALUES (NEW.id, (SELECT COALESCE(max(version_no), 0) + 1 FROM genba.term_version WHERE term_id = NEW.id),
            NEW.ja, NEW.ja_reading, NEW.th, NEW.en, NEW.domain, NEW.notes, NEW.forbidden_json, NEW.approved_by,
            COALESCE(NULLIF(current_setting('genba.effective_from', true), '')::date, (NEW.updated_at AT TIME ZONE 'Asia/Bangkok')::date),
            NULLIF(current_setting('genba.change_note', true), ''));
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_glossary_version AFTER INSERT OR UPDATE ON knowledge.glossary_term
    FOR EACH ROW EXECUTE FUNCTION genba.trg_glossary_version_fn();

-- FR-24 / AC-07: memory is approved, immutable, and one target per normalised source and pair.
CREATE OR REPLACE FUNCTION genba.trg_tm_guard_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'TM_IMMUTABLE: approved memory is never edited or deleted; approve a new segment instead'; END IF;
    IF NEW.approver_id IS NULL OR NOT genba.has_role(NEW.approver_id, 'reviewer', 'admin') THEN
        RAISE EXCEPTION 'TM_APPROVER: a TM segment needs a reviewer or admin approver (FR-24, FR-30)';
    END IF;
    IF btrim(NEW.src_text) = '' OR btrim(NEW.tgt_text) = '' THEN RAISE EXCEPTION 'TM_EMPTY'; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tm_guard BEFORE INSERT OR UPDATE OR DELETE ON knowledge.tm_segment
    FOR EACH ROW EXECUTE FUNCTION genba.trg_tm_guard_fn();

CREATE OR REPLACE FUNCTION genba.trg_tm_index_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM genba.tm_index i WHERE i.src_lang = NEW.src_lang AND i.tgt_lang = NEW.tgt_lang AND i.src_hash = genba.tm_hash(NEW.src_text)) THEN
        RAISE EXCEPTION 'TM_DUPLICATE_SOURCE: an approved target already exists for this source and pair (exact matches must be unambiguous, FR-03)';
    END IF;
    INSERT INTO genba.tm_index (tm_segment_id, src_lang, tgt_lang, src_norm, src_hash)
    VALUES (NEW.id, NEW.src_lang, NEW.tgt_lang, genba.normalise_for_tm(NEW.src_text), genba.tm_hash(NEW.src_text));
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_tm_index AFTER INSERT ON knowledge.tm_segment
    FOR EACH ROW EXECUTE FUNCTION genba.trg_tm_index_fn();

-- C-01 / C-02 / C-04 / FR-28 / FR-29 / FR-30: checks are computed here; status follows the checks; approval is gated.
CREATE OR REPLACE FUNCTION genba.trg_segment_checks_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    j   genba.translation_job%ROWTYPE;
    tgt text;
    ctx text := current_setting('genba.edit_ctx', true);
    tmt text;
BEGIN
    SELECT * INTO j FROM genba.translation_job WHERE id = NEW.job_id;
    -- FR-03 / AI-07: an exact TM hit is reused verbatim
    IF NEW.tm_match_id IS NOT NULL AND NEW.tm_score = 1 THEN
        SELECT tgt_text INTO tmt FROM knowledge.tm_segment WHERE id = NEW.tm_match_id;
        IF NEW.mt_text IS DISTINCT FROM tmt THEN RAISE EXCEPTION 'TM_EXACT_PRIORITY: an exact match is reused verbatim (FR-03)'; END IF;
    END IF;
    -- FR-29: final_text changes only through genba.edit_segment / approve_segment
    IF TG_OP = 'UPDATE' AND NEW.final_text IS DISTINCT FROM OLD.final_text AND ctx IS DISTINCT FROM NEW.id::text THEN
        RAISE EXCEPTION 'EDIT_CONTEXT_REQUIRED: use genba.edit_segment() so the edit is recorded with its distance (FR-29)';
    END IF;
    tgt := COALESCE(NEW.final_text, NEW.mt_text);
    IF tgt IS NOT NULL THEN
        NEW.checks_json := genba.run_checks(NEW.src_text, tgt, j.src_lang, j.tgt_lang);
    END IF;
    IF NEW.status = 'approved' THEN
        IF TG_OP = 'INSERT' THEN RAISE EXCEPTION 'APPROVE_ON_INSERT: a segment is approved after review, never created approved'; END IF;
        IF NEW.checks_json IS NULL OR (NEW.checks_json ->> 'blocked')::boolean THEN
            RAISE EXCEPTION 'SEGMENT_BLOCKED: numbers/codes differ — %', NEW.checks_json #> '{blocking,numbers}';
        END IF;
        IF (NEW.checks_json ->> 'flagged')::boolean AND NEW.reviewer_note IS NULL THEN
            RAISE EXCEPTION 'SEGMENT_FLAGGED: unresolved flags need a reviewer note — %', NEW.checks_json -> 'flags';
        END IF;
        IF NEW.approved_by IS NULL OR NOT genba.has_role(NEW.approved_by, 'reviewer', 'admin') THEN
            RAISE EXCEPTION 'APPROVER_ROLE: only a reviewer or admin approves (FR-30)';
        END IF;
        NEW.approved_at := COALESCE(NEW.approved_at, now());
    ELSE
        IF NEW.checks_json IS NOT NULL AND (NEW.checks_json ->> 'blocked')::boolean THEN NEW.status := 'blocked';
        ELSIF NEW.checks_json IS NOT NULL AND (NEW.checks_json ->> 'flagged')::boolean AND NEW.status IN ('machine', 'blocked', 'flagged', 'edited') THEN NEW.status := 'flagged';
        ELSIF NEW.status IN ('blocked', 'flagged') THEN NEW.status := CASE WHEN NEW.final_text IS NOT NULL THEN 'edited' ELSE 'machine' END;
        END IF;
        IF TG_OP = 'UPDATE' AND OLD.status = 'approved' THEN RAISE EXCEPTION 'SEGMENT_APPROVED: an approved segment is memory; changes need a new segment'; END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_segment_checks BEFORE INSERT OR UPDATE ON genba.segment
    FOR EACH ROW EXECUTE FUNCTION genba.trg_segment_checks_fn();

-- FR-24: approval writes the memory (once) and links it.
CREATE OR REPLACE FUNCTION genba.trg_tm_writeback_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    j    genba.translation_job%ROWTYPE;
    tmid uuid;
    h    text;
BEGIN
    IF NEW.status = 'approved' AND OLD.status <> 'approved' AND NEW.tm_written_id IS NULL THEN
        SELECT * INTO j FROM genba.translation_job WHERE id = NEW.job_id;
        h := genba.tm_hash(NEW.src_text);
        SELECT i.tm_segment_id INTO tmid FROM genba.tm_index i WHERE i.src_lang = j.src_lang AND i.tgt_lang = j.tgt_lang AND i.src_hash = h;
        IF tmid IS NOT NULL THEN
            IF (SELECT tgt_text FROM knowledge.tm_segment WHERE id = tmid) IS DISTINCT FROM NEW.final_text THEN
                RAISE EXCEPTION 'TM_CONFLICT: this source already has a different approved target; resolve in the glossary/TM review';
            END IF;
        ELSE
            INSERT INTO knowledge.tm_segment (src_lang, tgt_lang, src_text, tgt_text, domain, doc_ref, approver_id, created_at)
            VALUES (j.src_lang, j.tgt_lang, NEW.src_text, NEW.final_text, COALESCE(j.format::text, 'text'), 'job:' || NEW.job_id::text || '#' || NEW.ordinal, NEW.approved_by, NEW.approved_at)
            RETURNING id INTO tmid;
        END IF;
        PERFORM set_config('genba.edit_ctx', NEW.id::text, true);
        UPDATE genba.segment SET tm_written_id = tmid WHERE id = NEW.id;
        PERFORM set_config('genba.edit_ctx', '', true);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_tm_writeback AFTER UPDATE OF status ON genba.segment
    FOR EACH ROW EXECUTE FUNCTION genba.trg_tm_writeback_fn();

-- C-05 / FR-14 / FR-15 / AI-09 / FR-12: inference is labelled, thresholded, curated and indexed.
CREATE OR REPLACE FUNCTION genba.trg_interpretation_guard_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    thr numeric := genba.setting_num('ambiguity_threshold');
    x   jsonb;
    n   integer;
BEGIN
    IF NEW.inferred IS DISTINCT FROM true THEN RAISE EXCEPTION 'INTERPRETATION_NOT_LABELLED: inferred must be true (C-05)'; END IF;
    IF NEW.ambiguous THEN
        SELECT count(*) INTO n FROM genba.reading r WHERE r.segment_id = NEW.segment_id;
        IF n < 2 THEN RAISE EXCEPTION 'READINGS_REQUIRED: an ambiguous source lists >= 2 readings (FR-15)'; END IF;
        IF NEW.confidence > thr THEN RAISE EXCEPTION 'AMBIGUOUS_CONFIDENCE: % above the ambiguity threshold %', NEW.confidence, thr; END IF;
        IF jsonb_array_length(NEW.suggested_checks_json) > 0 OR jsonb_array_length(NEW.related_docs_json) > 0 THEN
            RAISE EXCEPTION 'AMBIGUOUS_ASSERTS: an ambiguous reading suggests nothing';
        END IF;
    ELSE
        IF NEW.confidence < thr THEN RAISE EXCEPTION 'CONFIDENCE_BELOW_THRESHOLD: % < % — list readings instead of guessing (FR-15)', NEW.confidence, thr; END IF;
        FOR x IN SELECT * FROM jsonb_array_elements(NEW.suggested_checks_json) LOOP
            IF NOT EXISTS (SELECT 1 FROM genba.check_item c WHERE c.id = (x #>> '{}')::uuid AND c.process = NEW.process AND c.message_type = NEW.message_type) THEN
                RAISE EXCEPTION 'CHECK_NOT_CURATED: % is not a curated item for %/% (FR-12)', x #>> '{}', NEW.process, NEW.message_type;
            END IF;
        END LOOP;
        FOR x IN SELECT * FROM jsonb_array_elements(NEW.related_docs_json) LOOP
            IF NOT EXISTS (SELECT 1 FROM knowledge.document d WHERE d.id = (x #>> '{}')::uuid) THEN
                RAISE EXCEPTION 'RELATED_DOC_NOT_INDEXED: % (AI-09, AC-09)', x #>> '{}';
            END IF;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_interpretation_guard BEFORE INSERT OR UPDATE ON genba.interpretation
    FOR EACH ROW EXECUTE FUNCTION genba.trg_interpretation_guard_fn();

CREATE OR REPLACE FUNCTION genba.trg_reading_limit_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ordinal > genba.setting_num('max_readings') THEN RAISE EXCEPTION 'READINGS_MAX: at most % readings', genba.setting_num('max_readings'); END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reading_limit BEFORE INSERT OR UPDATE ON genba.reading
    FOR EACH ROW EXECUTE FUNCTION genba.trg_reading_limit_fn();

-- C-03 / NFR-07: job transitions; confidential jobs stay local; resume only from failed.
CREATE OR REPLACE FUNCTION genba.trg_job_guard_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.confidential AND NOT NEW.confidential THEN RAISE EXCEPTION 'CONFIDENTIAL_IMMUTABLE: a confidential job cannot be declassified (C-03)'; END IF;
        IF OLD.status = 'failed' AND NEW.status = 'running' AND NEW.resumed_from_ordinal IS NULL THEN
            RAISE EXCEPTION 'RESUME_REQUIRED: use genba.resume_job() (NFR-07)';
        END IF;
        IF OLD.status IN ('done', 'cancelled') AND NEW.status <> OLD.status THEN RAISE EXCEPTION 'JOB_FINISHED'; END IF;
    END IF;
    IF NEW.status = 'running' THEN NEW.started_at := COALESCE(NEW.started_at, now()); END IF;
    IF NEW.status IN ('done', 'failed', 'cancelled') THEN NEW.finished_at := COALESCE(NEW.finished_at, now()); END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_job_guard BEFORE INSERT OR UPDATE ON genba.translation_job
    FOR EACH ROW EXECUTE FUNCTION genba.trg_job_guard_fn();

-- FR-18 / AI-06: handwriting or low character confidence is flagged, always.
CREATE OR REPLACE FUNCTION genba.trg_ocr_flag_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.low_confidence := NEW.handwriting OR NEW.char_confidence < genba.setting_num('ocr_char_accuracy_min');
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ocr_flag BEFORE INSERT OR UPDATE ON genba.ocr_region
    FOR EACH ROW EXECUTE FUNCTION genba.trg_ocr_flag_fn();

-- AI-02 / AI-05 / AI-08: the gate is computed, never supplied; a regression > 2 % flags investigation.
CREATE OR REPLACE FUNCTION genba.trg_eval_gate_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    prev genba.eval_run%ROWTYPE;
    computed boolean;
    reg numeric := genba.setting_num('regression_pct') / 100;
BEGIN
    IF NEW.glossary_compliance IS NULL OR NEW.numbers_preserved IS NULL OR NEW.mean_ped IS NULL OR NEW.class_accuracy IS NULL THEN
        IF NEW.passed IS NOT NULL THEN RAISE EXCEPTION 'EVAL_INCOMPLETE: metrics missing; call genba.eval_finalize() first'; END IF;
        RETURN NEW;
    END IF;
    computed := NEW.glossary_compliance >= genba.setting_num('gate_glossary_min')
            AND NEW.numbers_preserved >= genba.setting_num('gate_numbers_min')
            AND NEW.mean_ped <= genba.setting_num('gate_ped_max')
            AND NEW.class_accuracy >= genba.setting_num('gate_class_min');
    IF NEW.passed IS NOT NULL AND NEW.passed <> computed THEN
        RAISE EXCEPTION 'EVAL_GATE: supplied passed = % but the gates say % (AI-02, AI-05)', NEW.passed, computed;
    END IF;
    NEW.passed := computed;
    SELECT * INTO prev FROM genba.eval_run r
     WHERE r.test_set_id = NEW.test_set_id AND r.id <> NEW.id AND r.run_at < NEW.run_at AND r.mean_ped IS NOT NULL
     ORDER BY r.run_at DESC LIMIT 1;
    IF FOUND THEN
        NEW.investigate := (prev.glossary_compliance - NEW.glossary_compliance > reg)
                        OR (prev.numbers_preserved - NEW.numbers_preserved > reg)
                        OR (NEW.mean_ped - prev.mean_ped > reg)
                        OR (prev.class_accuracy - NEW.class_accuracy > reg);
    ELSE
        NEW.investigate := false;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_eval_gate BEFORE INSERT OR UPDATE ON genba.eval_run
    FOR EACH ROW EXECUTE FUNCTION genba.trg_eval_gate_fn();

-- FR-23: candidate decisions by admins.
CREATE OR REPLACE FUNCTION genba.trg_candidate_guard_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'proposed' THEN
        IF NEW.decided_by IS NULL OR NOT genba.has_role(NEW.decided_by, 'admin') THEN RAISE EXCEPTION 'CANDIDATE_DECIDER: only an admin accepts or rejects a term'; END IF;
        NEW.decided_at := COALESCE(NEW.decided_at, now());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_candidate_guard BEFORE INSERT OR UPDATE ON genba.term_candidate
    FOR EACH ROW EXECUTE FUNCTION genba.trg_candidate_guard_fn();

-- History is append-only.
CREATE OR REPLACE FUNCTION genba.trg_append_only_fn() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'APPEND_ONLY: % is history', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_edit_append_only BEFORE UPDATE OR DELETE ON genba.segment_edit
    FOR EACH ROW EXECUTE FUNCTION genba.trg_append_only_fn();
CREATE TRIGGER trg_version_append_only BEFORE UPDATE OR DELETE ON genba.term_version
    FOR EACH ROW EXECUTE FUNCTION genba.trg_append_only_fn();
CREATE TRIGGER trg_eval_result_append_only BEFORE UPDATE OR DELETE ON genba.eval_result
    FOR EACH ROW EXECUTE FUNCTION genba.trg_append_only_fn();

-- =====================================================================
-- 17. GENBA — indexes and views
-- =====================================================================

CREATE INDEX idx_genba_tm_index_norm_trgm ON genba.tm_index USING gin (src_norm gin_trgm_ops);
CREATE INDEX idx_genba_job_status         ON genba.translation_job (status, created_at DESC);
CREATE INDEX idx_genba_job_user           ON genba.translation_job (created_by, created_at DESC);
CREATE INDEX idx_genba_segment_job        ON genba.segment (job_id, ordinal);
CREATE INDEX idx_genba_segment_status     ON genba.segment (status) WHERE status IN ('blocked', 'flagged', 'edited', 'needs_review');
CREATE INDEX idx_genba_edit_segment       ON genba.segment_edit (segment_id, ts DESC);
CREATE INDEX idx_genba_match_segment      ON genba.tm_match (segment_id, score DESC);
CREATE INDEX idx_genba_interp_process     ON genba.interpretation (process, message_type);
CREATE INDEX idx_genba_reading_segment    ON genba.reading (segment_id, ordinal);
CREATE INDEX idx_genba_ocr_region_page    ON genba.ocr_region (page_id, ordinal);
CREATE INDEX idx_genba_ocr_low            ON genba.ocr_region (low_confidence) WHERE low_confidence;
CREATE INDEX idx_genba_term_version_term  ON genba.term_version (term_id, version_no DESC);
CREATE INDEX idx_genba_alias_lang         ON genba.term_alias (lang, alias);
CREATE INDEX idx_genba_candidate_status   ON genba.term_candidate (status, occurrences DESC);
CREATE INDEX idx_genba_usage_date         ON genba.term_usage (usage_date DESC);
CREATE INDEX idx_genba_eval_set           ON genba.eval_run (test_set_id, run_at DESC);
CREATE INDEX idx_genba_doc_tag            ON genba.document_tag (lower(tag));

-- FR-27: the review queue — source, output, TM match, glossary hits, check badges.
CREATE OR REPLACE VIEW genba.v_review_queue AS
SELECT s.id, j.id AS job_id, j.kind, j.src_lang, j.tgt_lang, j.register, s.ordinal, s.anchor, s.src_text, s.mt_text, s.final_text, s.status,
       s.tm_score, (s.checks_json ->> 'blocked')::boolean AS blocked, (s.checks_json ->> 'flagged')::boolean AS flagged,
       s.checks_json #> '{blocking,numbers,missing}' AS numbers_missing, s.checks_json #> '{blocking,numbers,extra}' AS numbers_extra,
       s.checks_json #> '{flags,glossary,missing}' AS glossary_missing, s.checks_json #> '{flags,forbidden,hits}' AS forbidden_hits,
       (s.checks_json #>> '{flags,length_ratio,ratio}')::numeric AS length_ratio, (s.checks_json #>> '{flags,omission,ok}')::boolean AS omission_ok,
       (SELECT count(*) FROM genba.tm_match m WHERE m.segment_id = s.id) AS fuzzy_matches,
       s.edit_distance, s.reviewer_note, s.approved_by, s.approved_at
  FROM genba.segment s JOIN genba.translation_job j ON j.id = s.job_id
 WHERE s.status <> 'approved';

CREATE OR REPLACE VIEW genba.v_segment_checks AS
SELECT s.id, s.job_id, s.ordinal, s.status, s.checks_json -> 'blocking' AS blocking, s.checks_json -> 'flags' AS flags,
       (s.checks_json ->> 'clean')::boolean AS clean
  FROM genba.segment s;

-- FR-20 / NFR-07: job progress and resumability.
CREATE OR REPLACE VIEW genba.v_job_progress AS
SELECT j.id, j.kind, j.status, j.src_lang, j.tgt_lang, j.format, j.confidential, j.provider, j.channel, j.created_by, j.created_at, j.finished_at,
       j.segment_count, j.done_count,
       (SELECT count(*) FROM genba.segment s WHERE s.job_id = j.id AND s.status = 'blocked') AS blocked,
       (SELECT count(*) FROM genba.segment s WHERE s.job_id = j.id AND s.status = 'flagged') AS flagged,
       (SELECT count(*) FROM genba.segment s WHERE s.job_id = j.id AND s.tm_score = 1) AS tm_exact,
       (SELECT count(*) FROM genba.job_file f WHERE f.job_id = j.id) AS files,
       (SELECT count(*) FROM genba.job_file f WHERE f.job_id = j.id AND f.status = 'done') AS files_done,
       (SELECT count(*) FROM genba.job_file f WHERE f.job_id = j.id AND f.status = 'failed') AS files_failed,
       j.resumed_from_ordinal, j.error
  FROM genba.translation_job j;

-- NFR-08: the glossary with its current version number and aliases.
CREATE OR REPLACE VIEW genba.v_glossary_current AS
SELECT g.id, g.ja, g.ja_reading, g.th, g.en, g.domain, g.notes, g.forbidden_json, u.display_name AS approved_by, g.updated_at,
       (SELECT max(v.version_no) FROM genba.term_version v WHERE v.term_id = g.id) AS version_no,
       (SELECT max(v.effective_from) FROM genba.term_version v WHERE v.term_id = g.id) AS effective_from,
       (SELECT string_agg(a.alias || ' (' || a.lang || ')', ', ' ORDER BY a.alias) FROM genba.term_alias a WHERE a.term_id = g.id) AS aliases
  FROM knowledge.glossary_term g LEFT JOIN core.app_user u ON u.id = g.approved_by;

-- FR-26: consistency of each term in the approved memory.
CREATE OR REPLACE VIEW genba.v_term_consistency AS
SELECT g.id, g.ja, g.th, g.en, c.segments, c.consistent, c.inconsistent,
       CASE WHEN c.segments > 0 THEN round(c.consistent::numeric / c.segments, 4) END AS consistency
  FROM knowledge.glossary_term g CROSS JOIN LATERAL genba.term_consistency(g.id) c;

-- NFR-03: memory size per pair.
CREATE OR REPLACE VIEW genba.v_tm_stats AS
SELECT src_lang, tgt_lang, count(*) AS segments, count(*) FILTER (WHERE embedding IS NOT NULL) AS embedded, max(created_at) AS last_approved
  FROM knowledge.tm_segment GROUP BY src_lang, tgt_lang;

-- FR-31: the quality dashboard — post-edit distance trend, glossary compliance, throughput per day.
CREATE OR REPLACE VIEW genba.v_quality_dashboard AS
SELECT (s.approved_at AT TIME ZONE 'Asia/Bangkok')::date AS day, j.src_lang, j.tgt_lang,
       count(*) AS approved_segments,
       round(avg(COALESCE(s.edit_distance, 0)), 4) AS mean_ped,
       round(avg(CASE WHEN (s.checks_json #>> '{flags,glossary,ok}')::boolean THEN 1 ELSE 0 END), 4) AS glossary_compliance,
       count(*) FILTER (WHERE s.tm_score = 1) AS tm_exact_reused,
       count(DISTINCT s.job_id) AS jobs
  FROM genba.segment s JOIN genba.translation_job j ON j.id = s.job_id
 WHERE s.status = 'approved'
 GROUP BY 1, 2, 3;

CREATE OR REPLACE VIEW genba.v_eval_gate AS
SELECT r.id, t.name, t.version, r.run_at, r.model, r.prompt_version, r.glossary_compliance, r.numbers_preserved, r.mean_ped, r.class_accuracy, r.passed, r.investigate,
       genba.setting_num('gate_glossary_min') AS gate_glossary, genba.setting_num('gate_ped_max') AS gate_ped, genba.setting_num('gate_class_min') AS gate_class,
       (SELECT count(*) FROM genba.eval_result x WHERE x.eval_run_id = r.id) AS segments
  FROM genba.eval_run r JOIN genba.test_set t ON t.id = r.test_set_id;

CREATE OR REPLACE VIEW genba.v_ocr_flags AS
SELECT p.job_id, p.page_no, r.ordinal, r.orientation, r.handwriting, r.char_confidence, r.low_confidence, left(r.text, 40) AS text_head, r.segment_id
  FROM genba.ocr_region r JOIN genba.ocr_page p ON p.id = r.page_id;

-- =====================================================================
-- 18. ROLES AND GRANTS (standalone; platform mode keeps the platform's roles and adds worker_rw + auditor_ro)
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')     THEN CREATE ROLE app_rw     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')     THEN CREATE ROLE app_ro     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker_rw')  THEN CREATE ROLE worker_rw  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor_ro') THEN CREATE ROLE auditor_ro NOLOGIN; END IF;
END
$$;

COMMENT ON ROLE worker_rw  IS 'Translation, interpretation, document and OCR workers: jobs, segments, matches, interpretations, readings, OCR. Never writes the glossary or the memory (those change only through approval and admin paths).';
COMMENT ON ROLE auditor_ro IS 'Who translated what: jobs, segments, edits, approvals, glossary versions, memory, exports, audit log — read only (NFR-05).';

GRANT USAGE ON SCHEMA core, knowledge, genba TO app_rw, app_ro, worker_rw;
GRANT USAGE ON SCHEMA audit TO app_rw, app_ro, worker_rw, auditor_ro;
GRANT USAGE ON SCHEMA knowledge, genba, core TO auditor_ro;

-- app_rw (api): people's actions, glossary (through admins), roles, test sets, exports; segments only through the edit/approve functions
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core TO app_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA knowledge TO app_rw;
GRANT INSERT, UPDATE ON knowledge.glossary_term TO app_rw;
GRANT INSERT ON knowledge.tm_segment TO app_rw;                    -- write-back and TMX import (approver required by trigger)
GRANT SELECT ON ALL TABLES IN SCHEMA genba TO app_rw;
GRANT INSERT, UPDATE ON genba.translation_job, genba.job_file, genba.segment, genba.tm_index, genba.user_role, genba.term_alias, genba.term_candidate,
                        genba.term_usage, genba.process_keyword, genba.message_keyword, genba.check_item, genba.entity_pattern, genba.unit_alias,
                        genba.ratio_bound, genba.document_tag, genba.test_set, genba.test_segment, genba.eval_run, genba.export_job, genba.setting TO app_rw;
GRANT INSERT ON genba.segment_edit, genba.term_version, genba.eval_result, genba.reading, genba.tm_match TO app_rw;
GRANT DELETE ON genba.term_alias, genba.document_tag, genba.user_role TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO app_rw;

-- worker_rw: jobs, segments, matches, interpretations, readings, OCR — no glossary, no memory, no roles
GRANT SELECT ON ALL TABLES IN SCHEMA core TO worker_rw;
REVOKE SELECT ON core.app_user, core.user_line_scope FROM worker_rw;
GRANT SELECT (id, display_name, role) ON core.app_user TO worker_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA knowledge TO worker_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA genba TO worker_rw;
GRANT INSERT, UPDATE ON genba.translation_job, genba.job_file, genba.segment, genba.tm_match, genba.interpretation, genba.reading,
                        genba.ocr_page, genba.ocr_region, genba.term_candidate, genba.term_usage, genba.document_tag, genba.eval_result TO worker_rw;
GRANT INSERT ON knowledge.document, genba.eval_run TO worker_rw;
GRANT UPDATE ON genba.eval_run TO worker_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO worker_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO worker_rw;

-- app_ro (dashboard): read only, no credentials
GRANT SELECT ON ALL TABLES IN SCHEMA core, knowledge, genba, audit TO app_ro;
REVOKE SELECT ON core.app_user FROM app_ro;
GRANT SELECT (id, display_name, role) ON core.app_user TO app_ro;

-- auditor_ro: who translated what
GRANT SELECT ON genba.translation_job, genba.job_file, genba.segment, genba.segment_edit, genba.tm_match, genba.interpretation, genba.reading,
                genba.term_version, genba.user_role, genba.export_job, genba.eval_run, genba.eval_result TO auditor_ro;
GRANT SELECT ON knowledge.glossary_term, knowledge.tm_segment, knowledge.document TO auditor_ro;
GRANT SELECT ON audit.log, audit.auth_event TO auditor_ro;
GRANT SELECT (id, display_name, role) ON core.app_user TO auditor_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA genba GRANT SELECT ON TABLES TO app_ro, app_rw, worker_rw;

-- =====================================================================
-- 19. SCHEMA VERSION
-- =====================================================================

INSERT INTO genba.migration (version, description)
VALUES ('genba_0001', 'GenbaGo extension of the platform knowledge context (DDS-14 v1.0): roles, glossary versions/aliases/candidates/usage, keywords and curated check items, jobs, segments and edits, TM index and matches, interpretations and readings, OCR, test sets and evaluation')
ON CONFLICT (version) DO NOTHING;
