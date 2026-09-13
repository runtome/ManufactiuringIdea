# Software Architecture Document — PawTrace (AI Dog Finder 2.0)

| Field | Value |
|---|---|
| Document ID | SAD-07-PawTrace |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-07](../SRS-PawTrace-AI-Dog-Finder.md) |
| Related | [DDS-07](DDS-PawTrace-Database-Design.md) · [API-07](../api/API-Specification.md) · [ICD-07](ICD-PawTrace-Interface-Control.md) · [SEC-07](SEC-PawTrace-Security-Requirements.md) · [TEST-07](TEST-PawTrace-Test-Plan.md) · [OPS-07](OPS-PawTrace-Deployment-Operations.md) · [UM-07](UM-PawTrace-User-Admin-Guide.md) · patterns borrowed from [SAD-00](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) |

---

## 1. Introduction

### 1.1 Purpose
Define the architecture of PawTrace: a public, mobile-first system where an owner posts a lost dog, anyone posts a sighting in under a minute, a vision pipeline turns photos into identity embeddings, and a search constrained by geography, time and coarse attributes returns **ranked candidates that a human confirms or rejects**. The document fixes the boundaries that the SRS makes non-negotiable — no definitive identification (C-03), no exact locations in public (C-01), no EXIF (C-04), moderation before display (C-05), anonymous posting (C-02) — as architecture, not as UI behaviour.

### 1.2 What makes this project different from its siblings
Every other project in this repository is a factory system with a language model somewhere in it. PawTrace has **no LLM** and **no factory**. Its models are a detector, a re-identification embedding, an attribute head, an NSFW screen and a multilingual text embedding (AI-09). Its users are the public. Three consequences shape the architecture:

- **The model never identifies.** A cosine similarity is not a claim. The system converts it into a *calibrated precision* (AI-04) — "candidates with this score were confirmed 61 % of the time" — shows it beside the photos, and lets a person decide. Only a human decision creates a match, a reunion or a training label (FR-19, FR-20, AI-07).
- **Privacy is structural.** A lost-dog map is a pet-theft map if it shows coordinates. The database role used by public queries cannot read `report.location`; the only readable form is a fuzzed cell (`fuzz_cell()`); a photo is unservable until it is EXIF-stripped *and* approved by moderation; exact coordinates are exchanged only after mutual consent on a confirmed match (NFR-05). None of this depends on the API remembering to filter.
- **Anonymous by default, abusable by design.** A finder must post without an account (C-02). The design therefore assumes spam, fake sightings and scraping from day one: device tokens, rate limits, CAPTCHA escalation, a moderation queue, and a public representation that is cheap to serve and useless to scrape.

### 1.3 Relationship to FactoryBrain
**Separate deployment** (SAD-00 §13, README-00 "None"). Own database (`pawtrace`, requires PostGIS which the platform database does not have — DDS-00 §12.2). PawTrace reuses the platform's *patterns* — RFC 7807 `Problem`, the `audit.log` shape, the UUIDv7/`updated_at` helpers, signed-URL object storage (IF-10), SMTP/webhook (IF-13), metrics (IF-14), the compose hardening — and shares nothing else. The SRS notes (§1.1) that the technical core, embeddings + pgvector + geospatial + temporal filtering, transfers to industrial part-matching; §9 records what would transfer.

### 1.4 Related documents
DDS-07 (schema, the privacy role, the per-version vector index, the seed reproducing AC-02), API-07 (privacy / candidate / anonymous contracts), ICD-07 (IF-39 map & geocoding, IF-40 push, IF-41 CAPTCHA & device tokens, IF-42 vision model contract, IF-43 shelter intake), SEC-07, TEST-07, OPS-07, UM-07.

---

## 2. Architecture principles

The four platform principles, restated for a consumer product:

| # | Principle | In PawTrace |
|---|---|---|
| **P-1′** | **The model never identifies.** | Detection, embedding and attributes produce *evidence*; the search produces *ranked candidates* with a calibrated score and its components (visual, attributes, distance, time). No screen, notification, API field or database state says "this is your dog" until a human confirms (C-03, AI-04, FR-19). A `match` row cannot be inserted as `confirmed`; only a `match_decision` by a person moves it there. |
| **P-2** | **Degrade without the GPU.** | The reporting path (create report, upload photos, post a sighting) never waits for the vision worker. Photos are stored and queued; when the worker is back, everything is processed in order with no loss (NFR-08, AC-07). A report with unprocessed photos is visible to its owner with an honest "photos being processed" state. |
| **P-3** | **Humans decide consequences.** | Confirm/reject, reunion, moderation hide/remove, duplicate merge, model activation and threshold changes are human actions with a recorded actor. Moderation *precedes* public display (C-05). |
| **P-4** | **The database is the source of truth — including for privacy.** | Location fuzzing, EXIF/moderation gating, one-vector-space-per-query, decision immutability, notification budgets and deletion cascades are database constraints, functions and roles. The API and workers cannot bypass them by accident (DDS-07 DD-T01…T09). |

Two product principles are added:

| # | Principle | Why |
|---|---|---|
| **P-5** | **Sixty seconds, no account.** | A finder is standing on a pavement with a phone. Anything that takes longer than a minute — or asks for an email — loses the sighting (C-02, AC-03). |
| **P-6** | **Missing a match costs more than an extra candidate.** | The notify threshold is tuned for recall (AI-05); the cost of extra candidates is contained by the daily budget and the digest (FR-25), not by raising the threshold. |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-07 §2.4)
| ID | Constraint | Architectural response |
|---|---|---|
| C-01 | Exact locations fuzzed in public views | `public_ro` role has no grant on `report.location`; `fuzz_cell()` (geohash-5 ≈ 4.9 km cells publicly, geohash-6 ≈ 1.2 km for logged-in area subscribers); `ReportPublic` schema has a `cell`, never coordinates; AC-04 tests the API, not the UI (ADR-T05, ADR-T06) |
| C-02 | Sighting without account | Anonymous device token (IF-41); rate limits per device and IP; CAPTCHA only on abuse signals; moderation queue (ADR-T07) |
| C-03 | Never a definitive match | Calibrated precision displayed; `match.status` ∈ candidate/confirmed/rejected/superseded, `confirmed` only via a decision row; copy reviewed (UM-07) (ADR-T04) |
| C-04 | EXIF stripped before storage/serving | Upload gate strips in memory before the first write; `photo.exif_stripped` must be true before `moderation_status = approved` (trigger); the original bytes are never stored (ADR-T10) |
| C-05 | Moderation before public display | Signed URLs are only minted for approved photos; `report_public` view joins only approved photos; NSFW screen sets `pending`/`hidden` |

### 3.2 Quality attributes
| Attribute | Requirement | Design |
|---|---|---|
| **Latency** | NFR-01 upload → candidates ≤ 15 s p95; NFR-02 ANN over 1 M ≤ 300 ms p95 | Pre-filter by radius/time/attributes → ANN on the filtered set within the active version's partial HNSW (ADR-T03); GPU batch of 1 for interactive uploads; candidates streamed as soon as the first crop is embedded |
| **Scale** | NFR-03 100 k active reports, 1 M photos | Vector footprint ≈ 3 GB + HNSW; image tiers (thumb/card/full); BRIN on time; closed-report retention (§10) |
| **Mobile** | NFR-04 FCP ≤ 2 s on 4G; low-end Android | PWA with a 60-second sighting flow that needs one photo, GPS and a tap; client-side resize before upload; offline draft (ICD-07 §PWA) |
| **Privacy** | NFR-05, NFR-06, NFR-07 | Consent handshake for exact location; export/delete incl. embeddings (AC-06) via `deletion_request` cascade; private buckets + signed expiring URLs |
| **Availability** | NFR-08 ≥ 99.5 %, graceful GPU degradation | Reporting path independent of workers; queue durable in PostgreSQL + Redis; CPU profile |
| **Retrieval quality** | AI-03 Recall@10 ≥ 0.80, Recall@1 ≥ 0.45; AI-08 bias gap ≤ 15 % | `benchmark_run`/`benchmark_slice` per model version; activation gated on the benchmark; bias report per colour and size |
| **Localisation** | NFR-09 TH/EN | All copy keyed; multilingual text embedding (AI-09) |

### 3.3 Not drivers
Real-time video, shelter management, payments (out of scope); definitive identification (forbidden); non-dog species (v1).

---

## 4. Views

### 4.1 Context view
```
  Owner (PWA/Flutter) ──┐                              ┌── Map tiles / geocoder  IF-39
  Finder (anonymous) ───┤                              ├── Web Push / FCM        IF-40
  Shelter volunteer ────┼──── HTTPS ──►  PawTrace  ◄───┼── CAPTCHA               IF-41
  Moderator ────────────┤              api · workers   ├── Object storage (S3)   IF-10
  Admin ────────────────┘              postgres        ├── SMTP / SMS relay      IF-13
                                                       ├── Vision models         IF-42
                                                       └── Shelter CSV intake    IF-43
```

### 4.2 Container view
| Container | Responsibility | Notes |
|---|---|---|
| `web` | PWA: report flows, candidate review, map, moderation UI, admin | Static; served by `api`'s reverse proxy |
| `api` | FastAPI: auth (magic link/OTP, device tokens), reports, photos (EXIF gate, sha256, store), matches, contact relay, subscriptions, map cells, search, moderation, privacy rights, admin | Runs as `app_rw` for authenticated paths and **`public_ro` for public paths** (two connection pools) |
| `worker-vision` | Detect → crop → quality gate → NSFW → attributes → embedding; idempotent per `(photo, model_version)` | GPU profile (CUDA) or CPU profile; batch API in ICD-07 IF-42 |
| `worker-match` | Candidate search, fusion, calibration, notify decision, duplicate detection | Runs on new embeddings and on the schedule (FR-17) |
| `scheduler` | Re-run matching for active reports, expiry, digests, re-embed jobs, retention, calibration refresh, bias report | Cron in-container |
| `postgres` | PostgreSQL 16 + pgvector + PostGIS | Built image (`deploy/postgres/Dockerfile`) |
| `redis` | Queues (RQ), rate-limit counters, push dedupe | — |
| `minio` | S3-compatible private buckets (`originals` never exist; `derivatives`, `crops`, `exports`) | Production may use any S3 |
| `mailpit` | Dev-only mail sink (`dev` profile) | — |

### 4.3 Component view

#### 4.3.1 Upload and privacy gate (`api`)
1. Receive bytes (≤ 12 MB, JPEG/PNG/HEIC) → decode in memory → **strip all EXIF/XMP/IPTC** → re-encode.
2. If the user consented to coarse location and EXIF had GPS: record `lat/lng` **rounded to the fuzz precision** on the report draft (never on the photo) and the capture time (FR-04); otherwise discard.
3. `sha256` of the stripped bytes → idempotent: same hash on the same report returns the existing photo.
4. Write derivatives (full ≤ 2048 px, card 800 px, thumb 200 px) to the private bucket; insert `photo` with `exif_stripped = true`, `moderation_status = pending`; enqueue vision job.
The original upload bytes are never persisted anywhere (AC-05).

#### 4.3.2 Vision pipeline (`worker-vision`, IF-42)
Detector (dog class only) → crops with short edge ≥ 128 px (AI-01) and a quality score (blur, occlusion, exposure) → reject with a specific reason (`NO_DOG`, `CROP_TOO_SMALL`, `LOW_QUALITY`, FR-09) → NSFW screen on the whole photo (FR-26) → attribute head per crop (size, colour ×2, coat length, breed group, markings; FR-11) → embedding per crop, L2-normalised, 768-d, stamped with `model_version` (AI-02, AI-06) → report aggregate (mean of normalised crop vectors, re-normalised; medoid kept for display; FR-12). Idempotent by `(photo_id, model_version_id)` (FR-13) so a re-run after a model upgrade is a plain re-enqueue.

#### 4.3.3 Candidate search (`worker-match`, ADR-T03)
```
candidates(lost L) =
   reports R  where kind ∈ {found, sighting} ∧ status = active
             ∧ ST_DWithin(R.location, L.location, radius)          -- GIST
             ∧ R.seen_at ∈ [L.lost_at − grace, L.lost_at + days]    -- BRIN
             ∧ attr_compat(L, R) ≥ 0.4                              -- hard incompatibility only (size 2 classes apart, colour disjoint)
   ORDER BY report_embedding.vec <=> L.vec                          -- HNSW partial index WHERE model_version_id = active
   LIMIT 200
```
Why pre-filter: the geo/time predicates remove > 99 % of rows for a local search, so the ANN runs on a small set and stays under 300 ms at 1 M vectors (NFR-02); post-filtering an ANN top-k would drop true matches that rank below distant look-alikes. The search function takes the **active embedding version** and reads only that version's vectors (AC-08).

#### 4.3.4 Fusion and calibration (Appendix A)
```
score = 0.55 · sim_visual (calibrated cosine → precision, 0–1)
      + 0.15 · attr_compat
      + 0.20 · spatial(d) = exp(−d / 3 km)
      + 0.10 · temporal(Δt, order)
      − penalty(quality)              -- 0.05 if either crop quality < 0.5
notify if calibrated_precision(score) ≥ 0.25 AND rank ≤ 5           (AI-05, FR-25 budget applies)
```
`temporal`: 1.0 for a sighting 0–24 h after the loss, decaying linearly to 0.3 at the window's end; a sighting *before* the loss time scores 0.1 unless the report is flagged re-loss (FR-16). Calibration: `calibration_bin` per embedding version maps score deciles to the empirical confirm rate from `match_decision`; refreshed nightly; a new model version starts with the previous curve and a "calibration provisional" flag until it has 200 decisions (AI-04). Every component is stored in `match.components_json` and shown to the user (FR-18).

#### 4.3.5 Review flow
Owner sees candidates side by side (their photo, the sighting's photo, distance, elapsed time, the calibrated score and its components). **Confirm** → `match_decision(confirm)` → `match.status = confirmed` → contact thread opens (relay) → consent handshake for exact locations → **Reunited** → `reunion` row, report `reunited`, remaining candidates `superseded`. **Reject** → `match_decision(reject)`, candidate hidden, never re-shown for this pair. Both decisions carry the consent version under which they may be used for training (AI-07).

#### 4.3.6 Notifications (FR-22, FR-23, FR-25)
Channels: Web Push/FCM (IF-40), email (IF-13), optional SMS. Budget: `can_notify(user)` — max `N = 5` per day per user; beyond that, a digest at 18:00 local. Area subscriptions (polygon + filters) get *new-report* alerts with the fuzzed cell only.

#### 4.3.7 Public map (FR-24, C-01, AC-04)
`GET /map/cells?bbox&days` returns geohash-5 cells with counts and the coarse attributes histogram — never a report's coordinates. The view `v_map_cells` is the only object the public role can read for location, and it is computed from `fuzz_cell(location, 'public')`.

#### 4.3.8 Moderation and anti-abuse (FR-26…29, C-02)
NSFW screen (IF-42) → `hidden` with reason; user abuse reports → `abuse_report` → queue; moderator hide/remove/merge with `moderation_event` audit; device trust score falls with abuse signals → CAPTCHA required (IF-41) → device banned; rate limits per device/IP/route in Redis with the last-known counters mirrored to `rate_limit_bucket` for forensics. Duplicates: two active reports of the same kind within 500 m and 48 h with report-vector cosine ≥ 0.9 → `duplicate_cluster` for a moderator to merge (FR-29).

#### 4.3.9 Privacy rights (NFR-06, AC-06)
`POST /me/export` → zip (reports, photos, decisions, messages) in `exports` bucket, signed URL, 24 h. `POST /me/delete` → `deletion_request` → trigger cascade removes reports, photos (bucket objects via the scheduler), crops, embeddings, text embeddings, subscriptions, push subscriptions; keeps an anonymised tombstone in `audit.log` and anonymised `match_decision` rows only if the consent version allows (else deleted). SLA 72 h; `v_deletion_status` shows progress.

### 4.4 Runtime views

**Lost report → candidates (NFR-01, ≤ 15 s p95)**
```
t=0     POST /reports (lost)  → report active
t=0.5   POST /reports/{id}/photos ×3 → EXIF strip, sha256, store (≈ 0.4 s each) → 3 vision jobs
t=2     worker-vision: detect+crop+attrs+embed photo 1 (GPU ≈ 0.6 s; CPU ≈ 4 s)
t=3     worker-match: search on the first embedding → 37 candidates after filters → fusion → top 10 stored
t=3.5   owner's screen shows candidates (polling /reports/{id}/matches; "2 photos still processing")
t=6     photos 2–3 done → report aggregate vector → matching re-run → ranks update
t=6.5   candidate #1 calibrated 0.61, rank 1 → notify (budget 0/5) → push + email
```

**Anonymous sighting in 60 s (AC-03, P-5)** — open PWA → "I saw a dog" → camera (1 photo) → GPS auto (map pin fallback) → "now" pre-filled → post. Device token created silently on first post; CAPTCHA not shown unless the device's trust score is low. Server: EXIF strip, store, `pending` moderation, queued; the finder sees "Thanks — owners nearby will be notified once the photo is checked".

**GPU worker down (AC-07)** — photos accepted and stored; jobs accumulate in Redis and in `photo.processing_state = queued`; `/readyz` reports `vision_backlog`; on restart the worker drains in FIFO; matching runs as embeddings appear; nothing lost.

**Model upgrade (AC-08)** — admin registers `emb v2` (dims 768, benchmark attached) → `reembed_job` walks all instances producing v2 embeddings alongside v1 (v1 stays `search_active`) → when 100 % and the benchmark ≥ v1, admin activates v2: one transaction flips `search_active`, the partial HNSW for v2 (built concurrently during the job) serves the next query; v1 rows are dropped after 7 days. At no point does a query read two versions.

**Deletion (AC-06)** — see §4.3.9; the scheduler deletes bucket objects and marks the request `completed`; the API returns 410 for the report's URLs.

**Abuse** — a device posts 6 sightings in 10 minutes with the same photo → rate limit 429 → trust score drops → CAPTCHA on next post → an owner reports one as fake → moderator hides all, bans the device → `moderation_event` rows, audit.

### 4.5 Deployment view
Single host compose (`deploy/docker-compose.yml`): `web`, `api`, `worker-vision` (`gpu` or `cpu` profile), `worker-match`, `scheduler`, `postgres`, `redis`, `minio`, `mailpit` (`dev`). Networks: `frontend` (api/web behind the reverse proxy, ports on `BIND_ADDR`), `internal` (no egress), `egress` (api + scheduler + worker-match: push, SMTP, geocoder, CAPTCHA verification). Scaling: `worker-vision` replicas by GPU count; `api` behind a load balancer; PostgreSQL read replica for the public role at scale.

### 4.6 Data view
Two schemas: `pawtrace` (everything) and `audit` (append-only). The privacy-critical objects are the `public_ro` role, `fuzz_cell()`, `report_public`, `v_map_cells`, and the photo gating trigger; the retrieval-critical ones are `model_version.search_active`, the per-version partial HNSW indexes and `search_candidates()`. DDS-07.

---

## 5. Cross-cutting concerns
| Concern | Design |
|---|---|
| Identity | Users: magic link or OTP by email (no passwords); anonymous: device token (random 32 B, stored hashed) with trust score; roles user/shelter/moderator/admin |
| Contact | In-app relay threads only; email relay optional with rewritten addresses; phone numbers never stored in plain text (FR-07) |
| Errors | RFC 7807 `Problem` verbatim from API-00; codes in API-07 §7 |
| Observability | IF-14 metrics: upload latency, vision backlog, ANN latency, candidates/notify per day, budget hits, moderation queue depth, calibration drift, recall per slice |
| Localisation | TH/EN copy keys; text embedding multilingual (AI-09) |
| Consent | Consent versions recorded on account creation and on each decision (AI-07); coarse-location consent per report (C-04) |
| Retention | Closed/reunited reports: photos to thumb-only after 90 d, deleted after 365 d unless the owner keeps the reunion story; embeddings of deleted photos removed; distractor-quality sightings expire after 30 d |

## 6. Similar-looking dogs — the design's own risk
The SRS risk "false hope" is the product's central UX and ethics problem. The architecture addresses it in four places: the displayed number is a calibrated precision, not a similarity (AI-04, ADR-T04); the side-by-side view shows *why* (components), so a user can see that a high score is mostly proximity; the copy never uses "match" before confirmation (UM-07 A0); and rejections are learned from (calibration and, with consent, training). What the architecture cannot fix: two genuinely identical-looking dogs 500 m apart. The human conversation in the relay thread is the resolution, and the design makes that conversation safe (no PII, consented location).

---

## 7. Architecture Decision Records

### ADR-T01 — One PostgreSQL with pgvector and PostGIS
Vectors, geography and time live in one database so the candidate query is one SQL statement with one transaction boundary and one index plan; a separate vector store would force post-filtering (rejected in ADR-T03). Cost: a custom image (`postgis/postgis:16-3.4` + `postgresql-16-pgvector`). Alternatives rejected: Qdrant/Milvus + PostGIS (two systems, post-filter), Elasticsearch (weaker geo+vector filtering at this scale for the team).

### ADR-T02 — Per-model-version partial HNSW indexes and an active-version search function
`embedding` and `report_embedding` carry `model_version_id`; each version gets `CREATE INDEX … WHERE model_version_id = <id>`; `search_candidates()` reads `model_version.search_active` and queries only that version. A migration builds the new index concurrently while the old version serves; activation is one UPDATE. Guarantees AC-08 (no mixed spaces) structurally.

### ADR-T03 — Pre-filter by geography, time and attributes, then ANN
See §4.3.3. HNSW post-filtering with strict predicates loses recall; pre-filtered exact/ANN search over a few thousand rows is fast and complete. When a lost report has a radius of 50 km in a dense city the filtered set may reach 50 k rows; the planner then uses the partial HNSW with `ef_search` raised — measured in TC-092.

### ADR-T04 — Display a calibrated precision, never a raw cosine
A cosine of 0.83 means nothing to an owner and is model-dependent. `calibration_bin` per embedding version, refreshed from decisions, gives a number with a plain meaning; new versions start provisional. The notify rule uses the calibrated value (Appendix A).

### ADR-T05 — Fuzz by geohash cells with audience-dependent precision
Public map and public report cards: geohash-5 (≈ 4.9 × 4.9 km). Logged-in area subscribers and candidate cards: geohash-6 (≈ 1.2 × 0.6 km) plus a distance *band* ("about 2 km away"). Exact coordinates: only the reporter, and the matched counterpart after both consented on a confirmed match. Cells rather than random jitter because jitter averages out over repeated queries (SEC-07 THR-T01).

### ADR-T06 — The public database role cannot read `location`
`public_ro` has column-level SELECT on `report` excluding `location`, and SELECT on `report_public` / `v_map_cells` which expose `fuzz_cell()` only. The API's public paths use a connection pool bound to this role. A bug in a public handler cannot leak a coordinate because the database will not return one.

### ADR-T07 — Anonymous posting via device tokens with CAPTCHA escalation
A device token is issued on first post; rate limits are per device and per IP; CAPTCHA is demanded only when the trust score falls (burst, duplicate photos, abuse reports). Keeps the 60-second flow for honest finders and makes spam expensive. Alternatives rejected: CAPTCHA always (kills AC-03), phone verification (excludes and costs).

### ADR-T08 — Contact through a relay; no PII exchange
Owner and finder talk in an in-app thread; optional email relay with rewritten addresses; phone numbers only if both sides paste them in the thread themselves. The system never displays a poster's email or phone (FR-07); the thread is moderatable.

### ADR-T09 — Decisions are append-only training signal with a consent version
`match_decision` cannot be updated or deleted by the application; each row records the consent version the user accepted (AI-07). Deletion requests remove or anonymise decisions according to that version. Calibration reads decisions; training exports read only consented ones.

### ADR-T10 — Images are private, EXIF-free derivatives served by signed URLs
No original bytes are stored; derivatives are written to private buckets; URLs are signed and expire in 15 min (thumb/card) or 5 min (full); the photo gating trigger prevents approving a non-stripped photo, and the URL signer refuses non-approved photos (C-04, C-05, NFR-07).

---

## 8. Quality attribute scenarios
| ID | Attribute | Scenario | Response | Trace |
|---|---|---|---|---|
| QAS-01 | Latency | Owner uploads 3 photos on 4G | First candidates ≤ 15 s p95 | NFR-01, TC-090 |
| QAS-02 | Latency | 1 M vectors, 50 km radius in Bangkok | ANN ≤ 300 ms p95 | NFR-02, TC-092 |
| QAS-03 | Privacy | Scraper calls `/map/cells` and `/search` 10 k times | Never a coordinate finer than the cell; rate-limited | C-01, AC-04, TC-060 |
| QAS-04 | Privacy | Photo with GPS EXIF uploaded | Stored derivative has no EXIF; report gets a coarse location only with consent | C-04, AC-05, TC-014 |
| QAS-05 | Correctness | 20 planted pairs among 10 k distractors | ≥ 16 in top 10 | AC-02, TC-041 |
| QAS-06 | Honesty | Candidate with cosine 0.92 but 40 km away, 20 days later | Score shows components; calibrated value moderate; copy says "candidate" | C-03, TC-046 |
| QAS-07 | Availability | GPU worker down 6 h | Reports accepted; all processed after restart | AC-07, TC-093 |
| QAS-08 | Evolvability | Embedding model v2 | Re-embed in background; activation atomic; no mixed query | AC-08, TC-110 |
| QAS-09 | Rights | User asks to delete | Everything incl. embeddings gone ≤ 72 h; tombstone only | AC-06, TC-124 |
| QAS-10 | Abuse | Device posts 20 fake sightings | 429 after limit; CAPTCHA; moderator hides; device banned | FR-28, TC-100 |
| QAS-11 | Fairness | Recall for black dogs 20 % below average | Bias report flags; rebalancing task created | AI-08, TC-113 |
| QAS-12 | Usability | Finder on a low-end Android | Sighting posted in ≤ 60 s | AC-03, NFR-04, TC-010 |

---

## 9. What transfers to industrial part-matching
The candidate query (ANN ∩ spatial ∩ temporal ∩ attribute pre-filter), per-version vector spaces with atomic activation, calibrated scores from human decisions, and the append-only decision log transfer directly to "which part / which defect have we seen before" in VisionOps (01) and Genba Memory (15). What does not transfer: the privacy role model (factory data is not public) and the anonymous device layer.

## 10. Risks and technical debt
| Risk (SRS §10) | Design response | Residual |
|---|---|---|
| Cold start | Shelter intake (IF-43), single-region launch config | Matching quality poor until density |
| False hope | §6 | Identical-looking dogs |
| Pet theft via location | ADR-T05/T06, SEC-07 | Timing/correlation attacks with many accounts (rate limits) |
| Abuse/spam | ADR-T07, moderation | Moderator capacity |
| Re-ID underperforms on mixed breeds | Attribute fallback in fusion; bias audit | Benchmark data availability (README gap) |
| Cost | Tiers, batch embedding, retention | GPU cost at > 50 k photos/day |

Debt: no Flutter build (PWA first); SMS provider unspecified; geocoder is a third-party dependency (self-hosting documented in OPS-07 §5); calibration provisional for new models.

## 11. Traceability to SRS-07
| SRS | Where |
|---|---|
| C-01…C-05 | §3.1, ADR-T05…T08, T10 |
| FR-01…07 | §4.3.1, §4.3.5, §4.4, ADR-T08 |
| FR-08…13 | §4.3.2, ADR-T02 |
| FR-14…21 | §4.3.3, §4.3.4, §4.3.5, ADR-T03, T04 |
| FR-22…25 | §4.3.6, §4.3.7 |
| FR-26…29 | §4.3.8, ADR-T07 |
| AI-01…09 | §4.3.2, §4.3.4, §3.2, ADR-T02, T04, T09 |
| NFR-01…09 | §3.2, §4.4, §5 |
| AC-01…08 | §8 |
