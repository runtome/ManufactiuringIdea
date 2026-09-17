# Interface Control Document — Factory Copilot (Local AI Factory Copilot)

| Field | Value |
|---|---|
| Document ID | ICD-10-Copilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-17 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-10](../SRS-FactoryCopilot-Local-Multilingual-Assistant.md) §4 · [SAD-10](SAD-Copilot-Software-Architecture.md) §4 · [API-10](../api/API-Specification.md) · [DDS-10](DDS-Copilot-Database-Design.md) · [SEC-10](SEC-Copilot-Security-Requirements.md) · [TEST-10](TEST-Copilot-Test-Plan.md) · platform: [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) |

---

## 1. Scope and register
Copilot is the **consumer** of the platform's interfaces rather than a provider of new data feeds: it calls every sibling's tools (IF-16), talks to the model runtime (IF-09), stores exports and reads images (IF-10), posts to Discord only when enabled (IF-08), and exposes metrics (IF-14). Five interfaces are new and owned here.

| IF | Name | Direction | Owner | Section |
|---|---|---|---|---|
| IF-08 | Discord (`/ask`, threads) | Copilot ↔ Discord | platform / Copilot | [§IF-08](#if-08) |
| IF-09 | LLM runtime (planner, composer, embeddings, reranker) | Copilot → Ollama | platform | [§IF-09](#if-09) |
| IF-10 | Object storage (documents, images, exports) | Copilot ↔ MinIO | platform | [§IF-10](#if-10) |
| IF-14 | Metrics | Prometheus → Copilot | platform | [§IF-14](#if-14) |
| IF-16 | Agent tool contract — **as consumer** | Copilot → 02 / 06 / 09 / 15 / vision | platform | [§IF-16](#if-16) |
| IF-17 | Inter-agent bus (optional) | KaizenSwarm → Copilot | platform | [§IF-17](#if-17) |
| IF-19 | Platform integration | Copilot ↔ FactoryBrain | platform | [§IF-19](#if-19) |
| **IF-53** | **Chat streaming protocol** | web / Discord / embed ← Copilot | **Copilot** | [§IF-53](#if-53) |
| **IF-54** | **Text-to-SQL sandbox** | planner → sandbox → PostgreSQL | **Copilot** | [§IF-54](#if-54) |
| **IF-55** | **Document ingestion & chunking** | sources → indexer → `knowledge` | **Copilot** (Genba Memory in platform mode) | [§IF-55](#if-55) |
| **IF-56** | **Evidence bundle & answer composer contract** | executor/retriever → composer | **Copilot** | [§IF-56](#if-56) |
| **IF-57** | **Embed widget** | FactoryBrain dashboard ↔ Copilot web | **Copilot** | [§IF-57](#if-57) |

## IF-08 — Discord {#if-08}
Inherits [ICD-00 IF-08](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-08). Copilot specifics:
- **Off by default** (`feature_flag.discord`, compose profile `discord`): a Discord answer leaves the LAN, so enablement is an admin decision with a written policy (SEC-10 SEC-C41): masking on for every Discord turn, no images, no document text beyond citations, channel allow-list.
- `/ask <question>` → acknowledged within 3 s (deferred), the answer follows in a thread with sources; follow-ups in the thread keep the conversation (`channel = discord`).
- Identity: the Discord user must have a **verified** `copilot.channel_binding`; unbound users get "not registered" and nothing else (chat presence is not authentication).
- No approval buttons, no write actions — Copilot has none.

## IF-09 — LLM runtime {#if-09}
Inherits [ICD-00 IF-09](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-09). Copilot makes at most three kinds of calls per turn:

| Call | Input | Output | Rules |
|---|---|---|---|
| planner | question, conversation slots (previous turn's line/time/metric), tool schemas of the caller's role, aliases hint, prompt `planner.vN` | typed plan JSON (validated against the registry) or a clarification | ≤ 5 tool calls; no document text; temperature ≤ 0.1 |
| composer | evidence bundle (IF-56) + prompt `composer.vN` + glossary entries | answer text with `[F-nn]`/`[D-nn]` citations | numbers only from the bundle; documents are data; language rule; temperature ≤ 0.3 |
| embeddings / reranker | chunk or query text | vector(1024) / relevance scores | `bge-m3`; reranker on ≤ 30 candidates |

Timing: first token ≤ 3 s, whole turn ≤ 20 s p95 (NFR-01); per-turn wall clock 60 s; calls serialise through the platform GPU semaphore in platform mode. Unavailability → `mode = dashboards_only`, `/chat` 503 with links (AC-09). Model tag, prompt versions and embedding version are recorded on every `agent.run`; any change re-runs the evaluation set (AI-05).

## IF-10 — Object storage {#if-10}
Inherits [ICD-00 IF-10](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-10). Prefixes: `docs/<source>/…` (ingested originals, ACL-tagged), `images/…` (read via `get_inspection_images`; signed URLs 15 min), `exports/shares/<token>.<png|pdf>` (≤ 30 days, deleted on expiry), `uploads/<user>/<id>` (photos for similarity search; 24 h). Exports carry the label "AI-generated answer — sources attached" and the version stamp.

## IF-14 — Metrics {#if-14}
`/metrics` (Prometheus, internal): `copilot_turns_total{outcome,intent,lang,channel}`, `copilot_first_token_seconds`, `copilot_answer_seconds`, `copilot_tool_calls_per_turn`, `copilot_tool_seconds{tool}`, `copilot_grounding_failed_total`, `copilot_refused_total`, `copilot_partial_total`, `copilot_scope_narrowed_total`, `copilot_clarifications_total`, `copilot_sql_generated_total{verdict}`, `copilot_retrieval_seconds`, `copilot_index_jobs_total{state}`, `copilot_suspicious_chunks_total`, `copilot_queue_depth`, `copilot_queue_wait_seconds`, `copilot_llm_available`, `copilot_eval_accuracy`, `copilot_eval_blocked`, `copilot_term_violations_total`.

## IF-16 — Agent tool contract (as consumer) {#if-16}
Copilot is the primary consumer of [ICD-00 IF-16](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-16). The tools it exposes, their providers and the scope argument (`deploy/tools.example.json`):

| Tool | Provider | Min role | Scope param | Used for |
|---|---|---|---|---|
| `query_production(date_from, date_to, lines?, sku?, shift?)` | ShiftBrief (02) / local | viewer | `lines` | rates, volumes, shifts (FR-07) |
| `query_defects(date_from, date_to, group_by, lines?)` | ShiftBrief (02) / local | viewer | `lines` | Pareto, shares |
| `get_spc(characteristic, lines?, window?)` | QE-Agent (09) | viewer | `lines` | control charts |
| `get_capability(characteristic, lines?, period?)` | QE-Agent (09) | viewer | `lines` | Cp/Cpk with context |
| `get_machine_telemetry(machine_id, signal, window, lines?)` | MachineSense (06) | inspector | `lines` | machine history |
| `search_memory(text, top_k?, kinds?, lines?)` | Genba Memory (15) / local | viewer | `lines` | past cases, documents |
| `get_inspection_images(date_from, date_to, lines?, defect?, sku?, limit?, similar_to_upload_id?)` | vision (01/03/05) | inspector | `lines` | image evidence (FR-10) |
| `get_signals(status?, lines?, severity?)` | QE-Agent (09) | viewer | `lines` | cause delegation |
| `get_case(case_id, lines?)` | QE-Agent (09) | viewer | `lines` | case link |
| `get_hypotheses(case_id, lines?)` | QE-Agent (09) | inspector | `lines` | ranked hypotheses (FR-21) |

Rules (in addition to ICD-00's): (1) the executor injects the caller's scope into `scope_param` before the call and `copilot.scope_ok()` refuses anything outside it at the database; (2) `create_draft_report` and `send_discord` exist in the registry but **cannot be enabled** for Copilot (`trg_tool_policy_read_only`); (3) every result carries `row_count` and a digest recorded on `agent.tool_call`; (4) per-tool timeout ≤ 10 s, ≤ 5 calls per turn; (5) a tool's schema change is a registry version change and triggers an evaluation run.

## IF-17 — Inter-agent message bus {#if-17}
Optional. Copilot subscribes to `quality.signal.high` and `agent.briefing.ready` to offer "ask about this" links in the UI; it publishes nothing.

## IF-19 — Platform integration {#if-19}
Same containers; platform database (`copilot_0001` applied; `agent.conversation/message/run/tool_call/feedback` owned by Copilot); platform auth, roles and scopes; platform Ollama with the GPU semaphore; platform object store with Copilot prefixes; Genba Memory as the document store (Copilot's indexer only for folders it does not cover); the gateway serves `/agent/ask`, `/agent/runs/{runId}`, `/agent/feedback`, `/agent/tools`, `/knowledge/search`, `/knowledge/documents`; the rest under `/copilot/`.

## IF-53 — Chat streaming protocol {#if-53}
**Parties.** Copilot `api` → web UI, Discord bot, embed widget. **Protocol.** HTTP `POST /chat` with `Accept: text/event-stream`; Server-Sent Events, UTF-8, `event:` = kind, `id:` = `seq`, `data:` = JSON.

| Event | Payload | When |
|---|---|---|
| `queue` | `{position, depth, eta_ms}` | while waiting; every 1 s (NFR-03) |
| `plan` | `{turn_id, lang, intent, entities[], time_range, steps[]}` | after understanding; before any tool runs |
| `clarify` | `{turn_id, question}` | ambiguity that changes the answer (FR-05); stream ends |
| `tool_call` | `{ordinal, tool, args}` | per step (args already scope-narrowed) |
| `tool_result` | `{ordinal, row_count, duration_ms, ok, partial_note?}` | per step |
| `token` | `{text}` | answer text as generated; first within 3 s |
| `chart` | `{id, kind, spec, facts[]}` | Vega-Lite spec referencing bundle facts (FR-14) |
| `image` | `{id, inspection_id, signed_url, expires_at}` | FR-10 |
| `sources` | `{items: Source[]}` | after the post-check passed (FR-15) |
| `confidence` | `{note, partial, partial_reason}` | FR-16 |
| `done` | `{turn_id, run_id, outcome, latency_ms, masked, delegated?, suggestions[]}` | end |
| `error` | `{code, detail, links?}` | `GROUNDING_FAILED`, `MODEL_UNAVAILABLE` (with links), `BUDGET_EXCEEDED`, `SCOPE` |

Rules: `plan` precedes any `token`; `sources` follows the last `token` only if the post-check passed — on failure no `token` of a withheld answer is ever flushed to the client (the composer output is buffered until the check completes; streaming starts from a *checked prefix* when the bundle contains no numbers, otherwise tokens stream and a failing check emits `error` and the client discards the buffered text — the UI never shows a withheld number as final). Reconnect with `Last-Event-ID` resumes the same turn. Timing: `done` within 20 s p95 for a 3-tool question.

## IF-54 — Text-to-SQL sandbox {#if-54}
**Parties.** planner → `sql-sandbox` → PostgreSQL as `copilot_sql_ro`.

| Item | Contract |
|---|---|
| Precondition | no typed tool covers the question; `feature_flag.text_to_sql = true`; latest `sql_eval_run.passed` (≥ 30 questions, ≥ 85 %) |
| Input | the model's proposed statement + the caller's scope |
| Validation | real SQL parser (`pglast`): single statement; `SELECT`/`WITH` only; no DML/DDL/`SET`/functions outside the allow-list; every relation in `copilot.sql_whitelist`; scope predicate appended on `scope_column`; `LIMIT` ≤ 1000 appended if absent; no comments — the database twin `copilot.sql_is_safe()` re-checks on insert |
| Execution | role `copilot_sql_ro` (`SELECT` on the whitelisted views only; `statement_timeout 5 s`; read-only transaction); rows ≤ `LIMIT` |
| Record | `copilot.sql_query` (statement, verdict, limit, timeout, executed_as, row_count, digest) |
| Surfacing | "show the SQL" in the answer; `POST /sql-queries/{id}/rerun` reproduces and compares digests (AC-07) |
| Failure | rejected statement → the planner is not retried with a "repaired" query; the answer refuses with "no tool covers this yet" |

## IF-55 — Document ingestion & chunking {#if-55}
**Parties.** watched sources (`copilot.doc_source`) / `POST /index/documents` → `indexer` → `knowledge.document/chunk`.

| Item | Contract |
|---|---|
| Kinds | `sop`, `eight_d`, `fmea`, `manual`, `work_instruction` (PDF, DOCX, XLSX, TXT, MD); scanned PDFs need a text layer or OCR enabled per source |
| Change detection | sha256 per file; unchanged → job `skipped`; changed → re-chunk + re-embed under a new `embedding_version` (FR-12) |
| Chunking | structure-aware: headings → `section`, tables kept whole, ~500 tokens with 15 % overlap, `page` recorded for every chunk (FR-11, AI-02) |
| Embeddings | `bge-m3`, 1024 d, HNSW cosine; `embedding_version` on every chunk |
| ACL | `acl_json.min_role` from the source; applied as a predicate at retrieval |
| Injection flagging | `trg_chunk_injection_flag` marks instruction-like text (EN/JA/TH phrase patterns) `suspicious`; the retriever excludes flagged chunks from bundles and lists them in `excluded[]`; admins review (AI-07, AC-05) |
| Citation | every hit returns `document_id, chunk_id, title, section, page` (FR-15) |

## IF-56 — Evidence bundle & answer composer contract {#if-56}
The whole of P-1 in one JSON document: [`deploy/schemas/evidence-bundle.schema.json`](../deploy/schemas/evidence-bundle.schema.json) (Draft 2020-12, `additionalProperties: false` at the top level).

Rules:
1. **Producer**: the executor and retriever assemble the bundle from tool results (`facts[]` with `F-nn` ids and the `tool#ordinal` source), QE hypotheses (`H-nn`, with QE's status), documents (`D-nn`, bounded quoted chunks with section/page), sandbox statements (`S-nn`), images (`I-nn`), chart specs referencing facts, `notes[]` for anything partial or narrowed.
2. **Consumer**: the composer receives the bundle and the versioned prompt; it may quote a number only with its evidence id; it must state `notes[]`; it uses QE's non-causal wording for hypotheses; it treats `documents[].text` as data.
3. **Post-check**: `grounding_check(answer, bundle)`; unmatched → withheld (§API-10 §3).
4. **Storage**: `agent.run.facts_json` = the bundle; `copilot.turn.bundle_digest` = sha256; the evaluation set stores each bundle for reproducibility.
5. **Versioning**: `schema_version: evidence.v1`; a change is a new version and an evaluation run.

TEST-10 TC-006: the seed's bundles validate; 14 negatives rejected (fact without id, source not a tool ref, chunk without page/section, oversize text, smuggled raw rows, chart without facts, partial without a note, unknown hypothesis status, non-whitelisted SQL relation, > 20 images, wording rule off, unknown language, wrong schema version).

## IF-57 — Embed widget {#if-57}
**Parties.** FactoryBrain dashboard (host page) ↔ Copilot `web` (iframe). The host passes a short-lived token by `postMessage` (`{type: "copilot.auth", token}`) after the iframe signals `{type: "copilot.ready"}`; the widget never reads host cookies; origin allow-list on both sides; the widget streams over IF-53 like the full UI; `channel = embed`; the host may pre-fill a question (`{type: "copilot.ask", text}`) for "ask about this" links (IF-17). Size and theme are host-controlled; the widget stays usable at 360 px width (NFR-09).

## 2. Interface matrix
| IF | Protocol | Security | Timing | Failure behaviour |
|---|---|---|---|---|
| IF-08 | Discord Gateway/REST | bot token secret; verified binding; policy | ack ≤ 3 s | Discord down → web unaffected |
| IF-09 | HTTP/JSON | internal; no egress | first token ≤ 3 s; ≤ 20 s p95 | dashboards-only mode |
| IF-10 | S3 | signed URLs 15 min | — | exports fail loudly; answers unaffected |
| IF-14 | HTTP | Prometheus host only | scrape 15 s | — |
| IF-16 | HTTP/JSON (typed) | JWT; scope predicate; `agent_ro` | ≤ 10 s per tool | partial answer with reason |
| IF-53 | SSE | JWT / embed token | events ≤ 1 s apart while active | `error` event; reconnect |
| IF-54 | SQL | `copilot_sql_ro`; parser; whitelist | ≤ 5 s | refusal |
| IF-55 | files | source ACL | scan every 5 min | job `failed` with reason |
| IF-56 | JSON | schema-validated | — | bundle invalid → turn `error` |
| IF-57 | postMessage | origin allow-list; token | — | widget shows "not authorised" |

## 3. Change control
| Change | Who | Requires |
|---|---|---|
| Tool schema / new tool | provider + Copilot admin | registry version; evaluation run; per-tool scope test (NFR-05) |
| Prompt template | ML owner | new version with checksum; evaluation run |
| Model or embedding | ML owner | evaluation run (+ re-embed for embeddings) |
| Evidence-bundle schema | Copilot | new `schema_version`; evaluation run |
| SQL whitelist | admin | evaluation of the SQL set; never `core.app_user` |
| Aliases, glossary, masking rules | admin | audit row |
| Discord / external model | admin | recorded flag with reason; policy |

## 4. Traceability
| SRS-10 | IF |
|---|---|
| FR-07, FR-22, C-01, C-03 | IF-16 |
| FR-08, C-05, AI-06 | IF-54 |
| FR-09…FR-12, AI-02, AI-03, AI-07 | IF-55 |
| FR-13…FR-18, AI-04, AI-08 | IF-56, IF-53 |
| FR-19 | IF-10 |
| FR-21 | IF-16 (`get_signals`, `get_hypotheses`) |
| AI-01, AI-03, NFR-01 | IF-09 |
| §4.2 channels, C-04 | IF-08, IF-57 |
| NFR-03 | IF-53 `queue` |
| NFR-06, AC-09 | IF-09 degradation, IF-53 `error` |
