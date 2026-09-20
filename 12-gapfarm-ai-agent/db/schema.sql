-- =====================================================================
--  GAPFarm AI — AI Farmer Agent — database schema  (DDS-12)
--  Target   : PostgreSQL 16 + PostGIS 3.4 + pgvector >= 0.7   (image: deploy/postgres/Dockerfile)
--  Schemas  : farm (all business data — the name DDS-00 §12.1 reserves), audit (append-only)
--  Separate deployment from FactoryBrain (SAD-00 §13 "none"). Sections marked [platform] are copied from
--  00-factorybrain-platform/db/schema.sql: the helper functions byte-identically, audit.log / audit.auth_event
--  with core.app_user -> farm.app_user (TEST-12 TC-002).
--
--  The GAP rules of SRS-12 are DATABASE RULES here (DDS-12 DD-G01..G09):
--    C-03 / FR-14 / AC-06  scouting_record, input_usage, harvest are append-only; a correction is version + 1
--    NFR-04                every record version is hash-chained per zone (record_chain); exports carry the head
--    FR-11 / AC-04         a harvest row (or a harvest task completion) is refused before phi_clear_at(zone)
--    C-02 / FR-28 / AC-08  a recommendation, an input-usage row or an agent answer may name approved products only
--    C-04 / AI-05 / AI-06  a diagnosis has 1..3 calibrated candidates or is refused (ood) with none
--    FR-05                 low confidence -> review_queue;  FR-07 / AI-09  a correction -> label_example
--    FR-09 / FR-16 / AC-03 confirming a diagnosis inserts the scouting record, the tasks and the reminders
--    AI-02 / AI-04 / AI-05 a model is released only with a passed FIELD evaluation, size within limit, calibration
--    FR-21 / FR-22         telemetry unit must match the sensor kind; a fault raises a maintenance task
--    NFR-02 / AC-07        sync batches are idempotent;  NFR-05  erasure pseudonymises, the chain survives
--
--  Apply:  psql -v ON_ERROR_STOP=1 -f schema.sql   (then optionally seed_demo.sql)
-- =====================================================================

-- =====================================================================
-- 1. EXTENSIONS
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_bytes, digest (hash chain)
CREATE EXTENSION IF NOT EXISTS postgis;       -- geography: farm point, zone polygons, ST_Contains, ST_Area
CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector: crop-library chunks for agent citations (FR-27)
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- product / condition name search

-- =====================================================================
-- 2. SCHEMAS
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS farm;
CREATE SCHEMA IF NOT EXISTS audit;

COMMENT ON SCHEMA farm  IS 'GAPFarm business data. GAP compliance rules are triggers here (DDS-12 DD-G01..G09).';
COMMENT ON SCHEMA audit IS 'Append-only audit log. INSERT only; no UPDATE or DELETE grants.';

-- =====================================================================
-- 3. HELPER FUNCTIONS  [platform — byte-identical, 00/db/schema.sql lines 63–104]
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
CREATE TYPE farm.user_role         AS ENUM ('farmer', 'farm_manager', 'agronomist', 'auditor', 'admin');
CREATE TYPE farm.observation_kind  AS ENUM ('scouting', 'followup', 'harvest_check', 'sensor_maintenance');
CREATE TYPE farm.condition_kind    AS ENUM ('disease', 'pest', 'deficiency', 'healthy', 'unknown');
CREATE TYPE farm.severity_level    AS ENUM ('none', 'low', 'moderate', 'severe');
CREATE TYPE farm.diagnosis_status  AS ENUM ('proposed', 'needs_review', 'refused', 'confirmed', 'corrected', 'superseded');
CREATE TYPE farm.computed_on       AS ENUM ('device', 'server');
CREATE TYPE farm.record_kind       AS ENUM ('scouting', 'input_usage', 'harvest');
CREATE TYPE farm.task_kind         AS ENUM ('inspect', 'treat', 'followup', 'harvest', 'sensor_maintenance', 'other');
CREATE TYPE farm.task_status       AS ENUM ('open', 'done', 'cancelled');
CREATE TYPE farm.task_priority     AS ENUM ('normal', 'critical');
CREATE TYPE farm.channel_kind      AS ENUM ('line', 'discord', 'push', 'email');
CREATE TYPE farm.reminder_status   AS ENUM ('scheduled', 'sent', 'failed', 'cancelled');
CREATE TYPE farm.sensor_status     AS ENUM ('ok', 'fault', 'offline', 'retired');
CREATE TYPE farm.fault_kind        AS ENUM ('stuck', 'out_of_range', 'offline');
CREATE TYPE farm.advisory_kind     AS ENUM ('disease_risk', 'spray_conflict', 'irrigation', 'phi', 'compliance_gap');
CREATE TYPE farm.advisory_level    AS ENUM ('info', 'elevated', 'high');
CREATE TYPE farm.forecast_kind     AS ENUM ('harvest_date', 'yield');
CREATE TYPE farm.forecast_status   AS ENUM ('ok', 'insufficient_data');
CREATE TYPE farm.model_kind        AS ENUM ('server', 'device');
CREATE TYPE farm.model_status      AS ENUM ('draft', 'evaluated', 'released', 'retired');
CREATE TYPE farm.eval_set_kind     AS ENUM ('field', 'lab');
CREATE TYPE farm.product_type      AS ENUM ('fungicide', 'insecticide', 'herbicide', 'fertilizer', 'biocontrol', 'other');
CREATE TYPE farm.data_request_kind AS ENUM ('export', 'erasure');
CREATE TYPE farm.request_status    AS ENUM ('open', 'completed', 'rejected');
CREATE TYPE farm.review_reason     AS ENUM ('low_confidence', 'ood', 'farmer_request', 'severe');

-- =====================================================================
-- 5. SETTINGS (one row — the constants the guards read)
-- =====================================================================
CREATE TABLE farm.setting (
    id                    smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    review_threshold      numeric(4,3) NOT NULL DEFAULT 0.600 CHECK (review_threshold > 0 AND review_threshold < 1),   -- FR-05
    ood_threshold         numeric(6,3) NOT NULL DEFAULT 0.000,        -- energy score above which an image is refused (AI-06); model-specific override in calibration_version
    severity_low_max_pct  numeric(5,2) NOT NULL DEFAULT 5.00,
    severity_mod_max_pct  numeric(5,2) NOT NULL DEFAULT 15.00 CHECK (severity_mod_max_pct > severity_low_max_pct),
    escalation_hours      integer      NOT NULL DEFAULT 24 CHECK (escalation_hours > 0),                              -- FR-20
    sensor_offline_minutes integer     NOT NULL DEFAULT 60 CHECK (sensor_offline_minutes >= 60),                       -- FR-22
    prediction_min_seasons integer     NOT NULL DEFAULT 3 CHECK (prediction_min_seasons >= 2),                         -- AC-09
    device_model_max_mb   numeric(6,1) NOT NULL DEFAULT 25.0 CHECK (device_model_max_mb <= 25.0),                      -- AI-04
    gate_top1_min         numeric(4,3) NOT NULL DEFAULT 0.800 CHECK (gate_top1_min >= 0.800),                          -- AI-02
    gate_top3_min         numeric(4,3) NOT NULL DEFAULT 0.930 CHECK (gate_top3_min >= 0.930),
    followup_days         integer      NOT NULL DEFAULT 7,
    updated_at            timestamptz  NOT NULL DEFAULT now()
);
INSERT INTO farm.setting (id) VALUES (1);
COMMENT ON TABLE farm.setting IS 'Constants the guard triggers read. The CHECKs pin the SRS minima (AI-02, AI-04, FR-22); deploy/gapfarm.yaml mirrors them (TC-006).';

-- =====================================================================
-- 6. USERS, FARMS, ZONES, CROPS
-- =====================================================================
CREATE TABLE farm.app_user (
    id                   uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    username             text NOT NULL UNIQUE,
    display_name         text NOT NULL,
    role                 farm.user_role NOT NULL DEFAULT 'farmer',
    phone                text,
    line_user_id         text,
    locale               text NOT NULL DEFAULT 'th' CHECK (locale IN ('th', 'en')),
    pdpa_consent_version text,
    pdpa_consent_at      timestamptz,
    active               boolean NOT NULL DEFAULT true,
    erased_at            timestamptz,                    -- NFR-05: identity pseudonymised (trg_pdpa_erasure)
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_app_user_updated BEFORE UPDATE ON farm.app_user FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
COMMENT ON TABLE farm.app_user IS 'Identity. agent_ro is granted (id, role, locale) only; authorship on records is the pseudonym farm.pseudonym(id) (DD-G09).';

CREATE TABLE farm.gap_scheme (
    code                  text PRIMARY KEY,               -- 'thaigap', 'globalgap'
    name                  text NOT NULL,
    version               text NOT NULL,
    record_templates_json jsonb NOT NULL DEFAULT '{}'::jsonb,   -- per record_kind: ordered fields for the export (IF-66)
    created_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE farm.gap_scheme IS 'GAP scheme as data (SRS §10 "scheme-configurable record templates"); deploy/schemes/*.yaml is the import format.';

CREATE TABLE farm.gap_scheme_rule (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    scheme_code     text NOT NULL REFERENCES farm.gap_scheme(code),
    rule_code       text NOT NULL,                       -- 'scouting_interval', 'input_usage_complete', 'harvest_traceability'
    record_kind     farm.record_kind NOT NULL,
    max_gap_days    integer CHECK (max_gap_days IS NULL OR max_gap_days > 0),   -- FR-15: no record of this kind for more than N days is a gap
    mandatory       boolean NOT NULL DEFAULT true,
    description_th  text NOT NULL,
    description_en  text,
    UNIQUE (scheme_code, rule_code)
);

CREATE TABLE farm.farm (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code               text NOT NULL UNIQUE,              -- MQTT topic segment (IF-12)
    name               text NOT NULL,
    owner_id           uuid NOT NULL REFERENCES farm.app_user(id),
    location           geography(Point, 4326) NOT NULL,   -- weather lookups (FR-23); PDPA-protected (agent_ro has no grant)
    gap_scheme         text NOT NULL REFERENCES farm.gap_scheme(code),
    timezone           text NOT NULL DEFAULT 'Asia/Bangkok',
    quiet_hours_start  time NOT NULL DEFAULT '20:00',     -- FR-18
    quiet_hours_end    time NOT NULL DEFAULT '06:00',
    reminder_time      time NOT NULL DEFAULT '07:00',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_farm_updated BEFORE UPDATE ON farm.farm FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE farm.farm_member (
    farm_id   uuid NOT NULL REFERENCES farm.farm(id) ON DELETE CASCADE,
    user_id   uuid NOT NULL REFERENCES farm.app_user(id) ON DELETE CASCADE,
    role      farm.user_role NOT NULL,
    PRIMARY KEY (farm_id, user_id)
);

CREATE TABLE farm.crop (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code             text NOT NULL UNIQUE,                -- 'chili'
    name_th          text NOT NULL,
    name_en          text NOT NULL,
    variety          text,
    family           text NOT NULL,                       -- model family (AI-01)
    gdd_base_c       numeric(4,1) NOT NULL DEFAULT 10.0,  -- FR-30
    stage_model_json jsonb NOT NULL,                      -- [{"stage":"seedling","gdd_from":0}, ..., {"stage":"maturity","gdd_from":1500}]
    created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN farm.crop.stage_model_json IS 'Ordered stages with the accumulated GDD at which each begins; the last stage is maturity (AI-08). Data, not code.';

CREATE TABLE farm.condition (
    code                       text PRIMARY KEY,          -- 'cercospora_leaf_spot'
    crop_id                    uuid NOT NULL REFERENCES farm.crop(id),
    kind                       farm.condition_kind NOT NULL,
    name_th                    text NOT NULL,
    name_en                    text NOT NULL,
    distinguishing_features_th text NOT NULL,             -- FR-03
    how_to_confirm_th          text NOT NULL,
    fast_spreading             boolean NOT NULL DEFAULT false,   -- FR-29
    active                     boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE farm.condition IS 'Crop library: the classes the diagnosis model may output, with the FR-03 texts. A candidate must reference one (trg_diagnosis_shape).';

CREATE TABLE farm.zone (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    farm_id     uuid NOT NULL REFERENCES farm.farm(id) ON DELETE CASCADE,
    code        text NOT NULL,                            -- 'B' — MQTT topic segment, record numbers
    name        text NOT NULL,
    boundary    geography(Polygon, 4326),
    area_rai    numeric(8,2) NOT NULL CHECK (area_rai > 0),
    crop_id     uuid REFERENCES farm.crop(id),
    planted_at  date,
    season_no   integer NOT NULL DEFAULT 1 CHECK (season_no >= 1),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (farm_id, code)
);
CREATE TRIGGER trg_zone_updated BEFORE UPDATE ON farm.zone FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE farm.device (
    id                      uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id                 uuid NOT NULL REFERENCES farm.app_user(id) ON DELETE CASCADE,
    platform                text NOT NULL CHECK (platform IN ('pwa', 'android', 'ios')),
    app_version             text,
    device_model_version    text,                         -- on-device model (AI-04)
    push_token_ref          text,                         -- reference to a secret store entry, never the token
    last_sync_at            timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.sync_batch (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    device_id        uuid NOT NULL REFERENCES farm.device(id),
    idempotency_key  text NOT NULL UNIQUE,                -- IF-63: client-generated; a replay is refused and the stored result returned
    received_at      timestamptz NOT NULL DEFAULT now(),
    item_count       integer NOT NULL CHECK (item_count >= 0),
    applied_count    integer NOT NULL DEFAULT 0,
    result_json      jsonb NOT NULL DEFAULT '[]'::jsonb   -- [{client_id, server_id, entity, status}]
);

-- =====================================================================
-- 7. OBSERVATIONS, PHOTOS, DIAGNOSES, REVIEW, CORRECTIONS
-- =====================================================================
CREATE TABLE farm.observation (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),   -- client-generated UUIDv7 when created offline
    zone_id           uuid NOT NULL REFERENCES farm.zone(id),
    ts                timestamptz NOT NULL,
    kind              farm.observation_kind NOT NULL DEFAULT 'scouting',
    photos_json       jsonb NOT NULL DEFAULT '[]'::jsonb,   -- ordered photo ids (SRS §5 name); rows in farm.photo
    severity          farm.severity_level,
    area_pct          numeric(5,2) CHECK (area_pct IS NULL OR (area_pct >= 0 AND area_pct <= 100)),   -- FR-06
    plants_affected   integer CHECK (plants_affected IS NULL OR plants_affected >= 0),
    plants_inspected  integer CHECK (plants_inspected IS NULL OR plants_inspected >= 0),
    growth_stage      text,                               -- FR-04, from the stage model at ts
    gps               geography(Point, 4326),
    reporter_id       uuid REFERENCES farm.app_user(id),
    reporter_ref      text NOT NULL,                      -- pseudonym (DD-G09)
    followup_of       uuid REFERENCES farm.observation(id),   -- FR-19
    followup_delta_pct numeric(6,2),                      -- area_pct − original area_pct (set by trg_followup_compare)
    sync_batch_id     uuid REFERENCES farm.sync_batch(id),
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.photo (
    id             uuid PRIMARY KEY,                      -- client-generated
    observation_id uuid NOT NULL REFERENCES farm.observation(id) ON DELETE CASCADE,
    uri            text NOT NULL,                         -- s3://photos/<farm>/<observation>/<photo>.jpg (private, signed URLs — NFR-06)
    sha256         text NOT NULL,
    bytes          integer NOT NULL CHECK (bytes > 0 AND bytes <= 1048576),   -- ≤ 1 MB after compression
    width          integer NOT NULL,
    height         integer NOT NULL,
    gate_json      jsonb NOT NULL,                        -- {"blur": 0.71, "exposure": 0.55, "distance": "ok", "pass": true, "guidance_th": null}  (FR-01)
    exif_stripped  boolean NOT NULL DEFAULT true CHECK (exif_stripped),   -- the file never carries location; the row does (gps on observation)
    taken_at       timestamptz NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.diagnosis (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    observation_id      uuid NOT NULL REFERENCES farm.observation(id) ON DELETE CASCADE,
    model_version       text NOT NULL,
    calibration_version text,                             -- AI-05; required unless ood
    computed_on         farm.computed_on NOT NULL DEFAULT 'server',
    candidates_json     jsonb NOT NULL DEFAULT '[]'::jsonb,   -- 1..3 of {condition_code, probability, distinguishing_features_th, how_to_confirm_th}
    ood                 boolean NOT NULL DEFAULT false,
    ood_score           numeric(8,3),
    top1_prob           numeric(4,3),                     -- set by trg_diagnosis_shape
    chosen_id           text REFERENCES farm.condition(code),   -- the confirmed candidate
    status              farm.diagnosis_status NOT NULL DEFAULT 'proposed',
    consult_agronomist  boolean NOT NULL DEFAULT false,   -- FR-29
    confirmed_by        uuid REFERENCES farm.app_user(id),
    confirmed_at        timestamptz,
    superseded_by       uuid REFERENCES farm.diagnosis(id),   -- server re-score of a device result (ADR-G02)
    created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE farm.diagnosis IS 'Calibrated top-3 or a refusal. Shape is enforced by trg_diagnosis_shape (DD-G04); confirmation creates the record, tasks and reminders (DD-G05).';

CREATE TABLE farm.review_queue (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    diagnosis_id uuid NOT NULL REFERENCES farm.diagnosis(id) ON DELETE CASCADE,
    reason       farm.review_reason NOT NULL,
    queued_at    timestamptz NOT NULL DEFAULT now(),
    assigned_to  uuid REFERENCES farm.app_user(id),
    resolved_at  timestamptz,
    resolution   text CHECK (resolution IS NULL OR resolution IN ('confirmed', 'corrected', 'better_photo', 'refused'))
);

CREATE TABLE farm.diagnosis_correction (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    diagnosis_id   uuid NOT NULL REFERENCES farm.diagnosis(id),
    reviewer_id    uuid NOT NULL REFERENCES farm.app_user(id),
    corrected_code text NOT NULL REFERENCES farm.condition(code),
    severity       farm.severity_level,
    note_th        text,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.label_example (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    correction_id       uuid NOT NULL UNIQUE REFERENCES farm.diagnosis_correction(id),
    photo_ids           uuid[] NOT NULL,
    label_code          text NOT NULL REFERENCES farm.condition(code),
    original_candidates jsonb NOT NULL,
    model_version       text NOT NULL,
    reviewer_ref        text NOT NULL,                    -- pseudonym: provenance without identity (AI-09, NFR-05)
    created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE farm.label_example IS 'The field dataset grows from agronomist corrections with provenance (FR-07, AI-09). Written only by trg_correction_dataset.';

-- =====================================================================
-- 8. APPROVED INPUTS (C-02) AND RECOMMENDATIONS
-- =====================================================================
CREATE TABLE farm.input_product (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code              text NOT NULL UNIQUE,
    name              text NOT NULL,                      -- trade name as on the label
    name_th           text,
    active_ingredient text NOT NULL,
    type              farm.product_type NOT NULL,
    phi_days          integer NOT NULL CHECK (phi_days >= 0),        -- FR-11 (example values in the seed — verify against the registered label)
    rei_hours         integer NOT NULL CHECK (rei_hours >= 0),       -- FR-28 re-entry interval
    rainfast_hours    integer CHECK (rainfast_hours IS NULL OR rainfast_hours >= 0),   -- FR-25
    approved          boolean NOT NULL DEFAULT false,
    author_id         uuid NOT NULL REFERENCES farm.app_user(id),
    approved_by       uuid REFERENCES farm.app_user(id),
    approved_at       timestamptz,
    unapproved_reason text,
    label_uri         text,                               -- mandatory when approved (IF-65)
    mrl_json          jsonb NOT NULL DEFAULT '{}'::jsonb, -- {"chili": {"mg_per_kg": 2.0, "source": "..."}}
    crops             text[] NOT NULL DEFAULT '{}',       -- crop codes
    target_conditions text[] NOT NULL DEFAULT '{}',       -- condition codes
    cautions_th       text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_input_product_updated BEFORE UPDATE ON farm.input_product FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
COMMENT ON TABLE farm.input_product IS 'The ONLY source of product names the system may show or the agent may say (C-02, AI-07). Approval needs a label URI and a second person (trg_product_approval).';

CREATE TABLE farm.treatment_recommendation (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    diagnosis_id   uuid NOT NULL REFERENCES farm.diagnosis(id) ON DELETE CASCADE,
    product_id     uuid NOT NULL REFERENCES farm.input_product(id),
    phi_days       integer NOT NULL,                      -- snapshot at recommendation time
    rei_hours      integer NOT NULL,
    cautions_th    text,
    rationale_th   text NOT NULL,
    spray_conflict boolean NOT NULL DEFAULT false,        -- FR-25 at the time of recommendation
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 9. GAP RECORDS — append-only, versioned, hash-chained (DD-G01, DD-G02)
-- =====================================================================
CREATE TABLE farm.record_counter (
    farm_id  uuid NOT NULL REFERENCES farm.farm(id),
    kind     farm.record_kind NOT NULL,
    year     integer NOT NULL,
    last_no  integer NOT NULL DEFAULT 0,
    PRIMARY KEY (farm_id, kind, year)
);

CREATE TABLE farm.record_chain (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    zone_id        uuid NOT NULL REFERENCES farm.zone(id),
    seq            integer NOT NULL,                      -- per zone, 1..n
    record_kind    farm.record_kind NOT NULL,
    record_no      text NOT NULL,
    record_version integer NOT NULL,
    record_id      uuid NOT NULL,
    payload        jsonb NOT NULL,                        -- the canonical record content (what is hashed)
    prev_hash      text,                                  -- NULL only for seq 1
    hash           text NOT NULL,                         -- sha256(prev_hash || payload::text)
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (zone_id, seq),
    UNIQUE (record_kind, record_id)
);
COMMENT ON TABLE farm.record_chain IS 'One hash chain per zone across all record kinds (NFR-04). Written only by trg_record_chain; append-only; farm.verify_chain(zone) recomputes it; the export manifest carries the head.';

CREATE TABLE farm.scouting_record (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    record_no          text NOT NULL,                     -- 'SC-2026-0412'
    record_version     integer NOT NULL DEFAULT 1 CHECK (record_version >= 1),
    supersedes         uuid REFERENCES farm.scouting_record(id),
    reason_th          text,                              -- mandatory for version > 1
    zone_id            uuid NOT NULL REFERENCES farm.zone(id),
    observed_at        timestamptz NOT NULL,
    observation_id     uuid REFERENCES farm.observation(id),
    diagnosis_id       uuid REFERENCES farm.diagnosis(id),
    condition_code     text REFERENCES farm.condition(code),
    severity           farm.severity_level NOT NULL,
    area_pct           numeric(5,2),
    plants_affected    integer,
    plants_inspected   integer,
    evidence_photo_ids uuid[] NOT NULL DEFAULT '{}',
    notes_th           text,
    author_id          uuid REFERENCES farm.app_user(id),
    author_ref         text NOT NULL,
    prev_hash          text,
    hash               text NOT NULL DEFAULT '',          -- set by trg_record_chain
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (record_no, record_version)
);

CREATE TABLE farm.input_usage (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    record_no        text NOT NULL,                       -- 'IU-2026-0031'
    record_version   integer NOT NULL DEFAULT 1 CHECK (record_version >= 1),
    supersedes       uuid REFERENCES farm.input_usage(id),
    reason_th        text,
    zone_id          uuid NOT NULL REFERENCES farm.zone(id),
    product_id       uuid NOT NULL REFERENCES farm.input_product(id),
    ts               timestamptz NOT NULL,
    dose             numeric(10,3) NOT NULL CHECK (dose > 0),
    unit             text NOT NULL,                       -- 'ml/20L', 'g/rai'
    method           text NOT NULL,                       -- 'knapsack_spray', 'drip', 'broadcast'
    applicator_id    uuid REFERENCES farm.app_user(id),
    applicator_ref   text NOT NULL,
    weather_json     jsonb NOT NULL,                      -- {"temp_c":..,"rh_pct":..,"wind_ms":..,"rain_next_12h_mm":..,"source":..}
    ppe              text[] NOT NULL,                     -- FR-10, non-empty
    phi_days         integer NOT NULL,                    -- snapshot from the product at application (trg_input_usage_approved)
    rei_hours        integer NOT NULL,
    phi_clear_at     timestamptz GENERATED ALWAYS AS (ts + make_interval(days => phi_days)) STORED,
    diagnosis_id     uuid REFERENCES farm.diagnosis(id),
    author_id        uuid REFERENCES farm.app_user(id),
    author_ref       text NOT NULL,
    prev_hash        text,
    hash             text NOT NULL DEFAULT '',
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (record_no, record_version)
);

CREATE TABLE farm.harvest (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    record_no         text NOT NULL,                      -- 'HV-2026-0007'
    record_version    integer NOT NULL DEFAULT 1 CHECK (record_version >= 1),
    supersedes        uuid REFERENCES farm.harvest(id),
    reason_th         text,
    zone_id           uuid NOT NULL REFERENCES farm.zone(id),
    lot_code          text NOT NULL,
    harvested_at      timestamptz NOT NULL,
    qty               numeric(10,2) NOT NULL CHECK (qty > 0),
    unit              text NOT NULL DEFAULT 'kg',
    grade             text,
    traceability_json jsonb NOT NULL DEFAULT '{}'::jsonb, -- filled by trg_harvest_phi from farm.trace_lot() (FR-12)
    author_id         uuid REFERENCES farm.app_user(id),
    author_ref        text NOT NULL,
    prev_hash         text,
    hash              text NOT NULL DEFAULT '',
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (record_no, record_version),
    UNIQUE (lot_code, record_version)
);

-- =====================================================================
-- 10. TASKS, TEMPLATES, REMINDERS, ESCALATIONS
-- =====================================================================
CREATE TABLE farm.task_template (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    condition_kind   farm.condition_kind,                 -- NULL = any
    min_severity     farm.severity_level NOT NULL DEFAULT 'low',
    ordinal          smallint NOT NULL,
    task_kind        farm.task_kind NOT NULL,
    description_th   text NOT NULL,                       -- may contain {n_plants}
    description_en   text NOT NULL,
    due_offset_days  integer NOT NULL CHECK (due_offset_days >= 0),
    priority         farm.task_priority NOT NULL DEFAULT 'normal',
    n_plants         integer,
    active           boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE farm.task_template IS 'What a confirmed diagnosis generates (FR-16). Appendix A: inspect 10 nearby plants today; consider an approved spray tomorrow; follow-up photo in 7 days.';

CREATE TABLE farm.task (
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    zone_id             uuid NOT NULL REFERENCES farm.zone(id),
    kind                farm.task_kind NOT NULL,
    description_th      text NOT NULL,
    description_en      text,
    due_at              timestamptz NOT NULL,
    owner_id            uuid REFERENCES farm.app_user(id),
    status              farm.task_status NOT NULL DEFAULT 'open',
    priority            farm.task_priority NOT NULL DEFAULT 'normal',
    evidence_json       jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {"photo_ids": [...], "observation_id": ..., "note_th": ...}
    source_diagnosis_id uuid REFERENCES farm.diagnosis(id),
    template_id         uuid REFERENCES farm.task_template(id),
    sensor_id           uuid,                             -- maintenance tasks (FK added after farm.sensor)
    completed_by        uuid REFERENCES farm.app_user(id),
    completed_at        timestamptz,
    escalated_at        timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_task_updated BEFORE UPDATE ON farm.task FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE farm.notification_channel (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id     uuid NOT NULL REFERENCES farm.app_user(id) ON DELETE CASCADE,
    kind        farm.channel_kind NOT NULL,
    address_ref text NOT NULL,                            -- LINE userId / webhook id / push token reference — never a secret value
    enabled     boolean NOT NULL DEFAULT true,
    UNIQUE (user_id, kind)
);

CREATE TABLE farm.reminder (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    task_id       uuid NOT NULL REFERENCES farm.task(id) ON DELETE CASCADE,
    user_id       uuid NOT NULL REFERENCES farm.app_user(id),
    channel_kind  farm.channel_kind NOT NULL,
    scheduled_at  timestamptz NOT NULL,                   -- shifted out of quiet hours by trg_reminder_quiet_hours (FR-18)
    sent_at       timestamptz,
    status        farm.reminder_status NOT NULL DEFAULT 'scheduled',
    message_th    text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.escalation (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    task_id         uuid NOT NULL REFERENCES farm.task(id) ON DELETE CASCADE,
    to_user_id      uuid NOT NULL REFERENCES farm.app_user(id),
    reason          text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    acknowledged_at timestamptz
);

-- =====================================================================
-- 11. SENSORS, TELEMETRY, WEATHER, RULES, ADVISORIES
-- =====================================================================
CREATE TABLE farm.sensor_kind (
    code            text PRIMARY KEY,                     -- 'soil_moisture', 'air_temp', 'air_rh', 'soil_ec', 'soil_ph', 'rain'
    unit            text NOT NULL,                        -- '%', 'C', '%', 'mS/cm', 'pH', 'mm'
    min_value       numeric(10,3) NOT NULL,
    max_value       numeric(10,3) NOT NULL CHECK (max_value > min_value),
    stuck_readings  integer NOT NULL DEFAULT 12 CHECK (stuck_readings >= 3),   -- FR-22
    description_th  text
);

CREATE TABLE farm.sensor (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    zone_id       uuid NOT NULL REFERENCES farm.zone(id),
    kind          text NOT NULL REFERENCES farm.sensor_kind(code),
    unit          text NOT NULL,                          -- must equal sensor_kind.unit (trg_sensor_unit)
    device_code   text NOT NULL UNIQUE,                   -- MQTT client id; per-device credential (IF-12)
    last_seen_at  timestamptz,
    status        farm.sensor_status NOT NULL DEFAULT 'ok',
    installed_at  date,
    created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE farm.task ADD CONSTRAINT task_sensor_fk FOREIGN KEY (sensor_id) REFERENCES farm.sensor(id);

CREATE TABLE farm.telemetry (
    ts        timestamptz NOT NULL,
    sensor_id uuid NOT NULL REFERENCES farm.sensor(id),
    value     numeric(12,3) NOT NULL,
    quality   text NOT NULL DEFAULT 'ok' CHECK (quality IN ('ok', 'out_of_range', 'stuck', 'late')),
    PRIMARY KEY (sensor_id, ts)
) PARTITION BY RANGE (ts);
CREATE TABLE farm.telemetry_2026_08 PARTITION OF farm.telemetry FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE farm.telemetry_2026_09 PARTITION OF farm.telemetry FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE farm.telemetry_2026_10 PARTITION OF farm.telemetry FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE farm.telemetry_default PARTITION OF farm.telemetry DEFAULT;
COMMENT ON TABLE farm.telemetry IS 'Monthly partitions (scheduler creates next month — OPS-12 §8). ingest_rw has INSERT only.';

CREATE TABLE farm.sensor_fault (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    sensor_id    uuid NOT NULL REFERENCES farm.sensor(id),
    kind         farm.fault_kind NOT NULL,
    detected_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at  timestamptz,
    detail_json  jsonb NOT NULL DEFAULT '{}'::jsonb,
    task_id      uuid REFERENCES farm.task(id)            -- set by trg_sensor_fault_task
);

CREATE TABLE farm.weather_forecast (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    farm_id     uuid NOT NULL REFERENCES farm.farm(id) ON DELETE CASCADE,
    provider    text NOT NULL,
    fetched_at  timestamptz NOT NULL DEFAULT now(),
    valid_from  timestamptz NOT NULL,
    valid_to    timestamptz NOT NULL CHECK (valid_to > valid_from),
    rain_mm     numeric(6,1) NOT NULL DEFAULT 0,
    rain_prob   numeric(4,3) NOT NULL DEFAULT 0 CHECK (rain_prob >= 0 AND rain_prob <= 1),
    temp_c      numeric(4,1),
    rh_pct      numeric(4,1),
    wind_ms     numeric(4,1),
    raw_json    jsonb
);

CREATE TABLE farm.weather_daily (
    farm_id      uuid NOT NULL REFERENCES farm.farm(id) ON DELETE CASCADE,
    day          date NOT NULL,
    tmax_c       numeric(4,1) NOT NULL,
    tmin_c       numeric(4,1) NOT NULL CHECK (tmin_c <= tmax_c),
    rh_mean_pct  numeric(4,1),
    rh_hours_ge  numeric(4,1),                            -- hours with RH ≥ 85 % (risk rules)
    rain_mm      numeric(6,1) NOT NULL DEFAULT 0,
    source       text NOT NULL DEFAULT 'provider',       -- 'provider' | 'sensor'
    PRIMARY KEY (farm_id, day)
);
COMMENT ON TABLE farm.weather_daily IS 'Daily aggregates for GDD (FR-30) and risk rules (FR-24); from the provider or from the farm''s own sensors.';

CREATE TABLE farm.risk_rule (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    crop_id        uuid NOT NULL REFERENCES farm.crop(id),
    condition_code text NOT NULL REFERENCES farm.condition(code),
    rh_min_pct     numeric(4,1) NOT NULL,
    temp_min_c     numeric(4,1) NOT NULL,
    temp_max_c     numeric(4,1) NOT NULL CHECK (temp_max_c > temp_min_c),
    hours_min      numeric(4,1) NOT NULL DEFAULT 6,
    level          farm.advisory_level NOT NULL DEFAULT 'elevated',
    message_th     text NOT NULL,
    source         text NOT NULL,                         -- where the rule comes from (extension bulletin, agronomist)
    active         boolean NOT NULL DEFAULT true
);

CREATE TABLE farm.advisory (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    farm_id           uuid NOT NULL REFERENCES farm.farm(id) ON DELETE CASCADE,
    zone_id           uuid REFERENCES farm.zone(id),
    kind              farm.advisory_kind NOT NULL,
    level             farm.advisory_level NOT NULL,
    message_th        text NOT NULL,
    message_en        text,
    factors_json      jsonb NOT NULL DEFAULT '{}'::jsonb,
    suppressed_reason text,                               -- IF-12: forecast unavailable → stated, not computed
    valid_until       timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 12. AGENT — questions, answers, citations, crop library chunks
-- =====================================================================
CREATE TABLE farm.knowledge_chunk (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    crop_id    uuid REFERENCES farm.crop(id),
    source     text NOT NULL,                             -- bulletin / extension document / label
    title      text NOT NULL,
    lang       text NOT NULL DEFAULT 'th',
    text       text NOT NULL,
    version    text NOT NULL,
    embedding  vector(1024),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.conversation (
    id         uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id    uuid NOT NULL REFERENCES farm.app_user(id),
    farm_id    uuid NOT NULL REFERENCES farm.farm(id),
    locale     text NOT NULL DEFAULT 'th',
    started_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.question (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    conversation_id uuid NOT NULL REFERENCES farm.conversation(id) ON DELETE CASCADE,
    text            text NOT NULL,
    zone_id         uuid REFERENCES farm.zone(id),
    asked_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.answer (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    question_id        uuid NOT NULL UNIQUE REFERENCES farm.question(id) ON DELETE CASCADE,
    text_th            text NOT NULL,
    facts_json         jsonb NOT NULL,                    -- what the model saw (products, records, chunks, phi, forecast)
    products_json      jsonb NOT NULL DEFAULT '[]'::jsonb,   -- product codes named in the answer — approved only (trg_answer_products)
    citations_json     jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{"kind":"chunk"|"record","ref":...}]
    consult_agronomist boolean NOT NULL DEFAULT false,    -- FR-29
    model              text,                              -- NULL = scripted fallback (FR-08)
    fallback           boolean NOT NULL DEFAULT false,
    created_at         timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 13. PREDICTION
-- =====================================================================
CREATE TABLE farm.yield_history (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    zone_id          uuid NOT NULL REFERENCES farm.zone(id),
    season_no        integer NOT NULL,
    planted_at       date NOT NULL,
    harvested_at     date NOT NULL CHECK (harvested_at > planted_at),
    gdd_to_harvest   numeric(8,1),
    yield_kg_per_rai numeric(8,1) NOT NULL CHECK (yield_kg_per_rai >= 0),
    source           text NOT NULL DEFAULT 'harvest_records',
    UNIQUE (zone_id, season_no)
);

CREATE TABLE farm.forecast (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    zone_id      uuid NOT NULL REFERENCES farm.zone(id),
    kind         farm.forecast_kind NOT NULL,
    status       farm.forecast_status NOT NULL DEFAULT 'ok',
    value        numeric(12,2),                           -- yield kg/rai, or harvest date as epoch days (see factors)
    low          numeric(12,2),
    high         numeric(12,2),
    value_date   date,                                    -- harvest_date kind
    low_date     date,
    high_date    date,
    generated_at timestamptz NOT NULL DEFAULT now(),
    factors_json jsonb NOT NULL DEFAULT '{}'::jsonb,      -- FR-31: gdd, stage, seasons used, method, interval basis
    model        text NOT NULL DEFAULT 'gdd_history_v1'
);
COMMENT ON TABLE farm.forecast IS 'Interpretable prediction (AI-08). trg_forecast_interval: status ok needs low ≤ value ≤ high and factors; insufficient_data carries no value (AC-09).';

-- =====================================================================
-- 14. MODELS, EVALUATION, CALIBRATION
-- =====================================================================
CREATE TABLE farm.model_registry (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name        text NOT NULL,
    version     text NOT NULL,
    crop_family text NOT NULL,                            -- AI-01
    kind        farm.model_kind NOT NULL,
    size_mb     numeric(7,1) NOT NULL CHECK (size_mb > 0),
    uri         text NOT NULL,
    status      farm.model_status NOT NULL DEFAULT 'draft',
    released_by uuid REFERENCES farm.app_user(id),
    released_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (name, version, kind)
);

CREATE TABLE farm.model_eval_run (
    id        uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    model_id  uuid NOT NULL REFERENCES farm.model_registry(id) ON DELETE CASCADE,
    set_kind  farm.eval_set_kind NOT NULL,                -- AI-03: only 'field' counts for release
    set_name  text NOT NULL,
    n_images  integer NOT NULL CHECK (n_images > 0),
    top1      numeric(4,3) NOT NULL CHECK (top1 >= 0 AND top1 <= 1),
    top3      numeric(4,3) NOT NULL CHECK (top3 >= 0 AND top3 <= 1),
    ece       numeric(4,3),                               -- expected calibration error (AI-05)
    ood_auroc numeric(4,3),                               -- AI-06
    passed    boolean NOT NULL DEFAULT false,             -- computed by trg_eval_gate
    run_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE farm.calibration_version (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    model_id         uuid NOT NULL REFERENCES farm.model_registry(id) ON DELETE CASCADE,
    version          text NOT NULL,
    temperature      numeric(6,3) NOT NULL CHECK (temperature > 0),
    ece              numeric(4,3) NOT NULL CHECK (ece >= 0 AND ece <= 1),
    ood_threshold    numeric(8,3) NOT NULL,
    reliability_json jsonb NOT NULL,                      -- bins: [{"lo":0.8,"hi":0.9,"confidence":0.85,"accuracy":0.83,"n":120}]
    active           boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (model_id, version)
);

-- =====================================================================
-- 15. EXPORTS, PRIVACY, SUMMARIES, MIGRATIONS
-- =====================================================================
CREATE TABLE farm.export_package (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    farm_id         uuid NOT NULL REFERENCES farm.farm(id),
    zone_id         uuid REFERENCES farm.zone(id),        -- NULL = whole farm
    scheme_code     text NOT NULL REFERENCES farm.gap_scheme(code),
    period_from     date NOT NULL,
    period_to       date NOT NULL CHECK (period_to >= period_from),
    requested_by    uuid REFERENCES farm.app_user(id),
    generated_at    timestamptz NOT NULL DEFAULT now(),
    record_count    integer NOT NULL DEFAULT 0,
    gap_count       integer NOT NULL DEFAULT 0,
    chain_heads     jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {zone_code: {"seq": n, "hash": ...}}
    manifest_json   jsonb NOT NULL DEFAULT '{}'::jsonb,   -- IF-66
    verify_hash     text NOT NULL DEFAULT '',             -- sha256 over the manifest (set by trg_export_hash)
    uri_pdf         text,
    uri_xlsx        text
);

CREATE TABLE farm.data_request (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id       uuid NOT NULL REFERENCES farm.app_user(id),
    kind          farm.data_request_kind NOT NULL,
    status        farm.request_status NOT NULL DEFAULT 'open',
    requested_at  timestamptz NOT NULL DEFAULT now(),
    completed_at  timestamptz,
    package_uri   text,
    note          text
);

CREATE TABLE farm.weekly_summary (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    farm_id     uuid NOT NULL REFERENCES farm.farm(id) ON DELETE CASCADE,
    week_start  date NOT NULL,
    facts_json  jsonb NOT NULL,                           -- issues, treatments, upcoming tasks, harvest outlook (FR-32)
    text_th     text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (farm_id, week_start)
);

CREATE TABLE farm.migration (
    id         text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 16. AUDIT  [platform — identical modulo core.app_user -> farm.app_user]
-- =====================================================================
CREATE TABLE audit.log (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts             timestamptz NOT NULL DEFAULT now(),
    user_id        uuid        REFERENCES farm.app_user(id) ON DELETE SET NULL,
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
    user_id    uuid REFERENCES farm.app_user(id) ON DELETE SET NULL,
    event      text NOT NULL CHECK (event IN ('login_ok','login_fail','logout','token_refresh',
                                              'password_change','mfa_fail','locked','key_rotated')),
    ip         inet,
    detail     text
);

-- =====================================================================
-- 17. FUNCTIONS — the deterministic logic (SQL twins re-derived in Python, TEST-12 TC-005)
-- =====================================================================

-- Pseudonymous authorship (DD-G09): identity never enters a record or the chain.
CREATE OR REPLACE FUNCTION farm.pseudonym(p_user uuid) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_user IS NULL THEN 'u-anonymous' ELSE 'u-' || left(encode(digest(p_user::text, 'sha256'), 'hex'), 10) END
$$;

-- Record numbers: SC-2026-0412, IU-2026-0031, HV-2026-0007 — per farm, kind and year.
CREATE OR REPLACE FUNCTION farm.next_record_no(p_farm uuid, p_kind farm.record_kind, p_at timestamptz) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_year int := extract(year FROM p_at)::int; v_no int; v_prefix text;
BEGIN
    v_prefix := CASE p_kind WHEN 'scouting' THEN 'SC' WHEN 'input_usage' THEN 'IU' ELSE 'HV' END;
    INSERT INTO farm.record_counter (farm_id, kind, year, last_no) VALUES (p_farm, p_kind, v_year, 1)
        ON CONFLICT (farm_id, kind, year) DO UPDATE SET last_no = farm.record_counter.last_no + 1
        RETURNING last_no INTO v_no;
    RETURN format('%s-%s-%s', v_prefix, v_year, lpad(v_no::text, 4, '0'));
END $$;

-- Severity from the affected leaf-area fraction (FR-06). Bands from farm.setting.
CREATE OR REPLACE FUNCTION farm.severity_level(p_area_pct numeric) RETURNS farm.severity_level LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_area_pct IS NULL OR p_area_pct <= 0 THEN 'none'::farm.severity_level
                WHEN p_area_pct < s.severity_low_max_pct THEN 'low'::farm.severity_level
                WHEN p_area_pct <= s.severity_mod_max_pct THEN 'moderate'::farm.severity_level
                ELSE 'severe'::farm.severity_level END
    FROM farm.setting s WHERE s.id = 1
$$;

-- Hash chain (NFR-04): sha256(prev_hash || canonical payload).
CREATE OR REPLACE FUNCTION farm.record_hash(p_prev text, p_payload jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT encode(digest(coalesce(p_prev, '') || p_payload::text, 'sha256'), 'hex')
$$;

CREATE OR REPLACE FUNCTION farm.verify_chain(p_zone uuid)
RETURNS TABLE (seq integer, record_no text, record_version integer, stored_hash text, recomputed_hash text, ok boolean)
LANGUAGE sql STABLE AS $$
    SELECT c.seq, c.record_no, c.record_version, c.hash,
           farm.record_hash(lag(c.hash) OVER (ORDER BY c.seq), c.payload),
           c.hash = farm.record_hash(lag(c.hash) OVER (ORDER BY c.seq), c.payload)
             AND (c.prev_hash IS NOT DISTINCT FROM lag(c.hash) OVER (ORDER BY c.seq))
    FROM farm.record_chain c WHERE c.zone_id = p_zone ORDER BY c.seq
$$;
COMMENT ON FUNCTION farm.verify_chain(uuid) IS 'Recomputes every hash in a zone''s chain from the stored payloads (AC-05 verify, IF-66).';

-- PHI (FR-11): the latest clear time over the CURRENT version of every input-usage record on the zone up to p_at.
CREATE OR REPLACE FUNCTION farm.phi_clear_at(p_zone uuid, p_at timestamptz) RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT max(u.phi_clear_at)
    FROM farm.input_usage u
    WHERE u.zone_id = p_zone AND u.ts <= p_at
      AND u.record_version = (SELECT max(record_version) FROM farm.input_usage x WHERE x.record_no = u.record_no)
$$;

CREATE OR REPLACE FUNCTION farm.phi_status(p_zone uuid, p_at timestamptz)
RETURNS TABLE (clear boolean, clear_at timestamptz, blocking_record_no text, blocking_product text, days_remaining numeric)
LANGUAGE sql STABLE AS $$
    WITH cur AS (
        SELECT u.record_no, u.phi_clear_at, p.name
        FROM farm.input_usage u JOIN farm.input_product p ON p.id = u.product_id
        WHERE u.zone_id = p_zone AND u.ts <= p_at
          AND u.record_version = (SELECT max(record_version) FROM farm.input_usage x WHERE x.record_no = u.record_no)
        ORDER BY u.phi_clear_at DESC LIMIT 1)
    SELECT coalesce(cur.phi_clear_at <= p_at, true), cur.phi_clear_at,
           CASE WHEN cur.phi_clear_at > p_at THEN cur.record_no END,
           CASE WHEN cur.phi_clear_at > p_at THEN cur.name END,
           CASE WHEN cur.phi_clear_at > p_at THEN round(extract(epoch FROM cur.phi_clear_at - p_at) / 86400.0, 2) ELSE 0 END
    FROM (SELECT 1) one LEFT JOIN cur ON true
$$;

-- Traceability (FR-12): zone -> inputs applied since planting -> scouting events, with record hashes.
CREATE OR REPLACE FUNCTION farm.traceability(p_zone uuid, p_harvested_at timestamptz) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'zone', z.code, 'crop', c.code, 'planted_at', z.planted_at, 'season_no', z.season_no,
        'phi_clear_at', farm.phi_clear_at(p_zone, p_harvested_at),
        'inputs', coalesce((SELECT jsonb_agg(jsonb_build_object('record_no', u.record_no, 'version', u.record_version, 'product', p.code,
                                    'active_ingredient', p.active_ingredient, 'ts', u.ts, 'phi_clear_at', u.phi_clear_at, 'hash', u.hash) ORDER BY u.ts)
                            FROM farm.input_usage u JOIN farm.input_product p ON p.id = u.product_id
                            WHERE u.zone_id = p_zone AND u.ts >= z.planted_at AND u.ts <= p_harvested_at
                              AND u.record_version = (SELECT max(record_version) FROM farm.input_usage x WHERE x.record_no = u.record_no)), '[]'::jsonb),
        'scouting', coalesce((SELECT jsonb_agg(jsonb_build_object('record_no', s.record_no, 'version', s.record_version, 'observed_at', s.observed_at,
                                    'condition', s.condition_code, 'severity', s.severity, 'hash', s.hash) ORDER BY s.observed_at)
                            FROM farm.scouting_record s
                            WHERE s.zone_id = p_zone AND s.observed_at >= z.planted_at AND s.observed_at <= p_harvested_at
                              AND s.record_version = (SELECT max(record_version) FROM farm.scouting_record x WHERE x.record_no = s.record_no)), '[]'::jsonb))
    FROM farm.zone z LEFT JOIN farm.crop c ON c.id = z.crop_id WHERE z.id = p_zone
$$;

CREATE OR REPLACE FUNCTION farm.trace_lot(p_lot text) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT h.traceability_json FROM farm.harvest h WHERE h.lot_code = p_lot ORDER BY h.record_version DESC LIMIT 1
$$;

-- Growing degree days (FR-30, AI-08).
CREATE OR REPLACE FUNCTION farm.gdd_day(p_tmax numeric, p_tmin numeric, p_base numeric) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT round(greatest(0, (p_tmax + p_tmin) / 2.0 - p_base), 2)
$$;

CREATE OR REPLACE FUNCTION farm.gdd_accumulated(p_zone uuid, p_to date) RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT coalesce(sum(farm.gdd_day(w.tmax_c, w.tmin_c, c.gdd_base_c)), 0)
    FROM farm.zone z JOIN farm.crop c ON c.id = z.crop_id
    JOIN farm.weather_daily w ON w.farm_id = z.farm_id AND w.day >= z.planted_at AND w.day <= p_to
    WHERE z.id = p_zone
$$;

CREATE OR REPLACE FUNCTION farm.stage_from_gdd(p_crop uuid, p_gdd numeric) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT s->>'stage' FROM farm.crop c, jsonb_array_elements(c.stage_model_json) s
    WHERE c.id = p_crop AND (s->>'gdd_from')::numeric <= p_gdd
    ORDER BY (s->>'gdd_from')::numeric DESC LIMIT 1
$$;

-- Student t (two-sided 95 %) for the prediction interval — df 1..10, then a normal-ish tail.
CREATE OR REPLACE FUNCTION farm.t_975(p_df integer) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_df WHEN 1 THEN 12.706 WHEN 2 THEN 4.303 WHEN 3 THEN 3.182 WHEN 4 THEN 2.776 WHEN 5 THEN 2.571
                     WHEN 6 THEN 2.447 WHEN 7 THEN 2.365 WHEN 8 THEN 2.306 WHEN 9 THEN 2.262 WHEN 10 THEN 2.228
                     ELSE 2.000 END
$$;

-- Interpretable harvest prediction (FR-30, FR-31, AI-08, AC-09):
--   harvest date  = as_of + (maturity GDD − accumulated GDD) / mean daily GDD of the last 14 days, interval from ± 1 sd of the daily GDD
--   yield         = mean of the zone's seasons (intercept-only regression) with a t prediction interval; needs ≥ prediction_min_seasons
CREATE OR REPLACE FUNCTION farm.predict_harvest(p_zone uuid, p_as_of date)
RETURNS TABLE (kind farm.forecast_kind, status farm.forecast_status, value numeric, low numeric, high numeric,
               value_date date, low_date date, high_date date, factors_json jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    z farm.zone%ROWTYPE; c farm.crop%ROWTYPE; s farm.setting%ROWTYPE;
    v_gdd numeric; v_maturity numeric; v_stage text; v_avg numeric; v_sd numeric; v_days int; v_n_days int;
    v_n int; v_mean numeric; v_ysd numeric; v_t numeric; v_half numeric;
BEGIN
    SELECT * INTO s FROM farm.setting WHERE id = 1;
    SELECT * INTO z FROM farm.zone WHERE id = p_zone;
    IF z.crop_id IS NULL OR z.planted_at IS NULL THEN
        RETURN QUERY SELECT 'harvest_date'::farm.forecast_kind, 'insufficient_data'::farm.forecast_status, NULL::numeric, NULL::numeric, NULL::numeric, NULL::date, NULL::date, NULL::date,
                            jsonb_build_object('reason', 'zone has no crop or planting date');
        RETURN QUERY SELECT 'yield'::farm.forecast_kind, 'insufficient_data'::farm.forecast_status, NULL::numeric, NULL::numeric, NULL::numeric, NULL::date, NULL::date, NULL::date,
                            jsonb_build_object('reason', 'zone has no crop or planting date');
        RETURN;
    END IF;
    SELECT * INTO c FROM farm.crop WHERE id = z.crop_id;
    v_gdd := farm.gdd_accumulated(p_zone, p_as_of);
    SELECT max((e->>'gdd_from')::numeric) INTO v_maturity FROM jsonb_array_elements(c.stage_model_json) e;
    v_stage := farm.stage_from_gdd(c.id, v_gdd);
    SELECT round(avg(g), 2), round(coalesce(stddev_samp(g), 0), 2), count(*) INTO v_avg, v_sd, v_n_days
    FROM (SELECT farm.gdd_day(w.tmax_c, w.tmin_c, c.gdd_base_c) g FROM farm.weather_daily w
          WHERE w.farm_id = z.farm_id AND w.day > p_as_of - 14 AND w.day <= p_as_of) d;
    IF v_n_days < 7 OR v_avg IS NULL OR v_avg <= 0 THEN
        RETURN QUERY SELECT 'harvest_date'::farm.forecast_kind, 'insufficient_data'::farm.forecast_status, NULL::numeric, NULL::numeric, NULL::numeric, NULL::date, NULL::date, NULL::date,
                            jsonb_build_object('reason', 'fewer than 7 days of weather', 'gdd_accumulated', v_gdd, 'stage', v_stage);
    ELSE
        v_days := ceil(greatest(0, v_maturity - v_gdd) / v_avg);
        RETURN QUERY SELECT 'harvest_date'::farm.forecast_kind, 'ok'::farm.forecast_status, v_days::numeric,
                            ceil(greatest(0, v_maturity - v_gdd) / (v_avg + v_sd))::numeric,
                            CASE WHEN v_avg - v_sd > 0 THEN ceil(greatest(0, v_maturity - v_gdd) / (v_avg - v_sd))::numeric ELSE (v_days * 2)::numeric END,
                            p_as_of + v_days,
                            p_as_of + ceil(greatest(0, v_maturity - v_gdd) / (v_avg + v_sd))::int,
                            p_as_of + CASE WHEN v_avg - v_sd > 0 THEN ceil(greatest(0, v_maturity - v_gdd) / (v_avg - v_sd))::int ELSE v_days * 2 END,
                            jsonb_build_object('method', 'gdd_to_maturity', 'gdd_base_c', c.gdd_base_c, 'gdd_accumulated', v_gdd, 'gdd_maturity', v_maturity,
                                               'stage', v_stage, 'daily_gdd_mean_14d', v_avg, 'daily_gdd_sd_14d', v_sd, 'days_of_weather', v_n_days, 'planted_at', z.planted_at);
    END IF;
    SELECT count(*), round(avg(yield_kg_per_rai), 1), round(coalesce(stddev_samp(yield_kg_per_rai), 0), 2) INTO v_n, v_mean, v_ysd
    FROM farm.yield_history WHERE zone_id = p_zone;
    IF v_n < s.prediction_min_seasons THEN
        RETURN QUERY SELECT 'yield'::farm.forecast_kind, 'insufficient_data'::farm.forecast_status, NULL::numeric, NULL::numeric, NULL::numeric, NULL::date, NULL::date, NULL::date,
                            jsonb_build_object('reason', format('%s season(s) of history, %s required', v_n, s.prediction_min_seasons), 'seasons', v_n);
    ELSE
        v_t := farm.t_975(v_n - 1);
        v_half := round(v_t * v_ysd * sqrt(1 + 1.0 / v_n), 1);
        RETURN QUERY SELECT 'yield'::farm.forecast_kind, 'ok'::farm.forecast_status, v_mean, greatest(0, v_mean - v_half), v_mean + v_half, NULL::date, NULL::date, NULL::date,
                            jsonb_build_object('method', 'intercept_only_regression_t_interval', 'seasons', v_n, 'mean_kg_per_rai', v_mean, 'sd', v_ysd,
                                               't_975', v_t, 'half_width', v_half, 'unit', 'kg/rai', 'area_rai', z.area_rai, 'expected_total_kg', round(v_mean * z.area_rai, 0));
    END IF;
END $$;
COMMENT ON FUNCTION farm.predict_harvest(uuid, date) IS 'AI-08: GDD + stage model + history; every output carries its factors (FR-31); insufficient_data below the season minimum (AC-09). A slope term on GDD is added only at ≥ 5 seasons (OPS-12 §7).';

-- Environment-based disease risk (FR-24) from rule rows.
CREATE OR REPLACE FUNCTION farm.disease_risk(p_crop uuid, p_rh numeric, p_temp numeric, p_hours numeric)
RETURNS SETOF farm.risk_rule LANGUAGE sql STABLE AS $$
    SELECT r.* FROM farm.risk_rule r
    WHERE r.crop_id = p_crop AND r.active AND p_rh >= r.rh_min_pct AND p_temp >= r.temp_min_c AND p_temp <= r.temp_max_c AND p_hours >= r.hours_min
$$;

CREATE OR REPLACE FUNCTION farm.evaluate_risk(p_farm uuid, p_day date) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE w farm.weather_daily%ROWTYPE; z record; r farm.risk_rule%ROWTYPE; n int := 0;
BEGIN
    SELECT * INTO w FROM farm.weather_daily WHERE farm_id = p_farm AND day = p_day;
    IF NOT FOUND THEN
        INSERT INTO farm.advisory (farm_id, kind, level, message_th, suppressed_reason)
        VALUES (p_farm, 'disease_risk', 'info', 'ไม่สามารถประเมินความเสี่ยงโรคได้: ไม่มีข้อมูลอากาศ', 'weather unavailable');
        RETURN 0;
    END IF;
    FOR z IN SELECT id, crop_id, code FROM farm.zone WHERE farm_id = p_farm AND crop_id IS NOT NULL LOOP
        FOR r IN SELECT * FROM farm.disease_risk(z.crop_id, w.rh_mean_pct, (w.tmax_c + w.tmin_c) / 2.0, coalesce(w.rh_hours_ge, 0)) LOOP
            INSERT INTO farm.advisory (farm_id, zone_id, kind, level, message_th, factors_json, valid_until)
            VALUES (p_farm, z.id, 'disease_risk', r.level, r.message_th,
                    jsonb_build_object('rule_id', r.id, 'condition', r.condition_code, 'day', p_day, 'rh_mean_pct', w.rh_mean_pct,
                                       'temp_mean_c', round((w.tmax_c + w.tmin_c) / 2.0, 1), 'rh_hours_ge85', w.rh_hours_ge, 'source', r.source),
                    (p_day + 2)::timestamptz);
            n := n + 1;
        END LOOP;
    END LOOP;
    RETURN n;
END $$;

-- Spray vs forecast rain within the product's rainfast window (FR-25). conflict NULL = no forecast covering the window (suppressed, IF-12).
CREATE OR REPLACE FUNCTION farm.spray_conflict(p_zone uuid, p_planned_at timestamptz, p_product uuid)
RETURNS TABLE (conflict boolean, rainfast_hours integer, rain_at timestamptz, rain_mm numeric, rain_prob numeric, reason text)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_rf int; v_farm uuid; f farm.weather_forecast%ROWTYPE;
BEGIN
    SELECT p.rainfast_hours INTO v_rf FROM farm.input_product p WHERE p.id = p_product;
    SELECT z.farm_id INTO v_farm FROM farm.zone z WHERE z.id = p_zone;
    IF v_rf IS NULL THEN
        RETURN QUERY SELECT false, NULL::int, NULL::timestamptz, NULL::numeric, NULL::numeric, 'product has no rainfast window'; RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM farm.weather_forecast w WHERE w.farm_id = v_farm AND w.valid_from <= p_planned_at + make_interval(hours => v_rf) AND w.valid_to > p_planned_at) THEN
        RETURN QUERY SELECT NULL::boolean, v_rf, NULL::timestamptz, NULL::numeric, NULL::numeric, 'forecast unavailable'; RETURN;
    END IF;
    SELECT * INTO f FROM farm.weather_forecast w
    WHERE w.farm_id = v_farm AND w.valid_from < p_planned_at + make_interval(hours => v_rf) AND w.valid_to > p_planned_at
      AND (w.rain_prob >= 0.5 OR w.rain_mm >= 1.0)
    ORDER BY w.valid_from LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT true, v_rf, f.valid_from, f.rain_mm, f.rain_prob, format('rain expected within %s h of application', v_rf);
    ELSE
        RETURN QUERY SELECT false, v_rf, NULL::timestamptz, NULL::numeric, NULL::numeric, 'no rain in the rainfast window';
    END IF;
END $$;

-- Soil-moisture trend (FR-26): least-squares slope in %/h over the zone's soil_moisture sensors.
CREATE OR REPLACE FUNCTION farm.moisture_trend(p_zone uuid, p_hours integer, p_now timestamptz)
RETURNS TABLE (slope_per_hour numeric, latest numeric, n integer) LANGUAGE sql STABLE AS $$
    SELECT round(regr_slope(t.value, extract(epoch FROM t.ts) / 3600.0)::numeric, 4),
           (SELECT t2.value FROM farm.telemetry t2 JOIN farm.sensor s2 ON s2.id = t2.sensor_id WHERE s2.zone_id = p_zone AND s2.kind = 'soil_moisture' AND t2.ts <= p_now ORDER BY t2.ts DESC LIMIT 1),
           count(*)::int
    FROM farm.telemetry t JOIN farm.sensor s ON s.id = t.sensor_id
    WHERE s.zone_id = p_zone AND s.kind = 'soil_moisture' AND t.quality = 'ok' AND t.ts > p_now - make_interval(hours => p_hours) AND t.ts <= p_now
$$;

CREATE OR REPLACE FUNCTION farm.irrigation_advice(p_zone uuid, p_now timestamptz) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE m record; v_farm uuid; v_rain numeric; v_stage text;
BEGIN
    SELECT * INTO m FROM farm.moisture_trend(p_zone, 24, p_now);
    SELECT z.farm_id, farm.stage_from_gdd(z.crop_id, farm.gdd_accumulated(z.id, p_now::date)) INTO v_farm, v_stage FROM farm.zone z WHERE z.id = p_zone;
    IF m.n < 6 OR m.latest IS NULL THEN RETURN 0; END IF;
    SELECT coalesce(sum(rain_mm), 0) INTO v_rain FROM farm.weather_forecast w WHERE w.farm_id = v_farm AND w.valid_from >= p_now AND w.valid_from < p_now + interval '24 hours';
    IF m.slope_per_hour < -0.3 AND m.latest < 30 AND v_rain < 5 THEN
        INSERT INTO farm.advisory (farm_id, zone_id, kind, level, message_th, factors_json, valid_until)
        VALUES (v_farm, p_zone, 'irrigation', 'elevated',
                format('ความชื้นดินลดลง %s %%/ชม. (ล่าสุด %s %%) และไม่มีฝนใน 24 ชม. — พิจารณาให้น้ำ (ระยะ %s)', abs(m.slope_per_hour), m.latest, v_stage),
                jsonb_build_object('slope_per_hour', m.slope_per_hour, 'latest_pct', m.latest, 'n', m.n, 'rain_next_24h_mm', v_rain, 'stage', v_stage), p_now + interval '12 hours');
        RETURN 1;
    END IF;
    RETURN 0;
END $$;

-- Sensor faults (FR-22).
CREATE OR REPLACE FUNCTION farm.sensor_stuck(p_sensor uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT count(*) = k.stuck_readings AND count(DISTINCT t.value) = 1
    FROM farm.sensor s JOIN farm.sensor_kind k ON k.code = s.kind
    CROSS JOIN LATERAL (SELECT value FROM farm.telemetry x WHERE x.sensor_id = s.id ORDER BY ts DESC LIMIT k.stuck_readings) t
    WHERE s.id = p_sensor GROUP BY k.stuck_readings
$$;

CREATE OR REPLACE FUNCTION farm.sensor_offline(p_sensor uuid, p_now timestamptz) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT s.last_seen_at IS NULL OR s.last_seen_at < p_now - make_interval(mins => st.sensor_offline_minutes)
    FROM farm.sensor s, farm.setting st WHERE s.id = p_sensor AND st.id = 1
$$;

CREATE OR REPLACE FUNCTION farm.detect_sensor_faults(p_now timestamptz) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE s record; n int := 0; v_last record;
BEGIN
    FOR s IN SELECT id, kind FROM farm.sensor WHERE status <> 'retired' LOOP
        IF farm.sensor_offline(s.id, p_now) AND NOT EXISTS (SELECT 1 FROM farm.sensor_fault f WHERE f.sensor_id = s.id AND f.kind = 'offline' AND f.resolved_at IS NULL) THEN
            INSERT INTO farm.sensor_fault (sensor_id, kind, detected_at, detail_json)
            VALUES (s.id, 'offline', p_now, jsonb_build_object('last_seen_at', (SELECT last_seen_at FROM farm.sensor WHERE id = s.id)));
            n := n + 1;
        END IF;
        IF farm.sensor_stuck(s.id) AND NOT EXISTS (SELECT 1 FROM farm.sensor_fault f WHERE f.sensor_id = s.id AND f.kind = 'stuck' AND f.resolved_at IS NULL) THEN
            SELECT value, ts INTO v_last FROM farm.telemetry WHERE sensor_id = s.id ORDER BY ts DESC LIMIT 1;
            INSERT INTO farm.sensor_fault (sensor_id, kind, detected_at, detail_json)
            VALUES (s.id, 'stuck', p_now, jsonb_build_object('value', v_last.value, 'since', v_last.ts));
            n := n + 1;
        END IF;
        SELECT value, ts, quality INTO v_last FROM farm.telemetry WHERE sensor_id = s.id ORDER BY ts DESC LIMIT 1;
        IF FOUND AND v_last.quality = 'out_of_range' AND NOT EXISTS (SELECT 1 FROM farm.sensor_fault f WHERE f.sensor_id = s.id AND f.kind = 'out_of_range' AND f.resolved_at IS NULL) THEN
            INSERT INTO farm.sensor_fault (sensor_id, kind, detected_at, detail_json)
            VALUES (s.id, 'out_of_range', p_now, jsonb_build_object('value', v_last.value, 'ts', v_last.ts));
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END $$;

-- Compliance gaps (FR-15): periods longer than the scheme rule between consecutive records of a kind, per zone.
CREATE OR REPLACE FUNCTION farm.compliance_gaps(p_farm uuid, p_from date, p_to date)
RETURNS TABLE (zone_code text, rule_code text, gap_from date, gap_to date, days integer) LANGUAGE sql STABLE AS $$
    WITH z AS (SELECT zn.id, zn.code, greatest(p_from, coalesce(zn.planted_at, p_from)) AS start_day
               FROM farm.zone zn WHERE zn.farm_id = p_farm AND zn.crop_id IS NOT NULL),
         rules AS (SELECT r.rule_code, r.record_kind, r.max_gap_days FROM farm.gap_scheme_rule r JOIN farm.farm f ON f.gap_scheme = r.scheme_code
                   WHERE f.id = p_farm AND r.max_gap_days IS NOT NULL),
         pts AS (
            SELECT z.id AS zone_id, rules.rule_code, rules.max_gap_days, d.day
            FROM z CROSS JOIN rules
            CROSS JOIN LATERAL (
                SELECT z.start_day AS day
                UNION SELECT p_to
                UNION SELECT s.observed_at::date FROM farm.scouting_record s WHERE rules.record_kind = 'scouting' AND s.zone_id = z.id AND s.observed_at::date BETWEEN z.start_day AND p_to
                UNION SELECT u.ts::date FROM farm.input_usage u WHERE rules.record_kind = 'input_usage' AND u.zone_id = z.id AND u.ts::date BETWEEN z.start_day AND p_to
                UNION SELECT h.harvested_at::date FROM farm.harvest h WHERE rules.record_kind = 'harvest' AND h.zone_id = z.id AND h.harvested_at::date BETWEEN z.start_day AND p_to
            ) d),
         seq AS (SELECT zone_id, rule_code, max_gap_days, day, lag(day) OVER (PARTITION BY zone_id, rule_code ORDER BY day) AS prev_day FROM pts)
    SELECT z.code, seq.rule_code, seq.prev_day, seq.day, (seq.day - seq.prev_day)::int
    FROM seq JOIN z ON z.id = seq.zone_id
    WHERE seq.prev_day IS NOT NULL AND seq.day - seq.prev_day > seq.max_gap_days
    ORDER BY z.code, seq.prev_day
$$;

-- Escalation of overdue critical tasks to the farm manager (FR-20).
CREATE OR REPLACE FUNCTION farm.escalate_overdue(p_now timestamptz) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE t record; v_mgr uuid; n int := 0; v_hours int;
BEGIN
    SELECT escalation_hours INTO v_hours FROM farm.setting WHERE id = 1;
    FOR t IN SELECT tk.id, tk.description_th, z.farm_id FROM farm.task tk JOIN farm.zone z ON z.id = tk.zone_id
             WHERE tk.status = 'open' AND tk.priority = 'critical' AND tk.escalated_at IS NULL AND tk.due_at < p_now - make_interval(hours => v_hours) LOOP
        SELECT coalesce((SELECT user_id FROM farm.farm_member m WHERE m.farm_id = t.farm_id AND m.role = 'farm_manager' LIMIT 1),
                        (SELECT owner_id FROM farm.farm WHERE id = t.farm_id)) INTO v_mgr;
        INSERT INTO farm.escalation (task_id, to_user_id, reason) VALUES (t.id, v_mgr, format('critical task overdue > %s h: %s', v_hours, t.description_th));
        UPDATE farm.task SET escalated_at = p_now WHERE id = t.id;
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;

-- Record + tasks + reminders from a diagnosis (FR-09, FR-16, FR-18, AC-03). Called by the confirmation and correction triggers only.
CREATE OR REPLACE FUNCTION farm.generate_from_diagnosis(p_diag uuid, p_user uuid, p_condition text, p_severity farm.severity_level)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE d farm.diagnosis%ROWTYPE; o farm.observation%ROWTYPE; z farm.zone%ROWTYPE; f farm.farm%ROWTYPE; c farm.condition%ROWTYPE;
        tpl farm.task_template%ROWTYPE; v_rec text; v_task uuid; v_due timestamptz; v_channel farm.channel_kind; v_ids uuid[];
BEGIN
    SELECT * INTO d FROM farm.diagnosis WHERE id = p_diag;
    SELECT * INTO o FROM farm.observation WHERE id = d.observation_id;
    SELECT * INTO z FROM farm.zone WHERE id = o.zone_id;
    SELECT * INTO f FROM farm.farm WHERE id = z.farm_id;
    SELECT * INTO c FROM farm.condition WHERE code = p_condition;
    SELECT coalesce(array_agg((e)::uuid), '{}') INTO v_ids FROM jsonb_array_elements_text(o.photos_json) e;
    v_rec := farm.next_record_no(f.id, 'scouting', o.ts);
    INSERT INTO farm.scouting_record (record_no, zone_id, observed_at, observation_id, diagnosis_id, condition_code, severity, area_pct,
                                      plants_affected, plants_inspected, evidence_photo_ids, author_id, author_ref)
    VALUES (v_rec, z.id, o.ts, o.id, d.id, p_condition, p_severity, o.area_pct, o.plants_affected, o.plants_inspected, v_ids, p_user, farm.pseudonym(p_user));
    SELECT kind INTO v_channel FROM farm.notification_channel WHERE user_id = p_user AND enabled ORDER BY CASE kind WHEN 'line' THEN 1 WHEN 'push' THEN 2 WHEN 'discord' THEN 3 ELSE 4 END LIMIT 1;
    FOR tpl IN SELECT * FROM farm.task_template t
               WHERE t.active AND (t.condition_kind IS NULL OR t.condition_kind = c.kind) AND t.min_severity <= p_severity ORDER BY t.ordinal LOOP
        v_due := (((o.ts AT TIME ZONE f.timezone)::date + tpl.due_offset_days) + time '17:00') AT TIME ZONE f.timezone;
        INSERT INTO farm.task (zone_id, kind, description_th, description_en, due_at, owner_id, priority, source_diagnosis_id, template_id)
        VALUES (z.id, tpl.task_kind, replace(tpl.description_th, '{n_plants}', coalesce(tpl.n_plants::text, '')),
                replace(tpl.description_en, '{n_plants}', coalesce(tpl.n_plants::text, '')), v_due, p_user, tpl.priority, d.id, tpl.id)
        RETURNING id INTO v_task;
        INSERT INTO farm.reminder (task_id, user_id, channel_kind, scheduled_at, message_th)
        VALUES (v_task, p_user, coalesce(v_channel, 'push'),
                CASE WHEN tpl.due_offset_days = 0 THEN o.ts
                     ELSE (((o.ts AT TIME ZONE f.timezone)::date + tpl.due_offset_days) + f.reminder_time) AT TIME ZONE f.timezone END,
                replace(tpl.description_th, '{n_plants}', coalesce(tpl.n_plants::text, '')));
    END LOOP;
    RETURN v_rec;
END $$;

-- Offline sync (IF-63, AC-07): idempotent by key; each item applied once; a replay returns the stored result.
CREATE OR REPLACE FUNCTION farm.apply_sync_batch(p_device uuid, p_key text, p_items jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_existing farm.sync_batch%ROWTYPE; it jsonb; res jsonb := '[]'::jsonb; v_id uuid; v_applied int := 0; v_user uuid; v_batch uuid; v_status text;
BEGIN
    SELECT * INTO v_existing FROM farm.sync_batch WHERE idempotency_key = p_key;
    IF FOUND THEN
        RETURN jsonb_build_object('batch_id', v_existing.id, 'replayed', true, 'applied', v_existing.applied_count, 'items', v_existing.result_json);
    END IF;
    SELECT user_id INTO v_user FROM farm.device WHERE id = p_device;
    INSERT INTO farm.sync_batch (device_id, idempotency_key, item_count) VALUES (p_device, p_key, jsonb_array_length(p_items)) RETURNING id INTO v_batch;
    FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        IF it->>'entity' = 'observation' THEN
            v_id := (it->>'client_id')::uuid;
            INSERT INTO farm.observation (id, zone_id, ts, kind, photos_json, area_pct, plants_affected, plants_inspected, growth_stage, reporter_id, reporter_ref, sync_batch_id)
            SELECT v_id, (it->'data'->>'zone_id')::uuid, (it->'data'->>'ts')::timestamptz, coalesce(it->'data'->>'kind', 'scouting')::farm.observation_kind,
                   coalesce(it->'data'->'photos', '[]'::jsonb), (it->'data'->>'area_pct')::numeric, (it->'data'->>'plants_affected')::int,
                   (it->'data'->>'plants_inspected')::int, it->'data'->>'growth_stage', v_user, farm.pseudonym(v_user), v_batch
            ON CONFLICT (id) DO NOTHING;
            v_status := CASE WHEN FOUND THEN 'applied' ELSE 'exists' END;
        ELSIF it->>'entity' = 'task_done' THEN
            v_id := (it->>'client_id')::uuid;
            UPDATE farm.task SET status = 'done', completed_by = v_user, completed_at = (it->'data'->>'completed_at')::timestamptz,
                                 evidence_json = coalesce(it->'data'->'evidence', evidence_json)
            WHERE id = v_id AND status = 'open';
            v_status := CASE WHEN FOUND THEN 'applied' ELSE 'exists' END;
        ELSE
            v_status := 'rejected';
        END IF;
        IF v_status = 'applied' THEN v_applied := v_applied + 1; END IF;
        res := res || jsonb_build_object('client_id', it->>'client_id', 'entity', it->>'entity', 'status', v_status);
    END LOOP;
    UPDATE farm.sync_batch SET applied_count = v_applied, result_json = res WHERE id = v_batch;
    UPDATE farm.device SET last_sync_at = now() WHERE id = p_device;
    RETURN jsonb_build_object('batch_id', v_batch, 'replayed', false, 'applied', v_applied, 'items', res);
END $$;

-- Zone from a GPS fix (FR-04).
CREATE OR REPLACE FUNCTION farm.zone_for_point(p_farm uuid, p_point geography) RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT z.id FROM farm.zone z WHERE z.farm_id = p_farm AND z.boundary IS NOT NULL AND ST_Covers(z.boundary, p_point) ORDER BY z.code LIMIT 1
$$;

-- =====================================================================
-- 18. GUARD TRIGGERS — the SRS rules as database properties (DD-G01..G09)
-- =====================================================================

-- DD-G01: append-only records and chain.
CREATE OR REPLACE FUNCTION farm.trg_record_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'RECORD_IMMUTABLE: % rows are append-only; insert record_version + 1 with supersedes and reason_th (C-03, FR-14)', TG_TABLE_NAME
        USING ERRCODE = 'integrity_constraint_violation';
END $$;
CREATE TRIGGER trg_record_append_only BEFORE UPDATE OR DELETE ON farm.scouting_record FOR EACH ROW EXECUTE FUNCTION farm.trg_record_append_only();
CREATE TRIGGER trg_record_append_only BEFORE UPDATE OR DELETE ON farm.input_usage     FOR EACH ROW EXECUTE FUNCTION farm.trg_record_append_only();
CREATE TRIGGER trg_record_append_only BEFORE UPDATE OR DELETE ON farm.harvest         FOR EACH ROW EXECUTE FUNCTION farm.trg_record_append_only();
CREATE TRIGGER trg_record_append_only BEFORE UPDATE OR DELETE ON farm.record_chain    FOR EACH ROW EXECUTE FUNCTION farm.trg_record_append_only();

-- DD-G02: versioning rules and the hash chain (fires after the per-table validation triggers — names sort earlier).
CREATE OR REPLACE FUNCTION farm.trg_record_chain() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_kind farm.record_kind; v_prev_hash text; v_seq int; v_payload jsonb; v_prev record;
BEGIN
    v_kind := CASE TG_TABLE_NAME WHEN 'scouting_record' THEN 'scouting'::farm.record_kind WHEN 'input_usage' THEN 'input_usage'::farm.record_kind ELSE 'harvest'::farm.record_kind END;
    IF NEW.record_version > 1 THEN
        IF NEW.supersedes IS NULL OR NEW.reason_th IS NULL OR length(NEW.reason_th) < 3 THEN
            RAISE EXCEPTION 'VERSION_NEEDS_SUPERSEDES: version % of % must reference the previous version and give a reason (AC-06)', NEW.record_version, NEW.record_no;
        END IF;
        EXECUTE format('SELECT record_no, record_version, zone_id FROM farm.%I WHERE id = $1', TG_TABLE_NAME) INTO v_prev USING NEW.supersedes;
        IF v_prev.record_no IS DISTINCT FROM NEW.record_no OR v_prev.record_version <> NEW.record_version - 1 OR v_prev.zone_id <> NEW.zone_id THEN
            RAISE EXCEPTION 'VERSION_CHAIN_BROKEN: % v% must supersede v% of the same record on the same zone', NEW.record_no, NEW.record_version, NEW.record_version - 1;
        END IF;
    ELSIF NEW.supersedes IS NOT NULL THEN
        RAISE EXCEPTION 'VERSION_CHAIN_BROKEN: version 1 cannot supersede anything';
    END IF;
    -- deterministic content only: no surrogate ids, no server timestamps (the chain row keeps record_id)
    v_payload := to_jsonb(NEW) - 'id' - 'supersedes' - 'hash' - 'prev_hash' - 'created_at' - 'phi_clear_at';
    SELECT c.hash, c.seq INTO v_prev_hash, v_seq FROM farm.record_chain c WHERE c.zone_id = NEW.zone_id ORDER BY c.seq DESC LIMIT 1;
    NEW.prev_hash := v_prev_hash;
    NEW.hash := farm.record_hash(v_prev_hash, v_payload);
    INSERT INTO farm.record_chain (zone_id, seq, record_kind, record_no, record_version, record_id, payload, prev_hash, hash)
    VALUES (NEW.zone_id, coalesce(v_seq, 0) + 1, v_kind, NEW.record_no, NEW.record_version, NEW.id, v_payload, v_prev_hash, NEW.hash);
    RETURN NEW;
END $$;
CREATE TRIGGER trg_record_chain BEFORE INSERT ON farm.scouting_record FOR EACH ROW EXECUTE FUNCTION farm.trg_record_chain();
CREATE TRIGGER trg_record_chain BEFORE INSERT ON farm.input_usage     FOR EACH ROW EXECUTE FUNCTION farm.trg_record_chain();
CREATE TRIGGER trg_record_chain BEFORE INSERT ON farm.harvest         FOR EACH ROW EXECUTE FUNCTION farm.trg_record_chain();

-- DD-G03: approved inputs only (C-02).
CREATE OR REPLACE FUNCTION farm.trg_product_approval() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.approved THEN
        IF NEW.label_uri IS NULL THEN RAISE EXCEPTION 'LABEL_REQUIRED: an approved product needs its registered label (IF-65)'; END IF;
        IF NEW.approved_by IS NULL OR NEW.approved_by = NEW.author_id THEN
            RAISE EXCEPTION 'APPROVAL_SELF: approval needs a second person (approved_by <> author_id)';
        END IF;
        NEW.approved_at := coalesce(NEW.approved_at, now());
        NEW.unapproved_reason := NULL;
    ELSIF TG_OP = 'UPDATE' AND OLD.approved AND NEW.unapproved_reason IS NULL THEN
        RAISE EXCEPTION 'REASON_REQUIRED: withdrawing approval needs unapproved_reason';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_product_approval BEFORE INSERT OR UPDATE ON farm.input_product FOR EACH ROW EXECUTE FUNCTION farm.trg_product_approval();

CREATE OR REPLACE FUNCTION farm.trg_input_usage_approved() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p farm.input_product%ROWTYPE;
BEGIN
    SELECT * INTO p FROM farm.input_product WHERE id = NEW.product_id;
    IF NOT p.approved OR p.approved_at > NEW.ts THEN
        RAISE EXCEPTION 'UNAPPROVED_PRODUCT: % was not on the approved list at % (C-02, FR-10)', p.code, NEW.ts;
    END IF;
    IF NEW.ppe IS NULL OR cardinality(NEW.ppe) = 0 THEN RAISE EXCEPTION 'PPE_REQUIRED: input usage must record the PPE used (FR-10)'; END IF;
    IF NOT (NEW.weather_json ? 'temp_c' AND NEW.weather_json ? 'rh_pct' AND NEW.weather_json ? 'wind_ms') THEN
        RAISE EXCEPTION 'WEATHER_REQUIRED: weather at application (temp_c, rh_pct, wind_ms) is mandatory (FR-10)';
    END IF;
    NEW.phi_days := p.phi_days;
    NEW.rei_hours := p.rei_hours;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_input_usage_approved BEFORE INSERT ON farm.input_usage FOR EACH ROW EXECUTE FUNCTION farm.trg_input_usage_approved();

CREATE OR REPLACE FUNCTION farm.trg_recommendation_approved() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p farm.input_product%ROWTYPE;
BEGIN
    SELECT * INTO p FROM farm.input_product WHERE id = NEW.product_id;
    IF NOT p.approved THEN RAISE EXCEPTION 'UNAPPROVED_PRODUCT: % cannot be recommended (C-02, FR-28)', p.code; END IF;
    NEW.phi_days := p.phi_days; NEW.rei_hours := p.rei_hours; NEW.cautions_th := coalesce(NEW.cautions_th, p.cautions_th);
    RETURN NEW;
END $$;
CREATE TRIGGER trg_recommendation_approved BEFORE INSERT ON farm.treatment_recommendation FOR EACH ROW EXECUTE FUNCTION farm.trg_recommendation_approved();

CREATE OR REPLACE FUNCTION farm.trg_answer_products() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_code text; v_bad text;
BEGIN
    FOR v_code IN SELECT jsonb_array_elements_text(NEW.products_json) LOOP
        IF NOT EXISTS (SELECT 1 FROM farm.input_product p WHERE p.code = v_code AND p.approved) THEN
            RAISE EXCEPTION 'UNAPPROVED_PRODUCT: the answer names % which is not on the approved list (AC-08)', v_code;
        END IF;
    END LOOP;
    SELECT p.name INTO v_bad FROM farm.input_product p
    WHERE NOT p.approved AND (position(lower(p.name) IN lower(NEW.text_th)) > 0 OR (p.name_th IS NOT NULL AND position(p.name_th IN NEW.text_th) > 0)) LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'UNAPPROVED_PRODUCT_MENTION: the answer text names an unapproved product (%). Refer to "the product you asked about" instead (AC-08)', v_bad;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_answer_products BEFORE INSERT OR UPDATE ON farm.answer FOR EACH ROW EXECUTE FUNCTION farm.trg_answer_products();

-- DD-G04: diagnosis shape — 1..3 calibrated candidates, or a refusal with none (C-04, AI-05, AI-06, FR-03, FR-05).
CREATE OR REPLACE FUNCTION farm.trg_diagnosis_shape() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n int; c jsonb; v_sum numeric := 0; v_prev numeric := 1; v_p numeric; v_thr numeric; v_first boolean := true; v_cond farm.condition%ROWTYPE;
BEGIN
    IF jsonb_typeof(NEW.candidates_json) <> 'array' THEN RAISE EXCEPTION 'DIAGNOSIS_SHAPE: candidates_json must be an array'; END IF;
    n := jsonb_array_length(NEW.candidates_json);
    IF NEW.ood THEN
        IF n <> 0 THEN RAISE EXCEPTION 'DIAGNOSIS_SHAPE: an out-of-distribution image is refused without candidates (AI-06, AC-02)'; END IF;
        NEW.status := 'refused'; NEW.top1_prob := NULL; NEW.chosen_id := NULL;
        RETURN NEW;
    END IF;
    IF n < 1 OR n > 3 THEN RAISE EXCEPTION 'DIAGNOSIS_SHAPE: 1..3 candidates required, got % (FR-03)', n; END IF;
    IF NEW.calibration_version IS NULL THEN RAISE EXCEPTION 'UNCALIBRATED: displayed probabilities must come from a calibration version (AI-05)'; END IF;
    FOR c IN SELECT * FROM jsonb_array_elements(NEW.candidates_json) LOOP
        IF NOT (c ? 'condition_code' AND c ? 'probability' AND c ? 'distinguishing_features_th' AND c ? 'how_to_confirm_th') THEN
            RAISE EXCEPTION 'DIAGNOSIS_SHAPE: every candidate needs condition_code, probability, distinguishing_features_th, how_to_confirm_th (FR-03)';
        END IF;
        v_p := (c->>'probability')::numeric;
        IF v_p < 0 OR v_p > 1 THEN RAISE EXCEPTION 'DIAGNOSIS_SHAPE: probability % outside [0,1]', v_p; END IF;
        IF v_p > v_prev + 0.0005 THEN RAISE EXCEPTION 'DIAGNOSIS_SHAPE: candidates must be ordered by probability'; END IF;
        SELECT * INTO v_cond FROM farm.condition WHERE code = c->>'condition_code' AND active;
        IF NOT FOUND THEN RAISE EXCEPTION 'DIAGNOSIS_SHAPE: unknown condition %', c->>'condition_code'; END IF;
        IF v_first THEN
            NEW.top1_prob := v_p;
            IF v_cond.fast_spreading THEN NEW.consult_agronomist := true; END IF;
            v_first := false;
        END IF;
        v_sum := v_sum + v_p; v_prev := v_p;
    END LOOP;
    IF v_sum > 1.0005 THEN RAISE EXCEPTION 'DIAGNOSIS_SHAPE: probabilities sum to % > 1', v_sum; END IF;
    SELECT review_threshold INTO v_thr FROM farm.setting WHERE id = 1;
    IF TG_OP = 'INSERT' AND NEW.status = 'proposed' AND NEW.top1_prob < v_thr THEN NEW.status := 'needs_review'; END IF;
    IF NEW.status = 'refused' THEN RAISE EXCEPTION 'DIAGNOSIS_SHAPE: only an ood diagnosis can be refused'; END IF;
    IF EXISTS (SELECT 1 FROM farm.observation o WHERE o.id = NEW.observation_id AND (o.severity = 'severe' OR farm.severity_level(o.area_pct) = 'severe')) THEN
        NEW.consult_agronomist := true;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_diagnosis_shape BEFORE INSERT OR UPDATE ON farm.diagnosis FOR EACH ROW EXECUTE FUNCTION farm.trg_diagnosis_shape();

CREATE OR REPLACE FUNCTION farm.trg_diagnosis_review() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'needs_review' THEN
        INSERT INTO farm.review_queue (diagnosis_id, reason) VALUES (NEW.id, 'low_confidence');
    ELSIF NEW.consult_agronomist AND NEW.status = 'proposed' THEN
        INSERT INTO farm.review_queue (diagnosis_id, reason) VALUES (NEW.id, 'severe');
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_diagnosis_review AFTER INSERT ON farm.diagnosis FOR EACH ROW EXECUTE FUNCTION farm.trg_diagnosis_review();

-- DD-G05: confirmation generates the record, the tasks and the reminders (FR-09, FR-16, AC-03).
CREATE OR REPLACE FUNCTION farm.trg_diagnosis_confirmed() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_sev farm.severity_level; o farm.observation%ROWTYPE;
BEGIN
    IF NEW.status = 'confirmed' AND OLD.status IS DISTINCT FROM 'confirmed' THEN
        IF OLD.status IN ('refused', 'superseded', 'corrected') THEN RAISE EXCEPTION 'DIAGNOSIS_STATE: a % diagnosis cannot be confirmed', OLD.status; END IF;
        IF NEW.chosen_id IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.candidates_json) c WHERE c->>'condition_code' = NEW.chosen_id) THEN
            RAISE EXCEPTION 'CHOSEN_NOT_CANDIDATE: chosen_id must be one of the candidates (C-04)';
        END IF;
        IF NEW.confirmed_by IS NULL THEN RAISE EXCEPTION 'CONFIRMER_REQUIRED'; END IF;
        SELECT * INTO o FROM farm.observation WHERE id = NEW.observation_id;
        v_sev := coalesce(o.severity, farm.severity_level(o.area_pct));
        PERFORM farm.generate_from_diagnosis(NEW.id, NEW.confirmed_by, NEW.chosen_id, v_sev);
        UPDATE farm.review_queue SET resolved_at = now(), resolution = 'confirmed' WHERE diagnosis_id = NEW.id AND resolved_at IS NULL;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_diagnosis_confirmed AFTER UPDATE OF status ON farm.diagnosis FOR EACH ROW EXECUTE FUNCTION farm.trg_diagnosis_confirmed();

-- DD-G06: a correction becomes training data with provenance and a record version (FR-07, AI-09, AC-06).
CREATE OR REPLACE FUNCTION farm.trg_correction_dataset() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d farm.diagnosis%ROWTYPE; o farm.observation%ROWTYPE; r farm.scouting_record%ROWTYPE; v_ids uuid[]; v_sev farm.severity_level;
BEGIN
    SELECT * INTO d FROM farm.diagnosis WHERE id = NEW.diagnosis_id;
    IF d.status = 'refused' THEN RAISE EXCEPTION 'DIAGNOSIS_STATE: a refused diagnosis has nothing to correct'; END IF;
    IF NOT EXISTS (SELECT 1 FROM farm.app_user u WHERE u.id = NEW.reviewer_id AND u.role IN ('agronomist', 'admin')) THEN
        RAISE EXCEPTION 'REVIEWER_ROLE: corrections are made by agronomists (FR-07)';
    END IF;
    SELECT * INTO o FROM farm.observation WHERE id = d.observation_id;
    SELECT coalesce(array_agg((e)::uuid), '{}') INTO v_ids FROM jsonb_array_elements_text(o.photos_json) e;
    INSERT INTO farm.label_example (correction_id, photo_ids, label_code, original_candidates, model_version, reviewer_ref)
    VALUES (NEW.id, v_ids, NEW.corrected_code, d.candidates_json, d.model_version, farm.pseudonym(NEW.reviewer_id));
    UPDATE farm.diagnosis SET status = 'corrected', chosen_id = NEW.corrected_code WHERE id = d.id;
    UPDATE farm.review_queue SET resolved_at = now(), resolution = 'corrected', assigned_to = coalesce(assigned_to, NEW.reviewer_id) WHERE diagnosis_id = d.id AND resolved_at IS NULL;
    v_sev := coalesce(NEW.severity, o.severity, farm.severity_level(o.area_pct));
    SELECT * INTO r FROM farm.scouting_record s WHERE s.diagnosis_id = d.id ORDER BY s.record_version DESC LIMIT 1;
    IF FOUND THEN
        INSERT INTO farm.scouting_record (record_no, record_version, supersedes, reason_th, zone_id, observed_at, observation_id, diagnosis_id, condition_code, severity,
                                          area_pct, plants_affected, plants_inspected, evidence_photo_ids, notes_th, author_id, author_ref)
        VALUES (r.record_no, r.record_version + 1, r.id, 'แก้ไขผลวินิจฉัยโดยนักวิชาการเกษตร: ' || coalesce(NEW.note_th, ''), r.zone_id, r.observed_at, r.observation_id, r.diagnosis_id,
                NEW.corrected_code, v_sev, r.area_pct, r.plants_affected, r.plants_inspected, r.evidence_photo_ids, r.notes_th, NEW.reviewer_id, farm.pseudonym(NEW.reviewer_id));
    ELSE
        PERFORM farm.generate_from_diagnosis(d.id, NEW.reviewer_id, NEW.corrected_code, v_sev);
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_correction_dataset AFTER INSERT ON farm.diagnosis_correction FOR EACH ROW EXECUTE FUNCTION farm.trg_correction_dataset();

CREATE OR REPLACE FUNCTION farm.trg_diagnosis_source() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.diagnosis_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM farm.diagnosis d WHERE d.id = NEW.diagnosis_id AND d.status IN ('confirmed', 'corrected')) THEN
        RAISE EXCEPTION 'DIAGNOSIS_NOT_CONFIRMED: a scouting record can cite only a confirmed or corrected diagnosis (FR-09)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_diagnosis_source BEFORE INSERT ON farm.scouting_record FOR EACH ROW EXECUTE FUNCTION farm.trg_diagnosis_source();

-- DD-G07: PHI (FR-11, AC-04) and traceability (FR-12).
CREATE OR REPLACE FUNCTION farm.trg_harvest_phi() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_clear timestamptz;
BEGIN
    v_clear := farm.phi_clear_at(NEW.zone_id, NEW.harvested_at);
    IF v_clear IS NOT NULL AND v_clear > NEW.harvested_at THEN
        RAISE EXCEPTION 'PHI_NOT_ELAPSED: zone is clear for harvest at % (harvest at %) — FR-11', v_clear, NEW.harvested_at
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.traceability_json = '{}'::jsonb THEN NEW.traceability_json := farm.traceability(NEW.zone_id, NEW.harvested_at); END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_harvest_phi BEFORE INSERT ON farm.harvest FOR EACH ROW EXECUTE FUNCTION farm.trg_harvest_phi();

CREATE OR REPLACE FUNCTION farm.trg_task_rules() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_clear timestamptz;
BEGIN
    IF NEW.status = 'done' AND OLD.status <> 'done' THEN
        NEW.completed_at := coalesce(NEW.completed_at, now());
        IF NEW.completed_by IS NULL THEN RAISE EXCEPTION 'COMPLETER_REQUIRED: a done task records who completed it (FR-17)'; END IF;
        IF NEW.kind = 'harvest' THEN
            v_clear := farm.phi_clear_at(NEW.zone_id, NEW.completed_at);
            IF v_clear IS NOT NULL AND v_clear > NEW.completed_at THEN
                RAISE EXCEPTION 'PHI_NOT_ELAPSED: harvest task cannot be completed before % (FR-11)', v_clear USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_task_rules BEFORE UPDATE ON farm.task FOR EACH ROW EXECUTE FUNCTION farm.trg_task_rules();

-- FR-18: reminders never inside quiet hours.
CREATE OR REPLACE FUNCTION farm.trg_reminder_quiet_hours() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE f farm.farm%ROWTYPE; v_local timestamp; v_t time;
BEGIN
    SELECT fm.* INTO f FROM farm.farm fm JOIN farm.zone z ON z.farm_id = fm.id JOIN farm.task t ON t.zone_id = z.id WHERE t.id = NEW.task_id;
    v_local := NEW.scheduled_at AT TIME ZONE f.timezone;
    v_t := v_local::time;
    IF f.quiet_hours_start > f.quiet_hours_end THEN            -- window wraps midnight, e.g. 20:00–06:00
        IF v_t >= f.quiet_hours_start THEN
            NEW.scheduled_at := ((v_local::date + 1) + f.quiet_hours_end) AT TIME ZONE f.timezone;
        ELSIF v_t < f.quiet_hours_end THEN
            NEW.scheduled_at := (v_local::date + f.quiet_hours_end) AT TIME ZONE f.timezone;
        END IF;
    ELSIF v_t >= f.quiet_hours_start AND v_t < f.quiet_hours_end THEN
        NEW.scheduled_at := (v_local::date + f.quiet_hours_end) AT TIME ZONE f.timezone;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_reminder_quiet_hours BEFORE INSERT ON farm.reminder FOR EACH ROW EXECUTE FUNCTION farm.trg_reminder_quiet_hours();

-- FR-19: follow-up severity comparison.
CREATE OR REPLACE FUNCTION farm.trg_followup_compare() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_orig numeric;
BEGIN
    IF NEW.followup_of IS NOT NULL THEN
        SELECT area_pct INTO v_orig FROM farm.observation WHERE id = NEW.followup_of;
        NEW.kind := 'followup';
        NEW.followup_delta_pct := NEW.area_pct - v_orig;
    END IF;
    IF NEW.severity IS NULL AND NEW.area_pct IS NOT NULL THEN NEW.severity := farm.severity_level(NEW.area_pct); END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_followup_compare BEFORE INSERT ON farm.observation FOR EACH ROW EXECUTE FUNCTION farm.trg_followup_compare();

-- DD-G08: sensors — unit fixed by kind, range flagged, faults become tasks (FR-21, FR-22).
CREATE OR REPLACE FUNCTION farm.trg_sensor_unit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_unit text;
BEGIN
    SELECT unit INTO v_unit FROM farm.sensor_kind WHERE code = NEW.kind;
    IF NEW.unit <> v_unit THEN RAISE EXCEPTION 'UNIT_MISMATCH: sensor kind % reports in %, not % (FR-21)', NEW.kind, v_unit, NEW.unit; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_sensor_unit BEFORE INSERT OR UPDATE OF kind, unit ON farm.sensor FOR EACH ROW EXECUTE FUNCTION farm.trg_sensor_unit();

CREATE OR REPLACE FUNCTION farm.trg_telemetry_range() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = farm, public AS $$
DECLARE k farm.sensor_kind%ROWTYPE;
BEGIN
    SELECT sk.* INTO k FROM farm.sensor s JOIN farm.sensor_kind sk ON sk.code = s.kind WHERE s.id = NEW.sensor_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'UNKNOWN_SENSOR'; END IF;
    IF NEW.value < k.min_value OR NEW.value > k.max_value THEN NEW.quality := 'out_of_range'; END IF;
    UPDATE farm.sensor SET last_seen_at = greatest(coalesce(last_seen_at, NEW.ts), NEW.ts) WHERE id = NEW.sensor_id;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_telemetry_range BEFORE INSERT ON farm.telemetry FOR EACH ROW EXECUTE FUNCTION farm.trg_telemetry_range();

CREATE OR REPLACE FUNCTION farm.trg_sensor_fault_task() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s farm.sensor%ROWTYPE; v_task uuid; v_owner uuid;
BEGIN
    SELECT * INTO s FROM farm.sensor WHERE id = NEW.sensor_id;
    SELECT f.owner_id INTO v_owner FROM farm.zone z JOIN farm.farm f ON f.id = z.farm_id WHERE z.id = s.zone_id;
    INSERT INTO farm.task (zone_id, kind, description_th, description_en, due_at, owner_id, priority, sensor_id)
    VALUES (s.zone_id, 'sensor_maintenance',
            format('ตรวจสอบเซ็นเซอร์ %s (%s): %s', s.device_code, s.kind, CASE NEW.kind WHEN 'stuck' THEN 'ค่าค้าง' WHEN 'offline' THEN 'ขาดการเชื่อมต่อ' ELSE 'ค่านอกช่วง' END),
            format('Check sensor %s (%s): %s', s.device_code, s.kind, NEW.kind), NEW.detected_at + interval '1 day', v_owner,
            CASE WHEN NEW.kind = 'offline' THEN 'critical'::farm.task_priority ELSE 'normal'::farm.task_priority END, s.id)
    RETURNING id INTO v_task;
    UPDATE farm.sensor_fault SET task_id = v_task WHERE id = NEW.id;
    UPDATE farm.sensor SET status = CASE WHEN NEW.kind = 'offline' THEN 'offline'::farm.sensor_status ELSE 'fault'::farm.sensor_status END WHERE id = s.id;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_sensor_fault_task AFTER INSERT ON farm.sensor_fault FOR EACH ROW EXECUTE FUNCTION farm.trg_sensor_fault_task();

-- AI-02 / AI-03 / AI-04 / AI-05: evaluation gate, release gate, calibration.
CREATE OR REPLACE FUNCTION farm.trg_eval_gate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s farm.setting%ROWTYPE;
BEGIN
    SELECT * INTO s FROM farm.setting WHERE id = 1;
    NEW.passed := NEW.set_kind = 'field' AND NEW.top1 >= s.gate_top1_min AND NEW.top3 >= s.gate_top3_min AND (NEW.ece IS NULL OR NEW.ece <= 0.05);
    RETURN NEW;
END $$;
CREATE TRIGGER trg_eval_gate BEFORE INSERT OR UPDATE ON farm.model_eval_run FOR EACH ROW EXECUTE FUNCTION farm.trg_eval_gate();

CREATE OR REPLACE FUNCTION farm.trg_calibration_required() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'released' AND OLD.status IS DISTINCT FROM 'released'
       AND NOT EXISTS (SELECT 1 FROM farm.calibration_version c WHERE c.model_id = NEW.id AND c.active) THEN
        RAISE EXCEPTION 'CALIBRATION_REQUIRED: a released model needs an active calibration with a reliability diagram (AI-05)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_calibration_required BEFORE UPDATE OF status ON farm.model_registry FOR EACH ROW EXECUTE FUNCTION farm.trg_calibration_required();

CREATE OR REPLACE FUNCTION farm.trg_model_release_gate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s farm.setting%ROWTYPE;
BEGIN
    SELECT * INTO s FROM farm.setting WHERE id = 1;
    IF NEW.status = 'released' AND OLD.status IS DISTINCT FROM 'released' THEN
        IF NOT EXISTS (SELECT 1 FROM farm.model_eval_run e WHERE e.model_id = NEW.id AND e.set_kind = 'field' AND e.passed) THEN
            RAISE EXCEPTION 'RELEASE_GATE_FAILED: no passed FIELD evaluation (top-1 ≥ %, top-3 ≥ %) — lab-only metrics are not evidence (AI-02, AI-03)', s.gate_top1_min, s.gate_top3_min;
        END IF;
        IF NEW.kind = 'device' AND NEW.size_mb > s.device_model_max_mb THEN
            RAISE EXCEPTION 'DEVICE_MODEL_TOO_LARGE: % MB > % MB (AI-04)', NEW.size_mb, s.device_model_max_mb;
        END IF;
        NEW.released_at := coalesce(NEW.released_at, now());
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_model_release_gate BEFORE UPDATE OF status ON farm.model_registry FOR EACH ROW EXECUTE FUNCTION farm.trg_model_release_gate();

-- FR-31 / AC-09: a forecast is an interval with factors, or an explicit insufficient_data.
CREATE OR REPLACE FUNCTION farm.trg_forecast_interval() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'ok' THEN
        IF NEW.factors_json = '{}'::jsonb THEN RAISE EXCEPTION 'FORECAST_SHAPE: factors_json is mandatory (FR-31)'; END IF;
        IF NEW.kind = 'yield' AND NOT (NEW.low IS NOT NULL AND NEW.high IS NOT NULL AND NEW.value IS NOT NULL AND NEW.low <= NEW.value AND NEW.value <= NEW.high) THEN
            RAISE EXCEPTION 'FORECAST_SHAPE: yield needs low <= value <= high (FR-31)';
        END IF;
        IF NEW.kind = 'harvest_date' AND NOT (NEW.low_date IS NOT NULL AND NEW.high_date IS NOT NULL AND NEW.value_date IS NOT NULL AND NEW.low_date <= NEW.value_date AND NEW.value_date <= NEW.high_date) THEN
            RAISE EXCEPTION 'FORECAST_SHAPE: harvest_date needs low_date <= value_date <= high_date (FR-31)';
        END IF;
    ELSE
        NEW.value := NULL; NEW.low := NULL; NEW.high := NULL; NEW.value_date := NULL; NEW.low_date := NULL; NEW.high_date := NULL;
        IF NOT (NEW.factors_json ? 'reason') THEN RAISE EXCEPTION 'FORECAST_SHAPE: insufficient_data must state a reason (AC-09)'; END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_forecast_interval BEFORE INSERT OR UPDATE ON farm.forecast FOR EACH ROW EXECUTE FUNCTION farm.trg_forecast_interval();

-- IF-63 / AC-07: replays are refused at the row level (apply_sync_batch returns the stored result before reaching here).
CREATE OR REPLACE FUNCTION farm.trg_sync_idempotent() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM farm.sync_batch b WHERE b.idempotency_key = NEW.idempotency_key) THEN
        RAISE EXCEPTION 'SYNC_REPLAY: batch % was already applied; use farm.apply_sync_batch() to get its result (NFR-02)', NEW.idempotency_key;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_sync_idempotent BEFORE INSERT ON farm.sync_batch FOR EACH ROW EXECUTE FUNCTION farm.trg_sync_idempotent();

-- DD-G09 / NFR-05: erasure pseudonymises the person; record versions and the chain are untouched.
CREATE OR REPLACE FUNCTION farm.trg_pdpa_erasure() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.kind = 'erasure' AND NEW.status = 'completed' AND OLD.status <> 'completed' THEN
        UPDATE farm.app_user SET username = 'erased-' || left(id::text, 8), display_name = 'erased', phone = NULL, line_user_id = NULL,
                                 active = false, erased_at = now() WHERE id = NEW.user_id;
        DELETE FROM farm.notification_channel WHERE user_id = NEW.user_id;
        UPDATE farm.device SET push_token_ref = NULL WHERE user_id = NEW.user_id;
        UPDATE farm.observation SET gps = NULL WHERE reporter_id = NEW.user_id;
        NEW.completed_at := coalesce(NEW.completed_at, now());
        INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
        VALUES (NULL, 'scheduler', 'pdpa.erasure', 'app_user', NEW.user_id::text, jsonb_build_object('request_id', NEW.id, 'records_kept', true));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_pdpa_erasure BEFORE UPDATE OF status ON farm.data_request FOR EACH ROW EXECUTE FUNCTION farm.trg_pdpa_erasure();

-- IF-66 / NFR-04: the export manifest and its verification hash.
CREATE OR REPLACE FUNCTION farm.trg_export_hash() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_heads jsonb; v_records jsonb; v_gaps int; v_count int;
BEGIN
    SELECT coalesce(jsonb_object_agg(z.code, jsonb_build_object('seq', c.seq, 'hash', c.hash)), '{}'::jsonb) INTO v_heads
    FROM farm.zone z JOIN LATERAL (SELECT seq, hash FROM farm.record_chain rc WHERE rc.zone_id = z.id ORDER BY seq DESC LIMIT 1) c ON true
    WHERE z.farm_id = NEW.farm_id AND (NEW.zone_id IS NULL OR z.id = NEW.zone_id);
    SELECT coalesce(jsonb_agg(jsonb_build_object('kind', r.kind, 'record_no', r.record_no, 'version', r.record_version, 'zone', r.zone_code, 'at', r.record_at, 'hash', r.hash) ORDER BY r.record_at, r.record_no), '[]'::jsonb), count(*)
    INTO v_records, v_count
    FROM farm.v_record_current r
    WHERE r.farm_id = NEW.farm_id AND (NEW.zone_id IS NULL OR r.zone_id = NEW.zone_id) AND r.record_at::date BETWEEN NEW.period_from AND NEW.period_to;
    SELECT count(*) INTO v_gaps FROM farm.compliance_gaps(NEW.farm_id, NEW.period_from, NEW.period_to) g
    WHERE NEW.zone_id IS NULL OR g.zone_code = (SELECT code FROM farm.zone WHERE id = NEW.zone_id);
    NEW.chain_heads := v_heads; NEW.record_count := v_count; NEW.gap_count := v_gaps;
    NEW.manifest_json := jsonb_build_object('scheme', NEW.scheme_code, 'period_from', NEW.period_from, 'period_to', NEW.period_to,
                                            'zone_id', NEW.zone_id, 'record_count', v_count, 'gap_count', v_gaps, 'chain_heads', v_heads, 'records', v_records);
    NEW.verify_hash := encode(digest(NEW.manifest_json::text, 'sha256'), 'hex');
    RETURN NEW;
END $$;

-- =====================================================================
-- 19. VIEWS
-- =====================================================================

-- Current version of every record, all kinds, with the farm for filtering (DD-G01).
CREATE OR REPLACE VIEW farm.v_record_current AS
    SELECT 'scouting'::farm.record_kind AS kind, s.id, s.record_no, s.record_version, s.zone_id, z.farm_id, z.code AS zone_code, s.observed_at AS record_at,
           s.condition_code AS detail, s.severity::text AS detail2, s.author_ref, s.hash, s.created_at
    FROM farm.scouting_record s JOIN farm.zone z ON z.id = s.zone_id
    WHERE s.record_version = (SELECT max(record_version) FROM farm.scouting_record x WHERE x.record_no = s.record_no)
    UNION ALL
    SELECT 'input_usage', u.id, u.record_no, u.record_version, u.zone_id, z.farm_id, z.code, u.ts, p.code, u.dose || ' ' || u.unit, u.author_ref, u.hash, u.created_at
    FROM farm.input_usage u JOIN farm.zone z ON z.id = u.zone_id JOIN farm.input_product p ON p.id = u.product_id
    WHERE u.record_version = (SELECT max(record_version) FROM farm.input_usage x WHERE x.record_no = u.record_no)
    UNION ALL
    SELECT 'harvest', h.id, h.record_no, h.record_version, h.zone_id, z.farm_id, z.code, h.harvested_at, h.lot_code, h.qty || ' ' || h.unit, h.author_ref, h.hash, h.created_at
    FROM farm.harvest h JOIN farm.zone z ON z.id = h.zone_id
    WHERE h.record_version = (SELECT max(record_version) FROM farm.harvest x WHERE x.record_no = h.record_no);

CREATE TRIGGER trg_export_hash BEFORE INSERT ON farm.export_package FOR EACH ROW EXECUTE FUNCTION farm.trg_export_hash();

-- Every version of every record, for the auditor and AC-06.
CREATE OR REPLACE VIEW farm.v_record_versions AS
    SELECT 'scouting'::farm.record_kind AS kind, record_no, record_version, id, supersedes, reason_th, zone_id, observed_at AS record_at, author_ref, prev_hash, hash, created_at FROM farm.scouting_record
    UNION ALL SELECT 'input_usage', record_no, record_version, id, supersedes, reason_th, zone_id, ts, author_ref, prev_hash, hash, created_at FROM farm.input_usage
    UNION ALL SELECT 'harvest', record_no, record_version, id, supersedes, reason_th, zone_id, harvested_at, author_ref, prev_hash, hash, created_at FROM farm.harvest;

CREATE OR REPLACE VIEW farm.v_chain_status AS
    SELECT z.farm_id, z.id AS zone_id, z.code AS zone_code, c.seq AS head_seq, c.hash AS head_hash, c.created_at AS head_at,
           (SELECT bool_and(ok) FROM farm.verify_chain(z.id)) AS chain_ok
    FROM farm.zone z LEFT JOIN LATERAL (SELECT seq, hash, created_at FROM farm.record_chain rc WHERE rc.zone_id = z.id ORDER BY seq DESC LIMIT 1) c ON true;

-- PHI board (FR-11).
CREATE OR REPLACE VIEW farm.v_zone_phi AS
    SELECT z.farm_id, z.id AS zone_id, z.code AS zone_code, c.code AS crop, p.clear, p.clear_at, p.blocking_record_no, p.blocking_product, p.days_remaining
    FROM farm.zone z LEFT JOIN farm.crop c ON c.id = z.crop_id, LATERAL farm.phi_status(z.id, now()) p;

-- Traceability per lot (FR-12).
CREATE OR REPLACE VIEW farm.v_traceability AS
    SELECT h.lot_code, h.record_no, h.record_version, z.farm_id, z.code AS zone_code, h.harvested_at, h.qty, h.unit, h.grade,
           jsonb_array_length(h.traceability_json->'inputs') AS input_count, jsonb_array_length(h.traceability_json->'scouting') AS scouting_count,
           h.traceability_json->>'phi_clear_at' AS phi_clear_at, h.hash
    FROM farm.harvest h JOIN farm.zone z ON z.id = h.zone_id
    WHERE h.record_version = (SELECT max(record_version) FROM farm.harvest x WHERE x.record_no = h.record_no);

-- Compliance gaps over the last 90 days for every farm (FR-15).
CREATE OR REPLACE VIEW farm.v_compliance_gaps AS
    SELECT f.id AS farm_id, f.code AS farm_code, g.* FROM farm.farm f, LATERAL farm.compliance_gaps(f.id, (now()::date - 90), now()::date) g;

-- Task board (FR-17, FR-20).
CREATE OR REPLACE VIEW farm.v_task_board AS
    SELECT t.id, z.farm_id, z.code AS zone_code, t.kind, t.priority, t.status, t.due_at, t.owner_id, t.description_th,
           t.due_at < now() AND t.status = 'open' AS overdue, t.escalated_at IS NOT NULL AS escalated,
           t.source_diagnosis_id, t.sensor_id, t.completed_at,
           CASE WHEN t.kind = 'harvest' THEN (SELECT clear FROM farm.phi_status(t.zone_id, now())) END AS phi_clear
    FROM farm.task t JOIN farm.zone z ON z.id = t.zone_id;

-- Review queue for agronomists (FR-05).
CREATE OR REPLACE VIEW farm.v_review_queue AS
    SELECT q.id, q.reason, q.queued_at, q.assigned_to, q.resolved_at, q.resolution, d.id AS diagnosis_id, d.top1_prob, d.candidates_json, d.model_version,
           o.id AS observation_id, o.zone_id, z.code AS zone_code, z.farm_id, o.ts, o.area_pct, o.severity, o.photos_json
    FROM farm.review_queue q JOIN farm.diagnosis d ON d.id = q.diagnosis_id JOIN farm.observation o ON o.id = d.observation_id JOIN farm.zone z ON z.id = o.zone_id;

-- Diagnosis quality per model version (AI-02 in production; OPS-12 §7).
CREATE OR REPLACE VIEW farm.v_diagnosis_quality AS
    SELECT d.model_version, d.computed_on, count(*) AS n,
           round(avg(CASE WHEN d.ood THEN 1 ELSE 0 END), 3) AS ood_rate,
           round(avg(CASE WHEN d.status = 'needs_review' OR EXISTS (SELECT 1 FROM farm.review_queue q WHERE q.diagnosis_id = d.id) THEN 1 ELSE 0 END), 3) AS review_rate,
           round(avg(CASE WHEN d.status = 'corrected' THEN 1 ELSE 0 END), 3) AS corrected_rate,
           round(avg(d.top1_prob), 3) AS mean_top1
    FROM farm.diagnosis d GROUP BY d.model_version, d.computed_on;

-- Sensor health (FR-22).
CREATE OR REPLACE VIEW farm.v_sensor_health AS
    SELECT s.id, z.farm_id, z.code AS zone_code, s.kind, s.unit, s.device_code, s.status, s.last_seen_at,
           farm.sensor_offline(s.id, now()) AS offline_now, farm.sensor_stuck(s.id) AS stuck_now,
           (SELECT count(*) FROM farm.sensor_fault f WHERE f.sensor_id = s.id AND f.resolved_at IS NULL) AS open_faults
    FROM farm.sensor s JOIN farm.zone z ON z.id = s.zone_id;

-- Active advisories (FR-24…26).
CREATE OR REPLACE VIEW farm.v_advisory_active AS
    SELECT a.*, z.code AS zone_code FROM farm.advisory a LEFT JOIN farm.zone z ON z.id = a.zone_id
    WHERE a.valid_until IS NULL OR a.valid_until > now();

-- Latest forecast per zone and kind (FR-30, FR-31).
CREATE OR REPLACE VIEW farm.v_harvest_outlook AS
    SELECT DISTINCT ON (f.zone_id, f.kind) f.zone_id, z.farm_id, z.code AS zone_code, f.kind, f.status, f.value, f.low, f.high, f.value_date, f.low_date, f.high_date, f.factors_json, f.generated_at
    FROM farm.forecast f JOIN farm.zone z ON z.id = f.zone_id ORDER BY f.zone_id, f.kind, f.generated_at DESC;

-- Export index for auditors (FR-13).
CREATE OR REPLACE VIEW farm.v_export_index AS
    SELECT e.id, e.farm_id, z.code AS zone_code, e.scheme_code, e.period_from, e.period_to, e.generated_at, e.record_count, e.gap_count, e.verify_hash, e.chain_heads
    FROM farm.export_package e LEFT JOIN farm.zone z ON z.id = e.zone_id;

-- Scrap of typing: what a confirmed diagnosis produced (AC-03).
CREATE OR REPLACE VIEW farm.v_diagnosis_outcome AS
    SELECT d.id AS diagnosis_id, d.status, d.chosen_id, d.top1_prob, d.consult_agronomist, z.code AS zone_code,
           (SELECT record_no FROM farm.scouting_record s WHERE s.diagnosis_id = d.id ORDER BY record_version LIMIT 1) AS record_no,
           (SELECT max(record_version) FROM farm.scouting_record s WHERE s.diagnosis_id = d.id) AS record_versions,
           (SELECT count(*) FROM farm.task t WHERE t.source_diagnosis_id = d.id) AS tasks,
           (SELECT count(*) FROM farm.reminder r JOIN farm.task t ON t.id = r.task_id WHERE t.source_diagnosis_id = d.id) AS reminders,
           (SELECT count(*) FROM farm.treatment_recommendation tr WHERE tr.diagnosis_id = d.id) AS recommendations
    FROM farm.diagnosis d JOIN farm.observation o ON o.id = d.observation_id JOIN farm.zone z ON z.id = o.zone_id;

-- =====================================================================
-- 20. INDEXES
-- =====================================================================
CREATE INDEX idx_zone_farm            ON farm.zone (farm_id);
CREATE INDEX idx_zone_boundary        ON farm.zone USING gist (boundary);
CREATE INDEX idx_farm_location        ON farm.farm USING gist (location);
CREATE INDEX idx_observation_zone_ts  ON farm.observation (zone_id, ts DESC);
CREATE INDEX idx_observation_reporter ON farm.observation (reporter_id);
CREATE INDEX idx_observation_followup ON farm.observation (followup_of) WHERE followup_of IS NOT NULL;
CREATE INDEX idx_observation_sync     ON farm.observation (sync_batch_id) WHERE sync_batch_id IS NOT NULL;
CREATE INDEX idx_photo_observation    ON farm.photo (observation_id);
CREATE INDEX idx_diagnosis_obs        ON farm.diagnosis (observation_id);
CREATE INDEX idx_diagnosis_status     ON farm.diagnosis (status, created_at DESC);
CREATE INDEX idx_diagnosis_model      ON farm.diagnosis (model_version);
CREATE INDEX idx_review_open          ON farm.review_queue (queued_at) WHERE resolved_at IS NULL;
CREATE INDEX idx_correction_diag      ON farm.diagnosis_correction (diagnosis_id);
CREATE INDEX idx_product_name_trgm    ON farm.input_product USING gin (name gin_trgm_ops);
CREATE INDEX idx_product_approved     ON farm.input_product (approved) WHERE approved;
CREATE INDEX idx_recommendation_diag  ON farm.treatment_recommendation (diagnosis_id);
CREATE INDEX idx_scouting_zone_at     ON farm.scouting_record (zone_id, observed_at DESC);
CREATE INDEX idx_scouting_diag        ON farm.scouting_record (diagnosis_id);
CREATE INDEX idx_input_usage_zone_ts  ON farm.input_usage (zone_id, ts DESC);
CREATE INDEX idx_input_usage_clear    ON farm.input_usage (zone_id, phi_clear_at DESC);
CREATE INDEX idx_harvest_zone_at      ON farm.harvest (zone_id, harvested_at DESC);
CREATE INDEX idx_harvest_lot          ON farm.harvest (lot_code);
CREATE INDEX idx_chain_zone_seq       ON farm.record_chain (zone_id, seq DESC);
CREATE INDEX idx_task_zone_status     ON farm.task (zone_id, status, due_at);
CREATE INDEX idx_task_owner_open      ON farm.task (owner_id, due_at) WHERE status = 'open';
CREATE INDEX idx_task_overdue_crit    ON farm.task (due_at) WHERE status = 'open' AND priority = 'critical' AND escalated_at IS NULL;
CREATE INDEX idx_task_source          ON farm.task (source_diagnosis_id) WHERE source_diagnosis_id IS NOT NULL;
CREATE INDEX idx_reminder_due         ON farm.reminder (scheduled_at) WHERE status = 'scheduled';
CREATE INDEX idx_reminder_task        ON farm.reminder (task_id);
CREATE INDEX idx_sensor_zone          ON farm.sensor (zone_id);
CREATE INDEX idx_telemetry_ts         ON farm.telemetry (ts DESC);
CREATE INDEX idx_sensor_fault_open    ON farm.sensor_fault (sensor_id) WHERE resolved_at IS NULL;
CREATE INDEX idx_forecast_farm_valid  ON farm.weather_forecast (farm_id, valid_from);
CREATE INDEX idx_advisory_farm_ts     ON farm.advisory (farm_id, created_at DESC);
CREATE INDEX idx_advisory_zone_kind   ON farm.advisory (zone_id, kind, created_at DESC);
CREATE INDEX idx_question_conv        ON farm.question (conversation_id, asked_at);
CREATE INDEX idx_chunk_crop           ON farm.knowledge_chunk (crop_id);
CREATE INDEX idx_chunk_embedding      ON farm.knowledge_chunk USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_forecast_zone_kind   ON farm.forecast (zone_id, kind, generated_at DESC);
CREATE INDEX idx_eval_model           ON farm.model_eval_run (model_id, run_at DESC);
CREATE INDEX idx_calibration_active   ON farm.calibration_version (model_id) WHERE active;
CREATE INDEX idx_export_farm          ON farm.export_package (farm_id, generated_at DESC);
CREATE INDEX idx_data_request_open    ON farm.data_request (requested_at) WHERE status = 'open';
CREATE INDEX idx_audit_log_ts         ON audit.log (ts DESC);
CREATE INDEX idx_audit_log_entity     ON audit.log (entity, entity_id, ts DESC);
CREATE INDEX idx_auth_event_user      ON audit.auth_event (user_id, ts DESC);

-- =====================================================================
-- 21. ROLES AND GRANTS  (SEC-12 §5.7, TEST-12 TC-003)
-- =====================================================================
--   app_rw      api, scheduler, workers — full business access; audit INSERT/SELECT only
--   app_ro      dashboards and reports
--   ingest_rw   ingest-mqtt — INSERT telemetry only (+ the sensor lookup the range trigger needs; last_seen is updated by the SECURITY DEFINER trigger)
--   agent_ro    worker-agent — reads facts; NO identity columns, NO farm.location, NO devices/channels/requests
--   auditor_ro  GAP auditor — records, versions, chain, exports, evidence; nothing personal beyond pseudonyms
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')     THEN CREATE ROLE app_rw     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')     THEN CREATE ROLE app_ro     NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ingest_rw')  THEN CREATE ROLE ingest_rw  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_ro')   THEN CREATE ROLE agent_ro   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor_ro') THEN CREATE ROLE auditor_ro NOLOGIN; END IF;
END $$;

GRANT USAGE ON SCHEMA farm, audit TO app_rw, app_ro, ingest_rw, agent_ro, auditor_ro;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA farm TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA farm TO app_rw;
GRANT INSERT, SELECT ON audit.log, audit.auth_event TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA audit TO app_rw;
-- append-only is enforced by trg_record_append_only even for app_rw; belt and braces:
REVOKE UPDATE, DELETE ON farm.scouting_record, farm.input_usage, farm.harvest, farm.record_chain, farm.label_example FROM app_rw;

GRANT SELECT ON ALL TABLES IN SCHEMA farm TO app_ro;
GRANT SELECT ON audit.log, audit.auth_event TO app_ro;

GRANT INSERT ON farm.telemetry TO ingest_rw;
GRANT SELECT ON farm.sensor, farm.sensor_kind TO ingest_rw;

GRANT SELECT (id, role, locale) ON farm.app_user TO agent_ro;
GRANT SELECT (id, code, name, gap_scheme, timezone, quiet_hours_start, quiet_hours_end, reminder_time) ON farm.farm TO agent_ro;   -- no location (NFR-05)
GRANT SELECT ON farm.zone, farm.crop, farm.condition, farm.gap_scheme, farm.gap_scheme_rule, farm.setting,
                farm.observation, farm.photo, farm.diagnosis, farm.review_queue, farm.diagnosis_correction,
                farm.input_product, farm.treatment_recommendation, farm.scouting_record, farm.input_usage, farm.harvest, farm.record_chain,
                farm.task, farm.task_template, farm.sensor, farm.sensor_kind, farm.telemetry, farm.sensor_fault,
                farm.weather_forecast, farm.weather_daily, farm.risk_rule, farm.advisory, farm.knowledge_chunk,
                farm.conversation, farm.question, farm.answer, farm.yield_history, farm.forecast, farm.weekly_summary TO agent_ro;
GRANT SELECT ON farm.v_record_current, farm.v_zone_phi, farm.v_traceability, farm.v_compliance_gaps, farm.v_task_board, farm.v_advisory_active, farm.v_harvest_outlook TO agent_ro;
REVOKE SELECT ON farm.observation FROM agent_ro;
GRANT SELECT (id, zone_id, ts, kind, photos_json, severity, area_pct, plants_affected, plants_inspected, growth_stage, reporter_ref, followup_of, followup_delta_pct) ON farm.observation TO agent_ro;   -- no gps, no reporter_id
GRANT INSERT ON farm.conversation, farm.question, farm.answer, farm.advisory, farm.forecast, farm.weekly_summary TO agent_ro;

GRANT SELECT ON farm.scouting_record, farm.input_usage, farm.harvest, farm.record_chain, farm.export_package, farm.input_product, farm.gap_scheme, farm.gap_scheme_rule,
                farm.observation, farm.photo, farm.diagnosis, farm.diagnosis_correction, farm.zone, farm.crop, farm.condition, farm.task,
                farm.v_record_current, farm.v_record_versions, farm.v_chain_status, farm.v_zone_phi, farm.v_traceability, farm.v_compliance_gaps, farm.v_export_index TO auditor_ro;
GRANT SELECT (id, code, name, gap_scheme) ON farm.farm TO auditor_ro;
REVOKE SELECT ON farm.observation FROM auditor_ro;
GRANT SELECT (id, zone_id, ts, kind, photos_json, severity, area_pct, plants_affected, plants_inspected, growth_stage, reporter_ref) ON farm.observation TO auditor_ro;

-- =====================================================================
-- 22. MIGRATION MARK
-- =====================================================================
INSERT INTO farm.migration (id) VALUES ('farm_0001');
