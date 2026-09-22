# Deployment & Operations Guide — GenbaGo (Japanese Factory Translator Agent)

| Field | Value |
|---|---|
| Document ID | OPS-14-GenbaGo |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SAD-14](SAD-GenbaGo-Software-Architecture.md) · [DDS-14](DDS-GenbaGo-Database-Design.md) · [SEC-14](SEC-GenbaGo-Security-Requirements.md) · [TEST-14](TEST-GenbaGo-Test-Plan.md) |
| Artefacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/genbago.example.yaml`](../deploy/genbago.example.yaml) · [`deploy/schemas/genbago-config.schema.json`](../deploy/schemas/genbago-config.schema.json) · [`deploy/prompts/`](../deploy/prompts/) · [`deploy/minio-init.sh`](../deploy/minio-init.sh) · [`deploy/initdb/20-roles.sh`](../deploy/initdb/20-roles.sh) · [`db/schema.sql`](../db/schema.sql) · [`db/seed_demo.sql`](../db/seed_demo.sql) |
| Parent | [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) for platform mode (§2) |

---

## 1. Topology

**Standalone** (this compose file): one host, one 8 GB GPU.

| Service | Role | Network | DB role |
|---|---|---|---|
| web | review UI, glossary admin, dashboard | frontend | — |
| api | API-14, IF-16 tools, signed URLs | frontend, internal | `app_rw` |
| worker-translate | segmentation → TM → model → segments; interpretation | internal | `worker_rw` |
| worker-ocr | IF-76 OCR | internal | `worker_rw` |
| worker-doc | IF-77 documents, batches | internal | `worker_rw` |
| indexer | embeddings, document tags, mining | internal | `worker_rw` |
| scheduler | monthly evaluation, usage rollup, retention | internal | `app_rw` |
| postgres (pgvector) | the source of truth | internal | — |
| redis | queues, GPU semaphore | internal | — |
| minio (+ minio-init) | IF-10 buckets | internal | — |
| ollama / ollama-cpu | IF-09 | internal | — |
| discord-bot (profile) | IF-08 `/jp` | internal, **egress** | — (viewer token) |
| mailpit (dev) | SMTP sink | internal | — |

Sizing: CPU 8 cores, RAM 32 GB (OCR + document rendering are memory-heavy), GPU 8 GB (qwen2.5:7b q4 ≈ 5 GB), disk 200 GB (documents 365 d; TM is small — 500 k segments ≈ 2 GB with vectors).

## 2. Platform mode

GenbaGo is a **medium-coupled** platform module (SAD-14 §9): run only `api` (as the platform's `/knowledge/translate` + `/genba/*` module), the three workers and the indexer; use the platform's postgres (apply `db/schema.sql` sections 10–19 as migration `genba_0001`), redis, minio (buckets under the platform's tenant), ollama (GPU semaphore) and notifier. `discord-bot` and `web` are not started; the platform web hosts the review UI. Register the three IF-16 tools in `agent.tool`. Related documents come from Genba Memory's `knowledge.document` (IF-19).

## 3. Installation (standalone)

```bash
git clone … && cd 14-japanese-factory-translator/deploy
cp .env.example .env && chmod 0600 .env                # edit PUBLIC_URL, BIND_ADDR, DEFAULT_LOCALE
sudo mkdir -p /etc/genbago/secrets /etc/genbago/prompts /etc/genbago/schemas
sudo cp genbago.example.yaml /etc/genbago/genbago.yaml  # edit; validate: python -c "import json,yaml,jsonschema;jsonschema.validate(yaml.safe_load(open('/etc/genbago/genbago.yaml')),json.load(open('schemas/genbago-config.schema.json')))"
sudo cp prompts/*.md /etc/genbago/prompts/ && sudo cp schemas/*.json /etc/genbago/schemas/ && sudo cp check-items.example.yaml /etc/genbago/check-items.yaml
# secrets — §4
docker compose --profile gpu pull
docker compose --profile gpu up -d postgres redis minio minio-init
docker compose --profile gpu up -d                     # api waits for postgres/redis/minio; workers wait for api's /readyz
docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M
curl -s http://127.0.0.1:8080/readyz                    # {"status":"ready","model":"qwen2.5:7b-instruct-q4_K_M","ocr":"not_measured"}
```

The first `postgres` start applies `db/schema.sql` (extensions `vector`, `pg_trgm`, `pgcrypto`; schemas `core`, `knowledge`, `audit`, `genba`; roles) and `initdb/20-roles.sh` (role passwords from the URL secret files). For a demo instance: `docker compose exec -T postgres psql -U genbago -d genbago < ../db/seed_demo.sql` (§12).

## 4. Secrets

All twelve are files under `${SECRETS_DIR}` (0400, owner root, group 10001):

| File | Content | Used by |
|---|---|---|
| `postgres_password` | superuser password | postgres |
| `database_url` | `postgresql://app_rw:<pw>@postgres:5432/genbago` | api, scheduler |
| `worker_database_url` | `postgresql://worker_rw:<pw>@postgres:5432/genbago` | workers, indexer |
| `jwt_secret` | 48 random bytes | api |
| `tool_token` | bearer for IF-16 consumers (Copilot, QE-Agent) | api |
| `bot_api_token` | a viewer token for the bot | discord-bot |
| `minio_root_user`, `minio_root_password` | MinIO admin | minio, minio-init |
| `s3_access_key`, `s3_secret_key` | the app user created by minio-init with the `genbago-app` policy | api, workers, scheduler |
| `discord_token`, `discord_channel_id` | bot | discord-bot |

Generate: `openssl rand -base64 36 > /etc/genbago/secrets/jwt_secret`. Rotate quarterly (SEC-00 §5); rotating a database URL means re-writing the file and `docker compose up -d --force-recreate api worker-translate worker-ocr worker-doc indexer scheduler`. There is **no cloud MT key**; if a plant ever enables a cloud provider for non-confidential text, it is a new secret and a config change reviewed under SEC-J11.

## 5. Configuration

`genbago.yaml` is validated against the schema at start; a value that is also a `genba.setting` row must be equal to it or `api` refuses to start (`CONFIG_MISMATCH` in the log). Change a threshold in the database first (`UPDATE genba.setting SET value_num = … WHERE key = …` as admin — the CHECK constraints keep it inside the SRS bounds), then in the file, then restart. Constants (glossary enforcement, numbers blocking, interpretation separate, confidential default, local provider) cannot be changed by configuration at all.

## 6. Glossary lifecycle

1. **Seed** from existing bilingual documents: fill `glossary.csv` (columns as [`deploy/glossary.example.csv`](../deploy/glossary.example.csv)), `POST /glossary/import` as admin (or `\copy` + the guard triggers). Every row becomes version 1 with the importer as approver and `effective_from`.
2. **Mining loop**: the indexer runs `mine_candidates()` after approvals; candidates with ≥ `candidate_min_count` occurrences and a stable rendering appear under `/glossary/candidates`; admin accepts (→ a term with a version) or rejects with a note.
3. **Change**: `POST /glossary` (upsert by `ja`) as admin with `effective_from` and a note → a new `term_version`; `v_glossary_current` shows the version in force; QE-Agent and Copilot see the change at its effective date.
4. **Forbidden renderings**: per target language; never equal to the mandated one (probe 9).
5. **Aliases** (社内用語, abbreviations): `POST /glossary/{id}/aliases`.
6. **Export** TBX/CSV monthly to `genbago-exports` (locked) — `POST /glossary/export`.
7. **Consistency review**: `v_term_consistency` monthly; a term with more than one rendering in use is a QE-lead action item (FR-26).

## 7. Translation memory, OCR and documents

**TM bootstrap**: align existing bilingual documents (an aligner produces TMX), review the alignment in the web UI (`/tm/import` creates rows as *proposed*; a reviewer approves in bulk), or import an approved TMX directly as a reviewer. Rows with the same normalised source and a different target are rejected and listed (`TM_DUPLICATE_SOURCE`). Memory is immutable: a correction is a new segment with a later date, and `tm_lookup()` prefers the newest.

**OCR setup**: pull the JA vertical model into the `ocr-models` volume (`docker compose run --rm worker-ocr ocr-models pull`); measure accuracy on the plant's printed sample set (`docker compose run --rm worker-ocr ocr-eval /samples`) — the measured value goes into `ocr.measured_accuracy`; while it is null or < 0.95, OCR jobs return `NOT_READY` (AI-06). Handwriting is always flagged, never measured.

**Documents**: DOCX/XLSX/PPTX are rebuilt with the original styles; PDF defaults to side-by-side; images to keep-layout. `MAX_FILE_MB` 50, batches ≤ 500 files. A failed file leaves the batch `failed`; `POST /jobs/{id}/resume` restarts at the first unfinished file.

## 8. Evaluation

The scheduler runs `EVAL_SCHEDULE` (monthly): every test-set segment is translated with the current model/prompts/glossary, metrics are computed (`eval_finalize()`), and `trg_eval_gate` decides `passed` (glossary ≥ 0.98, numbers = 1, PED ≤ 0.20 JA→TH, classification ≥ 0.90) and `investigate` (any metric worse than the previous run by > 2 %). `v_eval_gate` and `/eval/runs` show the history; an `investigate` run notifies the ML owner (IF-13).

**Build the plant sets** (the seed carries 40; the SRS needs ≥ 200 segments and ≥ 300 labelled sentences): export approved segments by domain (`/tm/export?domain=…`), have a reviewer confirm each reference, import as a new test-set version (`POST /test-sets/import`). A set is frozen once a run uses it.

**Release checklist** (SEC-J23) for a prompt, keyword, check-item or model change: change on staging → eval run passes with no `investigate` → version bump (`prompts.*` in `genbago.yaml`) → deploy → the next monthly run confirms.

## 9. Confidentiality operations

- Every job is confidential unless the caller says otherwise; confidential ⇒ local provider, never Discord (CHECK `job_confidential_local`).
- `/jp` in Discord is for short, non-confidential text; the bot refuses attachments and says so. Post the policy in the channel topic.
- Signed URLs expire in ≤ 15 min; results inherit the source ACL; confidential reads are audit rows.
- The workers have no route out (`internal` network); only `discord-bot` reaches the internet.
- Retention: documents and results 365 d (MinIO lifecycle + the scheduler nulls segment text), exports locked 730 d, glossary versions and memory forever, audit 2 y.

## 10. Monitoring

| Metric / view | Watch for |
|---|---|
| `genbago_translate_latency_ms` p95 | > 5 s (NFR-01) — GPU contention, model reload (`OLLAMA_KEEP_ALIVE`) |
| `genbago_job_duration_ms{kind=document}` | > 3 min per 20 pages (NFR-02) |
| `genbago_tm_hit_rate{pair}` | falling — memory not growing (approvals stalled) |
| `genbago_blocked_total`, `genbago_flagged_total{flag}` | a jump after a model/prompt change |
| `genbago_ped` histogram / `v_quality_dashboard` | PED trend up — RB-09 |
| `genbago_glossary_compliance{pair}` | < 0.98 — RB-06 |
| `genbago_ocr_low_confidence_total` | growing share — camera/lighting or handwriting |
| `genbago_eval_last_passed` | 0 — RB-09 |
| `v_review_queue` | age of the oldest `needs_review` > 2 days |
| `v_ocr_flags` | regions awaiting review |

Alerts: `/readyz` failing 3× → page; `investigate = true` → ML owner; blocked segments > 5 % of a day's segments → QE lead.

## 11. Runbooks

| ID | Situation | Steps |
|---|---|---|
| RB-01 | Fresh install / upgrade | §3; `docker compose pull && up -d`; migrations are idempotent (`genba.migration`); run TC-003 on a copy first |
| RB-02 | Rotate a secret | write the file; recreate the services that mount it (§4); for `tool_token` also update Copilot/QE-Agent |
| RB-03 | Model unavailable (`/readyz` `model: missing`) | `ollama pull`; check GPU (`nvidia-smi`); fall back to `--profile cpu` for a short outage; `/translate` returns `NOT_READY`, document jobs continue with gaps (SEC-J25) |
| RB-04 | A check looks wrong (false block / miss) | reproduce with `SELECT genba.run_checks(src, tgt, 'ja', 'th')`; compare with the Python twin (`seed14.py`); if the twin agrees, fix data (unit alias, ratio bound, glossary) not code; else open a defect and add a TC |
| RB-05 | Glossary import rejected rows | read the import report; `FORBIDDEN_IS_MANDATED`, `GLOSSARY_APPROVER`, duplicate JA — fix the CSV; never bypass the guard |
| RB-06 | Wrong mandated rendering in force | admin creates a new version with the correct rendering and `effective_from = today`; the old version stays in history; re-run `rollup_term_usage()`; segments approved with the wrong rendering are listed by `v_term_consistency` for re-translation |
| RB-07 | Wrong approved TM segment | do not edit (immutable); approve a corrected segment (new job) — it supersedes by date; note the old id in the new segment's `doc_ref` |
| RB-08 | Segment audit (I-1 / I-4) | `SELECT * FROM genba.v_segment_checks WHERE job_id = …`; `segment_edit` history; `interpretation` row and its `related_docs_json` vs `knowledge.document`; result object version in MinIO |
| RB-09 | Evaluation regression | compare `eval_result` rows of the two runs by segment; group by failure kind (glossary / numbers / PED / class); revert the last prompt/keyword change if it explains it; re-run |
| RB-10 | Confidentiality incident (I-2) | identify the job (`translation_job.provider`, `channel`); if Discord, delete the message and record the audit row; if a cloud provider was ever configured, remove it and rotate its key; report per SEC-00 |
| RB-11 | Batch stuck / failed file | `GET /jobs/{id}/files`; fix the file; `POST /jobs/{id}/resume`; a corrupt file can be skipped by cancelling that `job_file` |
| RB-12 | OCR accuracy below gate | re-measure with a better sample (lighting, resolution); do not lower `char_accuracy_gate`; keep OCR jobs refused until ≥ 0.95 |
| RB-13 | Restore from backup | `pg_restore` the nightly dump; restore MinIO buckets (versioned); the `\echo` totals of the seed are the smoke test on a demo instance |
| RB-14 | Retention run | the scheduler deletes expired objects and nulls segment text; approved TM rows are kept; verify with `SELECT count(*) FROM genba.segment WHERE src_text IS NULL AND created_at < now() - interval '365 days'` |

## 12. Verification on a real database

The authoring machine had no PostgreSQL; these commands complete TEST-14 TC-003.

```bash
# 12.1 DDL + seed + probes
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U genbago -d genbago -f /docker-entrypoint-initdb.d/10-schema.sql   # idempotent re-apply
docker compose exec -T postgres psql -U genbago -d genbago < ../db/seed_demo.sql 2>&1 | tee seed.log
grep -c "^ERROR" seed.log            # expect 16 — one per probe, each with its named code (SEGMENT_BLOCKED … CONFIDENCE_BELOW_THRESHOLD)
grep "expected:" seed.log            # jobs 9, segments 28, approved 13, tm 53, tm_index 53, interpretations 5, readings 3, ocr_regions 7, edits 3, term_versions 31, eval_results 120

# 12.2 twins on the live database (compare with seed14_expect.json)
psql -c "SELECT genba.extract_codes('公差 ±0.05 mm / 3.2 mm / LOT-2609-114')"           # {±0.05mm,3.2mm,LOT-2609-114}
psql -c "SELECT genba.edit_distance('厚さ 3.5 mm', '厚さ 3.2 mm')"                        # 0.0588 (normalised)
psql -c "SELECT * FROM genba.classify('成形条件を変更した後、不良率が上昇しました。')"   # injection_molding / problem_report / 0.91
psql -c "SELECT * FROM genba.v_eval_gate"                                                 # three runs: pass, pass, pass+investigate

# 12.3 roles
psql -U worker_rw -c "INSERT INTO knowledge.glossary_term (ja, th, en) VALUES ('x','x','x')"   # permission denied (SEC-J15)
psql -U auditor_ro -c "SELECT count(*) FROM genba.segment_edit"                                # 3
```
