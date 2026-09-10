# Software Requirements Specification — Multi-Agent Factory System

| Field | Value |
|---|---|
| Document ID | SRS-13-KaizenSwarm |
| Project code name | **KaizenSwarm** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify an **orchestrated multi-agent system** in which specialised agents (Quality, Maintenance, Production, Material) each own a domain, and a Manager agent aggregates their findings into a prioritised, cross-domain risk picture for the plant.

The value is not "more agents" — it is **cross-domain reasoning**: a quality signal, a maintenance signal and a schedule constraint that individually look minor may together be the top risk of the shift.

### 1.2 Scope

**In scope**
- Agent framework: registry, capability contracts, messaging, scheduling, budgets.
- Four specialist agents (Quality, Maintenance, Production, Material) with typed tools.
- Manager agent that requests, aggregates, deduplicates, ranks and reports.
- Shared blackboard of findings with provenance and lifecycle.
- Daily/shift risk briefing and on-demand queries.
- Full observability: who asked what, which tools ran, what it cost.

**Out of scope**
- Autonomous action on production systems (findings and recommendations only; execution is delegated to human-approved workflows).
- Replacing the specialised engines — agents call the engines defined in SRS-02/06/09/11.
- Agent-to-agent free-form negotiation (message types are fixed and typed).

### 1.3 Definitions
**Specialist agent** = a bounded agent with a domain, tools and a defined output type. **Finding** = a typed, evidence-backed observation. **Blackboard** = the shared store of findings. **Manager** = the aggregating agent. **Budget** = per-run limits on tool calls, tokens and wall time.

---

## 2. Overall Description

### 2.1 Product perspective
```
                         ┌────────────────┐
                         │  Manager Agent │
                         │  aggregate ·   │
                         │  dedupe · rank │
                         └───┬──┬──┬──┬───┘
             request/response│  │  │  │
        ┌───────────┬────────┘  │  │  └────────┬───────────┐
        ▼           ▼           ▼  ▼           ▼           ▼
   Quality      Maintenance   Production   Material    (extensible)
    Agent          Agent         Agent       Agent
      │              │             │           │
   SPC/defect    telemetry     schedule /    stock /
   tools         health tools  OEE tools    lot tools
      └──────────────┴─────────────┴───────────┘
                        ▼
                   Blackboard (findings + evidence + lifecycle)
                        ▼
          Shift briefing · Dashboard · Discord · Escalation
```

### 2.2 User classes
| Class | Need |
|---|---|
| Plant / production manager | "what are today's top 3 risks?" |
| Shift leader | actionable list at shift start |
| Quality / maintenance engineer | drill into a finding's evidence |
| Admin | agent configuration, budgets, tool permissions |

### 2.3 Operating environment
Docker on-prem; PostgreSQL for the blackboard; Redis/NATS for the message bus; Ollama with a shared model pool (8 GB VRAM baseline → agents run sequentially through a GPU semaphore); Next.js dashboard; Discord for delivery.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | Agents SHALL communicate only through typed messages via the bus — no shared mutable state, no free-form agent chat. |
| C-02 | Every finding SHALL carry evidence references; a finding without evidence is invalid and rejected by the blackboard. |
| C-03 | Agents SHALL be read-only with respect to production systems. |
| C-04 | Each run SHALL enforce budgets (tool calls, tokens, wall time); exceeding a budget produces a partial result with a clear "incomplete" flag, never a silent truncation. |
| C-05 | On a single 8 GB GPU, only one LLM inference runs at a time; the orchestrator SHALL serialise via a semaphore and agents SHALL be designed to work with that latency. |
| C-06 | An agent failure SHALL degrade the briefing (marking that domain unavailable) rather than fail the whole run. |

### 2.5 Assumptions
The underlying engines (SPC, telemetry, production, inventory) exist and expose APIs; a shift/production calendar is available; users accept a briefing that may sometimes be partial.

---

## 3. Functional Requirements

### 3.1 Framework
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | An agent registry SHALL define each agent: name, domain, tools, output schema, budget, schedule, enabled flag. | Must |
| FR-02 | Messages SHALL be typed: `RequestAssessment`, `Finding`, `Clarification`, `Error`, `StatusUpdate` — validated against JSON Schema. | Must |
| FR-03 | The orchestrator SHALL support scheduled runs (shift start, daily) and on-demand runs. | Must |
| FR-04 | The orchestrator SHALL run specialists in parallel where resources allow, and serialise LLM inference through a GPU semaphore. | Must |
| FR-05 | Timeouts, retries with backoff and circuit breaking SHALL be applied per agent. | Must |
| FR-06 | New agents SHALL be addable by configuration + a tool module, without changing the Manager's code. | Should |
| FR-07 | Every run SHALL record a trace: messages, tool calls, tokens, latency, cost, and outcome. | Must |

### 3.2 Specialist agents
| ID | Requirement | Priority |
|---|---|---|
| FR-08 | **Quality Agent** SHALL report: open SPC violations, defect-rate signals with significance, top defect classes, affected SKUs, and open quality cases — via [QE-Agent](../09-quality-engineer-agent/SRS-QE-Agent-Quality-Engineer.md) tools. | Must |
| FR-09 | **Maintenance Agent** SHALL report: machines with degrading health index, open alerts with severity and lead time, overdue preventive maintenance — via [MachineSense](../06-predictive-maintenance-agent/SRS-MachineSense-Predictive-Maintenance.md) tools. | Must |
| FR-10 | **Production Agent** SHALL report: plan vs actual, OEE components, downtime Pareto, and schedule risk for the coming shift. | Must |
| FR-11 | **Material Agent** SHALL report: stock coverage days, incoming delivery risk, lots with quality history, and shortage risk for the schedule. | Should |
| FR-12 | Each specialist SHALL emit findings in the common schema (§5) with severity, confidence, scope, evidence and a recommended action. | Must |
| FR-13 | A specialist SHALL emit an explicit "nothing significant in my domain" finding rather than staying silent. | Must |
| FR-14 | Specialists SHALL NOT reason outside their domain; cross-domain inference is the Manager's job. | Must |

### 3.3 Manager agent
| ID | Requirement | Priority |
|---|---|---|
| FR-15 | The Manager SHALL request assessments from enabled specialists for a given scope (plant, line, shift). | Must |
| FR-16 | The Manager SHALL deduplicate findings describing the same underlying issue across domains. | Must |
| FR-17 | The Manager SHALL detect **cross-domain compounds**: e.g. a machine health alert on the line that also has a quality signal and a tight schedule → elevated combined risk. | Must |
| FR-18 | The Manager SHALL rank risks using an explicit, inspectable scoring function (impact × likelihood × urgency × confidence), not an opaque LLM judgement. | Must |
| FR-19 | The Manager SHALL produce a briefing: top-N risks, each with one-line summary, evidence links, owner suggestion and recommended action. | Must |
| FR-20 | The Manager SHALL mark any domain that failed or timed out and state that the picture is partial. | Must |
| FR-21 | The Manager SHALL answer ad-hoc cross-domain questions by requesting targeted assessments. | Should |
| FR-22 | The Manager SHALL NOT invent findings; it may only aggregate, relate and rank what specialists reported. | Must |

### 3.4 Blackboard & lifecycle
| ID | Requirement | Priority |
|---|---|---|
| FR-23 | Findings SHALL be persisted with status: new → acknowledged → in_progress → resolved → expired. | Must |
| FR-24 | Repeated detection of the same issue SHALL update the existing finding (occurrence count, first/last seen) rather than duplicating. | Must |
| FR-25 | Users SHALL be able to acknowledge, assign, snooze or dismiss a finding with a reason. | Must |
| FR-26 | Dismissals and outcomes SHALL feed a precision report per agent. | Must |
| FR-27 | Findings SHALL expire automatically when their underlying condition clears, with the resolution recorded. | Should |

### 3.5 Delivery
| ID | Requirement | Priority |
|---|---|---|
| FR-28 | The briefing SHALL be delivered to Discord at shift start and be available in the dashboard. | Must |
| FR-29 | CRITICAL findings SHALL be pushed immediately outside the schedule. | Must |
| FR-30 | The dashboard SHALL show the agent run trace and per-agent status/health. | Should |
| FR-31 | Briefings SHALL be available in Thai / Japanese / English. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/runs` | trigger an orchestration run (scope, agents) |
| GET | `/api/v1/runs/{id}` | run status + trace |
| GET | `/api/v1/findings?status=&severity=` | blackboard query |
| POST | `/api/v1/findings/{id}/ack` | acknowledge / assign / dismiss |
| GET | `/api/v1/briefing?date=&shift=&lang=` | briefing |
| POST | `/api/v1/manager/ask` | cross-domain question |
| GET | `/api/v1/agents` | registry + health |

### 4.2 Message bus
NATS/Redis Streams subjects: `agent.request.{agent}`, `agent.finding.{agent}`, `agent.status.{agent}`, `orchestrator.run.{id}`.

---

## 5. Data Requirements

```sql
agent(id, name, domain, version, tools_json, output_schema, budget_json,
      schedule_cron, enabled)
run(id, started_at, finished_at, scope_json, trigger, status, partial_reason)
message(id, run_id, from_agent, to_agent, type, payload_json, ts)
finding(id, agent, first_seen, last_seen, occurrences, domain, scope_json,
        title, summary, severity, confidence, evidence_json,
        recommended_action, status, owner_id, resolved_at, resolution)
compound_risk(id, run_id, finding_ids, rationale, score, components_json)
briefing(id, run_id, lang, top_risks_json, text, delivered_at)
agent_metric(agent, date, runs, failures, findings, dismissed, avg_latency_ms, tokens)
```

**Finding schema (shared contract)**
```json
{
  "agent": "maintenance",
  "domain": "machine_health",
  "scope": {"line": 3, "machine": "M-07"},
  "title": "Bearing temperature trending up on M-07",
  "severity": "HIGH",
  "confidence": 0.78,
  "evidence": [{"kind": "metric", "ref": "telemetry:M-07:bearing_temp:2026-09-03..10"},
               {"kind": "alert",  "ref": "alert:1184"}],
  "recommended_action": "Inspect drive-side bearing within 3 days",
  "impact_estimate": {"downtime_risk_h": 6, "affected_lines": [3]}
}
```

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Specialist agents SHALL use tool results for all facts; the LLM only summarises and phrases. |
| AI-02 | Output SHALL be schema-validated; invalid agent output is rejected and retried once, then reported as an agent error. |
| AI-03 | Risk ranking SHALL be a deterministic scoring function with published weights; the LLM may explain the ranking but not produce it. |
| AI-04 | Compound-risk detection SHALL use explicit relation rules (same line/machine/SKU/time window) plus a configurable rule set — inspectable and testable. |
| AI-05 | Model pool: one shared local model (≤ 9 B) with a GPU semaphore; per-agent prompts versioned in git. |
| AI-06 | Evaluation: a scenario suite of ≥ 15 synthetic plant states with known expected top risks; target top-3 match ≥ 80 %, zero fabricated findings. |
| AI-07 | Each agent SHALL report its own confidence and the data freshness it relied on. |
| AI-08 | Token and time budgets per run SHALL be enforced by the orchestrator, not by the model's cooperation. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | A full 4-agent run SHALL complete in ≤ 3 minutes on the baseline hardware. |
| NFR-02 | An individual agent timeout SHALL default to 60 s. |
| NFR-03 | A single agent failure SHALL never prevent the briefing (C-06), verified by fault-injection tests. |
| NFR-04 | The system SHALL support ≥ 8 registered agents without architectural change. |
| NFR-05 | All runs, messages and findings SHALL be auditable and exportable. |
| NFR-06 | Read-only credentials for all data sources. |
| NFR-07 | Cost/observability: tokens, latency and tool calls per agent per run exposed as metrics. |
| NFR-08 | ≥ 80 % test coverage on orchestrator, scoring and schema validation. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Scenario suite: top-3 risks match expectation in ≥ 80 % of 15 scenarios. |
| AC-02 | Killing the Maintenance agent mid-run yields a briefing marked partial, with the other three domains intact. |
| AC-03 | The same issue reported by two agents appears once, with both evidence sets. |
| AC-04 | A compound risk (quality + maintenance on the same line) ranks above either individual finding. |
| AC-05 | Budget exceeded → partial result flagged; no silent truncation. |
| AC-06 | An agent returning malformed JSON is retried once then recorded as an agent error, without corrupting the blackboard. |
| AC-07 | Manager output contains no claim absent from specialist findings (automated check). |
| AC-08 | Recurring condition updates the existing finding rather than creating duplicates over 5 consecutive runs. |
| AC-09 | Full run trace reconstructs every message and tool call. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | framework: registry, bus, schemas, budgets, tracing |
| P2 | 3–4 | Quality + Production agents with real tools |
| P3 | 5–6 | Maintenance + Material agents |
| P4 | 7–8 | Manager: dedupe, compound rules, scoring, briefing |
| P5 | 9–10 | blackboard lifecycle, ack/assign, precision metrics |
| P6 | 11–12 | dashboard, Discord delivery, scenario suite, fault injection |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Multi-agent complexity without added value | scoring is deterministic; each agent must justify itself via precision metrics; start with 2 agents |
| Latency on a single 8 GB GPU | GPU semaphore, small model, cache, parallel tool calls (non-LLM) |
| Cascading failures | timeouts, circuit breakers, partial briefing, fault-injection tests |
| Agents duplicating or contradicting each other | strict domain boundaries (FR-14), Manager-only cross-domain reasoning, dedupe |
| Alert fatigue from many findings | severity gating, top-N briefing, lifecycle + dismissal feedback |
| Debuggability of agent behaviour | full message/tool trace, deterministic ranking, versioned prompts |

---

## Appendix A — Example briefing

```
🏭 Shift briefing — 2026-09-10 · Shift A · Plant 1
Data freshness: quality 5 min · maintenance 2 min · production 1 min · material 6 h ⚠

TOP 3 RISKS

1. [HIGH 0.84] Line 3 — compound risk: quality + maintenance
   Defect rate 5.82 % (+141 % vs 7-day, p<0.001) AND press M-07 bearing
   temperature +13.8 % over 5 days. Both concentrated on the same line/shift.
   → Inspect M-07 drive-side bearing today; hold RAD-500-A lot LOT-2609-114.
   Evidence: signal S-241 · alert 1184        Owner: Maintenance + QE

2. [HIGH 0.71] Material — coverage risk for SKU RAD-500-A
   Stock coverage 1.4 days against the 3-day schedule; incoming delivery
   confirmed only for 2026-09-14.
   → Confirm supplier ETA today or re-sequence the schedule.
   Evidence: stock:RAD-500-A · po:PO-2026-004821       Owner: Purchasing

3. [MEDIUM 0.52] Production — OEE performance loss on Line 1
   Performance 78 % vs 91 % baseline; micro-stops up 3× since 09-08.
   → Observe changeover and unload station on Line 1.
   Evidence: oee:line1:2026-09-08..10                  Owner: Production

Nothing significant reported by: (none — all domains reported)
Partial: no. Run 411 · 2 min 14 s · 4 agents · 23 tool calls.
```
