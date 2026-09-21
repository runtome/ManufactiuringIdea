# Database Design Specification — KaizenSwarm (Multi-Agent Factory System)

| Field | Value |
|---|---|
| Document ID | DDS-13-KaizenSwarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-21 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-13](../SRS-KaizenSwarm-Multi-Agent-Factory.md) · [SAD-13](SAD-KaizenSwarm-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) · [`db/seed_demo.sql`](../db/seed_demo.sql) · [`deploy/scenarios/suite.example.yaml`](../deploy/scenarios/suite.example.yaml) |
| Parent | [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) §9 (`agent`), §9.4 (findings blackboard) |

---

## 1. Scope and relationship to the platform

### 1.1 What this schema is
PostgreSQL 16. `db/schema.sql` has two halves:

- **Sections 1–9 — extracted verbatim from `00/db/schema.sql`**: extensions, the helper functions, the six enums the extracted sections use (`core.shift_code`, `core.language_code`, `quality.severity`, `agent.run_outcome`, `agent.finding_status`, `agent.message_role`), the whole `core` section, the whole `agent` section, `audit`, their indexes, `updated_at` triggers and four views. TEST-13 TC-002 diffs every block and every object against the platform file (66/66 identical). A difference is a defect here, never in the platform's.
- **Sections 10–19 — the `swarm` extension** (migration `swarm_0001`): 28 tables, 18 enum types (12 new), 50 functions, 25 triggers, 40 indexes, 14 views.

**Platform mode** applies only sections 10–19 on the platform database. KaizenSwarm **owns** `agent.finding` and `agent.briefing` (SAD-00 §13) — the guard triggers in section 16 attach to those two platform tables — and **reuses** `agent.run` (one row per specialist per run, `kind = 'specialist'`, `correlation_id = run_no`), `agent.tool_call` (each tool call) and `agent.tool` (the read-only tool registry). Nothing in `core`, `quality`, `telemetry`, `knowledge` or `vision` is written.

### 1.2 SRS §5 tables, mapped
| SRS-13 §5 | Here | Note |
|---|---|---|
| `agent(...)` | `swarm.agent_registry` + `swarm.agent_domain` + `swarm.agent_tool` | `agent` is the platform schema name; the registry gets its own table; tools bind to platform `agent.tool` rows |
| `run(...)` | `swarm.run` | orchestration run with `run_no`, budgets snapshot, `partial_reason`; the specialist's LLM call is the platform's `agent.run` |
| `message(...)` | `swarm.message` | typed, immutable |
| `finding(...)` | platform `agent.finding` + `swarm.finding_ext` + `swarm.finding_occurrence` | the platform row is the blackboard; the extension adds issue key, factors, scope columns; occurrences keep every agent's evidence set |
| `compound_risk(...)` | `swarm.compound_risk` | `finding_ids uuid[]` + `components_json` as in the SRS |
| `briefing(...)` | platform `agent.briefing` + `swarm.briefing_run` | link to the run, rank list, claim check |
| `agent_metric(...)` | `swarm.agent_metric` | |

The SRS's "nothing significant" *finding* (FR-13) is modelled as an **assessment outcome** (`swarm.assessment.outcome = 'nothing_significant'`, with `checked` in the StatusUpdate payload), not as a blackboard row — a finding without evidence is invalid by C-02, and the platform's `finding_has_evidence` CHECK would refuse it.

---

## 2. Design decisions

| ID | Decision | Why | Where |
|---|---|---|---|
| **DD-K01** | **Only enabled specialists can write findings, and only inside their registered domains** | FR-22 (the Manager invents nothing), FR-14 (no cross-domain reasoning by specialists) | `trg_finding_author` on `agent.finding`; `swarm.upsert_finding()` |
| **DD-K02** | **Every scored row is recomputed by the database** — the score from the active weights version, the compound by noisy-OR of its components' stored scores; a supplied value that differs is refused | FR-18, AI-03, AI-04, AC-04 | `trg_risk_score_computed`, `trg_compound_components`, `score_finding()`, `compound_score()` |
| **DD-K03** | **Dedupe by issue key**: `issue_code` + the scope entities of its family; one active finding per key; every detection is an occurrence with its own evidence | FR-16, FR-24, AC-03, AC-08 | `issue_key()`, `idx_finding_ext_issue_active`, `finding_occurrence`, `upsert_finding()` |
| **DD-K04** | **A briefing is refused if its text carries a number absent from the findings it cites, or if its partial flag disagrees with the assessments** | FR-22, AC-07, FR-20, AC-02 | `trg_briefing_grounded` (on `briefing_run`), `claim_check()`, `claim_corpus()` |
| **DD-K05** | **Every enabled specialist ends a run with exactly one assessment; over budget ⇒ `budget_exceeded` + `incomplete`; "complete" over budget is unrepresentable** | C-04, AI-08, AC-05, FR-13 | `assessment_one_per_agent`, `trg_assessment_budget`, `budget_check()`, `trg_run_status` |
| **DD-K06** | **Messages are typed, shape-checked, addressed to registered parties and immutable** | C-01, FR-02, FR-07, AC-09 | `trg_message_typed`, `message_shape_ok()`, `run_trace()` |
| **DD-K07** | **One LLM lease at a time**; retries bounded to two attempts with backoff; circuit transitions only as the function allows | C-05, FR-04, FR-05, AI-02, AC-06 | `trg_llm_lease_exclusive`, `trg_attempt_policy`, `backoff_ms()`, `trg_circuit_transition`, `circuit_next_state()` |
| **DD-K08** | **Lifecycle by action only**: a person changes a status through `finding_action` (reason codes for dismissals); the system resolves/expires only with a resolution text; history tables are append-only | FR-23, FR-25, FR-26, FR-27 | `trg_finding_lifecycle`, `trg_finding_action`, `expire_findings()`, `agent_precision()`, append-only triggers |
| **DD-K09** | **Constants the SRS fixes are CHECK constraints** (one semaphore slot, gate ≥ 0.80 and 0 fabricated, model ≤ 9 B, temperature ≤ 0.3, two attempts, retention ≥ 365 d); tools bound to agents must be `read` | C-05, AI-05, AI-06, NFR-05, C-03 | `swarm.setting` CHECKs, `trg_tool_read_only` |

---

## 3. The `swarm` schema

### 3.1 Registry and rules (section 11)
| Table | Purpose | Key constraints |
|---|---|---|
| `setting` | constants and thresholds | CHECKs of DD-K09 |
| `agent_registry` | FR-01: name, kind (specialist/manager), module (IF-68), output schema, `budget_json {tool_calls, tokens, wall_ms}`, cron, prompt version, enabled | budget shape; `manager` ⇔ kind manager; audited by `trg_registry_change`; the manager cannot be disabled |
| `agent_domain` | the domains an agent may report on | FR-14 |
| `agent_tool` | binding to `agent.tool` | read tools only (`trg_tool_read_only`) |
| `registry_change` | before/after of every registry edit | |
| `scoring_weights` | FR-18 / AI-03 published tables, one `active` version | monotone tables, values ≤ 1; `idx_weights_active` |
| `relation_rule` | AI-04: `match_keys ⊂ {plant,line,machine,sku,lot,shift}`, `min_domains ≥ 2`, `window_hours` | rules iterate in `code` order — the first rule to match absorbs |

### 3.2 Runs, assessments, messages, leases, circuits (section 12)
| Table | Purpose | Key constraints |
|---|---|---|
| `run` | orchestration run: `run_no`, trigger (schedule / on_demand / question / scenario), scope, budgets snapshot, `agent_count`, deadline, status, `partial_reason`, totals | `partial ⇔ partial_reason`; `trg_run_status` (completed needs all assessed and none failed; partial must name the failed domain) |
| `assessment` | one per enabled specialist per run: outcome, `incomplete`, counts, confidence, freshness (+flag), usage, `agent_run_id → agent.run` | unique per (run, agent); findings ⇒ count > 0; nothing_significant ⇒ 0; budget_exceeded ⇒ incomplete; failures need `error` |
| `attempt` | per assessment: attempt no, outcome, backoff | ≤ `max_attempts`; retry only after invalid_output / transport_error; backoff waited |
| `message` | the bus log: seq, from, to, type, subject, payload, correlation | typed and shape-checked; immutable |
| `llm_lease` | GPU semaphore mirror | exclusive |
| `circuit_state`, `circuit_event` | per-agent breaker | legal transitions only |

### 3.3 Blackboard extension, scores, compounds, briefings, deliveries (section 13)
| Table | Purpose |
|---|---|
| `finding_ext` (1:1 `agent.finding`) | issue code and key, likelihood class, horizon, freshness, impact, owner suggestion, scope columns, `active`, first/last run, snooze |
| `finding_occurrence` | per run per agent: evidence set, confidence, freshness, summary (append-only) |
| `finding_action` | acknowledge / assign / start / snooze / dismiss (reason code) / resolve / reopen — performs the transition (append-only) |
| `risk_score` | per run per finding: the four factors, score, rank, `absorbed_by` compound |
| `compound_risk` | per run: rule, `finding_ids`, shared key, rationale, components, score, rank, title, action, owner |
| `briefing_run` | link `agent.briefing ↔ run`, `rank_json`, `claims_json`, `claim_check_json`, phrasing attempts, template fallback |
| `delivery` | briefing (Discord / webhook / email / dashboard) or immediate (CRITICAL) |
| `question` | FR-21 ad-hoc questions with the claim-checked answer |
| `agent_metric` | NFR-07 daily rollup |

### 3.4 Scenario suite, exports, migration (section 14)
`scenario` (≥ 2 findings, 1–3 expected top ids), `suite_run`, `scenario_result`, `export` (sha256 of the ordered message log), `migration`.

---

## 4. Functions — the twins (section 15)

Every function below is re-derived in Python by TEST-13 TC-005 (`twin13.py`).

| Function | Twin of | Rule |
|---|---|---|
| `score_factors / score_finding(severity, class, horizon, confidence, version)` | FR-18 / AI-03 | `impact[severity] × likelihood[class] × urgency[horizon] × round(confidence, 3)`, rounded to 4 dp; tables from the version |
| `compound_score(scores[])` | FR-17 / AC-04 | `1 − Π(1 − sᵢ)`, ≥ 2 inputs, 4 dp — never below any component |
| `issue_key(code, scope)` | FR-16 / FR-24 | family by the code's prefix: `machine.* → plant,machine`; `lot.* → plant,lot`; `sku.*`/`material.* → plant,sku`; else `plant,line`; sorted `k=v` pairs; shift and dates never enter |
| `scope_key(scope, keys)`, `scope_label(key)` | AI-04 | relation key of a scope for a rule (NULL when a key is absent); "Line 3", "SKU RAD-500-A" |
| `evidence_ok(jsonb)` | C-02 | array ≥ 1, each `{kind ∈ list, ref ≥ 3 chars}` |
| `message_shape_ok(type, payload)` | FR-02 | required keys per type; enums; usage on done / nothing_significant; `checked` on nothing_significant |
| `budget_check(usage, budget)` | C-04 | first violated key as text, else NULL |
| `backoff_ms(n)` | FR-05 | `min(base × 2^(n−1), cap)` → 2000, 4000, 8000, 16000, 30000 |
| `circuit_next_state(state, ok, failures, opened_at, now)` | FR-05 | closed→open at the threshold; open→half_open after the cool-down; half_open: one probe decides |
| `freshness_flag / freshness_label(min)` | AI-07 | > 60 min ⇒ ⚠; "5 min", "6 h" |
| `num_tokens(text)` | AC-07 | `\d+(?:[.,]\d+)*` on the lower-cased text, thousands separators removed |
| `claim_corpus(run, finding_ids[])` | AC-07 | run metadata (`Run 411 · 2 min 14 s · 4 agents · 23 tool calls · date · scope`), the cited findings (title, summary, action, evidence, scope, impact, key, owner, score 2 dp and 4 dp, freshness), the run's compounds (title, rationale, action, owner, key, components, score), the assessments (name, outcome, freshness, usage, error), and the numerals 1…top_n |
| `claim_check(text, run, finding_ids[])` | FR-22 / AC-07 | tokens of the text not in the corpus → `unmatched` |
| `upsert_finding(run, agent, payload, message, assessment)` | FR-16 / FR-24 / DD-K01 | validates the payload; same active key ⇒ occurrences + 1, `last_seen`, evidence union (distinct), severity = max, latest confidence/summary/action/factors; else a new finding + extension; always an occurrence |
| `score_run(run)` | FR-18 | one `risk_score` row per finding that occurred in the run |
| `detect_compounds(run)` | FR-17 / AI-04 | for each enabled rule in code order: groups of ≥ 2 unabsorbed findings from ≥ `min_domains` domains (a finding's domain is its first reporter's) sharing the rule's key within the window → compound (components ordered by score, agents joined by best score, actions joined, owners distinct) and absorption |
| `rank_run(run)` | FR-18 / FR-19 | compounds + unabsorbed findings by score desc, title; writes ranks; returns `rank_json` |
| `rank_findings(findings jsonb, version)` | AI-06 | the same pipeline over a synthetic set (dedupe merges by key keeping the first id, highest severity, strongest class, nearest horizon, highest confidence) — no blackboard rows |
| `run_scenario / run_suite` | AI-06 / AC-01 | computed top-N ids as a set vs `expected_top_json`; pass = n ≥ 15 ∧ rate ≥ gate ∧ fabricated = 0 |
| `expire_findings(run)` | FR-27 | scheduled runs only; an active issue expires when **every** agent that ever reported it has since reported (findings or nothing_significant) in ≥ `expire_after_runs` scheduled runs without it; timeouts, budget stops and invalid outputs never clear an issue; resolution names the agents and runs |
| `agent_precision(agent, from, to)` | FR-26 | `1 − false_positives / findings` over the findings the agent reported |
| `rollup_agent_metrics(date)` | NFR-07 | runs, failures, timeouts, budget stops, findings, dismissed, false positives, latency, tokens, tool calls |
| `run_trace(run)` | FR-07 / AC-09 | messages, LLM runs, tool calls, leases, attempts in time order |
| `briefing_items(run, n)` | FR-19 | the deterministic template the Manager phrases from — and the fallback text |

---

## 5. Guard triggers (section 16)

| Trigger | Table | Refuses with |
|---|---|---|
| `trg_registry_change` | `agent_registry` | `REGISTRY_KIND_IMMUTABLE`, `MANAGER_REQUIRED`; writes `registry_change`; seeds `circuit_state` |
| `trg_tool_read_only` | `agent_tool` | `TOOL_NOT_READ_ONLY` |
| `trg_run_status` | `run` | `RUN_NOT_COMPLETE`, `RUN_NOT_PARTIAL`, `PARTIAL_REASON`; computes wall and totals |
| `trg_assessment_budget` | `assessment` | `ASSESSMENT_AUTHOR`, `BUDGET_SILENT_TRUNCATION`, `BUDGET_NOT_EXCEEDED`; sets `freshness_flag`, budget error text |
| `trg_attempt_policy` | `attempt` | `MAX_ATTEMPTS`, `ATTEMPT_SEQUENCE`, `RETRY_NOT_ALLOWED`, `BACKOFF_TOO_SHORT`, `BACKOFF_NOT_WAITED` |
| `trg_message_typed` | `message` | `MESSAGE_IMMUTABLE`, `MESSAGE_SHAPE`, `MESSAGE_PARTY`; assigns `seq` |
| `trg_llm_lease_exclusive` | `llm_lease` | `GPU_SEMAPHORE` |
| `trg_circuit_transition` | `circuit_state` | `CIRCUIT_TRANSITION`; writes `circuit_event` |
| `trg_finding_author` | `agent.finding` (INSERT) | `FINDING_AUTHOR`, `DOMAIN_VIOLATION`, `EVIDENCE_SHAPE` |
| `trg_finding_lifecycle` | `agent.finding` (UPDATE) | `FINDING_IMMUTABLE`, `LIFECYCLE_TRANSITION`, `ACTION_REQUIRED`, `RESOLUTION_REQUIRED` |
| `trg_finding_ext_active` | `agent.finding` (after UPDATE OF status) | keeps `finding_ext.active` |
| `trg_finding_action` | `finding_action` | `SNOOZE_UNTIL`, `REOPEN_ONLY_TERMINAL`; performs the transition inside the action context |
| `trg_risk_score_computed` | `risk_score` | `SCORE_FOREIGN_FINDING`, `SCORE_NOT_COMPUTED`; fills the factors |
| `trg_compound_components` | `compound_risk` | `COMPOUND_NEEDS_TWO`, `COMPOUND_FOREIGN_FINDING`, `COMPOUND_SINGLE_DOMAIN`, `COMPOUND_KEY_MISMATCH`, `COMPOUND_SCORE`, `COMPOUND_BELOW_COMPONENT` |
| `trg_briefing_grounded` (a.k.a. *trg_briefing_partial*) | `briefing_run` | `BRIEFING_RUN_STATUS`, `BRIEFING_FOREIGN_FINDING`, `BRIEFING_PARTIAL_MISMATCH`, `BRIEFING_PARTIAL_REASON`, `BRIEFING_UNGROUNDED`; stores the claim check |
| `trg_delivery_critical` | `agent.finding` | inserts an `immediate` delivery for CRITICAL |
| `trg_*_append_only` | `finding_occurrence`, `finding_action`, `attempt` | `APPEND_ONLY` |

---

## 6. Views (section 17)
`v_blackboard` (FR-23/FR-30: findings with key, factors, stale flag, owner, latest score, reporters), `v_finding_evidence` (AC-03: every evidence item per agent and run), `v_run_board`, `v_run_trace`, `v_briefing_latest`, `v_agent_health` (circuit, domains, tools, last outcome, averages, failures), `v_agent_precision` (last 90 days), `v_compound_explain` (each component's four factors), `v_budget_usage` (usage vs budget with the violation text), `v_scenario_gate`.

## 7. Indexes, sizing, retention
40 indexes: the platform's on `core`/`agent`/`audit` plus `swarm` indexes on runs by time/status, assessments by run and agent, messages by run/seq and type, leases by time, occurrences by finding and run, actions, scores and compounds by run/rank, pending deliveries, active scope lines, snoozes, scenario results, metrics.

Sizing (two scheduled runs a day, 4–8 agents): ≈ 30 messages and ≈ 25 tool-call rows per run → ≈ 40 k rows a year; findings a few hundred; everything fits a small VPS. Retention ≥ 365 days for runs, messages, findings, briefings (NFR-05, `retention_days` CHECK ≥ 365); tool-result caches live in Redis for the run only.

## 8. Roles (section 18)
| Role | Can | Cannot |
|---|---|---|
| `app_rw` (api) | people's actions (`finding_action`), registry, rules, weights, scenarios, exports, questions, runs (trigger) | write findings, occurrences, messages, scores directly (status changes only through actions) |
| `orchestrator_rw` | insert runs, assessments, attempts, messages, leases, occurrences, scores, compounds, briefings, deliveries; update runs, assessments, circuits, extensions, scores, compounds | UPDATE/DELETE on messages, occurrences, attempts, actions; read `core.app_user` / `user_line_scope` |
| `app_ro` (dashboard) | read all, users only `id, display_name, role` | write |
| `auditor_ro` | runs, messages, assessments, attempts, leases, findings, occurrences, actions, scores, compounds, briefings, exports, registry history, audit log | write, credentials |

---

## 9. The seed and its expected values (`db/seed_demo.sql`)

Plant 1, lines 1–3, machines M-01 / M-07 (line 3) / M-12 (line 2), SKU RAD-500-A, lot LOT-2609-114; five users; 18 tools (17 read, one disabled write tool for the probe); registry of four specialists + `manager` + a disabled `logistics` placeholder (FR-06); weights `v1`; four relation rules. Eleven runs on 2026-09-07…11:

| Run | What it proves | Expected |
|---|---|---|
| 405–410 | routine runs; the line-2 scratch signal (405) dismissed as a false positive; M-07 first seen in 407 | M-07 occurrences 5 through 411 (**AC-08**) |
| **411** | **Appendix A** — 4 agents, 23 tool calls, 2 min 14 s, sequential leases | scores quality **0.6800** (0.8 × 1.0 × 1.0 × 0.850), maintenance **0.4992** (0.8 × 1.0 × 0.8 × 0.780), material **0.7120**, production **0.5184**; compound `same_line` line 3 = 1 − 0.32 × 0.5008 = **0.8397** (≥ both, **AC-04**), owner "Maintenance + QE"; top 3 = compound 0.84, material 0.71, production 0.52; EN/TH/JA briefings, 31 numeric tokens each, **all matched** (**AC-07**); Discord + dashboard deliveries |
| 412 | Maintenance runner killed → `timeout`; partial (**AC-02**); quality and material both report the lot → one finding, 2 occurrences, 3 distinct evidence items (**AC-03**) | compound `same_sku` "SKU RAD-500-A — compound risk: material + quality" **0.9327** (1 − 0.32 × 0.73 × 0.288); partial reason "maintenance: timeout after 60 s" |
| 413 | Production's 13th tool call refused → `budget_exceeded`, `incomplete` (**AC-05**); CRITICAL M-12 → immediate delivery (FR-29) | order M-12 **0.9100** / compound 0.8397 / material 0.7200; violation "tool_calls 13 > 12" |
| 414 | Maintenance malformed output twice → `invalid_output`, blackboard unchanged (**AC-06**); line 1 OEE expires (**FR-27**) | attempts 1 and 2 `invalid_output`; resolution "condition cleared: not reported by production in runs 412, 414"; the lot expires too ("… material in runs 413, 414; quality in runs 413, 414") |
| 415 | question "Is line 3 at risk this shift?" (FR-21) | compound 0.84 for line 3; claim-checked answer |
| actions | acknowledge, assign, snooze (FR-25), resolve M-12; precision quality 3 / 1 / 1 → **0.6667** (FR-26) | |
| suite | 15 scenarios, `run_suite('v1')` | **14 / 15 = 0.9333 ≥ 0.80**, 0 fabricated, SC-15 the deliberate miss (**AC-01**, deterministic half) |
| totals | | 11 runs, 151 messages, 7 findings, 20 occurrences, 4 compounds, 12 briefings, 179 tool calls, 43 leases, 7 actions; export sha256 of run 411's message log `9153967a…d636` |

The `\echo` block at the end prints each of these; 16 probes must each fail with the named guard (TEST-13 TC-003).

---

## 10. Verification (what was executed here)

| Check | Result |
|---|---|
| Block and object identity vs `00/db/schema.sql` (TC-002) | ✅ 14/14 blocks, 66/66 objects byte-identical |
| Static DDL (TC-003): balance, FK targets and order, PKs, 19 guard triggers present, trigger functions defined before use, grants | ✅ |
| Twins vs Python (TC-005): scores, compounds, keys, ranking, dedupe, expiry, backoff, circuit, budget, precision, scenario suite, **claim check of every briefing text and the FR-21 answer against the corpus as it was at insert time** | ✅ `ALL SEED CHECKS OK: True` |
| PostgreSQL execution (TC-009) | ⚠️ **not executed** — no Docker daemon on the authoring machine |

## 11. Defects found while checking (fixed)
D1 a compound group with one merged finding but two domains produced a single-component compound → groups need ≥ 2 rows; D2 domain counting via occurrences made "quality + quality-reported-by-material" a compound on line 3 → a finding's domain is its first reporter's (IF-69 §3); D3 the claim corpus must be the state at insert time (later runs overwrite summaries) → the checker snapshots per run; D4 a question run (narrow scope) cleared plant-wide issues → only scheduled runs expire; D5 `max()` on an enum, `at`/`out`/`precision` used as identifiers, a `HAVING` on an ungrouped column → rewritten; D6 a routine briefing said "TOP 0" on a quiet run → the template always says "TOP 3"; D7 a partial briefing named machines it did not cite → text rewritten (the guard did its job).

## 12. Traceability
C-01 → DD-K06 · C-02 → DD-K01, `evidence_ok` · C-03 → DD-K09 · C-04 → DD-K05 · C-05 → DD-K07 · C-06 → DD-K05, `trg_run_status` · FR-01/06 → §3.1 · FR-02/07 → DD-K06 · FR-05 → DD-K07 · FR-13 → §1.2, DD-K05 · FR-14/22 → DD-K01 · FR-16/24 → DD-K03 · FR-17/18 → DD-K02 · FR-19/20 → DD-K04 · FR-23/25/26/27 → DD-K08 · FR-29 → `trg_delivery_critical` · AI-02 → `trg_attempt_policy` · AI-03/04 → DD-K02 · AI-06 → §3.4, `run_suite` · AI-07 → `freshness_flag` · AI-08 → DD-K05 · NFR-05 → §7, `export` · NFR-07 → `agent_metric` · AC-01…09 → §9.
