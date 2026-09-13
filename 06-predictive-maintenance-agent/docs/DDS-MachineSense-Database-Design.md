# Database Design Specification — MachineSense AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | DDS-06-MachineSense |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-06 §5](../SRS-MachineSense-Predictive-Maintenance.md), [SAD-06 §4.3.4–4.3.8, §4.6, ADR-P01…P07](SAD-MachineSense-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) (PostgreSQL 16 + TimescaleDB, 1,118 lines) · [`db/seed_demo.sql`](../db/seed_demo.sql) |
| Platform relationship | Standalone schema whose shared objects are **byte-identical** to [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) (`00/db/schema.sql`); the MachineSense extension (§10 of the file) is migration `machinesense_0001` in platform mode |
| Verification | **Byte-identity: 45/45 shared objects identical** (24 tables, 9 types, 2 functions, 6 indexes, 4 extensions); static checks pass; seed arithmetic re-derived in Python. **Not executed** against PostgreSQL — Docker unavailable on the authoring machine (README-06) |

---

## 1. Introduction

### 1.1 Purpose
The physical design of MachineSense's data: high-rate machine samples and their rollups, features per context, engineer-confirmed baselines, versioned anomaly models and their scores with attribution, degradation trends with confidence intervals, health indices, alerts grouped into incidents with **evidence the narrative is checked against**, technician feedback that makes precision measurable, failure history that gates RUL, and the configuration versions that produced all of it.

### 1.2 What is different from the other databases in this repository
| | 01/02 | 03/05 | **06** |
|---|---|---|---|
| Volume | thousands of rows/day | thousands, on a device | **billions of samples/day** (NFR-01: 50 k/s ≈ 4.3 B rows/day) |
| Engine | PostgreSQL | SQLite | **PostgreSQL + TimescaleDB** (hypertables, compression, retention — ADR-P01) |
| Truth for the narrative | facts object (02) | — | **`evidence_json` on the alert** (AI-08) |
| The thing to protect | a shift's numbers / a verdict | a person's judgement | **uncertainty** (RUL interval or nothing) and **actionability** (component + inspection + attribution) |

### 1.3 Engine and extensions
PostgreSQL 16 with `pgcrypto`, `pg_trgm`, `btree_gin`, `vector` (unused standalone; kept so the file is platform-compatible) and **`timescaledb`** (optional, `CREATE EXTENSION … CASCADE` succeeds only when installed; §15 of the file converts `sample`, `feature`, `anomaly_score` and `health_index` to hypertables, enables compression after 7 days and retention at 90 days / 2 years). Without TimescaleDB the platform's native range partitions on `telemetry.sample` stay and the scheduler runs `rollup_1m()` and retention — a supported configuration.

### 1.4 Assembly and byte identity
`schema.sql` is **assembled by extraction** from `00/db/schema.sql` (helpers §3, enums §4, `core.plant/line/machine/app_user/user_line_scope` §5, the whole platform telemetry section §6, `agent.*` §7, `ops.*` §8, `audit.*` §9, the telemetry and data-quality indexes) — 45 objects verified identical by TEST-06 TC-002 — followed by the MachineSense extension (§10) and its indexes, views, roles, retention helpers and TimescaleDB block. The `ALTER TABLE telemetry.alert/baseline ADD COLUMN …` statements in §10 extend platform tables without changing their definitions (the platform tables remain byte-identical; the migration adds columns).

---

## 2. Design principles

Platform DD-01…DD-08 apply unchanged (UUIDv7 for client-created rows, `timestamptz`, append-only audit, …). MachineSense adds:

| ID | Principle | Enforced by |
|---|---|---|
| **DD-P01** | **An alert without a component, an inspection and attribution is not an alert.** | `trg_alert_actionable` (C-05, AI-05) |
| **DD-P02** | **Uncertainty is stored, never implied.** RUL is `(low, high, confidence)` or `(NULL, NULL, NULL, reason)`; a trend carries its CI. | `rul_interval_or_nothing` CHECK; `trend_ci_ordered`; the platform's `rul_interval_ordered`; alert `rul_reason` required when no interval |
| **DD-P03** | **RUL needs history.** An interval is refused unless ≥ 3 comparable failures (same machine type + failure mode) precede it. | `trg_rul_gate` (AI-04) |
| **DD-P04** | **Baselines are engineer-confirmed, ≥ 4 weeks, versioned, one active per key.** | `trg_baseline_activate`, `ux_baseline_active` (AI-01, ADR-P03) |
| **DD-P05** | **Models are versioned and promoted only on metrics.** One active per (scope, algorithm). | `trg_model_promote`, `ux_anomaly_model_active_*` (AI-02, AI-06) |
| **DD-P06** | **Suppression is recorded, never silent.** An alert inside a maintenance window must be inserted as `suppressed = true`; suppressed rows exist and are visible. | `trg_alert_suppression` (FR-14) |
| **DD-P07** | **Feedback is immutable; every status change is logged.** | `trg_feedback_immutable`, `trg_alert_transition_log` (FR-19, FR-20) |
| **DD-P08** | **Service resets the baseline.** Component replacement / failure repair flags the machine for re-baselining. | `trg_maintenance_rebaseline` (AI-07) |
| **DD-P09** | **Samples are never touched by triggers.** The ingest path is COPY into a hypertable with a primary key for idempotent replay; all logic runs downstream. | No triggers on `telemetry.sample` (NFR-01, NFR-05) |

---

## 3. Schema overview

| Section (file) | Objects | Origin |
|---|---|---|
| §3–4 helpers, enums | `uuid_generate_v7`, `set_updated_at`; 9 enums incl. `quality.severity`, `telemetry.alert_status` | platform, byte-identical |
| §5 `core` | `plant`, `line`, `machine`, `app_user`, `user_line_scope` | platform, byte-identical |
| §6 `telemetry` (platform) | `sensor`, `sample` (+ 4 partitions), `feature`, `baseline`, `health_index`, `alert`, `alert_feedback`, `maintenance_event` | platform, byte-identical |
| §7 `agent` | `tool`, `conversation`, `message`, `run`, `tool_call`, `action_proposal`, `feedback` | platform, byte-identical |
| §8 `ops` | `scheduled_job`, `config`, `data_quality_event` | platform, byte-identical |
| §9 `audit` | `log`, `auth_event` | platform, byte-identical |
| **§10 telemetry extension** | `machine_state`, `context_rule`, `machine_context`, `derived_signal`, `alarm_event`, `anomaly_model`, `anomaly_score`, `trend_estimate`, `alert_group`, `alert_transition`, `maintenance_window`, `failure_event`, `rul_estimate`, `retrain_run`, `workorder_draft`, `sensor_health`, `sample_1m`, `config_version`; `ALTER` on `alert` and `baseline`; 13 triggers | **MachineSense** (migration `machinesense_0001`) |
| §11–16 | 27 indexes, 8 views, roles/grants, `rollup_1m()`, retention view, TimescaleDB block, `ops.schema_version` | MachineSense |

**48 tables (incl. 4 partitions), 8 views, 13 triggers, 27 indexes, 13 functions** — static count.

### 3.1 ERD (telemetry)

```
core.machine ──< telemetry.sensor ──< sample (hypertable, PK sensor_id+ts)  ──rollup──> sample_1m (1-min, 2 y)
      │               │            ──< feature (per window, context)
      │               │            ──< baseline (versioned; active only when confirmed_by; ≥ 28 d window)
      │               │            ──< trend_estimate (slope + CI, pct_change)
      │               └──< derived_signal (expression)
      ├──< machine_state (1:1)  · context_rule · machine_context · alarm_event · sensor_health
      ├──< anomaly_model (versioned; one active per scope+algorithm) ──< anomaly_score (score + contributions_json)
      ├──< health_index (value 0–100 + components_json)
      ├──< alert_group (one open per machine+component) ──< alert (evidence_json; rul low/high or rul_reason) ──< alert_transition
      │                                                          │── alert_feedback (immutable) · workorder_draft
      ├──< maintenance_window (suppression)  · maintenance_event (kind → rebaseline flag)
      ├──< failure_event (labelled; gates RUL)  · rul_estimate (interval or nothing)
      └──  retrain_run · config_version
```

---

## 4. Table specifications (MachineSense extension)

### 4.1 `machine_state`
One row per machine (created by trigger on `core.machine` insert): `alerts_enabled` (false until a confirmed baseline covers all contexts — AI-01), `rebaseline_required` + reason (AI-07), `current_context`, `last_scored_at`.

### 4.2 `context_rule`, `machine_context`, `derived_signal`
Context rules are **expressions over signals** (safe evaluator in the feature worker; never SQL, never model-generated) with priority and hysteresis; `machine_context` is the resulting timeline. Derived signals reference a `sensor` row with `source = 'derived'` and list their inputs, validated at config load.

### 4.3 `anomaly_model`, `anomaly_score`
A model is scoped to a machine **or** a machine type (CHECK), versioned, with the ordered feature vector, artefact hash and **retrospective metrics** (precision, lead time, false alerts/machine/month). Promotion is a status change guarded by `trg_model_promote`: metrics required and ≥ the active version's; the previous version is retired. Scores carry `contributions_json` — the attribution (AI-05).

### 4.4 `trend_estimate`
Per (sensor, feature, context): OLS slope per day over `window_days`, **80 % CI**, `pct_change`, consecutive rising days. The CI ordering is a CHECK.

### 4.5 `alert` (platform table + MachineSense columns), `alert_group`, `alert_transition`
Platform columns unchanged (`severity`, `signals_json`, `evidence_json`, `suspected_component`, `recommendation`, `rul_low_days`, `rul_high_days`, `status`). Added: `group_id`, `health_index`, `model_id`, `consecutive_windows`, `rule_code`, `rul_confidence`, **`rul_reason`**, `suppressed`.

**`evidence_json` is the contract the narrative is checked against** (API-06 §3). The seed's Appendix A row is the reference shape: per-signal `now / baseline_mean / baseline_std / sigma / pct_change / trend`, `anomaly`, `attribution[]`, `production_context`, `rul`, `similar_case`.

Grouping: one **open** `alert_group` per (machine, suspected component) (`ux_alert_group_open`); alerts attach and the group's `max_severity` rises. Every status change writes `alert_transition` (actor, channel, snooze-until, note).

### 4.6 `maintenance_window`, `failure_event`, `rul_estimate`, `retrain_run`, `workorder_draft`
- Windows: kind ∈ planned_service / changeover / warmup / commissioning; an alert whose `opened_at` falls inside must be `suppressed` (trigger).
- Failure events: labelled by an engineer with failure mode, component, downtime, cost, the alert that detected it and the **lead time** — the raw material of AC-01 and of RUL.
- RUL: `rul_interval_or_nothing` CHECK; `trg_rul_gate` counts comparable failures and stamps the count.
- Retrain runs: trigger (schedule / confirmed failure / manual), candidate vs baseline model, outcome, metrics.
- Work-order drafts: symptom, evidence, tasks, parts, priority, due; `exported_at`/`export_ref` when sent via IF-37 — never auto-posted.

### 4.7 `sample_1m`, `sensor_health`, `config_version`
`sample_1m` is the 2-year rollup (n, avg, min, max, stddev, good %) filled by `rollup_1m()` — or by a TimescaleDB continuous aggregate (OPS-06 §5.3). `sensor_health` is the scheduler's verdict on each sensor (gap/stuck/range/skew counts). `config_version` stores every loaded sensor map and alert-rules file with its hash — the answer to "which thresholds produced this alert".

---

## 5. Views

| View | Purpose |
|---|---|
| `v_machine_health_latest` | Latest health per machine with `alerts_enabled`, `rebaseline_required`, context, open incidents |
| **`v_top_risks_week`** | FR-22: risk score = (100 − health)·0.5 + 7-day drop·1.5 + criticality bonus; ordered |
| **`v_alert_precision`** | AC-08 / AI-03: TP/FP/unknown and precision per machine per month, from feedback; suppressed rows excluded |
| `v_open_incidents` | Groups with alert counts and the latest RUL interval |
| `v_sensor_health`, `v_baseline_current`, `v_data_quality_24h`, `v_retention_due` | Operations |

---

## 6. Sizing, partitioning, retention (SRS-06 §5, NFR-01, NFR-04)

| Data | Rate | Row size | Raw/day | Retention | Mechanism |
|---|---|---|---|---|---|
| `sample` | 50,000/s fleet-wide | ~40 B (+ index) | 4.3 B rows ≈ 170 GB uncompressed | **90 days** | hypertable, 1-day chunks, compression after 7 d (≈ 15×: ~1 GB/day compressed), retention policy |
| `sample_1m` | 1/min/sensor (e.g. 5,000 sensors → 7.2 M/day) | ~60 B | 430 MB/day | **2 years** | `rollup_1m()` hourly or continuous aggregate |
| `feature` | 3 names × 2 windows/sensor/hour | ~60 B | small | 2 years | hypertable, 7-day chunks |
| `anomaly_score`, `health_index` | 1/min/machine | ~200 B | small | 2 years | hypertable, 30-day chunks |
| `alert*`, `failure_event`, `maintenance_*` | events | — | — | **5 years** | none (business records) |

30-day chart ≤ 2 s (NFR-04): served from `sample_1m` (43,200 points/sensor) or `feature`, never from raw `sample`; the baseline band is two constants per context.

---

## 7. Roles and grants
| Role | Rights | Why |
|---|---|---|
| `app_rw` | rw on `core`, `telemetry`, `agent`, `ops`; insert/select on `audit` | The application |
| `telemetry_ingest` | **INSERT only** on `sample`, `alarm_event`, `data_quality_event`; SELECT `sensor`, `machine`; UPDATE `sensor.last_seen_at` | Narrowest role — an ingest process cannot read alerts or users (SEC-P30) |
| `agent_ro` | SELECT on `core` (not `app_user`/scope), `telemetry` (not `config_version` — OT endpoints and register maps) | The tool layer (SEC-P41) |
| `app_ro`, `analytics_ro` | read-only | Dashboards, exports |

---

## 8. Platform mode
The extension section is applied to the platform database as migration `machinesense_0001` (all `CREATE`s are additive; the two `ALTER TABLE … ADD COLUMN` statements extend `telemetry.alert` and `telemetry.baseline`). The hypertable conversion of an existing populated platform database follows OPS-00 RB-12, not the DO block in §15 (which drops the empty native partitions of a fresh database).

---

## 9. Demo and test dataset

[`db/seed_demo.sql`](../db/seed_demo.sql) reproduces **SRS-06 Appendix A** and gives every acceptance criterion its rows:

| Rows | Model |
|---|---|
| 3 machines: M-04 (healthy), **M-07 Injection press B** (degrading), M-11 (conveyor, one failure); 19 sensors incl. a derived `delta_t`; 9 context rules; 2 config versions | §1 |
| **820,800 one-minute rollups** (30 days × 19 sensors) from deterministic formulas: M-07 bearing temp ramps 68.9 → 78.4 °C over the last 5 days, vib RMS 2.9 → 4.9 and 2× band 0.6 → 1.1 over 6 days; others flat | FR-02, AC-03 |
| 21,600 raw samples (M-07, last hour) — exercises `rollup_1m()` | NFR-05 replay path |
| 41,040 hourly features; 2,163 hourly health points (M-07 92 → **60.87**); 241 anomaly scores rising to 0.75 | FR-04, FR-10, FR-12 |
| 18 active baselines (68.9 ± 2.1 °C, 2.9 ± 0.9 mm/s, 0.6 ± 0.2, 41.0 ± 1.5 A …), window July 2026 (31 d), engineer-confirmed | FR-08, AI-01 |
| 3 models: IF v1 retired, **IF v2 active (promoted through the trigger: 0.74 ≥ 0.68)**, AE candidate; 1 retrain run | AI-02, AI-06 |
| 4 failures: 3 × `bearing_wear` on injection presses (incl. **2025-03-18 M-04 = Genba case #212**), 1 × `belt_wear` on M-11 | FR-15 |
| **The Appendix A alert**: HIGH, health 60.87, `evidence_json` with σ 4.524 / 2.222 / 2.5 / 0.267, +13.79 %, attribution .41/.33/.18/.08, RUL **12–30 d @ 0.80 from 3 comparable failures (trigger-gated)**, similar case #212; incident group; acknowledged from Discord; work-order draft | FR-16, FR-18, FR-19, FR-21, AI-04, AI-05 |
| 24 judged historical alerts: 17 TP / 6 FP / 1 unknown → **precision 0.739** | AC-08, AI-03 |
| 1 suppressed alert inside M-04's maintenance window | AC-06, FR-14 |
| M-11 RUL row: `NULL` + "insufficient history (1 of 3 comparable failures)" | AC-07 |
| 4 maintenance events (each flags re-baselining via trigger; cleared after the confirmed July baselines), 4 data-quality events (gap, stuck, skew, out-of-range), 3 alarm events, sensor health | AI-07, FR-03, FR-07 |

**Arithmetic re-derived in Python (TC-005):** σ = (78.4 − 68.9)/2.1 = **4.524**; (4.9 − 2.9)/0.9 = **2.222**; (1.1 − 0.6)/0.2 = 2.5; (41.4 − 41.0)/1.5 = 0.267; +13.79 %; health = 100 − Σ w·f(σ) − 0.20·0.75·100 with f(σ) = 100·clamp((σ − 1)/7) and weights .35/.25/.10/.10 = **60.87**; feedback 17/6/1 → 0.739; 3 comparable failures before the alert; tallies as above.

**One SRS inconsistency**: Appendix A prints vibration σ = 2.1, but (4.9 − 2.9)/0.9 = 2.22. The seed stores the arithmetic (2.222); the SRS was not edited (README-06 known gaps) — the same treatment as ShiftBrief's Appendix A.

**Constraint probes** (the seed ends with eight statements that must each fail): alert without component; without attribution; RUL point estimate (`rul_low_days` without high); RUL interval for M-11 (1 comparable failure); activating an unconfirmed baseline; promoting v1 (0.68) over active v2 (0.74); updating feedback; an alert inside the maintenance window not marked suppressed.

**Not executed here.** README-06 gives the Docker one-liner (TimescaleDB image); expected: zero errors, the `\echo` values, eight probe failures.

---

## 10. Traceability

| SRS-06 | Implemented by |
|---|---|
| §5 data model | `machine`, `sensor`, `sample` (= `telemetry`), `feature`, `baseline`, `anomaly_score`, `health_index`, `alert`, `alert_feedback`, `maintenance_event`, `failure_event` — names kept |
| §5 retention | §6, `v_retention_due`, TimescaleDB policies |
| C-04, AI-04 | DD-P02, DD-P03 |
| C-05, AI-05 | DD-P01 |
| FR-02, FR-03 | `sample` (quality code), `data_quality_event`, `sensor_health` |
| FR-04…FR-07 | `feature`, `context_rule`, `machine_context`, `derived_signal`, `alarm_event` |
| FR-08, AI-01, AI-07 | DD-P04, DD-P08 |
| FR-09…FR-12 | `feature`/`baseline` → σ; `trend_estimate`; `anomaly_score`; `health_index` |
| FR-13 | `rul_estimate` |
| FR-14 | DD-P06 |
| FR-15, AI-06 | `failure_event`, `anomaly_model`, `retrain_run`, DD-P05 |
| FR-16…FR-20, FR-22 | `alert*`, `v_top_risks_week`, `v_alert_precision` |
| FR-21 | `workorder_draft` |
| FR-24 | `alert_group.genba_case_id`, evidence `similar_case` |
| AI-08 | `evidence_json` (§4.5) |
| NFR-01, NFR-04, NFR-05 | DD-P09, §6 |
| NFR-06 | `telemetry_ingest` role, `config_version` restricted from `agent_ro` |
| NFR-09 | `data_quality_event` (skew) |
| AC-01…AC-08 | seed §9 |

## Appendix A — The constraints that carry the weight
| Constraint | Protects against |
|---|---|
| `trg_alert_actionable` | An alert that tells a technician nothing |
| `rul_interval_or_nothing` + `trg_rul_gate` | A single-number RUL; a RUL from one failure |
| `trg_baseline_activate` + `ux_baseline_active` | A degraded-period baseline; two "current" baselines |
| `trg_model_promote` + `ux_anomaly_model_active_*` | A regression promoted; two active models |
| `trg_alert_suppression` | Silent suppression |
| `trg_feedback_immutable` | Rewriting the precision record |
| `trg_alert_transition_log` | An untraceable ack/snooze/escalate |
| `trg_maintenance_rebaseline` | Alerting against a pre-repair baseline |
| PK `(sensor_id, ts)` on `sample` | Duplicate samples on replay |
