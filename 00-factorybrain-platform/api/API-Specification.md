# API Specification — FactoryBrain AI Platform

| Field | Value |
|---|---|
| Document ID | API-00-FactoryBrain |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable spec | [`openapi.yaml`](./openapi.yaml) — OpenAPI 3.1, validated |
| Implements | [SRS §5.1](../SRS-FactoryBrain-AI-Platform.md), [SAD §4.3](../docs/SAD-FactoryBrain-Software-Architecture.md) |

---

## 1. Purpose and relationship to `openapi.yaml`

`openapi.yaml` is the **contract**: paths, schemas, status codes. It is validated in CI and is what clients generate from.

This document holds what an OpenAPI file cannot express well — cross-cutting conventions, the error catalogue, the semantics of idempotency and approval, rate limits, and the reasoning behind several deliberately unusual choices. When the two disagree, `openapi.yaml` wins for structure; this document wins for behaviour.

**Verification status:** `openapi.yaml` passes `openapi-spec-validator` against the OpenAPI 3.1 schema; all `$ref`s resolve; 62 operations across 58 paths, all with unique `operationId`s and at least one documented response.

---

## 2. Conventions

### 2.1 Base URL and versioning
```
https://factorybrain.local/api/v1
```

The major version is in the path. It changes only for **breaking** changes: removing a field, narrowing a type, changing a status code's meaning, or making an optional parameter required. Adding a field, adding an endpoint, or adding an enum value is **not** breaking, and clients must tolerate unknown fields.

Deprecation: an endpoint is marked `deprecated: true` in the spec and returns a `Deprecation` header with a sunset date, for a minimum of **two release cycles** before removal.

### 2.2 Content types
| Situation | Type |
|---|---|
| Requests and responses | `application/json` |
| Errors | `application/problem+json` (RFC 7807) |
| File upload | `multipart/form-data` |
| Streaming chat | `text/event-stream` (SSE) |

### 2.3 Dates, times and numbers
- Timestamps are RFC 3339 with an explicit offset: `2026-09-09T14:12:00+07:00`. Stored UTC, rendered in the plant timezone.
- Dates (`from`, `to`, `date`) are plant-local calendar dates and are **inclusive** at both ends.
- Percentages are returned as numbers, not strings, and are **not** pre-rounded for display — the client formats. `5.8255` means 5.8255 %.
- A rate is `null`, never `0`, when the denominator is zero. `0` would be a false claim of perfect quality.

### 2.4 Pagination
Cursor-based, not offset-based: inspection tables are partitioned and constantly appended to, and offset pagination silently skips or repeats rows under concurrent inserts.

```http
GET /inspections?limit=50
→ { "items": [...], "next_cursor": "eyJ0cyI6IjIw..." }

GET /inspections?limit=50&cursor=eyJ0cyI6IjIw...
→ { "items": [...], "next_cursor": null }
```

`total_estimate` is approximate and may be `null`. Exact counts across a partitioned table with millions of rows are expensive; where an exact count matters, use the KPI endpoints, which read pre-aggregated views.

### 2.5 Filtering
Filters are `AND`-combined query parameters. Unknown parameters are **rejected** with `400 INVALID_PARAMETER` rather than ignored — a silently-ignored filter returns a plausible-looking but wrong dataset, which is worse than an error.

### 2.6 Field naming
`snake_case` throughout, matching the database. No camelCase translation layer: two naming schemes for the same field is a permanent source of bugs at the boundary.

---

## 3. Authentication

### 3.1 Users — JWT bearer
```http
POST /auth/login       { username, password, mfa_code? }  → access + refresh
POST /auth/refresh     { refresh_token }                  → new access token
GET  /auth/me                                             → identity, role, line scope
```

| Property | Value |
|---|---|
| Access token lifetime | 15 minutes |
| Refresh token lifetime | 12 hours (one shift) |
| Refresh rotation | Yes — each refresh invalidates the previous token |
| MFA | Required for `admin`, optional otherwise |
| Algorithm | RS256 |

Refresh lifetime is one shift by design: an operator's token should not survive into the next crew's shift on a shared shop-floor tablet.

### 3.2 Edge nodes — `X-Edge-Key` or mTLS
Edge sync endpoints (`/edge/*`) authenticate with a per-node credential, never a user token.

```http
POST /edge/records:batch
X-Edge-Key: <per-node key>
```

mTLS client certificates are preferred where the network supports them. The API key exists for devices that cannot manage certificates.

An edge credential is deliberately the narrowest in the system: it can insert inspection data **for its own node** and read its own configuration. It cannot read other lines, query production data, or reach the agent. A physically compromised edge device is contained by this boundary — see [SEC §5](../docs/SEC-FactoryBrain-Security-Requirements.md).

### 3.3 Authorisation model
Five roles, ordered: `viewer` < `inspector` < `engineer` < `manager` < `admin`.

| Capability | Minimum role |
|---|---|
| Read dashboards, ask questions | `viewer` |
| Override a verdict, view evidence | `inspector` |
| SPC/capability, open cases, approve artifacts | `engineer` |
| Approve `medium`-risk agent actions, approve postings | `manager` |
| Configuration, model promotion, audit export, user admin | `admin` |

**Line scope is enforced by predicate, not by filtering.** A user restricted to Line 1 who requests Line 3 data does not receive a filtered empty list — the query never retrieves those rows. The distinction matters: response filtering leaks information through counts, timings and aggregate totals.

---

## 4. Idempotency

Three mechanisms, used in different places.

### 4.1 Client-generated resource IDs (edge and mobile)
Records created offline carry a client-generated **UUIDv7**. The server deduplicates on it.

```json
{ "id": "0192f0a1-0000-7000-8000-000000000001", "ts": "...", "verdict": "FAIL" }
```

Re-posting an existing `id` returns `200` with the existing record, not `409`. This is what lets an edge node retry an entire batch after a network failure without reconciliation logic.

### 4.2 `Idempotency-Key` header (mutating operations)
```http
POST /docflow/documents/{id}/post
Idempotency-Key: 7f3a9c21-...
```
The first request executes; replays within 24 hours return the original response. Applies to ERP posting, report generation and inspection creation.

### 4.3 Database-enforced uniqueness (ERP posting)
`docflow.posting` carries `UNIQUE (adapter, idem_key)`. Even if the application layer is bypassed or buggy, **the database refuses a second posting for the same document**. A duplicated purchase order is a real financial event; one layer of protection is not enough.

### 4.4 Batch semantics — `207 Multi-Status`
Batch endpoints never fail wholesale for one bad record:

```json
{
  "accepted": 198, "duplicate": 1, "rejected": 1,
  "items": [
    { "id": "...001", "status": "accepted" },
    { "id": "...002", "status": "duplicate" },
    { "id": "...003", "status": "rejected",
      "code": "VALIDATION_FAILED", "detail": "unknown sku code RAD-999-Z" }
  ]
}
```

`duplicate` is an **outcome, not an error** — it is the expected result of a healthy retry.

---

## 5. The grounding contract

This is the most important behavioural guarantee in the API and has no natural expression in OpenAPI.

### 5.1 What the caller is promised
Every number appearing in `answer` also appears in a tool result listed in `sources`. This is verified by a deterministic post-check after generation, not by asking the model to behave.

### 5.2 What happens when it fails
The answer is **withheld**. The caller receives `422` with `code: GROUNDING_FAILED`:

```json
{
  "type": "https://factorybrain.local/problems/grounding-failed",
  "title": "Answer withheld by grounding check",
  "status": 422,
  "code": "GROUNDING_FAILED",
  "detail": "The generated answer contained the value \"4.7\" which does not appear in any tool result for this turn. The answer was not returned.",
  "correlation_id": "..."
}
```

There is deliberately no option to receive an ungrounded answer with a warning attached. A warning next to a plausible number is not a safeguard — people read the number.

### 5.3 Three distinct non-success outcomes
| `outcome` | Meaning | HTTP |
|---|---|---|
| `refused` | Data was insufficient; the agent said so instead of speculating | `200` |
| `partial` | A budget (tool calls, wall time) was hit; `partial_reason` explains what is missing | `200` |
| `grounding_failed` | Post-check found an unmatched number; answer withheld | `422` |

`refused` is a **successful** response. An agent correctly saying "shift C data has not been uploaded, so I cannot compare shifts" has done its job.

### 5.4 Verification affordances
`GET /agent/runs/{runId}` returns the full trace: every tool call with arguments and row counts, the facts object handed to the model, and the grounding result. This backs the UI's "show the numbers" and "show the SQL" controls. Any user who can see an answer can see how it was produced.

---

## 6. Approval semantics

### 6.1 Write-capable agent actions
Write tools never execute directly. They create a proposal:

```json
{
  "id": "...", "tool_name": "send_discord",
  "args": { "channel": "#quality", "message": "..." },
  "args_hash": "sha256:9f2c...", "risk": "low",
  "status": "pending", "expires_at": "2026-09-10T07:15:00+07:00"
}
```

Approval must **echo `args_hash`**:
```http
POST /agent/proposals/{id}/approve
{ "args_hash": "sha256:9f2c..." }
```

Two failure modes this prevents:
- **Argument substitution** — approving one action and executing another. Mismatched hash → `409`.
- **Stale approval** — a proposal approved in a world that has since changed. Expired (default 10 min) → `409`.

### 6.2 AI-drafted quality artifacts
`POST /cases/{id}/artifacts/{kind}` always creates a **draft**: `ai_generated: true`, `approved: false`, and a populated `watermark` field.

An unapproved artifact:
- exports only with the `DRAFT — AI generated` watermark (there is **no parameter to suppress it**),
- is excluded from knowledge retrieval, so it cannot become precedent for a future analysis,
- cannot be cited by another agent.

Approval requires `engineer` or above, is immutable once recorded, and stamps approver and timestamp.

### 6.3 ERP posting — segregation of duties
Above a configurable amount, the approver may not be the user who edited the extracted fields. Violation returns `403` with `code: SEGREGATION_OF_DUTIES`.

---

## 7. Error catalogue

All errors are RFC 7807 with a stable `code`. Clients switch on `code`, never on `detail` (which is human-readable and may change).

| HTTP | `code` | Meaning | Caller action |
|---|---|---|---|
| 400 | `INVALID_PARAMETER` | Unknown or malformed query parameter | Fix the request; do not retry unchanged |
| 400 | `INVALID_DATE_RANGE` | `from` after `to`, or range exceeds the limit | Narrow the range |
| 401 | `TOKEN_EXPIRED` | Access token expired | Refresh, then retry once |
| 401 | `TOKEN_INVALID` | Malformed, wrong signature, or revoked | Re-authenticate |
| 401 | `EDGE_KEY_INVALID` | Unknown or rotated node key | Re-provision the node (OPS RB-04) |
| 403 | `INSUFFICIENT_ROLE` | Role below the required level | Do not retry |
| 403 | `OUT_OF_SCOPE` | Resource outside the user's line scope | Do not retry |
| 403 | `SEGREGATION_OF_DUTIES` | Approver also edited the document | Route to a different approver |
| 404 | `NOT_FOUND` | Resource does not exist or is not visible | Do not retry |
| 409 | `ALREADY_EXISTS` | Duplicate natural key | Treat as success if replaying |
| 409 | `VERDICT_UNCHANGED` | Override target equals current verdict | No action needed |
| 409 | `ALREADY_APPROVED` | Artifact or proposal already decided | Refresh state |
| 409 | `PROPOSAL_EXPIRED` | Approval window elapsed | Re-run the action to get a fresh proposal |
| 409 | `ARGS_HASH_MISMATCH` | Arguments changed since proposal | Re-propose; **never** force |
| 409 | `NOT_APPROVED` | Posting attempted before approval | Obtain approval first |
| 413 | `PAYLOAD_TOO_LARGE` | Batch or file exceeds the limit | Split the batch |
| 422 | `VALIDATION_FAILED` | Well-formed but semantically invalid | Inspect `errors[]` |
| 422 | `BATCH_REJECTED` | >5 % of rows invalid; nothing committed | Fix the source file, re-upload |
| 422 | `GROUNDING_FAILED` | Answer withheld by the grounding check | Report it — this is a model-quality incident |
| 429 | `RATE_LIMITED` | Quota exceeded | Honour `Retry-After` |
| 500 | `INTERNAL_ERROR` | Unhandled fault | Retry with backoff; report `correlation_id` |
| 502 | `ERP_UNAVAILABLE` | ERP rejected or unreachable | Safe to retry — posting is idempotent |
| 503 | `MODEL_UNAVAILABLE` | LLM down or GPU semaphore timeout | Retry later; deterministic endpoints still work |
| 503 | `NOT_READY` | Service starting or a dependency is down | Retry with backoff |

Every error response carries `correlation_id`, which ties the request to its audit and log entries.

### 7.1 Retry guidance
| Class | Retry? |
|---|---|
| 4xx except 429 | **No** — the request will fail identically |
| 429 | Yes, after `Retry-After` |
| 500, 502, 503 | Yes, exponential backoff with jitter, max 5 attempts |

All mutating endpoints are idempotent (§4), so retrying a 5xx is safe by design rather than by hope.

---

## 8. Rate limits

Per user, sliding window. Limits protect the shared GPU more than the CPU.

| Endpoint class | `viewer`/`inspector` | `engineer`/`manager` | `admin` | Edge node |
|---|---|---|---|---|
| Read (KPI, lists, charts) | 120/min | 300/min | 600/min | — |
| `POST /agent/ask` | 10/min | 30/min | 30/min | — |
| Artifact drafting | 3/min | 10/min | 10/min | — |
| Report generation | 2/min | 10/min | 20/min | — |
| `/edge/records:batch` | — | — | — | 60/min/node |
| `/edge/heartbeat` | — | — | — | 2/min/node |
| Upload (`/ingest`, `/docflow`) | 5/min | 20/min | 60/min | — |

Agent limits are low because each request may hold the GPU semaphore. Exceeding a limit returns `429` with `Retry-After`; the queue position is exposed via the `X-Queue-Depth` header so a client can show honest waiting feedback rather than an indefinite spinner.

---

## 9. Streaming

`POST /agent/ask?stream=true` returns Server-Sent Events:

```
event: status
data: {"stage":"planning"}

event: tool
data: {"tool":"query_defects","args":{"date_from":"2026-09-09"}}

event: token
data: {"text":"Line 3 defect rate was "}

event: done
data: {"run_id":"...","outcome":"ok","sources":[...],"grounding":{"all_matched":true}}
```

**The grounding check runs before `done`.** If it fails, the stream ends with an `error` event and the client must discard the accumulated text:

```
event: error
data: {"code":"GROUNDING_FAILED","run_id":"..."}
```

This is an explicit client obligation: streamed tokens are provisional until `done` arrives. A client that renders streamed text as final defeats the guarantee in §5.

---

## 10. Endpoint index

| Domain | Endpoint | Method | Min role | Owning SRS |
|---|---|---|---|---|
| auth | `/auth/login` | POST | — | 00 |
| auth | `/auth/refresh` | POST | — | 00 |
| auth | `/auth/me` | GET | viewer | 00 |
| ingest | `/ingest/production` | POST | engineer | 02 |
| ingest | `/ingest/batches/{id}` | GET | engineer | 02 |
| quality | `/kpi` | GET | viewer | 02 |
| quality | `/kpi/pareto` | GET | viewer | 02 |
| inspections | `/inspections` | GET, POST | viewer / inspector | 01 |
| inspections | `/inspections/{id}` | GET | viewer | 01 |
| inspections | `/inspections/{id}/verdict` | PATCH | inspector | 01 |
| inspections | `/reviews` | GET | inspector | 01 |
| edge | `/edge/records:batch` | POST | edge key | 03 |
| edge | `/edge/images` | POST | edge key | 03 |
| edge | `/edge/config` | GET | edge key | 03 |
| edge | `/edge/heartbeat` | POST | edge key | 03 |
| edge | `/edge/nodes` | GET | engineer | 03 |
| mobile | `/mobile/bootstrap` | GET | inspector | 05 |
| mobile | `/mobile/sessions:batch` | POST | inspector | 05 |
| quality | `/spc/chart` | GET | engineer | 09 |
| quality | `/spc/capability` | GET | engineer | 09 |
| quality | `/signals` | GET | engineer | 09 |
| quality | `/cases` | GET, POST | engineer | 09 |
| quality | `/cases/{id}` | GET | engineer | 09 |
| quality | `/cases/{id}/analyze` | POST | engineer | 09, 11 |
| quality | `/cases/{id}/artifacts/{kind}` | POST | engineer | 09 |
| quality | `/artifacts/{id}/approve` | POST | engineer | 09 |
| telemetry | `/telemetry/samples` | POST | edge key | 06 |
| telemetry | `/telemetry/series` | GET | engineer | 06 |
| telemetry | `/machines/{id}/health` | GET | viewer | 06 |
| telemetry | `/alerts` | GET | viewer | 06 |
| telemetry | `/alerts/{id}/feedback` | POST | inspector | 06 |
| agent | `/agent/ask` | POST | viewer | 10 |
| agent | `/agent/brief` | POST | viewer | 02 |
| agent | `/agent/proposals` | GET | manager | 00 |
| agent | `/agent/proposals/{id}/approve` | POST | manager | 00 |
| agent | `/agent/proposals/{id}/deny` | POST | manager | 00 |
| agent | `/agent/findings` | GET | viewer | 13 |
| agent | `/agent/briefing` | GET | viewer | 13 |
| agent | `/agent/runs/{id}` | GET | viewer | 10 |
| agent | `/agent/feedback` | POST | viewer | 10 |
| agent | `/agent/tools` | GET | viewer | 10 |
| knowledge | `/knowledge/search` | POST | viewer | 15 |
| knowledge | `/knowledge/documents` | POST | engineer | 15 |
| knowledge | `/knowledge/translate` | POST | viewer | 14 |
| docflow | `/docflow/documents` | GET, POST | engineer | 08 |
| docflow | `/docflow/documents/{id}` | GET | engineer | 08 |
| docflow | `/docflow/documents/{id}/approve` | POST | manager | 08 |
| docflow | `/docflow/documents/{id}/post` | POST | manager | 08 |
| reports | `/reports/{type}` | POST | viewer | 00 |
| reports | `/jobs/{id}` | GET | viewer | 00 |
| admin | `/admin/models` | GET | engineer | 00 |
| admin | `/admin/models/{id}` | GET | engineer | 00 |
| admin | `/admin/models/{id}/shadow` | POST | admin | 00 |
| admin | `/admin/models/{id}/promote` | POST | admin | 00 |
| admin | `/admin/config` | GET, PATCH | admin | 00 |
| admin | `/admin/audit` | GET | admin | 00 |
| admin | `/healthz`, `/readyz` | GET | — | 00 |

---

## 11. Deliberately unusual choices

Six decisions that will look wrong at a glance and are not.

| Choice | Why |
|---|---|
| `defect_rate_pct` can be `null` | Zero production means an undefined rate. Returning `0` would render as "0 % defects — perfect day" on a dashboard for a line that did not run. |
| `NO_READ` is a verdict, not an error | The frame failed the quality gate; nothing was judged. Folding it into `PASS` inflates the pass rate; folding it into `FAIL` inflates scrap. It needs its own value. |
| `duplicate` is a success outcome in batches | At-least-once delivery makes duplicates the *normal* result of a healthy retry. Treating them as errors would make edge nodes log alarms during correct operation. |
| Unknown query parameters are rejected | A typo in `?line=` silently returning all lines is worse than a 400. Wrong data that looks right is the failure mode with real cost. |
| `refused` returns 200 | The agent correctly declining to speculate is a success. Returning 4xx would push clients to treat honesty as a fault to retry around. |
| `total_estimate` may be `null` | Exact counts on partitioned multi-million-row tables cost seconds. An approximate count with an honest name beats a precise-looking number that times out the request. |

---

## 12. Traceability

| SRS requirement | Endpoint / mechanism |
|---|---|
| FR-P-01 file ingest | `POST /ingest/production` |
| FR-P-02 validation & quarantine | `GET /ingest/batches/{id}` → `quarantined[]`; `BATCH_REJECTED` |
| FR-P-03 edge push over HTTPS + key | `POST /edge/records:batch`, `edgeApiKey` |
| FR-P-05 idempotent re-ingest | §4.1, §4.2; `409` returns the existing batch |
| FR-V-01 inspection record | `InspectionDetail` schema |
| FR-V-02 review threshold | `EdgeConfig.recipes[].review_threshold`; `verdict: REVIEW` |
| FR-V-03 override recorded | `PATCH /inspections/{id}/verdict`, `override_history` |
| FR-Q-01 KPI & Pareto | `GET /kpi`, `GET /kpi/pareto` |
| FR-Q-02 control charts | `GET /spc/chart` |
| FR-Q-03 capability | `GET /spc/capability` incl. normality gate |
| FR-Q-04 Nelson rules | `SpcChart.violations[].rule` |
| FR-Q-05 significance vs baseline | `KpiResponse.significant`, `p_value` |
| FR-A-01 tool-based answers | `POST /agent/ask`, `sources[]` |
| FR-A-02 traceability | §5, `grounding`, `GET /agent/runs/{id}` |
| FR-A-03 daily brief | `POST /agent/brief` |
| FR-A-04 HITL drafts | §6.2, `Artifact.watermark` |
| FR-A-05 language selection | `lang` parameter throughout |
| FR-A-06 refuse on insufficient data | `outcome: refused` |
| FR-A-07 write-tool gating | §6.1, `/agent/proposals/*` |
| FR-U-01 dashboard data | `/kpi`, `/kpi/pareto`, `/inspections` |
| FR-U-02 review queue | `GET /reviews` |
| FR-U-05 report export | `POST /reports/{type}`, `GET /jobs/{id}` |
| FR-S-01 roles | §3.3 |
| FR-S-02 AI call logging | `GET /agent/runs/{id}`, `GET /admin/audit` |
| FR-S-03 model version | `Inspection.model_version`, `/admin/models` |
| NFR-03 agent latency | §8 rate limits, `X-Queue-Depth` |
| NFR-04 edge survives outage | §4.1, `207` batch semantics |
| NFR-06 security | §3, [SEC](../docs/SEC-FactoryBrain-Security-Requirements.md) |
| NFR-11 observability | `/healthz`, `/readyz`, `correlation_id` |

---

## Appendix A — Client checklist

A conforming client must:

1. Tolerate unknown response fields (forward compatibility).
2. Switch on `code`, never on `detail` text.
3. Send `Idempotency-Key` on all mutating requests.
4. Generate UUIDv7 identifiers for offline-created records.
5. Treat `duplicate` in batch results as success.
6. Never retry 4xx except 429.
7. Honour `Retry-After`.
8. Treat streamed tokens as **provisional** until the `done` event (§9).
9. Render `sources` alongside any AI answer — never the answer alone.
10. Display the `watermark` on unapproved artifacts and never strip it.

Items 8, 9 and 10 are the ones that carry the platform's integrity guarantees into the user interface. A client that skips them is technically functional and substantively broken.
