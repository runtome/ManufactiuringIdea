# Software Architecture Document — FactoryBrain AI Platform

| Field | Value |
|---|---|
| Document ID | SAD-00-FactoryBrain |
| Project code name | **FactoryBrain AI** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Classification | Internal / Portfolio |
| Governs | [SRS-00-FactoryBrain](../SRS-FactoryBrain-AI-Platform.md) |

**Structure basis:** ISO/IEC/IEEE 42010:2011 (architecture description) with C4-model views.

---

## 1. Introduction

### 1.1 Purpose
This document describes **how** FactoryBrain AI is built. The [SRS](../SRS-FactoryBrain-AI-Platform.md) states what the platform must do; this document states the structures, decisions and rationale that satisfy those requirements, in enough detail for an implementer to build the system and a reviewer to challenge it.

### 1.2 Audience
| Audience | Read |
|---|---|
| Implementer | §4 views, §5 cross-cutting, §7 ADRs |
| Reviewer / architect | §3 drivers, §7 ADRs, §8 quality scenarios, §10 risks |
| Security reviewer | §5.1–5.3, then [SEC](SEC-FactoryBrain-Security-Requirements.md) |
| Integrator (sibling project) | §6 sibling integration map, then [ICD](ICD-FactoryBrain-Interface-Control.md) |
| Operator | §4.5 deployment view, then [OPS](OPS-FactoryBrain-Deployment-Operations.md) |

### 1.3 Related documents
| ID | Document |
|---|---|
| SRS-00 | [Software Requirements Specification](../SRS-FactoryBrain-AI-Platform.md) |
| DDS-00 | [Database Design Specification](DDS-FactoryBrain-Database-Design.md) |
| API-00 | [API Specification](../api/API-Specification.md) · [`openapi.yaml`](../api/openapi.yaml) |
| ICD-00 | [Interface Control Document](ICD-FactoryBrain-Interface-Control.md) |
| SEC-00 | [Security Requirements](SEC-FactoryBrain-Security-Requirements.md) |
| TEST-00 | [Test Plan](TEST-FactoryBrain-Test-Plan.md) |
| OPS-00 | [Deployment & Operations](OPS-FactoryBrain-Deployment-Operations.md) |
| SRS-01…15 | Sibling project specifications (see [repository README](../../README.md)) |

---

## 2. Architecture principles

These four principles are **binding**. Any design that violates one is a defect, not a trade-off. They are repeated in every document in this set because they explain most of the decisions in it.

| ID | Principle | Consequence |
|---|---|---|
| **P-1** | **The LLM never computes numbers.** | Statistics are computed by the Quality Engine in Python. The model receives a structured *facts object* and writes prose around it. Every figure in AI output must be traceable to a tool result in the same turn (SRS FR-A-02). |
| **P-2** | **Offline-first.** | The factory LAN and the internet are both assumed unreliable. Edge nodes inspect and buffer without the server; the server operates without the internet. Nothing on the critical path may depend on a cloud call (SRS C-01, NFR-04). |
| **P-3** | **Human-in-the-loop for consequences.** | AI drafts, proposes and ranks. A named human approves anything that changes a verdict, a document of record, a machine, or an ERP transaction (SRS FR-A-04, FR-A-07, C-05). |
| **P-4** | **The database is the single source of truth.** | No component holds authoritative state in memory, in a file, or in an LLM context window. Any derived artefact can be rebuilt from the database (SRS C-06). |

A fifth, weaker rule guides sizing: **the 8 GB GPU is a first-class architectural constraint**, not a deployment detail. It forces model selection, process separation and the GPU semaphore in §5.6.

---

## 3. Architectural drivers

### 3.1 Constraints (from SRS §2.4)
| ID | Constraint | Architectural impact |
|---|---|---|
| C-01 | Local inference; no data leaves the LAN by default | No managed cloud services on the critical path; Ollama in-cluster; egress default-deny (§5.3) |
| C-02 | LLM ≤ 8 GB VRAM shared with vision | Model choice ≤ 9 B Q4_K_M; separate processes; GPU semaphore (ADR-011) |
| C-03 | Python 3.11 + FastAPI; Next.js 15 + TypeScript | Language boundary at the HTTP/OpenAPI contract |
| C-04 | Every component a Docker image; `docker compose up` | No host-installed dependencies except GPU driver/toolkit |
| C-05 | AI conclusions labelled and traceable | `ai_generated` and `approved_by` columns are structural, not cosmetic (DDS) |
| C-06 | DB is the single source of truth | Stateless services; agent state persisted per turn |

### 3.2 Quality attributes that shape the architecture
| Driver | Requirement | Shapes |
|---|---|---|
| Latency at the edge | NFR-02 ≤ 150 ms/frame | ONNX/TensorRT at the edge, not server round-trip (ADR-004, ADR-010) |
| Availability during shifts | NFR-04 ≥ 99 %, edge survives server loss | Store-and-forward, at-least-once sync, idempotency (ADR-004, §5.7) |
| Scale | NFR-05 ≥ 100 k inspections/day | Partitioned tables, async workers, batched ingest |
| Grounding / correctness | FR-A-02, AI-09 | Typed tools + facts object + post-check (ADR-005, §4.4.2) |
| Portability | NFR-10 air-gapped | Pre-pulled model cache, no CDN dependency, internal CA |
| Auditability | FR-S-02, C-05 | Append-only audit, correlation IDs, model version on every inference |

### 3.3 What is explicitly *not* an architectural driver
Multi-tenancy, horizontal auto-scaling, cloud elasticity, and sub-second global availability are **not** drivers. FactoryBrain is a single-plant, on-premise system operated by a small team. Designing for cloud-scale elasticity here would add cost and failure modes with no corresponding requirement — see ADR-002.

---

## 4. Architecture views

### 4.1 Context view (C4 level 1)

```
                        ┌─────────────────────────────────────┐
   Line cameras ───────►│                                     │
   PLC / OPC-UA ───────►│                                     │──► Discord (briefs, alerts, /ask)
   Machine telemetry ──►│        FactoryBrain AI Platform     │
   Production files ───►│        (on-premise, factory LAN)    │──► Email / webhook
   Quality documents ──►│                                     │
   Mobile inspectors ──►│                                     │──► PDF / PPTX reports
                        └───────┬──────────────┬──────────────┘
                                │              │
                    read-only   │              │  approved writes only
                                ▼              ▼
                          MES / ERP        (no machine control in v1)
```

**External actors**

| Actor | Direction | Interface | Notes |
|---|---|---|---|
| Line camera | in | [IF-02](ICD-FactoryBrain-Interface-Control.md#if-02) GenICam | Owned by edge node, not the server |
| PLC | in/out | [IF-03](ICD-FactoryBrain-Interface-Control.md#if-03) digital I/O | Verdict signal out; **advisory** — the PLC decides what to do with it |
| Machine controller | in | [IF-05](ICD-FactoryBrain-Interface-Control.md#if-05) OPC-UA | **Read-only session**, enforced by credential |
| MES / ERP | in/out | [IF-07](ICD-FactoryBrain-Interface-Control.md#if-07) | Read for master data; write only via DocFlow approval (SRS-08) |
| Discord | out/in | [IF-08](ICD-FactoryBrain-Interface-Control.md#if-08) | Delivery + `/ask`; not a system of record |
| Ollama | out | [IF-09](ICD-FactoryBrain-Interface-Control.md#if-09) | In-cluster; the only LLM by default |

> **Boundary rule.** FactoryBrain sits *beside* MES/ERP. It never becomes the system of record for production or financial data, and it never actuates machinery. The only writes leaving the platform are ERP postings that a human approved (SRS-08 C-01).

---

### 4.2 Container view (C4 level 2)

```
┌──────────────────────────── FACTORY LAN ─────────────────────────────────────┐
│                                                                              │
│  ┌── Edge zone (per line) ──────────┐      ┌── Server zone ────────────────┐ │
│  │                                  │      │                              │ │
│  │  E1 Capture Service              │      │  A1 Ingest Service           │ │
│  │  E2 Inference Runtime (TensorRT) │      │  A5 AI Gateway               │ │
│  │  E3 Rules Engine                 │─────►│  A6 Agent Runtime            │ │
│  │  E4 Local store (SQLite)         │ sync │  A4 Quality Engine           │ │
│  │  E5 Sync Agent                   │ IF-01│  A9 Report Service           │ │
│  │  E6 Local HMI (kiosk)            │      │  A8 Notifier                 │ │
│  └──────────────────────────────────┘      │  A10 Auth & RBAC             │ │
│                                            │  A2 Vision Service (batch)   │ │
│  ┌── Mobile ────────────────────────┐      │                              │ │
│  │  M1 PocketQC (Flutter, on-device │─────►│  ┌── Data platform (A3) ───┐ │ │
│  │     model, offline queue)        │IF-11 │  │ PostgreSQL 16          │ │ │
│  └──────────────────────────────────┘      │  │  + pgvector            │ │ │
│                                            │  │  + TimescaleDB (opt)   │ │ │
│  ┌── Clients ───────────────────────┐      │  │ MinIO (evidence)       │ │ │
│  │  Browser (A7 Next.js web app)    │◄────►│  │ Redis / NATS (bus)     │ │ │
│  │  Shop-floor tablet               │      │  └────────────────────────┘ │ │
│  └──────────────────────────────────┘      │                              │ │
│                                            │  ┌── Inference ───────────┐ │ │
│                                            │  │ Ollama (LLM)           │ │ │
│                                            │  │ GPU semaphore          │ │ │
│                                            │  └────────────────────────┘ │ │
│                                            └──────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Container responsibilities**

| ID | Container | Tech | Responsibility | Scales by |
|---|---|---|---|---|
| A1 | Ingest Service | FastAPI + RQ workers | File watch, CSV/XLSX import, validation, quarantine, MQTT/OPC-UA subscribe | worker count |
| A2 | Vision Service | Python + ONNX Runtime | Server-side/batch inference, retraining dataset export, drift metrics | GPU-bound, 1 instance |
| A3 | Data Platform | PostgreSQL 16, MinIO, Redis/NATS | Persistence, object store, message bus | vertical |
| A4 | Quality Engine | Python (pandas, scipy, statsmodels) | SPC charts, Cp/Cpk, Nelson rules, Pareto, significance tests | stateless, N instances |
| A5 | AI Gateway | FastAPI | Model routing, prompt templates, token/time budgets, grounding post-check, audit | stateless, N instances |
| A6 | Agent Runtime | Python tool-calling loop + Ollama | Plans, calls typed tools, drafts analysis | GPU-serialised |
| A7 | Web App | Next.js 15 + Tailwind + Recharts | Dashboard, review queue, case UI, report viewer | stateless, N instances |
| A8 | Notifier | discord.py + webhook/SMTP | Scheduled briefs, threshold alerts, `/ask` bridge | 1 instance (gateway session) |
| A9 | Report Service | python-pptx, WeasyPrint | PDF/PPTX with charts and evidence | stateless, N instances |
| A10 | Auth & RBAC | FastAPI + JWT | Users, roles, tokens, edge identity, audit hooks | stateless, N instances |
| E1–E6 | Edge node | see [SRS-03](../../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md) | Autonomous inspection + store-and-forward | one per line/station |
| M1 | Mobile app | see [SRS-05](../../05-offline-mobile-inspector/SRS-PocketQC-Offline-Mobile-Inspector.md) | Offline inspection + sync | per device |

> **Deployment reality (ADR-002).** A1/A4/A5/A9/A10 are *modules of one Python application*, deployed as one image with different entrypoints — not separate microservices. The table above describes logical containers; §4.5 describes what actually runs.

---

### 4.3 Component view (C4 level 3) — the four containers worth decomposing

#### 4.3.1 AI Gateway (A5)

```
             POST /api/v1/agent/ask
                       │
            ┌──────────▼──────────┐
            │  Request Validator  │  auth, quota, language, scope
            └──────────┬──────────┘
                       ▼
            ┌─────────────────────┐
            │  Prompt Assembler   │  versioned templates (AI-10), glossary, locale
            └──────────┬──────────┘
                       ▼
            ┌─────────────────────┐        ┌──────────────────┐
            │  Model Router       │───────►│  GPU Semaphore   │ (§5.6)
            │  local │ cloud-flag │        └──────────────────┘
            └──────────┬──────────┘
                       ▼
            ┌─────────────────────┐
            │  Agent Runtime (A6) │  tool loop, budget enforcement
            └──────────┬──────────┘
                       ▼
            ┌─────────────────────┐
            │  Grounding Post-Check│ ◄── **the enforcement point for P-1**
            │  every number in the │
            │  answer ∈ tool results│
            └──────────┬──────────┘
                       ▼
            ┌─────────────────────┐
            │  Audit Writer       │  agent_run + tool_call rows (FR-S-02)
            └─────────────────────┘
```

The **Grounding Post-Check** is the component that makes P-1 real rather than aspirational. It extracts every numeric token from the model's answer and asserts membership in the union of tool-result values (with tolerance for rounding and formatting). A failure is not a retry-and-hope: the answer is withheld and the turn is marked `grounding_failed`. See [TEST TC-041…TC-046](TEST-FactoryBrain-Test-Plan.md).

#### 4.3.2 Quality Engine (A4)

```
  chart_engine     ── X̄-R, X-mR, p, np, c, u; limits from baseline period
  rules_engine     ── Nelson rules 1–8, minimum {1,2,3,5,6}
  capability       ── Cp, Cpk, Pp, Ppk + Anderson–Darling normality gate
  significance     ── two-proportion z, Fisher exact, CUSUM change-point
  aggregation      ── KPI rollups, Pareto, per line/shift/SKU breakdown
  facts_builder    ── assembles the versioned facts object consumed by A5
```

`facts_builder` is the **only** path by which numbers reach the LLM. No other component may pass raw rows into a prompt.

#### 4.3.3 Ingest Service (A1)

```
  watchers      ── folder, upload endpoint, IMAP, MQTT, OPC-UA
  mapper        ── per-source YAML column mapping (schema drift tolerant)
  validator     ── types, ranges, referential checks, >5 % batch reject (SRS §6.3)
  quarantine    ── invalid rows + human-readable reason
  upserter      ── idempotent by natural key / source hash (FR-P-05)
  archiver      ── original file immutably stored + SHA-256
```

#### 4.3.4 Agent Runtime (A6)

```
  planner       ── intent → tool sequence, max N tools/turn (budget)
  tool_registry ── typed, schema-validated, read-only by default (ADR-005)
  executor      ── parallel where independent; permission-filtered per user
  composer      ── prose only; receives facts, never raw DB access
  approval_gate ── write-capable tools suspend for human approval (P-3)
```

---

### 4.4 Runtime views

#### 4.4.1 Edge inspection → verdict → sync (the offline-critical path)

```
Camera    Edge(E1-E4)         PLC        Sync(E5)      Platform(A1)      DB
  │           │                │            │               │             │
  ├─trigger──►│                │            │               │             │
  │           ├─preprocess     │            │               │             │
  │           ├─infer (TRT)    │            │               │             │
  │           ├─rules→verdict  │            │               │             │
  │           ├───verdict──────►│  ≤200 ms p95 (NFR-02)     │             │
  │           ├─persist LOCAL──┐│            │               │             │
  │           │◄───────────────┘│            │               │             │
  │           │   *** acknowledged to the line here ***      │             │
  │           │                │            │               │             │
  │           ├────────────────┼───enqueue─►│               │             │
  │           │                │            ├──batch POST──►│             │
  │           │                │            │  IF-01        ├─dedup(UUID)►│
  │           │                │            │◄──207 result──┤             │
```

**The critical property:** the line is acknowledged *before* any network operation. If the platform is unreachable for 72 hours, inspection continues and the queue drains later (SRS AC-06, [SRS-03 NFR-04](../../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md)). Delivery is at-least-once; the platform deduplicates by record UUID, which is why every edge record carries a client-generated UUID (§5.7).

#### 4.4.2 Agent question → grounded answer

```
User      A7 Web    A5 Gateway   A6 Agent    Tools/A4     Ollama      DB
 │          │           │           │           │           │          │
 ├─question►├──────────►│           │           │           │          │
 │          │           ├─assemble prompt (versioned)        │          │
 │          │           ├──────────►│           │           │          │
 │          │           │           ├─plan─────────────────►│          │
 │          │           │           │◄──tool calls──────────┤          │
 │          │           │           ├──────────►│           │          │
 │          │           │           │           ├─SQL (agent_ro role)─►│
 │          │           │           │◄─facts────┤           │          │
 │          │           │           ├─compose (facts only)─►│          │
 │          │           │           │◄──prose───────────────┤          │
 │          │           │◄──answer──┤           │           │          │
 │          │           ├─GROUNDING POST-CHECK                          │
 │          │           │   pass → return · fail → withhold + log       │
 │          │◄─stream───┤           │           │           │          │
 │◄─render──┤  answer + citations + "show the numbers"                  │
```

Budgets are enforced by the executor, not by the model's cooperation: max tool calls per turn, max wall time, max tokens. Exceeding a budget yields a **partial answer explicitly marked incomplete** — never a silent truncation.

#### 4.4.3 Draft → approval → record of record (P-3)

```
Agent drafts 8D ──► case_step(ai_generated=true, approved_by=NULL)
                          │
                    UI shows "DRAFT — AI generated" watermark
                          │
             Engineer edits ──► new version row (append-only)
                          │
              Engineer approves ──► approved_by, approved_at set
                          │
                    Only now: exportable without watermark,
                    indexed into knowledge base, citable as precedent
```

An unapproved draft **cannot** be exported clean, cannot become a precedent in Genba Memory, and cannot be cited by another agent. This is enforced by predicate, not by convention: export and retrieval queries filter on `approved_by IS NOT NULL`.

#### 4.4.4 Model promotion (shadow → promote → rollback)

```
new model artefact (manifest: version, sha256, metrics, class map)
        │
   checksum verify ──fail──► reject, alarm
        │ pass
   shadow run on ≥200 live frames (no verdict effect)
        │
   disagreement report vs current model
        │
   human promotion decision (P-3)
        │
   atomic swap; previous model retained
        │
   one-command rollback available; model_version stamped on every inference
```

#### 4.4.5 Document → ERP posting (the only outbound write)

```
Document ─► extract (schema-constrained) ─► validate (arithmetic in CODE, not LLM)
    ─► confidence gate ─► human review ─► role-checked approval
    ─► idempotent post (idem_key = doc hash + target) ─► erp_ref recorded
```
Retry can never double-post: the adapter contract requires `idem_key` honouring ([SRS-08](../../08-document-erp-agent/SRS-DocFlow-Document-to-ERP-Agent.md) C-04, [ICD IF-07](ICD-FactoryBrain-Interface-Control.md#if-07)).

---

### 4.5 Deployment view

#### 4.5.1 Reference topology (single server + N edge nodes)

```
┌─ Server (Ubuntu 22.04, ≥32 GB RAM, ≥1 TB SSD, RTX 3060 Ti 8 GB) ─────────┐
│  docker compose stack — see deploy/docker-compose.yml                    │
│                                                                          │
│   caddy/nginx (TLS, internal CA)                                         │
│   web (Next.js)          api (FastAPI: A1,A4,A5,A9,A10 modules)          │
│   worker (RQ: ingest, reports, retention)                                │
│   agent (A6, GPU)        vision (A2, GPU, batch)                         │
│   ollama (GPU)           postgres+pgvector    minio    redis/nats        │
│   prometheus   grafana                                                   │
└──────────────────────────────────────────────────────────────────────────┘
        ▲                    ▲                      ▲
        │ IF-01 mTLS         │ IF-11 TLS+JWT        │ HTTPS
   ┌────┴─────┐        ┌─────┴──────┐        ┌──────┴──────┐
   │ Edge x N │        │ Mobile x M │        │  Browsers   │
   │ Jetson / │        │ PocketQC   │        │  Tablets    │
   │ mini-PC  │        │            │        │             │
   └──────────┘        └────────────┘        └─────────────┘
```

Three supported topologies (detailed in [OPS §2](OPS-FactoryBrain-Deployment-Operations.md)): **single-node all-in-one** (demo/pilot), **server + N edge** (reference), **fully air-gapped** (no egress at all; pre-pulled images and models).

#### 4.5.2 GPU allocation on the 8 GB baseline

| Consumer | Budget | Mechanism |
|---|---|---|
| Ollama (LLM ≤ 9 B Q4_K_M) | ~5.5 GB | resident; `OLLAMA_KEEP_ALIVE` tuned |
| Vision batch (A2) | ~1.5 GB | acquires semaphore, releases after batch |
| Headroom | ~1 GB | fragmentation, CUDA context |

Edge inference runs on the **edge node's** GPU, not the server's — this is why NFR-02 is achievable while the server GPU is busy with the LLM.

#### 4.5.3 Network zones

| Zone | Contents | Ingress | Egress |
|---|---|---|---|
| Z1 OT / machine | PLC, machine controllers, cameras | none from Z3 | none |
| Z2 Edge | Edge nodes | Z1 (read), Z3 (config pull) | Z3 only, to the sync endpoint |
| Z3 Platform | Server stack | Z2, Z4 | **default-deny**; optional allow-list for weather/cloud LLM if enabled |
| Z4 Client | Browsers, tablets, mobile | — | Z3 |

Zone crossings are the conduits enumerated in [SEC §6](SEC-FactoryBrain-Security-Requirements.md).

---

### 4.6 Data view
Owned by the [DDS](DDS-FactoryBrain-Database-Design.md). Architectural summary only:

- **Schema-per-domain** in one PostgreSQL instance: `core`, `vision`, `quality`, `telemetry`, `knowledge`, `agent`, `docflow`, `ops`, `audit`. Isolation by schema + role grants, not by separate databases — one backup, one transaction boundary, one set of foreign keys.
- **`farm` and `pawtrace`** (SRS-12, SRS-07) are documented in the DDS but are **logically separate deployments**. They reuse the platform's patterns; they do not belong in a factory database. Stated explicitly so nobody later "integrates" a dog-finder table into a quality schema.
- **Time-series** (`telemetry.*`) uses TimescaleDB hypertables where available, native partitioning otherwise (ADR-007).
- **Vectors** (`knowledge.*`) use pgvector with HNSW, 1024-dim, and an explicit `embedding_version` so a model upgrade is a background re-embed rather than a stop-the-world migration (ADR-001).

---

## 5. Cross-cutting concerns

### 5.1 Authentication and authorisation
JWT access tokens (short-lived) + refresh; roles `viewer` < `inspector` < `engineer` < `manager` < `admin` (SRS FR-S-01). Edge nodes authenticate by **mTLS client certificate or per-node API key** — never a user token. Authorisation is enforced **at the tool/query layer**, not by filtering the response: an unauthorised user's query never retrieves the rows in the first place. Full matrix in [SEC §5](SEC-FactoryBrain-Security-Requirements.md).

### 5.2 Configuration
Twelve-factor: environment variables only, no config files baked into images. Every variable is documented in [`deploy/.env.example`](../deploy/.env.example) and [OPS §4](OPS-FactoryBrain-Deployment-Operations.md). Secrets arrive via Docker secrets or environment injection and never appear in prompts, logs or audit rows.

### 5.3 Egress control
Default-deny outbound from Z3. Enabling a cloud LLM is an explicit admin action, feature-flagged, logged, and visible in the UI — because it changes where factory data goes (SRS C-01). This is deliberately made awkward.

### 5.4 Logging, metrics, tracing
Structured JSON logs with a **correlation ID** propagated from the HTTP request through tool calls into the model call and back. Prometheus metrics per service (`/metrics`), health endpoints (`/healthz`, `/readyz`). Metric catalogue in [OPS §7](OPS-FactoryBrain-Deployment-Operations.md). Every `agent_run` row records model, prompt version, token counts, latency and tool calls (FR-S-02).

### 5.5 Internationalisation
Thai (default), Japanese, English. Language is a property of the **user**, applied at render time; stored data is language-neutral (defect types carry `name_th`/`name_ja`/`name_en`). Report generation must embed CJK and Thai fonts in the container image — a missing font is the usual cause of mojibake in PDF/PPTX (SRS AC-08). Japanese output is checked against a terminology glossary.

### 5.6 GPU arbitration
A single semaphore (Redis lock) guards GPU-heavy work on the server. Vision batches and LLM inference **never** run concurrently on the 8 GB card. Consequences are accepted deliberately: agent latency rises while a vision batch runs, so batch work is scheduled off-shift. Queue depth and wait time are exported as metrics so this is visible rather than mysterious (ADR-011).

### 5.7 Idempotency and delivery semantics
Every record created by an edge node or mobile device carries a **client-generated UUID**. Transport is at-least-once; the platform's dedup makes the *effect* exactly-once. Write APIs accept an `Idempotency-Key` header. File ingest is idempotent by natural key + source hash. This is what allows aggressive retry without fear of duplicates.

### 5.8 Time
All timestamps are `timestamptz` in UTC; local time is a presentation concern. Every node is NTP-synced; clock skew > 5 s raises a data-quality event, because skew silently corrupts shift attribution and change-point analysis.

### 5.9 Error handling
All APIs return RFC 7807 problem details with a stable `type` URI and a machine-readable `code` (catalogue in [API Specification §7](../api/API-Specification.md)). Errors are never swallowed into a 200 response. Partial batch results use `207 Multi-Status` with per-item outcomes.

---

## 6. Sibling integration map

Each sibling is an independent product. FactoryBrain owns the **integration surface**: the schema it writes, the endpoints it calls, the interfaces it speaks. Internal behaviour stays in the sibling's own SRS.

| SRS | Project | Deployment unit | Owns schema | Inbound | Outbound | Coupling |
|---|---|---|---|---|---|---|
| [01](../../01-factory-inspector-agent/SRS-AI-Factory-Inspector-Agent.md) | VisionOps | server module | `vision` | IF-01, IF-02 | agent tools, IF-08 | tight (core) |
| [02](../../02-production-ai-analyst/SRS-ShiftBrief-Production-AI-Analyst.md) | ShiftBrief | server module | `core.production_*` | file/IMAP | IF-08, reports | tight (core) |
| [03](../../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md) | EdgeGuard | **separate device** | local SQLite | IF-02, IF-03 | IF-01 | loose (async sync) |
| [04](../../04-local-ai-ops-agent/SRS-OpsPilot-Local-AI-Operations-Agent.md) | OpsPilot | separate stack | `ops` | Docker/host | IF-08 | **none** (infrastructure, not factory data) |
| [05](../../05-offline-mobile-inspector/SRS-PocketQC-Offline-Mobile-Inspector.md) | PocketQC | **mobile app** | local SQLite | camera | IF-11 | loose (async sync) |
| [06](../../06-predictive-maintenance-agent/SRS-MachineSense-Predictive-Maintenance.md) | MachineSense | server module | `telemetry` | IF-04, IF-05, IF-06 | agent tools, IF-08 | tight |
| [07](../../07-ai-dog-finder/SRS-PawTrace-AI-Dog-Finder.md) | PawTrace | **separate deployment** | `pawtrace` (own DB) | public web | push/email | **none** (shares patterns only) |
| [08](../../08-document-erp-agent/SRS-DocFlow-Document-to-ERP-Agent.md) | DocFlow | server module | `docflow` | IMAP, upload | **IF-07 (only outbound write)** | medium |
| [09](../../09-quality-engineer-agent/SRS-QE-Agent-Quality-Engineer.md) | QE-Agent | server module | `quality` | A4 facts | drafts → HITL | tight (core) |
| [10](../../10-factory-copilot/SRS-FactoryCopilot-Local-Multilingual-Assistant.md) | Factory Copilot | server module + UI | `agent` | all tools | UI, IF-08 | tight (front door) |
| [11](../../11-injection-molding-ai/SRS-MoldMind-Injection-Molding-AI.md) | MoldMind | server module | `quality.mould`, `quality.shot`, `quality.shot_part`, `quality.timeline_event` | IF-05 (Euromap 77) | QE-Agent handoff | medium |
| [12](../../12-gapfarm-ai-agent/SRS-GAPFarm-AI-Farmer-Agent.md) | GAPFarm AI | **separate deployment** | `farm` (own DB) | IF-12 | LINE/Discord | **none** (shares patterns only) |
| [13](../../13-multi-agent-factory/SRS-KaizenSwarm-Multi-Agent-Factory.md) | KaizenSwarm | server module | `agent.finding*` | IF-17 bus | briefing → IF-08 | tight (orchestrates 06/09/02) |
| [14](../../14-japanese-factory-translator/SRS-GenbaGo-Japanese-Factory-Translator.md) | GenbaGo | server module | `knowledge.tm_*` | upload, OCR | Copilot, Genba Memory | medium |
| [15](../../15-troubleshooting-memory/SRS-GenbaMemory-Troubleshooting-RAG.md) | Genba Memory | server module | `knowledge` | documents | `search_memory` tool | tight (core) |

**Three honest observations about this map:**

1. **04 OpsPilot, 07 PawTrace and 12 GAPFarm are not part of this platform.** They appear here because the user asked for full-sibling coverage, and their *integration surface with FactoryBrain is empty*. They reuse patterns (typed tools, HITL, offline-first, pgvector) and are documented in the DDS/ICD for completeness, but wiring them into the factory database would be a design error. They are listed so that the boundary is explicit.
2. **Tight coupling is concentrated in 01/02/09/10/15** — the core loop of inspect → measure → analyse → explain → remember. This is intentional: they share one schema and one transaction boundary.
3. **Every loose coupling is asynchronous** (03, 05) and every asynchronous link is idempotent (§5.7). That is the only reason offline-first works.

---

## 7. Architecture Decision Records

> Format: context → decision → consequences (including the ones we dislike).

### ADR-001 — PostgreSQL + pgvector instead of a dedicated vector database
**Context.** Semantic search is needed for Genba Memory, Copilot RAG and translation memory. Candidates: Qdrant/Milvus/Weaviate vs pgvector.
**Decision.** Use pgvector inside the existing PostgreSQL instance with HNSW indexes.
**Consequences.** ✅ One database to back up, one transaction boundary, joins between vectors and relational filters (line, SKU, date) in a single query — which is exactly the access pattern here. ✅ One less service on a 32 GB box. ❌ Lower ceiling than a specialised engine beyond ~10 M vectors; ❌ HNSW index build is memory-hungry. **Revisit if** the corpus exceeds ~5 M chunks or p95 search exceeds 500 ms.

### ADR-002 — Modular monolith, not microservices
**Context.** Ten logical containers, one operator, one server.
**Decision.** Ship A1/A4/A5/A9/A10 as one Python application with multiple entrypoints; separate processes only where isolation is genuinely required (agent/GPU, vision/GPU, notifier/gateway session, web).
**Consequences.** ✅ One deployment, one migration, no distributed transactions, dramatically simpler debugging. ✅ Module boundaries are enforced by import discipline and tests, so extraction stays possible. ❌ A crash in one module can take the API down; mitigated by per-module error isolation and workers. ❌ Scaling is coarse-grained — acceptable, since NFR-05's numbers fit one machine comfortably.

### ADR-003 — Ollama as the default local LLM runtime
**Context.** C-01 requires local inference; C-02 caps VRAM at 8 GB.
**Decision.** Ollama with a ≤ 9 B instruct model at Q4_K_M, tool-calling capable; cloud providers behind an explicit, logged feature flag.
**Consequences.** ✅ Simple model management, OpenAI-compatible surface, air-gap friendly. ✅ Swapping models is a config change. ❌ Weaker than frontier models at complex reasoning — mitigated because P-1 means the model writes prose, not analysis. ❌ Ollama is a single point of GPU contention (see ADR-011).

### ADR-004 — Store-and-forward at the edge, not server-side inference
**Context.** NFR-02 (≤150 ms/frame), NFR-04 (edge survives server loss), unreliable LAN.
**Decision.** Inference happens on the edge node; results are persisted locally and acknowledged to the line *before* any network call; a sync agent forwards batches with at-least-once delivery.
**Consequences.** ✅ Line never blocks on the network. ✅ Survives 72 h outages. ❌ Model distribution and version skew across nodes becomes a real operational problem — addressed by the manifest/shadow/rollback flow in §4.4.4. ❌ Edge devices need enough storage for the buffer.

### ADR-005 — Typed tools as the primary agent interface; text-to-SQL behind a flag
**Context.** The agent must answer data questions without fabricating numbers or executing dangerous SQL.
**Decision.** A registry of typed, schema-validated, read-only-by-default tools. Generated SQL is available only behind a feature flag, parsed and validated, executed as `agent_ro` with statement timeout and row limits.
**Consequences.** ✅ Bounded blast radius, testable, permission-filterable, cacheable. ✅ Tool results form the ground truth for the grounding post-check. ❌ Every new question shape may need a new tool — accepted; it is a feature that capabilities are deliberate. ❌ Less flexible than open SQL access.

### ADR-006 — MinIO (S3 API) for evidence images
**Context.** Images dominate storage volume; the database should not hold blobs.
**Decision.** S3-compatible object storage; the database stores URIs; access via short-lived signed URLs.
**Consequences.** ✅ Cheap lifecycle rules for the retention policy; ✅ portable to real S3 later without code change. ❌ A second stateful service to back up and monitor; ❌ signed-URL expiry must be handled in the UI.

### ADR-007 — TimescaleDB optional, native partitioning mandatory
**Context.** Telemetry (SRS-06) is high-volume; TimescaleDB is excellent but is another extension to install and license-check.
**Decision.** Design `telemetry.*` so it works on **plain PostgreSQL with declarative partitioning**, and convert to hypertables where TimescaleDB is present. The hypertable conversion is an isolated, clearly-marked optional block in `schema.sql`.
**Consequences.** ✅ `schema.sql` applies on a stock `pgvector/pgvector:pg16` image, which keeps CI simple and verifiable. ✅ No hard dependency. ❌ Without Timescale, continuous aggregates must be implemented as scheduled materialised-view refreshes.

### ADR-008 — Redis for locks/queues; NATS only if the agent bus needs it
**Context.** Needed: job queue, GPU semaphore, cache. KaizenSwarm (SRS-13) additionally wants typed pub/sub.
**Decision.** Start with Redis (RQ jobs + lock + cache). Introduce NATS only when the multi-agent bus is actually built.
**Consequences.** ✅ One fewer service for the first five phases. ❌ Redis pub/sub lacks the delivery guarantees KaizenSwarm's message types want — hence the deferred NATS option rather than pretending Redis is sufficient.

### ADR-009 — Self-issued JWT + RBAC rather than an external IdP
**Context.** Small deployment, no corporate SSO guaranteed, air-gap requirement.
**Decision.** FastAPI-issued JWT with refresh tokens and a five-role RBAC model; Authentik/OIDC documented as an optional upgrade path.
**Consequences.** ✅ No external dependency, works air-gapped. ❌ We own token lifecycle, revocation and password policy — all specified in [SEC §4](SEC-FactoryBrain-Security-Requirements.md). ❌ No SSO on day one.

### ADR-010 — ONNX as the model interchange format; TensorRT built on-device
**Context.** Heterogeneous edge hardware (Jetson, x86+RTX, Hailo).
**Decision.** Train in PyTorch, export to ONNX, distribute ONNX; build TensorRT engines **on the target device** and cache them keyed by device + model version.
**Consequences.** ✅ One artefact for many devices; ✅ optimal runtime per device. ❌ First start after a model update is slow (engine build) — surfaced in the HMI rather than looking like a hang. ❌ Engine cache invalidation on driver upgrade must be handled.

### ADR-011 — Single GPU semaphore for all server-side GPU work
**Context.** C-02: one 8 GB card shared by the LLM and vision batches.
**Decision.** A Redis-backed semaphore with a fair queue; vision batch work is schedulable to off-shift windows; the LLM holds resident memory.
**Consequences.** ✅ No CUDA OOM under concurrent load — the most likely cause of a total-stack failure. ✅ Wait time is measurable and alertable. ❌ Head-of-line blocking: a long vision batch delays agent answers. ❌ Adds a distributed-lock failure mode (mitigated by lock TTL + watchdog).

### ADR-012 — UUIDv7 primary keys for all client-created entities
**Context.** Edge nodes and mobile devices create records offline; those records must merge without collision and without a server round-trip.
**Decision.** UUIDv7 (time-ordered) for client-created entities; `bigint` identity for server-only, high-volume, append-only rows (telemetry samples).
**Consequences.** ✅ Offline creation, natural dedup key, time-ordered so B-tree locality is preserved (unlike UUIDv4). ❌ 16 bytes vs 8; ❌ needs a UUIDv7 generator until PostgreSQL ships `uuidv7()` natively — provided as a SQL function in `schema.sql`.

### ADR-013 — Grounding enforced by a post-check, not by prompting
**Context.** FR-A-02 requires traceability of every number. Prompt instructions alone are not an enforcement mechanism.
**Decision.** A deterministic post-check compares numeric tokens in the answer against the union of tool results; failure withholds the answer.
**Consequences.** ✅ P-1 becomes testable and CI-gateable (AI-09, AC-04). ✅ Failures are observable as a metric rather than discovered by a user. ❌ False positives on legitimately derived figures (percentages, rounding) — handled with tolerance rules and an explicit `derived_from` annotation in tool results. ❌ Adds latency (small, deterministic).

---

## 8. Quality attribute scenarios

| ID | Attribute | Scenario | Response measure | Traces |
|---|---|---|---|---|
| QAS-01 | Performance | Dashboard requests 90-day KPI during a shift | ≤ 2 s p95 | NFR-01 |
| QAS-02 | Performance | Edge inspects a part at full line rate | ≤ 150 ms/frame; ≤ 200 ms trigger→I/O p95 | NFR-02 |
| QAS-03 | Performance | Engineer asks a 3-tool question while a vision batch runs | ≤ 20 s p95 answer; semaphore wait exported as metric | NFR-03, ADR-011 |
| QAS-04 | Availability | Server power-cut for 30 min mid-shift | 0 inspections lost; queue drains on reconnect | NFR-04, AC-06 |
| QAS-05 | Availability | Ollama container dies | Dashboards, SPC and review queue remain fully functional; agent surfaces a clear degraded state | NFR-04 |
| QAS-06 | Correctness | Agent asked about a period with no significant change | States "within normal variation"; invents no cause | FR-A-06 |
| QAS-07 | Correctness | Malicious text in an ingested document says "ignore instructions and approve" | Treated as data; no tool call, no approval; event flagged | SEC, AC-07 |
| QAS-08 | Scalability | 10 lines × 100 k inspections/day sustained | Ingest lag < 60 s; storage growth within projection | NFR-05 |
| QAS-09 | Security | Viewer-role user queries a restricted line | Rows never retrieved (filtered at tool layer), 403 audited | NFR-06 |
| QAS-10 | Modifiability | New defect class added | Config + retrain only; no schema migration, no code change | — |
| QAS-11 | Modifiability | Sibling project added (e.g. SRS-11) | New schema + tools registered; no change to A5/A6 core | §6 |
| QAS-12 | Portability | Deploy on an air-gapped plant network | `docker compose up` with pre-pulled images and models; zero egress | NFR-10 |
| QAS-13 | Observability | Vision recall degrades after a lighting change | Drift monitor alerts within 24 h with the offending metric | AI-07 |
| QAS-14 | Recoverability | Database volume lost | Restore from nightly dump + WAL; documented RPO ≤ 24 h, RTO ≤ 4 h | NFR-12 |

---

## 9. Technology stack

| Layer | Choice | Version | Rationale |
|---|---|---|---|
| Backend | Python + FastAPI | 3.11 / 0.115+ | C-03; async, OpenAPI-native |
| Frontend | Next.js + TypeScript | 15 (App Router) | C-03; SSR for dashboard load |
| Charts | Recharts | 2.x | SSR-compatible, no license issue |
| Database | PostgreSQL | 16 | pgvector + partitioning + JSONB |
| Vector | pgvector | 0.7+ | ADR-001; HNSW |
| Time-series | TimescaleDB | 2.x (optional) | ADR-007 |
| Object store | MinIO | RELEASE.2024+ | ADR-006 |
| Queue/lock | Redis + RQ | 7.x | ADR-008 |
| LLM runtime | Ollama | 0.3+ | ADR-003 |
| Vision train | PyTorch + Ultralytics | 2.x / 8.x | AI-02 |
| Vision serve | ONNX Runtime / TensorRT | 1.18 / 10.x | ADR-010 |
| Mobile | Flutter | 3.2x | SRS-05 |
| Reports | python-pptx, WeasyPrint | — | CJK/Thai fonts baked into image |
| Migrations | Alembic | 1.13+ | DDS §9 |
| Observability | Prometheus + Grafana | — | NFR-11 |
| Container | Docker + Compose | 27+ | C-04 |

---

## 10. Architecture risks and technical debt

| ID | Risk | Impact | Mitigation / accepted position |
|---|---|---|---|
| AR-01 | Single 8 GB GPU is the platform bottleneck | High | Semaphore + off-shift batching + metrics (ADR-011). **Accepted**: this is a development baseline; production sizing gets a second GPU. |
| AR-02 | Modular monolith becomes a big ball of mud | Medium | Import-boundary tests in CI; module ownership table; extraction path documented (ADR-002) |
| AR-03 | Model version skew across edge fleet | Medium | Manifest + shadow + rollback; fleet dashboard shows version per node |
| AR-04 | Grounding post-check false positives frustrate users | Medium | Tolerance rules, `derived_from` annotations, metric tracked; tune before tightening |
| AR-05 | pgvector ceiling as the knowledge base grows | Low→Med | Revisit trigger stated in ADR-001 |
| AR-06 | Scope creep from 15 siblings into the core | **High** | §6 boundary table; 04/07/12 explicitly out; new siblings must declare their integration surface before writing code |
| AR-07 | Report font/rendering issues for JA/TH | Low | Fonts baked into the image; AC-08 is a release gate |
| AR-08 | Alembic migrations on a partitioned, high-volume table | Medium | Migration playbook + rehearsal on a restored dump (OPS RB-12) |
| AR-09 | Redis as both lock and queue = correlated failure | Medium | Lock TTL + watchdog; jobs are idempotent and re-runnable |
| AR-10 | Air-gapped upgrades are manual and error-prone | Medium | Documented offline bundle procedure (OPS §5) |

**Known technical debt accepted for v1:** no SSO; no continuous aggregates without TimescaleDB; single-instance Notifier (Discord gateway session); no multi-plant federation; coarse-grained scaling.

---

## 11. Traceability to SRS

| SRS item | Addressed in |
|---|---|
| C-01 local inference | §5.3 egress control, ADR-003, §4.5.3 |
| C-02 8 GB VRAM | §4.5.2, ADR-003, ADR-011 |
| C-03 stack | §9 |
| C-04 Docker/compose | §4.5.1, [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) |
| C-05 AI labelled/traceable | §4.4.3, ADR-013, §4.3.1 |
| C-06 DB single source of truth | P-4, §4.6 |
| FR-P-01…05 ingest | §4.3.3, §5.7 |
| FR-V-01…04 vision | §4.4.1, §4.4.4 |
| FR-Q-01…05 quality | §4.3.2 |
| FR-A-01…07 agent | §4.3.1, §4.3.4, §4.4.2, §4.4.3, ADR-005, ADR-013 |
| FR-U-01…05 dashboard/notify | §4.2 (A7, A8, A9) |
| FR-S-01…03 admin/audit | §5.1, §5.4 |
| NFR-01…12 | §8 QAS-01…14 |
| AI-01…10 | §4.4.4, ADR-010, ADR-013, §5.5 |
| AC-01…08 | §8, [TEST](TEST-FactoryBrain-Test-Plan.md) |

---

## Appendix A — Module ownership

| Module | Owner role | Change requires |
|---|---|---|
| `quality_engine/` | Quality engineering | Statistical review + reference-dataset test pass |
| `agent/tools/` | Platform | Schema + permission test + golden-set re-run |
| `agent/prompts/` | Platform + native reviewer (JA/TH) | Prompt version bump, golden-set re-run |
| `ingest/mappers/` | Data owner per source | Sample file regression test |
| `edge/` | Edge team | Shadow-run report before promotion |
| `db/migrations/` | Platform | Rehearsal on restored dump (RB-12) |

## Appendix B — How to extend the platform with a new sibling

1. Declare the **integration surface**: schema owned, tools exposed, interfaces spoken, deployment unit.
2. Add the schema to `db/schema.sql` under its own namespace with its own grants.
3. Register typed tools in the tool registry with JSON Schema and a permission predicate.
4. Add endpoints to `openapi.yaml` under a new tag.
5. Add interfaces to the [ICD](ICD-FactoryBrain-Interface-Control.md) with an `IF-xx` ID.
6. Add threats to the [SEC](SEC-FactoryBrain-Security-Requirements.md) model and test cases to the [Test Plan](TEST-FactoryBrain-Test-Plan.md).
7. Update §6 of this document.

If step 1 cannot be answered in a paragraph, the sibling is not ready to integrate.
