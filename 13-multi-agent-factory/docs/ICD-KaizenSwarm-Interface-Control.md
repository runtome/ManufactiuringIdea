# Interface Control Document — KaizenSwarm (Multi-Agent Factory System)

| Field | Value |
|---|---|
| Document ID | ICD-13-KaizenSwarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-21 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-13](../SRS-KaizenSwarm-Multi-Agent-Factory.md) §4 · [SAD-13](SAD-KaizenSwarm-Software-Architecture.md) |
| Parent | [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) — IF-17 is elaborated here as the implementing specification; IF-08, IF-09, IF-13, IF-14, IF-16 are consumed |
| Siblings | [ICD-09](../../09-quality-engineer-agent/docs/ICD-QEAgent-Interface-Control.md) (QE tools) · [ICD-06](../../06-predictive-maintenance-agent/docs/ICD-MachineSense-Interface-Control.md) (MachineSense tools) · [ICD-02](../../02-production-ai-analyst/docs/ICD-ShiftBrief-Interface-Control.md) (ShiftBrief tools) · [ICD-10](../../10-factory-copilot/docs/ICD-Copilot-Interface-Control.md) (IF-16 as consumer, precedent) |

---

## 1. Interface register

Shared `IF-xx` numbering with the platform (IF-01…IF-17) and the siblings (IF-18…IF-67). New here: **IF-68…IF-72**.

| ID | Interface | Parties | Protocol | Criticality | Here |
|---|---|---|---|---|---|
| [IF-08](#if-08) | Discord | Deliverer, Discord | WSS + HTTPS | Medium | briefings at shift start; CRITICAL pushes; TH/JA/EN |
| [IF-09](#if-09) | LLM runtime | Agent runner / Manager, Ollama | HTTP/JSON | High | one shared model, one lease at a time, versioned prompts |
| [IF-13](#if-13) | SMTP & webhook | Deliverer | SMTP / HTTPS | Low | fallback channel |
| [IF-14](#if-14) | Metrics scrape | Prometheus, services | HTTP/text | Medium | tokens, latency, tool calls, outcomes per agent per run |
| [IF-16](#if-16) | Agent tool contract (as consumer) | Agent runner, 09 / 06 / 02 / IF-07 adapter | in-process typed / HTTPS | **Critical** | the specialists' read tools |
| [IF-17](#if-17) | **Inter-agent message bus** | Orchestrator, Manager, specialists | NATS JetStream | **Critical** | **the implementing specification** |
| [IF-68](#if-68) | Agent registry & tool-module contract | Admin, agent runner | YAML + Python module | High | FR-01, FR-06 |
| [IF-69](#if-69) | Finding & blackboard contract | Specialists, orchestrator, UI | JSON Schema + DB | **Critical** | FR-12, FR-16, FR-23…FR-27 |
| [IF-70](#if-70) | Scoring & relation-rule contract | Admin, orchestrator | rows + YAML | High | FR-18, AI-03, AI-04 |
| [IF-71](#if-71) | Scenario suite | ML owner, CI | YAML | Medium | AI-06, AC-01 |
| [IF-72](#if-72) | Run trace & export | Auditor, dashboard | JSON | Medium | FR-07, NFR-05, AC-09 |

Each section: parties · protocol · format · timing · errors & retry · security · versioning · verification.

---

## IF-08 — Discord {#if-08}
**Parties.** `discord-bot` (the only container on the `egress` network) → a channel per plant/shift; the platform notifier in platform mode.
**Format.** The shift briefing as one message (the `text` of the language row; Appendix A shape), with a link to the dashboard briefing; an `immediate` delivery for a CRITICAL finding (`title`, `severity`, `recommended_action`, evidence refs, link). Numbers in the message are those of the stored briefing — the claim check happened before delivery (IF-69 §5).
**Timing.** At shift start after the run (≤ 3 min after 06:00 / 14:00); CRITICAL within 1 min of the finding (FR-29).
**Errors.** `swarm.delivery.status = failed` with the error; retried 3× with backoff; a failed Discord delivery falls back to IF-13 and the dashboard, never silently.
**Security.** Bot token as a secret file mounted only into `discord-bot`; the bot cannot read findings the channel's plant is not scoped to; no commands that write (C-03).
**Verification.** TEST-13 TC-090…TC-092.

## IF-09 — LLM runtime {#if-09}
**Parties.** Agent runner (phrasing a Finding from a facts object) and the Manager (phrasing a briefing from `top_risks_json`) → Ollama.
**Contract.** Model `≤ 9 B` (AI-05; `llm_max_params_b` CHECK), temperature ≤ 0.3, JSON output mode for specialists; **one inference at a time** — the caller holds the Redis lease (`SET NX PX`) mirrored in `swarm.llm_lease`; a second lease is refused by the database (`GPU_SEMAPHORE`). Tools never need the lease.
**Prompts.** `deploy/prompts/specialist.v1.md`, `manager_explain.v1.md`, `briefing.v1.md`, versioned in git; the version is recorded on `agent.run.prompt_version` and `agent_registry.prompt_version`.
**Errors.** Timeout ⇒ attempt `transport_error` with backoff; invalid JSON ⇒ `invalid_output`, one retry with the validation error, then `Error` (AI-02).
**Verification.** TC-021, TC-024, TC-085.

## IF-13 — SMTP & webhook {#if-13}
Fallback delivery of briefings and CRITICAL pushes (`channel = email | webhook`); same payload as IF-08 rendered as text; Mailpit in dev. TC-093.

## IF-14 — Metrics {#if-14}
`GET /metrics` on api, orchestrator, agent-runner. Per agent per run (NFR-07): `swarm_assessment_outcome_total{agent,outcome}`, `swarm_tool_calls{agent}`, `swarm_tokens{agent}`, `swarm_agent_wall_ms` (histogram), `swarm_lease_wait_ms`, `swarm_run_wall_ms`, `swarm_budget_exceeded_total`, `swarm_circuit_state{agent}`, `swarm_claim_check_unmatched_total`, `swarm_briefing_partial_total`, `swarm_bus_redelivered_total`. Daily rollup in `swarm.agent_metric`. TC-100.

## IF-16 — Agent tool contract, as consumer {#if-16}
**Parties.** Each specialist module calls typed read tools registered in `agent.tool` (platform) and bound in `swarm.agent_tool`. In platform mode the tools are the siblings' registry tools; standalone they are HTTPS calls to the sibling deployments (or `sibling-stub`).

| Agent | Tool | Provider | Returns (facts, never raw text) |
|---|---|---|---|
| quality | `get_signals(line, status?)` | 09 QE-Agent | ranked signals with statistic, p, baseline, affected SKU/lot |
| quality | `get_spc(characteristic, line?)` | 09 | chart data + violations |
| quality | `query_defects(date_from, date_to, group_by)` | 02 ShiftBrief (platform tool) | defect rows / Pareto |
| quality | `get_case(case_id)` | 09 | case board row |
| quality, material | `get_lot_quality_history(lot)` | IF-07 ERP adapter | rejections, cases, supplier |
| maintenance | `get_machine_health(machine)` | 06 MachineSense | health now, 7-day drop, components, open incidents |
| maintenance | `get_alert_evidence(alert_id)` | 06 | the `AlertEvidence` object |
| maintenance | `get_trend(machine, signal, days)` | 06 | slope with CI, pct change |
| maintenance | `get_machine_telemetry(machine, signal, window)` | platform | series summary |
| maintenance | `get_pm_overdue(line?)` | 06 | overdue PM items |
| production | `query_production(date_from, date_to, line?)` | 02 | plan vs actual |
| production | `get_oee(line, date_from?, date_to?)` | 02 | availability / performance / quality |
| production | `get_downtime_pareto(line, days?)` | 02 | downtime by cause / machine |
| production | `get_schedule_risk(line, shift?)` | 02 | coming-shift schedule risk |
| material | `get_stock_coverage(sku)` | IF-07 | stock, demand, coverage days |
| material | `get_inbound_deliveries(sku, days?)` | IF-07 | POs with ETA and confirmation |
| material | `get_shortage_risk(line?, days?)` | IF-07 | shortage risk per SKU vs schedule |

**Rules.** Read-only credentials per provider as secret files (NFR-06); `kind = read` enforced (`TOOL_NOT_READ_ONLY`); the run scope is passed to every tool; a tool call is an `agent.tool_call` row with args, digest, rows, duration, ok/error (AC-09); per-tool timeout 10–15 s; the orchestrator counts calls against the budget (C-04). Tool results are **data**: a free-text field that looks like an instruction is ignored by the prompt template (SEC-13 THR-K01).
**Verification.** TC-030…TC-034.

---

## IF-17 — Inter-agent message bus (implementing specification) {#if-17}

**Parties.** Orchestrator (and the Manager, for FR-21 requests) ↔ specialist agent runners. Elaborates ICD-00 IF-17; the platform's rules (typed only, no shared state, specialists in their domain, the Manager never invents) are enforced by the database (DDS-13 DD-K01, DD-K06).

**Transport.** NATS JetStream (ADR-K02). Streams and subjects:

| Stream | Subjects | Publisher → consumer | Retention |
|---|---|---|---|
| `AGENT_REQUEST` | `agent.request.{agent}` | orchestrator / manager → the agent (durable consumer per agent, explicit ack, `max_deliver 3`, ack wait 10 s) | 24 h |
| `AGENT_FINDING` | `agent.finding.{agent}` | agent → orchestrator | 7 d |
| `AGENT_STATUS` | `agent.status.{agent}` | agent → orchestrator (`StatusUpdate`, `Error`) | 7 d |
| `ORCH_RUN` | `orchestrator.run.{run_no}` | orchestrator → dashboard / api (lifecycle: started, assessed, ranked, briefed, delivered, finished) | 7 d |

Redis Streams is the documented alternative for a single-host deployment (ICD-00 IF-17); the message contract is the same.

**Messages.** Five types, JSON-Schema-validated on both ends (`deploy/schemas/messages/*.schema.json`) and again by `swarm.message_shape_ok()` when persisted:

| Type | Subject | Sender | Content |
|---|---|---|---|
| `RequestAssessment` | `agent.request.{agent}` | orchestrator / manager | `run_no`, `agent`, `scope`, `deadline_at`, `budget`, optional `question` |
| `StatusUpdate` | `agent.status.{agent}` | specialist | `started` · `tools_done` · `phrasing` · `done {usage}` · `nothing_significant {usage, checked[]}` |
| `Finding` | `agent.finding.{agent}` | specialist | IF-69 §2 |
| `Error` | `agent.status.{agent}` | specialist | `code ∈ {invalid_output, transport_error, timeout, tool_error, internal}`, `detail`, `attempt` |
| `Clarification` | `agent.request.{agent}` | orchestrator / manager | `budget_stop` · `scope` · `deadline` — the only post-request message; there is no free-form chat (C-01) |

Headers: `Nats-Msg-Id` = `{run_no}:{agent}:{type}:{seq}` (JetStream de-duplication), `correlation_id` = `run_no`, `schema` = `finding.v1` etc.

**Timing.** Per-agent timeout 60 s of *active* time (tools + phrasing; lease queue time excluded — ADR-K03), measured by the orchestrator from `started` to `done`; run wall 180 s; a `RequestAssessment` unanswered by `deadline_at` becomes assessment `timeout`.

**Errors and retry.** Transport: redelivery by JetStream up to 3×, then `failed`. Output: one retry on `invalid_output` (AI-02) with the validation error appended to the prompt, then `Error`. Budget: the orchestrator publishes `Clarification{budget_stop}` and stops accepting tool calls; the assessment is `budget_exceeded`, `incomplete` (C-04, AI-08). Circuit: 3 consecutive failures open the agent's circuit for 15 min; while open, the agent is not requested and its assessment is `circuit_open`. **Any failure degrades the briefing to `partial` with the domain named; nothing aborts the run** (C-06).

**Persistence.** Every message is written to `swarm.message` by the orchestrator in arrival order (`seq`), immutable; agent runners have no database access (ADR-K08).

**Security.** NATS accounts: `orchestrator` (publish `agent.request.*`, `orchestrator.run.*`; subscribe `agent.*`), one account per agent runner (publish `agent.finding.{self}` and `agent.status.{self}`; subscribe `agent.request.{self}`) — an agent cannot impersonate another (SEC-K10…K12); TLS inside the `internal` network; message size ≤ 64 KiB.

**Versioning.** Subject names and message schemas carry `v1`; a new field is additive; a breaking change is a new subject version with both consumed for one release.

**Verification.** TC-010…TC-019 (framework), TC-081…TC-088 (fault injection), the seed's 151 messages (TC-005).

---

## IF-68 — Agent registry & tool-module contract {#if-68}
**Parties.** Admin (`deploy/agents.example.yaml` → `POST /agents/import`) and the agent runner, which loads the module named in `module`.
**Registry file.** `deploy/schemas/agent-registry.schema.json`: name, kind, version, module, domains, tools (read only, with provider and timeout), output schema, budget, cron, prompt version, enabled; exactly one enabled manager. Equal to the seed's registry rows.
**Module contract (Python).**
```
class Agent(Protocol):
    name: str; version: str; domains: list[str]
    def plan(self, scope: Scope) -> list[ToolCall]                     # fixed per version — no LLM planner
    def facts(self, results: list[ToolResult]) -> FactsObject           # typed facts with refs; numbers only from results
    def phrase(self, facts: FactsObject, llm: Phraser) -> list[Finding] | NothingSignificant   # one lease, one call (+1 retry)
```
The runner enforces: tools ⊂ the bound read tools; every Finding validates against `finding.v1`; `domain ∈ domains`; every number in a Finding's title/summary occurs in `facts` (grounding, AI-01); usage reported in `StatusUpdate`.
**Adding an agent (FR-06, NFR-04).** Registry entry (enabled: false) → module deployed in `agent-runner` → scenario suite extended with ≥ 1 scenario for the domain → suite passes → `PATCH /agents/{name} {enabled: true}`. The Manager's code is untouched; ≥ 8 agents are a runner replica question, not an architecture change.
**Verification.** TC-013, TC-014 (a fifth agent by configuration), TC-006 (registry schema, 8 negatives).

## IF-69 — Finding & blackboard contract {#if-69}
**§1 Parties.** Specialists produce; the orchestrator persists (`swarm.upsert_finding`); the UI, Discord and Copilot read.
**§2 Shape.** `finding.v1` = the SRS §5 shared schema **plus** four fields the scoring and dedupe need: `issue_code`, `likelihood_class`, `horizon`, `freshness_min` (and `plant` in scope). The SRS example therefore validates only with those added — a deliberate v1 decision recorded in TEST-13 TC-006.
**§3 Issue families and identity.** `issue_code = family.kind`; the family fixes which scope entities identify the issue (`swarm.issue_key`): `machine.* → plant, machine` · `lot.* → plant, lot` · `sku.*`, `material.* → plant, sku` · everything else (`quality.*`, `production.*`, `schedule.*`, `line.*`) `→ plant, line`. Shift, dates and windows never enter the key. A finding's **domain is its first reporter's** — a merged finding is one domain for the compound rules. Vocabulary v1: `machine.degradation`, `machine.failure_imminent`, `machine.pm_overdue`, `quality.defect_rate`, `quality.spc_violation`, `quality.spc_warning`, `quality.open_case`, `lot.quality_history`, `material.shortage`, `material.delivery_risk`, `production.performance_loss`, `production.plan_gap`, `production.downtime`, `production.schedule_risk`, `production.changeover`.
**§4 Lifecycle.** `new → acknowledged → in_progress → resolved | expired | dismissed`, `reopen`; actions with reasons (`false_positive`, `duplicate`, `known`, `not_actionable`, `not_related`); expiry when every reporter has reported in ≥ 2 scheduled runs without the issue.
**§5 Guarantees the reader may rely on.** Evidence ≥ 1 (C-02); author an enabled specialist in its domain (FR-14, FR-22); one active finding per key (FR-16/24); every occurrence's evidence kept (AC-03); a briefing quotes only numbers present in the cited findings (AC-07).
**Verification.** TC-005, TC-006, TC-040…TC-049, TC-060…TC-066.

## IF-70 — Scoring & relation-rule contract {#if-70}
**Weights.** `scoring_weights` rows / `GET /scoring-weights`: `impact{INFO…CRITICAL}`, `likelihood{observed, trend, forecast, possible}`, `urgency{this_shift, today, within_3_days, this_week, later}`, each in [0, 1] and monotone; one active version; `score = impact × likelihood × urgency × confidence` (4 dp); compound `1 − Π(1 − sᵢ)`. Published in `deploy/kaizenswarm.example.yaml §scoring` and returned with every `RiskScore` so anyone can recompute a rank by hand (FR-18).
**Rules.** `relation_rule`: `code`, `match_keys`, `min_domains ≥ 2`, `window_hours`, `enabled`; evaluated in `code` order; the first matching rule absorbs (`same_line`, `same_lot`, `same_machine`, `same_sku` in v1).
**Change control.** New version / rule → `POST /scenarios/run` → `passed` → activate (`409 SCENARIO_GATE` otherwise); every change audited (`registry_change`, `audit.log`).
**Verification.** TC-005 (twins), TC-050…TC-056, TC-070.

## IF-71 — Scenario suite {#if-71}
`deploy/schemas/scenario-suite.schema.json` / `deploy/scenarios/suite.example.yaml`: ≥ 15 scenarios, each `findings[]` (id `F<n>`, agent, domain, scope, title, severity, likelihood_class, horizon, confidence, issue_code) and `expected_top[]` (`F<n>` or `C:F1+F2` for a compound; ≤ 3). Deterministic mode runs `swarm.rank_findings` per scenario and compares the top-N as a set; full mode also phrases each scenario's briefing with the model and counts fabricated tokens. Gate: `match_rate ≥ 0.80 ∧ fabricated = 0 ∧ n ≥ 15` (AI-06, AC-01). Equal to the seed's `swarm.scenario` rows (TC-006).

## IF-72 — Run trace & export {#if-72}
`GET /runs/{id}/trace` (events in time order) and `GET /runs/{id}/export` (`deploy/schemas/run-export.schema.json`, example `deploy/examples/run-trace-411.json`): run, assessments with budgets, messages with payloads, tool calls, leases, attempts, ranking, `message_log_sha256` (= `swarm.export.sha256`, over `seq|type|from|to` lines). The example briefing export is `deploy/examples/briefing-411.json`. Retention ≥ 365 d (NFR-05). TC-101…TC-103.

---

## 2. Interface matrix

| Interface | Standalone | Platform mode | Degrades to | Auditable |
|---|---|---|---|---|
| IF-08 Discord | own bot (profile) | platform notifier | IF-13 + dashboard | `swarm.delivery` |
| IF-09 LLM | own Ollama | platform Ollama + semaphore | template briefing text (`template_fallback`); specialists `invalid_output` → partial | `agent.run`, `llm_lease` |
| IF-16 tools | HTTPS to siblings / stub | registry tools | tool error → assessment `failed` → partial | `agent.tool_call` |
| IF-17 bus | own NATS | platform NATS | JetStream redelivery; timeout → partial | `swarm.message` |
| IF-68…72 | files + API | same | — | `registry_change`, `audit.log`, `export` |

## 3. Change control
| Artefact | Owner | Gate |
|---|---|---|
| registry (`agents.example.yaml`) | admin | schema; suite for new agents; audited |
| message schemas | integration owner | additive only within v1; both ends validate |
| issue-code vocabulary (IF-69 §3) | QE lead + maintenance lead | a new code needs a family; documented in the scenario suite |
| weights, rules | plant manager + ML owner | scenario gate |
| prompts | ML owner | version bump; suite full mode |
| scenario suite | ML owner | ≥ 15; reviewed quarterly |

## 4. Traceability
C-01/FR-02/FR-07 → IF-17 · C-02/FR-12 → IF-69 · C-03/NFR-06 → IF-16 · C-04/AI-08 → IF-17 errors · C-05/AI-05 → IF-09 · C-06/FR-05/FR-20 → IF-17 errors · FR-01/FR-06/NFR-04 → IF-68 · FR-08…FR-11 → IF-16 tables · FR-16/FR-23…FR-27 → IF-69 · FR-17/FR-18/AI-03/AI-04 → IF-70 · FR-28/FR-29/FR-31 → IF-08 · NFR-05/AC-09 → IF-72 · NFR-07 → IF-14 · AI-06/AC-01 → IF-71.
