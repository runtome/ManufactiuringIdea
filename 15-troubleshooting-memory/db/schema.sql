-- =====================================================================
--  Genba Memory — PostgreSQL 16 schema (standalone deployment)
--  DDS-15-GenbaMemory v1.0 (Draft) - 2026-09-22 - Suphot N.
--
--  Sections 1-9 are EXTRACTED VERBATIM from ../../00-factorybrain-platform/db/schema.sql
--  (extensions, helpers, the enums the extracted objects use, the whole core
--  section, quality.signal and quality.case, the whole knowledge section, audit,
--  their indexes, the updated_at triggers and knowledge.v_citable_case).
--  TEST-15 TC-002 diffs every block against the platform file; a difference is a
--  defect in this file, never in the platform's.
--  Sections 10-19 are the Genba Memory extension (schema memory, migration memory_0001).
--
--  Ownership inside the extracted knowledge section (SAD-15 ADR-H01):
--    knowledge.document / chunk / case_record / case_source / case_chunk  -> Genba Memory (15)
--    knowledge.glossary_term / knowledge.tm_segment                       -> GenbaGo (14), read-only here
--    knowledge.chunk.suspicious / suspicious_reason                       -> Factory Copilot (10)
--
--  Platform mode (SAD-15 section 9): apply ONLY sections 10-19 (migration
--  memory_0001) on the platform database; sections 1-9 already exist there.
--
--  NOT EXECUTED on the authoring machine (no PostgreSQL) - TEST-15 TC-009.
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
CREATE SCHEMA IF NOT EXISTS quality;     -- quality.signal and quality.case only: a new case is what pushes precedent (FR-20)
CREATE SCHEMA IF NOT EXISTS knowledge;   -- owned by Genba Memory (SAD-00 section 13, "tight (core)")
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
-- 4. ENUMERATED TYPES  [platform section 4 - the types the extracted objects use, verbatim lines]
-- =====================================================================

CREATE TYPE core.shift_code        AS ENUM ('A', 'B', 'C', 'OT');
CREATE TYPE core.language_code     AS ENUM ('th', 'ja', 'en');

CREATE TYPE quality.case_status    AS ENUM ('open', 'containment', 'analysis',
                                            'action', 'verification', 'closed', 'cancelled');
CREATE TYPE quality.severity       AS ENUM ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL');

-- =====================================================================
-- 5. CORE - master data and production facts  [platform section 5, verbatim]
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
-- 6. QUALITY - signal and case  [platform section 7, verbatim lines]
-- =====================================================================

-- Only the two objects Genba Memory touches: knowledge.case_record.quality_case_id
-- references quality.case, and an insert there is what triggers a suggestion
-- (FR-20, IF-82). The rest of the quality section belongs to QE-Agent (09).

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

-- =====================================================================
-- 7. KNOWLEDGE - documents, chunks, case records, TM  [platform section 9, verbatim]
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
-- 8. AUDIT  [platform section 13, verbatim]
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
-- 9. PLATFORM INDEXES, TRIGGERS AND VIEWS  [verbatim]
-- =====================================================================

-- core
CREATE INDEX idx_production_fact_date      ON core.production_fact (prod_date DESC);
CREATE INDEX idx_production_fact_line_date ON core.production_fact (line_id, prod_date DESC);
CREATE INDEX idx_defect_fact_date          ON core.defect_fact (prod_date DESC);
CREATE INDEX idx_defect_fact_type          ON core.defect_fact (defect_type_id, prod_date DESC);
CREATE INDEX idx_quarantine_batch          ON core.quarantine_row (batch_id);
CREATE INDEX idx_ingest_batch_sha          ON core.ingest_batch (sha256);

-- quality
CREATE INDEX idx_signal_status        ON quality.signal (status, opened_at DESC);
CREATE INDEX idx_case_status          ON quality.case (status, opened_at DESC);
CREATE INDEX idx_case_line            ON quality.case (line_id, opened_at DESC);

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

-- ops / audit
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

-- Approved knowledge only: unapproved AI drafts must never become precedent (P-3)
CREATE OR REPLACE VIEW knowledge.v_citable_case AS
SELECT cr.*
FROM knowledge.case_record cr
WHERE cr.verified_at IS NOT NULL;

COMMENT ON VIEW knowledge.v_citable_case IS
  'Retrieval for agent citation reads this view, not the base table, so an unverified extraction cannot be quoted as established fact.';

-- =====================================================================
-- 10. MEMORY — schema and types  (extension of the platform's knowledge
--     context; migration memory_0001)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS memory;

COMMENT ON SCHEMA memory IS
  'Genba Memory (SRS-15). The platform''s knowledge schema holds the documents, chunks and case records; memory holds everything that makes them trustworthy: provenance, curation, ranking, evaluation and the embedding registry (DDS-15 section 3).';

-- knowledge.chunk.suspicious and suspicious_reason belong to Factory Copilot
-- (10, migration copilot_0001, ICD-10 IF-55). Standalone they must exist here;
-- in platform mode copilot_0001 may already have added them, so both migrations
-- are written to apply in either order (ADR-H01, ICD-15 IF-55).
ALTER TABLE knowledge.chunk ADD COLUMN IF NOT EXISTS suspicious        boolean NOT NULL DEFAULT false;
ALTER TABLE knowledge.chunk ADD COLUMN IF NOT EXISTS suspicious_reason text;

CREATE TYPE memory.app_role       AS ENUM ('viewer', 'engineer', 'curator', 'admin');
CREATE TYPE memory.source_kind    AS ENUM ('folder', 'mail', 'chat', 'ticket', 'upload', 'manual');
CREATE TYPE memory.job_state      AS ENUM ('queued', 'running', 'done', 'failed', 'skipped');
CREATE TYPE memory.doc_class      AS ENUM ('eight_d', 'rca', 'maintenance_log', 'work_order',
                                           'handover', 'complaint', 'other');
CREATE TYPE memory.field_name     AS ENUM ('title', 'opened_at', 'closed_at', 'scope',
                                           'symptom', 'investigation', 'cause', 'containment',
                                           'corrective_action', 'verification', 'outcome', 'status');
CREATE TYPE memory.entity_kind    AS ENUM ('machine', 'line', 'sku', 'mould', 'defect_class', 'alarm_code');
CREATE TYPE memory.curation_kind  AS ENUM ('low_confidence', 'unmapped_entity', 'near_duplicate',
                                           'flagged_field', 'unverified_case', 'suspicious_chunk');
CREATE TYPE memory.curation_state AS ENUM ('open', 'in_review', 'resolved', 'dismissed');
CREATE TYPE memory.rating         AS ENUM ('helpful', 'not_helpful', 'incorrect');
CREATE TYPE memory.eval_kind      AS ENUM ('retrieval', 'extraction');
CREATE TYPE memory.embedding_state AS ENUM ('registering', 'active', 'retired');

COMMENT ON TYPE memory.field_name IS
  'The case model of SRS-15 FR-09. One memory.case_field row per member, each with its own confidence and provenance (ADR-H03) — never one score for the whole case.';
COMMENT ON TYPE memory.rating IS
  'incorrect is not a downvote: it flags the extraction, suppresses the field and opens a curation item (FR-30, AC-06).';

-- =====================================================================
-- 11. MEMORY — settings, roles, access groups, sources
-- =====================================================================

CREATE TABLE memory.setting (
    key         text PRIMARY KEY,
    value       jsonb       NOT NULL,
    locked      boolean     NOT NULL DEFAULT false,
    description text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN memory.setting.locked IS
  'A locked setting expresses a constraint, not a preference: verified-only retrieval, ACL as a predicate, local-only processing. deploy/schemas/genbamemory-config.schema.json const-locks the same keys (TEST-15 TC-007).';

CREATE TABLE memory.user_role (
    user_id    uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE CASCADE,
    role       memory.app_role NOT NULL,
    granted_by uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role)
);

CREATE TABLE memory.access_group (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code        text        NOT NULL UNIQUE,
    name        text        NOT NULL,
    description text
);

COMMENT ON TABLE memory.access_group IS
  'The groups named in knowledge.document.acl_json.groups. memory.acl_visible() resolves a user to their groups; there is no post-filter anywhere (P-4).';

CREATE TABLE memory.group_member (
    group_id uuid NOT NULL REFERENCES memory.access_group(id) ON DELETE CASCADE,
    user_id  uuid NOT NULL REFERENCES core.app_user(id)       ON DELETE CASCADE,
    PRIMARY KEY (group_id, user_id)
);

CREATE TABLE memory.source (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code          text        NOT NULL UNIQUE,
    kind          memory.source_kind NOT NULL,
    location      text        NOT NULL,
    default_acl_json jsonb    NOT NULL DEFAULT '{}'::jsonb,
    ocr_enabled   boolean     NOT NULL DEFAULT true,
    incremental   boolean     NOT NULL DEFAULT true,
    enabled       boolean     NOT NULL DEFAULT true,
    last_sync_at  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN memory.source.location IS
  'A path, mailbox or export name — never a credential. Credentials are files under the secrets directory (SEC-15 SEC-H29, IF-78).';

-- =====================================================================
-- 12. MEMORY — ingestion
-- =====================================================================

CREATE TABLE memory.ingest_job (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    source_id    uuid        REFERENCES memory.source(id) ON DELETE SET NULL,
    document_id  uuid        REFERENCES knowledge.document(id) ON DELETE SET NULL,
    original_name text       NOT NULL,
    sha256       text,
    state        memory.job_state NOT NULL DEFAULT 'queued',
    stage        text        NOT NULL DEFAULT 'fetch'
                 CHECK (stage IN ('fetch','text','ocr','classify','extract','normalise','index','done')),
    bytes        bigint,
    started_at   timestamptz,
    finished_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE memory.ingest_job IS
  'A failed job is a row, never an exception path: ingestion failures must not affect retrieval (NFR-07, QAS-07).';

CREATE TABLE memory.ingest_error (
    id        uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    job_id    uuid        NOT NULL REFERENCES memory.ingest_job(id) ON DELETE CASCADE,
    stage     text        NOT NULL,
    reason    text        NOT NULL
              CHECK (reason IN ('unreadable_scan','password_protected','unsupported_format',
                                'empty_document','ocr_failed','extract_failed','too_large',
                                'source_unreachable','duplicate')),
    detail    text        NOT NULL,
    action    text        NOT NULL,
    ts        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN memory.ingest_error.action IS
  'What a person should do about it. FR-07 asks for actionable reasons, so the actionable part is a column rather than a convention.';

CREATE TABLE memory.doc_text (
    document_id uuid        NOT NULL REFERENCES knowledge.document(id) ON DELETE CASCADE,
    page        integer     NOT NULL,
    lang        core.language_code,
    text        text        NOT NULL,
    from_ocr    boolean     NOT NULL DEFAULT false,
    PRIMARY KEY (document_id, page)
);

CREATE TABLE memory.ocr_page (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    document_id uuid        NOT NULL REFERENCES knowledge.document(id) ON DELETE CASCADE,
    page        integer     NOT NULL,
    width       integer,
    height      integer,
    engine      text        NOT NULL,
    mean_confidence numeric(4,3),
    CONSTRAINT ocr_page_unique UNIQUE (document_id, page)
);

CREATE TABLE memory.ocr_region (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ocr_page_id uuid        NOT NULL REFERENCES memory.ocr_page(id) ON DELETE CASCADE,
    ordinal     integer     NOT NULL,
    orientation text        NOT NULL CHECK (orientation IN ('horizontal','vertical')),
    lang        core.language_code,
    text        text        NOT NULL,
    char_confidence numeric(4,3) NOT NULL CHECK (char_confidence BETWEEN 0 AND 1),
    handwriting boolean     NOT NULL DEFAULT false,
    low_confidence boolean  NOT NULL DEFAULT false,
    bbox_json   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT ocr_region_unique UNIQUE (ocr_page_id, ordinal)
);

COMMENT ON TABLE memory.ocr_region IS
  'The IF-76 result shape GenbaGo (14) defines, stored rather than re-invented: vertical Japanese and Thai regions, per-region character confidence, handwriting always low confidence (FR-02, trg_ocr_flag).';

CREATE TABLE memory.near_duplicate (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    document_id  uuid        NOT NULL REFERENCES knowledge.document(id) ON DELETE CASCADE,
    other_id     uuid        NOT NULL REFERENCES knowledge.document(id) ON DELETE CASCADE,
    score        numeric(4,3) NOT NULL CHECK (score BETWEEN 0 AND 1),
    resolution   text        NOT NULL DEFAULT 'pending'
                 CHECK (resolution IN ('pending','merged','distinct')),
    decided_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    decided_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT near_dup_pair CHECK (document_id <> other_id),
    CONSTRAINT near_dup_unique UNIQUE (document_id, other_id)
);

-- =====================================================================
-- 13. MEMORY — structuring: classification, extraction, entities
-- =====================================================================

CREATE TABLE memory.doc_class_rule (
    id       uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    class    memory.doc_class NOT NULL,
    keyword  text        NOT NULL,
    lang     core.language_code,
    weight   integer     NOT NULL DEFAULT 1 CHECK (weight > 0),
    CONSTRAINT class_rule_unique UNIQUE (class, keyword)
);

COMMENT ON TABLE memory.doc_class_rule IS
  'The deterministic half of FR-08. memory.classify_document() is a twin re-derived in Python (TEST-15 TC-005); the model only sees documents no rule matches.';

CREATE TABLE memory.extraction (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    document_id    uuid        REFERENCES knowledge.document(id) ON DELETE CASCADE,
    case_record_id uuid        REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    model          text        NOT NULL,
    prompt_version text        NOT NULL,
    schema_version text        NOT NULL,
    temperature    numeric(3,2) NOT NULL DEFAULT 0.10 CHECK (temperature >= 0 AND temperature <= 0.30),
    ts             timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE memory.extraction IS
  'NFR-08: an extraction is reproducible or it is not an extraction. trg_field_provenance refuses a machine-written field whose extraction row is missing.';

CREATE TABLE memory.case_field (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_record_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    field          memory.field_name NOT NULL,
    value          text,
    confidence     numeric(4,3) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    provenance_json jsonb      NOT NULL DEFAULT '{}'::jsonb,
    extraction_id  uuid        REFERENCES memory.extraction(id) ON DELETE SET NULL,
    human          boolean     NOT NULL DEFAULT false,
    flagged        boolean     NOT NULL DEFAULT false,
    flagged_by     uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    flagged_reason text,
    corrected_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    corrected_at   timestamptz,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT case_field_unique UNIQUE (case_record_id, field),
    CONSTRAINT field_flag_has_reason CHECK (flagged = false OR flagged_reason IS NOT NULL)
);

COMMENT ON COLUMN memory.case_field.provenance_json IS
  'At least {document_id, page}; section and char offsets when the extractor has them. A machine-written field without provenance cannot exist (C-01, FR-13).';
COMMENT ON COLUMN memory.case_field.flagged IS
  'A flagged field is suppressed everywhere it would be rendered until a curator resolves it (FR-30, AC-06). It is not deleted: the wrong value is evidence about the extractor.';

CREATE TABLE memory.case_entity (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_record_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    kind           memory.entity_kind NOT NULL,
    raw_value      text        NOT NULL,
    canonical_id   text,
    mapped         boolean     NOT NULL DEFAULT false,
    confidence     numeric(4,3) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    CONSTRAINT case_entity_unique UNIQUE (case_record_id, kind, raw_value),
    CONSTRAINT mapped_has_canonical CHECK (mapped = false OR canonical_id IS NOT NULL)
);

CREATE TABLE memory.entity_map (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind         memory.entity_kind NOT NULL,
    raw_value    text        NOT NULL,
    canonical_id text        NOT NULL,
    approved_by  uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    approved_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT entity_map_unique UNIQUE (kind, raw_value)
);

COMMENT ON TABLE memory.entity_map IS
  'M07, M-07, เครื่อง M07 and 7号機 are one machine. Unmapped values are not guessed: they open a curation item (FR-10, IF-80).';

CREATE TABLE memory.symptom_descriptor (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_record_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    defect_class   text,
    failure_mode   text,
    alarm_code     text,
    deviation_json jsonb       NOT NULL DEFAULT '{}'::jsonb,
    confidence     numeric(4,3) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    CONSTRAINT descriptor_not_empty CHECK (
        defect_class IS NOT NULL OR failure_mode IS NOT NULL OR
        alarm_code IS NOT NULL OR deviation_json <> '{}'::jsonb
    )
);

COMMENT ON COLUMN memory.symptom_descriptor.deviation_json IS
  'Measured deviation as {parameter, value, unit, nominal, delta}. Numbers are copied from the document, never inferred (FR-11).';

CREATE TABLE memory.recurrence (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_record_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    prior_case_id  uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    score          numeric(4,3) NOT NULL CHECK (score BETWEEN 0 AND 1),
    interval_months integer    NOT NULL CHECK (interval_months >= 0),
    detected_at    timestamptz NOT NULL DEFAULT now(),
    confirmed_by   uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    confirmed_at   timestamptz,
    rejected       boolean     NOT NULL DEFAULT false,
    CONSTRAINT recurrence_pair CHECK (case_record_id <> prior_case_id),
    CONSTRAINT recurrence_unique UNIQUE (case_record_id, prior_case_id)
);

COMMENT ON TABLE memory.recurrence IS
  'A detection, not a fact. The threshold favours recall (AI-06), so nothing counts in analytics until confirmed_at is set by a person (trg_recurrence_confirm, ADR-H07).';

-- =====================================================================
-- 14. MEMORY — retrieval: index statistics, weights, queries, feedback
-- =====================================================================

CREATE TABLE memory.corpus_stat (
    scope      text PRIMARY KEY,
    n_docs     integer     NOT NULL CHECK (n_docs > 0),
    avg_len    numeric(8,3) NOT NULL CHECK (avg_len > 0),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memory.term_stat (
    scope text    NOT NULL REFERENCES memory.corpus_stat(scope) ON DELETE CASCADE,
    term  text    NOT NULL,
    df    integer NOT NULL CHECK (df > 0),
    PRIMARY KEY (scope, term)
);

COMMENT ON TABLE memory.term_stat IS
  'Document frequencies for the lexical leg. BM25 needs df and avgdl; keeping them as rows makes memory.bm25_score() a pure function of stored data, which is what lets TEST-15 TC-005 re-derive every score in Python (ADR-H04).';

CREATE TABLE memory.case_index (
    case_record_id uuid PRIMARY KEY REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    scope          text        NOT NULL REFERENCES memory.corpus_stat(scope) ON DELETE CASCADE,
    lang           core.language_code NOT NULL,
    indexed_text   text        NOT NULL,
    tokens         text[]      NOT NULL,
    token_count    integer     NOT NULL CHECK (token_count > 0),
    embedding_version text,
    acl_json       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN memory.case_index.tokens IS
  'memory.tokenize() output: words for Latin script, character bigrams for Thai and Japanese, plus any Latin or numeric token found inside them — which is how a Thai query containing "overload" and "M-07" still matches a Japanese report (AC-03).';

CREATE TABLE memory.rank_weight (
    key        text PRIMARY KEY,
    weight     numeric(4,3) NOT NULL CHECK (weight >= 0 AND weight <= 1),
    note       text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE memory.rank_weight IS
  'FR-18 as five numbers: similarity, entity overlap, recency, outcome quality and the verified boost. They sum to 1.000 (trg_rank_weight_sum) so a final score is always comparable across queries.';

CREATE TABLE memory.query_log (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ts          timestamptz NOT NULL DEFAULT now(),
    user_id     uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    user_role   memory.app_role NOT NULL DEFAULT 'viewer',
    query       text        NOT NULL,
    query_lang  core.language_code NOT NULL,
    scope_json  jsonb       NOT NULL DEFAULT '{}'::jsonb,
    require_json jsonb      NOT NULL DEFAULT '{}'::jsonb,
    verified_only boolean   NOT NULL DEFAULT true,
    top_k       integer     NOT NULL DEFAULT 5 CHECK (top_k BETWEEN 1 AND 50),
    n_candidates integer,
    n_results   integer,
    n_acl_filtered integer  NOT NULL DEFAULT 0,
    latency_ms  integer,
    origin      text        NOT NULL DEFAULT 'web'
                CHECK (origin IN ('web','api','tool','suggestion','discord','eval'))
);

COMMENT ON COLUMN memory.query_log.n_acl_filtered IS
  'How many rows the ACL predicate removed — a count, never the rows. SEC-H07: the log must not become the leak the predicate prevents.';
COMMENT ON COLUMN memory.query_log.scope_json IS
  'scope narrows the ranking (entity overlap); require_json removes rows outright. Appendix A uses scope, which is why a case on another machine can still appear — that is FR-22, horizontal deployment.';

CREATE TABLE memory.query_candidate (
    query_id       uuid        NOT NULL REFERENCES memory.query_log(id) ON DELETE CASCADE,
    case_record_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    vec_rank       integer     CHECK (vec_rank IS NULL OR vec_rank > 0),
    vec_score      numeric(5,4) CHECK (vec_score IS NULL OR vec_score BETWEEN 0 AND 1),
    rerank_sim     numeric(5,4) CHECK (rerank_sim IS NULL OR rerank_sim BETWEEN 0 AND 1),
    embedding_version text,
    PRIMARY KEY (query_id, case_record_id)
);

COMMENT ON TABLE memory.query_candidate IS
  'What the retriever brings in from outside SQL: the ANN rank and the cross-encoder similarity. Everything after this point — BM25, RRF, the cut to 30, the final score and why_matched — is computed by memory.rank_query() and re-derived in Python. The embedding itself is not computable here and the seed says so (README known gaps).';

CREATE TABLE memory.query_result (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    query_id       uuid        NOT NULL REFERENCES memory.query_log(id) ON DELETE CASCADE,
    case_record_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    rank           integer     NOT NULL CHECK (rank > 0),
    lex_rank       integer,
    lex_score      numeric(8,4),
    vec_rank       integer,
    rrf_score      numeric(8,6),
    rerank_sim     numeric(5,4),
    entity_overlap numeric(4,3),
    recency_weight numeric(4,3),
    outcome_weight numeric(4,3),
    verified       boolean     NOT NULL DEFAULT false,
    final_score    numeric(4,3) NOT NULL CHECK (final_score BETWEEN 0 AND 1),
    why_json       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT query_result_unique UNIQUE (query_id, case_record_id),
    CONSTRAINT query_rank_unique   UNIQUE (query_id, rank)
);

COMMENT ON COLUMN memory.query_result.why_json IS
  'FR-19: why it matched — matched terms, entity hits, the badge and the component scores. A ranking a user cannot interrogate cannot be trusted or debugged.';

CREATE TABLE memory.feedback (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    query_id     uuid        REFERENCES memory.query_log(id) ON DELETE SET NULL,
    result_id    uuid        REFERENCES memory.query_result(id) ON DELETE SET NULL,
    case_record_id uuid      NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    user_id      uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    rating       memory.rating NOT NULL,
    field        memory.field_name,
    reason       text,
    ts           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT incorrect_names_field CHECK (rating <> 'incorrect' OR field IS NOT NULL)
);

COMMENT ON TABLE memory.feedback IS
  'Append-only, and deliberately not a ranking weight (ADR-H08): it feeds evaluation runs and the curation queue. A case is never demoted because it was inconvenient.';

CREATE TABLE memory.suggestion (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    trigger_kind   text        NOT NULL CHECK (trigger_kind IN ('quality_case','alert','manual')),
    quality_case_id uuid       REFERENCES quality.case(id) ON DELETE CASCADE,
    trigger_ref    text,
    query_id       uuid        REFERENCES memory.query_log(id) ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    latency_ms     integer,
    delivered      boolean     NOT NULL DEFAULT false,
    opened_by      uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    opened_at      timestamptz
);

COMMENT ON TABLE memory.suggestion IS
  'FR-20: precedent is pushed when a case opens rather than waiting for someone to search. opened_at is the adoption metric that risk "low adoption" is measured by.';

-- =====================================================================
-- 15. MEMORY — curation, evaluation, embeddings
-- =====================================================================

CREATE TABLE memory.curation_item (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind           memory.curation_kind NOT NULL,
    state          memory.curation_state NOT NULL DEFAULT 'open',
    case_record_id uuid        REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    case_field_id  uuid        REFERENCES memory.case_field(id) ON DELETE CASCADE,
    case_entity_id uuid        REFERENCES memory.case_entity(id) ON DELETE CASCADE,
    document_id    uuid        REFERENCES knowledge.document(id) ON DELETE CASCADE,
    chunk_id       uuid        REFERENCES knowledge.chunk(id) ON DELETE CASCADE,
    near_duplicate_id uuid     REFERENCES memory.near_duplicate(id) ON DELETE CASCADE,
    detail         text        NOT NULL,
    opened_at      timestamptz NOT NULL DEFAULT now(),
    decided_by     uuid        REFERENCES core.app_user(id) ON DELETE SET NULL,
    decided_at     timestamptz,
    decision       text        CHECK (decision IS NULL OR decision IN
                   ('verified','corrected','mapped','merged','distinct','suppressed','dismissed')),
    CONSTRAINT curation_decided_together CHECK (
        (decided_by IS NULL AND decided_at IS NULL AND decision IS NULL) OR
        (decided_by IS NOT NULL AND decided_at IS NOT NULL AND decision IS NOT NULL)
    )
);

COMMENT ON TABLE memory.curation_item IS
  'The only path into "established fact" (ADR-H10). Its age is an operational metric: a queue nobody works is the same failure as a document nobody can find.';

CREATE TABLE memory.verification (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_record_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    verified_by    uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE RESTRICT,
    verified_at    timestamptz NOT NULL DEFAULT now(),
    scope          text        NOT NULL DEFAULT 'case' CHECK (scope IN ('case','field')),
    field          memory.field_name,
    note           text,
    revoked        boolean     NOT NULL DEFAULT false,
    revoked_reason text
);

COMMENT ON TABLE memory.verification IS
  'Append-only: a verification is never edited or deleted, only superseded by a revoking row. knowledge.case_record.verified_at is the denormalised answer; this is the history behind it.';

CREATE TABLE memory.merge_event (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kept_case_id uuid        NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    merged_case_id uuid      NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    reason       text        NOT NULL,
    decided_by   uuid        NOT NULL REFERENCES core.app_user(id) ON DELETE RESTRICT,
    decided_at   timestamptz NOT NULL DEFAULT now(),
    sources_moved integer    NOT NULL DEFAULT 0,
    CONSTRAINT merge_pair CHECK (kept_case_id <> merged_case_id)
);

COMMENT ON TABLE memory.merge_event IS
  'A merge moves sources and never deletes a document: provenance survives the merge, and the event is append-only so it can be read back or reversed (THR-H06).';

CREATE TABLE memory.label_set (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code       text        NOT NULL UNIQUE,
    version    integer     NOT NULL DEFAULT 1,
    n_documents integer    NOT NULL CHECK (n_documents > 0),
    note       text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memory.label_field (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    label_set_id uuid        NOT NULL REFERENCES memory.label_set(id) ON DELETE CASCADE,
    document_id  uuid        NOT NULL REFERENCES knowledge.document(id) ON DELETE CASCADE,
    field        memory.field_name NOT NULL,
    truth        text        NOT NULL,
    CONSTRAINT label_field_unique UNIQUE (label_set_id, document_id, field)
);

CREATE TABLE memory.eval_set (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code       text        NOT NULL UNIQUE,
    version    integer     NOT NULL DEFAULT 1,
    n_queries  integer     NOT NULL CHECK (n_queries > 0),
    note       text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memory.eval_query (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    eval_set_id uuid        NOT NULL REFERENCES memory.eval_set(id) ON DELETE CASCADE,
    ordinal     integer     NOT NULL,
    query       text        NOT NULL,
    query_lang  core.language_code NOT NULL,
    scope_json  jsonb       NOT NULL DEFAULT '{}'::jsonb,
    note        text,
    CONSTRAINT eval_query_unique UNIQUE (eval_set_id, ordinal)
);

CREATE TABLE memory.eval_qrel (
    eval_query_id  uuid    NOT NULL REFERENCES memory.eval_query(id) ON DELETE CASCADE,
    case_record_id uuid    NOT NULL REFERENCES knowledge.case_record(id) ON DELETE CASCADE,
    relevance      integer NOT NULL CHECK (relevance IN (1, 2)),
    PRIMARY KEY (eval_query_id, case_record_id)
);

COMMENT ON TABLE memory.eval_qrel IS
  'Known-relevant cases per query (AI-04). relevance 2 = the case the asker was looking for, 1 = also relevant. Recall@5 counts any qrel; MRR uses the first hit.';

CREATE TABLE memory.eval_run (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind           memory.eval_kind NOT NULL,
    eval_set_id    uuid        REFERENCES memory.eval_set(id) ON DELETE SET NULL,
    label_set_id   uuid        REFERENCES memory.label_set(id) ON DELETE SET NULL,
    ts             timestamptz NOT NULL DEFAULT now(),
    model          text        NOT NULL,
    embedding_version text,
    prompt_version text,
    recall_at_5    numeric(4,3) CHECK (recall_at_5 IS NULL OR recall_at_5 BETWEEN 0 AND 1),
    mrr            numeric(4,3) CHECK (mrr IS NULL OR mrr BETWEEN 0 AND 1),
    narrative_accuracy numeric(4,3) CHECK (narrative_accuracy IS NULL OR narrative_accuracy BETWEEN 0 AND 1),
    factual_accuracy   numeric(4,3) CHECK (factual_accuracy IS NULL OR factual_accuracy BETWEEN 0 AND 1),
    passed         boolean,
    investigate    boolean     NOT NULL DEFAULT false,
    note           text,
    CONSTRAINT eval_kind_has_set CHECK (
        (kind = 'retrieval'  AND eval_set_id  IS NOT NULL) OR
        (kind = 'extraction' AND label_set_id IS NOT NULL)
    )
);

COMMENT ON COLUMN memory.eval_run.passed IS
  'Computed by trg_eval_gate, not asserted: retrieval needs Recall@5 >= 0.80 and MRR >= 0.60 (AI-04); extraction needs >= 0.85 narrative and >= 0.95 factual (AI-02).';

CREATE TABLE memory.eval_result (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    eval_run_id   uuid        NOT NULL REFERENCES memory.eval_run(id) ON DELETE CASCADE,
    eval_query_id uuid        REFERENCES memory.eval_query(id) ON DELETE CASCADE,
    document_id   uuid        REFERENCES knowledge.document(id) ON DELETE CASCADE,
    field         memory.field_name,
    hit_rank      integer,
    correct       boolean,
    detail_json   jsonb       NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE memory.embedding_model (
    version    text PRIMARY KEY,
    model      text        NOT NULL,
    dim        integer     NOT NULL CHECK (dim = 1024),
    state      memory.embedding_state NOT NULL DEFAULT 'registering',
    registered_at timestamptz NOT NULL DEFAULT now(),
    activated_at  timestamptz,
    retired_at    timestamptz
);

COMMENT ON TABLE memory.embedding_model IS
  'ADR-H09. dim is fixed at 1024 because knowledge.chunk.embedding is vector(1024) on the platform; a different dimension is a platform change, not a configuration.';

CREATE TABLE memory.reembed_job (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    from_version  text        REFERENCES memory.embedding_model(version) ON DELETE SET NULL,
    to_version    text        NOT NULL REFERENCES memory.embedding_model(version) ON DELETE CASCADE,
    state         memory.job_state NOT NULL DEFAULT 'queued',
    total_chunks  integer     NOT NULL CHECK (total_chunks >= 0),
    done_chunks   integer     NOT NULL DEFAULT 0 CHECK (done_chunks >= 0),
    started_at    timestamptz,
    finished_at   timestamptz,
    search_available boolean  NOT NULL DEFAULT true,
    CONSTRAINT reembed_progress CHECK (done_chunks <= total_chunks),
    CONSTRAINT reembed_versions_differ CHECK (from_version IS NULL OR from_version <> to_version)
);

COMMENT ON COLUMN memory.reembed_job.search_available IS
  'AC-09 is a column: the job asserts that queries keep running against the active version throughout, and trg_embedding_version refuses to retire a version while a job still needs it.';

CREATE TABLE memory.migration (
    id         text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now(),
    note       text
);

-- =====================================================================
-- 16. MEMORY — functions
--     Deterministic twins of the logic that decides what a user sees.
--     TEST-15 TC-005 re-derives every one of them in Python over the seed.
--     What is NOT here, because SQL cannot compute it: the embedding and
--     the cross-encoder similarity. Both enter as data on
--     memory.query_candidate, and the README states the gap.
-- =====================================================================

-- --- text ------------------------------------------------------------

CREATE OR REPLACE FUNCTION memory.normalise_text(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(
             regexp_replace(lower(coalesce(p_text, '')),
                            E'[^0-9a-z฀-๿぀-ゟ゠-ヿ一-鿿/-]',
                            ' ', 'g'),
             '\s+', ' ', 'g'));
$$;

COMMENT ON FUNCTION memory.normalise_text(text) IS
  'Lower-case, keep digits, Latin letters, Thai, kana, CJK, hyphen and slash, collapse the rest to single spaces. Hyphen and slash survive because M-07, RAD-500-A and 8D/RCA are the tokens that matter most.';

CREATE OR REPLACE FUNCTION memory.content_hash(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT encode(digest(memory.normalise_text(p_text), 'sha256'), 'hex');
$$;

CREATE OR REPLACE FUNCTION memory.detect_lang(p_text text)
RETURNS core.language_code
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    n_th integer;
    n_ja integer;
    n_en integer;
BEGIN
    n_th := coalesce(array_length(ARRAY(SELECT regexp_matches(p_text, E'[฀-๿]', 'g')), 1), 0);
    n_ja := coalesce(array_length(ARRAY(SELECT regexp_matches(p_text, E'[぀-ゟ゠-ヿ一-鿿]', 'g')), 1), 0);
    n_en := coalesce(array_length(ARRAY(SELECT regexp_matches(lower(p_text), '[a-z]', 'g')), 1), 0);

    -- A little Japanese in a Thai sentence does not make it Japanese, but a
    -- Japanese document quoting English part numbers is still Japanese: the
    -- CJK and Thai scripts outrank Latin at equal counts (FR-03).
    IF n_ja >= n_th AND n_ja >= n_en AND n_ja > 0 THEN RETURN 'ja'; END IF;
    IF n_th >= n_ja AND n_th >= n_en AND n_th > 0 THEN RETURN 'th'; END IF;
    RETURN 'en';
END;
$$;

CREATE OR REPLACE FUNCTION memory.tokenize(p_text text, p_lang core.language_code)
RETURNS text[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    n      text;
    tok    text[];
    runs   text[];
    run    text;
    i      integer;
BEGIN
    n   := memory.normalise_text(p_text);
    tok := ARRAY(SELECT m[1]
                 FROM regexp_matches(n, '[0-9a-z][0-9a-z/-]*', 'g') AS m
                 WHERE length(m[1]) >= 2);

    IF p_lang = 'en' THEN
        RETURN tok;
    END IF;

    -- Thai and Japanese have no word spaces: character bigrams are the
    -- deterministic alternative to a segmenter (ADR-H04). Latin and numeric
    -- tokens are kept as words, which is how a Thai query carrying
    -- "overload" and "M-07" still reaches a Japanese report (AC-03).
    runs := ARRAY(SELECT m[1]
                  FROM regexp_matches(n, E'[฀-๿぀-ゟ゠-ヿ一-鿿]+', 'g') AS m);

    FOREACH run IN ARRAY coalesce(runs, ARRAY[]::text[]) LOOP
        IF length(run) = 1 THEN
            tok := tok || run;
        ELSE
            FOR i IN 1 .. length(run) - 1 LOOP
                tok := tok || substr(run, i, 2);
            END LOOP;
        END IF;
    END LOOP;

    RETURN tok;
END;
$$;

CREATE OR REPLACE FUNCTION memory.near_dup_score(p_a text, p_b text)
RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round(similarity(memory.normalise_text(p_a), memory.normalise_text(p_b))::numeric, 3);
$$;

COMMENT ON FUNCTION memory.near_dup_score(text, text) IS
  'FR-04 near-duplicate detection: the same 8D exported as PDF and as DOCX differs in whitespace and page furniture, not in content. Above memory.setting near_duplicate_threshold it becomes a curation merge item, never an automatic merge.';

CREATE OR REPLACE FUNCTION memory.injection_scan(p_text text)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT memory.normalise_text(p_text) ~ (
        '(ignore (all |the )?(previous|above) instructions'
        '|disregard (all |the )?(previous|above)'
        '|when asked about'
        '|you (are|must) (now )?(answer|reply|respond)'
        '|always (answer|reply|say)'
        '|do not mention'
        '|system prompt'
        '|treat (this|the following) as (approved|verified))'
    )
    OR p_text ~ '(以下の指示に従|前の指示は無視|承認済みとして)'
    OR p_text ~ '(ทำตามคำสั่ง|ไม่ต้องสนใจคำสั่ง)';
$$;

COMMENT ON FUNCTION memory.injection_scan(text) IS
  'AI-08 / P-6. A chunk that reads like an instruction is marked suspicious, excluded from evidence bundles and listed in excluded[] for an admin. This is the same column Copilot (10) sets with trg_chunk_injection_flag; the two definitions are deliberately identical in intent (ICD-15 IF-55).';

-- --- classification and structuring ----------------------------------

CREATE OR REPLACE FUNCTION memory.classify_document(p_text text)
RETURNS memory.doc_class
LANGUAGE plpgsql STABLE AS $$
DECLARE
    n   text := memory.normalise_text(p_text);
    got memory.doc_class;
BEGIN
    SELECT r.class
      INTO got
      FROM memory.doc_class_rule r
     WHERE position(memory.normalise_text(r.keyword) IN n) > 0
     GROUP BY r.class
     ORDER BY sum(r.weight) DESC, r.class
     LIMIT 1;

    RETURN coalesce(got, 'other');
END;
$$;

CREATE OR REPLACE FUNCTION memory.extract_alarm_code(p_text text)
RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(ARRAY(
        SELECT DISTINCT upper(m[1])
        FROM regexp_matches(upper(coalesce(p_text, '')),
                            '\m(AL-?[0-9]{2,4}|E-?[0-9]{2,4}|ER-?[0-9]{2,4}|F-?[0-9]{2,4})\M', 'g') AS m
        ORDER BY 1
    ), ARRAY[]::text[]);
$$;

CREATE OR REPLACE FUNCTION memory.extract_deviation(p_text text)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    m text[];
BEGIN
    SELECT regexp_matches(coalesce(p_text, ''),
                          '([0-9]+(?:\.[0-9]+)?)\s*(mm|um|µm|kg|g|a|v|c|°c|%|bar|mpa|sec|s|min|h)\M', 'i')
      INTO m;

    IF m IS NULL THEN
        RETURN '{}'::jsonb;
    END IF;

    RETURN jsonb_build_object('value', (m[1])::numeric, 'unit', lower(m[2]));
END;
$$;

COMMENT ON FUNCTION memory.extract_deviation(text) IS
  'FR-11. The number and unit are copied out of the text, never computed and never rounded: a measurement in a case record has to match the document a reader will open next (C-01).';

CREATE OR REPLACE FUNCTION memory.defect_classes(p_text text)
RETURNS text[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    n   text := memory.normalise_text(p_text);
    out text[] := ARRAY[]::text[];
BEGIN
    -- The order is the order of this list, so two callers always produce the
    -- same descriptor array for the same sentence (TEST-15 TC-005).
    IF n ~ '(overload|過負荷|โอเวอร์โหลด)'          THEN out := out || 'overload'; END IF;
    IF n ~ '(not rotating|no rotation|回転しない|ไม่หมุน)' THEN out := out || 'no_rotation'; END IF;
    IF n ~ '(misalign|芯ずれ|ไม่ตรงแนว)'                 THEN out := out || 'misalignment'; END IF;
    IF n ~ '(short shot|ショート|ฉีดไม่เต็ม)'  THEN out := out || 'short_shot'; END IF;
    IF n ~ '(flash|バリ|ครีบ)'                                   THEN out := out || 'flash'; END IF;
    IF n ~ '(scratch|キズ|傷|รอยขีด)'            THEN out := out || 'scratch'; END IF;
    IF n ~ '(dimension|tolerance|寸法|ขนาด)'                      THEN out := out || 'dimension'; END IF;
    IF n ~ '(contamina|specks|異物|สิ่งปนเปื้อน)' THEN out := out || 'contamination'; END IF;
    IF n ~ '(hydraulic pressure|油圧|แรงดันไฮดรอลิค)' THEN out := out || 'hydraulic_pressure'; END IF;
    RETURN out;
END;
$$;

COMMENT ON FUNCTION memory.defect_classes(text) IS
  'FR-11 / FR-18. A sentence can name more than one thing that went wrong — "overload, motor not rotating" names two — and both belong in the descriptor set the ranking compares against (memory.entity_overlap).';

CREATE OR REPLACE FUNCTION memory.defect_class_of(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT (memory.defect_classes(p_text))[1];
$$;

CREATE OR REPLACE FUNCTION memory.normalise_entity(p_kind memory.entity_kind, p_raw text)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    canon text;
    raw_n text := upper(btrim(coalesce(p_raw, '')));
BEGIN
    SELECT em.canonical_id INTO canon
      FROM memory.entity_map em
     WHERE em.kind = p_kind
       AND upper(em.raw_value) = raw_n
       AND em.approved_at IS NOT NULL;

    IF canon IS NOT NULL THEN
        RETURN canon;
    END IF;

    -- A value that is already a canonical code of the platform maps to itself.
    IF p_kind = 'machine' AND EXISTS (SELECT 1 FROM core.machine WHERE machine_code = raw_n) THEN
        RETURN raw_n;
    END IF;
    IF p_kind = 'line' AND EXISTS (SELECT 1 FROM core.line WHERE code = raw_n) THEN
        RETURN raw_n;
    END IF;
    IF p_kind = 'sku' AND EXISTS (SELECT 1 FROM core.sku WHERE sku_code = raw_n) THEN
        RETURN raw_n;
    END IF;

    RETURN NULL;   -- unmapped: trg_entity_mapped opens a curation item (FR-10)
END;
$$;

-- --- access control ---------------------------------------------------

CREATE OR REPLACE FUNCTION memory.role_rank(p_role text)
RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE lower(coalesce(p_role, 'viewer'))
             WHEN 'viewer'    THEN 1
             WHEN 'inspector' THEN 2
             WHEN 'engineer'  THEN 3
             WHEN 'curator'   THEN 4
             WHEN 'manager'   THEN 4
             WHEN 'admin'     THEN 5
             ELSE 1
           END;
$$;

COMMENT ON FUNCTION memory.role_rank(text) IS
  'One ladder for the platform roles used in knowledge.document.acl_json.min_role and the memory roles. manager and curator sit at the same height: both may read restricted records, neither outranks admin.';

CREATE OR REPLACE FUNCTION memory.acl_visible(p_acl jsonb, p_role text, p_groups text[])
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT
        memory.role_rank(p_role) >= memory.role_rank(coalesce(p_acl ->> 'min_role', 'viewer'))
    AND (
            p_acl -> 'groups' IS NULL
         OR jsonb_array_length(p_acl -> 'groups') = 0
         OR EXISTS (SELECT 1
                      FROM jsonb_array_elements_text(p_acl -> 'groups') g
                     WHERE g IN (SELECT unnest(coalesce(p_groups, ARRAY[]::text[]))))
        )
    AND coalesce(p_acl ->> 'embargoed', 'false') <> 'true';
$$;

COMMENT ON FUNCTION memory.acl_visible(jsonb, text, text[]) IS
  'P-4, C-05, NFR-05. Called inside the retrieval CTEs, never after ranking: there is no post-filter to forget, to bypass with a debug flag, or to leak a count through (AC-05).';

CREATE OR REPLACE FUNCTION memory.case_acl(p_case uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    strictest jsonb := '{}'::jsonb;
    d         record;
BEGIN
    -- The strictest ACL of the sources wins: a case that quotes a restricted
    -- document is restricted (trg_acl_inherit).
    FOR d IN
        SELECT doc.acl_json
          FROM knowledge.case_source cs
          JOIN knowledge.document doc ON doc.id = cs.document_id
         WHERE cs.case_record_id = p_case
    LOOP
        IF memory.role_rank(d.acl_json ->> 'min_role')
           > memory.role_rank(strictest ->> 'min_role') THEN
            strictest := jsonb_set(strictest, '{min_role}',
                                   to_jsonb(coalesce(d.acl_json ->> 'min_role', 'viewer')), true);
        END IF;
        IF d.acl_json -> 'groups' IS NOT NULL
           AND jsonb_array_length(d.acl_json -> 'groups') > 0 THEN
            strictest := jsonb_set(strictest, '{groups}', d.acl_json -> 'groups', true);
        END IF;
    END LOOP;

    RETURN strictest;
END;
$$;

-- --- ranking ----------------------------------------------------------

CREATE OR REPLACE FUNCTION memory.bm25_score(p_query text[], p_doc text[], p_scope text)
RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE
    k1      constant numeric := 1.2;
    b       constant numeric := 0.75;
    n_docs  integer;
    avg_len numeric;
    dl      integer;
    term    text;
    f       integer;
    df      integer;
    idf     numeric;
    score   numeric := 0;
BEGIN
    SELECT cs.n_docs, cs.avg_len INTO n_docs, avg_len
      FROM memory.corpus_stat cs WHERE cs.scope = p_scope;

    IF n_docs IS NULL OR p_doc IS NULL OR array_length(p_doc, 1) IS NULL THEN
        RETURN 0;
    END IF;

    dl := array_length(p_doc, 1);

    FOR term IN SELECT DISTINCT unnest(p_query) LOOP
        SELECT count(*) INTO f FROM unnest(p_doc) t WHERE t = term;
        CONTINUE WHEN f = 0;

        SELECT ts.df INTO df FROM memory.term_stat ts
         WHERE ts.scope = p_scope AND ts.term = term;
        df := coalesce(df, 1);

        idf   := ln(1 + (n_docs - df + 0.5) / (df + 0.5));
        score := score + idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avg_len));
    END LOOP;

    RETURN round(score, 4);
END;
$$;

COMMENT ON FUNCTION memory.bm25_score(text[], text[], text) IS
  'Okapi BM25, k1 = 1.2, b = 0.75, idf = ln(1 + (N - df + 0.5)/(df + 0.5)). The constants live in the function, not in configuration: changing them silently would change every stored score''s meaning (ADR-H04).';

CREATE OR REPLACE FUNCTION memory.rrf(p_lex_rank integer, p_vec_rank integer, p_k integer DEFAULT 60)
RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round(
             coalesce(1.0 / (p_k + p_lex_rank), 0)
           + coalesce(1.0 / (p_k + p_vec_rank), 0), 6);
$$;

COMMENT ON FUNCTION memory.rrf(integer, integer, integer) IS
  'Reciprocal rank fusion, k = 60. It decides which 30 candidates reach the reranker (ADR-H05); it deliberately does not decide the final order, because at k = 60 the fused scores of neighbouring ranks differ by less than a percent.';

CREATE OR REPLACE FUNCTION memory.entity_overlap(p_case uuid, p_scope jsonb, p_descriptors text[])
RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE
    considered integer := 0;
    matched    integer := 0;
    key        text;
    val        text;
    d          text;
BEGIN
    FOR key, val IN SELECT k, v FROM jsonb_each_text(coalesce(p_scope, '{}'::jsonb)) AS e(k, v) LOOP
        CONTINUE WHEN key NOT IN ('machine', 'line', 'sku', 'mould');
        considered := considered + 1;
        IF EXISTS (SELECT 1 FROM memory.case_entity ce
                    WHERE ce.case_record_id = p_case
                      AND ce.kind::text = key
                      AND ce.canonical_id = val) THEN
            matched := matched + 1;
        END IF;
    END LOOP;

    FOREACH d IN ARRAY coalesce(p_descriptors, ARRAY[]::text[]) LOOP
        considered := considered + 1;
        IF EXISTS (SELECT 1 FROM memory.symptom_descriptor sd
                    WHERE sd.case_record_id = p_case
                      AND (sd.defect_class = d OR sd.failure_mode = d OR sd.alarm_code = d)) THEN
            matched := matched + 1;
        END IF;
    END LOOP;

    IF considered = 0 THEN
        RETURN 0;
    END IF;

    RETURN round(matched::numeric / considered, 3);
END;
$$;

COMMENT ON FUNCTION memory.entity_overlap(uuid, jsonb, text[]) IS
  'Scope entities and the descriptors read out of the query, counted together. This is what lets a case on another machine still surface when the failure mode matches — FR-22, horizontal deployment — while the same-machine case outranks it.';

CREATE OR REPLACE FUNCTION memory.recency_weight(p_ts timestamptz, p_ref timestamptz)
RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE
    halflife numeric;
    age_days numeric;
BEGIN
    SELECT (value #>> '{}')::numeric INTO halflife
      FROM memory.setting WHERE key = 'recency_halflife_days';
    halflife := coalesce(halflife, 900);

    IF p_ts IS NULL THEN
        RETURN 0;
    END IF;

    age_days := greatest(0, extract(epoch FROM (p_ref - p_ts)) / 86400.0);
    RETURN round(power(0.5, age_days / halflife)::numeric, 3);
END;
$$;

COMMENT ON FUNCTION memory.recency_weight(timestamptz, timestamptz) IS
  'Exponential decay with a 900-day half-life: a fix from two years ago is still worth reading, which is the whole premise of the product. Recency carries only 0.05 of the final score for the same reason.';

CREATE OR REPLACE FUNCTION memory.outcome_weight(p_case uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE
    oc   text;
    reps integer;
BEGIN
    SELECT cr.outcome INTO oc FROM knowledge.case_record cr WHERE cr.id = p_case;

    SELECT count(*) INTO reps
      FROM memory.recurrence r
     WHERE r.prior_case_id = p_case
       AND r.confirmed_at IS NOT NULL
       AND r.rejected = false;

    IF oc = 'resolved' AND reps = 0 THEN RETURN 1.000; END IF;
    IF oc = 'resolved'              THEN RETURN 0.700; END IF;
    IF oc = 'not_resolved'          THEN RETURN 0.400; END IF;
    RETURN 0.200;
END;
$$;

COMMENT ON FUNCTION memory.outcome_weight(uuid) IS
  'FR-18: a fix that held outranks a fix that came back, and both outrank a case that was closed without knowing. A confirmed recurrence against a case is evidence about its action, so it lowers that case''s rank — this is how FR-24 feeds back into ranking.';

CREATE OR REPLACE FUNCTION memory.final_score(p_sim numeric, p_entity numeric, p_recency numeric,
                                              p_outcome numeric, p_verified boolean)
RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE
    w_sim numeric; w_ent numeric; w_rec numeric; w_out numeric; w_ver numeric;
BEGIN
    SELECT weight INTO w_sim FROM memory.rank_weight WHERE key = 'similarity';
    SELECT weight INTO w_ent FROM memory.rank_weight WHERE key = 'entity_overlap';
    SELECT weight INTO w_rec FROM memory.rank_weight WHERE key = 'recency';
    SELECT weight INTO w_out FROM memory.rank_weight WHERE key = 'outcome';
    SELECT weight INTO w_ver FROM memory.rank_weight WHERE key = 'verified';

    RETURN round(
        w_sim * coalesce(p_sim, 0)
      + w_ent * coalesce(p_entity, 0)
      + w_rec * coalesce(p_recency, 0)
      + w_out * coalesce(p_outcome, 0)
      + w_ver * CASE WHEN p_verified THEN 1 ELSE 0 END, 3);
END;
$$;

CREATE OR REPLACE FUNCTION memory.why_matched(p_query_tokens text[], p_case uuid,
                                              p_scope jsonb, p_descriptors text[],
                                              p_components jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    terms   text[];
    ents    text[];
    is_ver  boolean;
BEGIN
    SELECT ARRAY(
        SELECT DISTINCT t
          FROM unnest(p_query_tokens) t
         WHERE t = ANY (SELECT unnest(ci.tokens) FROM memory.case_index ci
                         WHERE ci.case_record_id = p_case)
           AND length(t) >= 2
         ORDER BY t
         LIMIT 8
    ) INTO terms;

    SELECT ARRAY(
        SELECT ce.kind::text || ':' || ce.canonical_id
          FROM memory.case_entity ce
         WHERE ce.case_record_id = p_case
           AND ce.canonical_id IS NOT NULL
           AND ce.canonical_id = ANY (SELECT v FROM jsonb_each_text(coalesce(p_scope, '{}'::jsonb)) AS e(k, v))
         ORDER BY 1
    ) INTO ents;

    SELECT (cr.verified_at IS NOT NULL) INTO is_ver
      FROM knowledge.case_record cr WHERE cr.id = p_case;

    RETURN jsonb_build_object(
        'matched_terms',   to_jsonb(coalesce(terms, ARRAY[]::text[])),
        'matched_entities', to_jsonb(coalesce(ents, ARRAY[]::text[])),
        'matched_descriptors', to_jsonb(coalesce(p_descriptors, ARRAY[]::text[])),
        'badge', CASE WHEN is_ver THEN 'verified' ELSE 'extracted_not_verified' END,
        'components', p_components
    );
END;
$$;

COMMENT ON FUNCTION memory.why_matched(text[], uuid, jsonb, text[], jsonb) IS
  'FR-19. Every hit explains itself in the same structure the UI renders and the API returns, so "why did this come first" is answerable without reading code.';

CREATE OR REPLACE FUNCTION memory.rank_query(p_query_id uuid)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    q            record;
    q_tokens     text[];
    descriptors  text[];
    depth        integer;
    groups       text[];
    n_filtered   integer := 0;
    n_out        integer := 0;
    c            record;
    rk           integer := 0;
BEGIN
    SELECT * INTO q FROM memory.query_log WHERE id = p_query_id;
    IF NOT FOUND THEN RETURN 0; END IF;

    q_tokens := memory.tokenize(q.query, q.query_lang);

    descriptors := memory.defect_classes(q.query) || memory.extract_alarm_code(q.query);

    SELECT coalesce((value #>> '{}')::integer, 30) INTO depth
      FROM memory.setting WHERE key = 'rerank_depth';
    depth := coalesce(depth, 30);

    groups := ARRAY(SELECT ag.code FROM memory.group_member gm
                      JOIN memory.access_group ag ON ag.id = gm.group_id
                     WHERE gm.user_id = q.user_id);

    DELETE FROM memory.query_result WHERE query_id = p_query_id;

    FOR c IN
        WITH cand AS (
            SELECT qc.case_record_id,
                   qc.vec_rank,
                   qc.rerank_sim,
                   memory.bm25_score(q_tokens, ci.tokens, ci.scope) AS lex_score
              FROM memory.query_candidate qc
              JOIN memory.case_index ci ON ci.case_record_id = qc.case_record_id
             WHERE qc.query_id = p_query_id
        ),
        ranked AS (
            SELECT cand.*,
                   rank() OVER (ORDER BY lex_score DESC, case_record_id) AS lex_rank
              FROM cand
        ),
        fused AS (
            SELECT ranked.*,
                   memory.rrf(lex_rank::integer, vec_rank) AS rrf_score
              FROM ranked
             ORDER BY memory.rrf(lex_rank::integer, vec_rank) DESC
             LIMIT depth
        )
        SELECT f.*,
               cr.opened_at,
               (cr.verified_at IS NOT NULL) AS verified,
               memory.case_acl(f.case_record_id) AS acl
          FROM fused f
          JOIN knowledge.case_record cr ON cr.id = f.case_record_id
    LOOP
        IF NOT memory.acl_visible(c.acl, q.user_role::text, groups) THEN
            n_filtered := n_filtered + 1;
            CONTINUE;
        END IF;
        CONTINUE WHEN q.verified_only AND NOT c.verified;

        INSERT INTO memory.query_result (
            query_id, case_record_id, rank, lex_rank, lex_score, vec_rank,
            rrf_score, rerank_sim, entity_overlap, recency_weight, outcome_weight,
            verified, final_score, why_json)
        SELECT p_query_id, c.case_record_id, 0, c.lex_rank, c.lex_score, c.vec_rank,
               c.rrf_score, c.rerank_sim,
               memory.entity_overlap(c.case_record_id, q.scope_json, descriptors),
               memory.recency_weight(c.opened_at, q.ts),
               memory.outcome_weight(c.case_record_id),
               c.verified,
               memory.final_score(c.rerank_sim,
                                  memory.entity_overlap(c.case_record_id, q.scope_json, descriptors),
                                  memory.recency_weight(c.opened_at, q.ts),
                                  memory.outcome_weight(c.case_record_id),
                                  c.verified),
               '{}'::jsonb;
        n_out := n_out + 1;
    END LOOP;

    -- Order, cut to top_k, and write the explanation now that the
    -- components exist.
    FOR c IN
        SELECT id, case_record_id, rerank_sim, entity_overlap, recency_weight,
               outcome_weight, verified, final_score
          FROM memory.query_result
         WHERE query_id = p_query_id
         ORDER BY final_score DESC, case_record_id
         LIMIT q.top_k
    LOOP
        rk := rk + 1;
        UPDATE memory.query_result
           SET rank = rk,
               why_json = memory.why_matched(q_tokens, c.case_record_id, q.scope_json, descriptors,
                             jsonb_build_object('similarity', c.rerank_sim,
                                                'entity_overlap', c.entity_overlap,
                                                'recency', c.recency_weight,
                                                'outcome', c.outcome_weight,
                                                'verified', c.verified,
                                                'final', c.final_score))
         WHERE id = c.id;
    END LOOP;

    DELETE FROM memory.query_result WHERE query_id = p_query_id AND rank = 0;

    UPDATE memory.query_log
       SET n_candidates = (SELECT count(*) FROM memory.query_candidate WHERE query_id = p_query_id),
           n_results      = rk,
           n_acl_filtered = n_filtered
     WHERE id = p_query_id;

    RETURN rk;
END;
$$;

COMMENT ON FUNCTION memory.rank_query(uuid) IS
  'The whole ranking in one place: BM25, RRF, the cut to rerank_depth, the ACL predicate, the verified-only default, the final score and the explanation. TEST-15 TC-005 re-derives it row by row over the seeded queries.';

CREATE OR REPLACE FUNCTION memory.case_card(p_case uuid, p_role text, p_groups text[])
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    cr     record;
    fields jsonb;
    srcs   jsonb;
BEGIN
    SELECT * INTO cr FROM knowledge.case_record WHERE id = p_case;
    IF NOT FOUND THEN RETURN NULL; END IF;

    IF NOT memory.acl_visible(memory.case_acl(p_case), p_role, p_groups) THEN
        RETURN NULL;             -- not "restricted": absent (AC-05)
    END IF;

    SELECT coalesce(jsonb_object_agg(cf.field, jsonb_build_object(
               'value', cf.value,
               'confidence', cf.confidence,
               'human', cf.human,
               'provenance', cf.provenance_json)), '{}'::jsonb)
      INTO fields
      FROM memory.case_field cf
     WHERE cf.case_record_id = p_case
       AND cf.flagged = false;    -- suppressed until curated (FR-30, AC-06)

    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'document_id', d.id, 'original_name', d.original_name,
               'page_range', cs.page_range) ORDER BY d.original_name), '[]'::jsonb)
      INTO srcs
      FROM knowledge.case_source cs
      JOIN knowledge.document d ON d.id = cs.document_id
     WHERE cs.case_record_id = p_case;

    RETURN jsonb_build_object(
        'case_id', cr.id,
        'title', cr.title,
        'opened_at', cr.opened_at,
        'outcome', cr.outcome,
        'badge', CASE WHEN cr.verified_at IS NOT NULL THEN 'verified' ELSE 'extracted_not_verified' END,
        'fields', fields,
        'sources', srcs);
END;
$$;

-- --- recurrence and analytics ----------------------------------------

CREATE OR REPLACE FUNCTION memory.recurrence_check(p_case uuid)
RETURNS TABLE (prior_case_id uuid, score numeric, interval_months integer)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    threshold numeric;
BEGIN
    SELECT coalesce((value #>> '{}')::numeric, 0.72) INTO threshold
      FROM memory.setting WHERE key = 'recurrence_threshold';
    threshold := coalesce(threshold, 0.72);

    RETURN QUERY
    SELECT qr.case_record_id,
           qr.final_score,
           (extract(year  FROM age(cur.opened_at, prior.opened_at))::integer * 12
          + extract(month FROM age(cur.opened_at, prior.opened_at))::integer)
      FROM memory.suggestion s
      JOIN memory.query_result qr ON qr.query_id = s.query_id
      JOIN knowledge.case_record prior ON prior.id = qr.case_record_id
      JOIN knowledge.case_record cur   ON cur.id  = p_case
     WHERE s.quality_case_id IS NOT NULL
       AND cur.quality_case_id = s.quality_case_id
       AND qr.case_record_id <> p_case
       AND prior.closed_at IS NOT NULL
       AND qr.final_score >= threshold
     ORDER BY qr.final_score DESC;
END;
$$;

COMMENT ON FUNCTION memory.recurrence_check(uuid) IS
  'Recurrence reuses the ranking rather than inventing a second similarity, so the number in the alert is the number in the search result. The interval is whole months between the two cases'' opened_at — computed, never entered (AC-07).';

CREATE OR REPLACE FUNCTION memory.top_recurring(p_kind memory.entity_kind, p_from date, p_to date)
RETURNS TABLE (canonical_id text, n_cases bigint, n_recurrences bigint)
LANGUAGE sql STABLE AS $$
    SELECT ce.canonical_id,
           count(DISTINCT cr.id),
           count(DISTINCT r.id)
      FROM knowledge.case_record cr
      JOIN memory.case_entity ce ON ce.case_record_id = cr.id AND ce.kind = p_kind
      LEFT JOIN memory.recurrence r ON r.case_record_id = cr.id
                                   AND r.confirmed_at IS NOT NULL AND r.rejected = false
     WHERE ce.canonical_id IS NOT NULL
       AND cr.opened_at >= p_from AND cr.opened_at < (p_to + 1)
     GROUP BY ce.canonical_id
     ORDER BY count(DISTINCT r.id) DESC, count(DISTINCT cr.id) DESC, ce.canonical_id;
$$;

CREATE OR REPLACE FUNCTION memory.action_effectiveness(p_defect_class text)
RETURNS TABLE (action_text text, case_id uuid, recurred boolean)
LANGUAGE sql STABLE AS $$
    SELECT cr.action_text,
           cr.id,
           EXISTS (SELECT 1 FROM memory.recurrence r
                    WHERE r.prior_case_id = cr.id
                      AND r.confirmed_at IS NOT NULL AND r.rejected = false)
      FROM knowledge.case_record cr
      JOIN memory.symptom_descriptor sd ON sd.case_record_id = cr.id
     WHERE sd.defect_class = p_defect_class
       AND cr.action_text IS NOT NULL
     ORDER BY cr.opened_at;
$$;

COMMENT ON FUNCTION memory.action_effectiveness(text) IS
  'FR-24. "Which corrective actions were followed by recurrence" is a join, not an opinion: the answer is only as good as the confirmed recurrence links, which is why confirmation is mandatory (ADR-H07).';

CREATE OR REPLACE FUNCTION memory.mtbr(p_defect_class text)
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT round(avg(r.interval_months)::numeric, 1)
      FROM memory.recurrence r
      JOIN memory.symptom_descriptor sd ON sd.case_record_id = r.case_record_id
     WHERE sd.defect_class = p_defect_class
       AND r.confirmed_at IS NOT NULL
       AND r.rejected = false;
$$;

CREATE OR REPLACE FUNCTION memory.knowledge_gaps()
RETURNS TABLE (case_id uuid, title text, missing text)
LANGUAGE sql STABLE AS $$
    SELECT cr.id, cr.title,
           CASE WHEN cr.cause_text IS NULL AND cr.verification_text IS NULL THEN 'cause+verification'
                WHEN cr.cause_text IS NULL THEN 'cause'
                ELSE 'verification' END
      FROM knowledge.case_record cr
     WHERE cr.cause_text IS NULL OR cr.verification_text IS NULL
     ORDER BY cr.opened_at DESC;
$$;

COMMENT ON FUNCTION memory.knowledge_gaps() IS
  'FR-26. A case closed without a recorded cause is not a failure of the system, it is a fact about the plant''s records — and the only way it gets fixed is by being counted.';

CREATE OR REPLACE FUNCTION memory.coverage_metrics()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'cases',            count(*),
        'with_cause',       round(count(*) FILTER (WHERE cause_text IS NOT NULL)::numeric
                                  / greatest(count(*), 1), 3),
        'with_verification', round(count(*) FILTER (WHERE verification_text IS NOT NULL)::numeric
                                  / greatest(count(*), 1), 3),
        'human_verified',   round(count(*) FILTER (WHERE verified_at IS NOT NULL)::numeric
                                  / greatest(count(*), 1), 3))
      FROM knowledge.case_record;
$$;

-- --- evaluation -------------------------------------------------------

CREATE OR REPLACE FUNCTION memory.recall_at_k(p_run uuid, p_k integer)
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT round(
             count(*) FILTER (WHERE er.hit_rank IS NOT NULL AND er.hit_rank <= p_k)::numeric
             / greatest(count(*), 1), 3)
      FROM memory.eval_result er
     WHERE er.eval_run_id = p_run
       AND er.eval_query_id IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION memory.mrr(p_run uuid)
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT round(avg(CASE WHEN er.hit_rank IS NULL THEN 0
                          ELSE 1.0 / er.hit_rank END)::numeric, 3)
      FROM memory.eval_result er
     WHERE er.eval_run_id = p_run
       AND er.eval_query_id IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION memory.extraction_accuracy(p_run uuid, p_factual boolean)
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT round(count(*) FILTER (WHERE er.correct)::numeric / greatest(count(*), 1), 3)
      FROM memory.eval_result er
     WHERE er.eval_run_id = p_run
       AND er.field IS NOT NULL
       AND (er.field IN ('opened_at', 'closed_at', 'scope', 'status')) = p_factual;
$$;

COMMENT ON FUNCTION memory.extraction_accuracy(uuid, boolean) IS
  'AI-02 splits the target: dates and scope entities (factual, >= 0.95) are held to a higher standard than symptom, cause and action (narrative, >= 0.85), because a wrong date silently breaks recurrence intervals.';

CREATE OR REPLACE FUNCTION memory.eval_finalize(p_run uuid)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    r    record;
    pass boolean;
BEGIN
    SELECT * INTO r FROM memory.eval_run WHERE id = p_run;
    IF NOT FOUND THEN RETURN false; END IF;

    IF r.kind = 'retrieval' THEN
        UPDATE memory.eval_run
           SET recall_at_5 = memory.recall_at_k(p_run, 5),
               mrr         = memory.mrr(p_run)
         WHERE id = p_run;
    ELSE
        UPDATE memory.eval_run
           SET narrative_accuracy = memory.extraction_accuracy(p_run, false),
               factual_accuracy   = memory.extraction_accuracy(p_run, true)
         WHERE id = p_run;
    END IF;

    SELECT * INTO r FROM memory.eval_run WHERE id = p_run;

    pass := CASE r.kind
              WHEN 'retrieval'  THEN r.recall_at_5 >= 0.80 AND r.mrr >= 0.60
              WHEN 'extraction' THEN r.narrative_accuracy >= 0.85 AND r.factual_accuracy >= 0.95
            END;

    UPDATE memory.eval_run SET passed = pass WHERE id = p_run;
    RETURN pass;
END;
$$;

COMMENT ON FUNCTION memory.eval_finalize(uuid) IS
  'AI-02 / AI-04 as executable thresholds. trg_eval_gate refuses any hand-written passed value that disagrees with this computation (AC-01, AC-02).';

-- =====================================================================
-- 17. MEMORY — guard triggers  (DDS-15 DD-H01…DD-H10)
--     Each one makes a requirement a property of the data rather than a
--     rule the application is trusted to remember. db/seed_demo.sql ends
--     with sixteen probes that must all raise.
-- =====================================================================

-- DD-H01 — the original never changes (C-01, FR-05) -------------------

CREATE OR REPLACE FUNCTION memory.trg_document_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.sha256 <> OLD.sha256
       OR NEW.uri <> OLD.uri
       OR coalesce(NEW.original_name, '') <> coalesce(OLD.original_name, '')
       OR NEW.ingested_at <> OLD.ingested_at THEN
        RAISE EXCEPTION 'DOCUMENT_IMMUTABLE: sha256, uri, original_name and ingested_at are fixed once ingested (SRS-15 C-01, FR-05). Ingest a new document instead.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_document_immutable
    BEFORE UPDATE ON knowledge.document
    FOR EACH ROW EXECUTE FUNCTION memory.trg_document_immutable();

-- DD-H02 — near-duplicates go to a person, never to an automatic merge (FR-04)

CREATE OR REPLACE FUNCTION memory.trg_near_duplicate()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    threshold numeric;
BEGIN
    SELECT coalesce((value #>> '{}')::numeric, 0.92) INTO threshold
      FROM memory.setting WHERE key = 'near_duplicate_threshold';
    threshold := coalesce(threshold, 0.92);

    IF NEW.resolution = 'merged' AND NEW.decided_by IS NULL THEN
        RAISE EXCEPTION 'MERGE_NEEDS_CURATOR: a near-duplicate is merged by a person, not by a score (SRS-15 FR-04, FR-27).';
    END IF;

    IF TG_OP = 'INSERT' AND NEW.score >= threshold THEN
        INSERT INTO memory.curation_item (kind, document_id, near_duplicate_id, detail)
        VALUES ('near_duplicate', NEW.document_id, NEW.id,
                format('near-duplicate score %s — merge or mark distinct', NEW.score));
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_near_duplicate
    AFTER INSERT OR UPDATE ON memory.near_duplicate
    FOR EACH ROW EXECUTE FUNCTION memory.trg_near_duplicate();

-- DD-H03 — no machine-written field without provenance (FR-13, NFR-08)

CREATE OR REPLACE FUNCTION memory.trg_field_provenance()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    low numeric;
BEGIN
    IF NEW.human = false THEN
        IF NEW.extraction_id IS NULL THEN
            RAISE EXCEPTION 'EXTRACTION_REQUIRED: a machine-written field must name the extraction that produced it — model, prompt version, schema version (SRS-15 NFR-08).';
        END IF;
        IF NEW.confidence IS NULL THEN
            RAISE EXCEPTION 'CONFIDENCE_REQUIRED: a machine-written field must carry its confidence (SRS-15 FR-13, C-02).';
        END IF;
        IF NEW.provenance_json -> 'document_id' IS NULL OR NEW.provenance_json -> 'page' IS NULL THEN
            RAISE EXCEPTION 'PROVENANCE_REQUIRED: provenance_json must carry at least document_id and page — the structure indexes the document, it does not replace it (SRS-15 C-01).';
        END IF;
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_field_provenance
    BEFORE INSERT OR UPDATE ON memory.case_field
    FOR EACH ROW EXECUTE FUNCTION memory.trg_field_provenance();

CREATE OR REPLACE FUNCTION memory.trg_field_queue()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    low numeric;
BEGIN
    SELECT coalesce((value #>> '{}')::numeric, 0.70) INTO low
      FROM memory.setting WHERE key = 'low_confidence_threshold';
    low := coalesce(low, 0.70);

    IF NEW.human = false AND NEW.confidence < low
       AND NOT EXISTS (SELECT 1 FROM memory.curation_item ci
                        WHERE ci.case_field_id = NEW.id AND ci.state = 'open') THEN
        INSERT INTO memory.curation_item (kind, case_record_id, case_field_id, detail)
        VALUES ('low_confidence', NEW.case_record_id, NEW.id,
                format('%s extracted at confidence %s', NEW.field, NEW.confidence));
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_field_queue
    AFTER INSERT ON memory.case_field
    FOR EACH ROW EXECUTE FUNCTION memory.trg_field_queue();

-- DD-H04 — a flagged field is suppressed until a curator resolves it (FR-30, AC-06)

CREATE OR REPLACE FUNCTION memory.trg_field_flag_suppress()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.flagged = true AND OLD.flagged = false THEN
        INSERT INTO memory.curation_item (kind, case_record_id, case_field_id, detail)
        VALUES ('flagged_field', NEW.case_record_id, NEW.id,
                coalesce(NEW.flagged_reason, 'flagged as incorrect'));
    END IF;

    IF NEW.flagged = false AND OLD.flagged = true THEN
        IF NEW.corrected_by IS NULL
           OR NOT EXISTS (SELECT 1 FROM memory.user_role ur
                           WHERE ur.user_id = NEW.corrected_by
                             AND ur.role IN ('curator', 'admin')) THEN
            RAISE EXCEPTION 'UNFLAG_NEEDS_CURATOR: a suppressed field returns to results only through curation (SRS-15 FR-27, FR-30, AC-06).';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_field_flag_suppress
    BEFORE UPDATE ON memory.case_field
    FOR EACH ROW EXECUTE FUNCTION memory.trg_field_flag_suppress();

-- DD-H05 — nothing is citable without a source and a curator (AI-07, AC-08, FR-28)

CREATE OR REPLACE FUNCTION memory.trg_case_citable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.verified_at IS NOT NULL
       AND (OLD.verified_at IS NULL OR TG_OP = 'INSERT') THEN

        IF NOT EXISTS (SELECT 1 FROM knowledge.case_source cs
                        WHERE cs.case_record_id = NEW.id) THEN
            RAISE EXCEPTION 'SOURCE_REQUIRED: a case cannot become citable without at least one source document (SRS-15 AI-07, AC-08).';
        END IF;

        IF EXISTS (SELECT 1 FROM memory.case_field cf
                    WHERE cf.case_record_id = NEW.id AND cf.flagged = true) THEN
            RAISE EXCEPTION 'FLAGGED_FIELD_PRESENT: resolve the flagged field before verifying the case (SRS-15 FR-30).';
        END IF;

        IF NEW.verified_by IS NULL
           OR NOT EXISTS (SELECT 1 FROM memory.user_role ur
                           WHERE ur.user_id = NEW.verified_by
                             AND ur.role IN ('curator', 'admin')) THEN
            RAISE EXCEPTION 'VERIFY_NEEDS_CURATOR: only a curator or an admin turns an extraction into established fact (SRS-15 FR-28, ADR-H10).';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_case_citable
    BEFORE INSERT OR UPDATE ON knowledge.case_record
    FOR EACH ROW EXECUTE FUNCTION memory.trg_case_citable();

-- DD-H06 — verification is a role, an event and append-only (FR-28) ----

CREATE OR REPLACE FUNCTION memory.trg_verify_role()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM memory.user_role ur
                    WHERE ur.user_id = NEW.verified_by
                      AND ur.role IN ('curator', 'admin')) THEN
        RAISE EXCEPTION 'VERIFY_NEEDS_CURATOR: % does not hold curator or admin (SRS-15 FR-28).', NEW.verified_by;
    END IF;

    IF NEW.scope = 'field' AND NEW.field IS NULL THEN
        RAISE EXCEPTION 'FIELD_REQUIRED: a field-scoped verification must name the field (SRS-15 FR-13).';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_verify_role
    BEFORE INSERT ON memory.verification
    FOR EACH ROW EXECUTE FUNCTION memory.trg_verify_role();

CREATE OR REPLACE FUNCTION memory.trg_verification_applies()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.scope = 'case' AND NEW.revoked = false THEN
        UPDATE knowledge.case_record
           SET verified_by = NEW.verified_by,
               verified_at = NEW.verified_at
         WHERE id = NEW.case_record_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_verification_applies
    AFTER INSERT ON memory.verification
    FOR EACH ROW EXECUTE FUNCTION memory.trg_verification_applies();

-- DD-H07 — unmapped entities are not guessed (FR-10) ------------------

CREATE OR REPLACE FUNCTION memory.trg_entity_mapped()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    canon text;
BEGIN
    canon := memory.normalise_entity(NEW.kind, NEW.raw_value);

    IF NEW.mapped = true THEN
        IF canon IS NULL THEN
            RAISE EXCEPTION 'ENTITY_NOT_MAPPED: "%" is not an approved % — map it in memory.entity_map first (SRS-15 FR-10).', NEW.raw_value, NEW.kind;
        END IF;
        IF NEW.canonical_id IS DISTINCT FROM canon THEN
            RAISE EXCEPTION 'ENTITY_MAP_CONFLICT: "%" maps to % , not % (SRS-15 FR-10).', NEW.raw_value, canon, NEW.canonical_id;
        END IF;
    ELSE
        IF canon IS NOT NULL THEN
            NEW.canonical_id := canon;
            NEW.mapped := true;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_entity_mapped
    BEFORE INSERT OR UPDATE ON memory.case_entity
    FOR EACH ROW EXECUTE FUNCTION memory.trg_entity_mapped();

CREATE OR REPLACE FUNCTION memory.trg_entity_queue()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.mapped = false
       AND NOT EXISTS (SELECT 1 FROM memory.curation_item ci
                        WHERE ci.case_entity_id = NEW.id AND ci.state = 'open') THEN
        INSERT INTO memory.curation_item (kind, case_record_id, case_entity_id, detail)
        VALUES ('unmapped_entity', NEW.case_record_id, NEW.id,
                format('%s "%s" has no canonical id', NEW.kind, NEW.raw_value));
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_entity_queue
    AFTER INSERT ON memory.case_entity
    FOR EACH ROW EXECUTE FUNCTION memory.trg_entity_queue();

-- DD-H08 — a recurrence is a proposal until a person confirms it (FR-21, AI-06)

CREATE OR REPLACE FUNCTION memory.trg_recurrence_confirm()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    threshold numeric;
    months    integer;
BEGIN
    SELECT coalesce((value #>> '{}')::numeric, 0.72) INTO threshold
      FROM memory.setting WHERE key = 'recurrence_threshold';
    threshold := coalesce(threshold, 0.72);

    IF NEW.score < threshold THEN
        RAISE EXCEPTION 'RECURRENCE_BELOW_THRESHOLD: % < % — a weaker match is a search result, not a recurrence (SRS-15 FR-21, AI-06).', NEW.score, threshold;
    END IF;

    SELECT extract(year  FROM age(cur.opened_at, prior.opened_at))::integer * 12
         + extract(month FROM age(cur.opened_at, prior.opened_at))::integer
      INTO months
      FROM knowledge.case_record cur, knowledge.case_record prior
     WHERE cur.id = NEW.case_record_id AND prior.id = NEW.prior_case_id;

    IF months IS NULL OR months < 0 THEN
        RAISE EXCEPTION 'RECURRENCE_ORDER: the prior case must be older than the recurring one (SRS-15 FR-21).';
    END IF;

    NEW.interval_months := months;   -- computed, never entered (AC-07)

    IF NEW.confirmed_at IS NOT NULL THEN
        IF NEW.confirmed_by IS NULL
           OR NOT EXISTS (SELECT 1 FROM memory.user_role ur
                           WHERE ur.user_id = NEW.confirmed_by
                             AND ur.role IN ('engineer', 'curator', 'admin')) THEN
            RAISE EXCEPTION 'CONFIRM_NEEDS_ENGINEER: a recurrence enters the analytics only when someone who knows the machine confirms it (SRS-15 AI-06, ADR-H07).';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_recurrence_confirm
    BEFORE INSERT OR UPDATE ON memory.recurrence
    FOR EACH ROW EXECUTE FUNCTION memory.trg_recurrence_confirm();

-- DD-H09 — a case is as restricted as its strictest source (C-05, NFR-05)

CREATE OR REPLACE FUNCTION memory.trg_acl_inherit()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    inherited jsonb;
BEGIN
    inherited := memory.case_acl(NEW.case_record_id);

    IF NEW.acl_json = '{}'::jsonb THEN
        NEW.acl_json := inherited;
    ELSIF memory.role_rank(NEW.acl_json ->> 'min_role')
          < memory.role_rank(inherited ->> 'min_role') THEN
        RAISE EXCEPTION 'ACL_WEAKER_THAN_SOURCE: the index would expose a case whose source requires % (SRS-15 C-05, NFR-05, AC-05).', inherited ->> 'min_role';
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_acl_inherit
    BEFORE INSERT OR UPDATE ON memory.case_index
    FOR EACH ROW EXECUTE FUNCTION memory.trg_acl_inherit();

-- DD-H10 — embeddings, versions and the injection flag ----------------

CREATE OR REPLACE FUNCTION memory.trg_embedding_version()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.embedding IS NOT NULL AND NEW.embedding_version IS NULL THEN
        RAISE EXCEPTION 'EMBEDDING_VERSION_REQUIRED: a vector without its model version cannot be queried or re-embedded safely (SRS-15 AI-09, NFR-08).';
    END IF;

    IF NEW.embedding_version IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM memory.embedding_model em
                        WHERE em.version = NEW.embedding_version) THEN
        RAISE EXCEPTION 'EMBEDDING_VERSION_UNKNOWN: % is not registered in memory.embedding_model (SRS-15 AI-09).', NEW.embedding_version;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_chunk_embedding_version
    BEFORE INSERT OR UPDATE ON knowledge.chunk
    FOR EACH ROW EXECUTE FUNCTION memory.trg_embedding_version();

CREATE TRIGGER trg_case_chunk_embedding_version
    BEFORE INSERT OR UPDATE ON knowledge.case_chunk
    FOR EACH ROW EXECUTE FUNCTION memory.trg_embedding_version();

CREATE OR REPLACE FUNCTION memory.trg_embedding_retire()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.state = 'retired' AND OLD.state <> 'retired' THEN
        IF EXISTS (SELECT 1 FROM memory.reembed_job j
                    WHERE j.from_version = NEW.version
                      AND j.state IN ('queued', 'running')) THEN
            RAISE EXCEPTION 'VERSION_IN_USE: a re-embed job is still serving queries from % — search stays available throughout (SRS-15 AC-09).', NEW.version;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_embedding_retire
    BEFORE UPDATE ON memory.embedding_model
    FOR EACH ROW EXECUTE FUNCTION memory.trg_embedding_retire();

CREATE OR REPLACE FUNCTION memory.trg_injection_flag()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF memory.injection_scan(NEW.text) THEN
        NEW.suspicious        := true;
        NEW.suspicious_reason := 'instruction-like text in an ingested document (SRS-15 AI-08)';
    ELSE
        NEW.suspicious        := false;
        NEW.suspicious_reason := NULL;
    END IF;
    RETURN NEW;
END;
$$;

-- Factory Copilot (10) defines a trigger of this name with the same intent in
-- copilot_0001. When both modules are deployed the one already present keeps
-- the table; the two implementations agree on what counts as instruction-like
-- text and on the columns they set (ICD-15 IF-55, DDS-15 DD-H10).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger tg
          JOIN pg_class c ON c.oid = tg.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE tg.tgname = 'trg_chunk_injection_flag'
           AND n.nspname = 'knowledge' AND c.relname = 'chunk'
           AND NOT tg.tgisinternal) THEN
        EXECUTE 'CREATE TRIGGER trg_chunk_injection_flag'
             || ' BEFORE INSERT OR UPDATE ON knowledge.chunk'
             || ' FOR EACH ROW EXECUTE FUNCTION memory.trg_injection_flag()';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION memory.trg_suspicious_queue()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.suspicious
       AND NOT EXISTS (SELECT 1 FROM memory.curation_item ci
                        WHERE ci.chunk_id = NEW.id AND ci.state = 'open') THEN
        INSERT INTO memory.curation_item (kind, document_id, chunk_id, detail)
        VALUES ('suspicious_chunk', NEW.document_id, NEW.id, left(NEW.text, 200));
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_suspicious_queue
    AFTER INSERT OR UPDATE ON knowledge.chunk
    FOR EACH ROW EXECUTE FUNCTION memory.trg_suspicious_queue();

-- Supporting guards ---------------------------------------------------

CREATE OR REPLACE FUNCTION memory.trg_ocr_flag()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    gate numeric;
BEGIN
    SELECT coalesce((value #>> '{}')::numeric, 0.95) INTO gate
      FROM memory.setting WHERE key = 'ocr_confidence_gate';
    gate := coalesce(gate, 0.95);

    IF (NEW.handwriting OR NEW.char_confidence < gate) AND NEW.low_confidence = false THEN
        RAISE EXCEPTION 'OCR_LOW_CONFIDENCE: handwriting and characters below % are always low confidence (SRS-15 FR-02; IF-76).', gate;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ocr_flag
    BEFORE INSERT OR UPDATE ON memory.ocr_region
    FOR EACH ROW EXECUTE FUNCTION memory.trg_ocr_flag();

CREATE OR REPLACE FUNCTION memory.trg_eval_gate()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    should boolean;
BEGIN
    should := CASE NEW.kind
                WHEN 'retrieval'  THEN coalesce(NEW.recall_at_5, 0) >= 0.80
                                   AND coalesce(NEW.mrr, 0) >= 0.60
                WHEN 'extraction' THEN coalesce(NEW.narrative_accuracy, 0) >= 0.85
                                   AND coalesce(NEW.factual_accuracy, 0) >= 0.95
              END;

    IF NEW.passed IS NOT NULL AND NEW.passed <> should THEN
        RAISE EXCEPTION 'EVAL_GATE: a % run passes only at the SRS thresholds — Recall@5 >= 0.80 and MRR >= 0.60, or >= 0.85 narrative and >= 0.95 factual (SRS-15 AI-02, AI-04).', NEW.kind;
    END IF;

    NEW.passed := should;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_eval_gate
    BEFORE INSERT OR UPDATE ON memory.eval_run
    FOR EACH ROW EXECUTE FUNCTION memory.trg_eval_gate();

CREATE OR REPLACE FUNCTION memory.trg_rank_weight_sum()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    total numeric;
BEGIN
    SELECT sum(weight) INTO total FROM memory.rank_weight;
    IF total IS NOT NULL AND total <> 1.000 THEN
        RAISE EXCEPTION 'RANK_WEIGHTS_SUM: the ranking weights must sum to 1.000, not % — otherwise scores stop being comparable between queries (SRS-15 FR-18).', total;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_rank_weight_sum
    AFTER INSERT OR UPDATE OR DELETE ON memory.rank_weight
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION memory.trg_rank_weight_sum();

CREATE OR REPLACE FUNCTION memory.trg_feedback_incorrect()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.rating = 'incorrect' THEN
        UPDATE memory.case_field
           SET flagged = true,
               flagged_by = NEW.user_id,
               flagged_reason = coalesce(NEW.reason, 'reported incorrect from a search result')
         WHERE case_record_id = NEW.case_record_id
           AND field = NEW.field
           AND flagged = false;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_feedback_incorrect
    AFTER INSERT ON memory.feedback
    FOR EACH ROW EXECUTE FUNCTION memory.trg_feedback_incorrect();

CREATE OR REPLACE FUNCTION memory.trg_curation_decision()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.decided_by IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM memory.user_role ur
                        WHERE ur.user_id = NEW.decided_by
                          AND ur.role IN ('curator', 'admin')) THEN
        RAISE EXCEPTION 'CURATION_NEEDS_CURATOR: curation decisions are the one audited path into established fact (SRS-15 FR-27, ADR-H10).';
    END IF;

    IF NEW.decided_at IS NOT NULL AND NEW.state = 'open' THEN
        NEW.state := 'resolved';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_curation_decision
    BEFORE UPDATE ON memory.curation_item
    FOR EACH ROW EXECUTE FUNCTION memory.trg_curation_decision();

CREATE OR REPLACE FUNCTION memory.trg_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'APPEND_ONLY: % is evidence about what the system did; it is never edited or deleted (SRS-15 C-02, SEC-15 O-3).', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_verification_append_only
    BEFORE UPDATE OR DELETE ON memory.verification
    FOR EACH ROW EXECUTE FUNCTION memory.trg_append_only();

CREATE TRIGGER trg_query_log_append_only
    BEFORE DELETE ON memory.query_log
    FOR EACH ROW EXECUTE FUNCTION memory.trg_append_only();

CREATE TRIGGER trg_feedback_append_only
    BEFORE UPDATE OR DELETE ON memory.feedback
    FOR EACH ROW EXECUTE FUNCTION memory.trg_append_only();

CREATE TRIGGER trg_merge_append_only
    BEFORE UPDATE OR DELETE ON memory.merge_event
    FOR EACH ROW EXECUTE FUNCTION memory.trg_append_only();

CREATE TRIGGER trg_setting_updated
    BEFORE UPDATE ON memory.setting
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_rank_weight_updated
    BEFORE UPDATE ON memory.rank_weight
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_corpus_stat_updated
    BEFORE UPDATE ON memory.corpus_stat
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =====================================================================
-- 18. MEMORY — indexes and views
-- =====================================================================

CREATE INDEX idx_ingest_job_state     ON memory.ingest_job (state, created_at DESC);
CREATE INDEX idx_ingest_job_document  ON memory.ingest_job (document_id);
CREATE INDEX idx_ingest_error_reason  ON memory.ingest_error (reason, ts DESC);
CREATE INDEX idx_doc_text_lang        ON memory.doc_text (lang);
CREATE INDEX idx_ocr_region_low       ON memory.ocr_region (ocr_page_id) WHERE low_confidence = true;
CREATE INDEX idx_near_dup_pending     ON memory.near_duplicate (score DESC) WHERE resolution = 'pending';
CREATE INDEX idx_case_field_case      ON memory.case_field (case_record_id, field);
CREATE INDEX idx_case_field_flagged   ON memory.case_field (case_record_id) WHERE flagged = true;
CREATE INDEX idx_case_field_low       ON memory.case_field (confidence) WHERE human = false;
CREATE INDEX idx_case_entity_canon    ON memory.case_entity (kind, canonical_id);
CREATE INDEX idx_case_entity_unmapped ON memory.case_entity (case_record_id) WHERE mapped = false;
CREATE INDEX idx_descriptor_class     ON memory.symptom_descriptor (defect_class);
CREATE INDEX idx_descriptor_alarm     ON memory.symptom_descriptor (alarm_code) WHERE alarm_code IS NOT NULL;
CREATE INDEX idx_recurrence_prior     ON memory.recurrence (prior_case_id) WHERE confirmed_at IS NOT NULL;
CREATE INDEX idx_recurrence_open      ON memory.recurrence (detected_at DESC) WHERE confirmed_at IS NULL AND rejected = false;
CREATE INDEX idx_case_index_tokens    ON memory.case_index USING gin (tokens);
CREATE INDEX idx_case_index_text_trgm ON memory.case_index USING gin (indexed_text gin_trgm_ops);
CREATE INDEX idx_query_log_ts         ON memory.query_log (ts DESC);
CREATE INDEX idx_query_log_user       ON memory.query_log (user_id, ts DESC);
CREATE INDEX idx_query_result_case    ON memory.query_result (case_record_id);
CREATE INDEX idx_feedback_case        ON memory.feedback (case_record_id, ts DESC);
CREATE INDEX idx_suggestion_case      ON memory.suggestion (quality_case_id);
CREATE INDEX idx_curation_open        ON memory.curation_item (kind, opened_at) WHERE state = 'open';
CREATE INDEX idx_verification_case    ON memory.verification (case_record_id, verified_at DESC);
CREATE INDEX idx_eval_result_run      ON memory.eval_result (eval_run_id);
CREATE INDEX idx_eval_run_ts          ON memory.eval_run (kind, ts DESC);
CREATE INDEX idx_reembed_state        ON memory.reembed_job (state, started_at DESC);

COMMENT ON INDEX memory.idx_case_index_tokens IS
  'The lexical leg walks the token arrays; the trigram index backs near-duplicate scoring and substring lookups. NFR-01 budgets 1 s p95 over 100 k chunks with both in place.';

CREATE OR REPLACE VIEW memory.v_case_card AS
SELECT cr.id                                   AS case_record_id,
       cr.title,
       cr.opened_at,
       cr.closed_at,
       cr.symptom_text,
       CASE WHEN EXISTS (SELECT 1 FROM memory.case_field cf
                          WHERE cf.case_record_id = cr.id AND cf.field = 'cause' AND cf.flagged)
            THEN NULL ELSE cr.cause_text END    AS cause_text,
       CASE WHEN EXISTS (SELECT 1 FROM memory.case_field cf
                          WHERE cf.case_record_id = cr.id AND cf.field = 'corrective_action' AND cf.flagged)
            THEN NULL ELSE cr.action_text END   AS action_text,
       cr.outcome,
       (cr.verified_at IS NOT NULL)             AS verified,
       memory.case_acl(cr.id)                   AS acl_json,
       (SELECT count(*) FROM knowledge.case_source cs WHERE cs.case_record_id = cr.id) AS n_sources
  FROM knowledge.case_record cr;

COMMENT ON VIEW memory.v_case_card IS
  'What a result row shows. A flagged field is NULL here, not stale: suppression is a property of the read path, not something the UI is trusted to do (FR-30, AC-06).';

CREATE OR REPLACE VIEW memory.v_curation_queue AS
SELECT ci.id, ci.kind, ci.state, ci.detail, ci.opened_at,
       now() - ci.opened_at                    AS age,
       cr.title                                AS case_title,
       d.original_name                         AS document_name
  FROM memory.curation_item ci
  LEFT JOIN knowledge.case_record cr ON cr.id = ci.case_record_id
  LEFT JOIN knowledge.document d     ON d.id  = ci.document_id
 WHERE ci.state IN ('open', 'in_review')
 ORDER BY ci.opened_at;

CREATE OR REPLACE VIEW memory.v_recurring_problem AS
SELECT sd.defect_class,
       ce.canonical_id                          AS machine,
       count(DISTINCT cr.id)                    AS n_cases,
       count(DISTINCT r.id) FILTER (WHERE r.confirmed_at IS NOT NULL AND NOT r.rejected) AS n_recurrences,
       max(cr.opened_at)                        AS last_seen
  FROM knowledge.case_record cr
  JOIN memory.symptom_descriptor sd ON sd.case_record_id = cr.id
  LEFT JOIN memory.case_entity ce   ON ce.case_record_id = cr.id AND ce.kind = 'machine'
  LEFT JOIN memory.recurrence r     ON r.case_record_id  = cr.id
 GROUP BY sd.defect_class, ce.canonical_id;

CREATE OR REPLACE VIEW memory.v_action_effectiveness AS
SELECT sd.defect_class,
       cr.id                                    AS case_record_id,
       cr.action_text,
       cr.opened_at,
       EXISTS (SELECT 1 FROM memory.recurrence r
                WHERE r.prior_case_id = cr.id
                  AND r.confirmed_at IS NOT NULL AND NOT r.rejected) AS recurred
  FROM knowledge.case_record cr
  JOIN memory.symptom_descriptor sd ON sd.case_record_id = cr.id
 WHERE cr.action_text IS NOT NULL;

CREATE OR REPLACE VIEW memory.v_knowledge_gap AS
SELECT cr.id AS case_record_id, cr.title, cr.opened_at,
       (cr.cause_text IS NULL)        AS no_cause,
       (cr.verification_text IS NULL) AS no_verification,
       (cr.verified_at IS NULL)       AS not_human_verified
  FROM knowledge.case_record cr
 WHERE cr.cause_text IS NULL OR cr.verification_text IS NULL OR cr.verified_at IS NULL;

CREATE OR REPLACE VIEW memory.v_coverage AS
SELECT count(*)                                                              AS cases,
       round(count(*) FILTER (WHERE cause_text IS NOT NULL)::numeric
             / greatest(count(*), 1), 3)                                     AS with_cause,
       round(count(*) FILTER (WHERE verification_text IS NOT NULL)::numeric
             / greatest(count(*), 1), 3)                                     AS with_verification,
       round(count(*) FILTER (WHERE verified_at IS NOT NULL)::numeric
             / greatest(count(*), 1), 3)                                     AS human_verified
  FROM knowledge.case_record;

CREATE OR REPLACE VIEW memory.v_eval_gate AS
SELECT er.id, er.kind, er.ts, er.model, er.embedding_version,
       er.recall_at_5, er.mrr, er.narrative_accuracy, er.factual_accuracy,
       er.passed, er.investigate
  FROM memory.eval_run er
 ORDER BY er.ts DESC;

CREATE OR REPLACE VIEW memory.v_embedding_status AS
SELECT em.version, em.model, em.state,
       (SELECT count(*) FROM knowledge.chunk c      WHERE c.embedding_version = em.version) AS chunks,
       (SELECT count(*) FROM knowledge.case_chunk cc WHERE cc.embedding_version = em.version) AS case_chunks,
       j.state                                                       AS job_state,
       j.done_chunks, j.total_chunks, j.search_available
  FROM memory.embedding_model em
  LEFT JOIN memory.reembed_job j ON j.to_version = em.version;

CREATE OR REPLACE VIEW memory.v_ingest_health AS
SELECT date_trunc('day', ij.created_at)                          AS day,
       count(*)                                                  AS jobs,
       count(*) FILTER (WHERE ij.state = 'done')                 AS done,
       count(*) FILTER (WHERE ij.state = 'failed')               AS failed,
       count(*) FILTER (WHERE ij.state = 'skipped')              AS skipped,
       count(DISTINCT ie.reason)                                 AS distinct_reasons
  FROM memory.ingest_job ij
  LEFT JOIN memory.ingest_error ie ON ie.job_id = ij.id
 GROUP BY 1;

CREATE OR REPLACE VIEW memory.v_review_queue AS
SELECT cr.id AS case_record_id, cr.title, cr.opened_at,
       count(cf.id) FILTER (WHERE cf.human = false AND cf.confidence < 0.70) AS low_confidence_fields,
       count(cf.id) FILTER (WHERE cf.flagged)                                AS flagged_fields,
       (cr.verified_at IS NULL)                                              AS awaiting_verification
  FROM knowledge.case_record cr
  LEFT JOIN memory.case_field cf ON cf.case_record_id = cr.id
 GROUP BY cr.id, cr.title, cr.opened_at, cr.verified_at
HAVING cr.verified_at IS NULL
    OR count(cf.id) FILTER (WHERE cf.flagged) > 0;

-- =====================================================================
-- 19. ROLES, GRANTS AND SCHEMA VERSION
--     Standalone. In platform mode the platform's roles already exist and
--     only worker_rw and auditor_ro are added (SAD-15 section 9).
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')     THEN CREATE ROLE app_rw     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker_rw')  THEN CREATE ROLE worker_rw  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')     THEN CREATE ROLE app_ro     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor_ro') THEN CREATE ROLE auditor_ro NOLOGIN; END IF;
END
$$;

GRANT USAGE ON SCHEMA core, quality, knowledge, audit, memory TO app_rw, worker_rw, app_ro, auditor_ro;

GRANT SELECT ON ALL TABLES IN SCHEMA core, quality, knowledge, memory TO app_ro, auditor_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA audit                            TO auditor_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA memory     TO app_rw;
GRANT SELECT, INSERT, UPDATE          ON ALL TABLES IN SCHEMA knowledge TO app_rw;
GRANT SELECT, INSERT                  ON audit.log, audit.auth_event    TO app_rw;

-- The workers structure and index; they never verify, never curate and
-- never touch GenbaGo's two tables (ADR-H01, SEC-15 SEC-H12).
GRANT SELECT, INSERT, UPDATE ON
      memory.ingest_job, memory.ingest_error, memory.doc_text,
      memory.ocr_page, memory.ocr_region, memory.near_duplicate,
      memory.extraction, memory.case_field, memory.case_entity,
      memory.symptom_descriptor, memory.recurrence, memory.case_index,
      memory.corpus_stat, memory.term_stat, memory.curation_item,
      memory.query_log, memory.query_candidate, memory.query_result,
      memory.suggestion, memory.eval_run, memory.eval_result,
      memory.reembed_job
   TO worker_rw;
GRANT SELECT, INSERT, UPDATE ON knowledge.document, knowledge.chunk,
      knowledge.case_record, knowledge.case_source, knowledge.case_chunk
   TO worker_rw;
GRANT SELECT ON knowledge.glossary_term, knowledge.tm_segment TO worker_rw, app_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA core, quality TO worker_rw;
GRANT INSERT ON audit.log TO worker_rw;

REVOKE INSERT, UPDATE, DELETE ON knowledge.glossary_term, knowledge.tm_segment
    FROM app_rw, worker_rw;

REVOKE INSERT, UPDATE, DELETE ON memory.verification, memory.merge_event FROM worker_rw;
REVOKE UPDATE, DELETE ON audit.log, audit.auth_event FROM app_rw, worker_rw, app_ro, auditor_ro;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA memory TO app_rw, worker_rw;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA memory TO app_rw, worker_rw, app_ro;

COMMENT ON SCHEMA audit IS
  'Append-only. No UPDATE or DELETE grant exists for any role (SEC-15 O-3).';

INSERT INTO memory.migration (id, note) VALUES
  ('memory_0001',
   'Genba Memory extension of the platform knowledge context: ingestion, structuring with provenance, hybrid retrieval, curation, evaluation and the embedding registry (DDS-15).');
