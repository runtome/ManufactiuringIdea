# API Specification — OpsPilot Local AI Operations Agent

| Field | Value |
|---|---|
| Document ID | API-04-OpsPilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **38 paths / 43 operations / 20 schemas**, validated with `openapi-spec-validator` |
| Related | [SAD-04](../docs/SAD-OpsPilot-Software-Architecture.md) · [DDS-04](../docs/DDS-OpsPilot-Database-Design.md) · [ICD-04](../docs/ICD-OpsPilot-Interface-Control.md) (Discord commands map onto these endpoints) · [SEC-04](../docs/SEC-OpsPilot-Security-Requirements.md) |

---

## 1. Purpose and consumers

The internal API behind everything a person does with OpsPilot: the Discord bot (IF-08) translates slash commands and button clicks into these calls; the web console is a client of the read endpoints plus approve/deny; `opsctl` scripts them. SRS-04 §4.1 lists six endpoints; this specification keeps those six (same paths, same purpose) and adds what the console, runbooks, alerts, incidents and audit need.

Targets are **not** clients. The agent reaches Docker hosts, databases and repositories through IF-25…IF-29, never through this API.

## 2. Conventions

| Topic | Rule |
|---|---|
| Base path | `/api/v1`, internal network only — never exposed to the internet (SEC-O10) |
| Auth | Bearer JWT with `role` ∈ viewer/operator/admin/owner; 15-min access, 12-h refresh; the Discord bot uses a service token and forwards the mapped user (§5) |
| Formats | JSON; RFC 3339 timestamps (UTC in storage, offset preserved in responses); UUIDs as strings |
| Errors | RFC 7807 `application/problem+json`, `type = urn:opspilot:problem:<slug>`, stable `code` (§7), `correlation_id` = run id where applicable |
| Pagination | Cursor (`next_cursor`), `limit ≤ 200`, default 50 |
| Idempotency | `Idempotency-Key` on `/ask`, `approve`, `deny`, `runbooks/{name}/run`; replay returns the original response for 24 h |
| Async | `/ask` and runbooks return `202` with a run id; poll `GET /runs/{id}` or stream `GET /runs/{id}/events` (§8) |
| Rate limits | `/ask` 30/min per user; `approve` 10/min per user; action-level limits are policy (§3) |
| Redaction | Every tool result in every response is the **redacted** form; there is no endpoint that returns raw results (NFR-05) |

## 3. The approval contract

A proposal is a row the policy engine created with `status = pending`, bound to `args_hash = sha256(tool_name | canonical args)`. `POST /proposals/{id}/approve` re-evaluates, **at approval time**, in this order — and stops at the first failure:

| # | Check | Failure | HTTP / `code` |
|---|---|---|---|
| 1 | `status = pending` | already decided / expired / executed | 409 `PROPOSAL_NOT_PENDING` |
| 2 | `now ≤ expires_at` (≤ 10 min from creation, FR-19) | expired | 409 `APPROVAL_EXPIRED` |
| 3 | caller role rank ≥ `require_role` | too low | 403 `ROLE_INSUFFICIENT` |
| 4 | no active change freeze for the env (write tools) | frozen | 409 `CHANGE_FREEZE` |
| 5 | rate limit for (tool, key) not exceeded | exceeded | 429 `RATE_LIMITED` + `Retry-After` |
| 6 | `args_hash` equals the hash of the stored args (defence against a tampered row) | mismatch | 409 `APPROVAL_HASH_MISMATCH` |
| 7 | single-use lock acquired (Redis `SETNX` + DB transition trigger) | concurrent approval | 409 `PROPOSAL_NOT_PENDING` |

Passing all seven → `status = approved`, execution is enqueued, and the response returns the proposal with `status: approved`. **Every outcome, pass or fail, is an `audit.log` row** (FR-31) — including the ones the model never sees.

Deny (`POST /proposals/{id}/deny`) needs only check 1 and a role ≥ operator; it changes nothing on any target and is audited (AC-03).

Things the API **cannot** do, by construction:
- create a proposal for a tool not in the registry or on the deny-list — the policy engine refuses before a row with `status = pending` exists; the refusal is stored as `denied` with `denied_reason = DENYLISTED` and actor `policy` (AC-04);
- set `auto_execute` for a `high`-risk tool (`PUT /policies` → 422 `POLICY_INVALID`; also a DB trigger);
- change a proposal's tool or arguments (DB trigger).

## 4. The verification contract

`status = executed` is only reachable with `before`, `after` and `verification_ok` populated (DB CHECK). The executor runs the tool's `verify_with` read tool before the action and again after; the report the user sees is the **diff of those two JSON documents**, and `verification_ok` is a rule over the after-state (e.g. `restart_container` → container running and healthy; `redeploy_last_good` → health 200). Model text never sets these fields (FR-16, FR-20). A failed verification is `status = failed` with the evidence attached — the API never says "done" for a failed one.

## 5. Identity and roles

| Client | Identity | Role source |
|---|---|---|
| Console | JWT from `/auth/login` (+ MFA for admin/owner) | `ops.app_user.role` |
| Discord bot | Service token; forwards `X-On-Behalf-Of: <ops.app_user.id>` resolved from `discord_user_id` | Same table; unmapped Discord users → `viewer` |
| `opsctl` | Personal token | Same |

Role ladder: viewer < operator < admin < owner. `require_role` on a proposal is what the **policy** says for that tool in that env (e.g. `redeploy_last_good` in prod → admin). The agent itself has no role and no token to this API (SRS-04 §2.2).

## 6. Endpoint groups

| Group | Endpoints | Notes |
|---|---|---|
| Ask | `POST /ask`, `POST /diag/{target}` | `/diag` is synchronous and deterministic; `/ask` is async and may propose one action |
| Runs | `GET /runs`, `/runs/{id}`, `/runs/{id}/tool-calls`, `/runs/{id}/timeline`, `/runs/{id}/events` | Timeline = `v_run_timeline` (AC-07) |
| Proposals | `GET /proposals`, `/proposals/{id}`; `POST …/approve`, `…/deny`, `…/dry-run`, `…/abort` | §3; dry-run stores `dry_run_json` (FR-22); abort records partial outcome (FR-23) |
| Tools | `GET /tools`, `/tools/{name}`, `PATCH /tools/{name}` | PATCH = enable/disable only; schema, risk, deny-list are code |
| Policy | `GET/PUT /policies`, `GET/POST /freezes`, `DELETE /freezes/{id}` | PUT loads a validated `policy.yaml` atomically |
| Runbooks | `GET /runbooks`, `POST /runbooks/{name}/run`, `GET /runbooks/{name}/runs` | Write steps go through §3 |
| Alerts | `GET /alerts`, `POST /alerts/{id}/ack`, `GET /alert-rules`, `GET /sweeps` | FR-25, FR-26 |
| Incidents | `GET/POST /incidents`, `GET/PATCH /incidents/{id}`, `POST /incidents/{id}/summary` | Summary timeline is data; prose cites event ids (FR-27) |
| Targets | `GET /targets`, `PATCH /targets/{code}` | enable/tags only; endpoints and secrets are provisioning |
| Audit | `GET /audit`, `POST /audit/export` | NDJSON + signed manifest (FR-32) |
| Auth / system | `/auth/login`, `/auth/refresh`, `/me`, `/healthz`, `/readyz`, `/metrics` | `/readyz` reports `llm: false` without failing (NFR-06) |

## 7. Error catalogue

| `code` | HTTP | When | Client action |
|---|---|---|---|
| `TOOL_NOT_IN_REGISTRY` | 422 (as `denied_reason`) | Model or runbook named an unknown tool | None — refused |
| `DENYLISTED` | 422 (as `denied_reason`) | Permanent deny-list hit (C-05) | None — refused, audited |
| `SCHEMA_INVALID` | 422 | Args fail the tool's JSON Schema (AI-03) | Rejected, not repaired |
| `POLICY_DENIED` | 422 (as `denied_reason`) | `allow: false` for tool/env | Owner policy |
| `PROPOSAL_NOT_PENDING` | 409 | Already decided/expired/executed | Refresh |
| `APPROVAL_EXPIRED` | 409 | > 10 min | Ask again for a fresh proposal |
| `APPROVAL_HASH_MISMATCH` | 409 | Stored args do not hash to `args_hash` | Security event — see SEC-04 |
| `ROLE_INSUFFICIENT` | 403 | Caller below `require_role` | Escalate to the named role |
| `CHANGE_FREEZE` | 409 | Active freeze for the env | Wait or end the freeze (admin+) |
| `RATE_LIMITED` | 429 | Action or API limit | `Retry-After` |
| `TARGET_NOT_ALLOWED` | 422 (as `denied_reason`) | Target not in `targets_allow` or tagged `ot`/`plc` | Owner |
| `LLM_UNAVAILABLE` | 200 (warning) | Ollama down; deterministic result returned | Nothing — the answer is still valid evidence |
| `ITERATION_CAP` / `TOOL_TIMEOUT` / `BUDGET_EXCEEDED` | 200 (warning) / 504 on `/diag` | AI-04 caps | Narrow the question |
| `GROUNDING_FAILED` | 200 (`outcome`) | Model claimed something no tool returned | The claim is withheld; evidence shown |
| `VERIFICATION_FAILED` | 200 (`status: failed`) | After-state did not meet the rule | Investigate; propose again |
| `DRY_RUN_UNSUPPORTED` | 409 | Tool has no dry-run hook | — |
| `POLICY_INVALID` | 422 | `PUT /policies` fails schema or C-03 rule | Fix the file |

## 8. SSE events (`GET /runs/{id}/events`)

| event | data |
|---|---|
| `plan` | `{ steps: [...] }` — the deterministic plan for the question class |
| `tool_call` | `{ id, ordinal, tool_name, args, status: started\|done, duration_ms, redaction_count }` |
| `evidence` | `{ bundle_size, ids: [tc-01…] }` |
| `diagnosis` | `{ probable_cause, confidence, evidence: [...], next_checks: [...] }` |
| `proposal` | `{ id, tool_name, args, risk, require_role, expires_at }` |
| `done` | `{ outcome, latency_ms, deterministic }` |
| `error` | `{ code, detail }` |

The stream is a *view* of the run; the database rows are the truth (P-4). Reconnecting replays from the last event id.

## 9. Traceability

| SRS-04 | Endpoint |
|---|---|
| §4.1 `/ask`, `/actions/{id}/approve`, `/actions/{id}/deny`, `/runs`, `/tools`, `/runbooks/{name}/run` | `/ask`, `/proposals/{id}/approve`, `/proposals/{id}/deny`, `/runs`, `/tools`, `/runbooks/{name}/run` (proposals are the SRS "actions") |
| FR-11, FR-12, FR-15 | `/ask`, `Run.evidence / confidence / next_checks` |
| FR-14, FR-18, FR-19 | `Proposal` (risk, require_role, args_hash, expires_at) |
| FR-16, FR-20 | §4 |
| FR-21 | `CHANGE_FREEZE`, `RATE_LIMITED`, `/freezes` |
| FR-22, FR-23 | `dry-run`, `abort` |
| FR-24, FR-25, FR-26, FR-27 | `/runbooks`, `/sweeps`, `/alerts`, `/incidents/{id}/summary` |
| FR-28, FR-29 | ICD-04 IF-08 maps commands to these endpoints |
| FR-30 | the read endpoints the console uses |
| FR-31, FR-32 | `/audit`, `/audit/export` |
| AI-03 | `SCHEMA_INVALID` |
| AI-04 | `ITERATION_CAP`, `TOOL_TIMEOUT` |
| AI-07 | `Run.model / prompt_version / registry_version`; `/readyz.registry_version` |
| NFR-06, AC-08 | `/diag`, `/readyz.llm` |
| AC-02…AC-04, AC-06 | §3 |
| AC-07 | `/runs/{id}/timeline`, `/audit/export` |
| C-01, C-02, C-05 | `TOOL_NOT_IN_REGISTRY`, `DENYLISTED`; no execution endpoint exists |
| C-03 | `POLICY_INVALID` on `auto_execute` for high |
