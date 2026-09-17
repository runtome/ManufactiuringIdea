# Deployment & Operations Guide — QE-Agent (AI Manufacturing Quality Engineer Agent)

| Field | Value |
|---|---|
| Document ID | OPS-09-QEAgent |
| Version | 1.0 (Draft) |
| Date | 2026-09-15 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-09](../SRS-QE-Agent-Quality-Engineer.md) · [SAD-09](SAD-QEAgent-Software-Architecture.md) · [DDS-09](DDS-QEAgent-Database-Design.md) · [ICD-09](ICD-QEAgent-Interface-Control.md) · [SEC-09](SEC-QEAgent-Security-Requirements.md) · [TEST-09](TEST-QEAgent-Test-Plan.md) · [UM-09](UM-QEAgent-User-Admin-Guide.md) · files: [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/qe.example.yaml`](../deploy/qe.example.yaml) · [`deploy/schemas/qe-config.schema.json`](../deploy/schemas/qe-config.schema.json) · platform: [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) |

---

## 1. What you are operating
A statistics engine with a drafting model attached, not the other way round. If Ollama is down the plant still gets charts, signals, correlations and hypotheses (AI-08); if the engine is down nothing useful happens. Operate accordingly: the engine's data feeds, its constants table and its reference-test result are the things to watch; the model is a convenience whose output is always checked by code before an engineer sees it.

Three operational truths from the SRS that this guide enforces:
- **Limits are never changed silently** — a recalculation needs a reason and leaves the old row (FR-06, RB-04).
- **Nothing is exported as fact without an approval** — the DRAFT watermark is structural (C-01, AC-06); an incident that finds otherwise freezes approvals (RB-11).
- **Every prompt, model, ranking or facts-schema change runs the golden set first** (AI-05, RB-08).

## 2. Topology and sizing
| Service | Image | Role | Sizing (one plant, 4 lines, 20 characteristics, ~1 M measurements/month) |
|---|---|---|---|
| `web`, `api` | `qe/web`, `qe/api` | UI, REST, approvals, exports (signed URLs), notifications | 2 vCPU / 2 GB each |
| `spc-engine` | `qe/spc-engine` | charts, rules, limits, capability, normality (Python, scipy/statsmodels) | 4 vCPU / 4 GB (`ENGINE_CPUS`/`ENGINE_MEMORY`) |
| `signal-detector` | `qe/signal-detector` | rates vs baselines, change points, ranking, suppression, auto-case | 2 vCPU / 2 GB; runs every `DETECT_INTERVAL_S` |
| `correlator` | `qe/correlator` | factor tests, BH, timeline, retrieval, hypotheses, facts object | 4 vCPU / 4 GB |
| `drafter` | `qe/drafter` | facts object → Ollama → claims → grounding → term check | 1 vCPU / 1 GB (waits on Ollama) |
| `indexer` | `qe/indexer` | case records, embeddings (bge-m3 via Ollama), glossary | 1 vCPU / 2 GB |
| `exporter` | `qe/exporter` | DOCX/XLSX/PDF (LibreOffice headless), watermark, stamp | 2 vCPU / 2 GB |
| `scheduler` | `qe/scheduler` | daily digest, escalation, golden runs, retention | 0.5 vCPU |
| `postgres` | `pgvector/pgvector:pg16` | DDS-09 | 4 vCPU / 8 GB; 60 GB/y (measurements 3 y) |
| `redis`, `minio` | | queues; charts / exports / golden buckets | 256 MB; 20 GB/y exports |
| `ollama` / `ollama-cpu` | `ollama/ollama` | `qwen2.5:7b-instruct` (drafting), `bge-m3` (embeddings) | GPU ≥ 8 GB VRAM (NFR-03 needs the GPU); CPU profile is for dev |
| `mailpit`, `source-stub` | dev profile | SMTP sink; seed feeds | |

Total production host: 16 vCPU / 32 GB / 1 GPU / 500 GB NVMe.

## 3. Networks
| Network | Members | Egress |
|---|---|---|
| `frontend` | reverse proxy → `web`, `api` | LAN only, TLS |
| `internal` (`internal: true`) | everything except `web`, `source-stub` | **none** |
| `sources` (`internal: true`) | `spc-engine`, `signal-detector`, `correlator`, `scheduler` (+ `source-stub` in dev) | read-only feeds (IF-49) |
| `egress` | `api`, `scheduler` (+ `mailpit` in dev) | Discord / SMTP only — statistics and links (SEC-Q41) |

The drafting model has no route out and receives no tools (SEC-Q50). `check_deploy09.py` (TEST-09 TC-004) verifies the placement.

## 4. Installing
### 4.1 Steps
1. Host: Ubuntu 24.04, Docker 27, NVIDIA container toolkit (gpu profile), `chrony`, `TZ=Asia/Bangkok`.
2. `git clone …/09-quality-engineer-agent && cd deploy && cp .env.example .env && chmod 600 .env`; set `PUBLIC_URL`, `BIND_ADDR`, sizes.
3. Create `${SECRETS_DIR}` and the 15 secret files (§4.2).
4. `${CONFIG_DIR}`: `qe.yaml` (from `qe.example.yaml`), `prompts/`, `schemas/`, `templates/` (company DOCX/XLSX templates per kind × language), `glossary.csv`.
5. `docker compose --profile gpu up -d postgres minio minio-init` → `docker compose exec postgres psql -U qe -d qe -f /docker-entrypoint-initdb.d/01_schema.sql` (auto-applied on first start) → create the login roles (§4.2).
6. `docker compose --profile gpu up -d` → `docker compose exec ollama ollama pull qwen2.5:7b-instruct && ollama pull bge-m3`.
7. `qectl config load qe.yaml` → `qectl glossary load glossary.csv` → `qectl prompts register` (checksums into `prompt_template`) → `qectl fmea criteria load aiag_vda_2019.csv`.
8. `qectl selftest` (§4.5) → onboard characteristics (§5) → connect sources (§6).

### 4.2 Secrets (files, 0400, `root:10001`) and database login roles
| File | Used by | Content |
|---|---|---|
| `database_url` | `api` | `postgresql://app_rw:…@postgres/qe` |
| `engine_database_url` | `spc-engine`, `signal-detector`, `correlator`, `drafter`, `indexer`, `scheduler` | role `engine_rw` — cannot update `approved_by/approved_at` (DDS-09 §8) |
| `exporter_database_url` | `exporter` | role `exporter_ro` |
| `postgres_password` | `postgres` | superuser — never used by a service |
| `jwt_secret`, `url_signing_key` | `api` | 32+ random bytes each; rotate on incident |
| `s3_access_key`, `s3_secret_key` | all | MinIO root (standalone) — a scoped user in platform mode |
| `smtp_url`, `discord_webhook` | `api`, `scheduler` | notification endpoints |
| `source_inspection_url`, `source_production_url`, `source_telemetry_url`, `source_cmms_url`, `source_erp_url` | engine + `scheduler` | **read-only** accounts on the source systems (SEC-Q43); TEST-09 TC-113 attempts an INSERT |

Login roles: `CREATE ROLE app_rw LOGIN PASSWORD …` etc. for `app_rw`, `app_ro`, `agent_ro` (platform), `engine_rw`, `exporter_ro`; the grants are in `db/schema.sql`. Passwords are set at bootstrap (`SET_AT_BOOTSTRAP` in the schema comments) and stored only in the files above.

### 4.3 Models
| Model | Use | Rule |
|---|---|---|
| `qwen2.5:7b-instruct` (7 B) | drafting | ≤ 9 B, temperature ≤ 0.3 (`qe.yaml drafting.model`, schema-enforced); changing it = `qectl golden run` first (RB-08) |
| `bge-m3` | embeddings for case retrieval (AI-02) | changing it = re-embed (`qectl index rebuild`) + retrieval regression (TC-063) |

### 4.4 Templates
`${CONFIG_DIR}/templates/<kind>.<lang>.<version>.docx|xlsx` — company templates with the placeholders the exporter fills; the Japanese report template must carry the five sections in order (`export.japanese_report_sections`, constant). `qectl templates check` renders the seed's artefacts A1–A4 and verifies the watermark on every page of the DRAFT outputs (TC-080).

### 4.5 Start, load, verify
```
docker compose --profile gpu up -d
docker compose exec postgres psql -U qe -d qe -f /db/seed_demo.sql      # dev/staging only — see TEST-09 TC-009 expected \echo block
qectl selftest    # engine reference suite (NIST/Montgomery, 1e-6), SQL twins vs engine on the seed, facts schema, config, Ollama ping, exporter watermark
curl -s $PUBLIC_URL/api/v1/readyz    # {"ready":true,"mode":"full"}  — "statistics_only" when Ollama is down
```

### 4.6 Reverse proxy
TLS termination; `BIND_ADDR=127.0.0.1`; `/api/v1/metrics` allowed from the Prometheus host only; request body limit 8 MB; timeouts: `/cases/*/analyze` 30 s, `/cases/*/draft/*` 120 s, exports 90 s.

## 5. Characteristics, subgroups, limits, rules
1. **Create a characteristic** (`POST /characteristics`): line, SKU, chart type, USL/LSL, subgroup rule (FR-03: fixed n, time window, batch), unit, decimals.
2. **Baseline**: pick a stable window with ≥ 25 subgroups (`spc.baseline.min_subgroups`); fewer → limits flagged *provisional* on the chart (the seed's July limits were provisional and were superseded in August — DDS-09 §9).
3. **Calculate limits** (`POST /characteristics/{id}/limits` with `reason`). The row records baseline window, `sample_size`, author, reason; the previous row stays with `active = false` (RB-04).
4. **Rules** (`PUT /characteristics/{id}/rules`): default {1,2,3,5,6}; add 4/7/8 for characteristics prone to stratification/mixtures; the minimum set cannot be removed (`422 RULES_MINIMUM_SET`).
5. **Capability**: needs `min_n` (100) and the normality result; non-normal characteristics show the recommended method (Box-Cox by default) and never a naive Cp/Cpk (C-03).

## 6. Data sources (IF-49)
| Source | Connection | Health signal | If it fails |
|---|---|---|---|
| Inspection (01/03/05) | `source_inspection_url`, every `REFRESH_INSPECTION_S` | `qe_source_lag_seconds{source="inspection"}` | charts stop advancing; signals not computed; alert at lag > 30 min (RB-02) |
| Production (02) | `source_production_url`, hourly | same | rates fall back to inspection volumes with a data-quality note |
| Telemetry / alerts (06) | `source_telemetry_url`, on event | | timeline lacks alarms; correlations note it |
| CMMS | `source_cmms_url` | | mould/tool maintenance factors marked *unknown* |
| ERP / DocFlow lots | `source_erp_url` | | lot factor excluded; the correlation report says how many measurements lacked a lot id |

Defect codes are normalised through `core.defect_type`; unmapped codes appear on the data-quality panel and must be mapped by the admin (RB-03).

## 7. Signals, cases and notifications
- `signal-detector` runs every 15 min; the daily digest (06:00) lists open signals by score, suppressed signals with reasons, and yesterday's closures.
- HIGH/CRITICAL signals open a case and notify the default owner role (FR-12); notifications carry the rate, baseline, n, p, change point and a link — never artefact text (SEC-Q41).
- Trial runs (`POST /trial-runs`) suppress signals on their line/window; they need a reason and expire; review suppressed signals weekly (RB-05).
- Escalation at 07:00: overdue actions at 1 and 7 days → owner, then manager (FR-31).

## 8. Drafting, prompts, glossary, golden set
| Task | Command | Rule |
|---|---|---|
| Register prompt versions | `qectl prompts register` | checksum stored in `prompt_template`; a changed file without a new version fails to load (TC-058) |
| Change a prompt/model/ranking/facts schema | edit → `qectl golden run` → review `v_golden_summary` → deploy | ≥ 60 % top-3, 0 fabricated, else `blocked = true` and the change is not deployed (RB-08) |
| Load the glossary | `qectl glossary load glossary.csv` | forbidden variants must not be substrings of mandated terms (checked at load) |
| Add golden incidents | `qectl golden add incident.yaml` (append-only; reviewer required) | ≥ 20 incidents; objects in `golden/` (SEC-Q70) |
| Inspect grounding failures | `SELECT * FROM quality.v_evidence_audit WHERE untraced > 0` | a rising `qe_claims_untraced_ratio` means the prompt or facts object regressed |

## 9. Observability
| Signal | Where | Alert |
|---|---|---|
| `qe_source_lag_seconds{source}` | `/metrics` | > 1800 |
| `qe_chart_latency_seconds` p95 | | > 2 (NFR-01) |
| `qe_analyze_seconds` p95 | | > 20 (NFR-02) |
| `qe_draft_seconds` p95 | | > 90 (NFR-03) |
| `qe_llm_available` | | 0 for > 15 min (mode statistics_only — RB-06) |
| `qe_grounding_failed_total` rate | | > 20 % of drafts in a day (RB-09) |
| `qe_claims_untraced_ratio` | | > 0.05 |
| `qe_term_violations_total` | | trend up after a prompt change |
| `qe_signals_suppressed_total{reason}` | | trial_run suppression > 30 % of signals for a line (RB-05) |
| `qe_actions_overdue` | | > 10 |
| `qe_golden_top3_rate` / `qe_golden_blocked` | | blocked = 1 |
| `qe_export_watermark_mismatch_total` | | **> 0 → RB-11 immediately** |
| DB: `v_action_overdue`, `v_open_signals`, `v_export_watermark` | psql | |

Logs: JSON to stdout; audit in `audit.log` (approvals, exports, limits, ratings, closures) — never trimmed.

## 10. Retention, backup, restore
- Measurements 3 y (monthly partitions dropped by the scheduler), cases/artefacts/exports 10 y, golden runs 5 y, charts 90 d (regenerable).
- Backups: nightly `pg_dump` + WAL; MinIO `exports`/`golden` mirrored (object lock preserved); `${CONFIG_DIR}` in git.
- Restore drill quarterly: restore to staging, run `qectl selftest`, reconstruct an approval chain from `audit.log` (TC-116).

## 11. Upgrades and platform mode
- Upgrade: read the changelog; `qectl golden run` on the new image before promoting (RB-08); migrations are `quality_000N` (idempotent); schema changes to the shared `quality` section are platform changes (SAD-09 §9).
- Platform mode: drop `postgres`, `redis`, `minio`, `ollama`, `web` from this compose; point `*_database_url` at the platform database; apply `quality_0001`; the gateway serves the nine platform paths; tools registered per ICD-09 IF-16; bus topics per IF-17.

## 12. Verification commands and runbooks
### 12.1 Verification commands (TEST-09 TS-0 on the authoring machine; TC-009 on a host with Docker)
```
python check_openapi.py api/openapi.yaml                    # TC-008: valid, 44/50/44, 26/26 platform blocks verbatim
python assemble09.py --check                               # TC-002: 72/72 byte-identical
python check_schema09.py                                   # TC-003: counts, FK order, guards, grants
python check_seed09.py                                     # TC-005: SQL twins vs Python reference on the seed's inputs
python check_facts09.py                                    # TC-006: example valid, 13/13 negatives rejected
python check_config09.py                                   # TC-007: qe.example.yaml valid, prompts/glossary consistent, 20/20 negatives rejected
python check_deploy09.py                                   # TC-004: 17 services, 45 env vars both ways, 15 secrets, network placement
docker compose --profile cpu up -d postgres && psql -f db/schema.sql && psql -f db/seed_demo.sql   # TC-009 (not run here)
```

### 12.2 Runbooks
| ID | Situation | Steps |
|---|---|---|
| RB-01 | **Install / first start** | §4.1–4.5; `qectl selftest`; onboard 2 characteristics; verify one chart against the source system's own numbers |
| RB-02 | **Source feed lag** (`qe_source_lag_seconds` > 1800) | check the source account (read-only — an expired password is the usual cause); `docker compose logs spc-engine`; after recovery the detector back-fills the missed windows; note the gap on affected signals |
| RB-03 | **Unmapped defect code** | map in `core.defect_type` (admin UI); re-run detection for the affected window; do not analyse with the code unmapped |
| RB-04 | **Recalculate limits** | agree the baseline window with the engineer; `POST /characteristics/{id}/limits` with a reason; check the chart shows both eras; never touch `control_limits` by SQL (append-only trigger refuses anyway) |
| RB-05 | **Too many suppressed signals** | review `/signals?status=suppressed`; expire stale trial runs; if `min_sample` hides a real problem on a low-volume line, lower it with the engineer (≥ 30) |
| RB-06 | **Ollama down / mode statistics_only** | charts, signals, analysis keep working; drafts return 503; `docker compose restart ollama`; check VRAM; pending drafts retry once when `readyz.mode = full` |
| RB-07 | **Analysis slow (> 20 s)** | check `correlation.window_days`, the measurement partitions, `ENGINE_CPUS`; a missing `lot_id` index after a source change is the usual cause |
| RB-08 | **Prompt / model / ranking / facts-schema change** | change in git → `qectl prompts register` or config load → `qectl golden run` → `v_golden_summary`: ≥ 60 % and 0 fabricated → deploy; blocked → revert |
| RB-09 | **Grounding failures rising** | sample `v_evidence_audit`; typical causes: facts object missing a fact the prompt asks for (extend the engine/evidence), model rounding numbers (raise the rule in the prompt), a new artefact section without evidence; never relax the gate |
| RB-10 | **Term violations after a glossary change** | the check re-runs on revision; resolve in the editor or mark a justified exception; adjust forbidden variants that collide with mandated terms |
| RB-11 | **Watermark mismatch or an approved artefact with an untraced claim** | `APPROVALS_ENABLED=false` + restart `api`; pull `v_export_watermark` and `v_evidence_audit`; find the path (direct SQL? disabled trigger?); notify the artefact owner and any recipient; SEC-09 §7 |
| RB-12 | **Golden run blocked after an upgrade** | do not deploy; compare the failing incidents' hypothesis lists to the previous run (objects in `golden/`); usually a ranking or retrieval change; open a defect |
| RB-13 | **Restore** | restore `pg_dump` + WAL and the `exports`/`golden` buckets; `qectl selftest`; verify object lock; reconstruct one approval chain (TC-116) |
| RB-14 | **Platform migration** | §11; apply `quality_0001` on the platform DB; re-point secrets; register tools; verify TC-002 identity on the platform schema; run TC-091 scope test |

## 13. Traceability
| SRS-09 | OPS |
|---|---|
| FR-01…FR-07 | §5, RB-04 |
| FR-08…FR-12 | §7, RB-05 |
| FR-13…FR-18, NFR-02 | §6, RB-07 |
| FR-19…FR-26, AI-03, AI-06 | §8, RB-08, RB-09, RB-10 |
| FR-27…FR-31 | §7 |
| AI-05, AC-04 | §8, RB-08, RB-12 |
| AI-08, AC-09 | §1, RB-06 |
| C-01, AC-06, NFR-05 | §1, RB-11 |
| NFR-01…NFR-03 | §9 |
| NFR-06, NFR-07 | §3, §10 |
