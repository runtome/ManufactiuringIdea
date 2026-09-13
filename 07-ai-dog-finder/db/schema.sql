-- =====================================================================
--  PawTrace — AI Dog Finder 2.0 — database schema  (DDS-07)
--  Target   : PostgreSQL 16 + pgvector >= 0.7 + PostGIS 3.4   (image: deploy/postgres/Dockerfile)
--  Schemas  : pawtrace (all business data), audit (append-only)
--  Separate deployment from FactoryBrain (SAD-00 §13). Sections marked [platform] are copied from
--  00-factorybrain-platform/db/schema.sql: the helper functions byte-identically, audit.log / audit.auth_event
--  with core.app_user -> pawtrace.app_user (TEST-07 TC-002).
--
--  The privacy rules of SRS-07 are DATABASE RULES here (DDS-07 DD-T01..T09):
--    C-01  public role cannot read report.location; the only public form is fuzz_cell()
--    C-03  a match is never inserted as confirmed; only a match_decision row moves it
--    C-04  a photo cannot be approved unless exif_stripped
--    C-05  report_public exposes approved photos only
--    AC-08 one embedding version is search_active; per-version partial HNSW; search_candidates() reads one space
--    AC-06 deletion_request cascades to photos, instances, embeddings, text embeddings; tombstone in audit
--    FR-25 notification budget enforced on insert
--    AI-07 match_decision is append-only and carries the consent version
--
--  Apply:  psql -v ON_ERROR_STOP=1 -f schema.sql   (then optionally seed_demo.sql)
-- =====================================================================

-- =====================================================================
-- 1. EXTENSIONS
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_bytes, digest
CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector: embeddings
CREATE EXTENSION IF NOT EXISTS postgis;       -- geography, ST_DWithin, ST_GeoHash
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- description search

-- =====================================================================
-- 2. SCHEMAS
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS pawtrace;
CREATE SCHEMA IF NOT EXISTS audit;

COMMENT ON SCHEMA pawtrace IS 'PawTrace business data. Public reads go through public_ro, which cannot read report.location (DD-T01).';
COMMENT ON SCHEMA audit    IS 'Append-only audit log. INSERT only; no UPDATE or DELETE grants.';

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
CREATE TYPE pawtrace.report_kind        AS ENUM ('lost', 'found', 'sighting');
CREATE TYPE pawtrace.report_status      AS ENUM ('draft', 'active', 'matched', 'reunited', 'expired', 'closed');
CREATE TYPE pawtrace.match_status       AS ENUM ('candidate', 'confirmed', 'rejected', 'superseded');
CREATE TYPE pawtrace.moderation_status  AS ENUM ('pending', 'approved', 'hidden', 'removed');
CREATE TYPE pawtrace.processing_state   AS ENUM ('queued', 'processing', 'done', 'rejected', 'failed');
CREATE TYPE pawtrace.size_class         AS ENUM ('small', 'medium', 'large', 'giant');
CREATE TYPE pawtrace.coat_len           AS ENUM ('short', 'medium', 'long', 'wire', 'hairless');
CREATE TYPE pawtrace.coat_color         AS ENUM ('black', 'white', 'brown', 'tan', 'golden', 'grey', 'red', 'cream', 'brindle', 'merle', 'spotted');
CREATE TYPE pawtrace.breed_group        AS ENUM ('toy', 'terrier', 'hound', 'working', 'herding', 'sporting', 'non_sporting', 'mixed', 'unknown');
CREATE TYPE pawtrace.model_kind         AS ENUM ('detector', 'embedding', 'attributes', 'nsfw', 'text');
CREATE TYPE pawtrace.decision_kind      AS ENUM ('confirm', 'reject');
CREATE TYPE pawtrace.notification_kind  AS ENUM ('candidate', 'new_report_in_area', 'message', 'reunion', 'moderation', 'digest');
CREATE TYPE pawtrace.channel_kind       AS ENUM ('push', 'email', 'sms', 'digest', 'in_app');
CREATE TYPE pawtrace.audience           AS ENUM ('public', 'subscriber', 'owner', 'counterpart');
CREATE TYPE pawtrace.user_role          AS ENUM ('user', 'shelter', 'moderator', 'admin');
CREATE TYPE pawtrace.entity_kind        AS ENUM ('report', 'photo', 'message', 'device', 'user', 'thread');
CREATE TYPE pawtrace.sender_kind        AS ENUM ('lost_side', 'found_side', 'moderator', 'system');

-- =====================================================================
-- 5. PEOPLE, DEVICES, REGIONS, SETTINGS
-- =====================================================================
CREATE TABLE pawtrace.app_user (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    email            text NOT NULL,
    display_name     text NOT NULL,
    role             pawtrace.user_role NOT NULL DEFAULT 'user',
    locale           text NOT NULL DEFAULT 'th' CHECK (locale IN ('th', 'en')),
    consent_version  text NOT NULL,                       -- terms accepted at sign-up (AI-07)
    consent_at       timestamptz NOT NULL DEFAULT now(),
    shelter_name     text,                                -- role = shelter
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,                         -- set by a deletion request; row anonymised
    CONSTRAINT shelter_has_name CHECK (role <> 'shelter' OR shelter_name IS NOT NULL)
);
CREATE UNIQUE INDEX ux_app_user_email ON pawtrace.app_user (lower(email)) WHERE deleted_at IS NULL;
COMMENT ON TABLE pawtrace.app_user IS 'Passwordless (magic link / OTP). No phone column: contact is a relay (FR-07, ADR-T08).';

CREATE TABLE pawtrace.device (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    token_hash        bytea NOT NULL UNIQUE,              -- sha256 of the anonymous device token (IF-41)
    first_ip          inet,
    trust_score       numeric(3,2) NOT NULL DEFAULT 0.50 CHECK (trust_score BETWEEN 0 AND 1),
    captcha_required  boolean NOT NULL DEFAULT false,
    banned_at         timestamptz,
    ban_reason        text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    last_seen_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE pawtrace.device IS 'Anonymous posting identity (C-02, ADR-T07). Trust score drives CAPTCHA and bans; the token itself is never stored.';

CREATE TABLE pawtrace.region (
    id                          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                        text NOT NULL UNIQUE,
    name                        text NOT NULL,
    center                      geography(Point, 4326) NOT NULL,
    fuzz_public_precision       smallint NOT NULL DEFAULT 5 CHECK (fuzz_public_precision BETWEEN 3 AND 5),      -- geohash chars: 5 ≈ 4.9 km cells
    fuzz_subscriber_precision   smallint NOT NULL DEFAULT 6 CHECK (fuzz_subscriber_precision BETWEEN 4 AND 6),  -- 6 ≈ 1.2 km
    default_radius_m            integer  NOT NULL DEFAULT 5000  CHECK (default_radius_m BETWEEN 500 AND 50000),
    max_radius_m                integer  NOT NULL DEFAULT 50000 CHECK (max_radius_m BETWEEN 1000 AND 50000),
    default_days                smallint NOT NULL DEFAULT 3  CHECK (default_days BETWEEN 1 AND 30),
    max_days                    smallint NOT NULL DEFAULT 30 CHECK (max_days BETWEEN 1 AND 30),
    notify_threshold            numeric(4,3) NOT NULL DEFAULT 0.250 CHECK (notify_threshold BETWEEN 0.05 AND 0.9),
    notify_rank_max             smallint NOT NULL DEFAULT 5 CHECK (notify_rank_max BETWEEN 1 AND 20),
    notify_daily_cap            smallint NOT NULL DEFAULT 5 CHECK (notify_daily_cap BETWEEN 1 AND 50),
    active                      boolean NOT NULL DEFAULT true,
    CONSTRAINT region_precision_order CHECK (fuzz_subscriber_precision >= fuzz_public_precision)
);
COMMENT ON COLUMN pawtrace.region.fuzz_public_precision IS 'Geohash precision for public views (C-01). 5 = ~4.9 x 4.9 km; never finer than 5 by CHECK.';

CREATE TABLE pawtrace.setting (
    key         text PRIMARY KEY,
    value_json  jsonb NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL
);
INSERT INTO pawtrace.setting (key, value_json) VALUES
    ('fusion.weights',        '{"visual": 0.55, "attr": 0.15, "spatial": 0.20, "temporal": 0.10}'),
    ('fusion.quality_penalty','{"threshold": 0.5, "penalty": 0.05}'),
    ('fusion.cosine_calibration','{"low": 0.35, "high": 0.95}'),
    ('fusion.spatial_scale_m','3000'),
    ('duplicate.rule',        '{"cosine_min": 0.90, "distance_m": 500, "hours": 48}'),
    ('signed_url.ttl_s',      '{"thumb": 900, "card": 900, "full": 300, "export": 86400}'),
    ('deletion.sla_hours',    '72');

CREATE TABLE pawtrace.config_version (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version    text NOT NULL UNIQUE,
    loaded_at  timestamptz NOT NULL DEFAULT now(),
    loaded_by  uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
    doc        jsonb NOT NULL                              -- validated copy of deploy/pawtrace.yaml
);

-- =====================================================================
-- 6. MODELS (versioned — AI-06)
-- =====================================================================
CREATE TABLE pawtrace.model_version (
    id                       smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind                     pawtrace.model_kind NOT NULL,
    name                     text NOT NULL,
    version                  text NOT NULL,
    dims                     integer,                                  -- embedding / text only
    checksum                 text NOT NULL,
    search_active            boolean NOT NULL DEFAULT false,           -- one per kind (ux below)
    calibration_provisional  boolean NOT NULL DEFAULT true,            -- until 200 decisions (AI-04)
    benchmark_recall1        numeric(4,3),
    benchmark_recall10       numeric(4,3),
    registered_at            timestamptz NOT NULL DEFAULT now(),
    activated_at             timestamptz,
    retired_at               timestamptz,
    UNIQUE (kind, name, version),
    CONSTRAINT vector_kind_has_dims CHECK (kind NOT IN ('embedding', 'text') OR dims IS NOT NULL),
    CONSTRAINT embedding_dims_768   CHECK (kind <> 'embedding' OR dims = 768),
    CONSTRAINT text_dims_1024       CHECK (kind <> 'text' OR dims = 1024),
    CONSTRAINT active_has_benchmark CHECK (NOT search_active OR kind NOT IN ('embedding') OR benchmark_recall10 IS NOT NULL)
);
CREATE UNIQUE INDEX ux_model_version_active ON pawtrace.model_version (kind) WHERE search_active;
COMMENT ON TABLE pawtrace.model_version IS 'Every model output carries a version. Exactly one embedding version is search_active (AC-08, ADR-T02); activation requires a benchmark (AI-03).';

CREATE TABLE pawtrace.benchmark_run (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    model_version_id  smallint NOT NULL REFERENCES pawtrace.model_version(id),
    dataset           text NOT NULL,
    n_queries         integer NOT NULL CHECK (n_queries > 0),
    recall1           numeric(4,3) NOT NULL,
    recall10          numeric(4,3) NOT NULL,
    filtered          boolean NOT NULL DEFAULT true,       -- under geo/time filter conditions (AI-03)
    run_at            timestamptz NOT NULL DEFAULT now(),
    notes             text
);
CREATE TABLE pawtrace.benchmark_slice (
    run_id       integer NOT NULL REFERENCES pawtrace.benchmark_run(id) ON DELETE CASCADE,
    slice_kind   text NOT NULL CHECK (slice_kind IN ('color', 'size')),
    slice_value  text NOT NULL,
    n            integer NOT NULL,
    recall10     numeric(4,3) NOT NULL,
    gap_pct      numeric(5,2) NOT NULL,                    -- (overall − slice) / overall × 100; > 15 triggers rebalancing (AI-08)
    PRIMARY KEY (run_id, slice_kind, slice_value)
);

CREATE TABLE pawtrace.reembed_job (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_version_id   smallint NOT NULL REFERENCES pawtrace.model_version(id),
    to_version_id     smallint NOT NULL REFERENCES pawtrace.model_version(id),
    total             integer NOT NULL,
    done              integer NOT NULL DEFAULT 0,
    state             text NOT NULL DEFAULT 'running' CHECK (state IN ('running', 'paused', 'completed', 'failed')),
    started_at        timestamptz NOT NULL DEFAULT now(),
    finished_at       timestamptz,
    CONSTRAINT reembed_progress CHECK (done BETWEEN 0 AND total),
    CONSTRAINT reembed_distinct CHECK (from_version_id <> to_version_id)
);

-- =====================================================================
-- 7. REPORTS AND PHOTOS
-- =====================================================================
CREATE TABLE pawtrace.contact_channel (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind           text NOT NULL CHECK (kind IN ('relay_thread', 'email_relay')),
    relay_address  text,                                   -- rewritten address, never the user's own
    user_id        uuid REFERENCES pawtrace.app_user(id) ON DELETE CASCADE,
    device_id      uuid REFERENCES pawtrace.device(id) ON DELETE CASCADE,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT channel_has_owner CHECK (user_id IS NOT NULL OR device_id IS NOT NULL)
);

CREATE TABLE pawtrace.report (
    id                       uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    kind                     pawtrace.report_kind NOT NULL,
    status                   pawtrace.report_status NOT NULL DEFAULT 'active',
    title                    text,
    description              text,
    event_at                 timestamptz NOT NULL,                     -- SRS lost_at: time lost (lost) or time seen (found/sighting)
    event_at_source          text NOT NULL DEFAULT 'user' CHECK (event_at_source IN ('user', 'exif', 'now')),   -- FR-04
    is_reloss                boolean NOT NULL DEFAULT false,           -- FR-16
    location                 geography(Point, 4326) NOT NULL,          -- EXACT. Never readable by public_ro (DD-T01)
    location_precision_m     integer NOT NULL DEFAULT 25 CHECK (location_precision_m >= 5),   -- GPS accuracy or pin precision
    location_source          text NOT NULL CHECK (location_source IN ('gps', 'pin', 'address', 'exif_coarse')),  -- FR-03
    consent_coarse_location  boolean NOT NULL DEFAULT false,           -- C-04: EXIF location only with consent, and only coarse
    radius_hint_m            integer CHECK (radius_hint_m BETWEEN 100 AND 50000),
    region_id                smallint NOT NULL REFERENCES pawtrace.region(id),
    contact_channel_id       uuid REFERENCES pawtrace.contact_channel(id),
    user_id                  uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
    device_id                uuid REFERENCES pawtrace.device(id) ON DELETE SET NULL,
    search_radius_m          integer,                                  -- owner-adjustable (FR-14)
    search_days              smallint,
    expires_at               timestamptz NOT NULL,
    closed_at                timestamptz,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT report_has_poster    CHECK (user_id IS NOT NULL OR device_id IS NOT NULL),      -- anonymous needs a device (C-02)
    CONSTRAINT lost_needs_account   CHECK (kind <> 'lost' OR user_id IS NOT NULL),             -- FR-01 vs FR-02
    CONSTRAINT lost_needs_contact   CHECK (kind <> 'lost' OR contact_channel_id IS NOT NULL),  -- FR-07
    CONSTRAINT exif_location_coarse CHECK (location_source <> 'exif_coarse' OR (consent_coarse_location AND location_precision_m >= 1000)),
    CONSTRAINT search_radius_range  CHECK (search_radius_m IS NULL OR search_radius_m BETWEEN 500 AND 50000),
    CONSTRAINT search_days_range    CHECK (search_days IS NULL OR search_days BETWEEN 1 AND 30)
);
COMMENT ON COLUMN pawtrace.report.location IS 'Exact coordinates. Readable only by app_rw/worker_rw; public_ro has no column grant (C-01, NFR-05). Public form: fuzz_cell().';

CREATE TABLE pawtrace.photo (
    id                 uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    report_id          uuid NOT NULL REFERENCES pawtrace.report(id) ON DELETE CASCADE,
    sha256             bytea NOT NULL CHECK (octet_length(sha256) = 32),   -- of the STRIPPED bytes
    uri_full           text NOT NULL,                                  -- private bucket keys; served by signed URL only (NFR-07)
    uri_card           text NOT NULL,
    uri_thumb          text NOT NULL,
    width              integer NOT NULL CHECK (width > 0),
    height             integer NOT NULL CHECK (height > 0),
    exif_stripped      boolean NOT NULL,                               -- asserted by the upload gate (C-04)
    capture_time_exif  timestamptz,                                    -- extracted BEFORE stripping (FR-04); never GPS
    moderation_status  pawtrace.moderation_status NOT NULL DEFAULT 'pending',
    moderation_reason  text,
    processing_state   pawtrace.processing_state NOT NULL DEFAULT 'queued',
    processing_error   text,                                           -- NO_DOG | CROP_TOO_SMALL | LOW_QUALITY | NSFW | ...
    position           smallint NOT NULL DEFAULT 1 CHECK (position BETWEEN 1 AND 10),   -- FR-01: 1–10 photos
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (report_id, sha256),
    UNIQUE (report_id, position),
    CONSTRAINT stripped_before_store CHECK (exif_stripped)             -- the row cannot exist otherwise (AC-05)
);
COMMENT ON CONSTRAINT stripped_before_store ON pawtrace.photo IS 'A photo row with EXIF present is impossible; the upload gate strips in memory and asserts true (C-04).';

CREATE TABLE pawtrace.dog_instance (
    id                    uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    photo_id              uuid NOT NULL REFERENCES pawtrace.photo(id) ON DELETE CASCADE,
    detector_version_id   smallint NOT NULL REFERENCES pawtrace.model_version(id),
    bbox_json             jsonb NOT NULL,                              -- {x,y,w,h} in full-derivative pixels
    crop_uri              text NOT NULL,
    quality_score         numeric(4,3) NOT NULL CHECK (quality_score BETWEEN 0 AND 1),
    short_edge_px         integer NOT NULL CHECK (short_edge_px >= 128),   -- AI-01
    det_confidence        numeric(4,3) NOT NULL,
    created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pawtrace.embedding (
    instance_id       uuid NOT NULL REFERENCES pawtrace.dog_instance(id) ON DELETE CASCADE,
    model_version_id  smallint NOT NULL REFERENCES pawtrace.model_version(id),
    vec               vector(768) NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (instance_id, model_version_id)
);
COMMENT ON TABLE pawtrace.embedding IS 'One row per (crop, embedding version). L2-normalised (AI-02). Partial HNSW per version is created by trg_model_version_indexes (ADR-T02).';

CREATE TABLE pawtrace.report_embedding (
    report_id         uuid NOT NULL REFERENCES pawtrace.report(id) ON DELETE CASCADE,
    model_version_id  smallint NOT NULL REFERENCES pawtrace.model_version(id),
    vec               vector(768) NOT NULL,                            -- normalised mean of the crop vectors (FR-12)
    medoid_instance   uuid REFERENCES pawtrace.dog_instance(id) ON DELETE SET NULL,
    n_instances       integer NOT NULL CHECK (n_instances >= 1),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (report_id, model_version_id)
);

CREATE TABLE pawtrace.attributes (
    instance_id       uuid PRIMARY KEY REFERENCES pawtrace.dog_instance(id) ON DELETE CASCADE,
    model_version_id  smallint NOT NULL REFERENCES pawtrace.model_version(id),
    size_class        pawtrace.size_class,
    color_primary     pawtrace.coat_color,
    color_secondary   pawtrace.coat_color,
    coat_len          pawtrace.coat_len,
    breed_group       pawtrace.breed_group,
    has_markings      boolean,
    confidence_json   jsonb NOT NULL                                   -- per-field confidence (FR-11)
);

CREATE TABLE pawtrace.report_attr (                                    -- aggregate per report, used by the pre-filter
    report_id         uuid PRIMARY KEY REFERENCES pawtrace.report(id) ON DELETE CASCADE,
    size_class        pawtrace.size_class,
    color_primary     pawtrace.coat_color,
    color_secondary   pawtrace.coat_color,
    coat_len          pawtrace.coat_len,
    breed_group       pawtrace.breed_group,
    has_markings      boolean,
    user_declared     boolean NOT NULL DEFAULT false,                  -- owner-entered attributes override the model
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pawtrace.text_embedding (                                 -- AI-09 / FR-21
    report_id         uuid NOT NULL REFERENCES pawtrace.report(id) ON DELETE CASCADE,
    model_version_id  smallint NOT NULL REFERENCES pawtrace.model_version(id),
    vec               vector(1024) NOT NULL,
    source_text       text NOT NULL,                                   -- attributes + description, TH/EN
    PRIMARY KEY (report_id, model_version_id)
);

-- =====================================================================
-- 8. MATCHING, DECISIONS, REUNIONS
-- =====================================================================
CREATE TABLE pawtrace.match (
    id                    uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    lost_report_id        uuid NOT NULL REFERENCES pawtrace.report(id) ON DELETE CASCADE,
    found_report_id       uuid NOT NULL REFERENCES pawtrace.report(id) ON DELETE CASCADE,
    model_version_id      smallint NOT NULL REFERENCES pawtrace.model_version(id),
    score                 numeric(5,4) NOT NULL CHECK (score BETWEEN 0 AND 1),
    calibrated_precision  numeric(4,3) NOT NULL CHECK (calibrated_precision BETWEEN 0 AND 1),   -- what the user sees (AI-04)
    components_json       jsonb NOT NULL,                              -- {cosine, sim_visual, attr_compat, spatial, temporal, penalty, distance_m, hours_after}
    rank                  smallint NOT NULL CHECK (rank >= 1),
    status                pawtrace.match_status NOT NULL DEFAULT 'candidate',
    notified_at           timestamptz,
    decided_at            timestamptz,
    decided_by            uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (lost_report_id, found_report_id, model_version_id),
    CONSTRAINT match_distinct_reports CHECK (lost_report_id <> found_report_id),
    CONSTRAINT components_complete CHECK (components_json ?& ARRAY['cosine', 'sim_visual', 'attr_compat', 'spatial', 'temporal', 'distance_m', 'hours_after'])   -- FR-18
);
COMMENT ON TABLE pawtrace.match IS 'A CANDIDATE pair with a calibrated score and its components. Never inserted as confirmed (C-03, DD-T02).';

CREATE TABLE pawtrace.match_decision (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    match_id         uuid NOT NULL REFERENCES pawtrace.match(id) ON DELETE CASCADE,
    decision         pawtrace.decision_kind NOT NULL,
    decided_by       uuid NOT NULL REFERENCES pawtrace.app_user(id) ON DELETE CASCADE,
    consent_version  text NOT NULL,                                    -- AI-07: terms under which this row may train a model
    note             text,
    created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE pawtrace.match_decision IS 'Append-only training signal (FR-19, AI-07, ADR-T09). trg_decision_immutable refuses UPDATE/DELETE from the application.';

CREATE TABLE pawtrace.reunion (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    lost_report_id   uuid NOT NULL REFERENCES pawtrace.report(id) ON DELETE CASCADE,
    found_report_id  uuid REFERENCES pawtrace.report(id) ON DELETE SET NULL,   -- NULL: reunited outside the app
    match_id         uuid REFERENCES pawtrace.match(id) ON DELETE SET NULL,
    confirmed_at     timestamptz NOT NULL DEFAULT now(),
    confirmed_by     uuid NOT NULL REFERENCES pawtrace.app_user(id) ON DELETE CASCADE,
    story            text,
    story_public     boolean NOT NULL DEFAULT false,
    UNIQUE (lost_report_id)
);

CREATE TABLE pawtrace.thread (                                         -- FR-07 relay (ADR-T08)
    id                          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    match_id                    uuid NOT NULL UNIQUE REFERENCES pawtrace.match(id) ON DELETE CASCADE,
    opened_at                   timestamptz NOT NULL DEFAULT now(),
    closed_at                   timestamptz,
    lost_side_consent_exact     boolean NOT NULL DEFAULT false,        -- NFR-05: exact location shared only when BOTH true
    found_side_consent_exact    boolean NOT NULL DEFAULT false
);
CREATE TABLE pawtrace.message (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    thread_id    uuid NOT NULL REFERENCES pawtrace.thread(id) ON DELETE CASCADE,
    sender       pawtrace.sender_kind NOT NULL,
    user_id      uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
    device_id    uuid REFERENCES pawtrace.device(id) ON DELETE SET NULL,
    body         text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
    hidden       boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pawtrace.duplicate_cluster (                              -- FR-29
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    primary_report_id   uuid NOT NULL REFERENCES pawtrace.report(id) ON DELETE CASCADE,
    member_report_ids   uuid[] NOT NULL CHECK (cardinality(member_report_ids) >= 1),
    cosine              numeric(4,3) NOT NULL,
    distance_m          integer NOT NULL,
    hours_apart         numeric(6,1) NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    merged_at           timestamptz,
    merged_by           uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
    dismissed_at        timestamptz
);

-- =====================================================================
-- 9. CALIBRATION (AI-04)
-- =====================================================================
CREATE TABLE pawtrace.calibration_bin (
    model_version_id  smallint NOT NULL REFERENCES pawtrace.model_version(id) ON DELETE CASCADE,
    bin_low           numeric(4,3) NOT NULL CHECK (bin_low >= 0),
    bin_high          numeric(4,3) NOT NULL CHECK (bin_high <= 1),
    n                 integer NOT NULL CHECK (n >= 0),
    confirmed         integer NOT NULL CHECK (confirmed >= 0),
    precision         numeric(4,3) NOT NULL CHECK (precision BETWEEN 0 AND 1),
    computed_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (model_version_id, bin_low),
    CONSTRAINT bin_order CHECK (bin_high > bin_low),
    CONSTRAINT bin_counts CHECK (confirmed <= n)
);
COMMENT ON TABLE pawtrace.calibration_bin IS 'Fusion score bin → empirical confirm rate from match_decision (AI-04). Displayed value = precision, never the cosine (ADR-T04).';

-- =====================================================================
-- 10. NOTIFICATIONS AND SUBSCRIPTIONS
-- =====================================================================
CREATE TABLE pawtrace.subscription (                                   -- FR-23
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id       uuid NOT NULL REFERENCES pawtrace.app_user(id) ON DELETE CASCADE,
    area          geography(Polygon, 4326) NOT NULL,
    filters_json  jsonb NOT NULL DEFAULT '{}',
    active        boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT area_size CHECK (ST_Area(area) BETWEEN 1.0e6 AND 2.0e10)   -- 1 km² … 20,000 km² (SEC-T05: no probe-sized polygons)
);
CREATE TABLE pawtrace.push_subscription (                              -- IF-40
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id      uuid REFERENCES pawtrace.app_user(id) ON DELETE CASCADE,
    device_id    uuid REFERENCES pawtrace.device(id) ON DELETE CASCADE,
    provider     text NOT NULL CHECK (provider IN ('webpush', 'fcm')),
    endpoint     text NOT NULL UNIQUE,
    keys_json    jsonb,                                                -- p256dh/auth for Web Push
    created_at   timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz,
    CONSTRAINT push_has_owner CHECK (user_id IS NOT NULL OR device_id IS NOT NULL)
);
CREATE TABLE pawtrace.notification (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     uuid REFERENCES pawtrace.app_user(id) ON DELETE CASCADE,
    device_id   uuid REFERENCES pawtrace.device(id) ON DELETE CASCADE,
    kind        pawtrace.notification_kind NOT NULL,
    channel     pawtrace.channel_kind NOT NULL,
    entity      pawtrace.entity_kind,
    entity_id   uuid,
    payload     jsonb NOT NULL DEFAULT '{}',                           -- fuzzed cell only, never coordinates
    created_at  timestamptz NOT NULL DEFAULT now(),
    sent_at     timestamptz,
    error       text,
    CONSTRAINT notification_has_target CHECK (user_id IS NOT NULL OR device_id IS NOT NULL)
);

-- =====================================================================
-- 11. MODERATION, ABUSE, RATE LIMITS
-- =====================================================================
CREATE TABLE pawtrace.moderation_event (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity        pawtrace.entity_kind NOT NULL,
    entity_id     uuid NOT NULL,
    action        text NOT NULL CHECK (action IN ('approve', 'hide', 'remove', 'restore', 'merge', 'ban_device', 'unban_device', 'nsfw_auto_hide')),
    moderator_id  uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,   -- NULL = automated (nsfw_auto_hide)
    ts            timestamptz NOT NULL DEFAULT now(),
    reason        text NOT NULL
);
CREATE TABLE pawtrace.abuse_report (                                   -- FR-27
    id                  uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    entity              pawtrace.entity_kind NOT NULL,
    entity_id           uuid NOT NULL,
    reporter_user_id    uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
    reporter_device_id  uuid REFERENCES pawtrace.device(id) ON DELETE SET NULL,
    reason              text NOT NULL CHECK (reason IN ('fake', 'abuse', 'spam', 'not_a_dog', 'privacy', 'other')),
    detail              text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    resolved_at         timestamptz,
    resolution          text CHECK (resolution IN ('hidden', 'removed', 'dismissed', 'merged')),
    resolved_by         uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL
);
CREATE TABLE pawtrace.rate_limit_bucket (                              -- FR-28 (mirror of the Redis counters for forensics)
    key           text NOT NULL,                                       -- e.g. device:<id>:post, ip:<inet>:post
    window_start  timestamptz NOT NULL,
    count         integer NOT NULL DEFAULT 0,
    PRIMARY KEY (key, window_start)
);

-- =====================================================================
-- 12. PRIVACY RIGHTS (NFR-06)
-- =====================================================================
CREATE TABLE pawtrace.deletion_request (
    id             uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id        uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
    device_id      uuid REFERENCES pawtrace.device(id) ON DELETE SET NULL,
    requested_at   timestamptz NOT NULL DEFAULT now(),
    due_at         timestamptz NOT NULL DEFAULT now() + interval '72 hours',
    state          text NOT NULL DEFAULT 'requested' CHECK (state IN ('requested', 'db_done', 'completed', 'failed')),
    db_done_at     timestamptz,
    completed_at   timestamptz,
    summary_json   jsonb NOT NULL DEFAULT '{}',                        -- counts of what was removed
    CONSTRAINT deletion_has_subject CHECK (user_id IS NOT NULL OR device_id IS NOT NULL)
);
CREATE TABLE pawtrace.export_request (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    user_id       uuid NOT NULL REFERENCES pawtrace.app_user(id) ON DELETE CASCADE,
    requested_at  timestamptz NOT NULL DEFAULT now(),
    state         text NOT NULL DEFAULT 'requested' CHECK (state IN ('requested', 'ready', 'expired', 'failed')),
    uri           text,
    expires_at    timestamptz
);

-- =====================================================================
-- 13. AUDIT  [platform — 00/db/schema.sql lines 1294–1321, core.app_user -> pawtrace.app_user]
-- =====================================================================
CREATE TABLE audit.log (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts             timestamptz NOT NULL DEFAULT now(),
    user_id        uuid        REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
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
    user_id    uuid REFERENCES pawtrace.app_user(id) ON DELETE SET NULL,
    event      text NOT NULL CHECK (event IN ('login_ok','login_fail','logout','token_refresh',
                                              'password_change','mfa_fail','locked','key_rotated')),
    ip         inet,
    detail     text
);

-- =====================================================================
-- 14. FUNCTIONS — privacy, scoring, search
-- =====================================================================

-- C-01 / ADR-T05: the only public form of a location. Precision by audience; owner/counterpart get NULL (= exact allowed elsewhere).
CREATE OR REPLACE FUNCTION pawtrace.fuzz_cell(p_loc geography, p_audience pawtrace.audience, p_region smallint DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE p_audience
             WHEN 'public'     THEN ST_GeoHash(p_loc::geometry, COALESCE((SELECT fuzz_public_precision     FROM pawtrace.region WHERE id = p_region), 5))
             WHEN 'subscriber' THEN ST_GeoHash(p_loc::geometry, COALESCE((SELECT fuzz_subscriber_precision FROM pawtrace.region WHERE id = p_region), 6))
             ELSE NULL
           END;
$$;
COMMENT ON FUNCTION pawtrace.fuzz_cell IS 'Geohash cell for an audience. public ≤ 5 chars (≈ 4.9 km), subscriber ≤ 6 (≈ 1.2 km). Never returns coordinates.';

CREATE OR REPLACE FUNCTION pawtrace.cell_center(p_cell text)
RETURNS geography LANGUAGE sql IMMUTABLE AS $$
    SELECT ST_SetSRID(ST_PointFromGeoHash(p_cell), 4326)::geography;
$$;

-- Appendix A components
CREATE OR REPLACE FUNCTION pawtrace.spatial_score(p_distance_m double precision)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT round(exp(-p_distance_m / 3000.0)::numeric, 4);           -- exp(−d / 3 km)
$$;

-- FR-16: a sighting before the loss is implausible unless re-loss; 0–24 h after = 1.0; linear decay to 0.3 at the window end.
CREATE OR REPLACE FUNCTION pawtrace.temporal_score(p_lost_at timestamptz, p_seen_at timestamptz, p_is_reloss boolean, p_window_days integer)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE h double precision := extract(epoch FROM (p_seen_at - p_lost_at)) / 3600.0;
        w double precision := p_window_days * 24.0;
BEGIN
    IF h < -1 THEN RETURN CASE WHEN p_is_reloss THEN 0.6 ELSE 0.1 END; END IF;   -- 1 h grace for clock error
    IF h <= 24 THEN RETURN 1.0; END IF;
    IF h >= w  THEN RETURN 0.3; END IF;
    RETURN round((1.0 - 0.7 * (h - 24) / (w - 24))::numeric, 4);
END $$;

-- Attribute compatibility 0–1 (unknowns are neutral). Hard incompatibility (< 0.4) is used as a pre-filter.
CREATE OR REPLACE FUNCTION pawtrace.attr_compat(a pawtrace.report_attr, b pawtrace.report_attr)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s numeric := 0; n integer := 0; dsz integer;
BEGIN
    IF a.size_class IS NOT NULL AND b.size_class IS NOT NULL THEN
        dsz := abs(array_position(enum_range(NULL::pawtrace.size_class), a.size_class) - array_position(enum_range(NULL::pawtrace.size_class), b.size_class));
        s := s + CASE dsz WHEN 0 THEN 1 WHEN 1 THEN 0.6 ELSE 0 END; n := n + 1;
    END IF;
    IF a.color_primary IS NOT NULL AND b.color_primary IS NOT NULL THEN
        s := s + CASE WHEN a.color_primary = b.color_primary THEN 1
                      WHEN a.color_primary = b.color_secondary OR a.color_secondary = b.color_primary THEN 0.6 ELSE 0 END; n := n + 1;
    END IF;
    IF a.coat_len IS NOT NULL AND b.coat_len IS NOT NULL THEN
        s := s + CASE WHEN a.coat_len = b.coat_len THEN 1 ELSE 0.3 END; n := n + 1;
    END IF;
    IF a.breed_group IS NOT NULL AND b.breed_group IS NOT NULL AND a.breed_group <> 'unknown' AND b.breed_group <> 'unknown' THEN
        s := s + CASE WHEN a.breed_group = b.breed_group OR a.breed_group = 'mixed' OR b.breed_group = 'mixed' THEN 1 ELSE 0.2 END; n := n + 1;
    END IF;
    RETURN CASE WHEN n = 0 THEN 0.7 ELSE round(s / n, 4) END;
END $$;

-- cosine → sim_visual (the "calibrated cosine" of Appendix A): linear rescale between the cosine of unrelated dogs and of identical crops
CREATE OR REPLACE FUNCTION pawtrace.sim_visual(p_cosine numeric)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT round(GREATEST(0, LEAST(1, (p_cosine - (c->>'low')::numeric) / ((c->>'high')::numeric - (c->>'low')::numeric))), 4)
      FROM (SELECT value_json c FROM pawtrace.setting WHERE key = 'fusion.cosine_calibration') s;
$$;

CREATE OR REPLACE FUNCTION pawtrace.fusion_score(p_sim_visual numeric, p_attr numeric, p_spatial numeric, p_temporal numeric, p_min_quality numeric)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE w jsonb := (SELECT value_json FROM pawtrace.setting WHERE key = 'fusion.weights');
        q jsonb := (SELECT value_json FROM pawtrace.setting WHERE key = 'fusion.quality_penalty');
        s numeric;
BEGIN
    s := (w->>'visual')::numeric * p_sim_visual + (w->>'attr')::numeric * p_attr
       + (w->>'spatial')::numeric * p_spatial   + (w->>'temporal')::numeric * p_temporal
       - CASE WHEN p_min_quality < (q->>'threshold')::numeric THEN (q->>'penalty')::numeric ELSE 0 END;
    RETURN round(GREATEST(0, LEAST(1, s)), 4);
END $$;
COMMENT ON FUNCTION pawtrace.fusion_score IS 'SRS Appendix A: 0.55·sim + 0.15·attr + 0.20·spatial + 0.10·temporal − penalty. Weights from pawtrace.setting (must sum to 1; TC-006).';

-- AI-04: score → empirical precision for a version; falls back to the active version's curve while provisional.
CREATE OR REPLACE FUNCTION pawtrace.calibrated_precision(p_score numeric, p_version smallint)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT precision FROM pawtrace.calibration_bin WHERE model_version_id = p_version AND p_score >= bin_low AND p_score < bin_high),
        (SELECT precision FROM pawtrace.calibration_bin cb JOIN pawtrace.model_version mv ON mv.id = cb.model_version_id
          WHERE mv.kind = 'embedding' AND mv.search_active AND p_score >= cb.bin_low AND p_score < cb.bin_high),
        0.0);
$$;

CREATE OR REPLACE FUNCTION pawtrace.active_embedding_version()
RETURNS smallint LANGUAGE sql STABLE AS $$
    SELECT id FROM pawtrace.model_version WHERE kind = 'embedding' AND search_active;
$$;

-- ADR-T03: pre-filter (geo ∩ time ∩ attribute) then ANN within ONE version (AC-08). Returns raw components; the worker fuses and calibrates.
CREATE OR REPLACE FUNCTION pawtrace.search_candidates(p_lost uuid, p_radius_m integer DEFAULT NULL, p_days integer DEFAULT NULL, p_limit integer DEFAULT 200)
RETURNS TABLE (found_report_id uuid, cosine numeric, distance_m double precision, hours_after numeric, attr_compat numeric, temporal numeric, spatial numeric, min_quality numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v smallint := pawtrace.active_embedding_version();
        l pawtrace.report; la pawtrace.report_attr; lv vector(768);
        r_m integer; d integer;
BEGIN
    SELECT * INTO l FROM pawtrace.report WHERE id = p_lost AND kind = 'lost';
    IF NOT FOUND THEN RAISE EXCEPTION 'search_candidates: % is not a lost report', p_lost; END IF;
    SELECT * INTO la FROM pawtrace.report_attr WHERE report_id = p_lost;
    SELECT vec INTO lv FROM pawtrace.report_embedding WHERE report_id = p_lost AND model_version_id = v;
    IF lv IS NULL THEN RETURN; END IF;                                  -- photos still processing (P-2)
    SELECT LEAST(COALESCE(p_radius_m, l.search_radius_m, rg.default_radius_m), rg.max_radius_m),
           LEAST(COALESCE(p_days, l.search_days, rg.default_days), rg.max_days)
      INTO r_m, d FROM pawtrace.region rg WHERE rg.id = l.region_id;
    RETURN QUERY
    SELECT f.id,
           round((1 - (fe.vec <=> lv))::numeric, 4),
           ST_Distance(f.location, l.location),
           round((extract(epoch FROM (f.event_at - l.event_at)) / 3600.0)::numeric, 1),
           pawtrace.attr_compat(la, fa),
           pawtrace.temporal_score(l.event_at, f.event_at, l.is_reloss, d),
           pawtrace.spatial_score(ST_Distance(f.location, l.location)),
           LEAST(lq.q, fq.q)
      FROM pawtrace.report f
      JOIN pawtrace.report_embedding fe ON fe.report_id = f.id AND fe.model_version_id = v
      LEFT JOIN pawtrace.report_attr fa ON fa.report_id = f.id
      LEFT JOIN LATERAL (SELECT min(di.quality_score) q FROM pawtrace.photo p JOIN pawtrace.dog_instance di ON di.photo_id = p.id WHERE p.report_id = f.id) fq ON true
      LEFT JOIN LATERAL (SELECT min(di.quality_score) q FROM pawtrace.photo p JOIN pawtrace.dog_instance di ON di.photo_id = p.id WHERE p.report_id = l.id) lq ON true
     WHERE f.kind IN ('found', 'sighting') AND f.status = 'active'
       AND ST_DWithin(f.location, l.location, r_m)
       AND f.event_at BETWEEN l.event_at - interval '1 hour' AND l.event_at + make_interval(days => d)
       AND (la IS NULL OR fa IS NULL OR pawtrace.attr_compat(la, fa) >= 0.4)
     ORDER BY fe.vec <=> lv
     LIMIT p_limit;
END $$;
COMMENT ON FUNCTION pawtrace.search_candidates IS 'FR-14/FR-15 candidate retrieval. Reads ONE vector space (the active version). Radius/days clamped to the region maxima (≤ 50 km, ≤ 30 d).';

-- FR-25: budget check used by trg_notification_budget and the API
CREATE OR REPLACE FUNCTION pawtrace.can_notify(p_user uuid, p_device uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT (SELECT count(*) FROM pawtrace.notification n
             WHERE ((p_user IS NOT NULL AND n.user_id = p_user) OR (p_device IS NOT NULL AND n.device_id = p_device))
               AND n.channel IN ('push', 'email', 'sms') AND n.created_at >= date_trunc('day', now()))
           < COALESCE((SELECT min(rg.notify_daily_cap) FROM pawtrace.report r JOIN pawtrace.region rg ON rg.id = r.region_id
                        WHERE r.status = 'active' AND (r.user_id = p_user OR r.device_id = p_device)), 5);
$$;

-- =====================================================================
-- 15. TRIGGERS — the guards (DDS-07 DD-T02..T09)
-- =====================================================================

-- DD-T03: a photo cannot be approved unless stripped and processed
CREATE OR REPLACE FUNCTION pawtrace.trg_photo_gate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.moderation_status = 'approved' THEN
        IF NOT NEW.exif_stripped THEN RAISE EXCEPTION 'PHOTO_NOT_STRIPPED: photo % cannot be approved (C-04)', NEW.id; END IF;
        IF NEW.processing_state <> 'done' THEN RAISE EXCEPTION 'PHOTO_NOT_PROCESSED: photo % must be processed (NSFW screen) before approval (C-05)', NEW.id; END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_photo_gate BEFORE INSERT OR UPDATE OF moderation_status, processing_state ON pawtrace.photo
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_photo_gate();

-- DD-T02: a match is born a candidate; confirmed/rejected only when a decision row exists
CREATE OR REPLACE FUNCTION pawtrace.trg_match_status() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.status <> 'candidate' THEN
        RAISE EXCEPTION 'MATCH_NOT_CANDIDATE: a match is inserted as candidate only (C-03)';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.status IN ('confirmed', 'rejected') AND NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT EXISTS (SELECT 1 FROM pawtrace.match_decision d WHERE d.match_id = NEW.id
                        AND d.decision = CASE NEW.status WHEN 'confirmed' THEN 'confirm'::pawtrace.decision_kind ELSE 'reject' END) THEN
            RAISE EXCEPTION 'MATCH_NEEDS_DECISION: match % cannot become % without a match_decision (C-03, FR-19)', NEW.id, NEW.status;
        END IF;
        NEW.decided_at := COALESCE(NEW.decided_at, now());
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_match_status BEFORE INSERT OR UPDATE OF status ON pawtrace.match
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_match_status();

-- a decision applies itself to the match (and stamps the actor)
CREATE OR REPLACE FUNCTION pawtrace.trg_decision_apply() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE pawtrace.match SET status = CASE NEW.decision WHEN 'confirm' THEN 'confirmed'::pawtrace.match_status ELSE 'rejected' END,
                              decided_by = NEW.decided_by, decided_at = NEW.created_at
     WHERE id = NEW.match_id AND status = 'candidate';
    IF NEW.decision = 'confirm' THEN
        UPDATE pawtrace.report r SET status = 'matched' WHERE r.status = 'active'
           AND r.id IN (SELECT lost_report_id FROM pawtrace.match WHERE id = NEW.match_id);
        INSERT INTO pawtrace.thread (match_id) VALUES (NEW.match_id) ON CONFLICT DO NOTHING;   -- FR-07 relay opens
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_decision_apply AFTER INSERT ON pawtrace.match_decision
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_decision_apply();

-- DD-T04: decisions are append-only
CREATE OR REPLACE FUNCTION pawtrace.trg_decision_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- the only legitimate delete is the cascade of a deletion request (NFR-06), which sets this transaction-local flag
    IF TG_OP = 'DELETE' AND current_setting('pawtrace.deleting', true) = 'on' THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'DECISION_IMMUTABLE: match_decision is append-only (AI-07)';
END $$;
CREATE TRIGGER trg_decision_immutable BEFORE UPDATE OR DELETE ON pawtrace.match_decision
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_decision_immutable();

-- DD-T05: report lifecycle active → matched → reunited → expired/closed (FR-05)
CREATE OR REPLACE FUNCTION pawtrace.trg_report_status() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT ( (OLD.status = 'draft'   AND NEW.status IN ('active', 'closed'))
              OR (OLD.status = 'active'  AND NEW.status IN ('matched', 'reunited', 'expired', 'closed'))
              OR (OLD.status = 'matched' AND NEW.status IN ('active', 'reunited', 'closed'))
              OR (OLD.status = 'expired' AND NEW.status IN ('active', 'closed')) ) THEN
            RAISE EXCEPTION 'REPORT_TRANSITION: % -> % not allowed (FR-05)', OLD.status, NEW.status;
        END IF;
        IF NEW.status IN ('reunited', 'expired', 'closed') THEN NEW.closed_at := COALESCE(NEW.closed_at, now()); END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_report_status BEFORE UPDATE OF status ON pawtrace.report
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_report_status();

-- a reunion closes the report, confirms its match, supersedes the rest (FR-20)
CREATE OR REPLACE FUNCTION pawtrace.trg_reunion_close() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE pawtrace.report SET status = 'reunited' WHERE id = NEW.lost_report_id AND status IN ('active', 'matched');
    UPDATE pawtrace.match  SET status = 'superseded' WHERE lost_report_id = NEW.lost_report_id AND status = 'candidate';
    IF NEW.found_report_id IS NOT NULL THEN
        UPDATE pawtrace.report SET status = 'closed' WHERE id = NEW.found_report_id AND status IN ('active', 'matched');
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_reunion_close AFTER INSERT ON pawtrace.reunion
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_reunion_close();

-- DD-T06: vectors belong to a registered version of the right kind
CREATE OR REPLACE FUNCTION pawtrace.trg_embedding_version() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE k pawtrace.model_kind; d integer;
BEGIN
    SELECT kind, dims INTO k, d FROM pawtrace.model_version WHERE id = NEW.model_version_id AND retired_at IS NULL;
    IF k IS NULL THEN RAISE EXCEPTION 'MODEL_VERSION_UNKNOWN: % is not a registered, unretired version', NEW.model_version_id; END IF;
    IF TG_TABLE_NAME IN ('embedding', 'report_embedding') AND k <> 'embedding' THEN RAISE EXCEPTION 'MODEL_KIND: version % is %, not embedding', NEW.model_version_id, k; END IF;
    IF TG_TABLE_NAME = 'text_embedding' AND k <> 'text' THEN RAISE EXCEPTION 'MODEL_KIND: version % is %, not text', NEW.model_version_id, k; END IF;
    IF vector_dims(NEW.vec) <> d THEN RAISE EXCEPTION 'MODEL_DIMS: vector has % dims, version % declares %', vector_dims(NEW.vec), NEW.model_version_id, d; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_embedding_version        BEFORE INSERT OR UPDATE ON pawtrace.embedding        FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_embedding_version();
CREATE TRIGGER trg_report_embedding_version BEFORE INSERT OR UPDATE ON pawtrace.report_embedding FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_embedding_version();
CREATE TRIGGER trg_text_embedding_version   BEFORE INSERT OR UPDATE ON pawtrace.text_embedding   FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_embedding_version();

-- ADR-T02: every embedding version gets its own partial HNSW indexes (empty at creation; production rebuilds CONCURRENTLY, OPS-07 §7)
CREATE OR REPLACE FUNCTION pawtrace.trg_model_version_indexes() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.kind = 'embedding' THEN
        EXECUTE format('CREATE INDEX IF NOT EXISTS hnsw_embedding_v%s ON pawtrace.embedding USING hnsw (vec vector_cosine_ops) WITH (m = 16, ef_construction = 128) WHERE model_version_id = %s', NEW.id, NEW.id);
        EXECUTE format('CREATE INDEX IF NOT EXISTS hnsw_report_embedding_v%s ON pawtrace.report_embedding USING hnsw (vec vector_cosine_ops) WITH (m = 16, ef_construction = 128) WHERE model_version_id = %s', NEW.id, NEW.id);
    ELSIF NEW.kind = 'text' THEN
        EXECUTE format('CREATE INDEX IF NOT EXISTS hnsw_text_embedding_v%s ON pawtrace.text_embedding USING hnsw (vec vector_cosine_ops) WHERE model_version_id = %s', NEW.id, NEW.id);
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_model_version_indexes AFTER INSERT ON pawtrace.model_version
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_model_version_indexes();

-- activation: one transaction flips the flag; an embedding version needs a benchmark and a finished re-embed (unless first)
CREATE OR REPLACE FUNCTION pawtrace.trg_model_activate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.search_active AND NOT OLD.search_active THEN
        IF NEW.kind = 'embedding' AND EXISTS (SELECT 1 FROM pawtrace.model_version WHERE kind = 'embedding' AND search_active AND id <> NEW.id)
           AND NOT EXISTS (SELECT 1 FROM pawtrace.reembed_job j WHERE j.to_version_id = NEW.id AND j.state = 'completed') THEN
            RAISE EXCEPTION 'REEMBED_INCOMPLETE: version % cannot become search_active before its re-embed job completes (AC-08)', NEW.id;
        END IF;
        UPDATE pawtrace.model_version SET search_active = false, retired_at = NULL WHERE kind = NEW.kind AND search_active AND id <> NEW.id;
        NEW.activated_at := now();
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_model_activate BEFORE UPDATE OF search_active ON pawtrace.model_version
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_model_activate();

-- DD-T07: the notification budget (FR-25) — over budget, alert kinds become a digest entry instead of a push/email
CREATE OR REPLACE FUNCTION pawtrace.trg_notification_budget() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.channel IN ('push', 'email', 'sms') AND NEW.kind IN ('candidate', 'new_report_in_area')
       AND NOT pawtrace.can_notify(NEW.user_id, NEW.device_id) THEN
        NEW.channel := 'digest'; NEW.kind := 'digest';
        NEW.payload := NEW.payload || jsonb_build_object('budget_exceeded', true);
    END IF;
    IF NEW.payload ? 'lat' OR NEW.payload ? 'lng' OR NEW.payload ? 'location' THEN
        RAISE EXCEPTION 'NOTIFICATION_LEAK: payload must carry a cell, not coordinates (C-01)';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_notification_budget BEFORE INSERT ON pawtrace.notification
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_notification_budget();

-- DD-T08: deletion request cascades immediately in the database; objects are removed by the scheduler (AC-06)
CREATE OR REPLACE FUNCTION pawtrace.trg_deletion_cascade() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n_reports integer; n_photos integer; n_emb integer;
BEGIN
    SELECT count(*) INTO n_photos FROM pawtrace.photo p JOIN pawtrace.report r ON r.id = p.report_id
     WHERE (NEW.user_id IS NOT NULL AND r.user_id = NEW.user_id) OR (NEW.device_id IS NOT NULL AND r.device_id = NEW.device_id);
    SELECT count(*) INTO n_emb FROM pawtrace.embedding e JOIN pawtrace.dog_instance di ON di.id = e.instance_id
      JOIN pawtrace.photo p ON p.id = di.photo_id JOIN pawtrace.report r ON r.id = p.report_id
     WHERE (NEW.user_id IS NOT NULL AND r.user_id = NEW.user_id) OR (NEW.device_id IS NOT NULL AND r.device_id = NEW.device_id);
    -- decisions on the subject's own reports are removed with the reports (cascade); decisions the subject made on
    -- other people's reports keep their training value (AI-07) and lose their identity with the anonymisation below
    PERFORM set_config('pawtrace.deleting', 'on', true);
    -- reports cascade to photos, instances, embeddings, attributes, text embeddings, matches, threads, messages
    WITH del AS (DELETE FROM pawtrace.report r
                  WHERE (NEW.user_id IS NOT NULL AND r.user_id = NEW.user_id) OR (NEW.device_id IS NOT NULL AND r.device_id = NEW.device_id)
                  RETURNING 1)
    SELECT count(*) INTO n_reports FROM del;
    DELETE FROM pawtrace.subscription      WHERE user_id = NEW.user_id;
    DELETE FROM pawtrace.push_subscription WHERE (NEW.user_id IS NOT NULL AND user_id = NEW.user_id) OR (NEW.device_id IS NOT NULL AND device_id = NEW.device_id);
    DELETE FROM pawtrace.notification      WHERE (NEW.user_id IS NOT NULL AND user_id = NEW.user_id) OR (NEW.device_id IS NOT NULL AND device_id = NEW.device_id);
    IF NEW.user_id IS NOT NULL THEN
        UPDATE pawtrace.app_user SET email = 'deleted+' || id::text || '@invalid', display_name = 'deleted user', deleted_at = now() WHERE id = NEW.user_id;
    END IF;
    IF NEW.device_id IS NOT NULL THEN
        UPDATE pawtrace.device SET token_hash = public.digest('deleted:' || id::text, 'sha256'), banned_at = COALESCE(banned_at, now()), ban_reason = COALESCE(ban_reason, 'deleted') WHERE id = NEW.device_id;
    END IF;
    NEW.state := 'db_done'; NEW.db_done_at := now();
    NEW.summary_json := jsonb_build_object('reports', n_reports, 'photos', n_photos, 'embeddings', n_emb);
    INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
    VALUES (NULL, 'deletion_request', 'delete', 'user', COALESCE(NEW.user_id, NEW.device_id)::text, NEW.summary_json);   -- tombstone, no identity
    RETURN NEW;
END $$;
CREATE TRIGGER trg_deletion_cascade BEFORE INSERT ON pawtrace.deletion_request
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_deletion_cascade();

-- DD-T09: anonymous reports need an unbanned device; owners cannot post lost reports anonymously (CHECK); banned devices cannot post
CREATE OR REPLACE FUNCTION pawtrace.trg_report_device() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.device_id IS NOT NULL AND EXISTS (SELECT 1 FROM pawtrace.device WHERE id = NEW.device_id AND banned_at IS NOT NULL) THEN
        RAISE EXCEPTION 'DEVICE_BANNED: device % may not post (FR-28)', NEW.device_id;
    END IF;
    IF NEW.expires_at IS NULL THEN NEW.expires_at := NEW.created_at + interval '30 days'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_report_device BEFORE INSERT ON pawtrace.report
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_report_device();

-- moderation actions audit themselves
CREATE OR REPLACE FUNCTION pawtrace.trg_moderation_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit.log (user_id, actor, action, entity, entity_id, after_json)
    VALUES (NEW.moderator_id, CASE WHEN NEW.moderator_id IS NULL THEN 'system' ELSE 'moderator' END, 'moderation.' || NEW.action, NEW.entity::text, NEW.entity_id::text, jsonb_build_object('reason', NEW.reason));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_moderation_audit AFTER INSERT ON pawtrace.moderation_event
    FOR EACH ROW EXECUTE FUNCTION pawtrace.trg_moderation_audit();

CREATE TRIGGER trg_app_user_updated  BEFORE UPDATE ON pawtrace.app_user FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_report_updated    BEFORE UPDATE ON pawtrace.report   FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_photo_updated     BEFORE UPDATE ON pawtrace.photo    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_match_updated     BEFORE UPDATE ON pawtrace.match    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =====================================================================
-- 16. INDEXES
-- =====================================================================
CREATE INDEX idx_report_location      ON pawtrace.report USING gist (location);                              -- SRS §5: GIST
CREATE INDEX idx_report_event_brin    ON pawtrace.report USING brin (event_at);                              -- SRS §5: BRIN on time
CREATE INDEX idx_report_created_brin  ON pawtrace.report USING brin (created_at);
CREATE INDEX idx_report_active        ON pawtrace.report (kind, region_id, event_at DESC) WHERE status = 'active';
CREATE INDEX idx_report_user          ON pawtrace.report (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX idx_report_device        ON pawtrace.report (device_id) WHERE device_id IS NOT NULL;
CREATE INDEX idx_report_expires       ON pawtrace.report (expires_at) WHERE status = 'active';
CREATE INDEX idx_report_desc_trgm     ON pawtrace.report USING gin (description gin_trgm_ops);
CREATE INDEX idx_photo_report         ON pawtrace.photo (report_id);
CREATE INDEX idx_photo_pending        ON pawtrace.photo (created_at) WHERE processing_state IN ('queued', 'processing');
CREATE INDEX idx_photo_moderation     ON pawtrace.photo (created_at) WHERE moderation_status = 'pending';
CREATE INDEX idx_instance_photo       ON pawtrace.dog_instance (photo_id);
CREATE INDEX idx_embedding_version    ON pawtrace.embedding (model_version_id);
CREATE INDEX idx_match_lost           ON pawtrace.match (lost_report_id, rank) WHERE status = 'candidate';
CREATE INDEX idx_match_found          ON pawtrace.match (found_report_id);
CREATE INDEX idx_match_created_brin   ON pawtrace.match USING brin (created_at);
CREATE INDEX idx_decision_match       ON pawtrace.match_decision (match_id);
CREATE INDEX idx_decision_created     ON pawtrace.match_decision USING brin (created_at);
CREATE INDEX idx_message_thread       ON pawtrace.message (thread_id, created_at);
CREATE INDEX idx_subscription_area    ON pawtrace.subscription USING gist (area) WHERE active;
CREATE INDEX idx_notification_target  ON pawtrace.notification (user_id, created_at DESC);
CREATE INDEX idx_notification_device  ON pawtrace.notification (device_id, created_at DESC) WHERE device_id IS NOT NULL;
CREATE INDEX idx_notification_unsent  ON pawtrace.notification (created_at) WHERE sent_at IS NULL;
CREATE INDEX idx_abuse_open           ON pawtrace.abuse_report (created_at) WHERE resolved_at IS NULL;
CREATE INDEX idx_moderation_entity    ON pawtrace.moderation_event (entity, entity_id, ts DESC);
CREATE INDEX idx_deletion_open        ON pawtrace.deletion_request (due_at) WHERE state <> 'completed';
CREATE INDEX idx_audit_log_ts         ON audit.log (ts DESC);
CREATE INDEX idx_audit_log_entity     ON audit.log (entity, entity_id, ts DESC);

-- =====================================================================
-- 17. VIEWS — the only public shapes (C-01, C-05)
-- =====================================================================

-- What the public sees of a report: a cell, an hour, coarse attributes, approved thumbnails. No coordinates, no poster.
CREATE OR REPLACE VIEW pawtrace.report_public AS
SELECT r.id, r.kind, r.status, r.title,
       pawtrace.fuzz_cell(r.location, 'public', r.region_id)           AS cell,
       date_trunc('hour', r.event_at)                                   AS event_hour,
       r.region_id,
       ra.size_class, ra.color_primary, ra.color_secondary, ra.coat_len, ra.breed_group, ra.has_markings,
       (SELECT count(*) FROM pawtrace.photo p WHERE p.report_id = r.id AND p.moderation_status = 'approved') AS approved_photos,
       (SELECT p.id FROM pawtrace.photo p WHERE p.report_id = r.id AND p.moderation_status = 'approved' ORDER BY p.position LIMIT 1) AS cover_photo_id,
       date_trunc('day', r.created_at)                                  AS created_day
  FROM pawtrace.report r
  LEFT JOIN pawtrace.report_attr ra ON ra.report_id = r.id
 WHERE r.status IN ('active', 'matched')
   AND EXISTS (SELECT 1 FROM pawtrace.photo p WHERE p.report_id = r.id AND p.moderation_status = 'approved');   -- C-05
COMMENT ON VIEW pawtrace.report_public IS 'The public representation (ReportPublic in API-07). public_ro reads this, never pawtrace.report.location.';

-- FR-24: map cells
CREATE OR REPLACE VIEW pawtrace.v_map_cells AS
SELECT rp.cell, rp.kind, rp.region_id,
       count(*)                                    AS n,
       max(rp.event_hour)                          AS last_event_hour,
       jsonb_object_agg(COALESCE(rp.color_primary::text, 'unknown'), 1) AS colors_present,
       ST_Y(pawtrace.cell_center(rp.cell)::geometry) AS center_lat,
       ST_X(pawtrace.cell_center(rp.cell)::geometry) AS center_lng
  FROM pawtrace.report_public rp
 GROUP BY rp.cell, rp.kind, rp.region_id;

-- What an owner sees: candidates with components, side-by-side photo ids, a distance BAND (not metres) until consent
CREATE OR REPLACE VIEW pawtrace.v_candidates AS
SELECT m.id AS match_id, m.lost_report_id, m.found_report_id, m.rank, m.status,
       m.calibrated_precision, m.score, m.components_json,
       CASE WHEN (m.components_json->>'distance_m')::numeric < 1000 THEN 'under 1 km'
            WHEN (m.components_json->>'distance_m')::numeric < 3000 THEN '1–3 km'
            WHEN (m.components_json->>'distance_m')::numeric < 10000 THEN '3–10 km'
            ELSE 'over 10 km' END                    AS distance_band,
       (m.components_json->>'hours_after')::numeric  AS hours_after,
       pawtrace.fuzz_cell(f.location, 'subscriber', f.region_id) AS found_cell,
       (SELECT p.id FROM pawtrace.photo p WHERE p.report_id = m.found_report_id AND p.moderation_status = 'approved' ORDER BY p.position LIMIT 1) AS found_photo_id,
       (SELECT p.id FROM pawtrace.photo p WHERE p.report_id = m.lost_report_id  AND p.moderation_status = 'approved' ORDER BY p.position LIMIT 1) AS lost_photo_id,
       m.notified_at, m.created_at
  FROM pawtrace.match m
  JOIN pawtrace.report f ON f.id = m.found_report_id
 WHERE m.status IN ('candidate', 'confirmed');

CREATE OR REPLACE VIEW pawtrace.v_moderation_queue AS
SELECT 'photo'::text AS item, p.id AS item_id, p.report_id, p.created_at, p.moderation_reason AS reason, 1 AS priority
  FROM pawtrace.photo p WHERE p.moderation_status = 'pending' AND p.processing_state = 'done'
UNION ALL
SELECT 'abuse_report', a.id, NULL, a.created_at, a.reason, 0
  FROM pawtrace.abuse_report a WHERE a.resolved_at IS NULL
UNION ALL
SELECT 'duplicate', d.id, d.primary_report_id, d.created_at, 'duplicate cluster', 2
  FROM pawtrace.duplicate_cluster d WHERE d.merged_at IS NULL AND d.dismissed_at IS NULL
ORDER BY priority, created_at;

-- AI-08
CREATE OR REPLACE VIEW pawtrace.v_bias_report AS
SELECT mv.name || ' ' || mv.version AS model, br.run_at, br.recall10 AS overall_recall10,
       bs.slice_kind, bs.slice_value, bs.n, bs.recall10, bs.gap_pct, bs.gap_pct > 15 AS rebalance_required
  FROM pawtrace.benchmark_run br
  JOIN pawtrace.model_version mv ON mv.id = br.model_version_id
  JOIN pawtrace.benchmark_slice bs ON bs.run_id = br.id
 WHERE br.id = (SELECT max(id) FROM pawtrace.benchmark_run b2 WHERE b2.model_version_id = br.model_version_id);

CREATE OR REPLACE VIEW pawtrace.v_notify_budget AS
SELECT u.id AS user_id, u.display_name,
       count(n.id) FILTER (WHERE n.channel IN ('push', 'email', 'sms') AND n.created_at >= date_trunc('day', now())) AS sent_today,
       count(n.id) FILTER (WHERE n.channel = 'digest' AND n.created_at >= date_trunc('day', now()))                  AS digested_today,
       pawtrace.can_notify(u.id, NULL) AS can_notify
  FROM pawtrace.app_user u LEFT JOIN pawtrace.notification n ON n.user_id = u.id
 WHERE u.deleted_at IS NULL
 GROUP BY u.id, u.display_name;

CREATE OR REPLACE VIEW pawtrace.v_deletion_status AS
SELECT d.id, d.requested_at, d.due_at, d.state, d.db_done_at, d.completed_at, d.summary_json,
       d.state <> 'completed' AND now() > d.due_at AS sla_breached
  FROM pawtrace.deletion_request d;

CREATE OR REPLACE VIEW pawtrace.v_vision_backlog AS
SELECT count(*) FILTER (WHERE processing_state = 'queued')     AS queued,
       count(*) FILTER (WHERE processing_state = 'processing') AS processing,
       min(created_at) FILTER (WHERE processing_state = 'queued') AS oldest_queued_at,
       extract(epoch FROM (now() - min(created_at) FILTER (WHERE processing_state = 'queued')))::integer AS oldest_age_s
  FROM pawtrace.photo;

CREATE OR REPLACE VIEW pawtrace.v_model_status AS
SELECT mv.id, mv.kind, mv.name, mv.version, mv.dims, mv.search_active, mv.calibration_provisional,
       mv.benchmark_recall1, mv.benchmark_recall10, mv.activated_at, mv.retired_at,
       (SELECT count(*) FROM pawtrace.embedding e WHERE e.model_version_id = mv.id) AS n_embeddings,
       (SELECT round(100.0 * j.done / NULLIF(j.total, 0), 1) FROM pawtrace.reembed_job j WHERE j.to_version_id = mv.id ORDER BY j.id DESC LIMIT 1) AS reembed_pct
  FROM pawtrace.model_version mv;

-- =====================================================================
-- 18. ROLES AND GRANTS  (DD-T01)
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')       THEN CREATE ROLE app_rw       NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')       THEN CREATE ROLE app_ro       NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'public_ro')    THEN CREATE ROLE public_ro    NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker_rw')    THEN CREATE ROLE worker_rw    NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_ro') THEN CREATE ROLE analytics_ro NOLOGIN; END IF;
END $$;

GRANT USAGE ON SCHEMA pawtrace, audit TO app_rw, app_ro, public_ro, worker_rw, analytics_ro;

-- api (authenticated paths)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pawtrace TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA pawtrace TO app_rw;
GRANT INSERT, SELECT ON audit.log, audit.auth_event TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA audit TO app_rw;

-- workers: vision writes instances/embeddings/attributes; match writes matches/notifications; scheduler runs jobs
GRANT SELECT ON ALL TABLES IN SCHEMA pawtrace TO worker_rw;
GRANT INSERT, UPDATE ON pawtrace.dog_instance, pawtrace.embedding, pawtrace.report_embedding, pawtrace.attributes, pawtrace.report_attr,
                        pawtrace.text_embedding, pawtrace.match, pawtrace.notification, pawtrace.duplicate_cluster, pawtrace.calibration_bin,
                        pawtrace.reembed_job, pawtrace.benchmark_run, pawtrace.benchmark_slice, pawtrace.rate_limit_bucket, pawtrace.moderation_event TO worker_rw;
GRANT UPDATE (processing_state, processing_error, moderation_status, moderation_reason, updated_at) ON pawtrace.photo TO worker_rw;
GRANT UPDATE (status, closed_at, updated_at) ON pawtrace.report TO worker_rw;
GRANT UPDATE (state, completed_at, summary_json) ON pawtrace.deletion_request TO worker_rw;
GRANT UPDATE (state, uri, expires_at) ON pawtrace.export_request TO worker_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA pawtrace TO worker_rw;
GRANT INSERT ON audit.log TO worker_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA audit TO worker_rw;

-- PUBLIC paths (ADR-T06): column-level on report WITHOUT location; the views; regions. Nothing else.
GRANT SELECT (id, kind, status, title, event_at, region_id, created_at) ON pawtrace.report TO public_ro;
GRANT SELECT ON pawtrace.report_public, pawtrace.v_map_cells, pawtrace.region TO public_ro;
GRANT SELECT (id, report_id, width, height, moderation_status, position) ON pawtrace.photo TO public_ro;
GRANT EXECUTE ON FUNCTION pawtrace.fuzz_cell(geography, pawtrace.audience, smallint), pawtrace.cell_center(text) TO public_ro;
REVOKE ALL ON pawtrace.app_user, pawtrace.device, pawtrace.contact_channel, pawtrace.thread, pawtrace.message, pawtrace.match, pawtrace.match_decision,
              pawtrace.subscription, pawtrace.push_subscription, pawtrace.notification, pawtrace.embedding, pawtrace.report_embedding, pawtrace.text_embedding FROM public_ro;

GRANT SELECT ON ALL TABLES IN SCHEMA pawtrace TO app_ro;
GRANT SELECT ON audit.log, audit.auth_event TO app_ro;

-- analytics: no identities, no locations, no messages
GRANT SELECT ON pawtrace.match, pawtrace.match_decision, pawtrace.calibration_bin, pawtrace.benchmark_run, pawtrace.benchmark_slice,
                pawtrace.v_bias_report, pawtrace.v_model_status, pawtrace.report_public, pawtrace.v_map_cells TO analytics_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA pawtrace GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA pawtrace GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit    GRANT INSERT, SELECT ON TABLES TO app_rw;

-- =====================================================================
-- 19. SCHEMA VERSION
-- =====================================================================
CREATE TABLE pawtrace.schema_version (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    notes       text
);
INSERT INTO pawtrace.schema_version (version, notes) VALUES ('pawtrace_0001', 'Initial schema — DDS-07 v1.0');
