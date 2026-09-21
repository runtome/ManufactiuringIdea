# API Specification — KaizenSwarm (Multi-Agent Factory System)

| Field | Value |
|---|---|
| Document ID | API-13-KaizenSwarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-21 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **54 paths / 59 operations / 54 schemas** |
| Source | [SRS-13 §4.1](../SRS-KaizenSwarm-Multi-Agent-Factory.md) · [SAD-13](../docs/SAD-KaizenSwarm-Software-Architecture.md) · [DDS-13](../docs/DDS-KaizenSwarm-Database-Design.md) |
| Parent | [API-00](../../00-factorybrain-platform/api/API-Specification.md) — `/agent/findings`, `/agent/briefing` and their components are served verbatim |

---

## 1. Conventions

- Base URL `https://kaizenswarm.plant.local/api/v1` (standalone) or the platform gateway (`/agent/findings` and `/agent/briefing` at the platform root; the rest under `/swarm/`). JSON, UTF-8, RFC 3339 timestamps in plant time (`+07:00`).
- **SRS-13 §4.1 verbatim**: `POST /runs`, `GET /runs/{id}`, `GET /findings?status=&severity=`, `POST /findings/{id}/ack`, `GET /briefing?date=&shift=&lang=`, `POST /manager/ask`, `GET /agents`.
- **Platform verbatim** (TEST-13 TC-008, 16/16 blocks byte-identical): `/agent/findings`, `/agent/briefing`, `Finding`, `Briefing`, `Severity`, `Shift`, `Language`, `Problem`, `Cursor`, `Limit`, `IdempotencyKey`, the five standard error responses.
- Auth: platform JWT (`bearerAuth`). Roles (SEC-13 §5.7): viewer reads briefings and findings; inspector (shift leader) acknowledges, assigns, snoozes, dismisses; engineer resolves and reads traces; manager triggers runs and asks; admin edits the registry, rules, weights, scenarios.
- Errors: RFC 7807 `application/problem+json` with a stable `code` (§8). Every `409` and `422` in this API is a database refusal surfaced as is — the guards of DDS-13 §5.
- Pagination: `cursor` / `limit` on lists. Idempotency: `Idempotency-Key` on `POST /runs`.

### 1.1 Mapping of the SRS paths
| SRS-13 §4.1 | Operation | Notes |
|---|---|---|
| `POST /api/v1/runs` | `triggerRun` | `202`; scope, optional agent subset; budgets from the registry |
| `GET /api/v1/runs/{id}` | `getRun` | status + one assessment per enabled specialist + links to the trace |
| `GET /api/v1/findings?status=&severity=` | `queryFindings` | plus `agent`, `line`, `issue_code` |
| `POST /api/v1/findings/{id}/ack` | `ackFinding` | acknowledge / assign / start / dismiss in one call |
| `GET /api/v1/briefing?date=&shift=&lang=` | `getShiftBriefing` | the language row of that run; `partial` and freshness always present |
| `POST /api/v1/manager/ask` | `askManager` | `202` + question; answer at `/manager/questions/{id}` |
| `GET /api/v1/agents` | `listAgents` | registry + health |

---

## 2. Tags
`runs` · `findings` · `compounds` · `briefing` · `manager` · `agents` · `rules` · `scenarios` · `exports` · `agent` (platform) · `admin` · `system`.

---

## 3. The finding contract (`findings`)

**What a finding is.** A row on the blackboard (`agent.finding`) with its extension: `issue_code` (family.kind), `issue_key` (the dedupe identity — IF-69 §3), `likelihood_class`, `horizon`, `freshness_min`/`stale`, `impact_estimate`, `owner_suggestion`, and the union of evidence. Every finding has ≥ 1 evidence item — the API cannot return one without, because the database cannot store one (C-02).

**Who wrote it.** `agent` is always a registered, enabled *specialist*; `manager` never appears as an author (FR-22). `domain` is one of that agent's registered domains (FR-14).

**Occurrences.** `GET /findings/{id}/occurrences` returns one row per detection (run, agent, confidence, freshness, that agent's evidence set). AC-03: a lot reported by quality and material is one finding with two occurrences; AC-08: five consecutive detections are one finding with `occurrences = 5`.

**Lifecycle (FR-23, FR-25).** `new → acknowledged → in_progress → resolved`, plus `expired` (system, FR-27), `dismissed` (person, with a reason code), `reopen` from any terminal state. A status changes **only** through an action:

| Call | Effect | Refusals |
|---|---|---|
| `POST /findings/{id}/ack {action: acknowledge}` | `new → acknowledged` | `409 LIFECYCLE_TRANSITION` |
| `… {action: assign, assignee_id}` | sets owner, `→ in_progress` | `422` without assignee |
| `… {action: dismiss, dismiss_reason, reason}` | `→ dismissed`; feeds precision (FR-26) | `422` without a reason code |
| `POST /findings/{id}/snooze {until, reason}` | status unchanged; no reminders until `until` | `409 SNOOZE_UNTIL` |
| `POST /findings/{id}/resolve {reason}` | `→ resolved` with the resolution | `409 LIFECYCLE_TRANSITION` |
| `POST /findings/{id}/reopen {reason}` | terminal `→ new` | `409 REOPEN_ONLY_TERMINAL` |

There is no `PATCH /findings/{id}` — a direct status write is `409 ACTION_REQUIRED` in the database and has no endpoint.

**Scores.** `GET /findings/{id}/scores` lists the finding's score in every run with the four factors and the weights version (§5).

---

## 4. The run contract (`runs`)

**Trigger.** `POST /runs {scope, agents?, trigger?}` → `202 Run{status: queued|running}`. The orchestrator publishes `RequestAssessment` (IF-17) with each agent's budget (`{tool_calls, tokens, wall_ms}`) and deadline. `agent_count` is the number of enabled specialists at that moment.

**Assessments (FR-13, C-04, AC-05).** `GET /runs/{id}/assessments` — exactly one per enabled specialist:

| `outcome` | Meaning | `incomplete` | Briefing |
|---|---|---|---|
| `findings` | ≥ 1 finding published | false | complete |
| `nothing_significant` | explicit "nothing in my domain", with what was checked | false | complete |
| `timeout` | no reply by the deadline (AC-02) | true | **partial** |
| `budget_exceeded` | a tool call or token over budget; the orchestrator stopped it | true | **partial** |
| `invalid_output` | schema-invalid twice (AI-02, AC-06) | true | **partial** |
| `failed` / `circuit_open` | transport error / breaker open (FR-05) | true | **partial** |

`usage` vs `budget` and the `violation` text are returned so a partial result is never a mystery. A `findings`/`nothing_significant` assessment over budget cannot exist (`BUDGET_SILENT_TRUNCATION`).

**Status.** `completed` (every agent reported), `partial` (with `partial_reason` naming every failed domain — FR-20), `failed`, `cancelled`. `POST /runs/{id}/cancel` stops a running run (`409 RUN_FINISHED` otherwise).

**Trace (FR-07, AC-09).** `GET /runs/{id}/trace` — messages, the specialists' LLM runs (platform `agent.run`), tool calls (platform `agent.tool_call`), leases and attempts in time order; `GET /runs/{id}/messages` — the typed bus log; `GET /runs/{id}/export` — the IF-72 JSON with `message_log_sha256`.

---

## 5. The ranking contract (`runs/{id}/ranking`, `compounds`, `rules`)

**Score (FR-18, AI-03).** For every finding that occurred in the run:

`score = impact[severity] × likelihood[likelihood_class] × urgency[horizon] × confidence`

with the tables of the active `ScoringWeights` version (`GET /scoring-weights`; v1: impact INFO 0.2 / LOW 0.4 / MEDIUM 0.6 / HIGH 0.8 / CRITICAL 1.0; likelihood observed 1.0 / trend 0.8 / forecast 0.6 / possible 0.4; urgency this_shift 1.0 / today 0.9 / within_3_days 0.8 / this_week 0.6 / later 0.4). `RiskScore` returns all four factors, rounded as stored; the database refuses any stored score that is not this product (`SCORE_NOT_COMPUTED`). Appendix A: 0.8 × 1.0 × 1.0 × 0.85 = **0.68** (quality), 0.8 × 1.0 × 0.8 × 0.78 = **0.4992** (maintenance), 0.8 × 1.0 × 1.0 × 0.89 = **0.712** (material), 0.6 × 1.0 × 0.9 × 0.96 = **0.5184** (production).

**Compounds (FR-17, AI-04, AC-04).** `RelationRule`s are evaluated in `code` order; a group of ≥ 2 unabsorbed findings from ≥ `min_domains` domains that agree on the rule's `match_keys` within `window_hours` becomes a `CompoundRisk` with `score = 1 − Π(1 − sᵢ)` — by construction ≥ every component. Components are absorbed (they no longer rank on their own; `RiskScore.absorbed_by`). `rationale` names the rule, the shared key and the component scores; `components[].factors` gives each component's four factors. Appendix A: `same_line` on line 3 → 1 − 0.32 × 0.5008 = **0.8397 → 0.84**.

**Ranking (FR-19).** `GET /runs/{id}/ranking` — compounds and unabsorbed findings by score desc, then title; `rank` is stored. The briefing takes the top N (`top_n`, default 3).

**Changing the arithmetic.** `POST /scoring-weights` publishes a new version (inactive); `POST /scoring-weights/{version}/activate` is refused with `409 SCENARIO_GATE` unless a suite run with that version passed (§6.1, ADR-K10). Rules likewise are created disabled and enabled after the suite passes.

---

## 6. The briefing contract (`briefing`, `briefings`, `deliveries`)

`BriefingDetail` = the platform `Briefing` (`partial`, `partial_reason`, `data_freshness`, `top_risks[]`, `text`) plus the run link, `top_n`, the `rank` list, the `claim_check` and deliveries.

- `top_risks[]` carries rank, score (2 dp), severity, title, `finding_ids`, `recommended_action`, `owner`, `evidence` — the deterministic template; `text` is the Manager's phrasing of exactly that, in `lang`.
- **Claim check (FR-22, AC-07).** Every numeric token in `text` must occur in the cited findings (title, summary, action, evidence, impact, score) or the run's own metadata (run number, wall time, agent count, tool calls, freshness, partial reason). The check is stored with the briefing and returned by `GET /briefings/{id}/claim-check`. A phrasing that fails is retried once with the failed tokens listed, then the template text is used (`template_fallback: true`). A briefing with an unmatched number is never returned: the database refuses it (`BRIEFING_UNGROUNDED`).
- **Partial (FR-20, AC-02).** `partial` is true iff an assessment of the run failed; `partial_reason` names each failed domain (`BRIEFING_PARTIAL_MISMATCH` / `BRIEFING_PARTIAL_REASON` otherwise). `data_freshness` per domain; ⚠ when older than 60 min.
- **Languages (FR-31).** One `Briefing` row per language of the same run and the same `top_risks_json`; `GET /briefing?lang=` returns that row.
- **Delivery (FR-28, FR-29).** Shift briefings go to Discord and the dashboard at shift start; a CRITICAL finding creates an `immediate` delivery on insert. `GET /deliveries` lists both.

### 6.1 The scenario suite as a gate
`POST /scenarios/run {mode}` runs the deterministic half in SQL (`run_suite`) — dedupe, compounds, scoring, ranking on each scenario's synthetic findings — or the full run with the model in CI. `SuiteRun.passed` = `scenarios ≥ 15 ∧ match_rate ≥ 0.80 ∧ fabricated = 0`. The seed's suite: 14/15 (SC-15 is a documented disagreement).

---

## 7. The trace & export contract (`runs/{id}/export`, `exports`)
`RunExport` (IF-72) is the complete run: `run`, `assessments` with budgets, `messages` in `seq` order with payloads, `tool_calls`, `leases`, `attempts`, `ranking`, `message_log_sha256` = sha256 over `seq|type|from|to` lines joined by `\n`. `swarm.export` keeps the hash; an auditor recomputes it from the export. `POST /exports {kind: findings|briefing|audit, from_ts, to_ts}` for periods.

---

## 8. Error catalogue

| HTTP | `code` | Raised by |
|---|---|---|
| 401 / 403 | platform | missing or insufficient token / role |
| 404 | `NOT_FOUND` | unknown run, finding, agent, rule, version |
| 409 | `LIFECYCLE_TRANSITION`, `ACTION_REQUIRED`, `REOPEN_ONLY_TERMINAL`, `SNOOZE_UNTIL`, `RESOLUTION_REQUIRED` | finding lifecycle (DDS-13 DD-K08) |
| 409 | `RUN_FINISHED`, `RUN_NOT_COMPLETE`, `RUN_NOT_PARTIAL`, `PARTIAL_REASON` | run status |
| 409 | `MANAGER_REQUIRED`, `REGISTRY_KIND_IMMUTABLE`, `TOOL_NOT_READ_ONLY` | registry |
| 409 | `CIRCUIT_TRANSITION`, `SCENARIO_GATE` | circuit / weights activation |
| 422 | `VALIDATION_FAILED` | request body or query |
| 422 | `BRIEFING_UNGROUNDED`, `BRIEFING_PARTIAL_MISMATCH`, `BRIEFING_PARTIAL_REASON`, `BRIEFING_FOREIGN_FINDING` | briefing insert (surfaced to the orchestrator; never to a reader, who only ever sees a stored briefing) |
| 422 | `FINDING_AUTHOR`, `DOMAIN_VIOLATION`, `EVIDENCE_SHAPE`, `FINDING_SHAPE`, `MESSAGE_SHAPE`, `MESSAGE_PARTY` | blackboard writer / bus (orchestrator-side) |
| 422 | `SCORE_NOT_COMPUTED`, `COMPOUND_*` | ranking (orchestrator-side) |
| 422 | `BUDGET_SILENT_TRUNCATION`, `BUDGET_NOT_EXCEEDED`, `MAX_ATTEMPTS`, `RETRY_NOT_ALLOWED`, `BACKOFF_*`, `GPU_SEMAPHORE` | orchestrator-side guards |
| 429 | `RATE_LIMITED` | runs and questions per user |
| 503 | `NOT_READY` | a dependency is down (`/readyz`) |

---

## 9. Roles per operation (summary)
| Operation group | viewer | inspector | engineer | manager | admin |
|---|---|---|---|---|---|
| read briefings, findings, compounds, agents | ✅ | ✅ | ✅ | ✅ | ✅ |
| ack / assign / snooze / dismiss | | ✅ | ✅ | ✅ | ✅ |
| resolve / reopen; run traces, messages, exports | | | ✅ | ✅ | ✅ |
| trigger runs, cancel, ask the manager, deliver | | | | ✅ | ✅ |
| registry, tools, circuit, rules, weights, scenarios, config | | | | | ✅ |

Line scope (platform `user_line_scope`) filters findings, compounds and briefing items for restricted users; a run's plant-wide briefing is visible to the roles above regardless of scope only when the user has no line restriction (SEC-13 O-5).
