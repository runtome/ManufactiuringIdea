# Interface Control Document — GenbaGo (Japanese Factory Translator Agent)

| Field | Value |
|---|---|
| Document ID | ICD-14-GenbaGo |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-14](../SRS-GenbaGo-Japanese-Factory-Translator.md) §4 · [SAD-14](SAD-GenbaGo-Software-Architecture.md) |
| Parent | [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) — IF-08, IF-09, IF-10, IF-13, IF-14 consumed; IF-16 **provided** |
| Siblings | [ICD-09](../../09-quality-engineer-agent/docs/ICD-QEAgent-Interface-Control.md) IF-52 (the term check GenbaGo serves) · [ICD-10](../../10-factory-copilot/docs/ICD-Copilot-Interface-Control.md) IF-16 (Copilot as consumer) · [ICD-11](../../11-injection-molding-ai/docs/ICD-MoldMind-Interface-Control.md) (shared parameter names) |

---

## 1. Interface register

Shared `IF-xx` numbering with the platform (IF-01…IF-17) and the siblings (IF-18…IF-72). New here: **IF-73…IF-77**.

| ID | Interface | Parties | Protocol | Criticality | Here |
|---|---|---|---|---|---|
| [IF-08](#if-08) | Discord | bot, Discord | WSS + HTTPS | Low | `/jp <text>` for non-confidential text only |
| [IF-09](#if-09) | LLM runtime | worker-translate / worker-interpret, Ollama | HTTP/JSON | High | JA-capable model ≤ 9 B; glossary + TM context injection; JSON output |
| [IF-10](#if-10) | Object storage | api, workers, MinIO | S3 API | High | documents, images, results; ACL |
| [IF-13](#if-13) | SMTP & webhook | api | SMTP / HTTPS | Low | job-done and review notifications |
| [IF-14](#if-14) | Metrics scrape | Prometheus, services | HTTP/text | Medium | segments, TM hit rate, blocked/flagged, PED, latency |
| [IF-16](#if-16) | Agent tool contract (**provider**) | GenbaGo, 10 Copilot, 09 QE-Agent | in-process typed / HTTPS | High | `translate`, `glossary_lookup`, `term_check` |
| [IF-19](#if-19) | Platform integration | GenbaGo, platform gateway, Genba Memory | — | High | owning `knowledge.tm_*`; the related-document index |
| [IF-73](#if-73) | Glossary & TM exchange | admin, external CAT tools | TBX / TMX / CSV | Medium | FR-25 |
| [IF-74](#if-74) | Segment check contract | database, workers, UI | JSON | **Critical** | FR-28, AI-04, C-01, C-02, C-04 |
| [IF-75](#if-75) | Interpretation contract | worker-interpret, UI, renderers | JSON | **Critical** | FR-09…FR-15, C-05, AI-09 |
| [IF-76](#if-76) | OCR contract | worker-ocr, worker-translate | JSON | High | FR-18, FR-19, AI-06 |
| [IF-77](#if-77) | Document translation job | api, worker-doc, worker-ocr | JSON + S3 | High | FR-16, FR-17, FR-20, NFR-07, C-03 |

Each section: parties · protocol · format · timing · errors & retry · security · versioning · verification.

---

## IF-08 — Discord {#if-08}
**Parties.** `discord-bot` (the only container on the `egress` network) ↔ a plant channel; the platform notifier in platform mode.
**Format.** `/jp <text>` → the two-part rendering (translation, then the ruled interpretation block) as one message; `/jp doc` is refused with a link to the web UI. Every request creates a job with `channel = discord` and `confidential = false` — the bot cannot create a confidential job, and a confidential text must not be pasted into Discord; the bot says so in its help.
**Timing.** ≤ 5 s for ≤ 200 chars (NFR-01).
**Errors.** Model down → the memory-only answer (exact TM hits) or "not available"; never a partial translation without the checks.
**Security.** Bot token as a secret file mounted only into `discord-bot`; the bot holds a viewer token to the API (read tools + `/translate` with `confidential: false`); no glossary or memory writes (SEC-J28).
**Verification.** TC-091.

## IF-09 — LLM runtime {#if-09}
**Parties.** worker-translate (phrasing between fixed points), worker-interpret (the LLM half of classification and the readings) → Ollama.
**Contract.** Model with Japanese capability, ≤ 9 B (`llm_max_params_b` CHECK), temperature ≤ 0.3, JSON output. The prompt (`deploy/prompts/translate.v1.md`) carries: the segment batch (≤ 12), the register, the glossary entries found in the source with their mandated target renderings and forbidden alternatives, up to 3 fuzzy TM matches as examples, and the rule that numbers, codes and dates are copied verbatim. The model never sees the glossary as a whole. Interpretation (`interpret.v1.md`) receives the sentence, the rule classifier's result and the curated item list to choose from; readings (`readings.v1.md`) receives the sentence and returns 2–3 readings with usage notes.
**Errors.** Timeout → retry once; invalid JSON → retry once with the error; then the segment is stored without MT text (`machine`, `mt_text = null`) and the job continues — never a silent drop (C-04).
**Security.** One shared model; prompts versioned in git; no external endpoint unless an admin enables the cloud provider for a non-confidential job (SEC-J10).
**Verification.** TC-015, TC-030, TC-036, TC-084.

## IF-10 — Object storage {#if-10}
Buckets `genbago-docs` (uploads, private, versioned), `genbago-results` (translated documents, side-by-side PDFs, keep-layout images), `genbago-exports` (TBX/TMX/CSV with object lock), `genbago-index` (indexed documents in standalone mode). Signed URLs ≤ 15 min; `acl_json` of `knowledge.document` enforced by the API. Retention: uploads 365 d, results 365 d, exports locked. TC-087.

## IF-13 — SMTP & webhook {#if-13}
Job finished / failed, review requested, monthly evaluation report; Mailpit in dev. TC-093 (optional).

## IF-14 — Metrics {#if-14}
`genbago_segments_total{pair,status}`, `genbago_tm_hit_rate{pair}`, `genbago_blocked_total`, `genbago_flagged_total{flag}`, `genbago_ped` (histogram), `genbago_translate_latency_ms` (histogram, pair), `genbago_job_duration_ms{kind}`, `genbago_ocr_low_confidence_total`, `genbago_glossary_compliance{pair}`, `genbago_eval_last_passed`. TC-064.

## IF-16 — Agent tool contract, as provider {#if-16}
GenbaGo registers three **read** tools in the platform tool registry (`agent.tool`, `kind = 'read'`), consumed by 10 Copilot's executor and by 09 QE-Agent's IF-52 term check:

| Tool | Args | Returns | Notes |
|---|---|---|---|
| `translate(text, target_lang, register?)` | ≤ 2,000 chars | `TranslationResult` (platform shape) + `interpretation_detail` | confidential by default; `tm_match` when exact |
| `glossary_lookup(text, target_lang)` | | the mandated renderings, readings and forbidden alternatives for every term found in the text | what Copilot's composer injects so mandated terms are used in the first place |
| `term_check(text, lang, source_text?)` | a draft | forbidden renderings with positions, missing mandated terms, applied terms | QE-Agent's `term_check` rows (IF-52) are built from this |

Scope: the caller's platform scope is passed and honoured for related documents; tool results are typed facts (numbers and terms), never free prose. Timeout 5 s. TC-092.

## IF-19 — Platform integration {#if-19}
| Aspect | Contract |
|---|---|
| Ownership | GenbaGo owns `knowledge.glossary_term` and `knowledge.tm_segment` (SAD-00 §13); its guard triggers attach to them; other modules read them (QE-Agent IF-52, Copilot composer) and never write |
| Migration | `genba_0001` on the platform database (sections 10–19 of `db/schema.sql`) |
| Gateway | `/knowledge/translate` served verbatim; SRS paths under `/genba/` |
| Related documents | Genba Memory's `knowledge.document` index; GenbaGo maintains `genba.document_tag` from the document's title, entities and process (the doc worker in standalone mode; the indexer in platform mode) |
| Users, roles | platform users; `genba.user_role` adds translator / reviewer / admin |
| Model, storage, notifier | platform Ollama (GPU semaphore), MinIO, notifier (IF-08 routed) |

---

## IF-73 — Glossary & TM exchange {#if-73}
**Formats.** Glossary: CSV (`ja, ja_reading, th, en, domain, forbidden ("lang:text;lang:text"), approved_by, effective_from, notes` — [`deploy/glossary.example.csv`](../deploy/glossary.example.csv) equals the seed) and TBX-Basic (one `termEntry` per term, `langSet` ja/th/en, `note type="forbidden"`). Memory: TMX 1.4b ([`deploy/tm.example.tmx`](../deploy/tm.example.tmx), `prop type="domain"`, `prop type="approver"`) and CSV (`src_lang, tgt_lang, src_text, tgt_text, domain, doc_ref, approver, created_at`).
**Rules.** Import is an admin (glossary) or reviewer/admin (TM) action; every glossary row becomes a version with the importer as approver and the file's `effective_from`; a TM row whose normalised source already has a different approved target is rejected (`TM_DUPLICATE_SOURCE`) and listed in the import report; a forbidden rendering equal to the mandated one is rejected. Exports record a sha256 (`genba.export_job`).
**Verification.** TC-057.

## IF-74 — Segment check contract {#if-74}
`deploy/schemas/segment-checks.schema.json`. Produced by `genba.run_checks()` on every insert/update of a segment's text — never by a worker or the UI:
```
{ blocking: { numbers: { ok, source[], missing[], extra[] } },
  flags: { glossary: { ok, missing[], applied[] }, forbidden: { ok, hits[{term, rendering, mandated}] },
           length_ratio: { ok, ratio, min, max }, untranslated: { ok }, omission: { ok, src_sentences, tgt_sentences } },
  blocked, flagged, clean }
```
Token canonicalisation (`extract_codes`): full-width → half-width; unit aliases (มม. / ミリ → mm, ℃ → °C, +/- → ±, 個 / ชิ้น → pcs); dates → `YYYY-MM-DD`; codes `[A-Z]+-[0-9]{2,}(-[A-Z0-9]+)*`; numbers with sign/tolerance and unit, spaces removed. `blocked` ⇒ status `blocked` and approval refused; `flagged` ⇒ status `flagged` and approval only with a reviewer note. TC-020…TC-029.

## IF-75 — Interpretation contract {#if-75}
`deploy/schemas/interpretation.schema.json`; example [`deploy/examples/appendix-a.json`](../deploy/examples/appendix-a.json). `inferred: true` (constant), `confidence`, `ambiguous`; assertion: `process`, `message_type`, `entities` (line, machine, mould, part_number, lot, defect_class, parameter, metric, quantity, date, role, direction), `timing_note`, `suggested_checks[]` (curated `check_item` rows — [`deploy/check-items.example.yaml`](../deploy/check-items.example.yaml), names shared with MoldMind), `related_documents[]` (ids that exist in `knowledge.document`); ambiguous: `readings[2..3]` and nothing suggested. Thresholds: assert only at confidence ≥ 0.60. Renderers (web, DOCX comment block, PDF side panel, Discord) draw the ruled block `INTERPRETATION (inferred — confidence x.xx)` after the translation and never inside it (AC-08). TC-030…TC-039.

## IF-76 — OCR contract {#if-76}
`deploy/schemas/ocr-result.schema.json`; example [`deploy/examples/ocr-j4.json`](../deploy/examples/ocr-j4.json). Per page: image, size, `layout_mode`; regions with `bbox`, `orientation` (vertical Japanese linearised top-to-bottom, right-to-left), `text`, `char_confidence`, `handwriting`, `low_confidence` (= handwriting ∨ confidence < 0.95; set by the database, cannot be cleared), linked `segment_id`. Engine: a Japanese-capable OCR with vertical support (PaddleOCR-JA or equivalent) running locally; printed accuracy ≥ 95 % is the gate (AI-06) measured on the plant's own sample set. TC-044…TC-046.

## IF-77 — Document translation job {#if-77}
`deploy/schemas/translation-job.schema.json`. Kinds `text | document | ocr | hmi | batch`; formats `docx | xlsx | pptx | pdf | image`; `keep_layout`; `layout_mode`; `files[]` for batches; `confidential` default true ⇒ `provider = local` and `channel ≠ discord`. Worker-doc extracts segments with anchors (paragraph / run / cell / shape), rebuilds the document with translated runs and the original styles, and writes the result to `genbago-results`; PDF → side-by-side or overlay. Batch: one `job_file` per file; a failed file does not stop the batch; `resume` restarts at the first unfinished file. Limits: 500 files per batch, 50 MB per file, 20 pages ≤ 3 min (NFR-02). TC-040…TC-049.

---

## 2. Interface matrix

| Interface | Standalone | Platform mode | Degrades to | Auditable |
|---|---|---|---|---|
| IF-08 Discord | own bot (profile) | platform notifier | web UI only | `translation_job.channel` |
| IF-09 LLM | own Ollama | platform Ollama + semaphore | memory-only (exact hits), segments without MT text | `agent`-style prompt versions on jobs |
| IF-10 storage | own MinIO | platform MinIO | job refused | bucket logs |
| IF-16 tools | HTTPS to GenbaGo | registry tools | sibling degrades (QE term check offline) | `audit.log` |
| IF-73…77 | files + API | same | — | `export_job`, `term_version`, `segment_edit` |

## 3. Change control
| Artefact | Owner | Gate |
|---|---|---|
| glossary (terms, forbidden, aliases) | terminology admin | versioned with approver and effective date; QE-Agent and Copilot see the new version at its effective date |
| curated check items, keywords, entity patterns | QE lead + ML owner | evaluation run (classification ≥ 0.90) |
| prompts | ML owner | version bump; evaluation run (glossary ≥ 0.98, numbers 1.0, PED ≤ 0.20) |
| test set | ML owner | new version; frozen once used |
| unit aliases, ratio bounds | admin | re-derivation of the seed checks (TC-005) |

## 4. Traceability
C-01/FR-04 → IF-74 · C-02/FR-05 → IF-74 · C-03/NFR-04 → IF-08, IF-77 · C-04 → IF-74 · C-05/FR-14 → IF-75 · FR-03/AI-07 → IF-09, IF-19 · FR-09…15/AI-09 → IF-75 · FR-16…20/NFR-02/NFR-07 → IF-77 · FR-18/19/AI-06 → IF-76 · FR-21…26/NFR-08 → IF-73, IF-19 · FR-28/AI-04 → IF-74 · NFR-07 → IF-77 · IF-52 (09) → IF-16 · AI-01/AI-05 → IF-09.
