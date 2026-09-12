# API Specification — EdgeGuard Node-Local API and Client Contracts

| Field | Value |
|---|---|
| Document ID | API-03-EdgeGuard |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **19 paths / 19 operations**, validated with `openapi-spec-validator` |
| Related | [SAD-03](../docs/SAD-EdgeGuard-Software-Architecture.md) · [DDS-03](../docs/DDS-EdgeGuard-Local-Store-Design.md) · [ICD-03](../docs/ICD-EdgeGuard-Interface-Control.md) · [SEC-03](../docs/SEC-EdgeGuard-Security-Requirements.md) · [API-01](../../01-factory-inspector-agent/api/API-Specification.md) (the server the node talks to) |

---

## 1. What this API is — and is not

An EdgeGuard node has **two API relationships**, and it is important not to confuse them:

| | Node-local API (this spec, §2–§8) | IF-01 client contract (§9) |
|---|---|---|
| Role of the node | **Server** | **Client** |
| Bound to | `127.0.0.1:8080` and `unix:///run/edgeguard/api.sock` | Outbound HTTPS to the central |
| Consumers | Kiosk HMI on the same device; technician via SSH tunnel; `edgectl` | VisionOps (01) or FactoryBrain (00) — identical paths and schemas |
| Purpose | See the node, correct a verdict (PIN), maintain it | Deliver records, images, heartbeat; pull config and models |
| Authoritative spec | `openapi.yaml` `paths` | `openapi.yaml` `x-client-contracts` + copied schemas; server-side truth is API-01 |

The node **never** exposes a LAN-reachable HTTP port (ADR-E10, SEC-E10). A fleet administrator sees nodes through the central's `/edge/nodes`, not by connecting to them.

## 2. Conventions

| Topic | Rule |
|---|---|
| Base path | `/api/v1` |
| Formats | JSON; RFC 3339 timestamps **with offset** (node local time); UUIDs as strings |
| Errors | RFC 7807 `application/problem+json`, `type` = `urn:edgeguard:problem:<slug>`, stable `code` (§7) |
| Pagination | Cursor, `limit` ≤ 500 (default 50), ordered `ts DESC, id DESC` |
| Idempotency | `Idempotency-Key` on `POST /records/{id}/override`; replay returns the original 201 for 24 h |
| Rate limits | PIN endpoints 5/min then 15-min lockout; everything else unlimited on loopback (the HMI polls `/status` at 2 Hz) |
| Versioning | `/v1`; additive changes only; the HMI and API ship in the same image, so skew is impossible by construction |
| Availability | `/status` and `/healthz` answer in every state, including FAULT — they are how you learn *why* it is FAULT |

## 3. The fail-safe contract

The most important guarantee of this API is what it **does not** do:

- `GET /status.ready` **mirrors** `v_ready` (DDS-03 §5). The supervisor process drives the PLC READY output from the same view, independently of this API. The API being down, slow or wrong cannot change the line's state.
- No endpoint can raise READY. `POST /fault/clear` acknowledges a *latched* fault; if the cause is still present the fault manager re-raises it in the same call and the response says so (`still_active`).
- `POST /records/{id}/override` never re-pulses the PLC. The part is gone; the override corrects the record and trains the model.
- `POST /inspect` (lab only) pulses the PLC only with `pulse_plc: true`, and is a hard 403 unless `node.yaml` enables it.

## 4. Authentication and authorisation

| Tier | Header | Who | Endpoints |
|---|---|---|---|
| None | — | Anyone on loopback (the HMI) | `GET /status`, `/healthz`, `/counters`, `/records*`, `/config`, `/models`, `/sync/status` |
| Technician token | `X-Tech-Token` | Maintenance technician, `edgectl` | `/config/apply`, `/models/*/activate`, `/models/*/rollback`, `/selftest`, `/calibration/check`, `/diagnostics/bundle`, `/sync/flush`, `/inspect` |
| Supervisor PIN | `X-Override-Pin` | Line inspector / supervisor at the kiosk | `/records/{id}/override`, `/fault/clear` |

- **Token**: issued by `edgectl token issue` at provisioning or by a fleet admin (via config bundle); 24 h lifetime; stored as an Argon2 hash in `/etc/edgeguard/secrets/tech.hash` (0600); rotated per maintenance visit.
- **PIN**: 6 digits, Argon2 hash in `/etc/edgeguard/secrets/pin.hash` (0600), distributed to named supervisors; every attempt (success or failure) is a `node_event` with `user_ref`; 5 attempts/min, then a 15-min lockout that also shows on the HMI.
- **"None" is safe only because of the binding.** Read endpoints expose lot numbers and verdicts; binding to a LAN interface would be a data exposure — TEST-03 TC-084 verifies the port is unreachable from the LAN.

## 5. Endpoint groups

### 5.1 Status — what the HMI shows
`GET /status` is the node in one object: `ready`/`blocking`/`alarms` (the fault manager), camera, models (active/previous/shadow with disagreement count), calibration, **buffer** (`v_backlog`), disk, thermal, sync, last verdict, versions. The example in the spec is the seed's end-of-shift state: 150 unsynced records, 16 queued images, alarm `config:SYNC_TARGET_UNREACHABLE`, still READY.

`GET /counters` serves the shift counters from `shift_counter` plus `effective_counts` with overrides applied — the HMI shows both so an inspector sees the effect of their overrides.

### 5.2 Records — the local store, read-only except override
`GET /records` and `/records/{id}` read the buffer; `GET /records/{id}/image` streams a cached evidence image. Rows purged by policy are **404 here and 200 on the central** — the HMI says "on server" rather than "not found" when `synced_at` is known.

`POST /records/{id}/override` (PIN) writes an `override` row with `user_ref` and `reason_code`, queues it for sync, and returns 409 if the new verdict equals the current *effective* verdict.

### 5.3 Config and models — the OTA surface, from the node's side
- `GET /config` returns the applied bundle, its ETag, its `source` (`central | usb | node_yaml`) and `ignored_fields` — the top-level keys the node did not understand (superset tolerance, SAD-03 §6).
- `POST /config/apply` applies a **signed** bundle from a file for air-gapped sites; the same validator as the central pull; atomic.
- `GET /models` lists the cache with `stage`, `verified_at`, engine state and shadow progress.
- `POST /models/{name}/{version}/activate` executes a promotion the central already decided; guards: verified, engine ready, shadow ≥ `shadow_min_frames` unless `skip_shadow` (logged).
- `POST /models/{name}/rollback` swaps active/previous **offline**.

### 5.4 Maintenance
`POST /selftest` runs the boot routine on demand and returns per-stage latency — the fastest way to see whether capture, inference or storage is the slow stage. `POST /calibration/check` measures a gauge block and reports error % against tolerance without writing anything. `POST /diagnostics/bundle` produces the redacted support archive (§8). `POST /fault/clear` (PIN) acknowledges latched faults.

### 5.5 Sync
`GET /sync/status` is the store-and-forward engine's state: target, state, backoff, backlog, image window, last batch outcome, config ETag, heartbeat. `POST /sync/flush` drains now, ignoring backoff and the image window.

### 5.6 Lab
`POST /inspect` is the software trigger TEST-03 uses through the lab compose (camera replay + PLC simulator). Production nodes return 403 `LAB_DISABLED`.

## 6. Status-code semantics
| Code | Meaning here |
|---|---|
| 200 / 201 / 202 | OK / override or resource created / long action started (`diagnostics/bundle`, `sync/flush`) |
| 401 | `TECH_TOKEN_REQUIRED` or `PIN_REQUIRED` — the PIN response includes attempts remaining |
| 403 | `LAB_DISABLED` |
| 404 | Not in the **local** store |
| 409 | State conflict — model not ready, no previous model, no calibration, same verdict, sync target unreachable |
| 422 | Validation — including `CONFIG_INVALID` with the exact reason |
| 429 | PIN lockout, `Retry-After` |
| 503 | Blocking fault prevents the action (`FAULT_ACTIVE`), or store unreadable on `/healthz` |

## 7. Error catalogue

| `code` | HTTP | When | Operator/technician action |
|---|---|---|---|
| `TECH_TOKEN_REQUIRED` | 401 | Missing/expired technician token | `edgectl token issue` |
| `PIN_REQUIRED` | 401 | Missing or wrong PIN | Retry; after 5, wait 15 min |
| `PIN_LOCKED` | 429 | Lockout active | Wait; fleet admin can reset via bundle |
| `LAB_DISABLED` | 403 | `/inspect` on a production node | Expected |
| `FAULT_ACTIVE` | 503 | Self-test or inspect while a blocking fault is set | Fix the fault (`/status.blocking`) |
| `RECORD_NOT_LOCAL` | 404 | Purged or never here | Look on the central |
| `SAME_VERDICT` | 409 | Override equals effective verdict | No action |
| `CONFIG_INVALID` | 422 | Schema/signature/class-map failure | Detail names the recipe and class; previous config still active |
| `MODEL_NOT_CACHED` | 404 | Activate/rollback of unknown version | Wait for pull or apply bundle |
| `MODEL_NOT_VERIFIED` | 409 | sha256 not yet verified | Check download; see `node_event` |
| `ENGINE_BUILDING` | 409 | TensorRT engine still compiling | Wait (≤ 10 min on Orin Nano); status in `/models` |
| `SHADOW_INCOMPLETE` | 409 | Shadow frames < minimum | Wait or `skip_shadow` (commissioning only) |
| `NO_PREVIOUS_MODEL` | 409 | Rollback with nothing to roll back to | Apply a bundle with the wanted version |
| `CALIBRATION_STALE` | 409 | Calibration invalid / fingerprint mismatch | Recalibrate on the central; OPS RB-06 |
| `SYNC_TARGET_UNREACHABLE` | 409 | Flush while central unreachable | Fix network; OPS RB-07 |
| `DISK_RESERVE` | (alarm) | Free % below reserve; PASS images disabled | OPS RB-08 |
| `THERMAL_THROTTLE` | (alarm) | Clocks reduced | OPS RB-10 |
| `STORE_UNREADABLE` | 503 | `/healthz` cannot open the store | Watchdog restarts; OPS RB-11 |

Alarm codes also appear verbatim in `/status.blocking` / `.alarms` as `source:CODE`.

## 8. Diagnostics bundle — what is and is not in it
**In**: last 24 h of service logs, `node_event`, `/status` snapshot, `/models`, `/config` (bundle *metadata*, not the signed payload), calibration metadata, thermal history, the last 20 FAIL overlay images, `v_backlog`.
**Out (SEC-E52)**: everything under `/etc/edgeguard/secrets/`, certificates and keys, PIN/token hashes, PASS images, OCR text (lot numbers are redacted to their last 4 characters).

## 9. Client contracts — the node as an IF-01 client

The schemas `InspectionCreate`, `BatchResult`, `NodeHealth`, `ModelManifest`, `EdgeConfig` (and their dependencies `Verdict`, `Detection`, `Measurement`, `AnomalyResult`, `RecipeRules`, `Problem`) are **copied verbatim from API-01** and verified identical by a structural diff (TEST-03 TC-008). If API-01 changes, this file must change with it — the diff is the tripwire.

| Contract | Node behaviour (full detail in ICD-03 §IF-01) |
|---|---|
| `POST /edge/records:batch` | Batches of ≤ 500, FAIL/REVIEW first (`sync_queue.priority`); on 207 each item: `accepted`/`duplicate` → `mark_synced`; `rejected` → keep, `attempts+1`, alarm after 5 (`stuck`) |
| `POST /edge/images` | Only after the record is synced; in the image window; sha256 verified server-side; 422 → re-hash and retry once, then stuck |
| `GET /edge/config` | Every 5 min with `If-None-Match`; 304 → nothing; 200 → validate → atomic apply; unknown top-level keys ignored and listed |
| `POST /edge/heartbeat` | Every 60 s; `buffer_depth` = unsynced records; `model_versions` includes shadow progress; failure is not a fault |
| Auth | mTLS with the per-node certificate (CN = `node_code`), or `X-Edge-Key` where mTLS is impossible |
| Backoff | 1 s → ×2 → 300 s max, ±20 % jitter; reset on any 2xx/207 |

The node cannot tell whether its target is VisionOps or FactoryBrain, and does not need to (SAD-03 §6).

## 10. Traceability
| SRS-03 | Endpoint |
|---|---|
| FR-01 software trigger mode | `/inspect` (lab/commissioning) |
| FR-15 HMI live verdict, counters | `/status`, `/counters`, `/records` |
| FR-17 override with user id and reason | `/records/{id}/override` |
| FR-18 connection status, buffer depth, model version, last sync | `/status.buffer`, `.models`, `.sync`, `/sync/status` |
| FR-19 degraded mode visible | `/status.blocking`, `.alarms` |
| FR-22 config pull, atomic apply | `/config`, `/config/apply` |
| FR-23/24 model shadow, promote, rollback | `/models`, `activate`, `rollback` |
| FR-25 health every 60 s | `NodeHealth` client contract; `/sync/status.heartbeat` |
| AI-04 shadow ≥ 200 frames before promotion | `SHADOW_INCOMPLETE` guard on `activate` |
| AI-07 fall back to previous, alarm | `rollback`; `model:LOAD_FAILED` in `/status.blocking` |
| NFR-05 cold boot self-test | `/selftest` (same routine as boot) |
| NFR-06 watchdog | `/healthz` |
| NFR-07 TLS, node identity, rotatable keys | §9 auth row |
| NFR-09 provisioning without a developer | `/config/apply` (air-gapped bundle) |
| NFR-10 diagnostics without shell access | `/status`, `/selftest`, `/diagnostics/bundle` |
| C-01 offline | every endpoint works with no central |
| C-02 no raw image leaves without policy | `/edge/images` client behaviour (window, sampling) |
