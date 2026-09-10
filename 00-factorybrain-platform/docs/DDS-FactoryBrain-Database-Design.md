# Database Design Specification — FactoryBrain AI Platform

| Field | Value |
|---|---|
| Document ID | DDS-00-FactoryBrain |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS §6](../SRS-FactoryBrain-AI-Platform.md), [SAD §4.6](SAD-FactoryBrain-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) · [`db/seed_demo.sql`](../db/seed_demo.sql) |

---

## 1. Introduction

### 1.1 Purpose
This document specifies the physical data model for FactoryBrain AI: the schemas, tables, keys, constraints, indexes, views, roles and lifecycle policies that implement the platform's data requirements. `schema.sql` is the authoritative artifact; this document explains **why** it looks the way it does.

### 1.2 Target platform
PostgreSQL 16 with `pgvector ≥ 0.7`, `pgcrypto`, `pg_trgm`, `btree_gin`. TimescaleDB is **optional** (ADR-007). Verified against the `pgvector/pgvector:pg16` image.

### 1.3 How to apply
```bash
psql -v ON_ERROR_STOP=1 -f db/schema.sql
psql -v ON_ERROR_STOP=1 -f db/seed_demo.sql   # optional: demo / test data
```
`schema.sql` is ordered so it executes top-to-bottom on an empty database: extensions → schemas → functions → enums → tables → indexes → triggers → views → roles/grants → version stamp.

---

## 2. Design principles

| ID | Principle | Rationale |
|---|---|---|
| **DD-01** | The database enforces the invariants that matter, not just the application. | An invariant enforced only in Python survives exactly as long as the next contributor's memory. Approval completeness, idempotency, evidence presence and spec-limit ordering are all CHECK/UNIQUE constraints. |
| **DD-02** | `timestamptz` everywhere, stored UTC. | Shift attribution and change-point analysis are silently corrupted by naive timestamps. Local time is a presentation concern. |
| **DD-03** | UUIDv7 for client-created rows; `bigint` identity for server-only append-only rows. | Edge and mobile devices create records offline (ADR-012). Telemetry samples and audit rows never originate off-server, so they use cheaper keys. |
| **DD-04** | Natural-key primary keys where the source data has one. | `production_fact` is keyed `(prod_date, shift, line_id, sku_id)`, which makes re-ingest an `UPSERT` rather than a delete-and-reload (SRS FR-P-05). |
| **DD-05** | No soft deletes. Use `active` flags for master data, real deletes elsewhere. | A `deleted_at` column that every query must remember to filter is a defect generator. Master data uses `active`; transactional data is retained or genuinely removed by the retention job. |
| **DD-06** | Audit is append-only at the grant level. | `app_rw` holds `INSERT, SELECT` on `audit.*` and nothing else. Non-repudiation that depends on application discipline is not non-repudiation. |
| **DD-07** | Derived values are generated columns or views, never application-written columns. | `measurement.in_spec` and `fmea_row.rpn` cannot drift from their inputs. |
| **DD-08** | Every table and non-obvious column carries a `COMMENT`. | The comments are the data dictionary; a separate spreadsheet would be stale within a month. |

### 2.1 Naming conventions
| Object | Convention | Example |
|---|---|---|
| Schema, table, column | `snake_case`, singular table names | `vision.inspection` |
| Primary key | `id` | `quality.case.id` |
| Foreign key | `<referenced_table>_id` | `line_id`, `defect_type_id` |
| Boolean | positive phrasing, no `is_not_` | `active`, `is_critical` |
| JSON payload | `*_json` suffix | `evidence_json` |
| Timestamp | `*_at` for events, `ts` for series | `approved_at`, `ts` |
| Index | `idx_<table>_<purpose>` | `idx_inspection_review` |
| View | `v_<subject>` | `v_kpi_daily` |
| Enum type | schema-qualified, singular | `vision.verdict` |

---

## 3. Schema organisation

One database, one schema per bounded context. Isolation is by schema plus role grants — not by separate databases, because the analytical queries that make this platform useful join across all of them.

| Schema | Owns | Primary consumer |
|---|---|---|
| `core` | Master data (plant, line, SKU, machine, defect type, lot, user), production facts, ingest batches | Everything |
| `vision` | Inspections, detections, measurements, overrides, model registry, drift | SRS-01, SRS-03, SRS-05 |
| `quality` | Characteristics, control limits, SPC violations, capability, signals, cases, artifacts, FMEA, molding shots | SRS-09, SRS-11 |
| `telemetry` | Sensors, samples, features, baselines, health index, alerts, maintenance | SRS-06 |
| `knowledge` | Documents, chunks, embeddings, case records, glossary, translation memory | SRS-14, SRS-15, SRS-10 |
| `agent` | Tool registry, runs, tool calls, proposals, findings, briefings, conversations | SRS-10, SRS-13 |
| `docflow` | Inbound documents, extraction, validation, approval, ERP postings | SRS-08 |
| `ops` | Edge fleet, node health, scheduled jobs, runtime config, data-quality events | Operations |
| `audit` | Append-only audit and auth event log | Compliance |

### 3.1 What is deliberately *not* in this database

`farm` (SRS-12 GAPFarm) and `pawtrace` (SRS-07 Dog Finder) are **not created** by `schema.sql`.

They appear in this document because the user requested full-sibling coverage, and the honest answer is that their integration surface with FactoryBrain is empty. Both are separate deployments that **reuse the platform's patterns** — UUIDv7 keys, pgvector retrieval, append-only audit, offline-first sync, human-in-the-loop gating — but placing agricultural scouting records or lost-pet sightings inside a factory quality database would couple systems that have no shared queries, no shared users, and no shared retention or privacy regime.

Their schemas are specified in [§12](#12-sibling-schemas-outside-the-platform-database) as standalone designs. If they are ever deployed, they get their own database instance with the same conventions from §2.

---

## 4. `core` — master data and production facts

### 4.1 ERD

```
plant ──< line ──< machine
  │        │
  │        └──< user_line_scope >── app_user
  │
  └──< shift_calendar

sku ──┐
      ├──< production_fact >── line          (PK: date, shift, line, sku)
      └──< defect_fact     >── defect_type

ingest_batch ──< quarantine_row
ingest_batch ──< production_fact / defect_fact   (provenance)

material_lot   (referenced by quality.shot, correlated by lot code on inspections)
```

### 4.2 Table specifications

**`core.plant`** — one row per physical site. `timezone` is used to resolve "yesterday" and shift boundaries for that site.

**`core.line`** — production line. `UNIQUE (plant_id, code)` because line codes are only unique within a plant.

**`core.sku`** — product. `spec_json` carries per-product data that does not deserve columns (ideal cycle time, packaging, customer-specific tolerances).

**`core.machine`** — equipment. `criticality` drives alert severity weighting in SRS-06 and risk ranking in SRS-13.

**`core.defect_type`** — the defect vocabulary, trilingual.

| Column | Type | Notes |
|---|---|---|
| `code` | `text UNIQUE` | Stable identifier used by edge nodes and import files |
| `name_th/ja/en` | `text NOT NULL` | All three required — a missing translation surfaces as a blank label on a shop-floor screen |
| `is_critical` | `boolean` | **Carries the recall ≥ 0.98 gate** (SRS AI-03). Used by the model promotion check and by risk ranking |

**`core.shift_calendar`** — shift boundaries **versioned by date** (`valid_from`, `valid_to`). Without versioning, a schedule change silently re-attributes every historical record when someone asks about "shift B last quarter".

**`core.app_user`** / **`core.user_line_scope`** — five roles per SRS FR-S-01. An empty scope means *all lines*; a non-empty scope restricts. The scope is applied as a **predicate inside tools**, never as post-hoc response filtering (SAD §5.1).

**`core.ingest_batch`** — one row per imported file.

| Column | Notes |
|---|---|
| `sha256` | Content hash; makes re-ingest detectable and idempotent |
| `status = 'rejected'` | The batch exceeded the >5 % invalid-row threshold (SRS §6.3) and was **not committed** |
| `archive_uri` | Immutable copy of the original file |
| CHECK | `rows_ok + rows_quarantined <= rows_total` |

**`core.production_fact`** — the daily production grid. Primary key is the natural key (DD-04), so `INSERT ... ON CONFLICT DO UPDATE` gives idempotent re-ingest for free. `CHECK (qty_ng <= qty_produced)` catches the single most common import error.

**`core.defect_fact`** — defect counts by type, same grain plus `defect_type_id`.

**`core.quarantine_row`** — rejected rows with a **human-readable** reason. The test is whether a data owner can fix the source file without reading code.

---

## 5. `vision` — inspection records

### 5.1 ERD

```
model_registry ──┐
                 ├──< inspection (PARTITIONED BY ts) ──< detection
recipe ──────────┤                                   ├──< measurement
camera ──────────┘                                   └──< verdict_override
                 │
edge_node (ops) ─┘

drift_metric >── camera, model_registry
```

### 5.2 Partitioning
`vision.inspection` is `PARTITION BY RANGE (ts)`, monthly. At the SRS NFR-05 target of 100 k inspections/day this is ~3 M rows per month; a single heap makes the retention sweep and `VACUUM` unmanageable, and partition pruning is what keeps QAS-01 (≤ 2 s for 90-day queries) achievable.

- Primary key is `(id, ts)` — PostgreSQL requires the partition key in the PK.
- Child tables `detection`, `measurement`, `verdict_override` therefore carry a composite FK `(inspection_id, inspection_ts)`.
- A `DEFAULT` partition exists so an out-of-range timestamp never fails an insert. **An alert fires if it is non-empty** — a row landing there means clock skew or a missing partition (OPS RB-13).

### 5.3 Notable columns

| Column | Design note |
|---|---|
| `inspection.id` | Client-generated UUIDv7. This is what makes offline creation and sync dedup possible (SAD §5.7) |
| `inspection.verdict` | `PASS / FAIL / REVIEW / NO_READ`. **`NO_READ` is distinct from `PASS`** — the frame failed the quality gate and nothing was actually judged. Collapsing them would inflate the pass rate |
| `inspection.model_id` | FK to the registry. SRS FR-S-03 requires the model version on every inference; a text column would drift |
| `detection.confidence` | `numeric(5,4)` with `CHECK 0..1` |
| `measurement.in_spec` | **Generated column** — derived from `value`, `usl`, `lsl`, so it cannot contradict the limits (DD-07) |
| `verdict_override` | `CHECK (old_verdict <> new_verdict)`. Also the retraining dataset source (SRS FR-V-04) |
| `recipe.review_threshold` | Per-SKU, because tolerance for false alarms differs by customer (SRS FR-V-02) |

### 5.4 Model registry
`vision.model_registry` records every model that has been deployed, with `metrics_json` holding hold-out results and `stage ∈ {candidate, shadow, active, retired}`. The shadow → promote → rollback flow in SAD §4.4.4 is a `stage` transition plus a `promoted_by` / `promoted_at` stamp. Rollback works because the previous row is still `active`-capable.

---

## 6. `quality` — SPC, cases, FMEA

### 6.1 SPC tables

**`quality.characteristic`** — what is measured, with `usl`/`lsl`/`target`, chart type and subgroup rule.

**`quality.control_limits`** — **append-only limit history** with a mandatory `reason` and `created_by`. Recalculating control limits silently is a classic way to make a process shift disappear from the chart; storing the history with a reason makes it a decision rather than an accident. `baseline_from`/`baseline_to`/`sample_size` are stored so a limit can always be justified.

**`quality.spc_violation`** — Nelson rule hits. `rule` is `smallint CHECK (1..8)`; the minimum implemented set is {1,2,3,5,6} (SRS FR-Q-04).

**`quality.capability_result`** — Cp/Cpk/Pp/Ppk with `n`, `period_from/to`, `normality_p` and `normality_ok`.

> `normality_ok = false` means Cp/Cpk **must not be presented as valid** (SRS-09 C-03). Storing `n` and the period alongside the index makes it structurally impossible to quote a capability number without its sample context — which is the single most common way Cpk is misused.

### 6.2 Case management

```
signal ──> case ──┬──< case_step        (5-Why, notes, containment)
                  ├──< hypothesis
                  ├──< artifact         (8D, FMEA proposal, report)
                  └──< action ──> effectiveness_json
```

**`quality.case_step`** and **`quality.artifact`** are the P-3 enforcement point:

| State | Meaning |
|---|---|
| `ai_generated = true`, `approved_by IS NULL` | **DRAFT.** Cannot be exported without watermark; cannot become precedent in `knowledge`; cannot be cited by another agent |
| `approved_by IS NOT NULL` | Approved by a named human at a recorded time |

`CHECK (approval_is_complete)` prevents a half-set approval (`approved_by` without `approved_at`). A partial index `idx_case_step_draft` makes "show me everything awaiting approval" cheap.

**`quality.action.effectiveness_json`** holds the before/after defect rate and significance test. An action reaches status `verified` only when this shows a real improvement (SRS-09 FR-28) — closing a case because the paperwork is done is exactly what this prevents.

### 6.3 FMEA
`quality.fmea_row` carries **both** `rpn` (generated as `s*o*d`) and `ap` (AIAG-VDA Action Priority). Which is authoritative is a configuration choice (SRS-09 C-05); carrying both avoids a migration when an organisation switches standards.

### 6.4 Injection molding extension (SRS-11)
`mould`, `shot`, `shot_part`, `timeline_event`. `shot` holds per-shot machine parameters from OPC-UA / Euromap 77. `shot_part` links a cavity to an inspection, which is what makes per-cavity defect analysis possible — the highest-value analysis in molding and the one most often impossible because cavity identity was never recorded.

`quality.timeline_event` is the correlation backbone: lot changes, parameter edits, maintenance, tool changes and startups on one timeline, so change-point analysis has something to correlate against.

---

## 7. `telemetry` — machine time-series

### 7.1 Structure

```
machine ──< sensor ──< sample     (PARTITIONED BY ts, monthly)
                   ├──< feature   (windowed aggregates, by context)
                   └──< baseline  (healthy-state stats, versioned)

machine ──< health_index
        ├──< alert ──> alert_feedback
        └──< maintenance_event
```

### 7.2 Design notes

**Context-aware features.** `telemetry.feature` carries a `context ∈ {running, idle, changeover, stopped, startup}`. Comparing a running machine against a baseline that includes idle periods produces meaningless anomaly scores — this is why context is part of the primary key, not an afterthought.

**Baseline confirmation.** `telemetry.baseline.confirmed_by` requires an engineer to confirm the healthy window. A baseline captured during an already-degraded period normalises the fault permanently, and the system then never alerts on it. Making confirmation a column forces the question to be asked.

**RUL as an interval.** `alert.rul_low_days` / `rul_high_days` with `CHECK (high >= low)`. There is deliberately **no single-value RUL column**: SRS-06 C-04 requires uncertainty to be carried, and `NULL` means "insufficient history" — which the system must say rather than guess.

**Feedback loop.** `alert_feedback` records `true_positive / false_positive / unknown` plus the actual finding. Without this there is no way to compute alert precision, and unmeasured alert fatigue is what kills predictive-maintenance deployments.

### 7.3 Partitioning and TimescaleDB
`telemetry.sample` uses **native declarative partitioning** so the schema applies on stock PostgreSQL. Where TimescaleDB is present, the same tables convert to hypertables with compression and continuous aggregates. The conversion is a **deliberate migration** (OPS RB-12), not a side effect of running `schema.sql` — `schema.sql` only emits a `NOTICE` telling you which mode you are in.

---

## 8. `knowledge` — documents, embeddings, memory

### 8.1 Structure

```
document ──< chunk           (embedding vector(1024), HNSW)
        └──< case_source >── case_record ──< case_chunk
glossary_term
tm_segment                   (translation memory, embedded)
```

### 8.2 Vector design

| Decision | Value | Rationale |
|---|---|---|
| Dimensions | 1024 | SRS AI-05; multilingual model covering TH/JA/EN |
| Distance | cosine (`vector_cosine_ops`) | Embeddings are L2-normalised |
| Index | HNSW, `m = 16`, `ef_construction = 64` | Good recall/build-time balance at this corpus size; `ef_search` tuned at query time |
| Versioning | `embedding_version` column | A model upgrade is a **background re-embed**, not a stop-the-world migration (ADR-001). Queries filter to a single version so two vector spaces are never mixed in one ranking |

### 8.3 Hybrid retrieval
Vector search alone underperforms on exact codes, part numbers and Japanese technical terms. Every embedded table also carries a **trigram GIN index** (`pg_trgm`).

Trigram is chosen over `tsvector` deliberately: Thai and Japanese have no word spaces, and PostgreSQL's default text-search configurations do not tokenise them usefully. Trigram degrades gracefully across all three languages.

### 8.4 Verified vs extracted knowledge
`knowledge.case_record.verified_at IS NULL` means the record was LLM-extracted and never human-confirmed (SRS-15 C-02).

The view `knowledge.v_citable_case` filters to verified records only, and **agent citation reads the view, not the base table**. This is the structural reason an unverified extraction cannot be quoted back as established fact — it is not a prompt instruction, it is a predicate.

---

## 9. `agent` — runs, tools, findings

### 9.1 The tool registry is the capability boundary
`agent.tool` holds name, `kind ∈ {read, write}`, `risk`, JSON Schema and `min_role`. There is deliberately **no free-form shell or SQL tool** (ADR-005). Adding a capability means adding a row *and* a reviewed implementation.

### 9.2 Grounding is auditable after the fact
`agent.run` stores:

| Column | Purpose |
|---|---|
| `facts_json` | The exact structured facts object handed to the model |
| `grounding_json` | Post-check result: numeric tokens found in the answer, and whether each matched a tool result |
| `outcome` | Includes `grounding_failed` — the answer was **withheld**, not returned with a warning |
| `prompt_version`, `model` | Reproducibility (SRS AI-10) |

The view `agent.v_grounding_health` turns P-1 into an operational metric. A rising `grounding_failure_pct` means the model is drifting toward fabrication and is an incident, not a curiosity.

### 9.3 Approval binding
`agent.action_proposal` stores `args_hash` and `expires_at`. Approval binds to **one specific set of arguments** and expires (default 10 minutes). Without the hash, an approval could be replayed against different arguments; without expiry, a stale approval executes in a changed world.

### 9.4 Findings blackboard
`agent.finding` carries a database-level constraint:

```sql
CONSTRAINT finding_has_evidence CHECK (jsonb_array_length(evidence_json) > 0)
```

SRS-13 C-02 says a finding without evidence is invalid. Enforcing it in the database means it is true regardless of which agent wrote the row.

Recurrence is handled by `first_seen` / `last_seen` / `occurrences` rather than duplicate rows (SRS-13 FR-24).

`agent.briefing.partial` + `partial_reason` make an incomplete picture announce itself — a briefing that silently omits a failed domain is worse than no briefing.

---

## 10. `docflow`, `ops`, `audit`

### 10.1 `docflow` — the only outbound write path
`docflow.posting` carries `UNIQUE (adapter, idem_key)`. **The database guarantees no double-post under retry**, independently of application logic (SRS-08 C-04, AC-05). This is the single most consequential constraint in the schema: a duplicated purchase order is a real financial event.

`docflow.extracted_field` requires `page_no` + `bbox_json` provenance; a field without provenance is treated as low confidence regardless of model score (SRS-08 AI-04).

### 10.2 `ops` — fleet and configuration
`ops.edge_node.buffer_depth` is the earliest signal of a connectivity or ingest problem — it rises before anything else looks wrong (OPS RB-05).

`ops.config` holds **runtime-tunable settings only** (thresholds, schedules). Secrets and infrastructure settings live in environment variables and never in the database.

`ops.data_quality_event` records clock skew, stuck sensor values, missing files and schema drift, so data problems are visible rather than silently poisoning downstream analysis.

### 10.3 `audit` — append-only by grant
`audit.log` and `audit.auth_event` use `bigint GENERATED ALWAYS AS IDENTITY`. `app_rw` holds `INSERT, SELECT` and nothing else; no role anywhere holds `UPDATE` or `DELETE`. `correlation_id` ties an audit row to the agent run and HTTP request that produced it.

---

## 11. Demo and test dataset

[`db/seed_demo.sql`](../db/seed_demo.sql) generates a **deterministic** 30-day dataset (2026-08-12 … 2026-09-10, 3 lines × 2 shifts). There is no `random()` anywhere — every value comes from a fixed formula seeded by date index, so tests can assert exact numbers.

**Planted scenario.** From 2026-09-08, Line 3 / Shift B defect rate rises from ~2.4 % to ~6 %, driven by `MISSING_COMPONENT`, coincident with material lot `LOT-2609-114` entering at 14:12 (recorded in `quality.timeline_event`). Everything else stays within normal variation.

This gives the test suite two things it needs:
1. Something **true to find** — correlation analysis should surface the lot change.
2. Something that must **not** trigger — the other 29 days and 5 line/shift combinations must not raise alerts (guards against a detector that fires on everything).

The script refuses to run against a non-empty `core.production_fact`, and ends with `\echo` verification queries stating the expected values (180 production rows; defect totals equal to `qty_ng`; 183 PASS / 12 FAIL / 5 REVIEW; 5 in the review queue; 1 citable case). If any of these change, either the seed or an aggregation view has drifted and the affected test cases must be re-baselined.

Fixed UUIDs (`00000000-0000-7000-8000-…`) let test cases reference entities by literal.

> **No credential ships in this file.** `password_hash` is the literal `SET_AT_BOOTSTRAP`; real hashes are set by the bootstrap job (OPS §3.4).

---

## 12. Sibling schemas outside the platform database

These are specified for completeness (full-sibling scope) and are **not created** by `schema.sql`. Each would be deployed as its own database using the conventions in §2.

### 12.1 `farm` — GAPFarm AI (SRS-12)
```sql
farm(id, name, owner_id, location geography(Point,4326), gap_scheme)
zone(id, farm_id, name, boundary geography(Polygon,4326), area_rai, crop_id, planted_at)
crop(id, name_th, name_en, variety, stage_model_json)
observation(id, zone_id, ts, kind, photos_json, severity, area_pct, reporter_id)
diagnosis(id, observation_id, model_version, candidates_json, chosen_id, confirmed_by, confirmed_at)
input_product(id, name, active_ingredient, phi_days, rei_hours, approved, label_uri, mrl_json)
input_usage(id, zone_id, product_id, ts, dose, unit, method, applicator_id, weather_json, ppe, record_version)
task(id, zone_id, kind, description, due_at, owner_id, status, evidence_json, source_diagnosis_id)
sensor(id, zone_id, kind, unit, last_seen_at, status)
telemetry(ts, sensor_id, value, quality)
harvest(id, zone_id, lot_code, harvested_at, qty, unit, grade, traceability_json)
```
**Requires PostGIS** (the platform database does not). Two constraints matter: `input_usage` records are **append-only and versioned** for GAP audit (SRS-12 C-03), and harvest eligibility is computed from `input_product.phi_days` against the latest `input_usage` per zone — the PHI block is a safety-relevant rule, not a warning banner.

### 12.2 `pawtrace` — AI Dog Finder (SRS-07)
```sql
report(id, kind, status, description, lost_at, location geography(Point,4326), contact_channel_id, user_id)
photo(id, report_id, uri, sha256, exif_stripped, moderation_status)
dog_instance(id, photo_id, bbox_json, crop_uri, quality_score)
embedding(instance_id, model_version, vec vector(768))
attributes(instance_id, size_class, color_primary, coat_len, breed_group, confidence_json)
match(id, lost_report_id, found_report_id, score, components_json, status, decided_at, decided_by)
reunion(id, lost_report_id, found_report_id, confirmed_at)
```
**Requires PostGIS**, uses `vector(768)` (not 1024 — a different embedding model). Privacy is structural: `photo.exif_stripped` is asserted before storage, and public queries must read location through a fuzzing function, never the raw `geography` column (SRS-07 C-01).

### 12.3 `ops` for OpsPilot (SRS-04)
OpsPilot's tables (`tool`, `agent_run`, `tool_call`, `action_proposal`, `incident`, `policy`) are **structurally identical** to the platform's `agent` schema. If both are deployed on one host they should share the `agent` schema rather than duplicate it; if deployed separately, OpsPilot gets its own database. What must **not** happen is OpsPilot's infrastructure-control tools being registered in the same `agent.tool` registry that the factory Copilot reads — the blast radius of those two tool sets is completely different.

---

## 13. Access control

### 13.1 Roles

| Role | Grants | Used by |
|---|---|---|
| `app_rw` | DML on all business schemas; `INSERT, SELECT` only on `audit` | API and workers |
| `app_ro` | `SELECT` everywhere including `audit` | Reporting, read replicas |
| `agent_ro` | `SELECT` on `core`, `vision`, `quality`, `telemetry`, `knowledge`; **`REVOKE`d on `core.app_user` and `core.user_line_scope`** | Agent tool layer |
| `edge_ingest` | `INSERT` on three `vision` tables, `SELECT` on recipe/model, node health writes | Edge sync endpoint |
| `analytics_ro` | `SELECT` on analytical schemas only | Ad-hoc analysis, BI |

`agent_ro` is the important one: the agent tool layer runs as a role that **cannot read credentials or user scope tables even if a tool is buggy**. Defence in depth behind the tool-layer permission predicate.

`edge_ingest` is the narrowest role in the system — an edge node that is physically compromised can insert inspections and nothing else.

`ALTER DEFAULT PRIVILEGES` ensures future tables inherit the same posture rather than silently defaulting to no grants (which fails at runtime) or excessive grants (which fails at audit).

### 13.2 Row-level scope
Line-level restriction (`core.user_line_scope`) is applied as a **predicate inside the tool implementation**, not as PostgreSQL RLS, in v1. RLS is the stronger mechanism and is the documented upgrade path; it is deferred because the tool layer is already the single choke point for agent data access and adding RLS now would duplicate the policy in two places with no test to keep them in sync.

---

## 14. Data lifecycle

### 14.1 Retention (implements SRS §6.2)

| Data | Retention | Mechanism |
|---|---|---|
| PASS evidence images | 30 days, then thumbnail only | Object-store lifecycle rule + `retention_sweep` job |
| FAIL / REVIEW images | 2 years | Object-store lifecycle rule |
| Inspection records | 5 years | Partition drop |
| Telemetry raw | 90 days | Partition drop |
| Telemetry 1-min aggregates | 2 years | Continuous aggregate / materialised view |
| Agent runs, audit log | 2 years | Partition drop (audit exported before drop) |
| Quality cases, FMEA | Indefinite | Never auto-deleted — this is the institutional memory |

`retention.pass_image_days` and `retention.fail_image_days` are in `ops.config` so a plant can tighten them without a deployment.

### 14.2 Partition maintenance
The `partition_maintain` job creates the next three months of partitions and drops those past retention. It runs monthly and alerts if the `DEFAULT` partition is non-empty (OPS RB-13).

### 14.3 Migrations
Alembic, one revision per change, forward-only in production.

| Rule | Reason |
|---|---|
| Every migration is rehearsed against a **restored production dump** before release | Migrations on partitioned, multi-million-row tables behave differently on an empty database (AR-08) |
| No `ALTER TABLE ... ADD COLUMN NOT NULL DEFAULT` on a large table without review | Table rewrite risk |
| Index creation uses `CONCURRENTLY` in production | Avoids write locks during a shift |
| Destructive changes are two-phase (deprecate → drop in a later release) | Allows rollback of the application without data loss |

### 14.4 Backup and recovery
Nightly `pg_dump` plus continuous WAL archiving for PITR. **Documented RPO ≤ 24 h, RTO ≤ 4 h** (QAS-14). NFR-12 requires a quarterly restore drill — an untested backup is a hypothesis, not a backup. Object storage is snapshotted on the same schedule; a database restored without its evidence images is only partially useful.

---

## 15. Sizing

Assumptions: 10 lines, 100 k inspections/day, 20 machines × 10 signals @ 1 Hz, 500 documents/month.

| Table | Rows/year | Storage/year | Note |
|---|---|---|---|
| `vision.inspection` | ~36 M | ~14 GB | Partitioned monthly |
| `vision.detection` | ~4 M | ~1.5 GB | Only failing/reviewed parts |
| `vision.measurement` | ~10 M | ~1 GB | Where measurement recipes are configured |
| `telemetry.sample` | ~6.3 B | — | **Not stored raw at 1 Hz for a year.** 90-day raw retention → ~1.5 B rows, ~60 GB; aggregates thereafter |
| `telemetry.feature` | ~50 M | ~4 GB | Windowed |
| `knowledge.chunk` | ~200 k | ~1.5 GB | Dominated by the 1024-dim vectors (~4 KB/row incl. HNSW) |
| `agent.run` + `tool_call` | ~500 k | ~2 GB | `facts_json` is the bulk |
| `audit.log` | ~5 M | ~3 GB | |
| **Evidence images (object store)** | — | **~2–4 TB** | The real storage driver. PASS sampling and 30-day retention are what keep this bounded |

The database itself fits comfortably on the 1 TB SSD from SRS §2.3. **Object storage is the capacity constraint**, and the PASS-image sampling rate is the main lever.

---

## 16. Traceability

| SRS requirement | Implemented by |
|---|---|
| §6.1 core tables | All schemas; superset of the SRS sketch |
| §6.2 retention | §14.1, `ops.config`, partition drops |
| §6.3 data quality | `core.ingest_batch.status='rejected'`, `core.quarantine_row`, `ops.data_quality_event` |
| FR-P-05 idempotent re-ingest | `core.production_fact` natural PK (DD-04) |
| FR-V-01 inspection record | `vision.inspection` + `detection` + `measurement` |
| FR-V-02 review threshold | `vision.recipe.review_threshold`, `verdict='REVIEW'` |
| FR-V-03 override recorded | `vision.verdict_override` |
| FR-V-04 retraining export | `vision.verdict_override` join to `inspection` |
| FR-Q-02 control charts | `quality.characteristic`, `control_limits` |
| FR-Q-03 capability | `quality.capability_result` incl. normality gate |
| FR-Q-04 Nelson rules | `quality.spc_violation.rule` |
| FR-A-02 traceability | `agent.run.facts_json` + `grounding_json`, `agent.tool_call` |
| FR-A-04 HITL drafts | `quality.case_step` / `artifact` approval columns |
| FR-A-07 write-tool gating | `agent.action_proposal` |
| FR-S-01 roles | `core.app_user.role`, §13.1 |
| FR-S-02 AI call logging | `agent.run`, `agent.tool_call` |
| FR-S-03 model version | `vision.inspection.model_id` → `model_registry` |
| AI-05 embeddings | `vector(1024)` + HNSW, §8.2 |
| AI-06 model versioning | `vision.model_registry` |
| AI-07 drift | `vision.drift_metric` |
| NFR-05 scalability | Partitioning §5.2, §7.3, sizing §15 |
| NFR-06 security | §13 roles and grants |
| NFR-07 privacy | §17 |
| NFR-12 backup | §14.4 |
| C-05 AI labelled | `ai_generated` + `approved_by` throughout |
| C-06 DB source of truth | DD-01, DD-06, DD-07 |

---

## 17. Privacy

SRS NFR-07 requires that operator identity is not used as a model feature and that personal identifiers are pseudonymised in analysis.

| Measure | Implementation |
|---|---|
| No operator FK on inspection records | `vision.inspection` carries no operator column. `core.production_fact` has no operator column either — shift and line are the analytical grain |
| Operator group, not operator identity | Where SRS-11 needs an operator dimension it uses `operator_group` on `quality.shot`, deliberately coarse |
| `verdict_override.user_id` | Retained because SRS FR-V-03 requires accountability for a quality decision. This is an **audit record, not an analytical feature** — it must never be joined into a defect-correlation analysis |
| Face images | Cameras are fixed on the part, not the operator. If a face appears in evidence, retention rules apply and the image is not a training input |
| Data subject requests | Supported by `user_id` FKs being `ON DELETE SET NULL` on analytical tables and `RESTRICT` on approval tables — an approval must not lose its approver |

The `ON DELETE RESTRICT` on `quality.case_step.approved_by` is deliberate and in tension with a naive "delete all my data" request: an approval record without an approver would break the audit trail. The resolution is pseudonymisation of the user row, not deletion of the approval — documented in [SEC](SEC-FactoryBrain-Security-Requirements.md).

---

## Appendix A — Quick reference

```
core.plant / line / sku / machine / defect_type / material_lot / shift_calendar
core.app_user / user_line_scope
core.ingest_batch / production_fact / defect_fact / quarantine_row

vision.model_registry / camera / recipe
vision.inspection [PARTITIONED] / detection / measurement / verdict_override / drift_metric

quality.characteristic / control_limits / spc_violation / capability_result
quality.signal / case / case_step / hypothesis / artifact / action / fmea_row
quality.mould / shot / shot_part / timeline_event

telemetry.sensor / sample [PARTITIONED] / feature / baseline
telemetry.health_index / alert / alert_feedback / maintenance_event

knowledge.document / chunk / case_record / case_source / case_chunk
knowledge.glossary_term / tm_segment

agent.tool / conversation / message / run / tool_call
agent.action_proposal / finding / briefing / feedback

docflow.document / extraction / extracted_field / line_item
docflow.validation_result / approval / posting

ops.edge_node / node_event / node_health / scheduled_job / config
ops.data_quality_event / schema_version

audit.log / auth_event

VIEWS  core.v_kpi_daily · core.v_defect_pareto · core.v_oee_daily
       vision.v_inspection_daily · vision.v_review_queue
       knowledge.v_citable_case · ops.v_fleet_status · agent.v_grounding_health
```

## Appendix B — The five constraints that carry the most weight

If the rest of this schema were rewritten, these five would need to survive:

| Constraint | Protects |
|---|---|
| `docflow.posting UNIQUE (adapter, idem_key)` | Against duplicate financial transactions under retry |
| `quality.case_step.approval_is_complete` + `approved_by IS NULL` predicate on export | Against an AI draft becoming an official record (P-3) |
| `agent.finding.finding_has_evidence` | Against evidence-free assertions entering the blackboard |
| `core.production_fact` natural primary key | Against duplicate production data on re-ingest |
| `audit.*` having no UPDATE/DELETE grant | Against a tamperable audit trail |
