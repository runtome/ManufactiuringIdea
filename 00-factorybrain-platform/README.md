# FactoryBrain AI Platform — Documentation Set

On-premise manufacturing intelligence platform: computer-vision inspection, production analytics, quality engineering (SPC / RCA / FMEA) and a grounded LLM agent layer, unified on one data platform.

FactoryBrain is the **integration target** for the 15 sibling projects in this repository. Each sibling ships independently; FactoryBrain defines the contracts — schema, API, interfaces, security posture — that let them compose.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts, no implementation yet.

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-00 | [Software Requirements Specification](SRS-FactoryBrain-AI-Platform.md) | *What must it do?* | Everyone — start here |
| SAD-00 | [Software Architecture Document](docs/SAD-FactoryBrain-Software-Architecture.md) | *How is it built, and why that way?* | Implementer, architect |
| DDS-00 | [Database Design Specification](docs/DDS-FactoryBrain-Database-Design.md) | *How is the data modelled?* | Implementer, DBA |
| API-00 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *How do I call it?* | Client developer, integrator |
| ICD-00 | [Interface Control Document](docs/ICD-FactoryBrain-Interface-Control.md) | *How does it meet the outside world?* | Integrator, controls engineer |
| SEC-00 | [Security Requirements Specification](docs/SEC-FactoryBrain-Security-Requirements.md) | *What are the threats and controls?* | Security reviewer, auditor |
| TEST-00 | [Test Plan and Test Cases](docs/TEST-FactoryBrain-Test-Plan.md) | *How do we know it works?* | QA, implementer |
| OPS-00 | [Deployment and Operations Guide](docs/OPS-FactoryBrain-Deployment-Operations.md) | *How do I run it?* | Administrator, on-call |
| UM-00 | [User Manual and Administrator Guide](docs/UM-FactoryBrain-User-Admin-Guide.md) | *How do I use it?* | All users, administrators |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`api/openapi.yaml`](api/openapi.yaml) | OpenAPI 3.1 — 58 paths, 62 operations, 58 schemas | ✅ Passes `openapi-spec-validator`; all `$ref`s resolve; no duplicate `operationId` |
| [`db/schema.sql`](db/schema.sql) | Full DDL — 9 schemas, ~60 tables, partitioning, HNSW indexes, roles and grants | ⚠️ Not executed (Docker daemon unavailable) — see [Verification](#verification) |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Deterministic 30-day dataset with a planted anomaly | ⚠️ Not executed |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) | Reference stack — 17 services | ✅ Parses as valid YAML |
| [`deploy/.env.example`](deploy/.env.example) | Every configuration variable with defaults and guidance | — |

---

## Reading paths

**Implementing it** → SRS §1–4 → SAD (all) → DDS + `schema.sql` → `openapi.yaml` → TEST §6 for the suite you are building against.

**Reviewing the design** → SRS §1–2 → SAD §2 principles, §7 ADRs, §10 risks → SEC §4 threat model → TEST §5 gates. The ADRs and the residual-risk register are where the arguable decisions live.

**Integrating a system** → ICD (find your `IF-xx`) → `openapi.yaml` → API Specification §4 idempotency and §7 errors.

**Auditing it** → SEC (all, especially §9 residual risks) → DDS §13 access control and §17 privacy → TEST §9 traceability → OPS §6.4 restore drill.

**Operating it** → OPS §3 install → OPS §8 runbooks → UM Part B.

**Using it** → UM Part A. If you read only one section, read [A6 — Using the AI assistant](docs/UM-FactoryBrain-User-Admin-Guide.md#a6-using-the-ai-assistant).

---

## The four principles

These appear in every document because they explain most of the decisions in all of them.

| | Principle | Consequence |
|---|---|---|
| **P-1** | **The LLM never computes numbers** | Statistics come from code. The model writes prose around a structured facts object. A deterministic post-check verifies every numeric token against tool results; an ungrounded answer is **withheld**, not flagged. |
| **P-2** | **Offline-first** | Edge nodes inspect and buffer for ≥ 72 h without the server. The server runs without the internet. Nothing on the critical path depends on a cloud call. |
| **P-3** | **Human-in-the-loop for consequences** | AI drafts, proposes and ranks. A named person approves anything that changes a verdict, a record of decision, a machine or an ERP transaction. |
| **P-4** | **The database is the single source of truth** | No authoritative state in memory, files or a context window. Every derived artifact is rebuildable. |

A fifth rule shapes sizing rather than correctness: **the 8 GB GPU is an architectural constraint, not a deployment detail.** It drives model selection, process separation and the GPU semaphore.

---

## Identifier conventions

| Prefix | Meaning | Defined in |
|---|---|---|
| `FR-*`, `NFR-*`, `AI-*`, `AC-*`, `C-*` | Functional / non-functional / ML / acceptance / constraint | SRS |
| `P-1…P-4` | Architecture principles | SAD §2 |
| `ADR-xxx` | Architecture decision record | SAD §7 |
| `QAS-xx` | Quality attribute scenario | SAD §8 |
| `DD-xx` | Data design decision | DDS §2 |
| `IF-xx` | External interface | ICD |
| `THR-xx` / `SEC-xxx` / `RR-xx` | Threat / security requirement / residual risk | SEC |
| `TS-x` / `TC-xxx` | Test suite / test case | TEST |
| `RB-xx` | Operational runbook | OPS §8 |

**Traceability flow.** Every SRS requirement reaches at least one test case:

```
SRS FR-A-02  "every numeric claim traceable"
   └─ SAD  ADR-013 grounding post-check · §4.3.1 enforcement point
        └─ DDS  agent.run.grounding_json · agent.v_grounding_health
             └─ API  §5 grounding contract · 422 GROUNDING_FAILED
                  └─ SEC  SEC-230 · THR-27 fabricated statistics
                       └─ TEST TC-041…TC-044 (zero-fabrication release gate)
                            └─ OPS  RB-09 grounding failure spike
                                 └─ UM   A6 "what you must understand"
```

---

## Sibling projects

FactoryBrain owns each sibling's **integration surface** — schema written, endpoints called, interfaces spoken. Internal behaviour stays in the sibling's own SRS.

| Coupling | Projects |
|---|---|
| **Tight** (shared schema, one transaction boundary) | [01 VisionOps](../01-factory-inspector-agent/) · [02 ShiftBrief](../02-production-ai-analyst/) · [06 MachineSense](../06-predictive-maintenance-agent/) · [09 QE-Agent](../09-quality-engineer-agent/) · [10 Factory Copilot](../10-factory-copilot/) · [13 KaizenSwarm](../13-multi-agent-factory/) · [15 Genba Memory](../15-troubleshooting-memory/) |
| **Loose** (separate device, async idempotent sync) | [03 EdgeGuard](../03-edge-vision-inspection/) · [05 PocketQC](../05-offline-mobile-inspector/) |
| **Medium** | [08 DocFlow](../08-document-erp-agent/) · [11 MoldMind](../11-injection-molding-ai/) · [14 GenbaGo](../14-japanese-factory-translator/) |
| **None** — separate deployments | [04 OpsPilot](../04-local-ai-ops-agent/) · [07 PawTrace](../07-ai-dog-finder/) · [12 GAPFarm AI](../12-gapfarm-ai-agent/) |

The last row is stated explicitly rather than left implicit. Those three reuse the platform's *patterns* — typed tools, HITL gating, offline-first, pgvector retrieval — but their integration surface with FactoryBrain is empty. Wiring agricultural scouting records or infrastructure-control tools into a factory quality database would be a design error. See [SAD §6](docs/SAD-FactoryBrain-Software-Architecture.md) and [DDS §3.1](docs/DDS-FactoryBrain-Database-Design.md).

---

## Verification

What was actually checked when these documents were written, and what was not.

| Check | Result |
|---|---|
| `openapi.yaml` against the OpenAPI 3.1 schema | ✅ **Pass** — `openapi-spec-validator` |
| `$ref` resolution | ✅ **Pass** — 0 broken, 0 orphan schemas |
| `operationId` uniqueness and response coverage | ✅ **Pass** — 62 operations, 0 duplicates, 0 without responses |
| Every SRS requirement ID referenced by a companion document | ✅ **Pass** — 65 of 65 |
| Database objects and endpoints cited in prose exist in the artifacts | ✅ **Pass** — 2 gaps found and fixed |
| `docker-compose.yml` YAML validity | ✅ **Pass** — 17 services, 12 volumes |
| `schema.sql` execution against PostgreSQL | ⚠️ **Not verified** — Docker daemon not running on the authoring machine |
| `seed_demo.sql` execution and its verification queries | ⚠️ **Not verified** — same reason |
| Cross-document identifier consistency | ✅ **Pass** |
| Relative link resolution | ✅ **Pass** |

**To complete the database verification**, start Docker Desktop and run:

```bash
cd 00-factorybrain-platform
docker run --rm -e POSTGRES_PASSWORD=x -v "$PWD/db:/db" pgvector/pgvector:pg16 \
  bash -c "docker-entrypoint.sh postgres & sleep 10; \
           psql -U postgres -v ON_ERROR_STOP=1 -f /db/schema.sql && \
           psql -U postgres -v ON_ERROR_STOP=1 -f /db/seed_demo.sql"
```

Success is both files applying with zero errors and the seed's `\echo` verification queries returning: 180 production rows · defect totals equal to `qty_ng` · 183 PASS / 12 FAIL / 5 REVIEW · 5 in the review queue · 1 citable case.

TimescaleDB statements are guarded, so the schema applies on plain `pgvector/pgvector:pg16`.

---

## Known gaps and open decisions

Stated here rather than buried, because a document set that claims completeness it does not have is worse than one that admits its edges.

| Gap | Where it is discussed |
|---|---|
| `schema.sql` has not been executed against a live PostgreSQL instance | Above |
| Single 8 GB GPU is the platform's binding bottleneck | SAD AR-01 |
| Modbus (IF-06) has no authentication or encryption — accepted risk, mitigated only by network isolation | SEC RR-01 |
| Grounding catches fabricated *numbers*, not flawed *reasoning* | SEC RR-05, UM A6 |
| No SSO / external identity provider in v1 | SAD ADR-009, SEC RR-07 |
| Continuous aggregates require TimescaleDB; otherwise scheduled materialised-view refreshes | SAD ADR-007, DDS §7.3 |
| Row-level security deferred in favour of tool-layer predicates | DDS §13.2 |
| Text-to-SQL behind a feature flag until it passes its own evaluation gate | SAD ADR-005 |
| Golden Q&A set, vision hold-out and incident set must be built before the release gates can run | TEST §4 |

---

*FactoryBrain AI Platform · v1.0 draft · 2026-09-10 · Suphot N.*
