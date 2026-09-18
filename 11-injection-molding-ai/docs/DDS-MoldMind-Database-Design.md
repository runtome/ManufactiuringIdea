# Database Design Specification — MoldMind (AI Vision + Agent for Injection Molding)

| Field | Value |
|---|---|
| Document ID | DDS-11-MoldMind |
| Version | 1.0 (Draft) |
| Date | 2026-09-18 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`db/schema.sql`](../db/schema.sql) (2,106 lines) · [`db/seed_demo.sql`](../db/seed_demo.sql) (474 lines) |
| Related | [SRS-11](../SRS-MoldMind-Injection-Molding-AI.md) §5 · [SAD-11](SAD-MoldMind-Software-Architecture.md) §4.6 · [API-11](../api/API-Specification.md) · [ICD-11](ICD-MoldMind-Interface-Control.md) IF-58…IF-61 · [SEC-11](SEC-MoldMind-Security-Requirements.md) · [TEST-11](TEST-MoldMind-Test-Plan.md) TC-002…TC-005, TC-009 · platform: [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) · sibling: [DDS-09](../../09-quality-engineer-agent/docs/DDS-QEAgent-Database-Design.md) |

---

## 1. Introduction

### 1.1 Purpose
MoldMind's promises are physical: a defect belongs to one shot and one cavity; the machine is never written to; a suggested parameter never leaves its documented window; a cause ranking can be read component by component; a fix is called effective only when a test says so; knowledge is sourced and approved before it is used. This document specifies the schema, the guard triggers that make those promises properties of the data, the SQL twins of the analytics used to verify the seed, and the demo dataset that reproduces SRS-11 Appendix A and AC-02…AC-09.

### 1.2 What is different from the other databases in this repository
- **MoldMind owns four platform tables.** `quality.mould`, `quality.shot`, `quality.shot_part` and `quality.timeline_event` (SRS-11 §5 `mould`, `shot`, `shot_part`, `timeline_event`) are extracted byte-identically from the platform's quality section and receive MoldMind's rows; `machine` and `material_lot` of SRS §5 are the platform's `core.machine` and `core.material_lot`.
- **Domain knowledge is rows, not prompt text.** `kb_defect` × `kb_cause` in `kb_version`s with mandatory sources and approval (C-03, AI-08, NFR-08); `deploy/kb/*.yaml` is the reviewable form (ICD-11 IF-59) and the database is what ranks.
- **The scoring function is a SQL function** (`cause_score()`), and `trg_cause_score_transparent` recomputes every stored score from its components — a score the function does not produce is refused (AI-05, AI-06).
- **Windows and ordering are triggers.** `trg_suggestion_window` stores an out-of-window suggestion as `blocked` with an audit row and refuses to store it as allowed (C-05, AI-09, AC-05); `trg_advice_check_first` refuses an action ordered before a check (C-04).

### 1.3 Engine and extensions
PostgreSQL 16; `pgcrypto`, `vector`, `pg_trgm`, `btree_gin` — the platform's four extension lines. TimescaleDB is optional (SAD-00 ADR-007): `quality.shot` works with plain PostgreSQL; OPS-11 §10 gives the hypertable conversion. **Not executed on the authoring machine** (TEST-11 TC-009).

### 1.4 Assembly and byte identity
`db/schema.sql` is assembled by marker extraction from `00/db/schema.sql` (`assemble11.py`): extensions (lines 23–26), helpers (63–104), the enums the extracted sections use (`core.shift_code`, `core.language_code`, `vision.verdict`, `vision.model_stage`, `quality.case_status`, `quality.severity`, `quality.artifact_kind`, `quality.chart_type`), the **whole core section 5**, **whole vision section 6** (partitioned `inspection`, `detection`, `verdict_override` for FR-11, `model_registry` for AI-01), **whole quality section 7** (MoldMind's four tables and QE-Agent's `case`/`hypothesis`/`artifact` for the FR-26 handoff), **whole knowledge section 9** (`case_record`, `glossary_term`), `audit.*`, the core/vision/quality/knowledge/audit indexes, the core `updated_at` triggers and the views `vision.v_inspection_daily`, `vision.v_review_queue`, `knowledge.v_citable_case`. TC-002: **111/111 shared objects byte-identical; the four sections present verbatim**. Agent, telemetry, docflow and ops sections are not extracted.

---

## 2. Design principles

| ID | Principle | Where it lives |
|---|---|---|
| **DD-M01** | **The machine is read-only.** | `machine_connection.credential_kind = read_only` and `SignAndEncrypt` (`trg_machine_readonly`); node maps refuse `access ≠ read` (`trg_node_map_readonly`); `gateway_rw` has `INSERT` only (C-01, NFR-06) |
| **DD-M02** | **Every defect is one shot and one cavity, aligned within tolerance.** | `shot_defect.shot_part_id NOT NULL` + `trg_defect_joinable`; `trg_shot_part_cavity` (cavity ≤ `mould.cavities`, platform `shot_cavity_unique`); `trg_alignment_tolerance` (|image − shot| ≤ tolerance); attribution method stored (C-02, FR-03, FR-08) |
| **DD-M03** | **Startup transients are classified and excluded, never hidden.** | `trg_shot_transient` from `startup_event.transient_shots`; every analysis view filters `NOT startup_transient` (FR-16, AC-06) |
| **DD-M04** | **Every parameter change is a timeline event.** | `trg_parameter_change_event` inserts `quality.timeline_event(kind = parameter_edit)` (FR-04, FR-15) |
| **DD-M05** | **Knowledge is sourced, approved by someone else, immutable once approved, and learns from verified outcomes.** | `kb_cause.source` CHECK; `trg_kb_cause_shape` (checks present; actions carry direction/range/window/side effects); `trg_kb_version_immutable` (author ≠ approver, role ≥ engineer, approved rows frozen); `trg_evidence_writeback` (C-03, AI-08, NFR-08, FR-25) |
| **DD-M06** | **Scores are transparent.** | `rca_cause_score` components ∈ [0,1]; `trg_cause_score_transparent` recomputes from `scoring_config` weights (sum = 1, CHECK) (AI-05, AI-06) |
| **DD-M07** | **Sessions rank with approved knowledge and close with a verdict.** | `trg_rca_session_rules` (approved KB version, active scoring config, verified cause ∈ ranked causes) |
| **DD-M08** | **Checks before changes.** | `rca_advice.kind`; `action_is_complete` CHECK; `trg_advice_check_first` (C-04, FR-22, FR-23) |
| **DD-M09** | **Windows are enforced; effectiveness is computed.** | `parameter_window` + `trg_suggestion_window` (blocked + audit; asserted `allowed` refused); `trg_action_effective` (two-proportion test, `effective` never typed); `trg_cavity_flag`, `trg_vision_gate`, `trg_golden_gate` likewise computed (C-05, AI-09, AC-05, FR-24, AC-07, FR-12, AI-02, AI-07) |

## 3. Schema overview
| Schema | Owner | Contents here |
|---|---|---|
| `core` | platform | plant, line, sku, **machine**, defect_type, **material_lot**, shift_calendar, app_user, user_line_scope, production facts |
| `vision` | platform | model_registry (AI-01 families), camera, recipe, inspection (partitioned), detection, measurement, **verdict_override** (FR-11), drift_metric; `v_inspection_daily`, `v_review_queue` |
| `quality` | platform; **MoldMind owns `mould`, `shot`, `shot_part`, `timeline_event`** | the SPC/case/FMEA section (QE-Agent's `case`/`artifact` receive the 8D handoff) |
| `knowledge` | platform (Genba Memory) | document, chunk, case_record, glossary_term (FR-27); `v_citable_case` |
| `audit` | platform | log (blocked suggestions land here), auth_event |
| `moldmind` | **this module** | 28 tables, 11 functions, 19 guard triggers, 14 views (§4–§6) |

Counts (TC-003): **77 tables / 17 views / 25 triggers / 32 functions / 60 indexes / 15 enums**.

### 3.1 ERD (the shot-to-knowledge spine)
```
core.machine ── moldmind.machine_connection (read-only credential) ──< node_map_version · gateway_batch
      │
quality.shot (params_json, cushion, cycle) ── 1 moldmind.shot_ext (context, dq flags, startup_transient)
      │                                         ▲ startup_event
      └──< quality.shot_part (cavity_no ≤ mould.cavities) ── 1 moldmind.image_alignment (tolerance, method) ── vision.inspection
                  └──< moldmind.shot_defect (class, region, confidence, ΔE, review verdict)      vision.verdict_override
quality.mould ──< setup_sheet_version (golden run) · parameter_window (mould × material × parameter) · cavity_flag
moldmind.parameter_change ──trg──> quality.timeline_event(parameter_edit)
kb_version (draft → approved, immutable) ──< kb_cause (prior, typical params, checks, actions, source) ──< kb_case_evidence
scoring_config (weights Σ = 1) ── rca_session ──< rca_cause_score (components + score) · rca_turn · rca_advice (check < action) · parameter_suggestion (allowed | blocked) · action_outcome (z, p, effective)
rca_session ──> quality.case + quality.artifact(eight_d)   (FR-26 handoff)
```

## 4. Table specifications (the ones that carry rules)

### 4.1 `machine_connection`, `node_map_version`, `gateway_batch` (IF-05)
Protocol (`opcua_euromap77` | `euromap63_file` | `mqtt`), endpoint, security policy, **`credential_ref` (a secret file name) and `credential_kind` (must be `read_only`)**, `buffer_hours ≥ 24` (NFR-05). Node maps are versioned JSON (`node_id`, `signal`, `unit`, `access = read`) with a checksum and `validated_at`; `active` one at a time. `gateway_batch` records an outage and its reconciliation: `shots_inserted + duplicates = shots_buffered` once `reconciled_at` is set (AC-09).

### 4.2 `shot_ext`, `startup_event`, `image_alignment`, `shot_defect`, `colour_reference`
`shot_ext` extends the platform shot with FR-02 context (SKU, cavity count, regrind %, dryer temperature/hours, ambient, operator group, controller shot number), FR-05 `dq_flags_json`, the FR-16 `startup_event_id` / `seq_after_startup` / `startup_transient` (set by trigger), and the batch it arrived in. `image_alignment` (IF-58): one per part, `delta_ms` generated from `image_ts − shot_ts`, `tolerance_ms` (default 1,500), `align_method` (`shot_id` | `timestamp`), `cavity_method` (`ocr_marking` | `robot_position` | `sequence`), `ocr_text`. `shot_defect` (SRS §5): class (10-value enum), confidence, region (gate area, far end, rib, boss, parting line), bbox, `delta_e` (mandatory for `colour_deviation`), anomaly score, model version, `review_required` and the human `review_verdict` with reviewer and time (FR-11). `colour_reference`: Lab per SKU and chart, threshold (default 2.0), lighting reference (FR-09, AI-04).

### 4.3 `parameter_window`, `setup_sheet_version`, `parameter_change`
Windows per mould × material grade × parameter with unit, `lo < hi`, source and approver (C-05). Setup sheets versioned per mould with `params_json = {parameter: {target, tol}}`, author/approver, one `active` (unique partial index); approved sheets immutable (`trg_setup_sheet`) (FR-18). `parameter_change`: machine, mould, ts, parameter, old/new, unit, `changed_by` (controller user or a person), source (`controller` | `manual_entry`), and the timeline event the trigger created (FR-04).

### 4.4 `kb_defect`, `kb_version`, `kb_cause`, `kb_case_evidence`, `scoring_config`
`kb_cause`: version, defect, `cause_code`, names TH/JA/EN, `prior_weight` (0–1), `typical_params_json` (`{parameter: up|down|low|high}`), `checks_json[]`, `actions_json[]` (`{param, direction, range, window_ref, side_effects}` — every field mandatory by trigger), `side_effects`, **`source` (non-empty CHECK)**, `design_cause`. Unique per version × defect × code. `kb_version`: `draft → approved` (approver ≠ author, engineer+) `→ retired`; approved rows frozen except the status. `kb_case_evidence`: verified outcome triplets per cause and session (FR-25). `scoring_config`: `w_prior + w_delta + w_timeline + w_case = 1` (CHECK), one active.

### 4.5 `rca_session`, `rca_cause_score`, `rca_turn`, `rca_advice`, `parameter_suggestion`, `action_outcome`
`rca_session`: defect class, mould, machine, window, the KB version and scoring config used (both frozen on the row), language, status (`open → dialogue → advised → acting → verifying → closed`), `facts_json` (IF-60), verified cause/by/at (all three or none), `closure_kind`, `qe_case_id` (FR-26). `rca_cause_score`: per session × cause × turn — `prior_c`, `delta_c`, `timeline_c`, `case_c` ∈ [0,1], `score`, `rank`, `evidence_json` (why each component has its value). `rca_turn`: question key (the KB check key), text, language, answer, normalised answer, who/when. `rca_advice`: ordinal, `kind`, cause, texts TH/JA/EN, and for actions parameter/direction/magnitude range/window ref/side effects (CHECK); `done` by whom. `parameter_suggestion`: current/suggested value, direction, magnitude % (computed), window lo/hi (copied), `allowed`/`blocked` (exactly one), `block_reason`. `action_outcome`: applied action and time, before/after counts; rate, z, p, `effective`, `outcome` computed.

### 4.6 `cavity_flag`, `scrap_cost_config`, `vision_eval_run`, `golden_run`, `prompt_template`
`cavity_flag`: per mould × class × window × cavity: `x/n` vs `others_x/others_n`, z, p, `flagged` (α 0.01, n ≥ 200, higher rate) — computed. `scrap_cost_config`: unit cost per SKU from a date (FR-17). `vision_eval_run`: model version, family, hold-out size, mAP@50, per-class recall JSON, `passed` (mAP ≥ 0.80 and recall ≥ 0.95 for short shot, flash, contamination — AI-02). `golden_run`: KB version, scoring config, incidents, top-3 hits, rate, `passed` (≥ 15 incidents, ≥ 70 % — AI-07). `prompt_template`: `rca_question` / `explain` versions with checksum, temperature ≤ 0.3.

## 5. Functions
| Function | Purpose (twin of) |
|---|---|
| `norm_sf(z)` | standard normal upper tail (A–S 7.1.26; max error 7e-8 vs `erfc`) |
| `two_proportion_z(x1, n1, x2, n2)` | continuity-corrected two-proportion test → (z, two-sided p): cavity vs others (FR-12), before vs after (FR-24) |
| `welch_t(m1, s1, n1, m2, s2, n2)`, `cohens_d(…)` | good-vs-defective parameter deltas with effect size (FR-13) |
| `drift_slope(values[])` | least-squares slope per shot (FR-14) |
| `in_window(v, lo, hi)` | C-05 |
| `delta_e76(L1, a1, b1, L2, a2, b2)` | CIE76 colour difference (FR-09, AI-04) |
| `cause_score(prior, delta, timeline, case, config)` | the AI-05 scoring function |
| `is_startup_transient(seq, n)` | FR-16 |
| `scrap_cost(qty, unit_cost)` | FR-17 |
| `role_rank(role)` | approval checks |

TC-005 re-derives every one of these in Python on the seed's inputs (§9).

## 6. Views
| View | Serves |
|---|---|
| `v_cavity_rates` | parts and fail rate per cavity, transients excluded (FR-12) |
| `v_defect_by_cavity` | defect counts per class per cavity (FR-12) |
| `v_parameter_delta` | per mould × class × parameter: defective vs good means, sd, delta, Cohen's d, Welch t (FR-13) |
| `v_drift` | slopes of cushion, cycle time, holding pressure over the last 200 shots (FR-14) |
| `v_golden_diff` | latest shot vs the active setup sheet with deviations and out-of-tolerance flags (FR-18) |
| `v_timeline` | timeline events + startup events (FR-15) |
| `v_rca_board`, `v_cause_ranking` | sessions; the ranking with components and weights ("why this order") (AI-05) |
| `v_suggestion_audit` | every suggestion with allowed/blocked and reason (AC-05) |
| `v_effectiveness` | outcomes with z, p, effective (FR-24) |
| `v_kb_status` | versions, approvers, causes, evidence rows (NFR-08) |
| `v_data_quality` | flagged and transient shots per day (FR-05) |
| `v_scrap_cost` | cost per class per day (FR-17) |
| `v_gateway_lag` | last shot, open batches, buffered/duplicate totals (NFR-05) |
| platform `vision.v_review_queue` | FR-11 |

## 7. Sizing and retention
| Object | Volume | Retention |
|---|---|---|
| `quality.shot` + `shot_ext` | 12 s cycle → ~7,200 shots/day/machine, ~220 k/month; params_json ≈ 400 B | 2 years (monthly partitions or hypertable chunks) |
| `shot_part` + `image_alignment` | × cavities (4) | 2 years; images 90 days in MinIO (defect images 2 years) |
| `shot_defect` | ~2–10 % of parts | 5 years |
| `timeline_event`, `parameter_change` | tens/day | 5 years |
| `kb_*`, `rca_*`, `action_outcome` | small | 10 years (knowledge is the asset) |
| `audit.log` | blocked suggestions, approvals, connection changes | 10 years |

## 8. Roles and grants
| Role | Grants |
|---|---|
| `app_rw` | DML on `core`, `vision`, `quality`, `knowledge`, `moldmind`; `audit` insert/select |
| `app_ro` | select everywhere |
| `agent_ro` (platform tools) | select on `core`/`vision`/`quality`/`knowledge`/`moldmind`; **revoked** on `core.app_user`, `core.user_line_scope`, `moldmind.machine_connection` |
| **`gateway_rw`** | select on machine/lot/sku/mould/connection/node map; **INSERT only** on `quality.shot`, `quality.timeline_event`; insert/update on `shot_ext`, `parameter_change`, `startup_event`, `gateway_batch`; update `node_map_version.validated_at` — no delete anywhere |
| **`vision_rw`** | insert on `vision.inspection/detection/measurement`; insert/update on `quality.shot_part`, `image_alignment`, `shot_defect`; select on references |
| **`kb_rw`** | `kb_*`, `scoring_config`, `prompt_template` only |

Passwords are `SET_AT_BOOTSTRAP` from secret files (OPS-11 §4.2).

## 9. Demo and test dataset (`db/seed_demo.sql`)
Deterministic. Plant BKK-1, line L2, SKU PNL-220 (PP-H-2000), machine M-3 (220 t) with an OPC-UA read-only connection and a 17-node map, mould MLD-0417 (4 cavities), lot LOT-2609-201, seven users (yuki manager; somsak technician; prasit QC inspector; nattaya process engineer; kenji quality engineer; wichai mould maintenance; admin). Setup sheet v1 (retired) and v2 (active: holding pressure 650 ± 20, holding time 8, cushion 4.5 ± 1.5, melt 235, mould 60, cooling 12, cycle 28); six parameter windows; colour reference Lab (62.1, −4.3, 12.8), threshold 2.0; scrap cost 42 THB; scoring config 0.35/0.30/0.20/0.15; KB `kb-2026.09.1` approved (author nattaya, approver kenji; 11 causes over sink mark = Appendix A, short shot, flash) and a draft `kb-2026.09.2-draft`.

**Shots (448)**: startup 2026-09-08 09:00 after a 120-min stop — 20 shots, transient window 20, short shots on shots 1–8 (AC-06); buffered 2026-09-08 15:00–16:00 — 128 shots in one `gateway_batch`, reconciled, 0 duplicates (AC-09); 2026-09-09 **before** 09:50 (100 cycles @ 650 bar, cushion 4.5 + 0.1·sin k), **parameter change 10:40 650 → 560** (controller, somsak → timeline event), **after** 10:40 (100 @ 560, cushion 2.8 + 0.1·sin k, cycle 28.2), **post-action** 13:00 (100 @ 616, cushion 4.3 + 0.1·sin k). Every 2026-09-09 shot and every startup shot has 4 parts, inspections, alignments (image = shot + 1.2 s; OCR marking except every 50th by sequence and one by robot position).

**Expected values (TC-005, re-derived in Python; TC-009 `\echo` block):**

| Item | Value |
|---|---|
| Counts | 448 shots · 1,280 parts · 83 defects (32 short shots on transients, 6 + 36 + 7 sink marks, 1 weld line, 1 colour deviation) · 20 transient shots · 128 buffered · 2 parameter edits |
| AC-03 trend | 6/400 = 1.5 % → 36/400 = 9.0 %: **z 4.5971, p 4.3e-6** |
| Cavity flags (after window) | cavity 3: 20/100 vs 16/300 → **z 4.2366, p 2.27e-5, flagged**; cavities 1/2/4: 6, 5, 5 of 100 → not flagged |
| `v_cavity_rates` | 300 parts per cavity; failed 11 / 8 / 26 / 6 |
| Parameter delta (sink mark, transients excluded) | holding pressure: defective n 42 mean **582.190** sd 34.876 vs good n 386 mean **625.254** sd 34.045 → delta −43.063, **Cohen's d −1.2619, Welch t −7.617**; cushion: 3.293 vs 4.139, d −1.288 |
| Drift (last 200 shots: after → post) | cushion **+0.011221 mm/shot**, holding **+0.420011 bar/shot**, cycle −0.0015 s/shot; `drift_slope([4.5, 4.4, 4.3, 4.2]) = −0.1` |
| Golden diff (latest shot 616 bar vs v2 650 ± 20) | holding pressure deviation **−34, out of tolerance**; cushion 4.249 (−0.251, within) |
| ΔE76 | (60.9, −3.9, 14.1) → **1.814** ok; (59.8, −3.1, 15.0) → **3.401** → `colour_deviation` defect with `delta_e` 3.401 |
| Cause ranking (turns 0 and 3) | insufficient_holding_pressure **0.88** (1.0/1.0/1.0/0.2) · holding_time_too_short 0.2333 · melt_temperature_too_high 0.175 · mould_temperature_too_high_local 0.175 · part_wall_thickness_design 0.1167 · insufficient_cooling_time 0.1167 — AC-03 top-2 ✓ |
| Advice | check 1 (cushion vs setup sheet), check 2 (holding trace vs golden run), action 3 (holding pressure up +5..+15 %, window 500–750, side effects flash / internal stress) |
| Suggestions | 616 bar (+10.0 %) **allowed**; 800 bar (+42.86 %) **blocked** `OUT_OF_WINDOW`, 1 audit row |
| AC-07 effectiveness | 36/400 → 7/400: before 0.09, after 0.0175, **z 4.3896, p 1.14e-5, effective = true**; `kb_case_evidence` 1 row (insufficient_holding_pressure, effective) |
| RCA board | closed / verified / top cause insufficient_holding_pressure / 3 answers / 1 blocked / effective / handed off (QC-0417 + `eight_d` draft) |
| KB status | kb-2026.09.1 approved, 11 causes, 3 defects, 1 evidence row; draft version 1 cause |
| Gates | vision v2 mAP 0.81, contamination 0.93 → **failed**; v3 0.83 / 0.97 / 0.96 / 0.95 → **passed**; golden 11/15 = 0.7333 **passed**, 9/15 = 0.60 **failed** |
| Data quality | 2026-09-09: 1 shot missing zone z3, 1 stuck cushion; gateway: 0 open batches, 128 buffered, 0 duplicates |
| Scrap cost | 2026-09-09 sink mark 49 × 42 = **2,058 THB** (incident window 36 × 42 = 1,512); 2026-09-08 short shots 32 × 42 = 1,344 |
| Twins | `is_startup_transient(20, 20)` true, `(21, 20)` false; A–S vs `erfc` max error 7e-8 |

**Probes (TC-003), each fails with the named guard:** 1 cavity 5 on a 4-cavity mould → `CAVITY_OUT_OF_RANGE`; 2 defect without a shot part → FK violation; 3 image 8 s from its shot → `ALIGNMENT_TOLERANCE`; 4 800 bar asserted allowed → `OUT_OF_WINDOW`; 5 `effective = true` typed with p 0.85 → `EFFECTIVE_NOT_TYPED`; 6 cause with a blank source → CHECK; 7 session on the draft KB → `KB_NOT_APPROVED`; 8 action before any check → `CHECK_BEFORE_CHANGE`; 9 read-write machine credential → `MACHINE_READONLY`; 10 editing the approved KB version → `KB_IMMUTABLE`; 11 stored score 0.99 → `SCORE_NOT_TRANSPARENT`; 12 node map with write access → `NODE_MAP_WRITE`.

## 10. Platform mode
Apply sections 10–17 only (`moldmind_0001`) on the platform database. MoldMind's four quality tables are already there and become its; `trg_shot_part_cavity` is an additive trigger on `quality.shot_part`; `gateway_rw`, `vision_rw`, `kb_rw` are added to the platform's roles; the 8D handoff writes QE-Agent's `quality.case`/`artifact` through QE's API (IF-62), not directly, in platform mode.

## 11. Traceability
| SRS-11 | Objects |
|---|---|
| C-01, NFR-06 | DD-M01, `machine_connection`, `node_map_version`, `gateway_rw` |
| C-02, FR-03, FR-08, AC-02 | DD-M02, `shot_part`, `image_alignment`, `shot_defect` |
| C-03, FR-19, AI-08, NFR-08 | DD-M05, `kb_version`, `kb_cause`, `v_kb_status` |
| C-04, FR-22, FR-23 | DD-M08, `rca_advice` |
| C-05, AI-09, AC-05 | DD-M09, `parameter_window`, `parameter_suggestion`, `v_suggestion_audit`, `audit.log` |
| FR-01, FR-02, FR-05 | `quality.shot`, `shot_ext`, node map |
| FR-04, FR-15 | DD-M04, `parameter_change`, `quality.timeline_event`, `v_timeline` |
| FR-06, FR-07, FR-09, FR-10, FR-11 | `shot_defect`, `colour_reference`, `vision.verdict_override`, `v_review_queue` |
| FR-12 | `cavity_flag`, `v_cavity_rates`, `v_defect_by_cavity` |
| FR-13 | `v_parameter_delta`, `welch_t`, `cohens_d` |
| FR-14 | `v_drift`, `drift_slope` |
| FR-16, AC-06 | DD-M03, `startup_event`, `shot_ext.startup_transient` |
| FR-17 | `scrap_cost_config`, `v_scrap_cost` |
| FR-18 | `setup_sheet_version`, `v_golden_diff` |
| FR-20, AI-05, AI-06 | DD-M06, `scoring_config`, `rca_cause_score`, `v_cause_ranking` |
| FR-21 | `rca_turn`, `rca_session.facts_json` |
| FR-24, AC-07 | DD-M09, `action_outcome`, `v_effectiveness` |
| FR-25 | `kb_case_evidence`, `trg_evidence_writeback` |
| FR-26 | `rca_session.qe_case_id`, `quality.case`, `quality.artifact` |
| FR-27, AC-08 | `knowledge.glossary_term`, TH/JA/EN columns on `kb_cause`, `rca_advice` |
| AI-02, AC-01 | `vision_eval_run` |
| AI-07, AC-04 | `golden_run` |
| NFR-05, AC-09 | `gateway_batch`, `v_gateway_lag` |

## Appendix A — The constraints that carry the weight
| Guard | Refuses | Error code surfaced by the API |
|---|---|---|
| `trg_machine_readonly`, `trg_node_map_readonly` | a non-read-only credential; an OPC-UA policy without SignAndEncrypt; a node with write access | `MACHINE_READONLY`, `MACHINE_SECURITY`, `NODE_MAP_WRITE`, `NODE_MAP_SHAPE` |
| `trg_shot_part_cavity`, `trg_defect_joinable` | a cavity beyond the mould; a part on a shot without a mould; a defect not on exactly one part | `CAVITY_OUT_OF_RANGE`, `SHOT_WITHOUT_MOULD`, `DEFECT_NOT_JOINABLE` |
| `trg_alignment_tolerance` | an image outside the tolerance of its shot | `ALIGNMENT_TOLERANCE` |
| `trg_kb_cause_shape`, `trg_kb_version_immutable` | causes without checks or with incomplete actions; inserting into an approved version; self-approval; approval below engineer; editing an approved version | `KB_SHAPE`, `KB_ACTION_SHAPE`, `KB_IMMUTABLE`, `KB_SELF_APPROVAL`, `ROLE_INSUFFICIENT` |
| `trg_cause_score_transparent` | a score the scoring function does not produce | `SCORE_NOT_TRANSPARENT` |
| `trg_rca_session_rules` | ranking with a draft KB or an inactive config; verified closure without a ranked cause | `KB_NOT_APPROVED`, `SCORING_INACTIVE`, `CLOSURE_UNVERIFIED`, `CAUSE_NOT_RANKED` |
| `trg_advice_check_first` | an action before any check | `CHECK_BEFORE_CHANGE` |
| `trg_suggestion_window` | an out-of-window suggestion asserted allowed (otherwise stored blocked + audited) | `OUT_OF_WINDOW` |
| `trg_action_effective` | an asserted effectiveness that the test does not support | `EFFECTIVE_NOT_TYPED` |
| `trg_setup_sheet` | editing an approved setup sheet | `SETUP_SHEET_IMMUTABLE` |
| `trg_shot_transient`, `trg_parameter_change_event`, `trg_evidence_writeback`, `trg_cavity_flag`, `trg_vision_gate`, `trg_golden_gate` | nothing — compute | — |
