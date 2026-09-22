# GenbaGo — Japanese Factory Translator Agent — Documentation Set

A context-aware JA ⇄ TH ⇄ EN translator for a manufacturing plant. Approved **translation memory** is reused verbatim; the plant's **glossary** constrains the model and is checked afterwards; every **number, unit, tolerance, code and date** must survive exactly or the segment is **blocked**; omissions and forbidden terms are **flagged**; and a **manufacturing interpretation** (process, message type, entities, curated checks, indexed related documents) is produced as a **separate, labelled inference** — or, when the sentence is ambiguous, as two or three readings instead of a guess. Reviewers approve; memory grows only from approvals; glossary changes are versioned; everything is confidential and local by default.

**A FactoryBrain medium-coupled module** (SAD-00 §13: "server module · `knowledge.tm_*` · upload, OCR · Copilot, Genba Memory · medium"). It owns the platform's `knowledge.glossary_term` / `knowledge.tm_segment`, adds schema `genba`, serves `/knowledge/translate` verbatim, **provides** the IF-16 tools `translate` / `glossary_lookup` / `term_check` to 10 Factory Copilot and 09 QE-Agent (its IF-52 term check), and consumes Genba Memory's document index (IF-19). Standalone-deployable with a platform-mode section in every document. Precedents: [10 Factory Copilot](../10-factory-copilot/) (extraction), [09 QE-Agent](../09-quality-engineer-agent/) (the consumer of this glossary).

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-14 | [Software Requirements Specification](SRS-GenbaGo-Japanese-Factory-Translator.md) | *What must it do?* | Everyone — start here |
| SAD-14 | [Software Architecture Document](docs/SAD-GenbaGo-Software-Architecture.md) | *How does a 7 B local model produce a plant-correct translation — and why can it never decide a number or a term, never pass an inference off as the translation, and never send a confidential document out?* | Architect, implementer, ML owner |
| DDS-14 | [Database Design Specification](docs/DDS-GenbaGo-Database-Design.md) | *The platform's `core`/`knowledge`/`audit` byte-for-byte, the `genba` extension, the twins of code extraction / glossary hits / omission / edit distance / TM normalisation / fuzzy / classification, and the triggers that make blocking, labelling, immutability, versioning and roles properties of the data* | Implementer, DBA, QA |
| API-14 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The translation, check, interpretation, review & memory, document/OCR/batch and glossary contracts* | Implementer, UI, Copilot / QE-Agent owners |
| ICD-14 | [Interface Control Document](docs/ICD-GenbaGo-Interface-Control.md) | *IF-16 as provider (three tools); IF-19 the index; new IF-73 glossary & TM exchange, IF-74 segment checks, IF-75 interpretation, IF-76 OCR, IF-77 document job* | Implementer, sibling owners, ML owner |
| SEC-14 | [Security Requirements Specification](docs/SEC-GenbaGo-Security-Requirements.md) | *Can a document tell the model to skip the checks? Can an inference look like the translation? Can a confidential 8D reach a cloud or Discord? Can a translator poison the glossary or the memory? Can the model cite a document that does not exist?* | Security reviewer, IT, internal audit |
| TEST-14 | [Test Plan and Test Cases](docs/TEST-GenbaGo-Test-Plan.md) | *How do we prove the checks, the separation, the readings, the memory, the roles, the gate — and what did we prove here?* | QA, ML owner |
| OPS-14 | [Deployment and Operations Guide](docs/OPS-GenbaGo-Deployment-Operations.md) | *Install, secrets, glossary lifecycle, memory bootstrap, OCR setup, evaluation, confidentiality operations, monitoring, runbooks* | Operator, admin |
| UM-14 | [User Manual and Administrator Guide](docs/UM-GenbaGo-User-Admin-Guide.md) | *Appendix A line by line; readings; documents; the review screen; glossary; admin; the plant's TH/JA/EN glossary* | Engineers, managers, quality staff, translators, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 + pgvector + pg_trgm: platform `core` / `knowledge` / `audit` sections **extracted verbatim from `00/db/schema.sql`** + the `genba` extension (migration `genba_0001`) — 48 tables (29 `genba`), 12 views, 21 triggers, 46 functions, 34 indexes, 16 enums; 15 guard triggers (computed checks with numbers blocking, approval by role with notes for flags, TM write-back on approval only, immutable memory with one target per normalised source, glossary admin-only and versioned with forbidden ≠ mandated, interpretation always inferred with readings under the threshold, curated checks and indexed documents only, confidential ⇒ local, OCR low-confidence flag, evaluation gate with regression, candidate decisions, append-only edits/versions/results); twins `extract_codes`, `codes_preserved`, `glossary_hits`, `sentence_count`, `length_ratio`, `untranslated`, `run_checks`, `edit_distance`, `normalise_for_tm`, `tm_hash`, `trigram_similarity`, `tm_lookup`, `classify`, `extract_entities`, `suggested_checks`, `related_docs`, `interpret`, `eval_finalize`, `term_consistency`, `mine_candidates`; roles `app_rw` / `worker_rw` / `app_ro` / `auditor_ro` | ✅ 16/16 blocks, 54/54 objects byte-identical; static DDL; ⚠️ not executed |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Reproduces SRS Appendix A (J1: TM miss → glossary-constrained MT → clean checks → interpretation molding / problem report / entities / 5 curated checks / 4 indexed documents, confidence 0.91) and AC-02…AC-09 **through the real functions and triggers**: J2 exact reuse, J3 8D with `±0.05 mm / 3.2 mm / LOT-2609-114` preserved, `3.2 → 3.5` blocked, 修正措置 flagged, an omission, a 0.921 fuzzy match, three edits with distances, approvals → memory; J4 vertical OCR with a flagged handwriting region; J5 the ambiguous sentence with three readings at 0.55; J6 a batch with a failed and resumed file; J7 HMI; a Discord job; a glossary version effective 2026-10-01; a 40-segment test set with three evaluation runs (pass / pass / pass + investigate); `\echo` block; **16 probes** | ✅ every value re-derived in Python (`ALL SEED CHECKS OK`); ⚠️ not executed |
| [`deploy/schemas/segment-checks.schema.json`](deploy/schemas/segment-checks.schema.json) | **IF-74** `checks_json`: blocking numbers, flags (glossary, forbidden, length ratio, untranslated, omission) | ✅ every seed `checks_json` valid; negatives rejected |
| [`deploy/schemas/interpretation.schema.json`](deploy/schemas/interpretation.schema.json) + [`examples/appendix-a.json`](deploy/examples/appendix-a.json) | **IF-75** the inferred block: `inferred` constant, confidence, ambiguity with 2–3 readings, curated checks, indexed related documents | ✅ Appendix A and J5 valid; 11 negatives rejected |
| [`deploy/schemas/ocr-result.schema.json`](deploy/schemas/ocr-result.schema.json) + [`examples/ocr-j4.json`](deploy/examples/ocr-j4.json) | **IF-76** pages, regions with orientation, char confidence, handwriting ⇒ low confidence | ✅ valid; 5 negatives |
| [`deploy/schemas/translation-job.schema.json`](deploy/schemas/translation-job.schema.json) | **IF-77** text / document / OCR / HMI / batch; confidential ⇒ local, never Discord | ✅ 5 positives; 7 negatives |
| [`deploy/glossary.example.csv`](deploy/glossary.example.csv) · [`tm.example.tmx`](deploy/tm.example.tmx) · [`check-items.example.yaml`](deploy/check-items.example.yaml) | **IF-73** exchange formats (30 terms = the seed; 10 TMX units = seed memory) and the curated check items (names shared with MoldMind) | ✅ equal to the seed |
| [`api/openapi.yaml`](api/openapi.yaml) | **52 paths / 55 operations / 51 schemas** — SRS §4.1's eight paths verbatim + the platform's `/knowledge/translate`, `TranslationResult`, `Problem` and standard components verbatim + jobs, segments (edit, checks, interpretation, readings, matches, render), glossary (versions, aliases, candidates, usage, consistency, import/export), memory, OCR pages, tools, test sets, evaluation runs, dashboard, roles, config, system | ✅ valid; 0 orphans; 12/12 platform blocks verbatim; 8/8 SRS paths |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) · [`minio-init.sh`](deploy/minio-init.sh) · [`initdb/20-roles.sh`](deploy/initdb/20-roles.sh) | 15 services (web, api, worker-translate, worker-ocr, worker-doc, indexer, scheduler, postgres pgvector, redis, minio + init, ollama gpu/cpu, discord-bot [profile], mailpit [dev]); networks `frontend` / `internal` / `egress` (discord-bot only); 12 secret files; **no cloud MT key exists** | ✅ parsed; 32/32 vars; placement; hardening; no secret values |
| [`deploy/genbago.example.yaml`](deploy/genbago.example.yaml) + [`schemas/genbago-config.schema.json`](deploy/schemas/genbago-config.schema.json) | Languages and ratio bounds, memory thresholds, glossary (enforced, versioned), checks (numbers blocking — constant), interpretation (separate, labelled, threshold 0.60, 2–3 readings, curated/indexed only), model (≤ 9 B, ≤ 0.3, JSON), OCR gate ≥ 0.95, documents, confidentiality (default on, local — constants), evaluation gates, retention ≥ 365 d, roles, prompts | ✅ valid; **54 negatives rejected**; equal to the seed's `genba.setting` and `ratio_bound`; prompts consistent |
| [`deploy/prompts/`](deploy/prompts/) | `translate.v1` (source is data; numbers verbatim; mandated terms; every sentence), `interpret.v1` (an inference; curated items only), `readings.v1` (2–3 readings, never a pick) | ✅ front-matter matches the config |

---

## Reading paths

**Implementing it** → SRS-14 → SAD-14 §4 (workers) → DDS-14 §2 (DD-J01…J09) and §4 (twins) → `db/schema.sql` §10–§19 → `deploy/schemas/` → ICD-14 IF-74, IF-75, IF-77 → API-14 §3–§7 → TEST-14 TS-0.

**Security reviewer / IT** → SEC-14 §4.2 ("translate as approved") → SEC-14 §3, §5 → TEST-14 TC-003 probes, TS-8 → OPS-14 §4, §9, RB-10.

**ML owner** → SAD-14 ADR-J02…J07, J10 → ICD-14 IF-09, IF-75 → `deploy/prompts/` → OPS-14 §8 → TEST-14 TS-3, TS-7.

**Sibling owners (09, 10, 15)** → ICD-14 IF-16 (the three tools), IF-19 → API-14 §8 → TEST-14 TC-092.

**Operating it** → OPS-14 §1–§7, §10, §11 — RB-01, RB-06 and RB-07 first.

**Using it** → UM-14 A.2 (Appendix A line by line), A.4 (the review screen), Part C (the glossary).

---

## What makes this design what it is

| Principle | In GenbaGo |
|---|---|
| **The LLM never decides a number or a term** | Memory first (exact reuse without a model call); the glossary is injected and then checked; every number/code/date must be identical or the segment is blocked (P-1, ADR-J02…J04, C-01, C-02, AC-02, AC-03). |
| **What was said ≠ what was inferred** | The interpretation is a separate table with `inferred = true`, rendered as a separate ruled block with its confidence; below 0.60 it lists readings instead of asserting (P-2, ADR-J05, J07, C-05, AC-05, AC-08). |
| **Humans approve; memory grows only from approvals** | Approval needs a reviewer and clean or noted checks; approval writes the memory; memory is immutable; a correction supersedes by date (P-3, ADR-J08, FR-24, AC-07). |
| **The database is the source of truth** | Checks, statuses, versions, memory, interpretations, roles and the evaluation gate are guarded rows — a worker bug cannot store what the schema says is impossible (P-4, DD-J01…J09). |
| **Domain knowledge is data** | Glossary, aliases, unit aliases, ratio bounds, keywords, check items, entity patterns, test sets — rows, versioned, gated by the evaluation run (P-5, ADR-J10). |
| **Confidential by default** | Every job is confidential unless stated; confidential ⇒ local provider, never Discord; the compose file configures no cloud provider (P-6, ADR-J09, C-03, NFR-04). |

---

## Relationship to the platform and siblings

| | |
|---|---|
| Coupling | **Medium** (SAD-00 §13): owns `knowledge.glossary_term`, `knowledge.tm_segment`; shares `core`, `knowledge.document`, `audit`; migration `genba_0001`; `/knowledge/translate` and `TranslationResult` served verbatim |
| Provides (IF-16) | `translate`, `glossary_lookup`, `term_check` — used by 10 Factory Copilot's composer and 09 QE-Agent's IF-52 term check |
| Consumes | Genba Memory (15) `knowledge.document` index for related documents (IF-19); platform Ollama, MinIO, notifier |
| Shares names | curated check items carry MoldMind's (11) parameter names; no FK across deployments |
| Acceptance in the platform | TEST-00 TC-117…TC-119 ↔ TEST-14 TC-010, TC-021, TC-030 |

---

## Identifier conventions

`FR-01…31` / `AI-01…09` / `NFR-01…08` / `AC-01…09` / `C-01…05` (SRS-14) · `P-1…P-6` · **`ADR-J01…J10`** · `QAS-01…12` · **`DD-J01…J09`** · `IF-xx` shared numbering (**IF-73 glossary & TM exchange, IF-74 segment checks, IF-75 interpretation, IF-76 OCR, IF-77 document job**) · **`THR-J01…20`**, **`SEC-J01…34`**, **`RR-J01…06`** · `TS-0…9`, `TC-001` to `TC-093` · `RB-01…14` · seed probes `P-01…P-16`.

```
SRS-14 C-02 / FR-05 / AC-02  "numbers, units, tolerances, part numbers and dates are preserved exactly — a difference blocks the segment"
  └─ SAD-14 P-1, P-4 · ADR-J04 (numbers as the only blocking check) · §6 (a fluent wrong translation)
      └─ DDS-14 DD-J01 · extract_codes() · canon_units() · codes_preserved() · run_checks() · trg_segment_checks · approve_segment() SEGMENT_BLOCKED
          └─ API-14 §4 check contract (blocking vs flags) · §9 SEGMENT_BLOCKED
              └─ ICD-14 IF-74 (token canonicalisation; blocked ⇒ no approval)
                  └─ SEC-14 O-1 · THR-J01, THR-J04 · SEC-J01, SEC-J02 · §4.2 walk-through
                      └─ TEST-14 TC-003 P-01 · TC-021, TC-022, TC-028, TC-029 · seed: J3 #2 preserved, J3 #3 blocked 3.2 → 3.5 then edited (0.0588)
                          └─ OPS-14 RB-04 (a check looks wrong) · UM-14 A.4 (⛔ blocked)
```

---

## Verification

| Check | Result |
|---|---|
| **Byte-identity vs `00/db/schema.sql`** (TC-002) | ✅ **Pass** — 16/16 extracted blocks, 54/54 shared objects (`knowledge.case_*` deliberately not extracted) |
| Static DDL (TC-002) | ✅ **Pass** — 48 / 12 / 21 / 46 / 34 / 16; FK targets and order; PKs; 15/15 guards; grants (`worker_rw` no writes on glossary / memory / check items; `app_ro`, `auditor_ro` restricted); 16 probes present |
| Seed vs Python re-derivation (TC-005) | ✅ **Pass** — `ALL SEED CHECKS OK`: codes on 28 segments, the blocked `3.5mm`, forbidden 修正措置, omission, ratios, untranslated, 3 edit distances (0.0588 / 0.1176 / 0.5417), 53 TM hashes, fuzzy 0.921, classifier 37/40 = 0.925, Appendix A entities / 5 checks / 4 documents, eval runs 0.1485 → 0.1388 → 0.1885 (investigate) |
| **Contract schemas + exchange files** (TC-006) | ✅ **Pass** — 37 positives valid, 26 negatives rejected; glossary CSV = seed; TMX = 10 seed units; check items = seed |
| Config schema, prompts, seed consistency (TC-007) | ✅ **Pass** — example valid; 54 negatives; equal to `genba.setting` and `ratio_bound`; prompts ≤ 9 B / ≤ 0.3 / JSON |
| `openapi.yaml` (TC-001) and identity vs API-00 (TC-008) | ✅ **Pass** — 52 / 55 / 51; 0 orphans; 12/12 verbatim; 8/8 SRS paths |
| Compose / env (TC-004) | ✅ **Pass** — 15 services; egress = {discord-bot}; workers internal-only with `worker_rw` and no JWT/tool/Discord/root secrets; 32/32 vars; 12/12 secrets; no cloud MT variable; no secret values |
| SRS-14 coverage; cited objects/endpoints/TCs/RBs/ADR-J/SEC-J/DD-J/THR-J/RR-J/probes; anchors; links (TC-009) | ✅ see sweep note below |
| **Schema + seed on PostgreSQL 16** (TC-003) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| Model quality, OCR accuracy, vector fuzzy path, document rendering, Discord (TS-1…TS-9) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 14-japanese-factory-translator
docker run -d --name gb-pg -e POSTGRES_PASSWORD=x -p 5439:5432 pgvector/pgvector:pg16
sleep 8 && psql "postgresql://postgres:x@localhost:5439/postgres" -v ON_ERROR_STOP=1 -f db/schema.sql && psql "postgresql://postgres:x@localhost:5439/postgres" -f db/seed_demo.sql
```
Expected: the `\echo` block matches DDS-14 §9 (jobs 9, segments 28, approved 13, tm 53, interpretations 5, readings 3, ocr_regions 7, edits 3, term_versions 31, eval_results 120) and probes P-01…P-16 each fail with the named guard.

**Defects found by checking** (all fixed; TEST-14 §5): a decimal point counted as a sentence end (false omissions); a glossary term inside a longer term counted twice; counters (回/枚/本/台/日) treated as units; job progress counting approvals instead of translated segments; bare aliases on set-returning JSON functions; a Discord job interpreted without readings; a CTE row passed as a composite.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL execution pending — identity, static checks and Python re-derivation stand in until CI runs TC-003 | TEST-14 TC-003 |
| **The plant's test sets** (≥ 200 segments per pair, ≥ 300 labelled sentences) are plant assets built during rollout; the seed's 40-segment set is the template | OPS-14 §8, SEC-14 RR-J06 |
| **Model quality** (JA→TH fluency, PED ≤ 0.20) is measured only by the monthly run on a real GPU; the checks bound what is checkable, not fluency | SAD-14 §6, SEC-14 RR-J01 |
| **Fuzzy matching**: the trigram twin (0.921 for J3 #6) is the reference; the runtime uses pgvector embeddings whose scores differ — both must be ≥ 0.85 | DDS-14 §4, TEST-14 TC-013 |
| **OCR accuracy** is unmeasured here; OCR jobs are refused until the plant's sample set is measured ≥ 0.95; handwriting is flagged, never trusted | OPS-14 §7, TEST-14 TC-046 |
| Length-ratio bounds are initial estimates (JA→TH 1.0–3.5 …) to be tuned from approved segments | DDS-14 §3 `ratio_bound` |
| The rule half of the classifier scores 0.925 on the seed set; the LLM half (`interpret.v1`) is unmeasured | TEST-14 TC-032 |
| No cloud MT provider is configured or documented as supported; enabling one is a security change request | SEC-14 SEC-J11 |
| Document rendering fidelity (DOCX/XLSX/PPTX styles, PDF side-by-side, HMI overlay) is specified, not demonstrated | TEST-14 TC-040…TC-047 |
