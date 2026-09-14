-- =====================================================================
--  DocFlow — AI Document → ERP Agent — database schema  (DDS-08)
--  Target   : PostgreSQL 16 (+ pgcrypto, pg_trgm)
--  Schemas  : core (shared master data and users), docflow (documents → ERP), audit (append-only)
--
--  ASSEMBLY (DDS-08 §1.4, TEST-08 TC-002): every object marked [platform] is copied BYTE-FOR-BYTE from
--  00-factorybrain-platform/db/schema.sql by line-range extraction — helpers, core.language_code, docflow.doc_state,
--  core.plant/line/sku, core.app_user/user_line_scope, all seven docflow.* tables (incl. posting_idem_unique),
--  the docflow indexes, trg_posting_updated and audit.*. Section 10 onward is the DocFlow extension
--  (migration docflow_0001), applied to the platform database in platform mode (SAD-08 §9).
--
--  The rules of SRS-08 that are DATABASE RULES here (DDS-08 DD-D01..D09):
--    C-01/NFR-05  a posting needs state = approved, an approval by a sufficient role, and above the SoD threshold an
--                 approver who edited no field                                 trg_posting_preconditions, trg_approval_policy
--    C-04         one ERP transaction per document/adapter/kind under retry     posting_idem_unique [platform] + idem_key()
--    C-03         arithmetic checked in SQL; the gate reads rules, not model confidences   arithmetic_check(), gate()
--    C-06         originals immutable; a document with a posting cannot be deleted        trg_document_immutable
--    FR-20/AC-03  a duplicate invoice number cannot be approved                          trg_no_duplicate_invoice
--    FR-25/AI-06  corrections are append-only training data                             trg_correction_immutable
--    AI-07/AC-06  an injection flag forces review_required                              trg_injection_flag
--    NFR-07/C-05  a cloud model needs an acknowledged admin decision, audited           trg_model_cloud
--    AI-09        an evaluation drop > 2 points blocks release                          trg_eval_release_gate
--
--  Apply:  psql -v ON_ERROR_STOP=1 -f schema.sql   (then optionally seed_demo.sql)
-- =====================================================================

-- =====================================================================
-- 1. EXTENSIONS  [platform lines 23, 25]
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_bytes, digest
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- trigram search (hybrid retrieval)

-- =====================================================================
-- 2. SCHEMAS
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS docflow;
CREATE SCHEMA IF NOT EXISTS audit;

COMMENT ON SCHEMA core    IS 'Shared master data and users (platform shape).';
COMMENT ON SCHEMA docflow IS 'Inbound business documents, extraction, validation, ERP postings.';
COMMENT ON SCHEMA audit   IS 'Append-only audit log. INSERT only; no UPDATE or DELETE grants.';

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
-- 4. ENUMERATED TYPES  [platform lines 111, 128–130] + DocFlow
-- =====================================================================
CREATE TYPE core.language_code     AS ENUM ('th', 'ja', 'en');
CREATE TYPE docflow.doc_state      AS ENUM ('received', 'classified', 'extracted', 'validated',
                                            'review_required', 'approved', 'rejected',
                                            'posting', 'posted', 'posting_failed');

CREATE TYPE docflow.doc_kind       AS ENUM ('purchase_order', 'invoice', 'delivery_note', 'quotation', 'certificate', 'other');
CREATE TYPE docflow.link_kind      AS ENUM ('duplicate', 'split_child', 'supersedes', 'related');
CREATE TYPE docflow.adapter_kind   AS ENUM ('rest', 'soap', 'staging_table', 'file_export');
CREATE TYPE docflow.gate_result    AS ENUM ('auto_clear', 'review_required', 'blocked');

-- =====================================================================
-- 5. CORE  [platform — plant/line/sku lines 144–174; app_user/user_line_scope lines 228–256]
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
-- 6. DOCFLOW — platform tables  [byte-identical, lines 1114–1202]
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
-- 7. AUDIT  [platform — lines 1294–1321]
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
-- 8. INDEXES AND TRIGGERS  [platform — lines 1405–1410, 1439–1440]
-- =====================================================================
-- docflow
CREATE INDEX idx_docflow_state      ON docflow.document (state, received_at DESC);
CREATE INDEX idx_extracted_field_ex ON docflow.extracted_field (extraction_id);
CREATE INDEX idx_line_item_ex       ON docflow.line_item (extraction_id, line_no);
CREATE INDEX idx_validation_doc     ON docflow.validation_result (document_id);
CREATE INDEX idx_posting_status     ON docflow.posting (status, updated_at DESC);

CREATE TRIGGER trg_posting_updated     BEFORE UPDATE ON docflow.posting
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =====================================================================
-- 9. END OF PLATFORM OBJECTS — everything below is migration docflow_0001
-- =====================================================================

-- =====================================================================
-- 10. DOCFLOW EXTENSION — master data (from the ERP, synced), templates, configuration
-- =====================================================================
CREATE TABLE docflow.supplier (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code        text NOT NULL UNIQUE,                     -- SUP-0142
    name        text NOT NULL,
    tax_id      text,
    country     char(2) NOT NULL,
    currency    char(3) NOT NULL,
    erp_ref     text,
    active      boolean NOT NULL DEFAULT true,
    synced_at   timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_supplier_tax_id ON docflow.supplier (country, tax_id) WHERE tax_id IS NOT NULL;

CREATE TABLE docflow.supplier_alias (                      -- FR-07: name / tax id / mail-domain matching
    supplier_id  uuid NOT NULL REFERENCES docflow.supplier(id) ON DELETE CASCADE,
    kind         text NOT NULL CHECK (kind IN ('name', 'tax_id', 'email_domain', 'layout_key')),
    alias        text NOT NULL,
    PRIMARY KEY (kind, alias)
);

CREATE TABLE docflow.item_alias (                          -- FR-17: supplier part numbers → item master (core.sku)
    supplier_id       uuid NOT NULL REFERENCES docflow.supplier(id) ON DELETE CASCADE,
    supplier_part_no  text NOT NULL,
    sku_id            uuid NOT NULL REFERENCES core.sku(id) ON DELETE RESTRICT,
    PRIMARY KEY (supplier_id, supplier_part_no)
);

CREATE TABLE docflow.price_list (                          -- FR-18
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    supplier_id  uuid NOT NULL REFERENCES docflow.supplier(id) ON DELETE CASCADE,
    sku_id       uuid NOT NULL REFERENCES core.sku(id) ON DELETE CASCADE,
    currency     char(3) NOT NULL,
    unit_price   numeric(16,4) NOT NULL CHECK (unit_price >= 0),
    source       text NOT NULL CHECK (source IN ('contract', 'quotation', 'last_invoice')),
    valid_from   date NOT NULL,
    valid_to     date,
    UNIQUE (supplier_id, sku_id, currency, valid_from)
);

CREATE TABLE docflow.open_po (                             -- FR-19: snapshot of open purchase orders from the ERP
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    po_number    text NOT NULL UNIQUE,
    supplier_id  uuid NOT NULL REFERENCES docflow.supplier(id),
    currency     char(3) NOT NULL,
    status       text NOT NULL CHECK (status IN ('open', 'partially_received', 'closed')),
    ordered_at   date NOT NULL,
    synced_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE docflow.open_po_line (
    po_id         uuid NOT NULL REFERENCES docflow.open_po(id) ON DELETE CASCADE,
    line_no       integer NOT NULL,
    sku_id        uuid NOT NULL REFERENCES core.sku(id),
    qty_ordered   numeric(14,4) NOT NULL CHECK (qty_ordered > 0),
    qty_received  numeric(14,4) NOT NULL DEFAULT 0 CHECK (qty_received >= 0),
    qty_invoiced  numeric(14,4) NOT NULL DEFAULT 0 CHECK (qty_invoiced >= 0),
    unit_price    numeric(16,4) NOT NULL,
    PRIMARY KEY (po_id, line_no)
);
CREATE TABLE docflow.goods_receipt (                       -- FR-19: 3-way
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    gr_number    text NOT NULL UNIQUE,
    po_id        uuid NOT NULL REFERENCES docflow.open_po(id) ON DELETE CASCADE,
    line_no      integer NOT NULL,
    qty          numeric(14,4) NOT NULL CHECK (qty > 0),
    received_at  date NOT NULL,
    synced_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (po_id, line_no) REFERENCES docflow.open_po_line(po_id, line_no) ON DELETE CASCADE
);

CREATE TABLE docflow.fx_rate (                             -- for approval policy thresholds in THB only — never for posting
    currency     char(3) NOT NULL,
    valid_from   date NOT NULL,
    rate_to_thb  numeric(14,6) NOT NULL CHECK (rate_to_thb > 0),
    PRIMARY KEY (currency, valid_from)
);

CREATE TABLE docflow.supplier_template (                   -- SRS §5, FR-14, AI-06 (ADR-D08)
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    supplier_id        uuid NOT NULL REFERENCES docflow.supplier(id) ON DELETE CASCADE,
    doc_kind           docflow.doc_kind NOT NULL,
    version            integer NOT NULL CHECK (version >= 1),
    layout_hints_json  jsonb NOT NULL,                     -- anchors, table columns, date formats, language
    accuracy_measured  numeric(5,4) CHECK (accuracy_measured BETWEEN 0 AND 1),
    n_measured         integer NOT NULL DEFAULT 0,
    active             boolean NOT NULL DEFAULT false,
    created_by         uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (supplier_id, doc_kind, version)
);
CREATE UNIQUE INDEX ux_template_active ON docflow.supplier_template (supplier_id, doc_kind) WHERE active;

CREATE TABLE docflow.approval_policy (                     -- FR-26, NFR-05 (SEC-117)
    id               smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_kind         docflow.doc_kind,                     -- NULL = any
    max_amount_thb   numeric(16,2),                        -- NULL = no upper bound
    min_role         text NOT NULL CHECK (min_role IN ('inspector', 'engineer', 'manager', 'admin')),
    sod_required     boolean NOT NULL DEFAULT false,       -- approver must not have edited a field
    priority         smallint NOT NULL DEFAULT 100
);
COMMENT ON TABLE docflow.approval_policy IS 'Ordered by priority; the first row whose kind matches and whose max_amount_thb >= the document amount applies. Roles: inspector = clerk, engineer = AP/warehouse (SAD-08 §5).';

CREATE TABLE docflow.field_gate (                          -- AI-05: per-field confidence gates
    doc_kind        docflow.doc_kind NOT NULL,
    field_path      text NOT NULL,                         -- header.total, lines[].qty, ...
    min_confidence  numeric(5,4) NOT NULL CHECK (min_confidence BETWEEN 0 AND 1),
    critical        boolean NOT NULL DEFAULT false,        -- critical fields require review unless template-matched AND arithmetic-consistent
    PRIMARY KEY (doc_kind, field_path)
);

CREATE TABLE docflow.stp_config (                          -- FR-29 (ADR-D07): straight-through processing, OFF by default
    doc_kind           docflow.doc_kind NOT NULL,
    supplier_id        uuid NOT NULL REFERENCES docflow.supplier(id) ON DELETE CASCADE,
    enabled            boolean NOT NULL DEFAULT false,
    accuracy_measured  numeric(5,4),
    n_measured         integer NOT NULL DEFAULT 0,
    enabled_by         uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    enabled_at         timestamptz,
    PRIMARY KEY (doc_kind, supplier_id),
    CONSTRAINT stp_needs_evidence CHECK (NOT enabled OR (accuracy_measured >= 0.98 AND n_measured >= 50 AND enabled_by IS NOT NULL))
);

CREATE TABLE docflow.tolerance (                           -- FR-18, FR-19
    doc_kind   docflow.doc_kind NOT NULL,
    rule       text NOT NULL,                              -- price.contract | match.2way.price | match.2way.qty | match.3way.qty | arithmetic.rounding
    warn_pct   numeric(6,3) NOT NULL CHECK (warn_pct >= 0),
    fail_pct   numeric(6,3) NOT NULL CHECK (fail_pct >= warn_pct),
    PRIMARY KEY (doc_kind, rule)
);

CREATE TABLE docflow.model_registry (                      -- AI-08, NFR-07 (ADR-D09)
    id                     smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind                   text NOT NULL CHECK (kind IN ('extraction', 'classifier', 'ocr', 'injection', 'embedding')),
    name                   text NOT NULL,
    version                text NOT NULL,
    cloud                  boolean NOT NULL DEFAULT false,
    cloud_acknowledged_by  uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    cloud_acknowledged_at  timestamptz,
    active                 boolean NOT NULL DEFAULT false,
    checksum               text,
    registered_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (kind, name, version),
    CONSTRAINT cloud_needs_ack CHECK (NOT cloud OR (cloud_acknowledged_by IS NOT NULL AND cloud_acknowledged_at IS NOT NULL))
);
CREATE UNIQUE INDEX ux_model_active ON docflow.model_registry (kind) WHERE active;

CREATE TABLE docflow.prompt_version (
    version     text PRIMARY KEY,                          -- p-2026.09
    kind        text NOT NULL CHECK (kind IN ('extraction', 'classification')),
    checksum    text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE docflow.extraction_schema (                   -- IF-47: the JSON Schemas the model output must satisfy (C-02)
    version     text PRIMARY KEY,                          -- po.v2, invoice.v1, delivery_note.v1
    doc_kind    docflow.doc_kind NOT NULL,
    checksum    text NOT NULL,
    uri         text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.erp_adapter (                         -- IF-07 / IF-48
    name           text PRIMARY KEY,
    kind           docflow.adapter_kind NOT NULL,
    supports_idem  boolean NOT NULL CHECK (supports_idem),  -- an adapter that cannot honour idem_key cannot be registered (ICD-00 IF-07)
    config_json    jsonb NOT NULL DEFAULT '{}',            -- endpoints, staging table, export path — NO credentials
    credential_ref text,                                   -- secret file name
    active         boolean NOT NULL DEFAULT true
);

CREATE TABLE docflow.intake_source (                       -- IF-44 / IF-45
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind            text NOT NULL CHECK (kind IN ('imap', 'folder', 'sftp', 'scanner', 'upload')),
    name            text NOT NULL UNIQUE,
    config_json     jsonb NOT NULL DEFAULT '{}',           -- host, folder, allow-list — NO credentials
    credential_ref  text,
    active          boolean NOT NULL DEFAULT true,
    last_poll_at    timestamptz,
    last_error      text
);

CREATE TABLE docflow.retention_policy (
    entity  text PRIMARY KEY CHECK (entity IN ('original', 'extraction', 'audit', 'page_image', 'export_file')),
    years   numeric(4,1) NOT NULL CHECK (years > 0),
    mode    text NOT NULL CHECK (mode IN ('worm', 'delete', 'regenerable'))
);
INSERT INTO docflow.retention_policy VALUES ('original', 7, 'worm'), ('extraction', 7, 'delete'), ('audit', 7, 'worm'), ('page_image', 7, 'regenerable'), ('export_file', 0.1, 'delete');

-- =====================================================================
-- 11. DOCFLOW EXTENSION — document-side tables and columns
-- =====================================================================
ALTER TABLE docflow.document
    ADD COLUMN doc_kind          docflow.doc_kind,                      -- typed twin of the platform's free-text kind
    ADD COLUMN kind_confidence   numeric(5,4) CHECK (kind_confidence BETWEEN 0 AND 1),
    ADD COLUMN supplier_id       uuid REFERENCES docflow.supplier(id) ON DELETE SET NULL,
    ADD COLUMN doc_number        text,                                  -- PO number / invoice number / DN number
    ADD COLUMN doc_date          date,
    ADD COLUMN currency          char(3),
    ADD COLUMN subtotal          numeric(16,4),
    ADD COLUMN tax               numeric(16,4),
    ADD COLUMN total             numeric(16,4),
    ADD COLUMN amount_thb        numeric(16,2),                         -- for approval policy only
    ADD COLUMN gate_result       docflow.gate_result,
    ADD COLUMN injection_flagged boolean NOT NULL DEFAULT false,
    ADD COLUMN template_id       uuid REFERENCES docflow.supplier_template(id) ON DELETE SET NULL,
    ADD COLUMN intake_source_id  uuid REFERENCES docflow.intake_source(id) ON DELETE SET NULL,
    ADD COLUMN intake_meta_json  jsonb NOT NULL DEFAULT '{}',            -- email from/subject/received, file name — no bodies
    ADD COLUMN text_source       text CHECK (text_source IN ('text_layer', 'ocr', 'mixed')),
    ADD COLUMN failure_reason    text,                                  -- extraction_failed | quality_too_low | ...
    ADD COLUMN updated_at        timestamptz NOT NULL DEFAULT now();
COMMENT ON COLUMN docflow.document.amount_thb IS 'Total converted with fx_rate for the approval policy (FR-26). Never used for posting; the ERP receives the document currency.';

ALTER TABLE docflow.extraction
    ADD COLUMN prompt_version  text REFERENCES docflow.prompt_version(version),
    ADD COLUMN cloud           boolean NOT NULL DEFAULT false,          -- NFR-07: visible on every extraction made with a cloud model
    ADD COLUMN schema_valid    boolean NOT NULL DEFAULT true,
    ADD COLUMN repair_rounds   smallint NOT NULL DEFAULT 0 CHECK (repair_rounds BETWEEN 0 AND 2),   -- ADR-D01
    ADD COLUMN lines_json      jsonb NOT NULL DEFAULT '[]';

ALTER TABLE docflow.line_item
    ADD COLUMN sku_id          uuid REFERENCES core.sku(id) ON DELETE SET NULL,
    ADD COLUMN delivery_date   date,
    ADD COLUMN page_no         integer,
    ADD COLUMN bbox_json       jsonb;

CREATE TABLE docflow.page_image (                          -- SRS §5, FR-05
    document_id  uuid NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    page_no      integer NOT NULL CHECK (page_no >= 1),
    uri          text NOT NULL,
    width        integer NOT NULL,
    height       integer NOT NULL,
    dpi          integer NOT NULL DEFAULT 150,
    text_chars   integer NOT NULL DEFAULT 0,               -- text-layer characters found (FR-09)
    ocr_conf     numeric(5,4),                             -- mean character confidence when OCR ran (AI-01)
    PRIMARY KEY (document_id, page_no)
);

CREATE TABLE docflow.document_link (                       -- FR-03 dedup → existing case; FR-04 splits
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id  uuid NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    related_id   uuid NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    kind         docflow.link_kind NOT NULL,
    detail       text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, related_id, kind),
    CONSTRAINT link_distinct CHECK (document_id <> related_id)
);

CREATE TABLE docflow.field_correction (                    -- FR-25, AI-06 (ADR — append-only training data)
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    extracted_field_id  uuid NOT NULL REFERENCES docflow.extracted_field(id) ON DELETE CASCADE,
    document_id         uuid NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    old_value           text,
    new_value           text NOT NULL,
    reason              text,
    corrected_by        uuid NOT NULL REFERENCES core.app_user(id) ON DELETE RESTRICT,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.injection_flag (                      -- AI-07, AC-06 (ADR-D10)
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id  uuid NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    page_no      integer,
    bbox_json    jsonb,
    phrase       text NOT NULL,
    classifier   text NOT NULL,                            -- regex | model:<name>
    score        numeric(5,4) NOT NULL CHECK (score BETWEEN 0 AND 1),
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.export_file (                         -- IF-48
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    posting_id  uuid NOT NULL REFERENCES docflow.posting(id) ON DELETE CASCADE,
    format      text NOT NULL CHECK (format IN ('csv', 'xml')),
    uri         text NOT NULL,
    sha256      text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.notification (                        -- FR-27, FR-34
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id  uuid NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    kind         text NOT NULL CHECK (kind IN ('review_needed', 'approval_needed', 'posted', 'posting_failed', 'rejected_reply', 'duplicate')),
    channel      text NOT NULL CHECK (channel IN ('email', 'discord', 'webhook', 'in_app')),
    recipient    text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    sent_at      timestamptz,
    error        text
);

CREATE TABLE docflow.access_log (                          -- SEC-116: reads of originals are audited
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id  uuid NOT NULL REFERENCES docflow.document(id) ON DELETE CASCADE,
    user_id      uuid REFERENCES core.app_user(id) ON DELETE SET NULL,
    action       text NOT NULL CHECK (action IN ('view_original', 'view_page', 'download_original', 'export')),
    ip           inet,
    ts           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.eval_run (                            -- AI-03, AI-09
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    model_version    text NOT NULL,
    prompt_version   text NOT NULL REFERENCES docflow.prompt_version(version),
    schema_version   text NOT NULL REFERENCES docflow.extraction_schema(version),
    dataset          text NOT NULL,
    n_docs           integer NOT NULL CHECK (n_docs > 0),
    header_acc       numeric(5,4) NOT NULL,
    line_acc         numeric(5,4) NOT NULL,
    class_acc        numeric(5,4) NOT NULL,
    baseline_run_id  integer REFERENCES docflow.eval_run(id),
    release_blocked  boolean NOT NULL DEFAULT false,
    block_reason     text,
    ran_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE docflow.migration (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    notes       text
);

-- =====================================================================
-- 12. FUNCTIONS — money, policy, arithmetic, gate, idempotency
-- =====================================================================
CREATE OR REPLACE FUNCTION docflow.role_rank(p_role text) RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_role WHEN 'viewer' THEN 0 WHEN 'inspector' THEN 1 WHEN 'engineer' THEN 2 WHEN 'manager' THEN 3 WHEN 'admin' THEN 4 ELSE -1 END::smallint;
$$;

CREATE OR REPLACE FUNCTION docflow.amount_thb(p_currency char(3), p_amount numeric, p_on date DEFAULT current_date)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_currency = 'THB' THEN round(p_amount, 2)
                ELSE round(p_amount * (SELECT rate_to_thb FROM docflow.fx_rate WHERE currency = p_currency AND valid_from <= p_on ORDER BY valid_from DESC LIMIT 1), 2) END;
$$;

-- FR-26: the policy row for a document
CREATE OR REPLACE FUNCTION docflow.required_policy(p_kind docflow.doc_kind, p_amount_thb numeric)
RETURNS docflow.approval_policy LANGUAGE sql STABLE AS $$
    SELECT p FROM docflow.approval_policy p
     WHERE (p.doc_kind IS NULL OR p.doc_kind = p_kind)
       AND (p.max_amount_thb IS NULL OR p_amount_thb <= p.max_amount_thb)
     ORDER BY p.priority, p.max_amount_thb NULLS LAST LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION docflow.editors_of(p_document uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT corrected_by), '{}') FROM docflow.field_correction WHERE document_id = p_document;
$$;

CREATE OR REPLACE FUNCTION docflow.rounding_unit(p_currency char(3)) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_currency IN ('JPY', 'KRW') THEN 1 ELSE 0.01 END;
$$;

-- C-03 / FR-15: arithmetic in SQL over line_item and the document totals. Returns one row per check.
CREATE OR REPLACE FUNCTION docflow.arithmetic_check(p_document uuid)
RETURNS TABLE (rule text, status text, detail_json jsonb) LANGUAGE plpgsql STABLE AS $$
DECLARE d docflow.document; ex uuid; u numeric; bad integer; sum_lines numeric;
BEGIN
    SELECT * INTO d FROM docflow.document WHERE id = p_document;
    SELECT id INTO ex FROM docflow.extraction WHERE document_id = p_document ORDER BY created_at DESC LIMIT 1;
    u := docflow.rounding_unit(COALESCE(d.currency, 'THB'));
    SELECT count(*) FILTER (WHERE abs(COALESCE(amount, 0) - COALESCE(qty, 0) * COALESCE(unit_price, 0)) > u), sum(amount)
      INTO bad, sum_lines FROM docflow.line_item WHERE extraction_id = ex;
    rule := 'arithmetic.line'; status := CASE WHEN bad = 0 THEN 'pass' ELSE 'fail' END;
    detail_json := jsonb_build_object('lines_failing', bad, 'rounding_unit', u); RETURN NEXT;
    rule := 'arithmetic.total';
    IF d.total IS NULL OR sum_lines IS NULL THEN status := 'fail'; detail_json := jsonb_build_object('reason', 'missing total or lines');
    ELSIF abs(sum_lines + COALESCE(d.tax, 0) - d.total) <= u THEN status := 'pass'; detail_json := jsonb_build_object('sum_lines', sum_lines, 'tax', COALESCE(d.tax, 0), 'total', d.total);
    ELSE status := 'fail'; detail_json := jsonb_build_object('sum_lines', sum_lines, 'tax', COALESCE(d.tax, 0), 'total', d.total, 'difference', sum_lines + COALESCE(d.tax, 0) - d.total);
    END IF;
    RETURN NEXT;
END $$;

-- FR-22 / FR-29 / AI-05: the gate reads validation_result rows (produced by worker-validate incl. arithmetic_check), never confidences alone.
CREATE OR REPLACE FUNCTION docflow.gate(p_document uuid) RETURNS docflow.gate_result LANGUAGE plpgsql STABLE AS $$
DECLARE d docflow.document; n_fail integer; n_warn integer; stp boolean; ex uuid; low_fields integer; no_prov integer;
BEGIN
    SELECT * INTO d FROM docflow.document WHERE id = p_document;
    SELECT count(*) FILTER (WHERE status = 'fail'), count(*) FILTER (WHERE status = 'warning') INTO n_fail, n_warn
      FROM (SELECT DISTINCT ON (rule) rule, status FROM docflow.validation_result WHERE document_id = p_document ORDER BY rule, ran_at DESC) v;
    IF n_fail > 0 OR d.injection_flagged THEN RETURN 'blocked'; END IF;       -- fail or injection: never auto-clear; review decides
    SELECT id INTO ex FROM docflow.extraction WHERE document_id = p_document ORDER BY created_at DESC LIMIT 1;
    SELECT count(*) FILTER (WHERE f.confidence < g.min_confidence), count(*) FILTER (WHERE g.critical AND (f.page_no IS NULL OR f.bbox_json IS NULL))
      INTO low_fields, no_prov
      FROM docflow.extracted_field f JOIN docflow.field_gate g ON g.doc_kind = d.doc_kind AND g.field_path = f.path
     WHERE f.extraction_id = ex AND f.corrected_value IS NULL;
    SELECT COALESCE(s.enabled, false) INTO stp FROM docflow.stp_config s WHERE s.doc_kind = d.doc_kind AND s.supplier_id = d.supplier_id;
    IF n_warn = 0 AND low_fields = 0 AND no_prov = 0 AND COALESCE(stp, false) AND d.template_id IS NOT NULL AND d.supplier_id IS NOT NULL THEN
        RETURN 'auto_clear';
    END IF;
    RETURN 'review_required';
END $$;
COMMENT ON FUNCTION docflow.gate IS 'auto_clear only if: no fail, no warning, no injection flag, every gated field above its gate, every critical field with provenance (AI-04), STP enabled for (kind, supplier) and template-matched. STP is OFF by default (FR-29).';

-- C-04 / ADR-D05: deterministic idempotency key
CREATE OR REPLACE FUNCTION docflow.idem_key(p_document uuid, p_adapter text) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT d.sha256 || ':' || p_adapter || ':' || COALESCE(d.doc_kind::text, d.kind, 'unknown') FROM docflow.document d WHERE d.id = p_document;
$$;

-- =====================================================================
-- 13. TRIGGERS — the guards (DDS-08 DD-D01..D09)
-- =====================================================================

-- DD-D06 (C-06): originals immutable; no delete while a posting exists
CREATE OR REPLACE FUNCTION docflow.trg_document_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF EXISTS (SELECT 1 FROM docflow.posting WHERE document_id = OLD.id) THEN
            RAISE EXCEPTION 'DOCUMENT_RETAINED: document % has a posting and cannot be deleted (C-06)', OLD.id;
        END IF;
        RETURN OLD;
    END IF;
    IF NEW.sha256 IS DISTINCT FROM OLD.sha256 OR NEW.original_uri IS DISTINCT FROM OLD.original_uri
       OR NEW.received_at IS DISTINCT FROM OLD.received_at OR NEW.source IS DISTINCT FROM OLD.source THEN
        RAISE EXCEPTION 'DOCUMENT_IMMUTABLE: sha256, original_uri, received_at and source cannot change (C-06)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_document_immutable BEFORE UPDATE OR DELETE ON docflow.document
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_document_immutable();

-- DD-D05: state machine (SRS §2.1); also derives amount_thb on insert/update
CREATE OR REPLACE FUNCTION docflow.trg_document_state() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.state IS DISTINCT FROM OLD.state THEN
        IF NOT ( (OLD.state = 'received'        AND NEW.state IN ('classified', 'review_required', 'rejected'))
              OR (OLD.state = 'classified'      AND NEW.state IN ('extracted', 'review_required', 'rejected'))
              OR (OLD.state = 'extracted'       AND NEW.state IN ('validated', 'review_required', 'rejected'))
              OR (OLD.state = 'validated'       AND NEW.state IN ('review_required', 'approved', 'rejected'))
              OR (OLD.state = 'review_required' AND NEW.state IN ('validated', 'approved', 'rejected'))
              OR (OLD.state = 'approved'        AND NEW.state IN ('posting', 'review_required'))
              OR (OLD.state = 'posting'         AND NEW.state IN ('posted', 'posting_failed'))
              OR (OLD.state = 'posting_failed'  AND NEW.state IN ('posting', 'review_required', 'rejected'))
              OR (OLD.state = 'rejected'        AND NEW.state IN ('review_required')) ) THEN
            RAISE EXCEPTION 'STATE_TRANSITION: % -> % not allowed', OLD.state, NEW.state;
        END IF;
        IF NEW.state = 'approved' AND NOT EXISTS (SELECT 1 FROM docflow.approval a WHERE a.document_id = NEW.id AND a.decision = 'approved') THEN
            RAISE EXCEPTION 'NOT_APPROVED: state approved requires an approval row (C-01)';
        END IF;
    END IF;
    IF NEW.total IS NOT NULL AND NEW.currency IS NOT NULL THEN NEW.amount_thb := docflow.amount_thb(NEW.currency, NEW.total, COALESCE(NEW.doc_date, current_date)); END IF;
    NEW.updated_at := now();
    RETURN NEW;
END $$;
CREATE TRIGGER trg_document_state BEFORE INSERT OR UPDATE ON docflow.document
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_document_state();

-- DD-D01 (FR-26, NFR-05, AC-07): approval must come from a sufficient role, and above the SoD threshold not from an editor
CREATE OR REPLACE FUNCTION docflow.trg_approval_policy() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d docflow.document; p docflow.approval_policy; urole text;
BEGIN
    SELECT * INTO d FROM docflow.document WHERE id = NEW.document_id;
    IF d.state NOT IN ('validated', 'review_required', 'posting_failed') THEN
        RAISE EXCEPTION 'APPROVAL_STATE: document % is % — approvals apply to validated/review_required documents', d.id, d.state;
    END IF;
    SELECT role INTO urole FROM core.app_user WHERE id = NEW.user_id AND active;
    IF urole IS NULL THEN RAISE EXCEPTION 'APPROVER_UNKNOWN'; END IF;
    IF NEW.role <> urole THEN RAISE EXCEPTION 'ROLE_MISMATCH: approval.role % differs from the user''s role %', NEW.role, urole; END IF;
    IF NEW.decision = 'approved' THEN
        p := docflow.required_policy(d.doc_kind, COALESCE(d.amount_thb, 0));
        IF p IS NULL THEN RAISE EXCEPTION 'POLICY_MISSING: no approval policy matches % / % THB', d.doc_kind, d.amount_thb; END IF;
        IF docflow.role_rank(urole) < docflow.role_rank(p.min_role) THEN
            RAISE EXCEPTION 'ROLE_INSUFFICIENT: % may not approve % THB (policy requires %) (FR-26, AC-07)', urole, d.amount_thb, p.min_role;
        END IF;
        IF p.sod_required AND NEW.user_id = ANY (docflow.editors_of(d.id)) THEN
            RAISE EXCEPTION 'SEGREGATION_OF_DUTIES: user % edited fields of document % and may not approve it (NFR-05)', NEW.user_id, d.id;
        END IF;
        IF d.doc_kind = 'invoice' AND d.supplier_id IS NOT NULL AND d.doc_number IS NOT NULL AND EXISTS (
               SELECT 1 FROM docflow.document o WHERE o.id <> d.id AND o.doc_kind = 'invoice' AND o.supplier_id = d.supplier_id
                  AND o.doc_number = d.doc_number AND o.state IN ('approved', 'posting', 'posted', 'posting_failed')) THEN
            RAISE EXCEPTION 'DUPLICATE_INVOICE: supplier % invoice % already approved or posted (FR-20, AC-03)', d.supplier_id, d.doc_number;
        END IF;
    ELSE
        IF NEW.reason IS NULL OR length(trim(NEW.reason)) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED: rejection needs a reason (FR-27)'; END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_approval_policy BEFORE INSERT ON docflow.approval
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_approval_policy();

CREATE OR REPLACE FUNCTION docflow.trg_approval_apply() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE docflow.document SET state = CASE NEW.decision WHEN 'approved' THEN 'approved'::docflow.doc_state ELSE 'rejected' END WHERE id = NEW.document_id;
    INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
    VALUES (NEW.user_id, NEW.role, 'docflow.' || NEW.decision, 'document', NEW.document_id::text, jsonb_build_object('reason', NEW.reason));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_approval_apply AFTER INSERT ON docflow.approval
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_approval_apply();

-- DD-D01/DD-D02 (C-01, C-04): a posting needs approved state, an approval by a sufficient role, SoD, a registered adapter, and the deterministic key
CREATE OR REPLACE FUNCTION docflow.trg_posting_preconditions() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d docflow.document; a docflow.approval; p docflow.approval_policy;
BEGIN
    SELECT * INTO d FROM docflow.document WHERE id = NEW.document_id;
    IF d.state NOT IN ('approved', 'posting_failed') THEN RAISE EXCEPTION 'NOT_APPROVED: document % is % (C-01)', d.id, d.state; END IF;
    SELECT * INTO a FROM docflow.approval WHERE document_id = d.id AND decision = 'approved' ORDER BY created_at DESC LIMIT 1;
    IF a IS NULL THEN RAISE EXCEPTION 'NOT_APPROVED: no approval row for document % (C-01)', d.id; END IF;
    p := docflow.required_policy(d.doc_kind, COALESCE(d.amount_thb, 0));
    IF docflow.role_rank(a.role) < docflow.role_rank(p.min_role) THEN RAISE EXCEPTION 'ROLE_INSUFFICIENT at posting time'; END IF;
    IF p.sod_required AND a.user_id = ANY (docflow.editors_of(d.id)) THEN RAISE EXCEPTION 'SEGREGATION_OF_DUTIES at posting time (NFR-05)'; END IF;
    IF NOT EXISTS (SELECT 1 FROM docflow.erp_adapter WHERE name = NEW.adapter AND active AND supports_idem) THEN
        RAISE EXCEPTION 'ADAPTER_UNKNOWN: % is not a registered idempotent adapter (IF-07)', NEW.adapter;
    END IF;
    IF NEW.idem_key IS DISTINCT FROM docflow.idem_key(d.id, NEW.adapter) THEN
        RAISE EXCEPTION 'IDEM_KEY: expected % (C-04)', docflow.idem_key(d.id, NEW.adapter);
    END IF;
    UPDATE docflow.document SET state = 'posting' WHERE id = d.id AND state IN ('approved', 'posting_failed');
    RETURN NEW;
END $$;
CREATE TRIGGER trg_posting_preconditions BEFORE INSERT ON docflow.posting
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_posting_preconditions();

CREATE OR REPLACE FUNCTION docflow.trg_posting_result() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'succeeded' AND OLD.status <> 'succeeded' THEN
        IF NEW.erp_ref IS NULL THEN RAISE EXCEPTION 'ERP_REF_REQUIRED: a succeeded posting must carry the ERP reference (FR-30)'; END IF;
        UPDATE docflow.document SET state = 'posted' WHERE id = NEW.document_id;
        INSERT INTO audit.log (actor, action, entity, entity_id, after_json)
        VALUES ('poster', 'docflow.posted', 'document', NEW.document_id::text, jsonb_build_object('adapter', NEW.adapter, 'erp_ref', NEW.erp_ref, 'attempts', NEW.attempts));
    ELSIF NEW.status = 'failed' AND OLD.status <> 'failed' THEN
        UPDATE docflow.document SET state = 'posting_failed' WHERE id = NEW.document_id AND state = 'posting';
    ELSIF NEW.status = 'pending' AND OLD.status = 'failed' THEN
        UPDATE docflow.document SET state = 'posting' WHERE id = NEW.document_id AND state = 'posting_failed';   -- retry (FR-32)
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_posting_result AFTER UPDATE OF status ON docflow.posting
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_posting_result();

-- DD-D04 (FR-25, AI-06): corrections are append-only and apply themselves to the field
CREATE OR REPLACE FUNCTION docflow.trg_correction_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'CORRECTION_IMMUTABLE: field_correction is append-only training data (AI-06)'; END $$;
CREATE TRIGGER trg_correction_immutable BEFORE UPDATE OR DELETE ON docflow.field_correction
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_correction_immutable();

CREATE OR REPLACE FUNCTION docflow.trg_correction_apply() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE docflow.extracted_field SET corrected_value = NEW.new_value, corrected_by = NEW.corrected_by, corrected_at = NEW.created_at WHERE id = NEW.extracted_field_id;
    INSERT INTO audit.log (user_id, actor, action, entity, entity_id, before_json, after_json)
    VALUES (NEW.corrected_by, 'reviewer', 'docflow.correct_field', 'extracted_field', NEW.extracted_field_id::text, jsonb_build_object('value', NEW.old_value), jsonb_build_object('value', NEW.new_value));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_correction_apply AFTER INSERT ON docflow.field_correction
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_correction_apply();

-- DD-D07 (AI-07, AC-06): an injection flag forces review and can never be auto-cleared
CREATE OR REPLACE FUNCTION docflow.trg_injection_flag() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE docflow.document SET injection_flagged = true, gate_result = 'blocked',
           state = CASE WHEN state IN ('validated') THEN 'review_required'::docflow.doc_state ELSE state END
     WHERE id = NEW.document_id;
    INSERT INTO audit.log (actor, action, entity, entity_id, after_json)
    VALUES ('injection_classifier', 'docflow.injection_flagged', 'document', NEW.document_id::text, jsonb_build_object('phrase', NEW.phrase, 'score', NEW.score, 'page', NEW.page_no));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_injection_flag AFTER INSERT ON docflow.injection_flag
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_injection_flag();

-- DD-D08 (NFR-07, C-05): enabling a cloud model is an acknowledged, audited admin decision
CREATE OR REPLACE FUNCTION docflow.trg_model_cloud() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.cloud AND NOT COALESCE(OLD.cloud, false) THEN
        IF NEW.cloud_acknowledged_by IS NULL THEN RAISE EXCEPTION 'CLOUD_NOT_ACKNOWLEDGED: enabling a cloud model needs an admin acknowledgement (NFR-07)'; END IF;
        IF (SELECT role FROM core.app_user WHERE id = NEW.cloud_acknowledged_by) <> 'admin' THEN RAISE EXCEPTION 'CLOUD_NOT_ADMIN'; END IF;
        NEW.cloud_acknowledged_at := COALESCE(NEW.cloud_acknowledged_at, now());
        INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
        VALUES (NEW.cloud_acknowledged_by, 'admin', 'docflow.cloud_model_enabled', 'model_registry', NEW.name || ' ' || NEW.version, jsonb_build_object('kind', NEW.kind));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_model_cloud BEFORE INSERT OR UPDATE OF cloud ON docflow.model_registry
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_model_cloud();

-- DD-D09 (AI-03, AI-09): release gate — below target or > 2 points below the baseline blocks release
CREATE OR REPLACE FUNCTION docflow.trg_eval_release_gate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE b docflow.eval_run; reasons text[] := '{}';
BEGIN
    IF NEW.header_acc < 0.95 THEN reasons := reasons || format('header %.1f%% < 95%%', NEW.header_acc * 100); END IF;
    IF NEW.line_acc   < 0.90 THEN reasons := reasons || format('lines %.1f%% < 90%%', NEW.line_acc * 100); END IF;
    IF NEW.class_acc  < 0.98 THEN reasons := reasons || format('classification %.1f%% < 98%%', NEW.class_acc * 100); END IF;
    IF NEW.baseline_run_id IS NOT NULL THEN
        SELECT * INTO b FROM docflow.eval_run WHERE id = NEW.baseline_run_id;
        IF b.header_acc - NEW.header_acc > 0.02 THEN reasons := reasons || format('header −%.1f pts vs baseline', (b.header_acc - NEW.header_acc) * 100); END IF;
        IF b.line_acc   - NEW.line_acc   > 0.02 THEN reasons := reasons || format('lines −%.1f pts vs baseline', (b.line_acc - NEW.line_acc) * 100); END IF;
        IF b.class_acc  - NEW.class_acc  > 0.02 THEN reasons := reasons || format('classification −%.1f pts vs baseline', (b.class_acc - NEW.class_acc) * 100); END IF;
    END IF;
    NEW.release_blocked := cardinality(reasons) > 0;
    NEW.block_reason := NULLIF(array_to_string(reasons, '; '), '');
    RETURN NEW;
END $$;
CREATE TRIGGER trg_eval_release_gate BEFORE INSERT ON docflow.eval_run
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_eval_release_gate();

-- dedup link: the same hash can never be a second document (UNIQUE sha256 [platform]); a link records the repeat (FR-03)
CREATE OR REPLACE FUNCTION docflow.trg_link_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit.log (actor, action, entity, entity_id, after_json)
    VALUES ('intake', 'docflow.link.' || NEW.kind, 'document', NEW.document_id::text, jsonb_build_object('related', NEW.related_id, 'detail', NEW.detail));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_link_audit AFTER INSERT ON docflow.document_link
    FOR EACH ROW EXECUTE FUNCTION docflow.trg_link_audit();

CREATE TRIGGER trg_supplier_updated BEFORE UPDATE ON docflow.supplier FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =====================================================================
-- 14. INDEXES (extension)
-- =====================================================================
CREATE INDEX idx_document_supplier_number ON docflow.document (supplier_id, doc_number) WHERE doc_number IS NOT NULL;
CREATE INDEX idx_document_kind_state      ON docflow.document (doc_kind, state, received_at DESC);
CREATE INDEX idx_document_received_brin   ON docflow.document USING brin (received_at);
CREATE INDEX idx_document_number_trgm     ON docflow.document USING gin (doc_number gin_trgm_ops);
CREATE INDEX idx_supplier_name_trgm       ON docflow.supplier USING gin (name gin_trgm_ops);
CREATE INDEX idx_approval_document        ON docflow.approval (document_id, created_at DESC);
CREATE INDEX idx_posting_document         ON docflow.posting (document_id);
CREATE INDEX idx_correction_document      ON docflow.field_correction (document_id);
CREATE INDEX idx_correction_user          ON docflow.field_correction (corrected_by);
CREATE INDEX idx_injection_document       ON docflow.injection_flag (document_id);
CREATE INDEX idx_access_log_document      ON docflow.access_log (document_id, ts DESC);
CREATE INDEX idx_access_log_user          ON docflow.access_log (user_id, ts DESC);
CREATE INDEX idx_notification_unsent      ON docflow.notification (created_at) WHERE sent_at IS NULL;
CREATE INDEX idx_link_related             ON docflow.document_link (related_id);
CREATE INDEX idx_price_list_lookup        ON docflow.price_list (supplier_id, sku_id, currency, valid_from DESC);
CREATE INDEX idx_open_po_supplier         ON docflow.open_po (supplier_id, status);
CREATE INDEX idx_audit_log_ts             ON audit.log (ts DESC);
CREATE INDEX idx_audit_log_entity         ON audit.log (entity, entity_id, ts DESC);

-- =====================================================================
-- 15. VIEWS
-- =====================================================================
CREATE OR REPLACE VIEW docflow.v_validation_report AS                 -- FR-22
SELECT v.document_id, v.rule, v.status, v.detail_json, v.ran_at
  FROM (SELECT DISTINCT ON (document_id, rule) * FROM docflow.validation_result ORDER BY document_id, rule, ran_at DESC) v;

CREATE OR REPLACE VIEW docflow.v_document_summary AS
SELECT d.id, d.doc_kind, d.state, d.doc_number, d.doc_date, s.code AS supplier_code, s.name AS supplier_name,
       d.currency, d.total, d.amount_thb, d.gate_result, d.injection_flagged, d.lang, d.source, d.received_at,
       (SELECT count(*) FROM docflow.v_validation_report v WHERE v.document_id = d.id AND v.status = 'fail')    AS rules_failed,
       (SELECT count(*) FROM docflow.v_validation_report v WHERE v.document_id = d.id AND v.status = 'warning') AS rules_warning,
       (SELECT p.min_role FROM docflow.required_policy(d.doc_kind, COALESCE(d.amount_thb, 0)) p)               AS required_role,
       (SELECT p.sod_required FROM docflow.required_policy(d.doc_kind, COALESCE(d.amount_thb, 0)) p)           AS sod_required,
       (SELECT max(a.created_at) FROM docflow.approval a WHERE a.document_id = d.id AND a.decision = 'approved') AS approved_at,
       (SELECT p.erp_ref FROM docflow.posting p WHERE p.document_id = d.id AND p.status = 'succeeded' LIMIT 1)   AS erp_ref
  FROM docflow.document d LEFT JOIN docflow.supplier s ON s.id = d.supplier_id;

CREATE OR REPLACE VIEW docflow.v_review_queue AS                       -- SRS §4.1 /queue?state=review
SELECT * FROM docflow.v_document_summary WHERE state = 'review_required' ORDER BY received_at;

CREATE OR REPLACE VIEW docflow.v_exception_queue AS                    -- FR-32
SELECT d.id, d.doc_kind, d.doc_number, d.state, p.adapter, p.attempts, p.last_error, p.updated_at AS last_attempt_at,
       CASE WHEN d.state = 'posting_failed' THEN 'posting' WHEN d.failure_reason IS NOT NULL THEN d.failure_reason ELSE 'validation' END AS exception_kind
  FROM docflow.document d LEFT JOIN docflow.posting p ON p.document_id = d.id AND p.status = 'failed'
 WHERE d.state = 'posting_failed' OR d.failure_reason IS NOT NULL;

CREATE OR REPLACE VIEW docflow.v_audit_export AS                       -- AC-09: who saw, edited, approved, posted
SELECT l.entity_id AS document_id, l.ts, l.user_id, u.username, l.actor, l.action, l.before_json, l.after_json, l.ip
  FROM audit.log l LEFT JOIN core.app_user u ON u.id = l.user_id
 WHERE l.entity IN ('document', 'extracted_field') AND l.action LIKE 'docflow.%'
UNION ALL
SELECT a.document_id::text, a.ts, a.user_id, u.username, 'reader', 'docflow.' || a.action, NULL, NULL, a.ip
  FROM docflow.access_log a LEFT JOIN core.app_user u ON u.id = a.user_id
UNION ALL
SELECT c.document_id::text, c.created_at, c.corrected_by, u.username, 'reviewer', 'docflow.correction', jsonb_build_object('value', c.old_value), jsonb_build_object('value', c.new_value), NULL
  FROM docflow.field_correction c LEFT JOIN core.app_user u ON u.id = c.corrected_by;

CREATE OR REPLACE VIEW docflow.v_stp_eligibility AS                    -- FR-29 / OPS-08 §7
SELECT s.id AS supplier_id, s.code, k.doc_kind,
       count(d.id) FILTER (WHERE d.state = 'posted')                                                   AS posted,
       count(d.id) FILTER (WHERE d.state = 'posted' AND NOT EXISTS (SELECT 1 FROM docflow.field_correction c WHERE c.document_id = d.id)) AS posted_without_correction,
       round(count(d.id) FILTER (WHERE d.state = 'posted' AND NOT EXISTS (SELECT 1 FROM docflow.field_correction c WHERE c.document_id = d.id))::numeric
             / NULLIF(count(d.id) FILTER (WHERE d.state = 'posted'), 0), 4)                             AS accuracy,
       COALESCE(sc.enabled, false) AS stp_enabled
  FROM docflow.supplier s
  CROSS JOIN (SELECT unnest(enum_range(NULL::docflow.doc_kind)) AS doc_kind) k
  LEFT JOIN docflow.document d ON d.supplier_id = s.id AND d.doc_kind = k.doc_kind
  LEFT JOIN docflow.stp_config sc ON sc.supplier_id = s.id AND sc.doc_kind = k.doc_kind
 GROUP BY s.id, s.code, k.doc_kind, sc.enabled;

CREATE OR REPLACE VIEW docflow.v_template_drift AS                     -- ADR-D08
SELECT t.id AS template_id, s.code AS supplier_code, t.doc_kind, t.version, t.accuracy_measured AS accuracy_at_activation,
       e.accuracy AS accuracy_recent, e.posted_without_correction, e.posted,
       (t.accuracy_measured - e.accuracy) > 0.05 AS drift_alert
  FROM docflow.supplier_template t JOIN docflow.supplier s ON s.id = t.supplier_id
  JOIN docflow.v_stp_eligibility e ON e.supplier_id = t.supplier_id AND e.doc_kind = t.doc_kind
 WHERE t.active;

CREATE OR REPLACE VIEW docflow.v_eval_latest AS                        -- AI-09
SELECT e.*, b.header_acc AS baseline_header, b.line_acc AS baseline_line, b.class_acc AS baseline_class
  FROM docflow.eval_run e LEFT JOIN docflow.eval_run b ON b.id = e.baseline_run_id
 WHERE e.id = (SELECT max(id) FROM docflow.eval_run);

CREATE OR REPLACE VIEW docflow.v_pipeline_backlog AS
SELECT state, count(*) AS n, min(received_at) AS oldest, extract(epoch FROM (now() - min(received_at)))::integer AS oldest_age_s
  FROM docflow.document WHERE state IN ('received', 'classified', 'extracted', 'posting') GROUP BY state;

-- =====================================================================
-- 16. ROLES AND GRANTS
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')       THEN CREATE ROLE app_rw       NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')       THEN CREATE ROLE app_ro       NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'poster_rw')    THEN CREATE ROLE poster_rw    NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor_ro')   THEN CREATE ROLE auditor_ro   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_ro') THEN CREATE ROLE analytics_ro NOLOGIN; END IF;
END $$;

GRANT USAGE ON SCHEMA core, docflow, audit TO app_rw, app_ro, poster_rw, auditor_ro, analytics_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, docflow TO app_rw;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA audit TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA docflow, audit TO app_rw;

-- poster: the only role that writes postings and export files; reads what it needs; cannot approve or edit
GRANT SELECT ON ALL TABLES IN SCHEMA core, docflow TO poster_rw;
GRANT INSERT, UPDATE ON docflow.posting, docflow.export_file, docflow.notification TO poster_rw;
GRANT UPDATE (state, updated_at) ON docflow.document TO poster_rw;
GRANT INSERT ON audit.log TO poster_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA docflow, audit TO poster_rw;
REVOKE INSERT, UPDATE, DELETE ON docflow.approval, docflow.field_correction, docflow.approval_policy, docflow.stp_config, docflow.model_registry FROM poster_rw;

GRANT SELECT ON ALL TABLES IN SCHEMA core, docflow, audit TO app_ro;

-- auditor: the audit export and document summaries; no field values, no originals
GRANT SELECT ON docflow.v_audit_export, docflow.v_document_summary, audit.log, docflow.access_log, docflow.approval, docflow.posting TO auditor_ro;

-- analytics: no identities, no document content
GRANT SELECT ON docflow.v_stp_eligibility, docflow.v_template_drift, docflow.v_eval_latest, docflow.v_pipeline_backlog, docflow.validation_result, docflow.eval_run TO analytics_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA core, docflow GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, docflow GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT INSERT, SELECT ON TABLES TO app_rw;

-- =====================================================================
-- 17. MIGRATION RECORD
-- =====================================================================
INSERT INTO docflow.migration (version, notes) VALUES ('docflow_0001', 'DocFlow extension over the platform docflow schema — DDS-08 v1.0');
