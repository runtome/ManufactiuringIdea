# Database Design Specification — Factory Copilot (Local AI Factory Copilot)

| Field | Value |
|---|---|
| Document ID | DDS-10-Copilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-17 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`db/schema.sql`](../db/schema.sql) (2,187 lines) · [`db/seed_demo.sql`](../db/seed_demo.sql) (822 lines) |
| Related | [SRS-10](../SRS-FactoryCopilot-Local-Multilingual-Assistant.md) §5 · [SAD-10](SAD-Copilot-Software-Architecture.md) §4.6 · [API-10](../api/API-Specification.md) · [ICD-10](ICD-Copilot-Interface-Control.md) IF-54, IF-56 · [SEC-10](SEC-Copilot-Security-Requirements.md) · [TEST-10](TEST-Copilot-Test-Plan.md) TC-002…TC-005, TC-009 · platform: [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) |

---

## 1. Introduction

### 1.1 Purpose
The database is where Copilot's promises become checkable: that every answer's numbers came from a tool, that generated SQL never left the sandbox, that no tool call reached outside the caller's lines, that a shared answer was a grounded one, and that a release passed its evaluation. This document specifies the schema, the guard triggers that enforce those promises, the SQL twins of the deterministic logic used to verify the seed, and the demo dataset that reproduces SRS-10 Appendix A and AC-02…AC-09.

### 1.2 What is different from the other databases in this repository
- **Copilot owns the platform's conversation tables.** `agent.conversation`, `agent.message`, `agent.run`, `agent.tool_call` and `agent.feedback` are the SRS-10 §5 tables `conversation`, `message`, `turn_trace`, `feedback` — extracted byte-identically from the platform schema, not redefined. The Copilot extension adds `copilot.turn` (understanding, evidence bundle, sources, notes) keyed one-to-one on `agent.run`.
- **The evidence bundle is stored, digested and checked.** `agent.run.facts_json` holds the bundle the composer received; `agent.run.grounding_json` the post-check result; `copilot.turn.bundle_digest` ties them together. The seed computes `grounding_json` with the schema's own `grounding_check()` at insert time, so the guard evaluates real output.
- **Generated SQL is a row before it is a query.** `copilot.sql_query` stores every statement the model proposed; `trg_sql_safe` decides whether it may execute; `copilot_sql_ro` is the only role it can run as.
- **Scope is a trigger, not a convention.** `trg_tool_scope` refuses any `agent.tool_call` on a Copilot run whose arguments reach outside the caller's `core.user_line_scope`.

### 1.3 Engine and extensions
PostgreSQL 16; `pgcrypto`, `vector` (chunk, case-chunk and curated-Q&A embeddings, HNSW), `pg_trgm` (lexical half of hybrid retrieval; alias fuzzy matching), `btree_gin` — the platform's four extension lines. **Not executed on the authoring machine** (TEST-10 TC-009).

### 1.4 Assembly and byte identity
`db/schema.sql` is assembled by marker extraction from `00/db/schema.sql` (`assemble10.py`): extensions (lines 23–26), helpers (63–104), the enums the extracted sections use (`core.shift_code`, `core.language_code`, `vision.verdict`, `vision.model_stage`, `quality.case_status`, `quality.severity`, `quality.artifact_kind`, `quality.chart_type`, `agent.run_outcome`, `agent.finding_status`, `agent.message_role`), the **whole core section 5**, **whole vision section 6**, **whole quality section 7** (needed because `knowledge.case_record` references `quality.case`, and because QE-Agent's `get_signals`/`get_case`/`get_hypotheses` read these tables), **whole knowledge section 9**, **whole agent section 10**, `audit.*`, the core/vision/quality/knowledge/agent/audit indexes, the six core `updated_at` triggers and the views `core.v_kpi_daily`, `core.v_defect_pareto`, `vision.v_inspection_daily`, `knowledge.v_citable_case`, `agent.v_grounding_health`. TC-002: **134/134 shared objects byte-identical; the five sections present verbatim**. Telemetry, docflow and ops sections are not extracted (MachineSense telemetry is reached through its tool, never its tables).

---

## 2. Design principles

| ID | Principle | Where it lives |
|---|---|---|
| **DD-C01** | **A run is `ok` only if the post-check matched every number; refusals and partial answers say why.** | `trg_run_grounded` on `agent.run` (`kind = 'ask'`): `outcome = ok` ⇒ `grounding_json.all_matched = true`; `refused`/`partial`/`budget_exceeded` ⇒ `grounding_json.reason` present (C-02, AI-04, FR-16, FR-17) |
| **DD-C02** | **Generated SQL executes only if it is a single whitelisted `SELECT` with a `LIMIT`, as the sandbox role, while the flag is on and the SQL evaluation passed.** | `copilot.sql_query` + `sql_is_safe()` + `trg_sql_safe` + `trg_sql_flag` + role `copilot_sql_ro` (`statement_timeout 5 s`, `default_transaction_read_only`) (C-05, FR-08, AI-06) |
| **DD-C03** | **Every tool call carries the caller's scope predicate.** | `trg_tool_scope` on `agent.tool_call` via `scope_ok(user_id, args_json)`; empty scope = all lines; restricted caller without a `line`/`lines` argument is refused (C-03, FR-22, AC-04) |
| **DD-C04** | **Copilot exposes read tools only.** | `copilot.tool_policy` + `trg_tool_policy_read_only` (`agent.tool.kind = 'read'`) (C-01) |
| **DD-C05** | **Only approved, embedded curated answers are citable; only verified cases are citable.** | `trg_curated_approved` (approver role ≥ engineer; `active` needs `approved_at` and `embedding`); `knowledge.v_citable_case` (FR-25, FR-16) |
| **DD-C06** | **Only grounded answers are shared or exported; shares expire.** | `trg_share_grounded` (run outcome = `ok`), `share_expiry_bounded` ≤ 30 days (FR-19) |
| **DD-C07** | **Release gates are computed, never typed.** | `trg_eval_gate` (≥ 60 questions, 3 languages, 6 intents, accuracy ≥ 0.90, citation ≥ 0.95, fabricated = 0), `trg_sql_eval_gate` (≥ 30, ≥ 0.85) (AI-05, AI-06, AC-01) |
| **DD-C08** | **Turn rules: masking below the threshold role, delegation for cause analysis, no grounded answer in dashboards-only mode.** | `trg_turn_rules` (FR-26, FR-21, AC-09) |
| **DD-C09** | **Documents are data: instruction-like chunks are flagged; messages are immutable; purge is the only delete.** | `trg_chunk_injection_flag`, `trg_message_immutable`, `purge_user_conversations()` (AI-07, FR-23, NFR-07) |

## 3. Schema overview
| Schema | Owner | Contents here |
|---|---|---|
| `core` | platform | plant, line, sku, machine, defect_type, material_lot, **shift_calendar** (FR-02), app_user, user_line_scope, ingest_batch, production_fact, defect_fact, quarantine_row; views `v_kpi_daily`, `v_defect_pareto` |
| `vision` | platform | model_registry, camera, recipe, inspection (partitioned), detection, measurement, verdict_override, drift_metric; `v_inspection_daily` — image evidence (FR-10) |
| `quality` | platform (QE-Agent) | the SPC/case/FMEA section; Copilot reads `signal`, `case`, `hypothesis` through QE's tools and stores the delegation FK |
| `knowledge` | platform (Genba Memory) | document, chunk (+ `suspicious`), case_record, case_source, case_chunk, glossary_term, tm_segment; `v_citable_case` |
| `agent` | platform, **conversation tables owned by Copilot** | tool, conversation, message, run, tool_call, action_proposal, finding, briefing, feedback; `v_grounding_health` |
| `audit` | platform | log, auth_event |
| `copilot` | **this module** | 24 tables, 14 functions, 13 guard triggers, 9 views (§4–§6) |

Counts (TC-003): **82 tables / 14 views / 19 triggers / 29 functions / 67 indexes / 17 enums**.

### 3.1 ERD (the question-to-answer spine)
```
core.app_user ──< agent.conversation ──< agent.message (user / assistant; immutable)
      │                    │                     │
      │ user_line_scope    └──< agent.run ───────┤ (= SRS turn_trace: model, prompt_version, facts_json, grounding_json, latency)
      │                           │ 1            │
      │                           ├──< agent.tool_call (args_json carries the scope predicate; digest; row_count)
      │                           │
      │                           └── 1 copilot.turn (lang, intent, entities, time range, plan, bundle, sources, notes, masked, delegation)
      │                                     ├──< copilot.sql_query (FR-08; executed only as copilot_sql_ro)
      │                                     ├──< copilot.share · copilot.pin · copilot.answer_flag ──> copilot.curated_qa
      │                                     ├──< copilot.term_check ──> knowledge.glossary_term
      │                                     └──> quality.signal / quality.case (FR-21 delegation)
      └── agent.feedback
knowledge.document ──< knowledge.chunk (+suspicious)      copilot.doc_source ──< copilot.index_job
agent.tool ── copilot.tool_policy                          copilot.eval_question ──< copilot.eval_result >── copilot.eval_run
```

## 4. Table specifications (the ones that carry rules)

### 4.1 `copilot.turn`
One row per question, `run_id UNIQUE` → `agent.run`. Understanding: `lang_detected`, `answer_lang`, `intent` (enum of the six SRS intents), `entities_json` (`[{kind, canonical_id, alias, method}]`), `time_expr`/`time_from`/`time_to`/`time_resolution` (`relative:yesterday`, `shift:B`, `explicit`, `context`), `context_json` (slots reused from the previous turn — FR-06), `clarification_asked`/`clarification_reply` (FR-05). Execution: `plan_json` (validated typed plan), `evidence_bundle_json` (IF-56, the composer's only input), `bundle_digest`, `sources_json` (FR-15), `charts_json`, `images_json`, `suggestions_json`. Honesty: `confidence_note` (FR-16), `partial` + `partial_reason` (CHECK), `masked` (FR-26), `delegated_signal_id`/`delegated_case_id` (FR-21), `mode` (`full` | `dashboards_only`). Latency: `queue_wait_ms`, `first_token_ms`.

### 4.2 `copilot.sql_query`, `copilot.sql_whitelist`, `copilot.feature_flag`
`sql_query`: `sql_text`, `parser_ok`, `whitelist_ok`, `reject_reason` (all set by `trg_sql_safe` from `sql_is_safe()`), `limit_applied` (1–1000), `timeout_ms` (≤ 5000), `executed_as` (must be `copilot_sql_ro` when executed), `executed`, `row_count`, `duration_ms`, `result_digest`. `sql_whitelist`: relation (`schema.view`), exposed columns, `scope_column`; CHECK refuses `core.app_user`, `core.user_line_scope`, `audit.*`. `feature_flag`: `text_to_sql`, `discord`, `external_model`, `image_similarity`; enabling requires `enabled_by`, `enabled_at`, `reason` (CHECK) — C-04's "explicitly enabled by an admin" is a row, and `text_to_sql` additionally needs the latest `sql_eval_run.passed` (`trg_sql_flag`).

### 4.3 `copilot.tool_policy`, `copilot.masking_rule`, `copilot.entity_alias`, `copilot.user_pref`, `copilot.channel_binding`
`tool_policy` per registry tool: provider (`shiftbrief`, `machinesense`, `qe_agent`, `genba_memory`, `vision`, `platform`), `min_role`, `scope_param` (the argument carrying the predicate — default `lines`), `max_rows`, `timeout_ms` (≤ 10 s, IF-16), `intents[]`. `masking_rule`: field kind, `min_role_unmasked` (default `manager`), replacement. `entity_alias` (SRS §5): kind, canonical id, alias, generated `alias_norm` (`norm_text()`: lower-case, fullwidth/Thai digits → ASCII, spaces removed), language; unique per (kind, alias_norm). `channel_binding`: Discord identity → platform user; channels allowed only after `verified_at` (`trg_binding_verified`).

### 4.4 `copilot.curated_qa`, `copilot.answer_flag`, `copilot.share`, `copilot.pin`, `copilot.saved_question`
`curated_qa` (SRS §5): question, answer, lang, author, approver (role ≥ engineer), `source_turn_id`, `sources_json`, `embedding vector(1024)`, `active` only when approved and embedded. `answer_flag`: FR-25 review queue; `corrected` requires `curated_qa_id` (CHECK). `share`: format (`link`/`png`/`pdf`), unique token, object URI, expiry ≤ 30 days, revocation; insert refused unless the run is `ok`. `saved_question` carries `direct_url` — the dashboards-only fallback (NFR-06).

### 4.5 `copilot.doc_source`, `copilot.index_job`, `knowledge.chunk.suspicious`
Watched sources with ACL and scan interval; jobs with `sha256`, `reason` (`new`/`changed`/`manual`/`reembed`) and state — unchanged files are `skipped` (FR-12). `knowledge.chunk` gains `suspicious`/`suspicious_reason`, set by `trg_chunk_injection_flag` from `injection_suspect()` (EN/JA/TH phrase patterns) — a mark for review and for the retriever's exclusion list, never an instruction (AI-07, AC-05).

### 4.6 `copilot.eval_question`, `copilot.eval_run`, `copilot.eval_result`, `copilot.sql_eval_run`, `copilot.prompt_template`, `copilot.term_check`, `copilot.queue_status`
Evaluation set and runs with computed `accuracy`, `citation_rate`, `passed`, `release_blocked`; per-question results with `fabricated_numbers`. `prompt_template`: planner/composer/clarify/suggest versions with checksums and `temperature ≤ 0.3` (AI-01/AI-03-style versioning). `term_check`: AI-09 hits per turn with the glossary term. `queue_status`: NFR-03 snapshots (`depth`, `max_wait_ms`, `gpu_wait_ms`, `mode`).

## 5. Functions
| Function | Purpose (twin of) |
|---|---|
| `norm_text(t)` | alias normalisation |
| `detect_lang(t)` | FR-01 script-based detection: Thai block, kana/kanji, Latin; dominant script; Thai on a tie |
| `resolve_time(expr, plant, now)` | FR-02: yesterday/today/last week/this week/last month/this month/this shift in TH/JA/EN, plant timezone, versioned `shift_calendar` with overnight shifts |
| `resolve_entity(text, kind)` | FR-03: exact on `alias_norm`, then trigram similarity ≥ 0.5 |
| `extract_numbers(t)` | AI-04: numeric tokens incl. thousands separators, decimals, `hh:mm`, fullwidth/Thai digits |
| `json_leaves(j)` | every scalar leaf of a bundle |
| `grounding_check(answer, bundle)` | ADR-013 post-check: each token matched within 0.005 absolute or 0.5 % relative, or as text inside a string leaf; years ignored → `{numbers_found, unmatched, all_matched}` |
| `sql_is_safe(sql)` | C-05 static rules: single `SELECT`/`WITH`, no comments, forbidden keywords, whitelisted relations only, `LIMIT ≤ 1000` (the production sandbox uses a real parser; this is its executable twin) |
| `rrf_fuse(bm25_rank, vector_rank, k = 60)` | AI-03 reciprocal rank fusion |
| `role_rank(r)`, `mask_names(t, role, names)` | FR-26 masking below `masking_rule.min_role_unmasked` |
| `scope_ok(user, args)` | FR-22 predicate check |
| `injection_suspect(t)` | AI-07 phrase patterns (EN/JA/TH) |
| `purge_user_conversations(user, actor)` | NFR-07 delete on request; audited; the only path that deletes messages |

TC-005 re-derives every one of these in Python on the seed's inputs (§9).

## 6. Views
| View | Serves |
|---|---|
| `copilot.v_conversation_board` | conversations × turns with outcome, latency, delegation (FR-23) |
| `copilot.v_turn_trace` | the full trace: question, plan, tool calls, SQL, sources, answer, grounding — "show the numbers / show the SQL" (FR-18) |
| `copilot.v_copilot_daily` | outcomes, clarifications, delegations, first-token and p95 latency, language mix (OPS-10 §9) |
| `copilot.v_sql_audit` | every generated statement with its verdict (C-05, AC-07) |
| `copilot.v_scope_audit` | every tool call with lines asked, caller scope and `in_scope` (NFR-05) |
| `copilot.v_eval_summary` | answer and SQL evaluation runs with gates (AI-05, AI-06) |
| `copilot.v_flag_queue` | FR-25 review queue |
| `copilot.v_index_status` | FR-12 per-source job and suspicious-chunk counts |
| `copilot.v_queue` | NFR-03 last 60 snapshots |
| platform `agent.v_grounding_health` | grounding failure rate per day |

## 7. Sizing and retention
| Object | Volume | Retention |
|---|---|---|
| `agent.run` + `copilot.turn` | ~2,000 turns/day at 10 concurrent users; bundle ≈ 4 KB | 365 days (NFR-07); `purge_user_conversations()` on request |
| `agent.tool_call` | ≤ 5 per turn | with the run |
| `knowledge.chunk` | 100 k chunks × 1024-d HNSW ≈ 600 MB | with the document |
| `copilot.sql_query` | ≤ 1 per turn when the flag is on | 365 days |
| `copilot.share` objects | PNG/PDF ≈ 300 KB | ≤ 30 days (expiry) |
| `copilot.queue_status` | 1 row / 10 s | 30 days |
| `copilot.eval_*` | 63 questions × runs | 5 years |

## 8. Roles and grants
| Role | Grants |
|---|---|
| `app_rw` | DML on `core`, `vision`, `quality`, `knowledge`, `agent`, `copilot`; `audit` insert/select |
| `app_ro` | select everywhere |
| `agent_ro` (platform) | select on `core`/`vision`/`quality`/`knowledge`; **revoked** on `core.app_user`, `core.user_line_scope`; `agent.finding`, `agent.briefing` only |
| **`copilot_sql_ro`** | `SELECT` on `core.v_kpi_daily`, `core.v_defect_pareto`, `vision.v_inspection_daily` **only**; `statement_timeout = 5 s`; `default_transaction_read_only = on` — the whitelist rows name exactly these relations |
| `indexer_rw` | `knowledge.document`, `knowledge.chunk`, `copilot.index_job` write; `copilot.doc_source` read |

Passwords are `SET_AT_BOOTSTRAP` from secret files (OPS-10 §4.2).

## 9. Demo and test dataset (`db/seed_demo.sql`)
Deterministic. Plant BKK-1 (Asia/Bangkok), lines L1–L4, SKUs RAD-500-A / PNL-220, machines M-7 / M-3, five defect types, lot LOT-2609-114, shifts A 06–14 / B 14–22 / C 22–06, seven users (yuki manager JA; somchai viewer TH scope L3+L4; prasit inspector scope L1; nattaya engineer; mai viewer scope L3; kenji inspector scope L2; admin). "Now" = 2026-09-10 10:00 +07.

**Expected values (TC-005, re-derived in Python; TC-009 `\echo` block):**

| Item | Value |
|---|---|
| L3 baseline 2026-09-02…09-08 | produced 22,490, NG 542 → **2.4100 %** |
| L3 2026-09-09 (Appendix A) | 3,213 / 187 → **5.8201 %**; shift B 127/187 = **67.91 %**; MISSING_PART 118/187 = **63.10 %**; Pareto order MISSING_PART 118, SCRATCH 31, BURR 22, DIM 16 |
| Two-proportion z (continuity-corrected) 187/3213 vs 542/22490 | **z 10.8352**, p 2.3e-27 (`signal.statistic_json`, `p_text "< 0.001"`) |
| L4 / L1 / L2 on 09-09 | 61/2,980 = 2.0470 % (answer "2.05 %") · 72/3,000 = 2.4000 % · 80/3,100 = 2.5806 % |
| Last week (08-31…09-06), 5 days available | 388/16,065 = 2.4152 % → "2.42 %", `partial` |
| L2 downtime this month | (8 × 54 + 36) / 9 = **52.0 min/day**, 9 days |
| `detect_lang` on SRS §2.2 questions | th, en, en, en, ja, en |
| `resolve_time` at 10:00 | yesterday → 09-09; 先週 → 08-31…09-07; เมื่อวาน → 09-09; this shift → A 06:00–14:00; このシフト at 23:30 → C 22:00–06:00 (+1 d) |
| `resolve_entity` | ライン３ → L3 exact; line3 → exact; mashine 7 → machine 7 by trigram (0.5) |
| `grounding_check` | every seed run `all_matched = true` (T1 36 tokens, T1b 28, T2 17, T3 11, T4 13, T5 13, T6 9, T7 21, T8 16); the fabricated variant "4.7 %" → `unmatched ["4.7"]` |
| `sql_is_safe` | 1 statement ok; then `LIMIT required`, `forbidden keyword`, `relation not whitelisted: core.app_user`, `multiple statements`, `comments not allowed`, `not a SELECT` |
| `rrf_fuse(1, 3)` / `(NULL, 1)` | 0.032266 / 0.016393 |
| `scope_ok` | yuki any → t; prasit L1 → t; prasit L3 → f; prasit no predicate → f; somchai L3+L4 → t; all 13 seed tool calls in scope |
| Eval gates | run 1: 58/63 = 0.9206, 61/63 = 0.9683, fabricated 0 → **passed**; run 2: 55/63 = 0.8730 → **blocked**; SQL 26/32 = 0.8125 failed, 28/32 = 0.8750 passed |
| Injection | the uploaded supplier note's chunk `suspicious = true` ("ignore-instructions phrase"); SOP chunks not flagged |
| Counts | 104 production rows (26 L3 + 78 other lines), 7 conversations, 20 messages, 10 runs, 13 tool calls, 10 turns, 5 chunks (1 suspicious), 63 eval results, ≥ 2 audit rows |

**Turns:** T1 Appendix A (ja, cause_analysis, 5 tool calls, delegated to S-241 / QC-0241, 2 charts, shared as PDF, pinned, 👍); T1b 先週は？ (context reuse, partial); T2 AC-03 (th, equals `v_kpi_daily`); T3 AC-08 follow-up (line changed, range/metric reused); T4 AC-04 (scope narrowed by the tool layer, notice); T5 AC-06 (refused: shift C missing); T6 AC-07 (sandbox SQL, executed as `copilot_sql_ro`, "show the SQL"); T7 how-to (SOP citations §2 p.2 / §3 p.3; injected chunk excluded; 👎 → flag → curated Q&A approved by an engineer); T8 image lookup (3 signed images); T9 AC-09 (dashboards-only, outcome `error`, links).

**Probes (TC-003), each fails with the named guard:** 1 ok run with an unmatched number → `GROUNDING_FAILED`; 2 `UPDATE` → `SQL_REJECTED (not a SELECT)`; 3 `core.app_user` → `SQL_REJECTED (relation not whitelisted)`; 4 no `LIMIT` → `SQL_REJECTED`; 5 prasit's run with `lines ["L3"]` → `SCOPE_VIOLATION`; 6 share of the refused run → `NOT_SHAREABLE`; 7 `send_discord` in the policy → `READ_ONLY`; 8 curated Q&A approved by a viewer → `ROLE_INSUFFICIENT`; 9 message edit → `IMMUTABLE`; 10 cause turn without delegation → `CAUSE_NOT_DELEGATED`; 11 SQL executed with the flag off → `SQL_FLAG_OFF`.

## 10. Platform mode
Apply sections 10–17 only (`copilot_0001`) on the platform database; `agent.*` conversation tables are already there and become Copilot's; the trigger `trg_run_grounded` applies to `kind = 'ask'` runs only, `trg_tool_scope` likewise, so KaizenSwarm's runs are untouched; `copilot_sql_ro` and `indexer_rw` are added to the platform's roles; `knowledge.chunk.suspicious` is an additive column Genba Memory ignores.

## 11. Traceability
| SRS-10 | Objects |
|---|---|
| C-01 | DD-C04, `tool_policy`, `trg_tool_policy_read_only`, `copilot_sql_ro` |
| C-02, AI-04, AC-06 | DD-C01, `grounding_check`, `trg_run_grounded`, `agent.run.grounding_json` |
| C-03, FR-22, AC-04, NFR-05 | DD-C03, `scope_ok`, `trg_tool_scope`, `v_scope_audit` |
| C-04 | `feature_flag` (recorded enablement), `channel_binding` |
| C-05, FR-08, AI-06, AC-07 | DD-C02, `sql_query`, `sql_whitelist`, `sql_is_safe`, `trg_sql_safe`, `trg_sql_flag`, `sql_eval_run`, `v_sql_audit` |
| FR-01…FR-06, AC-08 | `turn` understanding columns, `detect_lang`, `resolve_time`, `resolve_entity`, `entity_alias`, `context_json`, `shift_calendar` |
| FR-07 | `agent.tool`, `tool_policy` |
| FR-09…FR-12 | `knowledge.document/chunk`, `doc_source`, `index_job`, `rrf_fuse`, `v_index_status` |
| FR-13…FR-18 | `turn.evidence_bundle_json`, `sources_json`, `charts_json`, `confidence_note`, `partial`, `v_turn_trace` |
| FR-19 | `share`, `pin` |
| FR-21, AC-02 | `turn.delegated_*`, `trg_turn_rules`, `quality.signal/case/hypothesis` |
| FR-23 | `agent.run`, `agent.tool_call`, `turn`, `v_conversation_board` |
| FR-24, FR-25 | `agent.feedback`, `answer_flag`, `curated_qa`, `trg_curated_approved` |
| FR-26 | `masking_rule`, `mask_names`, `turn.masked` |
| AI-05, AC-01 | `eval_question/run/result`, `trg_eval_gate`, `v_eval_summary` |
| AI-07, AC-05 | `chunk.suspicious`, `injection_suspect`, `trg_chunk_injection_flag` |
| AI-09 | `glossary_term`, `term_check` |
| NFR-03 | `queue_status`, `v_queue` |
| NFR-06, AC-09 | `turn.mode`, `saved_question.direct_url` |
| NFR-07 | `purge_user_conversations`, `trg_message_immutable` |

## Appendix A — The constraints that carry the weight
| Guard | Refuses | Error code surfaced by the API |
|---|---|---|
| `trg_run_grounded` | an `ok` run whose post-check has an unmatched number; a refusal without a reason | `GROUNDING_FAILED` (422), `REASON_REQUIRED` |
| `trg_sql_safe` | any generated statement that is not a single whitelisted `SELECT` with `LIMIT`; execution as any role but `copilot_sql_ro` | `SQL_REJECTED`, `SQL_ROLE` |
| `trg_sql_flag` | execution while `text_to_sql` is off or the last SQL evaluation failed | `SQL_FLAG_OFF`, `SQL_EVAL_GATE` |
| `trg_tool_scope` | a tool call outside the caller's lines, or without a predicate for a restricted caller | `SCOPE_VIOLATION` |
| `trg_tool_policy_read_only` | exposing a write tool | `READ_ONLY` |
| `trg_curated_approved` | curated answers approved below engineer or active without approval/embedding | `ROLE_INSUFFICIENT`, `NOT_CITABLE` |
| `trg_share_grounded` | sharing a run that is not `ok` | `NOT_SHAREABLE` |
| `trg_eval_gate`, `trg_sql_eval_gate` | typed gate results (recomputed) | — |
| `trg_turn_rules` | an unmasked turn for a role below the threshold; a cause answer without delegation; a grounded answer in dashboards-only mode | `MASKING_REQUIRED`, `CAUSE_NOT_DELEGATED`, `MODE_MISMATCH` |
| `trg_chunk_injection_flag` | nothing — marks | — |
| `trg_message_immutable` | editing or deleting messages outside the purge | `IMMUTABLE` |
| `trg_binding_verified` | channel rights on an unverified Discord identity | `UNVERIFIED_BINDING` |
