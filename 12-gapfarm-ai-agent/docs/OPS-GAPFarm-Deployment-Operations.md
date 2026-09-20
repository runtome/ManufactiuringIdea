# Deployment and Operations Guide — GAPFarm AI (AI Farmer Agent)

| Field | Value |
|---|---|
| Document ID | OPS-12-GAPFarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-20 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-12](../SRS-GAPFarm-AI-Farmer-Agent.md) §2.3, §7, §9 |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/postgres/Dockerfile`](../deploy/postgres/Dockerfile) · [`deploy/gapfarm.example.yaml`](../deploy/gapfarm.example.yaml) + [`schemas/gapfarm-config.schema.json`](../deploy/schemas/gapfarm-config.schema.json) · [`deploy/mosquitto/mosquitto.conf`](../deploy/mosquitto/mosquitto.conf) · [`deploy/inputs/`](../deploy/inputs/approved-products.example.yaml) · [`deploy/schemes/`](../deploy/schemes/thaigap.example.yaml) · [`deploy/models/`](../deploy/models/chili-v3.manifest.json) · [`deploy/prompts/`](../deploy/prompts/answer.th.v1.md) · [`deploy/glossary.example.csv`](../deploy/glossary.example.csv) |
| Related | [SAD-12](SAD-GAPFarm-Software-Architecture.md) §4.5 · [DDS-12](DDS-GAPFarm-Database-Design.md) §6, §8 · [ICD-12](ICD-GAPFarm-Interface-Control.md) · [SEC-12](SEC-GAPFarm-Security-Requirements.md) §5.5, §6 · [TEST-12](TEST-GAPFarm-Test-Plan.md) TC-004, TC-009 · [UM-12](UM-GAPFarm-User-Admin-Guide.md) Part B |

---

## 1. What you are operating
One compose stack on a small VPS (or an on-farm mini-PC): a PWA, an API, two workers (vision, agent), a scheduler, PostgreSQL 16 + PostGIS + pgvector, Redis, MinIO, an optional local language model, and — for farms with sensors — a Mosquitto broker and an MQTT ingester. The API and the scheduler are the only services that reach the internet (weather, LINE, Discord, push, mail). Everything a certification depends on is a database rule (DDS-12 §2): you cannot misconfigure PHI enforcement, append-only records or the approved-list rule — the config schema pins them.

## 2. Topology and sizing (NFR-09)
| Option | Hardware | Profile | Notes |
|---|---|---|---|
| Pilot VPS (default) | 4 vCPU / 8 GB / 100 GB SSD | `cpu` (+ `mqtt`) | ≤ 20 farms; diagnosis ≈ 1.5 s CPU + upload; the 7 B model answers in ≈ 6–10 s; TEST-12 TC-082 |
| Pilot with GPU | + 1 small GPU (8 GB) | `gpu` (+ `mqtt`) | diagnosis < 0.5 s; model answers ≈ 2 s |
| On-farm mini-PC | 8 GB, no public IP | `cpu`, `mqtt` | phones on the farm Wi-Fi; a 4G router for weather/LINE; no inbound port except 8883 on the LAN |

Networks: `frontend` (reverse proxy with TLS → `web`, `api`), `sensors` (broker ↔ ingest; 8883 published for field devices), `internal` (no egress), `egress`. Storage growth: DDS-12 §6 (≈ 20 GB/year for 20 farms incl. photos).

## 3. Prerequisites
Docker 26 / Compose v2; a domain and TLS at the reverse proxy; a LINE Official Account (Messaging API channel + Login channel) if LINE is used; a weather provider key if the provider needs one (Open-Meteo does not); FCM project for Android push (optional); SMTP (optional). The field model artefacts (`chili-v3`, `chili-v3-lite`) with manifests.

## 4. Installation

### 4.1 Files
```
/opt/gapfarm/deploy/            docker-compose.yml, .env (0600), postgres/, mosquitto/
/etc/gapfarm/                   gapfarm.yaml, schemas/, schemes/, inputs/, prompts/, glossary.csv     (CONFIG_DIR, read-only in containers)
/etc/gapfarm/secrets/           one file per secret (0400 root:10001)                                (SECRETS_DIR)
```

### 4.2 Secrets (files, never env — SEC-G25)
| File | Content | Used by |
|---|---|---|
| `database_url` | `postgresql://app_rw:…@postgres/gapfarm` | api, scheduler |
| `vision_database_url` | app_rw pool for worker-vision | worker-vision |
| `agent_database_url` | `agent_ro` login | worker-agent |
| `ingest_database_url` | `ingest_rw` login | ingest-mqtt |
| `postgres_password` | superuser bootstrap | postgres |
| `jwt_secret`, `url_signing_key` | 32 random bytes each | api (+ scheduler for signed export links) |
| `s3_access_key`, `s3_secret_key` | MinIO root | api, workers, scheduler |
| `line_channel_token` / `line_channel_secret` | Messaging API token / webhook secret | scheduler / api |
| `discord_webhook`, `fcm_server_key`, `vapid_private`, `smtp_url` | optional channels | scheduler |
| `weather_api_key` | provider key (empty file for Open-Meteo) | api, scheduler |
| `mqtt_ingest` | `ingest:<password>` | ingest-mqtt, sensor-sim |
| `mqtt_passwd`, `mqtt_acl`, `mqtt_certs/` | broker password file, ACL, TLS material (generated, §5.1) | mosquitto (mounted) |

Bootstrap: `gapfarm secrets init` writes random keys and the four role URLs; the role passwords are set in PostgreSQL by `gapfarm db roles-sync` after first start (roles are created by `schema.sql` with `NOLOGIN`; the tool adds `LOGIN` and passwords).

### 4.3 Steps
1. `cp .env.example .env`; set `PUBLIC_URL`, `BIND_ADDR`, `MQTT_BIND_ADDR`, image tags; keep the rest.
2. Copy `gapfarm.example.yaml` → `/etc/gapfarm/gapfarm.yaml`; validate: `gapfarm config check` (schema + loader rules; TC-006).
3. Copy `schemas/`, `schemes/thaigap.yaml`, `inputs/approved-products.yaml` (**after** verifying every PHI/REI/MRL against the labels — §5.3), `prompts/`, `glossary.csv`.
4. `docker compose build postgres && docker compose --profile cpu --profile mqtt up -d` — `schema.sql` is applied on first start (initdb); `minio-init` creates the buckets.
5. `gapfarm db roles-sync`; `gapfarm scheme import thaigap.yaml`; `gapfarm inputs import approved-products.yaml` (two-person approval is enforced: the importing admin cannot be the approver of an entry).
6. `gapfarm models pull chili-v3 chili-v3-lite` — downloads artefacts and manifests into the `models` volume, registers them (`draft`), records the field evaluations and calibrations from the manifests, and **releases them only if the gates pass** (`RELEASE_GATE_FAILED` otherwise).
7. `gapfarm crops import chili.yaml` (crop, stage model, conditions); create the farm, zones and users in the admin UI (UM-12 Part B).
8. Optional: seed the demo farm for training — `psql -f db/seed_demo.sql` (development only; it creates real-looking records).
9. `docker compose ps` — all healthy; `GET /readyz` → `ok`; `gapfarm doctor` runs TC-004-style checks against the running stack.

## 5. Providers, devices and data

### 5.1 Sensors (IF-12.1)
Register each sensor in the admin UI (`POST /sensors`): zone, kind (fixes unit and range), device code. The response shows the MQTT credential **once**; `gapfarm sensors acl-sync` rewrites `mqtt_passwd`/`mqtt_acl` and reloads the broker (a device may publish only to `farm/<farm>/<zone>/<signal>`). TLS: `gapfarm mqtt certs init` creates a CA and the server certificate; devices get the CA. Firewall 8883 to the farm's address range. Verify: publish from the device, see the reading on `/sensors`; publish to another topic → refused (TC-091).

### 5.2 Weather (IF-12.2)
`WEATHER_PROVIDER=open-meteo` needs no key. When the provider is down the dashboard shows "weather unavailable" and forecast-dependent advisories are suppressed — this is by design, do not "fix" it by extending the cache. `gapfarm weather refresh` forces a fetch.

### 5.3 Approved-input list (IF-65) — the most important file you maintain
Every entry needs the registered label (PDF in the `labels` bucket, `label_uri`), PHI, REI, rainfast, MRL with source, target conditions and cautions. **The values in `approved-products.example.yaml` are examples.** Import creates entries as unapproved; a *second* admin approves each in the UI (or the file carries `approved_by` different from `author`). Removing a product keeps its historical usages. Every change is audited with a diff; the list version appears on every recommendation. Review the list at least once per season and whenever a label or regulation changes.

### 5.4 Schemes (IF-66)
`deploy/schemes/thaigap.yaml` — templates (field order in the export) and rules (mandatory records, maximum gaps). Map it to the scheme's current checklist with the certifying body before the first audit; a new version is a new file and import; exports of old periods use the scheme version then in force.

### 5.5 LINE (IF-67), push, Discord, mail
LINE: create the Messaging API channel, set the webhook to `https://<host>/api/v1/line/webhook` (signature verified with `line_channel_secret`), put the token in `line_channel_token`; farmers link their account through LINE Login. Push: FCM key / VAPID pair. Discord: a webhook per farm channel. Mail: `smtp_url`. Without any of them the app still shows reminders in-app; `gf_reminders_failed_total` tells you when a channel is broken.

## 6. Configuration (`gapfarm.yaml`)
Validated at start by every service against `schemas/gapfarm-config.schema.json`; a violation refuses to start with the JSON-pointer of the offending key. The schema **pins**: PHI enforcement `block`, append-only, hash chain, approved-list-only, two-person approval, OOD refusal, calibration required, gates ≥ 0.80/0.93, device model ≤ 25 MB, sensor buffer ≥ 24 h, LLM ≤ 9 B at temperature ≤ 0.3, scripted fallback, suppression when weather is unavailable. Tunables: review threshold (≥ 0.5), severity bands, quiet hours, reminder/due times, escalation hours, fault rules, irrigation thresholds, prediction minimum seasons (≥ 2), retention. Loader rules beyond the schema: quiet-hours start ≠ end, severity low < moderate, exposure min < max. Runtime constants also live in `farm.setting` (DDS-12 §3) — `gapfarm config check` compares the two and refuses to start on a mismatch.

## 7. Model lifecycle (AI-01…AI-06, AI-09)
1. **Field set first.** ≥ 640 real phone photos per crop family (mixed lighting, backgrounds), labelled by two agronomists, versioned in the `models` bucket. Lab sets are allowed for development, never for release.
2. **Evaluate**: `gapfarm models eval <model> --set field-chili-2026Q3` writes a `model_eval_run`; `passed` is computed by the database.
3. **Calibrate**: temperature scaling on a held-out slice; ECE ≤ 0.05; reliability bins recorded (`calibration_version`, active).
4. **OOD threshold** chosen on the field set + a non-plant set (AUROC ≥ 0.90).
5. **Release**: `gapfarm models release <model>` — refused without a passed field evaluation, an active calibration, or over 25 MB for device models. Devices pick up the new artefact from `Device.recommended_model` (sha256 checked).
6. **Monitor**: `v_diagnosis_quality` (OOD rate, review rate, corrected rate, mean top-1 per model version); a corrected rate > 15 % over 30 days is a retraining trigger.
7. **Retrain** from `label_example` rows (provenance kept) + the field set; back to step 2. Prompt changes (`prompts/*.v1.md → v2`) require the adversarial set to pass (TC-092) before deploy.

## 8. Routine operations
| When | What | How |
|---|---|---|
| Daily | reminders/escalations sent; sensor faults; weather refreshed; compliance gap scan (05:00); retention (03:00) | scheduler; check `gf_reminders_failed_total`, `gf_sensor_faults_open`, `gf_weather_available` |
| Weekly | weekly summaries (Mon 06:00); review queue age; chain verification of every zone (`SELECT * FROM farm.v_chain_status`) | `gf_review_age_seconds`, `chain_ok = true` everywhere |
| Monthly (25th) | next telemetry partition; backup restore test (quarterly) | `PARTITION_CRON`; RB-05 |
| Per season | approved-list review; scheme mapping check; field-set refresh; model evaluation | §5.3, §5.4, §7 |
| Before an audit | export the period; verify; hand the manifest and chain heads to the auditor | §10 |

## 9. Monitoring
Metrics in ICD-12 IF-14. Alerts: `gf_chain_verify_failures_total > 0` (page), `gf_unapproved_product_refusals_total` rising (advice-integrity incident — RB-10), `gf_phi_refusals_total` (informational; someone tried), `gf_sync_lag_seconds > 300`, `gf_review_age_seconds > 172800` (2 d), `gf_sensor_faults_open{kind="offline"} > 0` for > 24 h, `gf_weather_available == 0` for > 6 h, `gf_reminders_failed_total` rising, `gf_model_fallback_total` rising (Ollama down — not an outage, but check), `gf_ingest_buffer_depth` rising (database unreachable from ingest). Logs carry correlation ids, never personal data (SEC-G24).

## 10. Audit support, backup and retention
**Export and verify**: `GET /export/gap?from=&to=` → package; `GET /export/gap/{id}/verify`. Give the auditor the PDF, the XLSX and `manifest.json`; keep a copy of every manifest **off the server** (e.g. the auditor's mailbox and the farm's own storage) — this is what makes THR-G04 (operator rewriting history) detectable: the chain heads in older manifests must still match. Offline verification of the XLSX `chain` sheet:
```python
import hashlib, openpyxl
ws = openpyxl.load_workbook('package.xlsx')['chain']; prev = {}
for zone, seq, kind, no, ver, payload, prev_hash, h in ws.iter_rows(min_row=2, values_only=True):
    assert prev.get(zone) == prev_hash, (zone, seq)
    assert hashlib.sha256(((prev_hash or '') + payload).encode()).hexdigest() == h, (zone, seq)
    prev[zone] = h
print('chain ok', prev)
```
(`payload` is the jsonb canonical text stored in `record_chain.payload`; DDS-12 DD-G02.)

**Backups**: nightly `pg_dump` (custom format) + MinIO mirror to an encrypted off-site bucket; the exports bucket is object-locked (compliance mode, 5 y) so a restore cannot silently shorten it. Restore test quarterly (RB-05) — after restore, `v_chain_status` heads must equal the last export's manifest.

**Retention** (config `privacy.*`): refused-diagnosis photos 30 d; PASS photos 365 d; evidence photos with their records (forever); telemetry 2 y; forecasts 1 y; exports 5 y; PDPA packages 7 d; records forever.

**PDPA operations**: export requests are fulfilled by the scheduler within 24 h; erasure requests within the SLA (30 d) — the scheduler completes them (`trg_pdpa_erasure` pseudonymises; records stay). Consent version changes require re-acceptance at next login.

## 11. Runbooks
| ID | Situation | Steps |
|---|---|---|
| RB-01 | API not ready | `docker compose ps`; `GET /readyz` lists the failing check (db / minio / redis); the model and the weather provider never block readiness |
| RB-02 | Diagnoses slow or queued | check `worker-vision` logs and `gf_diagnosis_latency_seconds`; CPU profile: reduce `CPU_THREADS` contention; queued diagnoses drain automatically; farmers can still record (FR-08) |
| RB-03 | Ollama down / answers say `fallback: true` | not an outage — scripted answers are complete for lookups; restart `ollama-cpu`; check memory (7 B needs ≈ 5 GB) |
| RB-04 | Weather unavailable > 6 h | provider status; key; egress firewall; advisories stay suppressed by design |
| RB-05 | Restore from backup | restore `pg_dump` + MinIO mirror; `gapfarm db roles-sync`; compare `v_chain_status` heads with the last export manifest; if they differ, treat as RB-06 |
| RB-06 | Chain verification fails / export mismatch | freeze writes for the zone (`UPDATE farm.setting` is not enough — revoke `app_rw` INSERT on the record tables temporarily); compare with the last off-site manifest; identify the first failing `seq`; restore; report to the certifying body if an exported period is affected |
| RB-07 | Sensor offline > 24 h | maintenance task already exists; check device power/coverage; broker ACL; `gapfarm sensors acl-sync` |
| RB-08 | Signed-URL / JWT key rotation | write new `url_signing_key` / `jwt_secret`; `docker compose restart api scheduler`; all sessions re-login; in-flight export links expire |
| RB-09 | LINE token leaked or rotated | issue a new token in the LINE console; replace `line_channel_token`; restart `scheduler`; check `gf_reminders_failed_total` |
| RB-10 | Advice-integrity incident (an unapproved product name seen) | `AGENT_ENABLED=false` + restart `api worker-agent`; pull the answer row and facts; run TC-092; fix the prompt or the list; re-enable |
| RB-11 | Spoofed / faulty sensor readings | disable the device credential (`gapfarm sensors disable <code>`), resolve faults, mark affected readings `quality = stuck` with a note; advisories are advisory only |
| RB-12 | Farmer's phone lost | `gapfarm users revoke <user>` (refresh tokens, device, push token); the local store on the phone holds only that user's own data |
| RB-13 | Model release refused | read the reason (`RELEASE_GATE_FAILED` / `CALIBRATION_REQUIRED` / `DEVICE_MODEL_TOO_LARGE`); §7 — never override |
| RB-14 | Mass PHI refusals at harvest time | a product with a long PHI was applied late; the PHI board (`v_zone_phi`) shows `clear_at`; there is no override in v1 — plan the split of zones for next season (README known gaps) |

## 12. Verification of this guide's artefacts (executed 2026-09-20)
| Check | Result |
|---|---|
| `docker-compose.yml` parses; 17 services; profiles gpu / cpu / mqtt / dev | ✅ |
| Hardening on 7 app services; ports on `BIND_ADDR` (web, api, mailpit) and `MQTT_BIND_ADDR` (8883) | ✅ |
| `sensors` network = broker + ingest + sim only; broker the only member with a port; egress = api + scheduler; 9 internal-only services; `internal: true` | ✅ |
| Four database roles by service; LINE token only on scheduler, LINE secret only on api; weather key only on api + scheduler; worker-agent and ingest without channel/S3 secrets as specified | ✅ |
| `${VAR}` used ⊆ `.env.example` and vice versa: 53/53; secrets referenced = defined: 17/17 | ✅ |
| Buckets private; exports object-locked; photos versioned; refused photos expire; ingest buffer volume; models read-only | ✅ |
| `gapfarm.example.yaml` valid; 45/45 schema negatives rejected; loader rules hold | ✅ |
| Secret scan | ✅ none |
| **Stack actually started; PostgreSQL applied `schema.sql` + `seed_demo.sql`** (TC-009) | ⚠️ **not executed** — no Docker daemon on the authoring machine |

To execute what could not be executed here:
```bash
cd 12-gapfarm-ai-agent/deploy && docker compose build postgres
docker run -d --name gf-pg -e POSTGRES_PASSWORD=x -p 5435:5432 $(docker compose config --images | grep postgres-postgis-pgvector)
sleep 10 && psql "postgresql://postgres:x@localhost:5435/postgres" -v ON_ERROR_STOP=1 -f ../db/schema.sql \
  && psql "postgresql://postgres:x@localhost:5435/postgres" -f ../db/seed_demo.sql
```
Expected: the `\echo` block matches the seed header (chain heads `05ff22f2ff8d` / `eed384754914` / `d1b32c897c84`; SC-2026-0412 v1/v2; export 27 records, gap 1, `727922173316…`; forecast A yield 1450.0 [1102.2, 1797.8], B date 2026-10-06 [10-06, 10-07]; faults 3; risk advisories 3) and the 15 probes each fail inside their savepoint.
