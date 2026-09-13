# OpsPilot — Local AI Operations Agent — Documentation Set

"Check why the backend is down" → evidence from typed, read-only tools → a diagnosis with confidence and cited evidence → at most one proposed action from a whitelist of nine → **a human approves** → the action runs → a read tool verifies → everything is in an append-only audit log. Driven from Discord and a web console, powered by a local LLM that is treated as untrusted.

**A separate deployment.** OpsPilot has **no integration surface** with FactoryBrain ([SAD-00 §13](../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md), [DDS-00 §12.3](../00-factorybrain-platform/docs/DDS-FactoryBrain-Database-Design.md)): no shared schema, no shared tool registry. A FactoryBrain stack is a *target* it may observe and restart — a customer, not a host.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts, no implementation yet.

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-04 | [Software Requirements Specification](SRS-OpsPilot-Local-AI-Operations-Agent.md) | *What must it do?* | Everyone — start here |
| SAD-04 | [Software Architecture Document](docs/SAD-OpsPilot-Software-Architecture.md) | *How is a policy engine with an LLM attached built so the LLM cannot hurt anything?* | Implementer, security reviewer |
| DDS-04 | [Database Design Specification](docs/DDS-OpsPilot-Database-Design.md) | *What is recorded, and which constraints hold the gate?* | Implementer, DBA |
| API-04 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The approval and verification contracts* | Bot/console developer |
| ICD-04 | [Interface Control Document](docs/ICD-OpsPilot-Interface-Control.md) | *Exactly which Docker endpoints, which DB role, which SSH command — and nothing more* | Owner, security reviewer |
| SEC-04 | [Security Requirements Specification](docs/SEC-OpsPilot-Security-Requirements.md) | *What if the model is adversarial? What if a log tells it to delete the database?* | Security reviewer |
| TEST-04 | [Test Plan and Test Cases](docs/TEST-OpsPilot-Test-Plan.md) | *How do we know nothing changes without approval?* | QA |
| OPS-04 | [Deployment and Operations Guide](docs/OPS-OpsPilot-Deployment-Operations.md) | *Install; onboard a target safely; run it* | Owner, on-call |
| UM-04 | [User Manual and Administrator Guide](docs/UM-OpsPilot-User-Admin-Guide.md) | *Reading a diagnosis; approving; what it will never do* | All users |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`api/openapi.yaml`](api/openapi.yaml) | OpenAPI 3.1 — **38 paths / 43 operations / 20 schemas** | ✅ validator pass; 124 `$ref`s resolve; no orphans; no null-valued keys |
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 — `ops` + `audit`; 19 tables, 6 views, 10 triggers, 17 indexes | ✅ **column parity** with the platform's `agent.*` (0 missing / 0 unexpected); helpers byte-identical to 00; static checks; ⚠️ **not executed** (Docker unavailable) |
| [`db/seed_demo.sql`](db/seed_demo.sql) | One week of operation ending with the Appendix A incident; rows for every AC | ✅ static tallies match the header; `args_hash` recomputed in Python; ⚠️ not executed |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) | The agent stack: 10 services (8 + 2 optional sources) | ✅ **no raw Docker socket anywhere**; all 5 OpsPilot services non-root / read-only / `cap_drop ALL` / no-new-privileges; ports only on `${BIND_ADDR}`; 39/39 env variables both ways |
| [`deploy/target-proxy.compose.yml`](deploy/target-proxy.compose.yml) | The per-target-host socket proxy with the exact flag set | ✅ all 16 "never" flags `0`; socket mounted `:ro`; loopback only |
| [`deploy/policy.yaml.example`](deploy/policy.yaml.example) · [`deploy/schemas/policy.schema.json`](deploy/schemas/policy.schema.json) | Who may approve what, where, how often | ✅ validates; negatives rejected (auto-execute on high; deny-listed name); every action in the registry; every write tool has a policy |
| [`deploy/runbooks/*.yaml`](deploy/runbooks/) · [`deploy/schemas/runbook.schema.json`](deploy/schemas/runbook.schema.json) | `backend-down`, `disk-full`, `db-slow` | ✅ validate; negatives rejected (deny-listed tool; step without a tool); every step tool in the registry |
| [`deploy/.env.example`](deploy/.env.example) | Runtime knobs; no secrets | ✅ secret scan clean |

---

## Reading paths

**Security review** → SAD-04 §1.2 and §4.3.2 (policy engine) → SEC-04 §4.2 (the walk-through: five layers between an injected log line and a target) → ICD-04 IF-25 (the proxy flag table) → DDS-04 Appendix A → TEST-04 TS-3, TS-6, TS-7.

**Implementing it** → SRS-04 → SAD-04 §4.3 (registry, policy engine, loop, redaction, evidence bundle, verification) → DDS-04 → `db/schema.sql` → API-04 §3–4 (approval and verification contracts) → ICD-04 IF-16 (the 20 tools) → TEST-04.

**Running it** → OPS-04 §5 (onboarding a target — the procedure that decides whether this is safe) → `target-proxy.compose.yml` → `policy.yaml.example` → OPS-04 §9 runbooks.

**Using it** → UM-04 A3 (reading a diagnosis), A4 (approving), B8 (what it will never do).

---

## What makes this design what it is

The four platform principles, plus one:

| Principle | On OpsPilot |
|---|---|
| **The LLM never computes** → **the LLM never *claims*** | Every statement cites a tool-call id; a claimed outcome must be a verification result; unbacked claims are withheld (FR-16). Deterministic diagnostics produce the evidence; the model narrates and proposes. |
| **Offline-first** → **local-only, LLM-optional** | With Ollama down, `/diag`, runbooks, sweeps and alerts are unchanged (AC-08). No egress from the model. |
| **Human-in-the-loop** | Every state change is a proposal bound to `args_hash`, expiring in 10 min, approved by the role policy names, executed once, verified after. Auto-execution is opt-in per action per environment and impossible for `high`. |
| **Database is the source of truth** | `ops.*` and `audit.log` record what happened; Discord and the console are views; an incident timeline is reconstructed from the database alone (AC-07). |
| **Tool output is data, never instruction** (P-5) | Logs, files, rows and bodies are untrusted evidence. The model may reason about them; nothing in them can call a tool. Behind the model stand the policy engine, the deny-list in code, and a proxy with `EXEC=0 VOLUMES=0`. |

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | **None as integration** — by design. Patterns reused: typed tools (IF-16), HITL proposals, UUIDv7 helpers (byte-identical), `audit.log` (byte-identical modulo FK), `agent.*` table shapes (column parity). OpsPilot's tools are never registered in the platform's `agent.tool`. A FactoryBrain stack is a **target** (SAD-04 §6). |
| [01 VisionOps](../01-factory-inspector-agent/), [02 ShiftBrief](../02-production-ai-analyst/) | Targets, if deployed — their containers, health endpoints and Postgres (probe role). |
| [03 EdgeGuard](../03-edge-vision-inspection/) | **Never a target**: an edge node's line path is OT (`ot` tag → no write tool). |
| [10 Factory Copilot](../10-factory-copilot/) | Same tool-contract pattern, different registry, different database. They must not share a registry. |

---

## Identifier conventions

`FR-`/`NFR-`/`AI-`/`AC-`/`C-` (SRS-04) · `P-1…P-5` · **`ADR-O01…O10`** · `QAS-01…11` · **`DD-O01…O07`** · `IF-xx` shared numbering (**IF-25 socket proxy, IF-26 host, IF-27 target DB, IF-28 git, IF-29 logs** new) · **`THR-O`/`SEC-O`** · `TS-`/`TC-` · `RB-01…14`.

```
SRS-04 C-02 / C-05 / AC-04  "no shell; destructive permanently denied; volume rm refused even if the model asks"
  └─ SAD-04 ADR-O01 (no shell, ever) · ADR-O04 (proxy allowlist) · ADR-O07 (deny-list in code) · §4.3.2 step 1
      └─ DDS-04 DD-O04 trg_tool_denylist · action_proposal.denied_reason = DENYLISTED, actor policy
          └─ API-04 §3 "cannot create a proposal for a deny-listed tool" · error DENYLISTED
              └─ ICD-04 IF-25 EXEC=0 VOLUMES=0 · IF-16 rule 5 · IF-26 forced command
                  └─ SEC-04 §4.2 five layers · SEC-O01…O05, O31
                      └─ TEST-04 TC-040, TC-042, TC-044, TC-080, TC-094 · seed r3/p3
                          └─ OPS-04 RB-02 · UM-04 A8, B8
```

---

## Verification

| Check | Result |
|---|---|
| **Column parity** `ops.tool / agent_run / tool_call / action_proposal / audit.log` vs 00 `agent.tool / run / tool_call / action_proposal / audit.log` (TC-002) | ✅ **Pass** — 8/8, 17/17, 10/10, 12/12, 12/12 platform columns present; only the declared OpsPilot-only columns extra; only the declared type difference (`outcome` text vs enum) |
| Helper functions byte-identical to 00 lines 59–104; `audit.log` identical modulo FK target (TC-008) | ✅ **Pass** |
| `schema.sql` static (balance, FK targets, object counts, guard triggers present) (TC-003) | ✅ **Pass** — 19 tables, 6 views, 10 triggers, 17 indexes, 11 functions |
| Seed tallies vs header; `args_hash(p1)` recomputed from jsonb canonical text; statuses/reasons; AC-05 run has 0 proposals (TC-005) | ✅ **Pass** — 21 runs, 50 tool calls, 7 proposals (4 executed / 3 denied), hash `07c98103…375d` |
| `openapi.yaml` (TC-001) | ✅ **Pass** — 38 paths / 43 ops / 20 schemas; 0 orphans; 0 null keys |
| Compose least-privilege and env coverage (TC-004) | ✅ **Pass** — no `docker.sock`; hardening flags on all five services; ports on `${BIND_ADDR}` only; 39/39 variables both ways; target proxy never-flags all `0` |
| Policy and runbooks vs JSON Schemas, incl. negatives; registry cross-checks (TC-006) | ✅ **Pass** |
| Secret scan (TC-007) | ✅ **Pass** (one false positive: a secret *file path* in a compose mount) |
| SRS-04 coverage; cited tables/views/endpoints/TCs/RBs/ADRs/SEC-Os; links | ✅ see sweep note below |
| **`schema.sql` / `seed_demo.sql` executed on PostgreSQL** (TC-009) | ⚠️ **Not verified** — Docker daemon unavailable on the authoring machine |

To complete the database verification:
```bash
cd 04-local-ai-ops-agent
docker run --rm -e POSTGRES_PASSWORD=x -v "$PWD/db:/db" postgres:16-alpine \
  bash -c "docker-entrypoint.sh postgres & sleep 8; \
           psql -U postgres -v ON_ERROR_STOP=1 -f /db/schema.sql && \
           psql -U postgres -f /db/seed_demo.sql"
```
Success: zero errors in the schema, the seed's `\echo` values (header of `seed_demo.sql`), `hash_consistent = t`, and **four** probe statements failing at the end (deny-listed name, illegal transition, audit update, auto-execute on high).

**Defects found while writing and checking** (all fixed; TEST-04 §4): `denied` proposals inserted without a reason the CHECK requires; unquoted `{id}` inside `text[]` literals; header tallies off by one run and five tool calls; the timeline view dropping the approval event of executed proposals; three unquoted commas/colons in the OpenAPI YAML.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| DDL and seed not executed against PostgreSQL | Above |
| The socket proxy cannot scope to individual containers; `targets_allow` and tags narrow at policy level only | SEC-04 §8, ICD-04 IF-25 |
| `scale_service` and `redeploy_last_good` need `POST /containers/create` — the widest proxy capability | ICD-04 IF-25 (hence `medium`, admin, disable-able) |
| Restarting a non-containerised systemd service is not a v1 tool (FR-06 is read-only) | ICD-04 IF-26 |
| `scale_service` is Compose-only; Swarm needs `SERVICES=1` | SAD-04 §9 |
| Corpora (30 incidents, ≥ 50 injections, ≥ 100 secret formats) must be built before the release gates can run | TEST-04 TS-7, TS-10 |
| The agent host and targets on one machine share host-compromise risk | OPS-04 §2, SEC-04 §8 |
| `opsctl` CLI is specified by its commands only | OPS-04, UM-04 |
