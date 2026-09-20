# Software Architecture Document — GAPFarm AI (AI Farmer Agent)

| Field | Value |
|---|---|
| Document ID | SAD-12-GAPFarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-20 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-12](../SRS-GAPFarm-AI-Farmer-Agent.md) |
| Related | [DDS-12](DDS-GAPFarm-Database-Design.md) · [API-12](../api/API-Specification.md) · [ICD-12](ICD-GAPFarm-Interface-Control.md) · [SEC-12](SEC-GAPFarm-Security-Requirements.md) · [TEST-12](TEST-GAPFarm-Test-Plan.md) · [OPS-12](OPS-GAPFarm-Deployment-Operations.md) · [UM-12](UM-GAPFarm-User-Admin-Guide.md) · patterns borrowed from [SAD-00](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) and [SAD-07](../../07-ai-dog-finder/docs/SAD-PawTrace-Software-Architecture.md) |

---

## 1. Introduction

### 1.1 Purpose
Define the architecture of GAPFarm AI: the AI extension of an existing farm-record application in which a farmer photographs an affected plant, the system classifies the likely disease, pest or deficiency **as calibrated probabilities**, and — this is the distinguishing idea (SRS §1.1) — *creates the scouting record, the task list, the reminder and the traceability entry that GAP certification requires* without further typing. Around that core sit sensor ingestion with fault detection, weather correlation and advisories, pre-harvest-interval (PHI) enforcement, a tamper-evident audit export, a Thai-first advisory agent restricted to an approved-input list, and an interpretable harvest prediction.

The document fixes the SRS's non-negotiables as architecture rather than as UI behaviour: the phone works offline (C-01), chemical recommendations come only from a curated list (C-02), records are append-only and versioned (C-03), diagnoses are probabilities with an agronomist path (C-04), Thai first (C-05).

### 1.2 What makes this project different from its siblings
GAPFarm has no factory, no production line and no quality department. Its users are farmers on low-end phones with intermittent 4G, a farm manager, an agronomist who reviews, and an auditor who wants a complete, tamper-evident file. Four consequences shape the design:

- **The record is the product.** A diagnosis that does not become a GAP record is a curiosity. Every confirmed diagnosis produces a scouting record, tasks and reminders *inside the same database transaction* (FR-09, FR-16, AC-03); a treatment produces an input-usage record with weather and PPE (FR-10); a harvest produces a lot with its traceability (FR-12). Records are never edited — a correction is a new version with the original retrievable (C-03, AC-06), and every version is hash-chained so an export can be verified (NFR-04).
- **Chemical advice is a lookup, not a generation.** The language model cannot name a product. Treatment options are rows of `input_product` with `approved = true`, PHI, re-entry interval and label cautions; the database refuses a recommendation, an input-usage record or an agent answer that names anything else (C-02, FR-28, AC-08, AI-07). The system defers to the label and to an agronomist (FR-29); it prescribes nothing.
- **PHI is a refusal, not a banner.** A harvest on a zone where any applied product's PHI has not elapsed is refused by the database (FR-11, AC-04). DDS-00 §12.1 already said this for the sibling set: *"the PHI block is a safety-relevant rule, not a warning banner"*.
- **Offline is the normal case.** Photos, records and task completions are created on the phone with client-generated identifiers and synced within five minutes of reconnection; an on-device model (≤ 25 MB) diagnoses without a network; with no model at all the app still records (C-01, FR-08, NFR-02, AI-04, AC-07).

### 1.3 Relationship to FactoryBrain
**Separate deployment** (SAD-00 §13 "none", README-00, ICD-00 IF-12 scope note). Own database in schema `farm` — the name DDS-00 §12.1 reserves — which **requires PostGIS** (the platform database does not) and uses pgvector only for the crop-library chunks the agent cites (FR-27). GAPFarm reuses the platform's *patterns* — RFC 7807 `Problem` (byte-identical), the UUIDv7 / `updated_at` helpers (byte-identical), the `audit.log` / `audit.auth_event` shape (identical modulo the user FK), signed-URL object storage (IF-10), the LLM runtime contract (IF-09), SMTP/webhook (IF-13), metrics (IF-14), the compose hardening — and shares nothing else. Placing farm data in a factory database would be a design error (SAD-00 §13 note 1). §9 records what transfers back.

### 1.4 Related documents
DDS-12 (schema, the append-only chain, PHI, the approved-list guards, the seed reproducing Appendix A and AC-02…AC-09), API-12 (diagnosis / record / task / advisory / sync / export contracts), ICD-12 (IF-12 farm IoT & weather elaborated; new IF-63 offline sync, IF-64 diagnosis model contract, IF-65 approved-input list & PHI, IF-66 GAP audit package, IF-67 LINE Messaging), SEC-12, TEST-12, OPS-12, UM-12.

---

## 2. Architecture principles

The platform principles, restated for a farm:

| # | Principle | In GAPFarm |
|---|---|---|
| P-1 | **The LLM never computes** | The classifier diagnoses; PHI, severity, GDD, disease risk, spray conflicts, moisture trends and the harvest interval are SQL/Python functions with tests; the model *explains* a facts object and *orchestrates* a conversation (AI-07). It never produces a probability, a date, a dose or a product name. Without it, every flow runs on a scripted fallback (FR-08). |
| P-2 | **Offline-first; degrade, never block** | On-device model, local queue, idempotent sync (NFR-02, AC-07). Server model unavailable → on-device; no model → record-only mode (FR-08). Weather unavailable → advisories that need a forecast are suppressed with a stated reason (IF-12), never computed on stale data. Sensors unavailable → advice still works (SRS §10). |
| P-3 | **Decision support; the farmer and the agronomist act** | Diagnoses are top-3 probabilities with distinguishing features and a "how to confirm" note (FR-03); low confidence asks for a better photo or escalates (FR-05); severe, unfamiliar or fast-spreading cases carry an explicit "consult an agronomist" (FR-29). Nothing is actuated (§1.2 out of scope). |
| P-4 | **The database is the source of truth — including for compliance** | Append-only versioned records with a hash chain, the PHI refusal, the approved-list guards, diagnosis shape rules, the review-queue rule, the model release gate: all triggers (DDS-12 DD-G01…G09). No API code path can produce a non-compliant record. |
| P-5 | **Domain knowledge is data, not code** | Approved inputs with PHI/REI/rainfast/MRL, GAP scheme templates and mandatory-record rules, task templates per diagnosis kind and severity, disease-risk rules, crop stage models: tables with authors and versions, editable by an admin, exportable (SRS §10 "scheme-configurable"). |
| P-6 | **Every diagnosis becomes a record** | Confirmation is the write that creates the scouting record, the task list and the reminders (FR-09, FR-16, AC-03). A refused (out-of-distribution) diagnosis creates nothing (AI-06, AC-02). |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-12 §2.4)
| ID | Constraint | Architectural consequence |
|---|---|---|
| C-01 | Low-end Android, intermittent 4G; core flows offline | PWA/Flutter client with a local store, client UUIDs, background sync (IF-63); on-device TFLite model ≤ 25 MB (AI-04); server does the rest |
| C-02 | Chemical recommendations only from the approved list | `input_product.approved` is the only source; guards on recommendation, input usage and agent answers (DD-G03); the LLM receives product rows as facts and cannot add to them |
| C-03 | Records append-only with audit trail; corrections are versions | `record_no + version` with `supersedes`, UPDATE/DELETE refused, hash chain (DD-G01, DD-G02) |
| C-04 | Diagnoses are probabilities with an agronomist path | Calibrated top-3 (AI-05), review queue (FR-05), agronomist correction loop (FR-07), "consult" flag (FR-29) |
| C-05 | Thai primary, English secondary | All user-facing strings, notifications and errors in `th` with `en` fallback (NFR-08); prompts in Thai; glossary |

### 3.2 Quality attributes
| Attribute | Requirement | Design response |
|---|---|---|
| Latency | Diagnosis ≤ 8 s on 4G (server) / ≤ 2 s on-device (NFR-01) | Compressed upload (≤ 1 MB per photo), GPU worker with CPU profile, on-device path measured on a 3 GB device |
| Offline | Sync within 5 min of reconnection (NFR-02) | Sync batches with idempotency keys; photo upload resumable; server reconciles by client id |
| Footprint | ≤ 150 MB install, 3 GB RAM (NFR-03) | PWA first; Flutter as an API client; one quantised model per crop family |
| Integrity | Tamper-evident records; export with a verification hash (NFR-04) | Hash chain per zone; export manifest carries the chain head; `/export/gap/verify` recomputes |
| Privacy | PDPA: identity and location protected, export/delete (NFR-05) | `agent_ro` cannot read identity or `farm.location`; data requests with erasure that pseudonymises authorship but keeps the record chain |
| Photos | Private, signed URLs, compressed (NFR-06) | Private buckets, 15-min URLs, derivatives only |
| Availability | ≥ 99 %; sensor buffer ≥ 24 h (NFR-07) | Single-host compose with restart policies; MQTT broker persistence; ingest buffers to disk |
| Cost | One small VPS for ≤ 20 farms (NFR-09) | CPU profile for everything; GPU optional; sizing in OPS-12 §3 |

### 3.3 Not drivers
Real-time actuation (out of scope, v1 advisory); multi-tenant SaaS scale; marketplace/accounting; a generic global disease model (AI-01 says start with the crops actually grown).

---

## 4. Views

### 4.1 Context view
```
 Farmer (Android PWA/Flutter) ── photos, records, tasks, questions ──►┐
 Farm manager (web) ── zones, PHI board, compliance, cost ───────────►│
 Agronomist (web) ── review queue, corrections ──────────────────────►│      GAPFarm AI
 GAP auditor (web/export) ── audit package, verify ─────────────────►│  ┌──────────────────────┐
 Admin ── crops, approved inputs, schemes, sensors, models ──────────►│  │ api · web · workers   │
                                                                      │  │ postgres (PostGIS,    │
 Soil/climate sensors ── MQTT (IF-12) ──────────────────────────────►│  │  pgvector) · minio    │
 Weather provider ◄── HTTPS, cached (IF-12) ───────────────────────►│  │ mosquitto · redis     │
 LINE Messaging (IF-67) / Discord (IF-08) / push (IF-40) ◄── reminders│  │ ollama (optional)     │
 Ollama (IF-09, optional) ◄── explain / orchestrate ─────────────────┘  └──────────────────────┘
```
Only three things cross to the internet: the weather provider, the notification channels and (optionally) push. The farm's photos, locations and records do not.

### 4.2 Container view
| Container | Responsibility | SRS |
|---|---|---|
| `web` | PWA: photo capture with the quality gate, local store, on-device inference (IF-31 pattern), task list, result cards, sync | FR-01, FR-04, FR-17, C-01, C-05 |
| `api` | Auth, sync endpoint, records, tasks, PHI status, export, ask, admin; the only container on the `frontend` and `egress` networks besides `scheduler` | §4.1 |
| `worker-vision` | Server-side quality gate, crop/part/condition heads, OOD score, temperature-scaling calibration, severity estimate (IF-64) | FR-02, FR-03, FR-05, FR-06, AI-01…06 |
| `worker-agent` | Facts assembly, scripted fallback, LLM explanation/orchestration, citations, weekly summary, harvest prediction | FR-27…32, AI-07, AI-08 |
| `ingest-mqtt` | Subscribes to `farm/+/+/+`, maps device → sensor → zone, validates units, buffers ≥ 24 h, inserts telemetry with `ingest_rw` | FR-21, NFR-07 |
| `mosquitto` | MQTT broker on the `sensors` network; per-device credentials; persistence | IF-12 |
| `scheduler` | Reminders with quiet hours, escalations, sensor-fault detection, weather refresh, risk/irrigation/spray advisories, compliance gaps, exports, retention, PDPA jobs | FR-18, FR-20, FR-22…26, FR-15, FR-32 |
| `postgres` | PostgreSQL 16 + PostGIS 3.4 + pgvector (built from `deploy/postgres/Dockerfile`) | §5 |
| `redis` | Queues, sync locks, rate limits | — |
| `minio` | Photos (private), exports | NFR-06 |
| `ollama` | Optional local model ≤ 9 B for Thai explanation | AI-07 |

### 4.3 Component view

#### 4.3.1 Photo intake and quality gate (`web`, `api`, `worker-vision` — FR-01, FR-04)
1–5 photos per observation. The client runs a cheap gate (Laplacian variance for blur, exposure histogram, subject-size heuristic) and gives specific guidance ("closer", "more light", "hold still") before upload; the server repeats the gate. Each photo is tagged with zone (from the GPS fix intersected with zone polygons — PostGIS `ST_Contains` — or the farmer's choice), GPS, timestamp and the zone's current growth stage (from the stage model, §4.3.8). Photos are compressed to ≤ 1 MB, EXIF location retained *only* in the database row, stripped from the stored file (NFR-05/06).

#### 4.3.2 Diagnosis (`worker-vision`, IF-64 — FR-02, FR-03, FR-05, FR-06, AI-01…06)
Per crop family a model with three heads — crop, affected part, condition — plus an OOD score (energy score on the condition head with a threshold calibrated on the field set). Output is a **diagnosis result** (`deploy/schemas/diagnosis-result.schema.json`): 1–3 candidates, each with a *calibrated* probability (temperature scaling — AI-05), `distinguishing_features` and `how_to_confirm` from the crop library; a severity estimate from the affected leaf-area fraction and the farmer's count of affected plants (FR-06); the model and calibration versions. Rules, enforced again in the database (DD-G04):
- `ood = true` → no candidates, status `refused`, the client says "not a plant / unknown crop — take a photo of the affected leaf" (AI-06, AC-02).
- top-1 below `review_threshold` (0.60) → status `needs_review`: specific photo guidance *and* a `review_queue` row for the agronomist (FR-05).
- otherwise `proposed`: the farmer confirms (or picks another candidate) → `confirmed`.
On-device: the same heads exported to TFLite int8, ≤ 25 MB (AI-04); the client result is uploaded as a diagnosis with `computed_on = device` and is re-scored by the server model when online — the server result supersedes if it disagrees, and the farmer is told.

#### 4.3.3 Confirmation → record, tasks, reminders (`api`, DDS-12 DD-G05 — FR-09, FR-16, FR-17, FR-18, AC-03)
Confirmation is one transaction: `diagnosis.status = confirmed` fires `trg_diagnosis_confirmed`, which inserts the **scouting record** (zone, date, severity, evidence photo ids, candidate, `record_no` like `SC-2026-0412`), the **tasks** from `task_template` rows matching the diagnosis kind and severity (inspect N nearby plants — today; consider an approved treatment — tomorrow; follow-up photo — +7 d), and a **reminder** per task at the farm's reminder hour outside quiet hours. No API code composes any of it; the seed reproduces Appendix A through this trigger alone.

#### 4.3.4 Treatment, PHI and traceability (`api` — FR-10, FR-11, FR-12, FR-28, C-02)
A treatment is proposed from `input_product` rows filtered by crop, target condition and `approved = true`, shown with PHI, REI and label cautions (FR-28); the spray-conflict function warns when forecast rain falls within the product's rainfast window (FR-25). Applying it creates an **input-usage record** with product, active ingredient, dose, method, applicator, weather at application (snapshot of the nearest forecast/observation), PPE — all mandatory (FR-10). `phi_status(zone, at)` returns `clear_at = max(ts + phi_days)` over applied products; `trg_harvest_phi` refuses a harvest row before `clear_at` with `PHI_NOT_ELAPSED` (FR-11, AC-04); harvest tasks show the same status as a warning. A harvest lot's `traceability_json` is computed by `trace_lot()`: zone → inputs applied since planting → scouting events → the record hashes (FR-12).

#### 4.3.5 Append-only records and the audit package (DD-G01, DD-G02, IF-66 — FR-13, FR-14, NFR-04, AC-05, AC-06)
Scouting, input-usage and harvest records share the *record-version pattern*: `(record_no, version)` is the key; UPDATE and DELETE are refused; a correction inserts `version + 1` with `supersedes = previous id` and `reason`; `v_record_current` shows the latest. Every version carries `hash = sha256(prev_hash ‖ canonical_json)` where `prev_hash` is the previous version in the same zone's chain — a single tampered row breaks every hash after it. The export (`/export/gap`) builds the PDF/XLSX package from the scheme's record templates for the period and zone, plus a manifest with the chain head; `/export/gap/verify` recomputes and compares. Missing mandatory records for the scheme (e.g. no scouting for 7 days) are **compliance gaps** computed by `compliance_gaps()` from `gap_scheme_rule` rows and shown before the auditor sees them (FR-15).

#### 4.3.6 Tasks, reminders, escalation (`scheduler` — FR-17…FR-20)
Tasks have owner, due, zone, kind, priority and optional evidence (photo). Reminders go to the farmer's channels — LINE (IF-67), push (IF-40), Discord (IF-08) — never inside the farm's quiet hours (`trg_reminder_quiet_hours` shifts the send time). A re-inspection task prompts a follow-up photo; the new observation's severity is compared with the original and stored as `followup_delta` (FR-19). A `critical` task overdue by more than the configured hours creates an escalation to the farm manager (FR-20).

#### 4.3.7 Sensors, weather, advisories (`ingest-mqtt`, `scheduler` — FR-21…FR-26)
Topics `farm/{farm_code}/{zone_code}/{signal}` with a JSON payload `{ts, value, unit, device}`; the device must be registered to a sensor whose kind fixes the unit and physical range — anything else is refused (FR-21). Fault detection runs every 15 min: stuck (same value for `stuck_readings` consecutive readings), out of range, offline > 1 h → `sensor_fault` and a maintenance task (FR-22). Weather is fetched per farm hourly and cached; daily Tmax/Tmin/RH/rain feed GDD and risk (FR-23). Advisories are rule rows: `risk_rule` (crop, condition, RH ≥, temperature band, hours → risk level) (FR-24); spray conflict (FR-25); irrigation from the soil-moisture slope, stage and forecast rain (FR-26). All advisory only.

#### 4.3.8 Agent, prediction, summary (`worker-agent` — FR-27…FR-32, AI-07, AI-08)
`POST /ask` assembles a **facts object**: the question, the farm's zones and stages, recent diagnoses and records, the relevant crop-library chunks (pgvector), the approved products for the crop, PHI status, forecast. The model (or the scripted fallback) writes a Thai answer *from* those facts with citations to chunk ids and record numbers; the answer's `products_json` is validated against the approved list before storage (`trg_answer_products`, AC-08); severe/unfamiliar/fast-spreading conditions set `consult_agronomist = true` (FR-29). Harvest prediction is interpretable (AI-08): GDD accumulated since planting against the crop's stage model gives the maturity date; a linear regression of yield per rai on the zone's history gives the expected yield with a prediction interval; the factors are stored (FR-30, FR-31); fewer than `min_seasons` history rows → `insufficient_data` (AC-09). The weekly summary is a rendered facts object (FR-32).

#### 4.3.9 Offline sync (`web`, `api`, IF-63 — C-01, NFR-02, AC-07)
The client stores observations, photos, records and task completions locally with client-generated UUIDv7 ids and an idempotency key per batch. On reconnection it uploads photos (resumable) then posts the batch; the server applies each item once (`trg_sync_idempotent`) and returns the server rows; conflicts are impossible for append-only records and resolved last-writer-wins for task status with the device timestamp. A replayed batch returns the same rows.

#### 4.3.10 Corrections and the training loop (FR-07, AI-03, AI-09)
An agronomist correction (`diagnosis_correction`) inserts a `label_example` with photo ids, the corrected class, the original candidates, the model version and the reviewer — the field dataset grows from real use with provenance. Model release (`model_registry.status = released`) is refused unless a `model_eval_run` on a **field** set passed the AI-02 gates and the on-device size is within AI-04 (`trg_model_release_gate`); a released model needs an active calibration with an expected-calibration-error record (`trg_calibration_required`).

### 4.4 Runtime views
**RV-1 Appendix A end to end.** Farmer opens zone B (chili, flowering) → 3 photos pass the gate → server diagnosis: Cercospora 0.82 / anthracnose 0.09 / Mg deficiency 0.05, severity moderate 8–12 % → farmer taps confirm → one transaction: `SC-2026-0412`, three tasks, three reminders → the result card also shows the spray-conflict advisory (rain within 12 h) and the agronomist line → LINE reminder at 07:00 next day.
**RV-2 AC-02.** A photo of a hand → OOD energy above threshold → `refused`, no record, guidance shown.
**RV-3 AC-04.** Mancozeb applied 2026-09-10, PHI 7 d → harvest attempt 2026-09-14 refused `PHI_NOT_ELAPSED` (clear 2026-09-17) → harvest 2026-09-18 accepted with traceability.
**RV-4 AC-06.** Correction of `SC-2026-0412` severity → version 2, version 1 still readable, chain continues.
**RV-5 AC-07.** Airplane mode: 20 observations queued → reconnection → one batch → 20 rows; the batch replayed → the same 20 ids.
**RV-6 AC-08.** "ใช้พาราควอตได้ไหม" → facts contain the approved list only → the answer names no unapproved product, explains why, and points to an agronomist.
**RV-7 AC-09.** Zone A (3 seasons) → interval and factors; zone C (no history) → `insufficient_data`.
**RV-8 FR-22.** Soil-moisture sensor stuck for 12 readings → fault → maintenance task; EC sensor offline 3 h → fault.

### 4.5 Deployment view
One small VPS (4 vCPU / 8 GB, NFR-09) or an on-farm mini-PC; compose with profiles `gpu` / `cpu` / `mqtt` / `dev`; networks `frontend` (reverse proxy → api/web), `sensors` (mosquitto, ingest, sensor-sim), `internal` (everything else), `egress` (api, scheduler — weather, LINE, Discord, push). The phone app is a PWA served by `web`; Flutter is documented as an API client. OPS-12 §2.

### 4.6 Data view
DDS-12. One schema `farm` (SRS §5's tables kept by name and extended) + `audit`. Monthly partitions on `telemetry`; PostGIS `geography` for farm points and zone polygons; `vector(1024)` on `knowledge_chunk` only; `record_no` sequences per farm and record kind; the record-version pattern on three tables.

---

## 5. Cross-cutting concerns
| Concern | Design |
|---|---|
| Identity & roles | farmer / farm_manager / agronomist / auditor / admin; a user belongs to farms; auditors see records and versions only (SEC-12 §5.7) |
| PDPA (NFR-05) | Identity and location only for `app_rw`; `agent_ro` sees pseudonyms and zone codes; data export and erasure requests; erasure pseudonymises authorship (`author_ref`) but never deletes a record version — the chain and the audit requirement win, the identity does not survive |
| i18n (C-05, NFR-08) | Every string, notification and error has `th` and `en`; templates and prompts in Thai; glossary with forbidden variants |
| Errors | RFC 7807 `Problem` (byte-identical to API-00) with stable codes (API-12 §7) |
| Observability | IF-14 metrics: diagnosis latency by path, OOD rate, review rate, sync lag, sensor faults, PHI refusals, blocked product mentions, export verifications |
| Retention | Photos of `refused` diagnoses 30 d; PASS-quality derivatives 365 d; records forever (GAP); telemetry 2 y; OPS-12 §9 |

---

## 6. The design's own risk — a wrong diagnosis that becomes a record
The strongest feature — a confirmed diagnosis *is* a record — is also the risk: a confidently wrong classifier fills the GAP file with wrong scouting entries. Mitigations are structural: calibration (AI-05) so that "82 %" means 82 %; the review queue below 0.60; the agronomist correction that creates a *new version* of the scouting record rather than deleting it (the file shows the correction, which auditors prefer); the field test set as the only acceptable evidence (AI-03); and the "consult" line on every severe or fast-spreading result (FR-29). What the design cannot do is make a farmer photograph the right leaf — the gate and the guidance help; the follow-up task at +7 d is the safety net.

---

## 7. Architecture Decision Records

### ADR-G01 — Separate deployment on PostgreSQL + PostGIS + pgvector, schema `farm`
**Context.** SAD-00 §13 classifies GAPFarm as "none"; zones are polygons; the agent cites a crop library. **Decision.** One database built from `deploy/postgres/Dockerfile` (`postgis/postgis:16-3.4` + pgvector), schema `farm` + `audit`; helpers and audit copied from the platform and diffed. **Consequences.** No platform coupling to maintain; PostGIS functions for zone assignment and area; the byte-identity check keeps the patterns aligned.

### ADR-G02 — On-device model with server fallback and a record-only mode
**Context.** C-01, FR-08, AI-04, NFR-01. **Decision.** The same heads exported to TFLite int8 ≤ 25 MB run on the phone; when online the server model re-scores and supersedes; with neither, the observation is recorded with photos and the diagnosis is queued. **Consequences.** Two model artefacts per release with one manifest (IF-64); the device result is never the final word when a server is reachable.

### ADR-G03 — Append-only versioned records with a per-zone hash chain
**Context.** C-03, FR-14, NFR-04, AC-06. **Decision.** `(record_no, version)` keys; UPDATE/DELETE refused by trigger; corrections are versions with `supersedes` and `reason`; each version hashes the previous version in the zone's chain; the export manifest carries the chain head and a verify endpoint recomputes. **Consequences.** Auditors can verify without trusting the operator; erasure must pseudonymise, not delete (ADR-G10).

### ADR-G04 — PHI is enforced by the database
**Context.** FR-11, AC-04; DDS-00 §12.1. **Decision.** `trg_harvest_phi` refuses a harvest row before `phi_clear_at(zone)`; harvest tasks display the status; no override in v1. **Consequences.** A manager cannot "just harvest"; if a product was applied to part of a zone only, the zone must be split — recorded as an open decision (README).

### ADR-G05 — The approved-input list is the only source of product names
**Context.** C-02, FR-28, AI-07, AC-08. **Decision.** `input_product` with `approved`, PHI, REI, rainfast, MRL, label URI and an approval workflow (IF-65); guards refuse a recommendation, an input-usage row or an agent answer that names an unapproved or unknown product; the LLM receives product rows as facts and cannot add to them. **Consequences.** A new product needs an admin and a label; the adversarial test is a database probe, not a prompt experiment.

### ADR-G06 — Calibrated top-3 with OOD refusal and a review queue
**Context.** C-04, FR-03, FR-05, AI-05, AI-06. **Decision.** Temperature scaling per model version with an expected-calibration-error record; OOD by energy score with a field-calibrated threshold; below 0.60 → review queue; diagnosis shape enforced in the database. **Consequences.** A model cannot be released without calibration; a refused image creates no record.

### ADR-G07 — Confirmation generates records, tasks and reminders from templates, in one transaction
**Context.** FR-09, FR-16, AC-03; "≤ 3 taps per record" (§10). **Decision.** `task_template` rows per diagnosis kind × severity; `trg_diagnosis_confirmed` creates everything. **Consequences.** The API cannot forget a record; templates are data an agronomist can edit; Appendix A is reproducible from the seed.

### ADR-G08 — Interpretable harvest prediction (GDD + stage observations + history regression)
**Context.** FR-30, FR-31, AI-08, AC-09. **Decision.** Maturity date from GDD accumulated against the crop stage model, adjusted by stage observations; yield from a linear regression on the zone's seasons with a t-based prediction interval; factors stored; `insufficient_data` below 3 seasons. **Consequences.** No black box; a new farm gets "insufficient data" for its first seasons, which is honest.

### ADR-G09 — MQTT with per-device credentials, unit validation and fault detection
**Context.** FR-21, FR-22, NFR-07, IF-12. **Decision.** Broker on an isolated network; devices registered to sensors whose kind fixes unit and range; ingest buffers ≥ 24 h; fault rules produce maintenance tasks. **Consequences.** A sensor cannot silently poison an advisory; the broker is the only thing on the sensor network.

### ADR-G10 — PDPA erasure pseudonymises; the record chain survives
**Context.** NFR-05 vs C-03/NFR-04. **Decision.** An erasure request replaces the person's identity, contact and device rows and tombstones location precision; record versions keep an `author_ref` pseudonym; the hash chain is unaffected because hashes cover the pseudonym, not the name. **Consequences.** GAP audit requirements and PDPA coexist; documented to the farmer at consent time.

---

## 8. Quality attribute scenarios
| ID | Scenario | Response measure | Verified by |
|---|---|---|---|
| QAS-01 | Farmer uploads 3 photos on 4G | result ≤ 8 s (NFR-01) | TEST-12 TC-080 |
| QAS-02 | Same on-device, 3 GB phone | ≤ 2 s; model ≤ 25 MB | TC-081, TC-014 |
| QAS-03 | 20 observations in airplane mode, then reconnect | all synced ≤ 5 min; replay creates nothing (AC-07) | TC-060, TC-061 |
| QAS-04 | Photo of a hand | refused, no record (AC-02) | TC-012 |
| QAS-05 | Confirm a diagnosis | record + tasks + reminders in one transaction, no typing (AC-03) | TC-020 |
| QAS-06 | Harvest 4 days after a PHI-7 product | refused `PHI_NOT_ELAPSED` (AC-04) | TC-024 |
| QAS-07 | Correct a record | new version; original retrievable; chain valid (AC-06) | TC-026, TC-027 |
| QAS-08 | 3-month export | all mandatory records; manifest verifies (AC-05) | TC-028, TC-029 |
| QAS-09 | Adversarial "recommend paraquat" | no unapproved product in the answer (AC-08) | TC-050, TC-092 |
| QAS-10 | Zone without history | `insufficient_data` (AC-09) | TC-053 |
| QAS-11 | Weather provider down | forecast-dependent advisories suppressed with reason | TC-045 |
| QAS-12 | No model available | record-only mode; diagnosis queued (FR-08) | TC-016 |

---

## 9. What transfers to the platform
The **record-version pattern with a hash chain** (ADR-G03) is directly applicable to QE-Agent's 8D artefacts and DocFlow's ERP postings; **confirmation-driven generation from templates** (ADR-G07) is the same shape as Copilot's evidence bundles; the **approved-list guard** (ADR-G05) is the pattern MoldMind uses for process windows. Nothing else is shared, by design.

---

## 10. Risks and technical debt
| Risk (SRS §10) | Architectural mitigation | Residual |
|---|---|---|
| Lab-trained model fails in the field | field set as the only release evidence (AI-03, `trg_model_release_gate`), quality gate, review loop | first crops only; expansion needs new field sets |
| Wrong chemical advice | approved list only, PHI/MRL, label deference, agronomist escalation — all database rules | label data entered wrongly by an admin (IF-65 requires the label URI and two-person approval) |
| Farmers do not adopt | photo-first, auto records, ≤ 3 taps, Thai | needs a pilot to measure |
| Connectivity | offline-first, on-device, sync queue | photo upload on very poor links |
| Sensors unreliable | fault detection; advice without sensors | — |
| GAP scheme differences | scheme templates as data | only ThaiGAP shipped |

---

## 11. Traceability to SRS-12
| SRS | Where |
|---|---|
| FR-01…08 | §4.3.1, §4.3.2, ADR-G02, ADR-G06 |
| FR-09…15 | §4.3.3…§4.3.5, ADR-G03, ADR-G04, ADR-G07 |
| FR-16…20 | §4.3.3, §4.3.6 |
| FR-21…26 | §4.3.7, ADR-G09 |
| FR-27…32 | §4.3.8, ADR-G05, ADR-G08 |
| AI-01…09 | §4.3.2, §4.3.10, ADR-G02, ADR-G06, ADR-G08 |
| NFR-01…09 | §3.2, §5 |
| C-01…05 | §3.1 |
| AC-01…09 | §4.4, §8 |
