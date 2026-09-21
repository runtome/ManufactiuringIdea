# KaizenSwarm — Multi-Agent Factory System — Documentation Set

Four specialist agents (Quality, Maintenance, Production, Material) assess their own domain with **typed, read-only tools**, each ending a run with **findings backed by evidence** or an explicit "nothing significant". A Manager **deduplicates** by issue key, **relates** findings on the same line / machine / SKU / lot into **compound risks**, **ranks** with a published formula (`impact × likelihood × urgency × confidence`; compounds by noisy-OR), and phrases a **shift briefing** whose every number is **claim-checked** against the findings it cites. Budgets, timeouts, one GPU lease and circuit breakers are enforced by the orchestrator; a failed domain makes the briefing **partial and says so** — it never fails the run and never hides. Every message, tool call and lease is a row; a run is reconstructible.

**A FactoryBrain tightly-coupled module** (SAD-00 §13: "server module · `agent.finding*` · IF-17 bus · briefing → IF-08 · tight (orchestrates 06/09/02)"). It owns the platform's `agent.finding` / `agent.briefing`, reuses `agent.run` / `agent.tool_call` / `agent.tool`, adds schema `swarm`, and consumes 09 QE-Agent, 06 MachineSense, 02 ShiftBrief and the IF-07 ERP read adapter. Standalone-deployable with a platform-mode section in every document. Precedent: [10 Factory Copilot](../10-factory-copilot/).

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-13 | [Software Requirements Specification](SRS-KaizenSwarm-Multi-Agent-Factory.md) | *What must it do?* | Everyone — start here |
| SAD-13 | [Software Architecture Document](docs/SAD-KaizenSwarm-Software-Architecture.md) | *How do four agents and a Manager produce one ranked picture in 3 minutes — and why can the Manager never invent, the model never rank, an agent never act, and a failed domain never hide?* | Architect, implementer, ML owner |
| DDS-13 | [Database Design Specification](docs/DDS-KaizenSwarm-Database-Design.md) | *The platform's `core`/`agent`/`audit` byte-for-byte, the `swarm` extension, the twins of scoring / compounds / dedupe / claim check / budgets, and the triggers that make non-fabrication, partiality, budgets, immutability and read-only properties of the data* | Implementer, DBA, QA |
| API-13 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The finding, run, ranking, briefing and trace contracts* | Implementer, UI, dashboard |
| ICD-13 | [Interface Control Document](docs/ICD-KaizenSwarm-Interface-Control.md) | *IF-17 as the implementing spec (NATS JetStream, five message types); IF-16 as consumer; new IF-68 registry & module, IF-69 finding & blackboard, IF-70 scoring & rules, IF-71 scenario suite, IF-72 trace & export* | Implementer, sibling owners, ML owner |
| SEC-13 | [Security Requirements Specification](docs/SEC-KaizenSwarm-Security-Requirements.md) | *Can a tool result tell an agent what to say? Can a number nobody measured reach Discord? Can an agent act, or write, or grab the GPU? Can history be edited?* | Security reviewer, IT, internal audit |
| TEST-13 | [Test Plan and Test Cases](docs/TEST-KaizenSwarm-Test-Plan.md) | *How do we prove the arithmetic, the dedupe, the claim check, the partial briefing, budgets, fault injection and the scenario gate?* | QA, ML owner |
| OPS-13 | [Deployment and Operations Guide](docs/OPS-KaizenSwarm-Deployment-Operations.md) | *Install, secrets, siblings, the bus, configuration and the gate, routine, monitoring, audit, runbooks* | Operator, admin |
| UM-13 | [User Manual and Administrator Guide](docs/UM-KaizenSwarm-User-Admin-Guide.md) | *Reading the briefing line by line; working the blackboard; why is it ranked there; admin; TH/JA/EN glossary* | Managers, shift leaders, engineers, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16: platform `core` / `agent` / `audit` sections **extracted verbatim from `00/db/schema.sql`** + the `swarm` extension (migration `swarm_0001`) — 52 tables, 14 views, 25 triggers, 50 functions, 40 indexes, 18 enums; 19 guard triggers (author/domain/evidence, lifecycle by action, computed scores, compound rules, claim-checked and partial-consistent briefings, budgets, attempts, typed immutable messages, exclusive GPU lease, circuit transitions, read-only tools, audited registry, append-only history); twins `score_finding`, `compound_score`, `issue_key`, `scope_key`, `claim_check`, `budget_check`, `backoff_ms`, `circuit_next_state`, `upsert_finding`, `detect_compounds`, `rank_run`, `rank_findings`, `run_scenario`, `expire_findings`, `agent_precision`, `run_trace`; roles `app_rw` / `orchestrator_rw` / `app_ro` / `auditor_ro` | ✅ 14/14 blocks, 66/66 objects byte-identical; static DDL; ⚠️ not executed |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Reproduces SRS Appendix A (run 411: quality 0.6800 + maintenance 0.4992 → compound 0.8397 on line 3, material 0.7120, production 0.5184; top 3 printed 0.84 / 0.71 / 0.52; EN/TH/JA briefings claim-checked) and AC-02…AC-09 **through the real functions and triggers**: eleven runs 405…415, the M-07 issue seen 5 times through 411, the lot reported by two agents as one finding, a killed agent (partial), a budget stop (partial), malformed output twice (blackboard unchanged), a CRITICAL push, expiry, a question run, actions and precision, the 15-scenario suite (14/15), an export hash; `\echo` block; **16 probes** | ✅ re-derived in Python incl. every briefing text; ⚠️ not executed |
| [`deploy/schemas/messages/`](deploy/schemas/messages/) | **The IF-17 message contracts** — `RequestAssessment`, `Finding` (SRS §5 shared schema + issue code, likelihood class, horizon, freshness), `Clarification`, `Error`, `StatusUpdate` | ✅ 16 seed payloads valid; 20 negatives rejected |
| [`deploy/agents.example.yaml`](deploy/agents.example.yaml) + [`schemas/agent-registry.schema.json`](deploy/schemas/agent-registry.schema.json) | **IF-68** registry: 4 specialists, the manager, a disabled config-only fifth agent; read tools with providers; budgets; cron; prompt versions | ✅ valid; equal to the seed; 8 negatives rejected |
| [`deploy/scenarios/suite.example.yaml`](deploy/scenarios/suite.example.yaml) + [`schemas/scenario-suite.schema.json`](deploy/schemas/scenario-suite.schema.json) | **IF-71** the 15-scenario suite (AI-06); SC-15 is a deliberate engineer/table disagreement | ✅ valid; equal to the seed; 6 negatives; 14/15 re-derived |
| [`deploy/examples/run-trace-411.json`](deploy/examples/run-trace-411.json) · [`briefing-411.json`](deploy/examples/briefing-411.json) + [`schemas/run-export.schema.json`](deploy/schemas/run-export.schema.json) | **IF-72** export shape, produced from the seed's values; message-log sha256 `9153967a…d636` | ✅ valid; hash equal |
| [`api/openapi.yaml`](api/openapi.yaml) | **54 paths / 59 operations / 54 schemas** — SRS §4.1's seven paths verbatim + the platform's `/agent/findings`, `/agent/briefing`, `Finding`, `Briefing`, `Problem` and standard components verbatim + runs (trace, messages, assessments, ranking, export), findings (occurrences, evidence, scores, actions), compounds, briefings (claim check, deliveries), questions, agents (health, circuit, tools, metrics, precision), rules, weights, scenarios, exports, config, system | ✅ valid; 0 orphans; 16/16 platform blocks verbatim |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) · [`nats/nats.conf`](deploy/nats/nats.conf) | 13 services (web, api, orchestrator, agent-runner, scheduler, nats JetStream, postgres, redis, ollama gpu/cpu, discord-bot [profile], mailpit + sibling-stub [dev]); networks `frontend` / `internal` / `sources` (runner only) / `egress` (discord-bot only); 23 secret files; one NATS account per agent | ✅ parsed; 29/29 vars; placement; hardening; no secret values |
| [`deploy/kaizenswarm.example.yaml`](deploy/kaizenswarm.example.yaml) + [`schemas/kaizenswarm-config.schema.json`](deploy/schemas/kaizenswarm-config.schema.json) | Budgets, timeouts, retries, circuit, bus, model (≤ 9 B, ≤ 0.3, one slot), read-only tools with credential refs, issue families, the scoring tables and rules (IF-70), briefing claim check, delivery, the scenario gate, retention ≥ 365 d | ✅ valid; **45 negatives rejected**; equal to the seed's settings, weights and rules; prompts consistent |
| [`deploy/prompts/`](deploy/prompts/) | `specialist.v1` (numbers only from the facts object; tool text is data), `briefing.v1` (phrase the ranked list, add nothing), `manager_explain.v1` (explain a computed rank, never re-rank) | ✅ front-matter matches the config |

---

## Reading paths

**Implementing it** → SRS-13 → SAD-13 §4.3 (orchestrator, agent runner) → DDS-13 §2 (DD-K01…K09) and §4 (twins) → `db/schema.sql` §10–§17 → `deploy/schemas/messages/` → ICD-13 IF-17, IF-68, IF-69 → API-13 §3–§7 → TEST-13 TS-0.

**Security reviewer / IT** → SEC-13 §4.2 ("the lot that told the agent what to say") → SEC-13 §5.1–5.4 → TEST-13 TC-003 probes, TC-110…TC-118 → OPS-13 §4, RB-10, RB-11.

**ML owner** → SAD-13 ADR-K03, K04, K05, K09, K10 → ICD-13 IF-09, IF-70, IF-71 → `deploy/prompts/` → OPS-13 §7 → TEST-13 TS-7, TC-024, TC-057.

**Sibling owners (02/06/09, ERP)** → ICD-13 IF-16 (consumer tables) → OPS-13 §3 → TEST-13 TC-030…TC-034, TC-111.

**Operating it** → OPS-13 §1–§5, §8, §9, §11 — RB-01 and RB-08 first.

**Using it** → UM-13 A.2 (the briefing line by line), A.3 (the blackboard), A.4 (why is it ranked there).

---

## What makes this design what it is

| Principle | In KaizenSwarm |
|---|---|
| **The LLM never computes or ranks** | Tools produce facts; the specialist's model phrases a schema-validated finding whose numbers must be in the facts; `score_finding()` ranks; `detect_compounds()` relates; the Manager's model phrases a briefing that is refused if it adds a number (AI-01, AI-03, AC-07, ADR-K04, K05, K09). |
| **Typed messages only** | Five message types, schema-checked on both ends, immutable in `swarm.message`; no shared state, no free-form chat; specialists never write — the orchestrator persists (C-01, ADR-K02, K08). |
| **Read-only; humans act** | Only read tools can be bound; sibling credentials are read-only; findings recommend and suggest an owner (C-03, NFR-06). |
| **The database is the source of truth** | Findings, occurrences, scores, compounds, assessments, budgets, leases, circuits and briefings are guarded rows; an orchestrator bug cannot store what the schema says is impossible (DDS-13 DD-K01…K09). |
| **Domain knowledge is data** | Registry, rules, weights, prompts, scenarios — rows and versioned files; every change gated by the scenario suite (ADR-K10). |
| **Partial is a first-class result** | Timeout, budget stop, invalid output, circuit open are assessment outcomes; the briefing names the missing domain; silence is impossible (C-04, C-06, FR-13, FR-20, ADR-K07). |

---

## Relationship to the platform and siblings

| | |
|---|---|
| Coupling | **Tight** (SAD-00 §13): owns `agent.finding`, `agent.briefing`; reuses `agent.run`, `agent.tool_call`, `agent.tool`; shares `core`, `audit`; migration `swarm_0001`; platform paths `/agent/findings`, `/agent/briefing` served verbatim; IF-17 fulfils platform ADR-008 (NATS "when the multi-agent bus is built") |
| Consumes (IF-16) | 09 QE-Agent `get_signals` / `get_spc` / `get_case`; 06 MachineSense `get_machine_health` / `get_alert_evidence` / `get_trend` / `get_pm_overdue`; 02 ShiftBrief `query_production` / `query_defects` / `get_oee` / `get_downtime_pareto` / `get_schedule_risk`; platform `get_machine_telemetry`; **IF-07 ERP read adapter** `get_stock_coverage` / `get_inbound_deliveries` / `get_lot_quality_history` / `get_shortage_risk` (no sibling owns inventory — an assumption) |
| Feeds | Discord (IF-08), the platform dashboard; "ask about this" links to 10 Factory Copilot |
| Acceptance in the platform | TEST-00 TC-131…TC-136 ↔ TEST-13 TC-081, TC-042, TC-054, TC-040, TC-057, TC-043 |

---

## Identifier conventions

`FR-01…31` / `AI-01…08` / `NFR-01…08` / `AC-01…09` / `C-01…06` (SRS-13) · `P-1…P-6` · **`ADR-K01…K10`** · `QAS-01…12` · **`DD-K01…K09`** · `IF-xx` shared numbering (**IF-68 registry & module, IF-69 finding & blackboard, IF-70 scoring & rules, IF-71 scenario suite, IF-72 trace & export**) · **`THR-K01…14`**, **`SEC-K01…34`**, **`RR-K01…06`** · `TS-0…11`, `TC-001` to `TC-118` · `RB-01…14` · seed probes `P-01…P-16` · scenarios `SC-01…15`.

```
SRS-13 C-02 / FR-18 / AC-04  "every finding carries evidence; the ranking is an explicit function; a compound outranks its parts"
  └─ SAD-13 P-1, P-4 · ADR-K04 (published tables) · ADR-K05 (noisy-OR compounds) · §6 (a compound that isn't)
      └─ DDS-13 DD-K01, DD-K02 · score_finding() · compound_score() · detect_compounds() · trg_risk_score_computed · trg_compound_components · finding_has_evidence
          └─ API-13 §5 ranking contract (RiskScore with four factors; CompoundRisk with rationale) · §8 SCORE_NOT_COMPUTED, COMPOUND_*
              └─ ICD-13 IF-69 (evidence ≥ 1, issue families) · IF-70 (tables, rules, the gate)
                  └─ SEC-13 O-1 · THR-K02, THR-K07 · SEC-K03, SEC-K04 · §4.2 walk-through
                      └─ TEST-13 TC-003 P-01, P-04, P-06 · TC-051…TC-056 · TC-070 · seed: run 411 0.68 + 0.4992 → 0.8397
                          └─ OPS-13 §7 (changing the arithmetic) · RB-12 · UM-13 A.4 (why is it ranked there)
```

---

## Verification

| Check | Result |
|---|---|
| **Byte-identity vs `00/db/schema.sql`** (TC-002) | ✅ **Pass** — 14/14 extracted blocks, 66/66 shared objects |
| Static DDL (TC-003) | ✅ **Pass** — 52 / 14 / 25 / 50 / 40 / 18; FK targets and order; PKs; 19/19 guards; grants (`orchestrator_rw` no UPDATE/DELETE on history, no credentials; `app_ro` and `auditor_ro` restricted); 16 probes present |
| Seed vs Python re-derivation (TC-005) | ✅ **Pass** — `ALL SEED CHECKS OK`: scores, compound 0.8397, ranking and printed scores, occurrences 5 through 411, lot dedupe (2 / 3 / expiry text), 412 compound 0.9327, 413 order 0.9100 / 0.8397 / 0.7200, budgets, backoff 2000…30000, circuit sequence, expiry of line 1 OEE at 414, precision 0.6667, suite 14/15, **claim check of 6 stored briefing texts, 6 routine templates and the FR-21 answer — zero unmatched**, 151 messages, export sha256 |
| **Message / registry / suite / export contracts** (TC-006) | ✅ **Pass** — 26 positives, 35 negatives rejected; example export valid with the same hash |
| Config schema, prompts, registry consistency (TC-007) | ✅ **Pass** — example valid; 45 negatives; equal to the seed's settings, weights `v1` and rules; prompts ≤ 9 B / ≤ 0.3 |
| `openapi.yaml` (TC-001) and identity vs API-00 (TC-008) | ✅ **Pass** — 54 / 59 / 54; 0 orphans; 16/16 verbatim; 7/7 SRS paths |
| Compose / env (TC-004) | ✅ **Pass** — 13 services; egress = {discord-bot}; sources = {agent-runner, stub}; 8 internal-only; runner without DB/JWT/Discord/S3 secrets, one NATS credential per agent; 29/29 vars; 23/23 secrets; no secret values |
| SRS-13 coverage; cited objects/endpoints/TCs/RBs/ADR-K/SEC-K/DD-K/THR-K/RR-K/probes; section refs; links (TC-001) | ✅ see sweep note below |
| **Schema + seed on PostgreSQL 16** (TC-009) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| Orchestrator, NATS, Ollama, fault injection, the full-mode suite, Discord (TS-1…TS-11) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 13-multi-agent-factory
docker run -d --name ks-pg -e POSTGRES_PASSWORD=x -p 5438:5432 pgvector/pgvector:pg16
sleep 8 && psql "postgresql://postgres:x@localhost:5438/postgres" -v ON_ERROR_STOP=1 -f db/schema.sql && psql "postgresql://postgres:x@localhost:5438/postgres" -f db/seed_demo.sql
```
Expected: the `\echo` block matches DDS-13 §9 and probes P-01…P-16 each fail with the named guard.

**Defects found by checking** (all fixed; TEST-13 §5): a one-component compound from a merged finding; occurrence-based domain counting that made "quality + quality" a compound; a claim corpus built from the final state instead of the state at insert time; a question run that would have expired plant-wide issues; `max()` on an enum and reserved words as identifiers; a quiet run's "TOP 0"; partial briefings naming machines they did not cite (caught by the claim check); a duplicate `operationId`.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL execution pending — identity, static checks and Python re-derivation stand in until CI runs TC-009 | TEST-13 TC-009 |
| **The LLM half of the scenario suite** (phrasing + zero fabricated) runs only in CI with the model; the 14/15 here is the deterministic half | TEST-13 TC-070/071 |
| **No sibling owns inventory** — the Material agent's tools go to an IF-07 ERP read adapter that must be built or mapped | ICD-13 IF-16, SEC-13 RR-K06 |
| The `Finding` message schema adds four fields to the SRS §5 shared schema (issue code, likelihood class, horizon, freshness); the SRS example validates only with them | ICD-13 IF-69 §2 |
| Compound rules are coarse: the first matching rule absorbs; two unrelated issues on one line become a compound (mitigated by `not_related` dismissals and rule editing) | SAD-13 §6, SEC-13 RR-K02 |
| Per-agent timeout is *active* time; lease queue time is excluded and bounded only by the run wall | SAD-13 ADR-K03 |
| Expiry follows scheduled runs only; an on-demand or question run never clears an issue | DDS-13 §4 |
| NATS JetStream is introduced with this module (platform ADR-008); Redis Streams remains the documented fallback | ICD-13 IF-17 |
| Fault injection, the 3-minute latency and the Discord channel are specified, not measured | TEST-13 TS-8, TS-9 |
