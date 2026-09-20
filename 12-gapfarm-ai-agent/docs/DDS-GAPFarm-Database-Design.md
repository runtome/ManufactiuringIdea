# Database Design Specification — GAPFarm AI (AI Farmer Agent)

| Field | Value |
|---|---|
| Document ID | DDS-12-GAPFarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-20 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-12](../SRS-GAPFarm-AI-Farmer-Agent.md) §5 · [SAD-12](SAD-GAPFarm-Software-Architecture.md) §4.6, ADR-G01, G03…G10 |
| Artifacts | [`db/schema.sql`](../db/schema.sql) (1,905 lines) · [`db/seed_demo.sql`](../db/seed_demo.sql) (485 lines) |
| Related | [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) §12.1 (the `farm` sibling schema) · [API-12](../api/API-Specification.md) · [SEC-12](SEC-GAPFarm-Security-Requirements.md) §5.7 · [TEST-12](TEST-GAPFarm-Test-Plan.md) TC-002…TC-005 |

---

## 1. Scope and platform relationship

One PostgreSQL 16 database with **PostGIS 3.4** (farm point, zone polygons — SRS §5 `geography`) and **pgvector** (crop-library chunks the agent cites — FR-27). Schema **`farm`** — the name DDS-00 §12.1 reserves for this sibling — plus **`audit`**. GAPFarm is a *separate deployment* (SAD-00 §13); it copies three platform patterns and nothing else:

| Pattern | Source | Identity (TEST-12 TC-002) |
|---|---|---|
| `public.uuid_generate_v7()`, `public.set_updated_at()` | `00/db/schema.sql` §3 | byte-identical |
| `audit.log`, `audit.auth_event` | `00/db/schema.sql` §13 | identical modulo `core.app_user → farm.app_user` |
| `Problem` (API) | `00/api/openapi.yaml` | byte-identical (API-12 §7) |

Every SRS §5 table exists under its SRS name with its SRS columns (`farm`, `zone`, `crop`, `observation`, `diagnosis`, `input_product`, `input_usage`, `task`, `sensor`, `telemetry`, `harvest`, `forecast`, `audit_log` → `audit.log`), extended as §2 describes.

**Inventory** (TC-003): 52 tables (50 `farm` + 2 `audit`; 4 of the 50 are `telemetry` partitions), 14 views, 30 distinct triggers (35 bindings), 54 functions (2 platform helpers, 26 domain functions, 26 trigger functions), 46 indexes, 25 enums, 5 roles.

---

## 2. Design decisions — the SRS rules as database properties

| ID | Decision | SRS | Mechanism |
|---|---|---|---|
| **DD-G01** | **Records are append-only and versioned.** `scouting_record`, `input_usage`, `harvest` have the key `(record_no, record_version)`; UPDATE and DELETE are refused; a correction inserts `record_version + 1` with `supersedes` (the previous version's id) and a mandatory `reason_th`. `v_record_current` shows the latest version, `v_record_versions` every version. | C-03, FR-14, AC-06 | `trg_record_append_only` (also on `record_chain`), version rules in `trg_record_chain` (`VERSION_NEEDS_SUPERSEDES`, `VERSION_CHAIN_BROKEN`), `REVOKE UPDATE, DELETE` from `app_rw` |
| **DD-G02** | **Every record version is hash-chained per zone.** `record_chain(zone_id, seq, record_kind, record_no, record_version, payload, prev_hash, hash)`: `hash = sha256(prev_hash ‖ payload::text)`, `payload = to_jsonb(row) − {id, supersedes, hash, prev_hash, created_at, phi_clear_at}` (deterministic content only — no surrogate ids, no server timestamps). `verify_chain(zone)` recomputes; `v_chain_status` shows the head; the export manifest carries the heads and is itself hashed (`verify_hash`). | NFR-04, FR-13, AC-05 | `trg_record_chain` BEFORE INSERT on the three record tables (fires after the per-table validation triggers, whose names sort earlier); `trg_export_hash` |
| **DD-G03** | **Only approved products can be named.** `input_product.approved` needs a label URI and `approved_by ≠ author_id`; `input_usage` and `treatment_recommendation` refuse a product not approved at the time; `answer.products_json` may list approved codes only and `answer.text_th` may not contain the name of an unapproved product. PHI/REI are **snapshotted** into the usage row at application. | C-02, FR-10, FR-28, AI-07, AC-08 | `trg_product_approval` (`LABEL_REQUIRED`, `APPROVAL_SELF`), `trg_input_usage_approved` (`UNAPPROVED_PRODUCT`, `PPE_REQUIRED`, `WEATHER_REQUIRED`), `trg_recommendation_approved`, `trg_answer_products` (`UNAPPROVED_PRODUCT`, `UNAPPROVED_PRODUCT_MENTION`) |
| **DD-G04** | **A diagnosis is 1–3 calibrated candidates or a refusal.** Each candidate carries `condition_code` (a `condition` row), `probability` ∈ [0,1], `distinguishing_features_th`, `how_to_confirm_th`; ordered; Σ ≤ 1; `calibration_version` mandatory. `ood = true` ⇒ zero candidates and `status = refused`. `top1_prob` below `setting.review_threshold` ⇒ `needs_review` and a `review_queue` row; a fast-spreading top-1 or a severe observation ⇒ `consult_agronomist` and a `severe` queue row. | C-04, FR-03, FR-05, FR-29, AI-05, AI-06, AC-02 | `trg_diagnosis_shape` (`DIAGNOSIS_SHAPE`, `UNCALIBRATED`), `trg_diagnosis_review` |
| **DD-G05** | **Confirmation generates the record, the tasks and the reminders.** `status → confirmed` requires `chosen_id` among the candidates and `confirmed_by`; then `generate_from_diagnosis()` inserts the scouting record (`next_record_no()` → `SC-2026-0412`), one task per matching `task_template` (condition kind × minimum severity, ordinal order, due at 17:00 local + offset days) and one reminder per task (immediate for offset 0, else at the farm's `reminder_time`). | FR-09, FR-16, FR-17, FR-18, AC-03 | `trg_diagnosis_confirmed` (`CHOSEN_NOT_CANDIDATE`, `DIAGNOSIS_STATE`), `trg_diagnosis_source` (a scouting record cites only a confirmed/corrected diagnosis) |
| **DD-G06** | **A correction is training data and a record version.** `diagnosis_correction` by an agronomist inserts `label_example` (photo ids, label, original candidates, model version, reviewer pseudonym), sets the diagnosis `corrected`, resolves the queue, and either inserts version + 1 of the existing scouting record or generates one. | FR-07, AI-09, AC-06 | `trg_correction_dataset` (`REVIEWER_ROLE`) |
| **DD-G07** | **PHI is a refusal.** `input_usage.phi_clear_at` is a generated column (`ts + phi_days`); `phi_clear_at(zone, at)` is the maximum over current versions; a `harvest` row or a harvest task completion before it raises `PHI_NOT_ELAPSED`. The harvest's `traceability_json` is filled by `traceability()` (inputs and scouting since planting, with hashes). | FR-11, FR-12, AC-04 | `trg_harvest_phi`, `trg_task_rules` |
| **DD-G08** | **Sensors: unit fixed by kind, range flagged, faults become tasks.** `sensor.unit` must equal `sensor_kind.unit`; a reading outside the kind's range is stored with `quality = out_of_range`; `detect_sensor_faults()` writes `sensor_fault` rows (stuck = the last `stuck_readings` values identical; offline > `sensor_offline_minutes`; out of range) and each fault inserts a maintenance task (critical when offline). | FR-21, FR-22 | `trg_sensor_unit` (`UNIT_MISMATCH`), `trg_telemetry_range` (SECURITY DEFINER, updates `last_seen_at`), `trg_sensor_fault_task` |
| **DD-G09** | **Identity never enters a record; erasure pseudonymises.** Records carry `author_ref = pseudonym(user)` (`'u-' ‖ sha256(uuid)[:10]`) beside a nullable `author_id`; `agent_ro` cannot read `app_user` identity columns, `farm.location`, `observation.gps` or `reporter_id`; an erasure request replaces the person's identity, contact, channels and push tokens and nulls their observation GPS — record versions and the chain are untouched. | NFR-05, C-03 | column grants (§8), `trg_pdpa_erasure` (audit row `pdpa.erasure`) |

Further guards: `trg_eval_gate` (an evaluation passes only on a **field** set with top-1 ≥ 0.80, top-3 ≥ 0.93, ECE ≤ 0.05 — AI-02/AI-03), `trg_model_release_gate` (`RELEASE_GATE_FAILED`, `DEVICE_MODEL_TOO_LARGE` — AI-04), `trg_calibration_required` (AI-05), `trg_forecast_interval` (`FORECAST_SHAPE` — FR-31/AC-09), `trg_sync_idempotent` (`SYNC_REPLAY` — NFR-02/AC-07), `trg_reminder_quiet_hours` (FR-18), `trg_followup_compare` (FR-19). The constants they read live in `farm.setting` whose CHECKs pin the SRS minima (review threshold, device ≤ 25 MB, gates, offline ≥ 60 min, ≥ 2 seasons).

---

## 3. Schema by section

| § | Tables | Purpose |
|---|---|---|
| 5 | `setting` | one row of constants (DD-G04, DD-G08, AI gates) |
| 6 | `app_user`, `gap_scheme`, `gap_scheme_rule`, `farm`, `farm_member`, `crop`, `condition`, `zone`, `device`, `sync_batch` | identity, scheme as data (§10), crop library with the GDD stage model, zones with PostGIS polygons, devices and idempotent sync |
| 7 | `observation`, `photo`, `diagnosis`, `review_queue`, `diagnosis_correction`, `label_example` | the diagnosis flow (FR-01…08); `photo.exif_stripped` is a CHECK; `observation.followup_of` / `followup_delta_pct` (FR-19) |
| 8 | `input_product`, `treatment_recommendation` | the approved list (C-02) with PHI/REI/rainfast/MRL, target conditions, label URI, approval workflow |
| 9 | `record_counter`, `record_chain`, `scouting_record`, `input_usage`, `harvest` | GAP records (DD-G01, DD-G02, DD-G07) |
| 10 | `task_template`, `task`, `notification_channel`, `reminder`, `escalation` | FR-16…20 |
| 11 | `sensor_kind`, `sensor`, `telemetry` (monthly partitions), `sensor_fault`, `weather_forecast`, `weather_daily`, `risk_rule`, `advisory` | FR-21…26 |
| 12 | `knowledge_chunk` (`vector(1024)`), `conversation`, `question`, `answer` | FR-27…29; `answer.facts_json` is what the model saw |
| 13 | `yield_history`, `forecast` | FR-30, FR-31 |
| 14 | `model_registry`, `model_eval_run`, `calibration_version` | AI-01…06 |
| 15 | `export_package`, `data_request`, `weekly_summary`, `migration` | FR-13, NFR-05, FR-32 |
| 16 | `audit.log`, `audit.auth_event` | platform pattern |

### 3.1 The record-version pattern
```
record_no        text      'SC-2026-0412' / 'IU-2026-0031' / 'HV-2026-0007'   (next_record_no(farm, kind, at))
record_version   int ≥ 1   UNIQUE (record_no, record_version)
supersedes       uuid      previous version's id (NULL for v1)
reason_th        text      mandatory for v > 1
author_id / author_ref     nullable identity / mandatory pseudonym
prev_hash / hash           set by trg_record_chain from the zone chain
```
Kind-specific content: scouting (observation, diagnosis, condition, severity, area %, plants, evidence photo ids, notes), input usage (product, ts, dose, unit, method, applicator, weather at application, PPE, PHI/REI snapshot, `phi_clear_at` generated), harvest (lot, qty, grade, `traceability_json`).

---

## 4. Functions — the deterministic logic (SQL twins, re-derived in Python — TC-005)
| Function | Purpose | SRS |
|---|---|---|
| `pseudonym(user)` | `'u-' ‖ sha256(uuid)[:10]` | NFR-05 |
| `next_record_no(farm, kind, at)` | per farm × kind × year counter → `SC-2026-0412` | FR-14 |
| `severity_level(area_pct)` | none / low (< 5) / moderate (≤ 15) / severe | FR-06 |
| `record_hash(prev, payload)`, `verify_chain(zone)` | the chain | NFR-04 |
| `phi_clear_at(zone, at)`, `phi_status(zone, at)` | latest PHI over current input-usage versions; days remaining | FR-11 |
| `traceability(zone, at)`, `trace_lot(lot)` | zone → inputs → scouting with hashes | FR-12 |
| `gdd_day(tmax, tmin, base)`, `gdd_accumulated(zone, to)`, `stage_from_gdd(crop, gdd)` | degree days and the stage model | FR-30 |
| `t_975(df)`, `predict_harvest(zone, as_of)` | harvest date from GDD to maturity (± 1 sd of the last 14 days' daily GDD); yield as the history mean with a t prediction interval; `insufficient_data` below `prediction_min_seasons` or with < 7 days of weather | FR-30, FR-31, AI-08, AC-09 |
| `disease_risk(crop, rh, temp, hours)`, `evaluate_risk(farm, day)` | rule rows → advisories; "weather unavailable" advisory when no daily row | FR-24, IF-12 |
| `spray_conflict(zone, planned_at, product)` | rain (≥ 50 % or ≥ 1 mm) inside the rainfast window; `conflict NULL` = no forecast covering it | FR-25 |
| `moisture_trend(zone, hours, now)`, `irrigation_advice(zone, now)` | least-squares slope (%/h); advise when slope < −0.3, latest < 30 %, rain next 24 h < 5 mm | FR-26 |
| `sensor_stuck`, `sensor_offline`, `detect_sensor_faults(now)` | FR-22 rules → `sensor_fault` rows | FR-22 |
| `compliance_gaps(farm, from, to)` | intervals longer than `gap_scheme_rule.max_gap_days` between consecutive records of a kind, per zone | FR-15 |
| `escalate_overdue(now)` | critical tasks overdue by `escalation_hours` → escalation to the farm manager | FR-20 |
| `generate_from_diagnosis(diag, user, condition, severity)` | DD-G05 (called by triggers only) | FR-09, FR-16 |
| `apply_sync_batch(device, key, items)` | idempotent batch; replay returns the stored result | NFR-02, AC-07 |
| `zone_for_point(farm, point)` | `ST_Covers` | FR-04 |

---

## 5. Views
`v_record_current`, `v_record_versions`, `v_chain_status` (head + `chain_ok`), `v_zone_phi`, `v_traceability`, `v_compliance_gaps` (90 days), `v_task_board` (overdue, escalated, `phi_clear` for harvest tasks), `v_review_queue`, `v_diagnosis_quality` (OOD / review / corrected rates per model version), `v_sensor_health`, `v_advisory_active`, `v_harvest_outlook` (latest forecast per zone × kind), `v_export_index`, `v_diagnosis_outcome` (what a diagnosis produced — AC-03).

---

## 6. Sizing and retention (NFR-09: ≤ 20 farms)
| Table | Rate | 2 years |
|---|---|---|
| `telemetry` | 5 sensors × 96/day × 20 farms | ≈ 7 M rows (monthly partitions; 2 y retention) |
| `photo` | ≈ 10/day/farm × 0.6 MB | 4.4 M objects in MinIO; rows small; refused diagnoses' photos 30 d, PASS derivatives 365 d |
| records | ≈ 1 scouting/day/zone, 2 usages/month/zone | < 100 k rows; **kept forever** (GAP) |
| `weather_forecast` | hourly × 8 slots | 3.5 M rows; 1 y |
| `knowledge_chunk` | ≈ 5 k chunks × 1024 dims | HNSW index ≈ 30 MB |

---

## 7. Seed — what `seed_demo.sql` reproduces (TC-005)
Farm **สวนพริกบ้านโนน** (ThaiGAP), zones A (planted 2026-06-01, 3 seasons of history), B (2026-07-20 — **flowering on 2026-09-09**: GDD 922.5), C (2026-08-20, no history). Deterministic integer weather 2026-06-01…09-20. Five approved products (example label values) and one banned (paraquat).

| Scenario | Rows | Expected (Python re-derivation) |
|---|---|---|
| 20 routine weekly scouting records (healthy) | `SC-2026-0391…0410` | counters preset so Appendix A's record is **SC-2026-0412** |
| Zone A anthracnose, severe (09-08) | diagnosis 0902 → `consult_agronomist`, queue `severe`; confirmed → SC-2026-0411, 4 tasks, 4 reminders; critical task escalated to the farm manager at 09-10 09:00 | escalations 1 |
| Treatment IU-2026-0031 (mancozeb 09-10 08:00) | PHI 7 d snapshot | `phi_clear_at` 2026-09-17 08:00 |
| **Appendix A** (09-09 10:15, zone B) | diagnosis 0901 (0.82 / 0.09 / 0.05) confirmed → **SC-2026-0412**, 3 tasks (inspect today, treat tomorrow, follow-up +7 d), 3 reminders; recommendation P-MANCO with `spray_conflict = true` (rain 09-10 06:00 inside the 6 h window); advisory "ฝนตกใน 12 ชม." | `v_diagnosis_outcome`: tasks 3, reminders 3 |
| Low confidence (09-12, 0.41) | needs_review → correction (mg deficiency, low) → label_example, diagnosis corrected, **SC-2026-0413** + 2 tasks | queue resolved `corrected` |
| AC-02 hand photo | diagnosis 0904 `refused`, ood 8.2 | no record, no task |
| Device diagnosis in zone C | 0905 `proposed`, no record | — |
| AC-07 | `apply_sync_batch` 20 observations → applied 20; replay → `replayed = true`; direct re-insert → `SYNC_REPLAY` | 20 rows with `sync_batch_id` |
| Follow-up (09-16, FR-19) | observation 0706 `followup_delta_pct = −7.00`; diagnosis 0906 confirmed → SC-2026-0415 | follow-up task done |
| AC-06 | SC-2026-0412 **v2** (plants 6 → 8, reason) by the manager; v1 retrievable | hashes v1 `b1c0a31d5026…`, v2 `eed384754914…` |
| AC-04 | harvest 09-14 → `PHI_NOT_ELAPSED` (probe P-03); **HV-2026-0007** 09-18 with traceability (1 input, 15 scouting) | chain A 17 rows, B 10, C 1; heads `05ff22f2ff8d` / `eed384754914` / `d1b32c897c84` |
| Sensors (24 h to 09-20 09:00) | SM-A1 slope −0.5 %/h, latest 26 % → irrigation advisory; SM-B1 stuck; T-A1 61 °C out of range; EC-B1 offline (critical task) | faults 3, tasks 3 |
| Risk rule (09-19: RH 80, 27 °C, 4 h) | cercospora rule fires for A, B, C | 3 advisories |
| Quiet hours | reminder asked at 21:30 → 2026-09-14 06:00 | — |
| Prediction (AC-09) | A: yield 1450.0 [1102.2, 1797.8] (t 4.303, sd 70), harvest date 09-20 (GDD 1987 ≥ 1400); B: harvest 2026-10-06 [10-06, 10-07] (GDD 1118.5, 17.68 ± 0.89/day), yield `insufficient_data` (1 season); C: both `insufficient_data` | — |
| AC-08 | answer e21 names no product, `consult_agronomist`; e22 names P-MANCO, P-COPPER with PHI | probes P-06, P-07 |
| FR-15 / AC-05 | compliance gap zone C 08-25 → 09-20 (26 d), only gap; export 06-20…09-20: 27 records, gap 1, `verify_hash 727922173316…` | — |
| NFR-05 | export request; erasure of มานะ → identity pseudonymised, his observation kept with `reporter_ref` | audit `pdpa.erasure` |

15 probes (P-01…P-15) each fail inside a savepoint: immutability, PHI, unapproved product (usage, recommendation, answer code, answer mention), diagnosis shape (4 candidates; ood with candidates), unit mismatch, release gates (lab-only; > 25 MB), forecast shape, sync replay, version without reason.

---

## 8. Roles (SEC-12 §5.7)
| Role | Grants |
|---|---|
| `app_rw` | all `farm` tables; audit INSERT/SELECT; **no** UPDATE/DELETE on the three record tables, `record_chain`, `label_example` |
| `app_ro` | SELECT all |
| `ingest_rw` | INSERT `telemetry`; SELECT `sensor`, `sensor_kind` (`last_seen_at` is updated by the SECURITY DEFINER trigger) |
| `agent_ro` | facts only: `app_user (id, role, locale)`; `farm` without `location`; `observation` without `gps`, `reporter_id`; no `device`, `notification_channel`, `data_request`, `sync_batch`, `export_package`; INSERT on conversation/question/answer/advisory/forecast/weekly_summary |
| `auditor_ro` | records, versions, chain, exports, evidence, products, schemes; `farm (id, code, name, gap_scheme)`; observation without identity; no writes |

---

## 9. Verification (what was and was not executed)
| Check | Result |
|---|---|
| Static DDL (TC-003): balance, FK targets/order, PKs, 25/25 guard bindings present, trigger functions defined before use, views used by functions defined before the trigger binding | ✅ |
| Pattern identity (TC-002) | ✅ helpers byte-identical; audit identical modulo the FK |
| Seed re-derivation (TC-005): chain heads, v1/v2 hashes, traceability counts, export manifest hash, PHI dates, GDD/stage (Appendix A "flowering" holds), prediction intervals, risk firing, spray conflict, moisture slope, stuck/offline, quiet-hours shift, compliance gaps, record numbering | ✅ Python (`check_seed12.py`) |
| Schema + seed on PostgreSQL 16 + PostGIS + pgvector (TC-009) | ⚠️ **not executed** — no Docker daemon on the authoring machine; OPS-12 §12 has the commands and the expected `\echo` block |

Known authoring defects found while checking (fixed): `at` used as a view column alias (renamed `record_at`); chain payload originally included surrogate ids and `supersedes`, which would have made hashes non-reproducible across environments (removed); the RH sensor series ended exactly 60 min before "now", on the offline boundary (extended); zone A's routine scouting had a 9-day gap that would have failed AC-05's mock audit (08-31 and 09-05 records added).
