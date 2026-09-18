# MoldMind — AI Vision + Agent for Injection Molding — Documentation Set

Per-shot machine parameters over **OPC-UA / Euromap 77 (read-only)** → part images at the part-exit station → **every defect joined to exactly one shot and one cavity** (OCR marking, robot position or sequence; alignment within tolerance) → an analyser that computes **per-cavity rates with a flag test, good-vs-defective parameter deltas with effect sizes, drift against the setup sheet, timeline correlation, startup transients and scrap cost** → a **reviewable defect → cause → check → action knowledge base** (YAML, sourced, approved by a second engineer, versioned) → an RCA agent that ranks causes with a **transparent additive score you can read component by component**, runs a guided dialogue in TH/JA/EN, orders **checks before changes**, **blocks any suggestion outside the documented process window**, verifies effectiveness with a significance test, writes verified outcomes back into the knowledge base and hands the 8D to QE-Agent. The language model phrases questions and explanations — it never ranks, never computes, never proposes a magnitude.

**A FactoryBrain module of medium coupling that owns `quality.mould`, `quality.shot`, `quality.shot_part` and `quality.timeline_event`** (SAD-00 §13; the platform's quality section 7 was written for SRS-09 QE-Agent and SRS-11). Standalone-deployable with a platform-mode section in every document. It consumes IF-05 machine data, the camera pipeline, MachineSense alarms and Genba Memory's past cases; it feeds QE-Agent (8D) and Copilot (`get_cavity_analysis`, `get_parameter_delta`, `get_golden_run_diff`).

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-11 | [Software Requirements Specification](SRS-MoldMind-Injection-Molding-AI.md) | *What must it do?* | Everyone — start here |
| SAD-11 | [Software Architecture Document](docs/SAD-MoldMind-Software-Architecture.md) | *How does a setpoint edit at 10:40 become a flagged cavity, a ranked cause list, two checks and one bounded suggestion — and why can the machine never be written, the window never exceeded, the ranking never invented?* | Architect, implementer, process engineering |
| DDS-11 | [Database Design Specification](docs/DDS-MoldMind-Database-Design.md) | *The platform's shot tables byte-for-byte, the `moldmind` extension, and the triggers that make joinability, read-only machines, windows, check-first ordering, transparent scores, computed effectiveness and knowledge approval properties of the data* | Implementer, DBA, QA |
| API-11 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The shot, analysis, RCA, knowledge and handoff contracts* | Implementer, UI, gateway and QE integrators |
| ICD-11 | [Interface Control Document](docs/ICD-MoldMind-Interface-Control.md) | *IF-05 node maps and buffering; alignment & attribution (IF-58); the KB format (IF-59); the scoring function and facts object (IF-60); suggestions & windows (IF-61); the QE handoff (IF-62)* | Implementer, OT, ML owner, process engineering |
| SEC-11 | [Security Requirements Specification](docs/SEC-MoldMind-Security-Requirements.md) | *Can anything write to the press? Can an out-of-window value reach a technician as allowed? Can the knowledge base be edited quietly? Can the wrong cavity be blamed?* | Security reviewer, OT, process engineering |
| TEST-11 | [Test Plan and Test Cases](docs/TEST-MoldMind-Test-Plan.md) | *How do we prove the twins, the 12 guards, the write refusal, the 500-part attribution trial, AC-03 on a real press, the blocked 800 bar, the effectiveness test and the golden set?* | QA, ML owner, OT |
| OPS-11 | [Deployment and Operations Guide](docs/OPS-MoldMind-Deployment-Operations.md) | *Press-side enclosure, machine onboarding with the write-refusal test, mould onboarding, KB workflow, observability, retention, runbooks* | Operator, OT, admin |
| UM-11 | [User Manual and Administrator Guide](docs/UM-MoldMind-User-Admin-Guide.md) | *A defect trend from alert to verified fix; reading the ranking; checks before changes; blocked suggestions; admin; TH/JA/EN moulding glossary* | Technicians, process/quality engineers, mould maintenance, managers, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 + pgvector (TimescaleDB optional): platform `core`/`vision`/`quality`/`knowledge`/`audit` sections **extracted verbatim from `00/db/schema.sql`** + the `moldmind` extension (migration `moldmind_0001`) — 77 tables, 17 views, 25 triggers, 32 functions, 60 indexes, 15 enums; 19 guard triggers (read-only machine, node-map read access, cavity range, joinability, alignment tolerance, transients, parameter change → timeline, KB shape/approval/immutability, transparent scores, session rules, check-before-change, window block + audit, computed effectiveness, write-back, cavity flag, vision/golden gates, setup-sheet immutability); twins `two_proportion_z`, `welch_t`, `cohens_d`, `drift_slope`, `delta_e76`, `cause_score`, `is_startup_transient`, `scrap_cost`; roles `app_rw`/`app_ro`/`agent_ro`/**`gateway_rw` (insert-only)**/`vision_rw`/`kb_rw` | ✅ 111/111 shared objects byte-identical, 4 sections verbatim; static DDL; ⚠️ not executed |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Reproduces SRS Appendix A (the sink-mark KB entry) and AC-02…AC-09 **through the real functions and triggers**: 448 shots / 1,280 parts / 83 defects; the AC-03 scenario (holding pressure 650 → 560 at 10:40 → sink marks 1.5 % → 9.0 %, z 4.60; cavity 3 flagged; deltas d −1.26; ranking 0.88 / 0.23 / 0.18 …; three dialogue answers; two checks then one action; 616 bar allowed, 800 bar blocked + audited; 616 applied → 1.75 %, effective, knowledge written back; 8D handed to QE); AC-06 transients; AC-09 128 buffered shots reconciled; ΔE 1.814 / 3.401; a reviewed weld line; data-quality flags; evaluation gates; 12 probes | ✅ re-derived in Python; ⚠️ not executed |
| [`deploy/kb/`](deploy/kb/) + [`schemas/kb-entry.schema.json`](deploy/schemas/kb-entry.schema.json) | **The IF-59 contract**: `sink_mark.yaml` = SRS Appendix A verbatim, `short_shot.yaml`, `flash.yaml`; every cause sourced; checks before actions; actions with direction/range/window/side effects | ✅ 3/3 valid; 12 negatives rejected; seed causes ⊆ YAML |
| [`deploy/machines/M-3.opcua.yaml`](deploy/machines/M-3.opcua.yaml) + [`schemas/opcua-nodemap.schema.json`](deploy/schemas/opcua-nodemap.schema.json) | **The IF-05 node map**: the FR-01 parameters, setpoint nodes, controller user; every node read-only; SignAndEncrypt; buffer ≥ 24 h | ✅ valid; 8 negatives rejected; equals the seed's node map |
| [`deploy/schemas/rca-facts.schema.json`](deploy/schemas/rca-facts.schema.json) | **The IF-60 contract**: what the dialogue model receives — ranked causes with components and weights, trend/cavity/delta/timeline facts with evidence codes, questions, windows, constant wording rules | ✅ valid; the seed's facts object valid (Σ w·c = score for every cause); 8 negatives rejected |
| [`api/openapi.yaml`](api/openapi.yaml) | **56 paths / 73 operations / 57 schemas** — SRS §4.1's eight paths + the platform's `/inspections/{inspectionId}`, `/inspections/{inspectionId}/verdict`, `/reviews`, `/cases/{caseId}/artifacts/{kind}`, `/knowledge/search` verbatim + machines/node maps/tests, gateway batches, moulds/setup sheets/windows, shots/defects/review, timeline/parameter changes/startup events/data quality/drift/transients/scrap cost, colour references, sessions (ranking, advice, suggestions, actions, outcomes, verify, close, handoff, term check), KB versions/approve/evidence, evaluation runs, scoring, glossary, config, system | ✅ valid; 0 orphans; 23/23 platform blocks verbatim |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) | 20 services (web, api, gateway-opcua, gateway-mqtt [profile], vision-infer gpu/cpu, aligner, analyser, kb-service, rca-agent, scheduler, postgres pgvector, redis, minio [+init], ollama gpu/cpu, mailpit, machine-sim, camera-replay); networks `frontend` / `machine` (gateways only) / `camera` (vision only) / `internal` / `egress`; four DB roles; 17 secret files incl. the machine's read-only account and the client certificate | ✅ parsed; 51/51 vars both ways; placement; hardening; no secret values |
| [`deploy/moldmind.example.yaml`](deploy/moldmind.example.yaml) + [`schemas/moldmind-config.schema.json`](deploy/schemas/moldmind-config.schema.json) | Acquisition (read-only constant, buffer ≥ 24 h), alignment tolerance, vision classes/lighting/ΔE/gates, analysis (flag α, transients excluded), knowledge rules (source, approval by another engineer, immutable), scoring weights (sum 1, transparent), RCA (check-before-change, window enforcement = block, effectiveness α, model ≤ 9 B / ≤ 0.3, scripted fallback, 8D → QE), golden gates, glossary, retention, locale | ✅ valid; **36 negatives rejected**; prompts, glossary, seed weights/tolerances consistent |
| [`deploy/prompts/`](deploy/prompts/) · [`deploy/glossary.example.csv`](deploy/glossary.example.csv) | `rca_question.v1` and `explain.v1` (phrase only; numbers with evidence codes; never a value outside the window); 20 moulding terms TH/JA/EN with forbidden variants (ヒケ, バリ, ショートショット …) | ✅ front-matter matches the config; no forbidden variant inside a mandated term |

---

## Reading paths

**Implementing it** → SRS-11 → SAD-11 §4.3 (acquisition, vision & attribution, analysis, KB, RCA agent) → DDS-11 §2 (DD-M01…M09) → `db/schema.sql` §10–§17 → `deploy/schemas/` (KB, node map, facts) → API-11 §3–§7 → ICD-11 IF-05, IF-58…IF-62 → TEST-11 TS-0.

**OT / machine owner** → ICD-11 IF-05 → `deploy/machines/M-3.opcua.yaml` → SEC-11 §5.1 → OPS-11 §5, RB-02, RB-11 → TEST-11 TC-013, TC-014.

**Process engineering** → SRS-11 Appendix A → ICD-11 IF-59, IF-60, IF-61 → `deploy/kb/sink_mark.yaml` → DDS-11 §9 (the AC-03 scenario) → UM-11 A.3, B.4 → OPS-11 §6, §8.

**Security reviewer** → SEC-11 §4.2 ("just raise the holding pressure") → SEC-11 §5 → DDS-11 Appendix A → TEST-11 TC-003 probes, TC-055, TC-057, TC-110 → OPS-11 §9 (write refusals = 0).

**ML owner** → SAD-11 ADR-M04, ADR-M05, ADR-M10 → ICD-11 IF-09, IF-60 → `deploy/prompts/` → TEST-11 TC-020, TC-056, TC-070 → OPS-11 §4.3, §8.

**Operating it** → OPS-11 §1, §4, §5, §9, §12 runbooks — RB-02 and RB-07 first.

**Using it** → UM-11 A.1, A.3 (alert to verified fix), A.8.

---

## What makes this design what it is

| Principle | In MoldMind |
|---|---|
| **The LLM never computes** | Scores come from `cause_score()` over stored components and are recomputed by the database; deltas, flags, drift and effectiveness are code; the model phrases questions and explanations from a facts object (AI-05, AI-06, ADR-M04, ADR-M05). |
| **Offline-first → degrade** | The gateway buffers ≥ 24 h and reconciles by shot id; vision, alignment and analysis need no model; the dialogue falls back to the KB's scripted questions (NFR-05, AC-09). |
| **Advisory only — the technician acts** | The machine is read-only; every action carries direction, range, window and side effects; checks precede changes; out-of-window values are blocked and audited (C-01, C-04, C-05, AI-09, ADR-M06, ADR-M07). |
| **The database is the source of truth** | Joinability, alignment tolerance, transients, KB approval, transparent scores, ordering, windows, effectiveness — 19 triggers (DDS-11 DD-M01…M09). |
| **Domain knowledge is reviewable data** | YAML with sources, imported as versions, approved by a second engineer, immutable, golden-tested, learning from verified outcomes (C-03, AI-08, NFR-08, FR-25, ADR-M03). |
| **Every defect is one shot and one cavity** | `shot_defect → shot_part → shot`; cavity ≤ mould cavities; image within tolerance; attribution method recorded and measured (C-02, AC-02, ADR-M02). |

---

## Relationship to the platform and siblings

| | |
|---|---|
| Coupling | **Medium** (SAD-00 §13): owns `quality.mould/shot/shot_part/timeline_event`; shares the quality section with [QE-Agent (09)](../09-quality-engineer-agent/); migration `moldmind_0001` |
| Consumes | IF-05 machine data (Euromap 77), the camera pipeline (01 VisionOps / 03 EdgeGuard) for inspections, 06 MachineSense alarms on the timeline, 15 Genba Memory past cases, 14 GenbaGo glossary |
| Feeds | 09 QE-Agent (8D handoff — IF-62), 10 Copilot (`get_cavity_analysis`, `get_parameter_delta`, `get_golden_run_diff` — IF-16), 13 KaizenSwarm (`quality.signal.high`, `moldmind.rca.closed` — IF-17) |
| Platform paths served verbatim | `/inspections/{inspectionId}`, `/inspections/{inspectionId}/verdict`, `/reviews`, `/cases/{caseId}/artifacts/{kind}`, `/knowledge/search` |

---

## Identifier conventions

`FR-01…27` / `AI-01…09` / `NFR-01…09` / `AC-01…09` / `C-01…05` (SRS-11) · `P-1…P-6` · **`ADR-M01…M10`** · `QAS-01…12` · **`DD-M01…M09`** · `IF-xx` shared numbering (**IF-58 alignment & attribution, IF-59 KB format, IF-60 scoring & facts, IF-61 suggestions & windows, IF-62 QE handoff**) · **`THR-M01…12`**, **`SEC-M01…53`**, **`RR-M01…07`** · `TS-0…9`, `TC-001` to `TC-117` · `RB-01…14` · evidence codes `E-nn`.

```
SRS-11 C-04 / C-05 / AI-09 / FR-22 / FR-23 / AC-05  "checks before changes; suggestions within the documented window; out-of-window blocked and logged"
  └─ SAD-11 P-3 · ADR-M06 (check-before-change structural) · ADR-M07 (windows block) · §4.3.5 · §4.4.1
      └─ DDS-11 DD-M08, DD-M09 · parameter_window · rca_advice (kind, ordinal) · parameter_suggestion (allowed | blocked) · trg_advice_check_first · trg_suggestion_window · audit.log
          └─ API-11 §5 RCA contract (advice order; 201 blocked; 409 OUT_OF_WINDOW / CHECK_BEFORE_CHANGE)
              └─ ICD-11 IF-61 (window source, verdict, presentation) · IF-59 (actions with window_ref and side_effects)
                  └─ SEC-11 O-2 · THR-M02, THR-M03 · SEC-M10…M13 · §4.2 walk-through
                      └─ TEST-11 TC-003 probes 4, 8 · TC-053 · TC-054 · TC-055 · seed: 616 allowed, 800 blocked + audit row
                          └─ OPS-11 §6 · §9 (blocked share) · RB-07 · UM-11 A.3.4, B.3
```

---

## Verification

| Check | Result |
|---|---|
| **Byte-identity vs `00/db/schema.sql`** (TC-002) | ✅ **Pass** — 111/111 shared objects; the core, vision, quality and knowledge sections present verbatim |
| Static DDL (TC-003) | ✅ **Pass** — 77 / 17 / 25 / 32 / 60 / 15; FK targets and order; 19/19 guard triggers; `gateway_rw` insert-only and no DELETE for gateway/vision/kb roles; `agent_ro` revoked on users/scope/connections; 12 probes present |
| Seed vs Python re-derivation (TC-005) | ✅ **Pass** — 448 shots / 1,280 parts / 83 defects; 36/400 vs 6/400 z 4.5971 p 4.3e-6; cavity 3 z 4.2366 flagged, cavities 1/2/4 not; holding pressure 582.190 vs 625.254, d −1.2619, t −7.617; cushion d −1.288; drift +0.011221 / +0.420011 / −0.0015; ΔE 1.814 / 3.401; scores 0.88 / 0.2333 / 0.175 / 0.175 / 0.1167 / 0.1167 (rank 1 insufficient holding pressure); 616 allowed (+10 %), 800 blocked (+42.86 %); effectiveness 36/400 → 7/400 z 4.3896 effective; golden diff −34; scrap 1,512 / 2,058 / 1,344; gates vision v2 fail / v3 pass, golden 0.7333 pass / 0.60 fail; A–S vs `erfc` 7e-8 |
| **KB, node-map and RCA-facts contracts** (TC-006) | ✅ **Pass** — KB 3/3 valid + 12/12 negatives; node map valid + 8/8; facts valid (Σ w·c = score) + 8/8; seed cause codes ⊆ YAML; seed node map = YAML |
| Config schema, prompts, glossary (TC-007) | ✅ **Pass** — example valid; 36 negatives rejected; prompts' front-matter match; glossary 20 terms, AC-08 terms present; seed weights / transient window / tolerance = config |
| `openapi.yaml` (TC-001) and identity vs API-00 (TC-008) | ✅ **Pass** — 56 / 73 / 57; 0 orphans; 5 paths + 9 schemas + 5 parameters + 4 responses verbatim |
| Compose / env (TC-004) | ✅ **Pass** — 20 services; `machine` = gateways only; `camera` = vision only; egress = {api, scheduler}; 9 internal-only; rca-agent/ollama isolated; gateway has only its DB role, certificate and the machine's read-only account; 51/51 vars; 17/17 secrets; eval bucket locked; no secret values |
| SRS-11 coverage; cited objects/endpoints/TCs/RBs/ADR-M/SEC-M/DD-M/THR-M; section refs; links (TC-001) | ✅ see sweep note below |
| **Schema + seed on PostgreSQL 16** (TC-009) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| Press, OPC-UA write refusal, camera/lighting/models, attribution trial, GPU timing, Ollama, golden set, native review (TS-1, TS-2, TS-8, TC-056, TC-066, TC-070) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 11-injection-molding-ai
docker run -d --name mm-pg -e POSTGRES_PASSWORD=x -p 5438:5432 pgvector/pgvector:pg16
sleep 8 && psql "postgresql://postgres:x@localhost:5438/postgres" -v ON_ERROR_STOP=1 -f db/schema.sql && psql "postgresql://postgres:x@localhost:5438/postgres" -f db/seed_demo.sql
```
Expected: the `\echo` block matches DDS-11 §9 (counts, trend and cavity tests, parameter deltas, drift, golden diff, ΔE, ranking with components, advice order, suggestions with the audit row, effectiveness and write-back, RCA board, KB status, gates, data quality, gateway lag, scrap cost) and probes 1–12 each fail with the named guard.

**Defects found by checking** (all fixed; TEST-11 §5): a JSON array written as a SQL array literal; bigint counts into integer columns; a KB-schema conditional that fired on absent keys; guards that silently recomputed an asserted `allowed`/`effective` (now refused); estimated delta means in the facts object; agent-section leftovers in the assembler; a probe that could not fail.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL execution pending — byte-identity, static checks and Python re-derivation stand in until CI runs TC-009 | TEST-11 TC-009 |
| **Real press, camera, lighting and models** — AI-02 metrics, AC-02 attribution and AC-03 on a real run need the pilot rig; the seed's evaluation runs are illustrative | TEST-11 TS-1, TS-2, TC-050 |
| **The golden set** (15 historical moulding incidents) is plant data and not in the repository | TEST-11 TC-070 |
| ΔE formula: CIE76 shipped (simple, in-frame chart); CIE2000 selectable — the plant's colour spec decides | ICD-11 IF-58, `moldmind.yaml vision.colour.formula` |
| SRS §5 `machine` and `material_lot` are the platform's `core.machine`/`core.material_lot`; SRS `mould.last_maintenance_at` is the platform's `last_maintenance`; `kb_*`, `rca_session`, `action_outcome` live in schema `moldmind` | DDS-11 §1.2 |
| `get_machine_telemetry`-style machine signals are MachineSense's; MoldMind reads alarms from the bus, not telemetry tables | ICD-11 IF-17 |
| TimescaleDB optional — plain partitioning shipped; the hypertable conversion is one command | OPS-11 §10 |
| Euromap 63 file adapter specified, not exercised by the seed | ICD-11 IF-05 |
| The dialogue answers in the seed do not change the ranking (all consistent with cause 1); a session where an answer demotes a cause is a TS-5 case, not a seed row | DDS-11 §9, TEST-11 TC-052 |
| A technician's own change at the controller outside any window is captured but not preventable | SEC-11 RR-M01 |
