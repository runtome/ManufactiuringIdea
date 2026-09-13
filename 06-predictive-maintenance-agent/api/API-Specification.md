# API Specification — MachineSense AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | API-06-MachineSense |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **45 paths / 50 operations / 24 schemas**; validated; 5 paths, 6 schemas and 2 parameters structurally identical to [API-00](../../00-factorybrain-platform/api/openapi.yaml) |
| Related | [SAD-06](../docs/SAD-MachineSense-Software-Architecture.md) · [DDS-06](../docs/DDS-MachineSense-Database-Design.md) · [ICD-06](../docs/ICD-MachineSense-Interface-Control.md) · [SEC-06](../docs/SEC-MachineSense-Security-Requirements.md) · [API-00](../../00-factorybrain-platform/api/API-Specification.md) |

---

## 1. Scope and platform mode

Standalone, this is the whole API. In platform mode the five shared paths and six shared schemas are served by the platform (verbatim here — TEST-06 TC-008); the rest is MachineSense's own module surface mounted under the same base path. SRS-06 §4.1's seven endpoints map as follows:

| SRS-06 §4.1 | Here | Note |
|---|---|---|
| `POST /telemetry` | `POST /telemetry/samples` | the platform's path (identical) |
| `GET /machines/{id}/health` | same | identical |
| `GET /signals?machine=&signal=&from=&to=` | `GET /telemetry/series` (identical) + `GET /telemetry/rollup` (resolution, context, trend) | **`/signals` in the platform is the *quality* signals endpoint**; MachineSense keeps the platform's telemetry path to avoid the collision (README-06 known gaps) |
| `GET /alerts?status=` | same | identical; `GET /machines/{id}/alerts` adds filters and pagination |
| `POST /alerts/{id}/feedback` | same | identical; `POST /alerts/{id}/resolve` combines close + feedback + optional failure label |
| `POST /agent/explain/{alert_id}` | same | |
| `POST /workorders/draft` | same | + `POST /workorders/{id}/export` |

## 2. Conventions
| Topic | Rule |
|---|---|
| Base path | `/api/v1` |
| Auth | Bearer JWT; roles viewer < technician < planner < engineer < admin (platform mode: viewer, engineer, manager, admin) |
| Formats | JSON; RFC 3339 timestamps (UTC storage; plant zone in `from`/`to` date params of the platform paths) |
| Errors | RFC 7807 with stable `code` (§7) |
| Pagination | Cursor on `/machines/{id}/alerts`; `limit` elsewhere |
| Idempotency | `Idempotency-Key` on acknowledge and export |
| Machines | Platform paths take `machineId` (uuid); MachineSense paths accept the machine **code** where a person types it |

## 3. The evidence contract (AI-08, FR-23, AC-04)

`AlertDetail.evidence` (`AlertEvidence`) is the **only** input the agent receives about an alert, and the only source a narrative may cite:

```json
"signals": { "bearing_temp_ds": { "now": 78.4, "baseline_mean": 68.9, "baseline_std": 2.1, "sigma": 4.524, "pct_change_5d": 13.79, "trend_slope_per_day": 1.90, "trend_ci_80": [1.62, 2.18] } , … },
"anomaly": { "model": "isolation_forest v2", "score": 0.75 },
"attribution": [ { "feature": "bearing_temp_mean", "contribution": 0.41 }, … ],
"production_context": { "volume_change_pct_5d": -1.2 },
"rul": { "low_days": 12, "high_days": 30, "confidence": 0.80, "comparable_failures": 3 },
"similar_case": { "machine": "M-04", "date": "2025-03-18", "outcome": "bearing replaced", "genba_case": 212 }
```

Rules: (1) the scoring engine writes it when the alert opens; it is never edited by the agent; (2) `attribution` is non-empty (DB trigger); (3) `POST /agent/explain` post-checks every numeric token in the narrative against these values (rounding tolerance: the value as displayed with ≤ 1 decimal, e.g. 4.524 → "4.5", 13.79 → "13.8"); an unmatched number withholds the narrative (`narrative: null`, `withheld_reason`) while `assessment`, `recommended_inspection` and `evidence_used` are still returned; (4) `rul` is an interval or null — the narrative may say "12–30 days (80 %)" or "insufficient history", never a single number.

## 4. The uncertainty contract (C-04, AI-04, FR-11, FR-26)
| Quantity | Representation | Refused |
|---|---|---|
| RUL | `{low_days, high_days, confidence, comparable_failures}` or `null` + `rul_reason` | any point estimate; an interval without ≥ 3 comparable failures (409 from the DB gate) |
| Trend | `slope_per_day` with `slope_ci_low/high` (80 %) and `pct_change` | a slope without a CI |
| Cause | `assessment.hypothesis` with `likelihood ∈ {low, medium, high}` and `verification_required[]` | certainty language — the post-check rejects "is caused by", "definitely" |

## 5. The advisory contract (C-01)
No operation writes to a machine. `POST /telemetry/samples` and `/telemetry/import` write *into* MachineSense. The agent's tools are read-only (ICD-06 IF-16). There is no OPC-UA/Modbus write endpoint, and `PUT /config/sensor-map` refuses a map that declares a write mode (422 `OPCUA_WRITE_FORBIDDEN`).

## 6. Endpoint groups

| Group | Endpoints | Notes |
|---|---|---|
| Telemetry | `POST /telemetry/samples`*, `GET /telemetry/series`*, `/telemetry/rollup`, `/telemetry/features`, `/telemetry/data-quality`, `POST /telemetry/import` | `*` identical to API-00; rollup serves 30-day charts ≤ 2 s (NFR-04) |
| Machines | `GET /machines`, `/machines/{id}`, `/sensors`, `/context`, `/health`*, `/health/history`, `/alerts`, `/rul` | |
| Baselines | `GET/POST /baselines`, `POST /baselines/{machine}/{version}/confirm`, `POST /baselines/{machine}/rebaseline` | Propose (engineer) → confirm (engineer); ≥ 4 weeks and all contexts (AI-01); re-baseline after service (AI-07) |
| Models | `GET /models`, `POST /models/{id}/promote`, `POST /models/retrain`, `GET /models/retrain-runs` | Promotion refused below the active version's metrics (AI-06) |
| Alerts | `GET /alerts`*, `GET /alerts/{id}`, `POST …/acknowledge`, `…/snooze`, `…/escalate`, `…/resolve`, `POST …/feedback`*, `GET /incidents`, `/incidents/{id}`, `GET /reports/precision` | Resolve requires feedback (FR-20); precision report (AC-08) |
| Risks | `GET /risks/top`, `GET /machines/{id}/rul`, `GET/POST /failures` | FR-22, FR-13, FR-15 |
| Agent | `POST /agent/explain/{alertId}`, `POST /agent/ask`, `POST /workorders/draft`, `POST /workorders/{id}/export` | §3; ask uses typed tools (FR-25); export to PDF or CMMS webhook (IF-37) |
| Admin | `GET/POST /maintenance-windows`, `POST /maintenance-events`, `GET/PUT /config/sensor-map`, `GET/PUT /config/alert-rules` | Schema-validated configs, versioned |
| Auth / system | `/auth/login`, `/healthz`, `/readyz` | `/readyz.llm=false` does not fail readiness (P-2) |

## 7. Error catalogue

| `code` | HTTP | When |
|---|---|---|
| `BASELINE_WINDOW_INSUFFICIENT` | 422 | < 28 days or a normal context uncovered (AI-01) |
| `BASELINE_NOT_CONFIRMED` | 409 | activation without an engineer (DB trigger) |
| `RUL_INSUFFICIENT_HISTORY` | 409 | an interval requested with < 3 comparable failures |
| `MODEL_METRICS_BELOW_ACTIVE` / `MODEL_METRICS_MISSING` | 409 | promotion refused (AI-06) |
| `ALERT_NOT_ACTIONABLE` | 422 | component / recommendation / attribution missing (C-05, AI-05) — only reachable via import tooling; the engine never produces such an alert |
| `ALERT_IN_MAINTENANCE_WINDOW` | 409 | an unsuppressed alert inside a window (FR-14) |
| `FEEDBACK_IMMUTABLE` | 409 | second feedback for the same alert |
| `ALERT_NOT_OPEN` | 409 | ack/snooze/escalate on a closed alert |
| `SNOOZE_TOO_LONG` | 422 | > 7 days |
| `OPCUA_WRITE_FORBIDDEN` | 422 | sensor map declares a write mode (C-01) |
| `CONFIG_INVALID` | 422 | schema failure with the path |
| `LLM_UNAVAILABLE` | 503 | explain/ask; alert endpoints unaffected |
| `GROUNDING_FAILED` | 200 (`narrative: null`) | narrative withheld |
| `CMMS_EXPORT_FAILED` | 502 | webhook error; draft kept |
| `IMPORT_SCHEMA_INVALID` | 422 | CSV/Parquet columns wrong (IF-36) |
| `RATE_LIMITED` | 429 | |

## 8. Platform mode mapping
| MachineSense | Platform |
|---|---|
| Five shared paths, six shared schemas | served by the platform unchanged |
| `/agent/explain`, `/agent/ask` | the platform's `/agent/ask` with MachineSense tools registered (IF-16); explain remains a MachineSense path |
| `/auth/*` | the platform's |
| `/models`, `/baselines`, `/incidents`, `/risks`, `/config` | mounted as the MachineSense module under the platform gateway |
| Alerts → siblings | `quality.signal` rows for QE-Agent (09); `v_top_risks_week` for KaizenSwarm (13); closed incidents → Genba Memory (15) |

## 9. Traceability
| SRS-06 | Endpoint |
|---|---|
| §4.1 | §1 mapping |
| FR-02, FR-03 | `/telemetry/samples`, `/telemetry/data-quality` |
| FR-04, FR-05 | `/telemetry/features`, `/machines/{id}/context` |
| FR-08, AI-01, AI-07 | `/baselines*` |
| FR-09, FR-11, FR-12 | `/telemetry/rollup` (trend), `/machines/{id}/health`, `/health/history` |
| FR-10, AI-02, AI-06 | `/models*` |
| FR-13, AI-04, C-04 | `/machines/{id}/rul`, §4 |
| FR-14 | `/maintenance-windows` |
| FR-15 | `/failures` |
| FR-16, AI-05, C-05 | `AlertDetail.evidence.attribution`, `suspected_component`, `recommendation` |
| FR-18 | `/incidents` |
| FR-19 | acknowledge / snooze / escalate |
| FR-20, AC-08 | `/resolve`, `/feedback`, `/reports/precision` |
| FR-21 | `/workorders/*` |
| FR-22 | `/risks/top` |
| FR-23…FR-27, AI-08 | `/agent/*`, §3 |
| NFR-04 | `/telemetry/rollup` |
| C-01 | §5 |
