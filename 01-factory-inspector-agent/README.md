# VisionOps — AI Factory Inspector Agent — Documentation Set

Camera → vision AI → measurement and defect detection → quality database → narrative agent → dashboard and Discord. The #1-ranked project in this repository and the canonical owner of the FactoryBrain `vision` schema.

**Standalone-deployable** (one `docker compose up`, cameras attached or replayed from a folder) **and** a FactoryBrain module in platform mode. Every document below describes the standalone deployment and carries a *platform mode* section.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts, no implementation yet.

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-01 | [Software Requirements Specification](SRS-AI-Factory-Inspector-Agent.md) | *What must it do?* | Everyone — start here |
| SAD-01 | [Software Architecture Document](docs/SAD-VisionOps-Software-Architecture.md) | *How is it built, and why?* | Implementer, architect |
| DDS-01 | [Database Design Specification](docs/DDS-VisionOps-Database-Design.md) | *How is the data modelled?* | Implementer, DBA |
| API-01 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *How do I call it?* | Client developer, integrator |
| ICD-01 | [Interface Control Document](docs/ICD-VisionOps-Interface-Control.md) | *Camera, PLC, edge, LLM, platform — how do they connect?* | Integrator, controls engineer |
| SEC-01 | [Security Requirements Specification](docs/SEC-VisionOps-Security-Requirements.md) | *How could verdicts be corrupted, and what stops it?* | Security reviewer, auditor |
| TEST-01 | [Test Plan and Test Cases](docs/TEST-VisionOps-Test-Plan.md) | *How do we know it works?* | QA, implementer |
| OPS-01 | [Deployment and Operations Guide](docs/OPS-VisionOps-Deployment-Operations.md) | *How do I install, commission and run it?* | Administrator, on-call |
| UM-01 | [User Manual and Administrator Guide](docs/UM-VisionOps-User-Admin-Guide.md) | *How do I use it?* | All users, administrators |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`api/openapi.yaml`](api/openapi.yaml) | OpenAPI 3.1 — 54 paths, 62 operations, 50 schemas | ✅ `openapi-spec-validator` pass; 220 `$ref`s resolve; no duplicate `operationId`; no orphan schemas |
| [`db/schema.sql`](db/schema.sql) | Standalone DDL — 5 schemas, 43 tables, 36 indexes, 9 views, roles and grants | ✅ 44 shared objects **byte-identical** to the platform schema; ⚠️ not executed (Docker daemon unavailable) |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Deterministic 7-day dataset reproducing SRS-01 Appendix A exactly | ✅ planted-day arithmetic verified (37/6/31, 27/5/5, 5.12 %/0.94 %, +42.0 %); ⚠️ not executed |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) | 21-service stack with `allinone` and `telemetry` profiles | ✅ valid YAML; all 15 referenced variables defined in `.env.example` |
| [`deploy/.env.example`](deploy/.env.example) | Every configuration variable with guidance and a pre-flight checklist | — |

---

## Reading paths

**Implementing it** → SRS-01 → SAD-01 §4 (views), §7 (ADRs) → DDS-01 §5–6 (VisionOps tables, recipe schema) → `openapi.yaml` → TEST-01 for the suite you are building against.

**Commissioning a real line** → OPS-01 §3.5–3.7 → §3.6 checklist (twelve checks, sign before enabling the reject signal) → ICD-01 IF-02/IF-03.

**Reviewing the design** → SAD-01 §2 principles, §7 ADR-V01…V10, §10 risks → SEC-01 §4 threat model and §7 residual risks → TEST-01 §4 gates.

**Integrating** → ICD-01 (find your `IF-xx`) → API-01 §11 platform-mode mapping → SAD-01 §9.

**Auditing** → SEC-01 (all) → DDS-01 Appendix B (the constraints that carry the weight) → TEST-01 §6 traceability.

**Using it** → UM-01 Part A. If one section: [A6 — Using the narrative agent](docs/UM-VisionOps-User-Admin-Guide.md#a6-using-the-narrative-agent).

---

## What makes this design what it is

The four platform principles apply ([00 README](../00-factorybrain-platform/README.md)). In VisionOps they land as:

| Principle | Concrete consequence |
|---|---|
| **The LLM never computes numbers** | The narrative agent has six typed read tools. Every figure is post-checked against tool output; a failed check **withholds** the narrative and the database refuses to store its text (`narrative_withheld_has_no_text`). |
| **Offline-first** | The verdict reaches the PLC after the local record is durable and **before any network I/O**. The inspection path contains no LLM, no server, no network. |
| **Human-in-the-loop** | REVIEW is a first-class verdict with its own PLC signal. Overrides are append-only and attributed. No model reaches the line without a shadow run and an admin, and **no API parameter bypasses the critical-recall gate**. |
| **The database is the source of truth** | Recipes, calibrations, models, verdicts, overrides and narratives are rows; the edge store is a buffer. Calibration validity is a generated column; frozen snapshots are immutable by trigger. |

Three VisionOps-specific decisions worth knowing before reading anything else:

- **`NO_READ` is not `PASS`.** A blurred, glared or uncalibrated frame is *not inspected*. Collapsing it into PASS inflates the pass rate and hides a dirty lens (ADR-V04).
- **Anomaly detection escalates to REVIEW only, never FAIL** (ADR-V05). A safety net that can reject product on an unexplainable score is a liability.
- **`vision.*` is byte-identical to the platform** (ADR-V10). `schema.sql` is *assembled* from `00/db/schema.sql` by line-range extraction; a diff over every shared `CREATE TABLE`/`TYPE` reports 44 objects, 0 differences.

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | Host in platform mode. VisionOps **owns** `vision.*`; the platform imports it. `/auth`, `/edge`, `/admin` collapse into the platform's; everything else mounts unchanged (API-01 §11). Edge nodes need only a URL change. |
| [03 EdgeGuard](../03-edge-vision-inspection/) | Supplies the edge runtime. VisionOps' E1–E6 containers *are* the EdgeGuard node on Jetson; VisionOps defines what they inspect and where results go. |
| [09 QE-Agent](../09-quality-engineer-agent/) | Consumes `vision.inspection`/`measurement` for SPC and cases; VisionOps hands "why" questions to it in platform mode. |
| [15 Genba Memory](../15-troubleshooting-memory/) | Indexes approved narratives as precedent; provides `search_memory` to the narrative agent in platform mode. |
| [10 Factory Copilot](../10-factory-copilot/) | Front-end for `/ask` in platform mode; the six VisionOps tools register into its registry. |
| [05 PocketQC](../05-offline-mobile-inspector/) | Mobile inspections land in the same `vision.inspection` with `source = 'mobile'`. |

---

## Identifier conventions

Shared with the platform set: `FR-`/`NFR-`/`AI-`/`AC-`/`C-` (SRS-01) · `P-1…P-4` · `ADR-` (platform) and **`ADR-V01…V10`** (VisionOps) · `QAS-` · **`DD-V01…V03`** · `IF-xx` (**numbering shared with ICD-00**; IF-18, IF-19 new) · **`THR-V`/`SEC-V`/`RR-V`** · `TS-`/`TC-` · `RB-01…14`.

```
SRS-01 FR-19  "every number traceable"
  └─ SAD-01 §4.3.3 narrative agent · ADR-V07 six tools
      └─ DDS-01 vision.narrative (facts · sources · grounding) · narrative_withheld_has_no_text
          └─ API-01 §8 grounding contract · 422 GROUNDING_FAILED
              └─ SEC-01 THR-V09 · SEC-V74
                  └─ TEST-01 TC-072 (seed numbers exact) · TC-073 (withheld stores no text) · TC-074 (zero fabrication)
                      └─ OPS-01 RB-12 · UM-01 A6
```

---

## Verification

What was actually checked when these documents were written.

| Check | Result |
|---|---|
| `openapi.yaml` vs OpenAPI 3.1 schema | ✅ **Pass** |
| `$ref` resolution, `operationId` uniqueness, responses present, orphan schemas | ✅ **Pass** — 220 refs, 62 operations, 0 defects |
| **Byte-identity of shared DDL vs `00/db/schema.sql`** | ✅ **Pass** — 44 shared `CREATE TABLE`/`TYPE` blocks, 0 differences; 7 VisionOps-only tables |
| `schema.sql` static checks (paren/quote/`$$` balance, FK targets exist) | ✅ **Pass** |
| `seed_demo.sql` planted-day arithmetic (positions, shifts, stations, lots, rates) | ✅ **Pass** — 37 unique fails; A 6 / B 31; ST3 27; lot 114 5.12 %; +42.0 % vs 2.1008 % |
| `docker-compose.yml` YAML; env coverage | ✅ **Pass** — 21 services; 15/15 variables defined |
| Every SRS-01 requirement ID referenced by a companion document | ✅ see below |
| Database objects and endpoints cited in prose exist in the artifacts | ✅ see below |
| Relative links (including into `../00-factorybrain-platform/`) | ✅ see below |
| **`schema.sql` / `seed_demo.sql` executed against PostgreSQL** | ⚠️ **Not verified** — Docker daemon not running on the authoring machine |

**To complete the database verification**, start Docker Desktop and run:

```bash
cd 01-factory-inspector-agent
docker run --rm -e POSTGRES_PASSWORD=x -v "$PWD/db:/db" pgvector/pgvector:pg16 \
  bash -c "docker-entrypoint.sh postgres & sleep 10; \
           psql -U postgres -v ON_ERROR_STOP=1 -f /db/schema.sql && \
           psql -U postgres -v ON_ERROR_STOP=1 -f /db/seed_demo.sql"
```

Success is both files applying with zero errors and the seed's `\echo` queries returning the values in [TEST-01 §3.1](docs/TEST-VisionOps-Test-Plan.md): 8,392 rows · 1,240 / 37 / 2.9839 % · baseline 2.1008 % · classes 19/8/6/4 · shifts 6/31 · stations 27/5/5 · queue 3 · overrides 10 · calibrations 3 · snapshot 10 items · narratives 2/1.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| DDL not executed against a live PostgreSQL | Above |
| A bumped camera mount is detected by drift and the next gauge check, not instantly — automated in-line gauge check is a future enhancement | SEC-01 RR-V02 |
| Grounding catches fabricated *numbers*, not flawed *reasoning* | SEC-01 RR-V04, UM-01 A6 |
| An `engineer` with a plausible reason can relax a recipe; two-person rule not enforced in v1 | SEC-01 RR-V03 |
| All-in-one mode shares one GPU; narratives slow under load | SAD-01 AR-V06 |
| Segmentation-based area rules, multi-camera fusion and automatic threshold optimisation are out of v1 | SAD-01 §10 |
| Golden narrative set, vision hold-out and replay image set must be built before the release gates can run | TEST-01 §3 |
| VisionOps-only tables (7) are not yet in the platform schema; back-port when adopted | DDS-01 §12 |

---

*VisionOps · v1.0 draft · 2026-09-11 · Suphot N.*
