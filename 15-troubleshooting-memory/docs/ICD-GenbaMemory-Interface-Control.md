# Interface Control Document — Genba Memory

| Field | Value |
|---|---|
| Document ID | ICD-15-GenbaMemory |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-15](../SRS-GenbaMemory-Troubleshooting-RAG.md) · [SAD-15](SAD-GenbaMemory-Software-Architecture.md) |
| Platform relationship | `IF-xx` numbering is **shared with [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md)** so cross-references hold. **IF-78…IF-84 are new here.** IF-55 is Copilot's (10) and IF-76 is GenbaGo's (14); both are reused rather than re-invented. |

---

## 1. Interface register

| ID | Interface | Parties | Transport | Criticality | This module's role |
|---|---|---|---|---|---|
| [IF-08](#if-08) | Discord | notifier, Discord | WSS + HTTPS | Low | recurrence and suggestion alerts; **never** a restricted record |
| [IF-09](#if-09) | LLM runtime | worker-extract / retriever, Ollama | HTTP/JSON | High | extraction ≤ 9 B, embeddings, the reranker |
| [IF-10](#if-10) | Object storage | api, workers, MinIO | S3 API | **Critical** | the originals, under object-lock (C-01, FR-05) |
| [IF-13](#if-13) | SMTP & webhook | api | SMTP / HTTPS | Low | curation-queue and evaluation notifications |
| [IF-14](#if-14) | Metrics scrape | Prometheus, services | HTTP/text | Medium | ingest backlog, search p95, Recall@5, coverage, queue age |
| [IF-16](#if-16) | Agent tool contract (**provider**) | Genba Memory → 01, 02, 06, 09, 10, 13 | in-process typed / HTTPS | **Critical** | `search_memory`, `get_case`, `similar_cases`, `recurrence_check` |
| [IF-17](#if-17) | Inter-agent bus | QE-Agent, KaizenSwarm, Genba Memory | NATS / Redis Streams | Medium | closed cases and signals in; suggestions out |
| [IF-19](#if-19) | Platform integration | Genba Memory, gateway, 14, 10 | — | **Critical** | owning the whole `knowledge` schema |
| [IF-55](#if-55) | Document ingestion & chunking (**provider in platform mode**) | sources → indexer → `knowledge` | in-process | High | Copilot (10) defines it; 15 serves it |
| [IF-76](#if-76) | OCR contract (**consumer**) | worker-ocr → doc pipeline | JSON | Medium | GenbaGo (14) defines it; 15 stores the same shape |
| [IF-78](#if-78) | **Source connectors** | file shares, mail, chat, tickets → worker-ingest | files / IMAP / export | High | FR-01, FR-06, FR-07 |
| [IF-79](#if-79) | **Case extraction contract** | worker-extract → database | JSON | **Critical** | FR-08…FR-13, AI-01, NFR-08 |
| [IF-80](#if-80) | **Entity normalisation & mapping** | normaliser → curation | JSON / CSV | High | FR-10 |
| [IF-81](#if-81) | **Retrieval & ranking contract** | retriever → api, UI, tools | JSON | **Critical** | FR-15…FR-19, AI-03…AI-05, AI-07 |
| [IF-82](#if-82) | **Suggestion & recurrence alert** | scheduler → api, bus, Discord | JSON | High | FR-20…FR-22, AI-06 |
| [IF-83](#if-83) | **Feedback & curation** | UI → api → database | JSON | High | FR-27…FR-31 |
| [IF-84](#if-84) | **Embedding model & re-embed** | indexer → database | JSON | Medium | AI-09, AC-09 |

---

## 2. Platform interfaces

### IF-08 — Discord {#if-08}
Outbound only, on the `egress` network, from one container. Carries: a recurrence proposal (case title, score, interval, link), a curation-queue age warning, an evaluation-gate failure. **Never** carries a document, a snippet, or anything whose ACL is above `viewer` — the bot builds its message from the case card of a *verified, unrestricted* case or it sends a link and nothing else (SEC-15 SEC-H21).

### IF-09 — LLM runtime {#if-09}
| Use | Model | Constraint |
|---|---|---|
| Extraction | ≤ 9 B instruct, temperature ≤ 0.3, JSON output | schema-constrained against IF-79; the document text is data, never instructions (AI-08) |
| Embeddings | `bge-m3`, 1024-d | the dimension is fixed by `knowledge.chunk.embedding vector(1024)`; changing it is a platform change |
| Reranking | cross-encoder over the top 30 | an LLM reranker is a configurable alternative (`prompts/rerank.v1.md`), not the default — it is slower and not reproducible run to run |

One endpoint, in-cluster. There is no external model endpoint in the configuration schema, the compose file or the environment file, and TEST-15 TC-004 and TC-007 check that.

### IF-10 — Object storage {#if-10}
Buckets `memory-originals` (versioned, **object-lock**, the C-01 guarantee in the storage layer), `memory-ocr`, `memory-exports`, `memory-tmp`. Credentials are files. Originals are written once and read many; nothing deletes from `memory-originals` except a retention job that an admin runs explicitly.

### IF-13 — SMTP & webhook {#if-13}
Curation queue over its age SLA, evaluation gate failures, ingest backlog. Non-blocking, at-least-once.

### IF-14 — Metrics {#if-14}
`memory_ingest_backlog`, `memory_ingest_failed_total{reason}`, `memory_extraction_confidence_bucket`, `memory_search_latency_seconds`, `memory_search_acl_filtered_total`, `memory_recall_at_5`, `memory_coverage_ratio{kind}`, `memory_curation_age_hours`, `memory_suspicious_chunks_total`, `memory_reembed_progress`.

### IF-16 — Agent tool contract (provider) {#if-16}
Four read-only tools, registered in `agent.tool` with `min_role: viewer`:

| Tool | Arguments | Returns |
|---|---|---|
| `search_memory` | `text`, `top_k?` ≤ 20, `scope?`, `verified_only?` (default **true**) | ranked cases in the IF-81 shape |
| `get_case` | `case_id` | one case card with its sources and badge |
| `similar_cases` | `case_id` or `symptom`, `scope?` | the IF-82 suggestion shape |
| `recurrence_check` | `case_id` | proposals above the threshold, with intervals |

Three rules bind every one of them. The **caller's identity travels with the call**, so the ACL applies to the person asking and not to the agent (SEC-15 THR-H03). The result is **case ids with sources**, never prose — the calling agent composes the sentence, and its own grounding check can verify every figure against these rows. And `verified_only` defaults to `true`, so an agent that does not think about it quotes only what a human confirmed (C-03, AI-07).

Consumers: 10 Factory Copilot (RAG and the `search_memory` tool in its registry), 09 QE-Agent (precedent for a hypothesis), 06 MachineSense (alert enrichment, its FR-24), 13 KaizenSwarm (agents), 01 VisionOps and 02 ShiftBrief (narrative context in platform mode).

### IF-17 — Inter-agent bus {#if-17}
**In**: `quality.case.opened` and `quality.case.closed` from QE-Agent (09) — the first triggers a suggestion (FR-20), the second queues the case for indexing; `telemetry.alert.opened` from MachineSense (06). **Out**: `memory.suggestion.created` and `memory.recurrence.detected` for KaizenSwarm (13) and the notifier. At-least-once; a duplicate suggestion is idempotent on `(trigger_kind, quality_case_id)`.

### IF-19 — Platform integration {#if-19}
Genba Memory **owns the `knowledge` schema** (SAD-00 §13, "tight (core)"). The boundary is per table, and it is worth stating precisely because three modules write into one schema:

| Object | Owner | 15's rights |
|---|---|---|
| `knowledge.document`, `chunk`, `case_record`, `case_source`, `case_chunk` | **15** | read / write |
| `knowledge.glossary_term`, `knowledge.tm_segment` | **14 GenbaGo** | read only; `worker_rw` and `app_rw` are explicitly revoked |
| `knowledge.chunk.suspicious`, `suspicious_reason` | **10 Copilot** | set by the injection guard (see IF-55) |
| `knowledge.v_citable_case` | platform | read — the only view an agent may quote |

Migration `memory_0001` is sections 10–19 of `db/schema.sql`. It adds the two Copilot columns with `ADD COLUMN IF NOT EXISTS` and creates `trg_chunk_injection_flag` only when it is not already there, so `copilot_0001` and `memory_0001` may be applied in either order.

### IF-55 — Document ingestion & chunking (provider in platform mode) {#if-55}
Copilot (10) defines this contract; in platform mode Genba Memory serves it and Copilot's own indexer covers only folders 15 does not. The terms are quoted, not paraphrased:

| Item | Contract |
|---|---|
| Kinds | `eight_d`, `rca`, `maintenance_log`, `work_order`, `handover`, `complaint`, `other`, plus the SOP/manual kinds Copilot indexes; scanned PDFs need a text layer or OCR enabled per source |
| Change detection | sha256 per file; unchanged → job `skipped`; changed → re-chunk and re-embed under a new `embedding_version` |
| Chunking | structure-aware: headings → `section`, tables kept whole, ~500 tokens with 15 % overlap, `page` on every chunk |
| Embeddings | `bge-m3`, 1024-d, HNSW cosine; `embedding_version` on every chunk |
| ACL | `acl_json.min_role` from the source, applied as a predicate at retrieval |
| Injection flagging | instruction-like text marks the chunk `suspicious`; the retriever excludes it and lists it in `excluded[]`; admins review |
| Citation | every hit returns `document_id`, `chunk_id`, `title`, `section`, `page` |

The only difference between the two implementations of the flag is the wording of `suspicious_reason`. Whichever migration ran first owns the trigger.

### IF-76 — OCR contract (consumer) {#if-76}
GenbaGo (14) defines the JSON shape for Japanese vertical text, Thai and handwriting. Genba Memory stores exactly that shape in `memory.ocr_page` / `memory.ocr_region` and applies the same rule: **handwriting, or a character confidence below the gate, is always `low_confidence`** (`trg_ocr_flag`). In platform mode the OCR worker is shared; standalone, 15 runs its own producing the same JSON. Inventing a second OCR contract for the same plant would have been the easy thing and the wrong one.

---

## 3. New interfaces

### IF-78 — Source connectors {#if-78}
**Schema**: [`deploy/schemas/source-connector.schema.json`](../deploy/schemas/source-connector.schema.json).

| Item | Contract |
|---|---|
| Kinds | `folder` (SMB/NFS path), `mail` (IMAP mailbox), `chat` (export file), `ticket` (read-only API), `upload`, `manual` |
| Credentials | **never inline.** `credentials_ref` matches `^file:/run/secrets/[a-z0-9_]+$`; a remote kind without one is refused |
| Selection | `include` / `exclude` globs, `kinds`, `date_from` / `date_to` — a decade of file shares is ingested in waves, not at once (OPS-15 §5) |
| ACL | `default_acl` travels with everything the source produces |
| Incremental | sha256 change detection; unchanged files are `skipped`, not re-extracted |
| Failure | one of nine closed reasons with a human-readable `detail` and an `action`; never blocks retrieval (FR-07, NFR-07) |

### IF-79 — Case extraction contract {#if-79}
**Schema**: [`case-extract.schema.json`](../deploy/schemas/case-extract.schema.json) · **example**: [`examples/case-418.json`](../deploy/examples/case-418.json).

Schema-constrained generation, validated before anything is written. What the shape makes impossible is the point:

| Cannot express | Why |
|---|---|
| a field without `provenance {document_id, page}` | the structure indexes the document (C-01, FR-13) |
| a field without `confidence` | extracted is not the same as known (C-02) |
| an extraction without `model`, `prompt_version`, `schema_version` | NFR-08 — reproducible or not an extraction |
| `verified: true` | verification is a human event with a named curator (FR-28) |
| an entity `mapped: true` with no `canonical_id` | unmapped values go to curation, they are not guessed (FR-10) |
| `temperature` above 0.3 | AI-01 |

### IF-80 — Entity normalisation & mapping {#if-80}
**Exchange**: [`deploy/entity-map.example.csv`](../deploy/entity-map.example.csv) (`kind,raw_value,canonical_id,approved_by,approved_at`), identical to `memory.entity_map` in the seed.

`M07`, `M-07`, `เครื่อง 7` and `7号機` are one machine. `normalise_entity(kind, raw)` resolves through approved mappings first and then through the platform's own codes; anything else returns NULL, the entity is stored `mapped: false`, and a curation item opens. Adding a mapping re-normalises the affected cases. Export and import are CSV so a plant can maintain it in a spreadsheet and keep the approver column.

### IF-81 — Retrieval & ranking contract {#if-81}
**Schema**: [`retrieval-result.schema.json`](../deploy/schemas/retrieval-result.schema.json) · **example**: [`examples/appendix-a.json`](../deploy/examples/appendix-a.json).

```
tokenize → bm25_score over term_stat ─┐
embed    → vector cosine (HNSW) ──────┴→ rrf(k = 60) → top 30 → cross-encoder
     acl_visible() and verified_only applied INSIDE both legs
     final = 0.65·similarity + 0.10·entity + 0.05·recency + 0.12·outcome + 0.08·verified
```

Required in every response: `n_acl_filtered` (a count, never the rows), and per hit `badge`, `sources` (≥ 1), `scores` and `why`. Forbidden by construction: a hit with several case ids, a hit with no source, a badge outside the two values, and any carrier for a snippet of a filtered row.

**Consumers**: the web UI, `POST /search`, `POST /similar`, and the IF-16 tools — all four read the same shape so a Copilot answer and a UI card cannot disagree about what matched.

### IF-82 — Suggestion & recurrence alert {#if-82}
**Schema**: [`recurrence-alert.schema.json`](../deploy/schemas/recurrence-alert.schema.json) · **example**: [`examples/recurrence-418.json`](../deploy/examples/recurrence-418.json).

| Item | Contract |
|---|---|
| Trigger | `quality_case` (FR-20), `alert` (MachineSense), `manual` |
| Budget | `latency_ms` ≤ 3000 (NFR-02) — a slow suggestion is a contract violation, not a slow response |
| Threshold | default 0.72, tuned for recall with the precision/recall table in OPS-15 §10 |
| Interval | whole months between the two cases' `opened_at`; **computed**, never supplied |
| Confirmation | `counted_in_analytics` cannot be true while `confirmed` is false (AI-06) |
| First checks | quoted from the prior case's action text; nothing is invented |

### IF-83 — Feedback & curation {#if-83}
| Rating | Effect |
|---|---|
| `helpful` | recorded against the retrieval; feeds evaluation |
| `not_helpful` | the same, with an optional reason |
| `incorrect` | **names a field**, flags it, suppresses it from every rendering, opens a curation item (FR-30, AC-06) |

Curation kinds: `low_confidence`, `unmapped_entity`, `near_duplicate`, `flagged_field`, `unverified_case`, `suspicious_chunk`. Decisions: `verified`, `corrected`, `mapped`, `merged`, `distinct`, `suppressed`, `dismissed` — a closed vocabulary, curator or admin only, append-only in the audit log. Feedback never changes a live score (ADR-H08).

### IF-84 — Embedding model & re-embed {#if-84}
`memory.embedding_model` registers `version`, `model`, `dim` (fixed at 1024) and `state`. Every chunk and every candidate carries its `embedding_version`. A re-embed job walks the corpus in batches writing the new version; queries stay pinned to the active one; the switch is one row; `search_available` asserts it and `trg_embedding_retire` refuses to retire a version a running job still serves. That is AC-09 expressed as three columns and a trigger.

---

## 4. Interface matrix

| Interface | Standalone | Platform mode | On failure | Audit trail |
|---|---|---|---|---|
| IF-08 Discord | own bot (`discord` profile) | platform notifier | alerts queue; retrieval unaffected | `audit.log` |
| IF-09 LLM | own Ollama | platform Ollama + GPU semaphore | lexical retrieval still answers; extraction queues | `memory.extraction` |
| IF-10 storage | own MinIO | platform MinIO with memory prefixes | ingest fails as a row (FR-07) | bucket + `ingest_job` |
| IF-16 tools | HTTPS to this module | `agent.tool` registry | the sibling degrades to its own data | `audit.log` |
| IF-17 bus | not used | NATS / Redis Streams | suggestion is late, never wrong | `memory.suggestion` |
| IF-19 platform | full schema | `memory_0001` only | — | `memory.migration` |
| IF-55 ingestion | own connectors | 15 serves it for the platform | `skipped` / `failed` job | `memory.ingest_job` |
| IF-76 OCR | own worker | shared worker | region marked low confidence | `memory.ocr_region` |
| IF-78…IF-84 | files + API | same | see each above | `curation_item`, `verification`, `eval_run` |

---

## 5. Change control

| What changes | Who approves | Consequence |
|---|---|---|
| A rank weight | admin | recorded with a timestamp; every stored score keeps the weights it was computed with, and `POST /search/explain` returns them |
| `recurrence_threshold` | admin, with the precision/recall table | existing confirmed links are untouched; new proposals change |
| A prompt version | admin | a new `memory.extraction.prompt_version`; old fields keep theirs (NFR-08) |
| The evaluation or labelled set | curator + admin | a new `version`; runs name the version they used |
| The entity map | curator | affected cases are re-normalised; the approver is stored |
| An embedding model | admin | a new `embedding_model` row and a re-embed job; the old version stays queryable (AC-09) |
| `case-extract-1.0` | platform owner | a new `schema_version`; the old one stays valid for stored fields |

---

## 6. Traceability

| SRS | Interface |
|---|---|
| FR-01, FR-06, FR-07 | IF-78, IF-55 |
| FR-02 | IF-76 |
| FR-08…FR-13, AI-01, NFR-08 | IF-79 |
| FR-10 | IF-80 |
| FR-15…FR-19, AI-03…AI-05, AI-07 | IF-81, IF-16 |
| FR-20…FR-22, AI-06 | IF-82, IF-17 |
| FR-27…FR-31 | IF-83 |
| AI-08 | IF-55 (injection flagging), IF-09 |
| AI-09, AC-09 | IF-84 |
| C-01, FR-05 | IF-10 (object-lock), IF-79 (provenance) |
| C-04, NFR-06 | IF-09 (in-cluster only), IF-08 (single egress container) |
| C-05, NFR-05 | IF-81 (`n_acl_filtered`), IF-16 (caller identity), IF-78 (`default_acl`) |
| NFR-09 | IF-16 (GenbaGo `translate` as a consumer for snippets) |
