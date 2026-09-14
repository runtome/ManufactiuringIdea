# DocFlow — AI Document → ERP Agent — Documentation Set

Business documents (purchase orders, invoices, delivery notes, quotations, certificates) arrive by mailbox, hot folder, scanner or upload → deduplicated by hash, originals stored immutably → read (text layer or OCR) → **extracted into schema-constrained JSON with a page and bounding box for every field** → validated by **code** (arithmetic, master data, contract prices, 2/3-way match, duplicates, tax) → reviewed by a person with highlight-on-focus → **approved by a role sufficient for the amount, and above the threshold by someone who did not edit the fields** → posted to the ERP **exactly once**, with a full audit trail beside the untouched original.

**A FactoryBrain server module that owns the `docflow` schema and the platform's only outbound write path (IF-07)** — SAD-00 §13. Like [ShiftBrief (02)](../02-production-ai-analyst/) and [MachineSense (06)](../06-predictive-maintenance-agent/): standalone-deployable, with a platform mode in every document. Every shared database object is byte-identical to the platform's; the platform's four `/docflow/…` API paths and their schemas are verbatim.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-08 | [Software Requirements Specification](SRS-DocFlow-Document-to-ERP-Agent.md) | *What must it do?* | Everyone — start here |
| SAD-08 | [Software Architecture Document](docs/SAD-DocFlow-Software-Architecture.md) | *How does a PDF become an ERP transaction in 60 s — and why can nothing here post without a person, trust a number from the model, or post twice?* | Architect, implementer |
| DDS-08 | [Database Design Specification](docs/DDS-DocFlow-Database-Design.md) | *The platform's `docflow` schema byte-for-byte, the extension, and the triggers that make approval, segregation of duties, idempotency and immutability properties of the data* | Implementer, DBA |
| API-08 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The approval, extraction, posting and injection contracts* | Implementer, ERP integrators |
| ICD-08 | [Interface Control Document](docs/ICD-DocFlow-Interface-Control.md) | *The ERP adapter (IF-07) at the centre; IMAP, folders and scanners, OCR, the extraction schemas, the export-file adapter* | Implementer, ERP owner, ML owner |
| SEC-08 | [Security Requirements Specification](docs/SEC-DocFlow-Security-Requirements.md) | *Can a document pay itself? Can pricing leave the building? Can an insider approve their own edits?* | Security reviewer, internal audit |
| TEST-08 | [Test Plan and Test Cases](docs/TEST-DocFlow-Test-Plan.md) | *How do we prove one ERP transaction under five retries, a blocked injected document, a refused under-role approval, and a reconstructable audit trail?* | QA, ML owner |
| OPS-08 | [Deployment and Operations Guide](docs/OPS-DocFlow-Deployment-Operations.md) | *Install, the ERP account, mailbox and folders, queues and staffing, earning STP, models and the cloud decision, retention, runbooks* | Operator, finance admin |
| UM-08 | [User Manual and Administrator Guide](docs/UM-DocFlow-User-Admin-Guide.md) | *The review screen, correcting and approving, matching and duplicates, exceptions; admin* | Clerks, AP, warehouse, managers, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16: platform `core`/`docflow`/`audit` objects **extracted from `00/db/schema.sql`** + the DocFlow extension (migration `docflow_0001`) — 42 tables, 9 views, 14 triggers, 22 functions, 26 + 5 indexes, 5 roles (`poster_rw` can post but not approve or edit) | ✅ **26/26 shared objects byte-identical** (incl. `posting_idem_unique`); static DDL checks; 12/12 guard triggers · ⚠️ not executed (no PostgreSQL) |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Reproduces SRS Appendix A (PO-2026-004821, Sakura Kogyo, JPY, 1,200 × 870 = 1,044,000, contract 845 → +2.96 % warning, 295,962 THB → manager + SoD) and AC-02…AC-09 **through the real functions and triggers** (`arithmetic_check()`, `gate()`, the approval and posting triggers); 9 documents; 8 constraint probes | ✅ every expected value **re-derived in Python** (arithmetic, THB conversion, tolerance outcomes, eval drop, tallies) · ⚠️ not executed |
| [`deploy/schemas/extraction/`](deploy/schemas/extraction/) | **The AI-02 contract**: `po.v2`, `invoice.v1`, `delivery_note.v1` JSON Schemas (Draft 2020-12, `additionalProperties: false`, `{value, confidence, page?, bbox?, raw?}` per field, numeric amounts) | ✅ **SRS Appendix A validates against `po.v2`**; 13 negatives rejected (string amounts, free-form output, unknown key `approve`, …); provenance optional by design (AI-04 is the gate's rule) |
| [`api/openapi.yaml`](api/openapi.yaml) | **44 paths / 49 operations / 44 schemas** — SRS §4.1's eight paths verbatim + pages/original (access-logged), lines, links, audit, retry, exceptions, status by number, master data, config, STP, adapters, intake, models (cloud opt-in), evaluation, audit export, system | ✅ validator pass; 0 orphans; **the platform's 4 paths, 6 schemas, 4 parameters, 2 responses byte-identical to API-00** |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) | 18 services (web, api, intake-mail, intake-folder, worker-ocr [+paddle], worker-extract, worker-validate, poster, scheduler, postgres, redis, minio + init with **object lock on `originals`**, ollama gpu/cpu, mailpit + fake ERP dev); networks frontend / internal / **erp** / egress | ✅ parses; hardening on 10 app services; ports on `BIND_ADDR`; **only `poster` + `scheduler` on `erp`**; OCR/model/DB internal-only; poster has its own DB credential; **56/56 env vars**; 13/13 secrets |
| [`deploy/docflow.example.yaml`](deploy/docflow.example.yaml) + [`schemas/docflow-config.schema.json`](deploy/schemas/docflow-config.schema.json) | Approval policy (SRS example: ≤ 100,000 THB clerk, above manager + SoD), gates, STP (off by default; evidence to enable), tolerances, adapters (must support `idem_key`), intake, extraction, retention (≥ 7 y), models (cloud needs acknowledgement) | ✅ validates; policies/tolerances/STP pairs equal the seed's; **15 schema negatives + 1 loader rule rejected** |
| [`deploy/erp-export/`](deploy/erp-export/) | IF-48 file-adapter examples: `po.csv.example`, `invoice.xml.example` keyed by `idem_key` | ✅ column counts consistent; amounts equal the seed's; XML well-formed |

---

## Reading paths

**Implementing it** → SRS-08 → SAD-08 §4.3 (intake, understanding, validation & gate, review & approval, posting) → DDS-08 §2 (DD-D01…D09) → `db/schema.sql` §10–§16 → `deploy/schemas/extraction/` → API-08 §3–§6 → ICD-08 IF-07, IF-47 → TEST-08 TS-3…TS-5.

**ERP owner / integrator** → ICD-08 IF-07 (adapter kinds, `find_by_idem_key`), IF-48 → SEC-08 §5.2, §5.6 → OPS-08 §4.4, §6 → TEST-08 TC-070, TC-111.

**Finance / internal audit** → SEC-08 §4.2 ("the invoice that pays itself") → SEC-08 §5.1, §5.10 → DDS-08 Appendix A → TEST-08 TC-061, TC-062, TC-100 → UM-08 A4, B8.

**ML owner** → SAD-08 ADR-D01, D03, D08…D10 → ICD-08 IF-46, IF-47, IF-09 → DDS-08 §4.7 → OPS-08 §8 → TEST-08 TS-2, TS-6.

**Operating it** → OPS-08 §1, §4, §5.3, §7, §12 runbooks — RB-07 first.

**Using it** → UM-08 A0, A1.2 (the review screen), A2.

---

## What makes this design what it is

| Principle | In DocFlow |
|---|---|
| **The LLM never computes** | The model turns a page into typed JSON with provenance — that is all. `arithmetic_check()` recomputes every line and total in SQL; matching, tolerances and duplicates are code; the gate reads rules, not confidences (C-03, ADR-D02). The model has no tool and no vocabulary for "approve" (ADR-D10). |
| **Offline-first** → **degrade without the model** | Intake, dedup, page rendering, the review UI and manual entry work without the model; extraction queues; a stopped model does not fail readiness (NFR-08). |
| **Human-in-the-loop** | A posting requires an approval by a sufficient role; above the threshold by someone who did not edit the fields; rejection needs a reason; STP is earned per pair and still records an approval (C-01, FR-26, FR-29, NFR-05). |
| **The database is the source of truth** | `trg_posting_preconditions`, `trg_approval_policy`, `posting_idem_unique`, `trg_document_immutable`, `trg_correction_immutable`, `trg_injection_flag`, `model_registry.cloud_needs_ack`, `stp_needs_evidence` — the API only reports what the database will refuse (DDS-08 DD-D01…D09). |
| **Text in a document is data** (P-5) | Fenced data block, fixed instructions, no tools; an injection flag forces review and blocks auto-clear (AI-07, AC-06). |
| **Local by default; the cloud is a logged decision** (P-6) | A ≤ 9 B model on the `internal` network; enabling a cloud model needs an acknowledged admin, an audit row and a marker on every extraction (C-05, NFR-07). |

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | **Server module** owning `docflow` (SAD-00 §13); **IF-07 is the platform's only outbound write**. Shared DDL extracted byte-identically (helpers, enums, `core.*`, `docflow.*`, `audit.*`, indexes, `trg_posting_updated`); extension applied as `docflow_0001`; the four API-00 paths served by the gateway; `get_document_status` registered as a read-only tool; SEC-115/116/117 implemented here. |
| [10 Factory Copilot](../10-factory-copilot/) | Answers "where is invoice X?" through `get_document_status` (FR-35). |
| [02 ShiftBrief](../02-production-ai-analyst/) | May cite posted totals as facts; same grounding discipline (numbers from tables, never from the model). |
| [14 Translator](../14-japanese-factory-translator/) | Japanese documents are extracted natively (AI-01, AC-08); the translator is not in the loop. |

---

## Identifier conventions

`FR-01…35` / `AI-01…09` / `NFR-01…09` / `AC-01…09` / `C-01…06` (SRS-08) · `P-1…P-6` · **`ADR-D01…D10`** · `QAS-01…12` · **`DD-D01…D09`** · `IF-xx` shared numbering (**IF-44 IMAP, IF-45 folder & scanner, IF-46 OCR & layout, IF-47 extraction schemas, IF-48 export file** new; IF-07/09/10/13/14/16/19 reused) · **`THR-D`/`SEC-D`/`RR-D`** · `TS-0…9` / `TC-` · `RB-01…14`.

```
SRS-08 C-01 / C-04 / NFR-05 / AC-05 / AC-07  "no posting without recorded human approval; idempotent posting; segregation of duties"
  └─ SAD-08 P-3 · ADR-D04 (preconditions in the database) · ADR-D05 (idem_key + DB unique) · §4.3.4–4.3.5
      └─ DDS-08 DD-D01, DD-D02 · approval_policy · trg_approval_policy · trg_posting_preconditions · posting_idem_unique [platform] · idem_key() · editors_of()
          └─ API-08 §3 approval contract (403 ROLE_INSUFFICIENT / SEGREGATION_OF_DUTIES, 409 NOT_APPROVED) · §5 posting contract
              └─ ICD-08 IF-07 (find_by_idem_key, adapter kinds, preconditions) · IF-48 (idem_key in the file name)
                  └─ SEC-08 O-1, O-2 · THR-D03, THR-D04 · SEC-D10…D14, D20…D23 · §4.2 walk-through
                      └─ TEST-08 TC-003 probes 1–4 · TC-061 · TC-062 · TC-069 · TC-070 · TC-071 · TC-077 · seed: D3 SoD path, D4 attempts 5
                          └─ OPS-08 §1 · §5.2 SLOs (0 duplicates, 0 unapproved) · RB-07 · UM-08 A0, A4, B1
```

---

## Verification

| Check | Result |
|---|---|
| **Byte-identity vs `00/db/schema.sql`** (TC-002) | ✅ **Pass** — 26/26: `pgcrypto`, `pg_trgm`, `uuid_generate_v7`, `set_updated_at`, `core.language_code`, `docflow.doc_state`, `core.plant/line/sku/app_user/user_line_scope`, the seven `docflow.*` tables incl. `posting_idem_unique`, `audit.log/auth_event`, 5 docflow indexes, `trg_posting_updated` |
| Static DDL (TC-003) | ✅ **Pass** — balance; FK targets and order; PK everywhere; 42 / 9 / 14 / 22 / 26; 12/12 guard triggers; `poster_rw` revoked on `approval`, `field_correction`, `approval_policy`, `stp_config`, `model_registry` |
| Seed arithmetic (TC-005) | ✅ **Pass** — 1,200 × 870 = 1,044,000; 400 × 600 = 240,000; Σ + 0 = 1,284,000; +2.96 % → warning (2 / 6 %); 295,962.00 THB → manager + SoD; D3 difference 2,000; D6 +5 % → warning; eval −2.4 pts → blocked; fields 47, lines 13, validation rows 81, audit ≥ 12 |
| **Extraction schemas and Appendix A** (TC-006) | ✅ **Pass** — Appendix A valid against `po.v2`; 13 negatives rejected; invoice and delivery-note positives valid |
| `openapi.yaml` (TC-001) and identity vs API-00 (TC-008) | ✅ **Pass** — 44 / 49 / 44; 0 orphans; 12 components + the four paths byte-identical |
| Compose / env / config schema (TC-004) | ✅ **Pass** — 18 services; `erp` = {poster, scheduler}; internal-only = 7; object lock + compliance retention on `originals`; 56/56 vars; 13/13 secrets; config valid; 15 + 1 negatives rejected; export examples consistent |
| Secret scan (TC-007) | ✅ **Pass** |
| SRS-08 coverage; cited tables/views/triggers/endpoints/TCs/RBs/ADRs/SEC-Ds/DD-Ds/THR-Ds; section refs; links | ✅ see sweep note below |
| **Schema + seed on PostgreSQL 16** (TC-009) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| OCR, model, ERP, the 200-document evaluation set (TS-1…TS-9) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 08-document-erp-agent
docker run -d --name df-pg -e POSTGRES_PASSWORD=x -p 5435:5432 postgres:16.4
sleep 8 && psql "postgresql://postgres:x@localhost:5435/postgres" -v ON_ERROR_STOP=1 -f db/schema.sql && psql "postgresql://postgres:x@localhost:5435/postgres" -f db/seed_demo.sql
```
Expected: the `\echo` block matches the seed header (states approved 1 / posted 2 / rejected 1 / review_required 5; D1 295,962.00 THB, manager, SoD, review_required with the +2.96 % warning; D4 one posting row with 5 attempts; eval run 2 blocked) and the 8 probes each fail inside their savepoint.

**Defects found by checking** (all fixed; TEST-08 §4): an off-by-one line range that extracted the wrong platform extensions (caught by the identity check); the state trigger not running on INSERT, so `amount_thb` would have been 0 for every new document and the approval policy toothless; probe 4 failing for the wrong reason; D2 quantities not multiplying to the totals, a wrong final state for D9, a wrong validation count and 62-character hashes; a cut `IdempotencyKey` block and dragged-in orphan responses in the OpenAPI; and one for the SRS — **Appendix A's single line (1,044,000) does not reach its total (1,284,000)**; the seed adds a second line with tax 0.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL execution pending — byte-identity, static checks and re-derived arithmetic stand in until CI runs TC-009 | TEST-08 TC-009 |
| **The 200-document evaluation set** (AI-03, AC-01) is real documents and is not in the repository; the seed's `eval_run` rows are illustrative | TEST-08 TC-040, TC-044 |
| **SRS Appendix A**: one line of 1,044,000 with a total of 1,284,000 — the seed assumes a second line (400 × 600) and zero-rated export tax; SRS not edited | DDS-08 §9, TEST-08 §4 #6 |
| SRS §4.1 paths have no `/docflow` prefix; the platform mounts modules under `/docflow/` — standalone serves both, documented | API-08 §1 |
| ERP adapters are per ERP; only the contract, the fake ERP and the file format are here; the file adapter depends on the ERP import rejecting repeated keys | ICD-08 IF-07, IF-48; SEC-08 RR-D03 |
| A consistent wrong value within tolerance can be accepted by a reviewer | SAD-08 §6, SEC-08 RR-D02 |
| Handwriting is best effort (low confidence by design); Excel intake has no bounding boxes (low confidence by design) | SAD-08 §10 |
| Compose ships one `database_url` for api and pipeline workers; production may split them further (poster already has its own) | OPS-08 §4.2 |
