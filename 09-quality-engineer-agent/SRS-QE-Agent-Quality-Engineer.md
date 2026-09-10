# Software Requirements Specification — AI Manufacturing Quality Engineer Agent

| Field | Value |
|---|---|
| Document ID | SRS-09-QEAgent |
| Project code name | **QE-Agent** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify an AI agent that performs the **routine analytical work of a quality engineer**: watch defect trends and SPC signals, propose probable causes from process data, and draft the standard quality artefacts — 5-Why, 8D, FMEA updates and a Japanese-style quality report — for a human engineer to verify and own.

### 1.2 Scope

**In scope**
- SPC engine: X̄-R, X-mR, p, np, c, u charts; Nelson/Western Electric rules.
- Process capability: Cp, Cpk, Pp, Ppk with normality checks.
- Defect trend detection and change-point identification.
- Contextual correlation: material lot, machine, mould/tool, operator group, shift, parameter change.
- Draft generation: 5-Why, 8D (D1–D8), FMEA row proposals with S/O/D and RPN/AP.
- Report generation in Thai / Japanese / English.
- Case management with human approval and evidence links.

**Out of scope**
- Being the official system of record for quality approvals unless the organisation formally adopts it.
- Automatic FMEA approval or control-plan changes (drafts only).
- Vision inspection itself (SRS-01/03) and machine telemetry (SRS-06) — consumed as inputs.

### 1.3 Definitions
| Term | Meaning |
|---|---|
| 5-Why | Iterative causal questioning technique |
| 8D | 8-discipline problem-solving report (D1 team … D8 closure) |
| FMEA / AP | Failure Mode & Effects Analysis / Action Priority (AIAG-VDA) |
| S, O, D | Severity, Occurrence, Detection ratings |
| Cp / Cpk | Process capability / capability accounting for centring |
| OCAP | Out-of-Control Action Plan |
| 不良率 | Defect rate (JA) |

---

## 2. Overall Description

### 2.1 Product perspective
```
Inspection data ─┐
Production data  ├─►  Quality Data Layer  ──►  SPC & Capability Engine
Machine params   │                                  │  charts · violations · Cpk
Material lots    │                                  ▼
Maintenance log ─┘                          Signal Detector
                                        (shift · trend · change-point)
                                                    ▼
                                        Correlation Analyser
                                (lot · machine · mould · shift · parameter change)
                                                    ▼
                                    Knowledge Retrieval (past 8D / FMEA / OCAP)
                                                    ▼
                                            LLM Agent (drafting)
                                                    ▼
                            5-Why · 8D draft · FMEA rows · report (TH/JA/EN)
                                                    ▼
                                    Engineer review → approve → case record
```

### 2.2 User classes
| Class | Need |
|---|---|
| Quality engineer | analysis support, draft artefacts, evidence |
| QC supervisor | daily signals, containment status |
| Production engineer | parameter/process correlation |
| Japanese management | 品質報告書 in correct form and language |
| Customer-facing QA | 8D for customer complaints |
| Admin | rules, chart configs, FMEA library |

### 2.3 Operating environment
Docker on-prem, PostgreSQL + pgvector, Python analytics (pandas/scipy/statsmodels), local LLM ≤ 9 B via Ollama, Next.js UI, export to DOCX/XLSX/PDF.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | Every AI-produced artefact SHALL be marked **DRAFT — AI generated** until a named engineer approves it. |
| C-02 | All statistics SHALL be computed by the analytics engine; the LLM writes prose around given numbers only. |
| C-03 | Capability indices SHALL NOT be reported without a stated sample size, subgroup structure and normality assessment. |
| C-04 | Causal language SHALL be reserved for verified causes; unverified items are "hypotheses to verify". |
| C-05 | FMEA drafts SHALL follow the organisation's chosen standard (AIAG-VDA AP or classic RPN), configurable. |

### 2.5 Assumptions
Defect data is coded consistently; process parameters and lot genealogy are recorded and joinable by time/lot; historical 8D/FMEA documents exist and can be indexed.

---

## 3. Functional Requirements

### 3.1 SPC & capability
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Compute X̄-R, X-mR, p, np, c and u charts with control limits derived from a configurable baseline period. | Must |
| FR-02 | Detect Nelson rules 1–8 (minimum 1, 2, 3, 5, 6) and label each violation with rule id and points involved. | Must |
| FR-03 | Support subgroup definition by time window, batch or fixed n, configured per characteristic. | Must |
| FR-04 | Compute Cp, Cpk, Pp, Ppk with a normality test (Anderson–Darling) and warn when the assumption fails. | Must |
| FR-05 | Recommend a transformation or non-normal method when normality fails, rather than silently reporting Cpk. | Should |
| FR-06 | Recalculate limits on demand and record limit history (who changed, when, why). | Must |
| FR-07 | Provide chart export as an image/CSV for reports. | Must |

### 3.2 Signal detection
| ID | Requirement | Priority |
|---|---|---|
| FR-08 | Detect defect-rate changes vs 7/30-day baselines with a two-proportion test and report the p-value. | Must |
| FR-09 | Detect change points (e.g. CUSUM/binary segmentation) and report the estimated change timestamp. | Must |
| FR-10 | Rank open signals by severity: customer impact, defect class criticality, volume affected and trend slope. | Must |
| FR-11 | Suppress signals below a minimum-sample threshold and during declared trial runs. | Must |
| FR-12 | Open a quality case automatically for HIGH signals and notify the owner. | Should |

### 3.3 Correlation & hypothesis generation
| ID | Requirement | Priority |
|---|---|---|
| FR-13 | For a given signal, test association between the defect and: material lot, machine, mould/tool id, shift, operator group, SKU, and recent parameter changes (chi-square / Fisher / rate comparison). | Must |
| FR-14 | Report effect size and confidence, not only significance, and explicitly warn about multiple-comparison risk. | Must |
| FR-15 | Correlate the change point with a timeline of events: lot change, maintenance, tool change, parameter edit, personnel change, environment. | Must |
| FR-16 | Retrieve similar historical cases via vector search over past 8D/RCA documents and rank by similarity + outcome. | Must |
| FR-17 | Produce a ranked hypothesis list, each with supporting evidence, contradicting evidence and a proposed verification step. | Must |
| FR-18 | Explicitly state when no factor shows a meaningful association. | Must |

### 3.4 Artefact drafting
| ID | Requirement | Priority |
|---|---|---|
| FR-19 | Draft a 5-Why chain from the top hypothesis, marking each level as verified/unverified with its evidence. | Must |
| FR-20 | Draft an 8D report covering D1–D8, with D3 containment, D4 root cause, D5 corrective action, D6 implementation, D7 prevention and D8 closure placeholders. | Must |
| FR-21 | Propose FMEA updates: new/edited failure mode rows with S/O/D justification and resulting RPN or AP, linked to the case evidence. | Must |
| FR-22 | Propose control-plan / OCAP updates as suggestions requiring approval. | Should |
| FR-23 | Every drafted claim SHALL cite its evidence (query, chart, case id, document chunk). | Must |
| FR-24 | Drafts SHALL be editable in the UI with change tracking and a diff against the AI version. | Must |
| FR-25 | Export artefacts to DOCX/XLSX/PDF using the company template. | Must |
| FR-26 | Generate the Japanese quality report using appropriate technical register and standard section names (現象・原因・対策・効果確認・水平展開). | Must |

### 3.5 Case management
| ID | Requirement | Priority |
|---|---|---|
| FR-27 | A quality case SHALL track: signal, owner, status, containment, actions with due dates, verification and closure. | Must |
| FR-28 | Effectiveness verification SHALL compare the defect rate before/after the action with a significance test and record the result. | Must |
| FR-29 | Closed cases SHALL be indexed into the knowledge base for future retrieval. | Must |
| FR-30 | Horizontal deployment (水平展開) candidates — similar lines/SKUs/moulds — SHALL be suggested at closure. | Should |
| FR-31 | Overdue actions SHALL be escalated via notification. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/spc/chart?char=&line=&from=&to=` | chart data + violations |
| GET | `/api/v1/capability?char=&line=&period=` | Cp/Cpk + normality |
| GET | `/api/v1/signals?status=open` | ranked signals |
| POST | `/api/v1/cases` | open a case |
| POST | `/api/v1/cases/{id}/analyze` | run correlation + hypotheses |
| POST | `/api/v1/cases/{id}/draft/{artifact}` | 5why \| 8d \| fmea \| report |
| POST | `/api/v1/cases/{id}/approve` | engineer approval |
| GET | `/api/v1/knowledge/search?q=` | past-case retrieval |

### 4.2 Data sources
Inspection DB (SRS-01/03), production facts (SRS-02), machine telemetry (SRS-06), material lot genealogy, maintenance log, quality document archive (SRS-15).

---

## 5. Data Requirements

```sql
characteristic(id, sku_id, name, unit, usl, lsl, target, chart_type, subgroup_rule)
measurement_series(ts, characteristic_id, line_id, subgroup_id, value, lot, machine_id)
control_limits(id, characteristic_id, ucl, cl, lcl, baseline_from, baseline_to,
               created_by, reason, active)
spc_violation(id, characteristic_id, ts, rule, points_json, severity)
signal(id, opened_at, kind, scope_json, statistic_json, severity, status)
quality_case(id, signal_id, opened_at, title, owner, status, severity,
             sku_id, line_id, closed_at)
hypothesis(id, case_id, statement, evidence_json, contra_json, score, status)
artifact(id, case_id, kind, version, content_json, ai_generated, approved_by,
         approved_at, exported_uri)
action(id, case_id, kind, description, owner, due_date, status, effectiveness_json)
fmea_row(id, sku_id, process_step, failure_mode, effect, cause, control_prev,
         control_det, s, o, d, rpn, ap, source_case_id, approved_by)
knowledge_doc(id, kind, title, lang, uri)
knowledge_chunk(id, doc_id, text, embedding vector(1024))
```

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Statistics are computed in Python (scipy/statsmodels); the LLM receives a structured facts object and never raw computation duties. |
| AI-02 | Retrieval over past cases SHALL use a multilingual embedding (TH/JA/EN) with hybrid BM25 + vector search and reranking. |
| AI-03 | Drafting model: local instruct model ≤ 9 B, temperature ≤ 0.3, prompt templates versioned in git per artefact type and language. |
| AI-04 | Every generated sentence containing a number or a causal claim SHALL be traceable to an evidence id; untraceable content is a release-blocking defect. |
| AI-05 | Golden set: ≥ 20 historical incidents with known root causes. Target: the true cause appears in the agent's top-3 hypotheses in **≥ 60 %** of cases; fabricated evidence rate 0 %. |
| AI-06 | Japanese output SHALL be reviewed against a terminology glossary (社内用語) enforced by a term-consistency check. |
| AI-07 | S/O/D proposals SHALL be justified by referenced criteria tables, not invented; the engineer must confirm each rating. |
| AI-08 | The agent SHALL degrade to statistics-only mode (charts, tests, correlations, no prose) if the LLM is unavailable. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | SPC chart for 90 days of data ≤ 2 s p95. |
| NFR-02 | Correlation analysis over 30 days across 6 factors ≤ 20 s. |
| NFR-03 | 8D draft generation ≤ 90 s on the baseline GPU. |
| NFR-04 | Statistical correctness verified against reference datasets (Minitab/NIST examples) within 1e-6. |
| NFR-05 | RBAC: only role `quality_engineer` and above may approve artefacts; approvals are immutable and audited. |
| NFR-06 | Drafts, edits and approvals versioned; any exported document identifies its version and approver. |
| NFR-07 | Full local operation; no quality data leaves the LAN. |
| NFR-08 | ≥ 85 % unit-test coverage on the SPC/capability engine. |
| NFR-09 | UI and exports fully localised TH/JA/EN including chart labels. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Control limits and Cp/Cpk match NIST/Minitab reference examples to 1e-6. |
| AC-02 | Nelson rule detection verified against a constructed dataset containing each rule pattern. |
| AC-03 | Non-normal data triggers a warning and suppresses a naive Cpk claim. |
| AC-04 | Golden set: true root cause in top-3 for ≥ 60 % of 20 historical incidents. |
| AC-05 | Every number in a generated 8D traces to a query result (automated evidence audit). |
| AC-06 | An unapproved draft can never be exported without the DRAFT watermark. |
| AC-07 | Japanese 品質報告書 export matches the company template and passes a native-speaker review. |
| AC-08 | Effectiveness verification correctly detects a real post-action improvement and correctly reports "no significant improvement" on a control case. |
| AC-09 | With Ollama stopped, charts, tests and correlations still work. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | data layer, characteristics, subgroups, chart engine |
| P2 | 3–4 | Nelson rules, capability, normality, limit history |
| P3 | 5–6 | signal detection, change points, severity ranking, cases |
| P4 | 7–8 | correlation analyser, event timeline, hypothesis ranking |
| P5 | 9–10 | knowledge indexing + retrieval of past 8D/FMEA |
| P6 | 11–13 | drafting (5-Why, 8D, FMEA, report), evidence citations, exports |
| P7 | 14–15 | JA/TH localisation, golden-set validation, approval workflow |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Statistically wrong output damages credibility | reference-dataset verification, high test coverage, statistics-only fallback |
| Spurious correlations presented as causes | effect size + multiple-comparison warning + "hypothesis to verify" wording |
| Engineers rubber-stamp AI drafts | DRAFT watermark, per-claim evidence, required rating confirmation, change tracking |
| Poor data quality (defect codes inconsistent) | code normalisation layer + data-quality report before analysis |
| Japanese register wrong for management | glossary enforcement + template + native review gate |
| Standard mismatch (RPN vs AP) | configurable FMEA method per organisation |

---

## Appendix A — Example hypothesis output (EN)

```
Signal S-241 · Scratch defect  Line 4 · 0.52 % → 3.18 % (p < 0.001)
Change point estimated 2026-09-08 14:20 (±40 min)

Hypotheses (ranked)
1. Material lot change  — score 0.71
   Supporting : lot LOT-2609-114 started 14:12; defect rate on that lot 4.9 %
                vs 0.6 % on other lots in the same window (Fisher p < 0.001, n=1,880)
   Contra     : incoming inspection recorded no abnormality
   Verify     : re-inspect retained sample of LOT-2609-114 surface condition
2. Mould surface condition — score 0.38
   Supporting : mould M-12 last polished 62 days ago (plan: 45); scratch rate on M-12
                2.1× other moulds over 30 days
   Contra     : rise is abrupt, mould wear is usually gradual
   Verify     : inspect mould M-12 cavity surface
3. Shift B handling — score 0.19
   Supporting : 68 % of defects in Shift B
   Contra     : Shift B also ran 61 % of the volume in the window — weak effect
   Verify     : observe part handling at unload station

No meaningful association found for: machine, operator group, ambient temperature.
Similar past cases: #212 (2025-03) material contamination → confirmed;
                    #178 (2024-11) mould polish overdue → confirmed.
```
