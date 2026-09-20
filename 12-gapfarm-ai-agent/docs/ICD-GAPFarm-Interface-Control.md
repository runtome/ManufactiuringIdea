# Interface Control Document — GAPFarm AI (AI Farmer Agent)

| Field | Value |
|---|---|
| Document ID | ICD-12-GAPFarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-20 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-12](../SRS-GAPFarm-AI-Farmer-Agent.md) §4.2 · [SAD-12](SAD-GAPFarm-Software-Architecture.md) §4.2 |
| Related | [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) (IF-08, IF-09, IF-10, IF-12, IF-13, IF-14) · [ICD-05](../../05-offline-mobile-inspector/docs/ICD-PocketQC-Interface-Control.md) IF-31 · [ICD-07](../../07-ai-dog-finder/docs/ICD-PawTrace-Interface-Control.md) IF-40 · [API-12](../api/API-Specification.md) · [DDS-12](DDS-GAPFarm-Database-Design.md) · [SEC-12](SEC-GAPFarm-Security-Requirements.md) · [TEST-12](TEST-GAPFarm-Test-Plan.md) |

---

## 1. Interface register

`IF-xx` numbers are shared across the document set; IF-63…IF-67 are new here.

| ID | Interface | Direction | Criticality | Section |
|---|---|---|---|---|
| IF-08 | Discord (optional reminder channel) | out | low | [§IF-08](#if-08) |
| IF-09 | LLM runtime (Ollama) — explain and orchestrate only | internal | medium | [§IF-09](#if-09) |
| IF-10 | Object storage (photos, exports, labels, models) | internal | high | [§IF-10](#if-10) |
| **IF-12** | **Farm IoT (MQTT) and weather provider** | in / out | high | [§IF-12](#if-12) |
| IF-13 | SMTP / webhook | out | low | [§IF-13](#if-13) |
| IF-14 | Metrics | out | medium | [§IF-14](#if-14) |
| IF-31 | On-device inference pattern (TFLite) | in-app | high | [§IF-31](#if-31) |
| IF-40 | Push (FCM / Web Push) | out | medium | [§IF-40](#if-40) |
| **IF-63** | **Offline observation sync** | in | **critical** | [§IF-63](#if-63) |
| **IF-64** | **Diagnosis model contract** | in-process | **critical** | [§IF-64](#if-64) |
| **IF-65** | **Approved-input list and PHI contract** | in (admin) | **critical** | [§IF-65](#if-65) |
| **IF-66** | **GAP audit package** | out | high | [§IF-66](#if-66) |
| **IF-67** | **LINE Messaging API** | out | medium | [§IF-67](#if-67) |

Every third-party service (weather, LINE, Discord, push, SMTP) is optional at deploy time; OPS-12 §5 lists what degrades. Only the weather provider, the notification channels and push cross to the internet (SEC-12 O-6).

---

## IF-08 — Discord {#if-08}
Inherits [ICD-00 IF-08](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-08). Use here: reminders and escalations to a farm's channel (FR-18, FR-20) — statistics and task text only; never a photo, a location or a person's name. Quiet hours apply. Optional; LINE is primary (IF-67).

## IF-09 — LLM runtime {#if-09}
Inherits [ICD-00 IF-09](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-09). GAPFarm uses the model for **two things only** (AI-07): composing the Thai answer to `/ask` from a facts object, and rendering the weekly summary. Contract: `POST /api/chat` with the prompt in `deploy/prompts/answer.th.v1.md`, temperature ≤ 0.3, model ≤ 9 B (`deploy/gapfarm.yaml agent.model`), timeout 15 s. The facts object contains the approved products for the crop as the **only** product list; the answer's `products` must be a subset and its text is checked (`trg_answer_products`). **Rule-based fallback is mandatory** (SRS §2.3): when the runtime is unreachable or times out, `worker-agent` answers from templates (`fallback: true`) — the product list, PHI status, the next tasks and the agronomist line are all facts, so the fallback is complete for every FR-27 question class that is a lookup. Verification: TC-050 (fallback), TC-092 (injection).

## IF-10 — Object storage {#if-10}
Inherits [ICD-00 IF-10](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-10).

| Bucket | Content | Written by | Read via |
|---|---|---|---|
| `photos` | `<farm>/<observation>/<photo>.jpg` ≤ 1 MB, **EXIF-stripped** (location lives in the database row only), `thumb.jpg` 256 px | api | signed URL 15 min (NFR-06); farm members only |
| `exports` | `<export_id>/package.pdf`, `package.xlsx`, `manifest.json` | scheduler | signed URL 24 h; auditor and managers |
| `labels` | registered product labels (PDF) | admin | signed URL 24 h |
| `models` | `chili-v3/model.onnx`, `chili-v3-lite/model.tflite` + manifests | admin | server: internal; device: signed URL with sha256 in `Device.recommended_model` |
| `pdpa` | export packages for data requests | scheduler | signed URL 24 h to the requester only |

Rules: private ACL on every bucket (`mc anonymous set none`); refused-diagnosis photos expire after 30 d, PASS derivatives after 365 d, evidence photos of records are kept with the records (GAP); object keys carry no person id.

## IF-12 — Farm IoT and weather {#if-12}
Elaborates [ICD-00 IF-12](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-12) (which documents it "for completeness"; this is the implementing specification).

### IF-12.1 Sensors over MQTT (FR-21, FR-22, NFR-07)
| Item | Contract |
|---|---|
| Broker | Mosquitto 2 on the `sensors` network (`deploy/mosquitto/mosquitto.conf`); TLS 8883 for field devices; **per-device username/password** issued at `POST /sensors` (shown once); ACL: a device may publish only to its own topics and subscribe to nothing |
| Topic | `farm/{farm_code}/{zone_code}/{signal}` — `signal` ∈ `sensor_kind.code` (`soil_moisture`, `air_temp`, `air_rh`, `soil_ec`, `soil_ph`, `rain`) |
| Payload | `{"device": "SM-A1", "ts": "2026-09-20T09:00:00+07:00", "value": 26.0, "unit": "%"}` — `device` must be the registered `sensor.device_code`; `unit` must equal the kind's unit (`UNIT_MISMATCH` → dropped and counted); `ts` within ±10 min of broker time, otherwise stored with `quality = late` |
| Rate | 5–15 min per sensor; a device publishing > 1 msg/s is throttled |
| Buffering | `ingest-mqtt` writes to a local queue before the database and keeps ≥ 24 h (`BUFFER_HOURS`); Mosquitto persistence keeps QoS 1 messages while ingest is down |
| Validation | range per kind → `quality = out_of_range` (stored, counted); stuck (`stuck_readings` identical) and offline (> 60 min) → `sensor_fault` and a maintenance task (`detect_sensor_faults()` every 15 min) |
| Failure | broker down: devices buffer locally (their firmware); ingest down: broker persists; database down: ingest buffers to disk; **advice still works without sensors** (SRS §10) |
| Verification | TC-040 (unit mismatch), TC-041 (stuck / offline / range), TC-042 (24 h buffer) |

### IF-12.2 Weather provider (FR-23, FR-25)
| Item | Contract |
|---|---|
| Provider | Configurable (`weather.provider`: `open-meteo` default, `tmd` adapter); one call per farm per hour; key in a secret file |
| Request | farm `location` (point) → hourly forecast 48 h (rain mm, probability, temperature, RH, wind) and daily history (Tmax, Tmin, RH, rain) for GDD |
| Storage | `weather_forecast` (snapshots, never overwritten — the snapshot Appendix A saw is kept) and `weather_daily` (one row per day; own sensors override when present, `source = sensor`) |
| Cache | ≥ 30 min; last good snapshot served with `available: false` when the provider fails |
| **Suppression** | advisories that need a forecast (spray conflict, irrigation) are **not computed on stale data**: `spray_conflict()` returns `conflict = null, reason = "forecast unavailable"`; `evaluate_risk()` writes an `info` advisory "ไม่มีข้อมูลอากาศ"; GDD uses the last complete day only |
| Privacy | only the farm point leaves the system; no user id, no zone polygons |
| Verification | TC-045 (provider down → suppression), TC-044 (rainfast window) |

## IF-13 — SMTP and webhook {#if-13}
Inherits [ICD-00 IF-13](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-13). Uses: e-mail reminders (optional channel), export-ready notification to the auditor with a signed link, PDPA export package link, admin alerts (sensor offline > 24 h, model release). Recipient allow-list; no photos attached.

## IF-14 — Metrics {#if-14}
`/metrics` (internal network only): `gf_diagnosis_latency_seconds{path=server|device}`, `gf_diagnosis_total{status}`, `gf_ood_rate`, `gf_review_queue_depth`, `gf_review_age_seconds`, `gf_sync_lag_seconds`, `gf_sync_replays_total`, `gf_records_total{kind}`, `gf_chain_verify_failures_total`, `gf_phi_refusals_total`, `gf_unapproved_product_refusals_total`, `gf_sensor_faults_open{kind}`, `gf_ingest_buffer_depth`, `gf_weather_available`, `gf_reminders_sent_total{channel}`, `gf_reminders_failed_total{channel}`, `gf_escalations_total`, `gf_export_verifications_total{ok}`, `gf_model_fallback_total`, `gf_compliance_gaps_open`.

## IF-31 — On-device inference {#if-31}
Follows the pattern of [ICD-05 IF-31](../../05-offline-mobile-inspector/docs/ICD-PocketQC-Interface-Control.md#if-31): the same heads exported to TFLite int8, ≤ 25 MB (AI-04), downloaded with sha256 from `Device.recommended_model`; input 256 px; outputs the three heads + energy score; the device applies the calibration temperature and the OOD threshold from the manifest (IF-64) and produces the same `DiagnosisResult` shape with `computed_on: device`. Timing target ≤ 2 s on a 3 GB Android (NFR-01); the PWA uses TensorFlow.js/WebGL or WASM with the same artefact. Server re-scoring supersedes the device result when online (ADR-G02).

## IF-40 — Push {#if-40}
Inherits [ICD-07 IF-40](../../07-ai-dog-finder/docs/ICD-PawTrace-Interface-Control.md#if-40) (FCM for Android/Flutter, Web Push for the PWA; token references only). Payloads: task text, zone code, due time — never a photo, a location or a name. Quiet hours applied before sending.

---

## IF-63 — Offline observation sync {#if-63}
**Parties.** Phone app (PWA/Flutter) → `api` (`POST /sync`, `POST /observations/{id}/photos`). **SRS.** C-01, NFR-02, AC-07. **Pattern.** ICD-00 IF-11 (mobile sync), adapted.

| Item | Contract |
|---|---|
| Identity | every offline object gets a **client UUIDv7** at creation (observation, photo, task completion); the server never renumbers |
| Batch | `SyncBatch{device_id, idempotency_key, items[≤ 500]}`; `idempotency_key = <device_id>-<yyyy-mm-dd>-<seq>`; items are ordered by device time |
| Items | `observation` (zone, ts, kind, photo ids, counts, growth stage, followup_of) · `task_done` (task id, completed_at = device time, evidence) |
| Apply | `apply_sync_batch()` — each item once; `applied | exists | rejected`; the batch row stores the result |
| Replay | the same key → `200 {replayed: true, items: <stored>}`; a direct re-insert is `SYNC_REPLAY` in the database (probe P-14) |
| Photos | uploaded before or after the batch; `Content-Range` resumption; the observation is complete when all `photos_json` ids exist; diagnosis of a synced observation is queued server-side (`202 DiagnosisQueued`) unless the device already diagnosed it (then the device result is uploaded as a diagnosis with `computed_on: device`) |
| Conflicts | records are append-only (no conflict possible); task status last-writer-wins by device time; a task completed offline **after** it was cancelled server-side stays `cancelled` and the item returns `exists` |
| Timing | the app syncs within 5 min of reconnection (NFR-02) and on foreground; the server processes a 500-item batch in < 5 s |
| Clock | device time is stored as given; the server records `received_at`; a skew > 24 h is flagged in the audit log, not corrected |
| Security | bearer token of the device's user; a batch may only contain the user's farms' zones (`403`) |
| Verification | TC-060 (20 observations, airplane mode), TC-061 (replay), TC-062 (resumed photo), TC-063 (500-item batch) |

## IF-64 — Diagnosis model contract {#if-64}
**Parties.** `worker-vision` / on-device model → `api` → database. **SRS.** FR-01…FR-06, AI-01…AI-06. **Artefacts.** `deploy/schemas/diagnosis-result.schema.json`, `deploy/schemas/model-manifest.schema.json`, `deploy/models/*.manifest.json`, `deploy/examples/diagnosis-appendix-a.json`.

| Item | Contract |
|---|---|
| Model | one per crop family (AI-01) with three heads — crop, affected part, condition — and an energy-based OOD score; classes are `condition.code` rows |
| Quality gate | blur (variance of Laplacian, normalised), exposure (histogram), subject distance (leaf-area fraction); `pass=false` returns guidance in Thai and no candidates |
| Output | `DiagnosisResult`: ≤ 3 candidates ordered by calibrated probability, Σ ≤ 1, each with `distinguishing_features_th` and `how_to_confirm_th` from the crop library; severity level + leaf-area band; `ood`, `ood_score`; `model_version`, `calibration_version`, `computed_on` |
| Calibration | temperature scaling per model version (AI-05); the manifest carries the temperature, ECE (≤ 0.05) and the reliability bins; a model without an active calibration cannot be released (`trg_calibration_required`) |
| OOD | energy score above the manifest threshold ⇒ `ood: true`, zero candidates, status `refused` (AI-06, AC-02); the threshold is chosen on the field set (AUROC ≥ 0.90 required) |
| Release gate | a **field** evaluation (real phone photos, mixed lighting — AI-03) with top-1 ≥ 0.80 and top-3 ≥ 0.93 (AI-02); lab sets (PlantVillage) are recorded but never pass (`trg_eval_gate`); device artefacts ≤ 25 MB (AI-04) |
| Latency | server ≤ 8 s end-to-end on 4G including upload (NFR-01); device ≤ 2 s |
| Retraining | `label_example` rows from agronomist corrections with provenance (AI-09) feed the next field set and training run; a corrected class that is not in the model's classes triggers an admin alert |
| Verification | TC-010…TC-016, TC-080, TC-081 |

## IF-65 — Approved-input list and PHI contract {#if-65}
**Parties.** Admin → `api` → `input_product`. **SRS.** C-02, FR-10, FR-11, FR-25, FR-28, AI-07, AC-04, AC-08. **Artefacts.** `deploy/schemas/input-product.schema.json`, `deploy/inputs/approved-products.example.yaml`.

| Item | Contract |
|---|---|
| Source of truth | `input_product` rows — the **only** product names the UI shows and the agent may say |
| Fields | code, trade name (+ Thai), active ingredient, type, **PHI days, REI hours, rainfast hours**, MRL per crop with source, target conditions, crops, cautions, **label URI** |
| Approval | `approved = true` needs the label URI and a second person (`approved_by ≠ author` — loader rule L-1, `trg_product_approval`); withdrawal needs a reason; approval time is kept so a usage at `ts` is checked against the list *as it was* |
| Use | recommendations, input-usage records and answers reference products by code; PHI/REI are snapshotted into the usage row; `phi_clear_at = ts + phi_days` |
| Deference | the app shows the label link and the caution text with every recommendation; doses are shown as "per label" ranges typed by the admin, never computed; the agronomist line (FR-29) is always present for severe cases |
| Rainfast | `spray_conflict()` uses `rainfast_hours` against the forecast (FR-25) |
| Change control | list version in the file header; import is an admin action audited with a diff; a product removed from the list keeps its historical usages |
| Verification | TC-006 (schema + 14 negatives + L-1), TC-021…TC-024, TC-050, TC-092 |

## IF-66 — GAP audit package {#if-66}
**Parties.** `scheduler` → object storage → auditor. **SRS.** FR-13, FR-15, NFR-04, AC-05. **Artefacts.** `deploy/schemas/gap-export-manifest.schema.json`, `deploy/examples/export-manifest.example.json`, `deploy/schemes/thaigap.example.yaml`.

| Item | Contract |
|---|---|
| Package | `package.pdf` — cover (farm, scheme, period, zones, chain heads, verify hash), compliance gaps first, then one section per record kind in the scheme's template order, every **current** version with its hash, an appendix of superseded versions with reasons; `package.xlsx` — one sheet per kind, every version, plus `chain` and `gaps` sheets; `manifest.json` |
| Manifest | `{scheme, period_from, period_to, zone_id, record_count, gap_count, chain_heads{zone: {seq, hash}}, records[{kind, record_no, version, zone, at, hash}]}`; `verify_hash = sha256(jsonb canonical text)` |
| Verification | `GET /export/gap/{id}/verify`; offline: recompute `sha256(prev_hash ‖ payload)` for each chain row exported in the XLSX `chain` sheet (OPS-12 §10 gives a 20-line Python script) |
| Mandatory records | from `gap_scheme_rule` (`mandatory`, `max_gap_days`); a gap is listed, never hidden |
| Language | Thai with English field names in parentheses (auditors of both schemes) |
| Retention | packages 5 y in object storage; the manifest also in `export_package.manifest_json` |
| Verification | TC-028, TC-029, TC-030 (mock audit checklist) |

## IF-67 — LINE Messaging API {#if-67}
**Parties.** `scheduler` → LINE Messaging API → farmer. **SRS.** FR-18, FR-20, C-05.

| Item | Contract |
|---|---|
| Channel | LINE Official Account; channel access token in a secret file; `notification_channel.address_ref = line:<userId>` obtained through LINE Login at `/auth/login` (`line_id_token`) |
| Messages | push messages (text + a flex card with the task, zone and due time; a "done" postback button); reminders, escalations, export-ready, weekly summary link |
| Content rules | Thai; **no photos, no coordinates, no names of other people**; a deep link into the app instead |
| Quiet hours | `reminder.scheduled_at` is already shifted (`trg_reminder_quiet_hours`); the sender never sends inside quiet hours even for retries |
| Errors | 429 → backoff and retry ≤ 3 over 30 min; invalid userId → channel disabled and the farmer is told in-app; delivery failure never blocks the originating write (task, record) |
| Webhook | inbound postbacks (`done`, `snooze 1h`) verified by the LINE signature; `done` completes the task through the same rules as `/tasks/{id}/complete` (PHI applies) |
| Verification | TC-033 (quiet hours), TC-034 (postback done obeys PHI), TC-091 (signature) |

---

## 2. Client notes (PWA / Flutter)
Local store: observations, photos (compressed), records created locally, tasks, the approved list, crop library, the last known PHI status and forecast per zone; the on-device model artefact. Everything user-facing is Thai first (NFR-08). Camera guidance before capture (gate). Install ≤ 150 MB including one crop-family model (NFR-03).

## 3. Interface change control
| Artefact | Owner | Process |
|---|---|---|
| Diagnosis result schema, model manifests | ML owner | version in `model_version`; a schema change is a minor API version; old device models keep working until retired |
| Approved-input list | farm admin + second approver | list version; audited import with a diff; label URI mandatory |
| Scheme definitions | compliance owner | version; templates and rules as data; re-export of an old period uses the scheme version in force then (`export_package.scheme_code` + scheme version in the manifest) |
| Prompts | agent owner | `deploy/prompts/*.v1.md`; a change re-runs the adversarial set (TC-092) before deploy |
| Risk rules, task templates | agronomist | editable in the admin UI; every rule has a source |
| MQTT topics / payload | integrator | additive only; a new signal kind is a `sensor_kind` row |

## 4. Traceability
| SRS | IF |
|---|---|
| FR-01…08, AI-01…06 | IF-64, IF-31 |
| FR-10, FR-11, FR-25, FR-28, C-02 | IF-65 |
| FR-13, FR-15, NFR-04 | IF-66 |
| FR-18, FR-20 | IF-67, IF-40, IF-08, IF-13 |
| FR-21…26, NFR-07 | IF-12 |
| FR-27, FR-32, AI-07 | IF-09 |
| C-01, NFR-02 | IF-63 |
| NFR-05, NFR-06 | IF-10 |
