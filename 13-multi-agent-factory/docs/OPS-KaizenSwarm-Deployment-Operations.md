# Deployment and Operations Guide — KaizenSwarm (Multi-Agent Factory System)

| Field | Value |
|---|---|
| Document ID | OPS-13-KaizenSwarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-21 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SAD-13](SAD-KaizenSwarm-Software-Architecture.md) · [DDS-13](DDS-KaizenSwarm-Database-Design.md) · [ICD-13](ICD-KaizenSwarm-Interface-Control.md) · [SEC-13](SEC-KaizenSwarm-Security-Requirements.md) · [TEST-13](TEST-KaizenSwarm-Test-Plan.md) |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`.env.example`](../deploy/.env.example) · [`kaizenswarm.example.yaml`](../deploy/kaizenswarm.example.yaml) · [`agents.example.yaml`](../deploy/agents.example.yaml) · [`nats/nats.conf`](../deploy/nats/nats.conf) · [`scenarios/suite.example.yaml`](../deploy/scenarios/suite.example.yaml) · [`prompts/`](../deploy/prompts/) |
| Parent | [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) — platform mode inherits the platform's operations |

---

## 1. Topology

| Mode | What runs where |
|---|---|
| **Platform mode** (intended) | `orchestrator`, `agent-runner` (×N), `api` (mounted under `/swarm/`), `web` pages embedded in the platform dashboard, `scheduler` jobs registered in the platform scheduler; the platform's PostgreSQL (migration `swarm_0001`), NATS, Redis, Ollama (with the platform GPU semaphore), notifier (Discord). Sibling tools through the registry (IF-16). |
| **Standalone** | `deploy/docker-compose.yml`: web, api, orchestrator, agent-runner, scheduler, nats (JetStream), postgres (pgvector image), redis, ollama (gpu) / ollama-cpu (cpu), discord-bot (profile `discord`), mailpit + sibling-stub (profile `dev`) — 13 services. Sibling tools over HTTPS on the `sources` network with read-only tokens. |

Hardware baseline (SRS §2.3): one host with an 8 GB GPU, 16 GB RAM, 4 vCPU, 100 GB SSD. A 4-agent run needs ≈ 80 s of GPU time (four phrasing calls) inside the 3-minute wall; two shift runs a day.

Networks: `frontend` (reverse proxy → web/api) · `internal` (no route out: db, bus, cache, model, orchestrator, runner, scheduler) · `sources` (agent-runner → sibling APIs / ERP adapter) · `egress` (discord-bot only). `BIND_ADDR=127.0.0.1`; TLS at the reverse proxy.

## 2. Install (standalone)

```bash
git clone … && cd 13-multi-agent-factory/deploy
cp .env.example .env && chmod 600 .env                      # runtime knobs only
sudo mkdir -p /etc/kaizenswarm/{secrets,schemas,scenarios,prompts,nats}
sudo cp kaizenswarm.example.yaml /etc/kaizenswarm/kaizenswarm.yaml
sudo cp agents.example.yaml /etc/kaizenswarm/agents.yaml
sudo cp -r schemas scenarios prompts nats /etc/kaizenswarm/
# secrets — one FILE each, 0400 root:10001 (§4); never in .env
docker compose --profile cpu --profile dev config -q          # parses; ${VAR} both ways (TC-004)
docker compose --profile gpu --profile discord up -d
docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M
psql "$DATABASE_URL" -f ../db/seed_demo.sql                   # demo only — never on a plant database
curl -s https://kaizenswarm.plant.local/api/v1/readyz
```

Platform mode: `psql "$PLATFORM_DB" -f db/schema.sql` **sections 10–19 only** (`swarm_0001`); register the streams in the platform NATS with `nats/nats.conf`'s account fragment; add the module's compose overlay; point the platform gateway at `/swarm/`.

## 3. Registry, tools and siblings (first run)

1. `POST /agents/import` with `agents.yaml` — four specialists enabled, `manager`, `logistics` disabled.
2. Sibling tokens (§4): read-only accounts on QE-Agent (`get_signals`, `get_spc`, `get_case`), MachineSense (`get_machine_health`, `get_alert_evidence`, `get_trend`, `get_pm_overdue`), ShiftBrief (`query_production`, `query_defects`, `get_oee`, `get_downtime_pareto`, `get_schedule_risk`), the ERP read adapter (`get_stock_coverage`, `get_inbound_deliveries`, `get_lot_quality_history`, `get_shortage_risk`), the platform (`get_machine_telemetry`). Verify each with `GET /agents/{name}/tools` and a write attempt that must fail (TC-111).
3. `POST /scenarios/import` with the suite; `POST /scenarios/run` → `passed: true` (14/15 with the example suite).
4. `POST /runs {scope: {plant: 1}}` on-demand; read the trace; then enable the shift-start cron.

## 4. Secrets (files under `${SECRETS_DIR}`, 0400 root:10001)

| File | Used by | Purpose |
|---|---|---|
| `database_url` | api | `app_rw` |
| `orchestrator_database_url` | orchestrator | `orchestrator_rw` — the one writer |
| `postgres_password` | postgres | |
| `jwt_secret` | api | |
| `nats_api_creds`, `nats_orchestrator_creds`, `nats_agent_<name>` | api, orchestrator, agent-runner | one NATS account per party (SEC-K12) |
| `lease_token` | orchestrator, agent-runner | header required by the Ollama gateway (SEC-K16) |
| `qe_agent_token`, `machinesense_token`, `shiftbrief_token`, `erp_adapter_token`, `platform_token` | agent-runner only | **read-only** (NFR-06, SEC-K09) |
| `scheduler_token` | scheduler | API token for cron jobs |
| `s3_access_key`, `s3_secret_key` | api | exports bucket |
| `discord_token`, `discord_channel_id`, `bot_api_token` | discord-bot only | IF-08 |

Rotation: sibling tokens and NATS credentials quarterly; `lease_token` and `jwt_secret` on incident (RB-10, RB-11). No secret value exists in any repository file (TC-004).

## 5. The bus (NATS JetStream)

Streams: `AGENT_REQUEST` (`agent.request.>`, 24 h), `AGENT_FINDING` (`agent.finding.>`, 7 d), `AGENT_STATUS` (`agent.status.>`, 7 d), `ORCH_RUN` (`orchestrator.run.>`, 7 d); durable consumer per agent, explicit ack, `max_deliver 3`, ack wait 10 s; `max_payload 64 KiB`. Accounts per `nats/nats.conf`. Health: `GET :8222/healthz`, `nats stream ls`, consumer lag (`nats consumer info AGENT_REQUEST quality`). A pending count that grows while a runner is up means the runner's account cannot subscribe (RB-05).

## 6. Configuration (`kaizenswarm.yaml`)

Validated against `schemas/kaizenswarm-config.schema.json` at start; 45 negatives rejected in TC-007. What you may tune and what you may not:

| Section | Tunable | Pinned (schema / DB CHECK) |
|---|---|---|
| orchestrator | run wall ≤ 180 s, agent timeout, default budget, backoff, circuit, schedule | `max_attempts = 2`, `partial_on_failure = true` |
| llm | model, lease TTL, prompt versions, output tokens | `≤ 9 B`, `temperature ≤ 0.3`, `semaphore_slots = 1` |
| tools | timeouts, providers (https only, credential **refs**) | `read_only = true` |
| blackboard | freshness threshold, expiry runs, snooze max, issue families | |
| scoring / relation_rules | the tables, top-N, rules | `compound = noisy_or`; activation gated by the suite |
| briefing | phrasing retries (0–1) | `claim_check = true`, `template_fallback = true` |
| delivery | Discord languages, webhook allow-list (https), email | `dashboard = true` |
| scenarios | suite file, gate ≥ 0.80 | `fabricated_max = 0`, `min_scenarios ≥ 15`, `run_before_activation = true` |
| audit | bucket | `retention_days ≥ 365` |

The example file's values equal the seed's `swarm.setting`, `scoring_weights v1` and `relation_rule` rows (TC-007).

## 7. Changing the arithmetic, the rules, the prompts, the agents (ADR-K10)

1. Publish, don't overwrite: `POST /scoring-weights` (new version, inactive) / `POST /relation-rules` (disabled) / a new prompt file `*.v2.md` / a registry entry `enabled: false`.
2. `POST /scenarios/run {mode: deterministic}` — must pass; nightly CI runs `full` with the model.
3. Activate / enable. Every step is audited (`registry_change`, `audit.log`).
4. Watch `v_agent_precision` and `swarm_claim_check_unmatched_total` for a week; roll back by activating the previous version.

**Adding an agent** (IF-68): module in the `kaizenswarm.agents` package (new runner image) → registry entry → ≥ 1 scenario for the domain → suite passes → enable. Eight agents: `RUNNER_REPLICAS=2` (TC-088).

## 8. Routine operations

| When | What | Where |
|---|---|---|
| Shift start (06:00, 14:00) | the run; Discord and dashboard briefing within 3 min | `v_run_board`, `/briefing` |
| During the shift | shift leader acknowledges / assigns / snoozes / dismisses (with reasons) | UM-13 A.3 |
| Daily 22:00 | `rollup_agent_metrics`, expiry check, retention job | scheduler |
| Weekly | precision per agent (`v_agent_precision`); agents below 0.5 for two weeks → review or disable (RB-09) | admin |
| Monthly | rotate nothing; review the issue-code vocabulary and the compound dismissals `not_related` (SAD-13 §6) | QE lead |
| Quarterly | scenario suite review; token rotation | ML owner, IT |

## 9. Monitoring and alerts (IF-14)

| Signal | Alert when |
|---|---|
| `swarm_run_wall_ms` p95 | > 150 s (NFR-01 headroom) |
| `swarm_assessment_outcome_total{outcome=timeout|failed|invalid_output|circuit_open}` | > 1 per day per agent |
| `swarm_budget_exceeded_total` | any — a module is looping (RB-06) |
| `swarm_lease_wait_ms` p95 | > 60 s — GPU contention or a stuck lease (RB-07) |
| `swarm_claim_check_unmatched_total`, `template_fallback` | any — phrasing regression (RB-08) |
| `swarm_briefing_partial_total` | > 20 % of runs |
| NATS consumer pending | > 0 for > 60 s |
| `v_agent_precision.precision_rate` | < 0.5 (RB-09) |
| Discord delivery `failed` | any (RB-11) |

## 10. Audit, backup, retention

- Everything auditable is a row: messages (immutable), occurrences, actions, attempts, leases, registry changes, `audit.log`. `GET /runs/{id}/export` reconstructs a run; `swarm.export.sha256` is the hash over the message log — recompute it offline: `awk -F'|' '{print $1"|"$2"|"$3"|"$4}' messages.txt | sha256sum`.
- Backups: nightly `pg_dump` of the database (findings, runs, messages) + the JetStream store; restore drill quarterly (RTO 4 h as OPS-00).
- Retention ≥ 365 d (CHECK); the retention job deletes only rows older than that and never messages of a run younger than that.

## 11. Runbooks

| ID | Situation | Steps |
|---|---|---|
| RB-01 | Briefing missing at shift start | `v_run_board` for the run; if no run → scheduler token / cron; if `running` past 3 min → RB-07; if `partial` → read `partial_reason`, the assessments' `error`, then the agent-specific runbook |
| RB-02 | An agent times out every run | its tools: `GET /agents/{name}/tools` and the sibling's health; tool timeouts in the trace; the sibling stub in dev to isolate; circuit state |
| RB-03 | A sibling API is down | assessments `failed` → partial briefings (by design); no action in KaizenSwarm; inform the sibling owner; the blackboard keeps existing findings |
| RB-04 | Database down | api/orchestrator not ready (`/readyz 503`); scheduled runs skipped and logged; restore; rerun `POST /runs` |
| RB-05 | NATS consumer pending grows | account permissions (`nats.conf`), the runner's credential file, `nats consumer info`; restart the runner; requests older than 24 h expire from the stream |
| RB-06 | Budget stops every run | a module that loops (`swarm_budget_exceeded_total`); inspect the tool calls in the trace; fix the module; raise the budget only with the suite passing |
| RB-07 | GPU lease stuck / run at the wall clock | `swarm.llm_lease` open rows; the orchestrator revokes at the run wall; check Ollama (`OLLAMA_NUM_PARALLEL=1`); model reload |
| RB-08 | Claim-check failures / template fallback | compare the phrased text and `unmatched`; a prompt or model regression → roll back the prompt version; run the suite in full mode |
| RB-09 | An agent's findings are mostly dismissed | `v_agent_precision`; review the dismiss reasons; `PATCH /agents/{name} {enabled: false}`; fix thresholds in the module; re-enable after the suite |
| RB-10 | `FINDING_AUTHOR` / `DOMAIN_VIOLATION` / `MESSAGE_PARTY` in the log | a forged or mis-routed message: rotate the agent's NATS credential, verify the runner image digest, review `swarm.message` for the run |
| RB-11 | Discord posts wrong or missing | `swarm.delivery` status/error; the bot posts by id only — a foreign text means a compromised token: rotate `discord_token` |
| RB-12 | Weights or rules changed by mistake | `registry_change` / `audit.log`; activate the previous weights version; disable the rule; rerun the suite |
| RB-13 | Upgrade | `docker compose pull`; `swarm.migration` applied by the api at start (additive only); replay the suite; watch RB-08 signals |
| RB-14 | Retire an agent | disable (never delete — history references it); its findings stay; expiry continues by the remaining reporters |

## 12. Verification (this revision)

| Check | Result |
|---|---|
| `docker compose config` semantics (TC-004) | ✅ 13 services; 29/29 `${VAR}` both ways; 23/23 secrets; egress = {discord-bot}; sources = {agent-runner, sibling-stub}; 8 internal-only; runner has no DB/JWT/Discord/S3 secrets and one NATS credential per agent; sibling tokens only on the runner; orchestrator on `orchestrator_rw`; lease token on orchestrator + runner; Ollama single-parallel; hardening on 7 app services; no secret values |
| Config schema (TC-007) | ✅ example valid; 45 negatives rejected; weights, rules and settings equal the seed; prompts' front-matter (≤ 9 B, ≤ 0.3) |
| NATS accounts | ✅ one per agent with own publish/subscribe subjects; `max_payload 65536` |
| PostgreSQL execution (TC-009) | ⚠️ not executed here |

To execute what could not be executed here:
```bash
cd 13-multi-agent-factory
docker run -d --name ks-pg -e POSTGRES_PASSWORD=x -p 5438:5432 pgvector/pgvector:pg16
sleep 8 && psql "postgresql://postgres:x@localhost:5438/postgres" -v ON_ERROR_STOP=1 -f db/schema.sql \
        && psql "postgresql://postgres:x@localhost:5438/postgres" -f db/seed_demo.sql
```
Expected: the `\echo` block matches DDS-13 §9 (runs, scores 0.6800 / 0.4992 / 0.7120 / 0.5184, compound 0.8397, briefings with `unmatched []`, M-07 occurrences 5 through 411, the lot dedupe, run 412/413/414 outcomes, blackboard, precision 0.6667, suite 14/15, trace counts, export sha256 `9153967a…`, totals 11 / 151 / 7 / 20 / 4 / 12 / 179 / 43 / 7) and probes P-01…P-16 each fail with the named guard.
