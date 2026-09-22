# Database Design Specification — GenbaGo (Japanese Factory Translator Agent)

| Field | Value |
|---|---|
| Document ID | DDS-14-GenbaGo |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-14](../SRS-GenbaGo-Japanese-Factory-Translator.md) · [SAD-14](SAD-GenbaGo-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) · [`db/seed_demo.sql`](../db/seed_demo.sql) · [`deploy/glossary.example.csv`](../deploy/glossary.example.csv) · [`deploy/tm.example.tmx`](../deploy/tm.example.tmx) · [`deploy/check-items.example.yaml`](../deploy/check-items.example.yaml) |
| Parent | [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) §9 (`knowledge` — glossary and translation memory) |

---

## 1. Scope and relationship to the platform

### 1.1 What this schema is
PostgreSQL 16 with pgvector and pg_trgm. `db/schema.sql` has two halves:

- **Sections 1–9 — extracted verbatim from `00/db/schema.sql`**: extensions, the helper functions, the three enums the extracted objects use (`core.shift_code`, `core.language_code`, `quality.severity`), the whole `core` section, the four `knowledge` objects GenbaGo owns or reads (`document`, `chunk`, `glossary_term`, `tm_segment`, with their comments), `audit`, their indexes (including the HNSW and trigram indexes on `chunk` and `tm_segment`), the `updated_at` triggers and three views. TEST-14 TC-002 diffs every block and object (54/54 identical). Genba Memory's `knowledge.case_*` tables are not extracted.
- **Sections 10–19 — the `genba` extension** (migration `genba_0001`): 29 tables, 13 enum types, 46 functions, 21 triggers, 34 indexes, 12 views.

**Platform mode** applies only sections 10–19. GenbaGo **owns** `knowledge.glossary_term` and `knowledge.tm_segment` (SAD-00 §13) — the guard triggers of section 16 attach to those two platform tables — and reads `knowledge.document` (the related-document index). Nothing in `vision`, `quality`, `telemetry` or `agent` is touched.

### 1.2 SRS §5 tables, mapped
| SRS-14 §5 | Here | Note |
|---|---|---|
| `glossary_term(...)` | platform `knowledge.glossary_term` + `genba.term_version` (NFR-08), `term_alias` (FR-22), `term_candidate` (FR-23), `term_usage` (FR-26) | `pos` is carried in `notes`; the platform row is the current version, `term_version` the history |
| `tm_segment(... embedding vector(1024))` | platform `knowledge.tm_segment` + `genba.tm_index` (normalised source, hash) | the vector column is the platform's; the exact index is GenbaGo's |
| `translation_job(...)` | `genba.translation_job` + `job_file` (batches) | plus confidentiality, provider, channel, format, layout, resume ordinal |
| `segment_result(...)` | `genba.segment` + `segment_edit` + `tm_match` | `checks_json` computed by the database; `edit_distance` per edit and last |
| `interpretation(...)` | `genba.interpretation` + `reading` | `inferred` is a CHECK; readings for ambiguity |
| `term_usage(...)` | `genba.term_usage` | |

---

## 2. Design decisions

| ID | Decision | Why | Where |
|---|---|---|---|
| **DD-J01** | **Checks are computed by the database on every text change and never supplied**; numbers/codes are *blocking*, the rest are *flags* | C-02, C-01, C-04, FR-05, FR-28, AI-04 | `run_checks()`, `trg_segment_checks` |
| **DD-J02** | **A blocked segment cannot be approved; a flagged one needs a reviewer note; only a reviewer/admin approves** | AC-02, AC-03, FR-30 | `trg_segment_checks` (approved branch) |
| **DD-J03** | **Memory is approved, immutable and unambiguous**: approval writes `tm_segment` once; one approved target per normalised source and pair; no UPDATE/DELETE | FR-24, FR-03, AI-07, AC-07 | `trg_tm_writeback`, `trg_tm_guard`, `trg_tm_index`, `tm_index` unique |
| **DD-J04** | **An exact TM hit is reused verbatim**; fuzzy candidates are offered, never applied | FR-03 | `tm_lookup()`, `add_segment()`, `trg_segment_checks` (`TM_EXACT_PRIORITY`) |
| **DD-J05** | **Every human edit is a row with its normalised edit distance**; `final_text` changes only through `edit_segment()` / `approve_segment()` | FR-29, AI-08 | `segment_edit`, `edit_distance()`, `EDIT_CONTEXT_REQUIRED` |
| **DD-J06** | **Inference is its own table, labelled, thresholded, curated and indexed**: `inferred = true` (CHECK), an assertion needs confidence ≥ the ambiguity threshold, an ambiguous reading needs ≥ 2 readings and asserts nothing, suggested checks must be curated items for the classified process/type, related documents must exist in `knowledge.document` | C-05, FR-12…FR-15, AI-09, AC-05, AC-08, AC-09 | `interpretation`, `reading`, `trg_interpretation_guard` |
| **DD-J07** | **Glossary changes are admin-approved versions**; forbidden renderings can never equal the mandated one | FR-21, FR-30, NFR-08 | `trg_glossary_guard`, `trg_glossary_version`, `term_version` |
| **DD-J08** | **Confidential by default and unrepresentable otherwise**: a confidential job cannot use a non-local provider or the Discord channel, cannot be declassified; failed jobs resume at the first unfinished item | C-03, NFR-04, NFR-07, FR-20 | `job_confidential_local`, `trg_job_guard`, `resume_job()` |
| **DD-J09** | **Gates are constants and computed**: OCR low-confidence flag, evaluation pass/fail and the > 2 % regression flag are set by triggers from CHECK-pinned settings | AI-02, AI-05, AI-06, AI-08 | `setting` CHECKs, `trg_ocr_flag`, `trg_eval_gate` |

---

## 3. The `genba` schema

### 3.1 Settings, roles, glossary extension, knowledge as data (section 11)
| Table | Purpose | Key constraints |
|---|---|---|
| `setting` | constants and thresholds | fuzzy ≥ 0.85, gates (0.98 / 1 / 0.20 / 0.90), OCR ≥ 0.95, regression = 2, model ≤ 9 B, temperature ≤ 0.3, confidential default, retention ≥ 365 |
| `user_role` | translator / reviewer / admin per platform user | `has_role()` used by every guard |
| `term_version` | every glossary change with approver, effective date, note | append-only; unique (term, version) |
| `term_alias` | abbreviations, jargon, supplier and variant renderings per language | unique (alias, lang) |
| `term_candidate` | mined terms awaiting an admin decision | `trg_candidate_guard` |
| `term_usage` | per term per day: count, inconsistencies | |
| `process_keyword`, `message_keyword` | the rule half of the classifier (weighted keywords, three languages) | weight ≤ 3 |
| `check_item` | curated "standard items to check" per process × message type; `moldmind_param` names MoldMind's parameter | unique ordinal |
| `entity_pattern` | regex per entity (one capture group); `direction` has a canonical value | |
| `unit_alias`, `ratio_bound` | unit canonicalisation (มม., ミリ, ℃, +/-, 個 …); length-ratio bounds per pair | |
| `document_tag` | tags on `knowledge.document` — the only source of related documents | |
| `tm_index` | normalised source + hash per TM segment | unique (pair, hash) |

### 3.2 Jobs, segments, edits, matches (section 12)
| Table | Purpose | Key constraints |
|---|---|---|
| `translation_job` | kind (text / document / ocr / hmi / batch), pair, register, status, `confidential` (default true), provider, channel, format, layout, files, counts, error, resume ordinal | pair differs; done ⇒ counts equal; failed ⇒ error; confidential ⇒ local and not Discord |
| `job_file` | items of a batch with their own status/error | |
| `segment` | ordinal, anchor, `src_text`, `mt_text`, TM match and score, `final_text`, `status`, `checks_json`, last edit distance, reviewer note, approver, TM link | unique (job, ordinal); approved ⇒ approver, time, final text |
| `segment_edit` | before/after with edit distance (append-only) | |
| `tm_match` | fuzzy candidates with method and diff | score ≥ 0.85 unless exact |

### 3.3 Interpretation, readings, OCR (section 13)
`interpretation` (1:1 segment; `inferred = true` CHECK; confidence; `ambiguous`; process, message type, entities, timing note, suggested check ids, related document ids; asserting ⇒ process and type present), `reading` (1–3 per segment: reading_ja, th, en, usage note), `ocr_page` (image, size, layout mode), `ocr_region` (bbox, orientation, text, character confidence, handwriting, `low_confidence` set by trigger, linked segment).

### 3.4 Test sets, evaluation, exports, migration (section 14)
`test_set` (name, version, frozen), `test_segment` (source, reference, expected process/type), `eval_run` (metrics, `passed`, `investigate`), `eval_result` (per segment: MT text, PED, glossary ok, numbers ok, predictions; append-only), `export_job` (CSV/TBX/TMX with sha256), `migration`.

---

## 4. Functions — the twins (section 15)

Re-derived in Python by TEST-14 TC-005 (`twin14.py`, driven by the seed generator).

| Function | Twin of | Rule |
|---|---|---|
| `normalise_for_tm(text)`, `tm_hash(text)` | FR-03 | full-width → half-width, ideographic space, collapsed whitespace, trim; md5 of the result |
| `canon_units(text)` | C-02 / AI-04 | unit aliases replaced longest-first (มม. → mm, ℃ → °C, +/- → ±, 個 / ชิ้น → pcs …) |
| `extract_codes(text)` | C-02 / FR-05 | dates (→ YYYY-MM-DD), codes (`[A-Z]+-[0-9]{2,}(-[A-Z0-9]+)*`), then numbers with sign/tolerance/decimal and a canonical unit; sorted multiset |
| `codes_preserved(src, tgt)` | AC-02 | `{ok, source, missing, extra}` by multiset difference — **blocking** |
| `glossary_hits(src, tgt, src_lang, tgt_lang)` | C-01 / FR-04 / AC-03 | a term is *relevant* when its source rendering (or an alias) occurs in the source and no longer matching term contains it; relevant ⇒ its target rendering must occur (`applied` / `missing`); forbidden renderings for the target language are reported as `forbidden` hits |
| `sentence_count(text, lang)` | C-04 | JA on 。！？ and newlines; TH on newlines, double spaces and terminal punctuation followed by space/end; EN likewise (a decimal point never ends a sentence) |
| `length_ratio`, `untranslated(tgt, lang)` | AI-04 | chars(tgt)/chars(src) vs `ratio_bound`; Japanese script in a TH/EN target or Thai script in a JA target |
| `run_checks(src, tgt, langs)` | FR-28 / AI-04 | `{blocking: {numbers}, flags: {glossary, forbidden, length_ratio, untranslated, omission}, blocked, flagged, clean}` |
| `edit_distance(a, b)` | FR-29 | Levenshtein over characters / max length, 4 dp — no extension, multibyte-safe |
| `trigrams`, `trigram_similarity(a, b)` | FR-03 fuzzy (reference) | character trigrams of `'  ' ‖ lower(normalised) ‖ ' '`, Jaccard, 3 dp; the runtime also uses pg_trgm and vectors — this is the deterministic reference score |
| `tm_lookup(text, src, tgt)` | FR-03 / AI-07 | exact by hash first and alone; else trigram candidates ≥ `tm_fuzzy_threshold`, top 5 |
| `classify(text)` | FR-09 / FR-10 / AI-05 | keyword weights summed per class (ties by enum order); `confidence = min(0.99, 0.5 + 0.1 × (top process + top message) − 0.1 × (runner-ups))`, 2 dp |
| `extract_entities(text)` | FR-11 | patterns per entity (first group; direction canonical) + glossary terms of domain defect / parameter / metric found in the text |
| `suggested_checks(process, type)`, `related_docs(entities, process)` | FR-12, FR-13, AI-09 | curated ids in order; documents whose tags match an entity value or the process, by title |
| `interpret(segment)` | FR-09…FR-15 | classify + entities + timing note; below the threshold (or no class) ⇒ `ambiguous` (readings must exist); else the assertion with curated checks and indexed documents |
| `add_segment(job, ordinal, src, mt, anchor)` | FR-03 | exact hit ⇒ the TM target with `tm_score 1.000` and an `exact` match; else the MT text plus fuzzy candidates with a diff; updates the job counts |
| `edit_segment(segment, editor, text, ts)` | FR-29 / FR-30 | role check, edit row with distance, `final_text` under the edit context, status `edited` |
| `approve_segment(segment, reviewer, note, at)` | FR-24 / FR-30 | the approval update — the triggers do the gating and the write-back |
| `resume_job(job)` | NFR-07 | failed ⇒ running at the first unfinished file/segment |
| `eval_finalize(run)` | AI-02 / AI-05 | metrics from results; the trigger applies the gate and the regression flag |
| `term_consistency(term)`, `rollup_term_usage(date)`, `mine_candidates(job)` | FR-26, FR-23 | consistency in the approved memory; daily usage; recurring JA tokens not in the glossary |
| `render_text(segment)` | AC-08 | the two-part text: SOURCE / TRANSLATION, then a ruled INTERPRETATION (or POSSIBLE READINGS) block, then "Glossary terms applied" |

---

## 5. Guard triggers (section 16)

| Trigger | Table | Refuses with |
|---|---|---|
| `trg_glossary_guard` | `knowledge.glossary_term` | `GLOSSARY_APPROVER`, `GLOSSARY_EMPTY`, `FORBIDDEN_SHAPE`, `FORBIDDEN_IS_MANDATED` |
| `trg_glossary_version` | `knowledge.glossary_term` (after) | writes `term_version` (effective date / note from the session context) |
| `trg_tm_guard` | `knowledge.tm_segment` | `TM_IMMUTABLE`, `TM_APPROVER`, `TM_EMPTY` |
| `trg_tm_index` | `knowledge.tm_segment` (after insert) | `TM_DUPLICATE_SOURCE`; maintains `tm_index` |
| `trg_segment_checks` | `segment` | `TM_EXACT_PRIORITY`, `EDIT_CONTEXT_REQUIRED`, `APPROVE_ON_INSERT`, `SEGMENT_BLOCKED`, `SEGMENT_FLAGGED`, `APPROVER_ROLE`, `SEGMENT_APPROVED`; computes `checks_json` and the status |
| `trg_tm_writeback` | `segment` (after update of status) | `TM_CONFLICT`; writes the memory once and links it |
| `trg_interpretation_guard` | `interpretation` | `INTERPRETATION_NOT_LABELLED`, `READINGS_REQUIRED`, `AMBIGUOUS_CONFIDENCE`, `AMBIGUOUS_ASSERTS`, `CONFIDENCE_BELOW_THRESHOLD`, `CHECK_NOT_CURATED`, `RELATED_DOC_NOT_INDEXED` |
| `trg_reading_limit` | `reading` | `READINGS_MAX` |
| `trg_job_guard` | `translation_job` | `CONFIDENTIAL_IMMUTABLE`, `RESUME_REQUIRED`, `JOB_FINISHED`; sets timestamps |
| `trg_ocr_flag` | `ocr_region` | sets `low_confidence` (cannot be cleared) |
| `trg_eval_gate` | `eval_run` | `EVAL_INCOMPLETE`, `EVAL_GATE`; sets `passed`, `investigate` |
| `trg_candidate_guard` | `term_candidate` | `CANDIDATE_DECIDER` |
| `trg_*_append_only` | `segment_edit`, `term_version`, `eval_result` | `APPEND_ONLY` |

## 6. Views (section 17)
`v_review_queue` (FR-27: source, MT, final, TM score, badges, numbers missing/extra, glossary missing, forbidden hits, ratio, omission, fuzzy count), `v_segment_checks`, `v_job_progress` (FR-20/NFR-07), `v_glossary_current` (version, effective date, aliases), `v_term_consistency` (FR-26), `v_tm_stats` (NFR-03), `v_quality_dashboard` (FR-31: PED, compliance, TM reuse, throughput per day and pair), `v_eval_gate`, `v_ocr_flags`.

## 7. Indexes, sizing, retention
34 indexes: the platform's (core, knowledge HNSW/trigram, audit) plus `genba`: a trigram GIN on `tm_index.src_norm` (fuzzy), the unique (pair, hash) for exact lookups (NFR-03: an exact hit is one index probe over 500 k rows), jobs by status/user, segments by job and by open status, edits, matches, interpretations by class, readings, OCR regions and flags, versions, aliases, candidates, usage, eval runs, lower-cased tags. Sizing: 500 k TM segments ≈ 1.5 GB with vectors; documents of 20 pages ≈ 400 segments each. Retention ≥ 365 d for jobs/segments/edits (CHECK); glossary versions and memory are kept.

## 8. Roles (section 18)
| Role | Can | Cannot |
|---|---|---|
| `app_rw` (api) | jobs, roles, glossary (admins, via triggers), aliases, candidates, keywords, check items, patterns, units, bounds, tags, test sets, eval runs, exports; segments through `edit_segment` / `approve_segment`; TM inserts (write-back, TMX import — approver required) | update or delete memory, edits, versions, results |
| `worker_rw` (translate / interpret / doc / OCR workers) | jobs, files, segments, matches, interpretations, readings, OCR, candidates, usage, tags, eval results | glossary, memory, roles, versions; read credentials (`app_user` restricted to id/name/role) |
| `app_ro` | read all; users as id/name/role | write |
| `auditor_ro` | who translated what: jobs, segments, edits, matches, interpretations, readings, versions, roles, exports, eval, glossary, memory, documents, audit log | write |

---

## 9. The seed and its expected values (`db/seed_demo.sql`)

Generated by `seed14.py` from one data model that the Python twins also evaluate. Five users with GenbaGo roles (Nok translator, Pranee reviewer, admin), 30 glossary terms (each with version 1, effective 2026-09-01), 5 aliases, 11 unit aliases, 6 ratio bounds, 31 process and 35 message keywords, 13 curated check items (5 molding items mirroring MoldMind's parameter names), 13 entity patterns, 5 indexed documents with tags, 40 approved TM segments.

| Job | What it proves | Expected |
|---|---|---|
| **J1 / J1E** | **Appendix A** JA→TH and JA→EN: TM miss, MT text, clean checks (applied 不良率, 成形条件), interpretation | `injection_molding` / `problem_report`, confidence **0.91** (process 2.5 = 成形 1.0 + 成形条件 1.5; message 2.0 = 不良率 1.5 + 上昇 0.5; runner-up 変更 0.4), entities `{metric: [不良率], direction: up, parameter: [成形条件]}`, timing "sequence stated: the change precedes the increase (causal claim implied, not verified)", 5 curated checks, 4 related documents (all tagged `injection_molding`), `render_text()` = the two-part output (**AC-04, AC-08, AC-09**) |
| **J2** | the same source after J1's approval | exact hit: `tm_score 1.000`, method `exact`, text = the approved Thai, `doc_ref job:<J1>#1` (**AC-07**) |
| **J3** | 8D TH→JA, 12 segments | #2 `±0.05mm`, `3.2mm`, `LOT-2609-114` preserved (**AC-02**); #3 MT `3.5 mm` → missing `3.2mm` / extra `3.5mm` → **blocked**, edited (distance 0.0588) → clean; #4 修正措置 → glossary missing 是正処置 + forbidden hit → **flagged** (**AC-03**), edited (0.1176); #5 two Thai sentences → one → omission flag, edited (0.5417); #6 fuzzy candidate **0.921** (trigram, ≥ 0.85, offered not applied); 11 approved → 11 new TM segments; #12 `needs_review` |
| **J4** | photo of a vertical 検査基準書 | 3 vertical printed regions (0.981 / 0.972 / 0.966), one handwritten note 0.712 → `low_confidence`; every region linked to a segment; side-by-side result (**AC-06**) |
| **J5** | `不良品は現場で処理してください` | no process keyword; message tie-breaking gives confidence **0.55** < 0.60 → `ambiguous`, 3 readings (dispose / rework / handle), no assertion (**AC-05**) |
| **J6** | batch of 5 files | file 4 fails (corrupt XLSX) → job `failed`; `resume_job()` → running from ordinal 4 → done 5/5 (FR-20, NFR-07) |
| **J7** | HMI screenshot JA→EN, layout kept | 3 horizontal regions; numbers `85MPa`, `45MPa`, `3s`, `18s` preserved (FR-19) |
| **JD** | non-confidential `/jp` request from Discord | allowed only because `confidential = false` (C-03) |
| glossary | 是正処置 Thai rendering changed by the admin | version 2, effective 2026-10-01 (NFR-08) |
| memory | `v_tm_stats` | ja→en 11, ja→th 26, th→ja 16 = **53** (40 + 13 approvals) |
| evaluation | test set v1 (40), three runs | run 1 **1.0000 / 1.0000 / 0.1485 / 0.9250** passed; run 2 0.1388 passed; run 3 (prompt v2 candidate) **0.1885** passed but **investigate = true** (PED +0.0497 > 2 %) (**AC-01** at seed scale); the stored predictions equal `classify()` on every test segment (3 designed misses: #20 no cue, #39 keyword tie, #40 no cue) |
| totals | | 9 jobs, 30 segments, 13 approved, 53 TM, 3 interpretations, 3 readings, 7 OCR regions, 3 edits, 31 term versions, 120 eval results |

The `\echo` block prints each of these; 16 probes must each fail with the named guard (TEST-14 TC-003).

---

## 10. Verification (what was executed here)

| Check | Result |
|---|---|
| Block and object identity vs `00/db/schema.sql` (TC-002) | ✅ 16/16 blocks, 54/54 objects byte-identical |
| Static DDL (TC-003): balance, FK targets and order, PKs, 15 guard triggers, functions before use, grants | ✅ |
| Twins vs the seed (TC-005): every TM segment and every seed segment through `run_checks`; codes, glossary hits, forbidden, omission, ratio, untranslated; edit distances; TM exact/fuzzy; classification on 40 sentences; entities; related docs; eval metrics, gate and regression | ✅ `ALL SEED CHECKS OK: True` |
| PostgreSQL execution (TC-009) | ⚠️ **not executed** — no Docker daemon on the authoring machine |

## 11. Defects found while checking (fixed)
D1 a decimal point ended a Thai/English sentence — `3.2 mm` counted as two sentences → terminal punctuation must be followed by a space or the end; D2 a glossary term contained in a longer matching term (対策 ⊂ มาตรการแก้ไข, 検査 ⊂ 検査基準書) was demanded separately → longest match wins; D3 counters (回, 枚, 本, 台, 日) have no cross-language canonical unit → dropped from the unit list (the number is still compared); D4 an instruction keyword too specific (してください vs 従ってください) → ください; D5 a `/jp` request would have needed readings → the bot returns the translation only unless interpretation is requested; D6 set-returning JSON aliases referenced without `.value` → made explicit (also hardened in `13/db/schema.sql`); D7 `out` as a plpgsql variable → renamed.

## 12. Traceability
C-01 → DD-J01, `glossary_hits` · C-02 → DD-J01, DD-J02, `extract_codes` · C-03 → DD-J08 · C-04 → DD-J01 (`omission`, `untranslated`) · C-05 → DD-J06 · FR-02 → `sentence_count` · FR-03 → DD-J03, DD-J04 · FR-04/05 → DD-J01 · FR-09…15 → DD-J06, `classify`, `extract_entities`, `interpret` · FR-16…20 → §3.2, §3.3, DD-J08 · FR-21…26 → §3.1, DD-J07 · FR-27…31 → §3.2, DD-J02, DD-J05, `v_review_queue`, `v_quality_dashboard` · AI-02/05/08 → DD-J09, `eval_finalize` · AI-06 → `trg_ocr_flag` · AI-07 → DD-J04 · AI-09 → DD-J06 · NFR-03 → §7 · NFR-05 → §8 · NFR-07 → DD-J08 · NFR-08 → DD-J07 · AC-01…09 → §9.
