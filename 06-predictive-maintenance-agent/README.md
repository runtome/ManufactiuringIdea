# MachineSense — AI Predictive Maintenance Agent — Documentation Set

Machine telemetry (MQTT / OPC-UA read-only / Modbus / DAQ features / CSV) → features per running context → engineer-confirmed baselines → σ-scores, anomaly models with attribution, trends with confidence intervals, a health index → **alerts that name a component, an inspection and their uncertainty** → technician feedback that tunes the system. The LLM explains from stored evidence; it never computes a number and there is no path from it — or from anything else here — to a machine.

**A tightly-coupled platform module that owns the `telemetry` schema** (SAD-00 §13). Like [VisionOps (01)](../01-factory-inspector-agent/) and [ShiftBrief (02)](../02-production-ai-analyst/): standalone-deployable, with a platform mode in every document. Every shared database object is byte-identical to the platform's; the six shared API schemas and five shared paths are verbatim.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL/TimescaleDB could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-06 | [Software Requirements Specification](SRS-MachineSense-Predictive-Maintenance.md) | *What must it do?* | Everyone — start here |
| SAD-06 | [Software Architecture Document](docs/SAD-MachineSense-Software-Architecture.md) | *How do 50 k samples/s become one alert with a component, an inspection and an interval — and why can nothing here touch a machine?* | Architect, implementer |
| DDS-06 | [Database Design Specification](docs/DDS-MachineSense-Database-Design.md) | *The `telemetry` extension, TimescaleDB, and the constraints that make an alert without evidence impossible* | Implementer, DBA |
| API-06 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The evidence contract, the uncertainty contract, the advisory contract* | Implementer, integrators |
| ICD-06 | [Interface Control Document](docs/ICD-MachineSense-Interface-Control.md) | *MQTT, OPC-UA (read-only), Modbus, the DAQ feature contract, CSV import, CMMS export, Discord, LLM, tools* | Implementer, OT/IT, security reviewer |
| SEC-06 | [Security Requirements Specification](docs/SEC-MachineSense-Security-Requirements.md) | *Can anyone use this to stop the press? What protects the evidence, the baselines, the models?* | Security reviewer, OT |
| TEST-06 | [Test Plan and Test Cases](docs/TEST-MachineSense-Test-Plan.md) | *How do we prove ≥ 5 retrospective failures caught, ≤ 1 false alert / machine / month, and every explanation grounded?* | QA, ML owner |
| OPS-06 | [Deployment and Operations Guide](docs/OPS-MachineSense-Deployment-Operations.md) | *Topology near OT, onboarding a machine as a controls change, the 4-week baseline, TimescaleDB, the monthly precision review, runbooks* | Plant IT/OT, reliability engineer, on-call |
| UM-06 | [User Manual and Administrator Guide](docs/UM-MachineSense-User-Admin-Guide.md) | *Reading an alert card, ack/snooze/escalate/resolve, feedback, baselines, RUL, what the agent cannot do; admin* | Technicians, planners, managers, engineers, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 + TimescaleDB (native-partition fallback): platform `core`/`telemetry`/`agent`/`ops`/`audit` objects **extracted from `00/db/schema.sql`** + the MachineSense extension (migration `machinesense_0001`) — 48 tables, 8 views, 13 triggers, 27 explicit indexes, 13 functions, 5 roles | ✅ **45/45 shared objects byte-identical** to the platform; static DDL checks; nine guard triggers present · ⚠️ not executed (no PostgreSQL) |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Reproduces SRS Appendix A (M-07, HIGH, health 61/100, σ 4.5, +13.8 %, RUL 12–30 d from 3 failures) with 30 days of 1-min rollups for 3 machines + rows for AC-03, AC-05…AC-08 + 8 constraint probes | ✅ every expected value **re-derived in Python** (σ-scores, % change, health formula, precision 17/23 = 0.739, tallies) · ⚠️ not executed |
| [`api/openapi.yaml`](api/openapi.yaml) | **45 paths / 50 operations / 24 schemas** — SRS §4.1 endpoints + machines, baselines, models, incidents, failures, RUL, risks, reports, agent, work orders, config | ✅ validator pass; null-key scan clean; 0 orphans; **6 schemas, 5 paths and 2 parameters byte-identical to API-00** |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) | 14 services (3 ingest, broker, features, scoring, alerting, agent, scheduler, api, web, TimescaleDB, Redis, Ollama); networks `ot` / `internal` / `frontend` / `egress`; profiles `opcua`, `modbus` | ✅ parses; only ingest + broker on `ot`; hardening on all 10 app services; ports bound to `BIND_ADDR`/`OT_BIND_ADDR`; no write-capable flags; **50/50 env vars** both ways |
| [`deploy/sensors.example.yaml`](deploy/sensors.example.yaml) + [`schemas/sensor-map.schema.json`](deploy/schemas/sensor-map.schema.json) | Per-machine signals, OPC-UA nodes (read-only account), Modbus registers (isolated segment), DAQ, derived expressions, context rules, components | ✅ validates (Draft 2020-12); negatives rejected: OPC-UA `access: write`, Modbus FC 16, non-isolated Modbus, inline credential, security mode `None` |
| [`deploy/alert-rules.example.yaml`](deploy/alert-rules.example.yaml) + [`schemas/alert-rules.schema.json`](deploy/schemas/alert-rules.schema.json) | N consecutive windows, severity ladder, health weights, suppression, RUL gate, component map | ✅ validates; weights sum 1.0 and equal the seed's; negatives rejected: σ threshold 0, N = 0, RUL point estimate, RUL with 1 failure, empty component map (+ weights ≠ 1 as loader rule) — **11 negatives** across both schemas |
| [`deploy/mosquitto.conf.example`](deploy/mosquitto.conf.example) · [`mosquitto.acl.example`](deploy/mosquitto.acl.example) | TLS listener on the OT interface; per-gateway publish-only ACLs | ✅ secret scan clean |

---

## Reading paths

**Implementing it** → SRS-06 → SAD-06 §4 (ingest & buffer, context, features, baseline, scoring, alert engine, agent, feedback loop) → DDS-06 → `db/schema.sql` §10 → API-06 §3–5 → ICD-06 IF-38 (what the DAQ sends) → TEST-06 TS-3/TS-4.

**OT / controls engineer** → SEC-06 §4.2 ("use MachineSense to stop the press") → ICD-06 IF-05/IF-06 → OPS-06 §3, §4.4 (TC-020: the write test that must fail) → `deploy/sensors.example.yaml`.

**Reliability engineer** → UM-06 A4 → OPS-06 §4.4 steps 7–9, §6.3–6.5 → `deploy/alert-rules.example.yaml` → TEST-06 TC-128, TC-129, TC-139 (retrospective validation gates AC-01…03).

**Security review** → SEC-06 §1.1, §5.1, §5.7 → DDS-06 DD-P (guard triggers) → TEST-06 TS-7.

**Platform team** → SAD-06 §9 → DDS-06 §8 → API-06 §1 (`/signals` collision) → ICD-06 IF-16/IF-19 → OPS-06 §9.

**Using it** → UM-06 A0, A1.2 (the alert card, line by line), A1.5 (feedback).

---

## What makes this design what it is

| Principle | In MachineSense |
|---|---|
| **The LLM never computes** | Every number in an alert — now, baseline, σ, % change, slope CI, anomaly score, attribution, health, RUL interval — is computed by the scoring engine and stored in `evidence_json`. The model receives that bundle **only** (AI-08) and its explanation is post-checked: every figure must cite a key in it, or the explanation is withheld and the structured card ships alone (AC-04). |
| **Offline-first** | Ingest buffers 24 h locally and replays (AC-05); scoring, alerting and delivery work without Ollama; the LLM is the optional layer. |
| **Human-in-the-loop** | Baselines are proposed by the system and **confirmed by an engineer** (ADR-P03); technicians close every alert with a verdict (append-only); model promotion is metric-gated; work orders are drafts for a planner. **Advisory only — no write path exists** (ADR-P09): OPC-UA accounts are read-only and tested (TC-020), Modbus is read-only on an isolated segment, there is no tool, endpoint or flag that writes to a machine. |
| **The database is the source of truth** | `evidence_json` is what an explanation is checked against; triggers refuse an alert without component + recommendation + attribution (P-6 / C-05), an RUL that is not an interval or is not backed by ≥ 3 comparable failures (C-04, AI-04), an alert opened inside a maintenance window (FR-14), an unconfirmed baseline going active, a model promoted with worse metrics, an edit to feedback. |
| **P-6: an alert without component + inspection + uncertainty is not an alert** | Enforced by `trg_alert_actionable`; the component map in the alert rules is where the recommendation comes from; the UM teaches the card line by line. |

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | **Tight** — owns `telemetry` (SAD-00 §13). Shared DDL extracted byte-identically; extension applied as migration `machinesense_0001`; TimescaleDB becomes the default here (platform ADR-007 keeps it optional). Registers tools `get_machine_health`, `get_alert_evidence`, `list_top_risks`, `list_failures`, `get_trend` next to the platform's `get_machine_telemetry` and `search_memory` (IF-16). Its alerts feed `quality.signal`. |
| [09 QE-Agent](../09-quality-engineer-agent/) · [13 KaizenSwarm](../13-multi-agent-factory/) | Consume health and alerts as signals (via `quality.signal` and the tools). |
| [15 Genba Memory](../15-troubleshooting-memory/) | Source of "similar past case" (FR-24) in platform mode via `search_memory`; standalone falls back to local case search. |
| [02 ShiftBrief](../02-production-ai-analyst/) | Same grounding mechanism (every number cites the evidence) and the same Appendix-A-arithmetic honesty. |

---

## Identifier conventions

`FR-01…27` / `AI-01…08` / `NFR-01…09` / `AC-01…08` / `C-01…05` (SRS-06) · `P-1…P-4` + **P-6** · **`ADR-P01…P10`** · `QAS-01…12` · **`DD-P01…P09`** · `IF-xx` shared numbering (**IF-36 CSV/Parquet import, IF-37 CMMS export, IF-38 vibration DAQ feature contract** new; IF-04/05/06/08/09/13/14/16/19 reused) · **`THR-P`/`SEC-P`** · `TS-0…9` / `TC-` · `RB-01…14`.

```
SRS-06 C-04 / AI-04  "predictions always with uncertainty; RUL only with ≥ 3 comparable failures"
  └─ SAD-06 ADR-P05 interval-or-nothing · QAS
      └─ DDS-06 DD-P02, DD-P03 · rul_estimate CHECK rul_interval_or_nothing · trg_rul_gate (counts comparable failure_event rows)
          └─ API-06 RulEstimate {low_days, high_days, confidence} | {status: insufficient_history, comparable_failures, required: 3} · §4
              └─ alert-rules.schema.json: min_comparable_failures const 3, point_estimate const false (negatives rejected)
                  └─ TEST-06 TC-005 (seed: M-07 12–30 d, M-11 insufficient) · TC-125 (AC-07) · TC-003 probe
                      └─ UM-06 A1.2, A3, A4.6 · OPS-06 §6.5
```

---

## Verification

| Check | Result |
|---|---|
| **Byte-identity vs `00/db/schema.sql`** (TC-002) | ✅ **Pass** — 45/45 shared objects identical (extensions, helpers, enums, `core.plant/line/machine/app_user/user_line_scope`, all `telemetry.*` platform tables incl. `sample` partitions, `agent.*`, `ops.scheduled_job/config/data_quality_event`, `audit.*`, `idx_dq_event_ts`) |
| Static DDL (TC-003) | ✅ **Pass** — balance, FK targets defined, 48 tables / 8 views / 13 triggers / 27 indexes / 13 functions; 9/9 guard triggers; grants as specified; TimescaleDB block conditional |
| Compose / env (TC-004) | ✅ **Pass** — 14 services; `ot` network = ingest ×3 + broker only; hardening ×10; ports on `BIND_ADDR`/`OT_BIND_ADDR`; no write flags; 50/50 vars |
| Seed arithmetic and tallies (TC-005) | ✅ **Pass** — σ 4.524 / 2.222 / 2.5 / 0.267; +13.79 %; health 60.87; precision 0.739; 3 comparable failures for M-07, 1 for M-11; 820,800 rollups / 41,040 features / 2,163 health points |
| Sensor map and alert rules vs schemas + 11 negatives (TC-006) | ✅ **Pass** |
| Secret scan (TC-007) | ✅ **Pass** |
| `openapi.yaml` (TC-001) and contract identity vs API-00 (TC-008) | ✅ **Pass** — 45 / 50 / 24; `TelemetrySample`, `TelemetrySeries`, `MachineHealth`, `MaintenanceAlert`, `Severity`, `Problem`, `DateFrom`, `DateTo` and the five shared paths identical |
| SRS-06 coverage; cited tables/views/triggers/endpoints/TCs/RBs/ADRs/SEC-Ps; links | ✅ see sweep note below |
| **Schema + seed on PostgreSQL 16 + TimescaleDB** (TC-009) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| Ingest at 50 k/s, retrospective validation, everything with hardware (TS-1…TS-9) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 06-predictive-maintenance-agent
docker run -d --name ms-pg -e POSTGRES_PASSWORD=x -p 5433:5432 timescale/timescaledb-ha:pg16   # has pgvector + timescaledb
sleep 10 && psql "postgresql://postgres:x@localhost:5433/postgres" -v ON_ERROR_STOP=1 -f db/schema.sql -f db/seed_demo.sql
```
Expected: schema NOTICE "TimescaleDB: hypertables, compression (7 d) and retention …"; seed `\echo` block matches the header; the 8 probes at the end each fail inside their savepoint.

**Defects found by checking** (all fixed; TEST-06 §4): a BEFORE trigger that inserted an FK row before its parent existed; a platform index re-typed with a different column list (caught by byte-identity); header tallies that forgot the derived sensor and the inclusive hour; a feedback `unknown` that collided with the FP pattern; re-baseline flags left set; a promotion probe that would not have failed; four unquoted commas in the OpenAPI; and one for the SRS — **Appendix A prints vibration σ = 2.1 but (4.9 − 2.9) / 0.9 = 2.22**.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL/TimescaleDB execution pending — byte-identity, static checks and re-derived arithmetic stand in until CI runs TC-009 | TEST-06 TC-009 |
| **SRS Appendix A vibration σ**: printed 2.1, computed 2.22; the seed and the card show the computed value; SRS not edited | DDS-06 §9, TEST-06 §4 #7, UM-06 A1.2 |
| **SRS §4.1 `/signals` collides with the platform's quality `/signals`**; served as `/telemetry/series` (API-00) with the mapping recorded | API-06 §1 |
| Modbus is inherently unauthenticated: read-only function codes + isolated segment + signed risk acceptance, not a fix | SEC-06 §8, OPS-06 §3 |
| Autoencoder model is optional; Isolation Forest is the shipped baseline model; both versioned and metric-gated | SAD-06 ADR-P06 |
| Continuous aggregate vs scheduler rollup is an operator choice above ~20 k samples/s | OPS-06 §5.3 |
| Retrospective validation (AC-01/02) needs ≥ 5 labelled failures per plant — the first months of a deployment cannot meet it | TEST-06 TC-129, TC-139 |
