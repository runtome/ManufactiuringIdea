# Test Plan & Test Cases — PawTrace (AI Dog Finder 2.0)

| Field | Value |
|---|---|
| Document ID | TEST-07-PawTrace |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-07](../SRS-PawTrace-AI-Dog-Finder.md) §8 · [SAD-07](SAD-PawTrace-Software-Architecture.md) · [DDS-07](DDS-PawTrace-Database-Design.md) · [API-07](../api/API-Specification.md) · [ICD-07](ICD-PawTrace-Interface-Control.md) · [SEC-07](SEC-PawTrace-Security-Requirements.md) · [OPS-07](OPS-PawTrace-Deployment-Operations.md) |

---

## 1. Strategy

### 1.1 What is different about testing a lost-pet retrieval system
- **The privacy properties are tested against the API, not the UI.** AC-04 is 10,000 randomised public queries whose responses are scanned for anything finer than the configured cell. The strongest test is structural: the public database role cannot read a coordinate (TC-003), so a leaking handler fails instead of leaking (TC-060).
- **Retrieval quality has two corpora.** A held-out re-ID benchmark under the filtered protocol (AC-01, AI-03 — dataset availability is a README gap) and the **seeded scenario** of AC-02, which the demo seed reproduces with 20 planted pairs among 10,000 distractors run through the real `search_candidates()` → fusion → calibration chain (TC-041).
- **The numbers are re-derived.** The Appendix A fusion example (spatial, temporal, sim, score, calibrated precision) is recomputed in Python; the planted-pair construction is simulated in NumPy (TC-005).
- **Abuse is a first-class corpus**: flood, duplicate photos across devices, fake sightings, luring patterns (TS-5).
- **Static artefacts run now** (TS-0): DDL checks and grants, platform-pattern identity, OpenAPI, config schema with negatives, compose/env, secret scan, seed arithmetic. PostgreSQL + PostGIS + pgvector could not be executed on the authoring machine (TC-009 pending).

### 1.2 Levels
| Level | Scope | Runs |
|---|---|---|
| L0 Static | DDL, seed arithmetic, OpenAPI, config schema, compose | every commit |
| L1 Unit | upload gate (EXIF), fusion/temporal/attr functions (SQL + Python reference), budget logic, rate-limit buckets, trust score | every commit |
| L2 Integration (compose) | API + workers (CPU profile) + PostgreSQL/PostGIS/pgvector + MinIO + Redis + mailpit; seed loaded | nightly |
| L3 Corpora | re-ID benchmark, AC-02 seeded scenario at 10 k and 1 M, EXIF corpus, abuse corpus | release |
| L4 Field | usability timing on real phones (AC-03), pen test (SEC-07 §6), single-region pilot | launch |

### 1.3 Exit for release
All Must FR TCs green; AC-01…AC-08 green (TC-051, TC-041, TC-010, TC-060, TC-014, TC-120, TC-093, TC-110); no coordinate finer than the cell in any public response; pen-test goal (SEC-07 §6) not achieved by the tester; NFR-01/02/04 measured; residual risks (SEC-07 §8) acknowledged.

---

## 2. Test suites and cases

Notation: **[X]** executed on the authoring machine · **[ ]** specified, not run · Pri M/S.

### TS-0 — Static and executable artefacts (L0)
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-001 | OpenAPI valid | validator; unique operationIds; every op has a 2xx; refs resolve; no orphans; null-valued-key scan (unquoted `{`/`,`/`:` in flow mappings) | Pass | M | [X] 47 paths / 54 ops / 48 schemas; 0 orphans; 0 null keys |
| TC-002 | Platform pattern identity | Diff `uuid_generate_v7` + `set_updated_at` against `00/db/schema.sql` lines 63–104; diff `audit.log`/`audit.auth_event` modulo `core.app_user → pawtrace.app_user` | Byte-identical / identical modulo substitution | M | [X] both true |
| TC-003 | DDL static checks, guards, grants, probes | Paren/`$$` balance; FK targets defined and ordered; every table has a PK; the 15 guard triggers present; `public_ro` grants contain no `location` and none of users/devices/threads/messages/matches/vectors; the 8 probes in `seed_demo.sql` §14 each fail | Pass | M | [X] static part: 36 tables / 9 views / 19 triggers / 26 functions / 33 indexes / 17 enums; 15/15 guards; `public_ro` report grant = `(id, kind, status, title, event_at, region_id, created_at)` · [ ] probes need PostgreSQL |
| TC-004 | Compose, env, buckets | Parse; profiles `gpu`/`cpu`/`dev`; every `${VAR}` in `.env.example` both ways; hardening on app services; ports on `BIND_ADDR`; egress network only for api/scheduler/worker-match; MinIO buckets private (no anonymous policy); no `originals` bucket | Pass | M | [X] see README-07 |
| TC-005 | Seed arithmetic and simulation | Re-derive in Python: WGS84 geodesic for Δλ = 0.019425° at 13.7563° N; `exp(−d/3000)`; temporal at 34.75 h; `sim_visual(0.83)`; fusion; bin lookup; tallies (10,040 reports, 6,225 v2 vectors, 7 → 5 + 2 notifications, 14/12 decisions, 16.87 % gap). NumPy: 20 pairs with exact cosine among 10,000 random 768-d unit vectors | Values equal the seed header; pairs rank 1 | M | [X] distance 2,100.8 m; spatial 0.4965; temporal 0.8432; sim 0.80; score 0.7736; precision 0.680; 20/20 rank 1 by cosine and by worst-case fused score; max distractor cosine 0.162 |
| TC-006 | Config schema and negatives | `deploy/pawtrace.example.yaml` vs `schemas/pawtrace-config.schema.json`; negatives: weights ≠ 1 (loader rule), public fuzz precision 6, radius max 60 km, days max 45, notify threshold 1.5, daily cap 0, rate-limit posts 0, subscriber precision < public, exact-location audience `public`, CAPTCHA threshold > 1, retention delete < thumb-only | Example valid; every negative rejected | M | [X] see README-07 |
| TC-007 | No secrets in examples | Scan `.env.example`, config, compose, seed, schema for keys/tokens/passwords | None | M | [X] |
| TC-008 | `Problem` identity vs API-00 | Diff the schema block | Byte-identical | M | [X] true |
| TC-009 | Schema and seed execute on PostgreSQL 16 + PostGIS + pgvector | `psql -v ON_ERROR_STOP=1 -f schema.sql -f seed_demo.sql`; `\echo` block equals the header; 8 probes fail | Zero errors; values match | M | [ ] no Docker daemon on the authoring machine |

### TS-1 — Reporting and upload (L2/L4) — FR-01…FR-07, C-02, C-04, AC-03, AC-05
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-010 | **Anonymous sighting in 60 s (AC-03)** | 10 testers, mid-range and low-end Android, 4G: open PWA → "I saw a dog" → one photo → GPS → post; stopwatch from tap to 202 | Median ≤ 45 s, p90 ≤ 60 s; no account, no CAPTCHA | M | [ ] |
| TC-011 | Lost report needs an account and a contact channel | `POST /reports` kind lost with a device token only | 401; with a session → 201 with `contact_channel` | M | [ ] |
| TC-012 | Location sources (FR-03) | GPS, map pin, address search via `/geocode` | `location.source` recorded with `precision_m`; geocoder down → GPS/pin still work | M | [ ] |
| TC-013 | EXIF time prefill (FR-04) | Upload with `DateTimeOriginal` | `event_at` prefilled, `event_at_source = exif`, editable | S | [ ] |
| TC-014 | **EXIF stripped (AC-05)** | Corpus of 200 images with GPS EXIF, XMP, IPTC, thumbnails-in-EXIF, HEIC; upload; download every derivative and crop via signed URL; run `exiftool` | Zero metadata tags in every served object; no originals key in any bucket; with `consent_coarse_location` → report location rounded to ≥ 1 km, `source = exif_coarse` | M | [ ] |
| TC-015 | Photo limits and idempotency | 11th photo; 13 MB file; same bytes twice | 422 TOO_MANY_PHOTOS; 413; second upload returns 200 with the same photo id | M | [ ] |
| TC-016 | Lifecycle (FR-05) | active → matched (decision) → reunited; expired → active; closed → active | Allowed transitions succeed; others 409 REPORT_TRANSITION | M | [ ] |
| TC-017 | Adding photos later (FR-06) | Add 2 photos to an active lost report | Report aggregate vector recomputed (n_instances 3); matching re-run; ranks may change | S | [ ] |
| TC-018 | Contact relay (FR-07) | Confirm a candidate; both sides message | Neither side's email/phone appears anywhere in responses or mails; `sender` is `lost_side`/`found_side` | M | [ ] |

### TS-2 — Vision pipeline (L1/L2) — FR-08…FR-13, AI-01, AI-02, IF-42
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-020 | Detector dog-only and min crop (AI-01) | Photos with a cat, a dog at 90 px short edge, two dogs | Cat → NO_DOG; small → CROP_TOO_SMALL; two → 2 instances | M | [ ] |
| TC-021 | Rejection feedback (FR-09) | Blurry photo | `processing_error = LOW_QUALITY`; PWA shows the reason | M | [ ] |
| TC-022 | Embedding contract (AI-02) | 100 crops | 768-d, ‖v‖ = 1 ± 1e-3, `model_version_id` = active; `trg_embedding_version` refuses 1024-d or a text version | M | [ ] |
| TC-023 | Attributes (FR-11) | Labelled set of 200 crops | Size/colour accuracy reported; low-confidence fields NULL | S | [ ] |
| TC-024 | Aggregate vector (FR-12) | Report with 3 photos | `report_embedding.vec` = normalised mean; medoid = closest crop | M | [ ] |
| TC-025 | Idempotent re-run (FR-13) | Process the same photo twice; re-run for v2 | No duplicate rows; `(instance, version)` PK; v1 rows untouched | M | [ ] |
| TC-026 | NSFW thresholds (FR-26) | Scores 0.95 / 0.75 / 0.2 | hidden + `nsfw_auto_hide`; pending for moderator; approved | M | [ ] |

### TS-3 — Matching (L1/L2/L3) — FR-14…FR-21, AI-03…AI-05, AI-09, AC-01, AC-02
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-040 | Radius/time filter and clamps (FR-14) | Sightings at 4.9 km / 5.1 km; 3 d / 3 d + 1 h; owner sets 60 km / 45 d | Inside only; values clamped to 50 km / 30 d by `search_candidates` | M | [ ] |
| TC-041 | **Seeded scenario (AC-02)** | Load the seed; read the `\echo` AC-02 block; then repeat with 100 k distractors | ≥ 16 of 20 pairs in the top 10 (seed expects 20/20); at 100 k still ≥ 16 | M | [ ] (arithmetic and simulation: TC-005) |
| TC-042 | Fusion components (FR-15, FR-18) | Appendix A pair | `components_json` has cosine, sim_visual, attr_compat, spatial, temporal, distance_m, hours_after; values within TC-005 tolerances; SQL `fusion_score` equals the Python reference on 1,000 random inputs | M | [ ] |
| TC-043 | Temporal ordering (FR-16) | Sighting 3 h before the loss; same with `is_reloss` | temporal 0.1 vs 0.6; candidate still listed but ranked accordingly | S | [ ] |
| TC-044 | Auto-run and schedule (FR-17) | New sighting near an active lost report; wait for the scheduled re-run | Candidate appears without user action; re-run recomputes ranks for active reports only | M | [ ] |
| TC-045 | Calibration (AI-04) | 500 synthetic decisions; refresh | Bins monotone; `calibrated_precision` for a score equals confirmed/n of its bin; a new version starts provisional with the previous curve | M | [ ] |
| TC-046 | Honest display | Candidate with cosine 0.92, 40 km, 20 days (radius/days widened by the owner) | Score shows spatial/temporal near 0; calibrated value moderate; UI wording "possible sighting"; raw cosine only in details | M | [ ] |
| TC-047 | Decisions stored (FR-19, AI-07) | Confirm; reject; try to decide twice; try to update a decision | Rows with `consent_version`; 409 ALREADY_DECIDED; DECISION_IMMUTABLE | M | [ ] |
| TC-048 | Reunion (FR-20) | `POST /matches/{id}/reunion` on a confirmed candidate | Lost report `reunited`, found `closed`, other candidates `superseded`; on an unconfirmed candidate → 409 NOT_CONFIRMED | M | [ ] |
| TC-049 | Semantic search (FR-21, AI-09) | `q = "หมาสีน้ำตาลขนสั้น อกขาว"` and the English equivalent | Same top results; attribute filters applied; TH/EN parity ≥ 0.9 overlap@10 | S | [ ] |
| TC-050 | Notify rule (AI-05) | Candidates at calibrated 0.24 rank 1; 0.30 rank 6; 0.30 rank 3 | Only the third notifies | M | [ ] |
| TC-051 | **Benchmark (AC-01, AI-03)** | Held-out re-ID set under the filtered protocol | Recall@10 ≥ 0.80, Recall@1 ≥ 0.45; `benchmark_run` recorded | M | [ ] dataset pending (README-07) |
| TC-052 | Relay thread | Messages both ways; moderator hides one | Delivered with budget; hidden message invisible to parties; audit row | M | [ ] |

### TS-4 — Notifications and map (L2) — FR-22…FR-25, C-01, AC-04
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-060 | **Public map never finer than the cell (AC-04)** | 10,000 randomised `/map/cells`, `/search`, `GET /reports/{id}` (non-owner) calls; scan every response for numbers resembling coordinates, `location`, `distance_m` | Only `Cell` objects with ≤ 5-char geohash; a deliberately broken handler that selects `location` fails with a permission error (role test) | M | [ ] |
| TC-061 | Public timestamps | Inspect `ReportPublic` | `event_hour` truncated to the hour; `created_day` to the day | M | [ ] |
| TC-062 | Map filters | kind/colour/days filters | Counts consistent with `v_map_cells` | S | [ ] |
| TC-063 | Push delivery (FR-22, IF-40) | Candidate above threshold; Web Push and FCM | Received ≤ 60 s; payload has a cell only; 410 endpoint revoked | M | [ ] |
| TC-064 | Budget and digest (FR-25) | 7 alerts for one user in a day (seed: Nok) | 5 push + 2 digest rows; digest mail at 18:00; `can_notify` false | M | [ ] |
| TC-070 | Area subscriptions (FR-23, SEC-T05) | Polygon 0.5 km²; 25,000 km²; 6th subscription; new sighting inside | 422 ×2; 422; alert with geohash-6 cell only | S | [ ] |

### TS-5 — Moderation and abuse (L2/L3) — FR-26…FR-29, C-05, IF-41
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-100 | NSFW auto-hide and queue | Upload NSFW test image | Hidden before any non-owner can see it; `nsfw_auto_hide` event; not in `report_public` | M | [ ] |
| TC-101 | Moderation actions audited (FR-27) | hide / remove / restore / ban with and without reason | Reason required; `moderation_event` + `audit.log` rows; restore works except NSFW remove | M | [ ] |
| TC-102 | Rate limits (FR-28) | 6 posts in an hour from one device; 21 from one IP; 200 `/map/cells` per minute | 429 with `Retry-After`; counters mirrored to `rate_limit_bucket` | M | [ ] |
| TC-103 | CAPTCHA escalation and ban | Drive trust score to 0.25 then 0.05 | 428 + challenge; solve → post allowed; 0.05 → banned; DB refuses the post (DEVICE_BANNED) | M | [ ] |
| TC-104 | Duplicate photo across devices | Same sha256 from 3 devices in 24 h | All three challenged; moderation item; cluster for a moderator | M | [ ] |
| TC-105 | CAPTCHA provider down | Block siteverify | Challenged devices refused (fail closed); unchallenged devices post normally | S | [ ] |
| TC-106 | Duplicate clusters (FR-29) | Two sightings 180 m and 24 min apart with cosine 0.96 | Cluster created; merge keeps the primary, redirects the member; dismiss records it | S | [ ] |
| TC-107 | Abuse report flow | Anonymous reports a fake sighting | Queue item; resolution recorded; reporter never identified to the poster | M | [ ] |

### TS-6 — Privacy and rights (L2) — NFR-05, NFR-06, NFR-07, AC-06, SEC-07 §5.1–5.3
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-120 | **Deletion (AC-06)** | User with 3 reports, 7 photos, 9 crops, 9 v1 + 5 v2 embeddings, 2 text embeddings, 3 decisions, 1 subscription requests deletion | Immediately: all rows gone, account anonymised, `db_done`, summary counts; `/reports/{id}` → 410 | M | [ ] |
| TC-121 | Object sweep SLA | Same; inspect buckets | All derivative/crop keys removed ≤ 72 h; `completed`; `sla_breached` false; a stalled sweep alerts (RB-09) | M | [ ] |
| TC-122 | Export | `POST /me/export` | Zip with reports (exact own locations), photos, decisions, messages; URL expires in 24 h | S | [ ] |
| TC-123 | Consent versions in training export | Decisions under two consent versions, one without training permission | Export contains only permitted decisions | M | [ ] |
| TC-124 | **Exact location by mutual consent (NFR-05)** | Confirmed candidate; one side consents; then both | Before both: `exact_locations_shared = false`, no coordinates in `Thread`; after: both `Location`s present; revoking one hides them again | M | [ ] |
| TC-125 | Non-owner report view | `GET /reports/{id}` as another user, a device, anonymous | `ReportPublic` (cell, hour); no 403 that reveals ownership | M | [ ] |
| TC-126 | No phone, masked email | Schema scan; `GET /me`; other users' profiles | No phone column; `email_masked` only; no endpoint returns another user's email | M | [ ] |
| TC-127 | Email relay rewrite (IF-13) | Enable relay; message | Sender shown as `thread-<id>@relay.<domain>`; reply routed to the thread | S | [ ] |
| TC-128 | Moderator thread access | Moderator opens a thread without / with an abuse report on it | 403 THREAD_NOT_PARTY / allowed with audit row | M | [ ] |

### TS-7 — Model lifecycle (L2/L3) — AI-06, AI-08, AC-08
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-110 | **Model upgrade without mixing spaces (AC-08)** | Register v2; run matching continuously while the re-embed runs; try to activate at 62 %; activate at 100 % | Every query during the job reads v1 only (`match.model_version_id`); activation at 62 % → 409 REEMBED_INCOMPLETE; at 100 % one transaction flips; zero queries with mixed versions; no downtime | M | [ ] |
| TC-111 | Checksum verification (SEC-T53) | Replace the v1 artefact bytes | Worker refuses to load; alert; no embeddings produced | M | [ ] |
| TC-112 | Benchmark gate | Activate a version without `benchmark_recall10` | 409 BENCHMARK_MISSING (CHECK `active_has_benchmark`) | M | [ ] |
| TC-113 | Bias report (AI-08) | Benchmark with a 20 % gap for black dogs | `v_bias_report.rebalance_required = true`; rebalancing task created; report per colour and size | S | [ ] |

### TS-8 — Performance and availability (L2/L3) — NFR-01…NFR-04, NFR-08, AC-07
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-090 | Upload → candidates (NFR-01) | 3 photos on 4G, GPU profile; CPU profile | p95 ≤ 15 s (GPU); CPU profile measured and documented | M | [ ] |
| TC-091 | Mobile web (NFR-04) | Lighthouse on a low-end Android over 4G | FCP ≤ 2 s; the sighting flow completes | M | [ ] |
| TC-092 | ANN at 1 M (NFR-02) | 1 M embeddings; 5 km/3 d and 50 km/30 d queries in Bangkok density | p95 ≤ 300 ms; plan uses GIST + BRIN pre-filter then HNSW; `ef_search` 100 for the 50 km case | M | [ ] |
| TC-093 | **GPU worker down (AC-07)** | Stop `worker-vision` 6 h while 500 photos are uploaded | All accepted (202); `/readyz` 200 with `vision_backlog`; after restart FIFO processing; 0 lost; matching catches up | M | [ ] |
| TC-094 | Scale (NFR-03) | 100 k active reports, 1 M photos | Search, map and matching within NFR-01/02; storage per DDS-07 §7 | S | [ ] |
| TC-095 | Availability (NFR-08) | 30-day pilot | ≥ 99.5 % on the reporting path | S | [ ] |

### TS-9 — Security (L2/L4) — SEC-07
| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-130 | Magic link (SEC-T13) | Reuse a link; use after 11 min; use from another UA family | 401 each; `auth_event` rows | M | [ ] |
| TC-131 | Device token hashed (SEC-T14) | Inspect `device.token_hash`; replay a rotated token | sha256 only; old token 401 after ban/rotation | M | [ ] |
| TC-132 | Signed URLs (SEC-T22) | Mint for a pending photo as non-owner; use a thumb URL after 16 min | 403 / 403 (expired) | M | [ ] |
| TC-133 | TLS, CSP, storage (SEC-T62) | Scan headers; inspect PWA storage | HSTS; CSP without `unsafe-inline`; session not in `localStorage` | M | [ ] |
| TC-134 | Push payload scan (SEC-T04) | Instrumented push endpoint over 1,000 notifications | No `lat`/`lng`; DB refuses injected ones (probe 7) | M | [ ] |
| TC-135 | Pen test goal (SEC-07 §6) | External tester with the SEC-07 §4.2 scenario | No coordinate finer than the cell obtained for any report not owned | M | [ ] |

---

## 3. Traceability
| SRS-07 | TCs |
|---|---|
| FR-01 | TC-011, TC-015 |
| FR-02 | TC-010 |
| FR-03 | TC-012 |
| FR-04 | TC-013 |
| FR-05 | TC-016 |
| FR-06 | TC-017 |
| FR-07 | TC-018, TC-052, TC-126, TC-127 |
| FR-08, FR-09 | TC-020, TC-021 |
| FR-10 | TC-022, TC-092 |
| FR-11 | TC-023 |
| FR-12 | TC-024 |
| FR-13 | TC-025 |
| FR-14 | TC-040 |
| FR-15 | TC-042 |
| FR-16 | TC-043 |
| FR-17 | TC-044 |
| FR-18 | TC-042, TC-046 |
| FR-19 | TC-047 |
| FR-20 | TC-048 |
| FR-21 | TC-049 |
| FR-22 | TC-063 |
| FR-23 | TC-070 |
| FR-24 | TC-060, TC-062 |
| FR-25 | TC-064 |
| FR-26 | TC-026, TC-100 |
| FR-27 | TC-101, TC-107 |
| FR-28 | TC-102, TC-103, TC-104, TC-105 |
| FR-29 | TC-106 |
| AI-01, AI-02 | TC-020, TC-022 |
| AI-03 | TC-051 |
| AI-04 | TC-045 |
| AI-05 | TC-050 |
| AI-06 | TC-025, TC-110 |
| AI-07 | TC-047, TC-123 |
| AI-08 | TC-113 |
| AI-09 | TC-049 |
| NFR-01 | TC-090 |
| NFR-02 | TC-092 |
| NFR-03 | TC-094 |
| NFR-04 | TC-091 |
| NFR-05 | TC-124 |
| NFR-06 | TC-120, TC-121, TC-122 |
| NFR-07 | TC-132, TC-004 |
| NFR-08 | TC-093, TC-095 |
| NFR-09 | TC-049, TC-010 (TH UI) |
| C-01 | TC-003, TC-060, TC-061, TC-134 |
| C-02 | TC-010, TC-011 |
| C-03 | TC-003 (probes 1–2), TC-046, TC-047 |
| C-04 | TC-003 (probe 5), TC-014 |
| C-05 | TC-003 (probe 4), TC-100, TC-132 |
| AC-01 | TC-051 |
| AC-02 | TC-041, TC-005 |
| AC-03 | TC-010 |
| AC-04 | TC-060 |
| AC-05 | TC-014 |
| AC-06 | TC-120, TC-121 |
| AC-07 | TC-093 |
| AC-08 | TC-110 |

## 4. Defects found during TS-0
| # | Where | Defect | Fix |
|---|---|---|---|
| 1 | `db/schema.sql` | `trg_decision_immutable` refused every DELETE, so the deletion cascade (report → match → match_decision) would have aborted — AC-06 impossible | A transaction-local flag set by `trg_deletion_cascade` lets the cascade through; every other DELETE still raises |
| 2 | `db/schema.sql` | `trg_deletion_cascade` had a placeholder statement and a dead variable | Removed; comment states that decisions on other people's reports keep their training value anonymised |
| 3 | `db/schema.sql` | `subscription` had only a maximum area — probe-sized polygons could localise reports (THR-T14) | `area_size` CHECK 1 km² … 20,000 km² |
| 4 | `db/seed_demo.sql` | The seed's `ON_ERROR_STOP on` would have aborted at the first constraint probe | `\set ON_ERROR_STOP off` before the probe transaction |
| 5 | `db/seed_demo.sql` | Notification count assumed u1 owned 3 pairs; the round-robin gives 4 (pairs 1, 7, 13, 19) | Extra area alerts reduced to 3 → 7 total → 5 + 2 |
| 6 | `db/seed_demo.sql` header | Spatial component stated as 0.4966; the geodesic distance is 2,100.8 m → 0.4965 | Header corrected |
| 7 | `api/openapi.yaml` | Descriptions containing `{id}` or commas inside flow mappings broke the parse; a bulk quoting pass then mis-quoted schema properties named `description`/`summary` | Quoting restricted to response descriptions; properties restored; `/geocode` added because ICD-07 referenced it |

## 5. Release gates
1. TS-0 green on every commit; TC-009 green in CI with the PostGIS + pgvector image.
2. AC-04 (TC-060) and AC-05 (TC-014) green — no launch with a privacy failure of any severity.
3. AC-02 (TC-041) ≥ 16/20 at 10 k **and** 100 k distractors; AC-01 (TC-051) when the benchmark set exists — until then, launch is single-region pilot only.
4. AC-06 (TC-120/121), AC-07 (TC-093), AC-08 (TC-110) green.
5. TS-5 green; TS-9 green; pen test (TC-135) goal not achieved.
6. NFR-01, NFR-02, NFR-04 measured (TC-090, TC-092, TC-091).
