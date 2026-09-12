# API Specification — ShiftBrief (Production AI Analyst)

| Field | Value |
|---|---|
| Document ID | API-02-ShiftBrief |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable spec | [`openapi.yaml`](./openapi.yaml) — OpenAPI 3.1, validated (43 paths, 47 operations, 39 schemas, 165 `$ref`s) |
| Implements | [SRS-02 §4](../SRS-ShiftBrief-Production-AI-Analyst.md), [SAD-02 §4.3](../docs/SAD-ShiftBrief-Software-Architecture.md) |
| Inherits | Conventions from [API-00 §2–4](../../00-factorybrain-platform/api/API-Specification.md) |

---

## 1. Purpose
`openapi.yaml` is the contract. This document holds the behaviour the spec cannot express: the facts contract, the grounding contract, revision semantics, the text-to-SQL contract, the error catalogue, and how the standalone surface maps onto the platform.

---

## 2. Conventions (inherited)
As API-00 §2: `/api/v1`, `snake_case`, RFC 3339 with offset, plant-local inclusive dates, cursor pagination, unknown query parameters rejected, rates unrounded, `null` never `0` for an undefined rate.

ShiftBrief specifics:
- **Dates are production dates**, not timestamps. A "day" is the plant-local calendar date on which the shift *started* (a shift B ending at 22:00 belongs to that date).
- **Every rate is `ng / produced`** over the requested scope. Baselines are **pooled** (Σng / Σproduced over the window, excluding the day itself), which is what the significance test uses; the API never averages daily percentages.
- **`data_complete`** accompanies every aggregate. When a shift or line expected by the calendar is missing for a date, the flag is false and the client should say so before comparing anything.

---

## 3. Authentication and authorisation
User JWT only (15 min / 12 h rotating refresh; MFA for `admin`). There are no device or edge credentials in ShiftBrief.

| Capability | Minimum role |
|---|---|
| Read KPI, facts, briefs, ask | `viewer` |
| Upload a file, view quarantine and archives, manage subscriptions | `engineer` |
| Create a mapping version, set expectations, release a held batch | `engineer` |
| Deliver a brief now; approve `send_discord` | `manager` |
| Toggle `ask.enable_text_to_sql`, config, audit export | `admin` |
| `POST /ask/sql-preview` | `engineer` (and the flag must be on) |

Line scope is a query predicate: a restricted user's `GET /kpi` never retrieves out-of-scope rows, and the plant-wide facts object is **not visible** to a line-restricted user (it contains other lines' figures).

Two writes carry a mandatory `reason` and are audited with before/after: **mapping versions** and **the text-to-SQL flag**.

---

## 4. Idempotency
| Mechanism | Where |
|---|---|
| File SHA-256 | `POST /ingest/production` — identical file → `409` + existing batch, nothing re-processed |
| Natural key upsert | `core.production_fact` (date, shift, line, sku) — a corrected file updates rows, never duplicates |
| `Idempotency-Key` | `POST /brief`, `POST /export/*` — replay within 24 h returns the original response |
| Facts uniqueness | (date, line, facts_version) — regeneration under the same version reads, compares, and does not write |

---

## 5. The facts contract

| Promise | Detail |
|---|---|
| **Deterministic** | Same `core.production_fact`/`defect_fact` rows + same `FACTS_VERSION` → byte-identical `facts_json` → identical `facts_sha256` |
| **Stored, not recomputed per render** | The brief was written from a specific row; `GET /facts?date=` returns that row and its hash |
| **Immutable** | The database rejects `UPDATE`/`DELETE` on `analytics.facts`; a change is a new version |
| **Regeneration is a check, not an overwrite** | `POST /facts/regenerate` recomputes; a hash mismatch for an existing version → `409 FACTS_STALE` with both hashes. The caller decides — it is never papered over |
| **Completeness is explicit** | `data_complete: false` + `completeness.missing[]` when a shift or line the calendar expects is absent |

`FACTS_STALE` has exactly two causes and the detail names both: rows changed without a superseding batch (someone edited the warehouse directly), or analytics code changed without a `FACTS_VERSION` bump. Either is a defect to investigate (OPS RB-13), not a state to hide.

---

## 6. The brief grounding contract

Identical in spirit to [API-00 §5](../../00-factorybrain-platform/api/API-Specification.md), and stricter in one way: **the model's only input is the facts object**. There are no tool calls during brief generation, so "every number appears in a source" reduces to "every number appears in one JSON document" — the tightest grounding condition in the whole set.

| Outcome | Behaviour |
|---|---|
| Grounded | `200`, `withheld: false`, `grounding.all_matched: true` |
| Ungrounded | `422 GROUNDING_FAILED`; a brief row is stored with `withheld: true` and **`text: null`** (database constraint) — it can be listed in history but never displayed or delivered |
| Not significant | `significant: false`; the text **must** contain "within normal variation" (or its TH/JA equivalent) and **must not** contain a recommended action |
| Incomplete data | Text must name the missing shift/line before any comparison |

**Deterministic generation settings:** `temperature ≤ 0.2`, pinned model tag, `prompt_version` recorded. Regenerating a brief from the same facts row produces a new brief row; the *prose* may differ in wording, the *numbers* cannot.

---

## 7. Revision semantics

```
original file  → batch B1 → facts (v "1.0")      → brief X   (delivered 07:00)
corrected file → batch B3 (supersedes B1 for its dates)
               → facts (v "1.0-r2", supersedes)  → brief Y   (revised_of = X, delivered 11:35 with the delta)
```

- Brief X is never modified. `GET /brief/{X}` returns `revisions: [Y]`.
- `GET /brief/history` returns Y by default (`latest_only=true`); pass `latest_only=false` to see both.
- The revised brief's text begins with **"REVISED"** and states what changed (`ng 311 → 313`).
- A `brief_revised` alert is raised so anyone who acted on X is told.

---

## 8. The text-to-SQL contract

Off by default (`ask.enable_text_to_sql = false`). When on:

| Rule | Enforcement |
|---|---|
| SELECT only | Parsed with sqlglot; any other statement type → `SQL_REJECTED` |
| Whitelisted objects only | The grant list of DB role `agent_ro` **is** the whitelist: `core.line/sku/defect_type/shift_calendar/plant`, `core.v_kpi_daily`, `core.v_defect_pareto`, `core.v_oee_daily`, `analytics.v_line_shift_daily`, `analytics.v_trend_daily`, `analytics.v_latest_facts`, `analytics.v_latest_brief`. Any other table, `pg_catalog`, `information_schema` → `SQL_REJECTED` at parse time *and* permission denied at execution |
| Bounded | `LIMIT 200` injected if absent (or lowered if larger); `SET statement_timeout = '5s'` per session |
| No side effects, no functions with side effects | Function allow-list (aggregates, date/math/string); `pg_sleep`, `lo_*`, `dblink`, `copy` etc. rejected |
| Line scope | The user's scope predicate is appended as an outer `WHERE line_code IN (…)` on any view carrying `line_code` |
| **Transparent** | The executed SQL is returned in `AskResponse.sql` and stored on the tool call. `POST /ask/sql-preview` shows it without running it |
| Gated | Enabled only after the ≥ 30-question execution-accuracy gate (≥ 85 %) passes ([TEST-02 TS-4](../docs/TEST-ShiftBrief-Test-Plan.md)); the toggle is `admin`-only and audited |

Numbers in a text-to-SQL answer are grounded against the query result rows, exactly as tool results.

---

## 9. Error catalogue

Platform codes (API-00 §7) apply. ShiftBrief adds:

| HTTP | `code` | Meaning | Caller action |
|---|---|---|---|
| 409 | `BATCH_DUPLICATE` | Identical file already ingested; existing batch returned | Treat as success |
| 409 | `BATCH_HELD` | Batch held for mapping drift; not committed | Update the mapping, then `/release` |
| 409 | `FACTS_STALE` | Recomputed facts hash ≠ stored hash for the same version | Investigate (RB-13); do not force |
| 409 | `BRIEF_WITHHELD` | Attempt to deliver a withheld brief | Regenerate after investigating (RB-06) |
| 409 | `TEXT_TO_SQL_DISABLED` | `/ask/sql-preview` with the flag off | Use typed tools; ask an admin |
| 422 | `BATCH_REJECTED` | > 5 % invalid rows; **nothing committed** | Fix the file; `reject_reason` and quarantine rows name the problems |
| 422 | `MAPPING_INVALID` | Mapping YAML fails the schema | Fix the YAML; `errors[]` names fields |
| 422 | `MAPPING_DRIFT` | File header ≠ active mapping fingerprint | New mapping version, then `/release` |
| 422 | `SQL_REJECTED` | Generated SQL failed the parser/whitelist | Rephrase; the reason is in `detail` |
| 422 | `GROUNDING_FAILED` | Brief/answer withheld | Report — model-quality incident |
| 404 | `FACTS_NOT_FOUND` | No facts for the date | Usually the file has not arrived; check `/sources` |
| 404 | `FILE_NOT_ARRIVED` | Brief requested for a date whose file is late | Wait or chase the source |
| 413 | `FILE_TOO_LARGE` | Over `INGEST_MAX_FILE_MB` | Split the file |
| 503 | `MODEL_UNAVAILABLE` | LLM down; intake/facts/KPI unaffected | Retry later |

---

## 10. Rate limits

| Endpoint class | viewer | engineer/manager | admin |
|---|---|---|---|
| Reads (kpi, facts, briefs) | 120/min | 300/min | 600/min |
| `POST /ask` (GPU profile) | 10/min | 30/min | 30/min |
| `POST /ask` (**CPU profile**) | 3/min | 6/min | 6/min |
| `POST /brief` | 2/min | 6/min | 6/min |
| `POST /ingest/production` | — | 10/min | 20/min |
| Exports | 2/min | 10/min | 20/min |

The CPU profile's lower limits are deliberate (ADR-S06): a 4 B model on 4 vCPU answers in tens of seconds, and queueing more than that misleads users.

---

## 11. Platform mode — mapping onto FactoryBrain

| Standalone path | Platform mode |
|---|---|
| `/auth/*`, `/admin/config`, `/admin/audit`, `/healthz`, `/readyz` | **Collapse** into the platform's |
| `/ingest/production`, `/ingest/batches*` | **Become the platform's implementation** of `POST /ingest/production` / `GET /ingest/batches/{id}` (same request/response) |
| `/kpi`, `/kpi/pareto` | **Become the platform's** `/kpi`, `/kpi/pareto`; `/kpi/trend`, `/heatmap`, `/oee`, `/significance` mount alongside |
| `/facts*`, `/brief*`, `/subscriptions`, `/sources*`, `/export/*` | **Mount unchanged**; the platform's `POST /agent/brief` delegates to `/brief` |
| `/ask*` | **Collapses** into the platform Copilot; the eight ShiftBrief tools register into the registry; `run_sql` obeys the platform flag |
| Significance | `significant: true` on a daily facts row also opens `quality.signal` for QE-Agent |

---

## 12. Endpoint index

| Domain | Endpoint | Method | Min role | SRS-02 |
|---|---|---|---|---|
| auth | `/auth/login`, `/auth/refresh` | POST | — | — |
| auth | `/auth/me` | GET | viewer | — |
| ingest | `/ingest/production` | POST | engineer | FR-01…06 |
| ingest | `/ingest/batches`, `/ingest/batches/{id}` | GET | engineer | FR-04, FR-06 |
| ingest | `/ingest/batches/{id}/quarantine`, `/archive` | GET | engineer | FR-04, FR-06 |
| ingest | `/ingest/batches/{id}/release` | POST | engineer | FR-02 |
| sources | `/sources` | GET, POST | viewer / engineer | FR-01 |
| sources | `/sources/{code}/mappings` | GET, POST | viewer / engineer | FR-02 |
| sources | `/sources/{code}/mappings/validate` | POST | engineer | FR-02, FR-03 |
| sources | `/sources/{code}/expectation` | PUT | engineer | FR-08 |
| facts | `/facts`, `/facts/history` | GET | viewer | FR-16 |
| facts | `/facts/regenerate` | POST | engineer | FR-07, FR-31 |
| brief | `/brief` | POST | viewer (deliver: manager) | FR-17…22, FR-31 |
| brief | `/brief/{id}`, `/brief/history` | GET | viewer | FR-17 |
| brief | `/brief/{id}/deliver` | POST | manager | FR-27 |
| brief | `/subscriptions` | GET, POST | viewer / engineer | FR-21, FR-27 |
| kpi | `/kpi`, `/kpi/pareto`, `/kpi/trend`, `/kpi/heatmap`, `/kpi/oee`, `/kpi/significance` | GET | viewer | FR-09…15, FR-29 |
| ask | `/ask` | POST | viewer | FR-23, FR-24, FR-26 |
| ask | `/ask/sql-preview` | POST | engineer | FR-25 |
| ask | `/ask/runs/{id}`, `/ask/tools` | GET | viewer | FR-23 |
| ask | `/ask/feedback` | POST | viewer | — |
| ask | `/ask/proposals*` | GET, POST | manager | — |
| export | `/export/{format}`, `/jobs/{id}` | POST, GET | viewer | FR-30 |
| admin | `/admin/config` | GET, PATCH | admin | — |
| admin | `/admin/alerts`, `/admin/alerts/{id}/ack` | GET, POST | engineer | FR-28 |
| admin | `/admin/audit` | GET | admin | NFR-06 |
| admin | `/healthz`, `/readyz` | GET | — | — |

---

## 13. Deliberately unusual choices

| Choice | Why |
|---|---|
| Facts are a stored row with a hash, not a computed response | A brief's provenance must be one immutable row you can point at a year later; recomputing on read would let the brief and its evidence drift apart |
| `FACTS_STALE` is an error, not a silent refresh | The two causes are both defects. Auto-refreshing would erase the evidence that one occurred |
| A rejected batch commits **nothing** | A day that is 92 % loaded looks complete on a dashboard. All-or-nothing keeps "the file is in" a true statement |
| `refused` is HTTP 200 | The analyst correctly saying "I only have production counts" is a successful answer |
| Text-to-SQL returns its SQL | An answer whose query you can read and run yourself is verifiable; one that hides it is a claim |
| CPU profile has lower rate limits | Honest queueing beats a spinner that lies about wait time |
| Baselines are pooled, not averaged percentages | Averaging daily rates weights a 200-part Sunday the same as a 12,000-part Tuesday; the z-test needs pooled counts anyway |

---

## 14. Traceability

| SRS-02 | Endpoint / mechanism |
|---|---|
| FR-01 sources | `/sources` (`kind`) |
| FR-02 mapping | `/sources/{code}/mappings`, `MAPPING_DRIFT`, `/release` |
| FR-03 validation | `QuarantineRow.reason`, `/mappings/validate` |
| FR-04 quarantine, > 5 % reject | `BATCH_REJECTED`, `IngestBatch.reject_reason` |
| FR-05 idempotent | §4 |
| FR-06 archive + hash | `/ingest/batches/{id}/archive` |
| FR-07 corrected → revised | §7, `Brief.revised_of`, `IngestBatch.supersedes_batch_id` |
| FR-08 late file alert | `FileExpectation`, `FILE_NOT_ARRIVED`, `Source.arrival_status` |
| FR-09…15 analytics | `/kpi*`, `GroupStat.rankable`, `Significance`, `TrendPatterns`, `OeeRow` |
| FR-16 facts object | `/facts`, `Facts` schema |
| FR-17…20 brief content, facts-only, correlation, normal variation | §6 |
| FR-21, FR-22 language, tone | `lang`, `tone`, `Subscription` |
| FR-23…26 Q&A | `/ask`, §8, `refused` |
| FR-27, FR-28 delivery, alerts | `/brief/{id}/deliver`, `/subscriptions`, `/admin/alerts` |
| FR-29, FR-30 dashboard, export | `/kpi/*`, `/export/{format}` |
| FR-31 regenerate past date | `POST /brief` with `regenerate`, `/facts/regenerate` |
| AI-02 prompt versioning | `Brief.prompt_version` |
| AI-03 deterministic | §6 settings |
| AI-04 golden set / zero fabrication | §6 |
| AI-05 constrained SQL | §8 |
| NFR-07 PII | never in `Facts`; mapping `pii` |
| NFR-08 reproducible | §5 |
| C-01 | §6 — facts-only input |
| C-03 | §5 |
