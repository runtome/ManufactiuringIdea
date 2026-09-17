-- =====================================================================
--  QE-Agent — AI Manufacturing Quality Engineer Agent — database schema  (DDS-09)
--  Target   : PostgreSQL 16 + pgvector >= 0.7 (+ pgcrypto, pg_trgm, btree_gin)
--  Schemas  : core (shared master data, users), vision (model_registry only — referenced by quality.artifact),
--             quality (SPC, signals, cases, hypotheses, artefacts, FMEA — owned by QE-Agent, shared with MoldMind for mould/shot),
--             knowledge (documents, case records, glossary — the retrieval half), audit (append-only)
--
--  ASSEMBLY (DDS-09 §1.4, TEST-09 TC-002): every object marked [platform] is copied BYTE-FOR-BYTE from
--  00-factorybrain-platform/db/schema.sql by marker extraction: extensions, helpers, enums, core.plant/line/sku,
--  core.machine/defect_type/material_lot, core.app_user/user_line_scope, vision.model_registry, ALL of quality.* (section 7),
--  knowledge.document/chunk/case_record/case_source/case_chunk/glossary_term, audit.*, the quality and knowledge indexes,
--  the core updated_at triggers. Section 10 onward is the QE-Agent extension (migration quality_0001), applied to the
--  platform database in platform mode (SAD-09 §9).
--
--  The rules of SRS-09 that are DATABASE RULES here (DDS-09 DD-Q01..Q09):
--    C-02/AI-04  every numeric or causal claim in an artefact points at an evidence row; untraced ⇒ cannot be approved   artifact_claim, trg_claim_check, trg_artifact_approval
--    C-01/AC-06  an unapproved artefact can only be exported with the DRAFT watermark                                    trg_export_watermark
--    NFR-05      approval needs role >= engineer; approvals immutable; audited                                            trg_artifact_approval
--    C-03/AC-03  capability with normality_ok = false needs a method note                                                 trg_capability_note
--    C-04        causal wording refused unless the hypothesis is confirmed; verify step mandatory                         trg_hypothesis_wording
--    FR-06       control limits append-only with a reason; previous limits deactivated, never deleted                    trg_limits_append_only
--    FR-11       signals below the minimum sample or inside a trial run are suppressed                                    trg_signal_admissible
--    AI-07/C-05  FMEA rows exist only after each S/O/D rating is confirmed against a criteria row                         trg_fmea_confirm
--    FR-28/FR-29 an action is verified only with a significant improvement; a case closes only when actions are settled
--                and is then indexed as a knowledge.case_record with horizontal candidates                               trg_action_verified, trg_case_close
--    AI-05       golden run < 60 % top-3 or any fabricated evidence ⇒ release_blocked                                    trg_golden_gate
--
--  Apply:  psql -v ON_ERROR_STOP=1 -f schema.sql   (then optionally seed_demo.sql)
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

COMMENT ON SCHEMA quality   IS 'SPC, capability, signals, cases, hypotheses, artefacts, FMEA (SRS-09; mould/shot shared with SRS-11).';
COMMENT ON SCHEMA knowledge IS 'Documents, case records, glossary — the retrieval half of QE-Agent (platform shape).';
COMMENT ON SCHEMA audit     IS 'Append-only audit log. INSERT only; no UPDATE or DELETE grants.';

-- =====================================================================
-- 3. HELPER FUNCTIONS  [platform — byte-identical, lines 63–104]
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
-- 4. ENUMERATED TYPES  [platform lines 110–120] + QE-Agent
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

CREATE TYPE quality.evidence_kind    AS ENUM ('query', 'chart', 'test', 'change_point', 'correlation', 'capability', 'limits', 'timeline', 'case', 'doc_chunk');
CREATE TYPE quality.claim_kind       AS ENUM ('numeric', 'date', 'count', 'causal', 'other');
CREATE TYPE quality.grounding_status AS ENUM ('pending', 'passed', 'failed');
CREATE TYPE quality.fmea_standard    AS ENUM ('aiag_vda_ap', 'classic_rpn');
CREATE TYPE quality.factor_kind      AS ENUM ('material_lot', 'machine', 'mould', 'shift', 'operator_group', 'sku', 'parameter_change', 'ambient');

-- =====================================================================
-- 5. CORE  [platform — plant/line/sku 144–174; machine/defect_type/material_lot 176–213; app_user/user_line_scope 228–256]
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
-- 6. VISION — model registry only  [platform — referenced by quality.artifact.model_id]
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

-- =====================================================================
-- 7. QUALITY — platform tables  [byte-identical, section 7 lines 491–738]
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
-- 8. KNOWLEDGE — documents, case records, glossary  [platform lines 864–950]
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

-- =====================================================================
-- 9. AUDIT, INDEXES, TRIGGERS  [platform]
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

CREATE INDEX idx_chunk_embedding ON knowledge.chunk
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_case_chunk_embedding ON knowledge.case_chunk
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_chunk_text_trgm      ON knowledge.chunk      USING gin (text gin_trgm_ops);
CREATE INDEX idx_case_chunk_text_trgm ON knowledge.case_chunk USING gin (text gin_trgm_ops);
CREATE INDEX idx_chunk_doc            ON knowledge.chunk (document_id, ordinal);
CREATE INDEX idx_chunk_embver         ON knowledge.chunk (embedding_version);
CREATE INDEX idx_case_record_verified ON knowledge.case_record (verified_at) WHERE verified_at IS NOT NULL;

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

-- =====================================================================
-- 10. QE-AGENT EXTENSION (migration quality_0001) — data layer and configuration
-- =====================================================================
CREATE TABLE quality.subgroup (                            -- FR-03: subgroup by fixed n / time window / batch
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    characteristic_id  uuid NOT NULL REFERENCES quality.characteristic(id) ON DELETE CASCADE,
    line_id            uuid REFERENCES core.line(id) ON DELETE CASCADE,
    seq                integer NOT NULL,
    ts_from            timestamptz NOT NULL,
    ts_to              timestamptz NOT NULL,
    n                  integer NOT NULL CHECK (n >= 1),
    mean               numeric(14,5) NOT NULL,
    range              numeric(14,5),
    sd                 numeric(14,6),
    lot_id             uuid REFERENCES core.material_lot(id) ON DELETE SET NULL,
    machine_id         uuid REFERENCES core.machine(id) ON DELETE SET NULL,
    UNIQUE (characteristic_id, line_id, seq),
    CONSTRAINT subgroup_window CHECK (ts_to >= ts_from)
);

CREATE TABLE quality.measurement (                         -- SRS §5 measurement_series (IF-49)
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts                 timestamptz NOT NULL,
    characteristic_id  uuid NOT NULL REFERENCES quality.characteristic(id) ON DELETE CASCADE,
    line_id            uuid REFERENCES core.line(id) ON DELETE CASCADE,
    subgroup_id        uuid REFERENCES quality.subgroup(id) ON DELETE SET NULL,
    value              numeric(14,5) NOT NULL,
    lot_id             uuid REFERENCES core.material_lot(id) ON DELETE SET NULL,
    machine_id         uuid REFERENCES core.machine(id) ON DELETE SET NULL,
    shift              core.shift_code,
    source             text NOT NULL DEFAULT 'inspection' CHECK (source IN ('inspection', 'gauge', 'import', 'manual')),
    source_ref         text
);

CREATE TABLE quality.rule_config (                         -- FR-02: Nelson rules per characteristic; {1,2,3,5,6} cannot be disabled
    characteristic_id  uuid PRIMARY KEY REFERENCES quality.characteristic(id) ON DELETE CASCADE,
    enabled_rules      smallint[] NOT NULL DEFAULT '{1,2,3,5,6}',
    updated_by         uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT rules_minimum_set CHECK (enabled_rules @> '{1,2,3,5,6}'::smallint[]),
    CONSTRAINT rules_valid       CHECK (enabled_rules <@ '{1,2,3,4,5,6,7,8}'::smallint[])
);

CREATE TABLE quality.trial_run (                           -- FR-11: declared trials suppress signals
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    line_id      uuid REFERENCES core.line(id) ON DELETE CASCADE,
    sku_id       uuid REFERENCES core.sku(id) ON DELETE CASCADE,
    ts_from      timestamptz NOT NULL,
    ts_to        timestamptz NOT NULL,
    reason       text NOT NULL,
    declared_by  uuid NOT NULL REFERENCES core.app_user(id) ON DELETE RESTRICT,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT trial_window CHECK (ts_to > ts_from)
);

CREATE TABLE quality.ranking_config (                      -- FR-10 / FR-11
    id             smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version        text NOT NULL UNIQUE,
    weights_json   jsonb NOT NULL,                         -- {impact, criticality, volume, slope} — must sum to 1 (loader + CHECK below)
    min_sample     integer NOT NULL CHECK (min_sample >= 30),
    baseline_days  smallint[] NOT NULL DEFAULT '{7,30}',
    active         boolean NOT NULL DEFAULT false,
    set_by         uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    set_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT weights_sum_one CHECK (abs(((weights_json->>'impact')::numeric + (weights_json->>'criticality')::numeric + (weights_json->>'volume')::numeric + (weights_json->>'slope')::numeric) - 1) < 0.0001)
);
CREATE UNIQUE INDEX ux_ranking_active ON quality.ranking_config (active) WHERE active;

CREATE TABLE quality.fmea_config (                         -- C-05
    id             smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    standard       quality.fmea_standard NOT NULL,
    ap_table_json  jsonb NOT NULL DEFAULT '{}',            -- AIAG-VDA AP lookup (S,O,D) → H/M/L
    active         boolean NOT NULL DEFAULT false,
    set_by         uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    set_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_fmea_config_active ON quality.fmea_config (active) WHERE active;

CREATE TABLE quality.sod_criteria (                        -- AI-07: the organisation's S/O/D criteria tables
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    standard      quality.fmea_standard NOT NULL,
    dimension     char(1) NOT NULL CHECK (dimension IN ('S', 'O', 'D')),
    rating        smallint NOT NULL CHECK (rating BETWEEN 1 AND 10),
    criteria_text text NOT NULL,
    UNIQUE (standard, dimension, rating)
);

CREATE TABLE quality.prompt_template (                     -- AI-03: versioned in git; registered here with checksum
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind         quality.artifact_kind NOT NULL,
    lang         core.language_code NOT NULL,
    version      text NOT NULL,
    path         text NOT NULL,                            -- deploy/prompts/<kind>.<lang>.<version>.md
    checksum     text NOT NULL,
    temperature  numeric(3,2) NOT NULL DEFAULT 0.2 CHECK (temperature BETWEEN 0 AND 0.3),
    active       boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (kind, lang, version)
);
CREATE UNIQUE INDEX ux_prompt_active ON quality.prompt_template (kind, lang) WHERE active;

CREATE TABLE quality.migration (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    notes       text
);

-- =====================================================================
-- 11. QE-AGENT EXTENSION — analysis objects: change points, correlations, EVIDENCE, hypotheses links
-- =====================================================================
ALTER TABLE quality.signal
    ADD COLUMN score              numeric(6,4) CHECK (score BETWEEN 0 AND 1),   -- FR-10 ranking score
    ADD COLUMN rank_components    jsonb NOT NULL DEFAULT '{}',
    ADD COLUMN suppressed_reason  text,                                          -- FR-11
    ADD COLUMN defect_code        text,
    ADD COLUMN owner_id           uuid REFERENCES core.app_user(id) ON DELETE SET NULL;

CREATE TABLE quality.analysis_run (                        -- AI-08: full or statistics-only
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id       uuid REFERENCES quality.case(id) ON DELETE CASCADE,
    signal_id     uuid REFERENCES quality.signal(id) ON DELETE SET NULL,
    mode          text NOT NULL CHECK (mode IN ('full', 'statistics_only')),
    llm_available boolean NOT NULL,
    model_version text,                                    -- drafting model tag (the platform's artifact.model_id targets the vision registry, not an LLM)
    prompt_version text,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    duration_ms   integer,
    tests_run     integer NOT NULL DEFAULT 0,
    hypotheses    integer NOT NULL DEFAULT 0,
    artifacts     integer NOT NULL DEFAULT 0,
    CONSTRAINT mode_matches_llm CHECK ((mode = 'full') = llm_available)
);

CREATE TABLE quality.change_point (                        -- FR-09
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    signal_id       uuid NOT NULL REFERENCES quality.signal(id) ON DELETE CASCADE,
    estimated_ts    timestamptz NOT NULL,
    window_minutes  integer NOT NULL CHECK (window_minutes >= 0),
    method          text NOT NULL CHECK (method IN ('cusum', 'binary_segmentation', 'cusum+binseg')),
    statistic_json  jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE quality.correlation_test (                    -- FR-13 / FR-14
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    signal_id       uuid REFERENCES quality.signal(id) ON DELETE CASCADE,
    case_id         uuid REFERENCES quality.case(id) ON DELETE CASCADE,
    run_id          uuid REFERENCES quality.analysis_run(id) ON DELETE SET NULL,
    factor          quality.factor_kind NOT NULL,
    level           text,                                  -- the level tested, e.g. LOT-2609-114, M-12, B
    test            text NOT NULL CHECK (test IN ('chi_square', 'fisher_exact', 'two_proportion', 'rate_ratio')),
    statistic       numeric(14,6),
    p_value         numeric(12,10) NOT NULL CHECK (p_value BETWEEN 0 AND 1),
    p_adjusted      numeric(12,10) CHECK (p_adjusted BETWEEN 0 AND 1),          -- Benjamini–Hochberg across the factor scan
    effect_measure  text NOT NULL CHECK (effect_measure IN ('risk_ratio', 'rate_ratio', 'cramers_v', 'odds_ratio')),
    effect_size     numeric(12,6) NOT NULL,
    ci_low          numeric(12,6),
    ci_high         numeric(12,6),
    n               integer NOT NULL CHECK (n > 0),
    table_json      jsonb NOT NULL,                        -- the contingency table / counts
    meaningful      boolean NOT NULL,                      -- FR-18: false = "no meaningful association"
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE quality.evidence (                            -- FR-23 / AI-04: THE EVIDENCE REGISTRY (ADR-Q02)
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id       uuid REFERENCES quality.case(id) ON DELETE CASCADE,
    signal_id     uuid REFERENCES quality.signal(id) ON DELETE CASCADE,
    code          text NOT NULL,                           -- E-01 … within a case
    kind          quality.evidence_kind NOT NULL,
    value_json    jsonb NOT NULL,                          -- the numbers the model may quote, and nothing else
    source_query  text,                                    -- SQL / engine call that produced it
    source_ref    text,                                    -- chart uri, correlation_test id, case_record id, chunk id
    digest        text NOT NULL,                           -- sha256 of value_json, canonical
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (case_id, code),
    CONSTRAINT evidence_has_scope CHECK (case_id IS NOT NULL OR signal_id IS NOT NULL)
);
COMMENT ON TABLE quality.evidence IS 'Every value an artefact may cite. The facts object (ICD-09 IF-51) is assembled from these rows only; a claim without an evidence id cannot be approved (AI-04).';

ALTER TABLE quality.hypothesis
    ADD COLUMN rank            smallint CHECK (rank >= 1),
    ADD COLUMN run_id          uuid REFERENCES quality.analysis_run(id) ON DELETE SET NULL,
    ADD COLUMN effect_size     numeric(12,6),
    ADD COLUMN p_adjusted      numeric(12,10),
    ADD COLUMN factor          quality.factor_kind,
    ADD COLUMN level           text,
    ADD COLUMN verified_by     uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    ADD COLUMN verified_at     timestamptz,
    ADD COLUMN verify_result   text;

CREATE TABLE quality.hypothesis_evidence (                 -- FR-17: supporting / contra / verify links
    hypothesis_id  uuid NOT NULL REFERENCES quality.hypothesis(id) ON DELETE CASCADE,
    evidence_id    uuid NOT NULL REFERENCES quality.evidence(id) ON DELETE CASCADE,
    role           text NOT NULL CHECK (role IN ('supporting', 'contra', 'verify')),
    PRIMARY KEY (hypothesis_id, evidence_id, role)
);

-- =====================================================================
-- 12. QE-AGENT EXTENSION — artefacts: claims, revisions, exports, term checks, FMEA proposals, OCAP
-- =====================================================================
ALTER TABLE quality.artifact
    ADD COLUMN grounding_status  quality.grounding_status NOT NULL DEFAULT 'pending',
    ADD COLUMN claims_total      integer NOT NULL DEFAULT 0,
    ADD COLUMN claims_untraced   integer NOT NULL DEFAULT 0,
    ADD COLUMN term_violations   integer NOT NULL DEFAULT 0,
    ADD COLUMN facts_digest      text,                     -- sha256 of the facts object given to the model (IF-51)
    ADD COLUMN revision          integer NOT NULL DEFAULT 1 CHECK (revision >= 1),
    ADD COLUMN run_id            uuid REFERENCES quality.analysis_run(id) ON DELETE SET NULL,
    ADD COLUMN prompt_template_id uuid REFERENCES quality.prompt_template(id) ON DELETE SET NULL;

CREATE TABLE quality.artifact_claim (                      -- AI-04 / AC-05: sentence-level trace (ADR-Q03)
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    artifact_id    uuid NOT NULL REFERENCES quality.artifact(id) ON DELETE CASCADE,
    ordinal        integer NOT NULL,
    section        text,                                   -- D4, 現象, why-3 …
    sentence       text NOT NULL,
    kind           quality.claim_kind NOT NULL,
    evidence_id    uuid REFERENCES quality.evidence(id) ON DELETE SET NULL,
    hypothesis_id  uuid REFERENCES quality.hypothesis(id) ON DELETE SET NULL,
    traced         boolean NOT NULL DEFAULT false,         -- set by trg_claim_check
    UNIQUE (artifact_id, ordinal)
);

CREATE TABLE quality.artifact_revision (                   -- FR-24: engineer edits with diff against the AI version
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    artifact_id   uuid NOT NULL REFERENCES quality.artifact(id) ON DELETE CASCADE,
    revision      integer NOT NULL CHECK (revision >= 1),
    content_json  jsonb NOT NULL,
    diff_json     jsonb NOT NULL DEFAULT '[]',
    edited_by     uuid REFERENCES core.app_user(id) ON DELETE SET NULL,   -- NULL = the AI version (revision 1)
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (artifact_id, revision)
);

CREATE TABLE quality.export (                              -- FR-25 / NFR-06 / AC-06 (ADR-Q08)
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    artifact_id        uuid NOT NULL REFERENCES quality.artifact(id) ON DELETE CASCADE,
    format             text NOT NULL CHECK (format IN ('docx', 'xlsx', 'pdf')),
    template           text NOT NULL,                      -- company template id per kind × lang (IF-50)
    uri                text NOT NULL,
    sha256             text NOT NULL,
    watermark          text NOT NULL CHECK (watermark IN ('DRAFT — AI generated', 'APPROVED')),
    version_stamp      text NOT NULL,                      -- v<version>.<revision>
    approved_by_stamp  uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    exported_by        uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE quality.term_check (                          -- AI-06 / AC-07: glossary consistency on JA (and TH) output
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    artifact_id    uuid NOT NULL REFERENCES quality.artifact(id) ON DELETE CASCADE,
    term_id        uuid REFERENCES knowledge.glossary_term(id) ON DELETE SET NULL,
    found_text     text NOT NULL,
    expected_text  text NOT NULL,
    position       integer,
    resolved       boolean NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE quality.fmea_proposal (                       -- FR-21 / AI-07 (ADR-Q07): rows proposed with per-rating justification and confirmation
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id          uuid NOT NULL REFERENCES quality.case(id) ON DELETE CASCADE,
    artifact_id      uuid REFERENCES quality.artifact(id) ON DELETE SET NULL,
    sku_id           uuid REFERENCES core.sku(id) ON DELETE CASCADE,
    process_step     text NOT NULL,
    failure_mode     text NOT NULL,
    effect           text,
    cause            text,
    control_prev     text,
    control_det      text,
    s                smallint NOT NULL CHECK (s BETWEEN 1 AND 10),
    o                smallint NOT NULL CHECK (o BETWEEN 1 AND 10),
    d                smallint NOT NULL CHECK (d BETWEEN 1 AND 10),
    s_criteria_id    uuid NOT NULL REFERENCES quality.sod_criteria(id),
    o_criteria_id    uuid NOT NULL REFERENCES quality.sod_criteria(id),
    d_criteria_id    uuid NOT NULL REFERENCES quality.sod_criteria(id),
    s_evidence_id    uuid REFERENCES quality.evidence(id) ON DELETE SET NULL,
    o_evidence_id    uuid REFERENCES quality.evidence(id) ON DELETE SET NULL,
    d_evidence_id    uuid REFERENCES quality.evidence(id) ON DELETE SET NULL,
    s_confirmed_by   uuid REFERENCES core.app_user(id) ON DELETE RESTRICT,
    o_confirmed_by   uuid REFERENCES core.app_user(id) ON DELETE RESTRICT,
    d_confirmed_by   uuid REFERENCES core.app_user(id) ON DELETE RESTRICT,
    ap               text CHECK (ap IS NULL OR ap IN ('H', 'M', 'L')),
    status           text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'confirmed', 'rejected')),
    fmea_row_id      uuid REFERENCES quality.fmea_row(id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    decided_at       timestamptz
);

CREATE TABLE quality.ocap_suggestion (                     -- FR-22
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id            uuid NOT NULL REFERENCES quality.case(id) ON DELETE CASCADE,
    characteristic_id  uuid REFERENCES quality.characteristic(id) ON DELETE SET NULL,
    suggestion         text NOT NULL,
    evidence_id        uuid REFERENCES quality.evidence(id) ON DELETE SET NULL,
    status             text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'accepted', 'rejected')),
    decided_by         uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    decided_at         timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 13. QE-AGENT EXTENSION — case management: effectiveness, horizontal deployment, escalation, golden set
-- =====================================================================
CREATE TABLE quality.effectiveness_check (                 -- FR-28 / AC-08
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    action_id     uuid NOT NULL REFERENCES quality.action(id) ON DELETE CASCADE,
    before_from   timestamptz NOT NULL,
    before_to     timestamptz NOT NULL,
    before_x      integer NOT NULL CHECK (before_x >= 0),
    before_n      integer NOT NULL CHECK (before_n > 0),
    after_from    timestamptz NOT NULL,
    after_to      timestamptz NOT NULL,
    after_x       integer NOT NULL CHECK (after_x >= 0),
    after_n       integer NOT NULL CHECK (after_n > 0),
    test          text NOT NULL DEFAULT 'two_proportion_z' CHECK (test IN ('two_proportion_z', 'fisher_exact')),
    z             numeric(10,4),
    p_value       numeric(12,10) NOT NULL CHECK (p_value BETWEEN 0 AND 1),
    rate_before   numeric(8,6) NOT NULL,
    rate_after    numeric(8,6) NOT NULL,
    improved      boolean NOT NULL,                        -- p < 0.05 AND rate_after < rate_before
    computed_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT windows_ordered CHECK (before_to <= after_from)
);

CREATE TABLE quality.horizontal_candidate (                -- FR-30
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    case_id      uuid NOT NULL REFERENCES quality.case(id) ON DELETE CASCADE,
    target_kind  text NOT NULL CHECK (target_kind IN ('line', 'sku', 'mould')),
    target_id    uuid,
    target_code  text NOT NULL,
    reason       text NOT NULL,
    status       text NOT NULL DEFAULT 'suggested' CHECK (status IN ('suggested', 'accepted', 'dismissed')),
    decided_by   uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (case_id, target_kind, target_code)
);

CREATE TABLE quality.escalation (                          -- FR-12 / FR-31
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id      uuid REFERENCES quality.case(id) ON DELETE CASCADE,
    action_id    uuid REFERENCES quality.action(id) ON DELETE CASCADE,
    signal_id    uuid REFERENCES quality.signal(id) ON DELETE CASCADE,
    kind         text NOT NULL CHECK (kind IN ('high_signal', 'overdue_action', 'grounding_failed', 'case_opened')),
    channel      text NOT NULL CHECK (channel IN ('discord', 'email', 'in_app')),
    recipient    text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    sent_at      timestamptz,
    error        text
);

CREATE TABLE quality.golden_incident (                     -- AI-05
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code             text NOT NULL UNIQUE,                 -- G-01 …
    title            text NOT NULL,
    true_cause       text NOT NULL,
    true_factor      quality.factor_kind,
    scope_json       jsonb NOT NULL DEFAULT '{}',
    quality_case_id  uuid REFERENCES quality.case(id) ON DELETE SET NULL,
    added_by         uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    added_at         timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE quality.golden_run (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ran_at           timestamptz NOT NULL DEFAULT now(),
    model_version    text NOT NULL,
    prompt_version   text NOT NULL,
    ranking_version  text NOT NULL,
    n                integer NOT NULL CHECK (n >= 20),     -- AI-05: ≥ 20 incidents
    top3_hits        integer NOT NULL CHECK (top3_hits >= 0),
    top1_hits        integer NOT NULL CHECK (top1_hits >= 0),
    fabricated       integer NOT NULL CHECK (fabricated >= 0),
    top3_rate        numeric(5,4),
    release_blocked  boolean NOT NULL DEFAULT false,
    block_reason     text,
    notes            text,
    CONSTRAINT hits_le_n CHECK (top3_hits <= n AND top1_hits <= top3_hits)
);
CREATE TABLE quality.golden_result (
    run_id              uuid NOT NULL REFERENCES quality.golden_run(id) ON DELETE CASCADE,
    incident_id         uuid NOT NULL REFERENCES quality.golden_incident(id) ON DELETE CASCADE,
    rank_of_true_cause  smallint CHECK (rank_of_true_cause >= 1),   -- NULL = not in the list
    fabricated_claims   integer NOT NULL DEFAULT 0,
    PRIMARY KEY (run_id, incident_id)
);

-- =====================================================================
-- 14. FUNCTIONS — SQL twins of the closed-form statistics (verification, ADR-Q01 / P-6) and helpers
-- =====================================================================
-- Shewhart constants (ASTM E2587 / Montgomery Appendix VI) for subgroup sizes 2..10
CREATE OR REPLACE FUNCTION quality.spc_constant(p_n integer, p_name text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_name
        WHEN 'A2' THEN (ARRAY[1.880, 1.023, 0.729, 0.577, 0.483, 0.419, 0.373, 0.337, 0.308])[p_n - 1]
        WHEN 'D3' THEN (ARRAY[0.000, 0.000, 0.000, 0.000, 0.000, 0.076, 0.136, 0.184, 0.223])[p_n - 1]
        WHEN 'D4' THEN (ARRAY[3.267, 2.574, 2.282, 2.114, 2.004, 1.924, 1.864, 1.816, 1.777])[p_n - 1]
        WHEN 'd2' THEN (ARRAY[1.128, 1.693, 2.059, 2.326, 2.534, 2.704, 2.847, 2.970, 3.078])[p_n - 1]
    END::numeric;
$$;

-- X̄-R limits (FR-01): UCLx = X̿ + A2·R̄, LCLx = X̿ − A2·R̄, UCLr = D4·R̄, LCLr = D3·R̄
CREATE OR REPLACE FUNCTION quality.xbar_r_limits(p_xbarbar numeric, p_rbar numeric, p_n integer)
RETURNS TABLE (ucl_x numeric, cl_x numeric, lcl_x numeric, ucl_r numeric, cl_r numeric, lcl_r numeric, sigma_within numeric) LANGUAGE sql IMMUTABLE AS $$
    SELECT round(p_xbarbar + quality.spc_constant(p_n, 'A2') * p_rbar, 6), round(p_xbarbar, 6), round(p_xbarbar - quality.spc_constant(p_n, 'A2') * p_rbar, 6),
           round(quality.spc_constant(p_n, 'D4') * p_rbar, 6), round(p_rbar, 6), round(quality.spc_constant(p_n, 'D3') * p_rbar, 6),
           round(p_rbar / quality.spc_constant(p_n, 'd2'), 6);
$$;

-- p-chart limits (FR-01): p̄ ± 3·sqrt(p̄(1−p̄)/n), clamped to [0, 1]
CREATE OR REPLACE FUNCTION quality.p_limits(p_pbar numeric, p_n integer)
RETURNS TABLE (ucl numeric, cl numeric, lcl numeric) LANGUAGE sql IMMUTABLE AS $$
    SELECT round(LEAST(1, p_pbar + 3 * sqrt(p_pbar * (1 - p_pbar) / p_n)), 6), round(p_pbar, 6), round(GREATEST(0, p_pbar - 3 * sqrt(p_pbar * (1 - p_pbar) / p_n)), 6);
$$;

-- Capability (FR-04): Cp/Cpk from within-subgroup sigma (R̄/d2), Pp/Ppk from overall sigma
CREATE OR REPLACE FUNCTION quality.capability_indices(p_mean numeric, p_sd_within numeric, p_sd_overall numeric, p_usl numeric, p_lsl numeric)
RETURNS TABLE (cp numeric, cpk numeric, pp numeric, ppk numeric) LANGUAGE sql IMMUTABLE AS $$
    SELECT round((p_usl - p_lsl) / (6 * p_sd_within), 4),
           round(LEAST((p_usl - p_mean) / (3 * p_sd_within), (p_mean - p_lsl) / (3 * p_sd_within)), 4),
           round((p_usl - p_lsl) / (6 * p_sd_overall), 4),
           round(LEAST((p_usl - p_mean) / (3 * p_sd_overall), (p_mean - p_lsl) / (3 * p_sd_overall)), 4);
$$;

-- Standard normal upper tail via erfc (Abramowitz–Stegun 7.1.26, |error| < 1.5e-7). Good enough for p-values in this twin; the engine uses scipy.
CREATE OR REPLACE FUNCTION quality.norm_sf(p_z double precision) RETURNS double precision LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE x double precision := abs(p_z) / sqrt(2.0); t double precision; y double precision;
BEGIN
    t := 1.0 / (1.0 + 0.3275911 * x);
    y := 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
    -- y = erf(x); upper tail = erfc(x)/2
    RETURN CASE WHEN p_z >= 0 THEN (1.0 - y) / 2.0 ELSE 1.0 - (1.0 - y) / 2.0 END;
END $$;

-- Two-proportion z-test with continuity correction, two-sided (FR-08, FR-28)
CREATE OR REPLACE FUNCTION quality.two_proportion_z(p_x1 integer, p_n1 integer, p_x2 integer, p_n2 integer, p_continuity boolean DEFAULT true)
RETURNS TABLE (p1 numeric, p2 numeric, z numeric, p_value numeric) LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE pp double precision; se double precision; diff double precision; zz double precision;
BEGIN
    pp := (p_x1 + p_x2)::double precision / (p_n1 + p_n2);
    se := sqrt(pp * (1 - pp) * (1.0 / p_n1 + 1.0 / p_n2));
    diff := p_x1::double precision / p_n1 - p_x2::double precision / p_n2;
    IF p_continuity THEN diff := sign(diff) * GREATEST(0, abs(diff) - 0.5 * (1.0 / p_n1 + 1.0 / p_n2)); END IF;
    zz := CASE WHEN se = 0 THEN 0 ELSE diff / se END;
    RETURN QUERY SELECT round((p_x1::numeric / p_n1), 6), round((p_x2::numeric / p_n2), 6), round(zz::numeric, 4), round((2 * quality.norm_sf(abs(zz)))::numeric, 10);
END $$;

-- Nelson rules 1, 2, 3, 5, 6 over a series (FR-02) — the SQL twin used by the seed and by TC-022. Points are 1-based indexes.
CREATE OR REPLACE FUNCTION quality.nelson_rules(p_values numeric[], p_cl numeric, p_sigma numeric)
RETURNS TABLE (rule smallint, points integer[]) LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE n integer := array_length(p_values, 1); i integer; k integer; cnt integer; side integer;
        r1 integer[] := '{}'; r2 integer[] := '{}'; r3 integer[] := '{}'; r5 integer[] := '{}'; r6 integer[] := '{}';
BEGIN
    FOR i IN 1..n LOOP
        IF abs(p_values[i] - p_cl) > 3 * p_sigma THEN r1 := r1 || i; END IF;                                   -- rule 1: beyond 3σ
        IF i >= 9 THEN                                                                                          -- rule 2: 9 in a row same side
            side := sign(p_values[i] - p_cl); cnt := 0;
            FOR k IN i-8..i LOOP IF sign(p_values[k] - p_cl) = side AND side <> 0 THEN cnt := cnt + 1; END IF; END LOOP;
            IF cnt = 9 THEN FOR k IN i-8..i LOOP IF NOT (k = ANY (r2)) THEN r2 := r2 || k; END IF; END LOOP; END IF;
        END IF;
        IF i >= 6 THEN                                                                                          -- rule 3: 6 in a row steadily up or down
            cnt := 0; FOR k IN i-4..i LOOP IF p_values[k] > p_values[k-1] THEN cnt := cnt + 1; END IF; END LOOP;
            IF cnt = 5 THEN FOR k IN i-5..i LOOP IF NOT (k = ANY (r3)) THEN r3 := r3 || k; END IF; END LOOP; END IF;
            cnt := 0; FOR k IN i-4..i LOOP IF p_values[k] < p_values[k-1] THEN cnt := cnt + 1; END IF; END LOOP;
            IF cnt = 5 THEN FOR k IN i-5..i LOOP IF NOT (k = ANY (r3)) THEN r3 := r3 || k; END IF; END LOOP; END IF;
        END IF;
        IF i >= 3 THEN                                                                                          -- rule 5: 2 of 3 beyond 2σ same side
            FOREACH side IN ARRAY ARRAY[1, -1] LOOP
                cnt := 0; FOR k IN i-2..i LOOP IF side * (p_values[k] - p_cl) > 2 * p_sigma THEN cnt := cnt + 1; END IF; END LOOP;
                IF cnt >= 2 THEN FOR k IN i-2..i LOOP IF side * (p_values[k] - p_cl) > 2 * p_sigma AND NOT (k = ANY (r5)) THEN r5 := r5 || k; END IF; END LOOP; END IF;
            END LOOP;
        END IF;
        IF i >= 5 THEN                                                                                          -- rule 6: 4 of 5 beyond 1σ same side
            FOREACH side IN ARRAY ARRAY[1, -1] LOOP
                cnt := 0; FOR k IN i-4..i LOOP IF side * (p_values[k] - p_cl) > p_sigma THEN cnt := cnt + 1; END IF; END LOOP;
                IF cnt >= 4 THEN FOR k IN i-4..i LOOP IF side * (p_values[k] - p_cl) > p_sigma AND NOT (k = ANY (r6)) THEN r6 := r6 || k; END IF; END LOOP; END IF;
            END LOOP;
        END IF;
    END LOOP;
    IF array_length(r1, 1) > 0 THEN rule := 1; points := r1; RETURN NEXT; END IF;
    IF array_length(r2, 1) > 0 THEN rule := 2; points := r2; RETURN NEXT; END IF;
    IF array_length(r3, 1) > 0 THEN rule := 3; points := r3; RETURN NEXT; END IF;
    IF array_length(r5, 1) > 0 THEN rule := 5; points := r5; RETURN NEXT; END IF;
    IF array_length(r6, 1) > 0 THEN rule := 6; points := r6; RETURN NEXT; END IF;
END $$;

-- FR-10: ranking score from the active weights
CREATE OR REPLACE FUNCTION quality.ranking_score(p_impact numeric, p_criticality numeric, p_volume numeric, p_slope numeric)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT round(LEAST(1, GREATEST(0,
        (w->>'impact')::numeric * p_impact + (w->>'criticality')::numeric * p_criticality + (w->>'volume')::numeric * p_volume + (w->>'slope')::numeric * p_slope)), 4)
      FROM (SELECT weights_json w FROM quality.ranking_config WHERE active) c;
$$;

CREATE OR REPLACE FUNCTION quality.role_rank(p_role text) RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_role WHEN 'viewer' THEN 0 WHEN 'inspector' THEN 1 WHEN 'engineer' THEN 2 WHEN 'manager' THEN 3 WHEN 'admin' THEN 4 ELSE -1 END::smallint;
$$;

CREATE OR REPLACE FUNCTION quality.artifact_is_draft(p_artifact uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT approved_by IS NULL FROM quality.artifact WHERE id = p_artifact;
$$;

-- FR-30: horizontal-deployment candidates — other lines measuring the same SKU's characteristics; other SKUs sharing a characteristic name
CREATE OR REPLACE FUNCTION quality.suggest_horizontal(p_case uuid) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c quality.case; n integer := 0;
BEGIN
    SELECT * INTO c FROM quality.case WHERE id = p_case;
    INSERT INTO quality.horizontal_candidate (case_id, target_kind, target_id, target_code, reason)
    SELECT DISTINCT p_case, 'line', l.id, l.code, 'same SKU produced on another line'
      FROM quality.measurement m JOIN quality.characteristic ch ON ch.id = m.characteristic_id JOIN core.line l ON l.id = m.line_id
     WHERE ch.sku_id = c.sku_id AND m.line_id IS DISTINCT FROM c.line_id
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO quality.horizontal_candidate (case_id, target_kind, target_id, target_code, reason)
    SELECT DISTINCT p_case, 'sku', s.id, s.code, 'shares characteristic "' || ch2.name || '" with the case SKU'
      FROM quality.characteristic ch1 JOIN quality.characteristic ch2 ON ch2.name = ch1.name AND ch2.sku_id <> ch1.sku_id
      JOIN core.sku s ON s.id = ch2.sku_id
     WHERE ch1.sku_id = c.sku_id
    ON CONFLICT DO NOTHING;
    RETURN n;
END $$;

-- =====================================================================
-- 15. TRIGGERS — the guards (DDS-09 DD-Q01..Q09)
-- =====================================================================

-- DD-Q05 (FR-06): limits are history — a new active row deactivates the previous one; rows are never updated except to deactivate
CREATE OR REPLACE FUNCTION quality.trg_limits_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.active THEN
            UPDATE quality.control_limits SET active = false WHERE characteristic_id = NEW.characteristic_id AND line_id IS NOT DISTINCT FROM NEW.line_id AND active AND id <> NEW.id;
        END IF;
        INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
        VALUES (NEW.created_by, 'spc-engine', 'quality.limits_recalculated', 'characteristic', NEW.characteristic_id::text,
                jsonb_build_object('ucl', NEW.ucl, 'cl', NEW.cl, 'lcl', NEW.lcl, 'baseline_from', NEW.baseline_from, 'baseline_to', NEW.baseline_to, 'n', NEW.sample_size, 'reason', NEW.reason));
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'LIMITS_APPEND_ONLY: control limits are history and cannot be deleted (FR-06)'; END IF;
    IF NEW.ucl <> OLD.ucl OR NEW.cl <> OLD.cl OR NEW.lcl <> OLD.lcl OR NEW.baseline_from <> OLD.baseline_from OR NEW.baseline_to <> OLD.baseline_to OR NEW.reason <> OLD.reason THEN
        RAISE EXCEPTION 'LIMITS_APPEND_ONLY: insert a new limit row with a reason instead of editing (FR-06)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_limits_append_only BEFORE INSERT OR UPDATE OR DELETE ON quality.control_limits
    FOR EACH ROW EXECUTE FUNCTION quality.trg_limits_append_only();

-- DD-Q04 (C-03): non-normal capability needs a method note
CREATE OR REPLACE FUNCTION quality.trg_capability_note() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.normality_ok AND (NEW.method_note IS NULL OR length(trim(NEW.method_note)) < 10) THEN
        RAISE EXCEPTION 'CAPABILITY_METHOD_NOTE: normality failed — a transformation or non-normal method must be stated (C-03, FR-05)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_capability_note BEFORE INSERT OR UPDATE ON quality.capability_result
    FOR EACH ROW EXECUTE FUNCTION quality.trg_capability_note();

-- DD-Q06 (C-04, FR-17): hypotheses are hypotheses until confirmed; a verification step is mandatory
CREATE OR REPLACE FUNCTION quality.trg_hypothesis_wording() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'confirmed' AND NEW.statement ~* '(caused by|root cause is|is the cause|is due to|was due to|because of|原因は|สาเหตุคือ)' THEN
        RAISE EXCEPTION 'CAUSAL_WORDING: "%" states a cause; unverified items are hypotheses to verify (C-04)', left(NEW.statement, 60);
    END IF;
    IF NEW.verify_step IS NULL OR length(trim(NEW.verify_step)) < 5 THEN
        RAISE EXCEPTION 'VERIFY_STEP_REQUIRED: every hypothesis needs a proposed verification step (FR-17)';
    END IF;
    IF NEW.status = 'confirmed' AND (NEW.verified_by IS NULL OR NEW.verified_at IS NULL) THEN
        RAISE EXCEPTION 'CONFIRM_NEEDS_VERIFIER: a confirmed hypothesis records who verified it and when';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_hypothesis_wording BEFORE INSERT OR UPDATE ON quality.hypothesis
    FOR EACH ROW EXECUTE FUNCTION quality.trg_hypothesis_wording();

-- DD-Q07 (FR-11): signals below the minimum sample or inside a declared trial are suppressed on insert
CREATE OR REPLACE FUNCTION quality.trg_signal_admissible() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE minn integer; nn integer; tr uuid;
BEGIN
    SELECT min_sample INTO minn FROM quality.ranking_config WHERE active;
    nn := COALESCE((NEW.statistic_json->>'n')::integer, 0);
    IF minn IS NOT NULL AND nn < minn THEN
        NEW.status := 'dismissed'; NEW.suppressed_reason := format('below minimum sample (%s < %s)', nn, minn);
    END IF;
    SELECT id INTO tr FROM quality.trial_run t
     WHERE (t.line_id IS NULL OR t.line_id = NEW.line_id) AND (t.sku_id IS NULL OR t.sku_id = NEW.sku_id) AND NEW.opened_at BETWEEN t.ts_from AND t.ts_to LIMIT 1;
    IF tr IS NOT NULL THEN NEW.status := 'dismissed'; NEW.suppressed_reason := 'inside declared trial run ' || tr; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_signal_admissible BEFORE INSERT ON quality.signal
    FOR EACH ROW EXECUTE FUNCTION quality.trg_signal_admissible();

-- DD-Q01 (AI-04): a claim is traced when its number points at evidence, or its causal statement at a CONFIRMED hypothesis
CREATE OR REPLACE FUNCTION quality.trg_claim_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE hs text;
BEGIN
    IF NEW.kind IN ('numeric', 'date', 'count') THEN
        NEW.traced := NEW.evidence_id IS NOT NULL;
    ELSIF NEW.kind = 'causal' THEN
        SELECT status INTO hs FROM quality.hypothesis WHERE id = NEW.hypothesis_id;
        NEW.traced := (hs = 'confirmed');
    ELSE
        NEW.traced := true;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_claim_check BEFORE INSERT OR UPDATE ON quality.artifact_claim
    FOR EACH ROW EXECUTE FUNCTION quality.trg_claim_check();

CREATE OR REPLACE FUNCTION quality.trg_claim_rollup() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE a uuid := COALESCE(NEW.artifact_id, OLD.artifact_id); tot integer; unt integer;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE NOT traced) INTO tot, unt FROM quality.artifact_claim WHERE artifact_id = a;
    UPDATE quality.artifact SET claims_total = tot, claims_untraced = unt,
           grounding_status = CASE WHEN tot = 0 THEN 'pending'::quality.grounding_status WHEN unt = 0 THEN 'passed' ELSE 'failed' END
     WHERE id = a;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_claim_rollup AFTER INSERT OR UPDATE OR DELETE ON quality.artifact_claim
    FOR EACH ROW EXECUTE FUNCTION quality.trg_claim_rollup();

-- DD-Q02 (C-01, NFR-05, AI-04): approval needs role >= engineer and grounding passed; once approved, immutable; audited
CREATE OR REPLACE FUNCTION quality.trg_artifact_approval() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
    IF OLD.approved_by IS NOT NULL THEN
        IF NEW.approved_by IS DISTINCT FROM OLD.approved_by OR NEW.approved_at IS DISTINCT FROM OLD.approved_at OR NEW.content_json IS DISTINCT FROM OLD.content_json THEN
            RAISE EXCEPTION 'APPROVAL_IMMUTABLE: artifact % is approved; create a new version instead (NFR-05)', OLD.id;
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.approved_by IS NOT NULL THEN
        SELECT role INTO r FROM core.app_user WHERE id = NEW.approved_by AND active;
        IF r IS NULL OR quality.role_rank(r) < quality.role_rank('engineer') THEN
            RAISE EXCEPTION 'ROLE_INSUFFICIENT: only quality_engineer (engineer) and above may approve artefacts (NFR-05)';
        END IF;
        IF NEW.ai_generated AND NEW.grounding_status <> 'passed' THEN
            RAISE EXCEPTION 'GROUNDING_FAILED: artifact % has % untraced claim(s) of % — cannot be approved (AI-04)', NEW.id, NEW.claims_untraced, NEW.claims_total;
        END IF;
        IF NEW.term_violations > 0 THEN
            RAISE EXCEPTION 'TERM_CHECK: artifact % has % unresolved glossary violations (AI-06)', NEW.id, NEW.term_violations;
        END IF;
        NEW.approved_at := COALESCE(NEW.approved_at, now());
        INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
        VALUES (NEW.approved_by, r, 'quality.artifact_approved', 'artifact', NEW.id::text,
                jsonb_build_object('kind', NEW.kind, 'version', NEW.version, 'revision', NEW.revision, 'lang', NEW.lang, 'digest', encode(public.digest(NEW.content_json::text, 'sha256'), 'hex'), 'facts_digest', NEW.facts_digest));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_artifact_approval BEFORE UPDATE ON quality.artifact
    FOR EACH ROW EXECUTE FUNCTION quality.trg_artifact_approval();

-- DD-Q03 (C-01, AC-06, NFR-06): an export of a draft carries the DRAFT watermark; every export carries version and approver
CREATE OR REPLACE FUNCTION quality.trg_export_watermark() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE a quality.artifact;
BEGIN
    SELECT * INTO a FROM quality.artifact WHERE id = NEW.artifact_id;
    IF a.approved_by IS NULL THEN
        IF NEW.watermark <> 'DRAFT — AI generated' THEN RAISE EXCEPTION 'DRAFT_WATERMARK: artifact % is not approved; export must carry the DRAFT watermark (C-01, AC-06)', a.id; END IF;
        NEW.approved_by_stamp := NULL;
    ELSE
        IF NEW.watermark <> 'APPROVED' THEN RAISE EXCEPTION 'WATERMARK: approved artefacts export with the APPROVED stamp'; END IF;
        NEW.approved_by_stamp := a.approved_by;
    END IF;
    NEW.version_stamp := format('v%s.%s', a.version, a.revision);
    INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
    VALUES (NEW.exported_by, 'exporter', 'quality.artifact_exported', 'artifact', a.id::text, jsonb_build_object('format', NEW.format, 'watermark', NEW.watermark, 'version', NEW.version_stamp, 'sha256', NEW.sha256));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_export_watermark BEFORE INSERT ON quality.export
    FOR EACH ROW EXECUTE FUNCTION quality.trg_export_watermark();

-- revisions bump the artefact and refuse edits to approved content
CREATE OR REPLACE FUNCTION quality.trg_revision_apply() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT quality.artifact_is_draft(NEW.artifact_id) THEN RAISE EXCEPTION 'APPROVAL_IMMUTABLE: approved artefacts are not edited; create a new version (NFR-05)'; END IF;
    UPDATE quality.artifact SET content_json = NEW.content_json, revision = NEW.revision WHERE id = NEW.artifact_id AND NEW.revision > revision;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_revision_apply AFTER INSERT ON quality.artifact_revision
    FOR EACH ROW EXECUTE FUNCTION quality.trg_revision_apply();

-- term violations roll up
CREATE OR REPLACE FUNCTION quality.trg_term_rollup() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE a uuid := COALESCE(NEW.artifact_id, OLD.artifact_id);
BEGIN
    UPDATE quality.artifact SET term_violations = (SELECT count(*) FROM quality.term_check WHERE artifact_id = a AND NOT resolved) WHERE id = a;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_term_rollup AFTER INSERT OR UPDATE OR DELETE ON quality.term_check
    FOR EACH ROW EXECUTE FUNCTION quality.trg_term_rollup();

-- DD-Q08 (AI-07, C-05): confirming a proposal needs every rating confirmed by an engineer against a criteria row of the active standard; then the fmea_row is written
CREATE OR REPLACE FUNCTION quality.trg_fmea_confirm() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE std quality.fmea_standard; apv text; rid uuid; u uuid;
BEGIN
    IF NEW.status = 'confirmed' AND OLD.status <> 'confirmed' THEN
        IF NEW.s_confirmed_by IS NULL OR NEW.o_confirmed_by IS NULL OR NEW.d_confirmed_by IS NULL THEN
            RAISE EXCEPTION 'RATINGS_NOT_CONFIRMED: S, O and D must each be confirmed by an engineer (AI-07)';
        END IF;
        FOREACH u IN ARRAY ARRAY[NEW.s_confirmed_by, NEW.o_confirmed_by, NEW.d_confirmed_by] LOOP
            IF quality.role_rank((SELECT role FROM core.app_user WHERE id = u)) < quality.role_rank('engineer') THEN RAISE EXCEPTION 'ROLE_INSUFFICIENT: ratings are confirmed by engineers'; END IF;
        END LOOP;
        SELECT standard, (ap_table_json->>(NEW.s::text || '-' || NEW.o::text || '-' || NEW.d::text)) INTO std, apv FROM quality.fmea_config WHERE active;
        IF NOT EXISTS (SELECT 1 FROM quality.sod_criteria WHERE id = NEW.s_criteria_id AND standard = std AND dimension = 'S' AND rating = NEW.s)
        OR NOT EXISTS (SELECT 1 FROM quality.sod_criteria WHERE id = NEW.o_criteria_id AND standard = std AND dimension = 'O' AND rating = NEW.o)
        OR NOT EXISTS (SELECT 1 FROM quality.sod_criteria WHERE id = NEW.d_criteria_id AND standard = std AND dimension = 'D' AND rating = NEW.d) THEN
            RAISE EXCEPTION 'CRITERIA_MISMATCH: each rating must reference the criteria row of the active standard (%) for its value (AI-07)', std;
        END IF;
        NEW.ap := CASE WHEN std = 'aiag_vda_ap' THEN COALESCE(apv, 'M') ELSE NULL END;
        INSERT INTO quality.fmea_row (sku_id, process_step, failure_mode, effect, cause, control_prev, control_det, s, o, d, ap, source_case_id, approved_by, approved_at)
        VALUES (NEW.sku_id, NEW.process_step, NEW.failure_mode, NEW.effect, NEW.cause, NEW.control_prev, NEW.control_det, NEW.s, NEW.o, NEW.d, NEW.ap, NEW.case_id, NEW.s_confirmed_by, now())
        RETURNING id INTO rid;
        NEW.fmea_row_id := rid; NEW.decided_at := now();
        INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
        VALUES (NEW.s_confirmed_by, 'engineer', 'quality.fmea_row_confirmed', 'fmea_row', rid::text, jsonb_build_object('s', NEW.s, 'o', NEW.o, 'd', NEW.d, 'ap', NEW.ap, 'case', NEW.case_id));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_fmea_confirm BEFORE UPDATE OF status ON quality.fmea_proposal
    FOR EACH ROW EXECUTE FUNCTION quality.trg_fmea_confirm();

-- DD-Q09 (FR-28): effectiveness → action; verified only on a significant improvement
CREATE OR REPLACE FUNCTION quality.trg_effectiveness_apply() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE quality.action SET effectiveness_json = jsonb_build_object('test', NEW.test, 'rate_before', NEW.rate_before, 'rate_after', NEW.rate_after, 'z', NEW.z, 'p_value', NEW.p_value,
                                                                     'before_n', NEW.before_n, 'after_n', NEW.after_n, 'improved', NEW.improved, 'check_id', NEW.id)
     WHERE id = NEW.action_id;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_effectiveness_apply AFTER INSERT ON quality.effectiveness_check
    FOR EACH ROW EXECUTE FUNCTION quality.trg_effectiveness_apply();

CREATE OR REPLACE FUNCTION quality.trg_action_verified() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'verified' AND (NEW.effectiveness_json IS NULL OR (NEW.effectiveness_json->>'improved')::boolean IS DISTINCT FROM true) THEN
        RAISE EXCEPTION 'NOT_EFFECTIVE: an action is verified only with a recorded significant improvement (FR-28)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_action_verified BEFORE UPDATE OF status ON quality.action
    FOR EACH ROW EXECUTE FUNCTION quality.trg_action_verified();

-- DD-Q09 (FR-29, FR-30): closure needs settled actions and a note; then the case is indexed and horizontal candidates suggested
CREATE OR REPLACE FUNCTION quality.trg_case_close() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cause text; act text; ver text; outcome text;
BEGIN
    IF NEW.status = 'closed' AND OLD.status <> 'closed' THEN
        IF EXISTS (SELECT 1 FROM quality.action WHERE case_id = NEW.id AND status IN ('open', 'in_progress')) THEN
            RAISE EXCEPTION 'ACTIONS_OPEN: case % has open actions (FR-27)', NEW.id;
        END IF;
        IF NEW.closure_note IS NULL OR length(trim(NEW.closure_note)) < 10 THEN RAISE EXCEPTION 'CLOSURE_NOTE_REQUIRED'; END IF;
        NEW.closed_at := COALESCE(NEW.closed_at, now());
        SELECT string_agg(statement, '; ') INTO cause FROM quality.hypothesis WHERE case_id = NEW.id AND status = 'confirmed';
        SELECT string_agg(description, '; ') INTO act FROM quality.action WHERE case_id = NEW.id AND status IN ('verified', 'done');
        SELECT string_agg(format('%s: %s%% → %s%% (p=%s)', a.kind, round(e.rate_before * 100, 2), round(e.rate_after * 100, 2), e.p_value), '; ') INTO ver
          FROM quality.action a JOIN quality.effectiveness_check e ON e.action_id = a.id WHERE a.case_id = NEW.id;
        outcome := CASE WHEN EXISTS (SELECT 1 FROM quality.action WHERE case_id = NEW.id AND status = 'verified') THEN 'resolved' ELSE 'not_resolved' END;
        INSERT INTO knowledge.case_record (title, opened_at, closed_at, scope_json, symptom_text, cause_text, action_text, verification_text, outcome, quality_case_id, verified_by, verified_at, extracted_by)
        VALUES (NEW.title, NEW.opened_at, NEW.closed_at, jsonb_build_object('line_id', NEW.line_id, 'sku_id', NEW.sku_id, 'machine_id', NEW.machine_id, 'severity', NEW.severity),
                (SELECT s.kind || ' ' || COALESCE(s.defect_code, '') FROM quality.signal s WHERE s.id = NEW.signal_id), cause, act, ver, outcome, NEW.id, NEW.owner_id, NEW.closed_at, 'qe-agent/closure');
        PERFORM quality.suggest_horizontal(NEW.id);
        INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
        VALUES (NEW.owner_id, 'owner', 'quality.case_closed', 'case', NEW.id::text, jsonb_build_object('outcome', outcome));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_case_close BEFORE UPDATE OF status ON quality.case
    FOR EACH ROW EXECUTE FUNCTION quality.trg_case_close();

-- AI-05: golden gate
CREATE OR REPLACE FUNCTION quality.trg_golden_gate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.top3_rate := round(NEW.top3_hits::numeric / NEW.n, 4);
    NEW.release_blocked := NEW.top3_rate < 0.60 OR NEW.fabricated > 0;
    NEW.block_reason := NULLIF(concat_ws('; ', CASE WHEN NEW.top3_rate < 0.60 THEN format('top-3 %.1f%% < 60%%', NEW.top3_rate * 100) END,
                                               CASE WHEN NEW.fabricated > 0 THEN format('%s fabricated evidence item(s)', NEW.fabricated) END), '');
    RETURN NEW;
END $$;
CREATE TRIGGER trg_golden_gate BEFORE INSERT OR UPDATE ON quality.golden_run
    FOR EACH ROW EXECUTE FUNCTION quality.trg_golden_gate();

-- =====================================================================
-- 16. INDEXES (extension)
-- =====================================================================
CREATE INDEX idx_measurement_char_ts    ON quality.measurement (characteristic_id, ts DESC);
CREATE INDEX idx_measurement_line_ts    ON quality.measurement (line_id, ts DESC);
CREATE INDEX idx_measurement_lot        ON quality.measurement (lot_id) WHERE lot_id IS NOT NULL;
CREATE INDEX idx_measurement_ts_brin    ON quality.measurement USING brin (ts);
CREATE INDEX idx_subgroup_char_seq      ON quality.subgroup (characteristic_id, line_id, seq);
CREATE INDEX idx_change_point_signal    ON quality.change_point (signal_id);
CREATE INDEX idx_correlation_case       ON quality.correlation_test (case_id, factor);
CREATE INDEX idx_evidence_case          ON quality.evidence (case_id, code);
CREATE INDEX idx_hypothesis_case_rank   ON quality.hypothesis (case_id, rank);
CREATE INDEX idx_claim_artifact         ON quality.artifact_claim (artifact_id, traced);
CREATE INDEX idx_export_artifact        ON quality.export (artifact_id, created_at DESC);
CREATE INDEX idx_effectiveness_action   ON quality.effectiveness_check (action_id);
CREATE INDEX idx_escalation_unsent      ON quality.escalation (created_at) WHERE sent_at IS NULL;
CREATE INDEX idx_fmea_proposal_case     ON quality.fmea_proposal (case_id, status);
CREATE INDEX idx_signal_score           ON quality.signal (score DESC) WHERE status = 'open';
CREATE INDEX idx_audit_log_ts           ON audit.log (ts DESC);
CREATE INDEX idx_audit_log_entity       ON audit.log (entity, entity_id, ts DESC);

-- =====================================================================
-- 17. VIEWS
-- =====================================================================
CREATE OR REPLACE VIEW quality.v_open_signals AS                       -- FR-10 ranked, FR-11 suppressed excluded
SELECT s.id, s.opened_at, s.kind, s.defect_code, l.code AS line_code, k.code AS sku_code, s.severity, s.score, s.rank_components, s.statistic_json,
       (SELECT cp.estimated_ts FROM quality.change_point cp WHERE cp.signal_id = s.id ORDER BY cp.created_at DESC LIMIT 1) AS change_point_ts,
       (SELECT c.id FROM quality.case c WHERE c.signal_id = s.id LIMIT 1) AS case_id
  FROM quality.signal s LEFT JOIN core.line l ON l.id = s.line_id LEFT JOIN core.sku k ON k.id = s.sku_id
 WHERE s.status IN ('open', 'triaged', 'case_opened')
 ORDER BY s.score DESC NULLS LAST, s.opened_at;

CREATE OR REPLACE VIEW quality.v_case_board AS
SELECT c.id, c.title, c.status, c.severity, l.code AS line_code, k.code AS sku_code, u.username AS owner, c.opened_at, c.closed_at,
       (SELECT count(*) FROM quality.hypothesis h WHERE h.case_id = c.id) AS hypotheses,
       (SELECT count(*) FROM quality.hypothesis h WHERE h.case_id = c.id AND h.status = 'confirmed') AS confirmed_hypotheses,
       (SELECT count(*) FROM quality.action a WHERE a.case_id = c.id AND a.status IN ('open', 'in_progress')) AS open_actions,
       (SELECT count(*) FROM quality.action a WHERE a.case_id = c.id AND a.status = 'verified') AS verified_actions,
       (SELECT count(*) FROM quality.artifact ar WHERE ar.case_id = c.id AND ar.approved_by IS NULL) AS draft_artifacts,
       (SELECT count(*) FROM quality.artifact ar WHERE ar.case_id = c.id AND ar.approved_by IS NOT NULL) AS approved_artifacts
  FROM quality.case c LEFT JOIN core.line l ON l.id = c.line_id LEFT JOIN core.sku k ON k.id = c.sku_id LEFT JOIN core.app_user u ON u.id = c.owner_id;

CREATE OR REPLACE VIEW quality.v_evidence_audit AS                     -- AC-05
SELECT a.id AS artifact_id, a.case_id, a.kind, a.lang, a.version, a.revision, a.ai_generated, a.grounding_status, a.claims_total, a.claims_untraced, a.term_violations,
       a.approved_by IS NOT NULL AS approved,
       (SELECT jsonb_agg(jsonb_build_object('ordinal', c.ordinal, 'section', c.section, 'sentence', c.sentence, 'kind', c.kind) ORDER BY c.ordinal)
          FROM quality.artifact_claim c WHERE c.artifact_id = a.id AND NOT c.traced) AS untraced_claims
  FROM quality.artifact a;

CREATE OR REPLACE VIEW quality.v_export_watermark AS                   -- AC-06
SELECT e.id, e.artifact_id, a.kind, a.lang, e.format, e.watermark, e.version_stamp, u.username AS approved_by, e.created_at,
       a.approved_by IS NULL AS artifact_is_draft
  FROM quality.export e JOIN quality.artifact a ON a.id = e.artifact_id LEFT JOIN core.app_user u ON u.id = e.approved_by_stamp;

CREATE OR REPLACE VIEW quality.v_action_overdue AS                     -- FR-31
SELECT a.id, a.case_id, c.title, a.kind, a.description, u.username AS owner, a.due_date, current_date - a.due_date AS days_overdue, a.status
  FROM quality.action a JOIN quality.case c ON c.id = a.case_id LEFT JOIN core.app_user u ON u.id = a.owner_id
 WHERE a.status IN ('open', 'in_progress') AND a.due_date < current_date;

CREATE OR REPLACE VIEW quality.v_effectiveness AS                      -- FR-28 / AC-08
SELECT e.*, a.case_id, a.kind AS action_kind, a.status AS action_status
  FROM quality.effectiveness_check e JOIN quality.action a ON a.id = e.action_id;

CREATE OR REPLACE VIEW quality.v_golden_summary AS                     -- AI-05
SELECT g.id, g.ran_at, g.model_version, g.prompt_version, g.ranking_version, g.n, g.top3_hits, g.top1_hits, g.top3_rate, g.fabricated, g.release_blocked, g.block_reason
  FROM quality.golden_run g ORDER BY g.ran_at DESC;

CREATE OR REPLACE VIEW quality.v_limit_history AS                      -- FR-06
SELECT cl.characteristic_id, ch.name, cl.line_id, cl.ucl, cl.cl, cl.lcl, cl.baseline_from, cl.baseline_to, cl.sample_size, cl.reason, u.username AS created_by, cl.created_at, cl.active
  FROM quality.control_limits cl JOIN quality.characteristic ch ON ch.id = cl.characteristic_id LEFT JOIN core.app_user u ON u.id = cl.created_by
 ORDER BY cl.characteristic_id, cl.created_at DESC;

CREATE OR REPLACE VIEW quality.v_horizontal_candidates AS              -- FR-30
SELECT h.*, c.title FROM quality.horizontal_candidate h JOIN quality.case c ON c.id = h.case_id WHERE h.status = 'suggested';

CREATE OR REPLACE VIEW quality.v_hypothesis_report AS                  -- Appendix A shape
SELECT h.case_id, h.rank, h.statement, h.score, h.status, h.factor, h.level, h.effect_size, h.p_adjusted, h.verify_step,
       (SELECT jsonb_agg(e.code || ': ' || e.value_json::text) FROM quality.hypothesis_evidence he JOIN quality.evidence e ON e.id = he.evidence_id WHERE he.hypothesis_id = h.id AND he.role = 'supporting') AS supporting,
       (SELECT jsonb_agg(e.code || ': ' || e.value_json::text) FROM quality.hypothesis_evidence he JOIN quality.evidence e ON e.id = he.evidence_id WHERE he.hypothesis_id = h.id AND he.role = 'contra') AS contra
  FROM quality.hypothesis h ORDER BY h.case_id, h.rank;

CREATE OR REPLACE VIEW quality.v_statistics_only AS                    -- AI-08 / AC-09
SELECT r.id, r.case_id, r.mode, r.llm_available, r.started_at, r.duration_ms, r.tests_run, r.hypotheses, r.artifacts FROM quality.analysis_run r WHERE r.mode = 'statistics_only';

-- =====================================================================
-- 18. ROLES AND GRANTS
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')      THEN CREATE ROLE app_rw      NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')      THEN CREATE ROLE app_ro      NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_ro')    THEN CREATE ROLE agent_ro    NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'engine_rw')   THEN CREATE ROLE engine_rw   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'exporter_ro') THEN CREATE ROLE exporter_ro NOLOGIN; END IF;
END $$;

GRANT USAGE ON SCHEMA core, vision, quality, knowledge, audit TO app_rw, app_ro, agent_ro, engine_rw, exporter_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, vision, quality, knowledge TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA quality, knowledge, audit TO app_rw;

-- analytics engine and drafter workers: write analysis objects; never approve, never export
GRANT SELECT ON ALL TABLES IN SCHEMA core, vision, quality, knowledge TO engine_rw;
GRANT INSERT, UPDATE ON quality.measurement, quality.subgroup, quality.control_limits, quality.spc_violation, quality.capability_result, quality.signal, quality.change_point,
                        quality.correlation_test, quality.evidence, quality.hypothesis, quality.hypothesis_evidence, quality.analysis_run, quality.artifact, quality.artifact_claim,
                        quality.artifact_revision, quality.term_check, quality.fmea_proposal, quality.ocap_suggestion, quality.effectiveness_check, quality.horizontal_candidate,
                        quality.escalation, quality.golden_run, quality.golden_result, quality.case, knowledge.case_record, knowledge.case_chunk, knowledge.case_source TO engine_rw;
REVOKE UPDATE (approved_by, approved_at) ON quality.artifact FROM engine_rw;
GRANT INSERT ON audit.log TO engine_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA quality, knowledge, audit TO engine_rw;

-- agent tools (IF-16): read-only; cannot read users or scope (platform rule)
GRANT SELECT ON ALL TABLES IN SCHEMA quality, knowledge TO agent_ro;
GRANT SELECT ON core.plant, core.line, core.sku, core.machine, core.defect_type, core.material_lot TO agent_ro;
REVOKE ALL ON core.app_user, core.user_line_scope FROM agent_ro;

-- exporter: reads artefacts, writes export rows only
GRANT SELECT ON quality.artifact, quality.artifact_revision, quality.case, quality.evidence, quality.capability_result, quality.hypothesis, core.app_user TO exporter_ro;
GRANT INSERT ON quality.export TO exporter_ro;
GRANT INSERT ON audit.log TO exporter_ro;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA quality, audit TO exporter_ro;

GRANT SELECT ON ALL TABLES IN SCHEMA core, vision, quality, knowledge, audit TO app_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA quality, knowledge GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA quality, knowledge GRANT SELECT ON TABLES TO app_ro, agent_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT INSERT, SELECT ON TABLES TO app_rw;

-- =====================================================================
-- 19. MIGRATION RECORD
-- =====================================================================
INSERT INTO quality.migration (version, notes) VALUES ('quality_0001', 'QE-Agent extension over the platform quality schema — DDS-09 v1.0');
