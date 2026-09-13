# Database Design Specification — PocketQC On-Device Database

| Field | Value |
|---|---|
| Document ID | DDS-05-PocketQC |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-05 §5](../SRS-PocketQC-Offline-Mobile-Inspector.md), [SAD-05 §4.3.5–4.3.9, §4.6](SAD-PocketQC-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) (SQLite, executed) · [`db/seed_demo.sql`](../db/seed_demo.sql) (executed) · [`db/payload_mapping.json`](../db/payload_mapping.json) (verified) |
| Engine | **SQLite 3.40+ via Drift**, **SQLCipher** at rest — not PostgreSQL |
| Verification | **Executed** with Python `sqlite3`: schema (17 tables, 7 views, 13 indexes, 6 triggers), seed (51 sessions, 1,006 steps, 804 images), every header value read back, 11 constraint probes rejected; payload mapping checked against API-00 and the executed schema |

---

## 1. Introduction

### 1.1 Purpose
The physical design of the database inside the PocketQC app: the record of every inspection an inspector performs — with the model's suggestion and the inspector's judgement side by side — the queue that carries it to the platform, and the caches (checklists, SKUs, defect codes, models, policy) that let the app work with no network for weeks.

It shares its *shape* with EdgeGuard's local store ([DDS-03](../../03-edge-vision-inspection/docs/DDS-EdgeGuard-Local-Store-Design.md)): a buffer that is authoritative until the platform acknowledges, UUIDv7 client ids, records-then-images sync, purge that can never touch unsynced rows. It differs in what it protects: **a person's judgement** (FR-11, FR-19) and **a device that will be lost** (C-05).

### 1.2 Why SQLite via Drift with SQLCipher (ADR-M01)
| Consideration | Choice |
|---|---|
| Typed Dart access, migrations, reactive queries for the UI | Drift |
| Encryption at rest (NFR-05) | SQLCipher (AES-256, page-level); key from Android Keystore (IF-35) |
| One transaction for "step + image row + queue entry + current_step" (FR-16) | one database file |
| Crash on a dropped phone mid-write | WAL + `synchronous = FULL` |
| No daemon, no ops | SQLite |

### 1.3 Engine settings

```sql
-- applied by the app on open, in this order
PRAGMA key = '<32-byte key from Keystore, hex>';   -- SQLCipher; never in code, prefs or logs (IF-35)
PRAGMA cipher_page_size = 4096;
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = FULL;        -- durability over write speed: a phone is dropped mid-transaction
PRAGMA foreign_keys = ON;
PRAGMA secure_delete = ON;         -- purged pages are overwritten (encrypted anyway; belt-and-braces)
PRAGMA busy_timeout = 5000;
```
`schema.sql` carries everything except `PRAGMA key`/`cipher_page_size`, which is why it executes on plain SQLite (a strict subset of SQLCipher). `synchronous = FULL` is the opposite choice from EdgeGuard's `NORMAL`: here there is no PLC pulse to protect and a few ms per step do not matter, so the extra fsync is free safety.

### 1.4 Access model
One app process. The UI writes through Drift on the main isolate; the sync worker (WorkManager, may run without UI) opens the same file. Drift serialises writes; readers never block. There is no other reader — no export, no backup (Android backup disabled, SEC-M43).

---

## 2. Design principles

Platform DD-01…DD-08 where they apply; EdgeGuard's DD-E01…E05 in spirit. PocketQC adds:

| ID | Principle | Enforced by |
|---|---|---|
| **DD-M01** | **Every step commits before the UI advances.** `step_result` + `image` row + `session.current_step` in one transaction; navigation only after commit. | Application transaction boundary (ADR-M02); `current_step` column; resume = read it |
| **DD-M02** | **The model never decides.** `suggested_result` (model/rule) and `human_result` (inspector) are separate columns; a session cannot finish while any judged step lacks a human result. | `trg_session_finish_requires_decisions`; both columns synced (AI-07) |
| **DD-M03** | **Unsynced rows are untouchable.** `synced_at` is set only by sync on `accepted`/`duplicate`; purge views exclude unsynced sessions and images not yet uploaded by construction. | `v_purge_candidates`, `v_low_space_candidates` |
| **DD-M04** | **A model runs only after verification and a self-test on this device.** At most one active and one previous per name. | `trg_model_activate_requires_selftest`, `trg_model_insert_requires_selftest`, `ux_model_active/previous`, `size_bytes ≤ 25 MB` CHECK (C-02) |
| **DD-M05** | **Re-judging is a supervisor act with an audit row.** A finished session's verdict cannot change without a `rejudge` audit event; audit is append-only. | `trg_session_rejudge_requires_audit`, `trg_audit_append_only_*` |
| **DD-M06** | **An image row never points at a missing file.** The encrypted file is written first; the row carries the plaintext `sha256` the server verifies. | Application order; `image.sha256` NOT NULL; `ON DELETE RESTRICT` from steps |
| **DD-M07** | **Secrets are never in this database.** Tokens and the PIN hash live in secure storage; the DB holds *references*. | `auth_state.token_ref`, `supervisor_pin_ref` |

Naming: `snake_case`; ISO-8601 text timestamps **with offset** for captured data (device local time) and `Z` for sync bookkeeping; booleans as `INTEGER CHECK IN (0,1)`; JSON as `TEXT` with `_json` suffix; UUIDs as `TEXT`.

---

## 3. Table overview

| Group | Tables | Rows | Purpose |
|---|---|---|---|
| Device & config (1 row each) | `device_info`, `auth_state`, `policy_cache`, `bootstrap_state` | 1 | Who/where; cached login window; policy; ETag and last sync |
| Master-data caches (server wins) | `checklist_cache`, `sku_cache`, `defect_code_cache` | tens | Replaced atomically at bootstrap |
| Models | `model_asset` | few | OTA state: verified → self-tested → active/previous |
| **Records (the buffer)** | `session`, `step_result`, `image`, `measurement` | thousands | What syncs |
| Sync | `sync_queue`, `sync_log` | | Records first, images second; history |
| Accountability | `audit_event` (append-only), `purge_log` | | PIN, re-judge, wipe, purge |
| Meta | `schema_version` | 1 | Drift migration stamp |

**17 tables, 7 views, 13 explicit indexes, 6 triggers** — executed and counted.

### 3.1 ERD

```
device_info(1)  auth_state(1)  policy_cache(1)  bootstrap_state(1)      model_asset (active|previous; self-test gated)

checklist_cache (id, version) ──< session ──< step_result ──< measurement
sku_cache ─(default checklist)         │  uuid = UUIDv7          │  suggested_result · human_result
defect_code_cache ─────────────────────│─────────────────────────┘  defect_code
                                       │  current_step · synced_at        │
                                       │                                  └──> image (encrypted file, sha256, uploaded_at)
sync_queue (session | image, priority) · sync_log · audit_event (append-only) · purge_log

VIEWS: v_pending_sync · v_purge_candidates · v_low_space_candidates · v_history · v_session_summary · v_active_models · v_storage
```

---

## 4. Table specifications

### 4.1 Device and configuration
- `device_info` — `device_id` from managed configuration (not the hardware serial), model, SDK, app/schema versions, the **cached delegate probe** (`nnapi | gpu | cpu`, ADR-M04), language, server URL. Single row (`CHECK (id = 1)`) — also the seed's re-run guard.
- `auth_state` — the logged-in user, role, `online_login_at`, **`offline_valid_until`** (FR-27) and *references* to the token and supervisor PIN hash in secure storage (DD-M07).
- `policy_cache` — the `/mobile/policy` payload: retention days, sync network, image compression, PASS-image upload, GPS toggle, offline days, low-space thresholds, **`wipe_requested`** (FR-28).
- `bootstrap_state` — bootstrap ETag, `last_sync_ok_at` (the "last successful sync" the UI shows, FR-24).

### 4.2 Master-data caches
Versioned checklists (`definition_json` validated against [`deploy/schemas/checklist.schema.json`](../deploy/schemas/checklist.schema.json) before insert; `sku_pattern` for auto-selection), SKUs with a default checklist (FR-08), defect codes with TH/JA/EN names and default severity. Replaced as a whole inside one transaction when the bootstrap ETag changes — **server wins** (FR-23); a session in progress keeps the version it started with (`session.checklist_version`).

### 4.3 `model_asset`
Per (name, version): `sha256`, `size_bytes` (≤ 25 MB, C-02), path, class map, `verified_at` (checksum matched), **`selftest_passed_at`** and `selftest_json` (recall on bundled samples, latency p95, delegate — on *this* device), `active`, `previous`. Activation is impossible without both timestamps (triggers); one active and one previous per name (partial unique indexes). The seed holds the instructive case: `1.1.0` downloaded, verified, **self-test failed** (recall 0.80), not active; `1.0.0` stays active.

### 4.4 `session` — one checklist run
`uuid` (client UUIDv7 = server dedup key), checklist id + **version**, SKU, lot, `started_at`/`finished_at`, `verdict`, **`current_step`** (FR-16), user, device, language, optional GPS, note, and sync bookkeeping (`synced_at`, `sync_attempts`, `last_sync_error`). `CHECK ((finished_at IS NULL) = (verdict IS NULL))`: finished ⇔ verdict present.

### 4.5 `step_result` — the heart of the design
| Column | Notes |
|---|---|
| `kind` | `photo_ai · photo · barcode · ocr · measure · check` |
| `model_name`, `model_version` | Which model judged this step (FR-12); `NULL` = manual mode (AI-08) |
| `model_result_json` | Detections / OCR raw / barcode raw / marker data — the evidence |
| **`suggested_result`** | What the model or rule proposed: `PASS · FAIL · REVIEW` |
| **`human_result`** | What the inspector decided: `PASS · FAIL` — never `REVIEW` (a person decides) |
| `decided_at`, `note`, `defect_code`, `severity` | The judgement's context (FR-15) |
| `text_value`, `text_raw` | OCR: corrected and raw (FR-07 one-tap correction); barcode: parsed |
| `image_uuid` | `ON DELETE RESTRICT` — an image with a step cannot be deleted |
| `latency_ms` | AI-03 diagnostics |

`UNIQUE (session_uuid, step_no)`; `human_result ⇒ decided_at`; a defect code on a PASS step needs a severity (a noted, accepted minor mark).

### 4.6 `image`
Encrypted file path, plaintext `sha256`, dimensions, bytes, capture time, torch state (FR-05), quality metrics (FR-02), chosen burst index (FR-03), **`upload_offset`** (resumable upload progress) and `uploaded_at`.

### 4.7 `measurement`
Per measure step: name, value, unit, `usl`/`lsl`, **`tolerance`** (± from marker size and distance, AI-05), `in_spec`, `method` (`aruco_reference | fixed_distance | manual`), marker id, px/mm.

### 4.8 Sync and accountability
- `sync_queue`: `session` rows at priority 1, `image` rows at priority 5 (records first, ADR-M06); attempts/backoff; `UNIQUE (entity, entity_uuid)`.
- `sync_log`: one row per sync operation with counts, bytes, duration, detail.
- `audit_event` (append-only): logins (online/offline), PIN ok/fail, **re-judge**, model activate/rollback, self-test failed, purge, wipe; synced to the platform.
- `purge_log`: what was freed and why.

---

## 5. Views

| View | Purpose | Guarantee |
|---|---|---|
| **`v_pending_sync`** | The FR-24 counter: sessions pending, in progress, images pending (only for already-synced sessions), bytes, stuck, last sync | One query for the status bar |
| **`v_purge_candidates`** | Synced sessions past retention whose images are all uploaded | **Never an unsynced session, never one with a pending image** (DD-M03) |
| `v_low_space_candidates` | PASS-step images of synced+uploaded sessions, oldest first | Purged first below 10 % free (SAD §4.4.8) |
| `v_history` | FR-17 search fields: lot, SKU, date, verdict, synced, progress | |
| `v_session_summary` | steps, undecided, review, **overrides** (model ≠ human), manual-mode steps | AI-07 source |
| `v_active_models` | Active model per name with self-test latency | |
| `v_storage` | Counts and bytes for the low-space logic | |

---

## 6. Payload mapping — local → IF-11 → platform

[`db/payload_mapping.json`](../db/payload_mapping.json) maps the local tables to the platform's `MobileSession` (API-00, verbatim) and to the proposed typed `MobileSessionStep` (API-05). Verified (TEST-05 TC-006): **0 required fields unmapped, 0 properties unmapped, 0 mapped fields outside the contract, 0 dangling local column references.** Never sent: `current_step`, sync bookkeeping, encrypted paths, upload offsets, quality metrics, burst index, marker internals.

Server landing (SAD-05 §6): one `vision.inspection` row per `photo_ai` step with `source = 'mobile'`; `vision.measurement` per measurement; a `vision.verdict_override` whenever `human_result ≠ suggested_result` — the retraining signal (AI-07).

---

## 7. Sizing, storage and encryption

| Item | Typical | NFR-04 target |
|---|---|---|
| Session + 20 steps + 3 measurements | ~25 KB | 5,000 sessions ≈ 125 MB DB |
| Images (1600 px, q85) | ~180–230 KB each; 16/session ≈ 3.3 MB | 20 GB ≈ 6,000 sessions of images |
| Models | ≤ 25 MB each; 2 versions × 2 models ≈ 75 MB | within the 200 MB install (models are OTA, not bundled) |

Encryption: SQLCipher for the DB; each image file AES-256-GCM with a random data key wrapped by an Android Keystore key (StrongBox when present) — a copied `files/` tree is useless without the device (ADR-M05, IF-35). Thumbnails are encrypted too. `secure_delete` overwrites freed pages.

Retention (FR-30): synced sessions older than `retention_days` (default 60) are purged with their images; low-space tiers at 20 % (warn, compress harder) and 10 % (purge synced PASS images first; single capture only). Unsynced data is never purged — the app warns and stops burst capture instead.

---

## 8. Recovery, wipe, migration
- **Crash / kill**: WAL recovery on open; `session.current_step` is the resume point; a step is either fully present or absent (DD-M01).
- **Corruption**: `PRAGMA quick_check` on open; failure → the file is moved aside (still encrypted), a fresh DB is created, the event is synced; the aside file can be handed to support with the device's Keystore-wrapped key export **only through the MDM channel** (OPS-05 RB-13).
- **Remote wipe** (FR-28): DB file, image directory, Keystore aliases and secure-storage entries are deleted; `purge_log` cannot survive (by design); acknowledgement is posted before deletion of the network credentials.
- **Migrations**: Drift schema versions, forward-only, in a transaction; additive columns nullable.

---

## 9. Demo and test dataset

[`db/seed_demo.sql`](../db/seed_demo.sql) models **tablet TAB-07 on 2026-09-11 — AC-01 exactly: 50 complete inspections in airplane mode** with the 20-step `RAD-500-A-incoming v3` (SRS Appendix A, completed to 20 steps), then the first Wi-Fi contact on 09-12. Every acceptance criterion has rows:

| Rows | Model |
|---|---|
| 50 finished sessions (PASS 43 / FAIL 7) | AC-01; FAIL by model agreement (7, 18, 26), by human override of a missed defect (33, 41, 49), by supervisor re-judge (22) |
| 3 REVIEW steps decided by the inspector | FR-10 |
| 8 overrides (5 false alarms, 3 missed defects) | FR-11, AI-07 |
| 1 in-progress session at step 7 of 20 | AC-03 |
| 5 OCR one-tap corrections (`L26O911` → `L260911`) | FR-07 |
| 1 measurement out of spec (session 18, fin height 16.9 > 16.5) | FR-09 |
| Sessions 1–30 synced; images of 1–25 uploaded; 80 images pending; 20 sessions unsynced | AC-02 in flight, FR-20, FR-24 |
| Model `1.1.0` downloaded, verified, **self-test failed**, not active | FR-26, AI-06 |
| Supervisor PIN re-judge with two audit rows, **performed by the seed through the trigger** | FR-19 |

**Executed results** (Python `sqlite3`, in-memory, 0.02 s):

| Check | Value |
|---|---|
| `integrity_check` / `foreign_key_check` | ok / clean |
| Sessions | 51 = 50 finished (43 PASS / 7 FAIL) + 1 in progress (`current_step` 7, 6 steps done) |
| Step results / measurements / images | 1,006 / 150 / 804 |
| Review steps / overrides / manual-mode steps / undecided in finished | 3 / 8 / 0 / **0** |
| Synced / unsynced finished | 30 / 20 |
| Images uploaded / not | 400 / 404 |
| `v_pending_sync` | sessions 20 · in progress 1 · images 80 (16.35 MB) · stuck 0 · last ok 07:34:40Z |
| `sync_queue` | 20 at priority 1, 80 at priority 5 |
| `v_purge_candidates` / unsynced rows in it | 0 / **0** |
| `v_low_space_candidates` (all synced + uploaded + PASS) | 397 ✓ |
| Models | 4: active 2, previous 1, self-test failed 1 |
| Audit / sync log / purge log / checklists / SKUs / defect codes | 6 / 5 / 0 / 3 / 12 / 15 |
| Session 22 after re-judge | `FAIL`, note "re-judged by supervisor sup-01" |

**Constraint probes** (each rejected): finish a session with an undecided REVIEW step; second active model per name; activate the model whose self-test failed; insert an active model without self-test; model > 25 MB; change a finished session's verdict without an audit row; update / delete an audit row; delete an image referenced by a step; finished session without verdict; second `device_info` row.

First-draft mistakes caught by execution and fixed: the header counted 806 images (the in-progress session has 4 image steps, not 6) and guessed 375 low-space candidates (397).

---

## 10. Traceability

| SRS-05 | Implemented by |
|---|---|
| §5 data model | `session`, `step_result`, `image`, `measurement`, `sync_queue`, `model_asset` — names kept; columns extended |
| FR-02, FR-03, FR-05 | `image.quality_json`, `burst_index`, `torch_on` |
| FR-04 | `session.user_id/device_id/gps_*`, `step_result.created_at` |
| FR-07 | `step_result.text_value/text_raw` |
| FR-09, AI-05 | `measurement` |
| FR-10, FR-11, AI-07 | DD-M02, `v_session_summary.overrides` |
| FR-12 | `step_result.model_version` |
| FR-13 | `checklist_cache` |
| FR-16 | DD-M01, `session.current_step` |
| FR-17 | `v_history` |
| FR-19 | DD-M05 |
| FR-20, FR-21 | `sync_queue`, `image.upload_offset` |
| FR-22, FR-23 | caches, server-wins replacement, `checklist_version` on session |
| FR-24 | `v_pending_sync`, `bootstrap_state.last_sync_ok_at` |
| FR-25 | `policy_cache.image_*` |
| FR-26, AI-06 | DD-M04 |
| FR-27 | `auth_state.offline_valid_until` |
| FR-28 | `policy_cache.wipe_requested`, §8 |
| FR-30 | `v_purge_candidates`, `purge_log` |
| AI-03 | `step_result.latency_ms`, `model_asset.selftest_json` |
| AI-08 | `model_version NULL`, `v_session_summary.manual_mode_steps` |
| C-02 | `size_bytes` CHECK |
| C-05, NFR-05 | §1.3, §7 |
| NFR-04 | §7 |
| AC-01…AC-03, AC-07 | seed §9 |

## Appendix A — The constraints that carry the weight
| Constraint | Protects against |
|---|---|
| `trg_session_finish_requires_decisions` | A session "finished" with the model's opinion standing in for the inspector's |
| `trg_session_rejudge_requires_audit` + append-only audit | Silent alteration of a recorded judgement |
| `trg_model_*_requires_selftest`, `ux_model_active` | Running an unverified or device-unfit model; ambiguous rollback |
| `v_purge_candidates` predicates | Losing unsynced work to disk pressure |
| `image` `ON DELETE RESTRICT` | A step whose evidence vanished |
| `(finished_at IS NULL) = (verdict IS NULL)` | A finished session without a verdict, or a verdict on an open one |
| `size_bytes ≤ 25 MB` | Breaking the install budget by OTA |
