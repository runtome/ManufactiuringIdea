# Database Design Specification — QE-Agent (AI Manufacturing Quality Engineer Agent)

| Field | Value |
|---|---|
| Document ID | DDS-09-QEAgent |
| Version | 1.0 (Draft) |
| Date | 2026-09-15 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`db/schema.sql`](../db/schema.sql) (DDL, 1,574 lines) · [`db/seed_demo.sql`](../db/seed_demo.sql) (demo data + probes) |
| Related | [SRS-09](../SRS-QE-Agent-Quality-Engineer.md) §5 · [SAD-09](SAD-QEAgent-Software-Architecture.md) ADR-Q01…Q10 · [API-09](../api/API-Specification.md) · [ICD-09](ICD-QEAgent-Interface-Control.md) IF-51 · [SEC-09](SEC-QEAgent-Security-Requirements.md) · [TEST-09](TEST-QEAgent-Test-Plan.md) TS-0 · platform: [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify the QE-Agent database: the platform's `quality` schema reproduced byte-for-byte, the extension (migration `quality_0001`) that adds measurements, the **evidence registry**, claim tracing, correlation results, exports with watermarks, FMEA proposals with criteria references, effectiveness checks and the golden set — and the constraints that turn SRS-09's C-01…C-05, NFR-05, AI-04, AI-05 and AI-07 into properties of the data.

### 1.2 What is different from the other databases in this repository
- **Statistics have SQL twins.** `xbar_r_limits`, `p_limits`, `capability_indices`, `two_proportion_z` and `nelson_rules` are implemented in SQL/plpgsql beside the Python engine. They are not the production engine (that is `spc-engine`, with scipy and the reference suite); they are independent checks that the seed and TC-020…TC-022 use, and a second opinion an auditor can run in `psql`.
- **The evidence registry is the model's only input.** `evidence` rows hold every value an artefact may quote, with a digest; `artifact_claim` links each numeric or causal sentence to a row; the approval trigger reads the roll-up. Nothing in the schema lets prose become a fact without that link (DD-Q01, DD-Q02).
- **Ownership is enforced, not displayed.** DRAFT watermarks, role-gated immutable approvals, per-rating FMEA confirmation, effectiveness-gated verification and closure-gated indexing are triggers (DD-Q02, Q03, Q08, Q09).
- **Shared with MoldMind.** `quality.mould`, `quality.shot`, `quality.shot_part` belong to the same platform section (SRS-11 owns their content); QE-Agent reads them for mould correlation and keeps them byte-identical.

### 1.3 Engine and extensions
PostgreSQL 16; `pgcrypto` (digests), `vector` (case-record embeddings for retrieval), `pg_trgm` (lexical half of hybrid retrieval), `btree_gin` — the platform's four extension lines. **Not executed on the authoring machine** (no Docker daemon); byte-identity, static checks and Python re-derivations stand in until TC-009 runs.

### 1.4 Assembly and byte identity
`db/schema.sql` is assembled by marker extraction from `00/db/schema.sql`: extensions (23–26), helpers (63–104), enums (110–120: `core.shift_code`, `core.language_code`, `vision.verdict`, `vision.model_stage`, `quality.case_status/severity/artifact_kind/chart_type`), `core.plant/line/sku` (144–174), `core.machine/defect_type/material_lot` (176–213), `core.app_user/user_line_scope` (228–256), `vision.model_registry`, all of `quality.*` (section 7), `knowledge.document/chunk/case_record/case_source/case_chunk/glossary_term`, `audit.*`, the quality indexes, seven knowledge indexes, the five core `updated_at` triggers. TC-002 diffs every object present in both files: **72/72 byte-identical**. The extension only adds: new tables, `ALTER TABLE … ADD COLUMN` on `signal`, `hypothesis`, `artifact` (nullable or defaulted), functions, triggers, views, roles.

---

## 2. Design principles
| # | Principle | Mechanism |
|---|---|---|
| **DD-Q01** | **Every number and every causal sentence is traced.** | `evidence` (case-scoped, coded `E-nn`, `value_json`, `digest`); `artifact_claim(kind, evidence_id, hypothesis_id)`; `trg_claim_check` sets `traced` (numeric/date/count ⇒ evidence; causal ⇒ a **confirmed** hypothesis); `trg_claim_rollup` maintains `artifact.claims_total/untraced/grounding_status` (C-02, FR-23, AI-04, AC-05) |
| **DD-Q02** | **Approval is role-gated, grounding-gated, immutable and audited.** | `trg_artifact_approval`: approver role ≥ `engineer`; `grounding_status = passed` for AI artefacts; `term_violations = 0`; once approved, `approved_by/at` and `content_json` frozen (new version instead); audit row with content and facts digests (C-01, NFR-05, AI-06) |
| **DD-Q03** | **DRAFT is a constraint.** | `export.watermark ∈ {'DRAFT — AI generated', 'APPROVED'}`; `trg_export_watermark` forces DRAFT for unapproved artefacts, stamps `version_stamp = v<version>.<revision>` and the approver; audited (C-01, NFR-06, AC-06) |
| **DD-Q04** | **No capability index without its context.** | Platform `capability_result` requires `n`, `period_*`, `normality_ok`; `trg_capability_note` requires a method note when normality fails (C-03, FR-05, AC-03) |
| **DD-Q05** | **Limits are history.** | `trg_limits_append_only`: insert deactivates the previous active row, writes an audit row with the reason; updates other than `active` and deletes are refused (FR-06) |
| **DD-Q06** | **Hypotheses are hypotheses.** | `trg_hypothesis_wording`: causal phrases (EN/JA/TH) refused unless `status = confirmed`; `verify_step` mandatory; confirmation records verifier and time; `hypothesis_evidence` links supporting/contra/verify evidence (C-04, FR-17) |
| **DD-Q07** | **Signals are admissible or suppressed, never silently dropped.** | `trg_signal_admissible`: `n < ranking_config.min_sample` or inside a `trial_run` ⇒ `status = dismissed` with `suppressed_reason` (FR-11) |
| **DD-Q08** | **FMEA ratings come from criteria and are confirmed one by one.** | `fmea_proposal` with `s/o/d_criteria_id` and `s/o/d_confirmed_by`; `trg_fmea_confirm` checks each criteria row matches the active standard, dimension and value, each confirmer is an engineer, derives AP from `fmea_config.ap_table_json`, then writes `fmea_row` (RPN generated by the platform) and audits (C-05, FR-21, AI-07) |
| **DD-Q09** | **Verification and closure are gated; closure creates precedent.** | `trg_action_verified`: `verified` only with `effectiveness_json.improved = true`; `trg_case_close`: no open actions, closure note, then `knowledge.case_record` (outcome resolved/not_resolved) and `suggest_horizontal()` (FR-27…FR-30) |

---

## 3. Schema overview
58 tables (8 `core`, 1 `vision`, 41 `quality` — 15 platform + 26 extension, 6 `knowledge`, 2 `audit`), 11 views, 20 triggers (5 platform `updated_at` + 15 guards), 28 functions (2 helpers, 11 business, 15 trigger functions), 41 indexes, 13 enums, 5 roles.

| Group | Tables |
|---|---|
| Platform `core` | `plant`, `line`, `sku`, `machine`, `defect_type`, `material_lot`, `app_user`, `user_line_scope` |
| Platform `vision` | `model_registry` (target of `artifact.model_id`) |
| Platform `quality` | `characteristic`, `control_limits`, `spc_violation`, `capability_result`, `signal`, `case`, `case_step`, `hypothesis`, `artifact`, `action`, `fmea_row`, `mould`, `shot`, `shot_part`, `timeline_event` |
| Platform `knowledge` | `document`, `chunk`, `case_record`, `case_source`, `case_chunk`, `glossary_term` |
| Data layer | `subgroup`, `measurement`, `rule_config`, `trial_run` |
| Configuration | `ranking_config`, `fmea_config`, `sod_criteria`, `prompt_template`, `migration` |
| Analysis | `analysis_run`, `change_point`, `correlation_test`, **`evidence`**, `hypothesis_evidence` |
| Artefacts | `artifact_claim`, `artifact_revision`, `export`, `term_check`, `fmea_proposal`, `ocap_suggestion` |
| Case management | `effectiveness_check`, `horizontal_candidate`, `escalation` |
| Golden set | `golden_incident`, `golden_run`, `golden_result` |
| Audit | `audit.log`, `audit.auth_event` |

### 3.1 ERD (the analysis-to-artefact spine)
```
measurement ─< subgroup ─► control_limits (append-only) · spc_violation (rule, points) · capability_result (n, normality_ok, method_note)
signal (statistic_json, score, suppressed_reason) ─< change_point · correlation_test (p, p_adjusted, effect_size, n, meaningful)
   └─ case ─< analysis_run (mode, llm_available)
         ├─< evidence (code, kind, value_json, digest)  ◄── hypothesis_evidence >── hypothesis (rank, score, status, verify_step, verified_by)
         ├─< artifact (kind, lang, version, revision, grounding_status, approved_by) ─< artifact_claim (kind, evidence_id | hypothesis_id, traced)
         │        ├─< artifact_revision (diff)   ├─< export (watermark, version_stamp, approved_by_stamp)   └─< term_check ── knowledge.glossary_term
         ├─< fmea_proposal (s/o/d + criteria + confirmers) ─► fmea_row (rpn generated, ap)      ├─< ocap_suggestion
         ├─< action ─< effectiveness_check (before/after, z, p, improved)                        ├─< horizontal_candidate
         └─ closed ─► knowledge.case_record (outcome) ─< case_chunk (embedding)                    └─< escalation
golden_incident ─< golden_result >── golden_run (top3_rate, release_blocked)
```

---

## 4. Table specifications (the ones that carry rules)

### 4.1 `measurement`, `subgroup`, `rule_config`, `trial_run`
`measurement` (SRS `measurement_series`): ts, characteristic, line, `subgroup_id`, value, lot, machine, shift, source. `subgroup`: seq, window, n, mean, range, sd — the pre-aggregation that keeps NFR-01. `rule_config.enabled_rules` with CHECK `⊇ {1,2,3,5,6}` and `⊆ {1..8}` (FR-02). `trial_run`: declared windows with a reason and declarer (FR-11).

### 4.2 `signal` (+ extension), `change_point`, `correlation_test`
Platform `signal.statistic_json` holds p-value, effect size, baseline and n ("the agent may only quote values present here"); extension adds `score`, `rank_components`, `suppressed_reason`, `defect_code`, `owner_id`. `change_point`: estimated time, ± window, method, statistic. `correlation_test`: factor, level, test, statistic, `p_value`, **`p_adjusted`** (Benjamini–Hochberg), effect measure/size with CI, n, the table, `meaningful` (FR-13, FR-14, FR-18).

### 4.3 `evidence`, `hypothesis` (+ extension), `hypothesis_evidence`
`evidence`: `UNIQUE (case_id, code)`; `digest = sha256(value_json::text)`; `source_query`/`source_ref` say where the value came from. `hypothesis` (platform: statement, score, evidence_json, contra_json, verify_step, status) + rank, run, effect size, adjusted p, factor/level, verifier and result. `hypothesis_evidence` typed links.

### 4.4 `artifact` (+ extension), `artifact_claim`, `artifact_revision`, `export`, `term_check`
Platform `artifact` (kind, version, lang, content_json, ai_generated, prompt_version, approved_by/at, exported_uri) + `grounding_status`, `claims_total`, `claims_untraced`, `term_violations`, `facts_digest`, `revision`, `run_id`, `prompt_template_id`. `artifact_claim`: ordinal, section, sentence, kind, evidence/hypothesis, `traced`. `artifact_revision`: revision, content, diff, editor (revision 1 = the AI version). `export`: format, template, uri, sha256, **watermark**, **version_stamp**, approver stamp. `term_check`: found/expected text against the glossary.

### 4.5 `fmea_config`, `sod_criteria`, `fmea_proposal`, `ocap_suggestion`
One active `fmea_config` (standard + AP table). `sod_criteria` rows per (standard, dimension, rating). `fmea_proposal`: the row content, three ratings each with a criteria reference, an optional evidence justification and a confirmer; `status` and the resulting `fmea_row_id`. `ocap_suggestion` with evidence and a decision.

### 4.6 `action` (platform), `effectiveness_check`, `horizontal_candidate`, `escalation`
`effectiveness_check`: before/after windows and counts, z, p, rates, `improved` (p < 0.05 and rate fell); `trg_effectiveness_apply` writes the platform's `action.effectiveness_json`. `horizontal_candidate`: target line/SKU/mould with reason and decision. `escalation`: HIGH signals, overdue actions, grounding failures, case opened; channel and delivery.

### 4.7 `golden_incident`, `golden_run`, `golden_result`, `prompt_template`, `analysis_run`
Golden incidents with the true cause and factor; runs with model/prompt/ranking versions, `n ≥ 20`, hits, `fabricated`, computed `top3_rate` and `release_blocked` (AI-05). `prompt_template`: kind × lang × version, path, checksum, `temperature ≤ 0.3` (AI-03), one active per pair. `analysis_run`: mode `full`/`statistics_only` consistent with `llm_available` (CHECK), model and prompt versions, timings, counts (AI-08).

---

## 5. Functions
| Function | Role |
|---|---|
| `spc_constant(n, name)` | A2, D3, D4, d2 for n = 2…10 (ASTM E2587 / Montgomery) |
| `xbar_r_limits(X̿, R̄, n)` | UCL/CL/LCL for X̄ and R, `sigma_within = R̄/d2` (FR-01) |
| `p_limits(p̄, n)` | p-chart limits clamped to [0, 1] |
| `capability_indices(mean, sd_within, sd_overall, USL, LSL)` | Cp, Cpk, Pp, Ppk (FR-04) |
| `norm_sf(z)` | Standard normal upper tail (Abramowitz–Stegun 7.1.26; max error 7e-8 vs `erfc` — TC-005) |
| `two_proportion_z(x1, n1, x2, n2, continuity)` | Rates, z (continuity-corrected), two-sided p (FR-08, FR-28) |
| `nelson_rules(values, cl, sigma)` | Rules 1, 2, 3, 5, 6 with the 1-based points involved (FR-02, AC-02) |
| `ranking_score(impact, criticality, volume, slope)` | Weighted score from the active `ranking_config` (FR-10) |
| `role_rank(role)` | viewer 0 … admin 4 |
| `artifact_is_draft(artifact)` | approval state |
| `suggest_horizontal(case)` | Inserts line and SKU candidates (FR-30) |

The SQL twins are verification aids: TC-005 recomputes their outputs in Python from the seed's deterministic inputs; the production engine (`spc-engine`) is scipy/statsmodels with the reference suite (NFR-04).

---

## 6. Views
| View | Reader | Content |
|---|---|---|
| `v_open_signals` | supervisors, engineers | ranked open signals with change point and case (FR-10) |
| `v_case_board` | everyone | cases with hypothesis/action/artefact counters |
| `v_evidence_audit` | engineers, audit | per artefact: grounding status, counts, the **untraced sentences** (AC-05) |
| `v_export_watermark` | audit | every export with its watermark, version stamp, approver, and whether the artefact was a draft (AC-06) |
| `v_action_overdue` | supervisors | open actions past due (FR-31) |
| `v_effectiveness` | engineers | before/after tests with the action state (AC-08) |
| `v_golden_summary` | ML owner | runs with rate and block reason (AI-05) |
| `v_limit_history` | engineers, audit | limit rows with reason and author (FR-06) |
| `v_horizontal_candidates` | engineers | suggested targets (FR-30) |
| `v_hypothesis_report` | engineers | the Appendix A shape: rank, score, status, supporting, contra, verify step |
| `v_statistics_only` | ops | runs made without the model (AC-09) |

---

## 7. Sizing and retention
- Measurements: 1 M/month at 10 characteristics × 4 lines × 1 sample/min — 36 M rows over 3 years (BRIN on ts, B-tree per characteristic); subgroups ≈ 1/5.
- Violations, signals, correlation tests: thousands per year. Evidence: ~15 rows per case; claims ~40 per artefact. Case-record embeddings (1024-d) ≈ 4 KB per chunk.
- Retention: measurements 3 y; subgroups/violations 5 y; cases, evidence, artefacts, claims, revisions, exports 10 y (quality records); golden set indefinitely; audit 7 y.

## 8. Roles and grants
| Role | Grants | Used by |
|---|---|---|
| `app_rw` | DML on `core`, `vision`, `quality`, `knowledge`; INSERT/SELECT on `audit` | API |
| **`engine_rw`** | SELECT everywhere; INSERT/UPDATE on analysis objects (measurements, subgroups, limits, violations, capability, signals, change points, correlations, evidence, hypotheses, runs, artefacts, claims, revisions, term checks, proposals, OCAP, effectiveness, candidates, escalations, golden, case records); **no `UPDATE (approved_by, approved_at)` on `artifact`**; INSERT `audit.log` | spc-engine, signal-detector, correlator, drafter, indexer, scheduler |
| **`agent_ro`** | SELECT on `quality`, `knowledge` and master data; **`REVOKE ALL` on `core.app_user`, `core.user_line_scope`** (platform rule) | IF-16 tools |
| `exporter_ro` | SELECT artefacts/revisions/evidence; INSERT `export` and `audit.log` | exporter |
| `app_ro` | SELECT everywhere | support |

---

## 9. Demo and test dataset (`db/seed_demo.sql`)
Deterministic (no `random()`). One plant, four lines, two SKUs, two machines, three moulds, three lots, six users, the ranking and FMEA configuration with 30 S/O/D criteria rows, four prompt templates, three glossary terms. **The statistics run through the SQL twins and the rules through the triggers**; the Python reference (TC-005) recomputes them from the same deterministic inputs.

| Item | Expected |
|---|---|
| **C1 X̄-R (AC-01)** | 125 values from `2.500 + 0.020·sin(1.3·seq + 0.7·k) + 0.005·cos(2.1·k)` → X̿ 2.498951, R̄ 0.031497 → UCLx 2.517125, LCLx 2.480778, UCLr 0.066584, LCLr 0; sd_within 0.013541, sd_overall 0.014536 → Cp 2.4616, Cpk 2.4358, Pp 2.2932, Ppk 2.2692; the provisional July limit row deactivated by the August recalculation (FR-06), audit rows |
| **Nelson (AC-02)** | 40-point constructed series (CL 100, σ 2) → rule 1 {5}, rule 2 {10…18}, rule 3 {20…25}, rule 5 {28, 29}, rule 6 {33, 34, 36, 37} — Python twin agrees |
| **AC-03** | C2 `normality_ok = false`, Ppk 1.08 with the Box-Cox note; a note-less row is probe 6 |
| **Appendix A (S-241)** | 70/2,200 = 3.18 % vs 80/15,400 = 0.52 % → z 12.58, p ≈ 2.6e-36; score 0.35·0.6 + 0.25·0.4 + 0.20·0.35 + 0.20·0.9 = **0.5600**; change point 2026-09-08 14:20 ± 40; 7 factor tests — lot Fisher p 6.7e-9 (BH 4.7e-8), RR 7.67, n 1,880; mould z 3.34, p 8.4e-4 (BH 2.9e-3), 2.1×; shift z 1.20, p 0.23 (BH 0.54), RR 1.39; machine, operator group, ambient, parameter change not meaningful; 14 evidence rows E-01…E-14 with SQL digests; hypotheses 0.71 / 0.38 / 0.19 with supporting/contra/verify; similar cases #212, #178 |
| FR-11 | S-242 (n 25 < 50) and S-243 (inside the trial run) dismissed with reasons |
| **AC-05** | A1 (8D): 12 claims; the D4 causal claim untraced until H1 is confirmed → then `passed`; A2 (5-Why): "fell to 0.3 %" untraced → `failed` (probe 1 cannot approve it) |
| **NFR-05** | A1 approved by the engineer after a revision (v1.2); probes 3 and 4: viewer approval and changing an approval refused |
| **AC-06** | exports: A1 `APPROVED v1.2` with approver; A2 and A3 `DRAFT — AI generated`; probe 2 refuses an `APPROVED` watermark on A2 |
| **AC-07 (shape)** | A3 (ja): 修正措置 flagged against 是正処置 → `term_violations 1` → resolved after the edit |
| **AI-07** | proposal S 7 / O 4 / D 5 confirmed against criteria rows → `fmea_row` rpn 140, AP M; probe 7 refuses confirmation with an unconfirmed rating |
| **AC-08** | QC-0241 corrective: 3.18 % → 0.55 %, z 6.31, p 2.7e-10 → `verified`; QC-0230 polish: 1.58 % → 0.48 %, p 1.3e-4 → verified; retraining control: 0.60 % vs 0.58 % → z 0, p 1.0 → **not improved**, stays `done` |
| **FR-29/30/31** | QC-0230 closed → `case_record` (resolved) + candidates line L4 and SKU PNL-240; QC-0241 has an overdue horizontal action → `v_action_overdue`; probe 8 refuses closing QC-0241 |
| **AI-05** | run 1: 13/20 = 65 %, 0 fabricated → not blocked; run 2: 11/20 = 55 % → `release_blocked` |
| **AC-09** | `analysis_run` for QC-0230: `statistics_only`, `llm_available = false`, 7 tests, 3 hypotheses, 0 artefacts |
| Probes | 8, each fails in its savepoint: untraced approval; APPROVED watermark on a draft; viewer approval; changing an approval; causal wording; non-normal without note; unconfirmed rating; closing with open actions |

Run: `psql -v ON_ERROR_STOP=1 -f db/schema.sql -f db/seed_demo.sql`. **Pending**: PostgreSQL execution (no Docker daemon here) — README-09.

---

## 10. Platform mode
The extension (§10 onward of `schema.sql`) is applied to the platform database as migration `quality_0001`; all `CREATE`s are additive and the three `ALTER TABLE … ADD COLUMN` statements are nullable or defaulted, so API-00 payloads keep working. MoldMind's rows in `mould/shot/shot_part` are read, never written, by QE-Agent. The platform's `agent_ro` already carries the `REVOKE` on users; the migration adds `engine_rw` and `exporter_ro`.

## 11. Traceability
| SRS-09 | Objects |
|---|---|
| C-01, AC-06, NFR-06 | DD-Q03, `export`, `trg_export_watermark`, `artifact_revision` |
| C-02, FR-23, AI-01, AI-04, AC-05 | DD-Q01, `evidence`, `artifact_claim`, `trg_claim_check`, `trg_claim_rollup`, `v_evidence_audit` |
| C-03, FR-04, FR-05, AC-03 | DD-Q04, `capability_result`, `trg_capability_note`, `capability_indices` |
| C-04, FR-17, FR-18 | DD-Q06, `trg_hypothesis_wording`, `hypothesis_evidence`, `correlation_test.meaningful` |
| C-05, FR-21, AI-07 | DD-Q08, `fmea_config`, `sod_criteria`, `fmea_proposal`, `trg_fmea_confirm` |
| FR-01…FR-03, FR-06, FR-07, AC-01 | `measurement`, `subgroup`, `control_limits`, `trg_limits_append_only`, `spc_constant`, `xbar_r_limits`, `p_limits`, `rule_config` |
| FR-02, AC-02 | `spc_violation`, `nelson_rules`, `rule_config` |
| FR-08…FR-12 | `signal` + extension, `change_point`, `ranking_config`, `ranking_score`, `trg_signal_admissible`, `trial_run`, `escalation` |
| FR-13…FR-16 | `correlation_test`, `timeline_event`, `knowledge.case_record`, `case_chunk` |
| FR-19, FR-20, FR-24, FR-25, FR-26, AI-03, AI-06 | `artifact` + extension, `artifact_revision`, `export`, `prompt_template`, `term_check`, `knowledge.glossary_term` |
| FR-22 | `ocap_suggestion` |
| FR-27…FR-31 | `action`, `effectiveness_check`, `trg_action_verified`, `trg_case_close`, `suggest_horizontal`, `v_action_overdue` |
| AI-05 | `golden_*`, `trg_golden_gate` |
| AI-08, AC-09 | `analysis_run`, `v_statistics_only` |
| NFR-05 | DD-Q02, `trg_artifact_approval`, roles |
| NFR-04 | §5 SQL twins |

## Appendix A — The constraints that carry the weight
```
artifact_claim.traced           numeric/date/count ⇒ evidence_id; causal ⇒ confirmed hypothesis              AI-04
trg_artifact_approval           role ≥ engineer ∧ grounding passed ∧ no term violations; then immutable; audited   C-01, NFR-05, AI-06
export.watermark CHECK + trigger draft ⇒ 'DRAFT — AI generated'; version and approver stamped                    C-01, AC-06, NFR-06
trg_capability_note             normality_ok = false ⇒ method_note                                                C-03
trg_hypothesis_wording          causal phrases ⇒ status confirmed; verify_step required                            C-04, FR-17
trg_limits_append_only          insert with reason; deactivate previous; no edit/delete                            FR-06
trg_signal_admissible           n < min_sample or trial run ⇒ dismissed with reason                                FR-11
trg_fmea_confirm                three engineer confirmations against criteria rows ⇒ fmea_row; AP from table       AI-07, C-05
trg_action_verified             verified ⇒ improved = true                                                          FR-28
trg_case_close                  no open actions ∧ note ⇒ case_record + horizontal candidates                        FR-27, FR-29, FR-30
trg_golden_gate                 top-3 < 60 % ∨ fabricated > 0 ⇒ release_blocked                                     AI-05
rule_config CHECK               enabled_rules ⊇ {1,2,3,5,6}                                                         FR-02
prompt_template CHECK           temperature ≤ 0.3                                                                   AI-03
analysis_run CHECK              mode = full ⇔ llm_available                                                         AI-08
```
