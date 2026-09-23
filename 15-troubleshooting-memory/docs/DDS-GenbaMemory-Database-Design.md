# Database Design Specification — Genba Memory

| Field | Value |
|---|---|
| Document ID | DDS-15-GenbaMemory |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-15](../SRS-GenbaMemory-Troubleshooting-RAG.md) · [SAD-15](SAD-GenbaMemory-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) (2,777 lines) · [`db/seed_demo.sql`](../db/seed_demo.sql) (1,375 lines) |
| Related | [API-15](../api/API-Specification.md) · [ICD-15](ICD-GenbaMemory-Interface-Control.md) · [SEC-15](SEC-GenbaMemory-Security-Requirements.md) · [TEST-15](TEST-GenbaMemory-Test-Plan.md) · parent [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) |

---

## 1. Scope

PostgreSQL 16 with `pgvector`, `pg_trgm`, `pgcrypto` and `btree_gin`. The file is one schema for a standalone deployment and, read from section 10 onwards, one migration (`memory_0001`) for platform mode.

**What this database is asked to guarantee.** Not "store cases" — a spreadsheet does that. It is asked to make four things impossible: quoting a case no document backs; presenting a machine's guess as a human's conclusion; returning a row the reader is not allowed to see; and letting a number in a report (a similarity, a recall, an interval) be something other than what the stored inputs produce. Sections 5 and 4 are where those four live.

---

## 2. What is extracted and what is new

- **Sections 1–9 — extracted verbatim from `00/db/schema.sql`** and marked `[platform section N, verbatim]`: the four extensions, the two helper functions, the four enums the extracted objects use (`core.shift_code`, `core.language_code`, `quality.case_status`, `quality.severity`), the whole `core` section, `quality.signal` and `quality.case`, the **whole `knowledge` section** (all seven tables), `audit`, their indexes, the six `updated_at` triggers and the view `knowledge.v_citable_case`. TEST-15 TC-002 diffs every block and every object: **14 / 14 blocks and 58 / 58 objects byte-identical**.
- **Sections 10–19 — the `memory` extension**: 40 tables, 34 deterministic functions, 22 trigger functions, 26 guard triggers, 28 indexes and 11 views.

`quality.signal` and `quality.case` are extracted because `knowledge.case_record.quality_case_id` references `quality.case` and because an insert there is what pushes precedent (FR-20). The rest of the `quality` section belongs to QE-Agent (09) and is not reproduced.

### 2.1 Who owns what inside `knowledge`

| Object | Owner | Genba Memory's rights |
|---|---|---|
| `knowledge.document`, `chunk`, `case_record`, `case_source`, `case_chunk` | **Genba Memory (15)** | read / write |
| `knowledge.glossary_term`, `knowledge.tm_segment` | **GenbaGo (14)** | read only — `REVOKE INSERT, UPDATE, DELETE … FROM app_rw, worker_rw` |
| `knowledge.chunk.suspicious`, `suspicious_reason` | **Factory Copilot (10)** (`copilot_0001`) | set by the injection guard; added here with `ADD COLUMN IF NOT EXISTS` so the two migrations apply in either order |
| `knowledge.v_citable_case` | platform | read — it is the only thing an agent may quote |

The trigger `trg_chunk_injection_flag` exists in both `copilot_0001` and `memory_0001`. `memory_0001` creates it only when it is not already there, and both implementations set the same two columns for the same reason (ICD-15 [IF-55](ICD-GenbaMemory-Interface-Control.md#if-55)).

---

## 3. The `memory` schema

### 3.1 Settings, roles and access (section 11)

| Table | Purpose |
|---|---|
| `setting` | key/value with a `locked` flag. A locked setting is a constraint, not a preference: `verified_only_default`, `acl_at_query_time`, `local_only`, `source_link_required`, `extraction_marked`, `rerank_depth`, `embedding_dim` and the four quality gates. `deploy/schemas/genbamemory-config.schema.json` const-locks the same keys. |
| `user_role` | `viewer` / `engineer` / `curator` / `admin` on platform users. Verification is curator or admin; recurrence confirmation is engineer and up. |
| `access_group`, `group_member` | the groups named in `knowledge.document.acl_json.groups`, resolved by `acl_visible()`. |
| `source` | watched folder, mailbox, chat export, ticket system or upload (IF-78). `location` is a path, never a credential. |

### 3.2 Ingestion (section 12)

`ingest_job` (state × stage; a failure is a row, never an exception path — NFR-07), `ingest_error` (nine closed reasons **and an `action` column**, because FR-07 asks for *actionable* reasons), `doc_text` (per page, per language), `ocr_page` / `ocr_region` (the IF-76 shape GenbaGo defines: orientation, character confidence, handwriting), `near_duplicate` (score, resolution, decider).

### 3.3 Structuring (section 13)

| Table | Purpose |
|---|---|
| `doc_class_rule` | keyword → document class with a weight; the deterministic half of FR-08 |
| `extraction` | model, prompt version, schema version, temperature — NFR-08 in one row |
| `case_field` | **one row per field** with `value`, `confidence`, `provenance_json`, `extraction_id`, `human`, `flagged` (ADR-H03) |
| `case_entity` | raw value → canonical id, `mapped` |
| `entity_map` | `M07`, `7号機`, `เครื่อง 7` → `M-07`, approved by a curator |
| `symptom_descriptor` | defect class, failure mode, alarm code, measured deviation (FR-11) |
| `recurrence` | case → prior case, score, **computed** interval, confirmation |

### 3.4 Retrieval (section 14)

| Table | Purpose |
|---|---|
| `corpus_stat`, `term_stat` | `N`, `avgdl` and the document frequencies BM25 needs, as rows — which is what makes `bm25_score()` a pure function of stored data |
| `case_index` | the indexed text, its token array, the token count, the embedding version and the **inherited ACL** |
| `rank_weight` | FR-18 as five numbers that must sum to 1.000 |
| `query_log` | the query, scope, `require`, `verified_only`, `top_k`, `n_results` and **`n_acl_filtered` — a count, never the rows** |
| `query_candidate` | what SQL cannot compute: the ANN rank and the cross-encoder similarity |
| `query_result` | every component score, the final score and `why_json` |
| `feedback` | helpful / not helpful / incorrect; append-only; never a live ranking weight |
| `suggestion` | the push on case open, its latency and whether anyone opened it |

**`scope` versus `require`.** `scope_json` narrows the *ranking* through `entity_overlap()`; `require_json` removes rows outright. Appendix A filters `machine = M-07` as a **scope**, which is why Case #602 on M-04 still appears — that is FR-22, horizontal deployment, not a leak in the filter.

### 3.5 Curation and evaluation (section 15)

`curation_item` (six kinds, four states, one decision vocabulary), `verification` (append-only; `knowledge.case_record.verified_at` is its denormalised answer), `merge_event` (append-only; sources move, documents are never deleted), `label_set` / `label_field` (AI-02), `eval_set` / `eval_query` / `eval_qrel` / `eval_run` / `eval_result` (AI-04), `embedding_model` / `reembed_job` (AI-09), `migration`.

---

## 4. The deterministic functions (section 16)

Thirty-four functions. Each is a **twin**: TEST-15 TC-005 re-derives it in Python from the seed's own literals and compares. Two things are deliberately *not* here because SQL cannot compute them — the embedding and the cross-encoder similarity. Both enter as data on `query_candidate`, and the README says so.

| Group | Functions | Notes |
|---|---|---|
| Text | `normalise_text`, `content_hash`, `detect_lang`, `tokenize`, `near_dup_score`, `injection_scan` | `normalise_text` keeps digits, Latin, Thai, kana, CJK, `-` and `/` — because `M-07`, `RAD-500-A` and `8D/RCA` are the tokens that matter most |
| Structuring | `classify_document`, `extract_alarm_code`, `extract_deviation`, `defect_classes`, `defect_class_of`, `normalise_entity` | `defect_classes` returns **all** matches in a fixed order: "overload, motor not rotating" names two things |
| Access | `role_rank`, `acl_visible`, `case_acl` | `acl_visible` is called inside the retrieval CTEs (P-4) |
| Ranking | `bm25_score`, `rrf`, `entity_overlap`, `recency_weight`, `outcome_weight`, `final_score`, `why_matched`, `rank_query`, `case_card` | see §4.1 |
| Recurrence and analytics | `recurrence_check`, `top_recurring`, `action_effectiveness`, `mtbr`, `knowledge_gaps`, `coverage_metrics` | |
| Evaluation | `recall_at_k`, `mrr`, `extraction_accuracy`, `eval_finalize` | |

### 4.1 The ranking, step by step

```
tokenize(query, lang)          words for Latin script; character bigrams for Thai and
                               Japanese; Latin and numeric tokens kept as words
bm25_score(q, d, scope)        Okapi BM25, k1 = 1.2, b = 0.75,
                               idf = ln(1 + (N - df + 0.5) / (df + 0.5))
rrf(lex_rank, vec_rank, 60)    reciprocal rank fusion → the top `rerank_depth` (30)
acl_visible(case_acl(c), …)    inside the CTE, before any snippet exists
verified_only                  default true (C-03)
final_score = 0.65 · rerank_sim + 0.10 · entity_overlap + 0.05 · recency
            + 0.12 · outcome  + 0.08 · verified
why_matched                    matched terms, entities, descriptors, badge, components
```

The constants `k1`, `b` and the RRF `k` live in the functions, not in configuration: changing them silently would change the meaning of every score already stored. The five weights live in `rank_weight` because they *are* meant to be tuned — and a constraint trigger keeps them summing to 1.000 so a score stays comparable across queries.

### 4.2 Appendix A, re-derived

The seed runs SRS Appendix A through these functions. The result is worth reading twice:

| Case | BM25 | lex rank | vec rank | rerank sim | entity | recency | outcome | verified | **final** |
|---|---|---|---|---|---|---|---|---|---|
| **#418** (Japanese 8D) | **1.1323** | **6** | 1 | 0.8342 | 1.000 | 0.556 | 1.000 | ✅ | **0.870** |
| **#602** (Thai log) | 12.6645 | 2 | 2 | 0.7815 | 0.333 | 0.694 | 0.700 | ✅ | **0.740** |
| **#331** (Thai handover) | 16.9755 | 1 | 5 | 0.7637 | 0.667 | 0.458 | 0.200 | ⚠ | **0.610** |

The Thai query has the **worst possible lexical match** with the Japanese 8D — it ranks sixth of seven on BM25 — and the 8D still comes first, because the vector leg ranked it first and it is the only candidate that matches both the machine and both descriptors. That single row is AC-03. The inverse is #331: the **best** lexical match, third place, because nobody ever verified it and its outcome is unknown (P-2). Change `verified_only` to its default and #331 disappears entirely (C-03).

---

## 5. Guard triggers (section 17)

| ID | Trigger(s) | What becomes impossible | SRS |
|---|---|---|---|
| **DD-H01** | `trg_document_immutable` | changing a stored document's `sha256`, `uri`, `original_name` or `ingested_at` | C-01, FR-05 |
| **DD-H02** | `trg_near_duplicate` | merging a near-duplicate without a person; a score ≥ 0.92 not reaching the queue | FR-04, FR-27 |
| **DD-H03** | `trg_field_provenance`, `trg_field_queue` | a machine-written field without confidence, provenance and its extraction row; a low-confidence field nobody is asked to look at | FR-13, FR-27, NFR-08, C-01 |
| **DD-H04** | `trg_field_flag_suppress` | a flagged field returning to results without a curator | FR-30, AC-06 |
| **DD-H05** | `trg_case_citable` | verifying a case with no source, with a flagged field, or by someone who is not a curator | AI-07, AC-08, FR-28 |
| **DD-H06** | `trg_verify_role`, `trg_verification_applies`, `trg_verification_append_only` | verification by the wrong role; editing or deleting a verification | FR-28 |
| **DD-H07** | `trg_entity_mapped`, `trg_entity_queue` | claiming an unmapped value as canonical; an unmapped entity nobody sees | FR-10 |
| **DD-H08** | `trg_recurrence_confirm` | a recurrence below the threshold; an *entered* interval; confirmation by a viewer | FR-21, AI-06, AC-07 |
| **DD-H09** | `trg_acl_inherit` | indexing a case more permissively than its strictest source | C-05, NFR-05, AC-05 |
| **DD-H10** | `trg_chunk_embedding_version`, `trg_case_chunk_embedding_version`, `trg_embedding_retire`, `trg_chunk_injection_flag`, `trg_suspicious_queue` | a vector without its model version; an unregistered version; retiring a version a running re-embed still serves; instruction-like text entering the index unflagged | AI-08, AI-09, AC-09 |

Supporting guards: `trg_ocr_flag` (handwriting and sub-gate characters are always low confidence), `trg_eval_gate` (`passed` is computed from AI-02 / AI-04, never asserted), `trg_rank_weight_sum` (deferred constraint trigger), `trg_feedback_incorrect` ("this is wrong" flags the field), `trg_curation_decision` (curator or admin), and the append-only triggers on `query_log`, `feedback` and `merge_event`.

---

## 6. Indexes, views and sizing (section 18)

Platform indexes are extracted verbatim, including HNSW (`m = 16`, `ef_construction = 64`, cosine) on `knowledge.chunk`, `case_chunk` and `tm_segment`, the trigram GIN indexes and `idx_case_record_verified`. The extension adds 28, of which the ones that carry NFR-01 are `idx_case_index_tokens` (GIN over the token array), `idx_case_index_text_trgm`, and the partial indexes on the curation-shaped predicates (`flagged`, `mapped = false`, `resolution = 'pending'`, unconfirmed recurrences).

| Sizing target | Design response |
|---|---|
| 50 k cases, 500 k chunks (NFR-04) | `case_index` is one row per case, not per chunk; HNSW over `case_chunk` only; `embedding_version` keeps a single index hot during a migration |
| ≤ 1 s p95 over 100 k chunks (NFR-01) | candidate generation bounded by `top_k` on each leg, fusion bounded by `rerank_depth = 30`, the ACL predicate pushed into both CTEs |
| ≥ 500 documents/h (NFR-03) | a queue per stage; OCR isolated so scans never block text |

Views: `v_case_card` (a flagged field is NULL here, not stale), `v_review_queue`, `v_curation_queue` (with its age), `v_recurring_problem`, `v_action_effectiveness`, `v_knowledge_gap`, `v_coverage`, `v_eval_gate`, `v_embedding_status`, `v_ingest_health`.

---

## 7. Roles and grants (section 19)

| Role | Rights |
|---|---|
| `app_rw` | full `memory`; insert/update on `knowledge`; insert/select on `audit`; **no write** on `knowledge.glossary_term` or `tm_segment` |
| `worker_rw` | the ingestion, structuring, indexing and retrieval tables; **no** `verification`, **no** `merge_event`, **no** GenbaGo tables |
| `app_ro` | select on `core`, `quality`, `knowledge`, `memory` |
| `auditor_ro` | the same plus `audit` |

No role anywhere is granted `UPDATE` or `DELETE` on `audit.log` or `audit.auth_event`.

---

## 8. Platform mode

Apply sections 10–19 only, as migration `memory_0001`. `core`, `quality`, `knowledge` and `audit` already exist. The `ALTER TABLE … ADD COLUMN IF NOT EXISTS` on `knowledge.chunk` and the conditional creation of `trg_chunk_injection_flag` make the order of `copilot_0001` and `memory_0001` irrelevant. Roles are the platform's; `worker_rw` and `auditor_ro` are added.

---

## 9. The demo seed

`db/seed_demo.sql` reproduces SRS Appendix A and AC-01…AC-09 **through the real functions and triggers**. Every computed literal in it was produced by the Python twins and is re-derived from the file by TEST-15 TC-005 (`ALL SEED CHECKS OK`).

| What | Detail |
|---|---|
| People | Somchai (technician), Pranee (quality engineer), Anan (maintenance planner), Nok (new employee, viewer), Suda (curator), an admin |
| Documents | 16, including the scanned Japanese 8D with four OCR regions (one handwritten at 0.706 → low confidence), its DOCX near-duplicate at 0.941, a **restricted** customer complaint, a chat export that tries to give the system instructions, and two ingest failures with actionable reasons |
| Cases | 13 records: #96, #178, #275, #331, #418, #506, #602, #655, #688, #710, #722, #733 and the duplicate #419 that a curator merged into #418 (its document moved, nothing was deleted) |
| Fields | 41 `case_field` rows with per-field confidence and provenance; three below 0.70 and therefore in the curation queue |
| Index | 12 indexed cases, 509 terms, `avg_len` 72.5 |
| Appendix A | the table in §4.2, plus the same query under the `verified_only` default (#331 gone, #655 third at 0.598) |
| AC-05 | the same complaint query as an engineer (2 rows, 1 ACL-filtered) and as a curator (3 rows) |
| AC-04 / AC-07 | quality case QC-2026-0912 opens 2026-09-21 → suggestion in 1,912 ms → recurrence of #418 at 0.870 after **25 months**, awaiting confirmation |
| AC-06 | Anan flags #710's cause as incorrect → the field is suppressed and queued |
| AC-09 | `bge-m3@2` registering, 24 of 48 chunks re-embedded, `search_available` true |
| AC-01 / AC-02 | a 12-document labelled set (0.875 narrative / 0.958 factual, passes) and a 12-query evaluation set — run A 0.833 / 0.632 passes, run B 0.667 / 0.413 fails and is marked `investigate` |
| Probes | **16**, each in its own transaction, each must raise |

The SRS asks for a 100-document labelled set and a 50-query evaluation set. Those are plant assets; the seed carries a 12 and a 12 and says so here, in the README and in TEST-15 §5.

### 9.1 The sixteen probes

| # | Attempt | Refused by |
|---|---|---|
| P-01 | change a document's `sha256` | `DOCUMENT_IMMUTABLE` |
| P-02 | ingest the same `sha256` twice | `document_sha256_key` |
| P-03 | a machine-written field with no extraction | `EXTRACTION_REQUIRED` |
| P-04 | a machine-written field with no provenance | `PROVENANCE_REQUIRED` |
| P-05 | verification by an engineer | `VERIFY_NEEDS_CURATOR` |
| P-06 | verify a case that has no source document | `SOURCE_REQUIRED` |
| P-07 | verify a case that still has a flagged field | `FLAGGED_FIELD_PRESENT` |
| P-08 | un-flag a suppressed field without a curator | `UNFLAG_NEEDS_CURATOR` |
| P-09 | claim an unmapped entity as canonical | `ENTITY_NOT_MAPPED` |
| P-10 | confirm a recurrence as a viewer | `CONFIRM_NEEDS_ENGINEER` |
| P-11 | index a case more permissively than its source | `ACL_WEAKER_THAN_SOURCE` |
| P-12 | store a vector with no model version | `EMBEDDING_VERSION_REQUIRED` |
| P-13 | retire a version a running re-embed serves | `VERSION_IN_USE` |
| P-14 | mark a failing evaluation run as passed | `EVAL_GATE` |
| P-15 | break the ranking weights | `RANK_WEIGHTS_SUM` |
| P-16 | delete a verification | `APPEND_ONLY` |

---

## 10. Traceability

| SRS | Database |
|---|---|
| C-01, FR-05, AC-08 | `knowledge.case_source`, DD-H01, DD-H05, `case_field.provenance_json` |
| C-02, C-03, FR-13, FR-28 | `case_field`, `extraction`, `verification`, `v_citable_case`, DD-H03, DD-H05, DD-H06 |
| C-04, NFR-06 | no external endpoint anywhere in the schema or the config |
| C-05, NFR-05, AC-05 | `acl_visible()`, `case_acl()`, DD-H09, `query_log.n_acl_filtered` |
| FR-01…FR-07 | `source`, `ingest_job`, `ingest_error`, `doc_text`, `ocr_*`, `near_duplicate`, DD-H02 |
| FR-08…FR-14 | `doc_class_rule`, `classify_document()`, `extraction`, `case_field`, `symptom_descriptor`, `case_entity` |
| FR-10 | `entity_map`, `normalise_entity()`, DD-H07 |
| FR-15…FR-19 | `tokenize`, `bm25_score`, `rrf`, `entity_overlap`, `recency_weight`, `outcome_weight`, `final_score`, `why_matched`, `rank_query` |
| FR-20…FR-22 | `suggestion`, `recurrence`, `recurrence_check()`, DD-H08, `scope` vs `require` |
| FR-23…FR-26 | `top_recurring`, `action_effectiveness`, `mtbr`, `knowledge_gaps`, the analytics views |
| FR-27…FR-31 | `curation_item`, `feedback`, `verification`, `coverage_metrics()`, DD-H04 |
| AI-01, NFR-08 | `extraction`, DD-H03 |
| AI-02, AI-04, AC-01, AC-02 | `label_*`, `eval_*`, `eval_finalize()`, `trg_eval_gate` |
| AI-05 | `rerank_depth`, `query_candidate.rerank_sim` |
| AI-06, AC-07 | `recurrence_threshold`, DD-H08 |
| AI-07 | `v_citable_case`, DD-H05 |
| AI-08 | `injection_scan()`, DD-H10 |
| AI-09, AC-09 | `embedding_model`, `reembed_job`, DD-H10 |
| NFR-01…NFR-04 | §6 sizing and indexes |
| NFR-07 | `ingest_job` / `ingest_error` as rows |
| NFR-09 | `case_index.lang`, the original-language text in the index |
