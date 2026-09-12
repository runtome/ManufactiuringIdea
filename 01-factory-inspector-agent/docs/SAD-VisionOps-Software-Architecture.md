# Software Architecture Document — VisionOps (AI Factory Inspector Agent)

| Field | Value |
|---|---|
| Document ID | SAD-01-VisionOps |
| Project code name | **VisionOps** |
| Version | 1.0 (Draft) |
| Date | 2026-09-11 |
| Author | Suphot N. |
| Status | Draft for review |
| Governs | [SRS-01-VisionOps](../SRS-AI-Factory-Inspector-Agent.md) |
| Platform relationship | Standalone-deployable; integrates with [FactoryBrain (SAD-00)](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) in platform mode |

**Structure basis:** ISO/IEC/IEEE 42010:2011 with C4-model views.

---

## 1. Introduction

### 1.1 Purpose
This document describes **how** VisionOps is built: a camera-to-narrative inspection system that detects and measures defects at line speed, keeps evidence for every judgement, and lets an LLM agent explain *what changed, why it probably changed, and what to do next* — without ever inventing a number.

### 1.2 Two ways to deploy it
VisionOps is designed to run **standalone** — one server, one `docker compose up`, cameras attached or replayed from a folder — because that is how it is demonstrated, developed and piloted on a single line.

It is also the canonical owner of the `vision` schema inside the FactoryBrain platform. In **platform mode** the standalone stack's database, object store, LLM runtime and authentication are replaced by the platform's, and VisionOps becomes a module. §9 describes exactly what changes. Every other section describes the standalone deployment and marks the parts that differ.

### 1.3 Audience
| Audience | Read |
|---|---|
| Implementer | §4 views, §5 cross-cutting, §7 ADRs |
| Reviewer | §3 drivers, §7 ADRs, §8 QAS, §10 risks |
| Integrator (EdgeGuard, QE-Agent, Genba Memory) | §6, §9, [ICD](ICD-VisionOps-Interface-Control.md) |
| Operator | §4.5, [OPS](OPS-VisionOps-Deployment-Operations.md) |

### 1.4 Related documents
| ID | Document |
|---|---|
| SRS-01 | [Requirements](../SRS-AI-Factory-Inspector-Agent.md) |
| DDS-01 | [Database Design](DDS-VisionOps-Database-Design.md) · [`schema.sql`](../db/schema.sql) |
| API-01 | [API Specification](../api/API-Specification.md) · [`openapi.yaml`](../api/openapi.yaml) |
| ICD-01 | [Interface Control](ICD-VisionOps-Interface-Control.md) |
| SEC-01 | [Security Requirements](SEC-VisionOps-Security-Requirements.md) |
| TEST-01 | [Test Plan](TEST-VisionOps-Test-Plan.md) |
| OPS-01 | [Deployment & Operations](OPS-VisionOps-Deployment-Operations.md) |
| SAD-00 | [Platform architecture](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) — inherited decisions are linked, not restated |
| SRS-03 | [EdgeGuard](../../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md) — the edge runtime VisionOps deploys onto |

---

## 2. Architecture principles

The four platform principles apply unchanged. What follows is what each one *means for an inspection system*, because that is where they bite.

| ID | Principle | What it means in VisionOps |
|---|---|---|
| **P-1** | The LLM never computes numbers | The narrative agent reads `inspection_stats`, `defect_pareto`, `station_breakdown`, `shift_correlation` — typed tools over SQL. It never sees raw rows. A deterministic post-check compares every number in the narrative with tool output and **withholds** the narrative on mismatch. "1,240 inspected, 37 defects, 2.98 %" is a query result, not a model output. |
| **P-2** | Offline-first | The verdict reaches the PLC and is persisted locally **before** any network call. Server down = nothing changes at the line. Cloud down = nothing changes anywhere. |
| **P-3** | Human-in-the-loop for consequences | The model proposes a verdict; below threshold it says REVIEW and a person decides. A model is never promoted to the line without a shadow run and a named approver. An override is never deleted. |
| **P-4** | The database is the single source of truth | Recipes, calibration, model versions, verdicts, overrides, narratives — all rows. The edge node's local store is a **buffer**, not a second truth: once synced, the server row is authoritative and the local copy is disposable. |

And the sizing rule: **the inference GPU is at the edge, the LLM GPU is on the server, and neither is shared with the other.** This is what makes ≤ 150 ms/frame and ≤ 20 s narratives simultaneously achievable on 8 GB cards (§4.5.2).

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-01 §2.4)
| ID | Constraint | Impact |
|---|---|---|
| C-01 | Fully on-premise inference and agent | Ollama in-stack; ONNX/TensorRT at the edge; no cloud on the critical path |
| C-02 | Sustain line takt (≥ 10 fps at 640 px) | Inference on edge GPU; rules engine in-process; evidence write is asynchronous to the verdict |
| C-03 | Every verdict reproducible: model version + threshold set + input hash | `inspection.model_id`, `recipe_id` (versioned), image SHA-256 stored per row |
| C-04 | Agent never invents numbers | Facts-builder + grounding post-check (ADR-013 inherited); inspection-domain tools only (ADR-V07) |

### 3.2 Quality attributes that shape the design
| Driver | Requirement | Shapes |
|---|---|---|
| Latency | NFR-01 ≤ 200 ms trigger→verdict p95; NFR-02 ≥ 10 insp/s | Edge inference, ROI cropping, TensorRT FP16, verdict before evidence |
| Availability | NFR-03 ≥ 24 h buffer if DB unreachable; NFR-04 ≥ 99 % | Store-and-forward with UUIDv7 dedup; PLC fail-safe |
| Correctness | AI-02 recall ≥ 0.98 on critical classes; AI-04 ±0.2 mm | Recall gate blocks promotion; calibration with gauge verification |
| Trust | FR-13–16 override + agreement stats | Overrides append-only; agreement report per class; REVIEW as first-class |
| Learnability | FR-15, AI-08 retraining reproducible | Dataset snapshots with immutable ids |
| Explainability | FR-17–21 | Narrative with sources; "no significant change" is a valid answer |

### 3.3 Not drivers
Multi-plant, cloud elasticity, sub-100 ms server APIs. VisionOps is a single-line-to-ten-line, on-premise system with a small team.

---

## 4. Views

### 4.1 Context view

```
                   ┌─────────────────────────────────────────┐
  Camera(s) ──────►│                                         │──► PLC verdict I/O (advisory)
  PLC trigger ────►│               VisionOps                 │──► Discord (narrative, alerts)
  Barcode/PLC tag ►│   inspect · measure · judge · explain   │──► PDF / PPTX reports
  (SKU, lot)       │                                         │──► FactoryBrain (platform mode)
  Ollama (local) ◄─┤                                         │
                   └─────────────────────────────────────────┘
```

| Actor | Interface | Notes |
|---|---|---|
| Camera | [IF-02](ICD-VisionOps-Interface-Control.md#if-02) | Terminates at the edge; no live video reaches the server |
| PLC | [IF-03](ICD-VisionOps-Interface-Control.md#if-03) | Verdict is advisory; PLC owns rejection; **absence of verdict = FAULT** |
| SKU / lot identity | [IF-15](ICD-VisionOps-Interface-Control.md#if-15) | Barcode scan or PLC tag; manual entry flagged |
| Light controller | [IF-18](ICD-VisionOps-Interface-Control.md#if-18) | Optional strobe sync |
| Ollama | [IF-09](ICD-VisionOps-Interface-Control.md#if-09) | Narrative only; the inspection path never touches an LLM |
| FactoryBrain | [IF-19](ICD-VisionOps-Interface-Control.md#if-19) | Platform mode only |

> The inspection path — trigger → verdict → I/O — involves **no LLM, no server, no network**. Everything the LLM does happens minutes to hours later, on data already judged and stored. This separation is the single most important property of the design: model quality problems and server outages cannot stop the line.

### 4.2 Container view

```
┌─── Edge node (per station) ─────────────────┐   ┌─── Server ──────────────────────────────┐
│ E1 capture      GenICam/USB3/CSI, trigger    │   │ api         FastAPI: inspections, recipes,│
│ E2 inference    ONNX Runtime / TensorRT      │   │             calibration, models, stats   │
│ E3 rules        recipe evaluation → verdict  │   │ worker      RQ: evidence, reports,        │
│ E4 local-store  SQLite + image cache         │──►│             retention, dataset export     │
│ E5 sync         store-and-forward (IF-01)    │   │ narrative   agent runtime + Ollama        │
│ E6 hmi          kiosk: verdict, counters     │   │ web         Next.js dashboard + review    │
│ GPU: inference only                          │   │ notifier    Discord                       │
└──────────────────────────────────────────────┘   │ postgres+pgvector · minio · redis · ollama│
                                                   │ GPU: LLM + optional batch                 │
   all-in-one demo: E1–E6 run on the server        └───────────────────────────────────────────┘
   under the `allinone` compose profile
```

| ID | Container | Tech | Responsibility |
|---|---|---|---|
| E1 | Capture | Python + GenTL/OpenCV | Trigger handling, frame grab, quality gate (blur/exposure), ROI, undistort |
| E2 | Inference | ONNX Runtime / TensorRT | Detection; optional segmentation, OCR, anomaly score |
| E3 | Rules | Python | Recipe evaluation → PASS/FAIL/REVIEW/NO_READ; measurement vs USL/LSL |
| E4 | Local store | SQLite + filesystem | Persist record + evidence **before** ack; disk policy |
| E5 | Sync | Python | Batched push, UUIDv7 dedup, config/model pull with ETag |
| E6 | HMI | Kiosk browser | Verdict, counters, connection state, FAULT |
| api | API | FastAPI | All endpoints in [`openapi.yaml`](../api/openapi.yaml) |
| worker | Workers | RQ | Evidence thumbnails, PASS sampling, retention, dataset export, drift metrics |
| narrative | Agent | Python + Ollama | Shift/daily narrative, `/ask`, grounding check |
| web | Web app | Next.js 15 | Dashboard, review queue, recipe editor, model admin |
| notifier | Notifier | discord.py | Scheduled narrative, threshold alerts, `/ask` bridge |

**Modular monolith** (ADR-002 inherited): `api`, `worker`, `narrative`, `notifier` are one Python image with different entrypoints. Edge containers E1–E6 are one image with a supervisor; on Jetson they are the [EdgeGuard](../../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md) runtime.

### 4.3 Component view — the four components that carry the product

#### 4.3.1 Rules Engine (E3)

```
inputs:  detections[] · measurements[] · ocr_text · quality_gate · recipe(version)
         │
         ▼
  ┌── quality gate ──┐   blur/exposure fail ──► NO_READ  (stop here; nothing judged)
  └──────────────────┘
         │ pass
         ▼
  ┌── rule evaluation in recipe order ─────────────────────────────────┐
  │  class_present   : FAIL if any listed class ≥ its threshold        │
  │  class_count     : FAIL if count(class) > max                      │
  │  class_area      : FAIL if area_mm² > max                          │
  │  measurement     : FAIL if value ∉ [LSL, USL]                      │
  │  ocr_match       : FAIL/REVIEW if pattern mismatch                 │
  │  anomaly_score   : REVIEW if score > threshold (never FAIL alone)  │
  └────────────────────────────────────────────────────────────────────┘
         │
         ▼
  ┌── resolution ──────────────────────────────────────────────────────┐
  │  any FAIL rule fired                        ──► FAIL               │
  │  no FAIL, any detection in [review_thr, rule_thr) ──► REVIEW      │
  │  no FAIL, anomaly flagged                   ──► REVIEW             │
  │  conflicting rules (configured)             ──► REVIEW             │
  │  otherwise                                  ──► PASS               │
  └────────────────────────────────────────────────────────────────────┘
```

Rules are **data** (ADR-V02): a versioned JSON document per SKU validated against a JSON Schema ([DDS §6.3](DDS-VisionOps-Database-Design.md)). No code is written per SKU. The evaluation is pure and deterministic — same inputs and recipe version always produce the same verdict, which is what makes C-03 (reproducibility) true.

**Anomaly score can only escalate to REVIEW, never to FAIL** (ADR-V05). It is a safety net for defect types the detector was not trained on, and a safety net that can reject product on its own is a liability.

#### 4.3.2 Measurement and calibration

```
pixel coordinates ──► undistort (camera intrinsics) ──► scale (px→mm) ──► value
                           │                              │
                   from calibration record         from calibration record
                   (per camera, versioned)         verified against a gauge
```

- A **calibration record** is created per camera with a calibration target, stores intrinsics + scale (or a homography for non-normal views), and carries a **gauge verification**: N repeat measurements of a known artefact with mean, σ and max error. A calibration whose verification exceeds tolerance is `invalid` and the rules engine refuses to emit measurements from it — `NO_READ` with reason `CALIBRATION_STALE` rather than a confident wrong number (AI-04).
- Changing camera, lens, working distance or lighting **invalidates** the calibration (ADR-V06). This is enforced by a hardware fingerprint (camera serial + lens id + mount id) on the record.

#### 4.3.3 Narrative Agent

```
   POST /agent/narrative {period, line}          POST /agent/ask {question}
                 │                                          │
                 ▼                                          ▼
   ┌── facts-builder ───────────────────┐    ┌── planner ───────────────────┐
   │ inspection_stats(period, line)     │    │ picks tools, ≤5 per turn     │
   │ defect_pareto(period, line)        │    │ scope predicate per user     │
   │ station_breakdown(period, line)    │    └──────────────┬───────────────┘
   │ shift_correlation(period, line)    │                   ▼
   │ similar_periods(signature)         │            typed tools (IF-16)
   │ → facts object (versioned JSON)    │◄──────────────────┘
   └────────────────┬───────────────────┘
                    ▼
   ┌── composer (Ollama) ───────────────┐   prose around facts; language per user;
   │ prompt template vN + glossary      │   causal language rules: "correlation", "possible"
   └────────────────┬───────────────────┘
                    ▼
   ┌── grounding post-check ────────────┐   every numeric token ∈ facts ∪ tool results
   │ pass → store narrative + sources   │   fail → withhold, outcome=grounding_failed
   └────────────────────────────────────┘
```

Tools are inspection-domain only (ADR-V07). There is no general SQL tool, no document search in standalone mode, and no write tool except `send_discord`, which creates a proposal. `similar_periods` finds past periods with a similar defect signature (class mix, station concentration) — it is how the narrative says "this resembles 2026-05-14" without a knowledge base.

The **significance guard** (FR-21): `inspection_stats` returns `significant: false` with the p-value when the change vs baseline is within variation, and the composer's template requires the phrase "within normal variation" and forbids proposing a cause in that case. This is tested, not hoped for (TEST TC-071).

#### 4.3.4 Retraining loop

```
verdict_override ──┐
confirmed REVIEW ──┼──► dataset_snapshot (immutable id, item list, label version)
sampled PASS ──────┘            │
                                ▼  export COCO / YOLO
                        training (outside VisionOps)
                                │
                                ▼  ONNX + manifest (sha256, metrics, class map)
                        model_registry: candidate
                                │
                        shadow run on live frames (≥ 200; no verdict effect)
                                │
                        disagreement report + critical-recall delta
                                │
                        human promotion (refused if critical recall < 0.98)
                                │
                        active · previous retained · one-command rollback
```

The snapshot id is stamped on the resulting model's `trained_from` so any model can be traced to the exact labelled set that produced it (AI-08).

### 4.4 Runtime views

#### 4.4.1 Trigger → verdict → I/O — the 200 ms budget

```
PLC        E1 capture    E2 inference   E3 rules    E4 store    PLC I/O
 │──trigger──►│               │             │           │           │
 │            │ grab ≤15 ms   │             │           │           │
 │            │ gate ≤5 ms    │             │           │           │
 │            │──frame───────►│             │           │           │
 │            │               │ infer ≤100  │           │           │
 │            │               │──dets──────►│           │           │
 │            │               │             │ eval ≤5   │           │
 │            │               │             │──record──►│           │
 │            │               │             │           │ write ≤10 │
 │            │               │             │◄──ack─────┤           │
 │◄───────────┼───────────────┼─────────────┼──verdict pulse────────┤   t ≤ 200 ms p95
 │            │               │             │           │           │
 │            │               │             │           │ evidence image → async
 │            │               │             │           │ sync queue    → async
```

The verdict pulse is emitted **after the local record is durable and before any image encoding or network I/O**. If E4 cannot write (disk fault), the node asserts FAULT — it does not emit a verdict it cannot account for.

#### 4.4.2 Store-and-forward
Identical to platform IF-01: at-least-once batches, server dedup on client UUIDv7, `207` per-record outcomes, local row deleted only after a non-`rejected` outcome. Images sync after records at lower priority. Buffer ≥ 24 h (NFR-03); EdgeGuard hardware extends this to 72 h.

#### 4.4.3 Recipe change propagation

```
engineer edits recipe ──► POST /recipes/{sku}/validate  (dry-run on last N inspections:
                                                          "would change 14 PASS → REVIEW")
                     ──► POST /recipes/{sku}             (new version, active_from)
                     ──► config ETag changes
edge polls GET /edge/config (If-None-Match) ──► 200 new bundle ──► atomic swap
in-flight inspections keep the version they started with; inspection.recipe_id records which
```

A recipe is never edited in place. The dry-run exists because the most common recipe error — a threshold that silently flips hundreds of parts — is invisible until the next shift without it.

#### 4.4.4 Unknown defect (anomaly fallback)
Detector finds nothing → anomaly model scores the frame → score above threshold → **REVIEW** with reason `ANOMALY` → inspector judges → if FAIL, the override carries a new or existing class label → feeds the next snapshot. This is how the class list grows without anyone guessing.

#### 4.4.5 Narrative generation
Scheduled (shift end, daily) or on demand. Facts-builder → composer → grounding → store `vision.narrative` with `facts_json`, `sources_json`, `grounding_json` → notifier posts to Discord with sources → dashboard renders with "show the numbers". A withheld narrative posts nothing and raises `narrative_grounding_failed`.

### 4.5 Deployment view

#### 4.5.1 Shapes

| Shape | Where E1–E6 run | GPU | Use |
|---|---|---|---|
| **All-in-one** | On the server, `allinone` profile; camera by USB/GigE or `folder`/`rtsp` replay | One card shared: inference + LLM through the GPU semaphore | Demo, development, single-line pilot |
| **Server + edge** | On Jetson / mini-PC per station | Edge card: inference only. Server card: LLM + batch | Production |
| **Platform mode** | As above, but server stack is FactoryBrain's | Platform's | Integrated deployment (§9) |

#### 4.5.2 GPU allocation
| Card | Consumer | Budget |
|---|---|---|
| Edge (Jetson Orin Nano 8 GB / RTX) | Detector FP16 ~1.2 GB, anomaly ~0.5 GB, OCR ~0.4 GB | Headroom for TensorRT workspace |
| Server (RTX 3060 Ti 8 GB) | Ollama ≤ 9 B Q4_K_M ~5.5 GB; batch drift/re-scoring ~1.5 GB | Serialised by the Redis semaphore (ADR-011 inherited) |

In all-in-one mode the two collapse onto one card and **inference has priority**: the semaphore grants the narrative agent the GPU only when no frame is in flight, and the narrative may be slow. The line never waits for a sentence.

#### 4.5.3 Zones
Inherited from SAD-00 §4.5.3: Z1 camera/PLC, Z2 edge, Z3 server, Z4 clients. Edge connections are outbound-only.

### 4.6 Data view
Owned by [DDS-01](DDS-VisionOps-Database-Design.md). Architecturally: `vision.*` is **byte-identical** to the platform's; VisionOps additionally owns `vision.station`, `vision.calibration`, `vision.anomaly_score`, `vision.dataset_snapshot/_item`, `vision.agreement_stat`, `vision.narrative`. `core` is the minimal master-data subset. `inspection` is partitioned monthly.

---

## 5. Cross-cutting concerns

| Concern | Position |
|---|---|
| **Authentication** | User JWT (15 min / 12 h refresh), edge mTLS or per-node key — inherited from SAD-00 §5.1 |
| **Authorisation** | Roles viewer < inspector < engineer < manager < admin; line scope as query predicate. VisionOps adds: recipe, calibration and model changes require `engineer`+ with a mandatory reason |
| **Calibration lifecycle** | Per camera, versioned, gauge-verified, hardware-fingerprinted; stale → measurements refused |
| **Model versioning** | `model_id` on every inspection; manifest sha256 verified on load; shadow before promote |
| **Evidence ordering** | Record first, image second; PASS images sampled (`PASS_IMAGE_SAMPLE_RATE`), FAIL/REVIEW always kept |
| **Clock** | NTP on every node; skew > 5 s → data-quality event; shift attribution depends on it |
| **Egress** | `backend` network `internal: true`; default-deny (SAD-00 §5.3) |
| **Observability** | Correlation id from trigger through sync; metrics in [OPS §7](OPS-VisionOps-Deployment-Operations.md) |
| **i18n** | Narratives and HMI in TH/JA/EN; defect names trilingual in `core.defect_type` |
| **Idempotency** | Client UUIDv7 on every inspection; `Idempotency-Key` on writes; batch `207` |

---

## 6. Integration map

| Sibling | Relationship | Interface |
|---|---|---|
| [03 EdgeGuard](../../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md) | **Supplies the edge runtime.** VisionOps E1–E6 *are* the EdgeGuard node when deployed on Jetson; VisionOps defines what they inspect and where results go | IF-01 |
| [09 QE-Agent](../../09-quality-engineer-agent/SRS-QE-Agent-Quality-Engineer.md) | Consumes `vision.inspection`/`measurement` for SPC and cases; VisionOps hands off "why" analysis to it in platform mode | shared schema, IF-19 |
| [15 Genba Memory](../../15-troubleshooting-memory/SRS-GenbaMemory-Troubleshooting-RAG.md) | Consumes approved narratives as precedent; provides `search_memory` to the narrative agent in platform mode | IF-19 |
| [10 Factory Copilot](../../10-factory-copilot/SRS-FactoryCopilot-Local-Multilingual-Assistant.md) | Front-end for `/ask` in platform mode; VisionOps tools are registered into the Copilot registry | IF-16 |
| [05 PocketQC](../../05-offline-mobile-inspector/SRS-PocketQC-Offline-Mobile-Inspector.md) | Mobile inspections land in the same `vision.inspection` with `source='mobile'` | IF-11 (platform) |
| [00 FactoryBrain](../../00-factorybrain-platform/) | Platform mode host | §9 |

---

## 7. Architecture Decision Records

Inherited unchanged from SAD-00 — one line each, follow the link for the argument:
**ADR-001** pgvector · **ADR-002** modular monolith · **ADR-003** Ollama local-first · **ADR-004** store-and-forward · **ADR-005** typed tools · **ADR-006** MinIO · **ADR-008** Redis · **ADR-009** self-issued JWT · **ADR-010** ONNX + on-device TensorRT · **ADR-011** GPU semaphore · **ADR-012** UUIDv7 · **ADR-013** grounding post-check.

VisionOps-specific:

### ADR-V01 — Inference at the edge, even in all-in-one mode
**Context.** NFR-01/02 need ≤ 150 ms and ≥ 10 fps; the server GPU is busy with the LLM.
**Decision.** The capture→verdict path always runs as the edge container set (E1–E6), talking to the API only through IF-01 — even when those containers are on the server. **Consequences.** ✅ One code path, one test suite, one failure model; the demo behaves like production. ✅ Server outage never touches the line. ❌ All-in-one shares one GPU (mitigated by inference priority in the semaphore).

### ADR-V02 — Recipes are data, not code
**Context.** Every SKU has different pass criteria; writing Python per SKU does not scale and cannot be edited by an engineer.
**Decision.** A recipe is a versioned JSON document validated against a JSON Schema, evaluated by a generic engine in fixed order. **Consequences.** ✅ Engineers own recipes; dry-run validation; reproducibility by `recipe_id`. ❌ Complex logic (e.g. "fail if A and B but not C") needs schema extension, not ad-hoc code — accepted; expressiveness grows deliberately.

### ADR-V03 — REVIEW is a first-class verdict, not a flag
**Context.** Confidence between "clearly fine" and "clearly bad" is the norm early in a deployment.
**Decision.** `REVIEW` is one of four verdict values, drives its own PLC signal, its own queue and its own metrics. **Consequences.** ✅ The line can route uncertain parts physically; inspector load is measurable; the model/human agreement report has a denominator. ❌ Requires a review lane or bin at the line.

### ADR-V04 — NO_READ is distinct from PASS
**Context.** A blurred or mis-positioned frame produces no detections. The lazy default is PASS.
**Decision.** Quality-gate failure produces `NO_READ`, excluded from the defect-rate denominator, with its own alert. **Consequences.** ✅ A dirty lens or failed strobe shows up as a NO_READ spike within minutes instead of as a suspiciously perfect shift. ❌ NO_READ parts need a re-present or a manual check.

### ADR-V05 — Anomaly detection escalates to REVIEW only
**Context.** Unknown defect types will appear; an anomaly model catches them but has no class semantics.
**Decision.** Anomaly score can raise a part to REVIEW, never to FAIL. **Consequences.** ✅ No product rejected on an unexplainable score; humans label the unknown, growing the class list. ❌ Novel defects reach a person, not the reject bin — acceptable, since the alternative is silent escape.

### ADR-V06 — Calibration is versioned, gauge-verified and hardware-fingerprinted
**Context.** A moved camera silently shifts every measurement; a "recalibrate" button gets pressed without verification.
**Decision.** Calibration records carry gauge-verification statistics and a hardware fingerprint; mismatch or out-of-tolerance verification marks it invalid and measurements are refused (`NO_READ`, reason `CALIBRATION_STALE`). **Consequences.** ✅ No confident wrong measurement. ❌ A camera swap stops measurement until recalibration — correct, and it is fast with the documented procedure.

### ADR-V07 — The narrative agent has inspection-domain tools only
**Context.** The platform Copilot has broad tools; a broad tool set is a broad attack surface and a broad fabrication surface.
**Decision.** Six read tools (`inspection_stats`, `defect_pareto`, `station_breakdown`, `shift_correlation`, `similar_periods`, `get_evidence`) and one gated write (`send_discord`). No SQL, no documents in standalone mode. **Consequences.** ✅ Every narrative claim maps to one of six queries; golden-set coverage is tractable. ❌ "Why" questions that need machine or material data are answered "outside my data" in standalone mode — and handed to QE-Agent in platform mode.

### ADR-V08 — Review threshold is per SKU, in the recipe
**Context.** A customer with zero tolerance for escapes and one that resents false alarms cannot share a threshold.
**Decision.** `review_threshold` lives in the recipe, versioned with it. **Consequences.** ✅ Tuning is auditable per SKU. ❌ More knobs; mitigated by the dry-run.

### ADR-V09 — PASS evidence is sampled; FAIL/REVIEW is always kept
**Context.** At 100 k inspections/day, images dominate storage by 100×.
**Decision.** PASS images stored at `PASS_IMAGE_SAMPLE_RATE` (default 2 %) then 30-day retention; FAIL/REVIEW kept 2 years. **Consequences.** ✅ Storage bounded to ~2–4 TB/year. ❌ A specific PASS part usually has no image; accepted — the record, model version and recipe are always kept, and the sample suffices for drift and audit.

### ADR-V10 — `vision.inspection` partitioned monthly and byte-identical to the platform
**Context.** VisionOps must run alone and also be the platform's `vision` schema.
**Decision.** The DDL for shared tables is maintained in one place (01) and copied verbatim into 00; a CI diff enforces identity. **Consequences.** ✅ No schema drift between standalone and platform. ❌ A change needs two commits — deliberate friction.

---

## 8. Quality attribute scenarios

| ID | Scenario | Measure | Traces |
|---|---|---|---|
| QAS-01 | Part triggers at full line rate | ≤ 150 ms infer, ≤ 200 ms trigger→I/O p95 | NFR-01, NFR-02 |
| QAS-02 | Server unreachable for 24 h mid-shift | 0 inspections lost; PLC signalling unaffected; queue drains | NFR-03, AC-04 |
| QAS-03 | Camera lens fogs | NO_READ spike alert within 5 min; no false PASS | ADR-V04 |
| QAS-04 | Camera physically bumped | Next measurement refused as CALIBRATION_STALE if fingerprint/gauge fails | ADR-V06, AI-04 |
| QAS-05 | Unknown defect type appears | REVIEW via anomaly; labelled; in next snapshot | ADR-V05, AI-06 |
| QAS-06 | Engineer lowers a threshold | Dry-run shows impact on last N; new version; edge picks up via ETag; in-flight unaffected | FR-08, §4.4.3 |
| QAS-07 | Narrative asked about a normal day | "Within normal variation"; no cause proposed | FR-21 |
| QAS-08 | Model emits an unsupported number | Narrative withheld; `grounding_failed` recorded | C-04, FR-19 |
| QAS-09 | New model has higher mAP, lower critical recall | Promotion refused | AI-02 |
| QAS-10 | Inspector overrides 100 parts in 5 min | Queue and keyboard flow support it; all attributed | AC-07 |
| QAS-11 | Deploy on a laptop with a USB camera | `docker compose --profile allinone up` works | NFR-08 |
| QAS-12 | Lighting changes gradually over weeks | Drift alert names brightness metric within 24 h | AI-07 |

---

## 9. Platform mode

What changes when VisionOps runs inside FactoryBrain.

| Concern | Standalone | Platform mode |
|---|---|---|
| Database | Own Postgres, `schema.sql` (core-min + vision + agent + ops + audit) | Platform Postgres; `vision.*` is the same DDL; `core.*` is the platform's full master data; VisionOps additions applied as a migration |
| Object store, Redis, Ollama | Own containers | Platform's |
| Auth | Own JWT issuer | Platform's; roles identical |
| API | `/api/v1/…` on its own host | Mounted under the platform API; endpoints that duplicate platform ones (`/auth/*`, `/edge/*`, `/admin/models*`) **collapse into** the platform's — see [API-01 §11](../api/API-Specification.md) |
| Narrative agent | Six tools | Same six, registered into the Copilot registry; gains `search_memory` (Genba Memory) and hands "why" to QE-Agent |
| Compose | `deploy/docker-compose.yml` | Only edge containers + `web` module are deployed; the rest is `00/deploy/docker-compose.yml` |
| Edge nodes | Speak IF-01 to VisionOps | Speak the same IF-01 to the platform — **no edge change** |

Edge nodes do not know which mode the server is in. That is the point of keeping IF-01 identical.

---

## 10. Risks and technical debt

| ID | Risk | Mitigation |
|---|---|---|
| AR-V01 | Too few labelled defect images (defects are rare) | Anomaly fallback → REVIEW → labelling loop; targeted harvesting; augmentation |
| AR-V02 | Lighting / pose drift degrades the model silently | Drift monitor (AI-07), NO_READ alerting, scheduled re-validation on hold-out |
| AR-V03 | Takt faster than the model | ROI-only inference, smaller backbone, TensorRT INT8 with recall gate, second node |
| AR-V04 | Operators distrust or ignore REVIEW | Queue ergonomics (≤ 5 min / 100), visible agreement stats, threshold tuning with dry-run |
| AR-V05 | Narrative over-claims causality | Template rules, significance guard, `must_not_claim` golden checks |
| AR-V06 | All-in-one GPU contention makes narratives slow | Inference priority; documented; not a line risk |
| AR-V07 | `vision.*` drifts from platform | CI byte-identity diff (ADR-V10) |
| AR-V08 | Recipe expressiveness hits a wall | Schema versioning; extension by design review, not ad-hoc code |

**Accepted debt for v1:** no segmentation-based area rules on the edge by default (server batch only); OCR limited to printed text; no multi-camera fusion per part; no automatic threshold optimisation.

---

## 11. Traceability to SRS-01

| SRS item | Addressed in |
|---|---|
| C-01 on-premise | §4.1, ADR-003, §5 egress |
| C-02 takt | §4.4.1, ADR-V01, §4.5.2 |
| C-03 reproducibility | §4.3.1, §4.6, ADR-V02, ADR-V06 |
| C-04 no invented numbers | §4.3.3, ADR-013, ADR-V07 |
| FR-01…04 acquisition | E1, §4.3.1 quality gate, ADR-V04 |
| FR-05…12 inspection | E2, E3, §4.3.1–2, §4.4.1 |
| FR-13…16 review & learning | §4.3.4, ADR-V03, §5 |
| FR-17…22 agent | §4.3.3, §4.4.5, ADR-V07 |
| FR-23…25 delivery | `web`, `notifier`, `worker` |
| AI-01…08 | §4.3.4, §4.5.2, ADR-V05, ADR-V06, ADR-010 |
| NFR-01…09 | §8 QAS |
| AC-01…07 | §8, [TEST-01](TEST-VisionOps-Test-Plan.md) |

---

## Appendix A — Module ownership

| Module | Owner | Change requires |
|---|---|---|
| `edge/rules/` | Quality + platform | Recipe-schema test matrix pass |
| `edge/calibration/` | Vision | Gauge repeatability test |
| `narrative/tools/` | Platform | Golden set re-run |
| `narrative/prompts/` | Platform + native reviewer | Version bump + golden set |
| `db/schema.sql` (`vision.*`) | VisionOps | Byte-identity diff against 00 |
