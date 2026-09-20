# API Specification — GAPFarm AI (AI Farmer Agent)

| Field | Value |
|---|---|
| Document ID | API-12-GAPFarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-20 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1.0, **56 paths / 62 operations / 78 schemas** |
| Related | [SRS-12](../SRS-GAPFarm-AI-Farmer-Agent.md) §4.1 · [SAD-12](../docs/SAD-GAPFarm-Software-Architecture.md) §4.3 · [DDS-12](../docs/DDS-GAPFarm-Database-Design.md) §2 · [ICD-12](../docs/ICD-GAPFarm-Interface-Control.md) IF-63…IF-67 · [SEC-12](../docs/SEC-GAPFarm-Security-Requirements.md) · [TEST-12](../docs/TEST-GAPFarm-Test-Plan.md) TC-001, TC-008 · patterns from [API-00](../../00-factorybrain-platform/api/API-Specification.md) |

---

## 1. Scope and conventions
Base URL `https://<host>/api/v1`. JSON; multipart for `/diagnose` and photo upload. Bearer JWT (15 min) for people; `X-Device-Key` for sensors on `/telemetry`. `Accept-Language` `th` (default) or `en` — every `message_th` has an English twin server-side (NFR-08). Errors are RFC 7807 `application/problem+json` with a stable `code` (§9). `Cursor`/`Limit` pagination, `Idempotency-Key` on writes that a phone may retry (IF-63). `Problem`, `Cursor`, `Limit`, `IdempotencyKey` and the five standard responses are byte-identical to API-00 (TC-008: 9/9).

**SRS §4.1 mapping — nine paths verbatim** (TC-001: 9/9):

| SRS | Operation | Contract |
|---|---|---|
| `POST /diagnose` | `diagnose` | §3 |
| `POST /records/scouting` | `createScoutingRecord` | §4 |
| `POST /records/input-usage` | `createInputUsage` | §4 |
| `GET /zones/{id}/phi-status` | `getZonePhiStatus` | §4 |
| `GET /tasks?status=` | `listTasks` | §5 |
| `POST /telemetry` | `ingestTelemetry` | §6 |
| `GET /forecast/harvest?zone=` | `getHarvestForecast` | §6 |
| `POST /ask` | `ask` | §6 |
| `GET /export/gap?zone=&from=&to=` | `requestGapExport` | §8 |

---

## 2. Tags and paths
| Tag | Paths |
|---|---|
| diagnosis | `/diagnose`, `/observations`, `/observations/{id}`, `/observations/{id}/photos`, `/diagnoses/{id}`, `/diagnoses/{id}/confirm`, `/diagnoses/{id}/recommendations`, `/review-queue`, `/diagnoses/{id}/correction` |
| records | `/records/scouting`, `/records/input-usage`, `/zones/{id}/phi-status`, `/records`, `/records/{recordNo}`, `/records/{recordNo}/versions`, `/records/harvest`, `/records/harvest/{lotCode}/traceability`, `/zones/{id}/chain/verify` |
| tasks | `/tasks`, `/tasks/{id}`, `/tasks/{id}/complete`, `/escalations`, `/me/channels` |
| telemetry | `/telemetry`, `/sensors`, `/zones/{id}/telemetry`, `/farms/{id}/weather`, `/advisories`, `/zones/{id}/spray-check` |
| agent | `/ask`, `/forecast/harvest`, `/conversations/{id}`, `/farms/{id}/summary/weekly` |
| export | `/export/gap`, `/export/gap/{id}`, `/export/gap/{id}/verify`, `/farms/{id}/compliance-gaps` |
| farm | `/farms`, `/farms/{id}/zones`, `/crops` |
| sync / auth / privacy | `/sync`, `/auth/login`, `/auth/refresh`, `/devices`, `/privacy/requests`, `/privacy/requests/{id}` |
| admin | `/admin/products`, `/admin/products/{code}/approval`, `/admin/models`, `/admin/models/{id}/release`, `/admin/schemes/{code}`, `/admin/task-templates`, `/admin/risk-rules`, `/admin/config`, `POST /sensors` |
| system | `/healthz`, `/readyz` |

---

## 3. The diagnosis contract (FR-01…FR-08, AI-05, AI-06, C-04)
1. **Input.** 1–5 JPEGs ≤ 1 MB each (the client compresses — NFR-06), `zone_id` or `gps`, `taken_at`, optional plant counts and `client_observation_id` (UUIDv7 made offline; a repeat is idempotent). The server repeats the quality gate; failure is `422 PHOTO_QUALITY` with `guidance_th` ("ถ่ายใกล้ขึ้นอีก", "ถือให้นิ่ง", "หาแสงเพิ่ม").
2. **Output** is a `DiagnosisResult` (`deploy/schemas/diagnosis-result.schema.json`, IF-64):
   - `status: proposed` — 1–3 `candidates`, each `probability` (calibrated), `distinguishing_features_th`, `how_to_confirm_th`; `severity` as a level and a leaf-area band (FR-06); `consult_agronomist` when the top candidate is fast-spreading or the severity is severe (FR-29).
   - `status: needs_review` — same, plus `review.queued = true`; an agronomist will confirm or correct (FR-05).
   - `status: refused` — `ood = true`, `candidates: []`, guidance; **nothing is recorded** (AI-06, AC-02).
   - `202 DiagnosisQueued` — no model reachable: the observation and photos are stored, the diagnosis runs later (record-only mode, FR-08).
3. **Nothing becomes a record until `POST /diagnoses/{id}/confirm`.** `chosen` must be a candidate (`409 CHOSEN_NOT_CANDIDATE`). The response `ConfirmationResult` is Appendix A: `record_no` (`SC-2026-0412`), `tasks` with due dates, `reminders`, `recommendations` (approved products with PHI/REI/cautions and the spray check), `advisories`, `consult_agronomist`, and `card_th` — the rendered card.
4. **Device vs server.** A device result is uploaded as a diagnosis with `computed_on: device`; when the server re-scores and disagrees, the device diagnosis becomes `superseded` and the farmer is notified; a device diagnosis already confirmed keeps its record (the correction path applies).
5. **Corrections** (`POST /diagnoses/{id}/correction`, agronomists only — `409 REVIEWER_ROLE`) return the `label_example_id` (provenance for retraining, AI-09) and the record version they produced (AC-06).

---

## 4. The record contract (C-03, FR-09…FR-14, NFR-04)
- **Append-only versions.** Every record has `record_no` and `record_version`; `PUT`/`DELETE` do not exist. `POST /records/{recordNo}/versions` creates version + 1 with `reason_th` and `changes`; `GET /records/{recordNo}` returns every version, oldest first (AC-06). Each version carries `prev_hash`/`hash` from the zone's chain; `GET /zones/{id}/chain/verify` recomputes.
- **Input usage** (`POST /records/input-usage`): `product_code` must be approved at `ts` (`409 UNAPPROVED_PRODUCT`), `weather` must contain `temp_c`, `rh_pct`, `wind_ms` (`422 WEATHER_REQUIRED`), `ppe` non-empty (`422 PPE_REQUIRED`); PHI/REI are snapshotted; the response has `phi_clear_at` and a `spray_conflict` check (FR-25 — a warning; the farmer decides).
- **PHI** (`GET /zones/{id}/phi-status`): `clear`, `clear_at`, `blocking_record_no`, `blocking_product`, `days_remaining`, `message_th`. `POST /records/harvest` before `clear_at` is `409 PHI_NOT_ELAPSED` (AC-04); so is completing a harvest task.
- **Traceability** (`GET /records/harvest/{lot}/traceability`): zone, crop, planting date, `phi_clear_at`, inputs applied since planting and scouting events — each with its record hash (FR-12).
- **Routine scouting / record-only mode** (`POST /records/scouting`): a record without a diagnosis; with `diagnosis_id` it must be confirmed or corrected (`409 DIAGNOSIS_NOT_CONFIRMED`).

---

## 5. The task contract (FR-16…FR-20)
Tasks come from templates on confirmation (§3) or from sensor faults; `GET /tasks?status=open&owner=me` is the farmer's list (≤ 3 taps: open, tick, optional photo). `POST /tasks/{id}/complete` records who and when (device time when offline) plus evidence; harvest tasks obey PHI. Reminders are created with the task and already shifted out of quiet hours (FR-18); `PUT /me/channels` chooses LINE / push / Discord / e-mail. `GET /escalations` lists critical tasks overdue by more than the configured hours, addressed to the farm manager (FR-20).

---

## 6. The advisory and agent contract (FR-21…FR-32, AI-07, AI-08, C-02)
- **Telemetry** (`POST /telemetry`, device key): `unit` must match the sensor kind (`422 UNIT_MISMATCH`); out-of-range values are accepted with `quality = out_of_range` and counted (`TelemetryAck.out_of_range`). Faults appear on `GET /sensors` with their maintenance task (FR-22).
- **Weather** (`GET /farms/{id}/weather`): `available: false` means forecast-dependent advisories are suppressed with `suppressed_reason` — never computed on stale data (IF-12).
- **Advisories** (`GET /advisories`): disease risk (rule rows with their source in `factors`), spray conflict, irrigation (moisture slope, stage, rain), PHI, compliance gap. `GET /zones/{id}/spray-check?product=&planned_at=` answers `conflict: true|false|null` (`null` = no forecast covering the window, stated in `reason`).
- **Ask** (`POST /ask`): `Answer.products` are `Recommendation` objects from the approved list — an unapproved product cannot appear in `products` or in `text_th` (the database refuses the row — AC-08); `citations` reference crop-library chunks and record numbers; `consult_agronomist` per FR-29; `fallback: true` when the scripted answerer replied (FR-08). The text of the question is never sent to a third party.
- **Forecast** (`GET /forecast/harvest?zone=`): two `Forecast` objects. `status: ok` guarantees `low ≤ value ≤ high` (or the date triplet) **and** `factors`; `status: insufficient_data` guarantees no numbers and a `factors.reason` (AC-09).
- **Weekly summary** (`GET /farms/{id}/summary/weekly`): `text_th` rendered from `facts` — issues, treatments with PHI clear dates, harvests, open tasks, gaps, sensor faults (FR-32).

---

## 7. The sync contract (IF-63, C-01, NFR-02, AC-07)
`POST /sync` with `device_id`, `idempotency_key`, `items[]` (`observation` or `task_done`, each with a client UUIDv7). The server applies each item once and returns per-item `applied | exists | rejected`; **the same key again returns `replayed: true` and the stored result** — no second write, no error, so a phone can retry safely. Photos go through `POST /observations/{id}/photos` with `Content-Range` for resumption (`308` until complete). Conflicts: records are append-only (none possible); task status is last-writer-wins by device time.

---

## 8. The export contract (FR-13, FR-15, NFR-04, AC-05)
`GET /export/gap?zone=&from=&to=` returns `202` with an `ExportPackage` (`status: queued`); `GET /export/gap/{id}` gives signed URLs for the PDF (scheme record templates, compliance gaps first), the XLSX (one sheet per record kind, every version) and `manifest.json` (`deploy/schemas/gap-export-manifest.schema.json`): every current record with its hash, the chain heads per zone, `record_count`, `gap_count`, and `verify_hash = sha256(manifest)`. `GET /export/gap/{id}/verify` recomputes the manifest hash and every record hash in the package and lists mismatches; an auditor can do the same offline (OPS-12 §10). `GET /farms/{id}/compliance-gaps` lists the gaps alone.

---

## 9. Error catalogue (`Problem.code`)
| Code | Status | Where |
|---|---|---|
| `PHOTO_QUALITY` | 422 | `/diagnose`, photo upload — guidance in `errors[]` |
| `DIAGNOSIS_SHAPE`, `UNCALIBRATED` | 422 | model result rejected by the database (DD-G04) — reported as `MODEL_RESULT_INVALID` to clients |
| `CHOSEN_NOT_CANDIDATE`, `DIAGNOSIS_STATE` | 409 | confirm |
| `REVIEWER_ROLE` | 409 | correction |
| `DIAGNOSIS_NOT_CONFIRMED` | 409 | scouting record citing an unconfirmed diagnosis |
| `UNAPPROVED_PRODUCT`, `UNAPPROVED_PRODUCT_MENTION` | 409 | input usage, recommendation, answer (C-02) |
| `PPE_REQUIRED`, `WEATHER_REQUIRED` | 422 | input usage |
| `PHI_NOT_ELAPSED` | 409 | harvest record, harvest task completion |
| `RECORD_IMMUTABLE`, `VERSION_NEEDS_SUPERSEDES`, `VERSION_CHAIN_BROKEN` | 409 | record versions |
| `UNIT_MISMATCH`, `UNKNOWN_SENSOR` | 422 | telemetry, sensor registration |
| `FORECAST_SHAPE` | 500 | internal — a forecast without an interval never reaches a client |
| `SYNC_REPLAY` | — | never surfaced: `/sync` returns the stored result instead |
| `APPROVAL_SELF`, `LABEL_REQUIRED`, `REASON_REQUIRED` | 409 | product approval |
| `RELEASE_GATE_FAILED`, `CALIBRATION_REQUIRED`, `DEVICE_MODEL_TOO_LARGE` | 409 | model release |
| `NOT_READY` | 503 | readiness |
| `VALIDATION_FAILED`, `UNAUTHORIZED`, `FORBIDDEN`, `NOT_FOUND`, `RATE_LIMITED` | 422/401/403/404/429 | platform responses (verbatim) |

---

## 10. Roles per operation (SEC-12 §5.7)
| Operation group | farmer | farm_manager | agronomist | auditor | admin |
|---|---|---|---|---|---|
| diagnose, observations, confirm, records create, tasks, sync, ask, channels | ✓ (own farm) | ✓ | ✓ | — | ✓ |
| review queue, correction | — | — | ✓ | — | ✓ |
| record versions (correction), harvest | ✓ | ✓ | ✓ | — | ✓ |
| export, verify, compliance gaps, records read, traceability, chain verify | ✓ | ✓ | ✓ | ✓ | ✓ |
| escalations, weekly summary, weather | ✓ (read) | ✓ | ✓ | — | ✓ |
| privacy requests | own | own | own | own | any |
| admin/* , register sensor, release model | — | — | — | — | ✓ |

Farm scoping is a predicate on `farm_member`, evaluated in the query, not by filtering the response (SEC-12 SEC-G20).
