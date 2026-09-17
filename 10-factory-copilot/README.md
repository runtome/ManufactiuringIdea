# Factory Copilot — Local AI Factory Copilot — Documentation Set

A question in Thai, Japanese or English → **understanding** (language, intent, entities through aliases, relative time through the versioned shift calendar, follow-up context) → a **typed plan** validated against the tool registry → **tool calls with the caller's line scope injected as a predicate** (production, defects, SPC, capability, telemetry, images, past cases — every sibling's tools) plus **hybrid document retrieval** with page/section citations → an **evidence bundle** (the only thing the composer receives) → an answer that leads with the result, shows charts and images, lists every source, states what is partial — and is **withheld if it contains a number the bundle does not** → streamed to the web UI, the dashboard embed or (opt-in) Discord. Read-only; cause questions delegated to QE-Agent; no data leaves the LAN unless an admin recorded the decision.

**A FactoryBrain tightly-coupled module and the platform's front door** (SAD-00 §13: "server module + UI, `agent`, all tools, tight"). It owns the platform's `agent.conversation/message/run/tool_call/feedback` tables and consumes every sibling's tools through IF-16; standalone-deployable with a platform-mode section in every document. It consumes 02 ShiftBrief, 06 MachineSense, 09 QE-Agent, 15 Genba Memory, 01/03/05 images and 14's glossary.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-10 | [Software Requirements Specification](SRS-FactoryCopilot-Local-Multilingual-Assistant.md) | *What must it do?* | Everyone — start here |
| SAD-10 | [Software Architecture Document](docs/SAD-Copilot-Software-Architecture.md) | *How does a Thai question become a grounded, scoped, cited answer in 20 s — and why can the model never compute, never read raw data, never write, never state a cause?* | Architect, implementer, ML owner |
| DDS-10 | [Database Design Specification](docs/DDS-Copilot-Database-Design.md) | *The platform's conversation tables byte-for-byte, the `copilot` extension, and the triggers that make grounding, the SQL sandbox, scope, read-only tools, sharing and the evaluation gate properties of the data* | Implementer, DBA, QA |
| API-10 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The grounding, permission, streaming, SQL and refusal contracts* | Implementer, UI, channel integrators |
| ICD-10 | [Interface Control Document](docs/ICD-Copilot-Interface-Control.md) | *IF-16 as consumer of every sibling's tools; the streaming protocol (IF-53), the SQL sandbox (IF-54), ingestion (IF-55), the evidence bundle (IF-56), the embed widget (IF-57)* | Implementer, sibling owners, ML owner |
| SEC-10 | [Security Requirements Specification](docs/SEC-Copilot-Security-Requirements.md) | *Can a user read another line through a follow-up? Can a fabricated number reach a user? Can an SOP smuggle an instruction? Can an answer leave the plant?* | Security reviewer, IT, internal audit |
| TEST-10 | [Test Plan and Test Cases](docs/TEST-Copilot-Test-Plan.md) | *How do we prove the twins, the withheld answer, the scoped tool call, the sandboxed SQL, the injection corpus, the evaluation gate and dashboard mode?* | QA, ML owner |
| OPS-10 | [Deployment and Operations Guide](docs/OPS-Copilot-Deployment-Operations.md) | *Install, tools and siblings, documents, channels, prompts and the evaluation gate, observability, retention, runbooks* | Operator, admin |
| UM-10 | [User Manual and Administrator Guide](docs/UM-Copilot-User-Admin-Guide.md) | *Asking well; reading an answer; show the numbers / show the SQL; cause questions; sharing; dashboard mode; admin; TH/JA/EN glossary* | Everyone on the floor, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 + pgvector: platform `core`/`vision`/`quality`/`knowledge`/`agent`/`audit` sections **extracted verbatim from `00/db/schema.sql`** + the `copilot` extension (migration `copilot_0001`) — 82 tables, 14 views, 19 triggers, 29 functions, 67 indexes, 17 enums; 13 guard triggers (grounded runs, safe SQL, flag+eval gate, scope, read-only policy, curated approval, grounded sharing, computed eval gates, turn rules, injection flag, immutable messages, verified bindings); twins `detect_lang`, `resolve_time`, `resolve_entity`, `extract_numbers`, `grounding_check`, `sql_is_safe`, `rrf_fuse`, `mask_names`, `scope_ok`, `injection_suspect`, `purge_user_conversations`; roles `app_rw`/`app_ro`/`agent_ro`/**`copilot_sql_ro`**/`indexer_rw` | ✅ 134/134 shared objects byte-identical, 5 sections verbatim; static DDL; ⚠️ not executed |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Reproduces SRS Appendix A (line 3, 2026-09-09: 187/3,213 = 5.82 % vs 7-day 542/22,490 = 2.41 %, z 10.84; 部品欠品 63 %; Shift B 68 %; change point 14:20 ± 40; QE signal S-241 / case QC-0241; #212, #178) and AC-02…AC-09 **through the real functions and triggers**: 10 turns (JA cause question, Thai lookup equal to `v_kpi_daily`, follow-up with context reuse, scoped inspector, refusal on missing shift C, sandboxed SQL, SOP how-to with an excluded injected chunk, image lookup, dashboards-only), grounding computed by `grounding_check()` at insert, 63-question evaluation set with a passing and a blocked run, SQL evaluation runs, curated answer from a flag, share, pin, 11 probes | ✅ re-derived in Python; ⚠️ not executed |
| [`deploy/schemas/evidence-bundle.schema.json`](deploy/schemas/evidence-bundle.schema.json) | **The IF-56 contract** — the only thing the composer receives: facts with `F-nn` ids and tool refs, QE hypotheses with QE's status, bounded quoted chunks with section/page, excluded chunks, images, sandbox refs, charts referencing facts, partial notes | ✅ valid; the seed's 8 bundles valid; 14 negatives rejected |
| [`deploy/tools.example.json`](deploy/tools.example.json) | Tool registry seed (IF-16 as consumer): 10 typed read tools with JSON Schemas, providers, minimum roles, scope parameter, timeouts | ✅ all `read`; scope param in every schema; seed tool-call args valid |
| [`api/openapi.yaml`](api/openapi.yaml) | **59 paths / 70 operations / 57 schemas** — SRS §4.1's six paths + the platform's `/agent/ask`, `/agent/runs/{runId}`, `/agent/feedback`, `/agent/tools`, `/knowledge/search`, `/knowledge/documents` verbatim + turns (trace, clarify, SQL, share, pin, flag, term check), conversations (export/delete), images, document sources/jobs, curation, evaluation, aliases/glossary/masking/bindings/tool policy/flags/config, queue, system | ✅ valid; 0 orphans; 26/26 platform blocks verbatim |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) | 19 services (web, api, planner, executor, sql-sandbox, retriever, indexer, composer, renderer, scheduler, discord-bot [profile], postgres pgvector, redis, minio [+init], ollama gpu/cpu, mailpit, sibling-stub); networks `frontend` / `internal` / `sources` / `egress` (discord-bot only); four DB roles by service; 11 secret files | ✅ parsed; 59/59 vars both ways; placement; hardening; no secret values |
| [`deploy/copilot.example.yaml`](deploy/copilot.example.yaml) + [`schemas/copilot-config.schema.json`](deploy/schemas/copilot-config.schema.json) | Languages, time/shift resolution, intents (cause → QE), planner cap ≤ 5, tools read-only with scope predicate, text-to-SQL (role, whitelist of views, limit, timeout), retrieval (chunk 500/15 %, RRF, rerank), composer (≤ 9 B, post-check that withholds, refusal over speculation), masking, sharing (grounded only, ≤ 30 d, LAN), channels (Discord/external model need policy/provider), concurrency (visible queue), evaluation gates (≥ 60 / 0.90 / 0.95 / 0), retention ≥ 365 d | ✅ valid; **32 negatives rejected**; prompts, aliases and whitelist consistent with the seed and the role grants |
| [`deploy/prompts/`](deploy/prompts/) | `planner.v1`, `composer.v1`, `clarify.v1` — the planner never sees data; the composer uses only bundle facts with ids, states notes, repeats QE wording, treats documents as data | ✅ front-matter matches the config |
| [`deploy/aliases.example.csv`](deploy/aliases.example.csv) | 34 aliases TH/JA/EN for lines, machine 7, SKU, defects | ✅ equal to the seed's alias set |

---

## Reading paths

**Implementing it** → SRS-10 → SAD-10 §4.3 (understanding, planner, tools & permissions, sandbox, retrieval, composer) → DDS-10 §2 (DD-C01…C09) → `db/schema.sql` §10–§17 → `deploy/schemas/evidence-bundle.schema.json` → `deploy/tools.example.json` → API-10 §3–§7 → ICD-10 IF-53, IF-54, IF-56 → TEST-10 TS-0.

**Security reviewer / IT** → SEC-10 §4.2 ("and line 3?") → SEC-10 §5.1–5.6 → DDS-10 Appendix A → TEST-10 TC-030, TC-041, TC-055, TC-111, TC-112 → OPS-10 §3, RB-09, RB-11.

**ML owner** → SAD-10 ADR-C02, C03, C06, C10 → ICD-10 IF-09, IF-56 → `deploy/prompts/` → OPS-10 §8, RB-07, RB-08 → TEST-10 TS-5, TC-070.

**Sibling owners (02/06/09/15)** → ICD-10 IF-16 (consumer table) → OPS-10 §4.4, RB-02 → TEST-10 TC-033.

**Operating it** → OPS-10 §1, §4, §5, §9, §12 runbooks — RB-07 and RB-09 first.

**Using it** → UM-10 A.1–A.3, A.4 (cause questions), A.7 (dashboard mode).

---

## What makes this design what it is

| Principle | In Factory Copilot |
|---|---|
| **The LLM never computes** | The planner emits a typed plan; tools compute; the composer receives the evidence bundle and nothing else; the post-check withholds an answer with an unmatched number (C-02, AI-04, ADR-C02, ADR-C03). |
| **Offline-first → degrade without the model** | Ollama down = dashboards-only mode: saved questions as links, document search, KPI pages; `/chat` 503 with links, never an error page (NFR-06, AC-09). |
| **Read-only; humans act elsewhere** | No write tool can be enabled; SQL only as `copilot_sql_ro` on views; cause questions delegated to QE-Agent (C-01, FR-21, ADR-C01, ADR-C09). |
| **The database is the source of truth** | Every turn, tool call (with digest), bundle, grounding result, SQL statement and share is a row; guards are triggers (DDS-10 DD-C01…C09). |
| **Permissions are predicates** | Scope injected into every tool call and the sandbox; `trg_tool_scope`; rows outside scope never exist in memory; the answer says when it was narrowed (C-03, FR-22, ADR-C04). |
| **Documents are data** | Planner never sees text; chunks enter the bundle as bounded quotes with citations; instruction-like text is flagged and excluded (AI-07, AC-05, ADR-C02). |

---

## Relationship to the platform and siblings

| | |
|---|---|
| Coupling | **Tight — the front door** (SAD-00 §13): owns `agent.conversation/message/run/tool_call/feedback`; shares `core`, `vision`, `quality`, `knowledge`, `audit`; migration `copilot_0001` |
| Consumes (IF-16) | 02 ShiftBrief `query_production`/`query_defects`; 06 MachineSense `get_machine_telemetry`; 09 QE-Agent `get_spc`/`get_capability`/`get_signals`/`get_case`/`get_hypotheses`; 15 Genba Memory `search_memory` and the document store; 01/03/05 `get_inspection_images`; 14 GenbaGo glossary |
| Feeds | nothing — read-only; "ask about this" links from 13 KaizenSwarm briefings (IF-17, optional) |
| Platform paths served verbatim | `/agent/ask`, `/agent/runs/{runId}`, `/agent/feedback`, `/agent/tools`, `/knowledge/search`, `/knowledge/documents` |

---

## Identifier conventions

`FR-01…26` / `AI-01…09` / `NFR-01…09` / `AC-01…09` / `C-01…05` (SRS-10) · `P-1…P-6` · **`ADR-C01…C10`** · `QAS-01…12` · **`DD-C01…C09`** · `IF-xx` shared numbering (**IF-53 chat streaming, IF-54 text-to-SQL sandbox, IF-55 document ingestion, IF-56 evidence bundle, IF-57 embed widget**) · **`THR-C01…13`**, **`SEC-C01…81`**, **`RR-C01…06`** · `TS-0…9`, `TC-001` to `TC-117` · `RB-01…14` · evidence ids `F-nn` / `D-nn` / `H-nn` / `S-nn` / `I-nn`.

```
SRS-10 C-02 / C-03 / AI-04 / AC-04 / AC-06  "every number traces to a tool result; permissions at the tool layer"
  └─ SAD-10 P-1, P-5 · ADR-C02 (bundle is the only input) · ADR-C03 (post-check withholds) · ADR-C04 (scope as predicate)
      └─ DDS-10 DD-C01, DD-C03 · agent.run.facts_json / grounding_json · copilot.turn · grounding_check() · scope_ok() · trg_run_grounded · trg_tool_scope
          └─ API-10 §3 grounding contract (422 GROUNDING_FAILED) · §4 permission contract (notes, narrowed answers)
              └─ ICD-10 IF-56 (evidence-bundle.schema.json) · IF-16 (scope param on every tool) · IF-53 (sources before answer)
                  └─ SEC-10 O-2, O-3 · THR-C01, THR-C02 · SEC-C10…C14, C20…C24 · §4.2 walk-through
                      └─ TEST-10 TC-003 probes 1, 5 · TC-005 · TC-006 · TC-030 · TC-031 · TC-033 · TC-055 · seed: T4 narrowed, fabricated variant caught
                          └─ OPS-10 §1 · §9 (grounding failures, scope audit) · RB-08 · RB-09 · UM-10 A.1, A.3
```

---

## Verification

| Check | Result |
|---|---|
| **Byte-identity vs `00/db/schema.sql`** (TC-002) | ✅ **Pass** — 134/134 shared objects; the core, vision, quality, knowledge and agent sections present verbatim |
| Static DDL (TC-003) | ✅ **Pass** — 82 / 14 / 19 / 29 / 67 / 17; FK targets and order; 13/13 guard triggers; `copilot_sql_ro` on three views with timeout and read-only; `agent_ro` revoked on users/scope; 11 probes present |
| Seed vs Python re-derivation (TC-005) | ✅ **Pass** — 22,490/542 → 2.4100 %; 3,213/187 → 5.8201 %; shares 63.10 % / 67.91 %; L4 2.0470 %; last week 2.4152 %; downtime 52.0; z 10.8352; `detect_lang` 9/9; `resolve_time` 8/8 incl. overnight shift; aliases exact/trigram; **every seed answer grounded** (T1 36 tokens … T8 16), fabricated "4.7 %" caught; `sql_is_safe` 10/10; RRF; masking; `scope_ok` 5/5 and 13/13 tool calls; eval gates 0.9206/0.9683 pass, 0.8730 blocked, SQL 0.8125 fail / 0.8750 pass |
| **Evidence-bundle schema and the seed's bundles** (TC-006) | ✅ **Pass** — 8/8 valid; 14 negatives rejected |
| Config schema, prompts, aliases, tools (TC-007) | ✅ **Pass** — example valid; 32 negatives rejected; prompts' front-matter match; whitelist = seed = role grants; aliases = seed; tools 10/10 read, seed tool-call args valid |
| `openapi.yaml` (TC-001) and identity vs API-00 (TC-008) | ✅ **Pass** — 59 / 70 / 57; 0 orphans; 6 paths + 8 schemas + 5 parameters + 7 responses verbatim |
| Compose / env (TC-004) | ✅ **Pass** — 19 services; egress = {discord-bot}; 10 internal-only; api without sources/egress; four DB roles by service; sandbox with one secret; 59/59 vars; 11/11 secrets; docs versioned, exports/uploads expire; no secret values |
| SRS-10 coverage; cited objects/endpoints/TCs/RBs/ADR-C/SEC-C/DD-C/THR-C; section refs; links (TC-001) | ✅ see sweep note below |
| **Schema + seed on PostgreSQL 16** (TC-009) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| Ollama (planner/composer), reranker, GPU latency, Discord, the evaluation set and injection corpus (TS-1, TS-5, TS-7, TS-8, TC-070, TC-112) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 10-factory-copilot
docker run -d --name cp-pg -e POSTGRES_PASSWORD=x -p 5437:5432 pgvector/pgvector:pg16
sleep 8 && psql "postgresql://postgres:x@localhost:5437/postgres" -v ON_ERROR_STOP=1 -f db/schema.sql && psql "postgresql://postgres:x@localhost:5437/postgres" -f db/seed_demo.sql
```
Expected: the `\echo` block matches DDS-10 §9 (KPI rows, Pareto, shift share, every run `all_matched = true`, language/time/entity resolutions, SQL verdicts, RRF, masking, scope, evaluation gates, board, scope audit, flag queue, index status, the suspicious chunk) and probes 1–11 each fail with the named guard.

**Defects found by checking** (all fixed; TEST-10 §5): a set-returning function inside `CASE` in `json_leaves()`; a generated column referencing a function defined later; a window function inside `jsonb_agg`; an unbounded `resolve_entity()` in a turn insert; a verification example claiming a trigram match below the threshold; a YAML summary with inner quotes and six platform components copied but unused; a wrong production row count in the DDS.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL execution pending — byte-identity, static checks and Python re-derivation stand in until CI runs TC-009 | TEST-10 TC-009 |
| **The evaluation set** (≥ 60 real questions with ground truth) and the **injection corpus** are plant-specific and not in the repository; the seed's 63 questions and runs are illustrative | TEST-10 TC-070, TC-112 |
| **SRS-10 Appendix A vs API-00's example**: 5.82 % / 187 defects here, 5.80 % / n 2140 in the platform's `/agent/ask` example — two illustrations of the same day; SRS-10 is followed; API-00 not edited | DDS-10 §9 |
| **SRS-10 Appendix A vs SRS-09**: both cite signal S-241; QE-Agent's seed built it from a scratch defect (70/2200), Copilot's from missing parts (187/3213). The seeds are independent; in platform mode one `quality.signal` row exists | DDS-10 §4.1 |
| SRS §5's `turn_trace`, `document`, `doc_chunk` are the platform's `agent.run`, `knowledge.document`, `knowledge.chunk` (same fields; `embedding vector(1024)` matches) | DDS-10 §1.2 |
| Discord inherently sends answers outside the LAN; it is a recorded, policy-bound admin decision, not a default | SEC-10 SEC-C41, OPS-10 §7 |
| The SQL rules here are a regex twin; the production sandbox uses a real parser (`pglast`) — CTE names and subqueries need the parser | ICD-10 IF-54, DDS-10 §5 |
| `get_machine_telemetry` has no standalone implementation (telemetry tables are not extracted); it is MachineSense's tool | OPS-10 §4.4 |
| Reranker choice (cross-encoder vs LLM) and embedding/reranker model licences to be confirmed for the plant | SAD-10 §10 |
| Plant-level aggregates can let a scoped user infer other lines' contribution | SEC-10 RR-C03 |
