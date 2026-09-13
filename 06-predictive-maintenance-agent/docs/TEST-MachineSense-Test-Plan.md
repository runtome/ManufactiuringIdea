# Test Plan & Test Cases — MachineSense AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | TEST-06-MachineSense |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Basis | [SRS-06](../SRS-MachineSense-Predictive-Maintenance.md) FR-01…27, AI-01…08, NFR-01…09, AC-01…08, C-01…05 · [SAD-06](SAD-MachineSense-Software-Architecture.md) QAS-01…12 · [SEC-06](SEC-MachineSense-Security-Requirements.md) · [ICD-06](ICD-MachineSense-Interface-Control.md) |
| Executed so far | **TS-0 static checks** on the authoring machine (Python 3.14, `pyyaml`, `openapi-spec-validator`, `jsonschema`): byte-identity of 45 shared DDL objects, static DDL checks, seed arithmetic and tallies, OpenAPI validation and contract identity, JSON-Schema validation of the sensor map and alert rules, compose/env. **PostgreSQL/TimescaleDB execution not possible** (Docker unavailable). Everything from TS-1 onward needs the lab (broker, OPC-UA simulator, Modbus simulator, DAQ emulator) — specified, not run. |

---

## 1. Strategy

### 1.1 What is different about testing a predictive-maintenance system
- **Ground truth is rare and slow.** Failures happen months apart. The suite therefore relies on three corpora: the **retrospective failure set** (≥ 5 historical failures with the telemetry that preceded them — AC-01), a **healthy 30-day run** (AC-02), and **synthetic degradations** injected into replayed healthy data (AC-03). All three are replayed through the real pipeline (ingest → features → scoring → alerts) at accelerated time.
- **The numbers are the product.** TS-3 asserts computed values against independent implementations (NumPy reference for σ, EWMA, OLS slope + CI, kurtosis, crest, health index), not just "an alert fired".
- **"Advisory only" is tested against the machine, not the code.** TC-020 performs an OPC-UA write with MachineSense's account against every onboarded controller and expects the controller to refuse it.
- **Precision is measured from feedback**, never estimated: AC-08 closes ≥ 20 alerts through the real workflow and reads `v_alert_precision`.
- **Static artefacts run now** (TS-0): the schema's shared objects are diffed byte-for-byte against the platform, the seed's arithmetic is re-derived, and the config examples validate against their schemas.

### 1.2 Levels
| Level | Scope | Runs |
|---|---|---|
| L0 Static | DDL, seed, OpenAPI, schemas, compose | every commit |
| L1 Unit | feature extraction, context classifier, σ/EWMA/trend/health math, alert engine state machine, grounding post-check, redaction | every commit (≥ 80 % coverage on features and scoring — NFR-08) |
| L2 Integration (lab) | full pipeline with MQTT broker, OPC-UA and Modbus simulators, DAQ emulator, TimescaleDB, Ollama | nightly |
| L3 Corpora | retrospective set, healthy run, synthetic degradations, injection corpus | release |
| L4 Site | live machines, 30-day observation, technician feedback | commissioning |

### 1.3 Exit for release
All Must FR TCs green; **TC-020 green on every onboarded controller**; AC-01 (≥ 3 of ≥ 5 detected with ≥ 3 d lead), AC-02 (≤ 1 false alert / 30 d), AC-03 (ramp attributed), AC-04 (grounded explanation), AC-05 (6 h replay, 0 lost), AC-06, AC-07, AC-08 green; NFR-08 coverage ≥ 80 %; residual risks (SEC-06 §8, incl. the signed Modbus acceptance) acknowledged.

---

## 2. Test suites and cases

Notation: **[X]** executed on the authoring machine · **[ ]** specified, not run · Pri M/S.

### TS-0 — Static and executable artefacts (L0)

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-001 | OpenAPI valid | validator; unique operationIds; every op 2xx; refs; orphans; null-key scan | Pass | M | [X] 45 paths / 50 ops / 24 schemas; 0 orphans |
| TC-002 | **Byte-identity with the platform** | Parse `CREATE TABLE/TYPE/FUNCTION/INDEX/EXTENSION` blocks in `db/schema.sql` and `00/db/schema.sql`; diff every object present in both | All shared objects identical | M | [X] **45/45** (24 tables, 9 types, 2 functions, 6 indexes, 4 extensions) |
| TC-003 | DDL static checks, guard triggers, grants | Paren/`$$` balance; FK targets defined; schemas created; the nine guard triggers present; grants: `telemetry_ingest` INSERT-only, `agent_ro` no `app_user`/`config_version`; constraint probes at the end of the seed | 48 tables, 8 views, 13 triggers, 27 indexes, 13 functions; 9/9 triggers; probes fail when run | M | [X] static; probes **not executed** (needs PostgreSQL) |
| TC-004 | Compose and env | Parse; profiles (`opcua`, `modbus`, `gpu`); ingest services on the `ot` network and nowhere published; no write-capable flags; every `${VAR}` in `.env.example` both ways | As listed | M | [X] |
| TC-005 | **Seed arithmetic and tallies** | Re-derive in Python: σ = (78.4−68.9)/2.1, (4.9−2.9)/0.9, (1.1−0.6)/0.2, (41.4−41.0)/1.5; +13.79 %; health = 100 − Σ w·f(σ) − 0.20·0.75·100; feedback 17/6/1 → precision; 3 comparable failures; row tallies; the alert's `evidence_json` parses and carries the same numbers | 4.524 / 2.222 / 2.5 / 0.267; 13.79; **60.87**; 0.739; 3; 820,800 / 41,040 / 2,163 / 241 | M | [X] |
| TC-006 | Sensor map and alert rules validate; negatives | `sensors.example.yaml` vs `sensor-map.schema.json`; `alert-rules.example.yaml` vs `alert-rules.schema.json`; negatives: OPC-UA `access: write`; Modbus write FC; σ threshold ≤ 0; `consecutive_windows` 0; health weights not summing to 1; RUL `point_estimate: true` | Positives pass; negatives fail | M | [X] |
| TC-007 | No secrets in examples | Scan `.env.example`, sensor map, alert rules, seed for credentials | None; `credential_ref` names only | M | [X] |
| TC-008 | Contract identity vs API-00 | Diff `TelemetrySample`, `TelemetrySeries`, `MachineHealth`, `MaintenanceAlert`, `Severity`, `Problem`; paths `/telemetry/samples`, `/machines/{id}/health`, `/telemetry/series`, `/alerts`, `/alerts/{id}/feedback`; parameters `DateFrom`, `DateTo` | Identical | M | [X] 6/6, 5/5, 2/2 |
| TC-009 | Schema and seed execute on PostgreSQL 16 + TimescaleDB | `psql -v ON_ERROR_STOP=1 -f schema.sql -f seed_demo.sql`; `\echo` values; 8 probe failures; hypertables created | Zero errors; header values | M | [ ] **blocked** — Docker unavailable; command in README-06 |

### TS-1 — Ingestion and data quality (L2) — FR-01…03, FR-07, NFR-01, NFR-05, NFR-09

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-010 | MQTT telemetry ingest | Payload → `sample` with quality; unit mismatch → `quality 64` + event; unknown signal → rejected + event | M | [ ] |
| TC-011 | MQTT ACL | Client for M-04 publishing to M-07's topic → refused by the broker; logged | M | [ ] |
| TC-012 | Gap detection | 7 min silence on a 10 s signal → `gap` event; sensor health `gap` | M | [ ] |
| TC-013 | Stuck detection | 30 identical values → `stuck` event | M | [ ] |
| TC-014 | Out of range | 412 °C on a 0–200 signal → stored `quality 0`, `error` event, excluded from features | M | [ ] |
| TC-015 | Clock skew (NFR-09) | Source 7 s ahead → `skew` event; receive time stored | M | [ ] |
| TC-016 | Alarm log parsing (FR-07) | MQTT/OPC-UA alarm → `alarm_event` with code, severity, active/cleared | S | [ ] |
| TC-017 | **DB down 6 h (AC-05, NFR-05)** | Stop the database 6 h at full rate; buffer fills; on recovery replay → 0 samples lost (count vs publisher log); duplicates 0 (PK) | M | [ ] |
| TC-018 | 50,000 samples/s (NFR-01) | Fleet emulator 1 h at 50 k/s → ingest keeps up; lag ≤ 5 s; CPU/IO recorded | M | [ ] |
| TC-020 | **OPC-UA write refused** (C-01, C-02) | With MachineSense's account, attempt `write_value` on a writable node → controller returns `BadUserAccessDenied`; repeated on **every** onboarded controller | M | [ ] |
| TC-021 | OPC-UA session audit (NFR-06) | Sessions and the refused write appear in the audit with account and endpoint | M | [ ] |
| TC-022 | Node-id validation | Unknown node id in the sensor map → startup error naming it; no silent nulls | M | [ ] |
| TC-023 | Status codes kept | `Uncertain` and `Bad` stored with the value; Bad > 5 min → sensor `offline` | M | [ ] |
| TC-024 | 1 h OPC-UA outage | Reconnect with backoff; buffered/backfilled where the controller supports history; data-quality event | M | [ ] |
| TC-030 | Modbus scaling and word order | Reference value on the device display reproduced | M | [ ] |
| TC-031 | Modbus write function codes absent | Static scan + attempt through the client API → no such method; sensor map refuses | M | [ ] |
| TC-032 | Modbus offline / stuck register | 3 timeouts → offline event; constant register → stuck | M | [ ] |
| TC-040 | DAQ feature payload (IF-38) | Bands stored as features with RPM reference; RMS also as a sample | M | [ ] |
| TC-041 | Band naming and orders | 1x/2x/bpfo/bpfi as configured; a rename in DAQ firmware → validation error | M | [ ] |
| TC-042 | Snapshot on first alert | ≤ 2 s, ≤ 1 MB waveform stored and linked; never continuous | S | [ ] |
| TC-043 | Missing RPM reference | Bands stored `quality 64`, excluded from baseline | M | [ ] |
| TC-050 | CSV import (IF-36) | 1 M-row file → inserted/skipped/rejected counts; features backfilled; duplicates skipped | S | [ ] |
| TC-051 | Import schema errors | Wrong columns → `IMPORT_SCHEMA_INVALID` with the path | S | [ ] |

### TS-2 — Features and context (L1/L2) — FR-04…FR-06, NFR-02

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-090 | Feature maths vs NumPy | mean, std, min, max, RMS, kurtosis, crest on golden windows within 1e-9 | M | [ ] |
| TC-091 | Context classification with hysteresis (FR-05) | RPM/current transitions → running/idle/stopped with 60 s hold; no flapping on a 10 s dip | M | [ ] |
| TC-092 | Features per context | A window spanning a context change is split; no feature row without a context | M | [ ] |
| TC-093 | Derived signal (FR-06) | `delta_t = bearing_temp − ambient_temp` computed; an expression referencing an unknown signal refused at load | S | [ ] |
| TC-094 | Feature lag ≤ 60 s (NFR-02) | At 50 k/s, 95 % of windows available ≤ 60 s after their end | M | [ ] |
| TC-095 | Startup/stopped never scored | Windows in those contexts produce no σ/anomaly rows | M | [ ] |

### TS-3 — Baseline and scoring (L1/L2/L3) — FR-08…FR-13, AI-01…AI-07

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-120 | **Baseline confirmation (AI-01, ADR-P03)** | Propose < 28 d → `BASELINE_WINDOW_INSUFFICIENT`; ≥ 28 d with a missing context → 422 listing it; confirm → active, previous retired, `alerts_enabled` true; activate without `confirmed_by` → refused (trigger) | M | [ ] |
| TC-121 | σ-score and EWMA (FR-09) | Values equal the NumPy reference; EWMA λ = 0.2 | M | [ ] |
| TC-122 | Anomaly score and attribution (FR-10, AI-05) | IF v2 on the seed's feature vector → score 0.75 ± 0.05; contributions sum to 1; top feature `bearing_temp_mean` | M | [ ] |
| TC-123 | Trend with CI (FR-11, C-04) | OLS over 5 days on the seed ramp → slope 1.90 ± 0.05 °C/day; 80 % CI contains it; `pct_change` 13.79 | M | [ ] |
| TC-124 | Health index (FR-12) | Formula with the seed weights → 60.87 for M-07; components recorded; clamped [0, 100] | M | [ ] |
| TC-125 | **RUL gate (FR-13, AI-04, AC-07)** | M-11 (1 comparable failure) → `null` + "insufficient history (1 of 3 comparable failures)"; M-07 (3) → interval 12–30 @ 0.80; a point estimate refused (CHECK) | M | [ ] |
| TC-126 | Re-baseline after service (AI-07) | `component_replaced` → `rebaseline_required`; alerts downgraded to WATCH until a new baseline is confirmed; flag cleared on confirm | M | [ ] |
| TC-127 | Retrain and promote (AI-06) | Confirmed failure → retrain queued; candidate with lower precision → promotion refused (trigger); higher → promoted, previous retired | M | [ ] |
| TC-128 | **Synthetic ramp (AC-03)** | +0.5 °C/day on M-04 bearing temp over 10 days replayed → alert names the drive-side bearing; top attribution `bearing_temp_mean`; chart shows the ramp against the band | M | [ ] |
| TC-129 | **Retrospective replay (AC-01, AI-03)** | ≥ 5 historical failures replayed → ≥ 3 detected with ≥ 3 days lead; precision on the set ≥ 0.7; report attached to the release | M | [ ] |

### TS-4 — Alerting and workflow (L2/L4) — FR-14, FR-16…FR-22

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-130 | N consecutive windows (FR-17) | 2 violating windows → no alert; 3 → alert; a spike of 1 → none | M | [ ] |
| TC-131 | Severity ladder | σ 2.2 → WATCH; σ 3.1 → HIGH; σ 4.6 or health < 40 → CRITICAL; ladder from `alert-rules.yaml` | M | [ ] |
| TC-132 | Grouping (FR-18) | Second violation on the same (machine, component) attaches to the incident, card edited, severity may rise; different component → new incident | M | [ ] |
| TC-133 | **Suppression (AC-06, FR-14)** | Violations inside a declared window → `suppressed` rows, no delivery; after the window counters restart; an unsuppressed insert inside a window refused (trigger) | M | [ ] |
| TC-134 | Alert ≤ 5 min (NFR-03) | From the third violating window's end to Discord delivery ≤ 5 min p95 over 20 runs | M | [ ] |
| TC-135 | Lifecycle (FR-19) | ack / snooze / escalate / resolve via API and Discord → transitions with actor and channel; snooze > 7 d refused; closing without feedback refused | M | [ ] |
| TC-136 | **Feedback and precision (FR-20, AC-08)** | Close ≥ 20 alerts through the workflow → `v_alert_precision` matches a hand count; second feedback refused (immutable); tuning suggestions listed | M | [ ] |
| TC-137 | Top risks (FR-22) | `v_top_risks_week` ranks M-07 first in the seed; weekly post | M | [ ] |
| TC-138 | Config version stamped | Every alert carries the alert-rules version; reloading rules bumps it | M | [ ] |
| TC-139 | **Healthy machine 30 days (AC-02)** | Live or replayed healthy run → ≤ 1 false alert; each alert judged | M | [ ] |

### TS-5 — Agent (L2/L3) — FR-23…FR-27, AI-08

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-080 | Evidence-only input (AI-08) | Inspect the request to Ollama: evidence object, baselines, attribution, similar cases — no series, no free text as instruction | M | [ ] |
| TC-081 | **Grounding (AC-04)** | Explanation of the seed alert: every number ∈ evidence (78.4, 68.9, 2.1, 4.5, 13.8, 4.9, 2.9, 12–30…); a recorded model output with an invented number → narrative withheld, structured parts returned | M | [ ] |
| TC-082 | Likelihood language (FR-26) | "is caused by" / "definitely" → withheld; hypothesis carries `likelihood` and verification steps | M | [ ] |
| TC-083 | Injection corpus (SEC-P53) | Alarm text / maintenance notes / CSV cells with instructions → zero tool calls outside the read set; zero unbacked numbers; content reported as data | M | [ ] |
| TC-084 | Evidence immutable | Attempt to modify `evidence_json` via API → no such operation; via DB → audited (application rule) | S | [ ] |
| TC-085 | Ask with tools (FR-25) | "Which machines are degrading fastest this month?" → `get_trend`/`list_top_risks` calls; answer grounded; M-07 first | M | [ ] |
| TC-086 | Similar cases (FR-24) | Explanation includes the 2025-03-18 M-04 case (#212) from `search_memory` / local search | S | [ ] |
| TC-087 | TH / JA / EN (FR-27) | Same alert explained in three languages; numbers identical; post-check passes | S | [ ] |
| TC-088 | LLM down | `/agent/explain` → 503 `LLM_UNAVAILABLE`; alerts, cards, charts unaffected | M | [ ] |

### TS-6 — People-facing and exports (L2) — FR-19, FR-21, IF-08, IF-37

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-060 | Work-order draft (FR-21) | From the seed alert → symptom, evidence table, 4 tasks, parts, priority high, due 3 d; PDF renders TH/JA/EN | S | [ ] |
| TC-061 | CMMS webhook export | HMAC-signed POST; 2xx → `export_ref`; second export refused (409); non-2xx → 502 and draft kept | S | [ ] |
| TC-062 | Never automatic | No code path posts a draft without `POST /workorders/{id}/export` by planner+ | M | [ ] |
| TC-070 | Discord card content | All numbers from `evidence_json`; buttons; edited on attach, not reposted | M | [ ] |
| TC-071 | Discord actions | Buttons → transitions with `channel = discord` and the mapped actor | M | [ ] |
| TC-072 | Nothing sensitive posted | No endpoints, credentials, raw series in any card | M | [ ] |
| TC-073 | Identity mapping | Unmapped Discord user cannot ack | M | [ ] |
| TC-074 | Feedback prompt on close | Closing from Discord requires outcome + finding | M | [ ] |

### TS-7 — Security (L2/L3) — SEC-06

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-100 | No write code path | Static scan of ingest code: no OPC-UA write calls, no Modbus FC 5/6/15/16 | M | [ ] |
| TC-101 | Registry has no write tool | Attempt to register `opcua_write` → refused (deny-list) | M | [ ] |
| TC-102 | Egress capture | 1 h: from Z3 only Discord, SMTP, CMMS webhook, ingest hosts; nothing to Z1 except via ingest | M | [ ] |
| TC-103 | Unknown signal / rate anomaly | Rejected + event; flood from one client → broker rate limit | M | [ ] |
| TC-104 | Zone isolation | Z1 → Z3 blocked; Z4 → Z1 blocked | M | [ ] |
| TC-105 | Modbus risk acceptance on file | Signed document present for each Modbus segment | M | [ ] |
| TC-106 | DB grants | `telemetry_ingest` SELECT on `alert` → denied; `agent_ro` SELECT on `config_version` → denied | M | [ ] |
| TC-107 | Secrets | OT credentials only in files (0400); `config_version` content has `credential_ref` names only | M | [ ] |
| TC-108 | Audit of baseline / alerts_enabled / windows | Rows with actor and reason | M | [ ] |
| TC-109 | RBAC matrix | Each role's allowed/denied operations per SEC-06 §5.7 | M | [ ] |
| TC-110 | Export audit | CSV/PDF exports audited with user and scope | S | [ ] |
| TC-111 | Machines unaffected (NFR-07) | Stop the whole MachineSense stack 2 h → machine simulators unaffected; on restart, buffer replays | M | [ ] |

### TS-8 — Performance and coverage (L2/L3) — NFR-04, NFR-08

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-140 | 30-day chart ≤ 2 s (NFR-04) | `/telemetry/rollup` at 10 m for 30 days on 5,000-sensor data: p95 ≤ 2 s | M | [ ] |
| TC-141 | Coverage ≥ 80 % (NFR-08) | Feature extraction and scoring modules | M | [ ] |
| TC-142 | Scoring lag | Every machine scored ≤ 60 s after its features; 500 machines | M | [ ] |
| TC-143 | Compression and retention | After 7 d chunks compressed ≥ 10×; samples > 90 d dropped; `sample_1m` intact | M | [ ] |

### TS-9 — Platform mode (L2)

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-150 | Migration `machinesense_0001` on a platform DB | Applies cleanly; platform tables unchanged (TC-002 still green); `ALTER … ADD COLUMN` additive | M | [ ] |
| TC-151 | Tools registered in the platform registry | `get_machine_health`, `get_alert_evidence`, `list_top_risks`, `list_failures`, `get_trend` callable by Copilot under `agent_ro` | M | [ ] |
| TC-152 | Alerts → `quality.signal`; risks read by KaizenSwarm | Rows appear; a closed incident filed to Genba Memory | S | [ ] |

---

## 3. Traceability

| SRS-06 | TCs |
|---|---|
| FR-01 | TC-010, TC-020, TC-030, TC-050 |
| FR-02 | TC-010, TC-018 |
| FR-03 | TC-012…TC-015 |
| FR-04 | TC-090, TC-040 |
| FR-05 | TC-091, TC-092, TC-095 |
| FR-06 | TC-093 |
| FR-07 | TC-016 |
| FR-08 | TC-120 |
| FR-09 | TC-121 |
| FR-10 | TC-122 |
| FR-11 | TC-123 |
| FR-12 | TC-124 |
| FR-13 | TC-125 |
| FR-14 | TC-133 |
| FR-15 | TC-127, TC-129 (labels) |
| FR-16 | TC-070, TC-003 (actionable trigger) |
| FR-17 | TC-130 |
| FR-18 | TC-132 |
| FR-19 | TC-135, TC-071 |
| FR-20 | TC-136, TC-074 |
| FR-21 | TC-060…TC-062 |
| FR-22 | TC-137 |
| FR-23 | TC-081 |
| FR-24 | TC-086 |
| FR-25 | TC-085 |
| FR-26 | TC-082 |
| FR-27 | TC-087 |
| AI-01 | TC-120 |
| AI-02 | TC-122, TC-127 |
| AI-03 | TC-129, TC-139, TC-136 |
| AI-04 | TC-125 |
| AI-05 | TC-122, TC-128 |
| AI-06 | TC-127 |
| AI-07 | TC-126 |
| AI-08 | TC-080, TC-081 |
| NFR-01 | TC-018 |
| NFR-02 | TC-094 |
| NFR-03 | TC-134 |
| NFR-04 | TC-140 |
| NFR-05 | TC-017 |
| NFR-06 | TC-021, TC-107 |
| NFR-07 | TC-111 |
| NFR-08 | TC-141 |
| NFR-09 | TC-015 |
| AC-01 | TC-129 |
| AC-02 | TC-139 |
| AC-03 | TC-128 |
| AC-04 | TC-081 |
| AC-05 | TC-017 |
| AC-06 | TC-133 |
| AC-07 | TC-125 |
| AC-08 | TC-136 |
| C-01 | TC-020, TC-100, TC-101, TC-102 |
| C-02 | TC-020, TC-031, TC-106 |
| C-03 | TC-040…TC-043 |
| C-04 | TC-123, TC-125 |
| C-05 | TC-003, TC-128 |

## 4. Defects found during TS-0

| # | Where | Defect | Fix |
|---|---|---|---|
| 1 | `db/schema.sql` | `trg_alert_transition_log` was a BEFORE INSERT trigger inserting an `alert_transition` row that references the alert — the FK would fail because the alert row does not exist yet | Split into a BEFORE trigger (closed_at stamp) and an AFTER trigger (transition log) |
| 2 | `db/schema.sql` | Index `idx_dq_event_ts` redefined with a different column list than the platform's | Platform statement copied verbatim; 45/45 identical |
| 3 | `db/seed_demo.sql` header | Tallies assumed 18 sensors (777,600 rollups, 38,880 features, 2,160 health points); the derived signal makes it 19 and the hourly series is inclusive (820,800 / 41,040 / 2,163) | Header corrected from the re-derivation |
| 4 | `db/seed_demo.sql` | Feedback distribution put the `unknown` on n = 24, which is also `n % 4 = 0` → 5 FP instead of the intended 6 | `unknown` moved to n = 23; 17/6/1 → 0.739 |
| 5 | `db/seed_demo.sql` | Re-baseline flags set by trigger for M-07 and M-11 were left true although their baselines post-date the repairs; the promotion probe targeted a model with no active peer (would not fail) | Flags cleared for all; probe re-targeted to v1 (0.68 < 0.74) |
| 6 | `api/openapi.yaml` | Four unquoted commas inside flow-mapping descriptions parsed as bogus keys | Quoted; null-key scan in TC-001 |
| 7 | SRS-06 Appendix A | Vibration σ printed as 2.1 while (4.9 − 2.9)/0.9 = 2.22 | Seed stores 2.222; SRS not edited; README-06 known gaps |

## 5. Release gates
1. TS-0 green on every commit; TC-009 green in CI with the TimescaleDB image.
2. **TC-020 on every onboarded controller** — no exceptions, repeated quarterly (OPS-06 §4).
3. AC-01, AC-02, AC-03, AC-04, AC-05, AC-06, AC-07, AC-08 green (TC-129, TC-139, TC-128, TC-081, TC-017, TC-133, TC-125, TC-136).
4. TS-7 green; Modbus risk acceptance signed.
5. Coverage ≥ 80 % (TC-141); NFR-01…04 measured (TC-018, TC-094, TC-134, TC-140).
