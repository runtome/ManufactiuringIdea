# API Specification — Genba Memory

| Field | Value |
|---|---|
| Document ID | API-15-GenbaMemory |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1.0, **47 paths / 53 operations / 46 schemas** |
| Source | [SRS-15 §4.1](../SRS-GenbaMemory-Troubleshooting-RAG.md) · [SAD-15](../docs/SAD-GenbaMemory-Software-Architecture.md) · [DDS-15](../docs/DDS-GenbaMemory-Database-Design.md) |
| Related | [ICD-15](../docs/ICD-GenbaMemory-Interface-Control.md) · [SEC-15](../docs/SEC-GenbaMemory-Security-Requirements.md) · parent [API-00](../../00-factorybrain-platform/api/API-Specification.md) |

---

## 1. Conventions

Base path `/api/v1`. JSON in, JSON out. Bearer JWT except `/healthz` and `/readyz`. Errors are RFC 7807 `application/problem+json` with a stable `code`. Cursor pagination through the platform's `cursor` / `limit` parameters. Timestamps are RFC 3339 in the plant timezone.

**Verbatim from API-00** — twelve blocks, byte-identical (TEST-15 TC-001): `securitySchemes`, the parameters `DateFrom`, `DateTo`, `LineFilter`, `Cursor`, `Limit`, `IdempotencyKey`, `CaseId`, `DocumentId`, the seven standard `responses`, the schemas `Problem`, `Language` and `KnowledgeHit`, and the two paths `/knowledge/search` and `/knowledge/documents`. In platform mode the gateway serves those two; everything else lives under `/memory/`.

**SRS §4.1 verbatim** — the seven paths the SRS names are present with the methods it names: `POST /documents`, `GET /cases/{caseId}`, `POST /search`, `POST /similar`, `GET /analytics/recurring`, `POST /cases/{caseId}/verify`, `POST /feedback`.

---

## 2. Four rules the shape enforces

| Rule | Where it lives in the schema | SRS |
|---|---|---|
| Every answer names a real case and a retrievable original | `CaseCard.sources` is required with `minItems: 1`; there is no field anywhere that takes a list of case ids for one row | AI-07, AC-08, C-01 |
| Extracted is not verified | `CaseCard.badge` is required and has exactly two values; `SearchRequest.verified_only` defaults to `true`; a flagged field comes back as `null`, never stale | C-02, C-03, FR-28, FR-30 |
| The ACL is a predicate, not a filter | `RetrievalResult.n_acl_filtered` is required; nothing in the response carries a filtered row, a snippet of one, or a total that includes one | C-05, NFR-05, AC-05 |
| Ranking is arithmetic you can ask about | every `Hit` carries `scores` and `why`; `POST /search/explain` adds the weights in force | FR-18, FR-19 |

---

## 3. Ingestion

`POST /documents` (multipart) stores the original immutably and queues the pipeline. A repeated `sha256` is **not an error**: the job comes back `skipped` with the existing `document_id`, because re-dropping the same folder must be safe. `Idempotency-Key` makes a retried upload return the first result rather than a second job.

`POST /sources` defines a watched source and is validated against `deploy/schemas/source-connector.schema.json` (IF-78). A credential is never inline — `credentials_ref` names a file under the secrets directory, and anything else is refused with `SOURCE_CREDENTIAL_INLINE`. A source carries a `default_acl` that travels with everything it ingests, so a restricted share cannot quietly produce unrestricted cases.

`GET /ingest/errors` is the FR-07 surface: nine closed reasons, a human-readable `detail` and an `action` telling someone what to do. A failure never affects retrieval (NFR-07), which is also why `/readyz` reports `ingestion: degraded` without going unready.

---

## 4. The extraction contract

`worker-extract` speaks `deploy/schemas/case-extract.schema.json` (IF-79) and the API surfaces its result field by field:

```
GET /cases/{caseId}/fields →
  { "field": "cause",
    "value": "Proximity sensor abnormal (drifting output when hot).",
    "confidence": 0.94,
    "provenance": { "document_id": "…", "page": 3, "section": "D4 原因" },
    "extraction": { "model": "qwen2.5:7b-instruct-q4_K_M",
                    "prompt_version": "extract-case.v1",
                    "schema_version": "case-extract-1.0" },
    "human": false, "flagged": false }
```

Three things cannot be expressed in this contract, deliberately. An extraction cannot claim a field is verified (that is a human event, `POST /cases/{caseId}/verify`). It cannot supply a value without provenance. And it cannot mark an entity `mapped` without a canonical id — an unmapped value goes to curation instead of being guessed (FR-10).

`POST /cases` is the manual path (FR-14). Everything it writes is `human: true`, and it still needs at least one source before it can be verified: knowledge that exists only in someone's head becomes citable only once somebody attaches the note, photo or report it came from.

---

## 5. The retrieval contract

`POST /search` takes a query, a `scope`, a `require` and `verified_only`.

- **`scope` narrows the ranking**, through `entity_overlap`. A case outside the scope can still appear; that is FR-22, horizontal deployment — "cases like this on other machines".
- **`require` removes rows.** Use it when you mean a hard filter.
- **`verified_only` defaults to `true`.** Set it to `false` and unverified cases come back **badged**, never bare.

The response is `deploy/schemas/retrieval-result.schema.json` (IF-81). Its shape is the SRS Appendix A output:

```json
{ "n_candidates": 7, "n_results": 3, "n_acl_filtered": 0,
  "hits": [
    { "rank": 1, "case_id": "…", "title": "#418 M-07 overload alarm, motor not rotating",
      "cause": "Proximity sensor abnormal (drifting output when hot).",
      "outcome": "resolved", "badge": "verified",
      "sources": [{ "original_name": "8D_M07_2024-08.pdf", "page_range": "p.1-6" }],
      "scores": { "similarity": 0.8342, "entity_overlap": 1.0, "recency": 0.556,
                  "outcome": 1.0, "verified": true, "final": 0.870,
                  "lex_score": 1.1323, "lex_rank": 6, "vec_rank": 1, "rrf": 0.031545 },
      "why": { "matched_terms": ["overload"], "matched_entities": ["machine:M-07"],
               "matched_descriptors": ["overload", "no_rotation"] } } ] }
```

Read `lex_rank: 6` next to `rank: 1`. The Japanese 8D is the **worst** lexical match of the seven candidates for this Thai query and still comes first, because the vector leg ranked it first and it is the only candidate matching the machine and both descriptors. That row is AC-03, and `why` is how a user sees it without being told.

`POST /search/explain` returns the same components plus the five weights that were in force, so "why did this rank here" has an answer that does not require reading code.

`excluded[]` lists chunks left out of the evidence because they read as instructions (AI-08). They are reported, not silently dropped — a user who wonders why a document seems ignored gets the reason.

---

## 6. Suggestion and recurrence

`POST /similar` is what fires when a quality case or a maintenance alert opens (FR-20), inside the NFR-02 budget of 3 s — the schema caps `latency_ms` at 3000 so a slow answer is a contract violation, not a quality-of-service note.

The response is `deploy/schemas/recurrence-alert.schema.json` (IF-82). When a prior case crosses the threshold it adds a `recurrence` block:

```json
{ "prior_case_id": "…", "score": 0.870, "threshold": 0.72,
  "interval_months": 25, "confirmed": false,
  "counted_in_analytics": false,
  "suggested_first_checks": [
    "Proximity sensor condition and temperature drift (from the action of case #418)." ] }
```

Three properties of that block are requirements. `interval_months` is **computed** from the two cases and cannot be supplied. `counted_in_analytics` cannot be `true` while `confirmed` is `false` — the threshold favours recall, so an unconfirmed detection stays out of every report (AI-06). And `suggested_first_checks` are quoted from the prior case's own action text; nothing is invented.

`POST /cases/{caseId}/recurrences/{priorCaseId}/confirm` is the human decision. Only an engineer, curator or admin may make it.

---

## 7. Curation and feedback

`POST /feedback` takes `helpful`, `not_helpful` or `incorrect`. The first two feed evaluation. The third **names a field** and does three things at once: flags it, suppresses it from every rendering, and opens a curation item (FR-30, AC-06). Feedback is never a live ranking weight (ADR-H08) — a case cannot be pushed down because it was inconvenient.

`GET /curation` is the queue: low-confidence fields, unmapped entities, near-duplicates, flagged fields and suspicious chunks, oldest first, with an age. `POST /curation/{itemId}/decide` is the only path into "established fact"; the decision vocabulary is closed (`verified`, `corrected`, `mapped`, `merged`, `distinct`, `suppressed`, `dismissed`) and only a curator or admin may use it.

`POST /cases/{caseId}/verify` is the end of that path. It is refused when the case has no source, when a flagged field is still open, or when the caller is not a curator — three different `409`/`403` codes, not one vague failure.

---

## 8. Analytics

| Path | Answers | Note |
|---|---|---|
| `GET /analytics/recurring?scope=machine` | which problems keep coming back | **confirmed** recurrences only, so the number is smaller than the number of proposals — deliberately |
| `GET /analytics/effectiveness?defect_class=` | which corrective actions were followed by a recurrence | FR-24; a join, not an opinion |
| `GET /analytics/mtbr?defect_class=` | mean months between recurrences | FR-25 |
| `GET /analytics/gaps` | cases closed with no cause or no verification | FR-26 |
| `GET /analytics/coverage` | what share of the memory is actually usable | FR-31 — the honest number |

---

## 9. Evaluation and embeddings

`POST /eval/runs` runs a retrieval or extraction evaluation. `passed` is **computed** from the SRS thresholds (Recall@5 ≥ 0.80 and MRR ≥ 0.60; ≥ 0.85 narrative and ≥ 0.95 factual) and cannot be supplied — the database refuses a disagreeing value with `EVAL_GATE`.

`POST /embeddings/reembed` starts a background re-embed. `search_available` stays `true` throughout because queries are pinned to the active version until the job finishes (AC-09), and a version a running job still serves cannot be retired (`VERSION_IN_USE`).

---

## 10. Error catalogue

| HTTP | `code` | When |
|---|---|---|
| 400 | `INVALID_QUERY` | empty or oversized query text |
| 401 | `UNAUTHENTICATED` | missing or expired token |
| 403 | `FORBIDDEN` | the caller's role does not reach the resource; restricted rows were never retrieved |
| 403 | `VERIFY_NEEDS_CURATOR` | verification attempted by a non-curator |
| 403 | `CONFIRM_NEEDS_ENGINEER` | recurrence confirmation by a viewer |
| 403 | `UNFLAG_NEEDS_CURATOR` | un-flagging a suppressed field outside curation |
| 404 | `NOT_FOUND` | the resource does not exist **or** the caller may not see it — the two are indistinguishable by design |
| 409 | `SOURCE_REQUIRED` | verifying a case with no source document |
| 409 | `FLAGGED_FIELD_PRESENT` | verifying a case with an open flag |
| 409 | `ENTITY_NOT_MAPPED` | claiming an unmapped value as canonical |
| 409 | `VERSION_IN_USE` | retiring an embedding version a job still serves |
| 409 | `EVAL_GATE` | asserting a `passed` that the metrics do not support |
| 413 | `DOCUMENT_TOO_LARGE` | above the source's `max_bytes` |
| 422 | `SOURCE_CREDENTIAL_INLINE` | a credential in a source definition instead of a secret-file reference |
| 422 | `PROVENANCE_REQUIRED` | a machine-written field with no document and page |
| 422 | `EXTRACTION_REQUIRED` | a machine-written field with no model, prompt and schema version |
| 422 | `FEEDBACK_FIELD_REQUIRED` | `incorrect` without naming a field |
| 429 | `RATE_LIMITED` | retrieval rate limit |
| 503 | `MODEL_UNAVAILABLE` | the reranker or embedding model is down; lexical retrieval still answers |

`404` for "exists but not visible" is a decision, not an oversight: a `403` would confirm that a restricted document about this machine exists, which is the leak `n_acl_filtered` is careful to avoid (SEC-15 THR-H07).

---

## 11. Roles

| Role | May |
|---|---|
| `viewer` | search, read visible cases, open originals, give feedback |
| `engineer` | the above, plus manual case entry, corrections, confirming or rejecting a recurrence |
| `curator` | the above, plus verification, curation decisions, entity mapping, merges, restricted records if in the group |
| `admin` | the above, plus sources, ACLs, evaluation runs, re-embedding and configuration |

The ACL is separate from the role ladder and stricter: a curator still sees a restricted document only if they are in its group.

---

## 12. Platform mode

The gateway serves `/knowledge/search` and `/knowledge/documents` from this module and mounts the rest under `/memory/`. The four IF-16 tools (`search_memory`, `get_case`, `similar_cases`, `recurrence_check`) are registered in `agent.tool` as read-only with `min_role: viewer`; each carries the caller's identity so the ACL applies to the person asking, never to the agent (SEC-15 THR-H03).
