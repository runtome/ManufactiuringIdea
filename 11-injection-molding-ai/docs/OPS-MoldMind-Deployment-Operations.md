# Deployment & Operations Guide — MoldMind (AI Vision + Agent for Injection Molding)

| Field | Value |
|---|---|
| Document ID | OPS-11-MoldMind |
| Version | 1.0 (Draft) |
| Date | 2026-09-18 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-11](../SRS-MoldMind-Injection-Molding-AI.md) · [SAD-11](SAD-MoldMind-Software-Architecture.md) · [DDS-11](DDS-MoldMind-Database-Design.md) · [ICD-11](ICD-MoldMind-Interface-Control.md) · [SEC-11](SEC-MoldMind-Security-Requirements.md) · [TEST-11](TEST-MoldMind-Test-Plan.md) · [UM-11](UM-MoldMind-User-Admin-Guide.md) · files: [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/moldmind.example.yaml`](../deploy/moldmind.example.yaml) · [`deploy/schemas/`](../deploy/schemas/) · [`deploy/machines/M-3.opcua.yaml`](../deploy/machines/M-3.opcua.yaml) · [`deploy/kb/`](../deploy/kb/) · platform: [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) |

---

## 1. What you are operating
A read-only listener on a press, a camera next to it, and an analysis stack that turns "sink marks went up on cavity 3 after 10:40" into an ordered set of checks and one bounded suggestion. The machine side is the part you cannot get wrong: the OPC-UA account must be read-only *on the machine*, the node map must resolve, the enclosure must survive the press. The knowledge side is the part that decays: keep the KB sourced and approved, keep the windows current, run the golden set on every change.

Four operational truths this guide enforces:
- **MoldMind never writes to the machine** — the account is read-only on the server, the client has no write method, and a refused write is an incident (RB-02, RB-11).
- **No suggestion outside the documented window reaches a technician as allowed** — `v_suggestion_audit` shows every block (RB-07).
- **Knowledge is versioned, sourced and approved by a second engineer; every change runs the golden set** (RB-08).
- **Startup transients never raise trends; the gateway buffers 24 h; a defect always belongs to one shot and one cavity** (RB-04, RB-05, RB-06).

## 2. Topology and sizing
| Where | Component | Sizing / spec |
|---|---|---|
| Press side | **Camera station**: GigE camera + per-class lighting rig (low-angle/deflectometry for sink marks and weld lines) in an IP65 enclosure with forced-air cooling (internal ≤ 55 °C at 45 °C ambient), vibration-isolated mount, oil-mist-resistant window; reference colour chart fixed in frame | NFR-07; ICD-00 IF-02 |
| Press side | **Edge box** (`vision-infer`, capture): RTX-class 8 GB GPU or Jetson Orin; ≤ 150 ms per part; on the camera network only | NFR-02 |
| Machine network | **Gateway box** (`gateway-opcua` / `gateway-mqtt`): 2 vCPU / 2 GB / 64 GB SSD (≥ 24 h buffer ≈ 7,200 shots/day × 4 KB); OPC-UA client certificate; on the machine network only | NFR-05 |
| Server | `api`, `web`, `aligner`, `analyser`, `kb-service`, `rca-agent`, `scheduler`, `postgres` (pgvector), `redis`, `minio`, `ollama` | 16 vCPU / 32 GB / 1 × 8 GB GPU (shared with dialogue) / 500 GB NVMe; shots 2 y ≈ 25 GB/machine; images 200 GB |

## 3. Networks
| Network | Members | Reaches |
|---|---|---|
| `machine` (`internal: true`) | `gateway-opcua`, `gateway-mqtt` (+ `machine-sim` in dev) | the press's OPC-UA server / broker — **read-only** |
| `camera` (`internal: true`) | `vision-infer` (+ `camera-replay` in dev) | the camera station |
| `internal` (`internal: true`) | everything but `web` and the simulators | no egress |
| `frontend` | proxy → `web`, `api` | LAN, TLS |
| `egress` | `api`, `scheduler` (+ `mailpit` in dev) | Discord / SMTP — statistics and links only |

No container is on both `machine` and `camera`; `rca-agent` and `ollama` are on `internal` only. `check_deploy11.py` (TEST-11 TC-004) verifies the placement.

## 4. Installing
### 4.1 Steps
1. Hosts: server Ubuntu 24.04 + Docker 27 + NVIDIA toolkit; gateway box (Ubuntu, Docker); edge box (JetPack or Ubuntu + CUDA); `chrony` everywhere (clock skew is a data-quality flag).
2. `git clone …/11-injection-molding-ai && cd deploy && cp .env.example .env && chmod 600 .env`; set `PUBLIC_URL`, `CAMERA_STATION_URL`, `MQTT_URL` (if used), `QE_URL`.
3. Create `${SECRETS_DIR}` and the 17 secret files (§4.2) — including the machine's **read-only** OPC-UA account and the client certificate.
4. `${CONFIG_DIR}`: `moldmind.yaml` (from `moldmind.example.yaml`), `machines/<machine>.opcua.yaml` (node map), `kb/*.yaml`, `prompts/`, `schemas/`, `glossary.csv`.
5. `docker compose --profile gpu up -d postgres minio minio-init` (schema auto-applied) → create the login roles (§4.2).
6. Onboard the machine (§5) — certificate trust on the press, node-map validation, **write-refusal test** — before starting production ingest.
7. `docker compose --profile gpu up -d` → `docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M` → copy the family model(s) into the `models` volume.
8. `mmctl config load moldmind.yaml` → `mmctl kb import kb/*.yaml --version kb-2026.09.1` → approval by a second engineer (§8) → `mmctl glossary load glossary.csv` → `mmctl prompts register`.
9. Onboard moulds (§6: setup sheet, windows, colour reference, scrap cost) → camera station commissioning (§7) → `mmctl selftest` (§4.5) → attribution trial (TEST-11 TC-024) → golden run (§8).

### 4.2 Secrets (files, 0400, `root:10001`) and database login roles
| File | Used by | Content |
|---|---|---|
| `database_url` | `api`, `analyser`, `rca-agent`, `scheduler` | `postgresql://app_rw:…@postgres/moldmind` |
| `gateway_database_url` | `gateway-opcua`, `gateway-mqtt` | role `gateway_rw` — **INSERT** shots/context/changes/batches only (DDS-11 §8) |
| `vision_database_url` | `vision-infer`, `aligner` | role `vision_rw` |
| `kb_database_url` | `kb-service` | role `kb_rw` |
| `postgres_password` | `postgres` | superuser — never used by a service |
| `jwt_secret`, `url_signing_key` | `api` | 32+ random bytes; rotate on incident |
| `s3_access_key`, `s3_secret_key` | server services | MinIO root (standalone); scoped user in platform mode |
| `gateway_service_token` | `api` (verifies the gateway's batch uploads) | |
| `qe_service_token` | `api`, `rca-agent`, `scheduler` | QE-Agent handoff (IF-62) |
| `opcua_client_cert`, `opcua_client_key` | `gateway-opcua` | client certificate trusted on the press |
| `opcua_readonly_<machine>` | `gateway-opcua` | **the read-only OPC-UA account** — created on the press by the machine vendor/OT with read rights only (NFR-06); one file per machine, named by the node map's `credential` |
| `mqtt_readonly` | `gateway-mqtt` | read-only broker credentials |
| `smtp_url`, `discord_webhook` | `api`, `scheduler` | notifications |

Login roles: `CREATE ROLE … LOGIN PASSWORD …` for `app_rw`, `app_ro`, `agent_ro`, `gateway_rw`, `vision_rw`, `kb_rw`; grants in `db/schema.sql`; passwords `SET_AT_BOOTSTRAP` from the files above. Verify: `psql -U gateway_rw -c "DELETE FROM quality.shot"` must fail.

### 4.3 Models
| Model | Use | Rule |
|---|---|---|
| Family detection model (shared backbone + per-family heads) | vision | released only when `vision_eval_run.passed` (mAP ≥ 0.80; recall ≥ 0.95 on short shot, flash, contamination — AI-02); registered in `vision.model_registry` |
| Anomaly model | out-of-distribution appearance (FR-10) | threshold in `moldmind.yaml` |
| `qwen2.5:7b-instruct-q4_K_M` | dialogue and explanation only (AI-06) | ≤ 9 B, temperature ≤ 0.3; changing it → golden run (RB-08) |

### 4.4 Configuration files
`moldmind.yaml` (schema-validated; the constants cannot be switched off), `machines/*.opcua.yaml` (node maps, validated at gateway startup), `kb/*.yaml` (knowledge, imported as versions), `prompts/*.md` (versioned, checksummed), `glossary.csv`.

### 4.5 Start, load, verify
```
docker compose --profile gpu up -d
docker compose exec postgres psql -U moldmind -d moldmind -f /db/seed_demo.sql   # dev/staging only — expected \echo block in DDS-11 §9
mmctl selftest      # twins vs engine on the seed, KB/node-map/facts schemas, config, node-map resolution, WRITE-REFUSAL test on every connection, camera trigger, Ollama ping
curl -s $PUBLIC_URL/api/v1/readyz    # {"ready":true,"mode":"full","machines":{"M-3":"connected"},"vision":"ok"} — "scripted" when the model is down
```

### 4.6 Reverse proxy
TLS termination; `BIND_ADDR=127.0.0.1`; `/api/v1/metrics` from the Prometheus host only; body limit 16 MB (part images via signed URLs, not the API); timeouts: `/rca/sessions*` 30 s, `/cavity-analysis` 10 s.

## 5. Machine onboarding (IF-05)
1. OT creates a **read-only** OPC-UA user on the press and trusts the gateway's client certificate; `SignAndEncrypt` only.
2. Write the node map (`deploy/machines/<machine>.opcua.yaml`): every FR-01 parameter, the shot counter as trigger, the setpoint nodes and the controller-user node; `mmctl nodemap validate` (schema) → `POST /machines/connections` + `PUT …/node-map`.
3. `POST /machines/connections/{id}/test`: every node resolves; **`write_refused_by_server = true`** (the test attempts a write with the read-only account and expects `BadUserAccessDenied`); lag ≤ 2 s. Do not start production ingest until this passes (TEST-11 TC-013).
4. Firmware change → new node-map version (checksum); an unresolvable node is a startup error, never a silent null.
5. Euromap 63 / MQTT alternatives: same shot contract; the `mqtt` profile; still read-only.

## 6. Mould onboarding
1. `POST /moulds` (code, cavities, material spec).
2. Setup sheet (`POST /moulds/{id}/setup-sheets`): every parameter with target and tolerance; approved by a second engineer; becomes the golden run (FR-18).
3. Process windows (`PUT /moulds/{id}/windows`): one row per material grade × parameter with `lo`, `hi`, unit and **source** (mould datasheet, material datasheet, process validation) — without a window every suggestion for that parameter is blocked (C-05).
4. Colour reference (`POST /colour-references`): Lab from the reference chart under the station's lighting; threshold (default 2.0 ΔE76).
5. Scrap cost (`scrap_cost_config`) per SKU.
6. Cavity attribution: part marking OCR patterns, robot pose → cavity table, or the fixed ejection sequence; run the 500-part trial (AC-02) before trusting cavity analysis.

## 7. Camera station and lighting
Trigger from the robot's part-present or the ejection signal; one frame per part (or per cavity group with a fixed pose); lighting recipe per defect class — sink marks and weld lines **require** low-angle/deflectometry lighting (AI-03; the config refuses otherwise); the reference chart stays in frame (AI-04); frozen-frame detection and enclosure temperature alarms on (RB-03). Any camera/lens/lighting change → re-calibration and re-validation (ICD-00 IF-02).

## 8. Knowledge base, scoring, prompts, golden set
| Task | Command | Rule |
|---|---|---|
| Author / update knowledge | edit `kb/*.yaml` in git → `mmctl kb import … --version <v>` | schema-validated; every cause has a source; checks before actions; draft |
| Approve | `POST /knowledge/versions/{id}/approve` | process engineer ≠ author, role ≥ engineer; approved = immutable; golden run first |
| Change scoring weights | `PUT /scoring-config` | sum 1; inactive until a golden run ≥ 70 % |
| Change prompts / model | edit → `mmctl prompts register` → `mmctl golden run` | ≥ 70 % top-3 on ≥ 15 incidents or not deployed (RB-08) |
| Stale knowledge | weekly `mm_kb_stale_causes` (no evidence in 365 d) | review, re-source or retire |
| Evidence | `GET /knowledge/evidence` | verified outcomes only; never edit |

## 9. Observability
| Signal | Where | Alert |
|---|---|---|
| `mm_shot_lag_seconds` | `/metrics` | > 2 (NFR-01) |
| `mm_gateway_buffer_depth` | | > 0 for > 10 min (connection lost — RB-05) |
| `mm_machine_write_refused_total` | | **any → RB-11** (something tried to write) |
| `mm_alignment_misses_total` rate | | > 1 % of parts (RB-06) |
| `mm_cavity_method_total{method="sequence"}` share | | > 50 % — OCR/robot attribution failing |
| `mm_inference_seconds` p95 | | > 0.15 (NFR-02) |
| `mm_review_rate` | | > 10 % of parts |
| `mm_cavity_flags_total`, `mm_drift_alerts_total` | | informational; feed notifications |
| `mm_transient_shots_total` | | informational |
| `mm_suggestions_total{verdict="blocked"}` | | > 30 % of suggestions in a week — windows or KB ranges need review (RB-07) |
| `mm_outcomes_total{outcome}` | | not_effective rising — KB review |
| `mm_rca_turn_seconds` p95 | | > 15 (NFR-04) |
| `mm_kb_stale_causes` | | > 0 (weekly) |
| `mm_eval_vision_passed`, `mm_eval_golden_passed` | | = 0 → do not deploy |
| `mm_llm_available` | | 0 for > 5 min (scripted mode — RB-09) |
| DB: `v_gateway_lag`, `v_data_quality`, `v_cavity_rates`, `v_drift`, `v_suggestion_audit`, `v_effectiveness`, `v_kb_status` | psql | |

Logs: JSON to stdout; `audit.log` holds blocked suggestions, approvals, connection/node-map changes, purges.

## 10. Retention, backup, restore; TimescaleDB
- Shots 2 y (monthly partitions created by `PARTITION_CRON`, or TimescaleDB chunks), defect images 2 y, PASS images 90 d (bucket lifecycle), knowledge and sessions 10 y, evaluation artefacts 5 y (object lock).
- **TimescaleDB (optional, SAD-00 ADR-007)**: `CREATE EXTENSION timescaledb; SELECT create_hypertable('quality.shot', 'ts', migrate_data => true);` — the schema works unchanged on plain PostgreSQL.
- Backups: nightly `pg_dump` + WAL; MinIO `parts` (defect prefix), `colour`, `eval` mirrored; `${CONFIG_DIR}` (node maps, KB, prompts) in git.
- Restore drill quarterly: restore; `mmctl selftest`; reconstruct one session end-to-end (`v_cause_ranking`, `v_suggestion_audit`, `v_effectiveness`).

## 11. Upgrades and platform mode
- Upgrade: changelog → golden run and vision evaluation on the new images → promote; `moldmind_000N` migrations idempotent; changes to `quality.mould/shot/shot_part/timeline_event` are platform changes.
- Platform mode: drop `postgres`, `redis`, `minio`, `ollama`, `web`; point the DB secrets at the platform database; apply `moldmind_0001`; machine data through the platform's IF-05 ingest with MoldMind's node maps; inspections through the platform's vision pipeline with MoldMind's family heads; the gateway serves the five platform paths; QE-Agent for the 8D; Genba Memory for past cases.

## 12. Verification commands and runbooks
### 12.1 Verification commands (TEST-11 TS-0 on the authoring machine; TC-009 on a host with Docker)
```
python check_openapi.py api/openapi.yaml       # TC-008: valid, 56/73/57, 0 orphans
python check_api_identity11.py                 # TC-008: 23/23 platform blocks verbatim
python assemble11.py                           # regenerates db/schema.sql from the platform file + mm_body.sql
python check_schema11.py                       # TC-002/TC-003: 111/111 identical, 4 sections verbatim, counts, guards, grants
python check_seed11.py                         # TC-005: twins vs Python on the seed (all values equal)
python check_contracts11.py                    # TC-006: KB 3/3 valid + 12/12 negatives; node map + 8/8; RCA facts + 8/8
python check_config11.py                       # TC-007: moldmind.example.yaml valid, 36/36 negatives, prompts/glossary/seed consistent
python check_deploy11.py                       # TC-004: 20 services, 51 env vars both ways, 17 secrets, network placement
docker compose --profile cpu up -d postgres && psql -f db/schema.sql && psql -f db/seed_demo.sql   # TC-009 (not run here)
```

### 12.2 Runbooks
| ID | Situation | Steps |
|---|---|---|
| RB-01 | **Install / first press** | §4.1–4.5; §5 with the write-refusal test; §6; §7; attribution trial; golden run |
| RB-02 | **Onboard another machine / firmware change** | new node map version; validate; connection test incl. `write_refused_by_server`; only then enable |
| RB-03 | **Camera or lighting problem** (review rate up, frozen frames, enclosure temperature) | stop trusting new defects (flag the window); clean/replace; re-calibrate; re-validate the family model on the hold-out set |
| RB-04 | **Cavity flagged** | open the cavity view: rate vs others, defects by class, images; check attribution method mix first (a `sequence`-only window is suspect); then mould maintenance |
| RB-05 | **Gateway buffering / connection lost** | `v_gateway_lag`; check the machine network and the OPC-UA session; on reconnect the batch reconciles automatically — verify `inserted + duplicates = buffered`; > 20 h → extend disk or fix before the buffer fills |
| RB-06 | **Alignment misses rising** | check trigger timestamps vs shot timestamps (clock skew flags); tolerance stays ≤ 1.5 s — fix the clocks, do not widen the tolerance |
| RB-07 | **Suggestion blocked** | that is the system working; read the window and its source; if the window is genuinely wrong, a process engineer updates it with a new source and approver — never "allow once" |
| RB-08 | **KB / scoring / prompt / model change** | new version → golden run → ≥ 70 % → approve/activate; below → revert; keep retired versions |
| RB-09 | **Model down** | sessions continue in `scripted` mode (KB questions verbatim); ranking/advice/windows unaffected; restart Ollama |
| RB-10 | **Effectiveness not confirmed** | outcome `not_effective`/`inconclusive`; do not close as verified; continue with the next check; a wrong "effective" cannot be typed |
| RB-11 | **Write attempt refused by the press** | stop the gateway; rotate the machine account and certificate; verify the node map checksum; treat as a compromise of the gateway host (SEC-11 §7) |
| RB-12 | **8D handoff failing** | `QE_UNAVAILABLE`; the scheduler retries every 15 min; check `QE_URL` and the token; the session data is intact |
| RB-13 | **Restore** | restore `pg_dump` + WAL and the buckets; `mmctl selftest`; write-refusal test; reconstruct one session |
| RB-14 | **Platform migration** | §11; apply `moldmind_0001`; re-point secrets; identity TC-002 on the platform schema; TC-093 |

## 13. Traceability
| SRS-11 | OPS |
|---|---|
| FR-01…FR-05, C-01, NFR-01, NFR-05, NFR-06, AC-09 | §5, RB-02, RB-05, RB-11 |
| FR-06…FR-11, AI-01…AI-04, NFR-02, NFR-07, AC-01, AC-02 | §4.3, §7, RB-03, RB-06 |
| FR-12…FR-18, AC-06 | §6, §9, RB-04 |
| FR-19, FR-25, C-03, AI-08, NFR-08, AI-07, AC-04 | §8, RB-08 |
| FR-20…FR-24, C-04, C-05, AI-05, AI-06, AI-09, AC-05, AC-07 | §9, RB-07, RB-09, RB-10 |
| FR-26 | RB-12 |
| NFR-03, NFR-04 | §9 |
| §2.3 TimescaleDB | §10 |
