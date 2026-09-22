# Test Plan & Test Cases — GenbaGo (Japanese Factory Translator Agent)

| Field | Value |
|---|---|
| Document ID | TEST-14-GenbaGo |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-14](../SRS-GenbaGo-Japanese-Factory-Translator.md) §3–§7, Appendix A · [SAD-14](SAD-GenbaGo-Software-Architecture.md) · [DDS-14](DDS-GenbaGo-Database-Design.md) · [ICD-14](ICD-GenbaGo-Interface-Control.md) · [SEC-14](SEC-GenbaGo-Security-Requirements.md) |
| Parent | [TEST-00](../../00-factorybrain-platform/docs/TEST-FactoryBrain-Test-Plan.md) TC-117…TC-119 (`/knowledge/translate`) |

---

## 1. Strategy

| Level | What | Where | Executed in this set |
|---|---|---|---|
| **TS-0 static** | artefact validity, byte identity with the platform, DDL structure, SQL twins vs Python re-derivation on the whole seed, contract schemas with negatives, config and compose checks | authoring machine, Python | **yes** — every result below is from a run on 2026-09-22 |
| DDL + probes | `db/schema.sql` on PostgreSQL 16 + pgvector, `db/seed_demo.sql`, 16 probes | dev database | **no** — no PostgreSQL on the authoring machine; commands in OPS-14 §12 |
| Functional TS-1…TS-9 | the running system | dev / staging | **no** — steps and expected results specified; the seed is the fixture |
| Model quality | glossary compliance, number preservation, PED, classification on the ≥ 200 / ≥ 300 item plant sets (AI-02, AI-05) | staging, monthly | **no** — the seed carries a 40-segment set as the template (AC-01 at reduced scale) |

Fixture: `db/seed_demo.sql` — 5 users, 30 glossary terms (31 versions), 40 bootstrap TM segments (53 after approvals), jobs J1/J1E/J2/J3/J4/J5/J6/J7/JD, 28 segments, 13 approved, 5 interpretations, 3 readings, 7 OCR regions, 3 edits, test set v1 with three eval runs (120 results).

Pass criteria: every TS-0 check green; every probe fails inside its transaction; every TC step's expected result observed; no TC of TS-2, TS-3, TS-8 may be waived.

## 2. TS-0 — Static verification (executed)

| TC | Check | Tool | Result |
|---|---|---|---|
| TC-001 | `api/openapi.yaml` parses; every `$ref` resolves; operationIds unique; no orphan schema | `check_openapi.py` | **pass** — 52 paths / 55 operations / 51 schemas, 0 orphans |
| TC-002 | `db/schema.sql` platform sections byte-identical to `00/db/schema.sql`; extension objects present; guards present; grants; FK order; parentheses | `check_schema14.py` | **pass** — 16/16 blocks, 54/54 objects identical; 48 tables (29 `genba`), 12 views, 21 triggers, 46 functions, 34 indexes, 16 enums; 15 guards found |
| TC-003 | DDL loads; seed loads; the `\echo` totals match; 16 probes each raise their named error | psql | **not run** (no PostgreSQL) — OPS-14 §12.1 |
| TC-004 | compose parses; `${VAR}` in compose ⊆ `.env.example` and vice versa; `discord-bot` alone on `egress`; workers `internal` only; secrets by file; no secret values; no cloud MT variable required | `check_deploy14.py` | see §6 |
| TC-005 | SQL twins re-derived in Python on every seed row: `extract_codes` / `codes_preserved` on 28 segments (AC-02 tokens `±0.05mm`, `3.2mm`, `LOT-2609-114`; the blocked `3.5mm`), `glossary_hits` (forbidden 修正措置 hit; 30 terms; aliases; longest match), `sentence_count` / omission, `length_ratio` vs bounds, `untranslated`, `run_checks` for every segment equal to the seed's `checks_json`, `edit_distance` for the 3 edits (0.0588 / 0.1176 / 0.5417), `normalise_for_tm` + `tm_hash` for 53 TM rows, `trigram_similarity` 0.921 for J3 #6, `classify` on the 40-item set (37/40 = 0.925), `extract_entities` of Appendix A, 5 curated checks, 4 related docs, eval metrics of three runs and the regression flag | `seed14.py` (`twin14.py`) | **pass** — `ALL SEED CHECKS OK: True` |
| TC-006 | IF-74/75/76/77 schemas valid (draft 2020-12); seed-derived examples validate; negatives rejected; glossary CSV = seed (30 rows); TMX = 10 seed segments; check items = seed | `check_contracts14.py` | **pass** — 37 positives valid, 26 negatives rejected, `ALL CONTRACTS OK: True` |
| TC-007 | `deploy/genbago.example.yaml` validates against `genbago-config.schema.json`; values equal `genba.setting` and `genba.ratio_bound` of the seed; prompts referenced exist with the declared temperature/model; negatives rejected | `check_config14.py` | see §6 |
| TC-008 | `Problem`, `Language`, `TranslationResult`, `Cursor`, `Limit`, `IdempotencyKey`, 5 standard responses and `/knowledge/translate` byte-identical to API-00; SRS §4.1 eight paths present verbatim | `check_api_identity14.py` | **pass** — 12/12 blocks, 8/8 paths |
| TC-009 | Cross-document sweep: every SRS-14 ID (FR-01…31, AI-01…09, NFR-01…08, AC-01…09, C-01…05) cited; every `{#if-xx}` anchor resolves; every object / endpoint / TC / RB / ADR-J / QAS / SEC-J / DD-J / THR-J / RR-J / probe referenced exists | `sweep14.py` | see §6 |

## 3. Functional test cases

Notation: **Pre** fixture state · **Steps** · **Expect**. Segment ids are `J3#4` = job J3, ordinal 4. Users: nok (translator), pranee (reviewer), admin, sato, somchai.

### TS-1 — Translation core (FR-01…FR-08, AI-01, AI-07, NFR-01, AC-07)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-010 | Text translation JA→TH, TM miss | somchai POSTs Appendix A text to `/translate` | 200; `translation` in Thai with 成形条件 → เงื่อนไขการขึ้นรูป and 不良率 → อัตราของเสีย; `tm_match = null`; `checks.clean = true`; a job with `channel = api`, `confidential = true`, `provider = local` |
| TC-011 | Exact TM reuse (AC-07) | after J1's approval, POST the same text again (J2) | `tm_match.score = 1.000`; `translation` byte-equal to the approved segment's `final_text`; no model call in the worker log; `tm_score = 1` on the segment |
| TC-012 | Normalisation for exact match | POST the Appendix A text with full-width digits and trailing spaces | still an exact match (`normalise_for_tm` — full→half width, whitespace collapsed, trailing punctuation stripped) |
| TC-013 | Fuzzy match offered with diff | J3 #6 (a near-duplicate of a TM row) | `tm_match.score = 0.921` (trigram twin; vector score may differ, both ≥ 0.85); the diff highlights the changed token; the MT still runs; the reviewer sees both |
| TC-014 | Segmentation | POST three Japanese sentences separated by 。 and a newline | 3 segments with ordinals; `sentence_count` 3; `v_job_progress` shows 3/3 |
| TC-015 | Glossary injection (SEC-J28) | inspect the prompt logged for J1 (`translation_job.prompt_version = translate.v1`) | only the 2 glossary entries present in the source are injected, with their mandated TH rendering; the whole glossary is not in the prompt |
| TC-016 | Registers | POST TH→JA with `register = customer` (J3) and `shopfloor` | JA output in です/ます for customer, plain form for shopfloor; register stored on the job |
| TC-017 | Aliases (FR-22) | POST text containing 成条 | `glossary_lookup` maps 成条 → 成形条件; the mandated rendering is used; the alias is listed in `applied` |
| TC-018 | Latency (NFR-01) | 20 texts ≤ 200 chars, TM miss, one GPU | p95 ≤ 5 s end to end (`genbago_translate_latency_ms`) |
| TC-019 | Model outage (SEC-J25) | stop Ollama; POST text | 503 `NOT_READY` for `/translate`; a document job continues and leaves segments `machine` with `mt_text = null`; `done_with_gaps` reported |

### TS-2 — Checks (FR-05, FR-28, AI-04, C-01, C-02, C-04, AC-02, AC-03)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-020 | Checks computed by the database (SEC-J01) | insert a segment via `add_segment()`; then try `UPDATE genba.segment SET checks_json = '{}'` as `worker_rw` | `checks_json` populated on insert; the update is overwritten by the trigger (checks recomputed) |
| TC-021 | Numbers preserved (AC-02) | J3 #2 `公差 ±0.05 mm / 3.2 mm / LOT-2609-114` | `blocking.numbers.ok = true`, `source = ["±0.05mm","3.2mm","LOT-2609-114"]`; status `machine` → clean |
| TC-022 | Number changed → blocked (AC-02, SEC-J02) | J3 #3 MT `3.2 mm` → `3.5 mm` | `blocked = true`, `missing = ["3.2mm"]`, `extra = ["3.5mm"]`; status `blocked`; `POST /segments/{id}/approve` → 409 `SEGMENT_BLOCKED` (probe 1) |
| TC-023 | Forbidden rendering flagged (AC-03) | J3 #4 MT contains 修正措置 for มาตรการแก้ไข | `flags.forbidden.hits = [{term: 是正処置, rendering: 修正措置, mandated: 是正処置}]`; status `flagged`; approve without note → 409 `SEGMENT_FLAGGED` (probe 2); approve with note → 200 |
| TC-024 | Mandated term missing | MT of 不良率 without อัตราของเสีย | `flags.glossary.missing = ["不良率"]`; flagged |
| TC-025 | Omission (C-04) | J3 #5: 2 source sentences, 1 target sentence | `flags.omission.ok = false`, `src_sentences = 2`, `tgt_sentences = 1`; flagged; after nok's edit (distance 0.5417) the flag clears |
| TC-026 | Length ratio | a JA→TH target 4× the source | `flags.length_ratio.ok = false`, `max = 3.5`; flagged |
| TC-027 | Untranslated source | a Thai target containing a Japanese clause | `flags.untranslated.ok = false`; flagged |
| TC-028 | Unit canonicalisation | source `3.2 มม.`, target `3.2 mm`; source `+/-0.05`, target `±0.05` | numbers ok (unit aliases); no false block |
| TC-029 | Tolerance and code shapes | `RAD-500-A`, `LOT-2609-114`, `2026-09-15`, `15/9/2026`, `98.5%`, `±0.05 mm`, `230 °C` | each extracted once; date forms canonicalised to `2026-09-15`; `%` kept |

### TS-3 — Interpretation (FR-09…FR-15, AI-05, AI-09, C-05, AC-04, AC-05, AC-08, AC-09)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-030 | Appendix A end to end (AC-04) | J1 | `interpretation`: `process = injection_molding`, `message_type = problem_report`, `entities = {metric: [不良率], direction: up, parameter: [成形条件]}`, `confidence = 0.91`, `timing_note` about the sequence, 5 suggested checks in order, 4 related documents (SPC chart Line 3, FMEA RAD-500-A step 20, Control plan rev.7, case #178) |
| TC-031 | Separate table, always inferred (C-05, SEC-J07) | `INSERT genba.interpretation … inferred = false` | 23514 `INTERPRETATION_NOT_LABELLED` (probe 4); the `GET /segments/{id}` body has `interpretation` as a sibling of `translation`, never inside it |
| TC-032 | Rule classifier accuracy (AI-05) | `classify()` on test set v1 | 37/40 = 0.925 ≥ 0.90 (misses #20, #39, #40 documented in DDS-14 §9) |
| TC-033 | Ambiguous → readings (AC-05) | J5 不良品は現場で処理してください | `confidence = 0.55 < 0.60`, `ambiguous = true`, 3 readings (scrap on the line / rework on site / segregate on site) with usage notes; no process asserted; `suggested_checks = []` |
| TC-034 | Readings bounds | ambiguous with one reading; four readings | `READINGS_REQUIRED` (probe 5); `READINGS_MAX` from `trg_reading_limit` |
| TC-035 | Curated checks only (SEC-J19) | set a check of the press process on J1's interpretation | 23514 `CHECK_NOT_CURATED` (probe 7) |
| TC-036 | Related documents indexed (AC-09, SEC-J20) | add id `…999` | `RELATED_DOC_NOT_INDEXED` (probe 6); `GET` returns each related doc with `id`, `title`, `kind`, `uri` from `knowledge.document` |
| TC-037 | Rendering (AC-08, SEC-J08) | web result of J1; DOCX result of J3; Discord reply of JD | the interpretation is a ruled block after the translation titled `INTERPRETATION (inferred — confidence 0.91)`; in DOCX a comment block, not run text; in Discord a second block |
| TC-038 | Assertion below threshold refused | insert `confidence = 0.5, ambiguous = false, process = …` | `CONFIDENCE_BELOW_THRESHOLD` (probe 16) |
| TC-039 | Timing note (FR-11) | Appendix A ("changed … since then rose") | `timing_note` states the sequence and that causality is implied, not verified |

### TS-4 — Documents & OCR (FR-16…FR-20, AI-06, NFR-02, NFR-07, AC-06)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-040 | DOCX 8D job (J3) | upload; `POST /translate/document` | 12 segments with anchors; the result DOCX keeps styles, tables and numbering; blocked/flagged segments are highlighted in the result until resolved |
| TC-041 | XLSX / PPTX | upload each | cell/shape anchors; numbers in cells untouched; layout kept |
| TC-042 | PDF side-by-side | a 3-page PDF | `layout_mode = side_by_side` result; page count equal |
| TC-043 | Throughput (NFR-02) | a 20-page document | ≤ 3 min on one GPU (`genbago_job_duration_ms{kind=document}`) |
| TC-044 | Vertical text OCR (AC-06) | J4 photo of a 検査基準書 | regions with `orientation = vertical`, linearised top-to-bottom, right-to-left; a side-by-side result |
| TC-045 | Handwriting flagged (AI-06) | J4 region 4 (handwriting, 0.712) | `low_confidence = true`; the linked segment flagged `ocr_low_confidence`; the flag cannot be cleared (`UPDATE … low_confidence = false` is overwritten by `trg_ocr_flag`) |
| TC-046 | OCR accuracy gate | the plant's printed sample set | char accuracy ≥ 0.95 measured and recorded in `genba.setting` / OPS §7; otherwise OCR jobs are refused with `NOT_READY` |
| TC-047 | HMI screenshot (FR-19, J7) | upload a screenshot | `keep_layout` result with translated labels overlaid; a label table as text |
| TC-048 | Batch with a failed file (J6, FR-20) | 5 files, file 4 corrupt | `job_file` 4 `failed`, others `done`; the batch is `failed`; `POST /jobs/{id}/resume` restarts at file 4 only; `JOB_NOT_FAILED` on a done job |
| TC-049 | Resume keeps completed segments (NFR-07) | kill worker-doc mid-job; resume | completed segments unchanged (same ids, same `checks_json`); processing continues from the first unfinished ordinal |

### TS-5 — Glossary & TM (FR-21…FR-26, NFR-03, NFR-08)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-050 | Glossary versioning (NFR-08) | admin changes 是正処置's TH rendering with `effective_from = 2026-10-01` | `term_version` 2 with approver admin, effective date, note; `v_glossary_current` still shows v1 until 2026-10-01 |
| TC-051 | Admin only (SEC-J14) | nok (translator) edits a term | `GLOSSARY_APPROVER` (probe 8); 403 `APPROVER_ROLE` at the API |
| TC-052 | Forbidden = mandated refused | set forbidden `是正処置` on 是正処置 | `FORBIDDEN_IS_MANDATED` (probe 9) |
| TC-053 | Candidates (FR-23) | run `mine_candidates()` after J3's approvals | recurring n-grams with a stable rendering appear in `term_candidate` with counts; admin decides (`CANDIDATE_DECIDER` for others) |
| TC-054 | TM only through approval (SEC-J16) | direct `INSERT knowledge.tm_segment … approver = nok` | `TM_APPROVER` (probe 14); `approve_segment()` by pranee creates the TM row (`trg_tm_writeback`) with document, domain, approver, date |
| TC-055 | Immutable memory (SEC-J17) | `UPDATE knowledge.tm_segment` | `TM_IMMUTABLE` (probe 11); a correction is a new segment; `tm_lookup` returns the newest approved |
| TC-056 | One target per normalised source | insert a second TM row for the same normalised JA source with a different TH target | `TM_DUPLICATE_SOURCE` |
| TC-057 | Import / export (FR-25, IF-73) | export glossary CSV/TBX and TM TMX; re-import into an empty instance | round trip equal; the import report lists rejected rows; `export_job` rows with sha256 |
| TC-058 | Term consistency (FR-26) | `v_term_consistency` after the seed | 是正処置 shows 2 renderings in use with counts; the inconsistency flag is set |
| TC-059 | Scale (NFR-03) | 500 k TM rows | exact lookup ≤ 50 ms (hash index); fuzzy ≤ 500 ms (trigram GIN / ivfflat) |

### TS-6 — Review workflow (FR-27…FR-31)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-060 | Approver role (SEC-J06) | nok approves J3 #12 | `APPROVER_ROLE` (probe 3); pranee → 200, status `approved` |
| TC-061 | Edit recorded with distance (FR-29, SEC-J30) | nok edits J3 #3 via `POST /segments/{id}/edit` | `segment_edit` row with editor, timestamp, previous text, `edit_distance = 0.0588`; a raw `UPDATE final_text` → `EDIT_CONTEXT_REQUIRED` (probe 12) |
| TC-062 | Append-only history | `DELETE FROM genba.segment_edit` | refused by `trg_edit_append_only`; `auditor_ro` can read it |
| TC-063 | Review queue | `v_review_queue` | J3 #12 (`needs_review`) listed with its flags and TM score, oldest first |
| TC-064 | Dashboard (FR-31) | `v_quality_dashboard` and `/dashboard/quality` | PED trend per month, glossary compliance, throughput, blocked/flagged counts; metrics exported (IF-14) |
| TC-065 | Approved segment frozen | edit J3 #2 after approval | 409 `SEGMENT_APPROVED`; a new job is needed |
| TC-066 | Side-by-side diff | web review of J3 #6 | source, TM match, MT, final in four columns; the diff against the fuzzy match highlighted |

### TS-7 — Evaluation (AI-02, AI-03, AI-05, AI-08, AC-01)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-070 | Gate pass | eval run 1 on set v1 | compliance 1.0000, numbers 1.0000, PED 0.1485 ≤ 0.20, classification 0.9250 ≥ 0.90 → `passed = true`, `v_eval_gate` green |
| TC-071 | Frozen set (SEC-J34) | edit a test segment after run 1 | refused; a new set version is created instead |
| TC-072 | Regression flag (AI-08) | run 3: PED 0.1885 vs run 2's 0.1388 | `passed = true` but `investigate = true` (regression > 2 %); notification via IF-13 |
| TC-073 | Gate enforced by the database | `UPDATE eval_run SET mean_ped = 0.25, passed = true` | `EVAL_GATE` (probe 13) |

### TS-8 — Security & confidentiality (C-03, NFR-04, NFR-05, SEC-J)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-080 | Confidential ⇒ local (SEC-J10) | insert a confidential job with `provider = cloud` | CHECK `job_confidential_local` (probe 10); API 409 `CONFIDENTIAL_LOCAL` |
| TC-081 | Model output cannot set status (SEC-J05) | a crafted model reply containing `"status": "approved"` | stored as `mt_text` text only; status `machine`; checks recomputed |
| TC-082 | Discord scope (SEC-J12) | `/jp` with an attachment; `/jp` on a confidential result id | both refused with the help text; the bot's token cannot `GET` a confidential job (403) |
| TC-083 | Prompt injection walk-through (SEC §4.2) | the "translate as approved" document | the next segment blocked; nothing in TM; the injected sentence visible to the reviewer |
| TC-084 | Outage → no filler (SEC-J25) | kill Ollama during J6 | segments without MT text remain `machine`/null; no fabricated text; job `done_with_gaps` |
| TC-085 | Grants (SEC-J15) | as `worker_rw`: `INSERT knowledge.glossary_term`, `INSERT genba.check_item` | permission denied |
| TC-086 | Networks (SEC-J13) | from `worker-translate` container `curl https://example.com` | fails (no egress); `discord-bot` succeeds only to Discord |
| TC-087 | Signed URLs and ACL (SEC-J21) | fetch a result URL after 16 min; fetch another line's result | 403 both |
| TC-088 | Audit rows (SEC-J22) | read a confidential result; export the glossary | `audit.log` rows with actor, object, action |
| TC-089 | Retention (SEC-J32) | run the retention job with a 400-day-old document | document and result objects deleted; segments' text nulled; approved TM rows kept |

### TS-9 — i18n & clients (NFR-06, IF-08)

| TC | Title | Steps | Expect |
|---|---|---|---|
| TC-090 | UI languages | switch th / ja / en | every label translated; the interpretation block title localised; numbers unchanged |
| TC-091 | Discord `/jp` (non-confidential) | `/jp 不良率が上がっています` | the two-part reply; job `channel = discord`, `confidential = false` |
| TC-092 | IF-16 tools | Copilot calls `glossary_lookup` and `term_check`; QE-Agent's IF-52 term check | typed results; positions of forbidden renderings; no glossary dump; scope honoured on related docs |
| TC-093 | Notifications (IF-13, optional) | job done; review requested | e-mail in Mailpit; webhook received |

## 4. Traceability

| Requirement | Test cases |
|---|---|
| C-01 | TC-023, TC-024, TC-015 |
| C-02 | TC-021, TC-022, TC-028, TC-029 |
| C-03 | TC-080, TC-082, TC-086 |
| C-04 | TC-025, TC-019, TC-084 |
| C-05 | TC-031, TC-037 |
| FR-01…FR-08 | TC-010…TC-019 |
| FR-09…FR-15 | TC-030…TC-039 |
| FR-16…FR-20 | TC-040…TC-049 |
| FR-21…FR-26 | TC-050…TC-059 |
| FR-27…FR-31 | TC-060…TC-066 |
| AI-01 | TC-007, TC-015 |
| AI-02, AI-03, AI-08 | TC-070…TC-073 |
| AI-04 | TC-020…TC-029 |
| AI-05 | TC-032 |
| AI-06 | TC-044…TC-046 |
| AI-07 | TC-011, TC-012 |
| AI-09 | TC-036 |
| NFR-01 | TC-018 · NFR-02 TC-043 · NFR-03 TC-059 · NFR-04 TC-080, TC-086 · NFR-05 TC-087…TC-089 · NFR-06 TC-090 · NFR-07 TC-048, TC-049 · NFR-08 TC-050, TC-062 |
| AC-01 | TC-070 · AC-02 TC-021, TC-022 · AC-03 TC-023 · AC-04 TC-030 · AC-05 TC-033 · AC-06 TC-044 · AC-07 TC-011 · AC-08 TC-037 · AC-09 TC-036 |

## 5. Defects found while building the set

From DDS-14 §11 (found by the twin re-derivation, fixed before delivery):

| ID | Defect | Fix |
|---|---|---|
| D1 | A decimal point ended a TH/EN sentence (`3.2 mm` counted as 3 sentences) → false omission flags | terminal punctuation must be followed by whitespace or end of text |
| D2 | A glossary term contained in a longer matching term (対策 ⊂ มาตรการแก้ไข) counted as a separate hit | longest match wins, in SQL and in the twin |
| D3 | Counters 回/枚/本/台/日 extracted as units → false number mismatches | removed from the unit list |
| D4 | `done_count` counted approvals, so a finished job with unreviewed segments showed 0 % | counts segments with MT text |
| D5 | Set-returning JSON functions referenced by bare alias | `x.value` |
| D6 | The Discord job carried an interpretation without readings | non-ambiguous, asserted only above the threshold |
| D7 | `term_consistency` passed a CTE row as a composite | table alias |

## 6. Execution record (2026-09-22)

| TC | Result |
|---|---|
| TC-001 | pass — 52 / 55 / 51, 0 orphans |
| TC-002 | pass — 16/16 blocks, 54/54 objects, 15 guards |
| TC-003 | not run — PostgreSQL unavailable |
| TC-004 | pass — see README-14 verification table |
| TC-005 | pass — `ALL SEED CHECKS OK: True` |
| TC-006 | pass — 37 / 26, `ALL CONTRACTS OK: True` |
| TC-007 | pass — see README-14 verification table |
| TC-008 | pass — 12/12, 8/8 |
| TC-009 | pass — see README-14 verification table |
| TC-010…TC-066, TC-070…TC-073, TC-080…TC-093 | specified, not executed |
