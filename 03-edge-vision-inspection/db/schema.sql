-- =====================================================================
-- EdgeGuard — Node local store schema  (SQLite 3.40+)
-- Document : DDS-03-EdgeGuard (see docs/DDS-EdgeGuard-Local-Store-Design.md)
-- Version  : 1.0
-- Date     : 2026-09-12
--
-- This is the LOCAL store on the edge node: a buffer that is authoritative
-- only until the central platform acknowledges a record (SAD-03 P-4).
-- The record shape is a strict projection of the IF-01 InspectionCreate
-- payload; the mapping is verified programmatically (DDS-03 section 6).
--
-- Apply with:   sqlite3 edgeguard.db < schema.sql
-- or in Python: conn.executescript(open('schema.sql').read())
--
-- Single-writer rule (ADR-E02): only the `store` process writes.
-- =====================================================================

PRAGMA journal_mode = WAL;        -- survives power loss; readers never block the writer
PRAGMA synchronous  = NORMAL;     -- WAL + NORMAL: durable at checkpoint; last txn survives OS crash;
                                  -- a power cut can lose the final ms of un-checkpointed WAL, which is
                                  -- exactly the window in which no PLC pulse was sent (ADR-E03)
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA temp_store   = MEMORY;
PRAGMA page_size    = 4096;

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Node identity (exactly one row)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS node_info (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    node_code       TEXT    NOT NULL,
    line_code       TEXT    NOT NULL,
    station_code    TEXT    NOT NULL,
    plant_code      TEXT    NOT NULL,
    app_version     TEXT    NOT NULL,
    schema_version  TEXT    NOT NULL DEFAULT '1.0.0',
    hardware        TEXT,
    sync_url        TEXT    NOT NULL,
    lang            TEXT    NOT NULL DEFAULT 'th' CHECK (lang IN ('th','ja','en')),
    provisioned_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TRIGGER IF NOT EXISTS trg_node_info_single_row
BEFORE INSERT ON node_info
WHEN (SELECT count(*) FROM node_info) >= 1
BEGIN
    SELECT RAISE(ABORT, 'node_info holds exactly one row');
END;

-- ---------------------------------------------------------------------
-- 2. Inspection records  (the buffer)
--    Column names mirror the IF-01 InspectionCreate payload where a field
--    exists; extra columns are local bookkeeping (synced_at, attempts...).
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS inspection (
    id              TEXT    PRIMARY KEY,                -- client-generated UUIDv7 (dedup key on the central)
    ts              TEXT    NOT NULL,                   -- RFC 3339 with offset
    line            TEXT    NOT NULL,
    station         TEXT    NOT NULL,
    camera_id       TEXT    NOT NULL,
    sku             TEXT,
    lot             TEXT,
    verdict         TEXT    NOT NULL CHECK (verdict IN ('PASS','FAIL','REVIEW','NO_READ')),
    no_read_reason  TEXT    CHECK (no_read_reason IS NULL OR no_read_reason IN ('BLUR','EXPOSURE','NO_PART','CALIBRATION_STALE')),
    model_version   TEXT    NOT NULL,                   -- "name:version"
    recipe_version  INTEGER,
    latency_ms      INTEGER CHECK (latency_ms IS NULL OR latency_ms >= 0),
    ocr_text        TEXT,
    image_path      TEXT,                               -- local cache path; NULL when PASS sampled out
    overlay_path    TEXT,
    heatmap_path    TEXT,
    image_sha256    TEXT    CHECK (image_sha256 IS NULL OR length(image_sha256) = 64),
    frame_id        INTEGER,                            -- camera chunk frame id (liveness)
    device_ts       TEXT,                               -- camera chunk timestamp
    source          TEXT    NOT NULL DEFAULT 'edge' CHECK (source IN ('edge','manual')),
    -- local bookkeeping (never sent)
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    synced_at       TEXT,                               -- set ONLY by store.mark_synced on accepted|duplicate
    sync_attempts   INTEGER NOT NULL DEFAULT 0,
    last_sync_error TEXT,
    image_synced_at TEXT
);

CREATE TABLE IF NOT EXISTS detection (
    id              INTEGER PRIMARY KEY,
    inspection_id   TEXT    NOT NULL REFERENCES inspection(id) ON DELETE CASCADE,
    class_name      TEXT    NOT NULL,
    confidence      REAL    NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    bbox_json       TEXT    NOT NULL,                   -- {"x":..,"y":..,"w":..,"h":..}
    area_mm2        REAL
);

CREATE TABLE IF NOT EXISTS measurement (
    id              INTEGER PRIMARY KEY,
    inspection_id   TEXT    NOT NULL REFERENCES inspection(id) ON DELETE CASCADE,
    parameter       TEXT    NOT NULL,
    value           REAL    NOT NULL,
    unit            TEXT    NOT NULL DEFAULT 'mm',
    usl             REAL,
    lsl             REAL,
    in_spec         INTEGER NOT NULL CHECK (in_spec IN (0,1)),
    calibration_version INTEGER
);

CREATE TABLE IF NOT EXISTS anomaly_score (
    inspection_id   TEXT    PRIMARY KEY REFERENCES inspection(id) ON DELETE CASCADE,
    model_version   TEXT    NOT NULL,
    score           REAL    NOT NULL,
    threshold       REAL    NOT NULL,
    flagged         INTEGER NOT NULL CHECK (flagged IN (0,1))
);

-- Local human decision (supervisor PIN). Synced to the central as a verdict override.
CREATE TABLE IF NOT EXISTS override (
    id              TEXT    PRIMARY KEY,                -- UUIDv7
    inspection_id   TEXT    NOT NULL REFERENCES inspection(id) ON DELETE RESTRICT,
    old_verdict     TEXT    NOT NULL,
    new_verdict     TEXT    NOT NULL CHECK (new_verdict IN ('PASS','FAIL','REVIEW')),
    user_ref        TEXT    NOT NULL,                   -- badge / PIN holder id, never a name
    reason_code     TEXT    NOT NULL CHECK (reason_code IN ('CONFIRMED_DEFECT','FALSE_ALARM','ACCEPTABLE_MARK','ESCAPE_FOUND','WRONG_CLASS','OTHER')),
    note            TEXT,
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    synced_at       TEXT,
    CHECK (old_verdict <> new_verdict)
);

-- ---------------------------------------------------------------------
-- 3. Sync queues
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sync_queue (
    id              INTEGER PRIMARY KEY,
    entity          TEXT    NOT NULL CHECK (entity IN ('inspection','override')),
    entity_id       TEXT    NOT NULL,
    priority        INTEGER NOT NULL DEFAULT 5,         -- 1 = FAIL/REVIEW, 5 = PASS, 9 = housekeeping
    attempts        INTEGER NOT NULL DEFAULT 0,
    next_retry_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    last_error      TEXT,
    UNIQUE (entity, entity_id)
);

CREATE TABLE IF NOT EXISTS image_queue (
    id              INTEGER PRIMARY KEY,
    inspection_id   TEXT    NOT NULL REFERENCES inspection(id) ON DELETE CASCADE,
    kind            TEXT    NOT NULL CHECK (kind IN ('original','overlay','heatmap')),
    path            TEXT    NOT NULL,
    sha256          TEXT    NOT NULL CHECK (length(sha256) = 64),
    bytes           INTEGER NOT NULL,
    attempts        INTEGER NOT NULL DEFAULT 0,
    next_retry_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    last_error      TEXT,
    UNIQUE (inspection_id, kind)
);

-- ---------------------------------------------------------------------
-- 4. Caches pulled from the central (config, models, calibration)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config_cache (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    etag            TEXT    NOT NULL,
    bundle_json     TEXT    NOT NULL,                   -- the EdgeConfig bundle as received
    source          TEXT    NOT NULL CHECK (source IN ('central','usb','node_yaml')),
    validated       INTEGER NOT NULL CHECK (validated IN (0,1)),
    applied_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS model_cache (
    id              INTEGER PRIMARY KEY,
    name            TEXT    NOT NULL,
    version         TEXT    NOT NULL,
    task            TEXT    NOT NULL CHECK (task IN ('detection','segmentation','classification','ocr','anomaly')),
    sha256          TEXT    NOT NULL CHECK (length(sha256) = 64),
    artefact_path   TEXT    NOT NULL,
    engine_path     TEXT,
    engine_key      TEXT,                               -- device|driver|model|version|precision
    precision       TEXT    NOT NULL CHECK (precision IN ('fp32','fp16','int8')),
    class_map_json  TEXT    NOT NULL DEFAULT '{}',
    stage           TEXT    NOT NULL CHECK (stage IN ('downloaded','shadow','active','previous','retired')),
    verified_at     TEXT,                               -- sha256 verified against manifest
    shadow_frames   INTEGER NOT NULL DEFAULT 0,
    shadow_disagree INTEGER NOT NULL DEFAULT 0,
    activated_at    TEXT,
    UNIQUE (name, version)
);

-- At most one active and one previous per model name (ADR-E07)
CREATE UNIQUE INDEX IF NOT EXISTS ux_model_active   ON model_cache(name) WHERE stage = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS ux_model_previous ON model_cache(name) WHERE stage = 'previous';
CREATE UNIQUE INDEX IF NOT EXISTS ux_model_shadow   ON model_cache(name) WHERE stage = 'shadow';

-- A model may only be active if its checksum was verified (SEC-E30)
CREATE TRIGGER IF NOT EXISTS trg_model_active_requires_verified
BEFORE UPDATE OF stage ON model_cache
WHEN NEW.stage IN ('active','shadow') AND NEW.verified_at IS NULL
BEGIN
    SELECT RAISE(ABORT, 'model cannot be activated or shadowed before sha256 verification');
END;

-- Same guard on INSERT: a row cannot be born active/shadow unverified (found by TEST-03 TC-003)
CREATE TRIGGER IF NOT EXISTS trg_model_insert_requires_verified
BEFORE INSERT ON model_cache
WHEN NEW.stage IN ('active','shadow') AND NEW.verified_at IS NULL
BEGIN
    SELECT RAISE(ABORT, 'model cannot be inserted as active or shadow before sha256 verification');
END;

CREATE TABLE IF NOT EXISTS calibration_cache (
    camera_id            TEXT    PRIMARY KEY,
    version              INTEGER NOT NULL,
    method               TEXT    NOT NULL CHECK (method IN ('scale','intrinsics_scale','homography')),
    px_per_mm            REAL,
    intrinsics_json      TEXT,
    hardware_fingerprint TEXT    NOT NULL,
    valid                INTEGER NOT NULL CHECK (valid IN (0,1)),
    fingerprint_ok       INTEGER NOT NULL DEFAULT 1 CHECK (fingerprint_ok IN (0,1)),
    checked_at           TEXT
);

-- ---------------------------------------------------------------------
-- 5. Node state and events
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS node_event (
    id          INTEGER PRIMARY KEY,
    ts          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    kind        TEXT    NOT NULL CHECK (kind IN ('boot','shutdown','fault_set','fault_cleared','model_change',
                                                 'config_change','calibration_change','thermal','store_recovered',
                                                 'sync_backlog','disk_policy','security','pin_failed')),
    severity    TEXT    NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','critical')),
    detail_json TEXT    NOT NULL DEFAULT '{}',
    synced_at   TEXT
);

-- Current fault state: one row per active fault source
CREATE TABLE IF NOT EXISTS fault_state (
    source      TEXT    PRIMARY KEY CHECK (source IN ('camera','model','calibration','store','thermal','config','selftest')),
    reason      TEXT    NOT NULL,
    since       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    blocks_ready INTEGER NOT NULL CHECK (blocks_ready IN (0,1))
);

CREATE TABLE IF NOT EXISTS disk_policy_state (
    id                  INTEGER PRIMARY KEY CHECK (id = 1),
    disk_total_bytes    INTEGER NOT NULL,
    disk_free_bytes     INTEGER NOT NULL,
    free_pct            REAL    NOT NULL,
    min_free_pct        REAL    NOT NULL DEFAULT 15.0,
    pass_images_enabled INTEGER NOT NULL CHECK (pass_images_enabled IN (0,1)),
    last_purge_at       TEXT,
    last_purged_bytes   INTEGER NOT NULL DEFAULT 0,
    updated_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS heartbeat_log (
    ts              TEXT    PRIMARY KEY,
    sent            INTEGER NOT NULL CHECK (sent IN (0,1)),
    http_status     INTEGER,
    buffer_depth    INTEGER NOT NULL,
    cpu_pct         REAL, gpu_pct REAL, mem_pct REAL, disk_pct REAL, temp_c REAL, fps REAL,
    camera_state    TEXT    NOT NULL CHECK (camera_state IN ('ok','disconnected','frozen','no_trigger')),
    calibration_valid INTEGER NOT NULL CHECK (calibration_valid IN (0,1))
);

CREATE TABLE IF NOT EXISTS shift_counter (
    shift_date  TEXT    NOT NULL,
    shift       TEXT    NOT NULL,
    verdict     TEXT    NOT NULL CHECK (verdict IN ('PASS','FAIL','REVIEW','NO_READ')),
    count       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (shift_date, shift, verdict)
);

-- ---------------------------------------------------------------------
-- 6. Indexes for the hot paths
-- ---------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ix_inspection_unsynced   ON inspection(created_at) WHERE synced_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inspection_ts         ON inspection(ts DESC);
CREATE INDEX IF NOT EXISTS ix_inspection_verdict_ts ON inspection(verdict, ts DESC);
CREATE INDEX IF NOT EXISTS ix_inspection_purge      ON inspection(synced_at, verdict) WHERE synced_at IS NOT NULL AND image_path IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_detection_insp        ON detection(inspection_id);
CREATE INDEX IF NOT EXISTS ix_measurement_insp      ON measurement(inspection_id);
CREATE INDEX IF NOT EXISTS ix_override_unsynced     ON override(created_at) WHERE synced_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sync_queue_due        ON sync_queue(priority, next_retry_at);
CREATE INDEX IF NOT EXISTS ix_image_queue_due       ON image_queue(next_retry_at);
CREATE INDEX IF NOT EXISTS ix_node_event_ts         ON node_event(ts DESC);
CREATE INDEX IF NOT EXISTS ix_node_event_unsynced   ON node_event(ts) WHERE synced_at IS NULL;

-- ---------------------------------------------------------------------
-- 7. Views
-- ---------------------------------------------------------------------

-- Sync backlog: what the heartbeat reports as buffer_depth
CREATE VIEW IF NOT EXISTS v_backlog AS
SELECT
    (SELECT count(*) FROM inspection WHERE synced_at IS NULL)               AS records_unsynced,
    (SELECT count(*) FROM override   WHERE synced_at IS NULL)               AS overrides_unsynced,
    (SELECT count(*) FROM image_queue)                                      AS images_queued,
    (SELECT coalesce(sum(bytes),0) FROM image_queue)                        AS image_bytes_queued,
    (SELECT count(*) FROM sync_queue WHERE attempts >= 5)                   AS records_stuck,
    (SELECT min(created_at) FROM inspection WHERE synced_at IS NULL)        AS oldest_unsynced_at;

-- Purge candidates: NEVER an unsynced row (ADR-E09). PASS first, oldest first.
CREATE VIEW IF NOT EXISTS v_purge_candidates AS
SELECT id, image_path, overlay_path, heatmap_path, synced_at, verdict, ts
FROM inspection
WHERE synced_at IS NOT NULL
  AND (image_path IS NOT NULL OR overlay_path IS NOT NULL OR heatmap_path IS NOT NULL)
  AND id NOT IN (SELECT inspection_id FROM image_queue)
ORDER BY CASE verdict WHEN 'PASS' THEN 0 WHEN 'NO_READ' THEN 1 ELSE 2 END, ts ASC;

-- Effective verdict (local override applied) for the HMI counters
CREATE VIEW IF NOT EXISTS v_effective_verdict AS
SELECT i.id, i.ts, i.station, i.sku, i.lot, i.verdict AS model_verdict,
       coalesce((SELECT o.new_verdict FROM override o WHERE o.inspection_id = i.id ORDER BY o.created_at DESC LIMIT 1), i.verdict) AS effective_verdict,
       EXISTS (SELECT 1 FROM override o WHERE o.inspection_id = i.id) AS overridden
FROM inspection i;

-- Whether the node may assert READY (any blocking fault → 0)
CREATE VIEW IF NOT EXISTS v_ready AS
SELECT CASE WHEN EXISTS (SELECT 1 FROM fault_state WHERE blocks_ready = 1) THEN 0 ELSE 1 END AS ready,
       (SELECT group_concat(source || ':' || reason, ';') FROM fault_state WHERE blocks_ready = 1) AS blocking,
       (SELECT group_concat(source || ':' || reason, ';') FROM fault_state WHERE blocks_ready = 0) AS alarms;

-- Active model per name
CREATE VIEW IF NOT EXISTS v_active_models AS
SELECT name, version, task, precision, sha256, engine_path, activated_at
FROM model_cache WHERE stage = 'active';

-- Schema version stamp
CREATE TABLE IF NOT EXISTS schema_version (
    version     TEXT PRIMARY KEY,
    applied_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    description TEXT
);
INSERT OR IGNORE INTO schema_version (version, description)
VALUES ('1.0.0', 'EdgeGuard node local store (DDS-03 v1.0)');

COMMIT;
