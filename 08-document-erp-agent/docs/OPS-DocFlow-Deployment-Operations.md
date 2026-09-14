# Deployment & Operations Guide — DocFlow (AI Document → ERP Agent)

| Field | Value |
|---|---|
| Document ID | OPS-08-DocFlow |
| Version | 1.0 (Draft) |
| Date | 2026-09-14 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/docflow.example.yaml`](../deploy/docflow.example.yaml) · [`deploy/schemas/docflow-config.schema.json`](../deploy/schemas/docflow-config.schema.json) · [`deploy/schemas/extraction/`](../deploy/schemas/extraction/) · [`deploy/erp-export/`](../deploy/erp-export/) |
| Related | [SAD-08](SAD-DocFlow-Software-Architecture.md) · [DDS-08](DDS-DocFlow-Database-Design.md) · [ICD-08](ICD-DocFlow-Interface-Control.md) · [SEC-08](SEC-DocFlow-Security-Requirements.md) · [TEST-08](TEST-DocFlow-Test-Plan.md) · [UM-08](UM-DocFlow-User-Admin-Guide.md) · platform mode: [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) |
| Audience | Operator (install, mailbox/folder/ERP setup, backups, runbooks), finance admin (policies, STP, adapters), ML owner (models, prompts, evaluation), internal audit |

---

## 1. What you are operating
A system that turns supplier documents into ERP transactions. Three facts govern every procedure:

- **Every posting is a financial event.** The database refuses a posting without an approval by a sufficient role (and, above the threshold, by someone who did not edit the fields). Never work around this — not with a direct SQL insert, not with a "temporary" admin approval.
- **The ERP account is the crown jewel.** It can create purchase orders and invoices. It lives in one secret file, on one network (`erp`), used by two containers (`poster`, `scheduler`). Rotating it is a routine; widening it is an incident.
- **Straight-through processing is earned, not switched on.** A supplier/document pair auto-clears review only after ≥ 50 posted documents at ≥ 98 % accuracy without corrections, enabled by a named admin — and even then a human approval is recorded.

## 2. Topology and sizing
| Host | Runs | Notes |
|---|---|---|
| **App host** | reverse proxy (TLS), `web`, `api`, `intake-mail`, `intake-folder`, `worker-validate`, `poster`, `scheduler`, `redis` | 4 cores, 8 GB |
| **Pipeline host** (may be the app host) | `worker-ocr` (CPU, limited to `OCR_CPUS`/`OCR_MEMORY`), `worker-extract`, `ollama` (GPU: RTX 3060 Ti class handles a 7 B model at ≈ 20 s per 5-page document; CPU profile ≈ 2–3 min) | 500 documents/day (NFR-03) ≈ 21/hour → one GPU or 4 CPU workers |
| **Data host** | `postgres`, `minio` (`originals` bucket with object lock) | 60 GB database over 10 years; 3.5 TB objects over 7 years (DDS-08 §7) |

## 3. Networks
- `frontend`: reverse proxy → `api`/`web`; ports on `BIND_ADDR`, never 0.0.0.0.
- `internal` (`internal: true`): `postgres`, `redis`, `minio`, `ollama`, `worker-ocr`, `worker-extract`, `worker-validate` — **no route out**. The OCR worker opens untrusted files here; the model runs here.
- **`erp`**: only `poster` and `scheduler`. Firewall: this network reaches the ERP endpoint (or staging DB, or SFTP drop) and nothing else.
- `egress`: `api` (SMTP), `intake-mail` (IMAP), `intake-folder` (SFTP), `poster`/`scheduler` (SMTP, SFTP drop). A cloud model, if acknowledged, is reached from `worker-extract` only after adding it to `egress` deliberately (§8).

## 4. Installing

### 4.1 Steps
```bash
sudo mkdir -p /etc/docflow/secrets /srv/scans/docflow && sudo chmod 700 /etc/docflow/secrets
git clone <repo> && cd 08-document-erp-agent/deploy
cp .env.example .env && chmod 600 .env                   # BIND_ADDR, PUBLIC_URL, GPU_COUNT, OCR languages, crons
cp docflow.example.yaml /etc/docflow/docflow.yaml        # policies, gates, STP (all off), tolerances, adapters, intake sources
```

### 4.2 Secrets (files, 0400, `root:10001`) and database login roles
| File | Content | Used by |
|---|---|---|
| `postgres_password` | superuser (bootstrap) | postgres |
| `database_url` | `postgresql://df_app:<pw>@postgres:5432/docflow` — `df_app` LOGIN **in `app_rw`** | api, intake, workers, scheduler |
| `poster_database_url` | `postgresql://df_poster:<pw>@postgres:5432/docflow` — `df_poster` **in `poster_rw`** (cannot approve, edit or reconfigure) | poster |
| `jwt_secret`, `url_signing_key` | 48 random bytes each | api |
| `s3_access_key`, `s3_secret_key` | MinIO root / S3 user limited to the four buckets | all |
| `imap_ap_inbox` | `user:password` of the dedicated mailbox (read-only where supported) | intake-mail |
| `sftp_key` | private key for the scanner SFTP / ERP drop | intake-folder, poster |
| `erp_rest_token` | the ERP service account token — **read master data + create PO/invoice only** (SEC-D60) | poster, scheduler |
| `smtp_url`, `webhook_hmac` | notifications | api, poster, scheduler |
| `cloud_model_key` | empty file unless a cloud model is acknowledged (§8) | worker-extract |

After the first start:
```sql
CREATE ROLE df_app    LOGIN PASSWORD '…' IN ROLE app_rw;
CREATE ROLE df_poster LOGIN PASSWORD '…' IN ROLE poster_rw;
CREATE ROLE df_audit  LOGIN PASSWORD '…' IN ROLE auditor_ro;
```

### 4.3 Models and OCR packs
```bash
docker compose --profile gpu up -d ollama && docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M    # ≤ 9 B, local
docker compose run --rm -v models:/models worker-extract dfctl models pull --manifest /etc/docflow/models.json  # classifier, injection model, checksums
# OCR language packs (tha, jpn, jpn_vert, eng) are baked into the worker-ocr image; the paddle profile pulls PaddleOCR models into the same volume
dfctl models register --kind extraction --name qwen2.5-7b-instruct-q4_K_M --version 2025.06 --checksum sha256:…   # model_registry, cloud = false
```

### 4.4 ERP adapter, mailbox, folder
1. **ERP**: the ERP admin creates the service account (SEC-D60) and — for the staging-table kind — the staging table with `UNIQUE (idem_key)`; for the file kind, the drop share and the import job that rejects repeated keys (ICD-08 IF-48; the ERP owner signs off). `dfctl adapters test erp-rest` performs read-only lookups only.
2. **Mailbox**: a dedicated address with a `DocFlow` folder; suppliers are told to send there; the credential is read-only where the server allows.
3. **Hot folder**: the scanner writes to `/srv/scans/docflow`; DocFlow moves files to `processed/` and `rejected/`.

### 4.5 Start, load, verify
```bash
docker compose --profile gpu up -d                      # or --profile cpu; --profile paddle for PaddleOCR; --profile dev for mailpit + fake ERP
dfctl config load /etc/docflow/docflow.yaml             # PUT /config — schema-validated; STP off for every pair unless evidence is present
dfctl master-data sync                                  # suppliers, items, price lists, open POs, goods receipts (read-only adapter calls)
curl -s http://$BIND_ADDR:8080/api/v1/readyz            # db, redis, object_store, ocr, model, erp true; backlog {}
dfctl privacy-check                                     # verifies: no egress from internal, originals locked, poster cannot approve (TC-004 quick form)
```
Demo data (non-production only): `psql … -f ../db/seed_demo.sql` reproduces Appendix A and AC-02…AC-09.

### 4.6 Reverse proxy
TLS, HSTS, CSP for the review UI, client body limit 51 MB, `/metrics` blocked from outside, `X-Forwarded-For` passed (audit records IPs).

## 5. Day-to-day operation

### 5.1 Observability
| Signal | Where | Meaning |
|---|---|---|
| `/readyz` | API | db, redis, object store, OCR, model, ERP reachability, backlog per stage, oldest age, `cloud_model_enabled` |
| Metrics (IF-14) | `:8080/metrics` | intake, stage latencies/backlogs, schema-repair rate, gate outcomes, queues, posting attempts, injection flags, cloud calls, eval metrics, drift |
| Views | `v_pipeline_backlog`, `v_review_queue`, `v_exception_queue`, `v_stp_eligibility`, `v_template_drift`, `v_eval_latest` | operational state |
| Audit | `audit.log`, `access_log`, `v_audit_export` | approvals, postings, corrections, reads, config, cloud |

Alerts about DocFlow itself:

| Alert | Condition | Runbook |
|---|---|---|
| Pipeline backlog | oldest `received`/`classified`/`extracted` > 15 min | RB-01 |
| Model down | Ollama unreachable 5 min | RB-02 |
| OCR failures | `quality_too_low` > 10 % of the day | RB-03 |
| Schema repairs rising | `df_schema_repair_total` > 20 % of extractions | RB-04 |
| Exception queue | any posting with `attempts = 5`, or > 10 items | RB-05 |
| ERP unreachable | `readyz.erp = false` 10 min | RB-06 |
| **Posting-control anomaly** | a `posting` without a matching approval (should be impossible), or an ERP transaction without a DocFlow posting (reconciliation) | **RB-07 (page)** |
| Mailbox / folder errors | `intake_source.last_error` set 15 min | RB-08 |
| Injection flags spike | > 3× the 30-day daily mean | RB-09 |
| Cloud model calls | any, when policy says local-only | RB-10 |
| Template drift | `v_template_drift.drift_alert` | RB-11 |
| Evaluation blocked | `v_eval_latest.release_blocked` on the active versions | RB-12 |
| Disk / object lock | database > 80 %; bucket lock misconfigured | RB-13 |
| Duplicate invoices rising | `duplicate.invoice = fail` > 5/day | RB-14 |

### 5.2 SLOs
| SLO | Target | Measured by |
|---|---|---|
| Intake → validated | ≤ 60 s p95 for a 5-page digital PDF (NFR-01) | stage timestamps |
| Review UI | ≤ 2 s (NFR-02) | web vitals |
| Throughput | ≥ 500 documents/day (NFR-03) | daily count |
| Availability of intake | ≥ 99 % (NFR-08); queue, never reject | synthetic upload every 5 min |
| Duplicate ERP transactions | **0** | reconciliation (RB-07) |
| Postings without approval | **0** | `audit.log` join, hourly |

### 5.3 Queues and staffing
Review queue (`review_required`) is worked by clerks/AP by age; approvals above the threshold by managers. Rule of thumb: 3 minutes per reviewed document; 500 documents/day with STP off ≈ 25 person-hours — the reason to earn STP per supplier (§7). The exception queue (`posting_failed`, `extraction_failed`, `quality_too_low`) is AP's; retries are one click; rescans are requested from the sender with the rejection reply.

### 5.4 Master data and price lists
`MASTER_SYNC_CRON` pulls suppliers, items, price lists, open POs and goods receipts through the adapter's read calls every 30 minutes; `synced_at` on every row; a stale sync (> 2 h) shows on `/readyz`. Aliases (supplier names, part numbers) are maintained by AP in the UI as documents reveal them.

## 6. Security operations
- **ERP credential rotation**: quarterly, or on any suspicion: new token in the file → `docker compose restart poster scheduler` → old token revoked in the ERP.
- **Reconciliation** (SEC-D63): nightly job lists ERP transactions created by the DocFlow account and compares with `posting.erp_ref`; any transaction without a posting row pages (RB-07).
- **Access review**: quarterly sample of `access_log` (who viewed originals) and of approvals above the threshold (who, SoD honoured).
- **Injection flags**: weekly review of flagged documents by sender; repeated senders are reported to the supplier's real contact.
- Cloud model: §8.

## 7. Straight-through processing — how a pair earns it
1. Run with STP off. Every posted document counts; `v_stp_eligibility` shows, per (supplier, kind), posted documents and the share posted **without any correction**.
2. When a pair reaches ≥ 50 posted and ≥ 98 %, an admin may enable it: `PUT /stp/{kind}/{supplier}` `{enabled: true}` — the database CHECK refuses without the evidence; the change is audited with the admin's name.
3. Auto-cleared documents skip review but still need an approval (C-01). Watch `v_template_drift`; a −5-point drift alert on the pair means disable STP until the template is fixed and accuracy recovers.
4. Never enable STP globally; the configuration cannot express it.

## 8. Models, prompts, schemas, evaluation, cloud
- **Every change is a version**: model (`model_registry`), prompt (`prompt_version`), schema (`extraction_schema`). Register → run the evaluation (`EVAL_CRON` weekly, or `dfctl eval run`) on the 200-document set (stored encrypted outside the repository) → `v_eval_latest`: below target or −2 points → `release_blocked` → do not activate (AI-09).
- **Cloud model** (NFR-07): default off. To enable: an admin sets `models.cloud` in `docflow.yaml` with provider, model, `acknowledged_by/at`, the fixed statement and the credential ref, puts the key in `cloud_model_key`, adds `worker-extract` to the `egress` network in a compose override, and loads the config. The load writes `docflow.cloud_model_enabled` to the audit log; every extraction shows `cloud = true` in the review UI; RB-10 fires on every call while policy says local-only. Disable by reverting the config and removing the override.
- **Templates**: created from corrections (`dfctl templates suggest --supplier SUP-0142`), measured on the supplier's next 20 documents, activated by AP/admin; one active per (supplier, kind).

## 9. Retention, backup, restore
- Originals: object lock, compliance, 7 years — nobody can delete them, including the storage admin. Page images: regenerable; 2 years. Exports: 30 days. Audit: 7 years.
- Database: nightly `pg_dump`; weekly base backup; restore test quarterly. A restore must be followed by reconciliation against the ERP (`dfctl reconcile --since`), since postings created after the backup exist in the ERP.
- Objects: replicate `originals` to a second locked bucket.
- Retention deletion after 7 years is an admin job: postings first, then documents (the trigger refuses otherwise), with an audit row per document.

## 10. Upgrades
Pull images → `docker compose up -d`; migrations forward-only at API start with a pre-migration dump; any change to the approval or posting triggers re-runs TC-003 probes and TC-070/071 in CI before deploy; any change to a prompt, schema or model goes through §8.

## 11. Platform mode
Apply `db/schema.sql` §10 onward as migration `docflow_0001` on the platform database (OPS-00 migration procedure); create `df_poster`/`df_audit` login roles; point the containers at the platform DB, Ollama, object store and auth; register `get_document_status` in the tool registry; the four API-00 paths are served by the gateway, the rest mounts under `/docflow/`.

## 12. Runbooks
| RB | Symptom | Diagnose | Fix |
|---|---|---|---|
| **RB-01** | Pipeline backlog | `v_pipeline_backlog`; which stage; worker logs | Add workers for the stage; if OCR, check `OCR_TIMEOUT_S` hits (poor scans); intake and review are unaffected (P-2) |
| **RB-02** | Model down | `nvidia-smi`; Ollama logs | Restart; switch to the `cpu` profile until repaired; extraction resumes from the queue; nothing lost |
| **RB-03** | OCR quality failures | sample the `quality_too_low` documents | Usually a scanner setting (dpi, contrast); request rescans via the rejection reply; consider the `paddle` profile for TH/JA |
| **RB-04** | Schema repairs rising | which supplier/kind; prompt or model changed? | A supplier layout change → template (§8); a prompt regression → roll back `PROMPT_VERSION`; never loosen the schema |
| **RB-05** | Exception queue growing | `v_exception_queue` by kind and adapter error | ERP errors → RB-06; extraction failures → RB-04; each item is retried or rejected by AP with a reason |
| **RB-06** | ERP unreachable | `readyz.erp`; adapter test (read-only) | Postings wait in `posting_failed` with backoff; nothing half-posted; fix connectivity; retries drain |
| **RB-07** | **Posting-control anomaly** | `SELECT p.* FROM docflow.posting p LEFT JOIN docflow.approval a … WHERE a.id IS NULL`; reconciliation report | Should be impossible: deactivate the adapter; preserve evidence; finance reverses in the ERP; post-mortem on how the trigger or the account was bypassed (SEC-08 §7) |
| **RB-08** | Mailbox / folder errors | `intake_source.last_error` | Credential expired → rotate; folder unmounted → remount; mails stay on the server, files stay in place |
| **RB-09** | Injection flags spike | flagged documents by sender | Quarantine the sender in the intake source; review flagged documents; report to the supplier |
| **RB-10** | Cloud model calls while policy is local-only | `audit.log docflow.cloud_model_enabled`; config version | Revert config; remove the egress override; list affected extractions (`extraction.cloud = true`) for review |
| **RB-11** | Template drift | `v_template_drift` | Disable STP for the pair; suggest a new template from recent corrections; measure; activate |
| **RB-12** | Evaluation blocked | `v_eval_latest.block_reason` | Do not activate the candidate; investigate the metric; the active versions keep running |
| **RB-13** | Disk / lock | `pg_database_size`; `mc retention info` | Extend volumes; never relax the lock; page images may be purged and regenerated |
| **RB-14** | Duplicate invoices rising | senders and numbers | Usually a supplier re-sending scans of emailed invoices; they are blocked and linked — inform the supplier; check for a genuine fraud pattern |

## 13. Traceability
| SRS-08 | Section |
|---|---|
| C-01, NFR-05 | §1, §5.2, RB-07 |
| C-04, FR-31, FR-32 | §4.4, §5.3, RB-05, RB-06, RB-07 |
| C-05, NFR-07 | §3, §8, RB-10 |
| C-06, NFR-06 | §9, RB-13 |
| FR-01, FR-02 | §4.4, RB-08 |
| FR-14, AI-06 | §8 templates, RB-11 |
| FR-16…FR-19 | §5.4 |
| FR-29 | §7 |
| AI-03, AI-08, AI-09 | §8, RB-12 |
| AI-07 | §6, RB-09 |
| NFR-01…NFR-03, NFR-08 | §2, §5.2, RB-01, RB-02 |
| IF-07 | §4.2, §4.4, §6 |
