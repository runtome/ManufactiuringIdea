# Software Requirements Specification — Production AI Analyst (CSV → Analysis → Discord)

| Field | Value |
|---|---|
| Document ID | SRS-02-ShiftBrief |
| Project code name | **ShiftBrief** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Replace the manual "daily CSV → Python → PowerPoint" routine with an automated pipeline that validates production data, computes analytics, and has an LLM write a **production analyst's daily brief** delivered to Discord, a dashboard and an exportable deck.

This is the **fastest-to-value** project in the set: no cameras, no edge hardware, immediately useful at work.

### 1.2 Scope

**In scope**
- Scheduled/on-drop ingestion of daily production and defect files (CSV/XLSX).
- Data validation, quarantine and reconciliation.
- Analytics: volume, defect rate, Pareto, per line/shift/SKU breakdown, trend vs 7/30-day baselines, statistical significance.
- LLM-written narrative + recommended actions.
- Delivery: Discord message, `/ask` Q&A, web dashboard, PPTX/PDF export.

**Out of scope**
- Vision inspection (see SRS-01/03).
- Machine telemetry (see SRS-06).
- Write-back into MES/ERP.

### 1.3 Definitions
**Brief** = the generated daily/shift report. **Baseline** = rolling 7-day and 30-day comparison window. **Quarantine** = rows rejected by validation, stored for correction.

---

## 2. Overall Description

### 2.1 Product perspective
```
Daily CSV / XLSX  ──►  Ingest + Validation  ──►  Warehouse (PostgreSQL)
                                                     │
                                              Analytics Engine
                                        (KPI · Pareto · trend · significance)
                                                     │
                                              LLM (Ollama)  ← facts only
                                                     │
                         ┌───────────────────────────┼─────────────────┐
                         ▼                           ▼                 ▼
                     Discord                    Dashboard         PPTX / PDF
```

### 2.2 User classes
| Class | Need |
|---|---|
| Production manager | 30-second morning read of yesterday's performance |
| Quality engineer | drill into the worst line / defect / SKU |
| Supervisor | shift-level view, actions to take today |
| Japanese management | same brief in Japanese |
| Owner/admin | file mapping, thresholds, schedules |

### 2.3 Operating environment
Docker on a small server or VPS; PostgreSQL 16; Ollama with a ≤9 B instruct model (RTX 3060 Ti baseline) or CPU-only fallback for a 3–4 B model; Discord bot; Next.js dashboard.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | The LLM never computes statistics. All numbers are produced by the analytics engine and injected as structured facts. |
| C-02 | Source files must never be modified in place; originals archived with a checksum. |
| C-03 | Re-running a day MUST be idempotent and produce the same brief for the same input + config. |
| C-04 | Must run without internet (local model) — cloud LLM optional. |

### 2.5 Assumptions
Daily file arrives on a predictable path/schedule with a stable-enough column layout; column mapping is configurable per source.

---

## 3. Functional Requirements

### 3.1 Ingestion & validation
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | The system SHALL ingest files from a watched folder, an upload endpoint, and optionally email attachment or SFTP. | Must |
| FR-02 | Column mapping SHALL be configuration-driven (YAML per source), supporting renamed/reordered columns. | Must |
| FR-03 | The system SHALL validate: required columns, types, date parsing, non-negative quantities, `qty_ng ≤ qty_produced`, known line/SKU/defect codes. | Must |
| FR-04 | Invalid rows SHALL be quarantined with a human-readable reason; the batch SHALL fail if >5 % of rows are invalid. | Must |
| FR-05 | Ingestion SHALL be idempotent by (date, line, shift, sku, source_hash) with upsert semantics. | Must |
| FR-06 | The system SHALL archive the original file and record its SHA-256. | Must |
| FR-07 | Late-arriving or corrected files SHALL trigger recomputation and a "revised brief" notice. | Should |
| FR-08 | The system SHALL alert if the expected daily file has not arrived by a configured cutoff time. | Must |

### 3.2 Analytics engine
| ID | Requirement | Priority |
|---|---|---|
| FR-09 | Compute total produced, total NG, defect rate (%) overall and by line, shift, SKU, defect type. | Must |
| FR-10 | Compute defect Pareto with cumulative % and identify the top-N contributors. | Must |
| FR-11 | Compute deltas vs previous day, 7-day average and 30-day average, with % change. | Must |
| FR-12 | Test whether a change is statistically significant (two-proportion z-test on defect rate, α = 0.05) and expose the p-value. | Must |
| FR-13 | Identify the worst line, worst SKU and worst shift by defect rate with a minimum-volume guard (e.g. ≥ 100 pcs) to avoid small-sample noise. | Must |
| FR-14 | Detect trend patterns: N consecutive days rising, level shift, and outlier days (>3σ). | Should |
| FR-15 | Compute OEE components (availability, performance, quality) when the input provides runtime/downtime. | Could |
| FR-16 | All computed facts SHALL be serialised into a versioned `facts` JSON object used as the sole LLM input. | Must |

### 3.3 LLM analyst
| ID | Requirement | Priority |
|---|---|---|
| FR-17 | The LLM SHALL produce a brief with sections: headline numbers, top defect, worst line, trend, analysis, recommended action. | Must |
| FR-18 | The LLM SHALL only reference values present in the `facts` object; any other number is a defect of the system. | Must |
| FR-19 | The brief SHALL distinguish *correlation* from *cause* and mark unverified hypotheses as such. | Must |
| FR-20 | If no change is significant, the brief SHALL say the day was within normal variation. | Must |
| FR-21 | Language SHALL be selectable: Thai (default), Japanese, English. | Must |
| FR-22 | Tone/length SHALL be configurable (short Discord version, long report version). | Should |

### 3.4 Conversational Q&A
| ID | Requirement | Priority |
|---|---|---|
| FR-23 | `/ask <question>` in Discord SHALL run a tool-calling agent over the warehouse and answer with figures + the SQL/tool trace. | Must |
| FR-24 | The agent SHALL support follow-up questions within a thread context. | Should |
| FR-25 | Generated SQL SHALL be read-only, executed against a restricted role, with a row/time limit. | Must |
| FR-26 | The agent SHALL return "I don't have that data" rather than guessing when a field is absent. | Must |

### 3.5 Delivery
| ID | Requirement | Priority |
|---|---|---|
| FR-27 | The brief SHALL be posted to a configured Discord channel on a cron schedule. | Must |
| FR-28 | Threshold alerts (defect rate > X %, or +Y % vs baseline) SHALL be pushed immediately, outside the schedule. | Must |
| FR-29 | The dashboard SHALL show KPI tiles, trend line, Pareto bar, line/shift heatmap and the brief text. | Must |
| FR-30 | The system SHALL export the brief as PPTX and PDF with the same charts. | Should |
| FR-31 | Users SHALL be able to regenerate a brief for any past date. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/ingest` | upload a production file |
| GET | `/api/v1/ingest/{batch_id}` | batch status + quarantine rows |
| GET | `/api/v1/facts?date=` | computed facts object |
| POST | `/api/v1/brief?date=&lang=` | generate/regenerate brief |
| POST | `/api/v1/ask` | question answering |
| GET | `/api/v1/export/{date}.pptx` | deck export |

### 4.2 Discord
Slash commands: `/brief [date] [lang]`, `/ask <question>`, `/kpi <line> <period>`, `/subscribe <channel>`.

### 4.3 Input file contract (default mapping)
```
date, shift, line, sku, qty_produced, qty_ng, defect_code, defect_qty,
runtime_min, downtime_min, operator_id (optional), lot (optional)
```

---

## 5. Data Requirements

```sql
ingest_batch(id, source, filename, sha256, rows_total, rows_ok, rows_quarantined,
             status, started_at, finished_at)
production_fact(date, shift, line_id, sku_id, qty_produced, qty_ng,
                runtime_min, downtime_min, batch_id, PRIMARY KEY(date,shift,line_id,sku_id))
defect_fact(date, shift, line_id, sku_id, defect_code, qty, batch_id)
quarantine_row(id, batch_id, row_no, raw_json, reason)
brief(id, date, lang, facts_json, text, model, prompt_version, created_at, revised_of)
ask_log(id, ts, user, question, tools_json, answer, latency_ms)
```

Retention: raw archives 2 years, facts 5 years, briefs 5 years.

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Local LLM ≤ 9 B (Q4_K_M) via Ollama with tool calling; CPU fallback model ≤ 4 B for the no-GPU case. |
| AI-02 | Prompt templates versioned in git; `prompt_version` stored with every brief. |
| AI-03 | Deterministic settings for briefs (temperature ≤ 0.2) so the same facts give a stable narrative. |
| AI-04 | A golden set of ≥ 40 (facts → expected claims) cases SHALL be run in CI; **zero fabricated numbers** is a release gate. |
| AI-05 | Text-to-SQL for `/ask` SHALL be constrained by an explicit schema description and validated by a SQL parser before execution. |
| AI-06 | Token/latency per brief SHALL be logged for cost and performance tracking. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | A daily file of ≤ 500 k rows SHALL ingest + compute in ≤ 3 minutes. |
| NFR-02 | Brief generation ≤ 60 s on the baseline GPU. |
| NFR-03 | `/ask` answer ≤ 20 s p95. |
| NFR-04 | Dashboard queries over 12 months ≤ 2 s p95. |
| NFR-05 | The whole stack SHALL fit in 8 GB RAM + 8 GB VRAM. |
| NFR-06 | Secrets (Discord token, DB password) via environment/Docker secrets only. |
| NFR-07 | Personal identifiers (operator names) SHALL be pseudonymised in any generated text. |
| NFR-08 | Full re-run of any historical date SHALL reproduce the stored facts byte-identically. |
| NFR-09 | ≥ 80 % unit-test coverage on the analytics engine. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | 30 days of real historical files import with 0 unexplained quarantine rows. |
| AC-02 | KPI totals match a manually built Excel pivot exactly. |
| AC-03 | Significance test flags a synthetic injected 2× defect spike, and does *not* flag normal-variation days. |
| AC-04 | Golden-set run: 0 numbers absent from the facts object. |
| AC-05 | Discord brief posts on schedule for 7 consecutive days unattended. |
| AC-06 | `/ask "why did defect increase yesterday"` returns figures plus the tool trace. |
| AC-07 | Japanese brief renders correctly in Discord and PPTX (no mojibake). |
| AC-08 | Re-running day D after a corrected file produces a revised brief linked to the original. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1 | schema, ingest, validation, quarantine, archive |
| P2 | 2 | analytics engine + facts object + tests |
| P3 | 3 | LLM brief generation, prompt versioning, golden set |
| P4 | 4 | Discord bot, scheduling, alerts |
| P5 | 5 | Next.js dashboard + charts |
| P6 | 6 | PPTX/PDF export, i18n (TH/JA/EN), docs |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Source file layout changes without warning | config-driven mapping + schema-drift detector + alert |
| Small samples produce dramatic-looking % swings | minimum-volume guard (FR-13) + significance test |
| LLM writes a confident wrong cause | facts-only prompting, correlation wording rules, golden set |
| Data contains personal/operator info | pseudonymisation, RBAC on raw tables |
| Discord dependency | webhook + email fallback channel |

---

## Appendix A — Example brief

```
📅 Production Report — 2026-09-10
Production : 12,430 pcs
Defects    : 382 pcs
Defect rate: 3.07 %   (7-day avg 2.59 %, +18.4 %, p = 0.004 → significant)
Top defect : Missing Component — 41 %
Worst line : Line 3 — 5.82 % (n = 2,140)

AI analysis:
Line 3 shows abnormal defect growth beginning during Shift B.
Missing Component accounts for 63 % of Line 3 defects, concentrated
in SKU RAD-500-A. Other lines are within normal variation.

Recommended action:
1. Check component feeder on Line 3.
2. Review Shift B operator changeover records.
3. Verify incoming lot for SKU RAD-500-A.

Note: correlation only; root cause not verified.
Facts version 3 · model qwen3:8b · prompt v1.2
```
