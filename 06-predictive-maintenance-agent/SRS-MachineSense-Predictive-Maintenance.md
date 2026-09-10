# Software Requirements Specification — AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | SRS-06-MachineSense |
| Project code name | **MachineSense** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify a system that ingests machine telemetry (temperature, vibration, current, RPM, cycle counts, alarm logs), detects abnormal degradation with time-series models, and uses an LLM agent to explain the finding and recommend an inspection — moving maintenance from reactive to condition-based.

### 1.2 Scope

**In scope**
- Telemetry ingestion via MQTT / OPC-UA / Modbus / CSV.
- Signal processing: resampling, feature extraction (RMS, kurtosis, crest factor, FFT bands).
- Baseline modelling, anomaly detection, trend/degradation estimation.
- Alerting with severity and recommended inspection point.
- Maintenance event log and feedback loop (was the alert useful?).
- LLM agent for explanation, Q&A and work-order draft.

**Out of scope**
- Machine control or automatic shutdown (advisory only).
- Safety-instrumented functions.
- CMMS replacement — integration only.
- Vision-based inspection (SRS-01/03).

### 1.3 Definitions
**RUL** = Remaining Useful Life. **Baseline** = healthy-state statistics for a machine/signal/context. **σ-score** = deviation from baseline in standard deviations. **Health index** = 0–100 composite score per machine.

---

## 2. Overall Description

### 2.1 Product perspective
```
Machine sensors ─┐
  temperature    │  MQTT / OPC-UA / Modbus
  vibration      ├──►  Ingest & Buffer  ──►  Time-series store
  current        │                             (TimescaleDB)
  RPM            │                                 │
  cycle count    │                         Feature Extraction
  alarm log     ─┘                        (RMS, kurtosis, FFT bands)
                                                   │
                             ┌─────────────────────┼──────────────────┐
                             ▼                     ▼                  ▼
                     Baseline / SPC        Anomaly models       Degradation
                     (σ-score, EWMA)   (IF · autoencoder · OC-SVM)  trend / RUL
                             └─────────────────────┼──────────────────┘
                                                   ▼
                                       Health index + alert
                                                   ▼
                                    LLM agent → explanation + action
                                                   ▼
                                  Dashboard · Discord · work-order draft
```

### 2.2 User classes
| Class | Need |
|---|---|
| Maintenance technician | what to inspect, where, how urgent |
| Maintenance planner | ranked risk list for scheduling |
| Production manager | downtime risk for the coming shift/week |
| Reliability engineer | trends, model tuning, failure history |
| Admin | sensors, thresholds, model lifecycle |

### 2.3 Operating environment
On-prem server, Docker, TimescaleDB (PostgreSQL extension), MQTT broker, optional edge gateway for high-rate vibration. Local LLM (Ollama, ≤ 9 B). Vibration sampling may be handled by a dedicated DAQ/edge device that publishes features rather than raw waveforms.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | The system SHALL be strictly advisory. No control write-back to machines in v1. |
| C-02 | OPC-UA/Modbus access SHALL be read-only with a dedicated account. |
| C-03 | High-rate raw vibration (≥ 10 kHz) SHALL be reduced to features at the edge; only features and short snapshots are stored centrally. |
| C-04 | Predictions SHALL always be presented with uncertainty; a single-number RUL without a confidence interval is not acceptable. |
| C-05 | Alerts SHALL be actionable: every alert names a component/inspection point. |

### 2.5 Assumptions
At least 4 weeks of healthy-state data can be collected before baselining; machine context (running/idle/changeover) is derivable from RPM/current or a PLC tag; maintenance actions are recorded (manually is acceptable).

---

## 3. Functional Requirements

### 3.1 Ingestion & signal processing
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Ingest telemetry via MQTT (JSON/sparkplug), OPC-UA subscription, Modbus poll and CSV import. | Must |
| FR-02 | Persist raw samples with (machine_id, signal, ts, value, quality) at the configured rate. | Must |
| FR-03 | Detect and record gaps, stuck values (identical for N samples), and out-of-range values as data-quality events. | Must |
| FR-04 | Compute rolling features per window: mean, std, min, max, RMS, kurtosis, crest factor, and FFT band energies for vibration. | Must |
| FR-05 | Classify machine context (running / idle / changeover / stopped) and compute features per context. | Must |
| FR-06 | Support derived signals (e.g. ΔT = bearing_temp − ambient_temp) via configurable expressions. | Should |
| FR-07 | Parse machine alarm/error logs into a normalised event stream. | Should |

### 3.2 Modelling & detection
| ID | Requirement | Priority |
|---|---|---|
| FR-08 | Establish a healthy baseline per (machine, signal, context) from a labelled healthy window. | Must |
| FR-09 | Compute a σ-score and EWMA-smoothed trend per signal against the baseline. | Must |
| FR-10 | Run multivariate anomaly detection (Isolation Forest and/or autoencoder) over the feature vector. | Must |
| FR-11 | Estimate degradation trend (slope, % change over N days) with a confidence interval. | Must |
| FR-12 | Produce a per-machine health index (0–100) combining signal deviations, weighted by configuration. | Must |
| FR-13 | Estimate RUL where a monotonic degradation pattern and prior failures exist; otherwise report "insufficient history for RUL". | Should |
| FR-14 | Suppress alerts during known maintenance windows, changeovers and warm-up periods. | Must |
| FR-15 | Support labelled failure events to enable supervised classification of failure modes. | Should |

### 3.3 Alerting & workflow
| ID | Requirement | Priority |
|---|---|---|
| FR-16 | Generate alerts with: machine, signal(s), severity (INFO/WATCH/HIGH/CRITICAL), evidence, suspected component, recommended inspection. | Must |
| FR-17 | Require N consecutive violating windows before alerting (configurable) to limit noise. | Must |
| FR-18 | De-duplicate and group related alerts into one incident per machine per issue. | Must |
| FR-19 | Deliver alerts to Discord/email with a link to the chart and allow acknowledge / snooze / escalate. | Must |
| FR-20 | Record technician feedback on every closed alert: true positive / false positive / unknown, plus the actual finding. | Must |
| FR-21 | Draft a work order (machine, symptom, evidence, suggested parts/tasks) for export to CMMS or PDF. | Should |
| FR-22 | Present a ranked "top risks this week" list. | Must |

### 3.4 Agent & explanation
| ID | Requirement | Priority |
|---|---|---|
| FR-23 | The agent SHALL explain any alert in plain language, citing the measured values and baselines used. | Must |
| FR-24 | The agent SHALL retrieve similar historical events and their resolutions (links to [Genba Memory, SRS-15](../15-troubleshooting-memory/SRS-GenbaMemory-Troubleshooting-RAG.md)). | Should |
| FR-25 | The agent SHALL answer questions such as "which machines are degrading fastest this month?" using tools over the time-series store. | Must |
| FR-26 | The agent SHALL never state a physical root cause as certain; it SHALL phrase hypotheses with likelihood and required verification. | Must |
| FR-27 | Output SHALL be available in Thai / Japanese / English. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/telemetry` | push samples (batch) |
| GET | `/api/v1/machines/{id}/health` | health index + component breakdown |
| GET | `/api/v1/signals?machine=&signal=&from=&to=` | series + baseline band |
| GET | `/api/v1/alerts?status=` | alert list |
| POST | `/api/v1/alerts/{id}/feedback` | technician outcome |
| POST | `/api/v1/agent/explain/{alert_id}` | narrative explanation |
| POST | `/api/v1/workorders/draft` | work-order draft |

### 4.2 Protocols
MQTT 3.1.1/5 (TLS optional on LAN), OPC-UA binary (read-only session), Modbus TCP, CSV/Parquet import, webhook out.

---

## 5. Data Requirements

```sql
machine(id, code, name, line_id, type, install_date, criticality)
sensor(id, machine_id, signal, unit, sample_rate_hz, source, active)
telemetry(ts, sensor_id, value, quality)                -- hypertable
feature(ts, sensor_id, window_s, context, name, value)  -- hypertable
baseline(sensor_id, context, name, mean, std, p95, window_from, window_to, version)
anomaly_score(ts, machine_id, model_version, score, contributions_json)
health_index(ts, machine_id, value, components_json)
alert(id, opened_at, machine_id, severity, signals_json, evidence_json,
      suspected_component, recommendation, status, closed_at)
alert_feedback(alert_id, outcome, actual_finding, technician_id, ts)
maintenance_event(id, machine_id, ts, kind, description, parts_json, downtime_min)
failure_event(id, machine_id, ts, failure_mode, downtime_min, cost)
```

Retention: raw telemetry 90 days → 1-min aggregates 2 years; features 2 years; alerts/events 5 years.

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Baseline requires ≥ 4 weeks of healthy data covering all normal contexts before alerts are enabled. |
| AI-02 | Anomaly detection: Isolation Forest baseline; autoencoder/LSTM-AE where sample volume allows; both versioned. |
| AI-03 | Target performance: **precision ≥ 0.7** and lead time ≥ 3 days on the retrospective failure set; false alerts ≤ 1 per machine per month. |
| AI-04 | RUL estimates SHALL include a prediction interval; RUL is disabled unless ≥ 3 comparable historical failures exist. |
| AI-05 | Every alert SHALL carry feature attribution (which signals/features drove the score). |
| AI-06 | Models SHALL be retrained on a schedule and after any confirmed failure, with metric comparison before promotion. |
| AI-07 | Concept drift after maintenance (e.g. bearing replaced) SHALL trigger baseline re-establishment for that machine. |
| AI-08 | The LLM SHALL receive only computed statistics — never raw series — and SHALL not compute numbers itself. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Ingest ≥ 50,000 samples/s sustained across the fleet. |
| NFR-02 | Feature computation lag ≤ 60 s behind real time. |
| NFR-03 | Alert generated within 5 minutes of the triggering condition. |
| NFR-04 | Dashboard chart query over 30 days ≤ 2 s p95. |
| NFR-05 | Ingestion SHALL buffer ≥ 24 h if the database is unavailable and replay without loss. |
| NFR-06 | OPC-UA/Modbus credentials read-only; connections auditable. |
| NFR-07 | Availability ≥ 99 %; loss of MachineSense SHALL not affect machine operation. |
| NFR-08 | ≥ 80 % test coverage on feature extraction and scoring. |
| NFR-09 | Time synchronisation: all sources NTP-synced; clock skew > 5 s flagged as a data-quality event. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Retrospective replay of ≥ 5 historical failures: ≥ 3 detected with ≥ 3 days lead time. |
| AC-02 | 30-day live run on a healthy machine: ≤ 1 false alert. |
| AC-03 | Injected synthetic degradation (ramp on bearing temp) is detected and attributed to the correct signal. |
| AC-04 | Alert explanation cites only values retrievable from the store (verified against SQL). |
| AC-05 | Database stopped 6 h: no telemetry lost after replay. |
| AC-06 | Maintenance window suppression prevents alerts during a scheduled service. |
| AC-07 | Machine with 1 historical failure returns "insufficient history for RUL" instead of a number. |
| AC-08 | Technician feedback loop closes ≥ 20 alerts and produces a precision report. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | ingestion (MQTT/OPC-UA), TimescaleDB schema, data-quality checks |
| P2 | 3–4 | feature extraction, context classification, charts |
| P3 | 5–6 | baseline + σ-score + EWMA, threshold alerts |
| P4 | 7–8 | multivariate anomaly models, health index, attribution |
| P5 | 9–10 | alert workflow, Discord, feedback loop, work-order draft |
| P6 | 11–12 | degradation/RUL, agent explanations, retrospective validation |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Not enough failure history for supervised models | unsupervised anomaly detection first; label as failures accumulate |
| Alert fatigue kills adoption | consecutive-window rule, grouping, precision target, feedback-driven tuning |
| Sensor faults look like machine faults | data-quality events, stuck-value detection, sensor health check |
| Vibration data volume | edge feature extraction, snapshot-only raw storage |
| Baseline captured during an already-degraded period | require engineer confirmation of the healthy window; re-baseline after service |
| Over-promising RUL | AI-04 gating, prediction intervals, explicit "insufficient history" |

---

## Appendix A — Example alert

```
⚠️  Machine #7 — Injection press B  ·  severity: HIGH  ·  health index 61/100

Bearing temperature (drive side)
  now 78.4 °C · baseline 68.9 ± 2.1 °C · +13.8 % over 5 days · σ = 4.5
Vibration RMS (drive side, running context)
  now 4.9 mm/s · baseline 2.9 ± 0.9 mm/s · σ = 2.1 · rising 6 consecutive days
Motor current: within baseline.

Top contributing features: bearing_temp_mean, vib_rms, vib_band_2x_rpm

Assessment (likelihood: high):
Pattern is consistent with drive-side bearing degradation or lubrication loss.
2× RPM band energy rising supports a bearing/alignment issue rather than load change.
Production volume over the same window was flat (−1.2 %), so load is not the driver.

Recommended inspection (within 3 days):
1. Check drive-side bearing lubrication and temperature by hand-held probe.
2. Take a vibration spectrum reading; look for BPFO/BPFI peaks.
3. Verify coupling alignment.

Similar past case: 2025-03-18 Machine #4 — outcome: bearing replaced (see case #212).
Estimated RUL: 12–30 days (80 % interval, based on 3 prior comparable failures).
```
