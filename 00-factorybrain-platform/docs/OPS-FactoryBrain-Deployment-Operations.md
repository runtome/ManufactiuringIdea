# Deployment and Operations Guide — FactoryBrain AI Platform

| Field | Value |
|---|---|
| Document ID | OPS-00-FactoryBrain |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) |
| Audience | Platform administrator, on-call operator |

---

## 1. How to use this document

| Situation | Go to |
|---|---|
| First-time installation | §3 |
| Something is broken right now | §8 runbooks |
| Configuring a setting | §4 |
| Updating a model | §5.3 |
| Backup or restore | §6 |
| Upgrading the platform | §9 |
| Routine daily/weekly work | §10 |

**On-call summary — the four things that matter most:**

1. **The line must keep running.** Edge nodes inspect without the server. If the server is down, that is urgent but not a line stop — verify the edge buffer is draining and fix the server calmly (RB-05).
2. **A grounding-failure spike is an integrity incident**, not a performance blip (RB-09).
3. **Never disable `GROUNDING_CHECK_ENABLED` or `MODEL_VERIFY_SHA256`** to "get things working". Both exist to prevent silent wrongness.
4. **Restore is only real if it has been tested.** The quarterly drill (§6.4) is not optional paperwork.

---

## 2. Deployment topologies

### 2.1 Single-node all-in-one — pilot and demo
Everything from `docker-compose.yml` on one machine. Cameras attach directly or are simulated.
*Use for:* evaluation, development, single-line pilot. *Not for:* multiple production lines.

### 2.2 Server + N edge nodes — reference production
```
Server (Z3): the full compose stack
   ▲ IF-01 mTLS, node-initiated
   │
Edge nodes (Z2): one per line/station, autonomous inspection
   ▲ IF-02 camera · IF-03 PLC I/O
   │
Machines (Z1): read-only OPC-UA / Modbus / MQTT
```
*Use for:* normal production. Edge nodes survive a 72 h server outage.

### 2.3 Fully air-gapped
No internet at any point. Images, models and packages arrive as an offline bundle (§5.4). The `backend` Docker network is already `internal: true`, so most services have no egress route by construction — an air-gapped deployment behaves identically to a connected one, which is why it can be tested honestly.

---

## 3. Installation

### 3.1 Server prerequisites

| Component | Minimum | Reference |
|---|---|---|
| OS | Ubuntu 22.04 LTS | |
| CPU | 8 cores | 16 |
| RAM | 32 GB | 64 GB |
| Storage | 1 TB NVMe SSD | 2 TB + separate volume for evidence |
| GPU | NVIDIA, 8 GB VRAM | RTX 3060 Ti (dev baseline) |
| Docker | 24+ with Compose v2 | 27+ |
| NVIDIA driver | 535+ | |

```bash
# GPU support
sudo apt-get install -y nvidia-driver-535 nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi   # must list the GPU

# Time sync — required (SEC-146); skew corrupts shift attribution and audit sequence
sudo timedatectl set-ntp true && timedatectl status
```

### 3.2 TLS with an internal CA

```bash
mkdir -p deploy/certs && cd deploy/certs

openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt \
  -subj "/C=TH/O=FactoryBrain/CN=FactoryBrain Internal CA"

openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=factorybrain.local"
printf "subjectAltName=DNS:factorybrain.local,IP:10.20.30.40" > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 825 -sha256 -extfile san.ext

chmod 600 *.key
```
Distribute `ca.crt` to browsers, tablets and edge nodes. Certificate expiry is a recurring outage cause — see RB-08 and the calendar reminder in §10.

### 3.3 JWT keys
```bash
mkdir -p deploy/secrets
openssl genrsa -out deploy/secrets/jwt_private.pem 2048
openssl rsa -in deploy/secrets/jwt_private.pem -pubout -out deploy/secrets/jwt_public.pem
chmod 600 deploy/secrets/jwt_private.pem
```

### 3.4 Configure and start

```bash
cd deploy
cp .env.example .env
chmod 600 .env
grep -q '^deploy/\.env$' ../../.gitignore || echo 'deploy/.env' >> ../../.gitignore

# Fill every [REQUIRED] value; generate secrets with: openssl rand -base64 36
${EDITOR:-nano} .env

# Work through the pre-flight checklist at the bottom of .env.example.
docker compose up -d
docker compose ps
```

`schema.sql` (and `seed_demo.sql`, for non-production) apply automatically on **first start only**, when the Postgres data directory is empty. After that, schema changes go through Alembic in the `migrate` service.

**Verify:**
```bash
curl -k https://factorybrain.local/api/v1/healthz    # {"status":"ok"}
curl -k https://factorybrain.local/api/v1/readyz     # dependency-by-dependency
docker compose exec postgres psql -U factorybrain -c "SELECT * FROM ops.schema_version;"
```

**First login:** sign in as `BOOTSTRAP_ADMIN_USERNAME`, immediately enrol MFA, create a **second** admin (RR-09), then remove `BOOTSTRAP_ADMIN_PASSWORD` from `.env` and restart the API.

### 3.5 Edge node provisioning
Target: operational in ≤ 30 minutes without a developer (SRS-03 NFR-09).

1. Flash the edge image (JetPack 6 or Ubuntu 22.04 + NVIDIA toolkit).
2. Write `/etc/edgeguard/node.yaml` (see [SRS-03 Appendix A](../../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md)).
3. Install `ca.crt`; place the node certificate or `X-Edge-Key`.
4. `docker compose up -d` on the node.
5. Verify: node appears in `GET /edge/nodes` with `state: online`; a test part produces a verdict on the PLC within 200 ms.

**Commissioning checks that are not optional:**
- Pixel-to-mm calibration recorded in `vision.camera.calib_px_per_mm`.
- **PLC treats verdict-absence as FAULT** (TC-026). Verify by suppressing one verdict and confirming the line holds.
- 30-minute network-disconnection test with zero record loss.

---

## 4. Configuration reference

Full list in [`.env.example`](../deploy/.env.example). The settings below are the ones that change behaviour most, or that get changed for the wrong reasons.

### 4.1 Settings that must not be weakened

| Variable | Required value | Why |
|---|---|---|
| `GROUNDING_CHECK_ENABLED` | `true` | Disabling it removes the platform's core integrity guarantee (ADR-013). If it causes false positives, tune `GROUNDING_NUMERIC_TOLERANCE` — never switch it off. |
| `MODEL_VERIFY_SHA256` | `true` | An unverified model artefact is an arbitrary-code and integrity risk (SEC-181). |
| `REQUIRE_MFA_FOR_ADMIN` | `true` | SEC-103. |
| `ENABLE_EXTERNAL_LLM` | `false` | `true` sends factory data outside the LAN. Deliberate, logged decision only (SEC-241). |
| `OPCUA_USERNAME` | read-only account | The enforcement point for "no machine control" (SEC-261). |
| `SMTP_RECIPIENT_ALLOWLIST` | populated | Empty denies all sending. An unrestricted list turns the platform into an open relay. |

### 4.2 Frequently tuned

| Variable | Default | Guidance |
|---|---|---|
| `PASS_IMAGE_SAMPLE_RATE` | `0.02` | **The main lever on storage growth.** 100 % PASS retention consumes terabytes for little value. |
| `VISION_REVIEW_THRESHOLD_DEFAULT` | `0.55` | Lower → more REVIEW, safer, more inspector load. Prefer per-SKU `vision.recipe` overrides. |
| `AGENT_MAX_TOOL_CALLS` | `5` | Raising it increases latency and GPU contention. |
| `GPU_SEMAPHORE_WAIT_TIMEOUT_SECONDS` | `45` | Exceeded → `503 MODEL_UNAVAILABLE`. Raise only if users prefer waiting to a clear failure. |
| `ALERT_DEFECT_RATE_PCT` | `4.0` | Set from actual process capability, not a round number. |
| `INGEST_QUARANTINE_THRESHOLD_PCT` | `5` | Raising it lets bad data into the warehouse. Fix the source instead. |
| `DB_POOL_SIZE` | `20` | `workers × pool_size` must stay below `max_connections` (200). |

### 4.3 Runtime vs deploy-time
`ops.config` holds runtime-tunable values (thresholds, schedules) changeable in the admin UI without a restart. Environment variables hold infrastructure and secrets and require a restart. **Secrets never go in `ops.config`.**

---

## 5. Model management

### 5.1 LLM models (offline-first)
The `backend` network is `internal: true`, so `ollama pull` **cannot reach the internet from inside the stack**. This is intentional.

```bash
# On a connected machine
ollama pull qwen3:8b && ollama pull bge-m3
docker run --rm -v ollama_models:/dest -v ~/.ollama:/src alpine \
  sh -c "cp -a /src/. /dest/"

# Or move the whole volume to the air-gapped host
docker run --rm -v factorybrain_ollama_models:/v -v $(pwd):/b alpine \
  tar czf /b/ollama_models.tar.gz -C /v .
```
Verify: `docker compose exec ollama ollama list`.

### 5.2 Vision models — deploy
```bash
mc cp defect-yolo11s-1.1.0.onnx fb/models/
sha256sum defect-yolo11s-1.1.0.onnx     # register in vision.model_registry
```
Register via `POST /admin/models` as `stage: candidate`.

### 5.3 Promotion (shadow → active → rollback)

```
candidate ──► shadow (>=200 live frames, no verdict effect)
                 │
          disagreement report vs active model
                 │
          human decision (SEC-183)
                 │
              active            previous model retained
                 │
              rollback available by one command
```

```bash
# Start shadow
curl -X POST .../admin/models/{id}/shadow
# Review after >=200 frames
curl .../admin/models/{id}   # shadow_report: disagreement_pct, critical_recall_delta

# Promote (fails if no shadow run, or metrics below the gate)
curl -X POST .../admin/models/{id}/promote

# Rollback
curl -X POST .../admin/models/{previous_id}/promote
```

**Promotion is refused automatically if `critical_recall < 0.98`.** Do not work around this. A model that misses critical defects more often than the previous one must not reach the line, regardless of how much better its headline mAP looks.

### 5.4 Air-gapped bundle
```bash
# Connected machine
docker compose pull
docker save $(docker compose config --images) | gzip > fb-images-1.0.0.tar.gz
# Plus: ollama_models.tar.gz, model artefacts, this repository

# Air-gapped host
gunzip -c fb-images-1.0.0.tar.gz | docker load
docker compose up -d
```
Record image digests in the release notes so the offline bundle is verifiable (SEC-192).

---

## 6. Database operations

### 6.1 Migrations
```bash
docker compose run --rm migrate alembic upgrade head
docker compose run --rm migrate alembic current
```
**Rehearse every migration against a restored production-sized dump before release** (DDS §14.3, TC-149). Migrations behave differently on a partitioned multi-million-row table than on an empty one. Use `CREATE INDEX CONCURRENTLY` in production.

### 6.2 Backup
Nightly `pg_dump` plus continuous WAL archiving. **RPO ≤ 24 h, RTO ≤ 4 h** (QAS-14).

```bash
docker compose exec postgres pg_dump -U factorybrain -Fc factorybrain \
  | gzip > /backups/fb-$(date +%F).dump.gz
mc mirror --overwrite /data/evidence fb-backup/evidence-$(date +%F)
```
Backups are encrypted (`BACKUP_ENCRYPTION_KEY`) and the key is stored **somewhere other than this server** — a key beside the backup protects nothing.

### 6.3 Restore
```bash
docker compose stop api worker agent notifier
docker compose exec -T postgres psql -U factorybrain -c \
  "DROP DATABASE factorybrain; CREATE DATABASE factorybrain;"
gunzip -c /backups/fb-2026-09-09.dump.gz | \
  docker compose exec -T postgres pg_restore -U factorybrain -d factorybrain --no-owner
# PITR: place WAL files in restore_command and set recovery_target_time
docker compose start api worker agent notifier
```
Then **restore the object store too**. A database without its evidence images is only partially useful.

### 6.4 Quarterly restore drill (NFR-12, mandatory)
1. Provision a clean host.
2. Restore the latest backup — database and object store.
3. Run the seed verification queries and TC-070a.
4. **Record the measured RTO.** If it exceeds 4 h, that is a finding requiring action, not a note.

An untested backup is a hypothesis.

### 6.5 Partition maintenance
The `partition_maintain` job creates three months ahead and drops past retention.
```sql
SELECT count(*) FROM vision.inspection_default;   -- MUST be 0
```
A non-empty default partition means clock skew or a missing partition — investigate, do not just create the partition (RB-13).

---

## 7. Observability

### 7.1 Metrics that matter

| Metric | Watch for | Runbook |
|---|---|---|
| `factorybrain_agent_run_total{outcome="grounding_failed"}` | **Any sustained rise** | RB-09 |
| `factorybrain_edge_buffer_depth` | Rising = sync problem | RB-05 |
| `factorybrain_edge_heartbeat_age_seconds` | > 180 s = node down | RB-04 |
| `factorybrain_gpu_semaphore_wait_seconds` | p95 > 20 s = contention | RB-03 |
| `factorybrain_inspection_latency_ms` | p95 > 150 ms = takt risk | RB-03 |
| `factorybrain_ingest_rows_quarantined_total` | Spike = upstream change | RB-06 |
| `factorybrain_posting_attempts_total{status="failed"}` | ERP integration issue | RB-07 |
| `pg_stat_activity` count | Approaching `max_connections` | RB-10 |
| Disk free % | < 15 % | RB-02 |

### 7.2 Alert rules (thresholds)

| Alert | Condition | Severity |
|---|---|---|
| ServiceDown | `up == 0` for 2 min | Critical |
| EdgeNodeOffline | 3 missed heartbeats | Critical during shift |
| GroundingFailureSpike | rate > 1 % over 15 min | **Critical** |
| DiskCritical | free < 10 % | Critical |
| DiskWarning | free < 15 % | Warning |
| GpuSemaphoreSaturated | p95 wait > 30 s for 10 min | Warning |
| IngestMissing | no file by `INGEST_EXPECTED_DAILY_BY` | Warning |
| CertExpiring | < 14 days | Warning |
| BackupFailed | no successful backup in 26 h | **Critical** |
| DefaultPartitionNonEmpty | rows > 0 | Warning |
| PostingFailures | > 3 in 1 h | Warning |
| AuditWriteFailure | any | **Critical** |

`GroundingFailureSpike` and `AuditWriteFailure` are critical for the same reason: both mean the system may be producing output that cannot be trusted or traced.

### 7.3 SLOs

| SLO | Target | Window |
|---|---|---|
| API availability during shifts | 99.0 % | 30 d |
| Edge inspection availability | 99.5 % | 30 d |
| Dashboard p95 latency | ≤ 2 s | 7 d |
| Agent p95 latency | ≤ 20 s | 7 d |
| Data completeness (files on time) | 99 % | 30 d |

Error budget: exceeding it pauses feature work in favour of reliability work.

### 7.4 Logs
Structured JSON with `correlation_id` propagated from HTTP request → tool call → model call.
```bash
docker compose logs -f api | jq 'select(.correlation_id=="abc-123")'
```
`LOG_LEVEL=DEBUG` is for troubleshooting only — it is verbose and may log request bodies.

---

## 8. Runbooks

### RB-01 — A service is down
1. `docker compose ps` — identify the unhealthy service.
2. `docker compose logs --tail=200 <svc>`.
3. Check resources: `df -h`, `free -g`, `nvidia-smi`.
4. Restart one service: `docker compose restart <svc>`.
5. If it restart-loops, check for OOM: `dmesg | grep -i oom`.
6. **Verify the line is unaffected** — edge nodes should still be inspecting and buffering.

### RB-02 — Disk full
1. `df -h` and `du -sh /var/lib/docker/volumes/*`.
2. Usually evidence images. Confirm the retention sweep is running: `SELECT * FROM ops.scheduled_job WHERE name='retention_sweep';`
3. Immediate relief: `docker system prune -a --volumes=false` (images only, never volumes).
4. Run the retention sweep manually.
5. Structural fix: lower `PASS_IMAGE_SAMPLE_RATE` or `RETENTION_PASS_IMAGE_DAYS`.
6. **Never delete unsynced edge data or WAL archives** to free space.

### RB-03 — GPU exhausted or slow
1. `nvidia-smi` — check memory and processes.
2. `factorybrain_gpu_semaphore_wait_seconds` — is it queueing or genuinely OOM?
3. If OOM: confirm `OLLAMA_MAX_LOADED_MODELS=1`; check whether a vision batch is running.
4. Move batch work off-shift.
5. If persistent: use a smaller model quantisation, or add a second GPU (AR-01).
6. **Do not run vision and LLM work concurrently on one 8 GB card.** The semaphore exists to prevent this; disabling it converts a slow answer into a stack-wide CUDA failure.

### RB-04 — Edge node offline
1. `GET /edge/nodes` — check `last_heartbeat` and `state`.
2. Ping the node; check physical power and network.
3. On the node: `docker compose ps`, `docker compose logs edge-agent`.
4. **Confirm it is still inspecting locally** — offline from the server is not offline from the line.
5. Credential problem (`401 EDGE_KEY_INVALID`) → rotate: issue a new key/certificate, update `node.yaml`, restart the agent.
6. Once reconnected, watch `buffer_depth` drain to zero.

### RB-05 — Sync backlog / rising buffer depth
1. Confirm connectivity from node → platform.
2. Check API health and error rate on `/edge/records:batch`.
3. Look for repeated `rejected` outcomes — usually unknown SKU or line codes; fix master data.
4. Check platform disk and database health.
5. Buffer nearing capacity: temporarily raise the sync batch size or open the image bandwidth window.
6. **Records are never dropped to relieve a backlog.**

### RB-06 — Ingest failure or quarantine spike
1. `GET /ingest/batches/{id}` — read the quarantine reasons.
2. A spike usually means the source file layout changed. Compare against the mapping YAML.
3. Fix the mapping and re-upload; ingestion is idempotent.
4. `status: rejected` means nothing was committed — the data is not partially loaded.
5. **Do not raise `INGEST_QUARANTINE_THRESHOLD_PCT` to make it pass.**

### RB-07 — ERP posting failures
1. `GET /docflow/documents?state=posting_failed`.
2. Read `last_error` on `docflow.posting`.
3. Test ERP connectivity and credentials.
4. Retry: `POST /docflow/documents/{id}/post` — idempotent, cannot double-post.
5. After `ERP_MAX_POST_ATTEMPTS`, handle via the exception queue with the ERP owner.
6. If duplicates are suspected: query `SELECT adapter, idem_key, count(*) FROM docflow.posting GROUP BY 1,2 HAVING count(*)>1;` — this should return **zero rows**; a unique constraint enforces it.

### RB-08 — Certificate expiring or expired
1. `openssl x509 -in deploy/certs/server.crt -noout -enddate`.
2. Re-issue per §3.2 (keep the same CA so edge nodes keep trusting).
3. `docker compose restart caddy mqtt`.
4. If the **CA** expired, every edge node and client needs the new `ca.crt` — plan this as a change, not an emergency.

### RB-09 — Grounding failure spike (**integrity incident**)
1. Query recent failures:
   ```sql
   SELECT ts, question, grounding_json, model, prompt_version
   FROM agent.run WHERE outcome='grounding_failed'
   ORDER BY ts DESC LIMIT 50;
   ```
2. Establish what changed: model tag, prompt version, a new tool, a data shape change.
3. If a prompt or model change is the cause → **roll it back**.
4. Re-run the golden Q&A set to quantify.
5. If it is a false-positive pattern (derived percentages, rounding), tune `GROUNDING_NUMERIC_TOLERANCE` — **do not disable the check**.
6. Treat as a security/integrity incident per [SEC §7.3](SEC-FactoryBrain-Security-Requirements.md): the withheld answers are the system working, but the underlying drift needs a root cause.

### RB-10 — Database connections exhausted
1. `SELECT count(*), state FROM pg_stat_activity GROUP BY state;`
2. Find long-running queries; terminate with `pg_terminate_backend` if necessary.
3. Check `DB_POOL_SIZE × workers < max_connections`.
4. Look for a connection leak in recently deployed code.

### RB-11 — LLM unavailable
1. `docker compose ps ollama`; `docker compose logs ollama`.
2. `docker compose exec ollama ollama list` — is the model present?
3. `nvidia-smi` — GPU healthy?
4. Restart: `docker compose restart ollama`.
5. **Confirm degraded mode is working**: dashboards, SPC and the review queue must still function. If they do not, that is a worse bug than the LLM being down.
6. Communicate: AI features unavailable, everything else normal.

### RB-12 — Migration failure
1. Migrations run in `migrate` before `api` starts, so a failure blocks deployment rather than serving a mismatched schema.
2. `docker compose logs migrate`.
3. Roll back the application to the previous image.
4. Reproduce against a restored dump before retrying.
5. Never hand-edit `alembic_version` to skip a migration.

### RB-13 — Default partition non-empty
1. `SELECT min(ts), max(ts), count(*) FROM vision.inspection_default;`
2. Timestamps far in the future/past → clock skew on an edge node; fix NTP there.
3. Timestamps just past the last partition → the maintenance job did not run; run it manually.
4. Move rows into the correct partition once it exists.

### RB-14 — Planned upgrade
See §9.

---

## 9. Upgrade and rollback

### 9.1 Procedure
1. **Read the release notes**, especially migration and config changes.
2. Take a full backup and **verify it restores** (not just that it completed).
3. Rehearse migrations on a restored dump (TC-149).
4. Schedule in a maintenance window — between shifts, never mid-shift.
5. Pull new images; update tags/digests in `.env`.
6. `docker compose up -d` — `migrate` runs first and blocks on failure.
7. Verify: `/readyz`, a KPI query, a grounded agent question, one edge node syncing.
8. Watch metrics for 30 minutes.

### 9.2 Rollback
```bash
# Application only (no migration): revert image tags, redeploy
docker compose up -d
# With migrations: restore the pre-upgrade backup
```
This is why destructive schema changes are two-phase (deprecate, then drop a release later) — it keeps application rollback possible without data loss.

### 9.3 Edge fleet upgrades
Never all at once. One node → soak for a shift → the rest. `ops.edge_node.app_version` shows fleet state. An older minor version must keep syncing (IF-01 versioning rule).

---

## 10. Routine operations

**Daily (10 min)**
- [ ] All services healthy (`/readyz`)
- [ ] All edge nodes heartbeating, buffers near zero
- [ ] Yesterday's ingest completed; quarantine count normal
- [ ] Overnight backup succeeded
- [ ] No unacknowledged critical alerts
- [ ] Grounding failure rate at baseline

**Weekly (30 min)**
- [ ] Disk trend vs projection
- [ ] Review queue not accumulating
- [ ] Failed jobs in `ops.scheduled_job`
- [ ] Data-quality events reviewed
- [ ] Security events: failed logins, unmapped-user attempts
- [ ] Dependency scan results

**Monthly (2 h)**
- [ ] Partition maintenance ran; default partition empty
- [ ] Model drift metrics reviewed
- [ ] Alert precision reviewed with maintenance/quality
- [ ] Certificate expiry check
- [ ] Audit log spot-check
- [ ] Capacity forecast updated

**Quarterly (half a day)**
- [ ] **Restore drill with measured RTO** (§6.4)
- [ ] Authorisation matrix test (TC-091)
- [ ] Prompt-injection suite (TC-095)
- [ ] Golden Q&A set re-run
- [ ] Secret rotation
- [ ] Review this document against reality

---

## 11. Capacity planning

| Resource | Driver | Growth |
|---|---|---|
| **Object storage** | Evidence images | **The binding constraint** — 2–4 TB/year at 100 k inspections/day |
| Database | Inspections, telemetry | ~25 GB/year with retention applied |
| GPU | Agent + vision concurrency | One 8 GB card supports ~5 concurrent agent users |
| RAM | Postgres cache, workers | 32 GB adequate to ~10 lines |

**Scale-up triggers**
| Signal | Action |
|---|---|
| Object storage > 70 % | Lower `PASS_IMAGE_SAMPLE_RATE` or add storage |
| GPU semaphore p95 > 20 s | Second GPU, or move vision batch off-shift |
| Dashboard p95 > 2 s | Check partition pruning; add materialised views |
| > 10 lines | Split the vision service to its own host |
| pgvector search > 500 ms at 5 M chunks | Revisit ADR-001 |

---

## 12. Decommissioning

1. Export what must be retained: audit log, quality cases, FMEA (retention obligations outlive the platform).
2. Revoke all edge credentials and node certificates.
3. Securely erase volumes: `docker compose down -v` then wipe the underlying storage.
4. Destroy backup encryption keys **after** confirming exports are readable.
5. Remove CA trust from client devices.
6. Record the disposal for compliance.

---

## 13. Traceability

| Requirement | Section |
|---|---|
| NFR-04 availability | §7.3 SLOs, RB-01, RB-04, RB-11 |
| NFR-10 portability / air-gapped | §2.3, §5.1, §5.4 |
| NFR-11 observability | §7 |
| NFR-12 backup and restore | §6.2–6.4 |
| AC-01 clean deployment | §3.4 |
| C-04 docker compose | [`docker-compose.yml`](../deploy/docker-compose.yml) |
| SEC-181 model verification | §4.1, §5.3 |
| SEC-192 image pinning | §4.1, §5.4 |
| SEC-240 egress default-deny | §2.3, compose `internal: true` |
| SEC-244 secrets handling | §3.4, §4.3 |
| SEC-247 backup encryption | §6.2 |
| SEC-277 restore drill | §6.4, §10 |
| ADR-011 GPU semaphore | §4.2, RB-03 |
| ADR-013 grounding | §4.1, RB-09 |
| DDS §14.3 migrations | §6.1, RB-12 |

---

## Appendix A — Emergency contacts template

| Role | Name | Contact | Escalate when |
|---|---|---|---|
| Platform admin | | | Any RB-xx not resolved in 30 min |
| Quality engineer | | | Suspected wrong verdicts or statistics |
| Production supervisor | | | Line impact |
| IT / network | | | Connectivity, certificates, firewall |
| ERP owner | | | Posting failures |

## Appendix B — Diagnostic bundle

```bash
#!/bin/sh
# collect-diagnostics.sh — attach output to any escalation
OUT=fb-diag-$(date +%F-%H%M); mkdir -p "$OUT"
docker compose ps                          > "$OUT/services.txt"
docker compose logs --tail=500             > "$OUT/logs.txt"
df -h                                      > "$OUT/disk.txt"
free -g                                    > "$OUT/memory.txt"
nvidia-smi                                 > "$OUT/gpu.txt" 2>&1
curl -sk https://localhost/api/v1/readyz   > "$OUT/readyz.json"
docker compose exec -T postgres psql -U factorybrain -c \
  "SELECT * FROM ops.v_fleet_status;"      > "$OUT/fleet.txt"
docker compose exec -T postgres psql -U factorybrain -c \
  "SELECT * FROM agent.v_grounding_health ORDER BY day DESC LIMIT 7;" \
                                           > "$OUT/grounding.txt"
docker compose exec -T postgres psql -U factorybrain -c \
  "SELECT * FROM ops.data_quality_event ORDER BY ts DESC LIMIT 50;" \
                                           > "$OUT/dq_events.txt"
tar czf "$OUT.tar.gz" "$OUT" && rm -rf "$OUT"
echo "Wrote $OUT.tar.gz"
```

**Before sharing a diagnostic bundle, check it for secrets.** Logs are redacted by design (SEC-245), but a bundle leaving the site should still be reviewed.
