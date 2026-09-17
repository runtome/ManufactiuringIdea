# QE-Agent — AI Manufacturing Quality Engineer Agent — Documentation Set

Inspection, production, telemetry, lot, maintenance and parameter data → **SPC engine** (X̄-R, X-mR, p, np, c, u; Nelson rules; capability with a normality check; limits with history) → **signal detector** (rates vs 7/30-day baselines with a two-proportion test; change points; ranking; suppression) → **correlator** (lot, machine, mould, shift, operator group, SKU, parameter change, ambient — with effect sizes and a multiple-comparison correction; timeline; past cases) → a **ranked hypothesis list** with supporting evidence, contra evidence and a verification step → drafts of the **5-Why, 8D, FMEA rows and the 品質報告書** in TH/JA/EN → a **named engineer verifies, edits, confirms ratings, approves and exports**. Every number in a draft carries the evidence code it came from; nothing unapproved leaves without `DRAFT — AI generated`.

**A FactoryBrain tightly-coupled module that owns the `quality` schema** (SAD-00 §13; the platform's section 7 was written for SRS-09 and SRS-11 MoldMind). Like [ShiftBrief (02)](../02-production-ai-analyst/), [MachineSense (06)](../06-predictive-maintenance-agent/) and [DocFlow (08)](../08-document-erp-agent/): standalone-deployable, with a platform-mode section in every document. It consumes 01/03/05 inspection, 02 production, 06 telemetry, 15 Genba Memory's archive, and feeds 13 KaizenSwarm.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. PostgreSQL could not be executed on the authoring machine — see [Verification](#verification).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-09 | [Software Requirements Specification](SRS-QE-Agent-Quality-Engineer.md) | *What must it do?* | Everyone — start here |
| SAD-09 | [Software Architecture Document](docs/SAD-QEAgent-Software-Architecture.md) | *How does a rate change become a ranked hypothesis list and an 8D draft — and why can the model never compute, never state a cause, never approve?* | Architect, implementer, ML owner |
| DDS-09 | [Database Design Specification](docs/DDS-QEAgent-Database-Design.md) | *The platform's `quality` section byte-for-byte, the extension, the evidence registry, the SQL twins of the statistics, and the triggers that make grounding, DRAFT, approval, wording, normality and rating confirmation properties of the data* | Implementer, DBA, QA |
| API-09 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The evidence, hypothesis, approval & export and statistics contracts* | Implementer, UI |
| ICD-09 | [Interface Control Document](docs/ICD-QEAgent-Interface-Control.md) | *The quality data layer (IF-49), exports (IF-50), the facts object & evidence registry (IF-51), glossary & term check (IF-52); tools, bus, model, storage* | Implementer, data owners, ML owner |
| SEC-09 | [Security Requirements Specification](docs/SEC-QEAgent-Security-Requirements.md) | *Can a number nobody computed reach a customer? Can an approval be rubber-stamped or edited? Can a limit be recalculated silently?* | Security reviewer, quality manager, internal audit |
| TEST-09 | [Test Plan and Test Cases](docs/TEST-QEAgent-Test-Plan.md) | *How do we prove the arithmetic to 1e-6, every Nelson rule, the grounding gate, the DRAFT watermark, immutable approvals, the golden set and statistics-only mode?* | QA, ML owner |
| OPS-09 | [Deployment and Operations Guide](docs/OPS-QEAgent-Deployment-Operations.md) | *Install, sources, characteristics and limits, signals, prompts and the golden gate, observability, retention, runbooks* | Operator, quality admin |
| UM-09 | [User Manual and Administrator Guide](docs/UM-QEAgent-User-Admin-Guide.md) | *Reading a signal and a hypothesis list line by line; analyse, draft, edit, confirm ratings, approve, export; 品質報告書; admin; TH/JA/EN glossary* | Quality engineers, QC supervisors, production engineers, management, customer QA, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | PostgreSQL 16 + pgvector: platform `core`/`vision.model_registry`/`quality`/`knowledge`/`audit` objects **extracted from `00/db/schema.sql`** + the QE extension (migration `quality_0001`) — 58 tables, 11 views, 20 triggers, 28 functions, 41 indexes, 13 enums; the evidence registry, claim trace and 15 guard triggers; SQL twins `spc_constant`, `xbar_r_limits`, `p_limits`, `capability_indices`, `norm_sf`, `two_proportion_z`, `nelson_rules`, `ranking_score`; roles `app_rw`/`app_ro`/`agent_ro`/`engine_rw`/`exporter_ro` | ✅ 72/72 shared objects byte-identical; static DDL; ⚠️ not executed |
| [`db/seed_demo.sql`](db/seed_demo.sql) | Reproduces SRS Appendix A (S-241 scratch 0.52 % → 3.18 %, z 12.58; change point 09-08 14:20 ± 40; lot 0.71 / mould 0.38 / shift 0.19; #212, #178) and AC-01…AC-09 **through the real functions and triggers**: a closed-form X̄-R characteristic (X̿ 2.498951, UCL 2.517125, Cpk 2.4358), a 40-point series hitting Nelson rules 1/2/3/5/6, a non-normal characteristic, 14 evidence rows, an 8D with 12 traced claims, a 5-Why with an untraced number, a JA report with a term violation, FMEA S7/O4/D5 → RPN 140 / AP M, effectiveness improved vs not improved, a statistics-only run, golden runs 65 % pass / 55 % blocked, 8 probes | ✅ re-derived in Python; ⚠️ not executed |
| [`deploy/schemas/facts-object.schema.json`](deploy/schemas/facts-object.schema.json) | **The IF-51 contract** — the only thing the model receives: every number a `Fact {value, unit?, evidence E-nn}`; capability without normality → method note and no Cp/Cpk; correlations with effect size and adjusted p; hypotheses with contra and verify step; constant wording rules | ✅ valid; Appendix A object valid; 13 negatives rejected |
| [`api/openapi.yaml`](api/openapi.yaml) | **44 paths / 50 operations / 44 schemas** — SRS §4.1's eight paths + the platform's nine quality/knowledge paths verbatim + characteristics/limits/rules, violations, signals/triage/trial runs, evidence, correlations, timeline, hypotheses/verify, similar, artefacts/revisions/diff/export/term-check, FMEA proposals/confirm, OCAP, actions/effectiveness, close/horizontal, golden, glossary, config, system | ✅ valid; 0 orphans; 26/26 platform blocks verbatim |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) · [`.env.example`](deploy/.env.example) | 17 services (web, api, spc-engine, signal-detector, correlator, drafter, indexer, exporter, scheduler, postgres pgvector, redis, minio [+init], ollama gpu/cpu, mailpit, source-stub); networks `frontend` / `internal` / `sources` / `egress` (api + scheduler only); three DB roles; 15 secret files; object lock on exports and golden runs | ✅ parsed; 45/45 vars both ways; placement; hardening; no secret values |
| [`deploy/qe.example.yaml`](deploy/qe.example.yaml) + [`schemas/qe-config.schema.json`](deploy/schemas/qe-config.schema.json) | Rules (minimum {1,2,3,5,6} enforced), baselines, capability policy, signals (min sample ≥ 30, ranking weights), correlation (BH, effect size), drafting (model ≤ 9 B, temperature ≤ 0.3, prompts), FMEA standard + AP table, export (watermark constant), glossary, cases, golden gate (≥ 60 %, 0 fabricated), notifications (statistics only), retention, locale | ✅ valid; 20 negatives rejected; prompts and glossary consistent |
| [`deploy/prompts/`](deploy/prompts/) | AI-03 versioned templates `five_why.en.v1`, `eight_d.en.v1`, `fmea.en.v1`, `report.ja.v1` — numbers only from the facts object with evidence codes; causal wording only for confirmed hypotheses; fixed JSON output shapes; 現象・原因・対策・効果確認・水平展開 | ✅ front-matter matches the config |
| [`deploy/glossary.example.csv`](deploy/glossary.example.csv) | AI-06 社内用語: 12 terms with readings, TH/EN and forbidden variants (修正措置 → 是正処置, 横展開 → 水平展開) | ✅ seed terms and report sections present; no forbidden variant inside a mandated term |

---

## Reading paths

**Implementing it** → SRS-09 → SAD-09 §4.3 (data layer, SPC, signals, correlation & hypotheses, drafting, FMEA/OCAP, cases, exports) → DDS-09 §2 (DD-Q01…Q09) → `db/schema.sql` §10–§16 → `deploy/schemas/facts-object.schema.json` → API-09 §3–§6 → ICD-09 IF-49, IF-51 → TEST-09 TS-0.

**Quality manager / internal audit** → SEC-09 §4.2 ("the 8D that proves what the supplier wants") → SEC-09 §5.1–5.4 → DDS-09 Appendix A → TEST-09 TC-060, TC-080, TC-082, TC-116 → UM-09 A.1, A.3.6.

**ML owner** → SAD-09 ADR-Q01…Q03, Q06, Q10 → ICD-09 IF-09, IF-51, IF-52 → `deploy/prompts/` → OPS-09 §8, RB-08 → TEST-09 TS-3, TS-4, TC-047.

**Statistician / QE lead** → SAD-09 ADR-Q04, Q05 → DDS-09 §5 (SQL twins) and §9 (expected values) → TEST-09 TC-005, TC-020…TC-028, TC-041 → UM-09 A.8.

**Operating it** → OPS-09 §1, §4, §5, §6, §9, §12 runbooks — RB-04 and RB-08 first.

**Using it** → UM-09 A.1, A.3 (a case from signal to export), A.6 (品質報告書).

---

## What makes this design what it is

| Principle | In QE-Agent |
|---|---|
| **The LLM never computes** | The engine computes; the model receives a facts object in which every number carries an evidence code and writes prose around it; a claim extractor traces every sentence back; an untraced claim blocks approval (C-02, AI-01, AI-04, AC-05). |
| **Offline-first → degrade without the model** | Charts, rules, capability, signals, correlations and hypotheses are code; Ollama down = statistics-only mode, drafts 503, nothing else changes (AI-08, AC-09). |
| **A named engineer owns every artefact** | DRAFT watermark structural; S/O/D confirmed per rating; hypotheses verified by a person; approvals role-gated, immutable, audited (C-01, AI-07, NFR-05, AC-06). |
| **The database is the source of truth** | Evidence registry, claim trace, limit history, normality flag, wording guard, watermark CHECK, effectiveness gate — 15 triggers, not conventions (DDS-09 DD-Q01…Q09). |
| **Hypotheses, not causes** | "— hypothesis to verify" until confirmed; every hypothesis has contra evidence and a verification step; factors with no association are stated; effect sizes and BH-adjusted p always (C-04, FR-14, FR-17, FR-18). |
| **Statistics verified against references** | SQL twins re-derived in Python here; the engine against NIST/Montgomery to 1e-6 in CI; a golden set gates every prompt/model/ranking change (NFR-04, AC-01, AI-05). |

---

## Relationship to the platform and siblings

| | |
|---|---|
| Coupling | **Tight** (SAD-00 §13): owns `quality`; shares `core`, `vision.model_registry`, `knowledge`, `audit`; migration `quality_0001` |
| Shares the `quality` section with | [MoldMind (11)](../11-injection-molding-ai/) — `mould`, `shot`, `shot_part` |
| Consumes | 01 VisionOps / 03 EdgeGuard / 05 PocketQC inspection, 02 ShiftBrief production facts, 06 MachineSense alerts, ERP/DocFlow (08) lots, CMMS, 15 Genba Memory's archive |
| Feeds | 13 KaizenSwarm (`quality.signal.high`, `quality.case.*` on IF-17), the platform Copilot (IF-16 tools `get_capability`, `get_signals`, `get_case`, `get_hypotheses`) |
| Platform paths served verbatim | `/spc/chart`, `/spc/capability`, `/signals`, `/cases`, `/cases/{id}`, `/cases/{id}/analyze`, `/cases/{id}/artifacts/{kind}`, `/artifacts/{id}/approve`, `/knowledge/search` |

---

## Identifier conventions

`FR-01…31` / `AI-01…08` / `NFR-01…09` / `AC-01…09` / `C-01…05` (SRS-09) · `P-1…P-6` · **`ADR-Q01…Q10`** · `QAS-01…12` · **`DD-Q01…Q09`** · `IF-xx` shared numbering (**IF-49 quality data layer, IF-50 export & templates, IF-51 facts object & evidence registry, IF-52 glossary & term check**) · **`THR-Q01…12`**, **`SEC-Q01…71`**, **`RR-Q01…05`** · `TS-0…9`, `TC-001` to `TC-117` · `RB-01…14` · evidence codes `E-nn`.

```
SRS-09 C-01 / C-02 / AI-04 / AC-05 / AC-06  "every number traceable; nothing unapproved leaves without DRAFT"
  └─ SAD-09 P-1, P-3 · ADR-Q02 (facts object is the only LLM input) · ADR-Q03 (claim-level grounding gate) · ADR-Q08 (DRAFT structural)
      └─ DDS-09 DD-Q01, DD-Q02, DD-Q03 · evidence · artifact_claim · export.watermark CHECK · trg_claim_check/rollup · trg_artifact_approval · trg_export_watermark
          └─ API-09 §3 evidence contract (409 GROUNDING_FAILED) · §5 approval & export contract (409 APPROVAL_IMMUTABLE, DRAFT_WATERMARK)
              └─ ICD-09 IF-51 (facts-object.schema.json) · IF-50 (watermark on every page, version stamp)
                  └─ SEC-09 O-1, O-2 · THR-Q01, THR-Q02 · SEC-Q01…Q05, Q10…Q13 · §4.2 walk-through
                      └─ TEST-09 TC-003 probes 1–4 · TC-006 · TC-054 · TC-060 · TC-065 · TC-080…083 · seed: A1 traced, A2 untraced, DRAFT exports
                          └─ OPS-09 §1 · §8 · §9 (watermark mismatch = 0) · RB-09 · RB-11 · UM-09 A.1, A.3.3, A.3.6, A.3.7
```

---

## Verification

| Check | Result |
|---|---|
| **Byte-identity vs `00/db/schema.sql`** (TC-002) | ✅ **Pass** — 72/72: extensions, helpers, enums, `core.plant/line/sku/machine/defect_type/material_lot/app_user/user_line_scope`, `vision.model_registry`, the whole `quality` section 7 (incl. MoldMind's `mould/shot/shot_part`), `knowledge.document…glossary_term`, `audit.*`, indexes, triggers |
| Static DDL (TC-003) | ✅ **Pass** — 58 / 11 / 20 / 28 / 41 / 13; FK targets and order; 15/15 guard triggers; grants (`agent_ro` no users/scope; `engine_rw` cannot touch approvals) |
| Seed arithmetic vs Python reference (TC-005) | ✅ **Pass** — X̿ 2.498951, R̄ 0.031497, UCLx 2.517125, LCLx 2.480778, UCLr 0.066584, Cp 2.4616 / Cpk 2.4358 / Pp 2.2932 / Ppk 2.2692; `norm_sf` max error 7e-8; S-241 z 12.5832; lot Fisher p 6.7e-9 / BH 4.7e-8, RR 7.67; Nelson {1:{5}, 2:{10..18}, 3:{20..25}, 5:{28,29}, 6:{33,34,36,37}}; score 0.5600; effectiveness improved / not improved; golden 13/20 pass, 11/20 blocked |
| **Facts-object schema and Appendix A** (TC-006) | ✅ **Pass** — valid; 13 negatives rejected |
| Config schema, prompts, glossary (TC-007) | ✅ **Pass** — `qe.example.yaml` valid; 20 negatives rejected; 4 prompts' front-matter match; weights sum 1; glossary consistent |
| `openapi.yaml` (TC-001) and identity vs API-00 (TC-008) | ✅ **Pass** — 44 / 50 / 44; 0 orphans; 9 paths + 13 schemas + 6 parameters + 4 responses verbatim |
| Compose / env (TC-004) | ✅ **Pass** — 17 services; egress = {api, scheduler}; internal-only = 8; engine on internal + sources only; drafter has no sources, no egress, no tools; 45/45 vars; 15/15 secrets; object lock on `exports`/`golden`; no secret values |
| SRS-09 coverage; cited objects/endpoints/TCs/RBs/ADR-Q/SEC-Q/DD-Q/THR-Q; section refs; links (TC-001) | ✅ see sweep note below |
| **Schema + seed on PostgreSQL 16** (TC-009) | ⚠️ **Not executed** — no Docker daemon on the authoring machine |
| Engine reference suite with scipy (TC-104), Ollama drafting (TS-4), GPU latency (TS-8), the golden set (TC-047), native-speaker review (TC-066) | ⚠️ Specified, not run |

To execute what could not be executed here:
```bash
cd 09-quality-engineer-agent
docker run -d --name qe-pg -e POSTGRES_PASSWORD=x -p 5436:5432 pgvector/pgvector:pg16
sleep 8 && psql "postgresql://postgres:x@localhost:5436/postgres" -v ON_ERROR_STOP=1 -f db/schema.sql && psql "postgresql://postgres:x@localhost:5436/postgres" -f db/seed_demo.sql
```
Expected: the `\echo` block matches DDS-09 §9 (limits, Cpk, rule hits, S-241 statistic, correlation p-values, A1 grounding passed / A2 failed, exports DRAFT vs APPROVED, effectiveness verified vs not, golden run 2 blocked) and probes 1–8 each fail with the named guard; `audit.log` ≥ 9 rows.

**Defects found by checking** (all fixed; TEST-09 §5): `sod_criteria` ids built with hex so S7 did not resolve; correlation p/z/RR and BH values misaligned with the re-derivation; an 8D claim pointing at unrelated evidence; horizontal deployment with a single candidate; an unquoted colon and a duplicate `operationId` in the OpenAPI file.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| PostgreSQL execution pending — byte-identity, static checks and re-derived arithmetic stand in until CI runs TC-009 | TEST-09 TC-009 |
| **scipy/statsmodels not on the authoring machine** — the Python reference for TC-005 is closed-form (A–S normal tail, exact hypergeometric Fisher, BH by hand); the engine's own suite (TC-104) runs with scipy in CI | TEST-09 §1, §6 |
| **The golden set** (AI-05, AC-04) is plant history and is not in the repository; the seed's golden runs are illustrative | TEST-09 TC-047, TC-114 |
| **NIST/Minitab reference datasets** (NFR-04, AC-01): the NIST handbook examples are public domain; Minitab sample data is licensed — the team supplies its own copy; the seed uses a closed-form dataset instead | TEST-09 §1.3 |
| Native-speaker review of the 品質報告書 (AC-07) is a process gate, not automatable; the term check is the automated half | TEST-09 TC-066, SEC-09 RR-Q04 |
| SRS §4.1 spellings (`/capability`, `/cases/{id}/draft/{artifact}`, `/cases/{id}/approve`) differ from the platform's; standalone serves both | API-09 §1 |
| Confounded factors (a lot that only ran on one mould) cannot be separated by the correlator — the verification step is the resolution | SEC-09 RR-Q03 |
| Nelson rules 4, 7, 8 are implemented but off by default; the seed's constructed series exercises 1/2/3/5/6 only | DDS-09 §9, TEST-09 TC-022 |
| Company DOCX/XLSX templates are plant-specific and not in the repository; the exporter contract is | ICD-09 IF-50, OPS-09 §4.4 |
