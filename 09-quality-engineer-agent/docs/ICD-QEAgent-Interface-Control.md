# Interface Control Document — QE-Agent (AI Manufacturing Quality Engineer Agent)

| Field | Value |
|---|---|
| Document ID | ICD-09-QEAgent |
| Version | 1.0 (Draft) |
| Date | 2026-09-15 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-09](../SRS-QE-Agent-Quality-Engineer.md) §4 · [SAD-09](SAD-QEAgent-Software-Architecture.md) §4 · [API-09](../api/API-Specification.md) · [DDS-09](DDS-QEAgent-Database-Design.md) · [SEC-09](SEC-QEAgent-Security-Requirements.md) · [OPS-09](OPS-QEAgent-Deployment-Operations.md) · platform: [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) |
| Numbering | Shared `IF-xx` register. Reused with QE specifics: IF-08, IF-09, IF-10, IF-13, IF-14, IF-16, IF-17, IF-19. **New: IF-49 quality data layer, IF-50 export & templates, IF-51 facts object & evidence registry, IF-52 glossary & term-consistency check** |

---

## 1. Scope and register
Every interface between QE-Agent and something it does not own: the data sources it analyses, the model it drafts with, the documents it exports, the notifications it sends, and the platform it lives in.

| IF | Interface | Direction | Criticality | Section |
|---|---|---|---|---|
| IF-08 / IF-13 | Discord / SMTP-webhook notifications (FR-12, FR-31) | out | medium | [§IF-08](#if-08) |
| IF-09 | LLM runtime — drafting from the facts object | out | medium (statistics-only fallback) | [§IF-09](#if-09) |
| IF-10 | Object storage — chart images, exports | out | medium | [§IF-10](#if-10) |
| IF-14 | Metrics | out | low | [§IF-14](#if-14) |
| IF-16 | Agent tools (platform `get_spc`, `query_defects`, `search_memory`, `create_draft_report`; QE adds four read tools) | in | medium | [§IF-16](#if-16) |
| IF-17 | Inter-agent bus — signals and closures to KaizenSwarm | out | low | [§IF-17](#if-17) |
| IF-19 | Platform integration | — | — | [§IF-19](#if-19) |
| **IF-49** | Quality data layer — sources and join keys | in | **critical** | [§IF-49](#if-49) |
| **IF-50** | Export & templates — DOCX/XLSX/PDF, watermark, version stamp | out | high | [§IF-50](#if-50) |
| **IF-51** | Facts object & evidence registry — analytics engine → model | in-process | **critical** | [§IF-51](#if-51) |
| **IF-52** | Glossary & term-consistency check | in-process | medium | [§IF-52](#if-52) |

---

## IF-08 / IF-13 — Notifications {#if-08}
Inherit [ICD-00 IF-08](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-08) and [IF-13](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-13). QE messages: **HIGH signal** (kind, line, SKU, rate now vs baseline with n and p, change-point time, link — FR-12), **case opened** (owner), **overdue action** (owner, days overdue — FR-31), **grounding failed** (engineer: the untraced sentences), **golden run blocked** (ML owner). Every number in a message is taken from `signal.statistic_json` or an `evidence` row; no free text from documents. Escalations are recorded in `quality.escalation` with delivery status. Rate: one message per event; overdue digests daily.

## IF-09 — LLM runtime {#if-09}
Inherits [ICD-00 IF-09](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-09) (Ollama, GPU semaphore in platform mode). QE specifics:
- **Input**: the facts object (IF-51) and the versioned prompt template for (artefact kind, language) — nothing else. Temperature ≤ 0.3 (`prompt_template.temperature`, AI-03); `num_ctx` sized for the facts object (≈ 6 k tokens); one call per artefact; timeout 90 s (NFR-03).
- **Output**: the artefact's `content_json` shape (sections per kind: 5-Why levels; D1–D8; FMEA rows; 現象・原因・対策・効果確認・水平展開) — decoded against a per-kind JSON grammar so sections cannot be omitted; free text inside sections.
- **Post-processing** (the drafter, not the model): claim extraction → evidence trace → `grounding_status`; term check (IF-52); revision 1 stored.
- **Degradation** (AI-08): the runtime unavailable → `analysis_run.mode = statistics_only`; `/draft/*` returns `503 MODEL_UNAVAILABLE`; everything else runs.
- **No tools, no retrieval inside the call**: similar cases are retrieved by the correlator (platform `search_memory`) and placed in the facts object as evidence rows before drafting.

## IF-10 — Object storage {#if-10}
Inherits [ICD-00 IF-10](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-10). Buckets/prefixes: `charts/<characteristic>/<from>_<to>.<png|csv>` (FR-07; regenerable), `exports/<case>/<kind>-<version_stamp>.<docx|xlsx|pdf>` (10 y), `golden/<run>/…` (results and artefacts for audit). Signed URLs 15 min. Exports are immutable objects; a re-export is a new object with a new `export` row.

## IF-14 — Metrics {#if-14}
`/metrics` (Prometheus, internal): `qe_chart_latency_seconds`, `qe_violations_total{rule}`, `qe_capability_nonnormal_total`, `qe_signals_total{severity}`, `qe_signals_suppressed_total{reason}`, `qe_analyze_seconds`, `qe_correlation_tests_total`, `qe_draft_seconds{kind,lang}`, `qe_grounding_failed_total`, `qe_claims_untraced_ratio`, `qe_term_violations_total`, `qe_approvals_total`, `qe_exports_total{watermark}`, `qe_actions_overdue`, `qe_effectiveness_improved_ratio`, `qe_golden_top3_rate`, `qe_llm_available`.

## IF-16 — Agent tool contract {#if-16}
Platform mode. Inherits [ICD-00 IF-16](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-16) (typed, schema-validated, read-only, `agent_ro`, scope predicate, no free-form SQL).

| Tool | Returns | Notes |
|---|---|---|
| `get_spc(characteristic, line?, window?)` | chart data + violations | platform tool; QE serves it |
| `query_defects(date_from, date_to, group_by)` | rows | platform tool (02); QE consumes it |
| `search_memory(text, top_k?)` | past cases | platform tool (15); FR-16 |
| `create_draft_report(type, payload)` | draft id [write, HITL] | platform tool → QE `artifact` draft; approval is a human action |
| `get_capability(characteristic, line?, period?)` | `CapabilityDetail` (with n, normality, warning) | **new** |
| `get_signals(status?, line?, severity?)` | ranked signals with statistic | **new** |
| `get_case(case_id)` | case board row + hypotheses summary | **new** |
| `get_hypotheses(case_id)` | ranked hypotheses with evidence codes and status | **new** |

Rules: the Copilot may *quote* a statistic only through these tools (the platform's grounding post-check applies); no tool approves, confirms a rating, verifies a hypothesis, changes limits or exports.

## IF-17 — Inter-agent message bus {#if-17}
Inherits [ICD-00 IF-17](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-17). QE publishes `quality.signal.high` (signal id, line, SKU, defect, rate/baseline/p, change point), `quality.case.opened`, `quality.case.closed` (outcome, horizontal candidates). KaizenSwarm (13) subscribes; MachineSense (06) publishes machine alerts that the correlator reads as `timeline_event` rows.

## IF-19 — Platform integration {#if-19}
Same containers, platform database (`quality` + migration `quality_0001`; `core`, `knowledge`, `vision.model_registry`, `audit` shared), platform auth and roles, platform Ollama, platform object store with QE prefixes, platform SMTP/Discord. The nine API-00 paths are served by the gateway; the rest under `/quality/`. MoldMind (11) shares the mould/shot tables; Genba Memory (15) is the case archive the indexer writes to.

## IF-49 — Quality data layer {#if-49}
The sources QE-Agent analyses, how they are joined, and what a missing key does.

| Source (owner) | Feed | Lands in | Join keys | Refresh |
|---|---|---|---|---|
| Inspection records (01 VisionOps, 03 EdgeGuard, 05 PocketQC) | `vision.inspection` verdicts and measurements (platform) / CSV in standalone | `quality.measurement` (value per characteristic), defect counts per window | `line_id`, `sku_id`, `ts`, `lot_id` (from the inspection's lot), `machine_id` | every 5 min |
| Production facts (02 ShiftBrief) | `core.production_fact`, `core.defect_fact` | baseline volumes and defect counts for rates | `line_id`, `sku_id`, `prod_date`, `shift` | hourly |
| Machine telemetry / alerts (06 MachineSense) | alerts and maintenance events | `quality.timeline_event(kind = maintenance | alarm)` | `machine_id`, `ts` | on event |
| Material lot genealogy (ERP / DocFlow) | lot receipts, lot ↔ line assignments | `core.material_lot`, `quality.timeline_event(kind = lot_change)` | `lot_code`, `line_id`, `ts` | on change |
| Maintenance / tool log (CMMS) | polish, tool change, mould change | `quality.timeline_event`, `quality.mould.last_maintenance` | `mould_id`, `machine_id`, `ts` | on event |
| Parameter edits (MES / press controller) | setpoint changes | `quality.timeline_event(kind = parameter_edit)` | `machine_id`, `ts` | on event |
| Personnel / shift roster | operator group per shift | `quality.measurement.shift`, correlator lookup | `line_id`, `shift`, date | daily |
| Environment | ambient temperature/humidity | telemetry series per line | `line_id`, `ts` | 10 min |
| Quality document archive (15 Genba Memory) | past 8D/RCA/FMEA | `knowledge.case_record`, `knowledge.chunk` | text; `scope_json` line/SKU/machine | on ingest |

Rules: (1) joins are by time window (measurement ts within the event's window) or explicit lot/mould ids — never by fuzzy text; (2) a measurement without `lot_id` participates in charts but not in the lot factor, and the correlation report says how many were excluded; (3) defect codes are normalised through `core.defect_type.code` before analysis, and unmapped codes produce a data-quality line at the top of every report (SRS §10); (4) trial runs are declared, not inferred (FR-11); (5) nothing in this layer is written back to the source systems.

## IF-50 — Export & templates {#if-50}
| Item | Contract |
|---|---|
| Formats | DOCX and XLSX rendered from the company templates (`templates/<kind>.<lang>.<version>.docx|xlsx`); PDF from DOCX via LibreOffice headless in the `exporter` container (FR-25) |
| Templates | one per artefact kind × language; the Japanese 品質報告書 template carries the standard section order 現象・原因・対策・効果確認・水平展開 (FR-26); chart labels localised (NFR-09) |
| Watermark | every page of an export of an unapproved artefact carries the diagonal text `DRAFT — AI generated`; the `export` row carries the same value and the database refuses any other for a draft (C-01, AC-06) |
| Stamp | footer: `<kind> v<version>.<revision> · approved by <name> on <date>` or `DRAFT` (NFR-06) |
| Numbers | rendered from `content_json` — the exporter never recomputes; capability figures print the normality warning when `normality_ok = false` (C-03) |
| Charts | embedded PNGs from IF-10 with the rule violations highlighted and the limit row's baseline/reason in the caption (FR-07) |
| Integrity | `export.sha256` of the file; re-exports are new rows |

## IF-51 — Facts object & evidence registry {#if-51}
The contract between the analytics engine and the drafting model — the whole of P-1 in one JSON document: [`deploy/schemas/facts-object.schema.json`](../deploy/schemas/facts-object.schema.json) (Draft 2020-12, `additionalProperties: false` everywhere).

Rules:
1. **Producer**: the correlator assembles the object from `quality.evidence` rows of the case plus the signal, capability and hypothesis tables; every numeric field is a `Fact {value, unit?, evidence}` where `evidence` is an `E-nn` code that exists in `evidence[]`; `evidence[].digest` is the sha256 of the value.
2. **Consumer**: the drafter passes the object and the prompt template to the model; the object's `wording_rules` are constant (`numbers_only_from_evidence: true`, `causal_language_only_for: hypotheses with status confirmed`, `mark_as_draft`).
3. **Shape rules the schema enforces**: a capability entry with `normality_ok = false` must carry `method_note` and must not carry `cp`/`cpk` (C-03); a correlation entry must carry `effect_size` and `p_adjusted` (FR-14); a hypothesis must carry `supporting`, `contra` and `verify_step` (FR-17); `no_meaningful_association[]` and `multiple_comparison.warning` are present (FR-18, FR-14); no free text from documents (retrieved cases are 200-character summaries as evidence rows).
4. **Traceability**: `artifact.facts_digest` = sha256 of the object; claims map back to `evidence` codes; the golden run stores each object for reproducibility (AI-05).
5. **Versioning**: `schema_version: facts.v1`; a change is a new version and a golden run.

## IF-52 — Glossary & term-consistency check {#if-52}
| Item | Contract |
|---|---|
| Source | `knowledge.glossary_term` (platform, SRS-14 shape): `ja`, `ja_reading`, `th`, `en`, `domain`, `forbidden_json`; loaded from [`deploy/glossary.example.csv`](../deploy/glossary.example.csv) by `qectl glossary load` |
| Check | after drafting and after every revision: the JA (and TH) content is scanned for each forbidden rendering; hits become `term_check` rows with the expected term and position; `artifact.term_violations` counts unresolved rows (AI-06) |
| Effect | approval refused while violations are unresolved (`409 TERM_CHECK`); the editor shows the replacement; resolving = editing the text or marking a justified exception |
| Prompt side | the facts object carries the relevant glossary entries so the model uses mandated terms in the first place |
| Native review (AC-07) | a process gate recorded as an approval by a Japanese-speaking engineer/manager; the term check is the automated half |

---

## 2. Interface matrix
| IF | Protocol | Auth | Data leaving QE-Agent | Retry / failure |
|---|---|---|---|---|
| IF-08 / IF-13 | Discord HTTPS / SMTP TLS / webhook | bot token / credentials (secret files) | statistics and links; no document text | queue + retry; escalation rows |
| IF-09 | HTTP (Ollama) | none (internal) | facts object only | statistics-only mode |
| IF-10 | S3 over TLS | access key | chart images, exports | 3 retries |
| IF-14 | HTTP scrape | internal | metrics | — |
| IF-16 | platform tool runtime | `agent_ro` | statistics and summaries | — |
| IF-17 | bus (platform) | platform | signal/case events | at-least-once |
| IF-49 | SQL / CSV / bus | read-only source accounts | none (read) | data-quality report |
| IF-50 | files | — | exports with watermark | re-export |
| IF-51 | in-process | — | none | schema validation fails closed |
| IF-52 | in-process | — | none | violations block approval |

## 3. Change control
| Item | Versioned in | Procedure |
|---|---|---|
| Control limits | `control_limits` (append-only with reason) | recalculation through the API with a reason (FR-06) |
| Nelson rule sets | `rule_config` | admin; minimum set fixed |
| Ranking weights, min sample, baselines | `ranking_config` | new version; golden run |
| FMEA standard and S/O/D criteria | `fmea_config`, `sod_criteria` | admin; existing rows keep their standard |
| Prompt templates | `prompt_template` (git files + checksum) | new version; golden run gate (AI-05, AI-09-style) |
| Facts-object schema | `facts.v<n>` | new version; golden run |
| Export templates | `templates/<kind>.<lang>.<version>` | new version; native review for JA |
| Glossary | `knowledge.glossary_term` (approved_by) | approved by a Japanese-speaking manager |

## 4. Traceability
| SRS-09 | IF |
|---|---|
| FR-07, FR-25, FR-26, NFR-06, NFR-09, AC-06, AC-07 | IF-50, IF-52 |
| FR-12, FR-31 | IF-08 / IF-13 |
| FR-13, FR-15 (data sources §4.2) | IF-49 |
| FR-16 | IF-16 (`search_memory`), IF-19 |
| FR-19…FR-23, C-02, AI-01, AI-03, AI-04, AI-08 | IF-51, IF-09 |
| AI-06 | IF-52 |
| C-03, FR-14, FR-17, FR-18 | IF-51 shape rules |
| NFR-07 | §2 (no document text leaves) |
