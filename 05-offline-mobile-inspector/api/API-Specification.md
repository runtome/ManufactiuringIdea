# API Specification — PocketQC ↔ Platform Mobile Contract (IF-11)

| Field | Value |
|---|---|
| Document ID | API-05-PocketQC |
| Version | 1.0 (Draft) — describes IF-11 **v1.0 (as in API-00 today)** and **v1.1 (proposed)** |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **13 paths / 14 operations / 13 schemas**; validated; six schemas and two paths structurally identical to [API-00](../../00-factorybrain-platform/api/openapi.yaml) |
| Related | [SAD-05 §6](../docs/SAD-PocketQC-Software-Architecture.md) · [DDS-05 §6](../docs/DDS-PocketQC-Local-Database-Design.md) · [`db/payload_mapping.json`](../db/payload_mapping.json) · [ICD-05 IF-11](../docs/ICD-PocketQC-Interface-Control.md#if-11) · [ICD-00 IF-11](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-11) |

---

## 1. What this document is

PocketQC serves no API. This is the **server contract it consumes**, written from the client's side so that (a) the app's sync behaviour is specified against one exact shape, and (b) the platform team sees what SRS-05 §4.1 needs that API-00 does not yet have.

| Part | Source of truth | Status |
|---|---|---|
| `GET /mobile/bootstrap`, `POST /mobile/sessions:batch`; `MobileBootstrap`, `MobileSession`, `BatchResult`, `ModelManifest`, `Verdict`, `Problem` | API-00 — copied verbatim, diffed by TEST-05 TC-008 | **v1.0, implemented on the platform** |
| `/mobile/auth`, `/mobile/auth/refresh`, `/mobile/models`, `…/download`, `/mobile/images` (POST/PATCH/HEAD), `/mobile/policy`, `/mobile/devices/{id}/heartbeat`, `…/commands`, `…/ack`, `/mobile/audit:batch`; `MobileSessionStep`, `MobileMeasurement`, `MobileModelManifest`, `MobilePolicy`, `DeviceHeartbeat`, `DeviceCommand`, `MobileAuditEvent` | This document (`x-status: proposed`) | **v1.1 proposed** — a platform gap (README-05) |

`MobileSessionStep` is the typed shape PocketQC sends in `MobileSession.steps[]`; API-00 accepts any object there, so v1.1 is additive.

## 2. Conventions
| Topic | Rule |
|---|---|
| Base URL | From managed configuration (IF-33); HTTPS with certificate pinning (SEC-M30) |
| Auth | Bearer JWT from `/mobile/auth`; refresh token bound to `device_id`; **offline validity window** (default 30 days) governs local access when no refresh is possible (FR-27) |
| Ids | Client-generated **UUIDv7** for sessions, steps, images — the server's dedup keys (SAD-00 §5.7) |
| Timestamps | RFC 3339 **with the device's offset** for captured data; server records receipt time |
| Errors | RFC 7807 with stable `code` (§7) |
| Batches | `sessions:batch` ≤ 200; `audit:batch` ≤ 500; `207` per item |
| Caching | `If-None-Match` / `304` on bootstrap, models, policy |

## 3. The client's sync order and why

```
1. bootstrap   ETag → 304 or replace caches atomically (server wins — FR-23)
2. policy      retention / sync / wipe flag (a wipe is handled per §4 — flush first, then destroy)
3. sessions    finished, unsynced, oldest first, ≤ 200 → 207 → synced_at on accepted | duplicate
4. images      only for sessions now synced; resumable; sha256 verified; uploaded_at
5. models      manifests → download (ranged) → sha256 → self-test → activate | keep previous (FR-26)
6. audit       device audit events
7. heartbeat   pending counts, versions, storage, battery → may return commands
```
Records before images so a lost connection never leaves an image without its record; **images only for already-accepted sessions** so the server never holds an orphan file.

## 4. Remote wipe ordering — a deliberate choice
On a `wipe` command the app **first tries to flush pending sessions and their images** for up to 60 s (the data belongs to the company, not the thief), then acknowledges the command, then destroys DB, images, keys and tokens (FR-28). If the flush cannot complete, the wipe proceeds anyway — exposure risk outranks the unsynced records. Documented in SEC-05 §8 as a residual trade-off.

## 5. The conflict contract (FR-23) as the server sees it
| Data | Winner | Server behaviour |
|---|---|---|
| Checklists, SKUs, defect codes, models, policy | **Server** | Whatever the device cached is replaced at bootstrap; a running session keeps its `checklist_version` |
| Session, steps, measurements, `human_result` | **Device** | Stored as sent. A later server-side review is a `vision.verdict_override` linked to the record; the device's `human_result` is never modified |
| Duplicate session id | — | `duplicate` in the 207 — **success**; the device sets `synced_at` |
| Session referencing an unknown checklist version | — | `rejected` `CHECKLIST_UNKNOWN`; the device keeps it and re-bootstraps; stuck after 5 attempts |

## 6. Endpoints

| Endpoint | Purpose | Notes |
|---|---|---|
| `POST /mobile/auth` | Login; returns tokens + `offline_valid_until` | 403 `DEVICE_WIPED` / `DEVICE_NOT_ENROLLED` |
| `POST /mobile/auth/refresh` | Extend the window while online | |
| `GET /mobile/bootstrap` | Checklists, SKUs, defect codes, model manifests | ETag |
| `GET /mobile/models`, `GET …/download` | Manifests with `size_bytes ≤ 25 MB`, `samples_url` for the self-test; ranged download | Range/206 |
| `POST /mobile/sessions:batch` | The records | 207 |
| `POST /mobile/images`, `PATCH …/{id}`, `HEAD …/{id}` | Resumable image upload (tus-style: `Upload-Offset`) | 409 offset mismatch → HEAD and resume; 422 sha256 mismatch → discarded |
| `GET /mobile/policy` | Retention, sync network, image compression, GPS, offline days, low-space thresholds, wipe flag, allowed share targets | ETag |
| `POST /mobile/devices/{id}/heartbeat` | Fleet view; may return commands | |
| `GET …/commands`, `POST …/commands/{cid}/ack` | `wipe`, `force_relogin`, `force_bootstrap`, `rollback_model` | ack before destructive execution |
| `POST /mobile/audit:batch` | Device audit events (logins, PIN, re-judge, purge, wipe) | 207 |

## 7. Error catalogue (client-relevant)

| `code` | HTTP | Client action |
|---|---|---|
| `TOKEN_EXPIRED` | 401 | Refresh; if refresh fails and offline window valid → keep working offline; else re-login |
| `DEVICE_WIPED` / `DEVICE_NOT_ENROLLED` | 403 | Execute wipe (§4) / show "contact admin" |
| `CHECKLIST_UNKNOWN`, `SKU_UNKNOWN` | 207 item `rejected` | Re-bootstrap, retry; stuck after 5 |
| `SESSION_DUPLICATE` | 207 item `duplicate` | **Success** — mark synced |
| `UPLOAD_OFFSET_MISMATCH` | 409 | `HEAD`, resume from the server's offset |
| `CHECKSUM_MISMATCH` | 422 | Re-hash the local file; if it differs the file is corrupt → mark image stuck, keep the record |
| `IMAGE_TOO_LARGE` | 413 | Re-compress per policy and retry once |
| `MODEL_UNAVAILABLE` | 404 | Keep the active model |
| `RATE_LIMITED` | 429 | `Retry-After` |

## 8. Traceability
| SRS-05 | Contract |
|---|---|
| §4.1 six endpoints | all present (auth, bootstrap, models, sessions:batch, images, policy) + heartbeat/commands/audit |
| FR-20 | records first, images second; UUID dedup; resumable |
| FR-21 | policy `sync_network` |
| FR-22, FR-23 | bootstrap; §5 |
| FR-24 | heartbeat `pending`; local `v_pending_sync` |
| FR-25 | policy `image.*` |
| FR-26, AI-06 | `MobileModelManifest.sha256/samples_url/selftest` |
| FR-27 | `/mobile/auth` `offline_valid_until` |
| FR-28 | `wipe` command, §4 |
| FR-30 | policy `retention_days` |
| AI-07 | `MobileSessionStep.suggested_result` + `human_result` |
| FR-11 | `human_result` never altered by the server |
| C-04 | no inference endpoint exists in this contract |
