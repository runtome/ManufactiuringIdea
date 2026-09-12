# Database Design Specification — ShiftBrief (Production AI Analyst)

| Field | Value |
|---|---|
| Document ID | DDS-02-ShiftBrief |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-02 §5](../SRS-ShiftBrief-Production-AI-Analyst.md), [SAD-02 §4.6](SAD-ShiftBrief-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) · [`db/seed_demo.sql`](../db/seed_demo.sql) |
| Platform relationship | `core.*` production tables are byte-identical to [FactoryBrain (DDS-00)](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md); `analytics.*` is ShiftBrief's own |

---

## 1. Introduction

### 1.1 Purpose
The physical data model for ShiftBrief standalone, and the rules by which it becomes the platform's daily-brief engine. `schema.sql` is authoritative; this document explains why it looks the way it does.

### 1.2 Target and application
PostgreSQL 16. Extensions `pgcrypto` (hashing), `pg_trgm`, `btree_gin`, and `vector` (unused standalone; created so the same file applies in platform-compatible environments). Verified target image `pgvector/pgvector:pg16`.

```bash
psql -v ON_ERROR_STOP=1 -f db/schema.sql
psql -v ON_ERROR_STOP=1 -f db/seed_demo.sql    # demo / test data only
```

### 1.3 How the schema was built
As for VisionOps: `schema.sql` is **assembled from the platform schema**. Sections 1, 3–9 and the three shared views are line-range extracts of `00/db/schema.sql`; only section 10 (`analytics`), the index/trigger/grant subsets and the header are authored here. A diff over every shared `CREATE TABLE`, `CREATE TYPE` and `CREATE OR REPLACE VIEW` reports **37 shared objects, 0 differences**.

One deliberate omission: the platform's `ALTER TABLE vision.*` statements inside the `ops` section are not extracted (there is no `vision` schema here). Everything else in `ops` — including the edge-node tables ShiftBrief never uses — is kept verbatim so the identity check stays simple.

---

## 2. Design principles

Platform principles [DD-01…DD-08](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) apply. ShiftBrief adds:

| ID | Principle | Rationale |
|---|---|---|
| **DD-S01** | **The facts object is a stored, hashed, immutable row.** `analytics.facts` cannot be updated or deleted (trigger); a change is a new `facts_version`. | The brief's provenance is one row. Regeneration recomputes and compares the hash; a mismatch is surfaced as `FACTS_STALE`, never hidden (SRS-02 C-03, NFR-08). |
| **DD-S02** | **A brief that could not be grounded stores no text.** `brief_withheld_has_no_text`. | It is structurally impossible to persist an ungrounded brief and render it later. |
| **DD-S03** | **Corrections create new rows and link back; they never overwrite.** Facts version + `brief.revised_of` + `batch_detail.supersedes_batch_id`. | Anyone who acted on the original must be able to see what changed (ADR-S08). |
| **DD-S04** | **The source file's layout is data, not code.** `source_mapping` is versioned YAML with a header fingerprint. | A renamed column must hold the batch with `MAPPING_DRIFT`, not silently become a missing line (ADR-S02). |
| **DD-S05** | **Shared tables are byte-identical to the platform; ShiftBrief tables are fenced in one schema.** | Standalone and platform mode must never drift. |

---

## 3. Schema organisation

| Schema | Contents | Relationship to platform |
|---|---|---|
| `core` | plant, line, sku, defect_type, material_lot, shift_calendar, app_user, user_line_scope, **ingest_batch, production_fact, defect_fact, quarantine_row** | Byte-identical. Platform adds `core.machine` and the vision/quality/telemetry/knowledge/docflow schemas |
| **`analytics`** | source, source_mapping, file_expectation, batch_detail, facts, brief, alert_event, subscription; enums `batch_disposition`, `brief_kind` | **ShiftBrief-owned**; back-port candidates |
| `agent` | tool, conversation, message, run, tool_call, action_proposal, feedback | Byte-identical subset |
| `ops` | edge_node, node_event, node_health, scheduled_job, config, data_quality_event, schema_version | Byte-identical (edge tables unused standalone) |
| `audit` | log, auth_event | Byte-identical |

### 3.1 ERD

```
analytics.source ──< source_mapping (versioned YAML, header fingerprint)
       │        ──< file_expectation (cadence, expected_by, grace)
       │
       └──< analytics.batch_detail >── core.ingest_batch ──< core.quarantine_row
                  (disposition · dates_covered · supersedes)     │
                                                                 ├──< core.production_fact  (natural PK)
                                                                 └──< core.defect_fact
                                                                             │
                                          v_kpi_daily · v_defect_pareto · v_oee_daily
                                          v_line_shift_daily · v_trend_daily
                                                                             │
                                                                   analytics engine
                                                                             ▼
                                                 analytics.facts  (date, line, version, sha256)  [immutable]
                                                        │
                                                        ├──< analytics.brief  (text | withheld · revised_of ⟲ · run_id → agent.run)
                                                        └──  analytics.alert_event
analytics.subscription (who gets which brief, where, in which language)
```

---

## 4. Shared `core` production tables

Specified in [DDS-00 §4](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md). How ShiftBrief uses them:

| Table | ShiftBrief role |
|---|---|
| `core.ingest_batch` | One row per file. `sha256` is the dedup key (identical file → existing batch, `409`); `status = 'rejected'` with `reject_reason` implements the >5 % rule; `archive_uri` points at the immutable original |
| `core.production_fact` | Daily grid at (date, shift, line, sku). **Natural primary key** → re-ingest is `INSERT … ON CONFLICT DO UPDATE`; `CHECK (qty_ng <= qty_produced)` catches the commonest file error before it reaches the warehouse |
| `core.defect_fact` | Same grain plus defect type. The seed enforces, and TC-013 asserts, that per-cell defect sums equal `qty_ng` |
| `core.quarantine_row` | Rejected rows with the raw JSON and a **reason written for the data owner** |
| `core.shift_calendar` | Versioned by date; "yesterday, shift B" resolves correctly after a schedule change |

---

## 5. `analytics` tables

### 5.1 `analytics.source` and `source_mapping`
A **source** is one file contract: kind (`folder | upload | imap | sftp`), location, file pattern, encoding, plant.

A **mapping** is a versioned YAML document (schema in §6) plus `header_fingerprint` — the SHA-256 of the normalised expected header. Intake compares the incoming header's fingerprint; on mismatch the batch is **held** (`disposition = held_drift`) and an alert names the columns that differ. `reason` (≥ 5 chars) is mandatory and audited on every version.

### 5.2 `analytics.file_expectation`
When a file is due: cadence, `expected_by` time, grace, weekdays. The `file_expectation` job raises `FILE_NOT_ARRIVED` past the grace period, and — importantly — **the brief for that date is not generated from partial data**; the dashboard shows "awaiting file".

### 5.3 `analytics.batch_detail`
Extends `core.ingest_batch` (which stays identical to the platform) with what ShiftBrief needs: the source and mapping used, `disposition` (`committed | rejected | held_drift`), `dates_covered` (a `daterange`, GiST-indexed), `supersedes_batch_id` for corrected files, the header as seen, drift detail, and whether PII pseudonymisation ran.

### 5.4 `analytics.facts` — the product

| Column | Purpose |
|---|---|
| `fact_date`, `line_id` (NULL = plant-wide) | Scope |
| `facts_version` | Analytics code version; bumped on any change to how facts are computed |
| `facts_json` | The object (schema in §7) — **the only numeric input the LLM ever receives** |
| `facts_sha256` | `sha256(facts_json::text)`; jsonb canonicalises key order, so the hash is stable |
| `significant`, `p_value` | Denormalised from the JSON for indexing and for opening `quality.signal` in platform mode |
| `data_complete` | False when an expected shift/line is missing; the brief must say so before comparing |
| `source_batches` | Provenance |

`UNIQUE NULLS NOT DISTINCT (fact_date, line_id, facts_version)` — one row per scope per version (plant-wide rows have `line_id NULL`, hence `NULLS NOT DISTINCT`). A trigger rejects `UPDATE` and `DELETE`: facts are superseded, never edited.

### 5.5 `analytics.brief`

| Column | Purpose |
|---|---|
| `facts_id` | Exactly one facts row; `ON DELETE RESTRICT` |
| `text` | NULL when withheld |
| `sources_json` | `[{"kind":"facts","facts_id":…,"facts_version":…}]` — for a revision, the previous facts row too |
| `grounding_json` | Post-check result |
| `withheld`, `withheld_reason` | `brief_withheld_has_reason`, **`brief_withheld_has_no_text`** |
| `revised_of` | Self-FK to the original; `brief_not_self_revision` |
| `delivered_at`, `delivery_json` | Discord message id / email id per delivery |
| `model`, `prompt_version` | Reproducibility |

### 5.6 `analytics.alert_event` and `subscription`
Alerts are rows first, deliveries second: `defect_rate_threshold`, `defect_rate_change`, `file_not_arrived`, `batch_rejected`, `mapping_drift`, `brief_withheld`, `brief_revised`, with acknowledgement. Subscriptions decide who receives which brief kind on which channel, in which language and length (SRS-02 FR-21/22/27).

---

## 6. Mapping YAML schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://shiftbrief.local/schemas/source-mapping-v1.json",
  "type": "object",
  "required": ["schema_version", "source", "columns"],
  "additionalProperties": false,
  "properties": {
    "schema_version": { "const": 1 },
    "source": { "type": "string" },
    "delimiter": { "type": "string", "default": "," },
    "sheet": { "type": "string", "description": "XLSX only" },
    "header_row": { "type": "integer", "minimum": 1, "default": 1 },
    "date_format": { "type": "string", "default": "%Y-%m-%d" },
    "columns": {
      "type": "object",
      "required": ["prod_date", "shift", "line", "sku", "qty_produced", "qty_ng"],
      "additionalProperties": false,
      "properties": {
        "prod_date":    { "$ref": "#/$defs/col" },
        "shift":        { "$ref": "#/$defs/col" },
        "line":         { "$ref": "#/$defs/col" },
        "sku":          { "$ref": "#/$defs/col" },
        "qty_produced": { "$ref": "#/$defs/col" },
        "qty_ng":       { "$ref": "#/$defs/col" },
        "defect_code":  { "$ref": "#/$defs/col" },
        "defect_qty":   { "$ref": "#/$defs/col" },
        "runtime_min":  { "$ref": "#/$defs/col" },
        "downtime_min": { "$ref": "#/$defs/col" },
        "operator_id":  { "$ref": "#/$defs/col" },
        "lot":          { "$ref": "#/$defs/col" }
      }
    },
    "rules": {
      "type": "array",
      "items": { "enum": ["qty_ng <= qty_produced", "line in known_lines", "sku in known_skus",
                          "defect_code in known_defect_codes", "shift in shift_calendar",
                          "runtime_min + downtime_min <= 1440"] }
    }
  },
  "$defs": {
    "col": {
      "type": "object",
      "required": ["from"],
      "additionalProperties": false,
      "properties": {
        "from":     { "type": "string", "description": "Header text in the source file" },
        "type":     { "enum": ["text", "int", "number", "date"], "default": "text" },
        "map":      { "type": "object", "additionalProperties": { "type": "string" } },
        "min":      { "type": "number" },
        "optional": { "type": "boolean", "default": false },
        "pii":      { "enum": ["pseudonymise", "drop"] }
      }
    }
  }
}
```

**`pii: pseudonymise`** replaces the value with `HMAC-SHA256(value, PII_HMAC_KEY)` truncated to 16 hex characters at intake. The raw operator id never reaches the warehouse, the facts object or a brief (SRS-02 NFR-07).

---

## 7. Facts object schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://shiftbrief.local/schemas/facts-v1.json",
  "type": "object",
  "required": ["facts_version", "date", "scope", "totals", "baseline", "change", "significance", "pareto", "completeness", "meta"],
  "properties": {
    "facts_version": { "type": "string" },
    "date":  { "type": "string", "format": "date" },
    "scope": { "type": "object", "properties": { "plant": {"type":"string"}, "line": {"type":["string","null"]} } },
    "totals":   { "$ref": "#/$defs/rate_block" },
    "baseline": { "type": "object", "properties": {
        "d1":  { "$ref": "#/$defs/rate_block" },
        "d7":  { "$ref": "#/$defs/rate_block" },
        "d30": { "$ref": "#/$defs/rate_block" } } },
    "change": { "type": "object", "properties": {
        "vs_d1_pct": {"type":["number","null"]}, "vs_d7_pct": {"type":["number","null"]}, "vs_d30_pct": {"type":["number","null"]} } },
    "significance": { "type": "object", "required": ["test","vs","p_value","alpha","significant"], "properties": {
        "test": {"const":"two_proportion_z"}, "vs": {"enum":["d7","d30"]}, "z": {"type":"number"},
        "p_value": {"type":"number"}, "alpha": {"type":"number"}, "significant": {"type":"boolean"} } },
    "by_line":       { "type": "array", "items": { "$ref": "#/$defs/group" } },
    "by_shift":      { "type": "array", "items": { "$ref": "#/$defs/group" } },
    "by_sku":        { "type": "array", "items": { "$ref": "#/$defs/group" } },
    "by_line_shift": { "type": "array", "items": { "$ref": "#/$defs/group" } },
    "pareto": { "type": "array", "items": { "type": "object",
        "required": ["code","qty","share_pct","cumulative_pct"],
        "properties": { "code": {"type":"string"}, "qty": {"type":"integer"}, "share_pct": {"type":"number"},
                        "cumulative_pct": {"type":"number"}, "is_critical": {"type":"boolean"} } } },
    "worst": { "type": "object", "description": "Only rankable groups (n >= min_rank_volume) may appear here" },
    "trend": { "type": "object", "properties": {
        "consecutive_rise_days": {"type":"integer"}, "level_shift": {"type":"boolean"}, "outlier_3sigma": {"type":"boolean"} } },
    "oee": { "type": "object", "properties": {
        "availability_pct": {"type":["number","null"]}, "quality_pct": {"type":["number","null"]},
        "performance_pct": {"type":"null", "description": "Omitted until a validated ideal cycle time exists"} } },
    "completeness": { "type": "object", "required": ["expected_shifts","present_shifts","complete"] },
    "meta": { "type": "object", "required": ["computed_at","source_batches"] }
  },
  "$defs": {
    "rate_block": { "type": "object", "required": ["produced","ng","defect_rate_pct"],
      "properties": { "produced": {"type":"integer"}, "ng": {"type":"integer"},
                      "defect_rate_pct": {"type":["number","null"], "description": "null when produced = 0 — never 0"} } },
    "group": { "allOf": [ { "$ref": "#/$defs/rate_block" },
      { "properties": { "line": {"type":"string"}, "shift": {"type":"string"}, "sku": {"type":"string"},
                        "rankable": {"type":"boolean"} } } ] }
  }
}
```

Three rules the builder enforces that the schema cannot: `defect_rate_pct` is `null` when `produced = 0`; a group with `rankable: false` never appears under `worst`; `significance.significant = false` forbids any `worst.*` entry from being *headlined* by the composer (it may still be listed).

---

## 8. Views

| View | Purpose | Identical to platform |
|---|---|---|
| `core.v_kpi_daily` | Daily totals and rate per line | ✅ |
| `core.v_defect_pareto` | Pareto with cumulative share | ✅ |
| `core.v_oee_daily` | Availability and quality (performance omitted) | ✅ |
| `analytics.v_line_shift_daily` | Line × shift cells with `rankable` flag | ShiftBrief |
| `analytics.v_trend_daily` | Daily series with pooled 7- and 30-day trailing baselines (excluding the day) | ShiftBrief |
| `analytics.v_latest_facts` | Latest facts per (date, line) | ShiftBrief |
| `analytics.v_latest_brief` | Latest brief per (date, line, lang, kind) with `is_revision` | ShiftBrief |
| `analytics.v_brief_health` | Withheld, revision and within-normal-variation rates per day | ShiftBrief |
| `analytics.v_intake_health` | Per-source batch dispositions and quarantine totals | ShiftBrief |

`v_trend_daily.baseline_7d_*` are pooled sums (Σng / Σproduced), which is exactly what the two-proportion z-test in the facts builder compares against — the view and the test cannot disagree.

---

## 9. Access control

| Role | Grants | Note |
|---|---|---|
| `app_rw` | DML on `core`, `analytics`, `agent`, `ops`; INSERT/SELECT on `audit` | API, intake, workers |
| `app_ro` | SELECT everywhere | Reporting |
| **`agent_ro`** | SELECT on `core.line/sku/defect_type/shift_calendar/plant`, the three `core.v_*` views, four `analytics.v_*` views, `agent.run`, `agent.tool_call` — **nothing else** | The typed tools **and text-to-SQL** run as this role. No base fact tables (row-level detail), no users, no scope, no archives, no `pg_*` beyond defaults. The executor also sets `statement_timeout = 5s` per session (ADR-S07) |
| `analytics_ro` | SELECT on `core`, `analytics` | BI |

`agent_ro` is narrower than the platform's: because ShiftBrief has a text-to-SQL path, the role's grant list *is* the SQL whitelist. Adding a view to the tool set means granting it here, deliberately.

---

## 10. Demo and test dataset

[`db/seed_demo.sql`](../db/seed_demo.sql) reproduces **SRS-02 Appendix A**: 30 days (2026-08-12 … 2026-09-10), 3 lines × 2 shifts, from explicit per-line/per-shift quantities — no `random()`, no modulo.

| Fact | Value |
|---|---|
| Baseline day (×29) | 11,986 produced / 311 NG = **2.5947 %** |
| Planted day 2026-09-10 | **12,430 / 382 = 3.0732 %** |
| 7-day baseline (09-03…09-09) | 83,902 / 2,177 = **2.5947 %** → **+18.4 %** |
| Significance | z = 3.096, **p ≈ 0.002** (SRS says 0.004 — illustrative) |
| Top defect | Missing Component **157 = 41.1 %** |
| Worst line | Line 3 **2,147 / 125 = 5.822 %**; Shift B 1,077 / 95 = **8.82 %**; Missing Component 63 % of L3 |
| Correction | 2026-08-20 L2/B NG 60 → 62 via a superseding batch; facts `1.0` and `1.0-r2`; brief + **revised** brief |
| Intake | 3 batches: committed (183 rows, 3 quarantined), **rejected** (24 rows, 12.5 % invalid), committed correction |
| Briefs | 6: EN + TH day 30, "within normal variation" day 29, original + revised day 9, **withheld** day 28 |

> **SRS inconsistency.** Appendix A states "Line 3 — 5.82 % (n = 2,140)". No integer NG count yields 5.82 % of 2,140 (5.815–5.825 % × 2,140 = 124.4–124.7). The seed uses n = 2,147. Recorded in the README; the SRS is not edited here.

Every facts row's `facts_sha256` is computed at insert with `digest(facts_json::text, 'sha256')` and re-checked by the verification queries — the same computation the API uses for `FACTS_STALE`.

---

## 11. Sizing and lifecycle

Tiny. At 3 lines × 2 shifts × 3 SKUs: ~20 `production_fact` rows/day, ~100 `defect_fact` rows/day, ~4 facts rows/day, ~4 briefs/day. Ten years fits in well under 1 GB. The only volume is **archived source files** in object storage (~1–50 MB/day depending on the source); retain 2 years.

| Data | Retention |
|---|---|
| Raw archives | 2 years (object lifecycle) |
| `production_fact`, `defect_fact` | 5 years |
| `facts`, `brief` | 5 years — **never auto-deleted while any brief references the facts row** |
| Agent runs, audit | 2 years |

Migrations: Alembic; `facts_version` bump on analytics changes; old facts rows are retained. Backup: nightly dump + WAL; RPO ≤ 24 h, RTO ≤ 4 h; quarterly drill (OPS §6).

---

## 12. Platform mode

| Concern | Standalone | Platform mode |
|---|---|---|
| `schema.sql` | Applied on first start | **Not applied** — platform already has sections 1–9 verbatim |
| `analytics.*` | Part of `schema.sql` | Migration **`shiftbrief_0001`** against the platform database (2 enums, 8 tables, 6 views, grants) |
| `core.production_*` | Owned here | Owned by the platform; ShiftBrief's intake worker is the platform's `POST /ingest/production` implementation |
| `agent.tool` rows | 10 tools | Registered into the platform registry; `run_sql` stays disabled unless the platform flag is on |
| `significant = true` | Alert event | Also opens `quality.signal` (`defect_rate_shift`) for QE-Agent |
| `agent_ro` grants | ShiftBrief views | Platform `agent_ro` gains the same view grants; the SQL whitelist is the union |

---

## 13. Traceability

| SRS-02 | Implemented by |
|---|---|
| FR-01 sources | `analytics.source.kind` |
| FR-02 mapping | `analytics.source_mapping`, §6 |
| FR-03 validation | `production_fact` CHECKs, `quarantine_row`, mapping `rules` |
| FR-04 >5 % reject | `ingest_batch.status = 'rejected'`, `batch_detail.disposition` |
| FR-05 idempotent | `production_fact` natural PK; `ingest_batch.sha256` |
| FR-06 archive + hash | `ingest_batch.archive_uri`, `sha256` |
| FR-07 corrected file → revised | `batch_detail.supersedes_batch_id`, `facts_version`, `brief.revised_of` |
| FR-08 late file alert | `analytics.file_expectation`, `alert_event.file_not_arrived` |
| FR-09…16 analytics | Facts object §7, `v_trend_daily`, `v_line_shift_daily.rankable` |
| FR-17…22 brief | `analytics.brief`, `subscription.lang/tone` |
| FR-23…26 Q&A | `agent.*`, `agent_ro` whitelist §9 |
| FR-27…31 delivery | `subscription`, `brief.delivered_at`, `alert_event` |
| AI-02 prompt versioning | `brief.prompt_version` |
| AI-03 deterministic | `facts_sha256` |
| AI-05 constrained SQL | `agent_ro` grants §9 |
| NFR-07 PII | mapping `pii: pseudonymise` |
| NFR-08 reproducible | DD-S01, `facts_sha256` |
| C-01 facts-only LLM | `brief.facts_id` NOT NULL |
| C-02 archives | `ingest_batch.archive_uri` |
| C-03 idempotent rerun | DD-S01 |

---

## Appendix A — The constraints that carry the most weight

| Constraint | Protects against |
|---|---|
| `trg_facts_immutable` | A brief whose provenance was edited after the fact |
| `brief_withheld_has_no_text` | An ungrounded brief being displayed |
| `production_fact` natural PK | Duplicate production data on re-ingest |
| `ng_not_exceeding_produced` | The commonest file error reaching the warehouse |
| `source_mapping_reason_present` | An unexplained change to how a file is read |
| `agent_ro` view-only grants | Text-to-SQL reaching row-level or credential data |
