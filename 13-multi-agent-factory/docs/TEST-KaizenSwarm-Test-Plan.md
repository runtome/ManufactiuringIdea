# Test Plan and Test Cases — KaizenSwarm (Multi-Agent Factory System)

| Field | Value |
|---|---|
| Document ID | TEST-13-KaizenSwarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-21 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-13](../SRS-KaizenSwarm-Multi-Agent-Factory.md) §8 (AC-01…AC-09) · [SAD-13](SAD-KaizenSwarm-Software-Architecture.md) · [DDS-13](DDS-KaizenSwarm-Database-Design.md) · [ICD-13](ICD-KaizenSwarm-Interface-Control.md) · [SEC-13](SEC-KaizenSwarm-Security-Requirements.md) |
| Parent | [TEST-00](../../00-factorybrain-platform/docs/TEST-FactoryBrain-Test-Plan.md) TS-12 (TC-131…TC-136 are the platform's view of AC-02…AC-08) |

---

## 1. Strategy

Three layers, in the order they can be run:

1. **Static and re-derived (TS-0)** — executed on the authoring machine: identity of the extracted platform sections, static DDL, the Python twins of every deterministic function against the seed, the message / registry / scenario / export schemas with negatives, the OpenAPI document and its identity with API-00, the compose file. These stand in for TC-009 until PostgreSQL runs.
2. **Database (TS-0 TC-009, and every `TC-003 P-nn`)** — `schema.sql` + `seed_demo.sql` on PostgreSQL 16; the `\echo` block matches DDS-13 §9; the 16 probes each fail with the named guard.
3. **Integration and fault injection (TS-1…TS-11)** — orchestrator, runners, NATS, Ollama, sibling stubs; the scenario suite in full mode; killed processes, broken outputs, exhausted budgets.

Coverage target: ≥ 80 % on orchestrator, scoring and schema validation (NFR-08) — scoring and validation are SQL functions with Python twins, so most of the coverage is TS-0.

## 2. Test suites

| Suite | Scope | SRS |
|---|---|---|
| TS-0 | Static, identity, twins, contracts | all |
| TS-1 | Framework: registry, bus, budgets, semaphore, retries, circuit, schedule | FR-01…FR-07, C-01, C-04, C-05, AI-05, AI-08 |
| TS-2 | Specialists: outputs, grounding, nothing-significant, domain boundary, self-report | FR-08…FR-14, AI-01, AI-02, AI-07 |
| TS-3 | Tools (IF-16 as consumer): read-only, scope, timeouts, trace | C-03, NFR-06 |
| TS-4 | Blackboard: authorship, issue keys, dedupe, recurrence, evidence | FR-12, FR-16, FR-23, FR-24, AC-03, AC-08 |
| TS-5 | Manager: requests, scoring, compounds, ranking, briefing, claim check, questions | FR-15…FR-22, AI-03, AI-04, AC-04, AC-07 |
| TS-6 | Lifecycle: actions, dismissals, precision, expiry | FR-25, FR-26, FR-27 |
| TS-7 | Scenario suite and gate | AI-06, AC-01 |
| TS-8 | Resilience and fault injection | C-06, NFR-01…NFR-04, AC-02, AC-05, AC-06 |
| TS-9 | Delivery | FR-28…FR-31 |
| TS-10 | Audit, export, observability | FR-07, FR-30, NFR-05, NFR-07, AC-09 |
| TS-11 | Security | SEC-K01…K34 |

Columns: **M** = method (S static · P Python re-derivation · D database · I integration · F fault injection · R review), **Pri** 1 highest.

## 3. Test cases

### TS-0 — Static, identity, twins, contracts
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-001 | OpenAPI document valid | API-13 | `check_openapi.py api/openapi.yaml` | valid; 54 paths / 59 operations / 54 schemas; no undefined or orphan refs; every op has a 2xx | S | 1 |
| TC-002 | Extracted platform sections byte-identical | DDS-13 §1 | `check_schema13.py` block and object diff vs `00/db/schema.sql` | 14/14 blocks, 66/66 objects identical; nothing module-only in sections 1–9 | S | 1 |
| TC-003 | Static DDL and the probes | DDS-13 §3–§8 | balance, FK targets/order, PKs, 19 guard triggers, functions before use, grants; then `seed_demo.sql` probes P-01…P-16 on PostgreSQL | all checks pass; each probe fails with its named guard (`finding_has_evidence`/`EVIDENCE_SHAPE`, `FINDING_AUTHOR`, `DOMAIN_VIOLATION`, `SCORE_NOT_COMPUTED`, `COMPOUND_NEEDS_TWO`, `COMPOUND_SCORE`, `BRIEFING_UNGROUNDED`, `BRIEFING_PARTIAL_MISMATCH`, `BUDGET_SILENT_TRUNCATION`, `MESSAGE_SHAPE`, `GPU_SEMAPHORE`, `TOOL_NOT_READ_ONLY`, `MAX_ATTEMPTS`, `ACTION_REQUIRED`, `MESSAGE_IMMUTABLE`, `MANAGER_REQUIRED`) | S/D | 1 |
| TC-004 | Compose, env, secrets, networks | OPS-13, SEC-K10, K30, K33, K34 | `check_deploy13.py` | 13 services; every `${VAR}` in `.env.example` and vice versa; `discord-bot` alone on `egress`; `agent-runner` alone on `sources`; postgres/nats/redis/ollama internal-only; runner without DB or Discord secrets; hardening on app services; no secret values in the repository | S | 1 |
| TC-005 | Twins vs the seed | DDS-13 §4, §9 | `check_seed13.py` | scores 0.6800 / 0.4992 / 0.7120 / 0.5184; compound 0.8397; ranking; M-07 occurrences 5 through 411; lot dedupe (2 occurrences, 3 evidence, expiry text); 412 compound 0.9327; 413 order; budget verdicts; backoff series; circuit sequence; precision 0.6667; expiry of line 1 OEE; suite 14/15; **every briefing text and the FR-21 answer claim-checked against the corpus as it was at insert time**; message count 151; export sha256 | P | 1 |
| TC-006 | Contracts: message schemas, registry, scenario suite, export | ICD-13 IF-17, IF-68, IF-69, IF-71, IF-72 | `check_contracts13.py` | 16 seed Finding payloads valid; the SRS §5 example valid once `plant` and the four IF-69 fields are added (verbatim it is rejected — recorded); 12 Finding negatives, 2 request, 3 status, 2 error, 1 clarification rejected; registry example valid, 8 negatives; suite valid (15), 6 negatives; `run-trace-411.json` valid and its sha256 equals the seed's | S | 1 |
| TC-007 | Configuration schema | OPS-13 §6 | `check_config13.py` | `kaizenswarm.example.yaml` valid; negatives rejected (semaphore 2, gate 0.7, temperature 0.5, model 13 B, attempts 3, budget 0, agent timeout > run wall, weights not monotone, urgency > 1, circuit threshold 0, freshness 0, retention 30, top-N 0, expiry 0, unknown rule key, min_domains 1, langs empty, webhook not allow-listed …) | S | 1 |
| TC-008 | Identity with API-00 | API-13 §1 | `check_api_identity13.py` | 16/16 blocks byte-identical (`/agent/findings`, `/agent/briefing`, 6 schemas, 3 parameters, 5 responses); SRS §4.1 seven paths verbatim with their query parameters | S | 1 |
| TC-009 | Schema and seed on PostgreSQL 16 | DDS-13 §9 | OPS-13 §12 commands | `\echo` block equals DDS-13 §9; probes as TC-003 | D | 1 |

### TS-1 — Framework
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-010 | Registry defines an agent | FR-01, IF-68 | import `agents.example.yaml`; `GET /agents` | six entries with domains, tools, budget, schedule, enabled; manager present | I | 1 |
| TC-011 | Messages validated on both ends | FR-02, C-01 | publish a `Finding` with `evidence: []` from a runner | runner refuses to publish; if forced, the orchestrator drops it with `MESSAGE_SHAPE` in the log; no row | I | 1 |
| TC-012 | Bus accounts isolate agents | C-01, SEC-K12 | as the `quality` account publish on `agent.finding.maintenance` | NATS authorization error; nothing persisted | I | 1 |
| TC-013 | Module loaded only from the package | FR-06, SEC-K13 | registry `module: os.system` | import refused with `422`; agent not enabled | I | 2 |
| TC-014 | A fifth agent by configuration | FR-06, NFR-04 | enable `logistics` with a stub module; trigger a run | five assessments; the Manager's code unchanged; briefing includes the domain | I | 1 |
| TC-015 | Budgets enforced by the orchestrator | C-04, AI-08, SEC-K14 | module calls 13 tools | 13th refused at the tool gateway; `Clarification{budget_stop}`; assessment `budget_exceeded`, `incomplete` | I | 1 |
| TC-016 | One inference at a time | C-05, FR-04, SEC-K16 | four agents reach phrasing together | leases strictly sequential in `swarm.llm_lease`; Ollama concurrency observed = 1; a runner calling Ollama without the lease header is refused | I | 1 |
| TC-017 | Retries, backoff, circuit | FR-05 | transport errors 1, 2, 3 in consecutive runs | attempts with backoff 2 s → 4 s; third failure opens the circuit; assessment `circuit_open` for 15 min; half-open probe closes it | I | 1 |
| TC-018 | Replay is idempotent | SEC-K23 | redeliver a `Finding` with the same `Nats-Msg-Id` | de-duplicated by JetStream; if it arrives, `occurrence_unique` refuses a duplicate | I | 2 |
| TC-019 | Scheduled and on-demand runs | FR-03 | cron 06:00/14:00; `POST /runs` at 10:00 | three runs with `trigger` schedule/schedule/on_demand; briefings only for scheduled runs delivered to Discord by default | I | 2 |

### TS-2 — Specialists
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-020 | Quality agent output | FR-08 | stub QE with S-241 open and a defect signal | findings with evidence `signal:S-241`, affected SKU/lot, open case; `quality.defect_rate` issue code | I | 1 |
| TC-021 | Output schema-validated, one retry | AI-02 | model returns prose, then valid JSON | attempt 1 `invalid_output`, attempt 2 ok; `agent.run.outcome ok`; two leases | I | 1 |
| TC-022 | Maintenance agent output | FR-09 | stub MachineSense with alert 1184 and a declining health index | `machine.degradation` finding with metric and alert evidence, lead time in `horizon` | I | 1 |
| TC-023 | Production agent output | FR-10 | stub ShiftBrief line 1 performance 78 % vs 91 % | `production.performance_loss` with `oee:` and `downtime:` evidence | I | 1 |
| TC-024 | Grounding: numbers only from facts | AI-01, SEC-K02 | inject a model output with "6.1 %" absent from facts | runner rejects; retry; then `Error`; no finding | I | 1 |
| TC-025 | Material agent output | FR-11 | stub ERP: coverage 1.4 d, PO due 09-14, lot history | `material.shortage` and `lot.quality_history` findings; freshness 360 min flagged | I | 2 |
| TC-026 | Nothing significant is explicit | FR-13 | quiet plant | every assessment `nothing_significant` with `checked[]`; briefing lists the domains | I | 1 |
| TC-027 | Domain boundary | FR-14 | quality module emits `machine_health` | `DOMAIN_VIOLATION`; assessment `invalid_output` | I | 1 |
| TC-028 | Confidence and freshness reported | AI-07 | ERP data 6 h old | `freshness_min 360`, `freshness_flag true`, ⚠ in the briefing; confidence discounted by the module | I | 2 |
| TC-029 | The model sees only the facts object | AI-01, SEC-K01 | capture the prompt | no raw tool text beyond typed facts; free text labelled data, ≤ 300 chars | I | 1 |

### TS-3 — Tools (IF-16 as consumer)
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-030 | Only read tools bind | C-03, SEC-K08 | bind `create_work_order` | `TOOL_NOT_READ_ONLY` (probe P-12); `PATCH /agents/{name}` returns 409 | D/I | 1 |
| TC-031 | Scope passed and enforced | SEC-K26 | run scope line 3; stub returns line 2 rows | rows dropped before the facts object; recorded in the tool-call digest | I | 1 |
| TC-032 | Tool timeout | FR-05 | stub sleeps 20 s | `tool_error` after 10 s; the agent continues with the remaining facts or reports `failed` | I | 2 |
| TC-033 | Every tool call recorded | AC-09 | run 411 | 23 `agent.tool_call` rows with args, digest, rows, duration, ok | I | 1 |
| TC-034 | Providers per mode | ICD-13 IF-16 | standalone with `sibling-stub`; platform mode | same tool names; provider from the registry; credentials read-only | I | 2 |

### TS-4 — Blackboard
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-040 | Author, domain, evidence guards | C-02, FR-14, FR-22 | probes P-01…P-03 | refused | D | 1 |
| TC-041 | Issue key families | FR-16, IF-69 §3 | keys for machine/lot/sku/material/quality codes | `machine.degradation|machine=M-07,plant=1`, `lot.quality_history|lot=LOT-2609-114,plant=1`, `material.shortage|plant=1,sku=RAD-500-A`, `quality.defect_rate|line=3,plant=1`; shift ignored | P/D | 1 |
| TC-042 | Same issue from two agents → one finding | AC-03 | run 412 | one row, 2 occurrences, reporters material,quality, 3 distinct evidence items | P/D | 1 |
| TC-043 | Recurring condition updates, not duplicates | AC-08, FR-24 | runs 407…411 | one row for M-07, `occurrences = 5`, `first_seen 2026-09-08 06:00`, `last_seen 2026-09-10 06:00` | P/D | 1 |
| TC-044 | Evidence union keeps every set | AC-03 | `v_finding_evidence` for the lot | 4 rows (2 per agent), 3 distinct refs | D | 2 |
| TC-045 | Occurrences append-only | SEC-K19 | UPDATE an occurrence | `APPEND_ONLY` | D | 2 |
| TC-046 | Blackboard query | FR-23 | `GET /findings?status=in_progress&severity=HIGH` | M-07 and S-241 with latest scores and reporting agents | I | 2 |
| TC-047 | Merged finding keeps the first reporter's domain | IF-69 §3 | run 412 line-3 group | no compound from quality + quality; the SKU compound instead | P/D | 2 |
| TC-048 | Severity is the maximum on merge | DD-K03 | MEDIUM then HIGH payloads for one key | severity HIGH | P | 3 |
| TC-049 | Latest factors on merge | DD-K03 | confidence 0.80 then 0.75 | stored confidence 0.75; score 0.2700 | P | 3 |

### TS-5 — Manager
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-050 | Requests to every enabled specialist | FR-15 | run 411 | four `RequestAssessment` with budgets and deadline; `logistics` (disabled) not requested | I | 1 |
| TC-051 | Score function | FR-18, AI-03 | the four Appendix A findings | 0.6800, 0.4992, 0.7120, 0.5184 with factors as DDS-13 §9 | P/D | 1 |
| TC-052 | Score cannot be supplied | AI-03, SEC-K04 | probe P-04 | `SCORE_NOT_COMPUTED` | D | 1 |
| TC-053 | Compound detection | FR-17, AI-04 | run 411 | `same_line` on line 3: quality + maintenance; rationale names rule, key, component scores | P/D | 1 |
| TC-054 | Compound outranks its parts | AC-04 | run 411; probe P-06 | 0.8397 ≥ 0.6800 and 0.4992; rank 1; a compound below noisy-OR refused | P/D | 1 |
| TC-055 | Ranking and absorption | FR-18, FR-19 | run 411 ranking | compound, material 0.7120, production 0.5184; components `absorbed_by` set; top-3 printed 0.84 / 0.71 / 0.52 | P/D | 1 |
| TC-056 | Rule order: first match absorbs | AI-04 | run 412 | `same_line` finds one domain only → `same_sku` builds the 3-way compound 0.9327 | P/D | 2 |
| TC-057 | Claim check refuses an invented number | FR-22, AC-07 | probe P-07; then a model phrasing with "6.10 %" | `BRIEFING_UNGROUNDED`; orchestrator retries once with the tokens listed; then `template_fallback = true` | D/I | 1 |
| TC-058 | The Manager's model gets only the ranked list | SEC-K07 | capture the briefing prompt | `top_risks_json` only; no tool results, no message payloads | I | 1 |
| TC-059 | Ad-hoc question | FR-21 | run 415 "Is line 3 at risk this shift?" | scope line 3; four targeted assessments; answer with the compound 0.84; claim-checked; no new reasoning path | P/I | 2 |

### TS-6 — Lifecycle
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-060 | Status changes only through actions | FR-25, SEC-K20 | probe P-14; `POST /findings/{id}/ack` | direct update `ACTION_REQUIRED`; action row performs `new → acknowledged` | D/I | 1 |
| TC-061 | Dismissal needs a reason code | FR-25, FR-26 | dismiss without `dismiss_reason` | `422`; with `false_positive` → dismissed, resolution text stored | I | 1 |
| TC-062 | Snooze | FR-25 | snooze the shortage until 08:00 | status unchanged; `snoozed_until` set; past date `SNOOZE_UNTIL` | I | 2 |
| TC-063 | Resolve and reopen | FR-23 | resolve M-12; reopen | resolved with resolution; reopen → new, resolution cleared; reopen of an active finding `REOPEN_ONLY_TERMINAL` | I | 2 |
| TC-064 | Precision report | FR-26 | `agent_precision(quality, 2026-09-01, 2026-09-30)` | 3 findings, 1 dismissed, 1 false positive, 0.6667 | P/D | 1 |
| TC-065 | Expiry when the condition clears | FR-27 | runs 412…414 | line 1 OEE `expired` after 414 with "not reported by production in runs 412, 414"; the lot after material and quality both reported twice | P/D | 1 |
| TC-066 | Expiry ignores failures and question runs | FR-27 | maintenance timeout in 412; question run 415 | M-07 not expired by 412 (timeout is not a report); nothing expires in 415 | P/D | 2 |

### TS-7 — Scenario suite
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-070 | Deterministic suite | AI-06, AC-01 | `run_suite('v1')` | 15 scenarios, 14 matches (0.9333 ≥ 0.80), 0 fabricated, `passed`; SC-15 the documented disagreement; twin agrees on all 15 rankings | P/D | 1 |
| TC-071 | Full suite with the model | AI-06 | CI with Ollama | each scenario phrased; claim check zero unmatched; top-3 ≥ 80 % | I | 1 |
| TC-072 | The gate blocks activation | ADR-K10 | publish `v2` with a broken table; activate | `409 SCENARIO_GATE` until a suite run with `v2` passed | I | 2 |

### TS-8 — Resilience and fault injection
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-080 | Full run ≤ 3 min | NFR-01 | 4 agents on the baseline GPU, 10 runs | p95 ≤ 180 s; seed reference 134 s | I | 1 |
| TC-081 | Maintenance runner killed mid-run | AC-02, C-06, NFR-03 | `kill -9` after `started` | assessment `timeout` at 60 s; three domains intact; briefing `partial`, reason "maintenance: timeout after 60 s"; run 412 in the seed | F | 1 |
| TC-082 | Run wall clock | NFR-01, SEC-K18 | an agent that never answers | run ends at 180 s; outstanding assessments `timeout` | F | 1 |
| TC-083 | Budget exceeded | AC-05 | production module loops on tools | 13th call refused; `budget_exceeded`, `incomplete`; partial briefing names production; run 413 | F | 1 |
| TC-084 | Circuit opens | FR-05 | three consecutive failures | `open`; next run `circuit_open` without a request; half-open after 15 min | F | 1 |
| TC-085 | Malformed output twice | AC-06 | model returns prose twice | attempts 1, 2 `invalid_output`; `Error`; finding count unchanged; run 414 | F | 1 |
| TC-086 | Bus restart | IF-17 | restart NATS mid-run | JetStream redelivers unacked requests; no duplicate assessments | F | 2 |
| TC-087 | Model down | IF-09 | stop Ollama | every phrasing `transport_error` → `failed`; briefing partial for all domains with the template text | F | 1 |
| TC-088 | Eight agents | NFR-04 | register 8 specialists with stub modules | run completes ≤ 3 min with 2 runner replicas; no orchestrator change | I | 2 |

### TS-9 — Delivery
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-090 | Discord at shift start | FR-28 | run 411 | one message per language configured; the stored text; `delivery.sent` with message ref | I | 1 |
| TC-091 | CRITICAL pushed immediately | FR-29 | M-12 finding at 06:01 | `immediate` delivery within 1 min, outside the schedule | I | 1 |
| TC-092 | Thai / Japanese / English | FR-31 | run 411 | three rows with the same `top_risks_json`; each claim-checked (31 tokens matched) | P/I | 2 |
| TC-093 | Fallback channel | IF-13, SEC-K29 | Discord down | webhook/email from the allow-list; dashboard always | I | 3 |

### TS-10 — Audit, export, observability
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-100 | History immutable and audited | NFR-05, SEC-K19 | probe P-15; registry edit | `MESSAGE_IMMUTABLE`; `registry_change` and `audit.log` rows | D | 1 |
| TC-101 | Trace reconstructs a run | AC-09, FR-07 | `run_trace(411)` / `GET /runs/{id}/trace` | 20 messages, 4 LLM runs, 23 tool calls, 4 leases in time order; every message's payload | P/D | 1 |
| TC-102 | Export hash | NFR-05, IF-72 | `GET /runs/{id}/export` | `message_log_sha256` = `swarm.export.sha256` = `9153967a…d636` for the seed's run 411 | P/D | 2 |
| TC-103 | Retention | NFR-05 | retention job with `retention_days` 365 | nothing younger removed; `retention_days < 365` refused by CHECK | D | 3 |
| TC-104 | Dashboard trace and health | FR-30 | open run 413, agents page | assessments with usage vs budget, the partial reason, circuit states | I | 2 |
| TC-105 | Metrics per agent per run | NFR-07 | scrape `/metrics` after run 411 | tokens, latency, tool calls, outcome per agent; `swarm_briefing_partial_total` | I | 2 |

### TS-11 — Security
| ID | Title | Traces | Steps | Expected | M | Pri |
|---|---|---|---|---|---|---|
| TC-110 | Injection corpus through tool results | SEC-K01, THR-K01 | 30 tool payloads with instructions in free text | no instruction followed; no ungrounded number; findings unchanged | I | 1 |
| TC-111 | Read-only credentials | SEC-K09, NFR-06 | attempt a write with each sibling/ERP account | refused at the provider | I | 1 |
| TC-112 | Forged subject | SEC-K12 | payload agent ≠ subject agent | dropped and logged | I | 1 |
| TC-113 | Registry changes audited; manager protected | SEC-K22 | disable `quality`; disable `manager` | `registry_change` row with actor; `MANAGER_REQUIRED` | D/I | 2 |
| TC-114 | Replay | SEC-K23 | replay run 411's request log | no second assessment; `assessment_one_per_agent` | I | 2 |
| TC-115 | Scope filtering | SEC-K25 | user scoped to line 1 reads the 411 briefing | only the line 1 item; a note that plant-level items are withheld | I | 1 |
| TC-116 | Bot posts by id only | SEC-K28 | send the bot a free-text command | ignored; only `/briefing` (read) exists | I | 2 |
| TC-117 | Roles | SEC-K31 | each role against API-13 §9 | matrix holds; `403` otherwise | I | 1 |
| TC-118 | Rate limit | SEC-K32 | 20 `POST /runs` in a minute | `429` after the limit; GPU not monopolised | I | 3 |

## 4. Acceptance criteria map
| AC | Test cases |
|---|---|
| AC-01 | TC-070, TC-071 |
| AC-02 | TC-081 (seed run 412) |
| AC-03 | TC-042, TC-044 (seed run 412) |
| AC-04 | TC-054 (seed run 411, probe P-06) |
| AC-05 | TC-083, TC-015 (seed run 413, probe P-09) |
| AC-06 | TC-085, TC-021 (seed run 414) |
| AC-07 | TC-057, TC-092 (seed briefings, probe P-07) |
| AC-08 | TC-043 (seed runs 407…411) |
| AC-09 | TC-101, TC-033 (seed run 411, export) |

## 5. Defects found while authoring (all fixed)
| ID | Where | Defect | Fix |
|---|---|---|---|
| D1 | `rank_findings`, `detect_compounds` | a group with one merged finding but two domains produced a one-component compound | groups need ≥ 2 rows |
| D2 | `detect_compounds` | counting reporting agents per group made "quality + quality-corroborated-by-material" a line-3 compound in run 412 | a finding's domain is its first reporter's (IF-69 §3); the SKU compound results |
| D3 | `check_seed13.py` | claim corpus built from the final state, but later runs overwrite summaries | per-run snapshots; every text re-checked as at insert time |
| D4 | `expire_findings` | a question run (line 3 only) would have cleared plant-wide issues | scheduled runs only |
| D5 | `db/schema.sql` | `max()` on an enum; `at`, `out`, `precision` as identifiers; `HAVING` on an ungrouped column | rewritten |
| D6 | seed | a quiet routine run said "TOP 0 RISKS" — `0` was not in the corpus | the template always says "TOP 3" |
| D7 | seed | partial briefings named machines they did not cite (`07`, `12` unmatched) | texts rewritten — the guard worked |
| D8 | `openapi.yaml` | duplicate `operationId: getBriefing` | renamed `getBriefingById` |
| D9 | tooling | heredocs collapse `\\` in this shell | schemas and Python written with the file tool |

## 6. Environments
| Layer | Environment |
|---|---|
| TS-0 | authoring machine: Python 3.14, `jsonschema`, `openapi-spec-validator`, `pyyaml` |
| TC-009, probes | PostgreSQL 16 (`pgvector/pgvector:pg16` image), `psql -v ON_ERROR_STOP=1` |
| TS-1…TS-11 | compose `dev` profile: orchestrator, agent-runner, nats, redis, postgres, ollama-cpu, sibling-stub, mailpit; GPU host for TC-080 |
| TC-071 | CI job with the model (nightly) |

## 7. Execution record (this revision)
| Suite | Result |
|---|---|
| TS-0 TC-001 | ✅ valid; 54 / 59 / 54; no orphans |
| TS-0 TC-002 | ✅ 14/14 blocks, 66/66 objects |
| TS-0 TC-003 (static part) | ✅ balance, FKs, PKs, 19 guards, grants; probes present |
| TS-0 TC-004 | ✅ see OPS-13 §12 |
| TS-0 TC-005 | ✅ `ALL SEED CHECKS OK: True` (scores, compounds, dedupe, expiry, precision, suite, claim checks of 6 texts + 6 routine templates + the FR-21 answer) |
| TS-0 TC-006 | ✅ 26 positives, 35 negatives rejected; export example valid, sha256 equal |
| TS-0 TC-007 | ✅ see OPS-13 §12 |
| TS-0 TC-008 | ✅ 16/16; 7/7 |
| TS-0 TC-009 | ⚠️ not executed — no PostgreSQL on the authoring machine |
| TS-1…TS-11 | ⚠️ specified, not run (no orchestrator implementation yet; no NATS/Ollama here) |
