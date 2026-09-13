# Deployment & Operations Guide — OpsPilot Local AI Operations Agent

| Field | Value |
|---|---|
| Document ID | OPS-04-OpsPilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) (agent stack) · [`deploy/target-proxy.compose.yml`](../deploy/target-proxy.compose.yml) (per target host) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/policy.yaml.example`](../deploy/policy.yaml.example) · [`deploy/runbooks/`](../deploy/runbooks/) · [`deploy/schemas/`](../deploy/schemas/) |
| Related | [SAD-04](SAD-OpsPilot-Software-Architecture.md) · [ICD-04](ICD-OpsPilot-Interface-Control.md) · [SEC-04](SEC-OpsPilot-Security-Requirements.md) · [TEST-04](TEST-OpsPilot-Test-Plan.md) · [UM-04](UM-OpsPilot-User-Admin-Guide.md) |
| Audience | Owner (installs, onboards targets, manages policy), on-call operators/admins (runbooks) |

---

## 1. What you are operating

A small stack on one host that **watches other hosts and, with approval, restarts things on them**. Two facts shape every procedure here:

- **The dangerous part is onboarding a target**, not installing the agent. Installing the stack gives the agent no power at all; each target you onboard (§5) grants it exactly the proxy endpoints, probe role and keys you configure. Do it slowly, one host at a time, and verify the proxy matrix (TC-080) before the first `/ask`.
- **The agent must never become a dependency.** Targets do not know it exists. If OpsPilot is down, nothing else changes (NFR-07). Treat it accordingly: no target health check calls it, no deploy pipeline waits for it.

## 2. Topology and sizing

| Layout | When | Note |
|---|---|---|
| **Agent host separate from targets** (recommended) | Any team with ≥ 2 servers | Blast radius of an agent-host compromise = target allowlists only |
| Agent on one of the targets | Single-VPS teams | The proxy still separates the socket; host compromise is shared (SEC-04 §8) |

Sizing (NFR-02): stack ≤ 2 GB RAM excluding Ollama; Postgres small (audit ≈ 1 GB/year at 500 runs/day). Ollama: 8 GB GPU for the 7 B Q4_K_M reference model; CPU-only hosts run a ≤ 4 B model (`OLLAMA_MODEL=qwen2.5:3b-instruct-q4_K_M`, `GPU_COUNT=0`) with slower but still bounded runs — deterministic diagnostics do not need the model at all.

Network: agent host on the internal LAN; `BIND_ADDR` = its internal interface; firewall **inbound** allows only the console/API ports from the admin VLAN and SSH from the admin VLAN; **outbound** allows target tunnels, Discord (`gateway.discord.gg`, `discord.com`), NTP, alert sinks, and the registry at install time. Nothing else (SEC-O62).

## 3. Prerequisites
Ubuntu 22.04/24.04, Docker 26+ with Compose v2, NVIDIA container toolkit when a GPU is present, WireGuard (or SSH) for target tunnels, a Discord application with a bot in the team's server, an internal CA or reverse proxy for TLS on the console (recommended).

## 4. Installing the agent stack

### 4.1 Steps
```bash
sudo mkdir -p /etc/opspilot/{secrets,secrets/targets,runbooks} && sudo chmod 700 /etc/opspilot/secrets
git clone <repo> && cd 04-local-ai-ops-agent/deploy
cp .env.example .env && chmod 600 .env          # edit: BIND_ADDR, registry, model, Discord ids
cp policy.yaml.example /etc/opspilot/policy.yaml
cp runbooks/*.yaml /etc/opspilot/runbooks/
```

### 4.2 Secrets (files, 0400, owner `root:10001`)
| File | Content | Used by |
|---|---|---|
| `database_url` | `postgresql://opspilot_app:<pw>@postgres:5432/opspilot` | api, agent, scheduler |
| `postgres_password` | the `opspilot_app` password (also set in `schema.sql` roles at bootstrap) | postgres |
| `jwt_secret` | 48 random bytes | api |
| `discord_bot_token` | from the Discord developer portal | discord-bot |
| `discord_service_token` | random; the bot's credential to the API | api, discord-bot |
| `smtp_url`, `alert_webhook_hmac` | optional | scheduler |
| `targets/<code>.dsn`, `targets/<code>.key`, `targets/deploy.key` | per-target probe DSNs, tunnel/SSH keys, read-only deploy key | agent |

Generate with `openssl rand -base64 48`. Never put any of these in `.env`, `targets.yaml`, `policy.yaml` or a runbook (TC-007 scans the examples; SEC-O50).

### 4.3 Model
```bash
docker compose up -d ollama && docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M
```
Ollama has no egress after this; pin the model tag (and record its digest in the change log) so `OLLAMA_MODEL` is reproducible (AI-07).

### 4.4 Start and bootstrap
```bash
docker compose up -d                                   # schema.sql applies on first postgres start
docker compose exec postgres psql -U opspilot_app -d opspilot -c "ALTER ROLE opspilot_app PASSWORD '<pw>'"
opsctl user create suphot --role owner --discord 100000000000000001    # first owner; then map the others
opsctl policy load /etc/opspilot/policy.yaml           # PUT /policies — validated, atomic, audited
opsctl runbook load /etc/opspilot/runbooks/            # validated against runbook.schema.json
curl -s http://$BIND_ADDR:8080/api/v1/readyz           # db/redis/worker true; llm true (or false on CPU while warming)
```
Optional demo data: `psql … -f ../db/seed_demo.sql` on a **non-production** database only (it creates users with placeholder hashes).

### 4.5 Discord
Invite the bot with `applications.commands` and `bot` scopes (send messages, embed links, read message history) into the configured guild; restrict it to `DISCORD_CHANNEL_IDS`. Map every user who may approve with `opsctl user link <username> <discord_user_id>` — unmapped users are viewers (SEC-O20).

## 5. Onboarding a target — the procedure that decides whether this is safe

Do this per host, in this order, and do not skip step 6.

| # | Step | Where | Notes |
|---|---|---|---|
| 1 | Add the target to `/etc/opspilot/targets.yaml` (code, kind, env, tags) — **tags first**: `critical` for anything stateful you would not restart casually; `ot`/`plc` for anything that touches production equipment (which then gets **no** write tool) | agent host | `opsctl target add vps-1 --kind docker_host --env prod` |
| 2 | Deploy the socket proxy **on the target** with [`target-proxy.compose.yml`](../deploy/target-proxy.compose.yml); set `OPSPILOT_PROXY_IMAGES=0` unless pruning is enabled in policy; it listens on `127.0.0.1:2375` only | target host | Never `EXEC=1`, never `VOLUMES=1` (SEC-O31) |
| 3 | Tunnel: WireGuard peer or SSH tunnel from the agent host to `127.0.0.1:2375` on the target; the target's `endpoint` is the tunnel-local URL | both | Plaintext on the LAN is not acceptable |
| 4 | For non-container hosts: create the `opspilot` SSH user with the forced command from ICD-04 IF-26; install the `logrotate-force.service` unit if `rotate_logs` is wanted | target host | `no-pty,no-port-forwarding,…` |
| 5 | For databases: create `opspilot_probe` (ICD-04 IF-27); store the DSN as `secrets/targets/<code>.dsn` | target DB | `pg_monitor` only; 5 s timeout |
| 6 | **Run the proxy matrix** `opsctl target verify vps-1` (= TEST-04 TC-080/082/083): every never-endpoint must return 403; the probe role must fail to read a table | agent host | The onboarding is not complete until this passes |
| 7 | First read: `/diag vps-1` in Discord — a deterministic report; check that hostnames and secrets are not visible (redaction) | Discord | |
| 8 | Deploy repo (optional): read-only deploy key; confirm `deploy/<service>/<ts>` tags with `.deploy-status` exist before enabling `redeploy_last_good` in policy | agent host | ICD-04 IF-28 |
| 9 | Policy: confirm which actions are `allow: true` for this target (`targets_allow`), who approves, and the rate limits; `opsctl policy load` | agent host | |
| 10 | Record the onboarding in the change log (host, flags, tags, who verified) | — | Audit row `target.onboarded` |

## 6. Day-to-day operation

### 6.1 Observability of the agent itself
| Signal | Where | Meaning |
|---|---|---|
| `/readyz` | API | db/redis/worker/llm; `deterministic_only: true` when the LLM is down (not an outage) |
| Metrics | `:8080/metrics` (LAN) | runs by outcome, tool latency, denials by reason, proposals pending/expired, `redaction_count`, LLM breaker state, queue depth |
| Alerts about the agent | scheduler → Discord/IF-13 | `agent:LLM_UNAVAILABLE`, `agent:WORKER_DOWN`, `agent:QUEUE_BACKLOG`, `agent:REDACTION_SPIKE`, `agent:PROPOSALS_EXPIRING` |
| Audit | console → Audit; `opsctl audit tail` | every decision |

### 6.2 SLOs
| SLO | Target | Measured by |
|---|---|---|
| Diagnostic answer (5 tools) | ≤ 30 s p95 (NFR-01) | run latency metric |
| Stack memory excl. Ollama | ≤ 2 GB (NFR-02) | cgroup metrics |
| Deterministic availability (`/diag`, runbooks) | ≥ 99.5 % during business hours | `/readyz` without `llm` |
| Unapproved state changes | **0** — an incident if ever non-zero | audit reconciliation job (executed ⊆ approved) daily |

### 6.3 Change freezes
`/freeze prod 24 "release week"` (admin) or the console. During a freeze every write tool answers `CHANGE_FREEZE`; reads and runbook read-steps continue. End early with `DELETE /freezes/{id}`.

### 6.4 Policy changes
Edit `/etc/opspilot/policy.yaml` → `opsctl policy validate` → `opsctl policy load`. Loading is atomic and audited with the version string. Adding an action name that is not in the registry fails; the registry is code.

### 6.5 Model, prompt, registry versions
All three are recorded on every run (AI-07). Changing the model or prompt: bump `OLLAMA_MODEL`/`PROMPT_VERSION` in `.env`, restart `agent`, and **re-run the injection and incident corpora** (TEST-04 TC-095, TC-120) before using it in prod. Registry changes ship with the image (`REGISTRY_VERSION`).

## 7. Backup and retention
- **Audit is the asset.** Nightly `pg_dump` of `ops` + `audit` to encrypted storage; monthly `POST /audit/export` archived with its manifest (FR-32). Restore test quarterly.
- Retention jobs (scheduler): tool-call results nulled after 90 days; run/tool-call metadata and audit kept 2 years; audit older than 2 years is exported before deletion — by the owner, never by the app role (DDS-04 §8).
- Redis holds nothing durable (counters rebuild from `v_restart_rate`, ADR-O08).

## 8. Upgrades
Pull new images by tag → `docker compose up -d` (services restart one by one; the worker finishes the run in flight or marks it `failed` with a partial outcome — TC-116). Schema migrations run forward-only at API start with a pre-migration dump. Read the registry changelog: a new tool is `enabled: false` until the owner enables it and adds a policy entry.

## 9. Runbooks (for the people who run the agent)

| RB | Symptom | Diagnose | Fix |
|---|---|---|---|
| **RB-01** | Approval never arrives / proposal expired | `/proposals?status=pending`; expiry is 10 min by design | Ask again; if approvers are routinely late, review who holds the role, not the timeout (FR-19) |
| **RB-02** | "Refused by policy: DENYLISTED / TOOL_NOT_IN_REGISTRY" | The model asked for something outside the registry — this is the system working | Nothing on targets. If the need is real: new typed tool via code review (C-02) |
| **RB-03** | `RATE_LIMITED` | `v_restart_rate`; the card shows next-allowed time | Do not raise the limit reflexively — a 4th restart in an hour means the cause is elsewhere; run the matching runbook |
| **RB-04** | `CHANGE_FREEZE` on every action | `/freezes` | Wait, or an admin ends the freeze early with a reason |
| **RB-05** | LLM down or slow (`agent:LLM_UNAVAILABLE`, `/readyz.llm=false`) | `docker compose logs ollama`; GPU memory; model loaded? | Deterministic mode keeps `/diag`, runbooks, alerts working (NFR-06). Restart `ollama`; on CPU hosts switch to a ≤ 4 B model |
| **RB-06** | `VERIFICATION_FAILED` — the action ran but the after-state is not healthy | Proposal `before`/`after`; run `/diag` again | The agent never says "done" here; investigate the real cause; propose the next action; consider `redeploy_last_good` |
| **RB-07** | Redaction miss reported (a secret visible in a card or the console) | `tool_call.redacted_result_json` for the run; which family missed | **Rotate the secret first**; add the pattern (`ops.redaction_pattern`); purge affected result rows (allowed — results, not audit); add to the corpus (SEC-04 §7) |
| **RB-08** | Tool errors `403` from a proxy | `opsctl target verify <code>`; proxy env on the target | A flag was narrowed (good) or the tool needs an endpoint not granted — decide in policy, never by widening blindly (SEC-O31) |
| **RB-09** | `db_health` timeout | probe role `statement_timeout` (5 s) hit → the DB *is* slow — that is the finding | Run `db-slow` runbook; do not lengthen the timeout |
| **RB-10** | Discord bot offline | `docker compose logs discord-bot`; token valid; gateway reachable | Restart bot; approvals also work in the console meanwhile |
| **RB-11** | Runbook stopped mid-way (`failed`, `steps_done = n`) | `runbook_run.last_step`; the failing tool call | Fix the cause; re-run — completed write steps are visible in `action_proposal`; nothing is silently repeated |
| **RB-12** | Audit export requested (auditor, incident review) | `POST /audit/export` for the window | Deliver NDJSON + manifest; the incident timeline is reconstructable from it alone (AC-07) |
| **RB-13** | Rotating the agent's credentials | Which: tunnel keys, probe DSNs, deploy key, bot token, JWT secret | Replace the secret file; restart the one service that mounts it; old credential revoked on the target; audit row `secret.rotated` |
| **RB-14** | Agent host lost | Latest `pg_dump`; secrets backup (offline) | Reinstall §4 on a new host; restore DB; re-establish tunnels; run `opsctl target verify` for every target before enabling any write policy; targets were unaffected throughout (NFR-07) |

## 10. Decommissioning a target
`opsctl target disable <code>` → remove the proxy compose and tunnel on the target → drop `opspilot_probe` → delete `secrets/targets/<code>.*` → audit row `target.retired`. Runs and proposals referencing the target stay (SET NULL on the FK).

## 11. Traceability
| SRS-04 | Section |
|---|---|
| C-04, NFR-03, NFR-04 | §5 (proxy, forced command, probe role), §4.2 |
| C-06 | §2 network, §4.3 |
| FR-21 | §6.3, RB-03, RB-04 |
| FR-25, FR-26 | §6.1 |
| FR-32 | §7, RB-12 |
| AI-01 | §2, §4.3 |
| AI-06, AI-07 | §6.5 |
| NFR-01, NFR-02 | §6.2 |
| NFR-05 | §4.2, RB-07 |
| NFR-06 | RB-05 |
| NFR-07 | §1, RB-14 |
| AC-07 | RB-12 |
