# API Specification — DocFlow (AI Document → ERP Agent)

| Field | Value |
|---|---|
| Document ID | API-08-DocFlow |
| Version | 1.0 (Draft) |
| Date | 2026-09-14 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **44 paths / 49 operations / 44 schemas**; the platform's four `/docflow/…` paths, six schemas, four parameters and two responses byte-identical to API-00 (TEST-08 TC-008) |
| Related | [SRS-08](../SRS-DocFlow-Document-to-ERP-Agent.md) §4.1 · [SAD-08](../docs/SAD-DocFlow-Software-Architecture.md) · [DDS-08](../docs/DDS-DocFlow-Database-Design.md) · [ICD-08](../docs/ICD-DocFlow-Interface-Control.md) · [SEC-08](../docs/SEC-DocFlow-Security-Requirements.md) · platform: [API-00](../../00-factorybrain-platform/api/API-Specification.md) |

---

## 1. SRS §4.1 mapping and platform mode
| SRS | Standalone path | Platform mode | Note |
|---|---|---|---|
| `POST /api/v1/documents` | `POST /documents` | `POST /docflow/documents` (API-00, verbatim) | 202 received; 200 with the existing document on a repeated hash (FR-03) |
| `GET /api/v1/documents/{id}` | `GET /documents/{id}` | `GET /docflow/documents/{documentId}` | standalone `DocumentDetail` extends the platform's `DocflowDocumentDetail` (versions, gate, flags, links, required role) |
| `PATCH /api/v1/documents/{id}/fields` | same | DocFlow module path under `/docflow/` | corrections are append-only; the caller becomes an editor (SoD) |
| `POST /api/v1/documents/{id}/approve` | same | `POST /docflow/documents/{documentId}/approve` | role vs amount; SoD; `403` refused and audited |
| `POST /api/v1/documents/{id}/reject` | same | module path | reason required (FR-27) |
| `POST /api/v1/documents/{id}/post` | same | `POST /docflow/documents/{documentId}/post` | queued; idempotent by the derived key |
| `GET /api/v1/queue?state=` | same | module path | review / approval / exception / posting |
| `GET /api/v1/validation/{id}` | same | module path | per-rule report + gate (FR-22) |

The SRS paths live under `/api/v1` without a `/docflow` prefix; the platform mounts modules under `/docflow/*`. Standalone serves **both** prefixes; in platform mode the four API-00 paths are served by the platform gateway and the rest by the DocFlow module under `/docflow/`. Added beyond the SRS: pages and original (signed, access-logged), lines, links, audit, reprocess, retry, export file, exceptions, status by number (FR-35), suppliers/aliases/templates, items, price lists, master-data sync, policies, config, STP, adapters, intake sources, models (cloud opt-in), evaluation runs, audit export, system.

## 2. Conventions
- Base `/api/v1`; JSON; UTC timestamps; ids UUIDv7; `Problem` verbatim from API-00 with a stable `code` (§7).
- Auth: bearer JWT; platform-shape roles `viewer < inspector (clerk) < engineer (AP, warehouse) < manager < admin`; the auditor is a `viewer` with the audit scope.
- Pagination by `cursor`/`limit` (platform parameters). Rate limits per user on write paths → `429`.
- **Signed URLs** for page images (15 min) and originals (5 min); every mint is written to `access_log` (SEC-116). The API never streams document bytes.
- Every write endpoint that changes a document's state writes `audit.log` (FR-28); the database triggers write the approval, posting, correction and injection rows themselves, so the export (AC-09) does not depend on the API remembering.

## 3. The approval contract (C-01, FR-26, FR-27, NFR-05)
```
received → classified → extracted → validated ──┬── review_required ──┬── approved → posting → posted
                                                 │                     └── rejected
                                                 └── (gate auto_clear) ───── approved (approval still recorded)
posting_failed → posting (retry) | review_required | rejected
```
- `POST /approve`: the caller's role must be ≥ `required_role` for the document's `amount_thb` (`ApprovalPolicy`); above the SoD threshold the caller must not appear in `editors` (users who corrected fields). Refusals are `403 ROLE_INSUFFICIENT` / `403 SEGREGATION_OF_DUTIES` and audited (AC-07). A report with warnings requires `acknowledge_warnings: true`.
- Auto-clear (`gate = auto_clear`) skips the *review* step, not the approval: a posting still needs an `Approval` (C-01). STP is off by default and per (kind, supplier).
- `POST /reject` needs a `reason` (≥ 3 chars); `reply_to_sender` sends the reason to the intake email address (FR-27).
- A duplicate invoice number for the same supplier cannot be approved (`409 DUPLICATE_INVOICE`, FR-20).
- The database enforces all of the above again (DDS-08 DD-D01); the API's job is a good error message before the trigger's.

## 4. The extraction contract (C-02, C-03, FR-12, FR-13, AI-02, AI-04)
- `DocumentDetail.header` maps field paths to `Field` objects: `value` (normalised), `raw` (original text), `confidence`, `page`, `bbox`, `corrected_value/by/at`, `below_gate`. `lines[]` carry the same provenance.
- Amounts are numbers; dates are ISO 8601 with the original in `raw` (Buddhist and Reiwa calendars normalised); currencies ISO 4217.
- A field without `page`+`bbox` is `below_gate = true` whatever its confidence (AI-04). A critical field below its gate makes the document `review_required` (AI-05).
- The `extraction` object records `model_version`, `prompt_version`, `schema_version`, `cloud`, `schema_valid`, `repair_rounds` (AI-08). `schema_valid = false` after two repair rounds means the document is in the exception queue with `extraction_failed` — the API never returns coerced values.
- `ValidationReport.rules[]` is the code-side verdict: `arithmetic.line`, `arithmetic.total`, `supplier.master`, `item.master`, `price.contract`, `match.2way.*`, `match.3way.qty`, `duplicate.invoice`, `tax.consistency`, `injection.flag`, `confidence.gate` with `pass | warning | fail` and a detail object (e.g. `{"unit_price": 870, "contract": 845, "pct": 2.96}`).

## 5. The posting contract (C-04, FR-30…FR-33, AC-05)
- `POST /documents/{id}/post` creates (or returns) the `Posting` row: `idem_key = sha256:<adapter>:<kind>` derived by the server — the `Idempotency-Key` header, if sent, must equal it or is ignored with a warning. The database's `UNIQUE (adapter, idem_key)` makes a second row impossible.
- The adapter call happens in the `poster` worker, outside the request: `202` means queued. Failures set `posting_failed` with `attempts` and `last_error`; the worker retries with exponential backoff up to 5 times; `POST /documents/{id}/retry` forces a retry; `GET /exceptions` lists what is stuck (FR-32).
- `Posting.erp_ref` is filled only on success; a succeeded posting always has one (`ERP_REF_REQUIRED` otherwise).
- File-export adapters produce a file whose name contains the key; `GET /documents/{id}/export-file` returns a signed URL and the file's sha256 (FR-33, IF-48).

## 6. The injection contract (AI-07, AC-06)
- Text inside a document is data. If the classifier flags a phrase, `DocumentDetail.injection_flags[]` carries it (phrase, page, bbox, score); `injection_flagged = true`; `gate = blocked`; the document is `review_required`; STP is irrelevant.
- There is no endpoint, parameter or field that lets extraction output change state, approve or post. `Field.value` for a notes field may contain "approve this" — it is displayed, flagged, and ignored.

## 7. Error catalogue
| HTTP | `code` | When |
|---|---|---|
| 400 | `BAD_REQUEST` | malformed query/cursor |
| 401 | `UNAUTHENTICATED` | no/invalid token |
| 403 | `ROLE_INSUFFICIENT` · `SEGREGATION_OF_DUTIES` · `NOT_PERMITTED` | approval/posting/original access refused — audited |
| 404 | `NOT_FOUND` | |
| 409 | `NOT_APPROVED` · `APPROVAL_STATE` · `DUPLICATE_INVOICE` · `STATE_TRANSITION` · `ADAPTER_UNKNOWN` · `STP_NEEDS_EVIDENCE` · `NOT_EDITABLE` · `ALIAS_EXISTS` | database guard names surface unchanged (DDS-08 Appendix A) |
| 413 / 415 | `FILE_TOO_LARGE` · `TYPE_NOT_ALLOWED` | upload gate |
| 422 | `VALIDATION_FAILED` · `REASON_REQUIRED` · `CONFIG_INVALID` · `CLOUD_NOT_ACKNOWLEDGED` · `WARNINGS_NOT_ACKNOWLEDGED` | |
| 429 | `RATE_LIMITED` | |
| 502 | `ERP_UNREACHABLE` | platform `/docflow/…/post` synchronous form; safe to retry |
| 503 | `NOT_READY` | DB/Redis/object store down — a stopped model or OCR is not 503 (NFR-08) |

## 8. Traceability
| SRS-08 | Endpoints / schemas |
|---|---|
| FR-01…FR-05 | `/documents` (upload, dedup 200), `/intake/sources`, `/documents/{id}/links`, `/documents/{id}/pages/{n}`, `/documents/{id}/original` |
| FR-06…FR-14 | `Document.doc_kind/kind_confidence/lang/text_source`, `Field` provenance, `/suppliers/*/templates` |
| FR-15…FR-22 | `/validation/{id}`, `ValidationReport`, `/price-lists`, `/items/aliases`, `/master-data/sync` |
| FR-23…FR-29 | `/documents/{id}/fields`, `/approve`, `/reject`, `/queue`, `/documents/{id}/audit`, `/policies`, `/stp` |
| FR-30…FR-35 | `/documents/{id}/post`, `/retry`, `/exceptions`, `/export-file`, `/adapters`, `/status` |
| C-01…C-06 | §3, §4, §5, `/models/{id}/cloud`, `/documents/{id}/original` (immutable) |
| AI-02, AI-04, AI-05, AI-07, AI-08, AI-09 | §4, §6, `extraction` versions, `/eval/runs` |
| NFR-05, NFR-07 | §3 SoD, `CloudEnableRequest` |
| AC-05, AC-06, AC-07, AC-09 | §5, §6, §3, `/audit/export` |
