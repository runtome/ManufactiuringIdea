# Database Design Specification — EdgeGuard Node Local Store

| Field | Value |
|---|---|
| Document ID | DDS-03-EdgeGuard |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-03 §5](../SRS-EdgeGuard-Edge-Vision-Inspection.md), [SAD-03 §4.3.3, §4.6](SAD-EdgeGuard-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) (SQLite) · [`db/seed_demo.sql`](../db/seed_demo.sql) · [`db/payload_mapping.json`](../db/payload_mapping.json) |
| Engine | **SQLite 3.40+**, WAL mode — not PostgreSQL |
| Verification | **Executed.** Schema and seed run in-process with Python `sqlite3`; every expected value below was read back, and the payload mapping was checked against `01/api/openapi.yaml` |

---

## 1. Introduction

### 1.1 Purpose
The physical design of the **local store** on an EdgeGuard node: the buffer that holds every inspection until the central platform acknowledges it, plus the caches (config, models, calibration) and node state that let the node run with no server at all.

This is a different kind of database from the three Postgres designs in this repository. It has one writer, lives on a Jetson's SSD, must survive a power cut mid-transaction, and is **authoritative only until sync** — after which the server row is the truth and the local copy is disposable (SAD-03 P-4).

### 1.2 Why SQLite (ADR-E01)
| Consideration | SQLite (WAL) | Embedded PostgreSQL |
|---|---|---|
| Daemon to run, patch, monitor | none | yes |
| Survives power loss | by design (WAL journal) | yes, with more configuration |
| Backup | copy one file (or `VACUUM INTO`) | `pg_dump` |
| Footprint on 8 GB Jetson | ~0 | 100+ MB RAM, CPU |
| Concurrent readers while writing | yes (WAL) | yes |
| Multiple writers | serialised — **we want one writer anyway** | yes |
| Types | dynamic; UUID is `TEXT` | rich |

The one thing SQLite lacks — server-side types — is compensated by verifying the record shape against the IF-01 contract programmatically (§6) rather than relying on column types.

### 1.3 Engine settings and their reasoning

```sql
PRAGMA journal_mode = WAL;      -- readers never block the single writer; atomic commit
PRAGMA synchronous  = NORMAL;   -- see below
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA page_size    = 4096;
```

**`synchronous = NORMAL` is a deliberate durability trade-off.** With WAL it guarantees consistency after an OS crash and durability after each checkpoint; a *power cut* can lose the last few milliseconds of un-checkpointed WAL. That window is precisely the one in which **no PLC pulse has been sent yet** (ADR-E03: the pulse follows the commit), so a lost record never had a pulsed verdict and the part is simply re-presented. `FULL` would fsync every commit and roughly double SSD write amplification for no gain in the property that matters. Checkpoints run every 1,000 pages or 30 s, whichever first.

### 1.4 Access model (ADR-E02)
| Process | Access |
|---|---|
| `store` | **Only writer.** Owns the connection with write access; exposes `commit_inspection`, `mark_synced`, `record_event`, `purge` over a Unix socket |
| `hmi`, `sync`, `metrics`, `api` | Read-only connections (`?mode=ro`); `sync` asks `store` to mark rows, never writes |

One writer is not a limitation to work around — it is the design that keeps the verdict commit from ever waiting on a sync update.

---

## 2. Design principles

Platform DD-01…DD-08 apply where they make sense on a device. EdgeGuard adds:

| ID | Principle | Rationale |
|---|---|---|
| **DD-E01** | **The record is the source of the pulse.** A verdict is pulsed to the PLC only after its row is committed. | Line and data agree after any crash: a pulsed verdict always has a record; a lost record never pulsed (ADR-E03). |
| **DD-E02** | **Unsynced rows are untouchable.** `synced_at` is set only by `store.mark_synced` on an `accepted`/`duplicate` outcome; the purge view excludes unsynced rows by construction. | "No data loss" is a property of the schema, not of an application flag being remembered (ADR-E09). |
| **DD-E03** | **Caches are validated before use, and the previous version is kept.** `model_cache` cannot mark a model `active`/`shadow` without `verified_at` (trigger); at most one `active` and one `previous` per model (partial unique indexes). | An unverified artefact never runs; rollback works offline (ADR-E07, SEC-E30). |
| **DD-E04** | **Local bookkeeping columns are never sent.** The payload is a projection; `synced_at`, paths, attempts, frame ids stay local. | The central sees the contract, not the node's internals (§6). |
| **DD-E05** | **The store is a buffer.** Synced rows are purged by policy; the node never edits a synced row. | The server is the truth after acknowledgement (P-4). |

Naming: `snake_case`; ISO-8601 text timestamps with offset (`strftime` defaults for local bookkeeping); booleans as `INTEGER CHECK (x IN (0,1))`; JSON as `TEXT` with a `_json` suffix.

---

## 3. Table overview

| Group | Tables | Purpose |
|---|---|---|
| Identity | `node_info` (1 row) | Who this node is; sync URL; versions |
| **Records** | `inspection`, `detection`, `measurement`, `anomaly_score`, `override` | The buffer — what gets synced |
| Queues | `sync_queue`, `image_queue` | What is due to be sent, with priority and backoff |
| Caches | `config_cache` (1 row), `model_cache`, `calibration_cache` | What the central told us; validated; previous kept |
| State | `fault_state`, `disk_policy_state` (1 row), `heartbeat_log`, `shift_counter`, `node_event` | READY/FAULT truth, disk policy, HMI counters, audit |
| Meta | `schema_version` | Migration stamp |

**17 tables, 5 views, 14 explicit indexes, 3 triggers** — executed and counted.

### 3.1 ERD

```
node_info (1)     config_cache (1)     calibration_cache (per camera)     disk_policy_state (1)

model_cache ──(stage: active | previous | shadow | downloaded)   ux: one active, one previous, one shadow per name
      ▲ trigger: active/shadow require verified_at

inspection (id = client UUIDv7) ──< detection
    │  verdict · model_version   ──< measurement
    │  synced_at · attempts      ──< anomaly_score (1:1)
    │                            ──< override (PIN, user_ref, reason_code, synced_at)
    │                            ──< image_queue (kind, sha256, attempts)
    └──────────── sync_queue (entity, entity_id, priority, next_retry_at)

fault_state (source PK, blocks_ready) ──► v_ready
node_event · heartbeat_log · shift_counter

VIEWS: v_backlog · v_purge_candidates · v_effective_verdict · v_ready · v_active_models
```

---

## 4. Table specifications

### 4.1 `node_info`
Exactly one row (trigger `trg_node_info_single_row` aborts a second insert — this trigger is also the seed's re-seed guard). Holds `node_code` (= mTLS CN), line/station/plant codes, `app_version`, `schema_version`, `sync_url`, `lang`. Written at provisioning from `node.yaml`; `sync_url` is the only field that changes when the central moves from VisionOps to FactoryBrain.

### 4.2 `inspection` — the buffer

| Column | Notes |
|---|---|
| `id` | **Client-generated UUIDv7**, `TEXT` PK. The dedup key on the central (IF-01). |
| `ts` | RFC 3339 with offset — the capture time |
| `line`, `station`, `camera_id`, `sku`, `lot` | Identity; `line`/`sku` are **codes** resolved to ids by the central |
| `verdict` | `CHECK IN ('PASS','FAIL','REVIEW','NO_READ')` |
| `no_read_reason` | `BLUR / EXPOSURE / NO_PART / CALIBRATION_STALE` — local only; surfaced via heartbeat counters |
| `model_version`, `recipe_version` | Reproducibility: which model and rule set judged this part |
| `image_path`, `overlay_path`, `heatmap_path` | Local cache paths; `image_path` NULL when a PASS was sampled out |
| `image_sha256` | Sent with the record; verified by the central on upload |
| `frame_id`, `device_ts` | Camera chunk data — liveness evidence (frozen/replay detection) |
| **`synced_at`** | Set **only** by `store.mark_synced` after `accepted` or `duplicate`. Never by `sync` directly. |
| `sync_attempts`, `last_sync_error` | Backoff and diagnostics; a `rejected` outcome increments attempts and stores the reason |
| `image_synced_at` | Images upload after records, in the bandwidth window |

Child tables `detection`, `measurement`, `anomaly_score` cascade on delete (purge of a fully-synced record). `override` is `ON DELETE RESTRICT`: an inspection with a human decision is never purged before the override has synced.

### 4.3 `override`
A supervisor's decision at the node. `user_ref` is a badge/PIN-holder id (never a name — SEC-E50), `reason_code` from the same enum the central uses, `CHECK (old_verdict <> new_verdict)`. Synced as a verdict override; `synced_at` follows the same rule as inspections.

### 4.4 `sync_queue` and `image_queue`
`sync_queue` rows are created at commit with `priority` 1 (FAIL/REVIEW) or 5 (PASS); `attempts`/`next_retry_at` implement exponential backoff (1 s → 5 min). `UNIQUE (entity, entity_id)` makes enqueue idempotent. `image_queue` is separate and lower priority: `kind` ∈ original/overlay/heatmap, `sha256`, `bytes` (for bandwidth accounting), its own backoff. An image is queued only after its record exists; the central rejects an image for an unknown record.

### 4.5 `config_cache`, `model_cache`, `calibration_cache`
- `config_cache` (1 row): the last **validated** `EdgeConfig` bundle with its ETag and `source` (`central | usb | node_yaml`). Validation = JSON schema + every recipe class exists in the active model's `class_map`; an invalid bundle is not applied and the previous stays.
- `model_cache`: one row per artefact with `sha256`, `verified_at`, engine path/key, `stage`. Two constraints carry weight: **`trg_model_active_requires_verified`** + **`trg_model_insert_requires_verified`** (a row cannot become — or be born — `active`/`shadow` without verification; the INSERT half was missing until TC-003 probed it) and the partial unique indexes (**one `active`, one `previous`, one `shadow` per name**). `shadow_frames`/`shadow_disagree` accumulate the disagreement report the central reads via heartbeat.
- `calibration_cache`: per camera — version, method, scale/intrinsics, **`hardware_fingerprint`**, `valid`, `fingerprint_ok` (checked at boot against the live camera serial/lens/mount). `valid = 0` or `fingerprint_ok = 0` with a measurement rule active → `FAULT: CALIBRATION_STALE`.

### 4.6 State tables
- `fault_state`: one row per active fault source with `blocks_ready`. `v_ready` folds it into the READY decision — the **only** input the supervisor uses for the GPIO line (ADR-E05). Non-blocking rows are alarms (sync unreachable, thermal warning, disk reserve).
- `disk_policy_state` (1 row): totals, free %, reserve threshold, whether PASS images are currently stored, last purge.
- `heartbeat_log`: what was sent (or not) each minute — the local half of the fleet view.
- `shift_counter`: HMI counters per (date, shift, verdict), maintained by `store` at commit; cheap to read at 10 fps.
- `node_event`: boot (with cause and WAL recovery result), faults set/cleared, model/config/calibration changes, thermal, `store_recovered`, `pin_failed`, security. Synced to the central as `ops.node_event`.

---

## 5. Views

| View | Purpose | Guarantee |
|---|---|---|
| `v_backlog` | `buffer_depth` for the heartbeat: unsynced records/overrides, queued images and bytes, stuck records (≥ 5 attempts), oldest unsynced | One query, read by `sync` and `hmi` |
| **`v_purge_candidates`** | Synced rows with cached images, PASS first, oldest first, **excluding anything in `image_queue`** | **Never returns an unsynced row** — DD-E02 as a view, not a flag |
| `v_effective_verdict` | Model verdict with the latest local override applied | HMI counters reflect human decisions |
| `v_ready` | `ready` (0/1), `blocking` and `alarms` strings | The supervisor's single input for the READY line |
| `v_active_models` | Active model per name | Boot and self-test read this |

---

## 6. Payload mapping — local store → IF-01 → platform

The record shape is a **projection** of the IF-01 `InspectionCreate` contract (owned by [API-01](../../01-factory-inspector-agent/api/openapi.yaml), identical in [API-00](../../00-factorybrain-platform/api/openapi.yaml)). [`db/payload_mapping.json`](../db/payload_mapping.json) is the machine-readable mapping; the check in TEST-03 TC-006 loads the contract and asserts every property has a source.

| IF-01 field | Local source | Platform column |
|---|---|---|
| `id` | `inspection.id` | `vision.inspection.id` |
| `ts` | `inspection.ts` | `vision.inspection.ts` |
| `line`, `sku` | `inspection.line`, `.sku` (codes) | `line_id`, `sku_id` resolved by the central |
| `station`, `lot` | same | same |
| `verdict` | `inspection.verdict` | `vision.inspection.verdict` |
| `model_version` | `inspection.model_version` (`name:version`) | `model_id` resolved |
| `recipe_version` | `inspection.recipe_version` | `recipe_id` resolved (sku + version) |
| `latency_ms`, `ocr_text`, `source` | same | same |
| `image_sha256` | `inspection.image_sha256` | verified on `/edge/images` |
| `detections[]` | `detection` (class_name, confidence, bbox_json → bbox, area_mm2) | `vision.detection` |
| `measurements[]` | `measurement` (parameter, value, unit, usl, lsl) | `vision.measurement` |
| `anomaly` | `anomaly_score` (score, threshold, flagged) | `vision.anomaly_score` |

**Executed check result:** InspectionCreate has 4 required and 16 total properties; 0 required unmapped, 0 properties unmapped, 0 mapping entries outside the contract, 0 references to non-existent local columns.

Never sent: `created_at`, `synced_at`, `sync_attempts`, `last_sync_error`, `image_synced_at`, the three `*_path` columns, `frame_id`, `device_ts`, `no_read_reason`, `camera_id` (the central resolves the camera from node + station). `no_read_reason` is a candidate for contract v1.1; until then it travels as heartbeat quality-gate counters.

---

## 7. Sizing and storage wear

Per station at 2 parts/s triggered (the design centre), 16 h/day:

| Item | Per day | 72 h offline | Notes |
|---|---|---|---|
| `inspection` rows | ~115 k | ~350 k | ~600 B/row incl. indexes → ~210 MB |
| `detection` rows | ~5 k | ~15 k | FAIL/REVIEW only |
| FAIL/REVIEW images (~1.8 MB) | ~4.5 k × 1.8 MB ≈ 8 GB | ~24 GB | Always kept |
| PASS images at 2 % | ~2.2 k × 1.8 MB ≈ 4 GB | ~12 GB | First to be purged |
| WAL churn | ~0.3 GB | — | Checkpointed |

A 256 GB SSD holds 72 h with a comfortable reserve; **SD cards are not supported for the store** (write endurance). `synchronous=NORMAL` and PASS sampling are the two wear levers; the `disk_policy_state` reserve (`min_free_pct`, default 15) is the safety net.

### 7.1 On-node retention
| Data | Rule |
|---|---|
| Unsynced records, overrides, events | **Never purged** |
| Synced records | 30 days, then deleted (the server has them) |
| Synced FAIL/REVIEW images | 90 days locally, or on reserve pressure after all PASS images |
| Synced PASS images | Purged first, oldest first, when free % < reserve |
| Engines/models | Active + previous kept; others deleted |

---

## 8. Recovery and integrity

- **Boot**: `PRAGMA quick_check`; on failure the file is moved to `edgeguard.db.corrupt-<ts>`, a fresh store is created from `schema.sql`, and `fault_state('store','STORE_RECOVERED', blocks_ready=1)` is set until a technician acknowledges (RB-11) — the aside file is evidence, not garbage.
- **WAL recovery** is automatic on open. The seed's boot event models exactly this case.
- **Backup**: `VACUUM INTO '/backup/edgeguard-<ts>.db'` while running (readers safe); the unsynced rows are what matters — everything else is on the server.
- **Node replacement**: copy the store file to the replacement node; `sync` drains the unsynced rows under the *original* UUIDs, so the central deduplicates any that had already arrived (OPS RB-14).

---

## 9. Demo and test dataset

[`db/seed_demo.sql`](../db/seed_demo.sql) models **one node at the end of a shift with a sync backlog** — the scenario most tests need: node `L2-ST3`, 2026-09-10, 2,000 inspections at 30 s intervals, the central unreachable since 21:25.

Verdicts come from explicit position lists (40 FAIL, 12 REVIEW, 8 NO_READ). Sync state: `n ≤ 1850` synced, `n ≥ 1851` unsynced. Images cached for FAIL/REVIEW and 2 % of PASS (multiples of 50). Three overrides (one unsynced). Models: `1.0.0` active, `0.9.2` previous, `1.1.0` shadow at 84/200 frames. A non-blocking `SYNC_TARGET_UNREACHABLE` alarm; disk at 82 % used.

**Executed results** (Python `sqlite3`, in-memory, 0.07 s):

| Check | Value |
|---|---|
| `integrity_check` / `foreign_key_check` | ok / clean |
| Inspections | 2,000 — PASS 1,940 · FAIL 40 · REVIEW 12 · NO_READ 8 |
| Unsynced | 150 — FAIL 5 · REVIEW 2 · NO_READ 2 · PASS 141 |
| `v_backlog` | records 150 · overrides 1 · images 16 (29.5 MB) · stuck 0 · oldest 21:25:00 |
| `sync_queue` | 151 rows; 8 at priority 1 |
| Images cached / queued / purge candidates | 76 / 16 / 60 |
| `v_purge_candidates` containing an unsynced or queued row | **0 / 0** |
| Overrides / effective REVIEW | 3 / 9 |
| `v_ready` | `ready = 1`, alarm `config:SYNC_TARGET_UNREACHABLE`, nothing blocking |
| Model stages | active 2 · previous 1 · shadow 1 |
| Detections / measurements / anomaly | 52 / 50 / 200 |
| Re-seed | refused by the `node_info` trigger; row count unchanged |

The first draft of the seed's expected-values comment guessed 3/1/1/145 unsynced and 40 queued images; execution showed 5/2/2/141 and 16. The comment was corrected to the executed values — which is the argument for executing.

---

## 10. Schema evolution
`schema_version` stamps the file. Migrations are forward-only SQL scripts applied by `store` at boot before any other process opens the database, inside one transaction, with the pre-migration file copied aside first (`VACUUM INTO`). A migration that fails leaves the copy and sets `FAULT: STORE_RECOVERED`. Column additions are always nullable or defaulted so an older `sync` process can still read.

---

## 11. Traceability

| SRS-03 | Implemented by |
|---|---|
| FR-11 persist before ack | `inspection` commit; DD-E01 |
| FR-12 images FAIL/REVIEW always, PASS sampled | `image_path` rule, `image_queue`, `disk_policy_state.pass_images_enabled` |
| FR-13 disk policy: purge synced PASS first, never unsynced | `v_purge_candidates`, DD-E02 |
| FR-14 local audit log | `node_event` |
| FR-17 override queued for sync with user id and reason | `override` |
| FR-18 HMI shows buffer, version, last sync | `v_backlog`, `node_info`, `heartbeat_log` |
| FR-20 at-least-once, dedup by UUID | `inspection.id` UUIDv7; `synced_at` on `duplicate` |
| FR-21 images lower priority, window | `image_queue` |
| FR-22 config pull, atomic apply | `config_cache` (validated) |
| FR-23 model update: verify → shadow → promote | `model_cache` trigger, stages |
| FR-24 previous model kept, rollback | `ux_model_previous` |
| FR-25/26 heartbeat, health | `heartbeat_log`, `v_backlog` |
| AI-03 manifest sha256 | `model_cache.sha256`, `verified_at` |
| AI-07 fall back to previous on load failure | `previous` stage |
| NFR-04 72 h, 100 k records | §7 sizing |
| NFR-08 disk-full degrades, never stops | `disk_policy_state`, `v_purge_candidates` |
| C-01 offline | whole design |
| C-05 auto-recover | §8 |

---

## Appendix A — The constraints that carry the most weight

| Constraint | Protects against |
|---|---|
| `v_purge_candidates` excludes `synced_at IS NULL` and queued images | Losing an unacknowledged record to disk pressure |
| `trg_model_active_requires_verified`, `trg_model_insert_requires_verified` | Running an unverified model artefact — via UPDATE or INSERT |
| `ux_model_active` / `ux_model_previous` | Ambiguous rollback target |
| `override … ON DELETE RESTRICT` | Purging a part with a human decision before it synced |
| `trg_node_info_single_row` | A node with two identities (and accidental re-seeding) |
| `verdict` CHECK | A fifth, undefined verdict reaching the PLC map |
