# Deployment & Operations Guide — MachineSense AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | OPS-06-MachineSense |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/sensors.example.yaml`](../deploy/sensors.example.yaml) · [`deploy/alert-rules.example.yaml`](../deploy/alert-rules.example.yaml) · [`deploy/schemas/`](../deploy/schemas/) · [`deploy/mosquitto.conf.example`](../deploy/mosquitto.conf.example) · [`deploy/mosquitto.acl.example`](../deploy/mosquitto.acl.example) |
| Related | [SAD-06](SAD-MachineSense-Software-Architecture.md) · [DDS-06](DDS-MachineSense-Database-Design.md) · [ICD-06](ICD-MachineSense-Interface-Control.md) · [SEC-06](SEC-MachineSense-Security-Requirements.md) · [TEST-06](TEST-MachineSense-Test-Plan.md) · [UM-06](UM-MachineSense-User-Admin-Guide.md) · platform mode: [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) |
| Audience | Plant IT/OT (install, network, OT accounts), reliability engineer (onboarding, baselines, models, rules), on-call (runbooks) |

---

## 1. What you are operating

A stack that **reads** machines and **advises** people. Two facts govern every procedure:

- **Onboarding a machine is a controls change, not an IT change.** It creates a read-only account on a controller (or a Modbus register map on an isolated segment) and is finished only when TC-020 proves the account cannot write. Do it with the controls engineer.
- **Alerts are only as good as the baseline and the feedback.** The first four weeks of a machine are a data-collection period; the engineer confirms the healthy window; from then on every closed alert needs a technician's verdict, and the monthly precision report tunes the rules. Skip either and the system produces noise.

And one guarantee to keep: **nothing here can affect a machine** (C-01). If a procedure ever seems to need a write to a controller, stop — it is outside this system.

## 2. Topology and sizing

| Host | Runs | Networks | Notes |
|---|---|---|---|
| **Ingest host** (near the OT segment; may be the same server for small plants) | `ingest-mqtt`, `ingest-opcua`, `ingest-modbus`, `mosquitto` | `ot` (OT VLAN / direct NIC), `internal` | Only host with a route into Z1; local buffer volumes ≥ 24 h (≈ 1.1 GB/h at 50 k/s compressed) |
| **Server** | `postgres` (TimescaleDB), `redis`, `features`, `scoring`, `alerting`, `agent`, `scheduler`, `api`, `web`, `ollama` | `internal`, `frontend`, `egress` | 8+ cores, 32 GB, NVMe: raw 90 d at 50 k/s ≈ 90 GB compressed + rollups; GPU optional for Ollama |

Fleet sizing rule of thumb: 50 k samples/s ≈ 5,000 sensors at 10 Hz or 50,000 at 1 Hz; `features` workers ≈ 1 per 100 machines; `scoring` one process handles ~500 machines at 60 s.

## 3. Networks and OT access

- **Z1 OT segment**: machines, DAQ, the broker's TLS listener (`OT_BIND_ADDR:8883`). Firewall: allow only ingest host ↔ controllers (OPC-UA 4840, Modbus 502) and gateways → broker 8883. **No route from Z1 to the server.**
- **Compose `ot` network** is bridged to the OT-facing NIC on the ingest host (`br-ms-ot`); nothing else joins it (TC-004).
- **Modbus** only on an isolated segment with ACLs; sign the risk acceptance (SEC-P32) before enabling the `modbus` profile.
- **Egress** from the server: Discord, SMTP, the CMMS webhook, Genba Memory (platform mode). Nothing else.

## 4. Installing and onboarding

### 4.1 Steps
```bash
sudo mkdir -p /etc/machinesense/secrets/opcua /etc/machinesense/secrets/mosquitto_tls && sudo chmod 700 /etc/machinesense/secrets
git clone <repo> && cd 06-predictive-maintenance-agent/deploy
cp .env.example .env && chmod 600 .env          # BIND_ADDR, OT_BIND_ADDR, GPU_COUNT, model, Discord ids
cp sensors.example.yaml /etc/machinesense/sensors.yaml         # edit per §4.4
cp alert-rules.example.yaml /etc/machinesense/alert-rules.yaml
cp mosquitto.conf.example /etc/machinesense/mosquitto.conf && cp mosquitto.acl.example /etc/machinesense/mosquitto.acl
```

### 4.2 Secrets (files, 0400, `root:10001`)
| File | Content | Used by |
|---|---|---|
| `database_url` | `postgresql://app_rw:<pw>@postgres:5432/machinesense` | all app services |
| `postgres_password` | `app_rw` password | postgres |
| `jwt_secret` | 48 random bytes | api |
| `mqtt_ingest` | `ms-ingest:<password>` | ingest-mqtt |
| `mosquitto_passwd`, `mosquitto_tls/` | broker password file (`mosquitto_passwd -U`), CA + broker cert/key | mosquitto |
| `opcua/<credential_ref>` | `user:password` for each `secret:…` in the sensor map — **read-only accounts** | ingest-opcua |
| `opcua_client.crt/.key` | client certificate trusted on each controller | ingest-opcua |
| `discord_bot_token`, `smtp_url`, `alert_webhook_hmac`, `cmms_webhook_hmac` | delivery and export | alerting, api |

Never put any of these in `.env`, the sensor map or the alert rules (TC-007).

### 4.3 Model and start
```bash
docker compose up -d ollama && docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M
docker compose --profile opcua --profile modbus up -d       # schema.sql applies on first postgres start; TimescaleDB block converts hypertables
msctl config load /etc/machinesense/sensors.yaml            # PUT /config/sensor-map (admin) — schema-validated
msctl config load /etc/machinesense/alert-rules.yaml        # PUT /config/alert-rules (engineer)
curl -s http://$BIND_ADDR:8080/api/v1/readyz                # db, timescaledb, redis, broker true; ingest_lag/feature_lag 0; llm true
```
Demo data (non-production only): `psql … -f ../db/seed_demo.sql` reproduces the Appendix A alert.

### 4.4 Onboarding a machine — the controls change

| # | Step | Who | Done when |
|---|---|---|---|
| 1 | Add the machine to `sensors.yaml`: code, type, criticality, signals with units and ranges, contexts, components | reliability engineer | file validates (`msctl config validate`) |
| 2 | **OPC-UA**: controls engineer creates `machinesense_ro` on the controller — browse/read/subscribe only; trusts the client certificate; you store the credential as `secrets/opcua/<ref>` | controls + IT | — |
| 3 | **TC-020**: `msctl opcua write-test M-07` attempts a write with that account → the controller must answer `BadUserAccessDenied`. Record the result. **Repeat quarterly.** | IT | refused |
| 4 | **Modbus**: register map with explicit type/word order/scale; verify one value against the device display (TC-030); segment isolated; risk acceptance signed | controls + IT | matches |
| 5 | **MQTT gateway / DAQ**: broker user + ACL line for the machine prefix; DAQ publishes IF-38 features with the RPM reference | IT | messages arrive; `msctl sensors M-07` shows `ok` |
| 6 | Watch data quality for 48 h: no gaps/stuck/skew events; contexts classify sensibly (`/machines/M-07/context`) | engineer | clean |
| 7 | **Collect ≥ 4 weeks** covering all normal contexts (AI-01) — alerts are disabled meanwhile (`alerts_enabled = false`) | — | 28+ days |
| 8 | Propose the baseline (`POST /baselines`), review coverage per context and the band on the charts, **confirm** it (`…/confirm`) — this is the engineer asserting the window was healthy | engineer | `alerts_enabled = true` |
| 9 | First week live at WATCH-only delivery (rules `min_severity: HIGH` off for the machine group), then normal | engineer | precision review after 30 days |

## 5. TimescaleDB: sizing, compression, retention

### 5.1 Sizing
| Rate | Rows/day | Raw, uncompressed (~60 B/row) | Compressed (≈ 10×) | 90 d compressed |
|---|---|---|---|---|
| 5 k/s (small plant) | 432 M | 26 GB | 2.6 GB | 230 GB → with 7-day compression delay ≈ 30 GB |
| 50 k/s (NFR-01) | 4.3 B | 260 GB | 26 GB | ≈ 90 GB compressed + ≈ 180 GB for the 7 uncompressed days |

Plan NVMe at 2× the 50 k/s figure for headroom and chunk rewrites; `PG_SHARED_BUFFERS` at 25 % of RAM; chunk interval 1 day for `telemetry.sample` (set by the schema's DO block, ADR-P01).

### 5.2 Compression
`telemetry.sample` chunks compress after 7 days, segmented by `sensor_id`, ordered by `ts` (schema §15). Compression runs as a TimescaleDB background job; check `timescaledb_information.jobs` weekly (RB-10). `feature`, `anomaly_score` and `health_index` are hypertables (7 / 30 / 30-day chunks) but are not compressed by the shipped schema — enable it once they pass ~50 GB, same `segmentby`.

### 5.3 The 1-minute rollup and the continuous aggregate
`telemetry.sample_1m` (n, avg, min, max, stddev, good %) is what charts and the seed use and what survives the raw retention. Two supported ways to fill it:

| Mode | How | When |
|---|---|---|
| **Scheduler (default, both configurations)** | `telemetry.rollup_1m()` every hour (`ROLLUP_CRON`), idempotent upsert of the previous complete minutes | always works; native-partition fallback has no other option |
| **Continuous aggregate (TimescaleDB only)** | replace the table with a continuous aggregate over `telemetry.sample` with `refresh_policy` every 10 min; disable `ROLLUP_CRON` | plants above ~20 k samples/s, where the hourly SQL rollup starts to compete with ingest |

Switching is an operator decision recorded in the change log; the view `v_machine_health_latest` and the API do not care which one fills the table.

### 5.4 Retention
| Data | Keep | Mechanism |
|---|---|---|
| Raw `sample` | 90 d (`RETENTION_RAW_DAYS`) | TimescaleDB retention policy / scheduler job (fallback) |
| `sample_1m` rollups | 2 y | scheduler job |
| `feature`, `anomaly_score`, `health_index` | 2 y | retention policy / scheduler |
| `alert*`, `failure_event`, `maintenance_event`, `baseline`, `config_version`, `audit.log` | 5 y — **never auto-deleted** | none (manual archive only) |

`v_retention_due` lists what the next job will remove; a retention job that deletes from an alert or failure table is a bug, not a policy.

## 6. Day-to-day operation

### 6.1 Observability of MachineSense itself
| Signal | Where | Meaning |
|---|---|---|
| `/readyz` | API | db, timescaledb, redis, broker, `ingest_lag_s`, `feature_lag_s`, `llm`, `buffer_depth` |
| Metrics (IF-14) | `:8080/metrics` | ingest rate, lags, buffer depth, alerts/day, suppressed/day, precision 30 d, LLM breaker |
| Data quality | `/telemetry/data-quality`, `v_sensor_health` | gaps, stuck, range, skew, offline per sensor |
| Audit | `audit.log` | baselines, rules, windows, alerts_enabled, exports |

Alerts about the agent (delivered on the same channels, tagged `machinesense:`):

| Alert | Condition | Runbook |
|---|---|---|
| Ingest lag | `ingest_lag_s > 30` for 5 min | RB-01 |
| Buffer filling | `buffer_depth` > 50 % of 24 h | RB-02 |
| Feature/scoring lag | > 60 s for 10 min (NFR-02) | RB-03 |
| Sensor offline / stuck | per sensor health | RB-04 |
| OPC-UA session loss | > 5 min | RB-05 |
| Clock skew | any source > 5 s | RB-06 |
| Precision below target | 30-day precision < 0.7 for a machine | RB-07 |
| Grounding failures | > 10 % of explanations withheld | RB-08 |
| LLM unavailable | breaker open | RB-09 |
| Disk / retention | hypertable size > 80 % of allotment; retention job failed | RB-10 |

### 6.2 SLOs
| SLO | Target | Measured by |
|---|---|---|
| Ingest availability (no lost samples) | 100 % with ≤ 24 h outages (NFR-05) | buffer replay reconciliation |
| Feature lag | ≤ 60 s p95 (NFR-02) | metric |
| Alert latency | ≤ 5 min p95 from condition (NFR-03) | alert `opened_at` vs third window end |
| Chart p95 | ≤ 2 s (NFR-04) | API latency |
| Precision | ≥ 0.7; ≤ 1 false alert / machine / month (AI-03) | `v_alert_precision` |
| Availability | ≥ 99 % (NFR-07 — and machines are never affected) | uptime |

### 6.3 The monthly precision review (the most important routine)
1. `GET /reports/precision?months=1` per machine.
2. Machines with precision < 0.7: read the false positives' `actual_finding` (sensor bracket? changeover missed? wrong context rule?). Fix the *cause* — a context rule, a suppression window kind, a sensor — before touching thresholds.
3. If thresholds are the cause: raise `consecutive_windows` or the `sigma_min` for that severity in `alert-rules.yaml`; load a new version (stamped on every alert from then on).
4. Machines with detected failures: check `lead_time_days`; if < 3 days, discuss with the ML owner (retrain, features).
5. Record the review in the change log.

### 6.4 Baselines and re-baselining
Component replaced / overhaul / failure repair → the maintenance event flags `rebaseline_required`; alerts for the machine downgrade to WATCH; collect 4 weeks; propose and confirm a new baseline; the flag clears. Never confirm a window that contains the degradation you are trying to catch — that is the risk the confirmation step exists for.

### 6.5 Models
Retraining runs monthly and after every confirmed failure. A candidate is promoted only if its retrospective precision and lead time are ≥ the active version's (the database refuses otherwise). Review `GET /models/retrain-runs` monthly; a repeatedly rejected candidate means the retrospective set needs more labelled failures (`POST /failures`).

### 6.6 Retention
See §5.4. Check `v_retention_due` and hypertable sizes weekly; RB-10.

## 7. Backup
Nightly `pg_dump` of everything except `telemetry.sample` (raw is reproducible from gateways for 24 h and rolled up anyway) plus a weekly base backup of the hypertables; alerts, baselines, feedback, failures and config versions are the assets. Restore test quarterly. Model artefacts (`models` volume) backed up with their `anomaly_model` rows.

## 8. Upgrades
Pull images → `docker compose up -d`; migrations forward-only at API start; a pre-migration dump. Any change to feature extraction or scoring re-runs the retrospective set before release (TEST-06 §5).

## 9. Platform mode
Apply `db/schema.sql` §10 as migration `machinesense_0001` on the platform database (OPS-00 migration procedure); convert the populated hypertables as a deliberate migration (DDS-00 §7.3; OPS-00 RB-12 if it fails — not the §15 DO block, which is for a fresh database); point the containers at the platform DB, Ollama and auth; register the tools; set `GENBA_MEMORY_URL`. The five shared API paths are then served by the platform; the rest mounts under the platform gateway.

## 10. Runbooks

| RB | Symptom | Diagnose | Fix |
|---|---|---|---|
| **RB-01** | Ingest lag rising | `/readyz.ingest_lag_s`; which ingest process; DB write latency | DB slow → check compression jobs and disk; single source flooding → broker rate limit; add ingest workers |
| **RB-02** | Buffer filling / DB unreachable | `buffer_depth`; postgres health | Fix the DB; the buffer replays automatically (AC-05); if > 20 h, add disk to the ingest host before it fills |
| **RB-03** | Feature or scoring lag > 60 s | worker CPU; number of machines; `FEATURE_WORKERS` | Scale workers; check for a runaway derived expression; confirm `SCORING_INTERVAL_S` |
| **RB-04** | Sensor offline / stuck / gap | `v_sensor_health`; data-quality events | Field check the sensor and cable; a stuck register is a device fault; while unresolved, scoring excludes the sensor (quality < 192) |
| **RB-05** | OPC-UA session loss | controller reachable? certificate expiry? account locked? | Fix network/cert; **never** widen the account's rights; re-run TC-020 after any account change |
| **RB-06** | Clock skew events | which source; NTP on gateway/controller | Fix NTP at the source; evidence timestamps stay honest (receive time stored) |
| **RB-07** | Precision below 0.7 | §6.3 | Fix causes first, thresholds second |
| **RB-08** | Explanations withheld (grounding) | `agent.run.grounding_json`; prompt/model version changed? | Roll back `PROMPT_VERSION`/model; the structured recommendation is always delivered meanwhile |
| **RB-09** | LLM down | Ollama logs, GPU | Alerts unaffected; restart Ollama; CPU model if the GPU failed |
| **RB-10** | Disk / retention | `v_retention_due`; TimescaleDB jobs (`timescaledb_information.jobs`) | Re-enable jobs; compress older chunks; never delete `alert*`/`failure_event` |
| **RB-11** | Alert storm on one machine | grouping working? contexts? sensor fault? | Check `v_open_incidents` (should be 1 per component); declare a maintenance window if service is under way; fix the context rule or sensor |
| **RB-12** | Suspected false telemetry / injected data | unknown-signal events; rate anomalies; broker logs | Rotate the gateway credential; add a data-quality event for the range; SEC-06 §7 |
| **RB-13** | Baseline captured while degraded | alerts silent on a machine that failed; baseline window overlaps early symptoms | Retire the baseline version; confirm a new healthy window (may need to reach back further in history) |
| **RB-14** | CMMS export failing | `502 CMMS_EXPORT_FAILED`; webhook logs | Fix the endpoint/HMAC; drafts are kept and re-exportable; PDF export meanwhile |

## 11. Traceability
| SRS-06 | Section |
|---|---|
| C-01, C-02, NFR-06 | §1, §4.4 steps 2–3, RB-05 |
| C-03 | §4.4 step 5 |
| AI-01, FR-08 | §4.4 steps 7–8, §6.4 |
| AI-03, FR-20 | §6.3 |
| AI-06 | §6.5 |
| AI-07 | §6.4 |
| NFR-01…NFR-05 | §2, §6.1, §6.2, RB-01…03 |
| NFR-07 | §1 |
| NFR-09 | RB-06 |
| §5 retention (SRS) | §5, §6.6, §7 |
