# Software Architecture Document — KaizenSwarm (Multi-Agent Factory System)

| Field | Value |
|---|---|
| Document ID | SAD-13-KaizenSwarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-21 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-13](../SRS-KaizenSwarm-Multi-Agent-Factory.md) |
| Related | [DDS-13](DDS-KaizenSwarm-Database-Design.md) · [API-13](../api/API-Specification.md) · [ICD-13](ICD-KaizenSwarm-Interface-Control.md) · [SEC-13](SEC-KaizenSwarm-Security-Requirements.md) · [TEST-13](TEST-KaizenSwarm-Test-Plan.md) · [OPS-13](OPS-KaizenSwarm-Deployment-Operations.md) · [UM-13](UM-KaizenSwarm-User-Admin-Guide.md) · parent [SAD-00](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) · precedent [SAD-10](../../10-factory-copilot/docs/SAD-Copilot-Software-Architecture.md) |

---

## 1. Introduction

### 1.1 Purpose
Define the architecture of KaizenSwarm: an orchestrated multi-agent system in which four specialist agents — Quality, Maintenance, Production, Material — each assess their own domain with typed, read-only tools, and a Manager agent requests, deduplicates, relates, ranks and reports their findings as a prioritised cross-domain risk picture for the shift (SRS §1.1). The value is cross-domain reasoning: a defect-rate signal, a bearing-temperature alert and a tight schedule that individually look minor may together be the top risk of the shift (Appendix A, item 1).

The document fixes the SRS's non-negotiables as architecture rather than as agent behaviour: typed messages only (C-01), evidence or rejection (C-02), read-only (C-03), budgets enforced by the orchestrator (C-04, AI-08), one LLM inference at a time (C-05), and — the distinguishing idea — **a failed domain degrades the briefing to a partial one; it never fails the run and never hides** (C-06, FR-20).

### 1.2 What makes this project different from its siblings
Every other FactoryBrain module is one agent or one engine. KaizenSwarm is the layer above them, and it produces nothing of its own: every fact comes from a sibling's tool, every finding from a specialist, every rank from arithmetic. Four consequences shape the design:

- **Agents are configuration, not code paths in the Manager.** The registry (`swarm.agent_registry`) defines an agent by name, domains, tools, output schema, budget, schedule and enabled flag (FR-01). A new agent is a registry row plus a tool module that implements the IF-68 contract (FR-06); the Manager iterates over enabled agents and never names one (NFR-04, ADR-K01).
- **The Manager cannot invent, and the ranking is not a judgement.** The Manager may only aggregate, relate and rank what specialists reported (FR-22, AI-03). The database enforces it: only a registered specialist may insert a finding (`trg_finding_author`), a score row must equal the published scoring function (`trg_risk_score_computed`), a compound must cite ≥ 2 findings from ≥ 2 domains matched by a relation rule and score by noisy-OR (`trg_compound_components`), and a briefing whose text contains a number absent from the findings it cites is refused (`trg_briefing_grounded`, AC-07). The LLM phrases; it does not rank, relate or assert (P-1).
- **Partial is a first-class result.** An agent that times out, exceeds its budget, returns malformed output twice or trips its circuit breaker produces an *assessment* row with that outcome; the Manager still runs with the domains that answered; the briefing carries `partial = true` and names the domain (C-04, C-06, FR-20, AC-02, AC-05). "Nothing significant in my domain" is itself an assessment outcome, so silence is impossible (FR-13). The trigger `trg_briefing_partial` makes a briefing that hides a failed domain unrepresentable.
- **Every run is reconstructible.** Typed messages (`swarm.message`, immutable), the specialist's LLM run (`agent.run`), its tool calls (`agent.tool_call`), leases on the GPU, attempts and budget usage are rows written by the orchestrator as the run proceeds; `run_trace()` replays a run message by message and call by call (FR-07, NFR-05, AC-09).

### 1.3 Two ways to deploy it
- **Platform mode** (the intended one): KaizenSwarm is a **tightly-coupled server module** of FactoryBrain (SAD-00 §13: "server module · `agent.finding*` · IF-17 bus · briefing → IF-08 · tight (orchestrates 06/09/02)"). It **owns** the platform's `agent.finding` and `agent.briefing` tables, **reuses** `agent.run` / `agent.tool_call` for each specialist's LLM run and its tool calls and `agent.tool` for the read-only tool registry, adds the `swarm` schema (migration `swarm_0001`), speaks IF-17 on the platform's NATS, calls sibling tools through IF-16 (09 QE-Agent, 06 MachineSense, 02 ShiftBrief; the Material agent through the IF-07 ERP adapter) and serves `/agent/findings` and `/agent/briefing` verbatim (API-00 §mapping).
- **Standalone mode**: the same containers with their own PostgreSQL, NATS, Redis and Ollama; the platform's `core`, `agent` and `audit` sections extracted byte-identically into `db/schema.sql`; sibling tools reached over HTTPS at the siblings' own deployments (or the dev stub). §9 lists what changes.

### 1.4 Related documents
DDS-13 (the extracted platform sections, the `swarm` extension, the guard triggers, the twins of scoring / compounds / dedupe / claim check / budgets, the seed reproducing Appendix A and AC-02…AC-09, the scenario suite), API-13 (finding / run / ranking / briefing / trace contracts), ICD-13 (IF-17 elaborated as the implementing specification; IF-16 as consumer; new IF-68 agent registry & tool module, IF-69 finding & blackboard, IF-70 scoring & relation rules, IF-71 scenario suite, IF-72 run trace & export), SEC-13, TEST-13, OPS-13, UM-13.

---

## 2. Architecture principles

The platform principles (SAD-00 §2), restated for a swarm:

| # | Principle | Consequence in KaizenSwarm |
|---|---|---|
| P-1 | **The LLM never computes or ranks** | Tools produce facts (AI-01); the specialist's model turns a facts object into a schema-validated finding whose numbers must come from the facts (AI-02); `score_finding()` ranks (AI-03); `detect_compounds()` relates (AI-04); the Manager's model phrases the briefing and is refused if it adds a number (AC-07). |
| P-2 | **Typed messages only** | Five message types on the bus, JSON-Schema-validated (FR-02), stored immutably (`swarm.message`); no shared mutable state; no free-form chat (C-01). Specialists never touch the database — the orchestrator persists what the bus carries (ADR-K08). |
| P-3 | **Read-only; humans act** | Every tool bound to an agent is `kind = 'read'` (`trg_tool_read_only`); credentials to siblings are read-only (NFR-06); a finding carries a *recommended* action and an *owner suggestion*; execution is a human's workflow (C-03, §1.2 out of scope). |
| P-4 | **The database is the source of truth** | Findings, occurrences, scores, compounds, assessments, budgets, leases, circuit states and briefings are rows guarded by triggers (DDS-13 DD-K01…K09). An orchestrator bug cannot produce a briefing that the schema says is impossible. |
| P-5 | **Domain knowledge is data** | Registry, tool bindings, relation rules, scoring tables and weights, prompts (versioned), scenarios — all rows or versioned files; changing them is a change-control event with the scenario suite as its gate (ADR-K10). |
| P-6 | **Partial is a first-class result** | Outcomes `timeout`, `budget_exceeded`, `invalid_output`, `failed`, `circuit_open` are assessment rows, never exceptions that abort the run; the briefing states what is missing (C-04, C-06, FR-20). |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-13 §2.4)
| ID | Constraint | Architectural response |
|---|---|---|
| C-01 | Typed messages via the bus only | NATS JetStream subjects (IF-17); message schemas in `deploy/schemas/messages/`; `trg_message_typed`; no agent has a database connection (ADR-K02, ADR-K08) |
| C-02 | Every finding carries evidence | platform `finding_has_evidence` + `trg_finding_author` (each evidence item has `kind` and `ref`); the Finding message schema requires `evidence[≥1]` |
| C-03 | Read-only towards production systems | `trg_tool_read_only`; read-only sibling credentials as secret files; no write tool exists in the registry seed |
| C-04 | Budgets → partial, never silent truncation | orchestrator counts tool calls, tokens and wall time; `trg_assessment_budget` refuses an assessment that claims completeness over budget (ADR-K07) |
| C-05 | One LLM inference at a time on 8 GB | `swarm.llm_lease` with an exclusive partial unique index; Redis lease for the runtime; tools run in parallel, phrasing is serialised (ADR-K03) |
| C-06 | Agent failure degrades, never fails | assessment outcomes; `trg_briefing_partial`; circuit breaker per agent (ADR-K07) |

### 3.2 Quality attributes
| Attribute | Driver | Target | Tactic |
|---|---|---|---|
| Latency | NFR-01, NFR-02 | 4-agent run ≤ 3 min; agent timeout 60 s | tools in parallel, one phrasing call per agent (≤ 1,200 output tokens), cached tool results within a run, sequential leases |
| Resilience | C-06, NFR-03, FR-05 | one dead agent → partial briefing | timeouts, one retry on malformed output, exponential backoff on transport errors, circuit breaker (3 failures → open 15 min), fault-injection tests (TS-8) |
| Correctness of ranking | FR-18, AI-03, AC-04 | deterministic; compound ≥ components | published tables, noisy-OR, score trigger, Python re-derivation |
| Non-fabrication | FR-22, AI-06, AC-07 | zero invented claims | claim check on every briefing text; specialists' numbers must come from tool facts |
| Extensibility | FR-06, NFR-04 | ≥ 8 agents by configuration | registry + IF-68 module contract; Manager iterates enabled agents |
| Auditability | FR-07, NFR-05, AC-09 | every message and tool call reconstructible | immutable messages, `agent.run`/`agent.tool_call`, `run_trace()`, JSON export (IF-72) |
| Observability | NFR-07, FR-30 | tokens / latency / tool calls per agent per run | `swarm.agent_metric`, IF-14 metrics, `v_agent_health` |
| Test coverage | NFR-08 | ≥ 80 % on orchestrator, scoring, schema validation | scoring and validation are SQL twins + Python; the scenario suite runs the deterministic half in SQL |

### 3.3 Not drivers
Autonomous action (out of scope), agent-to-agent negotiation (message types are fixed), multi-plant federation, real-time (sub-minute) alerts other than CRITICAL push, and a general chat interface (that is 10 Factory Copilot; a briefing item links to it).

---

## 4. Views

### 4.1 Context view
```
  Plant / production manager ─┐        ┌─ Shift leader (ack · assign · snooze · dismiss)
  Quality / maintenance eng. ─┤  web   ├─ Admin (registry · budgets · rules · weights · scenarios)
                              ▼        ▼
                       ┌──────────────────────┐        Discord (IF-08) ◄── briefing · CRITICAL push
                       │   KaizenSwarm  API   │──────► Webhook / SMTP (IF-13, fallback)
                       └─────────┬────────────┘        Prometheus (IF-14)
                                 │
                       ┌─────────▼────────────┐   IF-17 (NATS JetStream)
                       │     Orchestrator     │◄═══════════════════════╗
                       │ runs · budgets · GPU │                        ║
                       │ lease · dedupe ·     │                ┌───────╨────────┐
                       │ compounds · scoring  │                │  Agent runner  │
                       │ briefing · claims    │                │ quality · maint│
                       └─────────┬────────────┘                │ production ·   │
                                 │                             │ material · (n) │
                       ┌─────────▼────────────┐                └───┬───┬───┬────┘
                       │ PostgreSQL           │      IF-16 tools   │   │   │  IF-09 (one lease at a time)
                       │ agent.* (owned) +    │  09 QE-Agent ◄─────┘   │   └────► Ollama (≤ 9 B)
                       │ swarm (extension)    │  06 MachineSense ◄─────┘
                       └──────────────────────┘  02 ShiftBrief ◄── IF-07 ERP adapter (Material)
```

### 4.2 Container view
| Container | Responsibility | Talks to | Notes |
|---|---|---|---|
| `web` | Next.js dashboard: briefing, blackboard, run trace, agent health, admin | `api` | FR-28, FR-30 |
| `api` | REST (API-13); lifecycle actions; registry; exports; triggers runs | `postgres`, `nats` (publish `orchestrator.run.*`) | role `app_rw` |
| `orchestrator` | Runs: schedule/on-demand; requests assessments; enforces timeouts, budgets, retries, circuit; GPU lease; persists messages; dedupe → compounds → scores → briefing → claim check; delivery | `nats`, `postgres` (`orchestrator_rw`), `redis` (lease, cache), `ollama` (Manager phrasing) | one process; horizontally scalable per run |
| `agent-runner` | Hosts the specialist modules (IF-68): receives `RequestAssessment`, calls tools in parallel, requests a lease, phrases with the model, validates against the output schema, publishes `Finding` / `StatusUpdate` / `Error` | `nats`, sibling APIs (`sources` network), `ollama`, `redis` (lease) | **no database connection**; scale by replicas |
| `scheduler` | Cron: shift-start and daily runs (FR-03), expiry (FR-27), metric rollup, retention | `api` | |
| `nats` | JetStream bus (IF-17): streams `AGENT_REQUEST`, `AGENT_FINDING`, `AGENT_STATUS`, `ORCH_RUN` | all | ADR-K02 |
| `postgres` | platform sections + `swarm` | | pgvector image for platform compatibility |
| `redis` | GPU lease (`SET NX PX`), tool-result cache within a run | | |
| `ollama` | one shared model ≤ 9 B (AI-05) | | GPU or CPU profile |
| `discord-bot` | delivers briefings and CRITICAL pushes; `/briefing` command | Discord | profile; only container with egress |
| `mailpit`, `sibling-stub` | dev: mail sink; stub QE/MachineSense/ShiftBrief/ERP tools | | profile `dev` |

### 4.3 Component view

**Orchestrator**
- *Run controller* — creates `swarm.run` (`run_no`, scope, trigger), publishes `RequestAssessment` to each enabled agent with `deadline_at` and the budget; waits until all assessments arrive or the run wall clock (180 s) elapses; marks the missing ones `timeout`.
- *Budget enforcer* — counts `tool_call` and token usage reported in `StatusUpdate` messages and measured on the lease; when a budget is exceeded it publishes `Clarification{kind: budget_stop}` and records the assessment as `budget_exceeded` with `incomplete = true` (AI-08). The agent's cooperation is not required: the orchestrator stops accepting its tool calls.
- *Resilience* — per-agent timeout, one retry on `invalid_output` (AI-02), exponential backoff on transport errors (`backoff_ms`), circuit breaker (`circuit_next_state`); an open circuit yields outcome `circuit_open` without a request.
- *GPU lease* — grants exactly one lease at a time (Redis `SET NX PX`, mirrored in `swarm.llm_lease`); agents queue for phrasing; tools do not need a lease (C-05, FR-04).
- *Blackboard writer* — validates each `Finding` message, computes `issue_key`, upserts (`upsert_finding`): same key → occurrences + 1, last_seen, evidence union, a new `finding_occurrence`; different key → a new `agent.finding` (FR-16, FR-24).
- *Relator* — `detect_compounds(run)`: relation rules (same line / machine / SKU / lot within a window, ≥ 2 domains) → `compound_risk` with components and rationale (FR-17, AI-04).
- *Ranker* — `score_finding` for each finding in the run, `compound_score` for compounds, `rank_run` orders and absorbs components into their compound; top-N (FR-18, AI-03).
- *Briefer* — builds `top_risks_json` from the ranked list (rank, score, severity, title, finding ids, action, owner suggestion, evidence refs, freshness); asks the model to phrase `text` in the requested language from that JSON only; runs `claim_check` (numbers in the text must occur in the cited findings); refuses and retries once with the failed tokens listed, then falls back to the template text (FR-19, FR-22, FR-31, AC-07).
- *Deliverer* — Discord at shift start; CRITICAL findings immediately (`delivery` rows; FR-28, FR-29).

**Agent runner (per specialist, IF-68)**
- *Tool plan* — fixed per agent version (no planner): the module lists the tools it calls for a scope; calls run in parallel with the per-tool timeout; results are cached for the run.
- *Facts object* — tool results reduced to typed facts with refs (`telemetry:M-07:bearing_temp:2026-09-03..10`, `alert:1184`, `signal:S-241`, `oee:line1:2026-09-08..10`, `stock:RAD-500-A`, `po:PO-2026-004821`); the model receives this and nothing else (AI-01).
- *Phraser* — one lease, one call, output validated against the agent's output schema (the Finding schema); numbers must occur in the facts; invalid → one retry with the validation error; second failure → `Error{invalid_output}` (AI-02, AC-06).
- *Self-report* — confidence and data freshness per finding (AI-07); `nothing_significant` when the facts cross no threshold (FR-13).
- *Domain boundary* — a module may emit only the domains registered for it; the orchestrator rejects others (FR-14).

**API** — findings (query, actions), runs (trigger, status, trace), briefing, manager ask, agents (registry, health, tools, metrics), rules/weights, scenarios, exports.

### 4.4 Runtime views

**RV-1 Appendix A — shift briefing 2026-09-10 Shift A (run 411)**
1. 06:00 scheduler → `POST /runs {scope: plant 1, trigger: schedule}` → `swarm.run 411 running`.
2. Orchestrator publishes `RequestAssessment` to quality, maintenance, production, material (deadline +60 s, budget 12 calls / 6,000 tokens).
3. Each runner calls its tools in parallel (23 calls in total; each an `agent.tool_call` row under the specialist's `agent.run`), builds its facts object, queues for the lease, phrases, validates, publishes `Finding` (quality S-241 line 3: 5.82 % vs 2.41 %, +141 %, p < 0.001; maintenance M-07 bearing +13.8 % over 5 d, alert 1184; material RAD-500-A coverage 1.4 d vs 3-day schedule, PO-2026-004821 due 09-14; production line 1 performance 78 % vs 91 %, micro-stops ×3) and `StatusUpdate{done, usage}`.
4. Blackboard writer upserts: M-07 has the same `issue_key` as in runs 407–410 → `occurrences = 5` (AC-08); the other three are new.
5. Relator: rule `same_line` matches quality + maintenance on line 3 → compound; ranker: 0.68 and 0.4992 → compound 0.8397; material 0.712; production 0.5184; top 3 = compound 0.84, material 0.71, production 0.52.
6. Briefer: `top_risks_json`; model phrases the EN text; `claim_check` matches every number (5.82, 141, 13.8, 5, 1.4, 3, 09-14, 78, 91, 3, 411, 2 min 14 s, 4, 23 …) against the findings and the run; TH and JA texts likewise; `partial = false`; data freshness material 6 h ⚠ (> 60 min).
7. Delivery to Discord; dashboard shows the briefing and the trace (2 min 14 s, 4 agents, 23 tool calls).

**RV-2 AC-02 — Maintenance agent killed mid-run (run 412)** — no `Finding` or `StatusUpdate` by the deadline → assessment `timeout`; circuit failures 1; the Manager ranks the three domains that answered; `partial = true`, `partial_reason = 'maintenance: timeout after 60 s'`; the briefing says so in its first line.

**RV-3 AC-05 — budget exceeded (run 413)** — production's 13th tool call is refused by the orchestrator; `Clarification{budget_stop}`; the runner phrases what it has; assessment `budget_exceeded`, `incomplete = true`, usage 13/12; the briefing is partial with the reason.

**RV-4 AC-06 — malformed output (run 414)** — maintenance returns text that is not a Finding; attempt 1 `invalid_output`; retry with the validation error; attempt 2 `invalid_output` → `Error` message; assessment `invalid_output`; no finding row was written (the blackboard writer validates before insert).

**RV-5 FR-21 — ad-hoc question (run 415)** — `POST /manager/ask {"question": "Is line 3 at risk this shift?"}` → the Manager maps the question to a scope (line 3, shift A) and requests targeted assessments from all enabled agents; the answer is a ranked list for that scope with the same claim check; no new reasoning path.

**RV-6 FR-29 — CRITICAL** — a `Finding` with `severity = CRITICAL` inserts a `delivery{kind: immediate}` row by trigger; the deliverer pushes it within a minute, outside the schedule.

**RV-7 FR-27 — expiry** — after run 413 the line 1 OEE issue has not been reported for two consecutive runs on its scope → `expire_findings()` sets `expired` with the resolution text naming the runs.

### 4.5 Deployment view
Standalone: one host (8 GB GPU baseline, 16 GB RAM), compose networks `frontend` (web, api), `internal` (everything), `sources` (agent-runner → sibling APIs / ERP adapter), `egress` (discord-bot only). Platform mode: the same images under the platform's compose with the platform's NATS, Ollama, PostgreSQL and notifier (OPS-13 §1).

### 4.6 Data view
Platform-owned by this module: `agent.finding`, `agent.briefing`. Platform-reused: `agent.run` (one per specialist per run, `kind = 'specialist'`, `correlation_id = run_no`), `agent.tool_call`, `agent.tool`. Extension `swarm`: registry and bindings; runs, assessments, attempts, messages, leases, circuit states; finding extension, occurrences, actions; scores, weights, relation rules, compounds; briefing↔run link with claims; deliveries; questions; metrics; scenarios; exports (DDS-13 §2).

---

## 5. Cross-cutting concerns

| Concern | Approach |
|---|---|
| Identity & roles | platform users/roles; viewer reads briefings; shift leader acts on findings; engineer drills into evidence; manager triggers runs and asks; admin edits registry/rules/weights (SEC-13 §5.7) |
| Scope | a run has a scope (plant / line / shift); findings carry `scope_json`; a user's line scope filters the blackboard (platform `user_line_scope`); sibling tools receive the scope (SEC-13 O-5) |
| Observability | `swarm.agent_metric` per agent per day; IF-14 gauges/histograms per agent per run: tool calls, tokens, latency, outcome; `v_agent_health` |
| Configuration | `deploy/kaizenswarm.example.yaml` (schema-validated); registry and rules are rows with an audited change history |
| Languages | briefing rows per language (`lang`), same `top_risks_json`; agent prompts are English; Thai/Japanese phrasing by the same model with the same claim check (FR-31) |
| Retention | messages, runs, findings, briefings ≥ 365 d (NFR-05); tool-result caches per run only |
| Cost | tokens per agent per run are a budget and a metric; the scenario suite reports tokens per scenario |

---

## 6. The design's own risk — a compound that isn't

The compound rule is deliberately simple: two findings from different domains on the same line, machine, SKU or lot within a window are related. Two unrelated issues on the same line (a supplier lot problem and a bearing) will be presented as one compound with a score above either. Mitigations: the compound's `rationale` names the rule and the shared key; the components remain visible with their own scores (`v_compound_explain`); a shift leader can dismiss the compound with reason `not_related`, which feeds the precision report for the *rule*; and rules can be narrowed (window, additional keys) without code. The alternative — letting the model decide relatedness — would make AC-04 untestable and AC-07 unenforceable.

---

## 7. Architecture Decision Records

### ADR-K01 — A tight platform module that owns `agent.finding*` and iterates a registry
**Context.** SAD-00 §13 places KaizenSwarm in the platform's `agent` context. FR-06/NFR-04 demand new agents without Manager changes. **Decision.** Own `agent.finding` and `agent.briefing`; add `swarm`; the Manager loops over `agent_registry WHERE enabled AND kind = 'specialist'`. **Consequences.** ✅ one blackboard for the platform (Copilot links to it); ✅ agents are rows. ❌ the module cannot be deployed against a platform database that already has a different owner of `agent.finding` — there is none.

### ADR-K02 — NATS JetStream as the bus, now
**Context.** Platform ADR-008 kept Redis and deferred NATS "until the multi-agent bus is built". **Decision.** Build it: JetStream streams with explicit acks, redelivery and a per-run subject; Redis stays for the lease and the cache. **Consequences.** ✅ delivery guarantees and replay for AC-09; ❌ one more service in standalone mode (ICD-13 IF-17).

### ADR-K03 — One shared model, one lease, tools in parallel
**Context.** C-05, AI-05, NFR-01. **Decision.** Tools run concurrently; only phrasing needs the lease; leases are exclusive (`trg_llm_lease_exclusive`); each agent makes exactly one phrasing call (plus one retry). **Consequences.** ✅ 4 agents × ≤ 25 s phrasing fits 3 min; ❌ agents wait in a queue — designed for (C-05).

### ADR-K04 — Deterministic scoring with published tables
**Context.** FR-18, AI-03. **Decision.** `score = impact(severity) × likelihood(class) × urgency(horizon) × confidence`, tables and version in `scoring_weights`; the trigger recomputes. **Consequences.** ✅ inspectable, testable, explainable by the model; ❌ coarse — refined by editing tables under the scenario gate.

### ADR-K05 — Compounds from relation rules, scored by noisy-OR
**Context.** FR-17, AI-04, AC-04. **Decision.** Rules over shared keys; score `1 − Π(1 − sᵢ)`. **Consequences.** ✅ AC-04 holds by construction; ✅ rationale is the rule; ❌ §6.

### ADR-K06 — Dedupe by issue key with occurrences and evidence union
**Context.** FR-16, FR-24, AC-03, AC-08. **Decision.** `issue_key = issue_code ‖ sorted scope entities`; same key → occurrence, never a duplicate; each occurrence keeps its agent's evidence set. **Consequences.** ✅ one finding, both evidence sets; ❌ requires a shared `issue_code` vocabulary (IF-69) that specialists must map to.

### ADR-K07 — Budgets, timeouts and circuits are enforced by the orchestrator and recorded as outcomes
**Context.** C-04, C-06, FR-05, AI-08. **Decision.** Outcomes are assessment rows; the briefing's `partial` is derived from them by trigger. **Consequences.** ✅ no silent truncation; ✅ fault injection is testable in SQL; ❌ an agent cannot "finish anyway" — by design.

### ADR-K08 — Specialists never write; the orchestrator persists
**Context.** C-01, C-03, NFR-06. **Decision.** Agent runners have no database credentials; everything they know arrives as a message. **Consequences.** ✅ the blackboard has one writer; ✅ a rogue module can only publish messages that are validated; ❌ the orchestrator is a single point — replicated per run.

### ADR-K09 — The briefing is claim-checked, and the template is the fallback
**Context.** FR-22, AC-07, FR-31. **Decision.** Numbers in the phrased text must occur in the cited findings; a failure retries once, then the deterministic template text is used. **Consequences.** ✅ zero fabricated claims is a database property; ❌ a legitimate derived number (e.g. a sum) must be computed by the briefer and placed in `top_risks_json` first.

### ADR-K10 — The scenario suite gates every change to agents, rules, weights and prompts
**Context.** AI-06, AC-01, FR-26. **Decision.** ≥ 15 synthetic plant states with expected top-3; the deterministic half runs in SQL (`run_scenario`) on every change; the LLM half runs in CI with the model; the gate is top-3 ≥ 80 % and zero fabricated. **Consequences.** ✅ regressions are caught before the shift; ❌ the suite must be maintained as the plant changes.

---

## 8. Quality attribute scenarios

| ID | Stimulus | Environment | Response | Measure |
|---|---|---|---|---|
| QAS-01 | Shift-start run, 4 agents | baseline GPU | briefing delivered | ≤ 3 min (NFR-01) |
| QAS-02 | Maintenance runner process killed | mid-run | assessment `timeout`, partial briefing with the other three domains | ≤ 60 s after the deadline (AC-02) |
| QAS-03 | Production agent's 13th tool call | budget 12 | refused; `budget_exceeded`, `incomplete`; briefing partial | 100 % of over-budget runs (AC-05) |
| QAS-04 | Agent output fails schema | any | one retry with the error, then `Error`; no finding written | AC-06 |
| QAS-05 | Two agents report the same lot | same run | one finding, two occurrences, evidence union | AC-03 |
| QAS-06 | Quality + maintenance on line 3 | any | compound with score ≥ both components | AC-04 |
| QAS-07 | Manager text contains a number not in any finding | phrasing | briefing refused, retried, template fallback | 0 fabricated (AC-07) |
| QAS-08 | Same condition on 5 consecutive runs | any | one finding, `occurrences = 5` | AC-08 |
| QAS-09 | Auditor requests run 411 | any time within retention | every message and tool call in order | AC-09 |
| QAS-10 | New agent `logistics` added | config + module | appears in runs without Manager change | FR-06 |
| QAS-11 | Two agents request the lease at once | 8 GB GPU | one granted, the other queued | 0 concurrent inferences (C-05) |
| QAS-12 | Weights table edited | admin | scenario suite runs; change blocked below 80 % | ADR-K10 |

---

## 9. Platform mode

| Aspect | Standalone | Platform |
|---|---|---|
| Database | own PostgreSQL with the extracted `core`/`agent`/`audit` sections + `swarm_0001` | platform database; `swarm_0001` applied; `agent.finding`/`agent.briefing` owned by KaizenSwarm |
| Bus | own NATS | platform NATS (ADR-008 fulfilled) |
| API | `/api/v1/runs`… and `/agent/findings`, `/agent/briefing` both served | gateway serves the two platform paths; SRS paths under `/swarm/` |
| Tools | sibling deployments over HTTPS (or `sibling-stub`) | registry tools from 09/06/02 via IF-16; Material via IF-07 |
| Model | own Ollama | platform Ollama + GPU semaphore (ADR-011) |
| Auth | own JWT issuer | platform users, roles, scopes |
| Discord | own bot (profile) | platform notifier (IF-08) |
| Copilot | — | briefing items carry an "ask about this" link to 10 (IF-16 reverse) |

---

## 10. Risks and technical debt

| Risk | Mitigation | Owner |
|---|---|---|
| Multi-agent complexity without value | precision report per agent (FR-26); an agent whose findings are mostly dismissed is disabled; start with Quality + Production (SRS §9 P2) | plant manager |
| Latency on one GPU | ADR-K03; small model; cache; fewer phrasing tokens | ML owner |
| Compound false positives (§6) | rationale, dismiss reasons feed rule precision, narrow rules | QE lead |
| Alert fatigue | top-N, severity gating, lifecycle, snooze | shift leaders |
| No inventory sibling | Material agent tools via IF-07 ERP adapter; `sibling-stub` in dev; listed as an assumption | integration owner |
| Bus operations (JetStream) new to the team | OPS-13 §6, RB-05 | operator |
| Scenario suite drift | ADR-K10; suite reviewed each quarter | ML owner |

---

## 11. Traceability to SRS-13

| SRS | Where |
|---|---|
| C-01…C-06 | §3.1, ADR-K02/K03/K07/K08, DDS-13 DD-K01…K09 |
| FR-01…07 framework | §4.3 orchestrator, ADR-K01/K02/K07, IF-68, IF-72 |
| FR-08…14 specialists | §4.3 agent runner, IF-16 consumer tables, DDS-13 `trg_finding_author` (domain), `trg_run_status` (every enabled specialist assessed) |
| FR-15…22 manager | §4.3 relator/ranker/briefer, ADR-K04/K05/K06/K09, RV-1, RV-5 |
| FR-23…27 blackboard | DDS-13 lifecycle, occurrences, actions, expiry, precision |
| FR-28…31 delivery | §4.2 discord-bot, RV-6, languages §5 |
| AI-01…08 | P-1, ADR-K03/K04/K05/K09/K10, §4.3 facts object |
| NFR-01…08 | §3.2 |
| AC-01…09 | RV-1…RV-7, QAS-02…09, TEST-13 TS-4, TS-5, TS-7, TS-8 |
