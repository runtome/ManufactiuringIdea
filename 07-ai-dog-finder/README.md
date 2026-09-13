# PawTrace — AI Dog Finder 2.0 — Documentation Set

An owner posts a lost dog; anyone posts a sighting in under a minute with no account; photos become identity embeddings; a search constrained by radius, time and coarse attributes returns **ranked possible sightings with a calibrated confirmation rate** — and a human confirms or rejects. Locations are shown publicly only as ~5 km cells; contact goes through an in-app relay; photos are EXIF-free and moderated before anyone sees them; everything a person posted, including the vectors derived from it, can be deleted.

**A separate deployment, not a FactoryBrain module** (SAD-00 §13 "none"). Own PostgreSQL 16 with **PostGIS + pgvector**. It reuses the platform's *patterns* — RFC 7807 `Problem` (byte-identical), the UUIDv7/`updated_at` helpers (byte-identical), the audit tables (identical modulo one FK), the compose hardening — and nothing else. The SRS notes that the technical core transfers to industrial part-matching; SAD-07 §9 says what does.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL/PostGIS/pgvector could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-07 | [Software Requirements Specification](SRS-PawTrace-AI-Dog-Finder.md) | *What must it do?* | Everyone — start here |
| SAD-07 | [Software Architecture Document](docs/SAD-PawTrace-Software-Architecture.md) | *How do photos become ranked candidates in 15 s — and why can nothing here reveal where a family lives or claim "this is your dog"?* | Architect, implementer |
| DDS-07 | [Database Design Specification](docs/DDS-PawTrace-Database-Design.md) | *Vectors per model version, geography, the public role that cannot read a coordinate, and the seed that reproduces AC-02* | Implementer, DBA |
| API-07 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The privacy contract, the candidate contract, the anonymous contract* | Implementer, PWA/Flutter |
| ICD-07 | [Interface Control Document](docs/ICD-PawTrace-Interface-Control.md) | *Object storage, mail relay, map tiles & geocoding, push, CAPTCHA & device tokens, the vision model contract, shelter intake* | Implementer, ML owner |
| SEC-07 | [Security Requirements Specification](docs/SEC-PawTrace-Security-Requirements.md) | *Can anyone find where the owner lives? Lure them? Scrape the photos? Keep their data after deletion?* | Security reviewer, privacy officer |
| TEST-07 | [Test Plan and Test Cases](docs/TEST-PawTrace-Test-Plan.md) | *How do we prove 20 planted pairs surface among 10,000 distractors, that no public response is finer than the cell, and that deletion removes the embeddings?* | QA, ML owner |
| OPS-07 | [Deployment and Operations Guide](docs/OPS-PawTrace-Deployment-Operations.md) | *Install, providers and what breaks without them, moderation staffing, the model lifecycle, retention, privacy operations, runbooks* | Operator, moderation lead |
| UM-07 | [User Manual and Administrator Guide](docs/UM-PawTrace-User-Admin-Guide.md) | *Reading a possible sighting, confirm/reject, meeting safely, the 60-second sighting, moderation; admin* | Owners, finders, shelters, moderators, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 + pgvector + PostGIS: 36 tables, 9 views, 19 triggers, 26 functions, 33 indexes + a partial HNSW pair per embedding version, 17 enums, 5 roles (`public_ro` has no grant on `report.location`) | ✅ static DDL checks; 15/15 guard triggers; helpers byte-identical and audit identical modulo `core.app_user → pawtrace.app_user` vs `00/db/schema.sql` · ⚠️ not executed (no PostgreSQL) |
| [`db/seed_demo.sql`](db/seed_demo.sql) | 10,000 distractor sightings + 20 planted pairs with exact cosines (AC-02), the Appendix A candidate computed **through the real `search_candidates()` → fusion → calibration functions**, decisions, reunions, budget overflow (FR-25), deletion (AC-06), re-embed at 62 % (AC-08), bias slices (AI-08), 8 constraint probes | ✅ every expected value **re-derived in Python** (geodesic distance 2,100.8 m, spatial 0.4965, temporal 0.8432, score 0.7736, precision 0.68); **NumPy simulation** of the planted-pair construction: 20/20 rank 1 · ⚠️ not executed |
| [`api/openapi.yaml`](api/openapi.yaml) | **47 paths / 54 operations / 48 schemas** — SRS §4.1's eight paths verbatim + auth/devices, report lifecycle, matches, relay threads with consent, subscriptions/push/inbox, moderation, privacy rights, admin, shelter intake, geocode proxy, system | ✅ validator pass; null-key scan clean; 0 orphans; **`Problem` byte-identical to API-00** |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) · [`postgres/Dockerfile`](deploy/postgres/Dockerfile) | 11 services (web, api, worker-vision gpu/cpu profiles, worker-match, scheduler, postgres built from `postgis/postgis:16-3.4` + pgvector, redis, minio + init, mailpit dev); networks frontend / internal / egress | ✅ parses; hardening on 6 app services; ports on `BIND_ADDR`; egress only api/worker-match/scheduler; private buckets, no `originals`; models volume read-only; **53/53 env vars** both ways; 11/11 secrets referenced |
| [`deploy/pawtrace.example.yaml`](deploy/pawtrace.example.yaml) + [`schemas/pawtrace-config.schema.json`](deploy/schemas/pawtrace-config.schema.json) | Fusion weights (Appendix A), search limits (≤ 50 km, ≤ 30 d), notify budget, fuzz precision (public ≤ geohash-5), trust/rate limits, moderation bands, retention, regions | ✅ validates (Draft 2020-12); weights sum 1.0 and equal the schema defaults; regions equal the seed's; **11 schema negatives + 3 loader-rule negatives rejected** |

---

## Reading paths

**Implementing it** → SRS-07 → SAD-07 §4.3 (upload gate, pipeline, candidate search order, fusion & calibration, review flow) → DDS-07 §2 (DD-T01…T09) → `db/schema.sql` → API-07 §3–§5 → ICD-07 IF-42 → TEST-07 TS-1…TS-3.

**Privacy / security review** → SEC-07 §4.2 ("find where the dog lives") → DDS-07 §8 (`public_ro`) → API-07 §3 → TEST-07 TC-060, TC-014, TC-120, TC-124 → SEC-07 §8.

**ML owner** → SAD-07 ADR-T02…T04 → ICD-07 IF-42 → DDS-07 §4.3, §4.6 → OPS-07 §7 → TEST-07 TS-7, TC-041, TC-051.

**Operating it** → OPS-07 §1, §4, §5 (providers), §6.3 (moderation), §11 runbooks — RB-07 first.

**Using it** → UM-07 A0, A1.2 (the possible-sighting card line by line), A2 (60 seconds).

---

## What makes this design what it is

| Principle | In PawTrace |
|---|---|
| **The LLM never computes** → **the model never identifies** | There is no LLM. Detection, embedding and attributes are evidence; the search ranks; the displayed number is an empirical confirmation rate (`calibration_bin`), never a cosine; a `match` cannot be inserted or updated to `confirmed` without a human `match_decision` (C-03, AI-04, FR-19). |
| **Offline-first** → **degrade without the GPU** | The reporting path never waits for the vision worker; photos are stored and queued; a stopped worker does not fail readiness; everything is processed after restart with nothing lost (NFR-08, AC-07). |
| **Human-in-the-loop** | Confirm/reject/reunited are human actions with consent versions; moderation precedes public display; model activation and thresholds are admin actions; contact is a relay both sides control (P-3). |
| **The database is the source of truth — including for privacy** | `public_ro` cannot read `report.location`; `fuzz_cell()` is the only public form and `region.fuzz_public_precision ≤ 5` by CHECK; a photo row with EXIF is impossible; notification payloads with coordinates are refused; deletion cascades to embeddings in one statement (DDS-07 DD-T01…T09). |
| **Sixty seconds, no account** (P-5) | Device tokens instead of sign-up for finders; CAPTCHA only after abuse signals; the flow is one photo, GPS and a tap (C-02, AC-03). |
| **Missing a match costs more than an extra candidate** (P-6) | Notify threshold tuned for recall; the cost is capped by the daily budget and digest, not by raising the threshold (AI-05, FR-25). |

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | **None — separate deployment** (SAD-00 §13, README-00). Patterns reused and diffed: `Problem`, helper functions, audit tables, compose hardening, IF-10/IF-13/IF-14 conventions. DDS-00 §12.2's rule "public queries read location only through a fuzzing function" is implemented here as a database role. |
| [01 VisionOps](../01-factory-inspector-agent/) · [15 Genba Memory](../15-troubleshooting-memory/) | What transfers (SAD-07 §9): pre-filtered ANN over versioned vector spaces with atomic activation, calibrated scores from human decisions, append-only decision logs — "which part / defect have we seen before". |
| [04 OpsPilot](../04-local-ai-ops-agent/) · [12 GAPFarm](../12-gapfarm-ai-agent/) | The other separate deployments. |

---

## Identifier conventions

`FR-01…29` / `AI-01…09` / `NFR-01…09` / `AC-01…08` / `C-01…05` (SRS-07) · `P-1′…P-6` · **`ADR-T01…T10`** · `QAS-01…12` · **`DD-T01…T09`** · `IF-xx` shared numbering (**IF-39 map tiles & geocoding, IF-40 push, IF-41 CAPTCHA & device tokens, IF-42 vision model contract, IF-43 shelter intake** new; IF-10/13/14 reused) · **`THR-T`/`SEC-T`/`RR-T`** · `TS-0…9` / `TC-` · `RB-01…14`.

```
SRS-07 C-01 / NFR-05 / AC-04  "exact locations fuzzed in public views; exact coordinates only after mutual consent"
  └─ SAD-07 ADR-T05 (geohash cells by audience) · ADR-T06 (public role cannot read location) · §4.3.7
      └─ DDS-07 DD-T01 · public_ro column grant without location · fuzz_cell() · region.fuzz_public_precision CHECK ≤ 5 · report_public · v_map_cells · thread consent flags · trg_notification_budget (no lat/lng)
          └─ API-07 §3 privacy contract · ReportPublic.cell · MatchCandidate.distance_band · ThreadConsent.exact_locations_shared
              └─ ICD-07 IF-40 payload (cell only) · IF-39 (tiles see no report data)
                  └─ SEC-07 O-1 · THR-T01, T11, T13, T14, T15 · SEC-T01…T06 · §4.2 walk-through
                      └─ TEST-07 TC-003 (grants) · TC-060 (10 k public queries) · TC-061 · TC-124 · TC-134 · seed: 5-char cells
                          └─ OPS-07 §4.4 privacy check · RB-07 · UM-07 A0, A1.4
```

---

## Verification

| Check | Result |
|---|---|
| Static DDL (TC-003) | ✅ **Pass** — balance; FK targets defined and ordered; every table has a PK; 36 / 9 / 19 / 26 / 33 / 17; 15/15 guard triggers; `public_ro` report grant = `(id, kind, status, title, event_at, region_id, created_at)`, no `location`, no users/devices/threads/messages/matches/vectors |
| Platform pattern identity (TC-002, TC-008) | ✅ **Pass** — helpers byte-identical (`00/db/schema.sql` lines 63–104); audit identical modulo `core.app_user → pawtrace.app_user`; `Problem` byte-identical to API-00 |
| Seed arithmetic and simulation (TC-005) | ✅ **Pass** — Appendix A: 2,100.8 m → spatial 0.4965; 34.75 h → temporal 0.8432; sim_visual 0.80; score 0.7736; bin 0.7–0.8 → 0.680; notify. Tallies: 10,040 reports after deletion, 6,225 v2 vectors (62.0 %), u1 7 → 5 + 2, 14 confirms / ≤ 12 rejects, black-slice gap 16.87 %. NumPy: max distractor cosine 0.162 (theory 0.155); 20/20 pairs rank 1 by cosine and by worst-case fused score; best distractor fused 0.45 → calibrated 0.208 < 0.25 |
| `openapi.yaml` (TC-001) | ✅ **Pass** — 47 / 54 / 48; 0 undefined refs; 0 orphans; 0 null-valued keys |
| Compose / env / buckets (TC-004) | ✅ **Pass** — 11 services; profiles gpu/cpu/dev; 53/53 vars; 11/11 secrets; egress = {api, worker-match, scheduler}; `internal: true`; no originals bucket; `mc anonymous set none` only |
| Config schema + negatives (TC-006) | ✅ **Pass** — example valid; 11 schema negatives + 3 loader rules rejected |
| Secret scan (TC-007) | ✅ **Pass** |
| SRS-07 coverage; cited tables/views/triggers/endpoints/TCs/RBs/ADRs/SEC-Ts/DD-Ts/THR-Ts; section refs; links | ✅ see sweep note below |
| **Schema + seed on PostgreSQL 16 + PostGIS + pgvector** (TC-009) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| Re-ID benchmark (AC-01), device timing (AC-03), everything with real photos and phones (TS-1…TS-9) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 07-ai-dog-finder/deploy && docker compose build postgres
docker run -d --name pt-pg -e POSTGRES_PASSWORD=x -p 5434:5432 $(docker compose config --images | grep postgres-postgis-pgvector)
sleep 10 && psql "postgresql://postgres:x@localhost:5434/postgres" -v ON_ERROR_STOP=1 -f ../db/schema.sql && psql "postgresql://postgres:x@localhost:5434/postgres" -f ../db/seed_demo.sql
```
Expected: the `\echo` block matches the seed header (AC-02 `in_top10 = 20`, the Appendix A row, 5 push + 2 digest, deletion `db_done`, one active embedding version) and the 8 probes each fail inside their savepoint.

**Defects found by checking** (all fixed; TEST-07 §4): the decision-immutability trigger would have blocked the deletion cascade (AC-06 impossible until a transaction-local flag was added); a placeholder statement in the cascade; no minimum subscription area (probe-sized polygons could localise reports); `ON_ERROR_STOP` would have aborted the seed at the first probe; the notification count assumed one owner had 3 pairs (round-robin gives 4); the spatial component was stated as 0.4966 (geodesic gives 0.4965); descriptions with `{id}` inside OpenAPI flow mappings, and a bulk quoting pass that then mis-quoted schema properties named `description`; ICD-07 referenced a `/geocode` proxy the spec did not have.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL/PostGIS/pgvector execution pending — static checks, byte-identity and re-derived arithmetic stand in until CI runs TC-009 | TEST-07 TC-009 |
| **Re-ID benchmark dataset** (AI-03, AC-01) is not available in this repository; launch is single-region pilot until it exists | TEST-07 TC-051, §5 |
| Identical-looking dogs cannot be separated by the system — the relay conversation is the resolution | SAD-07 §6, SEC-07 RR-T01 |
| Flutter app documented as an API client only (PWA first); FCM path untested | SAD-07 §10, ICD-07 §2 |
| SMS provider unspecified (optional OTP channel) | ICD-07 IF-13 |
| Geocoder and tiles are third-party unless self-hosted; self-hosting documented | OPS-07 §5, ICD-07 IF-39 |
| Calibration provisional for a new model until 200 decisions | SAD-07 ADR-T04, OPS-07 §6.5 |
| Compose shares one `database_url` secret between api and workers for brevity; production should split `pt_api` / `pt_worker` | OPS-07 §4.2 |
