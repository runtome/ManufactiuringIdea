# GAPFarm AI — AI Farmer Agent — Documentation Set

A farmer photographs an affected leaf; the app returns the likely disease, pest or deficiency **as calibrated probabilities** with what to look for and how to confirm — and when the farmer confirms, **the GAP scouting record, the task list and the reminders already exist** (SRS Appendix A: `SC-2026-0412`, three tasks, a rain warning, the agronomist line). Treatments come only from the farm's approved-input list with PHI/REI; a harvest inside a pre-harvest interval is **refused by the database**; every record is an append-only version in a per-zone hash chain an auditor can verify; sensors, weather, advisories and an interpretable harvest forecast sit around it; everything is Thai first and works offline on a low-end phone.

**A separate deployment, not a FactoryBrain module** (SAD-00 §13 "none"; DDS-00 §12.1 reserves the schema name `farm`). Own PostgreSQL 16 with **PostGIS + pgvector**. It reuses the platform's *patterns* — RFC 7807 `Problem` and the standard responses/parameters (byte-identical), the UUIDv7/`updated_at` helpers (byte-identical), the audit tables (identical modulo one FK), the compose hardening, IF-09/10/12/13/14 — and nothing else.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL/PostGIS/pgvector could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-12 | [Software Requirements Specification](SRS-GAPFarm-AI-Farmer-Agent.md) | *What must it do?* | Everyone — start here |
| SAD-12 | [Software Architecture Document](docs/SAD-GAPFarm-Software-Architecture.md) | *How does a photo become a record, a task and a reminder in one tap — and why can nothing here name a banned product or harvest inside PHI?* | Architect, implementer |
| DDS-12 | [Database Design Specification](docs/DDS-GAPFarm-Database-Design.md) | *Append-only versions, the hash chain, the PHI refusal, the approved-list guards, the seed that reproduces Appendix A and AC-02…AC-09* | Implementer, DBA |
| API-12 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The diagnosis, record, task, advisory/agent, sync and export contracts* | Implementer, PWA/Flutter |
| ICD-12 | [Interface Control Document](docs/ICD-GAPFarm-Interface-Control.md) | *MQTT sensors and weather (IF-12), offline sync (IF-63), the model contract (IF-64), the approved-input list (IF-65), the audit package (IF-66), LINE (IF-67)* | Implementer, ML owner, integrator |
| SEC-12 | [Security Requirements Specification](docs/SEC-GAPFarm-Security-Requirements.md) | *Can anyone get a dose or a banned product out of it? Edit the file before an audit? Harvest inside PHI? Find where the farmer lives?* | Security reviewer, compliance |
| TEST-12 | [Test Plan and Test Cases](docs/TEST-GAPFarm-Test-Plan.md) | *How we prove the chain, PHI, the approved list, the field-set gate, airplane mode and the mock audit* | QA, ML owner |
| OPS-12 | [Deployment and Operations Guide](docs/OPS-GAPFarm-Deployment-Operations.md) | *Install on one VPS, sensors and providers, the approved-list and model lifecycles, audit support, runbooks* | Operator, farm admin |
| UM-12 | [User Manual and Administrator Guide](docs/UM-GAPFarm-User-Admin-Guide.md) | *Reading the result card, the ≤ 3-tap flow, treating from the list, harvest and PHI, corrections, exports; admin* | Farmers, managers, agronomists, auditors, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 + PostGIS + pgvector: schema `farm` + `audit` — 52 tables (SRS §5's tables kept by name), 14 views, 30 triggers (35 bindings), 54 functions, 46 indexes, 25 enums, 5 roles (`agent_ro` cannot read identity, `farm.location` or `observation.gps`; `ingest_rw` inserts telemetry only; `app_rw` cannot UPDATE/DELETE records) | ✅ static DDL checks; 25/25 guard bindings; helpers byte-identical and audit identical modulo `core.app_user → farm.app_user` vs `00/db/schema.sql` · ⚠️ not executed (no PostgreSQL) |
| [`db/seed_demo.sql`](db/seed_demo.sql) | One chili farm, three zones, one season: Appendix A confirmed through the trigger (SC-2026-0412, 3 tasks, 3 reminders, rain conflict), a severe case with escalation, a treatment with PHI, the refused and the accepted harvest (AC-04), a low-confidence case corrected by an agronomist, an OOD refusal (AC-02), 20 offline observations synced and replayed (AC-07), a record corrected to version 2 (AC-06), sensor faults, an irrigation advisory, risk rules, the adversarial question (AC-08), predictions with intervals and `insufficient_data` (AC-09), a PDPA erasure, a 3-month export (AC-05), 15 probes | ✅ every expected value **re-derived in Python** (hash chain heads, export hash, PHI dates, GDD/stages, intervals, gaps, faults) · ⚠️ not executed |
| [`api/openapi.yaml`](api/openapi.yaml) | **56 paths / 62 operations / 78 schemas** — SRS §4.1's nine paths verbatim + observations/photos, confirm/review/correction, records with versions/PHI/traceability/chain, tasks/escalations/channels, sensors/weather/advisories/spray check, conversations/summary, export verify/compliance gaps, farms/zones/crops, sync, auth/devices, privacy, admin, system | ✅ validator pass; 0 undefined, 0 orphans, 0 null keys; **`Problem` + 3 parameters + 5 responses byte-identical to API-00 (9/9)** |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) · [`postgres/Dockerfile`](deploy/postgres/Dockerfile) · [`mosquitto/mosquitto.conf`](deploy/mosquitto/mosquitto.conf) | 17 services (web, api, worker-vision gpu/cpu, worker-agent, scheduler, mosquitto + ingest-mqtt [mqtt], postgres postgis+pgvector, redis, minio + init, ollama gpu/cpu, mailpit / sensor-sim / weather-mock [dev]); networks frontend / sensors / internal / egress | ✅ parses; hardening on 7 app services; egress only api + scheduler; sensors network = broker + ingest + sim; 9 internal-only; 4 DB roles by service; **53/53 env vars**, **17/17 secrets**; buckets private, exports object-locked, photos versioned |
| [`deploy/gapfarm.example.yaml`](deploy/gapfarm.example.yaml) + [`schemas/gapfarm-config.schema.json`](deploy/schemas/gapfarm-config.schema.json) | Runtime policy; the schema pins PHI enforcement, append-only, approved-list-only, two-person approval, OOD refusal, calibration, the AI-02 gates, ≤ 25 MB device model, ≥ 24 h buffer, LLM ≤ 9 B / ≤ 0.3, scripted fallback, weather suppression | ✅ valid; **45/45 negatives rejected**; loader rules hold |
| [`deploy/schemas/input-product.schema.json`](deploy/schemas/input-product.schema.json) + [`inputs/approved-products.example.yaml`](deploy/inputs/approved-products.example.yaml) | IF-65 — the approved-input list: PHI/REI/rainfast/MRL, label, two-person approval (example values — verify against labels) | ✅ valid; 14/14 negatives; loader rule L-1 |
| [`deploy/schemas/diagnosis-result.schema.json`](deploy/schemas/diagnosis-result.schema.json) + [`examples/diagnosis-appendix-a.json`](deploy/examples/diagnosis-appendix-a.json) | IF-64 — 1–3 calibrated candidates or an OOD refusal; Appendix A as JSON | ✅ Appendix A, OOD and gate-failure examples valid; 13/13 negatives |
| [`deploy/schemas/model-manifest.schema.json`](deploy/schemas/model-manifest.schema.json) + [`models/chili-v3*.manifest.json`](deploy/models/chili-v3.manifest.json) | IF-64 — field evaluations, calibration, OOD threshold, size; release conditions | ✅ both manifests valid; 11/11 negatives |
| [`deploy/schemas/gap-export-manifest.schema.json`](deploy/schemas/gap-export-manifest.schema.json) + [`examples/export-manifest.example.json`](deploy/examples/export-manifest.example.json) | IF-66 — the audit package manifest with chain heads and `verify_hash` (the seed's export) | ✅ valid; hash recomputed; 8/8 negatives |
| [`deploy/schemas/gap-scheme.schema.json`](deploy/schemas/gap-scheme.schema.json) + [`schemes/thaigap.example.yaml`](deploy/schemes/thaigap.example.yaml) | Scheme as data — record templates and mandatory-record rules (SRS §10) | ✅ valid; 7/7 negatives |
| [`deploy/prompts/`](deploy/prompts/answer.th.v1.md) · [`glossary.example.csv`](deploy/glossary.example.csv) | The two Thai prompts (answer from facts; render the Appendix A card) and the TH/EN glossary with forbidden variants | ✅ referenced by ICD-12 IF-09, config |

---

## Reading paths

**Implementing it** → SRS-12 → SAD-12 §4.3 (gate, diagnosis, confirmation, PHI, chain, sync) → DDS-12 §2 (DD-G01…G09) → `db/schema.sql` → API-12 §3–§8 → ICD-12 IF-63…IF-67 → TEST-12 TS-1, TS-2, TS-6.

**Compliance / audit review** → SAD-12 ADR-G03, G04, G05 → DDS-12 DD-G01, DD-G02, DD-G07 → ICD-12 IF-66 → SEC-12 O-1…O-3, §4.2 → TEST-12 TC-026…TC-030 → OPS-12 §10.

**ML owner** → SAD-12 ADR-G02, ADR-G06 → ICD-12 IF-64 → `deploy/schemas/diagnosis-result.schema.json`, `model-manifest.schema.json` → OPS-12 §7 → TEST-12 TC-011…TC-018, TC-092.

**Privacy review** → SEC-12 O-4, THR-G06, THR-G13, §5.3 → DDS-12 DD-G09, §8 → ADR-G10 → TEST-12 TC-070…TC-072.

**Operating it** → OPS-12 §4 (install), §5.3 (the approved list), §7 (models), §10 (audit support), §11 runbooks — RB-06 and RB-10 first.

**Using it** → UM-12 A.0, A.2 (the card line by line, one tap, treat from the list, harvest and PHI).

---

## What makes this design what it is

| Principle | In GAPFarm |
|---|---|
| **The LLM never computes** | The classifier diagnoses; PHI, severity, degree days, risk, spray conflicts, moisture trends and the harvest interval are SQL/Python functions with tests; the model composes Thai text from a facts object and cannot add a product, a dose or a number (AI-07). Without it, scripted answers (FR-08). |
| **Offline-first, degrade never block** | On-device model ≤ 25 MB, client UUIDs, idempotent sync (AC-07); no model → record-only mode; weather down → advisories suppressed with a reason; sensors down → advice still works. |
| **Decision support; the farmer and the agronomist act** | Calibrated top-3 with "how to confirm"; review queue; corrections as record versions; "consult an agronomist" on every severe or fast-spreading case; nothing actuated. |
| **The database is the source of truth — including for compliance** | Append-only versioned records with a per-zone hash chain; PHI refusal; approved-list guards; diagnosis shape; release gates; sync idempotency — 25 guard bindings (DDS-12 §2). |
| **Domain knowledge is data** | Approved inputs, scheme templates and rules, task templates, risk rules, crop stage models: tables with authors, sources and versions. |
| **Every diagnosis becomes a record** | Confirmation *is* the write that creates the scouting record, the tasks and the reminders; a refused image creates nothing. |

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | **None — separate deployment** (SAD-00 §13, DDS-00 §12.1, ICD-00 IF-12 scope note). Patterns reused and diffed: `Problem` + standard components, helper functions, audit tables, compose hardening, IF-09/10/12/13/14 conventions. |
| [05 PocketQC](../05-offline-mobile-inspector/) · [07 PawTrace](../07-ai-dog-finder/) | Patterns borrowed: on-device inference (ICD-05 IF-31), push (ICD-07 IF-40), the standalone PostGIS+pgvector image, the separate-deployment README shape. |
| [09 QE-Agent](../09-quality-engineer-agent/) · [08 DocFlow](../08-document-erp-agent/) · [11 MoldMind](../11-injection-molding-ai/) | What transfers back (SAD-12 §9): the record-version pattern with a hash chain, confirmation-driven generation from templates, the approved-list guard as the shape of MoldMind's process-window rule. |
| [04 OpsPilot](../04-local-ai-ops-agent/) · [07 PawTrace](../07-ai-dog-finder/) | The other separate deployments. |

---

## Identifier conventions

`FR-01…32` / `AI-01…09` / `NFR-01…09` / `AC-01…09` / `C-01…05` (SRS-12) · `P-1…P-6` · **`ADR-G01…G10`** · `QAS-01…12` · **`DD-G01…G09`** · `IF-xx` shared numbering (**IF-63 offline sync, IF-64 diagnosis model contract, IF-65 approved-input list & PHI, IF-66 GAP audit package, IF-67 LINE** new; IF-08/09/10/12/13/14/31/40 reused) · **`THR-G`/`SEC-G`/`RR-G`** · `TS-0…9` / `TC-` · `RB-01…14`.

```
SRS-12 C-02 / FR-11 / FR-28 / AC-04 / AC-08  "chemical advice only from the approved list; harvest blocked until PHI has elapsed"
  └─ SAD-12 ADR-G04 (PHI is a database refusal) · ADR-G05 (approved list is the only source of product names) · §4.3.4
      └─ DDS-12 DD-G03 (trg_product_approval, trg_input_usage_approved, trg_recommendation_approved, trg_answer_products) · DD-G07 (phi_clear_at, trg_harvest_phi, trg_task_rules) · seed: IU-2026-0031 → 09-14 refused / 09-18 accepted; e21 names no product
          └─ API-12 §4 record contract (409 PHI_NOT_ELAPSED, 409 UNAPPROVED_PRODUCT) · §6 (Answer.products ⊆ approved)
              └─ ICD-12 IF-65 (label, PHI/REI/rainfast/MRL, two-person approval) · IF-09 (facts-only prompt) · IF-67 (postback "done" obeys PHI)
                  └─ SEC-12 O-1, O-3 · THR-G01, G02, G05 · SEC-G01…G04, G09 · §4.2 walk-through
                      └─ TEST-12 TC-021…TC-024, TC-034, TC-050, TC-092, TC-093 · probes P-03…P-07
                          └─ OPS-12 §5.3 (the approved list), RB-10, RB-14 · UM-12 A.2.4, A.2.6, B.2
```

---

## Verification

| Check | Result |
|---|---|
| Static DDL (TC-003) | ✅ **Pass** — balance; FK targets defined and ordered; every table has a PK; 52 / 14 / 35 / 54 / 46 / 25; 25/25 guard bindings; grants as specified |
| Platform pattern identity (TC-002, TC-008) | ✅ **Pass** — helpers byte-identical (`00/db/schema.sql` §3); audit identical modulo `core.app_user → farm.app_user`; `Problem`, `Cursor`, `Limit`, `IdempotencyKey`, `Unauthorized`, `Forbidden`, `NotFound`, `ValidationFailed`, `TooManyRequests` byte-identical to API-00 |
| Seed re-derivation (TC-005) | ✅ **Pass** — record numbering SC-2026-0391…0415 (Appendix A = 0412); chain A 17 / B 10 / C 1, heads `05ff22f2ff8d` / `eed384754914` / `d1b32c897c84`, every hash recomputed; SC-2026-0412 v1 `b1c0a31d5026` → v2 `eed384754914`; traceability 1 input + 15 scouting; export 27 records, gap 1 (zone C 26 d), `verify_hash 727922173316…`; PHI 2026-09-17 08:00; GDD 1987.00 / 1118.50 / 567.00 (zone B flowering on 09-09 = 922.50 ✓ Appendix A); yield A 1450.0 [1102.2, 1797.8]; B harvest date 2026-10-06 [10-06, 10-07]; risk rule fires ×3; spray conflict true; moisture slope −0.5000; 3 faults; quiet-hours shift 21:30 → 06:00 |
| Contracts (TC-006) | ✅ **Pass** — product 14/14 + L-1; diagnosis 13/13 (Appendix A, OOD, gate-fail valid); manifests 11/11; export 8/8 + hash; scheme 7/7; config 45/45 + loader rules |
| `openapi.yaml` (TC-001) | ✅ **Pass** — 56 / 62 / 78; 0 undefined; 0 orphans; 0 null keys; 9/9 SRS paths |
| Compose / env / buckets (TC-004) | ✅ **Pass** — 17 services; profiles gpu/cpu/mqtt/dev; 53/53 vars; 17/17 secrets; egress = {api, scheduler}; sensors = {mosquitto, ingest-mqtt, sensor-sim}; 9 internal-only; private, locked, versioned buckets |
| Secret scan (TC-007) | ✅ **Pass** |
| SRS-12 coverage; cited tables/views/triggers/functions/endpoints/TCs/RBs/ADRs/SEC-Gs/DD-Gs/THR-Gs/IFs; section refs; links | ✅ sweep clean (see below) |
| **Schema + seed on PostgreSQL 16 + PostGIS + pgvector** (TC-009) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| Field benchmark (AC-01), device timing, airplane mode, LINE/weather providers, Ollama, mock audit (TS-1…TS-9) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 12-gapfarm-ai-agent/deploy && docker compose build postgres
docker run -d --name gf-pg -e POSTGRES_PASSWORD=x -p 5435:5432 $(docker compose config --images | grep postgres-postgis-pgvector)
sleep 10 && psql "postgresql://postgres:x@localhost:5435/postgres" -v ON_ERROR_STOP=1 -f ../db/schema.sql && psql "postgresql://postgres:x@localhost:5435/postgres" -f ../db/seed_demo.sql
```
Expected: the `\echo` block matches the seed header and the 15 probes each fail inside their savepoint.

**Defects found by checking** (all fixed; TEST-12 §5): `at` as a view column alias; chain payloads that included surrogate ids (non-reproducible hashes); a sensor series ending exactly on the offline boundary; a 9-day scouting gap in zone A that would have failed the mock audit; a diagnosis schema that rejected a legitimate gate failure; a product-schema clause that rejected every approved product; two YAML quoting errors in the OpenAPI; backslashes collapsed by shell heredocs on the authoring machine.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL/PostGIS/pgvector execution pending — static checks, byte-identity and re-derived arithmetic stand in until CI runs TC-009 | TEST-12 TC-009 |
| **Field test set** (AI-03, AC-01) does not exist in this repository; the release gate cannot pass until it does — launch is record-only + agronomist review for a new crop | TEST-12 TC-018, OPS-12 §7 |
| **PHI has no override** in v1 — a product applied to part of a zone blocks the whole zone; split zones is the workaround; an audited manager override is an open decision | ADR-G04, RB-14 |
| **Label values in the example list are examples** — PHI/REI/rainfast/MRL must be verified against registered labels before any farm uses them; no external PHI/MRL feed is in scope | ICD-12 IF-65, OPS-12 §5.3, RR-G04 |
| Only ThaiGAP shipped as a scheme file; GLOBALG.A.P. templates and rules need mapping with a certifying body | IF-66, OPS-12 §5.4 |
| LINE Messaging / Login, FCM and Web Push documented, not exercised; Discord optional | ICD-12 IF-67, IF-40 |
| Record-only observations (no confirmed diagnosis) do not count as scouting records for the gap rule — the app must create a scouting record explicitly in record-only mode | DDS-12 DD-G05, API-12 §4 |
| Harvest-date forecast uses the last 14 days' mean daily GDD (no seasonal weather normals); yield is an intercept-only model until ≥ 5 seasons | ADR-G08, `predict_harvest()` |
| Pseudonym is an unkeyed truncated hash of the user id | SEC-12 RR-G05 |
| Flutter app documented as an API client only (PWA first) | SAD-12 §4.5, ICD-12 §2 |
