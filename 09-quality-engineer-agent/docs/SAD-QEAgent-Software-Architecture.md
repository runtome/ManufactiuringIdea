# Software Architecture Document — QE-Agent (AI Manufacturing Quality Engineer Agent)

| Field | Value |
|---|---|
| Document ID | SAD-09-QEAgent |
| Version | 1.0 (Draft) |
| Date | 2026-09-15 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-09](../SRS-QE-Agent-Quality-Engineer.md) |
| Related | [DDS-09](DDS-QEAgent-Database-Design.md) · [API-09](../api/API-Specification.md) · [ICD-09](ICD-QEAgent-Interface-Control.md) · [SEC-09](SEC-QEAgent-Security-Requirements.md) · [TEST-09](TEST-QEAgent-Test-Plan.md) · [OPS-09](OPS-QEAgent-Deployment-Operations.md) · [UM-09](UM-QEAgent-User-Admin-Guide.md) · platform: [SAD-00](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) §13, [ICD-00 IF-16](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-16) |

---

## 1. Introduction

### 1.1 Purpose
Define the architecture of QE-Agent: the routine analytical work of a quality engineer — control charts and Nelson rules, capability with a normality check, defect-rate change detection and change points, correlation against lots, machines, moulds, shifts and parameter changes, retrieval of past cases — turned into a **ranked list of hypotheses with supporting and contradicting evidence**, and into drafts of the standard artefacts (5-Why, 8D, FMEA rows, the Japanese 品質報告書) that a **named engineer verifies and owns**. The document fixes as architecture what the SRS makes non-negotiable: every AI artefact is DRAFT until approved (C-01), every statistic is computed by the engine and never by the model (C-02), no capability index without its sample context and normality assessment (C-03), causal language only for verified causes (C-04), the organisation's FMEA standard (C-05).

### 1.2 What makes this project different from its siblings
QE-Agent is the project where **statistics and language meet most closely**. ShiftBrief writes prose around KPIs; MachineSense explains alerts; QE-Agent must produce documents that look like an engineer's — a 5-Why chain, an 8D, an FMEA row with S/O/D — from p-values, effect sizes and change points, in three languages, and those documents become the plant's institutional memory. Three consequences shape the architecture:

- **Two engines, one contract.** The analytics engine (Python: pandas/scipy/statsmodels) computes everything and writes it into an **evidence registry** — a table of numbered, digestible facts (`evidence`). The drafting model receives a **facts object** built only from that registry (IF-51) and writes prose. Every sentence with a number or a causal claim is extracted as a `claim` and must point at an `evidence_id`; an artefact with an untraced claim cannot be approved (AI-04, AC-05). The two engines never share a data path except this contract.
- **Hypotheses, not causes.** The correlation analyser reports significance *and* effect size *and* a multiple-comparison warning (FR-14); every hypothesis carries supporting evidence, contradicting evidence and a verification step (FR-17); a statement using causal wording is refused by the database until the hypothesis is `confirmed` (C-04). The Appendix A output — "Material lot change — score 0.71 … Verify: re-inspect retained sample" — is the shape the whole pipeline produces.
- **Ownership is structural.** DRAFT is not a caption: an unapproved artefact cannot be exported without the watermark (`export` rows are constrained), approvals need role ≥ engineer and are immutable and audited (NFR-05), S/O/D ratings are proposed against criteria tables and confirmed one by one by the engineer (AI-07), and a closed case becomes a precedent in the knowledge base only after effectiveness verification (FR-28, FR-29).

### 1.3 Two ways to deploy it
**Standalone**: the compose stack in `deploy/` with its own PostgreSQL (pgvector), object store, local model and the data sources connected through IF-49. **Platform mode**: QE-Agent is the FactoryBrain module that owns the `quality` schema (SAD-00 §13, "tight"); it shares `core`, `knowledge` and `audit`, registers its tools next to the platform's `get_spc`/`query_defects`/`search_memory` (IF-16), publishes signals on the bus for KaizenSwarm (IF-17) and uses Genba Memory (15) as the case archive. Every document carries a platform-mode section (§9 here).

### 1.4 Related documents
DDS-09 (schema; the evidence registry and grounding gate; SQL twins of the statistics; the seed reproducing Appendix A and AC-01…AC-09), API-09 (evidence / hypothesis / approval & export / statistics contracts), ICD-09 (IF-49 data layer, IF-50 export, IF-51 facts object, IF-52 glossary; reused IF-08/09/10/13/14/16/17/19), SEC-09, TEST-09, OPS-09, UM-09.

---

## 2. Architecture principles

| # | Principle | In QE-Agent |
|---|---|---|
| **P-1** | **The LLM never computes.** | Limits, rules, Cp/Cpk, p-values, effect sizes, change points, rankings and effectiveness tests are computed by the analytics engine and stored as `evidence`; the model receives the facts object and writes prose; a claim-level grounding gate blocks approval of any artefact whose numbers or causal statements are not traced (C-02, AI-01, AI-04). |
| **P-2** | **Degrade to statistics-only.** | With the model unavailable, charts, rule violations, capability, signals, correlations and the ranked hypothesis table are still produced; only the prose artefacts wait (AI-08, AC-09). |
| **P-3** | **A named engineer owns every artefact.** | DRAFT watermark until approval; approval by role ≥ engineer; approvals immutable and audited; S/O/D confirmed per rating; control-limit changes with a reason (C-01, FR-06, AI-07, NFR-05). |
| **P-4** | **The database is the source of truth.** | Evidence, claims, normality flags, watermarks, causal-wording rules, approval immutability, closure preconditions and case indexing are constraints, triggers and functions (DDS-09 DD-Q01…Q09). |
| **P-5** | **Hypotheses, not causes.** | "Hypothesis to verify" wording until confirmed; effect size beside every p-value; multiple-comparison warning on every factor scan; "no meaningful association" stated explicitly (C-04, FR-14, FR-18). |
| **P-6** | **Statistics are verified against references.** | Reference datasets (NIST/Minitab-style) in CI at 1e-6; SQL twins of the closed-form statistics in the database for independent checks (NFR-04, AC-01, AC-02). |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-09 §2.4)
| ID | Constraint | Architectural response |
|---|---|---|
| C-01 | AI artefacts marked DRAFT until a named engineer approves | `artifact.ai_generated ∧ approved_by IS NULL` = draft; `export.watermark` must be `DRAFT — AI generated` for drafts (CHECK); the exporter stamps it into DOCX/XLSX/PDF (ADR-Q08) |
| C-02 | Statistics by the engine; LLM writes prose around given numbers | Evidence registry + facts object (IF-51); claims trace; grounding gate (ADR-Q02, Q03) |
| C-03 | No capability index without n, subgroup structure and normality | `capability_result` carries `n`, `period`, `normality_p/ok`, `method_note`; `normality_ok = false` requires a method note and is exported with the warning, never as a plain Cpk (ADR-Q05) |
| C-04 | Causal language reserved for verified causes | `trg_hypothesis_wording` refuses causal phrases unless `status = confirmed`; prompt templates use "hypothesis to verify"; claims of kind `causal` must cite a confirmed hypothesis (ADR-Q06) |
| C-05 | FMEA standard configurable (AIAG-VDA AP or classic RPN) | `fmea_config.standard`; `sod_criteria` tables per standard; `fmea_row.rpn` generated (platform) and `ap` derived by the engine (ADR-Q07) |

### 3.2 Quality attributes
| Attribute | Requirement | Design |
|---|---|---|
| **Latency** | NFR-01 90-day chart ≤ 2 s; NFR-02 correlation 30 d × 6 factors ≤ 20 s; NFR-03 8D draft ≤ 90 s | Subgroups pre-aggregated (`subgroup` table); violations stored, not recomputed; factor tests as set-based SQL + scipy on aggregates; one model call per artefact with a compact facts object |
| **Correctness** | NFR-04 1e-6 vs references; AC-01, AC-02 | Reference test suite in CI; SQL twins (`xbar_r_limits`, `capability_indices`, `two_proportion_z`, `nelson_rule*`) for cross-checks |
| **Groundedness** | AI-04 untraceable content is release-blocking; AC-05 | `artifact_claim` + `trg_artifact_approval` gate; `v_evidence_audit` |
| **Hypothesis quality** | AI-05 true cause in top-3 ≥ 60 % on ≥ 20 incidents; fabricated evidence 0 % | `golden_incident`/`golden_run`; release gate (ADR-Q10) |
| **Governance** | NFR-05 approvals immutable/audited; NFR-06 versions and approver on every export | `trg_artifact_approval` (role, immutability, audit); `artifact_revision`; `export.version_stamp` |
| **Locality** | NFR-07 no quality data leaves the LAN | `internal` network for engine/model/DB; egress only for Discord/SMTP with no document content |
| **Coverage** | NFR-08 ≥ 85 % on the SPC/capability engine | engine as a pure library with the reference suite |
| **Localisation** | NFR-09 TH/JA/EN incl. chart labels; AI-06 glossary; AC-07 | prompt templates per language; `term_check` against `knowledge.glossary_term`; export templates per language |

### 3.3 Not drivers
Being the system of record for approvals unless adopted; automatic FMEA or control-plan changes; vision inspection and telemetry themselves (consumed).

---

## 4. Views

### 4.1 Context view
```
  Inspection (01/03) · Production (02) · Telemetry (06) · Lot genealogy · Maintenance · Parameter edits ──► IF-49 quality data layer
  Quality document archive (15 Genba Memory) ──► retrieval (IF-16 search_memory)                                   │
                                                                                                                    ▼
  Quality engineer · QC supervisor · Production engineer · Japanese management · Customer QA ◄── UI ──►  QE-Agent  ──► DOCX/XLSX/PDF (IF-50)
                                                                                                                    ├──► Discord / e-mail (IF-08 / IF-13)
                                                                                                                    ├──► KaizenSwarm (13) via the bus (IF-17)
                                                                                                                    └──► local LLM (IF-09) ◄── facts object only (IF-51)
```

### 4.2 Container view
| Container | Responsibility | Notes |
|---|---|---|
| `web` | Charts, signals, case board, hypothesis list, draft editor with diff, S/O/D confirmation, approvals, exports, admin | TH/JA/EN incl. chart labels |
| `api` | FastAPI: SRS §4.1 paths + characteristics, limits, violations, correlations, artefacts, FMEA, actions, config | `app_rw`; writes audit for approvals/limits/exports |
| `spc-engine` | Subgrouping (FR-03), charts and limits (FR-01), Nelson rules 1–8 (FR-02), capability + Anderson–Darling + non-normal path (FR-04/05), limit history (FR-06), chart images (FR-07) | Python; reference-tested; runs as `engine_rw` |
| `signal-detector` | 7/30-day baselines, two-proportion tests (FR-08), CUSUM/binary segmentation (FR-09), ranking (FR-10), suppression (FR-11), auto-case (FR-12) | scheduled and on-demand |
| `correlator` | Factor tests (χ²/Fisher/rate comparison), effect sizes, Benjamini–Hochberg (FR-13/14), timeline correlation (FR-15), retrieval (FR-16), hypothesis ranking (FR-17), "no association" (FR-18) | writes `evidence`, `hypothesis` |
| `drafter` | Facts object → prompt (per artefact × language, versioned) → prose → claim extraction → evidence trace → grounding check → term check (FR-19…FR-23, FR-26, AI-03/04/06) | Ollama ≤ 9 B, temperature ≤ 0.3; withholds an artefact that fails grounding |
| `indexer` | Closed cases → `knowledge.case_record` + chunks + embeddings (FR-29); glossary load; hybrid retrieval | multilingual embedding (AI-02) |
| `exporter` | DOCX/XLSX/PDF from company templates; DRAFT watermark; version + approver stamp (FR-25, NFR-06, AC-06) | LibreOffice headless for PDF |
| `scheduler` | Daily signal scan, overdue escalation (FR-31), golden runs, retention | cron |
| `postgres` | PostgreSQL 16 + pgvector (`core`, `quality`, `knowledge`, `vision.model_registry`, `audit`) | shared objects byte-identical |
| `redis` · `minio` · `ollama` · `mailpit` (dev) | queues; chart images and exports; local model; mail sink | — |

### 4.3 Component view

#### 4.3.1 Quality data layer (IF-49)
Measurements arrive as `quality.measurement` rows (ts, characteristic, line, value, lot, machine, shift) from inspection records (01/03) and manual gauges; defect counts per window come from `core.defect_fact`/inspection verdicts; events (lot change, maintenance, tool/mould change, parameter edit, personnel change, environment) are `quality.timeline_event` rows fed by 02/06/DocFlow/CMMS. The join keys are time, line, lot and mould; a data-quality report (missing lot on measurements, inconsistent defect codes) precedes any analysis (SRS §10).

#### 4.3.2 SPC engine (FR-01…FR-07)
- **Subgroups** by fixed n, time window or batch (`characteristic.subgroup_rule`) → `subgroup` rows with mean, range, sd, n.
- **Limits** from a configurable baseline period using the standard constants (A2, D3, D4, d2 for X̄-R; X-mR with 2.66/3.267; p/np/c/u from binomial/Poisson); stored in `control_limits` with `sample_size`, `reason`, `created_by` — **append-only** (FR-06; the platform's comment: "recalculating limits silently is a classic way to hide a process shift").
- **Nelson rules** 1–8 implemented; the enabled set per characteristic in `rule_config` (minimum {1, 2, 3, 5, 6} cannot be disabled); each violation stored with the rule id and the points involved (`spc_violation.points_json`).
- **Capability**: Cp, Cpk, Pp, Ppk with Anderson–Darling; `normality_ok = false` → the engine recommends a Box-Cox/Johnson transformation or a non-normal percentile method and records `method_note`; a naive Cpk is never presented (FR-04/05, AC-03).
- **Export** of chart images (PNG) and CSV to the object store (FR-07).

#### 4.3.3 Signal detection (FR-08…FR-12)
Defect rate per (line, sku, defect class) compared with 7- and 30-day baselines by a two-proportion z-test with continuity correction (Fisher exact below 5 expected events); the estimated change time by CUSUM confirmed by binary segmentation with a ± window; ranking score = `w_impact·customer_impact + w_crit·class_criticality + w_vol·volume_share + w_slope·trend_slope` (weights in `ranking_config`); suppression below `min_sample` and inside declared `trial_run` windows; HIGH signals open a `quality.case` and notify the owner (IF-08/IF-13).

#### 4.3.4 Correlation and hypotheses (FR-13…FR-18)
For a signal window: contingency tables per factor (lot, machine, mould, shift, operator group, SKU, recent parameter change) → χ² or Fisher; **effect size** (risk ratio / Cramér's V) with a confidence interval; Benjamini–Hochberg across factors with the multiple-comparison warning in the facts object; the change point aligned with `timeline_event` rows (±window); similar cases via hybrid retrieval ranked by similarity × outcome (`case_record.outcome`); hypotheses ranked by an evidence score (effect size × significance × timeline proximity × precedent), each with `evidence_json`, `contra_json` and `verify_step`; factors without a meaningful association listed explicitly. Every number produced here is an `evidence` row with a digest.

#### 4.3.5 Drafting (FR-19…FR-26, AI-03…AI-07)
1. Build the **facts object** (IF-51) from `evidence` for the case: signal statistics, change point, factor tests, hypotheses, similar cases, capability/limits — each value with its `evidence_id`; nothing else.
2. Prompt = versioned template (`prompt_template`, per artefact × language) + facts object; temperature ≤ 0.3; the template forbids numbers not in the object and prescribes "hypothesis to verify" wording.
3. Output → **claim extraction** (every sentence with a number, percentage, date, count or causal verb) → each claim mapped to an `evidence_id` by value match → `artifact_claim` rows; unmatched numeric/causal claims mark the artefact `grounding_failed`; the artefact is stored as a draft but **cannot be approved** (trigger) and the UI shows the untraced sentences.
4. Term check (IF-52) for JA against the glossary; violations listed (AI-06).
5. FMEA rows: proposed with `s/o/d` each pointing at a `sod_criteria` row and a justification evidence id; the engineer confirms each rating before the row is written to `fmea_row` (AI-07).
6. Edits in the UI create `artifact_revision` rows; the diff against the AI version is always available (FR-24).

#### 4.3.6 Case management (FR-27…FR-31)
`quality.case` with steps, actions (containment/corrective/preventive/horizontal, owners, due dates); **effectiveness verification** = two-proportion test before/after the action (`effectiveness_check`) — an action is `verified` only with a significant improvement recorded, and "no significant improvement" is a recorded, honest outcome (FR-28, AC-08); closure requires actions verified or cancelled and a closure note; closure indexes the case as a `knowledge.case_record` with chunks (FR-29) and proposes **horizontal candidates** (same mould/SKU family/line type — FR-30); overdue actions escalate (FR-31).

### 4.4 Runtime views

**Appendix A — Signal S-241 to an 8D draft**
```
t=0     daily scan: scratch rate on Line 4, last 24 h: 3.18 % vs 30-day baseline 0.52 % → two-proportion z, p < 0.001 → signal HIGH
t=1 s   CUSUM/binary segmentation on hourly rates → change point 2026-09-08 14:20 ± 40 min → evidence E-01..E-03
t=2 s   case opened (FR-12), owner notified
t=3 s   POST /cases/{id}/analyze → correlator:
        lot: LOT-2609-114 started 14:12 (timeline_event); 4.9 % on the lot vs 0.6 % on others, n = 1,880, Fisher p < 0.001, RR 8.2 → E-04..E-06
        mould M-12: last polished 62 d ago (plan 45); scratch rate 2.1× other moulds / 30 d → E-07..E-08
        shift B: 68 % of defects vs 61 % of volume → weak (RR 1.1) → E-09..E-10 · machine / operator group / ambient: no association → E-11
        BH correction over 7 factors: lot survives; mould borderline; shift does not → warning in the facts object
        retrieval: #212 (2025-03 material contamination, confirmed), #178 (2024-11 mould polish overdue, confirmed) → E-12..E-13
        hypotheses ranked 0.71 / 0.38 / 0.19 with supporting, contra, verify (FR-17)          [≤ 20 s, NFR-02]
t=25 s  POST /cases/{id}/draft/8d → facts object (13 evidence ids) → model → 8D draft (D1–D8, D4 "hypothesis to verify") → 41 claims, 41 traced → term check ok → DRAFT stored (v1)   [≤ 90 s, NFR-03]
        engineer edits D3 containment (revision v2, diff shown), verifies hypothesis 1 (retained sample re-inspected: contamination) → status confirmed
        approve (engineer) → approved_by/at immutable, audit row → export DOCX (clean, version v2, approver stamped)
```

**AC-03**: Anderson–Darling p = 0.003 on a characteristic → `normality_ok = false`, `method_note = 'Box-Cox λ = 0.2 recommended; percentile Ppk 1.08'`; the API returns the indices with `warning`; the exporter prints the warning beside any capability figure.

**AC-05**: a draft sentence "the defect rate fell to 0.3 %" with no evidence for 0.3 % → claim untraced → `grounding_failed`; approval refused with the sentence listed; the engineer edits or the drafter regenerates.

**AC-06**: `POST /artifacts/{id}/export` on an unapproved artefact → `export.watermark = 'DRAFT — AI generated'` (the CHECK refuses anything else) → file with the diagonal watermark on every page.

**AC-08**: action "replace lot; re-polish M-12" applied 2026-09-09 → before 3.18 % (n 2,200) vs after 0.55 % (n 2,100) → z = 6.1, p < 0.001 → `verified`; control case 0.60 % vs 0.58 % → p = 0.93 → "no significant improvement", action stays `done`.

**AC-09**: Ollama stopped → analyze works, hypotheses table works, `POST /draft/*` → `503 MODEL_UNAVAILABLE` with the statistics-only payload; `/readyz` 200 with `llm = false`.

### 4.5 Deployment view
Standalone compose: `web`, `api`, `spc-engine`, `signal-detector`, `correlator`, `drafter`, `indexer`, `exporter`, `scheduler`, `postgres` (pgvector), `redis`, `minio`, `ollama` (gpu/cpu), `mailpit` (dev). Networks: `frontend` (proxy → api/web), `internal` (`internal: true` — DB, Redis, MinIO, Ollama, engine, detector, correlator, drafter, indexer, exporter), `egress` (api, scheduler: Discord/SMTP; data-source connectors when remote). No document content leaves on `egress`.

### 4.6 Data view
Schemas: `core` (plant, line, sku, machine, material_lot, app_user, scope), `vision.model_registry` (referenced by `artifact.model_id`), `quality` (the platform's 15 tables byte-identical + the `quality_0001` extension), `knowledge` (document, chunk, case_record, case_source, case_chunk, glossary_term), `audit`. The rule-carrying objects: `evidence`, `artifact_claim`, `trg_artifact_approval`, `export.watermark` CHECK, `trg_hypothesis_wording`, `trg_capability_note`, `trg_fmea_confirm`, `trg_action_verified`, `trg_case_close`, `trg_limits_append_only`. DDS-09.

---

## 5. Cross-cutting concerns
| Concern | Design |
|---|---|
| Identity & roles | platform roles; `quality_engineer` = `engineer` (approve, confirm ratings), `manager` (also close cases), `admin` (config); `inspector` (QC supervisor: signals, containment), `viewer` |
| Numbers | every statistic stored with n, period and method; percentages as ratios with counts; p-values with the test name; effect sizes with CI |
| Localisation | prompt templates × {th, ja, en}; export templates × language; chart labels from a message catalogue; JA term check |
| Errors | RFC 7807 `Problem` verbatim from API-00; guard names surface (`GROUNDING_FAILED`, `NOT_APPROVED`, `ROLE_INSUFFICIENT`, `CAUSAL_WORDING`) |
| Observability | IF-14: engine latencies, violations/day, signals by severity, analyze/draft latencies, grounding failure rate, term-check violations, golden top-3 rate, overdue actions |
| Versions | `prompt_template` (git-tracked files with checksums), `vision.model_registry` for the drafting model, `artifact.version`/`artifact_revision`, `control_limits` history, `fmea_config` |
| Retention | measurements 3 y; subgroups/violations 5 y; cases, artefacts, evidence, exports 10 y; audit 7 y |

## 6. Spurious correlation presented as a cause — the design's own risk
The SRS's second risk is the one the architecture is built around. Five barriers: (1) effect size and CI beside every p-value (FR-14); (2) Benjamini–Hochberg across the factor scan with the warning carried into the facts object; (3) the hypothesis record requires contra evidence and a verification step (FR-17); (4) causal wording is refused by the database until the engineer confirms (C-04); (5) the golden set measures whether the *true* cause reaches the top-3, so ranking is tuned on outcomes, not on p-values. What the architecture cannot fix: confounded factors that move together (a new lot on one mould in one shift) — the hypothesis list shows all three with their overlap, and the verification steps are how the engineer separates them.

---

## 7. Architecture Decision Records

### ADR-Q01 — Statistics in a separate Python engine with a reference test suite
The SPC/capability/test code is a pure library (`spc-engine`) with no model dependency, tested against NIST/Minitab-style references at 1e-6 and ≥ 85 % coverage (NFR-04, NFR-08). Alternatives rejected: statistics in SQL only (Anderson–Darling, CUSUM impractical), statistics via the model (forbidden by C-02).

### ADR-Q02 — Evidence registry and facts object are the only model input
Every computed value is an `evidence` row (kind, value_json, query, digest); the facts object is assembled from those rows and validated against `facts-object.schema.json` (IF-51). The model never sees raw tables, documents or free text beyond the retrieved case summaries, which are themselves evidence rows.

### ADR-Q03 — Claim-level grounding gate blocks approval
Sentences with numbers, dates, counts or causal verbs are extracted as claims and matched to evidence; unmatched claims set `grounding_failed`; the approval trigger refuses. The gate is at approval, not at generation, so a draft can be shown with its problems highlighted (AI-04, AC-05).

### ADR-Q04 — Nelson rules configurable per characteristic, minimum set fixed
`rule_config` enables/disables rules 4, 7, 8 per characteristic; rules 1, 2, 3, 5, 6 cannot be disabled (FR-02). Violations store the rule id and point ids so a chart can highlight them and a report can cite them.

### ADR-Q05 — Capability is gated on normality with an explicit non-normal path
`capability_result.normality_ok = false` requires `method_note`; the API returns indices with a warning object; exports print the warning; the facts object carries `normality_ok` so the model cannot write "Cpk 1.33" without the caveat (C-03, FR-05, AC-03).

### ADR-Q06 — Hypotheses ranked by evidence score with mandatory contra, verify step and a causal-wording guard
Score = f(effect size, significance after correction, timeline proximity, precedent outcome); `contra_json` and `verify_step` required; `trg_hypothesis_wording` refuses "caused by / root cause is / due to" unless `status = confirmed` (C-04, FR-17).

### ADR-Q07 — FMEA ratings come from criteria tables and are confirmed one by one
`sod_criteria` holds the organisation's S/O/D tables per standard; a proposal's ratings reference criteria rows with an evidence justification; `fmea_row` is written only by the confirmation trigger after the engineer confirms each rating; RPN generated (platform), AP derived from the AIAG-VDA table (C-05, AI-07).

### ADR-Q08 — The DRAFT watermark is structural
`export.watermark` CHECK: an artefact without `approved_by` can only be exported with `'DRAFT — AI generated'`; the exporter reads the row, not a UI flag; the file carries version and approver (C-01, NFR-06, AC-06).

### ADR-Q09 — Approvals are immutable, role-gated and audited
`trg_artifact_approval`: approver role ≥ engineer; once set, `approved_by/at` cannot change (a new version is created instead); audit row with the artefact digest (NFR-05).

### ADR-Q10 — Closed cases become precedent only after verification; the golden set gates releases
`trg_case_close` requires actions verified/cancelled and inserts the `knowledge.case_record` with `outcome`; retrieval ranks verified outcomes higher (FR-29). Every change to prompts, ranking or the model re-runs the golden set; top-3 rate < 60 % or any fabricated evidence blocks release (AI-05).

---

## 8. Quality attribute scenarios
| ID | Attribute | Scenario | Response | Trace |
|---|---|---|---|---|
| QAS-01 | Correctness | Reference X̄-R dataset | Limits and Cp/Cpk equal the reference to 1e-6 | AC-01, TC-020 |
| QAS-02 | Correctness | Series with each Nelson pattern | Each rule detected with the right points | AC-02, TC-022 |
| QAS-03 | Honesty | Non-normal characteristic | Warning; no naive Cpk; method recommended | AC-03, TC-024 |
| QAS-04 | Hypothesis quality | 20 golden incidents | True cause in top-3 ≥ 60 %; fabricated evidence 0 | AC-04, TC-047 |
| QAS-05 | Groundedness | Draft with an untraced number | Grounding failed; approval refused; sentence listed | AC-05, TC-060 |
| QAS-06 | Governance | Export of an unapproved draft | DRAFT watermark on every page | AC-06, TC-080 |
| QAS-07 | Localisation | Japanese 品質報告書 | Template sections; glossary terms; native review pass | AC-07, TC-066 |
| QAS-08 | Correctness | Effectiveness on a real improvement and a control | Verified vs "no significant improvement" | AC-08, TC-072 |
| QAS-09 | Availability | Ollama stopped | Charts, tests, correlations work; drafts 503 | AC-09, TC-090 |
| QAS-10 | Latency | 90-day chart; 30-day × 6-factor analysis; 8D draft | ≤ 2 s; ≤ 20 s; ≤ 90 s | NFR-01…03, TC-100…102 |
| QAS-11 | Governance | Viewer tries to approve; approver edits an approval | Refused; refused; audited | NFR-05, TC-081, TC-082 |
| QAS-12 | Honesty | Limits recalculated | New limit row with reason; old kept; chart shows the change | FR-06, TC-025 |

---

## 9. Platform mode
- Database: the `quality_0001` extension on the platform database; `core`, `knowledge`, `vision.model_registry`, `audit` shared. MoldMind (11) shares the `quality.mould/shot/shot_part` tables; QE-Agent reads them for correlation (mould id, shot parameters).
- API: SRS paths under `/api/v1`; the platform's `/spc/chart`, `/spc/capability`, `/signals`, `/cases`, `/cases/{id}`, `/cases/{id}/analyze`, `/cases/{id}/artifacts/{kind}`, `/knowledge/search` served by the gateway verbatim (API-09 §1).
- Tools (IF-16): platform `get_spc`, `query_defects`, `search_memory`, `create_draft_report`; QE adds `get_capability`, `get_signals`, `get_case`, `get_hypotheses` (read-only, `agent_ro`).
- Bus (IF-17): HIGH signals and closed cases published for KaizenSwarm (13); Genba Memory (15) is the archive the indexer writes to.
- Model: platform Ollama with the GPU semaphore; prompts remain QE's versioned files.

## 10. Risks and technical debt
| Risk (SRS §10) | Design response | Residual |
|---|---|---|
| Statistically wrong output | ADR-Q01, SQL twins, statistics-only fallback | Reference set coverage |
| Spurious correlations as causes | §6 | Confounded factors |
| Rubber-stamping | DRAFT watermark, claim trace, rating confirmation, revisions | An engineer approving without reading (audited) |
| Poor data quality | data-quality report before analysis; code normalisation | Coverage of defect-code mapping |
| Japanese register | glossary + template + native review gate | Reviewer availability |
| Standard mismatch | `fmea_config.standard` | Mixed-standard history |

Debt: scipy/statsmodels not on the authoring machine (closed-form Python references used for the seed checks); the golden set is real incidents outside the repository; native-speaker review is a process, not a test; chart images rendered server-side only.

## 11. Traceability to SRS-09
| SRS | Where |
|---|---|
| C-01…C-05 | §3.1, ADR-Q05…Q09 |
| FR-01…FR-07 | §4.3.2, ADR-Q04, Q05 |
| FR-08…FR-12 | §4.3.3 |
| FR-13…FR-18 | §4.3.4, §6, ADR-Q06 |
| FR-19…FR-26 | §4.3.5, ADR-Q02, Q03, Q07, Q08 |
| FR-27…FR-31 | §4.3.6, ADR-Q10 |
| AI-01…AI-08 | §2, §4.3.5, §4.4, ADR-Q01…Q03, Q07, Q10 |
| NFR-01…NFR-09 | §3.2, §4.5, §5 |
| AC-01…AC-09 | §8 |
