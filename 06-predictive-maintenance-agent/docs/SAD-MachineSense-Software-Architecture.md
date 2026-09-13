# Software Architecture Document — MachineSense AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | SAD-06-MachineSense |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-06](../SRS-MachineSense-Predictive-Maintenance.md) |
| Platform relationship | **Standalone-deployable**; the telemetry, health and predictive-alert module of [FactoryBrain (SAD-00)](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) in platform mode — owns the `telemetry` schema (tight coupling, SAD-00 §13) |
| Related | [DDS-06](DDS-MachineSense-Database-Design.md) · [API-06](../api/API-Specification.md) · [ICD-06](ICD-MachineSense-Interface-Control.md) · [SEC-06](SEC-MachineSense-Security-Requirements.md) · [TEST-06](TEST-MachineSense-Test-Plan.md) · [OPS-06](OPS-MachineSense-Deployment-Operations.md) · [UM-06](UM-MachineSense-User-Admin-Guide.md) |

---

## 1. Introduction

### 1.1 Purpose
The architecture of **MachineSense**: a system that turns machine telemetry into **actionable, uncertain, explainable** maintenance advice. It ingests signals from MQTT, OPC-UA, Modbus and files; computes features per machine context; establishes engineer-confirmed healthy baselines; scores deviation, multivariate anomaly and degradation trend; produces a per-machine health index and alerts that name a component and an inspection; closes the loop with technician feedback; and lets a local LLM *explain* — never compute.

### 1.2 What makes this project different from its siblings
| Sibling | Judges | MachineSense |
|---|---|---|
| VisionOps / EdgeGuard | a *part*, now, from an image | a *machine*, over weeks, from numbers |
| ShiftBrief | yesterday's production, from a file | continuous streams at up to 50,000 samples/s |
| OpsPilot | servers, with approval-gated actions | machines, **with no action path at all** (C-01) |

Three things follow. **The numbers are the product**: every value in an alert — now, baseline, σ, % change, slope with confidence interval, RUL interval — is computed by the scoring engine and stored as `evidence_json`; the model explains from that and nothing else (AI-08). **Uncertainty is mandatory**: a RUL is an interval or the words "insufficient history" (C-04, AI-04); a trend has a confidence interval; a cause is a hypothesis with a likelihood (FR-26). **The loop must close**: an alert nobody gives feedback on cannot be tuned, and alert fatigue kills the programme (FR-20, AC-08).

### 1.3 Two ways to deploy it
**Standalone** — one `docker compose up` next to the OT network: TimescaleDB, brokers/ingest, workers, API, web, Ollama. **Platform mode** — the same ingest, feature, scoring, alerting and agent workers run inside FactoryBrain; the database, auth, LLM and Copilot are the platform's; MachineSense's tools register into the platform registry and its alerts feed KaizenSwarm and QE-Agent (§9).

### 1.4 Related documents
Platform principles P-1…P-4 ([SAD-00 §5.1](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md)); the grounding post-check (SAD-00 ADR-013) reused unchanged; IF-04/05/06 ([ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-04)); Genba Memory retrieval ([SRS-15](../../15-troubleshooting-memory/SRS-GenbaMemory-Troubleshooting-RAG.md)) for similar past cases (FR-24).

---

## 2. Architecture principles

| Principle | On MachineSense |
|---|---|
| **P-1 The LLM never computes numbers** | The scoring engine computes; `evidence_json` stores; the model receives *only* that document plus baselines and similar cases (AI-08). The explanation is post-checked: every number must be a value in the evidence, or the explanation is withheld (AC-04). |
| **P-2 Offline-first** | Ingest buffers ≥ 24 h locally and replays (NFR-05, AC-05). With Ollama down, alerts, evidence, charts and the structured recommendation still exist — only the prose is missing. |
| **P-3 Human-in-the-loop** | Advisory only — there is **no write path to any machine** (C-01, ADR-P09). Baselines are confirmed by an engineer (never auto-captured). Alerts are acknowledged, snoozed, escalated and *judged* (feedback) by people; work orders are drafts. |
| **P-4 Database is the source of truth** | Samples, features, baselines, scores, alerts with evidence, feedback and failures are rows; the Discord card, the chart and the narrative are views of them. A precision report is a query, not a dashboard artefact. |

MachineSense adds one:

| Principle | Meaning |
|---|---|
| **P-6 An alert without a component, an inspection and an uncertainty is not an alert** | The database refuses an alert with an empty `suspected_component`, an empty `recommendation` or empty attribution; RUL is an interval or NULL (C-05, AI-05, AI-04). |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-06 §2.4)
| ID | Constraint | Consequence |
|---|---|---|
| C-01 | Strictly advisory; no control write-back | No tool, endpoint or protocol client can write to a machine; OPC-UA accounts are read-only *server-side* (IF-05) |
| C-02 | OPC-UA/Modbus read-only dedicated accounts | Credentials per machine, audited connections (NFR-06) |
| C-03 | ≥ 10 kHz vibration reduced to features at the edge | The DAQ publishes the IF-38 feature contract; the store holds features and short snapshots only |
| C-04 | Predictions always with uncertainty | `rul_low_days/rul_high_days` CHECK; trend `slope_ci`; likelihood language (FR-26) |
| C-05 | Every alert names a component/inspection point | DB trigger on `telemetry.alert` (DDS-06) |

### 3.2 Quality attributes
| Attribute | Driver | Design response |
|---|---|---|
| **Throughput** | NFR-01 50 k samples/s | Batched inserts (COPY), TimescaleDB hypertables + compression, per-source ingest workers, no per-row triggers on `sample` |
| **Lag** | NFR-02 ≤ 60 s features; NFR-03 alert ≤ 5 min | Streaming windows in the feature worker; scoring every 60 s; N = 3 consecutive windows → ≤ 3 min + delivery |
| **Query speed** | NFR-04 30-day chart ≤ 2 s | 1-min continuous aggregates; baseline band precomputed |
| **Durability** | NFR-05, AC-05 | Local WAL queue per ingest process; idempotent replay (`(sensor_id, ts)` primary key) |
| **Precision** | AI-03 ≥ 0.7, ≤ 1 false alert/machine/month | N-consecutive rule, context-aware baselines, suppression windows, grouping, feedback-driven tuning |
| **Explainability** | AI-05, FR-23, FR-26 | Attribution stored per alert; evidence contract; likelihood vocabulary |
| Availability independence | NFR-07 | Machines never depend on MachineSense; ingest is read-only and fire-and-forget on the machine side |
| Testability | NFR-08 ≥ 80 % on features and scoring | Pure functions over arrays; golden fixtures; the seed's arithmetic |

### 3.3 Not drivers
Machine control; safety functions; replacing a CMMS (integration only, IF-37); vision inspection (01/03); raw-waveform storage at scale.

---

## 4. Views

### 4.1 Context view

```
 Machines ─┬─ MQTT (IF-04) ──────────┐
           ├─ OPC-UA read-only (IF-05)┤        ┌───────────────────────────────────────────────┐
           ├─ Modbus (IF-06) ─────────┼──────► │                 MachineSense                  │
 DAQ edge ─┴─ features (IF-38) ───────┘        │ ingest+buffer → features/context → baseline    │
 Files ───── CSV/Parquet (IF-36) ─────────────►│ → scoring (σ, anomaly, trend, health, RUL)    │
                                               │ → alerts (N windows, grouping, suppression)   │
 Technician / planner / manager / engineer ◄──►│ → agent (explain, ask, work-order draft)      │
        Discord (IF-08) · email/webhook (IF-13)│                                               │
 CMMS ◄─────────── work-order export (IF-37) ──┤ Ollama (IF-09) · Genba Memory (search_memory) │
 Platform (IF-19, platform mode) ◄────────────►└───────────────────────────────────────────────┘
```

| Actor / system | Interface | Notes |
|---|---|---|
| Machine gateways | [IF-04](ICD-MachineSense-Interface-Control.md#if-04) | Telemetry and alarms; QoS; ACLs |
| Controllers (OPC-UA) | [IF-05](ICD-MachineSense-Interface-Control.md#if-05) | **Read-only account — the C-01 enforcement point** |
| Legacy devices (Modbus) | [IF-06](ICD-MachineSense-Interface-Control.md#if-06) | Isolated segment; risk accepted |
| Vibration DAQ | [IF-38](ICD-MachineSense-Interface-Control.md#if-38) | Features, not waveforms |
| Historian / files | [IF-36](ICD-MachineSense-Interface-Control.md#if-36) | CSV/Parquet import |
| People | [IF-08](ICD-MachineSense-Interface-Control.md#if-08), web UI | Alert cards with ack/snooze/escalate; feedback |
| CMMS | [IF-37](ICD-MachineSense-Interface-Control.md#if-37) | Work-order drafts |
| LLM | [IF-09](ICD-MachineSense-Interface-Control.md#if-09) | Evidence-only prompts |
| Platform | [IF-19](ICD-MachineSense-Interface-Control.md#if-19) | Platform mode |

### 4.2 Container view

```
┌─ MachineSense standalone stack ───────────────────────────────────────────────────────┐
│  OT-facing:   ingest-mqtt · ingest-opcua · ingest-modbus · import (files)  ──► buffer │
│  Pipeline:    features (windows, context, derived) ──► scoring (σ/EWMA · IF/AE ·       │
│               trend+CI · health index · RUL gate) ──► alerting (N windows · grouping · │
│               suppression · delivery · lifecycle)                                      │
│  People:      api (FastAPI) · web (Next.js) · discord-bot · agent (explain/ask/WO)     │
│  Ops:         scheduler (retrain · retention · weekly risks · sensor health)           │
│  State:       postgres-timescale · redis · mosquitto · ollama                          │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

| Container | Tech | Responsibility | Network |
|---|---|---|---|
| `ingest-mqtt` | Python, paho | Subscribe, validate, quality codes, gap/stuck/range checks, buffer | OT + internal |
| `ingest-opcua` | Python, asyncua | Read-only sessions, monitored items, reconnect | OT + internal |
| `ingest-modbus` | Python, pymodbus | Poll register maps, stuck detection | OT + internal |
| `import` | Python | CSV/Parquet with dedup and quality | internal |
| `buffer` (library in each ingest) | SQLite WAL queue | ≥ 24 h at 50 k/s per process; replay | local disk |
| `features` | Python, NumPy | Rolling windows per context, derived signals, DAQ feature pass-through | internal |
| `scoring` | Python, scikit-learn, (PyTorch AE optional) | σ/EWMA, IF/AE with attribution, trend + CI, health index, RUL gate | internal |
| `alerting` | Python | Consecutive-window state, severity ladder, grouping, suppression, delivery, lifecycle | internal + egress (Discord/SMTP/webhook) |
| `agent` | Python + Ollama | Explanation, Q&A tools, work-order draft; grounding post-check | internal |
| `scheduler` | Python | Retrain (AI-06), retention, weekly top risks, sensor health, precision report | internal |
| `api`, `web`, `discord-bot` | FastAPI, Next.js, discord.py | People-facing | internal + LAN / egress |
| `postgres-timescale`, `redis`, `mosquitto`, `ollama` | | State, queues, broker, LLM | internal |

**Process model.** Ingest processes are independent per protocol and per plant segment; each owns a local buffer so a database outage never stalls a subscription. Feature and scoring workers are stateless over the database (any can restart); alert state (consecutive windows) lives in Redis with a database record on every transition.

### 4.3 Component view

#### 4.3.1 Ingest and buffer (FR-01…FR-03, NFR-05)
```
source ─► parse ─► validate (sensor known, unit, quality code) ─► checks: gap (> 3× expected interval) · stuck (identical N=30) · range · clock skew > 5 s
       ─► data_quality_event on failure (value still stored with quality < 192 unless out of physical range)
       ─► local WAL queue (SQLite, fsync per batch) ─► COPY to telemetry.sample in 5,000-row batches ─► ack queue
```
Replay after an outage is idempotent (`PRIMARY KEY (sensor_id, ts)` — duplicates are dropped on conflict). Alarm logs (FR-07) parse into `alarm_event`.

#### 4.3.2 Context classification (FR-05)
Per machine, from the sensor map's `context` rules (e.g. `running: rpm > 200 AND current > 5 A`, `changeover: plc_tag = 'CHG'`), with hysteresis (state must hold 60 s). Every feature carries its context; **a baseline exists per context or not at all** (ADR-P02).

#### 4.3.3 Feature pipeline (FR-04, FR-06)
Windows of 60 s (fast) and 600 s (trend): mean, std, min, max, RMS, kurtosis, crest factor; vibration FFT band energies arrive precomputed from the DAQ (IF-38) and are stored as features (`vib_band_1x`, `vib_band_2x`, …, referenced to RPM). Derived signals are expressions in the sensor map (`delta_t = bearing_temp - ambient_temp`), evaluated by a safe expression engine (no code execution).

#### 4.3.4 Baseline (FR-08, AI-01, AI-07)
An engineer selects a healthy window ≥ 4 weeks covering all normal contexts; the system computes mean/std/p95 per (sensor, context, feature) and stores a **versioned** baseline that is inert until **confirmed** (`confirmed_by`, DDS-06 trigger). A maintenance event of kind `component_replaced` (or any confirmed failure repair) marks the machine `rebaseline_required`; alerts for that machine are downgraded to WATCH until a new baseline is confirmed (ADR-P03).

#### 4.3.5 Scoring (FR-09…FR-13, AI-02, AI-04, AI-05)
Every 60 s per machine:
```
σ_i      = (feature_i − baseline.mean_i) / baseline.std_i             per signal/feature, current context
ewma_i   = λ·x + (1−λ)·ewma_prev, λ = 0.2                              smoothed trend
anomaly  = model.score(feature_vector) → [0,1] + attribution (per-feature contribution; IF: path-length deltas; AE: reconstruction error per input)
trend    = OLS slope over N days (default 5) with 80 % CI; pct_change = (now − mean_window_start)/mean_window_start
health   = 100 − Σ w_i · f(σ_i) − w_a · anomaly·100, weights from alert rules; clamped [0, 100]
RUL      = only if ≥ 3 comparable failures exist for the machine's type+failure mode and the trend is monotonic:
           interval from the empirical distribution of time-to-failure at the current health (80 %), else NULL + reason
```
All of it is written: `anomaly_score` (score + `contributions_json`), `health_index` (value + `components_json`), and — when an alert opens — `evidence_json` with every number the narrative may cite.

#### 4.3.6 Alert engine (FR-14, FR-16…FR-19, FR-22)
```
window violates? (σ ≥ threshold OR anomaly ≥ threshold OR trend CI excludes 0 with pct_change ≥ x)
  ─► consecutive counter (Redis) ≥ N (default 3)  ─► suppression? (maintenance window · changeover · startup ≤ 30 min) ─► suppressed event
  ─► severity ladder (WATCH σ≥2 · HIGH σ≥3 or anomaly≥0.7 · CRITICAL σ≥4.5 or health<40)
  ─► grouping: open incident for (machine, suspected_component)? → attach, escalate severity if higher · else new alert + incident
  ─► evidence_json built · attribution required · suspected_component + recommendation from the rule/attribution map
  ─► deliver (Discord card, email) ─► lifecycle: open → acknowledged | snoozed(until) | escalated → resolved | dismissed  (transitions audited)
  ─► on close: feedback prompt (true/false positive/unknown + actual finding) → precision report
```
Weekly: `v_top_risks_week` ranks machines by health trend, open incidents and criticality (FR-22).

#### 4.3.7 Agent (FR-23…FR-27, AI-08)
```
explain(alert) ─► evidence bundle = evidence_json + baselines used + attribution + similar cases (search_memory, FR-24) + production context (flat/rising)
              ─► LLM (versioned prompt): plain language, cite every number from the bundle, hypotheses with likelihood, required verification, inspection steps
              ─► post-check: every numeric token ∈ bundle values (tolerance for rounding) else withhold; language TH/JA/EN
ask(question) ─► typed tools over the store (get_machine_health, get_series_summary, list_top_risks, get_alert_evidence, list_failures, search_memory) → facts → narrative → post-check
draft_workorder(alert) ─► structured draft (machine, symptom, evidence, suggested tasks/parts from the attribution map) → PDF/JSON → IF-37
```
The model never sees a raw series (AI-08) and never states a cause as certain (FR-26 — the prompt and a lexical check on "is caused by" phrasing).

#### 4.3.8 Feedback loop (FR-20, AC-08, AI-06)
Every closed alert requires an outcome. The precision report per machine/rule/month drives threshold suggestions (raise N or σ where false positives cluster) and retraining: scheduled monthly and after any confirmed failure; a new model version is promoted only if its metrics on the retrospective set are ≥ the current one's (ADR-P06).

### 4.4 Runtime views

#### 4.4.1 Appendix A alert, end to end (NFR-02, NFR-03)
```
t=0        bearing_temp sample 78.4 °C arrives (MQTT) → buffer → sample                      (< 1 s)
t≤60 s     features: 60 s window mean 78.4; context running                                 (lag ≤ 60 s)
t≤120 s    scoring: σ = (78.4−68.9)/2.1 = 4.52 ; vib_rms σ = (4.9−2.9)/0.9 = 2.22 ; anomaly 0.81 ; trend +13.8 %/5 d CI [9.1, 18.4] ; health 61
t≤240 s    3rd consecutive violating window → not suppressed → CRITICAL? no: HIGH (σ 4.52 ≥ 3, health 61 ≥ 40) → new incident (M-07, drive-side bearing)
t≤300 s    evidence_json written; Discord card + email delivered                              (≤ 5 min)
t+2 min    technician taps Explain → agent narrative, post-checked (every number from evidence)
t+5 min    Ack → inspection within 3 days → resolved with feedback: true_positive, "lubrication loss, bearing replaced"
next day   maintenance_event component_replaced → rebaseline_required → engineer confirms a new window 4 weeks later
```

#### 4.4.2 Database down for 6 h (AC-05)
Ingest keeps subscribing; buffer fills (≈ 1.1 GB/h at 50 k/s compressed); on recovery COPY replays in order; duplicates dropped by the primary key; a data-quality event records the outage; feature workers catch up (lag alert while > 60 s).

#### 4.4.3 Maintenance window (AC-06)
Planner declares a window for M-07 (2026-09-20 08:00–12:00) → any violating window inside it → `suppressed` event, no alert; suppression is visible on the chart; after the window, counters restart from zero.

#### 4.4.4 RUL insufficient (AC-07)
M-11 has one comparable failure → `rul_estimate` row with `low/high = NULL`, `reason = insufficient_history (1 of 3)`; the card and the narrative say exactly that.

#### 4.4.5 Synthetic ramp (AC-03)
Test injects +0.5 °C/day on M-04 bearing temp for 10 days → attribution ranks `bearing_temp_mean` first → alert names the drive-side bearing → engineer sees the ramp on the chart with the baseline band.

#### 4.4.6 Retrain after a confirmed failure (AI-06)
Feedback `true_positive` + failure event labelled → scheduler queues a retrain run → new IF/AE version evaluated on the retrospective set → promoted only if precision and lead time ≥ current → recorded in `retrain_run`.

### 4.5 Deployment view

| Aspect | Standalone | Platform mode |
|---|---|---|
| Host | On-prem server, 8 cores / 32 GB / NVMe; ingest may run on a second host near the OT segment | Platform host + ingest host |
| Database | TimescaleDB (PostgreSQL 16 + timescaledb) — hypertables, compression, continuous aggregates; native partitioning fallback | Platform DB; hypertable migration per OPS-00 RB-12 |
| Networks | `ot` (ingest ↔ machines, isolated), `internal`, `egress` (Discord/SMTP/webhook) | Platform's zones |
| LLM | Ollama ≤ 9 B; optional GPU | Platform's |
| Model | scikit-learn IF on CPU; AE optional on GPU | same |

### 4.6 Data view
Owned by [DDS-06](DDS-MachineSense-Database-Design.md). Shared objects byte-identical to the platform; MachineSense additions under `telemetry` (migration `machinesense_0001`).

---

## 5. Cross-cutting concerns

| Concern | Position |
|---|---|
| Identity & roles | viewer / technician / planner / engineer / admin (platform roles map: viewer, engineer, manager, admin) |
| OT credentials | Per machine, read-only, in secrets files; connections audited (NFR-06) |
| Configuration | `sensors.yaml` (sensor map, contexts, derived signals) and `alert-rules.yaml` (thresholds, N, weights, severity ladder, suppression) — schema-validated, versioned, loaded into the DB with a version stamp |
| Time | All sources NTP-synced; skew > 5 s → data-quality event (NFR-09); UTC storage; plant-local display |
| Observability | Ingest rate, buffer depth, feature lag, scoring lag, alerts/day, precision; alerts about MachineSense itself |
| Logging | No raw series in logs; no OT credentials |
| i18n | Narratives TH/JA/EN (FR-27); signal names and codes English |

---

## 6. Alert precision and fatigue — the design's own risk

The programme dies if technicians stop trusting it. The architecture's answers, in order of leverage: context-aware baselines (idle vs running is the largest false-positive source); N consecutive windows; suppression windows; grouping into one incident per (machine, component); severity that rises rather than repeats; mandatory feedback with a monthly precision report; threshold suggestions from that report; retraining gated by metrics. AI-03's targets (precision ≥ 0.7, ≤ 1 false alert per machine per month) are measured by `v_alert_precision`, not estimated.

---

## 7. Architecture Decision Records

### ADR-P01 — TimescaleDB by default, native partitioning as the fallback
**Context.** 50 k samples/s, 30-day charts ≤ 2 s. **Decision.** Hypertables with compression (after 7 days) and continuous aggregates (1-min); the platform's ADR-007 makes this optional — here it is the default, with the same DDL running on plain PostgreSQL via native partitions. **Consequences.** ✅ 10–20× compression, fast rollups; ❌ one more extension to operate.

### ADR-P02 — Features and baselines exist per context or not at all
**Context.** Comparing a running machine to an idle baseline is the main source of false alerts. **Decision.** Every feature row carries `context`; a baseline is keyed by context; a window with `context = stopped`/`startup` never scores. **Consequences.** ✅ precision; ❌ contexts must be configured per machine.

### ADR-P03 — Baselines are engineer-confirmed and versioned; re-baseline after service
**Context.** A baseline captured while already degraded normalises the fault. **Decision.** `confirmed_by` required (trigger); component replacement sets `rebaseline_required`; alerts downgraded until confirmed. **Consequences.** ✅ no silent normalisation; ❌ 4 weeks of WATCH-only after a repair.

### ADR-P04 — N consecutive violating windows before an alert
**Context.** FR-17. **Decision.** N default 3 (≈ 3 min at 60 s windows), configurable per rule; counters in Redis, transitions in the DB. **Consequences.** ✅ spikes filtered; ❌ ≥ 3 min added latency — within NFR-03.

### ADR-P05 — RUL is an interval or nothing, gated by ≥ 3 comparable failures
**Context.** C-04, AI-04. **Decision.** `rul_estimate(low, high, confidence, reason)`; a trigger refuses low/high without ≥ 3 comparable failures; the platform's `rul_interval_ordered` CHECK already forbids inverted intervals. **Consequences.** ✅ no over-promising; ❌ most machines show "insufficient history" for a year — honest.

### ADR-P06 — Models are versioned and promoted only on metrics
**Context.** AI-02, AI-06. **Decision.** `anomaly_model` rows with metrics on the retrospective set; promotion trigger requires precision and lead time ≥ the active version. **Consequences.** ✅ no regressions; ❌ a retrospective set must exist.

### ADR-P07 — Attribution is mandatory on every alert
**Context.** AI-05, C-05. **Decision.** `evidence_json.attribution` non-empty (trigger); the attribution → component map in the alert rules yields `suspected_component` and `recommendation`. **Consequences.** ✅ every alert is actionable; ❌ new signals need a map entry.

### ADR-P08 — The LLM receives evidence_json only and is post-checked
**Context.** AI-08, FR-23, AC-04. **Decision.** Same mechanism as ShiftBrief (ADR-S01/S03): one structured input; numeric tokens in the output must match values in it; otherwise withheld with the structured recommendation shown instead. **Consequences.** ✅ AC-04 by construction; ❌ occasional withheld narratives.

### ADR-P09 — Advisory only: no write path exists
**Context.** C-01, C-02. **Decision.** No tool, endpoint or client can write to a machine; OPC-UA accounts are read-only at the server; Modbus uses read function codes only; a `run_shell`-style or `opcua_write` tool is on a permanent deny-list in the registry. **Consequences.** ✅ the system cannot cause a machine action; ❌ automated remediation is out of scope (intended).

### ADR-P10 — One incident per (machine, suspected component)
**Context.** FR-18. **Decision.** Alerts group into `alert_group`; a new violation on the same component attaches and may escalate severity; the card is edited, not duplicated. **Consequences.** ✅ no floods; ❌ different components on one machine remain separate cards — intended.

---

## 8. Quality attribute scenarios

| ID | Scenario | Measure | Traces |
|---|---|---|---|
| QAS-01 | Fleet at 50 k samples/s | Sustained ingest; feature lag ≤ 60 s | NFR-01, NFR-02 |
| QAS-02 | Degradation condition met | Alert ≤ 5 min with component, inspection, attribution | NFR-03, C-05, AI-05 |
| QAS-03 | 30-day chart | ≤ 2 s p95 | NFR-04 |
| QAS-04 | DB down 6 h | 0 samples lost after replay | NFR-05, AC-05 |
| QAS-05 | Retrospective replay of ≥ 5 failures | ≥ 3 detected with ≥ 3 days lead | AC-01, AI-03 |
| QAS-06 | Healthy machine 30 days | ≤ 1 false alert | AC-02, AI-03 |
| QAS-07 | Synthetic ramp | Detected and attributed to the right signal | AC-03 |
| QAS-08 | Explanation | Every number retrievable from the store | AC-04, AI-08 |
| QAS-09 | Scheduled service | No alerts inside the window | AC-06, FR-14 |
| QAS-10 | One historical failure | "insufficient history for RUL" | AC-07, AI-04 |
| QAS-11 | 20 closed alerts | Precision report produced | AC-08, FR-20 |
| QAS-12 | Component replaced | Re-baseline required; alerts downgraded until confirmed | AI-07 |

---

## 9. Platform mode

| Aspect | Standalone | Platform mode |
|---|---|---|
| Schema | `db/schema.sql` (shared objects byte-identical) | Platform schema + migration `machinesense_0001` (the extension tables) |
| Auth, users | Own `core.app_user` | Platform's |
| Agent tools | Own registry | Registered into the platform registry: `get_machine_telemetry` (exists in IF-16) + `get_machine_health`, `get_alert_evidence`, `list_top_risks`, `list_failures` |
| Alerts → siblings | Discord/email | Also `quality.signal` for QE-Agent (09); KaizenSwarm (13) Maintenance Agent reads `v_top_risks_week`; Genba Memory (15) receives closed incidents as cases |
| LLM | Own Ollama | Platform's, with the GPU semaphore |
| Ingest | Own brokers/clients near OT | Same containers, platform network zones |

---

## 10. Risks and technical debt

| Risk | Mitigation | Residual |
|---|---|---|
| Not enough failures for supervised models / RUL | Unsupervised first; RUL gated; label as failures accumulate | RUL rarely available in year 1 |
| Alert fatigue | §6 | Culture |
| Sensor faults look like machine faults | Data-quality events, stuck detection, sensor health view | Slow sensor drift |
| Baseline during degraded period | Engineer confirmation, re-baseline rule | Engineer error |
| Vibration volume | Edge features (IF-38); snapshots only | DAQ vendor lock-in |
| Small LLM misreads evidence | Post-check; structured fallback | Withheld narratives |

Debt: autoencoder path optional in v1; CMMS adapter is a webhook contract, not a vendor integration; FFT computed only at the DAQ.

---

## 11. Traceability to SRS-06

| SRS-06 | Architecture |
|---|---|
| C-01, C-02 | ADR-P09, IF-05 |
| C-03 | §4.3.3, IF-38 |
| C-04 | ADR-P05, §4.3.5 |
| C-05 | ADR-P07, P-6 |
| FR-01…FR-03 | §4.3.1 |
| FR-04, FR-06 | §4.3.3 |
| FR-05 | §4.3.2 |
| FR-07 | §4.3.1 (`alarm_event`) |
| FR-08, AI-01, AI-07 | §4.3.4, ADR-P03 |
| FR-09…FR-13, AI-02, AI-04, AI-05 | §4.3.5 |
| FR-14, FR-16…FR-19, FR-22 | §4.3.6, ADR-P04, ADR-P10 |
| FR-15, AI-06 | §4.3.8, ADR-P06 |
| FR-20, FR-21 | §4.3.8, §4.3.7 |
| FR-23…FR-27, AI-08 | §4.3.7, ADR-P08 |
| NFR-01…NFR-09 | §3.2 |
| AC-01…AC-08 | §4.4, §8 |
