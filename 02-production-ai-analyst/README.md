# ShiftBrief — Production AI Analyst — Documentation Set

Daily production file → validated warehouse → deterministic, hashed *facts object* → grounded LLM brief → Discord, dashboard, PPTX/PDF — in Thai, Japanese or English. The project this repository recommends building **first**: no cameras, no edge hardware, no GPU required, immediately useful at work.

**Standalone-deployable** on a small server or VPS (CPU-only reference profile) **and** the daily-brief engine of FactoryBrain in platform mode. Every document describes standalone and carries a *platform mode* section.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts, no implementation yet.

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-02 | [Software Requirements Specification](SRS-ShiftBrief-Production-AI-Analyst.md) | *What must it do?* | Everyone — start here |
| SAD-02 | [Software Architecture Document](docs/SAD-ShiftBrief-Software-Architecture.md) | *How is it built, and why?* | Implementer, architect |
| DDS-02 | [Database Design Specification](docs/DDS-ShiftBrief-Database-Design.md) | *How is the data modelled? What is a facts object?* | Implementer, DBA |
| API-02 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *How do I call it?* | Client developer, integrator |
| ICD-02 | [Interface Control Document](docs/ICD-ShiftBrief-Interface-Control.md) | *How does a file get in and a deck get out?* | Integrator, file owner |
| SEC-02 | [Security Requirements Specification](docs/SEC-ShiftBrief-Security-Requirements.md) | *What can a bad file, a bad query, or a bad export do?* | Security reviewer, auditor |
| TEST-02 | [Test Plan and Test Cases](docs/TEST-ShiftBrief-Test-Plan.md) | *How do we know it works?* | QA, implementer |
| OPS-02 | [Deployment and Operations Guide](docs/OPS-ShiftBrief-Deployment-Operations.md) | *How do I install it and set up the daily file?* | Administrator, on-call |
| UM-02 | [User Manual and Administrator Guide](docs/UM-ShiftBrief-User-Admin-Guide.md) | *How do I read the brief and use the analyst?* | All users, administrators |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`api/openapi.yaml`](api/openapi.yaml) | OpenAPI 3.1 — 43 paths, 47 operations, 39 schemas | ✅ `openapi-spec-validator` pass; 165 `$ref`s resolve; no duplicates; no orphans |
| [`db/schema.sql`](db/schema.sql) | Standalone DDL — 5 schemas, 36 tables, 9 views, roles and grants | ✅ 37 shared objects (tables, types **and views**) **byte-identical** to the platform; ⚠️ not executed (Docker daemon unavailable) |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Deterministic 30-day dataset reproducing SRS-02 Appendix A | ✅ arithmetic verified (12,430/382/3.07 %, 2.59 %, +18.4 %, 41.1 %, L3 5.82 %, p ≈ 0.002); ⚠️ not executed |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) | 18-service stack; CPU-only default, `gpu` and `sftp` profiles | ✅ valid YAML; all 15 referenced variables defined |
| [`deploy/.env.example`](deploy/.env.example) | Every variable with guidance and a pre-flight checklist | — |

---

## Reading paths

**Implementing it** → SRS-02 → SAD-02 §4.3 (intake, facts builder, composer, `/ask` planner) → DDS-02 §5–7 (analytics tables, mapping schema, **facts schema**) → `openapi.yaml` → TEST-02.

**Setting up the daily file for a real plant** → OPS-02 §3.5 (the afternoon that decides whether this is useful) → ICD-02 IF-20 → UM-02 B2.

**Reviewing the design** → SAD-02 §2 (P-1 at its strictest), §7 ADR-S01…S08, §10 → SEC-02 §4 (the attack walk-through, and RR-S01) → TEST-02 §4 gates.

**Auditing** → SEC-02 → DDS-02 Appendix A (the constraints that carry the weight) → TEST-02 §6 traceability.

**Using it** → UM-02 A2 (how to read a brief) and A6 (the analyst's limits).

---

## What makes this design what it is

The four platform principles apply ([00 README](../00-factorybrain-platform/README.md)). ShiftBrief is where **P-1 is at its strictest**:

| Principle | Concrete consequence |
|---|---|
| **The LLM never computes numbers** | The brief composer receives **exactly one input: the facts object**. No rows, no file, no tool calls. Every number is post-checked against that one JSON document; failure withholds the brief and the database refuses to store its text. |
| **Offline-first** | The reference deployment is a CPU-only VPS with no internet. A ≤ 4 B model is a supported configuration, not a degraded one (ADR-S06). |
| **Human-in-the-loop** | A brief is advisory; alerts are notifications. The only write tool is `send_discord`, gated by a proposal. Text-to-SQL is off until an admin enables it after two test gates. |
| **The database is the source of truth** | `analytics.facts` is immutable (trigger), hashed, versioned. Source files are archived unmodified with their hash. Corrections create linked revisions, never overwrites. |

Four decisions worth knowing before reading anything else:

- **The facts object is a stored, hashed row** (ADR-S01). Regeneration recomputes and compares; a mismatch is `FACTS_STALE`, surfaced, never papered over.
- **Column mapping is versioned YAML with a header fingerprint** (ADR-S02). A renamed column holds the batch; nothing is guessed.
- **> 5 % invalid rows rejects the whole batch** (ADR-S03). A day is either in or absent — never 92 % loaded and looking complete.
- **Significance gates causal language** (ADR-S05). A normal day is called "within normal variation" with no recommendation. A 12-part line is never "worst" (ADR-S04).

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | Host in platform mode. `core.production_*` and the three `core.v_*` views are byte-identical; ShiftBrief *is* the platform's daily brief (SRS-00 FR-A-03) and its `POST /ingest/production`. `analytics.*` is ShiftBrief's own (migration `shiftbrief_0001`). |
| [01 VisionOps](../01-factory-inspector-agent/) | Independent data path (inspection records vs the production file). The platform reconciles both. Same grounding mechanism, same conventions. |
| [09 QE-Agent](../09-quality-engineer-agent/) | A significant day opens a `quality.signal` for it; it has the machine and material data ShiftBrief does not. |
| [10 Factory Copilot](../10-factory-copilot/) | Front-end for `/ask`; the eight ShiftBrief tools register into its registry. |
| [13 KaizenSwarm](../13-multi-agent-factory/) | Its Production Agent reads `analytics.v_latest_facts` directly. |

---

## Identifier conventions

Shared with the set: `FR-`/`NFR-`/`AI-`/`AC-`/`C-` (SRS-02) · `P-1…P-4` · `ADR-` (platform) and **`ADR-S01…S08`** · `QAS-` · **`DD-S01…S05`** · `IF-xx` (shared numbering; **IF-20 file intake, IF-21 exports** new) · **`THR-S`/`SEC-S`/`RR-S`** · `TS-`/`TC-` · `RB-01…14`.

```
SRS-02 C-01 / FR-18  "facts-only LLM input"
  └─ SAD-02 P-1 · §4.3.3 composer · ADR-S01 facts row
      └─ DDS-02 analytics.facts (immutable, sha256) · brief_withheld_has_no_text
          └─ API-02 §5 facts contract · §6 grounding contract · FACTS_STALE
              └─ SEC-02 THR-S09/S12 · SEC-S45/S48
                  └─ TEST-02 TC-029 (hash identical / stale detected) · TC-031, TC-032 (zero fabrication) · TC-035
                      └─ OPS-02 RB-06, RB-13 · UM-02 A2, A6
```

---

## Verification

| Check | Result |
|---|---|
| `openapi.yaml` vs OpenAPI 3.1 schema | ✅ **Pass** |
| `$ref` resolution, `operationId` uniqueness, responses present, orphan schemas | ✅ **Pass** — 165 refs, 47 operations, 0 defects |
| **Byte-identity vs `00/db/schema.sql`** (tables, types, views) | ✅ **Pass** — 37 shared objects, 0 differences; the platform's `ALTER TABLE vision.*` statements correctly excluded |
| `schema.sql` static checks (balance, FK targets) | ✅ **Pass** |
| `seed_demo.sql` arithmetic vs SRS-02 Appendix A | ✅ **Pass** — 12,430/382/3.0732 %; 7-day 2.5947 % → +18.4 %; MC 157 = 41.1 %; L3 2,147/125 = 5.822 %; z = 3.096, p = 0.00196; per-shift defect sums equal shift NG for all 12 cells |
| `docker-compose.yml` YAML; env coverage | ✅ **Pass** — 18 services; 15/15 variables |
| SRS-02 requirement coverage; cited objects and endpoints; links | ✅ see below |
| **`schema.sql` / `seed_demo.sql` executed against PostgreSQL** | ⚠️ **Not verified** — Docker daemon not running on the authoring machine |

**To complete the database verification**, start Docker Desktop and run:

```bash
cd 02-production-ai-analyst
docker run --rm -e POSTGRES_PASSWORD=x -v "$PWD/db:/db" pgvector/pgvector:pg16 \
  bash -c "docker-entrypoint.sh postgres & sleep 10; \
           psql -U postgres -v ON_ERROR_STOP=1 -f /db/schema.sql && \
           psql -U postgres -v ON_ERROR_STOP=1 -f /db/seed_demo.sql"
```

Success is zero errors and the seed's `\echo` queries returning the values in [TEST-02 §3.1](docs/TEST-ShiftBrief-Test-Plan.md): 180/900 rows · 0 mismatched cells · 12,430/382/3.0732 · 2.5947/+18.4 · L3 2,147/125 · MC 157 · 08-20 NG 313 · 3 batches, 6 quarantined · 6 facts rows with matching hashes · 6 briefs, 1 withheld, 1 revision.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| DDL not executed against a live PostgreSQL | Above |
| **SRS-02 Appendix A is internally inconsistent**: "Line 3 — 5.82 % (n = 2,140)" admits no integer NG count. The seed uses n = 2,147 (125 NG = 5.822 %). The SRS was not edited; a correction to n = 2,147 is recommended | DDS-02 §10, TEST-02 §3.1 |
| Appendix A's p = 0.004 is illustrative; the seed's exact two-proportion test gives p = 0.002. Tests assert p < 0.01 | TEST-02 §3.1 |
| ShiftBrief validates a file's consistency, not its truth — a plausible false file is accepted | SEC-02 RR-S01, UM-02 A2 |
| Email intake is an internet-facing input path | SEC-02 RR-S02 |
| Text-to-SQL is a model composing executable code; off by default with two gates | SEC-02 RR-S03 |
| OEE performance component omitted (no validated ideal cycle time) | SAD-02 §10 |
| Golden brief set, sample-file corpus, SQL question set and injection corpora must be built before the release gates can run | TEST-02 §3 |
| `analytics.*` (8 tables, 6 views) not yet in the platform schema; back-port when adopted | DDS-02 §12 |

---

*ShiftBrief · v1.0 draft · 2026-09-12 · Suphot N.*
