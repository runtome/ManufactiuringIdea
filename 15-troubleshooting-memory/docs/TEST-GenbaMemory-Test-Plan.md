# Test Plan and Test Cases — Genba Memory

| Field | Value |
|---|---|
| Document ID | TEST-15-GenbaMemory |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-15](../SRS-GenbaMemory-Troubleshooting-RAG.md) · [SAD-15](SAD-GenbaMemory-Software-Architecture.md) · [DDS-15](DDS-GenbaMemory-Database-Design.md) |
| Related | [API-15](../api/API-Specification.md) · [ICD-15](ICD-GenbaMemory-Interface-Control.md) · [SEC-15](SEC-GenbaMemory-Security-Requirements.md) · [OPS-15](OPS-GenbaMemory-Deployment-Operations.md) |

---

## 1. Scope and method

Ten suites. **TS-0 ran on the authoring machine** and its results are in §2 with their numbers. TS-1…TS-9 are specified against a running stack; they did not run here, because PostgreSQL, Docker, the models and the plant's own documents were not available (TC-009). §6 says exactly what was and was not executed — no test in this document is reported as passing unless it actually did.

Legend: **E** executed here · **S** specified, needs the stack · **M** manual · **P** performance.

Where a test says "expected", the expectation is a value the generator derived with the Python twins and the checker re-derived from the seed file itself, not a number anyone typed.

---

## 2. TS-0 — static verification (executed here)

| TC | What | Result |
|---|---|---|
| **TC-001** | `api/openapi.yaml` parses as OpenAPI 3.1.0; every `$ref` resolves; no orphan schema; no unused parameter or response; every `operationId` unique; the twelve API-00 blocks byte-identical; the seven SRS §4.1 paths present | ✅ **47 paths / 53 operations / 46 schemas**, 158 refs, 0 orphans, **12/12** blocks identical, **7/7** SRS paths — 22 assertions |
| **TC-002** | `db/schema.sql`: every extracted platform block and object diffed against `00/db/schema.sql`; parentheses and dollar quotes balanced; every FK target defined earlier; every trigger function defined; the guards and twins present; the grants | ✅ **14/14 blocks**, **58/58 objects** byte-identical; 64 tables (40 `memory`), 11 views, 35 triggers, 58 functions, 50 indexes, 15 enums; **26/26 guard triggers**, **34/34 twins**; `worker_rw` denied `verification`, `merge_event` and GenbaGo's two tables — 14 assertions |
| **TC-003** | The 16 probes in `db/seed_demo.sql` are each in their own transaction and run with `ON_ERROR_STOP off` | ✅ structure verified; **not executed** (no PostgreSQL) |
| **TC-004** | `deploy/docker-compose.yml` parses; hardening on all ten application services; ports bound to `${BIND_ADDR}`; `egress` = `discord-bot` only; workers internal-only; `internal` has no route out; every `${VAR}` in `.env.example` and every entry used; secrets defined = referenced and all file-based; per-service secret placement; no external endpoint; the originals bucket is object-locked; no secret-looking value anywhere | ✅ **17 services**, **34/34 vars**, **16/16 secrets** — 24 assertions |
| **TC-005** | Every computed value in the seed re-derived **from the file** with the twins: tokenisation, BM25 over `term_stat`, RRF, recency, outcome, the final score, the ACL outcomes, the recurrence intervals, Recall@5 / MRR, extraction accuracy | ✅ `ALL SEED CHECKS OK` — 42 assertions |
| **TC-006** | IF-78…IF-82 schemas accept the real payloads and refuse the wrong ones; the entity map and the evaluation set equal the seed | ✅ **7 positives / 40 negatives**, all as expected — 56 assertions |
| **TC-007** | `genbamemory.example.yaml` validates; every locked key refuses its alternatives; every shared value equals `memory.setting`; the five weights equal `memory.rank_weight` and sum to 1.000 | ✅ **65 negatives rejected**, 15 shared values equal, weights equal — 83 assertions |
| **TC-008** | The three prompts: front-matter within the model and temperature limits; the extraction prompt states that document text is data, forbids inventing a cause and forbids claiming verification; the reranker prompt scores symptom similarity only and says it is not the default | ✅ (included in TC-007's run) |
| **TC-009** | **Honest reporting**: what could not be executed | ✅ PostgreSQL, Docker, the models, OCR, the plant's documents — see §6 |
| **TC-010** | `injection_scan()` matches the seeded chat-export paragraph and the three language patterns | ✅ static; the chunk is seeded `suspicious` |
| **TC-011** | Every `\echo` expectation in the seed is a generated value, not a typed one | ✅ by construction; TC-005 re-derives each |
| **TC-012** | Cross-document sweep: links, anchors, identifiers, object names, endpoints, TC and RB references | ✅ see §7 |

### 2.1 What TC-005 actually proved

The three numbers SRS Appendix A states were reproduced exactly, from the seeded inputs, through the documented arithmetic:

| Case | BM25 | lex rank | vec rank | rerank sim | entity | recency | outcome | verified | **final** |
|---|---|---|---|---|---|---|---|---|---|
| #418 | 1.1323 | 6 | 1 | 0.8342 | 1.000 | 0.556 | 1.000 | ✅ | **0.870** |
| #602 | 12.6645 | 2 | 2 | 0.7815 | 0.333 | 0.694 | 0.700 | ✅ | **0.740** |
| #331 | 16.9755 | 1 | 5 | 0.7637 | 0.667 | 0.458 | 0.200 | ⚠ | **0.610** |

and the recurrence interval **25 months**, the evaluation metrics **0.833 / 0.632** (pass) and **0.667 / 0.413** (fail, `investigate`), and the extraction accuracies **0.875 / 0.958**.

---

## 3. TS-1 — ingestion (FR-01…FR-07, NFR-03, NFR-07)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-013 | Ingest PDF, DOCX, XLSX, PPTX, TXT, EML and a PNG | one `knowledge.document` each, state `done` | S |
| TC-014 | Ingest the same file twice | second job `skipped`, the same `document_id`, no second case | S |
| TC-015 | Ingest the 8D as PDF and as DOCX | `near_duplicate` 0.941, a curation item, **no automatic merge** | S |
| TC-016 | Language detection per document and per section | the seeded 12 cases come back `ja` / `th` / `en` as in `case_index.lang` | S |
| TC-017 | A password-protected archive and an unreadable scan | two `ingest_error` rows with `password_protected` / `unreadable_scan` and an `action` each | S |
| TC-018 | 600 text documents in a watched folder | ≥ 500 documents/hour excluding OCR (NFR-03) | P |
| TC-019 | A scanned vertical Japanese 8D | OCR regions with `orientation`, the handwritten one `low_confidence` (IF-76) | S |
| TC-020 | Kill `worker-extract` mid-batch | retrieval unaffected; the job is retried; **0 failed searches** (NFR-07) | S |
| TC-021 | An incremental sync where two files changed | two jobs queued, the rest `skipped` | S |
| TC-022 | A source with an inline credential | refused with `SOURCE_CREDENTIAL_INLINE` (IF-78) | S |

## 4. TS-2 — structuring (FR-08…FR-14, AI-01, AI-02, NFR-08, AC-01)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-023 | Classify the 16 seeded documents | the keyword rules decide 14; the model is called for 2; no class outside the enum | S |
| TC-024 | Extract case #418 from the Japanese 8D | the IF-79 example, field for field | S |
| TC-025 | Extraction output that fails the schema | rejected before any write; the job is `failed` with `extract_failed` | S |
| TC-026 | A document with no recorded cause (#331) | no `cause` field at all — **not** an invented one | S |
| TC-027 | Fields below 0.70 confidence | a `low_confidence` curation item each (3 in the seed) | S |
| TC-028 | Symptom descriptors | defect class, failure mode, alarm code and the 3.5 mm deviation of #688 | S |
| TC-029 | Ask any machine-written field where it came from | model, prompt version, schema version, document and page (NFR-08) | S |
| TC-030 | Entity normalisation | `M07`, `7号機`, `เครื่อง 7` → `M-07`; `CONV-2` unmapped with a curation item | S |
| TC-031 | Manual case entry (FR-14) | every field `human: true`; not verifiable until a source is attached | S |
| TC-032 | Extraction run over the labelled set | ≥ 0.85 narrative and ≥ 0.95 factual; the seeded run gives 0.875 / 0.958 (AC-01) | S |
| TC-033 | Extraction below the gate | `passed = false`; the model is not promoted | S |
| TC-034 | The same document extracted twice with the same prompt and seed | identical field values (reproducibility) | S |
| TC-035 | A document whose text tries to instruct the extractor | no field carries the instruction; `notes` mentions it | S |

## 5. TS-3 — retrieval (FR-15…FR-19, AI-03…AI-05, AI-07, NFR-01)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-036 | The Appendix A query | the three rows of §2.1, in that order, with those scores | S |
| TC-037 | The same query with `require: {machine: M-07}` | #602 disappears; scope and require behave differently | S |
| TC-038 | Structured filters: machine, line, SKU, defect class, dates, outcome | each narrows as documented | S |
| TC-039 | `why` on every hit | matched terms, entities and descriptors; nothing empty without cause | S |
| TC-040 | `verified_only` default | #331 absent unless asked for | S |
| TC-041 | `verified_only: false` | #331 present with `badge: extracted_not_verified` | S |
| TC-042 | A case with a flagged field | the field is `null` in the hit, never the old value (AC-06) | S |
| TC-043 | BM25 against a changed corpus | `term_stat` and `avg_len` update; scores move accordingly | S |
| TC-044 | **A Thai query for a Japanese 8D** | #418 in the top 5 with `lex_rank` worse than `rank` — the vector leg is what found it (AC-03) | S |
| TC-045 | 10 concurrent queries over 100 k chunks | ≤ 1 s p95 (NFR-01) | P |
| TC-046 | Change a ranking weight | the sum constraint refuses a set that does not total 1.000; stored scores keep their old weights; `search/explain` returns the new ones | S |
| TC-047 | Ask an agent tool for a "combined" precedent | impossible: every hit is one `case_id` with its own sources (AI-07) | S |
| TC-048 | A query matching a suspicious chunk | the chunk is in `excluded[]`, not in the evidence (AI-08) | S |
| TC-049 | `POST /search/explain` for #418 | the five components, the five weights and the arithmetic that gives 0.870 | S |

## 6. TS-4 — suggestion and recurrence (FR-20…FR-22, AI-06, NFR-02, AC-04, AC-07)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-050 | Open quality case QC-2026-0912 | a suggestion row, delivered, with #418 first (AC-04) | S |
| TC-051 | Open a MachineSense alert | the same path through IF-17 | S |
| TC-052 | Suggestion latency | ≤ 3 s (NFR-02); the seed records 1,912 ms | P |
| TC-053 | The recurrence proposal for #733 | score 0.870, interval **25 months**, unconfirmed (AC-07) | S |
| TC-054 | Try to supply `interval_months` | ignored and recomputed by `trg_recurrence_confirm` | S |
| TC-055 | An unconfirmed recurrence in the analytics | absent from `/analytics/recurring` (AI-06) | S |
| TC-056 | Confirm it as an engineer, then as a viewer | accepted, then refused with `CONFIRM_NEEDS_ENGINEER` | S |
| TC-057 | Horizontal deployment (FR-22) | a scope of `machine: M-07` still surfaces #602 on M-04 | S |

## 7. TS-5 — curation, verification and feedback (FR-27…FR-31, AC-06)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-058 | The curation queue after a fresh ingest | 7 items in the seed: 3 low confidence, 1 unmapped entity, 1 near-duplicate, 1 flagged field, 1 suspicious chunk | S |
| TC-059 | Queue age | items older than 72 h raise the metric and the mail | S |
| TC-060 | Verify a case as a curator, then as an engineer | accepted, then `VERIFY_NEEDS_CURATOR` | S |
| TC-061 | Verify a case with no source | `SOURCE_REQUIRED` | S |
| TC-062 | Verify a case with an open flag | `FLAGGED_FIELD_PRESENT` | S |
| TC-063 | Verified cases in the ranking | the verified boost applies; `v_citable_case` contains exactly them | S |
| TC-064 | Revoke a verification | a new append-only row; the case loses its badge; the old row survives | S |
| TC-065 | Add an entity mapping | affected cases re-normalise; `approved_by` recorded; the CSV export matches | S |
| TC-066 | Flag `#710.cause` as incorrect | suppressed from the card and the hit immediately; a curation item opens (AC-06) | S |
| TC-067 | Twenty `not_helpful` ratings on one case | **its ranking does not change** (ADR-H08); the evaluation set notices | S |
| TC-068 | Merge #419 into #418 | one `merge_event`, the source moved, both documents still present | S |
| TC-069 | Coverage after curation | `with_cause`, `with_verification` and `human_verified` move as expected (FR-31) | S |

## 8. TS-6 — security and access control (C-04, C-05, NFR-05, NFR-06, AC-05, SEC-H)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-070 | `GET /cases/{id}` for a restricted case as an engineer | `404`, indistinguishable from a case that does not exist (SEC-H05) | S |
| TC-071 | **The automated ACL test**: search the exact wording of the restricted complaint as every role | 0 rows and 0 snippets below `manager`; `n_acl_filtered: 1`; the curator sees it (AC-05) | S |
| TC-072 | Index a case more permissively than its source | `ACL_WEAKER_THAN_SOURCE` (probe P-11) | S |
| TC-073 | Analytics, counts and the retrieval log with a restricted case in range | no aggregate changes visibly; the log stores counts, never text (THR-H05, THR-H07) | S |
| TC-074 | Ingest a document containing an instruction paragraph | the chunk is `suspicious` with a reason; a curation item opens (AI-08) | S |
| TC-075 | A query whose best chunk is suspicious | it appears in `excluded[]` with `reason: suspicious`, not in the answer | S |

## 9. TS-7 — analytics and evaluation (FR-23…FR-26, AI-02, AI-04, AC-01, AC-02)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-076 | The monthly evaluation run | Recall@5 and MRR computed; `passed` derived, not asserted; below the gate it is `false` (AC-02) | S |
| TC-077 | `/analytics/recurring?scope=machine` | M-04 2 cases / 1 confirmed recurrence; M-07 4 cases / 0 while #733 is unconfirmed | S |
| TC-078 | `/analytics/effectiveness?defect_class=overload` | #602's checklist action shows `recurred: true`; #418's sensor replacement shows `false` | S |
| TC-079 | `/analytics/mtbr?defect_class=overload` | 5.0 months from the one confirmed link | S |
| TC-080 | `/analytics/gaps` | #331, #688, #710, #733 with what each is missing (FR-26) | S |
| TC-081 | `/analytics/coverage` | the three ratios over all case records, including the merged one | S |

## 10. TS-8 — embeddings and scale (AI-09, NFR-01, NFR-04, AC-09)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-082 | Load 50 k cases and 500 k chunks | search stays within TC-045's budget (NFR-04) | P |
| TC-083 | Re-embed with a restricted document in the corpus | the job never leaves the service network; the ACL is unaffected (THR-H17) | S |
| TC-084 | **Re-embed 50 k chunks while searching** | 0 failed searches; queries pinned to the active version until the switch (AC-09) | P |
| TC-085 | Retire the old version mid-job | `VERSION_IN_USE` | S |
| TC-086 | A chunk stored with a vector and no version | `EMBEDDING_VERSION_REQUIRED` | S |
| TC-087 | Switch the active version | one row; the next query uses the new index; `v_embedding_status` reflects it | S |

## 11. TS-9 — clients, tools and languages (NFR-09, IF-16, IF-08)

| TC | Test | Expected | Kind |
|---|---|---|---|
| TC-088 | `search_memory` called by Copilot on behalf of a viewer | the **viewer's** ACL applies, not the agent's (THR-H03) | S |
| TC-089 | The four tools registered in `agent.tool` | all four present, `kind: read`, `min_role: viewer` | S |
| TC-090 | A recurrence alert on Discord | title, score, interval and a link — **no snippet, no restricted record** (SEC-H21) | M |
| TC-091 | The UI in Thai, Japanese and English | labels translated; case text shown in its own language, with a GenbaGo snippet when enabled (NFR-09) | M |
| TC-092 | QE-Agent asks for precedent on an open case | the same rows the UI shows for the same user | S |
| TC-093 | MachineSense enriches an alert | `similar_cases` returns the maintenance cases for that machine | S |

---

## 12. Traceability

| SRS | Suites |
|---|---|
| C-01, FR-05, AC-08 | TS-0 (TC-002), TS-1, TS-2 (TC-029), TS-3 (TC-047) |
| C-02, C-03, FR-13, FR-28 | TS-2 (TC-027, TC-029), TS-3 (TC-040, TC-041), TS-5 |
| C-04, NFR-06 | TS-0 (TC-004, TC-007), TS-6 |
| C-05, NFR-05, AC-05 | TS-6 (TC-070…TC-073) |
| FR-01…FR-07, NFR-03, NFR-07 | TS-1 |
| FR-08…FR-14, AI-01, AI-02, NFR-08, AC-01 | TS-2, TS-7 (TC-076) |
| FR-15…FR-19, AI-03…AI-05, AI-07, NFR-01, AC-03 | TS-3 |
| FR-20…FR-22, AI-06, NFR-02, AC-04, AC-07 | TS-4 |
| FR-23…FR-26, FR-31 | TS-7 |
| FR-27…FR-31, AC-06 | TS-5 |
| AI-08 | TS-2 (TC-035), TS-6 (TC-074, TC-075) |
| AI-09, NFR-04, AC-09 | TS-8 |
| AI-04, AC-02 | TS-7 (TC-076), TS-0 (TC-005) |
| NFR-09 | TS-9 (TC-091) |

---

## 13. Defects found and fixed while writing this set

| # | Found by | Defect | Fix |
|---|---|---|---|
| D1 | TC-007 | The configuration schema's model pattern rejected `q4_K_M` (upper case in the tag) | the tag part widened to `[A-Za-z0-9._-]+` |
| D2 | TC-004 | `docker-compose.yml` failed to parse: `${SECRETS_DIR}` inside a flow mapping | the secret paths quoted |
| D3 | TC-001 | Three API-00 components were extracted but never referenced (`IdempotencyKey`, `Unauthorized`, `TooManyRequests`) | used where they belong — ingest replay, search auth and the search rate limit |
| D4 | TC-006 | The evaluation set had three cross-language queries, not the four AI-03 deserves | one query rewritten in Thai; the seed, the YAML and the checker regenerated together |
| D5 | TC-005 | The first seed indexed only the English extraction text, which made AC-03 a claim rather than a demonstration | the source document's own language was added to `case_index.indexed_text`, and #418's BM25 then fell to sixth — the honest result |
| D6 | review | SAD §4.3 described the final score as "rrf + entity + …", which is not what `rank_query()` does | corrected to the weighted rerank formula; RRF selects the candidates, it does not order them |
| D7 | TC-005 | The expected curation count in the seed was typed (5) rather than derived (7) | computed from the low-confidence fields plus the four trigger-opened items |

---

## 14. Execution record

| Date | What ran | Environment | Result |
|---|---|---|---|
| 2026-09-22 | TC-001 | Python 3.14, PyYAML | 47 paths / 53 operations / 46 schemas; 12/12 blocks; 7/7 SRS paths; 0 orphans |
| 2026-09-22 | TC-002 | Python 3.14 | 14/14 blocks, 58/58 objects; 26 guards; 34 twins; grants verified |
| 2026-09-22 | TC-004 | Python 3.14, PyYAML | 17 services; 34/34 vars; 16/16 secrets; egress = `discord-bot` |
| 2026-09-22 | TC-005 | Python 3.14 | `ALL SEED CHECKS OK` — 42 assertions, Appendix A reproduced exactly |
| 2026-09-22 | TC-006 | Python 3.14, jsonschema 4.26 | 7 positives / 40 negatives |
| 2026-09-22 | TC-007, TC-008 | Python 3.14, jsonschema 4.26 | 65 negatives rejected; config = database; prompts consistent |
| 2026-09-22 | TC-012 | Python 3.14 | sweep clean |
| — | TC-003 | — | **not executed** — no PostgreSQL |
| — | TC-013…TC-093 | — | **specified, not executed** |

**Not executable on the authoring machine, and therefore not claimed:** PostgreSQL (no server, no Docker daemon) — the schema, the seed and the 16 probes were never run; the embedding model and the cross-encoder — the vector ranks and similarities in the seed are data, not computed; OCR accuracy on real scans; the plant's own 100-document labelled set and 50-query evaluation set; ingestion throughput (NFR-03), search latency (NFR-01) and scale (NFR-04); Discord delivery. OPS-15 §12 lists the psql commands that run TC-003 and TC-005's expectations against a real database in one pass.
