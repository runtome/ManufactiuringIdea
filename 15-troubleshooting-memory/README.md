# Genba Memory — AI Production Troubleshooting Memory — Documentation Set

An institutional memory of factory problems. Every 8D, RCA note, maintenance log, work order, handover note, chat thread and complaint the plant has kept is ingested, OCR'd, deduplicated and structured by a local model into a **case** — symptom, investigation, cause, action, verification, outcome — with **per-field confidence and provenance**, normalised to canonical machines and lines, indexed lexically *and* by multilingual vectors, and retrieved by symptom in Thai, Japanese or English. When a new problem opens, precedent arrives without anyone searching; recurrence is detected with its elapsed interval; and a curation loop keeps the memory from turning into noise. The rule the whole design turns on: **a machine's reading of a document is not a fact until a person says so, and every answer names a document you can open.**

**A FactoryBrain tightly-coupled core module** (SAD-00 §13: "server module · `knowledge` · documents · `search_memory` tool · **tight (core)**"). It owns the platform's entire `knowledge` schema — while GenbaGo (14) owns the two translation tables inside it and Factory Copilot (10) owns one column of a third — adds schema `memory` (migration `memory_0001`), serves `/knowledge/search` and `/knowledge/documents` verbatim, provides `search_memory` / `get_case` / `similar_cases` / `recurrence_check` through IF-16 to 01, 02, 06, 09, 10 and 13, and takes over Copilot's IF-55 ingestion contract in platform mode. Standalone-deployable, with a platform-mode section in every document. Precedents: [10 Factory Copilot](../10-factory-copilot/) (extraction, IF-55), [14 GenbaGo](../14-japanese-factory-translator/) (the OCR contract and the glossary tables inside `knowledge`).

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-15 | [Software Requirements Specification](SRS-GenbaMemory-Troubleshooting-RAG.md) | *What must it do?* | Everyone — start here |
| SAD-15 | [Software Architecture Document](docs/SAD-GenbaMemory-Software-Architecture.md) | *How does a decade of messy documents become something a technician can trust — and why can it never quote a case without a source, pass an extraction off as a fact, or return a row the reader may not see?* | Architect, implementer, ML owner |
| DDS-15 | [Database Design Specification](docs/DDS-GenbaMemory-Database-Design.md) | *The platform's `knowledge` schema byte-for-byte, the `memory` extension, the twins of tokenisation / BM25 / RRF / scoring / ACL / recurrence / evaluation, and the triggers that make provenance, suppression, roles and the gates properties of the data* | Implementer, DBA, QA |
| API-15 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The ingestion, extraction, retrieval, suggestion, curation and evaluation contracts* | Implementer, UI, Copilot / QE-Agent owners |
| ICD-15 | [Interface Control Document](docs/ICD-GenbaMemory-Interface-Control.md) | *IF-16 as provider (four tools); IF-55 and IF-76 reused rather than re-invented; new IF-78 sources, IF-79 extraction, IF-80 entities, IF-81 retrieval, IF-82 recurrence, IF-83 curation, IF-84 embeddings* | Implementer, sibling owners |
| SEC-15 | [Security Requirements Specification](docs/SEC-GenbaMemory-Security-Requirements.md) | *Can a restricted complaint leak through a snippet, a count or an agent? Can a document instruct the system? Can someone verify their own guess? Can a wrong precedent outlive everyone who remembers it?* | Security reviewer, IT, internal audit |
| TEST-15 | [Test Plan and Test Cases](docs/TEST-GenbaMemory-Test-Plan.md) | *How do we prove the provenance, the badges, the ACL, the ranking, the recurrence and the gates — and what did we actually prove here?* | QA, ML owner |
| OPS-15 | [Deployment and Operations Guide](docs/OPS-GenbaMemory-Deployment-Operations.md) | *Install, secrets, the ingestion campaign, the curation loop, evaluation, re-embedding, threshold tuning, monitoring, runbooks* | Operator, admin |
| UM-15 | [User Manual and Administrator Guide](docs/UM-GenbaMemory-User-Admin-Guide.md) | *Appendix A line by line; what ✅ and ⚠ mean; feedback; the curation queue; manual entry; the dashboard to watch* | Technicians, engineers, planners, curators, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 + pgvector + pg_trgm: the platform's `core`, `quality.signal`/`case`, the **whole `knowledge` section** and `audit` **extracted verbatim from `00/db/schema.sql`**, plus the `memory` extension (migration `memory_0001`) — 64 tables (40 `memory`), 11 views, 35 triggers, 58 functions, 50 indexes, 15 enums; **26 guard triggers** (immutable originals, provenance-or-nothing, suppression by flag, citable-only-with-a-source-and-a-curator, append-only verification, unmapped entities to curation, computed and confirmed recurrence, ACL inheritance, embedding versions, the injection flag, the evaluation gate, weights that sum to one); **34 twins** — `normalise_text`, `detect_lang`, `tokenize`, `bm25_score`, `rrf`, `entity_overlap`, `recency_weight`, `outcome_weight`, `final_score`, `why_matched`, `rank_query`, `case_card`, `acl_visible`, `case_acl`, `recurrence_check`, `top_recurring`, `action_effectiveness`, `mtbr`, `knowledge_gaps`, `coverage_metrics`, `recall_at_k`, `mrr`, `extraction_accuracy`, `eval_finalize` …; roles `app_rw` / `worker_rw` / `app_ro` / `auditor_ro` | ✅ **14/14 blocks, 58/58 objects byte-identical**; static DDL; ⚠️ not executed |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Reproduces SRS Appendix A and AC-01…AC-09 **through the real functions and triggers**: 16 documents (a scanned Japanese 8D with a handwritten region at 0.706, its DOCX near-duplicate at 0.941, a restricted complaint, a chat export that tries to give instructions, two ingest failures with actionable reasons), 13 cases, 41 fields with confidence and provenance, a 12-case index with 509 terms, the Appendix A query at **0.870 / 0.740 / 0.610**, the same query under the verified-only default, the AC-05 pair (engineer 2 rows + 1 filtered, curator 3 rows), the 2026-09-21 case with a **25-month** recurrence awaiting confirmation, a flagged cause, a half-finished re-embed, three evaluation runs; **16 probes** | ✅ every computed value re-derived from the file (`ALL SEED CHECKS OK`); ⚠️ not executed |
| [`deploy/schemas/case-extract.schema.json`](deploy/schemas/case-extract.schema.json) + [`examples/case-418.json`](deploy/examples/case-418.json) | **IF-79** — a field cannot exist without provenance, confidence and its extraction; an extraction cannot claim verification | ✅ valid; 12 negatives rejected |
| [`deploy/schemas/retrieval-result.schema.json`](deploy/schemas/retrieval-result.schema.json) + [`examples/appendix-a.json`](deploy/examples/appendix-a.json) | **IF-81** — every hit has one case id, ≥ 1 source, a badge, its component scores and `why`; `n_acl_filtered` is a count | ✅ valid; 12 negatives |
| [`deploy/schemas/recurrence-alert.schema.json`](deploy/schemas/recurrence-alert.schema.json) + [`examples/recurrence-418.json`](deploy/examples/recurrence-418.json) | **IF-82** — a computed interval, and nothing counted before a human confirms it | ✅ valid; 8 negatives |
| [`deploy/schemas/source-connector.schema.json`](deploy/schemas/source-connector.schema.json) | **IF-78** — credentials only as `file:/run/secrets/…`; the source's ACL travels with what it ingests | ✅ 2 positives; 7 negatives |
| [`deploy/entity-map.example.csv`](deploy/entity-map.example.csv) · [`eval-set.example.yaml`](deploy/eval-set.example.yaml) | **IF-80** exchange format and the 12-query evaluation set, four of them cross-language | ✅ equal to the seed |
| [`api/openapi.yaml`](api/openapi.yaml) | **47 paths / 53 operations / 46 schemas** — the seven SRS §4.1 paths verbatim + API-00's `/knowledge/search`, `/knowledge/documents`, `Problem`, `Language`, `KnowledgeHit`, the parameters and the seven standard responses verbatim + sources, ingestion, documents, cases and fields, search and explain, similar and recurrence, analytics, curation, feedback, entity maps, evaluation, embeddings, tools, config, roles, health | ✅ valid; 0 orphans; 158 refs; **12/12 platform blocks verbatim**; **7/7 SRS paths** |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) · [`minio-init.sh`](deploy/minio-init.sh) · [`initdb/20-roles.sh`](deploy/initdb/20-roles.sh) | 17 services (web, api, worker-ingest / -ocr / -extract, normaliser, indexer, retriever, scheduler, postgres pgvector, redis, minio + init, ollama gpu/cpu, discord-bot [profile], mailpit [dev]); networks `frontend` / `internal` / `egress` (discord-bot only); 16 secret files; the originals bucket under **object lock**; **no external model, embedding or translation endpoint exists** | ✅ parsed; 34/34 vars; 16/16 secrets; placement; hardening; no secret values |
| [`deploy/genbamemory.example.yaml`](deploy/genbamemory.example.yaml) + [`schemas/genbamemory-config.schema.json`](deploy/schemas/genbamemory-config.schema.json) | Languages, ingestion and OCR, extraction (schema-constrained, provenance, ≤ 9 B, ≤ 0.3), retrieval (BM25 constants, RRF k, rerank depth 30, the five weights, verified-only, ACL as a predicate), recurrence, curation, the four gates, embeddings (1024, live re-embed), confidentiality, retention, roles | ✅ valid; **65 negatives rejected**; equal to `memory.setting` and `memory.rank_weight` |
| [`deploy/prompts/`](deploy/prompts/) | `extract-case.v1` (the document is data; never invent a cause; never claim verification), `classify-document.v1` (`other` is a correct answer), `rerank.v1` (symptom similarity only, and why it is not the default) | ✅ front-matter and rules match the configuration |

---

## Reading paths

- **"Show me it working."** SRS Appendix A → [UM-15 §A.2](docs/UM-GenbaMemory-User-Admin-Guide.md) (the same output, line by line) → [DDS-15 §4.2](docs/DDS-GenbaMemory-Database-Design.md) (the arithmetic behind the three numbers).
- **Implementer.** SAD-15 §2, §4 → DDS-15 §3–§5 → API-15 → ICD-15 IF-78…IF-84.
- **Security reviewer.** SEC-15 §3 and §4.2 → DDS-15 §5 → TEST-15 TS-6.
- **Operator.** OPS-15 §1–§5 → §7 the curation loop → §12 runbooks → §13 verification.
- **A sibling module owner.** ICD-15 IF-16 and IF-19 → API-15 §12.

---

## The six principles

| ID | Principle | Where it is enforced |
|---|---|---|
| **P-1** | The source document is the truth; the structure is an index into it | `case_source`, `trg_document_immutable`, object lock, provenance on every field |
| **P-2** | Extracted ≠ verified — and the difference is visible and ranked | `badge`, `verified_only` default, `v_citable_case`, `trg_case_citable` |
| **P-3** | No case is invented | one `case_id` per hit, ≥ 1 source, no shape for a combined case |
| **P-4** | The ACL is a predicate inside the query, not a filter after it | `acl_visible()` in the CTEs, `trg_acl_inherit`, `n_acl_filtered` |
| **P-5** | Memory improves by curation and feedback, not by accumulation | the curation queue as the only path into fact; feedback is not a live weight |
| **P-6** | Document content is data, never instructions | `injection_scan()`, `excluded[]`, the prompts' first rule |

---

## Relationship to the platform and its siblings

| Module | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | **Tight (core)** — owns the whole `knowledge` schema. Sections 1–9 of `db/schema.sql` are extracted byte-identically; the extension applies as `memory_0001`. Serves `/knowledge/search` and `/knowledge/documents` verbatim. |
| [14 GenbaGo](../14-japanese-factory-translator/) | Owns `knowledge.glossary_term` and `knowledge.tm_segment` **inside this schema** — read-only here, and the grants say so. Defines the OCR contract (IF-76) this module stores rather than re-inventing, and translates snippets for the TH/JA/EN UI (NFR-09). |
| [10 Factory Copilot](../10-factory-copilot/) | Owns `knowledge.chunk.suspicious`; defines IF-55, which Genba Memory **serves** in platform mode. Consumes `search_memory` and the document store. |
| [09 QE-Agent](../09-quality-engineer-agent/) | Publishes closed cases here as the archive; consumes precedent for hypotheses. An opened `quality.case` is what fires a suggestion. |
| [06 MachineSense](../06-predictive-maintenance-agent/) | `search_memory` is its "similar past case" (its FR-24); its alerts enrich the same way a quality case does. |
| [13 KaizenSwarm](../13-multi-agent-factory/) · [01](../01-factory-inspector-agent/) · [02](../02-production-ai-analyst/) | Call `search_memory` through the tool registry; 01's approved narratives become precedent. |

---

## Identifier conventions

Shared with the platform set: `FR-` / `NFR-` / `AI-` / `AC-` / `C-` (SRS-15) · `P-1…P-6` · **`ADR-H01…H10`** · `QAS-01…12` · **`DD-H01…H10`** · `IF-xx` (**numbering shared with ICD-00**; IF-78…IF-84 new) · **`THR-H`/`SEC-H`/`RR-H`** · `TS-`/`TC-` · `RB-01…14` · `P-01…P-16` (the seed's probes).

One requirement, traced end to end:

```
SRS-15 C-05  "Access control SHALL follow the source document's ACL;
              retrieval must not leak restricted content."
   └─ SAD-15 P-4, ADR-H06     the ACL is a predicate inside the query
        └─ DDS-15 DD-H09       acl_visible(), case_acl(), trg_acl_inherit
             └─ IF-81           n_acl_filtered is required, and it is a count
                  └─ API-15 §2  404 for "exists but not visible"
                       └─ SEC-15 O-1, SEC-H01…H07, THR-H02…H05
                            └─ TEST-15 TC-071 (the automated ACL test), probe P-11
                                 └─ seed: engineer 2 rows + 1 filtered · curator 3 rows
```

---

## Verification

Everything below ran on the authoring machine on 2026-09-22 (Python 3.14, PyYAML, jsonschema 4.26). Nothing else is claimed.

| Check | Result |
|---|---|
| Platform identity — `db/schema.sql` vs `00/db/schema.sql` | ✅ **14/14 blocks, 58/58 objects byte-identical** |
| Static DDL, guards, grants | ✅ balanced, FK order, 26 guards, `worker_rw` denied verification / merges / GenbaGo's tables |
| Seed twins re-derived **from the file** — tokenisation, BM25, RRF, recency, outcome, final score, ACL, intervals, Recall@5 / MRR, extraction accuracy | ✅ `ALL SEED CHECKS OK` (42 assertions); Appendix A reproduces **0.870 / 0.740 / 0.610** and **25 months** exactly |
| Contract schemas IF-78…IF-82 + the exchange files | ✅ **7 positives / 40 negatives** |
| OpenAPI + API-00 identity | ✅ 47 paths / 53 ops / 46 schemas; 0 orphans; 12/12 blocks; 7/7 SRS paths |
| Configuration schema, example and prompts | ✅ **65 negatives rejected**; every shared value equals `memory.setting`; weights equal `memory.rank_weight` and sum to 1.000 |
| Compose, env, secrets, networks | ✅ 17 services; 34/34 vars; 16/16 secrets; `egress` = `discord-bot`; no secret-looking value anywhere |
| Cross-document sweep | ✅ links, anchors, identifiers, object names, endpoints, TCs, RBs, probes |
| **PostgreSQL** | ⚠️ **never executed** — no server and no Docker daemon here. The schema, the seed and the 16 probes are specified, not run. OPS-15 §13 is the command set that runs them. |

### Defects found and fixed while writing this set

Seven, listed in [TEST-15 §13](docs/TEST-GenbaMemory-Test-Plan.md#13-defects-found-and-fixed-while-writing-this-set). The one worth repeating: the first seed indexed only the extraction's English text, which made AC-03 ("a Thai query finds a Japanese 8D") a claim rather than a demonstration. Adding the source document's own language to the index made #418's BM25 score fall to **sixth of seven** — and it still ranks first. That is the honest version of the requirement, and it is now what the seed shows.

---

## Known gaps

| Gap | Why | What closes it |
|---|---|---|
| PostgreSQL never executed | no server, no Docker daemon on the authoring machine | OPS-15 §13 on a real instance: 16 probe errors and the expectations above |
| Embeddings and the cross-encoder never run | no model runtime here | the vector ranks and similarities in the seed are **data**, and every document says so; the twins cover everything downstream of them |
| The 100-document labelled set and the 50-query evaluation set | plant assets, not demo data | the seed ships 12 and 12; OPS-15 §8 describes building the real ones |
| OCR accuracy unmeasured | no scans of this plant's documents | `ingestion.ocr.measured_accuracy` is `null` on purpose |
| NFR-01 latency, NFR-03 throughput, NFR-04 scale | need the stack and volume | TC-018, TC-045, TC-082, TC-084 |
| Discord delivery | needs a workspace | TC-090 |
| A *verified* case can still be wrong | nothing detects this automatically | SAD-15 §6 — accepted, and mitigated by badging, the citable-case view, coverage metrics and contradicting recurrences |

---

*30 files · 10,331 lines, excluding the pre-existing SRS.*
