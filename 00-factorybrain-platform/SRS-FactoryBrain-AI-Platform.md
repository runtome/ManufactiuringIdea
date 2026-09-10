# Software Requirements Specification — FactoryBrain AI Platform

| Field | Value |
|---|---|
| Document ID | SRS-00-FactoryBrain |
| Project code name | **FactoryBrain AI** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Classification | Internal / Portfolio |

---

## 1. Introduction

### 1.1 Purpose
This document specifies the requirements for **FactoryBrain AI**, an umbrella *manufacturing intelligence platform* that unifies computer-vision inspection, production analytics, quality engineering (SPC / RCA / FMEA) and an LLM agent layer into a single on-premise system.

FactoryBrain is the **integration target** for the sibling projects in this repository. Each sibling project (SRS-01 … SRS-15) can be built and demonstrated standalone; FactoryBrain defines the contracts (schemas, APIs, event bus, auth) that let them compose.

### 1.2 Scope

**In scope**
- Shared data platform (PostgreSQL + pgvector + object storage) for inspection results, production data, machine telemetry and quality documents.
- AI Gateway: single entry point for vision inference and LLM/agent calls.
- Quality Engine: SPC (X̄-R, p, u charts), Cp/Cpk, trend/rule violations (Nelson rules).
- Agent layer: tool-calling LLM agent that reads the platform data and produces analysis, RCA drafts and reports.
- Web dashboard (Next.js), Discord bot, PDF/PPTX report export.
- Multilingual output: Thai / Japanese / English.
- Fully local deployment option (Ollama) plus optional cloud LLM fallback.

**Out of scope (v1)**
- Direct write-back / control of production machinery (read-only from OPC-UA/MQTT).
- Replacing the ERP or MES as a system of record.
- Safety-rated (SIL/PL) functions. FactoryBrain is an advisory system only.
- Automatic scrapping/rejection actuation without human confirmation.

### 1.3 Definitions and acronyms
| Term | Meaning |
|---|---|
| SPC | Statistical Process Control |
| Cp / Cpk | Process capability indices |
| RCA | Root Cause Analysis |
| 8D | Eight Disciplines problem-solving report |
| FMEA / RPN | Failure Mode and Effects Analysis / Risk Priority Number |
| HITL | Human-in-the-loop |
| Genba (現場) | The actual place / shop floor |
| Lot | Traceable batch of material or product |
| Edge node | On-premise inference PC near the line |

### 1.4 References
- IEEE 830-1998 SRS template (structure basis)
- AIAG-VDA FMEA Handbook (1st ed.)
- ISO 7870 / Nelson rules for control charts
- Sibling documents: SRS-01 … SRS-15 in this repository

### 1.5 Related projects
| Sibling | Role inside FactoryBrain |
|---|---|
| SRS-01 Factory Inspector Agent | Vision → inspection records pipeline |
| SRS-03 EdgeGuard | Edge inference node feeding SRS-01 |
| SRS-02 ShiftBrief | Daily production analyst / report generator |
| SRS-09 QE-Agent | Quality engineering brain (SPC/8D/FMEA) |
| SRS-10 Factory Copilot | Conversational front-end |
| SRS-11 MoldMind | Injection-molding-specific defect knowledge |
| SRS-15 Genba Memory | RAG memory of past problems |

---

## 2. Overall Description

### 2.1 Product perspective
FactoryBrain sits **beside** MES/ERP, not inside it. It ingests (a) images from line cameras, (b) production/defect data files or DB extracts, (c) machine telemetry, and (d) quality documents. It produces analysis, alerts and reports for humans.

```
   Cameras ─┐                                   ┌─► Next.js Dashboard
Production ─┤                                   │
   Data     ├─► Ingest ─► Data Platform ─► AI ──┼─► Discord bot
 Telemetry ─┤            (PG+pgvector)  Gateway │
 Documents ─┘                  │           │    └─► PDF / PPTX report
                               ▼           ▼
                        Quality Engine   Agent (Ollama / API)
                        SPC · Cpk · RCA   tool-calling
```

### 2.2 User classes
| Class | Needs | Technical level |
|---|---|---|
| Line operator | Simple PASS/FAIL/REVIEW, Thai UI | Low |
| QC inspector | Defect review, evidence images, re-judge | Medium |
| Quality engineer | SPC, Cpk, RCA, 8D, FMEA links | High |
| Production manager | KPI dashboard, daily/shift summary | Medium |
| Japanese management | Japanese report, trend, risk summary | Medium |
| Platform admin (you) | Deployment, models, users, retraining | Expert |

### 2.3 Operating environment
- **Server**: Ubuntu 22.04 LTS, Docker + Docker Compose, ≥32 GB RAM, ≥1 TB SSD.
- **GPU**: NVIDIA RTX 3060 Ti 8 GB (development baseline). All model choices MUST fit 8 GB VRAM.
- **Edge nodes**: Jetson Orin Nano / mini-PC + USB or GigE camera.
- **Clients**: Chrome/Edge desktop, Android tablet (shop floor), Discord.
- **Network**: factory LAN, no guaranteed internet. Offline operation is mandatory.

### 2.4 Design and implementation constraints
| ID | Constraint |
|---|---|
| C-01 | All AI inference MUST be able to run locally; no production data leaves the LAN by default. |
| C-02 | LLM footprint ≤ 8 GB VRAM (e.g. 7–9 B parameter model at Q4_K_M) when GPU is shared with vision. |
| C-03 | Backend Python 3.11 + FastAPI; frontend Next.js 15 (App Router) + TypeScript. |
| C-04 | Every component ships as a Docker image; `docker compose up` MUST bring the full stack up. |
| C-05 | All AI-generated conclusions MUST be labelled as AI-generated and be traceable to source records. |
| C-06 | Database is the single source of truth; the LLM never stores state outside the DB. |

### 2.5 Assumptions and dependencies
- Production/defect data is available at least daily as CSV or a readable DB view.
- Camera positions and lighting are fixed enough for a trained model to generalise.
- At least 200 labelled images per defect class can be collected for v1 models.
- Ollama or a compatible local inference server is available.

---

## 3. System Architecture

### 3.1 Components
| # | Component | Tech | Responsibility |
|---|---|---|---|
| A1 | Ingest Service | FastAPI + Celery/RQ | file watcher, CSV/Excel import, MQTT/OPC-UA subscriber |
| A2 | Vision Service | Python, Ultralytics/ONNX Runtime | detection, segmentation, OCR, measurement |
| A3 | Data Platform | PostgreSQL 16 + pgvector, MinIO | records, embeddings, image evidence |
| A4 | Quality Engine | Python (pandas, scipy) | SPC charts, Cp/Cpk, rule violations, Pareto |
| A5 | AI Gateway | FastAPI | model routing, prompt templates, token budget, audit log |
| A6 | Agent Runtime | Ollama + tool-calling loop | plans, calls tools, drafts analysis |
| A7 | Web App | Next.js + Tailwind + Recharts | dashboard, review UI, report viewer |
| A8 | Notifier | discord.py / webhook | alerts, daily briefs, `/ask` command |
| A9 | Report Service | python-pptx, WeasyPrint | PPTX / PDF export |
| A10 | Auth & RBAC | FastAPI + JWT (or Authentik) | users, roles, audit |

### 3.2 Agent tool contract (shared by all sibling agents)
Tools exposed to the LLM MUST be typed, read-only by default, and idempotent:

```
query_production(date_from, date_to, line?, sku?, shift?)  -> rows
query_defects(date_from, date_to, group_by)                -> rows
get_spc(parameter, line, window)                           -> chart data + violations
search_memory(text, top_k)                                 -> past cases (pgvector)
get_machine_telemetry(machine_id, signal, window)          -> series
get_inspection_images(record_ids)                          -> signed URLs
create_draft_report(type, payload)                         -> draft_id   [write, HITL]
send_discord(channel, message)                             -> ok         [write, rate-limited]
```

---

## 4. Functional Requirements

### 4.1 Ingestion
| ID | Requirement | Priority |
|---|---|---|
| FR-P-01 | The system SHALL ingest CSV/XLSX production files from a watched folder or upload endpoint. | Must |
| FR-P-02 | The system SHALL validate schema, types, ranges and duplicates before commit, and quarantine invalid rows with a reason. | Must |
| FR-P-03 | The system SHALL accept inspection records pushed by edge nodes over HTTPS with an API key. | Must |
| FR-P-04 | The system SHALL subscribe to MQTT topics and/or OPC-UA nodes for machine telemetry. | Should |
| FR-P-05 | Re-ingesting the same source file SHALL be idempotent (upsert by natural key). | Must |

### 4.2 Vision & inspection
| ID | Requirement | Priority |
|---|---|---|
| FR-V-01 | The system SHALL store, for each inspection, the verdict (PASS/FAIL/REVIEW), defect classes, confidences, bounding regions and evidence image reference. | Must |
| FR-V-02 | The system SHALL route any inference with confidence below a configurable threshold to REVIEW. | Must |
| FR-V-03 | A human SHALL be able to override any verdict; the override, user and timestamp SHALL be recorded. | Must |
| FR-V-04 | Overridden records SHALL be exportable as a retraining dataset. | Should |

### 4.3 Quality engine
| ID | Requirement | Priority |
|---|---|---|
| FR-Q-01 | The system SHALL compute defect rate, Pareto of defect classes, and per-line/shift/SKU breakdown for any date range. | Must |
| FR-Q-02 | The system SHALL compute X̄-R, p and u control charts with control limits from a configurable baseline period. | Must |
| FR-Q-03 | The system SHALL compute Cp, Cpk, Pp, Ppk for parameters with defined USL/LSL. | Must |
| FR-Q-04 | The system SHALL flag Nelson rule violations (at minimum rules 1, 2, 3, 5). | Should |
| FR-Q-05 | The system SHALL detect statistically significant shifts vs a 7-day and 30-day baseline. | Must |

### 4.4 Agent & reporting
| ID | Requirement | Priority |
|---|---|---|
| FR-A-01 | The agent SHALL answer natural-language questions by calling the typed tools in §3.2 — never by inventing numbers. | Must |
| FR-A-02 | Every numeric claim in agent output SHALL be traceable to a tool result included in the same turn. | Must |
| FR-A-03 | The agent SHALL produce a daily brief containing: volume, defect count, defect rate, top defect, worst line, trend vs baseline, analysis, recommended action. | Must |
| FR-A-04 | The agent SHALL draft RCA (5-Why) and 8D sections; drafts SHALL require human approval before becoming official. | Must |
| FR-A-05 | Output language SHALL be selectable per user among Thai / Japanese / English. | Must |
| FR-A-06 | The agent SHALL refuse and say so when data is insufficient, rather than speculating. | Must |
| FR-A-07 | Write-capable tools SHALL be gated behind an explicit approval step in the UI or Discord. | Must |

### 4.5 Dashboard & notification
| ID | Requirement | Priority |
|---|---|---|
| FR-U-01 | The dashboard SHALL show live KPI tiles, trend charts, Pareto, and a defect image gallery with filters. | Must |
| FR-U-02 | The dashboard SHALL provide a review queue for REVIEW records with keyboard-first judging. | Must |
| FR-U-03 | The Discord bot SHALL post the daily brief on a schedule and support `/ask <question>`. | Must |
| FR-U-04 | The system SHALL alert when defect rate exceeds a configurable threshold within a configurable window. | Must |
| FR-U-05 | Reports SHALL be exportable as PDF and PPTX with charts and evidence images. | Should |

### 4.6 Administration
| ID | Requirement | Priority |
|---|---|---|
| FR-S-01 | The system SHALL support roles: viewer, inspector, engineer, manager, admin. | Must |
| FR-S-02 | All AI calls SHALL be logged with prompt hash, model, latency, token counts and tool calls. | Must |
| FR-S-03 | Model versions SHALL be recorded on every inference record. | Must |

---

## 5. External Interface Requirements

### 5.1 REST API (representative)
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/ingest/production` | upload production file |
| POST | `/api/v1/inspections` | edge node pushes inspection result |
| GET | `/api/v1/kpi?from=&to=&line=` | KPI aggregate |
| GET | `/api/v1/spc?param=&line=&window=` | control chart data |
| POST | `/api/v1/agent/ask` | natural-language question |
| POST | `/api/v1/reports/{type}` | generate report |
| GET | `/api/v1/reviews?status=pending` | review queue |
| PATCH | `/api/v1/inspections/{id}/verdict` | human override |

All endpoints return RFC 7807 problem details on error and are documented via OpenAPI 3.1.

### 5.2 Hardware interfaces
GigE/USB3 industrial cameras (GenICam), light controller (optional), PLC/OPC-UA read-only, barcode scanner (HID).

### 5.3 Communications
HTTPS (self-signed CA acceptable on LAN), MQTT 3.1.1/5, OPC-UA binary, Discord Gateway + Webhooks, SMTP (optional).

---

## 6. Data Requirements

### 6.1 Core tables (sketch)
```sql
line(id, name, plant, active)
sku(id, code, name, spec_json)
production_record(id, ts, line_id, sku_id, shift, qty_produced, qty_ng, source_file, created_at)
defect_type(id, code, name_th, name_ja, name_en, category)
inspection(id, ts, line_id, sku_id, lot, station, verdict, model_version,
           latency_ms, image_uri, created_by)
inspection_defect(id, inspection_id, defect_type_id, confidence, bbox_json, area_px)
measurement(id, inspection_id, parameter, value, unit, usl, lsl)
machine_telemetry(ts, machine_id, signal, value)          -- hypertable candidate
quality_case(id, opened_at, title, line_id, sku_id, status, owner, severity)
case_step(id, case_id, kind, content_json, author, ai_generated, approved_by, approved_at)
document(id, kind, title, uri, lang, created_at)
document_chunk(id, document_id, ordinal, text, embedding vector(1024))
agent_run(id, ts, user_id, question, model, tool_calls_json, answer, tokens, latency_ms)
audit_log(id, ts, user_id, action, entity, entity_id, before_json, after_json)
```

### 6.2 Retention
| Data | Retention |
|---|---|
| PASS evidence images | 30 days (configurable), then thumbnail only |
| FAIL / REVIEW images | 2 years |
| Inspection records | 5 years |
| Telemetry raw | 90 days raw, then 1-minute aggregates for 2 years |
| Agent runs / audit log | 2 years |

### 6.3 Data quality
Ingest SHALL reject a batch if >5 % of rows fail validation, and notify the admin with a diff report.

---

## 7. AI / ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Vision models SHALL be exportable to ONNX/TensorRT for edge deployment. |
| AI-02 | Baseline detection model: YOLO11-s/m at 640 px, or RF-DETR where accuracy demands it. |
| AI-03 | Target vision metrics for v1: mAP@50 ≥ 0.85 on hold-out; **recall on critical defects ≥ 0.98** (missed defect is worse than a false alarm). |
| AI-04 | LLM: local instruct model ≤ 9 B at Q4_K_M via Ollama, with tool/function calling; optional cloud fallback behind a feature flag. |
| AI-05 | Embeddings: multilingual model (Thai/Japanese/English) with 1024-dim output stored in pgvector; HNSW index. |
| AI-06 | Every model SHALL be versioned (`name:version:hash`) and pinned per deployment. |
| AI-07 | The system SHALL monitor input drift (image brightness/blur, class distribution) and alert on significant deviation. |
| AI-08 | A retraining pipeline SHALL rebuild a candidate model from accumulated human overrides and report metric deltas before promotion. |
| AI-09 | Agent answers SHALL be evaluated against a golden Q&A set (≥50 questions) with a factuality pass rate ≥ 90 % before release. |
| AI-10 | Prompts and system messages SHALL be versioned in git, not hard-coded in ad-hoc strings. |

---

## 8. Non-Functional Requirements

| ID | Category | Requirement |
|---|---|---|
| NFR-01 | Performance | Dashboard queries over 90 days ≤ 2 s p95. |
| NFR-02 | Performance | Vision inference ≤ 150 ms/frame at 640 px on the edge baseline GPU. |
| NFR-03 | Performance | Agent answer ≤ 20 s p95 for a 3-tool question on local LLM. |
| NFR-04 | Availability | Core services ≥ 99 % during production shifts; edge inspection continues if the server is down (store-and-forward). |
| NFR-05 | Scalability | ≥ 10 lines, ≥ 100 k inspections/day, ≥ 5 concurrent agent sessions. |
| NFR-06 | Security | JWT auth, RBAC, TLS in transit, secrets via env/Docker secrets, no credentials in git. |
| NFR-07 | Privacy | Operator faces/IDs SHALL NOT be used as a model feature; personal identifiers pseudonymised in analysis. |
| NFR-08 | Usability | Shop-floor screens usable on a 10" tablet with gloves; Thai UI default. |
| NFR-09 | Maintainability | ≥ 70 % unit-test coverage on Quality Engine and tool layer; CI runs lint + tests. |
| NFR-10 | Portability | Single `docker compose` file; runs air-gapped with a pre-pulled model cache. |
| NFR-11 | Observability | Structured JSON logs, Prometheus metrics, health endpoints per service. |
| NFR-12 | Backup | Nightly DB dump + object-store snapshot, restore tested quarterly. |

---

## 9. Acceptance Criteria and Verification

| ID | Acceptance test | Method |
|---|---|---|
| AC-01 | `docker compose up` on a clean machine brings up all services healthy within 5 min. | Demo |
| AC-02 | Importing a 30-day production CSV set produces correct KPI totals vs a manual Excel check. | Analysis |
| AC-03 | Given a seeded dataset, the daily brief numbers match SQL ground truth exactly. | Test |
| AC-04 | 50-question golden set: ≥ 90 % factually correct, 0 fabricated numbers. | Test |
| AC-05 | Vision hold-out set meets AI-03 thresholds. | Test |
| AC-06 | Cutting the server link for 30 min: edge node buffers and later syncs with no data loss. | Test |
| AC-07 | A non-approved AI draft never appears as an official 8D record. | Test |
| AC-08 | Japanese report renders correctly (no mojibake) in PDF and PPTX. | Inspection |

---

## 10. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P0 Foundation | 1–2 | repo, docker compose, PG+pgvector, auth, CI |
| P1 Data & KPI | 3–4 | ingest, schema, KPI API, first dashboard |
| P2 Quality Engine | 5–6 | SPC, Cpk, Pareto, alerts |
| P3 Vision | 7–9 | dataset, model v1, inspection API, review UI |
| P4 Agent | 10–12 | tools, agent loop, daily brief, Discord `/ask` |
| P5 Reports & i18n | 13–14 | PDF/PPTX, TH/JA/EN |
| P6 Hardening | 15–16 | tests, docs, backup, demo video |

---

## 11. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Insufficient labelled defect images | High | start with anomaly detection + synthetic augmentation; HITL to grow dataset |
| LLM hallucinates numbers | High | tools-only numerics, FR-A-02 traceability, golden-set gating |
| 8 GB VRAM shared by vision + LLM | Medium | separate processes, quantised LLM, queue with GPU semaphore |
| Scope creep across 15 sibling projects | High | FactoryBrain defines contracts only; siblings ship independently |
| Factory network restrictions | Medium | offline-first design, store-and-forward |
| Model drift after line/lighting change | Medium | drift monitor AI-07, scheduled re-validation |

---

## 12. Future Enhancements
- Closed-loop parameter recommendation to the machine (with safety interlock).
- Multi-plant federation and cross-plant benchmarking.
- Vision-language model for zero-shot defect description.
- Digital twin / simulation link.

---

## Appendix A — Example agent output (EN)

```
Line 2 — 2026-09-10
Inspected      : 1,240
Defects        : 37
Defect rate    : 2.98 %  (+42 % vs 7-day avg 2.10 %)
Top defect     : missing fin (19 pcs, 51 %)
Worst SKU      : RAD-500-A (4.4 %)
Correlation    : 31/37 defects in Shift B, after 14:30

Analysis: the increase is concentrated in Shift B and in one SKU,
starting shortly after the material lot change at 14:12
(lot LOT-2609-114). Feeder station #3 shows the highest
per-station defect share (0.9 % vs 0.3 % line average).

Recommended action:
1. Inspect feeder station #3 (mechanical alignment).
2. Verify material lot LOT-2609-114 against incoming inspection.
3. Review Shift B changeover record.

Sources: query_defects(2026-09-10), get_spc(defect_rate, line=2, 30d),
search_memory("missing fin feeder")   [3 similar cases: 2025-11-04, ...]
```
