# API Specification — Factory Copilot (Local AI Factory Copilot)

| Field | Value |
|---|---|
| Document ID | API-10-Copilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-17 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **59 paths / 70 operations / 57 schemas**; the platform's six agent/knowledge paths, 8 schemas, 5 parameters and 7 responses byte-identical to API-00 (TEST-10 TC-008) |
| Related | [SRS-10](../SRS-FactoryCopilot-Local-Multilingual-Assistant.md) §4.1 · [SAD-10](../docs/SAD-Copilot-Software-Architecture.md) · [DDS-10](../docs/DDS-Copilot-Database-Design.md) · [ICD-10](../docs/ICD-Copilot-Interface-Control.md) IF-53, IF-54, IF-56 · [SEC-10](../docs/SEC-Copilot-Security-Requirements.md) · platform: [API-00](../../00-factorybrain-platform/api/API-Specification.md) |

---

## 1. SRS §4.1 mapping and platform mode
| SRS | Path here | Platform (API-00, verbatim) | Note |
|---|---|---|---|
| `POST /api/v1/chat` (streaming) | `/chat` | `/agent/ask?stream=true` | same engine; `/chat` returns the IF-53 event stream (`Accept: text/event-stream`) or a `ChatResponse`; `/agent/ask` returns the platform's `AskResponse` |
| `GET /api/v1/chat/{conversation_id}` | `/chat/{conversation_id}` | — | history with turn summaries |
| `POST /api/v1/feedback` | `/feedback` (by `message_id`) | `/agent/feedback` (by `run_id`) | both recorded in `agent.feedback` |
| `GET /api/v1/sources/{id}` | `/sources/{id}` | `/agent/runs/{runId}` (whole trace) | opens one cited source: tool call + arguments, chunk with section/page, or image |
| `POST /api/v1/index/documents` | `/index/documents` | `/knowledge/documents` | standalone twin; platform mode delegates to Genba Memory |
| `GET /api/v1/tools` | `/tools` | `/agent/tools` | filtered by role; read tools only |

Added beyond the SRS: turn traces ("show the numbers", "show the SQL"), clarification, share/export/pin, saved questions and preferences, conversation export/delete, image search, document sources and index jobs, flags and curated Q&A, evaluation runs, aliases, glossary and term check, masking rules, channel bindings, tool policy, feature flags, config, queue, health.

## 2. Conventions
- Base `/api/v1`; JSON; UTC timestamps (answers print the plant's local time); ids UUIDv7; `Problem` verbatim from API-00 with a stable `code` (§8).
- Auth: bearer JWT with the platform roles viewer < inspector < engineer < manager < admin; Discord identities act only through a verified `ChannelBinding`; `/shares/{token}`, `/healthz`, `/readyz`, `/metrics` are unauthenticated (LAN).
- Lists are paginated with the platform's `Cursor`/`Limit`; `/turns` uses `DateFrom`/`DateTo`/`LineFilter`.
- Every answer carries `lang` (= question language unless the user asked otherwise), `sources[]`, `grounding`, `masked`, and a `confidence_note`/`partial_reason` when anything is missing.

## 3. The grounding contract (C-02, AI-04, AC-06)
- The composer receives only the **evidence bundle** (ICD-10 IF-56, `deploy/schemas/evidence-bundle.schema.json`): facts `F-nn` from tool calls, `D-nn` documents with section/page, `H-nn` QE hypotheses, `S-nn` sandbox statements, `I-nn` images, charts referencing facts, notes.
- After composition the **post-check** (`copilot.grounding_check`) extracts every numeric token from the answer and matches it to the bundle (tolerance 0.005 absolute / 0.5 % relative; `hh:mm` and ids as text). An unmatched token withholds the answer: `422 GROUNDING_FAILED` with `detail` naming the token and the run id — the caller never receives an ungrounded answer with a warning attached (ADR-013).
- `TurnTrace.evidence_bundle.facts[]` is "show the numbers" (FR-18); `TurnTrace.grounding` shows what was checked.
- A refusal (`outcome = refused`) is a normal 200 with the answer stating what is missing and how to obtain it (FR-17); it carries `sources` of what *was* checked and never a figure.

## 4. The permission contract (C-03, FR-22, FR-26, AC-04)
- The executor injects the caller's line scope into every tool call's `lines` argument and the database refuses any call outside it (`SCOPE_VIOLATION`, never seen by a user because the executor narrows first). A narrowed answer carries `notes[]` in the bundle and `partial_reason = "requested line outside caller scope"`; the answer says so in the user's language.
- Rows outside scope are never retrieved — filtering happens in the tool's `WHERE`, not in the response.
- Operator names are masked below `masking_rule.min_role_unmasked` (default manager); `masked = true` on the response.
- `/sources/{id}` applies the same scope and ACL: a chunk from a document above the caller's role is `403`.

## 5. The streaming contract (IF-53, NFR-01, NFR-03)
`POST /chat` with `Accept: text/event-stream` emits, in order: `queue` (position, every second while waiting) → `plan` (tool names and arguments — sources are visible before the answer, FR-15) → `clarify` (question back; the stream ends; continue with `/turns/{turnId}/clarify`) or `tool_call`/`tool_result` per step → `token` (answer text, first within 3 s) → `chart`/`image` → `sources` → `confidence` → `done` (turn id, outcome, latency) or `error` (`GROUNDING_FAILED`, `MODEL_UNAVAILABLE`, `BUDGET_EXCEEDED`). Every event has `seq`; a client reconnecting with `Last-Event-ID` receives the rest of the same turn.

## 6. The SQL contract (C-05, FR-08, AI-06, AC-07)
- Generated SQL is used only when no typed tool covers the question **and** `feature_flag.text_to_sql` is on **and** the latest `/eval/sql-runs` passed (≥ 30 questions, ≥ 85 %).
- Every statement is stored (`SqlQuery`) with its verdict; it executes only if it is a single `SELECT`/`WITH` over whitelisted views with `LIMIT ≤ 1000`, as `copilot_sql_ro` (`statement_timeout` 5 s, read-only transaction); the caller's scope is appended.
- `GET /turns/{turnId}/sql` shows the exact statement; `POST /sql-queries/{id}/rerun` (engineer+) re-executes it and reports whether the result digest matches the stored one — AC-07's "reproduces the stated numbers when run manually".

## 7. The refusal / partial / degraded contract (FR-16, FR-17, NFR-06, AC-09)
| Situation | `outcome` | What the response carries |
|---|---|---|
| data absent (shift not uploaded, no rows) | `refused` | what is missing, how to obtain it, `sources` of what was checked |
| tool budget (5 calls / 60 s) or per-tool timeout hit | `partial` | `partial_reason`, the part answered |
| scope narrowed | `ok` or `partial` with `notes` | the notice in the answer |
| clarification needed (FR-05) | `ok` with `clarification` | the question back; slots kept |
| model unavailable | HTTP `503 MODEL_UNAVAILABLE` (`DegradedProblem`) | `mode = dashboards_only`, `links[]` to dashboards, saved questions and document search; `/readyz.mode` says the same |

## 8. Error catalogue
| HTTP | `code` | When |
|---|---|---|
| 401 | `UNAUTHENTICATED` | |
| 403 | `ROLE_INSUFFICIENT` · `SCOPE` · `NOT_OWNER` | admin endpoints; a source above the caller's ACL; another user's conversation |
| 404 | `NOT_FOUND` | |
| 409 | `NOT_SHAREABLE` · `NO_CLARIFICATION` · `READ_ONLY` · `SQL_REJECTED` · `SQL_FLAG_OFF` · `SQL_EVAL_GATE` · `POLICY_REQUIRED` · `ALIAS_EXISTS` · `NOT_CITABLE` | database guard names surface unchanged (DDS-10 Appendix A) |
| 410 | `SHARE_EXPIRED` | |
| 422 | `GROUNDING_FAILED` · `VALIDATION_FAILED` · `CONFIG_INVALID` · `MASKING_REQUIRED` | |
| 429 | `RATE_LIMITED` | per-user turns per minute; queue position is preferred over rejection |
| 503 | `MODEL_UNAVAILABLE` · `NOT_READY` | dashboards-only mode (with links) · DB/Redis/object store down |

## 9. Traceability
| SRS-10 | Endpoints / schemas |
|---|---|
| FR-01…FR-06 | `ChatRequest.answer_lang`, `ChatResponse.lang_detected/intent/entities/time_range/clarification`, `/turns/{turnId}/clarify`, `TurnTrace.context`, `/me/preferences` |
| FR-07, FR-22 | `/tools`, `/tool-policy*`, `ToolPolicy.scope_param`, §4 |
| FR-08 | `/turns/{turnId}/sql`, `/sql-queries/{id}/rerun`, `SqlQuery`, §6 |
| FR-09…FR-12 | `/index/documents`, `/documents/sources*`, `/index/jobs`, `DocSource`, `IndexJob`, `/knowledge/search` |
| FR-13…FR-18 | `ChatResponse`, `StreamEvent`, `Chart`, `Source`, `TurnTrace`, §3, §5 |
| FR-19 | `/turns/{turnId}/share`, `/shares/{token}`, `/turns/{turnId}/pin`, `/pins*` |
| FR-20 | `ChatResponse.suggestions` |
| FR-21 | `ChatResponse.delegated`, `TurnTrace.delegated` |
| FR-23 | `/turns`, `/turns/{turnId}`, `/agent/runs/{runId}`, `/conversations/{conversation_id}/export` |
| FR-24, FR-25 | `/feedback`, `/agent/feedback`, `/turns/{turnId}/flag`, `/flags*`, `/curated*` |
| FR-26 | `/masking-rules`, `ChatResponse.masked` |
| C-01…C-05 | `ToolPolicy.kind = read`, §3, §4, `/feature-flags` (recorded enablement), §6 |
| AI-04, AI-05, AI-06 | §3, `/eval/*` |
| AI-07 | `IndexJob`, `DocSource.status.suspicious_chunks` |
| AI-08, NFR-01, NFR-03 | §5, `/queue`, `QueueStatus` |
| AI-09 | `/glossary/terms`, `/turns/{turnId}/term-check` |
| NFR-06, AC-09 | `/readyz`, `DegradedProblem`, `SavedQuestion.direct_url` |
| NFR-07 | `/conversations/{conversation_id}/export`, `DELETE /conversations/{conversation_id}`, `DELETE /me/conversations` |
| AC-02…AC-08 | §3–§7 |
