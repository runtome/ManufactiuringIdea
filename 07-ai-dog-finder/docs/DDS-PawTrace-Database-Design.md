# Database Design Specification — PawTrace (AI Dog Finder 2.0)

| Field | Value |
|---|---|
| Document ID | DDS-07-PawTrace |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`db/schema.sql`](../db/schema.sql) (DDL, 1,141 lines) · [`db/seed_demo.sql`](../db/seed_demo.sql) (demo data + probes) |
| Related | [SRS-07](../SRS-PawTrace-AI-Dog-Finder.md) §5 · [SAD-07](SAD-PawTrace-Software-Architecture.md) ADR-T01…T10 · [API-07](../api/API-Specification.md) · [SEC-07](SEC-PawTrace-Security-Requirements.md) · [TEST-07](TEST-PawTrace-Test-Plan.md) TS-0 · patterns: [DDS-00](../../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md) §12.2 |

---

## 1. Introduction

### 1.1 Purpose
Specify the PawTrace database: what is stored, which rules are constraints rather than code, how vectors and geography are indexed for a ≤ 300 ms candidate search over a million embeddings, and how the demo dataset reproduces SRS acceptance criteria AC-02, AC-06 and AC-08 and the Appendix A fusion example.

### 1.2 What is different from the other databases in this repository
- **Own database, own extensions.** PawTrace is a separate deployment (SAD-00 §13). It needs **PostGIS** (the platform database does not) and **pgvector**. DDS-00 §12.2 sketches the tables and sets one rule that this design turns into a role: *public queries must read location through a fuzzing function, never the raw `geography` column*.
- **Privacy is a role, not a filter.** `public_ro` has column-level `SELECT` on `report` *without* `location`; the only location it can read is the geohash cell that `fuzz_cell()` returns through the views `report_public` and `v_map_cells` (DD-T01). The API's public endpoints use a connection pool bound to that role.
- **Vectors have versions.** Every embedding row carries `model_version_id`; one embedding version is `search_active`; each version has its own partial HNSW index; `search_candidates()` reads exactly one version (DD-T06). A model upgrade is a data migration with an atomic switch, not a schema change.
- **The score is a calibrated number.** `calibration_bin` maps fusion scores to empirical confirm rates; `match.calibrated_precision` is what the API shows (ADR-T04).
- **No LLM, no agent tables.** The only reused platform DDL is the helper functions (byte-identical) and the audit tables (identical modulo `core.app_user` → `pawtrace.app_user`), verified by TC-002.

### 1.3 Engine and extensions
PostgreSQL 16; `vector` ≥ 0.7 (`l2_normalize`, HNSW), `postgis` 3.4 (`geography`, `ST_DWithin`, `ST_GeoHash`), `pgcrypto`, `pg_trgm`. Image: `deploy/postgres/Dockerfile` (`postgis/postgis:16-3.4` + `postgresql-16-pgvector`). **Not executed on the authoring machine** (no Docker daemon); static checks and re-derived arithmetic stand in until TC-009 runs.

---

## 2. Design principles
| # | Principle | Mechanism |
|---|---|---|
| **DD-T01** | **Exact location is unreadable to the public.** | Column-level grant on `report` excluding `location`; `fuzz_cell(location, audience, region)` → geohash-5 (public, ≈ 4.9 km) / geohash-6 (subscriber, ≈ 1.2 km); `region.fuzz_public_precision` CHECK ≤ 5 so no configuration can make public cells finer; views expose cells only (C-01, AC-04, NFR-05) |
| **DD-T02** | **A match is born a candidate.** | `trg_match_status`: INSERT must be `candidate`; UPDATE to `confirmed`/`rejected` requires a matching `match_decision` row (C-03, FR-19) |
| **DD-T03** | **No EXIF, no unmoderated photo.** | `photo.exif_stripped` CHECK `= true` (a row with EXIF cannot exist); `trg_photo_gate` refuses `approved` unless `processing_state = done` (NSFW screen ran); `report_public` joins approved photos only (C-04, C-05) |
| **DD-T04** | **Decisions are append-only training signal.** | `trg_decision_immutable` refuses UPDATE/DELETE except inside a deletion cascade; each row carries `consent_version` (AI-07, ADR-T09) |
| **DD-T05** | **Report lifecycle is a state machine.** | `trg_report_status` allows active → matched/reunited/expired/closed, matched → active/reunited/closed, expired → active/closed only (FR-05) |
| **DD-T06** | **One vector space per query.** | `model_version` with `ux_model_version_active` (one `search_active` per kind); `trg_embedding_version` checks kind and dims; `trg_model_version_indexes` creates a partial HNSW per version; `trg_model_activate` refuses activation before the re-embed job completes; `search_candidates()` uses `active_embedding_version()` (AI-06, AC-08) |
| **DD-T07** | **Notification budget is enforced at insert.** | `trg_notification_budget`: over `region.notify_daily_cap` (default 5) the alert becomes a `digest` row; payloads with `lat`/`lng`/`location` keys are refused (FR-25, C-01) |
| **DD-T08** | **Deletion cascades in one statement.** | `trg_deletion_cascade` deletes the subject's reports (→ photos, instances, embeddings, attributes, text embeddings, matches, threads, messages), subscriptions, push subscriptions, notifications; anonymises the user or device; writes an identity-free tombstone to `audit.log`; bucket objects are removed by the scheduler and the request moves `db_done → completed` (NFR-06, AC-06) |
| **DD-T09** | **Anonymous posting is a device, not nothing.** | `report_has_poster` CHECK (user or device); `lost_needs_account`, `lost_needs_contact`; `trg_report_device` refuses banned devices; `exif_location_coarse` CHECK forces ≥ 1 km precision and consent for EXIF-derived locations (C-02, C-04, FR-28) |

---

## 3. Schema overview
36 tables (34 in `pawtrace`, 2 in `audit`), 9 views, 19 triggers, 26 functions (13 trigger functions, 11 business functions, 2 platform helpers), 33 explicit indexes + one partial HNSW pair per embedding version, 17 enums, 5 roles.

| Group | Tables |
|---|---|
| People & config | `app_user`, `device`, `region`, `setting`, `config_version` |
| Models | `model_version`, `benchmark_run`, `benchmark_slice`, `reembed_job`, `calibration_bin` |
| Reports | `contact_channel`, `report`, `photo`, `dog_instance`, `embedding`, `report_embedding`, `attributes`, `report_attr`, `text_embedding` |
| Matching | `match`, `match_decision`, `reunion`, `thread`, `message`, `duplicate_cluster` |
| Notifications | `subscription`, `push_subscription`, `notification` |
| Trust | `moderation_event`, `abuse_report`, `rate_limit_bucket` |
| Rights | `deletion_request`, `export_request` |
| Versioning | `schema_version` (`pawtrace_0001`) |
| Audit | `audit.log`, `audit.auth_event` (platform shape) |

### 3.1 ERD (core)
```
region ─┬─< report >── contact_channel          app_user ──< match_decision >── match
        │     │ location geography (exact)                        ▲              │ lost_report_id ─► report
        │     ├─< photo (exif_stripped = true)                    │              │ found_report_id ─► report
        │     │     └─< dog_instance ─< embedding (vec, version)  │              │ calibrated_precision, components_json
        │     │                       └─ attributes               │              ├─ thread ─< message
        │     ├─ report_embedding (vec, version)  ◄── search ─────┘              └─ reunion
        │     ├─ report_attr
        │     └─ text_embedding (1024-d, version)
        └─ fuzz_public_precision ≤ 5   →  report_public.cell · v_map_cells

model_version (search_active, one per kind) ─< embedding · report_embedding · text_embedding · calibration_bin · benchmark_run ─< benchmark_slice · reembed_job
device ─< report · push_subscription · notification · abuse_report        deletion_request ─(trigger)─► cascade + audit tombstone
```

---

## 4. Table specifications (the ones that carry rules)

### 4.1 `report`
SRS §5 columns plus: `event_at` (the SRS `lost_at`; time lost or time seen) with `event_at_source` user/exif/now (FR-04); `is_reloss` (FR-16); `location geography(Point,4326)` **exact**; `location_precision_m` and `location_source` gps/pin/address/exif_coarse (FR-03); `consent_coarse_location` (C-04); `region_id`; `search_radius_m`/`search_days` (owner-adjustable within `region` maxima, FR-14); `expires_at` (default +30 d), `closed_at`. CHECKs: poster present; lost requires account and contact channel; EXIF-derived location requires consent and ≥ 1 km precision; radius 500 m–50 km; days 1–30.

### 4.2 `photo`, `dog_instance`, `embedding`, `report_embedding`, `attributes`, `report_attr`, `text_embedding`
`photo`: `sha256` of the **stripped** bytes (idempotent upload, `UNIQUE (report_id, sha256)`), three derivative keys in private buckets, `exif_stripped` CHECK true, `capture_time_exif` (time only, never GPS), `moderation_status`, `processing_state` with `processing_error` codes (`NO_DOG`, `CROP_TOO_SMALL`, `LOW_QUALITY`, `NSFW`), `position` 1–10 (FR-01). `dog_instance`: bbox, crop key, `quality_score`, `short_edge_px ≥ 128` (AI-01), detector version. `embedding`: PK `(instance_id, model_version_id)`, `vector(768)`. `report_embedding`: the normalised mean per report and version, `medoid_instance` for display (FR-12). `attributes` per crop with `confidence_json`; `report_attr` is the aggregate the pre-filter reads, `user_declared` when the owner typed them. `text_embedding`: `vector(1024)` from attributes + description (AI-09).

### 4.3 `model_version`
`kind` detector/embedding/attributes/nsfw/text, `dims` (embedding = 768, text = 1024 by CHECK), `checksum`, `search_active`, `calibration_provisional`, benchmark recalls, activation/retirement stamps. Activation of an embedding version requires a benchmark (CHECK) and a completed `reembed_job` when another version is active (trigger). Inserting an embedding/text version creates its partial HNSW indexes (`hnsw_embedding_v<id>`, `hnsw_report_embedding_v<id>`, `hnsw_text_embedding_v<id>`; `m = 16`, `ef_construction = 128`).

### 4.4 `match`, `match_decision`, `reunion`, `thread`, `message`
`match`: `UNIQUE (lost, found, version)`, `score`, **`calibrated_precision`**, `components_json` with a CHECK that the seven keys of FR-18 are present (`cosine, sim_visual, attr_compat, spatial, temporal, distance_m, hours_after`), `rank`, `status`, `notified_at`, `decided_at/by`. `match_decision`: append-only, `consent_version`; `trg_decision_apply` moves the match to confirmed/rejected, the lost report to `matched` and opens the relay `thread` on confirm. `reunion` (`UNIQUE (lost_report_id)`): `trg_reunion_close` sets the lost report `reunited`, the found report `closed`, remaining candidates `superseded` (FR-20). `thread` holds the two **exact-location consent flags** (NFR-05); `message` bodies 1–2000 chars, hideable.

### 4.5 `region`, `setting`, `config_version`
`region`: fuzz precisions (public 3–5, subscriber 4–6, subscriber ≥ public), default/max radius and days (≤ 50 km, ≤ 30 d by CHECK — FR-14), `notify_threshold` (default 0.25), `notify_rank_max` (5), `notify_daily_cap` (5). `setting`: fusion weights (0.55/0.15/0.20/0.10), quality penalty, cosine calibration (0.35–0.95), duplicate rule, signed-URL TTLs, deletion SLA. `config_version`: validated copies of `deploy/pawtrace.yaml` loads.

### 4.6 `calibration_bin`, `benchmark_run`, `benchmark_slice`, `reembed_job`
Calibration: per embedding version, score bins → `n`, `confirmed`, `precision` (AI-04). Benchmark: per version, filtered protocol flag, recall@1/@10 (AI-03); slices per colour and size with `gap_pct` (AI-08; `v_bias_report.rebalance_required = gap_pct > 15`). `reembed_job`: `total`, `done`, state; the activation trigger reads it.

### 4.7 Trust and rights
`device`: hashed token, `trust_score`, `captcha_required`, ban. `moderation_event` (auto-audited by `trg_moderation_audit`), `abuse_report`, `duplicate_cluster` (FR-29 candidates for a moderator to merge), `rate_limit_bucket` (forensic mirror of Redis). `deletion_request` (state requested → db_done → completed; `due_at` = +72 h; `summary_json`), `export_request`.

---

## 5. Functions
| Function | Role |
|---|---|
| `fuzz_cell(loc, audience, region)` | The only public location form. `public` → geohash ≤ 5, `subscriber` → ≤ 6, `owner`/`counterpart` → NULL (exact allowed through the consented path) |
| `cell_center(cell)` | Centre point of a cell for map rendering |
| `spatial_score(d_m)` | `exp(−d / 3000)` (Appendix A) |
| `temporal_score(lost_at, seen_at, is_reloss, window_days)` | 1.0 for 0–24 h after the loss; linear to 0.3 at the window end; before the loss 0.1 (0.6 if re-loss) (FR-16) |
| `attr_compat(a, b)` | 0–1 agreement over size (adjacent class 0.6), colour (secondary 0.6), coat length, breed group (mixed compatible); unknowns neutral; `< 0.4` is the hard pre-filter |
| `sim_visual(cosine)` | Linear rescale between `setting.fusion.cosine_calibration` low/high (the "calibrated cosine") |
| `fusion_score(sim, attr, spatial, temporal, min_quality)` | Weighted sum from `setting.fusion.weights` minus the quality penalty; clamped 0–1 |
| `calibrated_precision(score, version)` | Bin lookup; falls back to the active version's curve while provisional |
| `active_embedding_version()` | The one `search_active` embedding version |
| `search_candidates(lost, radius_m, days, limit)` | FR-14/FR-15 retrieval: active/found/sighting ∩ `ST_DWithin` ∩ time window (1 h grace before the loss) ∩ `attr_compat ≥ 0.4`, ordered by cosine distance within the active version, radius/days clamped to the region maxima; returns raw components |
| `can_notify(user, device)` | Today's push/email/sms count < the smallest cap among the subject's active reports' regions |

---

## 6. Views
| View | Reader | Content |
|---|---|---|
| `report_public` | `public_ro` | id, kind, status, title, **cell**, `event_hour`, region, coarse attributes, approved photo count, cover photo id, created day. Only reports with ≥ 1 approved photo (C-05). No coordinates, no poster |
| `v_map_cells` | `public_ro` | cell × kind: count, last event hour, colours present, cell centre (FR-24) |
| `v_candidates` | owner (via API) | match components, **distance band** (not metres) and the found report's subscriber-precision cell until consent, side-by-side photo ids (FR-18) |
| `v_moderation_queue` | moderators | pending photos, open abuse reports, open duplicate clusters, prioritised |
| `v_bias_report` | admin, analytics | latest benchmark slices per version with `rebalance_required` (AI-08) |
| `v_notify_budget` | admin | per user: sent today, digested today, `can_notify` |
| `v_deletion_status` | admin | requests with `sla_breached` |
| `v_vision_backlog` | ops | queued/processing counts, oldest queued age (AC-07, `/readyz`) |
| `v_model_status` | admin | versions with embedding counts and re-embed % |

---

## 7. Indexes, sizing, retention (NFR-02, NFR-03)
- **Geo**: GIST on `report.location` and `subscription.area`. **Time**: BRIN on `report.event_at`, `created_at`, `match.created_at`, `match_decision.created_at`. **Vectors**: partial HNSW per version (cosine ops) on `embedding`, `report_embedding`, `text_embedding`. **Work queues**: partial indexes on pending photos, pending moderation, unsent notifications, open abuse, open deletions. **Text**: trigram GIN on `description`.
- **Query shape** (ADR-T03): the planner applies GIST + BRIN + attribute predicates first (a 5 km / 3 day window in a dense city yields ~10²–10³ rows), then orders by `<=>` — an exact scan on the filtered set or the partial HNSW when the set is large (50 km radius). `hnsw.ef_search` is raised to 100 for the 50 km case (TC-092).
- **Sizing at NFR-03** (1 M photos, ≈ 1.2 M crops, 100 k active reports): `embedding` 1.2 M × (768 × 4 B + overhead) ≈ 4 GB + HNSW ≈ 4–6 GB per version; two versions during a migration ≈ 20 GB; `report_embedding` 0.4 GB; `photo` + `dog_instance` < 1 GB; `report` with geography ≈ 0.2 GB. Plan 64 GB storage for the database and 2 TB for image derivatives (≈ 1.5 MB per photo across tiers).
- **Retention** (SRS §10, §5 SAD): closed/reunited/expired reports keep thumbnails only after 90 days and are deleted after 365 days (photos, crops, embeddings) unless the owner keeps a public reunion story; sightings without a match expire at 30 days (`expires_at`) and follow the same tiers; `match_decision` and `calibration_bin` are kept (anonymised) as training/calibration history; `audit.log` 3 years; `rate_limit_bucket` 30 days.

---

## 8. Roles and grants
| Role | Grants | Used by |
|---|---|---|
| `app_rw` | DML on `pawtrace`; INSERT/SELECT on `audit` | API (authenticated paths) |
| **`public_ro`** | `SELECT (id, kind, status, title, event_at, region_id, created_at)` on `report` — **no `location`**; `SELECT` on `report_public`, `v_map_cells`, `region`, photo metadata columns; EXECUTE `fuzz_cell`, `cell_center`; explicitly no access to users, devices, channels, threads, messages, matches, decisions, subscriptions, notifications, vectors | API (public paths: map, browse, search results) |
| `worker_rw` | SELECT everywhere; INSERT/UPDATE on pipeline tables (instances, vectors, attributes, matches, notifications, duplicates, calibration, jobs, benchmarks, rate buckets, moderation events); column-level UPDATE on `photo` processing/moderation, `report` status, deletion/export state | vision, match, scheduler workers |
| `app_ro` | SELECT everywhere incl. audit | support, reporting |
| `analytics_ro` | matches, decisions, calibration, benchmarks, bias/model views, public views — no identities, no locations, no messages | analysis, BI |

Views run with the owner's privileges, which is what lets `public_ro` read a cell computed from a column it cannot select (ADR-T06). `ALTER DEFAULT PRIVILEGES` keeps future tables in the same posture.

---

## 9. Demo and test dataset (`db/seed_demo.sql`)
Deterministic (`setseed(0.07)`; UUIDv7 ids are time-based). 10,000 distractor sightings across four Thai regions with random 768-d unit vectors generated in SQL, 20 planted lost/found pairs whose vectors are constructed with an **exact cosine** `c_i` (`found = c·b + √(1−c²)·u`, `u ⟂ b`), and every acceptance-criterion row. **Matching is run by the seed through the real functions** (`search_candidates` → `sim_visual` → `fusion_score` → `calibrated_precision`), so the match rows are not hand-typed.

Expected values (re-derived in Python; TC-005) — the seed prints them with `\echo` at the end:

| Item | Expected |
|---|---|
| Reports | 10,041 created (10,000 + 20 lost + 20 found + 1) → **10,040** after the deletion; photos / instances / v1 embeddings 10,040; v2 embeddings 6,225 (62.0 % of 10,041); text embeddings 40 |
| **AC-02** | Every planted pair's found report in its lost report's top 10 — expected **20/20** (≥ 16 required). NumPy simulation of the same construction: max distractor cosine ≈ 0.16 (theory √(2 ln 10⁴ / 768) ≈ 0.155) vs pair cosines 0.78–0.90 → rank 1 by cosine 20/20; even with the best possible non-visual components a distractor's fused score (≤ 0.45) stays below a pair's worst case (≥ 0.65) |
| **Appendix A** (pair #1) | lost 2026-09-08 20:30+07, seen 2026-09-10 07:15+07; Δλ = 0.019425° at 13.7563° N → **2,100.8 m** (WGS84 geodesic) → spatial `exp(−2100.8/3000)` = **0.4965**; 34.75 h → temporal **0.8432**; cosine 0.830 → sim_visual **0.80**; attr 1.0; quality min 0.77 (no penalty) → score 0.55·0.80 + 0.15 + 0.20·0.4965 + 0.10·0.8432 = **0.7736** → bin 0.7–0.8 → **calibrated precision 0.680** → rank 1 → notified |
| Distractors never notify | best possible distractor score 0.45 → calibrated 0.208 < 0.25 |
| Decisions | 14 confirms (pairs #2–#15) + up to 12 rejects (rank-2 candidates of pairs #2–#13, where a distractor qualified) |
| Reunions / lifecycle | 3 reunions (pairs #2–#4): lost reports reunited 3, matched 11, found reports closed 3; threads 14; messages 4; pair #2 thread both consents true |
| **FR-25** | Nok (u1, owner of pairs 1, 7, 13, 19): 4 candidate + 3 area alerts = 7 → **5 push + 2 digest**; `can_notify` false |
| **C-01** | `report_public.cell` for the Appendix A sighting is a 5-character geohash; `v_map_cells` rows carry cell centres only |
| **AI-08** | v1 slices: black recall@10 0.69, `gap_pct` 16.87 → `rebalance_required` |
| **AC-06** | u7's deletion: `db_done`, summary `{reports 1, photos 1, embeddings 1}`, u7 anonymised, one `audit.log` tombstone with `actor = deletion_request` |
| **AC-08** | active embedding version = v1 (id 2), `n_active` 1, v2 re-embed 62.0 % |
| Moderation | 4 events (2 hide, 1 nsfw_auto_hide, 1 ban_device), 3 abuse reports (1 resolved), 1 duplicate cluster; `audit.log` ≥ 5 |
| Probes | 8, each fails in its savepoint: match inserted as confirmed; confirmed without decision; decision edited; approve unprocessed photo; photo with EXIF; activate v2 before re-embed completes; notification payload with `lat`; banned device posts |

Run: `psql -v ON_ERROR_STOP=1 -f db/schema.sql -f db/seed_demo.sql` (~20 s for the vectors). **Pending**: PostgreSQL + PostGIS + pgvector execution (no Docker daemon here) — README-07.

---

## 10. Traceability
| SRS-07 | Objects |
|---|---|
| C-01, AC-04, NFR-05 | DD-T01, `fuzz_cell`, `region.fuzz_*`, `report_public`, `v_map_cells`, `thread.*_consent_exact`, `trg_notification_budget` (payload check) |
| C-02, FR-02, FR-28 | DD-T09, `device`, `trg_report_device`, `rate_limit_bucket` |
| C-03, FR-19, FR-20 | DD-T02, `match`, `match_decision`, `trg_decision_apply`, `reunion`, `trg_reunion_close` |
| C-04, FR-04, AC-05 | DD-T03, `photo.exif_stripped` CHECK, `capture_time_exif`, `exif_location_coarse` |
| C-05, FR-26, FR-27 | `trg_photo_gate`, `moderation_event`, `abuse_report`, `v_moderation_queue` |
| FR-01, FR-03, FR-05, FR-06, FR-07 | `report`, `photo.position`, DD-T05, `contact_channel`, `thread`, `message` |
| FR-08…FR-13 | `dog_instance`, `embedding`, `report_embedding`, `attributes`, `text_embedding`, DD-T06 |
| FR-14…FR-18, FR-21 | `search_candidates`, `spatial_score`, `temporal_score`, `attr_compat`, `fusion_score`, `match.components_json`, `text_embedding` |
| FR-22…FR-25 | `notification`, DD-T07, `subscription`, `push_subscription`, `v_map_cells` |
| FR-29 | `duplicate_cluster` |
| AI-03, AI-04, AI-06, AI-07, AI-08 | `benchmark_run/slice`, `calibration_bin`, `model_version`, `reembed_job`, `match_decision.consent_version`, `v_bias_report` |
| NFR-02, NFR-03 | §7 |
| NFR-06, AC-06 | DD-T08, `deletion_request`, `export_request`, `v_deletion_status` |
| NFR-08, AC-07 | `photo.processing_state`, `v_vision_backlog` |

## Appendix A — The constraints that carry the weight
```
report.location                 exact; no grant to public_ro                       C-01
region.fuzz_public_precision    CHECK BETWEEN 3 AND 5                              C-01 (never finer than ~4.9 km publicly)
photo.exif_stripped             CHECK (exif_stripped)                              C-04
trg_photo_gate                  approved ⇒ stripped ∧ processed                    C-05
trg_match_status                INSERT ⇒ candidate; confirmed/rejected ⇒ decision  C-03, FR-19
trg_decision_immutable          no UPDATE/DELETE (except deletion cascade)         AI-07
ux_model_version_active         one search_active per kind                         AC-08
trg_model_activate              activation ⇒ re-embed completed                    AC-08
trg_embedding_version           kind and dims match the version                    AI-06
trg_notification_budget         cap ⇒ digest; payload has no coordinates           FR-25, C-01
trg_deletion_cascade            reports → photos → instances → vectors; tombstone  NFR-06, AC-06
report CHECKs                   poster present; lost ⇒ account + contact; radius ≤ 50 km; days ≤ 30   C-02, FR-07, FR-14
```
