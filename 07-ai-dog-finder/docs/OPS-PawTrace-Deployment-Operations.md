# Deployment & Operations Guide — PawTrace (AI Dog Finder 2.0)

| Field | Value |
|---|---|
| Document ID | OPS-07-PawTrace |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/postgres/Dockerfile`](../deploy/postgres/Dockerfile) · [`deploy/pawtrace.example.yaml`](../deploy/pawtrace.example.yaml) · [`deploy/schemas/pawtrace-config.schema.json`](../deploy/schemas/pawtrace-config.schema.json) |
| Related | [SAD-07](SAD-PawTrace-Software-Architecture.md) · [DDS-07](DDS-PawTrace-Database-Design.md) · [ICD-07](ICD-PawTrace-Interface-Control.md) · [SEC-07](SEC-PawTrace-Security-Requirements.md) · [TEST-07](TEST-PawTrace-Test-Plan.md) · [UM-07](UM-PawTrace-User-Admin-Guide.md) |
| Audience | Operator (install, providers, backups, runbooks), ML owner (model lifecycle), moderation lead (staffing), privacy officer (requests) |

---

## 1. What you are operating
A public web service where distressed people post where they live and strangers tell them where to go. Three operational facts follow:

- **A privacy failure is a launch-blocking incident, not a bug.** The system is built so that the public database role cannot read a coordinate; keep it that way: never grant `public_ro` anything, never point a public handler at the `app_rw` pool, and run TC-060 after every deploy.
- **Anonymous posting means abuse is normal traffic.** Moderation is staffed, not optional; rate limits and CAPTCHA thresholds are tuned from the weekly abuse report, not set once.
- **Model changes are data migrations.** A new embedding model is registered, benchmarked, re-embedded in the background and activated atomically. Never overwrite an artefact.

## 2. Topology and sizing
| Host | Runs | Notes |
|---|---|---|
| **App host** | reverse proxy (TLS), `web`, `api`, `worker-match`, `scheduler`, `redis` | 4 cores, 8 GB for a city; `api` scales horizontally behind the proxy |
| **Vision host** (may be the app host) | `worker-vision-gpu` (RTX 3060 Ti class: ≈ 0.6 s per photo, batch 16) or `worker-vision-cpu` (≈ 4 s per photo) | GPU optional (NFR-08); CPU profile for low volume |
| **Data host** | `postgres` (PostGIS + pgvector), `minio` | NVMe: 64 GB database at NFR-03 (DDS-07 §7), 2 TB objects at 1 M photos |

Throughput rule of thumb: one GPU worker ≈ 5,000 photos/hour; one `worker-match` ≈ 20 candidate searches/second at 1 M vectors; `api` ≈ 300 req/s per replica.

## 3. Networks
- `frontend`: reverse proxy → `api` (8080) and `web` (3000), ports bound to `BIND_ADDR` (never 0.0.0.0). TLS, HSTS and rate-limit headers terminate at the proxy.
- `internal` (`internal: true`, no route out): `postgres`, `redis`, `minio`, vision workers. A vision worker cannot reach the Internet.
- `egress`: `api` (CAPTCHA verify, geocoder, SMTP), `worker-match` (push, SMTP), `scheduler` (SMTP). Firewall egress to the configured providers only.
- Public paths of `api` use the `public_database_url` pool (`public_ro`); authenticated paths use `database_url` (`app_rw`); workers use `worker_rw` (DDS-07 §8).

## 4. Installing

### 4.1 Steps
```bash
sudo mkdir -p /etc/pawtrace/secrets && sudo chmod 700 /etc/pawtrace/secrets
git clone <repo> && cd 07-ai-dog-finder/deploy
cp .env.example .env && chmod 600 .env                 # BIND_ADDR, PUBLIC_URL, providers, GPU_COUNT
cp pawtrace.example.yaml /etc/pawtrace/pawtrace.yaml   # regions, thresholds — edit per §4.4
docker compose build postgres                          # PostGIS 16-3.4 + pgvector (deploy/postgres/Dockerfile)
```

### 4.2 Secrets (files, 0400, `root:10001`) and database login roles
| File | Content | Used by |
|---|---|---|
| `postgres_password` | superuser password (bootstrap only) | postgres |
| `database_url` | `postgresql://pt_api:<pw>@postgres:5432/pawtrace` — `pt_api` is a LOGIN role **in `app_rw`** | api (authenticated), scheduler |
| `public_database_url` | `postgresql://pt_public:<pw>@postgres:5432/pawtrace` — `pt_public` **in `public_ro`** (no `location` grant) | api (public paths) |
| `jwt_secret`, `url_signing_key` | 48 random bytes each | api, worker-match |
| `s3_access_key`, `s3_secret_key` | MinIO root / S3 IAM user restricted to the four buckets | all |
| `vapid_private` (+ `VAPID_PUBLIC_KEY` in `.env`) | `web-push generate-vapid-keys` | worker-match, web |
| `fcm_server_key` | Firebase (only if the Flutter app is shipped) | worker-match |
| `captcha_secret` (+ `CAPTCHA_SITE_KEY` in `.env`) | Turnstile/hCaptcha | api |
| `smtp_url` | `smtps://user:pass@host:465` (dev: `smtp://mailpit:1025`) | api, worker-match, scheduler |

After the first start create the login roles (the schema creates the NOLOGIN group roles):
```sql
CREATE ROLE pt_api    LOGIN PASSWORD '…' IN ROLE app_rw;
CREATE ROLE pt_public LOGIN PASSWORD '…' IN ROLE public_ro;
CREATE ROLE pt_worker LOGIN PASSWORD '…' IN ROLE worker_rw;
```
Workers use `pt_worker` in their `database_url` (set a separate secret file if you want the split; the compose example shares one for brevity — production should not).

### 4.3 Model artefacts
```bash
docker compose run --rm -v models:/models worker-vision-cpu ptctl models pull --manifest /etc/pawtrace/models.json
# pulls detector, re-ID embedding v1 (768-d), attribute head, NSFW screen, multilingual text model into the read-only `models` volume,
# verifies checksums, and registers each as a pawtrace.model_version (embedding v1 needs a benchmark before activation — §7)
```

### 4.4 Start, load the configuration, verify
```bash
docker compose --profile gpu up -d                     # or --profile cpu; add --profile dev for mailpit
ptctl config load /etc/pawtrace/pawtrace.yaml          # PUT /admin/config — schema-validated; regions created/updated
curl -s http://$BIND_ADDR:8080/api/v1/readyz           # db, redis, object_store true; vision_backlog 0; active_embedding_version set
ptctl privacy-check                                    # TC-060 quick form: 500 public queries scanned for coordinates — must be clean
```
Demo data (non-production only): `psql … -f ../db/seed_demo.sql` (10 k distractors, the Appendix A candidate, AC-02/06/08 rows).

### 4.5 Reverse proxy
Any TLS-terminating proxy (Caddy, Traefik, nginx). Requirements: HSTS; `Content-Security-Policy` for the PWA (no `unsafe-inline`); client body limit 13 MB; per-IP connection limits; forward `X-Forwarded-For` (rate limits key on it); block `/metrics` from outside.

## 5. Third-party providers — what each one adds and what breaks without it
| Provider (IF) | Without it | Self-hosting |
|---|---|---|
| Map tiles (IF-39) | Map shows cells on a blank grid; everything else works | TileServer GL with an OSM extract of Thailand (~3 GB); set `MAP_TILES_URL` |
| Geocoder (IF-39) | Address search disabled; GPS and pin work (FR-03) | Photon or Nominatim (Thailand extract); set `GEOCODER_URL`; disable query logging |
| Push (IF-40) | In-app inbox + email only | Web Push needs no provider (VAPID); FCM only for the Flutter app |
| CAPTCHA (IF-41) | Challenged devices cannot post (fail closed); unchallenged ones can — set `trust.captcha_below` to 0 to disable challenges temporarily | none (Turnstile is free; hCaptcha alternative) |
| SMTP (IF-13) | No magic links → **sign-in impossible**; sightings still work anonymously | any relay; mailpit in dev |
| SMS | OTP by SMS unavailable (email OTP remains) | — |

## 6. Day-to-day operation

### 6.1 Observability
| Signal | Where | Meaning |
|---|---|---|
| `/readyz` | API | db, redis, object store, `vision_backlog`, `vision_oldest_age_s`, active embedding version |
| Metrics (IF-14) | `:8080/metrics` | upload latency, backlog, ANN latency by radius, notify/digest counts, moderation depth, CAPTCHA/429 counters, calibration drift, recall per slice, open deletions |
| Views | `v_vision_backlog`, `v_moderation_queue`, `v_notify_budget`, `v_deletion_status`, `v_model_status`, `v_bias_report` | operational state |
| Audit | `audit.log`, `audit.auth_event` | moderation, config, models, deletions, sign-ins |

Alerts about PawTrace itself:

| Alert | Condition | Runbook |
|---|---|---|
| Vision backlog | `vision_oldest_age_s > 900` | RB-01 |
| GPU worker down | no vision heartbeat 5 min | RB-02 |
| ANN latency | p95 > 300 ms for 10 min | RB-03 |
| Object store errors | S3 5xx > 1 % | RB-04 |
| Moderation queue | > 200 items or oldest > 24 h | RB-05 |
| Abuse wave | 429s > 5× baseline or CAPTCHA challenges > 3× | RB-06 |
| Coordinate leak check failed | `ptctl privacy-check` non-clean (runs hourly) | **RB-07 (page)** |
| Calibration drift | `pt_calibration_drift > 0.15` | RB-08 |
| Deletion SLA | `v_deletion_status.sla_breached` any | RB-09 |
| Re-embed stalled | job `done` unchanged 1 h | RB-10 |
| Push failures | > 20 % failed sends | RB-11 |
| Disk | database or objects > 80 % | RB-12 |
| Bias | `rebalance_required` after a benchmark | RB-13 |
| Magic-link mail failing | SMTP errors > 5 % | RB-14 |

### 6.2 SLOs
| SLO | Target | Measured by |
|---|---|---|
| Reporting path availability | ≥ 99.5 % (NFR-08) | synthetic sighting post every minute |
| Upload → candidates | ≤ 15 s p95 (NFR-01) | `pt_upload_latency_seconds` + first-candidate timestamp |
| ANN | ≤ 300 ms p95 (NFR-02) | `pt_ann_latency_seconds` |
| Mobile FCP | ≤ 2 s on 4G (NFR-04) | weekly Lighthouse |
| Deletion | ≤ 72 h (NFR-06) | `v_deletion_status` |
| Public coordinate leaks | **0** | hourly privacy check, TC-060 per deploy |

### 6.3 Moderation staffing
Queue priority: abuse reports → pending photos (NSFW 0.6–0.9) → duplicate clusters. Budget: ~40 items per moderator-hour. Rule of thumb: one moderator-hour per 500 new photos plus one per 50 abuse reports. Every action needs a reason; the weekly review samples 20 actions per moderator from `audit.log`. Escalations (harassment in a thread, luring suspicion): SEC-07 §7.

### 6.4 Weekly abuse and tuning review
`ptctl abuse-report --week`: 429s by route, CAPTCHA challenges and pass rate, bans, duplicate-hash clusters, abuse reports by reason and resolution, false-positive challenges (honest users who hit CAPTCHA). Tune `trust.rate_limits` and `trust.captcha_below` in `pawtrace.yaml`; load; the version is stamped.

### 6.5 Calibration and notification budget
Nightly `CALIBRATION_CRON` recomputes `calibration_bin` from decisions (needs ≥ 200 for a version to leave *provisional*). Monthly: compare shown precision vs realised precision per bin (`pt_calibration_drift`); review `v_notify_budget` — if many users hit the cap daily, the threshold is too low for that region or duplicates are leaking through (FR-25 is a cap, not a tuning knob).

## 7. Model lifecycle (AI-06, AC-08)
1. **Register**: `ptctl models register --kind embedding --name dogreid-arcface --version 2.0 --dims 768 --file …` → checksum, `model_version` row, empty partial HNSW indexes created by the trigger.
2. **Benchmark**: `ptctl models benchmark <id> --dataset dogreid-holdout --filtered` → `benchmark_run` + slices; Recall@10 ≥ 0.80 and Recall@1 ≥ 0.45 required (AI-03); bias slices reviewed (§7.1).
3. **Re-embed**: `POST /admin/models/{id}/reembed` → `reembed_job`; runs in the background at `REEMBED_BATCH` per batch; v1 stays `search_active`; expect ~2 h per 1 M crops on one GPU. **Index build**: for a populated table, build the partial HNSW `CONCURRENTLY` while the job runs (`ptctl models build-index <id> --concurrently`) so activation does not wait; the trigger-created index on an empty version is fine only for fresh databases.
4. **Activate**: `POST /admin/models/{id}/activate` — refused until the job is `completed` (`REEMBED_INCOMPLETE`) or without a benchmark (`BENCHMARK_MISSING`); one transaction flips `search_active`; the next query reads v2.
5. **Retire**: after 7 days with no rollback, `ptctl models retire <old>` drops the old version's vectors and indexes (frees ≈ 5 GB per 1 M crops).
6. **Rollback**: activating the previous version is the same one-transaction flip while its vectors still exist — which is why retirement waits 7 days.

### 7.1 Bias rebalancing (AI-08)
A benchmark slice with `gap_pct > 15` sets `rebalance_required`. Action: the ML owner adds in-domain data for that slice (with consent, from confirmed decisions), fine-tunes, registers a new version and repeats §7. The public bias report (`GET /admin/bias-report`) is part of the monthly review.

## 8. Retention, storage lifecycle, backup
- **Database**: nightly `pg_dump` (everything except `rate_limit_bucket`), weekly base backup; restore test quarterly. Vectors are included — they are part of the deletion contract, so a restore must be followed by replaying deletion requests newer than the backup (`ptctl privacy replay-deletions --since`).
- **Objects**: bucket replication or a nightly `mc mirror` to a second store; **never** to a public bucket.
- **Retention** (`retention.*` in `pawtrace.yaml`, executed by `RETENTION_CRON` + MinIO lifecycle rules created by `minio-init`): closed/reunited reports → thumb-only after 90 d, deleted after 365 d unless a public reunion story is kept; unmatched sightings expire at 30 d and follow the same tiers; exports 2 d; intake 7 d; audit 3 y; rate buckets 30 d.
- **Vectors** of deleted photos are removed by the cascade at once; of retained-thumb-only reports at the 365-day deletion.

## 9. Privacy operations (NFR-06)
- Deletion requests are self-service (`POST /me/delete`); the database part is immediate; `DELETION_SWEEP_CRON` removes objects; `v_deletion_status.sla_breached` alerts (RB-09).
- Manual requests (email, PDPA letter): the privacy officer runs `ptctl privacy delete --email …` which creates the same `deletion_request`. Never delete by hand in SQL — the cascade and the tombstone are the record.
- Export: `POST /me/export` or `ptctl privacy export --email …`.
- A suspected coordinate leak is an incident (SEC-07 §7): `PUBLIC_ROUTES_ENABLED=false` first, investigate second.

## 10. Upgrades
Pull images → `docker compose up -d`; migrations forward-only at API start with a pre-migration dump; a change to the upload gate re-runs the EXIF corpus (TC-014); a change to any public handler re-runs TC-060 before traffic; a change to scoring re-runs TC-041 at 10 k and TC-042.

## 11. Runbooks
| RB | Symptom | Diagnose | Fix |
|---|---|---|---|
| **RB-01** | Vision backlog growing | `v_vision_backlog`; worker logs; GPU memory | Add a worker replica; lower `VISION_BATCH_*` if OOM; the reporting path is unaffected (P-2) |
| **RB-02** | GPU worker down | `nvidia-smi`; container exit code | Restart; if the GPU is gone, start the `cpu` profile until repaired (`docker compose --profile cpu up -d worker-vision-cpu`); backlog drains FIFO (AC-07) |
| **RB-03** | ANN latency high | `EXPLAIN` a 50 km query; `hnsw.ef_search`; two active-size versions in flight? | Build the partial index `CONCURRENTLY` if missing; raise `maintenance_work_mem`; retire the old version; add a read replica for the public pool |
| **RB-04** | Object store errors | MinIO health; disk | Uploads fail closed (no photo without storage); restore service; the queue holds nothing on disk elsewhere |
| **RB-05** | Moderation queue backlog | `v_moderation_queue` by item | Add moderator hours; raise `moderation.nsfw_auto_hide` only if precision of auto-hides is verified; never auto-approve |
| **RB-06** | Abuse wave | `ptctl abuse-report --today`; duplicate-hash clusters | Lower `trust.captcha_below`, tighten `trust.rate_limits`, bulk-hide by sha256 cluster, ban devices; keep honest 60-second posting working — check the false-challenge rate |
| **RB-07** | **Privacy check failed / coordinate seen in a public response** | Which route; which pool; recent deploy | `PUBLIC_ROUTES_ENABLED=false`; confirm the public pool role (`SELECT current_user`); revert the deploy; audit what was served; SEC-07 §7 notification; post-mortem before re-enabling |
| **RB-08** | Calibration drift | bins vs realised confirms; model change? | Refresh calibration; if a new version, mark provisional; if drift persists, the decision mix changed — review with the ML owner |
| **RB-09** | Deletion SLA breached | `v_deletion_status`; sweep logs; object store | Run `ptctl privacy sweep --request <id>` manually; record in `summary_json`; notify the requester |
| **RB-10** | Re-embed stalled | `reembed_job.done`; worker logs; checksum error | Resume the job (`ptctl models reembed --resume`); a checksum error halts the worker by design (SEC-T53) — restore the artefact |
| **RB-11** | Push failures | provider status; expired subscriptions | Revoked endpoints are pruned automatically; rotate VAPID keys only with a client update; email fallback active |
| **RB-12** | Disk | `pg_database_size`; per-version vector size (`v_model_status.n_embeddings`); bucket usage | Retire old versions; run retention now; extend volumes |
| **RB-13** | Bias flag | `v_bias_report` | §7.1 — do not lower the 15 % threshold |
| **RB-14** | Sign-in mail failing | SMTP logs | Fix the relay; anonymous sightings keep working; owners can still post lost reports once mail is back |

## 12. Traceability
| SRS-07 | Section |
|---|---|
| C-01, AC-04 | §1, §4.4 privacy check, §6.2, RB-07 |
| C-02, FR-28 | §5 (CAPTCHA), §6.4, RB-06 |
| C-04, C-05 | §4.5 (body limit), §6.3, §10 |
| AI-03, AI-04, AI-06, AI-08, AC-08 | §7, §6.5, RB-08, RB-10, RB-13 |
| FR-25 | §6.5 |
| NFR-01, NFR-02, NFR-04, NFR-08, AC-07 | §2, §6.2, RB-01…03 |
| NFR-06, AC-06 | §8, §9, RB-09 |
| NFR-07 | §4.2, §8 |
| SRS §4.2 optional third parties | §5 |
| SRS §10 cost | §2, §8 |
