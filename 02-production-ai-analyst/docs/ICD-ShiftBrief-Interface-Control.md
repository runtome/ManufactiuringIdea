# Interface Control Document — ShiftBrief (Production AI Analyst)

| Field | Value |
|---|---|
| Document ID | ICD-02-ShiftBrief |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-02 §4](../SRS-ShiftBrief-Production-AI-Analyst.md), [SAD-02 §4.1](SAD-ShiftBrief-Software-Architecture.md) |
| Numbering | `IF-xx` shared with [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) and [ICD-01](../../01-factory-inspector-agent/docs/ICD-VisionOps-Interface-Control.md); IF-20 and IF-21 are new here |

---

## 1. Scope and register

ShiftBrief has no hardware interfaces. Its boundary is **files in, messages and documents out**, plus the local LLM. The interfaces that matter most are the two new ones: how a file gets in (IF-20) and how a deck gets out (IF-21).

| ID | Interface | Parties | Protocol | Criticality | vs platform |
|---|---|---|---|---|---|
| [IF-20](#if-20) | **File intake** | Data owner / MES / mailbox → intake | folder · upload · IMAP · SFTP | **Critical** | **New** |
| [IF-08](#if-08) | Discord | Notifier ↔ Discord | WSS/HTTPS | High | Identical + commands |
| [IF-09](#if-09) | LLM runtime | Brief composer → Ollama | HTTP/JSON | High | **Narrowed**: facts-only input; CPU profile |
| [IF-10](#if-10) | Object storage | Intake, worker → MinIO | S3 | High | Archives + exports |
| [IF-13](#if-13) | SMTP | Notifier → mail server | SMTP/STARTTLS | Medium | Delivery fallback |
| [IF-14](#if-14) | Metrics | Prometheus ← services | HTTP | Medium | ShiftBrief metric set |
| [IF-16](#if-16) | Agent tools | `/ask` planner → tools | In-process typed | **Critical** | **ShiftBrief tool set + gated `run_sql`** |
| [IF-19](#if-19) | Platform integration | ShiftBrief ↔ FactoryBrain | Shared DB + mounted API | High | ShiftBrief specifics |
| [IF-21](#if-21) | **Report export consumers** | Worker → PPTX/PDF/XLSX readers | File contract | Medium | **New** |

Not applicable: IF-01 edge, IF-02 camera, IF-03 PLC, IF-04 MQTT, IF-05 OPC-UA, IF-06 Modbus, IF-07 ERP, IF-11 mobile, IF-12 farm, IF-15 barcode, IF-17 agent bus, IF-18 light.

---

## IF-20 — File intake {#if-20}

**Parties.** A production data owner (a person exporting from MES, a scheduled MES job, or a mailbox) → the ShiftBrief intake worker.

**Why it is critical:** everything downstream is derived from this file. The file is produced by a system ShiftBrief does not control, and its layout, timing, encoding and correctness are all outside ShiftBrief's authority. The interface therefore specifies a *contract to validate against*, not a format to trust.

### Transports

| Kind | Mechanism | Detection | Notes |
|---|---|---|---|
| `folder` | Watched directory (`INGEST_WATCH_DIR/<source>/`) | inotify + 60 s poll; file considered complete when size is stable for 10 s and not open | Simplest; MES writes directly or via a share |
| `upload` | `POST /ingest/production` (multipart) | Immediate | Manual or scripted |
| `imap` | Mailbox poll every 5 min; attachments matching `file_pattern` | Sender allow-list **required**; subject/body ignored | Processed mail moved to `Processed/`; never deleted |
| `sftp` | Built-in SFTP server (`sftp` compose profile) with per-source account and chrooted directory | As `folder` | Host key pinned in the client's config; password or key auth |

### File contract

| Aspect | Rule |
|---|---|
| Formats | CSV (RFC 4180; delimiter per mapping) or XLSX (first sheet or `sheet` per mapping) |
| Encoding | Per source (`utf-8` default; `cp874`/`tis-620` for legacy Thai exports, `shift_jis` for Japanese MES); BOM tolerated |
| Header | Row `header_row` (default 1); **fingerprinted** — normalised (trim, lower, collapse spaces) and SHA-256'd; must match the active mapping or the batch is **held** |
| Naming | `file_pattern` glob; the date in the filename is informational — dates come from rows |
| Size | ≤ `INGEST_MAX_FILE_MB` (100); XLSX decompression ratio ≤ 100:1 (zip-bomb guard) |
| Columns | Mapped by name via the versioned YAML (DDS-02 §6); order is irrelevant |
| Required | `prod_date`, `shift`, `line`, `sku`, `qty_produced`, `qty_ng` |
| Optional | `defect_code` + `defect_qty` (one row per defect type, or a wide layout via mapping), `runtime_min`, `downtime_min`, `lot`, `operator_id` (**pseudonymised**) |
| Grain | One row per (date, shift, line, sku) for production; one per (…, defect_code) for defects. A file may carry one day or many |

### Validation (in order; each failure is a quarantine reason written for the data owner)

1. Header fingerprint matches active mapping → else `MAPPING_DRIFT`, batch **held**, alert lists missing/unexpected columns.
2. Per row: required present · types parse · date parses in `date_format` · `qty ≥ 0` · `qty_ng ≤ qty_produced` · `line`, `sku`, `defect_code` known · `shift` exists in the calendar for that date · `runtime + downtime ≤ 1440`.
3. Duplicates within the file for the same natural key → last wins, row flagged.
4. Invalid share > 5 % → batch **rejected**, nothing committed, admin alerted with the reasons.
5. Otherwise: upsert by natural key; quarantine invalid rows; archive original; recompute facts for covered dates; if a brief already existed for a covered date → **revised** brief.

### Timing and expectations
Per source: `cadence`, `expected_by` (plant time), `grace_minutes`, weekdays. Past expected + grace with no batch → `FILE_NOT_ARRIVED` alert; **no brief is generated from partial data** for that date.

### Error handling
| Condition | Behaviour |
|---|---|
| Unreadable file (corrupt, password-protected, wrong encoding) | Batch `failed` with a readable reason; archived anyway |
| Identical file re-sent | Dedup by SHA-256 → existing batch, no reprocessing |
| Same dates, different content | Treated as a **correction**: supersedes the earlier batch for those dates (`batch_detail.supersedes_batch_id`) |
| IMAP sender not on allow-list | Ignored; security event logged (SEC-02) |
| SFTP partial upload | Size-stable rule; `.part`/`.tmp` suffixes ignored |

### Security
Sender allow-list (IMAP); per-source SFTP accounts, chrooted; upload requires `engineer`+; spreadsheet parsing in a sandboxed worker with size, ratio and cell-count caps; XML external entities disabled; formulas never evaluated (XLSX read as values only). Archived originals are immutable and access-audited.

**Versioning.** The file contract is the mapping version. A layout change is a **new mapping version with a reason**, not a code change.

**Verification.** [TC-011…TC-022](TEST-ShiftBrief-Test-Plan.md).

---

## IF-08 — Discord {#if-08}

Identical to [ICD-00 IF-08](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-08). ShiftBrief specifics:

| Command | Behaviour |
|---|---|
| `/brief [date] [line] [lang]` | Posts the latest brief for the date (revision if any) with a "show the numbers" link to `/facts` |
| `/ask <question>` | Same planner as `POST /ask`; answer with sources; SQL shown when the SQL path was used |
| `/kpi <line> <period>` | Figures from `/kpi` |
| `/subscribe <lang> [tone] [line]` | Creates a subscription for the current channel (`manager`+) |
| `/status` | Sources and arrival status |

**Message contract.** A brief message carries: the text, `facts_version`, a `facts_id` link, the `significant` flag rendered as a badge, and **"REVISED"** prefix when `revised_of` is set. Threshold alerts carry the line, rate, baseline and p-value. A withheld brief posts **nothing** — the alert goes to the admin channel instead.

Discord is not a system of record; the dashboard and email fallback (IF-13) always exist. Unmapped Discord users cannot approve.

---

## IF-09 — LLM runtime {#if-09}

Narrowed from [ICD-00 IF-09](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-09).

| Aspect | ShiftBrief position |
|---|---|
| Consumers | Brief composer and `/ask` composer only. Intake and analytics never call the model |
| **Input for a brief** | The facts object and the prompt template. **Nothing else** — no rows, no file, no tool results |
| Input for `/ask` | Tool results (typed or SQL rows) + question |
| Profiles | `cpu`: ≤ 4 B Q4 model, no GPU, brief ~2–4 min · `gpu`: ≤ 9 B Q4_K_M, brief ≤ 60 s · `external`: flagged, logged, off by default |
| Determinism | `temperature ≤ 0.2` (0.0 in tests), pinned tag, `prompt_version` stored |
| Budgets | Brief: 1 call, 1024 output tokens, 300 s wall on CPU / 60 s on GPU · Ask: 5 tool calls, 60 s wall |
| Unavailable | `503 MODEL_UNAVAILABLE`; `/readyz` `degraded`; intake, facts, KPI, dashboard unaffected; the scheduled brief is retried every 10 min and an alert fires if not delivered by the SLO |
| Injection boundary | Free-text fields from files (`defect_code` descriptions, `lot`, notes) are data; retrieved content in platform mode is data |

**Verification.** TC-031…TC-040, TC-062.

---

## IF-10 — Object storage {#if-10}

| Bucket | Contents | Lifecycle |
|---|---|---|
| `archives` | Original source files, `archives/<source>/<date>/<filename>` | 2 years; **object versioning on**; no delete grant outside the sweep |
| `exports` | PPTX/PDF/XLSX jobs | 1 year |
| `backups` | DB dumps | 90 days |

Archive write happens **inside the intake transaction's success path**: a batch is `succeeded` only after the original is durably archived with its SHA-256 recorded on `ingest_batch`. Signed URLs (15 min) for `/ingest/batches/{id}/archive`, access audited.

---

## IF-13 — SMTP {#if-13}

Delivery fallback and a first-class channel for subscribers without Discord. STARTTLS; recipient allow-list (empty = deny all); HTML + plain-text; PPTX attached when the subscription is `tone: long`. Failure logged and surfaced; never blocks the brief.

---

## IF-14 — Metrics {#if-14}

```
shiftbrief_ingest_batches_total{source,disposition}      committed | rejected | held_drift | failed
shiftbrief_ingest_rows_quarantined_total{source}
shiftbrief_ingest_duration_seconds{source}                histogram
shiftbrief_file_arrival_lag_seconds{source}               now - expected_by while awaiting
shiftbrief_facts_compute_seconds                          histogram
shiftbrief_facts_stale_total                              FACTS_STALE occurrences
shiftbrief_brief_total{outcome}                           ok | withheld | deferred
shiftbrief_brief_generation_seconds{profile}              cpu | gpu
shiftbrief_brief_delivery_lag_seconds                     delivered_at - scheduled
shiftbrief_ask_total{mode,outcome}                        tools|sql × ok|refused|withheld
shiftbrief_text_to_sql_rejected_total{reason}
shiftbrief_alerts_total{kind}
```

`shiftbrief_brief_total{outcome="withheld"}` and `shiftbrief_facts_stale_total` are the two that page someone.

---

## IF-16 — Agent tools {#if-16}

The complete capability boundary of the `/ask` planner. Typed, JSON-Schema-validated, read-only except `send_discord` (gated).

| Tool | Args | Returns | Role |
|---|---|---|---|
| `kpi_summary` | `date_from, date_to, line?, shift?, sku?, baseline_days=7` | produced, ng, rate, baseline, change, `significant`, p_value, by_line, worst (rankable only), `data_complete` | viewer |
| `defect_pareto` | `date_from, date_to, line?, top_n=5` | code, qty, share, cumulative, is_critical | viewer |
| `line_shift_breakdown` | `date_from, date_to` | per (line, shift): produced, ng, rate, **rankable** | viewer |
| `trend` | `date_to, days=30, line?` | daily series + baselines + pattern flags | viewer |
| `significance` | `date, line?, baseline_days=7` | z, p, significant, pooled counts | viewer |
| `oee` | `date_from, date_to, line?` | availability, quality; performance `null` | viewer |
| `compare_periods` | `a_from, a_to, b_from, b_to, line?` | both rate blocks, change, significance | viewer |
| `get_facts` | `date, line?` | the stored facts object + hash | viewer |
| `run_sql` | `question` | rows (≤ 200) + the executed SQL | **engineer**, **disabled by default** |
| `send_discord` | `channel, message` | proposal id | manager, write, gated |

**Rules.** Schema validation before execution · DB role `agent_ro` · line scope as predicate · `data_complete: false` propagates to the composer, which must mention it · results carry `row_count` for the grounding check · `run_sql` obeys the contract in [API-02 §8](../api/API-Specification.md).

**Two ShiftBrief-specific rules:**
- `kpi_summary.worst` **omits** any group with `rankable = false`. The planner cannot be talked into headlining a 12-part line.
- `significance.significant = false` is a hard signal to the composer: "within normal variation", no cause, no recommendation.

**Verification.** TC-041…TC-052.

---

## IF-19 — Platform integration {#if-19}

| Contract | Direction | Detail |
|---|---|---|
| Shared schema | both | `core.*` production tables byte-identical; `analytics.*` via migration `shiftbrief_0001` |
| Intake | inbound | The platform's `POST /ingest/production` **is** ShiftBrief's intake worker |
| Facts | outbound | Platform `POST /agent/brief` delegates to ShiftBrief; the platform daily brief (SRS-00 FR-A-03) is a ShiftBrief brief |
| Signals | outbound | `facts.significant = true` → `quality.signal` (`defect_rate_shift`) for QE-Agent; KaizenSwarm's Production Agent reads `analytics.v_latest_facts` |
| Tools | outbound | Eight tools registered into the Copilot registry; `run_sql` honours the platform flag |
| `agent_ro` | both | Grant lists are unioned; ShiftBrief views become part of the platform SQL whitelist |
| Identity, Discord, audit | inbound | Platform's |

**Invariant:** a facts row computed standalone and one computed in platform mode from the same `core.*` rows and `FACTS_VERSION` have the same hash.

**Verification.** TC-091…TC-094.

---

## IF-21 — Report export consumers {#if-21}

**Parties.** Export worker → people opening PPTX/PDF/XLSX in PowerPoint, Keynote, LibreOffice, Acrobat, Excel.

| Aspect | Contract |
|---|---|
| PPTX | python-pptx; 16:9; template `deploy/templates/brief.pptx` with named placeholders; charts rendered as images (Recharts server-side or matplotlib) **from the same facts row as the brief** |
| PDF | WeasyPrint from the dashboard's print stylesheet; A4 |
| XLSX | openpyxl; **any cell whose text begins with `=`, `+`, `-`, `@`, tab or CR is prefixed with `'`** (formula-injection guard, SEC-S); numbers written as numbers |
| Fonts | **Embedded**: Noto Sans Thai, Noto Sans JP (or Sarabun / Noto Serif JP per template); a missing font is the usual cause of mojibake (SRS-02 AC-07) |
| Language | Per request/subscription; defect names from `core.defect_type.name_*` |
| Provenance | Footer on every page: `facts_version`, `facts_sha256` (first 12), `prompt_version`, generated-at; **"REVISED"** banner when applicable; **no export of a withheld brief** |
| Size | ≤ 20 MB; images downsampled |
| Delivery | Signed URL (15 min) via `/jobs/{id}`; attached to email when subscribed |

**Verification.** TC-071…TC-076.

---

## 2. Interface matrix

| Interface | Crosses trust boundary | Authenticated | Encrypted | Survives outage | Idempotent |
|---|---|---|---|---|---|
| IF-20 folder/SFTP | external → Z3 | share/SFTP account | SFTP: yes; share: per network | ✅ picked up later; expectation alert | ✅ SHA-256 |
| IF-20 IMAP | internet → Z3 | mailbox creds + sender allow-list | TLS | ✅ mail waits | ✅ SHA-256 |
| IF-20 upload | Z4 → Z3 | JWT engineer+ | TLS | n/a | ✅ SHA-256 |
| IF-08 Discord | Z3 → internet | bot token | TLS | ✅ non-blocking; dashboard/email remain | ⚠️ at-least-once |
| IF-09 LLM | in-zone | — | in-cluster | ✅ degraded; brief retried | ✅ stateless |
| IF-10 storage | in-zone | scoped creds | TLS | ✅ retry | ✅ by key |
| IF-13 SMTP | Z3 → mail | creds | STARTTLS | ✅ non-blocking | ⚠️ |
| IF-14 metrics | in-zone | ❌ internal | ❌ | ✅ | ✅ |
| IF-16 tools | in-process | role predicate | n/a | ✅ | ✅ |
| IF-19 platform | in-zone | platform JWT | in-cluster | ✅ | ✅ facts hash |
| IF-21 exports | Z3 → Z4 | signed URL | TLS | ✅ | ✅ by job |

**Worth arguing about:** IF-20 IMAP. Accepting files by email is convenient and is how many plants actually work; it is also the only path on which an outsider can put bytes into the pipeline. It is gated by a sender allow-list, sandboxed parsing, and the same validation as every other path — and the residual risk is recorded in [SEC-02 RR-S02](SEC-ShiftBrief-Security-Requirements.md).

---

## 3. Change control

| Change | Requires |
|---|---|
| Source file layout | New mapping version + reason (`engineer`+); held batches released after |
| New source | `POST /sources` + mapping + expectation |
| New tool (IF-16) | Schema + `agent_ro` grant if a new view + golden-set re-run |
| Whitelist a view for `run_sql` | `agent_ro` grant in `schema.sql` (reviewed) + this document |
| Facts object field | `FACTS_VERSION` bump; facts JSON schema (DDS-02 §7) + this document |
| Export template | Font embedding check (TC-073) |

---

## 4. Traceability

| SRS-02 | Interface |
|---|---|
| FR-01 sources | IF-20 transports |
| FR-02 mapping | IF-20 file contract, fingerprint |
| FR-03, FR-04 validation, quarantine, reject | IF-20 validation |
| FR-05 idempotent | IF-20 SHA-256 dedup |
| FR-06 archive | IF-10 |
| FR-07 corrections | IF-20 corrections rule |
| FR-08 late file | IF-20 expectations |
| FR-17…20 brief | IF-09 facts-only input |
| FR-23…26 Q&A | IF-16 |
| FR-27 Discord | IF-08 |
| FR-28 alerts | IF-08, IF-13 |
| FR-30 PPTX/PDF | IF-21 |
| §4.2 Discord commands | IF-08 |
| §4.3 input file contract | IF-20 |
| AI-01 CPU fallback | IF-09 profiles |
| AI-05 constrained SQL | IF-16 `run_sql` |
| NFR-07 PII | IF-20 `pii: pseudonymise` |
| AC-07 Japanese rendering | IF-21 fonts |
