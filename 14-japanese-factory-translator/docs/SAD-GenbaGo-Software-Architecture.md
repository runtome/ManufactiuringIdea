# Software Architecture Document — GenbaGo (Japanese Factory Translator Agent)

| Field | Value |
|---|---|
| Document ID | SAD-14-GenbaGo |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-14](../SRS-GenbaGo-Japanese-Factory-Translator.md) |
| Related | [DDS-14](DDS-GenbaGo-Database-Design.md) · [API-14](../api/API-Specification.md) · [ICD-14](ICD-GenbaGo-Interface-Control.md) · [SEC-14](SEC-GenbaGo-Security-Requirements.md) · [TEST-14](TEST-GenbaGo-Test-Plan.md) · [OPS-14](OPS-GenbaGo-Deployment-Operations.md) · [UM-14](UM-GenbaGo-User-Admin-Guide.md) · parent [SAD-00](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) · precedents [SAD-10](../../10-factory-copilot/docs/SAD-Copilot-Software-Architecture.md), [SAD-09](../../09-quality-engineer-agent/docs/SAD-QEAgent-Software-Architecture.md) |

---

## 1. Introduction

### 1.1 Purpose
Define the architecture of GenbaGo (現場語): a Japanese ⇄ Thai ⇄ English translator that understands *genba* language. A sentence is segmented, looked up in the translation memory, translated under glossary constraints, checked (numbers, terms, omissions), and — separately and visibly — **interpreted**: which process it is about, what kind of message it is, which entities it names, which standard items to check and which indexed documents relate to it (SRS §1.1, Appendix A). Documents and photos take the same path through layout-preserving and OCR front ends; humans review segment by segment, and only approved segments become memory.

The document fixes the SRS's non-negotiables as architecture: mandated terms are enforced and verified (C-01), numbers and codes are preserved exactly or the segment is blocked (C-02), confidential documents stay local (C-03), nothing is dropped silently (C-04), and — the distinguishing idea — **what was said is never mixed with what the system inferred** (C-05, FR-14).

### 1.2 What makes this project different from its siblings
GenbaGo is the only FactoryBrain module whose output is *language*, and language hides errors well: a fluent Thai sentence with `3.5 mm` where the Japanese said `3.2 mm` reads perfectly. Four consequences shape the design:

- **Numbers and terms are not the model's to decide.** The translation memory is consulted first and an exact match is reused verbatim (FR-03); the glossary is injected into the prompt *and* verified afterwards (FR-04); every number, unit, tolerance, part number, lot, date and code in the source must appear unchanged in the target or the segment is **blocked** — not flagged (FR-05, C-02, AC-02). The database computes these checks (`run_checks()`) and refuses to approve a blocked segment (ADR-J03, ADR-J04).
- **Inference is a second artefact, not a paragraph.** The interpretation (process, message type, entities, suggested checks, related documents, confidence, possible readings) lives in its own table with `inferred = true`, is rendered in its own block in every output format, and cites only curated check items and documents that exist in the index (FR-12…FR-15, AI-09, AC-08, AC-09, ADR-J05, ADR-J06). Under an ambiguity threshold the system lists readings instead of choosing (FR-15, AC-05, ADR-J07).
- **Memory grows only from approvals.** A reviewer's approval writes the segment to `knowledge.tm_segment` with document, domain, approver and date (FR-24); every human edit is recorded with its edit distance (FR-29); glossary changes are versioned with an approver and an effective date (NFR-08). Translators edit, reviewers approve, admins change the glossary (FR-30, ADR-J08).
- **Local by default.** A job is confidential unless someone says otherwise; a confidential job cannot use a non-local provider and cannot be sent to Discord (C-03, NFR-04, ADR-J09).

### 1.3 Two ways to deploy it
- **Platform mode** (the intended one): GenbaGo is a **medium-coupled server module** of FactoryBrain (SAD-00 §13: "server module · `knowledge.tm_*` · upload, OCR · Copilot, Genba Memory · medium"). It **owns** the platform's `knowledge.glossary_term` and `knowledge.tm_segment`, adds schema `genba` (migration `genba_0001`), serves `/knowledge/translate` verbatim (API-00 maps it to 14), **provides** three read tools through IF-16 (`translate`, `glossary_lookup`, `term_check` — the glossary QE-Agent's IF-52 consumes and the terms Copilot's composer uses), and reads Genba Memory's `knowledge.document` index for related documents (IF-19).
- **Standalone mode**: the same containers with their own PostgreSQL (pgvector + pg_trgm), Redis, MinIO and Ollama; the platform's `core`, `knowledge` (document, chunk, glossary, TM) and `audit` objects extracted byte-identically into `db/schema.sql`. §9 lists what changes.

### 1.4 Related documents
DDS-14 (extracted platform objects, the `genba` extension, the guard triggers, the twins of checks / edit distance / TM lookup / classification / entities / evaluation, the seed reproducing Appendix A and AC-02…AC-09), API-14 (translation / check / interpretation / review & memory / documents & OCR / glossary & TM contracts), ICD-14 (IF-16 as provider; new IF-73 glossary & TM exchange, IF-74 segment checks, IF-75 interpretation, IF-76 OCR, IF-77 document jobs), SEC-14, TEST-14, OPS-14, UM-14.

---

## 2. Architecture principles

The platform principles (SAD-00 §2), restated for a translator:

| # | Principle | Consequence in GenbaGo |
|---|---|---|
| P-1 | **The LLM never decides a number or a term** | TM first (exact reuse); glossary injected then verified; numbers/codes compared token by token and blocking; the model produces prose between the fixed points (FR-03…FR-05, AI-01, AI-04). |
| P-2 | **What was said ≠ what was inferred** | Translation and interpretation are two tables, two API objects, two rendered blocks; `inferred = true` and a confidence on every interpretation; readings instead of a guess below the threshold (C-05, FR-14, FR-15). |
| P-3 | **Humans approve; memory grows only from approvals** | A segment reaches the TM only through a reviewer's approval; edits are signals with a distance; the glossary changes only through an admin with a version (FR-24, FR-29, FR-30, NFR-08). |
| P-4 | **The database is the source of truth** | Checks, statuses, versions, roles, confidentiality and evaluation gates are guarded rows (DDS-14 DD-J01…J09); a worker bug cannot approve a blocked segment or write an unreviewed memory. |
| P-5 | **Domain knowledge is data** | Glossary, aliases, process and message keywords, curated check items (shared names with MoldMind), entity patterns, the versioned test set — rows and files with change control (ADR-J10). |
| P-6 | **Confidential by default** | Local processing, local model, no egress except an explicit non-confidential path to Discord; documents access-controlled and audited (C-03, NFR-04, NFR-05). |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-14 §2.4)
| ID | Constraint | Architectural response |
|---|---|---|
| C-01 | Mandated terms appear or the segment is flagged | glossary injection (IF-09) + `glossary_hits()` post-check → `checks_json.flags.glossary`; forbidden renderings flagged (AC-03); approval needs a reviewer note for an unresolved flag |
| C-02 | Numbers, units, part numbers, dates, codes preserved exactly | `extract_codes()` / `codes_preserved()` → `checks_json.blocking.numbers`; `approve_segment()` refuses approval (`SEGMENT_BLOCKED`); the UI shows the diff |
| C-03 | Confidential documents processed locally | `translation_job.confidential` default true; CHECK `job_confidential_local` + `trg_job_guard`; egress only for `discord-bot`; no cloud MT provider enabled by default |
| C-04 | Never silently drop content | `sentence_count()` (omission flag), `untranslated()`, `length_ratio()` flags; document jobs keep every segment with its ordinal; a failed job is resumable, never truncated |
| C-05 | Interpretation separated from translation | `genba.interpretation` table; `TranslationResult.interpretation` object with `inferred: true`; separate block in text, DOCX, PDF and Discord renderings (AC-08) |

### 3.2 Quality attributes
| Attribute | Driver | Target | Tactic |
|---|---|---|---|
| Latency | NFR-01 | ≤ 5 s p95 for ≤ 200 chars | TM exact hit skips the model; one model call per segment batch; JA model ≤ 9 B on one GPU |
| Throughput | NFR-02 | 20-page DOCX ≤ 3 min | segments batched ≤ 12 per prompt; TM hits removed first; layout worker in parallel |
| Memory lookup | NFR-03 | ≤ 200 ms over 500 k segments | normalised-hash unique index for exact; trigram GIN and HNSW for fuzzy |
| Correctness | C-01, C-02, AI-02 | glossary ≥ 98 %, numbers 100 %, PED ≤ 0.20 | checks in SQL with Python twins; review gate; the evaluation gate |
| Non-fabrication | AI-09, AC-09 | 0 invented references | related docs are FK-checked against `knowledge.document` |
| Confidentiality | C-03, NFR-04, NFR-05 | never leaves the LAN by default | network isolation, ACL on documents, audit of who translated what |
| Availability | NFR-07 | ≥ 99 %; jobs resumable | job state in the database per segment; workers idempotent by ordinal |
| Localisation | NFR-06 | UI TH/JA/EN | platform language codes; glossary itself is trilingual |

### 3.3 Not drivers
Speech (v1 text only), certified translation, general-domain quality, a chat interface (Copilot), document ingestion for retrieval (Genba Memory).

---

## 4. Views

### 4.1 Context view
```
 Thai engineer · Japanese manager · quality staff · translator/coordinator · new employee
        │ web (review UI, hover readings) · Discord /jp (non-confidential) · clipboard helper (optional)
        ▼
 ┌──────────────────────────────┐   IF-16 (provider) ──► 10 Copilot (glossary_lookup, term_check, translate)
 │        GenbaGo API           │                      ──► 09 QE-Agent IF-52 (term_check)
 └──────┬───────────┬───────────┘   IF-19 (consumer)  ◄── 15 Genba Memory (knowledge.document index)
        │           │
  worker-translate  worker-interpret     worker-doc (DOCX/XLSX/PPTX/PDF)     worker-ocr (JA vertical)
  seg → TM → LLM →  classify · entities · curated checks · indexed docs · readings
  checks
        │                 │
 ┌──────▼─────────────────▼─────┐   IF-09 Ollama (JA ≤ 9 B) · IF-10 MinIO (documents, images, results)
 │ PostgreSQL: knowledge.glossary_term / tm_segment (owned) + genba (extension) │
 └──────────────────────────────┘
```

### 4.2 Container view
| Container | Responsibility | Notes |
|---|---|---|
| `web` | translate box, two-part result, segment review, glossary/TM management, dashboard | NFR-06 TH/JA/EN |
| `api` | API-14; jobs; roles; exports; IF-16 tools | role `app_rw` |
| `worker-translate` | segmentation (JA/TH aware) → TM lookup (exact, fuzzy) → glossary-constrained LLM → `run_checks()` → segment rows | role `worker_rw` |
| `worker-interpret` | process/message classification (rules + LLM), entities, curated checks, related docs from the index, readings under the threshold | writes `genba.interpretation`, `reading` |
| `worker-doc` | DOCX/XLSX/PPTX/PDF: extract segments with anchors, rebuild with translations, side-by-side PDF | FR-16, FR-17 |
| `worker-ocr` | JA OCR with vertical/horizontal region detection, handwriting flag, HMI layout mode | FR-18, FR-19, AI-06 |
| `indexer` | TM embeddings (multilingual), term mining from approvals, usage statistics | AI-07, FR-23, FR-26 |
| `scheduler` | monthly evaluation, batch jobs, retention | AI-08, FR-20 |
| `postgres` (pgvector + pg_trgm), `redis`, `minio`, `ollama` | | |
| `discord-bot` | `/jp <text>` for non-confidential text; the only egress | IF-08 |

### 4.3 Component view

**worker-translate**
- *Segmenter* — Japanese on 。！？ and newlines (the same rule as `sentence_count()`); Thai and English on sentence punctuation; document segments keep their anchor (paragraph / cell / run) (FR-02).
- *TM lookup* — `normalise_for_tm()` (NFC, whitespace, full-width digits) → exact by hash → reuse verbatim, `tm_score = 1.000`; else fuzzy: trigram similarity and vector cosine, candidates ≥ 0.85 offered with a diff, never auto-applied (FR-03, AI-07).
- *Glossary constraint* — terms whose source rendering occurs in the segment are injected with their mandated target rendering and forbidden alternatives; register selected (FR-04, FR-06).
- *Phraser* — one model call per batch; JSON output per segment; temperature ≤ 0.3.
- *Checks* — `run_checks()` in the database on insert: `blocking.numbers` (C-02), `flags.glossary`, `flags.forbidden`, `flags.length_ratio`, `flags.untranslated`, `flags.omission` (FR-05, FR-28, AI-04).
- *Alternatives* — for terms with `alternatives_json`, a short usage note (FR-07); furigana from `ja_reading` (FR-08).

**worker-interpret** — `classify()` — process and message type (keyword rules; the LLM labels only when the rules abstain), `extract_entities()` (line, machine, mould, part number, defect class from the glossary, parameter, quantity, date, role), `suggested_checks(process, message_type)` from `check_item` (FR-12, shared names with MoldMind), `related_docs(entities)` from `knowledge.document` tags (FR-13, AI-09), confidence from rule agreement; below `ambiguity_threshold` the *readings* prompt lists up to three readings and no interpretation is asserted (FR-15).

**Review** — segment list with source, MT, TM match with diff, glossary hits highlighted, check badges (blocked / flagged); translator edits (`segment_edit` with `edit_distance()`), reviewer approves (`approve_segment()` → `trg_tm_writeback`), admin edits glossary with versions (FR-27…FR-31).

### 4.4 Runtime views

**RV-1 Appendix A — `成形条件を変更した後、不良率が上昇しました。`**
1. Segment: one sentence. TM: no exact match; fuzzy candidates none ≥ 0.85.
2. Glossary hits in the source: 成形条件, 不良率 (and 保圧 appears in the suggested checks). Prompt carries their Thai and English renderings.
3. Model: Thai `หลังจากเปลี่ยนเงื่อนไขการขึ้นรูป อัตราของเสียเพิ่มขึ้น`; English `After changing the molding conditions, the defect rate increased.`
4. Checks: no numbers → `blocking.numbers` pass; glossary present; ratio within bounds; no Japanese script in the Thai; sentence counts 1/1 → clean.
5. Interpretation: process `injection_molding` (keyword 成形), message type `problem_report` (不良率 + 上昇), entities `{parameter: 成形条件, metric: 不良率, direction: up}`, timing note "change precedes the increase (causal claim implied, not verified)", five curated checks for molding/problem_report, four related documents found by tags `RAD-500-A`, `line 3`, `molding`, confidence 0.91 — stored in `genba.interpretation` with `inferred = true`.
6. Rendering: translation block, then a ruled `INTERPRETATION (inferred — confidence 0.91)` block, then "Glossary terms applied".

**RV-2 AC-02 / blocked number** — an 8D segment `公差 ±0.05 mm / 3.2 mm / LOT-2609-114`; the model writes `3.5 mm`; `codes_preserved()` fails → `blocking.numbers = false`; the segment is `blocked`; a translator fixes the text; the check recomputes; approval possible.

**RV-3 AC-03 / forbidden term** — the model renders 是正処置 as 修正措置; `flags.forbidden` names the term; the reviewer cannot approve without resolving or writing a justified note.

**RV-4 AC-05 / readings** — `不良品は現場で処理してください`: 処理 = dispose / rework / handle; rule agreement low → confidence 0.55 < 0.60 → three readings stored, no single interpretation asserted; the translation shows the readings.

**RV-5 AC-06 / OCR** — a photo of a vertical 検査基準書: regions with orientation `vertical`, one handwritten note flagged `low_confidence`, text linearised, translated, a side-by-side PDF produced.

**RV-6 AC-07 / TM reuse** — after J1 is approved, the identical input is an exact hit; `mt_text = tgt_text`, `tm_score = 1.000`, no model call.

**RV-7 batch resume** — a five-file folder; file 4 fails on a corrupt XLSX; the job is `failed` with 4 of 5 done; `POST /jobs/{id}/resume` restarts at the first unfinished item.

### 4.5 Deployment view
One host with an 8 GB GPU (JA-capable model ≤ 9 B), 16 GB RAM; networks `frontend`, `internal` (no route out), `egress` (discord-bot only). Platform mode: the same images under the platform compose, using the platform's PostgreSQL (migration `genba_0001`), MinIO, Ollama and notifier (OPS-14 §1).

### 4.6 Data view
Platform-owned by this module: `knowledge.glossary_term`, `knowledge.tm_segment`. Platform-read: `knowledge.document` (related docs), `core.app_user`. Extension `genba`: settings; roles; glossary versions, aliases, candidates, usage; keywords, check items, entity patterns; jobs, files, batch items; segments, edits, TM matches; interpretations, readings; OCR pages and regions; test sets, eval runs and results; exports (DDS-14 §3).

---

## 5. Cross-cutting concerns

| Concern | Approach |
|---|---|
| Identity & roles | platform users; `genba.user_role` translator / reviewer / admin (FR-30); viewers read |
| Confidentiality | job flag (default true); ACL on documents (`knowledge.document.acl_json`); who translated what in `audit.log` (NFR-05) |
| Languages | JA/TH/EN everywhere; UI strings TH/JA/EN; registers report / shopfloor / customer (FR-06) |
| Observability | per-job metrics: segments, TM hit rate, blocked, flagged, PED, latency; monthly evaluation report (AI-08) |
| Configuration | `deploy/genbago.example.yaml` (schema-validated); glossary/keywords/check items/test set as data |
| Retention | jobs and segments ≥ 365 d; TM and glossary forever (versioned) |

---

## 6. The design's own risk — a fluent wrong translation

The checks catch what can be compared: numbers, codes, mandated terms, forbidden terms, missing sentences, untranslated script, implausible length. They cannot catch a fluent sentence that reverses a condition (「変更した後」 rendered as *before*) or drops a negation. Mitigations: the TM reuses proven sentences first; the register and glossary reduce the model's freedom; every segment of a *critical* document type (8D, 検査基準書, customer-facing) goes through a reviewer with the source beside the target; edit distances reveal segments the model gets wrong repeatedly; the monthly evaluation on a real test set measures post-edit distance, and a regression > 2 % triggers investigation. The design does not claim the checks make a translation correct — it claims they make the *common* silent errors impossible and the rest visible to a human.

---

## 7. Architecture Decision Records

### ADR-J01 — A medium platform module that owns `knowledge.glossary_term` and `knowledge.tm_segment`
**Context.** SAD-00 §13 places terminology and memory in `knowledge`; 09 and 10 already consume the glossary. **Decision.** Own both tables; add `genba`; serve `/knowledge/translate` verbatim; provide IF-16 tools. **Consequences.** ✅ one glossary for the platform; ❌ glossary edits affect QE-Agent's term check — hence versions and effective dates.

### ADR-J02 — Translation memory before the model, exact match reused verbatim
**Context.** FR-03, AI-07, NFR-03. **Decision.** Normalised-hash exact lookup first (verbatim reuse, no model call), then fuzzy (trigram + vector) ≥ 0.85 offered with a diff, never auto-applied. **Consequences.** ✅ proven sentences never drift; ✅ latency; ❌ a wrong approved segment propagates — the review gate is the control.

### ADR-J03 — Glossary injected into the prompt and verified after
**Context.** C-01, FR-04, AI-02. **Decision.** Both; the verification is a database function, the flag survives until resolved. **Consequences.** ✅ ≥ 98 % measured, not assumed; ❌ terms the glossary lacks are unprotected — the mining loop (FR-23).

### ADR-J04 — Numbers and codes are a blocking check, everything else a flag
**Context.** C-02, C-04, FR-05, FR-28. **Decision.** `blocking.numbers` refuses approval; glossary, forbidden, ratio, untranslated, omission are flags that need resolution or a reviewer note. **Consequences.** ✅ AC-02 by construction; ❌ a tolerance written differently but equivalently (`±0.05` vs `+/-0.05`) is blocked — canonicalisation rules in `extract_codes()`.

### ADR-J05 — Interpretation is a separate table and a separate rendering
**Context.** C-05, FR-14, AC-08. **Decision.** `genba.interpretation` with `inferred = true`; the API object and every renderer keep it apart. **Consequences.** ✅ users can always tell; ❌ two things to read — the UI folds the block by default for short texts.

### ADR-J06 — Curated check items and indexed documents only
**Context.** FR-12, FR-13, AI-09, AC-09. **Decision.** Suggested checks are `check_item` rows (names shared with MoldMind); related documents are `knowledge.document` ids — FK-checked. **Consequences.** ✅ zero invented references; ❌ an empty index yields no related documents, honestly.

### ADR-J07 — Readings instead of a guess below a threshold
**Context.** FR-15, AC-05. **Decision.** Below `ambiguity_threshold` (0.60) the interpretation is replaced by 2–3 readings with usage notes. **Consequences.** ✅ no confident wrong reading; ❌ more to read — the threshold is tunable under the evaluation gate.

### ADR-J08 — Review gate with edit-distance signal; memory from approvals only
**Context.** FR-24, FR-27…FR-31, AI-08. **Decision.** Translators edit, reviewers approve, approval writes the TM; every edit carries a normalised Levenshtein distance. **Consequences.** ✅ the monthly report is real data; ❌ approval is work — critical document types only require it, others may be approved in bulk by a reviewer.

### ADR-J09 — Local only by default; non-confidential is an explicit choice
**Context.** C-03, NFR-04. **Decision.** `confidential = true` default; a confidential job cannot use a non-local provider or Discord; the only egress container is the bot. **Consequences.** ✅ leakage needs an explicit action; ❌ cloud MT quality is unavailable by default — a per-job decision by an admin.

### ADR-J10 — A versioned real-document test set gates releases
**Context.** AI-02, AI-03, AI-05, AI-08, AC-01. **Decision.** The test set is data (versioned); an eval run passes only at the gates; a regression > 2 % flags investigation; prompts, glossary structure and model changes go through it. **Consequences.** ✅ regressions are caught; ❌ the plant must build and maintain the set (200 segments / 300 labelled sentences).

---

## 8. Quality attribute scenarios

| ID | Stimulus | Environment | Response | Measure |
|---|---|---|---|---|
| QAS-01 | 120-char JA sentence, no TM hit | baseline GPU | translation + interpretation | ≤ 5 s p95 (NFR-01) |
| QAS-02 | same sentence again after approval | any | exact TM reuse, no model call | ≤ 200 ms (NFR-03, AC-07) |
| QAS-03 | model changes `3.2 mm` to `3.5 mm` | any | segment blocked; approval refused | 100 % (AC-02) |
| QAS-04 | model renders a forbidden alternative | any | flagged before review | 100 % (AC-03) |
| QAS-05 | ambiguous sentence | any | 2–3 readings, no assertion | AC-05 |
| QAS-06 | 20-page DOCX | any | translated with layout | ≤ 3 min (NFR-02) |
| QAS-07 | vertical-text photo | any | OCR + side-by-side | AC-06; char accuracy ≥ 95 % printed (AI-06) |
| QAS-08 | interpretation cites a document | any | the document exists in the index | 0 invented (AC-09) |
| QAS-09 | confidential job with a cloud provider requested | any | refused | C-03 |
| QAS-10 | batch of 5 files, one corrupt | any | 4 done, job failed and resumable | NFR-07 |
| QAS-11 | monthly evaluation | test set v1 | metrics vs gates; regression > 2 % flagged | AI-02, AI-08 |
| QAS-12 | glossary term changed | admin | new version with approver and effective date | NFR-08 |

---

## 9. Platform mode

| Aspect | Standalone | Platform |
|---|---|---|
| Database | own PostgreSQL with extracted `core`/`knowledge`/`audit` objects + `genba_0001` | platform database; `genba_0001` applied; `knowledge.glossary_term`/`tm_segment` owned by GenbaGo |
| API | `/api/v1/translate`… and `/knowledge/translate` both served | gateway serves `/knowledge/translate`; SRS paths under `/genba/` |
| Tools (IF-16) | — | `translate`, `glossary_lookup`, `term_check` registered for 10 and 09 |
| Related documents | own `knowledge.document` rows (indexed by the doc worker) | Genba Memory's index (IF-19) |
| Model / storage | own Ollama, MinIO | platform Ollama (GPU semaphore), MinIO |
| Discord | own bot (profile) | platform notifier with `/jp` routed here (IF-08) |

---

## 10. Risks and technical debt

| Risk | Mitigation | Owner |
|---|---|---|
| Fluent wrong translation (§6) | review for critical types; PED tracking; evaluation gate | QE lead / coordinator |
| Glossary incomplete at launch | mine from bilingual documents (TMX import + candidate loop) | coordinator |
| Local JA→TH model weaker than cloud MT | TM + glossary compensate; measure (AI-02); larger model if hardware allows; cloud only per explicit admin decision | ML owner |
| Handwriting OCR | flagged low-confidence; human transcription for critical text | quality staff |
| Interpretation over-reach | separation, confidence, readings, curated items only | ML owner |
| Vector fuzzy matching unverified here | trigram twin verified; vector path in CI | ML owner |

---

## 11. Traceability to SRS-14

| SRS | Where |
|---|---|
| C-01…C-05 | §3.1, ADR-J03/J04/J05/J09, DDS-14 DD-J01…J09 |
| FR-01…08 translation core | §4.3 worker-translate, ADR-J02, J03, RV-1, RV-6 |
| FR-09…15 interpretation | §4.3 worker-interpret, ADR-J05, J06, J07, RV-1, RV-4 |
| FR-16…20 documents & images | §4.2 worker-doc / worker-ocr, RV-5, RV-7 |
| FR-21…26 terminology & memory | ADR-J01, J02, §4.6, DDS-14 |
| FR-27…31 review | §4.3 Review, ADR-J08 |
| AI-01…09 | P-1, ADR-J02, J03, J06, J10, §6 |
| NFR-01…08 | §3.2, §4.5, §5 |
| AC-01…09 | RV-1…RV-7, QAS-02…08, 11, TEST-14 TS-2, TS-3, TS-4, TS-7 |
