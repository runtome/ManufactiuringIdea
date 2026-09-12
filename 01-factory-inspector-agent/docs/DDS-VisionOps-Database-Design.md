# Database Design Specification — VisionOps (AI Factory Inspector Agent)

| Field | Value |
|---|---|
| Document ID | DDS-01-VisionOps |
| Version | 1.0 (Draft) |
| Date | 2026-09-11 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-01 §5](../SRS-AI-Factory-Inspector-Agent.md), [SAD-01 §4.6](SAD-VisionOps-Software-Architecture.md) |
| Artifacts | [`db/schema.sql`](../db/schema.sql) · [`db/seed_demo.sql`](../db/seed_demo.sql) |
| Platform relationship | Owns `vision.*` for [FactoryBrain (DDS-00)](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md); shared tables are byte-identical |

---

## 1. Introduction

### 1.1 Purpose
The physical data model for VisionOps as a **standalone deployment**, and the rules by which the same tables become the `vision` schema of the FactoryBrain platform. `schema.sql` is authoritative; this document explains the design.

### 1.2 Target platform and application
PostgreSQL 16 with `pgvector`, `pgcrypto`, `pg_trgm`, `btree_gin`. Verified target image `pgvector/pgvector:pg16`.

```bash
psql -v ON_ERROR_STOP=1 -f db/schema.sql
psql -v ON_ERROR_STOP=1 -f db/seed_demo.sql    # demo / test data only
```

### 1.3 How this schema was built — and why that matters
`schema.sql` is **assembled from the platform schema**, not written independently. Sections 1, 3–9 are line-range extracts of `00/db/schema.sql`; only section 10 (VisionOps-only tables), the index/view/grant subsets and the header are authored here. A diff over every `CREATE TABLE` and `CREATE TYPE` present in both files reports **44 shared objects, 0 differences**.

This is the mechanism behind ADR-V10: VisionOps can run alone *and* be the platform's vision schema because the two are literally the same text.

---

## 2. Design principles

The platform's data principles [DD-01…DD-08](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) apply unchanged: constraints in the database, `timestamptz` UTC, UUIDv7 for client-created rows, natural keys where they exist, no soft deletes, append-only audit, generated columns for derived values, comments as the data dictionary.

VisionOps adds three of its own:

| ID | Principle | Rationale |
|---|---|---|
| **DD-V01** | **The verdict of record is a view, not a column.** `vision.v_effective_verdict` resolves model verdict + latest override. Nothing rewrites `inspection.verdict`. | A human decision must never erase the model's judgement (SRS FR-13/14), and every KPI must still reflect the human decision. A view gives both without a second column that can drift. |
| **DD-V02** | **What cannot be trusted cannot be emitted.** Calibration validity is a generated column; a withheld narrative cannot store text; a frozen snapshot cannot change. | A confident wrong measurement, an ungrounded narrative, or a mutable training set are the three ways this product silently lies. Each is prevented by a constraint, not a convention. |
| **DD-V03** | **Shared tables are byte-identical to the platform; VisionOps-only tables are clearly fenced.** | Drift between standalone and platform mode is the most likely long-term defect. The fence (section 10 of `schema.sql`) and the CI diff make it visible. |

Naming conventions are the platform's (DDS-00 §2.1).

---

## 3. Schema organisation

| Schema | Contents | Relationship to platform |
|---|---|---|
| `core` | plant, line, sku, defect_type, material_lot, shift_calendar, app_user, user_line_scope | **Subset**, identical definitions. Platform adds machine, ingest_batch, production_fact, defect_fact, quarantine_row |
| `vision` | model_registry, camera, recipe, inspection (partitioned), detection, measurement, verdict_override, drift_metric — **plus** station, calibration, anomaly_score, dataset_snapshot, dataset_item, agreement_stat, narrative | **VisionOps owns this schema.** First 8 tables identical; 7 additions are candidates for back-port |
| `agent` | tool, conversation, message, run, tool_call, action_proposal, feedback | Subset, identical. Platform adds finding, briefing |
| `ops` | edge_node, node_event, node_health, scheduled_job, config, data_quality_event, schema_version | Identical |
| `audit` | log, auth_event | Identical |

Not present in standalone: `quality`, `telemetry`, `knowledge`, `docflow`. In platform mode they exist and VisionOps reads none of them directly — QE-Agent and Genba Memory read `vision.*`, not the reverse.

### 3.1 ERD — the VisionOps core

```
core.line ──< vision.station          (master record for station codes)
    │
    ├──< vision.camera ──< vision.calibration   (versioned, gauge-verified)
    │        │
    │        └──────────────┐
    ▼                       ▼
vision.inspection [PARTITION BY ts]  ──< vision.detection
    │  (id, ts) client UUIDv7        ──< vision.measurement   (in_spec generated)
    │  verdict · model_id · recipe_id──< vision.verdict_override
    │                                ──< vision.anomaly_score  (flagged generated)
    │                                ──< vision.dataset_item >── vision.dataset_snapshot
    ▼
vision.v_effective_verdict  ──►  v_inspection_daily · v_station_daily · v_defect_class_daily
                                                    │
                                                    ▼
                          agent.run ──< agent.tool_call        vision.narrative
                              ▲                                  (facts · sources · grounding)
                              └──────────────────────────────────────┘

vision.model_registry ◄── inspection.model_id · anomaly_score.model_id · agreement_stat.model_id
vision.recipe (per SKU, versioned) ◄── inspection.recipe_id
```

---

## 4. Shared `vision` tables (byte-identical to platform)

Full specifications are in [DDS-00 §5](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md). What matters here is how VisionOps *uses* them.

| Table | VisionOps role |
|---|---|
| `vision.model_registry` | Every detector, anomaly and OCR model ever deployed; `stage` drives the shadow → active → retired lifecycle; `trained_from` names a `dataset_snapshot` |
| `vision.camera` | One row per physical camera; `calib_px_per_mm` is a **denormalised cache** of the current valid calibration — `v_current_calibration` is authoritative |
| `vision.recipe` | Per-SKU, versioned rule set; `rules_json` validated against the schema in §6.3; `review_threshold` per SKU (ADR-V08) |
| `vision.inspection` | One row per judged part; partitioned monthly; `id` is the client UUIDv7 that makes offline creation and sync dedup possible |
| `vision.detection` | Class, confidence, bbox per detected defect |
| `vision.measurement` | Dimensional results with `in_spec` generated from USL/LSL |
| `vision.verdict_override` | Append-only human decisions with reason code; **also the retraining label source** |
| `vision.drift_metric` | Brightness, blur, class-distribution deviations per camera/model |

### 4.1 Partitioning
`vision.inspection` is `PARTITION BY RANGE (ts)`, monthly, with a `DEFAULT` partition that must stay empty (OPS RB-13). PK `(id, ts)`; children carry composite FKs. At 10 fps per camera, one camera produces ~860 k rows/day at free-run — in practice triggered inspection at 1–3 parts/s yields ~100–250 k/day per station, which is why monthly partitions are the minimum sensible grain.

---

## 5. VisionOps-only tables

### 5.1 `vision.station`
Master record for an inspection position. `vision.camera.station` and `vision.inspection.station` remain `text` codes so the shared tables stay unchanged; this table gives the code a home, a trigger mode, and the **PLC I/O map** used by IF-03:

```json
{"ready":"Q0.0","pass":"Q0.1","fail":"Q0.2","review":"Q0.3","fault":"Q0.4",
 "trigger":"I0.0","pulse_ms":200}
```
Changing this map is a controlled change with PLC re-validation (ICD §3).

### 5.2 `vision.calibration`
The most consequential VisionOps addition.

| Column | Purpose |
|---|---|
| `method` | `scale` (single px/mm), `intrinsics_scale` (undistort + scale), `homography` (non-normal view) |
| `hardware_fingerprint` | camera serial + lens id + mount id; runtime mismatch → measurements refused |
| `gauge_*` | ≥ 10 repeat measurements of a known artefact: nominal, mean, σ, max error |
| `tolerance_mm` | Default 0.2 (SRS AI-04) |
| **`valid`** | **Generated:** `gauge_max_err_mm IS NOT NULL AND gauge_max_err_mm <= tolerance_mm` |
| `invalidated_at/_reason` | Manual or automatic invalidation (hardware change, drift) |

`valid` being generated is DD-V02 in action: there is no way to mark a calibration valid without a verification that passes. A calibration performed but never verified is `valid = false` and the rules engine emits `NO_READ` with reason `CALIBRATION_STALE` rather than a number.

### 5.3 `vision.anomaly_score`
One row per frame scored by the anomaly model. `flagged` is generated (`score > threshold`). The rules engine reads `flagged` and may escalate to **REVIEW only** (ADR-V05). `heatmap_uri` gives the inspector a localisation cue for a defect the detector has no class for.

### 5.4 `vision.dataset_snapshot` / `vision.dataset_item`
The retraining contract (SRS FR-15, AI-08).

- A snapshot is created, items are added (from overrides, confirmed reviews, sampled PASS, manual), then it is **frozen** and exported (COCO or YOLO) with a SHA-256.
- A trigger (`vision.reject_frozen_snapshot_change`) refuses any insert/update/delete on items of a frozen snapshot.
- `dataset_item.inspection_id` is `ON DELETE RESTRICT`: the retention sweep cannot delete an inspection referenced by a snapshot. The image half of that rule (do not purge an image referenced by a frozen snapshot) is enforced by the sweep job checking `image_sha256`.
- `model_registry.trained_from` holds the snapshot name → any model traces to its exact data.

### 5.5 `vision.agreement_stat`
Model-vs-human agreement per period/line/SKU/class (SRS FR-16). The two off-diagonal cells are named explicitly because they mean opposite things:

| Cell | Meaning | Response |
|---|---|---|
| `model_fail_human_pass` | False alarm | Raise threshold, or accept |
| `model_pass_human_fail` | **Escape** — reached a human only because it was sampled or reported | Lower threshold, retrain; this is the critical-recall signal |

`agreement_pct` is generated.

### 5.6 `vision.narrative`
The generated narrative and everything needed to audit it.

| Column | Purpose |
|---|---|
| `facts_json` | The **sole** numeric input to the model — output of the facts-builder |
| `sources_json` | Tool calls with arguments and row counts |
| `grounding_json` | Post-check result: numeric tokens found, matched/unmatched |
| `significant` | From `inspection_stats`; `false` → "within normal variation", no cause (FR-21) |
| `withheld` + `withheld_reason` | Grounding failed or budget exceeded |

Two constraints carry DD-V02: `narrative_withheld_has_reason` and **`narrative_withheld_has_no_text`** — a withheld narrative stores `NULL` text. It is structurally impossible to persist an ungrounded narrative and render it later by mistake.

---

## 6. Recipes

### 6.1 Why recipes are data
ADR-V02. An engineer edits a recipe; nobody writes Python per SKU. The engine evaluates rules in a fixed order and the result is deterministic for a given `(recipe_id, inputs)`, which is what makes SRS C-03 reproducibility real.

### 6.2 Versioning
A recipe is never edited in place. `POST /recipes/{sku}` creates version N+1 with `active_from`; the previous version gets `active_to`. `inspection.recipe_id` records which version judged each part. The edge node receives the new version through the config ETag and swaps atomically; in-flight inspections finish on the version they started with.

### 6.3 `rules_json` JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://visionops.local/schemas/recipe-rules-v1.json",
  "type": "object",
  "required": ["schema_version", "rules"],
  "additionalProperties": false,
  "properties": {
    "schema_version": { "const": 1 },
    "quality_gate": {
      "type": "object",
      "properties": {
        "min_blur_variance": { "type": "number", "minimum": 0 },
        "exposure_range":    { "type": "array", "items": {"type":"number"}, "minItems": 2, "maxItems": 2 }
      }
    },
    "rules": {
      "type": "array", "minItems": 1,
      "items": { "$ref": "#/$defs/rule" }
    },
    "conflict_policy": { "enum": ["review", "fail"], "default": "review" },
    "anomaly": {
      "type": "object",
      "properties": { "threshold": { "type": "number" }, "action": { "const": "review" } }
    }
  },
  "$defs": {
    "rule": {
      "oneOf": [
        { "type":"object", "required":["kind","classes"], "additionalProperties": false,
          "properties": { "kind": {"const":"class_present"},
                          "classes": {"type":"object","additionalProperties":{"type":"number","minimum":0,"maximum":1}},
                          "verdict": {"enum":["FAIL","REVIEW"], "default":"FAIL"} } },
        { "type":"object", "required":["kind","class","max"], "additionalProperties": false,
          "properties": { "kind": {"const":"class_count"}, "class": {"type":"string"},
                          "max": {"type":"integer","minimum":0}, "min_confidence": {"type":"number"} } },
        { "type":"object", "required":["kind","class","max_mm2"], "additionalProperties": false,
          "properties": { "kind": {"const":"class_area"}, "class": {"type":"string"},
                          "max_mm2": {"type":"number","minimum":0} } },
        { "type":"object", "required":["kind","name"], "additionalProperties": false,
          "properties": { "kind": {"const":"measurement"}, "name": {"type":"string"},
                          "usl": {"type":"number"}, "lsl": {"type":"number"}, "unit": {"type":"string","default":"mm"},
                          "requires_calibration": {"const": true} } },
        { "type":"object", "required":["kind","pattern"], "additionalProperties": false,
          "properties": { "kind": {"const":"ocr_match"}, "pattern": {"type":"string","format":"regex"},
                          "on_mismatch": {"enum":["FAIL","REVIEW"], "default":"REVIEW"} } }
      ]
    }
  }
}
```

**Evaluation order** (SAD §4.3.1): quality gate → rules in array order → resolution. `class_present` thresholds are the *rule* thresholds; the recipe's `review_threshold` column is the lower bound below which a detection is ignored and between which it yields REVIEW.

### 6.4 Example

```json
{
  "schema_version": 1,
  "quality_gate": { "min_blur_variance": 120, "exposure_range": [40, 220] },
  "rules": [
    { "kind": "class_present", "classes": { "MISSING_FIN": 0.60, "MISSING_COMPONENT": 0.60 } },
    { "kind": "class_present", "classes": { "SCRATCH": 0.75 }, "verdict": "REVIEW" },
    { "kind": "class_count",   "class": "DENT", "max": 2, "min_confidence": 0.5 },
    { "kind": "measurement",   "name": "fin_pitch", "usl": 3.2, "lsl": 2.8, "requires_calibration": true },
    { "kind": "ocr_match",     "pattern": "^LOT-[0-9]{4}-[0-9]{3}$", "on_mismatch": "REVIEW" }
  ],
  "conflict_policy": "review",
  "anomaly": { "threshold": 0.82, "action": "review" }
}
```
With `review_threshold = 0.55`: a `MISSING_FIN` at 0.58 is REVIEW (≥ 0.55, < 0.60); at 0.61 it is FAIL.

### 6.5 Dry-run validation
`POST /recipes/{sku}/validate` re-evaluates the last N inspections (default 500) under the proposed rules and returns the verdict transition matrix ("14 PASS → REVIEW, 2 REVIEW → FAIL"). This is the single most useful guard against the most common recipe error.

---

## 7. Views

| View | Purpose | Identical to platform |
|---|---|---|
| `vision.v_inspection_daily` | Daily counts and defect rate (REVIEW/NO_READ excluded from denominator) | ✅ |
| `vision.v_review_queue` | REVIEW rows with no override | ✅ |
| `ops.v_fleet_status` | Edge heartbeat/buffer | ✅ |
| `agent.v_grounding_health` | Grounding failure rate per day | ✅ |
| **`vision.v_effective_verdict`** | Verdict of record (DD-V01) | VisionOps |
| `vision.v_station_daily` | Per-station defect share — feeds `station_breakdown` | VisionOps |
| `vision.v_defect_class_daily` | Per-class counts — feeds `defect_pareto` | VisionOps |
| `vision.v_current_calibration` | Latest valid calibration per camera | VisionOps |
| `vision.v_narrative_health` | Withheld and within-normal-variation rates | VisionOps |

The three VisionOps analytical views read `v_effective_verdict`, so a human override changes the KPI without touching history.

---

## 8. Access control

Roles identical to the platform: `app_rw`, `app_ro`, `agent_ro`, `edge_ingest`, `analytics_ro`.

| Role | VisionOps specifics |
|---|---|
| `agent_ro` | SELECT on `core`, `vision`; **REVOKE** on `core.app_user`, `core.user_line_scope`; read on `agent.run`/`tool_call` for `similar_periods`. The six narrative tools run as this role |
| `edge_ingest` | INSERT on `inspection`, `detection`, `measurement`, **`anomaly_score`**; SELECT on `recipe`, `model_registry`, **`v_current_calibration`**; node health writes |

Line scope is applied as a query predicate in the tool layer (DDS-00 §13.2); RLS remains the documented upgrade path.

---

## 9. Data lifecycle

| Data | Retention | Mechanism |
|---|---|---|
| PASS images | 30 days; sampled at `PASS_IMAGE_SAMPLE_RATE` (2 %) at capture time | Object-store lifecycle + sweep |
| FAIL / REVIEW images | 2 years | Object-store lifecycle |
| Images referenced by a frozen snapshot | **Never auto-deleted** | Sweep checks `dataset_item.image_sha256` |
| Inspection records | 5 years | Partition drop |
| Narratives, agreement stats | 5 years | — |
| Calibrations, recipes, models | Indefinite | Never deleted — they are the reproducibility record (C-03) |
| Agent runs, audit | 2 years | Partition drop, audit exported first |

Migrations: Alembic, rehearsed on a restored dump before release (OPS RB-12). Backup: nightly dump + WAL, RPO ≤ 24 h, RTO ≤ 4 h, quarterly drill.

---

## 10. Demo and test dataset

[`db/seed_demo.sql`](../db/seed_demo.sql) reproduces **SRS-01 Appendix A exactly**:

> Line 2 — 2026-09-10 · 1,240 units inspected · 37 defects · 2.98 % · main defect missing fin (19) · most affected SKU RAD-500-A · 31 of 37 defects in Shift B · feeder station #3.

It seeds seven days (2026-09-04 … 2026-09-10) of inspections on Line 2 across three stations, with:

- **Deterministic verdicts from explicit position lists** — no modulo arithmetic, no `random()` (a lesson from the 00 seed, where a modulo rule silently miscounted).
- Days 1–6 at ~2.0 % as the baseline; **day 7 planted at 2.98 %** with the defect concentration in Shift B and station ST3, coincident with lot `LOT-2609-114`.
- 50 `fin_pitch` measurements, a valid calibration with a 30-repeat gauge verification, an active and a shadow model, 12 overrides (10 confirming, 2 correcting), an agreement stat, and one grounded narrative run whose `facts_json` contains exactly the Appendix A numbers.

The script refuses a non-empty database and ends with `\echo` verification queries whose expected values are stated in the file and asserted by TEST TC-005, TC-046, TC-072.

---

## 11. Sizing

Per station at 2 parts/s triggered, 16 h/day: ~115 k inspections/day.

| Object | Per station per year | Note |
|---|---|---|
| `inspection` rows | ~42 M | ~16 GB |
| `detection` rows | ~1.5 M | Only on FAIL/REVIEW |
| `measurement` rows | ~42 M | If a measurement rule exists |
| `anomaly_score` rows | ~42 M | If anomaly enabled — consider sampling |
| **Evidence images** | **~1.6 TB** at 2 % PASS sampling | The binding constraint |

Three stations fit the 1 TB database volume with retention applied; object storage must be sized separately at ~5 TB/year.

---

## 12. Platform mode

| Concern | Standalone | Platform mode |
|---|---|---|
| `schema.sql` | Applied on first start | **Not applied.** Platform schema already contains sections 1–9 verbatim |
| Section 10 (VisionOps-only tables) | Part of `schema.sql` | Applied as **Alembic migration `visionops_0001`** against the platform database |
| `core.*` | Minimal subset | Platform's full master data — VisionOps reads the same columns |
| `agent.tool` rows | Six VisionOps tools | Registered into the platform registry alongside Copilot tools |
| Views | All nine | The five VisionOps views are created by the migration |
| Roles | Created by `schema.sql` | Already exist; grants on new tables added by the migration |

**Back-port rule.** When the platform adopts a VisionOps-only table, it is copied verbatim into `00/db/schema.sql` section 6 and moved above the fence in `01/db/schema.sql`. The CI diff then covers it.

---

## 13. Traceability

| SRS-01 requirement | Implemented by |
|---|---|
| FR-02 frame tagging | `inspection.camera_id`, `station`, `line_id`, `sku_id`, `lot`, `ts` |
| FR-05 detections | `vision.detection` |
| FR-06 area in mm² | `detection.area_mm2` via calibration |
| FR-07 measurement recipes | `recipe.rules_json` kind `measurement`; `vision.measurement.in_spec` |
| FR-08 per-SKU rule set | `vision.recipe` versioned; §6 |
| FR-09 REVIEW routing | `recipe.review_threshold`; `verdict = 'REVIEW'` |
| FR-10 evidence stored | `inspection.image_uri`, `overlay_uri`; `detection` JSON |
| FR-11 OCR | `inspection.ocr_text`; rule kind `ocr_match` |
| FR-13/14 override attributed | `vision.verdict_override`; `v_effective_verdict` |
| FR-15 dataset export | `dataset_snapshot`, `dataset_item`, frozen trigger |
| FR-16 agreement | `vision.agreement_stat` |
| FR-17…21 narrative | `vision.narrative` with facts/sources/grounding/significant |
| FR-22 languages | `narrative.lang` |
| AI-03 versioned models | `model_registry`, `inspection.model_id` |
| AI-04 measurement ±0.2 mm | `calibration.tolerance_mm`, generated `valid` |
| AI-06 anomaly fallback | `vision.anomaly_score`, ADR-V05 |
| AI-07 drift | `vision.drift_metric` |
| AI-08 reproducible retraining | `dataset_snapshot` frozen; `model_registry.trained_from` |
| NFR-03 24 h buffer | Client UUIDv7 dedup on `inspection.id` |
| NFR-06 override RBAC | `verdict_override.user_id`, roles §8 |
| C-03 reproducibility | `model_id` + `recipe_id` + image SHA on every row |
| C-04 no invented numbers | `narrative.facts_json` + `grounding_json` + withheld constraints |

---

## Appendix A — Quick reference

```
core.plant / line / sku / defect_type / material_lot / shift_calendar / app_user / user_line_scope

vision.model_registry / camera / recipe                       (shared)
vision.inspection [PARTITIONED] / detection / measurement     (shared)
vision.verdict_override / drift_metric                        (shared)
vision.station / calibration / anomaly_score                  (VisionOps)
vision.dataset_snapshot / dataset_item / agreement_stat       (VisionOps)
vision.narrative                                              (VisionOps)

agent.tool / conversation / message / run / tool_call / action_proposal / feedback
ops.edge_node / node_event / node_health / scheduled_job / config / data_quality_event / schema_version
audit.log / auth_event

VIEWS vision.v_effective_verdict · v_inspection_daily · v_review_queue · v_station_daily
      v_defect_class_daily · v_current_calibration · v_narrative_health
      ops.v_fleet_status · agent.v_grounding_health
```

## Appendix B — The constraints that carry the most weight

| Constraint | Protects against |
|---|---|
| `calibration.valid` generated from gauge verification | A confident wrong measurement |
| `narrative_withheld_has_no_text` | An ungrounded narrative being displayed |
| `trg_dataset_item_frozen` | A model that cannot be reproduced from its data |
| `dataset_item → inspection ON DELETE RESTRICT` | Retention deleting training evidence |
| `verdict_override.override_changes_verdict` + append-only | A no-op or silent rewrite of a human decision |
| `audit.*` no UPDATE/DELETE grant | A tamperable trail |
