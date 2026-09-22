# API Specification — GenbaGo (Japanese Factory Translator Agent)

| Field | Value |
|---|---|
| Document ID | API-14-GenbaGo |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **52 paths / 55 operations / 51 schemas** |
| Source | [SRS-14 §4.1](../SRS-GenbaGo-Japanese-Factory-Translator.md) · [SAD-14](../docs/SAD-GenbaGo-Software-Architecture.md) · [DDS-14](../docs/DDS-GenbaGo-Database-Design.md) |
| Parent | [API-00](../../00-factorybrain-platform/api/API-Specification.md) — `/knowledge/translate` and `TranslationResult` are served verbatim |

---

## 1. Conventions

- Base URL `https://genbago.plant.local/api/v1` (standalone) or the platform gateway (`/knowledge/translate` at the platform root; the rest under `/genba/`). JSON, UTF-8, RFC 3339 timestamps in plant time.
- **SRS-14 §4.1 verbatim**: `POST /translate`, `POST /translate/document`, `GET /jobs/{id}`, `POST /ocr`, `GET /glossary?q=`, `POST /glossary`, `POST /tm/search`, `POST /segments/{id}/approve`.
- **Platform verbatim** (TEST-14 TC-008, 12/12 blocks byte-identical): `/knowledge/translate`, `TranslationResult`, `Language`, `Problem`, `Cursor`, `Limit`, `IdempotencyKey`, the five standard error responses.
- Auth: platform JWT. GenbaGo roles are rows (`genba.user_role`): translator edits, reviewer approves, admin changes the glossary and roles (FR-30); every platform user reads.
- Errors: RFC 7807 with a stable `code` (§9). Every `409` is a database refusal surfaced as is (DDS-14 §5).
- Files: documents and images are referenced by `s3://` URIs in the local object store (IF-10); the API never accepts a public URL (C-03).

### 1.1 Mapping of the SRS paths
| SRS-14 §4.1 | Operation | Notes |
|---|---|---|
| `POST /api/v1/translate` | `translateText` | synchronous ≤ 2,000 chars; `202` + job otherwise |
| `POST /api/v1/translate/document` | `translateDocument` | DOCX / XLSX / PPTX / PDF, layout preserved; `202` |
| `GET /api/v1/jobs/{id}` | `getJob` | status, counts, result link |
| `POST /api/v1/ocr` | `ocrImage` | IF-76 result, or `202` job with `translate: true` |
| `GET /api/v1/glossary?q=` | `searchGlossary` | plus `lang`, `domain` |
| `POST /api/v1/glossary` | `upsertGlossaryTerm` | admin; every change a version |
| `POST /api/v1/tm/search` | `searchTm` | exact first, then fuzzy with diff |
| `POST /api/v1/segments/{id}/approve` | `approveSegment` | reviewer; writes the memory |

---

## 2. Tags
`translate` · `jobs` · `segments` · `review` · `glossary` · `tm` · `tools` (IF-16 provider) · `evaluation` · `knowledge` (platform) · `admin` · `system`.

---

## 3. The translation contract (`translate`)

`POST /translate {text, source_lang?, target_lang, register?, interpret?, confidential?}` →

```json
{
  "source_text": "成形条件を変更した後、不良率が上昇しました。", "source_lang": "ja",
  "translation": "หลังจากเปลี่ยนเงื่อนไขการขึ้นรูป อัตราของเสียเพิ่มขึ้น", "target_lang": "th",
  "tm_match": null,
  "glossary_applied": ["不良率", "成形条件"],
  "checks": { "numbers_preserved": true, "glossary_compliant": true, "omission_suspected": false },
  "interpretation": { "inferred": true, "confidence": 0.91, "process": "injection_molding", "message_type": "problem_report", "entities": {"metric": ["不良率"], "direction": "up", "parameter": ["成形条件"]}, "suggested_checks": ["Melt / mould temperature", "…"] },
  "job_id": "…", "segments": [ … ], "interpretation_detail": { … IF-75 … }, "rendered": "SOURCE (JA)\n…\n──────── INTERPRETATION (inferred — confidence 0.91) ────────\n…"
}
```

Rules the caller may rely on:
1. **Memory first.** If the normalised source has an approved target for the pair, `tm_match.score = 1.000`, `translation` is that target verbatim, and no model was called (FR-03, AC-07). Fuzzy candidates (≥ 0.85) are returned on the segment (`/segments/{id}/matches`) with a diff and are never applied.
2. **Glossary applied and verified.** Terms found in the source are injected; `glossary_applied` lists those verified in the output; a missing mandated term or a forbidden rendering is a flag on the segment (C-01, AC-03).
3. **Numbers or refusal.** `checks.numbers_preserved = false` means the segment is *blocked*: the translation is returned for correction but cannot be approved (C-02, AC-02).
4. **Two parts.** `interpretation` is the platform shape; `interpretation_detail` is the full IF-75 object; both carry `inferred: true`; `rendered` shows them as two blocks (C-05, AC-08). With `interpret: false` both are `null`.
5. **Register** (`report` / `shopfloor` / `customer`) changes phrasing only; never terms or numbers (FR-06).
6. **Language pairs**: any of ja / th / en to any other; source auto-detected when omitted.

---

## 4. The check contract (`segments/{id}/checks`)

`SegmentChecks` (IF-74) is computed by the database on every text change and never supplied:

| Group | Check | Effect | Resolution |
|---|---|---|---|
| `blocking.numbers` | every number (with sign, tolerance, canonical unit), code, lot and date in the source appears in the target with the same multiplicity — `missing` / `extra` list the difference | status **`blocked`**; approval refused (`409 SEGMENT_BLOCKED`) | edit the target (`POST /segments/{id}/edit`) — the check recomputes |
| `flags.glossary` | mandated renderings of the terms found in the source (longest match wins) | `flagged` | edit, or a reviewer note on approval |
| `flags.forbidden` | forbidden renderings for the target language | `flagged` | edit (the mandated term is given) or a justified note |
| `flags.length_ratio` | chars(target)/chars(source) within the pair's bounds | `flagged` | note |
| `flags.untranslated` | Japanese script in a TH/EN target, Thai in a JA target | `flagged` | edit |
| `flags.omission` | fewer sentences in the target than in the source | `flagged` | edit or note |

`clean = numbers ok ∧ no flag`. A flagged segment can be approved only with `note` (`409 SEGMENT_FLAGGED` otherwise); a blocked one never.

---

## 5. The interpretation contract (`segments/{id}/interpretation`, `readings`)

`Interpretation` (IF-75): `inferred: true` always; `confidence`; either an **assertion** (`ambiguous: false`, `process`, `message_type`, `entities`, `timing_note`, `suggested_checks` = curated `CheckItem`s for that process × type, `related_documents` = documents that exist in the index, each with an id) or an **ambiguous reading** (`ambiguous: true`, `readings[2..3]` with usage notes, nothing suggested). The threshold is 0.60: an assertion below it or a reading above it is refused by the database. `related_documents` never contains free text — a document that is not in the index is not a related document (AI-09, AC-09). `GET /segments/{id}/render` returns the two-part text exactly as the UI, DOCX and Discord renderers show it.

---

## 6. The review & memory contract (`review`, `segments`, `tm`)

| Step | Call | Who | Effect |
|---|---|---|---|
| queue | `GET /review` | translator, reviewer | source, MT, final, TM score, badges (blocked / flagged), missing numbers, glossary misses, forbidden hits, fuzzy count |
| edit | `POST /segments/{id}/edit {text}` | translator+ | `segment_edit` row with the normalised Levenshtein distance; checks recomputed; status `edited` (or `blocked` / `flagged` if still failing) |
| ready | `POST /segments/{id}/ready` | translator+ | `needs_review` (refused while blocked) |
| approve | `POST /segments/{id}/approve {note?}` | reviewer, admin | gates of §4; writes `knowledge.tm_segment` once (`tm_written_id`); `409 TM_CONFLICT` if the same source already has a different approved target |
| memory | `GET /tm/{id}`, `GET /tm/stats`, `POST /tm/search` | any | approved segments are immutable; one target per normalised source and pair |

Every edit and approval is auditable: who, when, distance (NFR-05, FR-29).

---

## 7. Documents, OCR and batch (`translate`, `jobs`)

- `POST /translate/document` / `POST /translate/batch` take an IF-77 `JobRequest`; `GET /jobs/{id}` reports counts (`segment_count`, `done_count`, `blocked`, `flagged`, `tm_exact`, files done/failed); `GET /jobs/{id}/result` returns the translated document, the side-by-side PDF or the batch report.
- Layout: DOCX/XLSX/PPTX keep styles and cells (segments carry an `anchor`); PDF and images produce `side_by_side`, `overlay` or `keep_layout` (HMI).
- OCR (`POST /ocr`): regions with `orientation` (vertical Japanese linearised), `char_confidence`, `handwriting`; `low_confidence` is set by the database and cannot be cleared (AI-06).
- Failure and resume: a failed batch keeps its finished items; `POST /jobs/{id}/resume` restarts at the first unfinished one (`409 JOB_NOT_FAILED` otherwise) (NFR-07).
- Confidentiality: `confidential` defaults to true; a confidential job with `provider: cloud` or `channel: discord` is `409 CONFIDENTIAL_LOCAL`; it can never be declassified afterwards.

---

## 8. Glossary & memory management (`glossary`, `tm`, `tools`)

- Terms: `GET /glossary?q=` (term, reading, alias), `POST /glossary` (admin; `effective_from`, `change_note` → a new `TermVersion`), `GET /glossary/{id}/versions`, aliases (`POST /glossary/{id}/aliases`), candidates mined from approvals (`GET /glossary/candidates`, `POST …/decide`), usage and consistency (FR-26).
- Exchange (IF-73): `POST /glossary/import` (CSV/TBX), `GET /glossary/export`, `POST /tm/import` (TMX/CSV — approver required; `409 TM_DUPLICATE_SOURCE`), `GET /tm/export`; every export records a sha256.
- IF-16 tools for siblings: `POST /tools/glossary_lookup {text, target_lang}` → the mandated renderings for the terms found; `POST /tools/term_check {text, lang}` → forbidden renderings and missing mandated terms with positions (QE-Agent's IF-52).
- Evaluation (`evaluation`): versioned test sets, `POST /eval/runs` → metrics computed and gated by the database (`passed`, `investigate`).

---

## 9. Error catalogue

| HTTP | `code` | Raised by |
|---|---|---|
| 401 / 403 | platform | missing or insufficient token / role |
| 404 | `NOT_FOUND` | unknown job, segment, term, TM segment, run |
| 409 | `SEGMENT_BLOCKED`, `SEGMENT_FLAGGED`, `APPROVER_ROLE`, `SEGMENT_APPROVED`, `TM_CONFLICT`, `EDITOR_ROLE` | review & memory (DDS-14 DD-J02, DD-J03, DD-J05) |
| 409 | `TM_IMMUTABLE`, `TM_APPROVER`, `TM_DUPLICATE_SOURCE`, `TM_EXACT_PRIORITY` | memory |
| 409 | `GLOSSARY_APPROVER`, `FORBIDDEN_IS_MANDATED`, `CANDIDATE_DECIDER` | glossary |
| 409 | `CONFIDENTIAL_LOCAL`, `CONFIDENTIAL_IMMUTABLE`, `JOB_NOT_FAILED`, `JOB_FINISHED`, `JOB_NOT_DONE` | jobs |
| 409 | `READINGS_REQUIRED`, `AMBIGUOUS_CONFIDENCE`, `CONFIDENCE_BELOW_THRESHOLD`, `CHECK_NOT_CURATED`, `RELATED_DOC_NOT_INDEXED` | interpretation (worker-side; surfaced when interpretation is requested) |
| 422 | `VALIDATION_FAILED` | request body or query; `EVAL_GATE` on an evaluation run |
| 429 | `RATE_LIMITED` | translations per user |
| 503 | `NOT_READY` | a dependency is down (`/readyz`) |

---

## 10. Roles per operation (summary)
| Operation group | viewer | translator | reviewer | admin |
|---|---|---|---|---|
| translate, OCR, jobs (own), glossary/TM read, tools | ✅ | ✅ | ✅ | ✅ |
| review queue, edit, ready | | ✅ | ✅ | ✅ |
| approve, all jobs, TM import/export | | | ✅ | ✅ |
| glossary write, aliases, candidates, roles, test sets, config | | | | ✅ |

Document ACLs (`knowledge.document.acl_json`) apply to related documents and job files; a user who may not read a document does not see it as a related document (SEC-14 O-5).
