-- =====================================================================
--  PocketQC — on-device database (SQLite via Drift, SQLCipher at rest)
--  DDS-05-PocketQC v1.0 · 2026-09-13 · Suphot N.
--
--  Executed on the authoring machine with Python sqlite3 (plain SQLite is a subset of SQLCipher;
--  the PRAGMA key line is documented in DDS-05 §1.3 and applied by the app, not here).
--
--  Rules the schema enforces (DDS-05 §2):
--    DD-M01  every step commits before the UI advances; session.current_step moves in the same transaction
--    DD-M02  the model never decides: suggested_result and human_result are separate; a session cannot
--            finish with an undecided REVIEW step (trigger)
--    DD-M03  synced_at is set only by sync; unsynced rows and their images are never purge candidates (view)
--    DD-M04  a model is active only after sha256 verification AND an on-device self-test (trigger + partial index)
--    DD-M05  re-judging a finished session requires a supervisor audit row (trigger); audit is append-only
--    DD-M06  an image row never points at a missing file: the file is written first (app), the row carries sha256
-- =====================================================================

PRAGMA journal_mode = WAL;
PRAGMA synchronous  = FULL;          -- a phone can be dropped mid-transaction; durability over write speed
PRAGMA foreign_keys = ON;
PRAGMA secure_delete = ON;           -- purged rows are overwritten (encrypted anyway; belt-and-braces)
PRAGMA busy_timeout = 5000;

-- =====================================================================
-- 1. DEVICE, USER, CONFIGURATION (single-row tables)
-- =====================================================================
CREATE TABLE IF NOT EXISTS device_info (
    id                INTEGER PRIMARY KEY CHECK (id = 1),
    device_id         TEXT    NOT NULL,            -- provisioned via managed configuration (IF-33), not the hardware serial
    device_model      TEXT    NOT NULL,
    android_sdk       INTEGER NOT NULL,
    app_version       TEXT    NOT NULL,
    schema_version    INTEGER NOT NULL,
    delegate          TEXT    CHECK (delegate IN ('nnapi','gpu','cpu')),   -- ADR-M04 probe result
    delegate_probed_at TEXT,
    lang              TEXT    NOT NULL DEFAULT 'th' CHECK (lang IN ('th','ja','en')),
    server_url        TEXT    NOT NULL,
    provisioned_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS auth_state (
    id                  INTEGER PRIMARY KEY CHECK (id = 1),
    user_id             TEXT    NOT NULL,
    username            TEXT    NOT NULL,
    display_name        TEXT    NOT NULL,
    role                TEXT    NOT NULL CHECK (role IN ('inspector','supervisor','admin')),
    token_ref           TEXT    NOT NULL,            -- key in secure storage (IF-35); the token itself is NEVER in this DB
    online_login_at     TEXT    NOT NULL,
    offline_valid_until TEXT    NOT NULL,            -- FR-27: online_login_at + offline_days (managed config, default 30)
    supervisor_pin_ref  TEXT                         -- key in secure storage for the PIN hash (FR-19)
);

CREATE TABLE IF NOT EXISTS policy_cache (
    id                   INTEGER PRIMARY KEY CHECK (id = 1),
    retention_days       INTEGER NOT NULL DEFAULT 60 CHECK (retention_days >= 1),        -- FR-30
    sync_network         TEXT    NOT NULL DEFAULT 'wifi' CHECK (sync_network IN ('wifi','any')),   -- FR-21
    image_max_edge_px    INTEGER NOT NULL DEFAULT 1600,                                   -- FR-25
    image_jpeg_quality   INTEGER NOT NULL DEFAULT 85 CHECK (image_jpeg_quality BETWEEN 40 AND 100),
    pass_image_upload    INTEGER NOT NULL DEFAULT 1 CHECK (pass_image_upload IN (0,1)),
    gps_enabled          INTEGER NOT NULL DEFAULT 0 CHECK (gps_enabled IN (0,1)),        -- FR-04 optional
    offline_days         INTEGER NOT NULL DEFAULT 30 CHECK (offline_days BETWEEN 1 AND 90),
    low_space_warn_pct   INTEGER NOT NULL DEFAULT 20,
    low_space_crit_pct   INTEGER NOT NULL DEFAULT 10,
    wipe_requested       INTEGER NOT NULL DEFAULT 0 CHECK (wipe_requested IN (0,1)),     -- FR-28
    etag                 TEXT,
    fetched_at           TEXT
);

CREATE TABLE IF NOT EXISTS bootstrap_state (
    id               INTEGER PRIMARY KEY CHECK (id = 1),
    etag             TEXT,
    fetched_at       TEXT,
    last_sync_ok_at  TEXT,                            -- FR-24 "last successful sync"
    last_sync_error  TEXT
);

-- =====================================================================
-- 2. MASTER DATA CACHES (server wins — replaced atomically at bootstrap, FR-22/FR-23)
-- =====================================================================
CREATE TABLE IF NOT EXISTS checklist_cache (
    checklist_id     TEXT    NOT NULL,
    version          INTEGER NOT NULL,
    sku_pattern      TEXT,                            -- regex over SKU codes; NULL = manual selection only
    title_th         TEXT, title_ja TEXT, title_en TEXT,
    definition_json  TEXT    NOT NULL,                -- validated against deploy/schemas/checklist.schema.json before insert
    step_count       INTEGER NOT NULL CHECK (step_count BETWEEN 1 AND 60),
    active           INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
    PRIMARY KEY (checklist_id, version)
);

CREATE TABLE IF NOT EXISTS sku_cache (
    sku              TEXT    PRIMARY KEY,
    name             TEXT    NOT NULL,
    family           TEXT,
    checklist_id     TEXT,                            -- default checklist for the SKU (FR-08 auto-select)
    active           INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1))
);

CREATE TABLE IF NOT EXISTS defect_code_cache (
    code             TEXT    PRIMARY KEY,
    name_th          TEXT, name_ja TEXT, name_en TEXT NOT NULL,
    severity_default TEXT    NOT NULL CHECK (severity_default IN ('minor','major','critical')),
    active           INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1))
);

-- =====================================================================
-- 3. MODELS (OTA: verified + self-tested before active — DD-M04)
-- =====================================================================
CREATE TABLE IF NOT EXISTS model_asset (
    name               TEXT    NOT NULL,
    version            TEXT    NOT NULL,
    task               TEXT    NOT NULL CHECK (task IN ('detection','classification','ocr')),
    sha256             TEXT    NOT NULL CHECK (length(sha256) = 64),
    size_bytes         INTEGER NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 26214400),   -- C-02: <= 25 MB
    path               TEXT    NOT NULL,
    class_map_json     TEXT    NOT NULL,
    input_size         INTEGER NOT NULL DEFAULT 640,
    installed_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    verified_at        TEXT,                          -- sha256 matched the manifest
    selftest_passed_at TEXT,                          -- FR-26 / AI-06: sample images on THIS device
    selftest_json      TEXT,                          -- recall on samples, latency p95, delegate
    active             INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0,1)),
    previous           INTEGER NOT NULL DEFAULT 0 CHECK (previous IN (0,1)),
    PRIMARY KEY (name, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_model_active   ON model_asset(name) WHERE active = 1;
CREATE UNIQUE INDEX IF NOT EXISTS ux_model_previous ON model_asset(name) WHERE previous = 1;

CREATE TRIGGER IF NOT EXISTS trg_model_activate_requires_selftest
BEFORE UPDATE OF active ON model_asset
WHEN NEW.active = 1 AND (NEW.verified_at IS NULL OR NEW.selftest_passed_at IS NULL)
BEGIN
    SELECT RAISE(ABORT, 'model cannot be activated before sha256 verification and a passed self-test (FR-26)');
END;
CREATE TRIGGER IF NOT EXISTS trg_model_insert_requires_selftest
BEFORE INSERT ON model_asset
WHEN NEW.active = 1 AND (NEW.verified_at IS NULL OR NEW.selftest_passed_at IS NULL)
BEGIN
    SELECT RAISE(ABORT, 'model cannot be inserted as active before verification and self-test (FR-26)');
END;

-- =====================================================================
-- 4. INSPECTION RECORDS (the buffer that syncs — SRS-05 §5 names kept)
-- =====================================================================
CREATE TABLE IF NOT EXISTS session (
    uuid              TEXT    PRIMARY KEY,           -- client UUIDv7 = server dedup key (IF-11)
    checklist_id      TEXT    NOT NULL,
    checklist_version INTEGER NOT NULL,
    sku               TEXT,
    lot               TEXT,
    started_at        TEXT    NOT NULL,
    finished_at       TEXT,
    verdict           TEXT    CHECK (verdict IN ('PASS','FAIL','REVIEW')),
    current_step      INTEGER NOT NULL DEFAULT 1,   -- FR-16 resume point
    user_id           TEXT    NOT NULL,
    device_id         TEXT    NOT NULL,
    lang              TEXT    NOT NULL DEFAULT 'th',
    gps_lat           REAL, gps_lon REAL,
    note              TEXT,
    synced_at         TEXT,                          -- set only by sync (DD-M03)
    sync_attempts     INTEGER NOT NULL DEFAULT 0,
    last_sync_error   TEXT,
    FOREIGN KEY (checklist_id, checklist_version) REFERENCES checklist_cache(checklist_id, version),
    CHECK ((finished_at IS NULL) = (verdict IS NULL))              -- finished ⇔ verdict present
);

CREATE TABLE IF NOT EXISTS image (
    uuid            TEXT    PRIMARY KEY,
    path_encrypted  TEXT    NOT NULL,                -- app-private path; AES-GCM, Keystore-wrapped key (ADR-M05)
    sha256          TEXT    NOT NULL CHECK (length(sha256) = 64),   -- of the plaintext JPEG; verified by the server
    width           INTEGER NOT NULL,
    height          INTEGER NOT NULL,
    bytes           INTEGER NOT NULL,
    captured_at     TEXT    NOT NULL,
    torch_on        INTEGER NOT NULL DEFAULT 0 CHECK (torch_on IN (0,1)),   -- FR-05
    quality_json    TEXT,                            -- blur variance, exposure mean, glare ratio (FR-02)
    burst_index     INTEGER,                         -- FR-03: which of the burst frames was chosen
    upload_offset   INTEGER NOT NULL DEFAULT 0,      -- resumable upload progress (IF-11)
    uploaded_at     TEXT
);

CREATE TABLE IF NOT EXISTS step_result (
    uuid               TEXT    PRIMARY KEY,
    session_uuid       TEXT    NOT NULL REFERENCES session(uuid) ON DELETE CASCADE,
    step_no            INTEGER NOT NULL,
    kind               TEXT    NOT NULL CHECK (kind IN ('photo_ai','photo','barcode','ocr','measure','check')),
    model_name         TEXT,
    model_version      TEXT,                         -- FR-12: which model judged this step (NULL = manual mode, AI-08)
    model_result_json  TEXT,                         -- detections / OCR raw / barcode raw; NULL in manual mode
    suggested_result   TEXT    CHECK (suggested_result IN ('PASS','FAIL','REVIEW')),
    human_result       TEXT    CHECK (human_result IN ('PASS','FAIL')),     -- FR-11: the inspector's judgement
    decided_at         TEXT,
    note               TEXT,
    defect_code        TEXT    REFERENCES defect_code_cache(code),
    severity           TEXT    CHECK (severity IN ('minor','major','critical')),
    text_value         TEXT,                         -- barcode / OCR corrected text
    text_raw           TEXT,                         -- OCR raw text before one-tap correction (FR-07)
    image_uuid         TEXT    REFERENCES image(uuid) ON DELETE RESTRICT,
    latency_ms         INTEGER,                      -- AI-03 diagnostics
    created_at         TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (session_uuid, step_no),
    CHECK (human_result IS NULL OR decided_at IS NOT NULL),
    CHECK (defect_code IS NULL OR human_result = 'FAIL' OR severity IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS measurement (
    uuid          TEXT    PRIMARY KEY,
    step_uuid     TEXT    NOT NULL REFERENCES step_result(uuid) ON DELETE CASCADE,
    name          TEXT    NOT NULL,
    value         REAL    NOT NULL,
    unit          TEXT    NOT NULL DEFAULT 'mm',
    usl           REAL, lsl REAL,
    tolerance     REAL,                              -- ± from marker size/distance (AI-05)
    in_spec       INTEGER NOT NULL CHECK (in_spec IN (0,1)),
    method        TEXT    NOT NULL CHECK (method IN ('aruco_reference','fixed_distance','manual')),
    marker_id     INTEGER,
    px_per_mm     REAL
);

-- FR-10/FR-11 (DD-M02): a session cannot be finished while any step's suggested REVIEW is undecided,
-- and every photo_ai / measure / check step must carry a human result.
CREATE TRIGGER IF NOT EXISTS trg_session_finish_requires_decisions
BEFORE UPDATE OF finished_at ON session
WHEN NEW.finished_at IS NOT NULL AND EXISTS (
    SELECT 1 FROM step_result s
    WHERE s.session_uuid = NEW.uuid
      AND s.kind IN ('photo_ai','photo','measure','check')
      AND s.human_result IS NULL)
BEGIN
    SELECT RAISE(ABORT, 'session cannot finish: a step still needs the inspector''s judgement (FR-10/FR-11)');
END;

-- =====================================================================
-- 5. SYNC QUEUE, LOG
-- =====================================================================
CREATE TABLE IF NOT EXISTS sync_queue (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    entity        TEXT    NOT NULL CHECK (entity IN ('session','image')),
    entity_uuid   TEXT    NOT NULL,
    priority      INTEGER NOT NULL DEFAULT 5,         -- 1 = sessions (records first), 5 = images (ADR-M06)
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    next_retry_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    enqueued_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (entity, entity_uuid)
);

CREATE TABLE IF NOT EXISTS sync_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    kind          TEXT    NOT NULL CHECK (kind IN ('bootstrap','policy','sessions','images','models','heartbeat','wipe')),
    ok            INTEGER NOT NULL CHECK (ok IN (0,1)),
    http_status   INTEGER,
    accepted      INTEGER, duplicate INTEGER, rejected INTEGER,
    bytes         INTEGER,
    duration_ms   INTEGER,
    detail        TEXT
);

-- =====================================================================
-- 6. AUDIT (append-only) and PURGE LOG
-- =====================================================================
CREATE TABLE IF NOT EXISTS audit_event (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    user_id       TEXT    NOT NULL,
    event         TEXT    NOT NULL CHECK (event IN ('login_online','login_offline','pin_ok','pin_fail','rejudge','override_model','wipe','purge','model_activate','model_rollback','selftest_failed')),
    session_uuid  TEXT,
    detail_json   TEXT,
    synced_at     TEXT
);
CREATE TRIGGER IF NOT EXISTS trg_audit_append_only_u BEFORE UPDATE ON audit_event
BEGIN SELECT RAISE(ABORT, 'audit_event is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_audit_append_only_d BEFORE DELETE ON audit_event
BEGIN SELECT RAISE(ABORT, 'audit_event is append-only'); END;

-- FR-19 (DD-M05): changing the verdict of a finished session requires a supervisor 'rejudge' audit row for it
CREATE TRIGGER IF NOT EXISTS trg_session_rejudge_requires_audit
BEFORE UPDATE OF verdict ON session
WHEN OLD.finished_at IS NOT NULL AND NEW.verdict IS NOT OLD.verdict
     AND NOT EXISTS (SELECT 1 FROM audit_event a WHERE a.session_uuid = OLD.uuid AND a.event = 'rejudge'
                     AND a.ts >= strftime('%Y-%m-%dT%H:%M:%fZ','now','-1 minute'))
BEGIN
    SELECT RAISE(ABORT, 're-judging a finished session requires a supervisor PIN audit row (FR-19)');
END;

CREATE TABLE IF NOT EXISTS purge_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    reason        TEXT    NOT NULL CHECK (reason IN ('retention','low_space','wipe')),
    sessions      INTEGER NOT NULL,
    images        INTEGER NOT NULL,
    bytes_freed   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS schema_version (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    notes      TEXT
);

-- =====================================================================
-- 7. INDEXES
-- =====================================================================
CREATE INDEX IF NOT EXISTS ix_session_started   ON session(started_at DESC);
CREATE INDEX IF NOT EXISTS ix_session_unsynced  ON session(synced_at) WHERE synced_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_session_lot       ON session(lot);
CREATE INDEX IF NOT EXISTS ix_session_sku       ON session(sku, started_at DESC);
CREATE INDEX IF NOT EXISTS ix_session_verdict   ON session(verdict, started_at DESC);
CREATE INDEX IF NOT EXISTS ix_step_session      ON step_result(session_uuid, step_no);
CREATE INDEX IF NOT EXISTS ix_step_image        ON step_result(image_uuid);
CREATE INDEX IF NOT EXISTS ix_image_unuploaded  ON image(uploaded_at) WHERE uploaded_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_measure_step      ON measurement(step_uuid);
CREATE INDEX IF NOT EXISTS ix_queue_due         ON sync_queue(priority, next_retry_at);
CREATE INDEX IF NOT EXISTS ix_audit_session     ON audit_event(session_uuid, ts);

-- =====================================================================
-- 8. VIEWS
-- =====================================================================

-- FR-24: pending-sync counter and bytes
CREATE VIEW IF NOT EXISTS v_pending_sync AS
SELECT
    (SELECT count(*) FROM session WHERE finished_at IS NOT NULL AND synced_at IS NULL)              AS sessions_pending,
    (SELECT count(*) FROM session WHERE finished_at IS NULL)                                        AS sessions_in_progress,
    (SELECT count(*) FROM image i JOIN step_result s ON s.image_uuid = i.uuid JOIN session se ON se.uuid = s.session_uuid
       WHERE i.uploaded_at IS NULL AND se.synced_at IS NOT NULL)                                    AS images_pending,
    (SELECT COALESCE(sum(i.bytes),0) FROM image i JOIN step_result s ON s.image_uuid = i.uuid JOIN session se ON se.uuid = s.session_uuid
       WHERE i.uploaded_at IS NULL AND se.synced_at IS NOT NULL)                                    AS image_bytes_pending,
    (SELECT count(*) FROM sync_queue WHERE attempts >= 5)                                           AS stuck,
    (SELECT last_sync_ok_at FROM bootstrap_state WHERE id = 1)                                      AS last_sync_ok_at;

-- FR-30 / DD-M03: purge candidates — synced sessions older than retention; never unsynced, never in-progress
CREATE VIEW IF NOT EXISTS v_purge_candidates AS
SELECT se.uuid AS session_uuid, se.finished_at, se.verdict,
       (SELECT count(*) FROM step_result s JOIN image i ON i.uuid = s.image_uuid WHERE s.session_uuid = se.uuid) AS images,
       (SELECT COALESCE(sum(i.bytes),0) FROM step_result s JOIN image i ON i.uuid = s.image_uuid WHERE s.session_uuid = se.uuid) AS bytes
FROM session se
WHERE se.synced_at IS NOT NULL
  AND se.finished_at IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM step_result s JOIN image i ON i.uuid = s.image_uuid
                  WHERE s.session_uuid = se.uuid AND i.uploaded_at IS NULL)
  AND se.finished_at < strftime('%Y-%m-%dT%H:%M:%fZ','now', '-' || (SELECT retention_days FROM policy_cache WHERE id = 1) || ' days')
ORDER BY CASE se.verdict WHEN 'PASS' THEN 0 ELSE 1 END, se.finished_at;

-- Low-space tier: synced PASS-step images of synced sessions (oldest first) — purged before anything else
CREATE VIEW IF NOT EXISTS v_low_space_candidates AS
SELECT i.uuid AS image_uuid, i.bytes, se.finished_at
FROM image i JOIN step_result s ON s.image_uuid = i.uuid JOIN session se ON se.uuid = s.session_uuid
WHERE se.synced_at IS NOT NULL AND i.uploaded_at IS NOT NULL AND s.human_result = 'PASS'
ORDER BY se.finished_at;

-- FR-17: history with search fields
CREATE VIEW IF NOT EXISTS v_history AS
SELECT se.uuid, se.started_at, se.finished_at, se.verdict, se.sku, se.lot, se.checklist_id, se.checklist_version,
       se.user_id, se.synced_at IS NOT NULL AS synced,
       (SELECT count(*) FROM step_result s WHERE s.session_uuid = se.uuid) AS steps_done,
       c.step_count,
       (SELECT count(*) FROM step_result s WHERE s.session_uuid = se.uuid AND s.human_result = 'FAIL') AS fail_steps
FROM session se JOIN checklist_cache c ON c.checklist_id = se.checklist_id AND c.version = se.checklist_version;

-- Per-session summary incl. undecided steps and model/human disagreements (AI-07)
CREATE VIEW IF NOT EXISTS v_session_summary AS
SELECT se.uuid, se.verdict, se.finished_at, se.synced_at,
       count(s.uuid) AS steps,
       sum(CASE WHEN s.kind IN ('photo_ai','photo','measure','check') AND s.human_result IS NULL THEN 1 ELSE 0 END) AS undecided_steps,
       sum(CASE WHEN s.suggested_result = 'REVIEW' THEN 1 ELSE 0 END) AS review_steps,
       sum(CASE WHEN s.suggested_result IN ('PASS','FAIL') AND s.human_result IS NOT NULL AND s.human_result <> s.suggested_result THEN 1 ELSE 0 END) AS overrides,
       sum(CASE WHEN s.kind = 'photo_ai' AND s.model_version IS NULL THEN 1 ELSE 0 END) AS manual_mode_steps
FROM session se LEFT JOIN step_result s ON s.session_uuid = se.uuid
GROUP BY se.uuid;

CREATE VIEW IF NOT EXISTS v_active_models AS
SELECT name, version, task, sha256, size_bytes, selftest_passed_at, json_extract(selftest_json,'$.latency_p95_ms') AS latency_p95_ms
FROM model_asset WHERE active = 1;

CREATE VIEW IF NOT EXISTS v_storage AS
SELECT (SELECT count(*) FROM session) AS sessions,
       (SELECT count(*) FROM image) AS images,
       (SELECT COALESCE(sum(bytes),0) FROM image) AS image_bytes,
       (SELECT COALESCE(sum(bytes),0) FROM image WHERE uploaded_at IS NULL) AS image_bytes_not_uploaded,
       (SELECT COALESCE(sum(size_bytes),0) FROM model_asset) AS model_bytes;

INSERT OR IGNORE INTO schema_version (version, notes) VALUES (1, 'PocketQC v1.0 — DDS-05');
