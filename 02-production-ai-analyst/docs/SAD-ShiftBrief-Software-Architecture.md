# Software Architecture Document — ShiftBrief (Production AI Analyst)

| Field | Value |
|---|---|
| Document ID | SAD-02-ShiftBrief |
| Project code name | **ShiftBrief** |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Governs | [SRS-02-ShiftBrief](../SRS-ShiftBrief-Production-AI-Analyst.md) |
| Platform relationship | Standalone-deployable; the daily-brief engine of [FactoryBrain (SAD-00)](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) in platform mode |

**Structure basis:** ISO/IEC/IEEE 42010:2011 with C4-model views.

---

## 1. Introduction

### 1.1 Purpose
This document describes **how** ShiftBrief is built: a pipeline that takes the production file someone sends every day, validates it without mercy, computes a deterministic *facts object*, and has a local language model write a manager's brief around those facts — delivered to Discord, a dashboard and a slide deck, in Thai, Japanese or English.

### 1.2 What makes this project different from its siblings
ShiftBrief has **no hardware**. No camera, no PLC, no edge node, and no GPU on the critical path. It is designed to run on a small server or VPS with a CPU-only language model, because that is what makes it the first thing to build and the first thing that is useful at work.

Its difficult problems are therefore not latency or takt time. They are:

| Problem | Where it is handled |
|---|---|
| The input file is produced by someone else and its layout changes without warning | §4.3.1 intake, ADR-S02 |
| A file arrives late, twice, or corrected after the brief went out | §4.4.2, §4.4.3, ADR-S08 |
| A 2 % → 4 % swing on 40 parts looks dramatic and means nothing | §4.3.2 minimum-volume guard, ADR-S04 |
| The model writes a confident cause for a normal day | §4.3.3 significance gate, ADR-S05 |
| A brief regenerated next month must say exactly what it said today | ADR-S01 facts table |
| Someone asks a question the typed tools cannot answer | §4.3.4 text-to-SQL behind a flag, ADR-S07 |

### 1.3 Two ways to deploy it
**Standalone** — one `docker compose up`, a watched folder, a Discord token. **Platform mode** — the intake and analytics become the FactoryBrain daily-brief engine; database, auth, LLM and Copilot are the platform's (§9).

### 1.4 Related documents
| ID | Document |
|---|---|
| SRS-02 | [Requirements](../SRS-ShiftBrief-Production-AI-Analyst.md) |
| DDS-02 | [Database Design](DDS-ShiftBrief-Database-Design.md) · [`schema.sql`](../db/schema.sql) |
| API-02 | [API Specification](../api/API-Specification.md) · [`openapi.yaml`](../api/openapi.yaml) |
| ICD-02 | [Interface Control](ICD-ShiftBrief-Interface-Control.md) |
| SEC-02 | [Security Requirements](SEC-ShiftBrief-Security-Requirements.md) |
| TEST-02 | [Test Plan](TEST-ShiftBrief-Test-Plan.md) |
| OPS-02 | [Deployment & Operations](OPS-ShiftBrief-Deployment-Operations.md) |
| SAD-00 | [Platform architecture](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) — inherited decisions linked, not restated |

---

## 2. Architecture principles

The four platform principles apply. ShiftBrief is where **P-1 is at its strictest**, and that is worth stating plainly.

| ID | Principle | What it means in ShiftBrief |
|---|---|---|
| **P-1** | The LLM never computes numbers | The model receives **exactly one input: the facts object**. Not rows, not a CSV, not a tool result mid-turn. Every figure in the brief must appear in that object; a deterministic post-check enforces it and **withholds** the brief otherwise. The facts object is stored with a hash, so the brief's provenance is one row. |
| **P-2** | Offline-first | The reference deployment has no internet and no GPU. A ≤ 4 B model on CPU is a **supported configuration**, not a degraded one (ADR-S06). The daily brief is slower; it is still there at 07:15. |
| **P-3** | Human-in-the-loop for consequences | A brief is advisory. Threshold alerts are *notifications*. The only write-capable agent tool is `send_discord`, and it creates a proposal. Nothing ShiftBrief does changes a record of decision. |
| **P-4** | The database is the single source of truth | `analytics.facts` is the truth for a date; `analytics.brief` is derived from it; source files are archived immutably with a hash. Re-running a date recomputes facts from `core.production_fact` and must reproduce the stored hash. |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-02 §2.4)
| ID | Constraint | Impact |
|---|---|---|
| C-01 | LLM never computes statistics; facts injected as structured input | Facts builder is the only path to the model; grounding post-check |
| C-02 | Source files never modified; archived with checksum | Immutable archive bucket, SHA-256 on `ingest_batch` |
| C-03 | Re-running a day is idempotent and reproduces the same brief for same input + config | Facts table with `facts_version` + hash; deterministic generation (`temperature ≤ 0.2`, pinned model) |
| C-04 | Runs without internet; cloud LLM optional | CPU model profile; `backend` network internal |

### 3.2 Quality attributes that shape the design
| Driver | Requirement | Shapes |
|---|---|---|
| Ingest throughput | NFR-01 ≤ 3 min for 500 k rows | Streaming CSV parse, batched upsert, validation in pandas not row-by-row |
| Brief latency | NFR-02 ≤ 60 s (GPU); CPU figure documented | Facts precomputed; model only writes prose |
| Ask latency | NFR-03 ≤ 20 s p95 | Typed tools over pre-aggregated views |
| Reproducibility | NFR-08 byte-identical facts | Facts table, hash, versioned analytics code |
| Footprint | NFR-05 ≤ 8 GB RAM + 8 GB VRAM (VRAM optional) | Small model; no vector DB needed in standalone |
| Correctness | AC-02 KPI = manual Excel; AC-04 zero fabricated numbers | Golden set; seed with known totals |

### 3.3 Not drivers
Real-time streaming, sub-second anything, multi-plant, image processing.

---

## 4. Views

### 4.1 Context view

```
 Daily CSV / XLSX ──┐  (folder · upload · IMAP · SFTP)
                    ▼
            ┌──────────────────────────────────┐
            │            ShiftBrief            │──► Discord (brief, alerts, /ask)
            │  intake · facts · brief · ask    │──► Dashboard (Next.js)
            │                                  │──► PPTX / PDF deck
   Ollama ◄─┤   (local; CPU or GPU)            │──► Email (fallback)
            └──────────────────────────────────┘──► FactoryBrain (platform mode)
```

| Actor | Interface | Notes |
|---|---|---|
| Production data owner (person/system) | [IF-20](ICD-ShiftBrief-Interface-Control.md#if-20) file intake | The file is the contract; its layout is mapped, not assumed |
| Discord | [IF-08](ICD-ShiftBrief-Interface-Control.md#if-08) | Not a system of record |
| Ollama | [IF-09](ICD-ShiftBrief-Interface-Control.md#if-09) | Receives only the facts object |
| Deck/report consumers | [IF-21](ICD-ShiftBrief-Interface-Control.md#if-21) | PPTX/PDF with embedded TH/JA fonts |
| FactoryBrain | [IF-19](ICD-ShiftBrief-Interface-Control.md#if-19) | Platform mode |

### 4.2 Container view

```
┌─ Server / VPS (no GPU required) ─────────────────────────────────────────┐
│  intake    watchers (folder · IMAP · SFTP · upload) → map → validate     │
│  api       FastAPI: ingest, facts, brief, kpi, ask, export               │
│  analytics facts builder (scheduled + on ingest)                         │
│  brief     composer + grounding post-check + /ask planner                │
│  worker    RQ: exports, retention, archive, alerts                       │
│  web       Next.js dashboard                                             │
│  notifier  Discord bot · SMTP fallback                                   │
│  postgres · minio (archives, exports) · redis · ollama (CPU | GPU)       │
└──────────────────────────────────────────────────────────────────────────┘
```

| Container | Responsibility | Notes |
|---|---|---|
| `intake` | Detect files, hash, dedup, map columns by versioned YAML, validate, quarantine, commit or reject, archive | Runs as a worker queue `ingest`; idempotent |
| `analytics` | Build the facts object for (date, line) from `core.production_fact`/`defect_fact`; store with hash | Pure functions; versioned by `FACTS_VERSION` |
| `brief` | Compose prose from facts; grounding post-check; `/ask` tool loop | The only container that talks to Ollama |
| `worker` | PPTX/PDF, retention, late-file alerts, revised-brief notices | |
| `notifier` | Scheduled brief post; threshold alerts; `/ask` bridge | Single instance (gateway session) |

Modular monolith (platform ADR-002): `intake`, `api`, `analytics`, `brief`, `worker`, `notifier` are one image with different entrypoints.

### 4.3 Component view

#### 4.3.1 Intake pipeline

```
file detected ─► SHA-256 ─► seen before? ──yes──► return existing batch (409 + batch)
                              │ no
                              ▼
                       load source mapping (YAML, versioned)
                              │
                       drift check: expected columns vs actual
                              │  drift ──► MAPPING_DRIFT alert; batch held for mapping update
                              ▼
                       parse (streaming) → map → normalise types/dates/units
                              │
                       validate row by row → ok | quarantine(reason)
                              │
                       invalid share > 5 %? ──yes──► batch REJECTED, nothing committed, admin notified
                              │ no
                              ▼
                       UPSERT core.production_fact / defect_fact  (natural key)
                       INSERT core.quarantine_row (reason, raw row)
                       archive original to object store (immutable, hash recorded)
                              │
                       trigger facts rebuild for affected dates → if a brief exists → REVISED brief
```

Every quarantine reason is written for the **data owner**, not the developer: *"row 217: qty_ng (48) exceeds qty_produced (40)"*, not *"CheckViolation ng_not_exceeding_produced"*.

#### 4.3.2 Analytics engine — the facts builder

```
inputs: production_fact, defect_fact for date D (and baselines D-1, D-7..D-1, D-30..D-1)
   │
   ├─ totals: produced, ng, defect_rate_pct  (null if produced = 0)
   ├─ by line / shift / sku: same, with min-volume flag (n < 100 → not rankable)
   ├─ pareto: defect_code, qty, share, cumulative
   ├─ deltas: vs D-1, vs 7-day, vs 30-day (% change, null if baseline null)
   ├─ significance: two-proportion z-test D vs pooled 7-day, α = 0.05 → p, significant
   ├─ worst_line / worst_sku / worst_shift: rate-ranked among rankable groups only
   ├─ trends: consecutive-rise count, level shift, >3σ outlier flag
   ├─ oee: availability, quality (performance omitted — no validated ideal cycle)
   └─ meta: facts_version, computed_at, source batch ids, data_completeness (shifts present)
   ▼
facts object (JSON, schema-validated) ─► analytics.facts (UNIQUE date+line+version, sha256)
```

Pure and deterministic: same rows + same `FACTS_VERSION` → same JSON → same hash. This is the mechanism behind SRS-02 NFR-08 and the reason a brief can be regenerated in a year.

#### 4.3.3 Brief composer

```
facts (one row) ─► prompt template vN (lang, tone: short | long) + glossary
                        │
                        ▼  Ollama (temperature ≤ 0.2, pinned tag)
                     prose
                        │
                        ▼  grounding post-check: every numeric token ∈ facts
                 pass ─► analytics.brief (text, sources = [facts_id], grounding)
                 fail ─► analytics.brief (withheld = true, text = NULL, reason)  ─► alert
```

**Significance gate** (ADR-S05): when `facts.significance.significant = false`, the template *requires* "within normal variation" and *forbids* a cause or recommendation. When true, causal language is limited to "possible", "correlation", "not verified".

**Completeness gate**: when `facts.meta.data_completeness` shows a missing shift, the brief must say which shift is missing before any comparison.

#### 4.3.4 `/ask` planner

```
question ─► intent + entities + time range (shift calendar aware)
                │
     ┌──────────┴─────────────┐
     ▼                        ▼
 typed tools              text-to-SQL  (ENABLE_TEXT_TO_SQL=true only)
 kpi_summary                 generate SQL from a schema description
 defect_pareto               ├─ parse (sqlglot) → SELECT only, whitelisted tables/views
 line_shift_breakdown        ├─ inject LIMIT 200, statement_timeout 5 s
 trend · significance        ├─ execute as agent_ro
 oee · compare_periods       └─ SQL returned to the caller with the answer
 get_facts
     └──────────┬─────────────┘
                ▼
         facts bundle ─► composer ─► grounding post-check ─► answer + sources (+ SQL)
```

Typed tools are always tried first. Text-to-SQL is **off by default** and stays behind the flag until its own evaluation gate passes (ADR-S07).

### 4.4 Runtime views

#### 4.4.1 The daily path
```
06:40  file lands in the watched folder
06:41  intake: hash, map, validate → batch succeeded (3 rows quarantined)
06:42  analytics: facts for 2026-09-10 × {all, L1, L2, L3} → 4 rows, hashed
07:00  scheduler: brief (daily, lang per subscriber) → Ollama → grounding pass
07:01  notifier: Discord post with facts id + "show the numbers" link
07:05  dashboard shows the same brief; PPTX job queued
```

#### 4.4.2 Late file
```
09:00  cutoff passes; no file for source "mes_daily" → FILE_NOT_ARRIVED alert
       (brief for that date is NOT generated from partial data; dashboard shows "awaiting file")
```

#### 4.4.3 Corrected file → revised brief
```
11:30  corrected file arrives (different hash, same dates)
       intake: UPSERT by natural key → rows updated; batch linked to previous
       analytics: facts recomputed → new facts_version row (old row retained)
       brief: new brief with revised_of = original id; Discord posts "REVISED" with a diff of the headline numbers
```
The original brief is never overwritten (ADR-S08). Anyone who acted on it can see what changed.

#### 4.4.4 Regeneration
`POST /brief?date=2026-08-20&regenerate=true` → analytics recomputes facts → hash compared with stored → **must match** (else `FACTS_STALE`, meaning code or data changed and the discrepancy is surfaced, not hidden) → composer runs → new brief row linked to the same facts.

### 4.5 Deployment view

| Shape | Hardware | LLM | Use |
|---|---|---|---|
| **Single server / VPS, CPU-only** (reference) | 4 vCPU, 8–16 GB RAM, 100 GB disk | ≤ 4 B Q4 on CPU; brief ~2–4 min | Small plant, one daily file |
| Same with GPU profile | + RTX 3060 Ti | ≤ 9 B Q4_K_M; brief ≤ 60 s | Faster `/ask`, longer briefs |
| Platform mode | FactoryBrain server | Platform's | Integrated |

Network: `backend` is `internal: true`; only `caddy`, `web`, `notifier` can egress, and only to allow-listed hosts (Discord, SMTP, optional cloud LLM).

### 4.6 Data view
Owned by [DDS-02](DDS-ShiftBrief-Database-Design.md). `core.*` production tables are **byte-identical** to the platform's; `analytics.*` is ShiftBrief's own schema (source, mapping, expectation, facts, brief, alert_event).

---

## 5. Cross-cutting concerns

| Concern | Position |
|---|---|
| Auth | Platform JWT model inherited (15 min / 12 h); no edge credentials exist here |
| Authorisation | viewer < inspector < engineer < manager < admin; line scope as query predicate. **Mapping changes require `engineer`+ and a reason**; text-to-SQL requires `engineer`+ |
| Idempotency | Batch by SHA-256; facts by (date, line, version); `Idempotency-Key` on writes |
| Determinism | `FACTS_VERSION` bumps on any analytics change; `prompt_version` on any template change; both stored on every brief |
| PII | `operator_id` in source files is pseudonymised at intake (HMAC); never enters facts or briefs (SRS NFR-07) |
| Egress | Default-deny; Discord/SMTP allow-listed; cloud LLM flagged and logged |
| Observability | Correlation id from file → batch → facts → brief → Discord message id |
| i18n | Brief language per subscriber; defect names trilingual; fonts embedded for PPTX/PDF |
| Time | Plant timezone for "yesterday"; shift calendar versioned by date |

---

## 6. Integration map

| Sibling | Relationship |
|---|---|
| [00 FactoryBrain](../../00-factorybrain-platform/) | Host in platform mode; `core.production_*` shared; ShiftBrief *is* the platform's daily brief (SRS-00 FR-A-03) |
| [09 QE-Agent](../../09-quality-engineer-agent/) | Consumes `analytics.facts.significance` as a `quality.signal` source in platform mode |
| [10 Factory Copilot](../../10-factory-copilot/) | Front-end for `/ask`; ShiftBrief tools register into its registry |
| [13 KaizenSwarm](../../13-multi-agent-factory/) | The Production Agent reads `analytics.facts` directly |
| [01 VisionOps](../../01-factory-inspector-agent/) | Independent data path (inspection vs production file); platform mode reconciles both in one dashboard |

---

## 7. Architecture Decision Records

Inherited from SAD-00 (one line each): **ADR-002** modular monolith · **ADR-003** Ollama local-first · **ADR-005** typed tools first · **ADR-006** MinIO · **ADR-008** Redis · **ADR-009** self-issued JWT · **ADR-012** UUIDv7 · **ADR-013** grounding post-check. pgvector (ADR-001) and the GPU semaphore (ADR-011) are **not needed** in standalone ShiftBrief; the extension is still created for platform-mode compatibility.

### ADR-S01 — The facts object is a stored, hashed, versioned row
**Context.** SRS-02 C-03/NFR-08: a rerun must reproduce the brief. **Decision.** `analytics.facts` stores the JSON with `facts_version` and SHA-256; briefs reference a facts row. Regeneration recomputes and compares hashes. **Consequences.** ✅ One-row provenance; a mismatch is surfaced as `FACTS_STALE` instead of silently drifting. ❌ Analytics changes require a version bump and produce new rows for old dates — deliberate.

### ADR-S02 — Column mapping is versioned YAML with drift detection
**Context.** The source file is produced by someone else and changes. **Decision.** One mapping per source, versioned, with the expected header fingerprint; a mismatch raises `MAPPING_DRIFT` and holds the batch rather than guessing. **Consequences.** ✅ A renamed column never silently becomes a missing line. ❌ A human must update the mapping when the layout changes — correct; guessing is worse.

### ADR-S03 — Batch rejection above 5 % is all-or-nothing
**Context.** SRS-02 FR-04 / SRS-00 §6.3. **Decision.** If > 5 % of rows fail validation nothing is committed. **Consequences.** ✅ No partially loaded day masquerading as complete. ❌ A single bad shift can block the day — the alert names the rows so the owner can fix the file.

### ADR-S04 — Minimum-volume guard before ranking
**Context.** 1 defect in 12 parts is 8.3 % and meaningless. **Decision.** Groups below `MIN_RANK_VOLUME` (default 100) are reported but never ranked "worst"; the facts object carries `rankable: false`. **Consequences.** ✅ No headline built on noise. ❌ A genuinely bad small run is reported, not headlined — the brief still lists it.

### ADR-S05 — Significance gates causal language
**Context.** SRS-02 FR-19/20. **Decision.** Two-proportion z-test vs pooled 7-day baseline; `significant=false` forces "within normal variation" and forbids recommendations; `true` permits only hedged correlation language. Tested by golden set. **Consequences.** ✅ The commonest LLM failure (a confident story about noise) is structurally prevented. ❌ Some real-but-small changes are described as normal — acceptable; the numbers are still shown.

### ADR-S06 — CPU-only is a supported configuration
**Context.** SRS-02 §2.3/AI-01: VPS deployment. **Decision.** A ≤ 4 B Q4 model on CPU is the reference profile; GPU is an optional profile. Brief latency on CPU is documented, not hidden. **Consequences.** ✅ Deployable anywhere; no GPU procurement blocks the first useful brief. ❌ `/ask` is slower on CPU; rate limits are lower in that profile.

### ADR-S07 — Text-to-SQL is default-off, read-only, parsed, limited, and shows its SQL
**Context.** SRS-02 FR-23…26 wants ad-hoc questions; free SQL is the largest attack and fabrication surface in the set. **Decision.** Behind `ENABLE_TEXT_TO_SQL`; generated SQL is parsed (sqlglot), restricted to SELECT over a whitelist of views, `LIMIT` injected, `statement_timeout` 5 s, executed as `agent_ro`, and **returned to the caller** with the answer. Enabled only after its own ≥ 85 % execution-accuracy gate. **Consequences.** ✅ Bounded blast radius; verifiable answers. ❌ Two answer paths to maintain.

### ADR-S08 — Revised briefs link, never overwrite
**Context.** Corrected files arrive after the brief was read. **Decision.** New facts version, new brief with `revised_of`; Discord posts the delta. **Consequences.** ✅ Anyone who acted on the original sees what changed. ❌ Two briefs for one date in history — labelled, and the correct behaviour.

---

## 8. Quality attribute scenarios

| ID | Scenario | Measure | Traces |
|---|---|---|---|
| QAS-01 | 500 k-row file lands | Ingested + facts ≤ 3 min | NFR-01 |
| QAS-02 | Daily brief on CPU profile | Delivered by 07:15 (≤ 4 min generation) | NFR-02, ADR-S06 |
| QAS-03 | Source renames two columns | `MAPPING_DRIFT` alert; nothing committed wrongly | ADR-S02 |
| QAS-04 | 8 % of rows invalid | Batch rejected; admin notified with reasons; no partial data | FR-04 |
| QAS-05 | Normal-variation day | Brief says "within normal variation"; no cause | FR-20 |
| QAS-06 | Line with 12 parts, 1 NG | Not ranked worst; shown with `rankable: false` | FR-13 |
| QAS-07 | Corrected file at 11:30 | Revised brief linked to original; delta posted | FR-07 |
| QAS-08 | Brief regenerated 6 months later | Facts hash matches; identical numbers | NFR-08 |
| QAS-09 | Model emits an unsupported number | Brief withheld; alert | AI-04 |
| QAS-10 | `/ask` with text-to-SQL off | Typed tools answer or refuse; no SQL path | ADR-S07 |
| QAS-11 | LLM container down | Ingest, facts, KPI, dashboard unaffected; brief deferred with alert | NFR-04 (platform) |
| QAS-12 | Deploy on a 4-vCPU VPS with no internet | `docker compose up`; first brief next morning | C-04 |

---

## 9. Platform mode

| Concern | Standalone | Platform mode |
|---|---|---|
| Database | Own Postgres; `schema.sql` (core incl. production facts + analytics + agent + ops + audit) | Platform's; `core.production_*` already present (identical); `analytics.*` applied as migration `shiftbrief_0001` |
| Intake | ShiftBrief `intake` worker | Same worker, registered as the platform's `POST /ingest/production` implementation |
| Facts & brief | `analytics.facts`, `analytics.brief` | Same tables; the platform's `POST /agent/brief` delegates here |
| `/ask` | ShiftBrief planner + 8 tools | Tools registered into the Copilot registry; text-to-SQL stays behind the platform flag |
| LLM | Own Ollama (CPU/GPU) | Platform's Ollama via the GPU semaphore |
| Auth, Discord, audit | Own | Platform's |
| Significance | Stored in facts | Also opens `quality.signal` (kind `defect_rate_shift`) for QE-Agent |

---

## 10. Risks and technical debt

| ID | Risk | Mitigation |
|---|---|---|
| AR-S01 | Source layout changes silently | Drift fingerprint (ADR-S02); mapping versioned; alert |
| AR-S02 | Small samples produce dramatic percentages | Min-volume guard (ADR-S04); significance (ADR-S05) |
| AR-S03 | LLM writes a confident wrong cause | Facts-only input; significance gate; `must_not_claim` golden checks |
| AR-S04 | Operator PII in source files | HMAC pseudonymisation at intake; never in facts |
| AR-S05 | Discord outage hides the brief | Dashboard and email fallback; brief exists regardless |
| AR-S06 | CPU brief too slow for the 07:15 SLO | Schedule generation at 06:45; documented latency; GPU profile |
| AR-S07 | Text-to-SQL enabled prematurely | Flag default off; eval gate; SEC-02 controls |
| AR-S08 | Facts version bump invalidates comparisons | Old rows retained; dashboards filter by version; documented |

**Accepted debt for v1:** OEE performance component omitted (needs validated ideal cycle time); no multi-source reconciliation (one file per plant per day); no email intake DKIM verification beyond sender allow-list.

---

## 11. Traceability to SRS-02

| SRS item | Addressed in |
|---|---|
| C-01 facts-only LLM | P-1, §4.3.3, ADR-S01 |
| C-02 archive + checksum | §4.3.1 |
| C-03 idempotent rerun | ADR-S01, §4.4.4 |
| C-04 no internet | §4.5, ADR-S06 |
| FR-01…08 ingestion | §4.3.1, ADR-S02, ADR-S03, §4.4.2 |
| FR-09…16 analytics | §4.3.2, ADR-S04 |
| FR-17…22 brief | §4.3.3, ADR-S05, ADR-S08 |
| FR-23…26 Q&A | §4.3.4, ADR-S07 |
| FR-27…31 delivery | notifier, worker, §4.4.1 |
| AI-01…06 | ADR-S06, ADR-S07, §5 determinism |
| NFR-01…09 | §8 QAS |
| AC-01…08 | §8, [TEST-02](TEST-ShiftBrief-Test-Plan.md) |
