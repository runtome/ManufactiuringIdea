# Software Architecture Document — MoldMind (AI Vision + Agent for Injection Molding)

| Field | Value |
|---|---|
| Document ID | SAD-11-MoldMind |
| Version | 1.0 (Draft) |
| Date | 2026-09-18 |
| Author | Suphot N. |
| Status | Draft for review |
| Source requirements | [SRS-11-MoldMind](../SRS-MoldMind-Injection-Molding-AI.md) v1.0 |
| Related | [DDS-11](DDS-MoldMind-Database-Design.md) · [API-11](../api/API-Specification.md) · [ICD-11](ICD-MoldMind-Interface-Control.md) · [SEC-11](SEC-MoldMind-Security-Requirements.md) · [TEST-11](TEST-MoldMind-Test-Plan.md) · [OPS-11](OPS-MoldMind-Deployment-Operations.md) · [UM-11](UM-MoldMind-User-Admin-Guide.md) · platform: [SAD-00](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) §13, ADR-005, ADR-007, ADR-013 · sibling: [SAD-09](../../09-quality-engineer-agent/docs/SAD-QEAgent-Software-Architecture.md) |

---

## 1. Introduction

### 1.1 Purpose
This document is the architecture of MoldMind: a process-specific system for injection moulding that sees a defect on a part, knows which shot and which cavity produced it, knows the machine parameters of that shot, knows what changed on the timeline, and walks a technician through the known causes in the order a good process engineer would — checks before changes, changes only inside the documented process window — then proves whether the fix worked and remembers it.

### 1.2 What makes this project different from its siblings
VisionOps (01) is process-agnostic; QE-Agent (09) is statistics-first and domain-neutral. MoldMind is built around **domain knowledge that is data**: the troubleshooting matrix (defect → cause → check → action, with the parameter directions each cause implies) lives in a versioned, sourced, approved knowledge base (C-03, AI-08), and the cause ranking is a **transparent additive score** over KB priors, observed parameter deltas, timeline coincidence and past-case outcomes (AI-05). The language model asks questions and explains; it never ranks, never computes and never proposes a magnitude (AI-06).

Three constraints shape everything: the moulding machine is **read-only** (C-01, NFR-06); every defect record is **joinable to exactly one shot and, where possible, one cavity** (C-02) — without that join no parameter analysis is honest; and any suggested parameter change is **advisory, ordered after checks, and blocked outside the mould/material window** (C-04, C-05, AI-09, AC-05).

### 1.3 Two ways to deploy it
- **Platform mode** (intended): a FactoryBrain module of medium coupling (SAD-00 §13) that owns `quality.mould`, `quality.shot`, `quality.shot_part`, `quality.timeline_event` in the platform's quality section, receives machine data through IF-05 (OPC-UA / Euromap 77), hands the 8D to QE-Agent (FR-26), publishes its analysis tools to Copilot (IF-16) and stores images in the platform object store.
- **Standalone mode**: the same containers with their own PostgreSQL (pgvector; TimescaleDB optional per ADR-007), Redis, MinIO and Ollama; the platform's `core`, `vision`, `quality`, `knowledge` and `audit` sections extracted byte-identically into `db/schema.sql`; the 8D handoff creates a QE-style draft locally. §9 lists what changes.

### 1.4 Related documents
DDS-11 (schema; joinability, window, KB-approval, transparent-score and effectiveness guards; twins of the analytics; the seed reproducing AC-02…AC-09 and Appendix A), API-11 (shot, analysis, RCA, knowledge and handoff contracts), ICD-11 (IF-05 node maps; IF-58 alignment & attribution; IF-59 KB format; IF-60 scoring; IF-61 suggestions & windows; IF-62 QE handoff), SEC-11, TEST-11, OPS-11, UM-11.

---

## 2. Architecture principles

| # | Principle | Consequence in MoldMind |
|---|---|---|
| **P-1** | **The LLM never computes** | Cause scores come from `cause_score()` over stored components; parameter deltas, cavity rates, drift and effectiveness are code; the model receives a facts object (IF-60/ICD-11) and writes questions and explanations only — AI-05, AI-06 |
| **P-2** | **Offline-first; degrade without the model** | The gateway buffers ≥ 24 h of shots (NFR-05, AC-09); vision, alignment, analysis and the cavity/drift/timeline views work without Ollama; the dialogue falls back to the KB's scripted question list — the ranking is unchanged |
| **P-3** | **Advisory only — the technician acts** | No write path to the machine (C-01); suggestions carry direction, magnitude range, window and side effects (FR-23); checks precede changes structurally (C-04); out-of-window suggestions are blocked and logged (C-05, AI-09, AC-05) |
| **P-4** | **The database is the source of truth** | Joinability, alignment tolerance, KB approval, score transparency, advice ordering, window enforcement, effectiveness and transients are triggers (DDS-11 DD-M01…M09), not conventions |
| **P-5** | **Domain knowledge is reviewable data** | KB entries in YAML/DB with a mandatory source and a process-engineer approval; versions append-only; verified case outcomes are written back as evidence (C-03, AI-08, NFR-08, FR-25) |
| **P-6** | **Every defect is one shot and one cavity** | `shot_defect → shot_part → shot`; cavity ≤ mould cavities; image aligned within tolerance; attribution method recorded (C-02, FR-03, FR-08, AC-02) |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-11 §2.4)
| ID | Constraint | Architectural response |
|---|---|---|
| C-01 | Read-only machine access | IF-05 read-only account enforced at the OPC-UA server; `trg_machine_readonly`; no write tool (ADR-M01) |
| C-02 | Defect joinable to one shot / one cavity | `trg_defect_joinable`, `trg_alignment_tolerance`, attribution methods (ADR-M02) |
| C-03 | Domain rules in a reviewable KB, not prompts | IF-59 YAML schema, `kb_version` with approval; prompts carry rules of conduct only (ADR-M03) |
| C-04 | Check-before-change ordering; suggestions within windows | `trg_advice_check_first`, `trg_suggestion_window` (ADR-M06, ADR-M07) |
| C-05 | Never exceed documented limits | `parameter_window`, block + audit (ADR-M07) |

### 3.2 Quality attributes
| Attribute | Requirement | Design response |
|---|---|---|
| Latency | NFR-01 shot-to-record ≤ 2 s; NFR-02 inference ≤ 150 ms/part; NFR-03 cavity analysis 30 d ≤ 3 s; NFR-04 dialogue turn ≤ 15 s | gateway publishes on cycle completion; edge inference per family head; monthly shot partitions + cavity aggregates; scoring is SQL, the model call is bounded |
| Availability | NFR-05 buffer ≥ 24 h | gateway store-and-forward with batch reconciliation (AC-09) |
| Correctness | AI-02 mAP ≥ 0.80, recall ≥ 0.95 on critical classes; AI-07 golden ≥ 70 %; AC-02 attribution ≥ 98 % | evaluation runs as release gates (ADR-M10); attribution method recorded and measured |
| Safety | C-04, C-05, AI-09 | structural ordering and window checks in the database |
| Environment | NFR-07 press environment | rated enclosure, vibration isolation, thermal budget (OPS-11 §2) |
| Localisation | FR-27, NFR-09, AC-08 | glossary with forbidden variants; term check on dialogue outputs |

### 3.3 Not drivers
Closed-loop control, mould design/flow simulation, non-injection processes (SRS §1.2).

---

## 4. Views

### 4.1 Context view
```
 Injection press (controller) ──IF-05 OPC-UA / Euromap 77 (read-only)──▶ gateway-opcua ──▶ shots + parameter changes
 Camera at part exit / robot pick ──IF-02──▶ vision-infer (per-family heads, anomaly, ΔE) ──▶ aligner (shot id · ts tolerance · cavity by OCR/robot/sequence)
 Dryer / material records ──▶ shot context (lot, regrind %, dryer temp/hours, ambient)
                                       ▼
                     ┌──────────── Shot database (quality.shot / shot_part / moldmind.*) ────────────┐
                     │ analyser: cavity rates · good-vs-bad deltas · drift vs setup sheet · timeline │
                     │           · startup transients · scrap cost · golden-run diff                │
                     └──────────────────────────────┬───────────────────────────────────────────────┘
                                                    ▼
                     knowledge base (IF-59, versioned, approved) ──▶ rca-agent: cause_score() → guided dialogue
                     (Ollama phrases questions/explanations only) → checks before changes → suggestions within windows
                     → technician acts → effectiveness test → KB write-back → 8D via QE-Agent (IF-62)
 Users: molding technician · process engineer · quality engineer · mould maintenance · production manager
 Siblings: QE-Agent (8D, cases) · Genba Memory (past cases) · Copilot (tools) · MachineSense (alarms on the timeline)
```

### 4.2 Container view
| Container | Responsibility | Tech | Talks to |
|---|---|---|---|
| `gateway-opcua` | OPC-UA/Euromap 77 client: node map, per-shot parameters on cycle completion, parameter-change detection, store-and-forward buffer, batch reconciliation | Python (asyncua) | press (read-only), Postgres (`gateway_rw`), Redis |
| `gateway-mqtt` | alternative feed (Euromap 63 files / MQTT gateway) — profile | Python | broker, Postgres |
| `vision-infer` | detection per mould family (shared backbone, family heads), anomaly model, ΔE colourimetry with the reference chart, low-confidence routing | PyTorch/ONNX + GPU | camera, MinIO, Postgres (`vision_rw`) |
| `aligner` | image ↔ shot alignment within tolerance; cavity attribution (OCR marking → robot position → sequence); `shot_part` rows | Python | Postgres, Redis |
| `analyser` | cavity rates and flags, good-vs-bad deltas (Welch t, Cohen's d), drift slopes, timeline correlation, startup transients, scrap cost, golden-run diff | Python (numpy/scipy) | Postgres |
| `kb-service` | KB import from YAML (IF-59), versions, approval, scoring config, glossary | Python | Postgres (`kb_rw`) |
| `rca-agent` | sessions: `cause_score()`, question selection, ranking updates per answer, advice (checks then actions), suggestions with window validation, effectiveness tests, KB write-back, 8D handoff | Python + Ollama | Postgres, Ollama, QE-Agent (IF-62) |
| `api` / `web` | REST (SRS §4.1 + platform paths), technician/engineer UI in TH/JA/EN, review queue, golden-run view | FastAPI / Next.js | all |
| `scheduler` | nightly evaluation, retention, partition creation, KB stale-check | Python | Postgres, MinIO |
| `postgres` | DDS-11 (pgvector; TimescaleDB optional) | PostgreSQL 16 | |
| `redis` | queues, alignment buffer, gateway lag | Redis 7 | |
| `minio` | part images, ΔE frames, eval artefacts | MinIO | |
| `ollama` | ≤ 9 B instruct model, temperature ≤ 0.3 — dialogue and explanation only | Ollama | GPU (shared with vision on the baseline) |

### 4.3 Component view

#### 4.3.1 Shot acquisition (FR-01…FR-05 — IF-05)
The node map (versioned YAML, validated at startup) lists every FR-01 parameter: injection pressure/speed profile, holding pressure/time, back pressure, screw RPM, cushion, melt temperature per zone, mould temperature fixed/moving, cooling time, cycle time, clamping force. A shot row is written on cycle completion with `params_json`, `melt_temp_json`, `mould_temp_json`, `cushion_mm`, `cycle_time_s` (platform `quality.shot`) and its context in `moldmind.shot_ext` (cavity count, material lot, regrind %, dryer temperature/hours, ambient, operator group, shift — FR-02). Setpoint changes seen on the controller become `parameter_change` rows (who from the controller's user field when available, when, old, new) and, by trigger, `timeline_event(kind = parameter_edit)` (FR-04). Data-quality flags (missing zone temperature, stuck value, clock skew) are set per shot (FR-05). During a connection loss the gateway buffers locally (≥ 24 h) and reconciles by `shot_id` on reconnect (AC-09).

#### 4.3.2 Vision and attribution (FR-06…FR-11 — IF-02, IF-58)
Ten classes (short shot, flash, sink mark, burn mark, weld line, silver streak, warpage, contamination/black spot, colour deviation, scratch); region mapping (gate area, far end, rib, boss, parting line — FR-07); per-family heads (AI-01); subtle classes (sink mark, weld line) with dedicated lighting (AI-03); ΔE against a reference chart in frame — measured, not inferred (FR-09, AI-04); anomaly score for out-of-distribution appearance (FR-10); confidence below the class threshold → review queue with a human verdict stored in `vision.verdict_override` (FR-11). The aligner joins an image to a shot within the configured tolerance (default 1.5 s) and assigns the cavity by OCR of the part marking, else robot position, else fixed sequence; the method is stored (FR-03, FR-08, AC-02).

#### 4.3.3 Analysis (FR-12…FR-18)
- **Cavity analysis**: rate per cavity vs the mould's other cavities (two-proportion test, α 0.01, n ≥ 200) → `cavity_flag` (FR-12).
- **Parameter delta**: for a defect class and window, good vs defective shots per parameter: means, Welch t, Cohen's d, CI (FR-13); the defect ↔ parameter direction is compared with the KB's `typical_params` (feeds the score's delta component).
- **Drift**: least-squares slope of cushion/cycle time/etc. vs shot index against the setup sheet's target and tolerance (FR-14).
- **Timeline**: lot change, mould change, purge, maintenance, parameter edit, shift change, startup — distance from the defect onset (FR-15).
- **Startup transients**: shots within N (default 20) of a `startup_event` are `startup_transient` and excluded from cavity/trend flags (FR-16, AC-06).
- **Scrap cost** per class per period from `scrap_cost_config` (FR-17).
- **Golden run**: current parameters vs the approved setup-sheet version with deviations highlighted (FR-18).

#### 4.3.4 Knowledge base (FR-19, FR-25, C-03, AI-08, NFR-08 — IF-59)
`kb_defect` × `kb_cause` (prior weight, typical parameter directions, checks, actions with direction/range/window ref/side effects, source) in `kb_version`s: `draft` → `approved` by a process engineer (author ≠ approver) → immutable. Only approved versions are used for ranking. Verified cause–action–outcome triplets are appended as `kb_case_evidence` and raise the cause's case component (FR-25).

#### 4.3.5 RCA agent (FR-20…FR-24, FR-26, AI-05, AI-06, AI-09 — IF-60, IF-61, IF-62)
1. **Scoring** (code): for each KB cause of the defect, `score = w_prior·prior + w_delta·delta + w_timeline·timeline + w_case·case` with the active `scoring_config` (default 0.35/0.30/0.20/0.15); components ∈ [0,1] are stored per cause (`rca_cause_score`) so the ranking is inspectable.
2. **Dialogue**: the agent picks the question with the highest expected ranking change from the KB's check list (e.g. "Was the material dried per spec?", 「材料ロットは変更しましたか？」); the model phrases it in the user's language from a facts object; each answer updates the components and the ranking (`rca_turn`).
3. **Advice**: checks first (cheapest/most reversible), then parameter changes, each with direction, magnitude range, the window reference and expected side effects (`rca_advice`); the database refuses an action ordered before a check (C-04).
4. **Suggestions**: a magnitude is validated against `parameter_window` for the mould × material; outside → `blocked = true` + audit, never presented as allowed (AC-05).
5. **Outcome**: the technician records what was applied; the agent compares defect rates before/after with a two-proportion test; `effective` only at p < 0.05 with an improvement (FR-24, AC-07); an effective outcome with a verified cause is written back to the KB (FR-25).
6. **8D**: `POST …/handoff-8d` creates the QE-Agent case and draft (FR-26) — MoldMind never writes an 8D itself.

### 4.4 Runtime views

#### 4.4.1 AC-03 end to end — deliberate hold-pressure reduction (seed)
```
2026-09-09 10:40  controller setpoint HoldingPressure 650 → 560 bar (technician somsak)
                  gateway → parameter_change → trg → timeline_event(parameter_edit)
10:40–12:00       100 cycles × 4 cavities: sink marks 36/400 = 9.0 % (before: 6/400 = 1.5 %); cushion 4.5 → 2.8 mm
                  aligner: cavity by OCR (C1…C4); vision: sink_mark region=boss/rib; 1 weld line at 0.58 → review
12:05  analyser   two-proportion 36/400 vs 6/400: z 4.53, p < 0.001 → trend; cavity 3: 20/100 vs 16/300 → flagged
                  parameter delta (defective vs good): holding_pressure 560 vs 650, d ≫ 1; cushion 2.8 vs 4.5, d ≫ 1
                  timeline: parameter_edit 10:40 within the onset window; no lot change; no maintenance
12:06  rca-agent  session for sink_mark on MLD-0417: KB v1 priors × delta × timeline × case #178
                  rank 1 insufficient_holding_pressure 0.74 · rank 2 holding_time_too_short 0.29 · rank 3 melt_temperature_too_high 0.20 …
       dialogue   Q1 "Was the material dried per spec?" → yes  · Q2 「材料ロットは変更しましたか？」 → no · Q3 "Was mould maintenance performed?" → no
                  ranking after each answer stored; rank 1 unchanged (AC-03: top-2 ✓)
       advice     check 1 cushion vs setup sheet (target 3–6 mm) · check 2 holding-pressure trace vs golden run
                  action 3 holding_pressure UP +5..+15 % → suggested 616 bar (window 500–750 ✓) side effects: flash, internal stress
       AC-05      a second suggestion to 800 bar → blocked = true, audit row, never shown as allowed
13:00  technician applies 616 bar (recorded); 13:00–14:30 after window: 7/400 = 1.75 %
14:35  outcome    36/400 vs 7/400: z 4.44, p < 0.001, improvement → effective = true (AC-07)
                  trg → kb_case_evidence (sink_mark · insufficient_holding_pressure · +10 % holding pressure · effective)
14:40  handoff    POST /rca/sessions/{id}/handoff-8d → QE-Agent case + eight_d draft (ai_generated, unapproved) (FR-26)
```

#### 4.4.2 AC-06 — startup after a 2 h stop
`startup_event` at 2026-09-08 09:00; shots 1–20 after it carry short shots; `startup_transient = true`; cavity and trend flags ignore them; the trend view shows them greyed with "startup transient (20 shots)".

#### 4.4.3 AC-09 — 1 h OPC-UA loss
Session lost 2026-09-08 15:00–16:00; the gateway stores 128 shots locally (`gateway_batch`), reconnects with backoff, uploads the batch; reconciliation by `shot_id` → 128 inserted, 0 duplicates, ordered by ts; `v_gateway_lag` shows the gap closed.

#### 4.4.4 FR-11 — low-confidence detection
Weld line at 0.58 (threshold 0.70) → `REVIEW`; the inspector opens the review queue, sets `FAIL` with reason; the human verdict is stored in `vision.verdict_override`; the shot part's verdict is updated; the model's original stays.

#### 4.4.5 FR-09 — colour deviation
Reference chart Lab (62.1, −4.3, 12.8) per SKU; sample (60.9, −3.9, 14.1) → ΔE76 1.81 (ok, threshold 2.0); sample (59.8, −3.1, 15.0) → 3.21 → `colour_deviation` defect with `delta_e` stored.

### 4.5 Deployment view
Press side: rated enclosure (IP65, ≤ 55 °C internal with forced air, vibration-isolated mount, oil-mist-resistant optics), camera at the part-exit/robot station, lighting rig per class, edge box running `vision-infer` and the camera capture; gateway box (or the same edge box) on the machine network with the OPC-UA client certificate. Server side: the compose stack. Networks: `machine` (gateways ↔ press only), `internal` (no egress), `frontend`, `egress` (notifications only). OPS-11 §2–§3.

### 4.6 Data view
Platform-owned (byte-identical): `quality.mould/shot/shot_part/timeline_event` (MoldMind's), `quality.case/hypothesis/artifact` (QE's, for the handoff), `vision.inspection/detection/verdict_override/model_registry`, `core.machine/material_lot/defect_type/app_user/user_line_scope`, `knowledge.case_record/glossary_term`, `audit.*`. MoldMind extension `moldmind.*`: `machine_connection`, `node_map_version`, `gateway_batch`, `shot_ext`, `image_alignment`, `shot_defect`, `colour_reference`, `parameter_window`, `setup_sheet_version`, `parameter_change`, `startup_event`, `kb_defect`, `kb_version`, `kb_cause`, `kb_case_evidence`, `scoring_config`, `rca_session`, `rca_cause_score`, `rca_turn`, `rca_advice`, `parameter_suggestion`, `action_outcome`, `cavity_flag`, `scrap_cost_config`, `vision_eval_run`, `golden_run`, `prompt_template`, `migration`. DDS-11.

---

## 5. Cross-cutting concerns
| Concern | Design |
|---|---|
| Machine safety | read-only OPC-UA account enforced at the server; the client has no write method; node maps refuse write access; audited (C-01, NFR-06) |
| Auth & roles | platform JWT; technician = inspector, process/quality engineer = engineer, mould maintenance = inspector, manager, admin; KB approval needs engineer and author ≠ approver |
| Observability | `/metrics` (IF-14): gateway lag, buffer depth, alignment misses, attribution method mix, review rate, inference latency, cavity flags, blocked suggestions, RCA sessions/outcomes, KB stale entries, eval gates |
| Localisation | TH/JA/EN UI and outputs; moulding glossary with forbidden variants (ヒケ not 引け跡, バリ, ショートショット); term check on dialogue text (FR-27, AC-08) |
| Versioning | node maps, setup sheets, KB, scoring config, prompts, models (per family) — all with versions and checksums; a change to KB/scoring/prompts/model re-runs the golden set |

## 6. The convincing wrong cause — the design's own risk
A ranking can be right about the parameter and wrong about the cause (holding pressure fell because the machine's hydraulic pump degraded — a maintenance cause, not a setpoint one). MoldMind's answers: scores are components you can read, not a single number; the timeline component shows *what changed* (a setpoint edit vs nothing); checks precede changes so the technician looks before turning a dial; effectiveness is measured, not assumed; and unverified sessions never become KB evidence. Residual: RR-M01.

---

## 7. Architecture Decision Records

### ADR-M01 — OPC-UA / Euromap 77 read-only with versioned node maps
**Context.** FR-01, C-01, NFR-06, AC-09. **Decision.** OPC-UA client with a read-only account enforced on the server, node maps per machine validated at startup, store-and-forward buffer ≥ 24 h; Euromap 63 file or MQTT gateway as alternatives with the same shot contract. **Consequences.** ✅ no write path exists; ✅ buffered outages reconcile by shot id. ❌ node IDs change with firmware — versioned maps.

### ADR-M02 — Shot id as the join key; timestamp tolerance and multi-method cavity attribution
**Context.** C-02, FR-03, FR-08, AC-02. **Decision.** Every part image is aligned to one shot (by shot id from the robot when available, else timestamp within tolerance) and one cavity (OCR marking → robot position → fixed sequence); the method is stored and measured. **Consequences.** ✅ every defect analysis is on real joins. ❌ unaligned images are kept but excluded from analysis.

### ADR-M03 — Knowledge base as versioned YAML/DB with mandatory sources and approval
**Context.** C-03, FR-19, AI-08, NFR-08. **Decision.** IF-59 schema; import into `kb_*`; versions `draft → approved` by a process engineer; only approved versions rank; prompts contain no domain rules. **Consequences.** ✅ reviewable, diffable, citable. ❌ authoring discipline required.

### ADR-M04 — Transparent additive scoring with configurable weights
**Context.** AI-05, FR-20. **Decision.** `score = Σ w_i · c_i` over prior, delta, timeline, case; components normalised to [0,1] and stored; weights sum to 1; the database recomputes and refuses a mismatch. **Consequences.** ✅ every ranking is explainable line by line. ❌ no learned interactions — accepted.

### ADR-M05 — The model phrases; the facts object is its only input
**Context.** AI-06, FR-21, FR-27. **Decision.** Questions and explanations are generated from a schema-validated facts object (ranked causes with components, evidence, windows, glossary); temperature ≤ 0.3; a scripted fallback exists. **Consequences.** ✅ ranking independent of the model. ❌ dialogue quality depends on the KB's question lists.

### ADR-M06 — Check-before-change is structural
**Context.** C-04, FR-22. **Decision.** Advice rows are typed `check`/`action` with ordinals; the database refuses an action ordered before any check of the session. **Consequences.** ✅ the safest step is always first. ❌ trivially checkable causes still get a check row.

### ADR-M07 — Process-window validation blocks suggestions
**Context.** C-05, AI-09, FR-23, AC-05. **Decision.** `parameter_window` per mould × material × parameter; a suggestion outside is stored `blocked` with an audit row and never shown as allowed; magnitudes are ranges relative to the current value. **Consequences.** ✅ AC-05 by construction. ❌ windows must be maintained.

### ADR-M08 — Effectiveness by significance test; write-back only when verified
**Context.** FR-24, FR-25, AC-07. **Decision.** Before/after two-proportion test at α 0.05 with an improvement; only then `effective`, and only then KB evidence. **Consequences.** ✅ the KB learns from proof. ❌ small samples stay `inconclusive`.

### ADR-M09 — Startup transients are excluded from trend logic
**Context.** FR-16, AC-06. **Decision.** N shots after a startup event are flagged and excluded from cavity/trend flags; shown, not hidden. **Consequences.** ✅ no false alerts after restarts. ❌ a real problem in the first N shots is seen one window later.

### ADR-M10 — 8D delegated to QE-Agent; evaluation gates for models and KB
**Context.** FR-26, AI-02, AI-07, AC-01, AC-04. **Decision.** Handoff creates the QE case and draft; vision runs and golden runs are release gates with computed pass flags. **Consequences.** ✅ one 8D engine; ✅ regressions caught. ❌ QE-Agent required for the 8D in platform mode.

---

## 8. Quality attribute scenarios
| ID | Attribute | Scenario | Response measure | Traces |
|---|---|---|---|---|
| QAS-01 | Correctness | Hold pressure lowered 650 → 560 | delta reported; "insufficient holding pressure" in top-2 | AC-03, TC-050 |
| QAS-02 | Safety | Suggestion of 800 bar (window 500–750) | blocked, logged, never shown allowed | AC-05, TC-055 |
| QAS-03 | Correctness | Corrective action applied | effectiveness confirmed by the test | AC-07, TC-057 |
| QAS-04 | Honesty | Restart after a 2 h stop | transient, no trend alert | AC-06, TC-045 |
| QAS-05 | Availability | OPC-UA lost for 1 h | shots buffered and reconciled | AC-09, TC-014 |
| QAS-06 | Attribution | 500-part trial | cavity correct ≥ 98 % | AC-02, TC-024 |
| QAS-07 | Detection | Hold-out set | mAP ≥ 0.80; recall ≥ 0.95 on critical classes | AC-01, TC-020 |
| QAS-08 | Knowledge | Golden set of 15 incidents | true cause in top-3 ≥ 70 % | AC-04, TC-070 |
| QAS-09 | Localisation | JA dialogue | ヒケ/バリ/ショートショット; native review | AC-08, TC-066 |
| QAS-10 | Latency | Cavity analysis over 30 d; dialogue turn | ≤ 3 s; ≤ 15 s | NFR-03, NFR-04, TC-100, TC-101 |
| QAS-11 | Safety | Write attempt on the machine | refused by the server; audited | C-01, TC-110 |
| QAS-12 | Governance | Unapproved KB version used for ranking | refused | AI-08, TC-062 |

## 9. Platform mode
| Aspect | Standalone | Platform |
|---|---|---|
| Database | own PostgreSQL with the extracted sections + `moldmind_0001` | platform database; `moldmind_0001` applied; MoldMind owns `quality.mould/shot/shot_part/timeline_event` |
| Machine data | own `gateway-opcua` | platform ingest through IF-05 with MoldMind's node maps |
| Images / inspections | own `vision-infer` writing `vision.inspection` | VisionOps/EdgeGuard pipeline; MoldMind adds family heads and ΔE |
| 8D | local QE-style draft | QE-Agent case and artefact (IF-62) |
| Tools | — | `get_cavity_analysis`, `get_parameter_delta`, `get_golden_run_diff` registered (IF-16); QE's `get_case` consumed |
| Past cases | own `knowledge.case_record` | Genba Memory |
| Model | own Ollama | platform Ollama + GPU semaphore |

## 10. Risks and technical debt
| Risk (SRS §10) | Mitigation in the design | Residual |
|---|---|---|
| Subtle defects invisible | per-class lighting (AI-03); classes scoped to optics; anomaly model | RR-M02 |
| Cavity misattribution | three methods, method recorded, AC-02 gate | RR-M03 |
| Unrecorded parameter changes | captured from the controller (FR-04) | RR-M04 (manual valve/heater changes) |
| Stale or wrong KB | approval, sources, write-back, stale check | RR-M05 |
| Suggested change causes another defect | side effects mandatory; windows; check-first; effectiveness | RR-M06 |
| Camera survivability | enclosure spec, thermal test (NFR-07) | RR-M07 |
| Debt | ΔE formula (CIE76 now; CIE2000 option); Euromap 63 adapter untested; TimescaleDB optional | |

## 11. Traceability to SRS-11
| SRS-11 | Sections |
|---|---|
| C-01…C-05 | §2, §3.1, ADR-M01, M02, M03, M06, M07 |
| FR-01…FR-05 | §4.3.1, §4.4.3, ADR-M01 |
| FR-06…FR-11 | §4.3.2, §4.4.4, §4.4.5, ADR-M02 |
| FR-12…FR-18 | §4.3.3, §4.4.1, §4.4.2, ADR-M09 |
| FR-19, FR-25 | §4.3.4, ADR-M03, ADR-M08 |
| FR-20…FR-24, FR-26 | §4.3.5, ADR-M04…M08, M10 |
| FR-27 | §5 |
| AI-01…AI-09 | §4.3.2, §4.3.5, ADR-M03, M04, M05, M07, M10 |
| NFR-01…NFR-09 | §3.2, §4.5, §5 |
| AC-01…AC-09 | §4.4, §8 |
