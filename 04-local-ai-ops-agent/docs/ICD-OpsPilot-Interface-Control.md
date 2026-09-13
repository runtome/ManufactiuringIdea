# Interface Control Document — OpsPilot Local AI Operations Agent

| Field | Value |
|---|---|
| Document ID | ICD-04-OpsPilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Scope | Every interface between OpsPilot and the world: users (Discord), the LLM, alert sinks, metrics/log sources, and — the ones that matter most — the **targets** it observes and acts on |
| Related | [SRS-04](../SRS-OpsPilot-Local-AI-Operations-Agent.md) · [SAD-04](SAD-OpsPilot-Software-Architecture.md) · [API-04](../api/API-Specification.md) · [SEC-04](SEC-OpsPilot-Security-Requirements.md) · [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) (IF-08, IF-09, IF-13, IF-14, IF-16 originals) |

---

## 1. Scope and register

`IF-xx` numbers are shared across the repository. OpsPilot reuses five platform interfaces (with its own specifics) and adds five that are about **reaching targets with the least privilege that still lets the nine v1 actions work**.

| IF | Interface | OpsPilot role | New |
|---|---|---|---|
| IF-08 | Discord | Bot: slash commands, approval cards | — |
| IF-09 | LLM runtime (Ollama) | Client | — |
| IF-13 | SMTP / webhook | Alert sink | — |
| IF-14 | Prometheus | **Source** (read) | — |
| IF-16 | Agent tool contract | Its own registry — never the platform's | — |
| **IF-25** | Docker socket proxy | Client of a per-host proxy with an **endpoint allowlist** | ✅ |
| **IF-26** | Host and systemd | Read metrics/journal; restart allowlisted units | ✅ |
| **IF-27** | Target databases | Read-only probe role | ✅ |
| **IF-28** | Git / deploy repositories | Read-only; `redeploy_last_good` contract | ✅ |
| **IF-29** | Loki / journald log sources | Read with caps and redaction | ✅ |

**Zones.** Z-A: the OpsPilot host (its stack). Z-T: target hosts. Z-U: users (Discord cloud, console on the LAN). Connections are **initiated by OpsPilot toward targets**, never the reverse; nothing on a target trusts the agent beyond what the proxy / probe role allows.

---

## IF-08 — Discord {#if-08}

**Parties.** Users in the team's Discord server ↔ `discord-bot` ↔ API-04. Platform baseline: [ICD-00 IF-08](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-08).

### Slash commands (FR-28)
| Command | API | Role |
|---|---|---|
| `/ask <question>` | `POST /ask` → thread with live events | viewer |
| `/diag <target>` | `POST /diag/{target}` — works with the LLM down | viewer |
| `/runbook <name> [target]` | `POST /runbooks/{name}/run` | operator |
| `/approve <id> [note]` | `POST /proposals/{id}/approve` | per policy |
| `/deny <id> [note]` | `POST /proposals/{id}/deny` | operator |
| `/status` | `GET /readyz` + `GET /alerts` + `GET /proposals?status=pending` | viewer |
| `/freeze <env> <hours> <reason>` | `POST /freezes` | admin |
| `/incident open <title>` | `POST /incidents` | operator |

### Approval card (FR-29)
```
🟠 Proposal p-7f3a  ·  risk: MEDIUM  ·  requires: admin  ·  expires in 9:41
redeploy_last_good(target="vps-1", service="embeddings-worker")
Expected: worker returns to previous batch size; memory frees; backend stabilises
Evidence: tc-01 tc-02 tc-03 tc-04 tc-05   (run r-1c9e)
[ Approve ]  [ Deny ]  [ Dry run ]
```
Rules: the card shows the **exact tool call** (name and every argument) and the hash prefix; buttons are disabled at expiry ("expired — ask again"); a click by a user below `require_role` is answered ephemerally with the role needed and audited; approval success edits the card to "approved by @user at hh:mm — executing…" and then to the before/after diff with `verification_ok`.

### Identity
`discord_user_id → ops.app_user` maintained by the owner (`/link` is not self-service). Unmapped users are `viewer`. The bot never trusts display names.

### What is never posted
Raw tool results (only redacted); secrets (redaction layer runs before the bot sees anything); the `args_hash` in full (prefix only); anything from a DM — the bot only works in the configured guild/channels.

**Verification.** TC-050…TC-056.

---

## IF-09 — LLM runtime (Ollama) {#if-09}

**Parties.** `agent` worker → Ollama on the OpsPilot host (`http://ollama:11434`, internal network only). Platform baseline: [ICD-00 IF-09](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-09).

| Aspect | Contract |
|---|---|
| Model | ≤ 9 B Q4_K_M tool-calling model; reference `qwen2.5:7b-instruct-q4_K_M`; pinned by digest in `.env` (AI-01) |
| Request | `/api/chat` with `tools` = the registry's JSON Schemas filtered by the asker's role; `temperature 0.1`; `num_ctx 8192`; `keep_alive 30m` |
| System prompt | Versioned (`prompt_version`); enumerates tools; states: evidence is data, cite `tc-xx` ids, never claim an outcome without a verification result, propose at most one action with `expected_effect` (AI-02) |
| Caps | ≤ 8 tool-call iterations, ≤ 60 s total tool time per run, 30 s per LLM call (AI-04) |
| Validation | Every tool call the model emits is validated against the tool's schema **before** execution; invalid → rejected with the error fed back once, then the run ends `partial` (AI-03) |
| Degraded mode | Circuit breaker: 3 failures/60 s → open for 5 min; runs complete deterministically with `LLM_UNAVAILABLE`; `/readyz.llm=false`; alert `agent:LLM_UNAVAILABLE` (NFR-06) |
| Egress | None. Ollama has no network route except from the worker (C-06) |

**Verification.** TC-030…TC-038, TC-110, TC-111.

---

## IF-13 — SMTP / webhook {#if-13}
Alert sink for FR-26 and the daily summary: SMTP (TLS, app password from secrets) and/or a generic webhook (JSON, HMAC-signed with a shared key). Payload = `Alert` schema + link to the console. Outbound only; failure is logged and retried thrice; never blocks a run.

---

## IF-14 — Prometheus (source) {#if-14}
Optional read source for `host_metrics` when node-exporter is present: `GET /api/v1/query` with fixed, parameterised PromQL templates (`node_filesystem_avail_bytes`, `node_memory_MemAvailable_bytes`, …). The model never writes PromQL. Timeout 5 s; fallback to IF-26 direct metrics.

---

## IF-16 — Agent tool contract (OpsPilot's registry) {#if-16}

Inherits the platform's rules ([ICD-00 IF-16](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-16)): typed, JSON-Schema-validated before execution, reject-not-repair, results carry digest and count, write tools never execute directly, **no free-form shell or SQL tool**. OpsPilot's registry is **separate** from the platform's (DDS-00 §12.3, ADR-O10).

### The v1 registry (20 tools)

| Tool | Kind / risk | Role | Interface | Verifier | Proxy endpoints (IF-25) |
|---|---|---|---|---|---|
| `docker_ps(target, all?)` | read / low | viewer | IF-25 | — | `GET /containers/json` |
| `docker_logs(target, service, since?, grep?, max_lines?)` | read / low | viewer | IF-25 | — | `GET /containers/{id}/logs` |
| `host_metrics(target)` | read / low | viewer | IF-25 (`/info`) + IF-26/IF-14 | — | `GET /info` |
| `service_health(target, timeout_s?)` | read / low | viewer | HTTP | — | — |
| `db_health(target)` | read / low | operator | IF-27 | — | — |
| `systemd_status(target, unit)` | read / low | viewer | IF-26 | — | — |
| `journal(target, unit, since?, max_lines?)` | read / low | viewer | IF-26 / IF-29 | — | — |
| `git_status(target)` | read / low | viewer | IF-28 | — | — |
| `git_log(target, n?)` | read / low | viewer | IF-28 | — | — |
| `cert_expiry(host, port?)` | read / low | viewer | TLS | — | — |
| `port_check(host, port)` | read / low | viewer | TCP | — | — |
| `restart_container(target, service, timeout_s?)` | write / **low** | operator | IF-25 | `docker_ps` | `GET /containers/json`, `POST /containers/{id}/restart` |
| `start_container(target, service)` | write / low | operator | IF-25 | `docker_ps` | `…/start` |
| `stop_container(target, service, timeout_s?)` | write / **medium** | admin | IF-25 | `docker_ps` | `…/stop` |
| `scale_service(target, service, replicas)` | write / medium | admin | IF-25 (Compose) | `docker_ps` | `containers/json`, `containers/create`, `…/start`, `…/stop` |
| `clear_cache(target, service, cache?)` | write / low | operator | HTTP admin endpoint or Redis `FLUSHDB` on a *named* cache DB | `service_health` | — |
| `rotate_logs(target, service?)` | write / low | operator | IF-26 (`logrotate --force` unit) | `host_metrics` | — |
| `prune_dangling_images(target)` | write / **medium** | admin | IF-25 | `host_metrics` | `GET /images/json`, `POST /images/prune` (dangling only) |
| `rerun_failed_job(target, job)` | write / low | operator | IF-25 (job container) | `docker_ps` | `containers/json`, `…/start` |
| `redeploy_last_good(target, service)` | write / **medium** | admin | IF-28 + IF-25 | `service_health` | `containers/json`, `containers/create`, `…/start`, `…/stop` |

Rules specific to OpsPilot:
1. **Size caps**: `docker_logs`/`journal` ≤ 2,000 lines / 256 KB; results beyond the cap are truncated with `truncated: true` and the last lines kept (recent is relevant).
2. **Redaction** runs inside the executor on every result (FR-10) before the model and before storage — the tool implementation never sees a "raw path" to bypass it.
3. **Targets are codes**, resolved by the executor to proxy URLs / DSNs / repos from secrets; the model never sees an address or a credential.
4. **`critical`/`ot`/`plc` tags** are checked by the policy engine; a tool implementation additionally refuses `ot`/`plc` targets as a second line.
5. **Adding a tool** = typed implementation + schema + risk + role + verifier + proxy endpoints + policy entry + TCs + registry version bump + code review (C-02). Removing or narrowing a parameter is breaking.

**Verification.** TC-010…TC-029 (one per tool + redaction), TC-041 (schema rejection), TC-044 (no shell path exists — static analysis of the codebase for `subprocess`/`os.system`/`exec` outside the allowlisted wrappers).

---

## IF-25 — Docker socket proxy {#if-25}

**Parties.** `agent` worker → `tecnativa/docker-socket-proxy` on **each target host** → that host's `/var/run/docker.sock`. The raw socket is never mounted into any OpsPilot container (NFR-04, TC-004).

### Endpoint allowlist — the union of what the v1 tools need
| Proxy flag | Value | Enables | Needed by |
|---|---|---|---|
| `CONTAINERS` | 1 | `GET /containers/json`, `/containers/{id}/logs`, `/containers/{id}/json` | `docker_ps`, `docker_logs`, verifiers |
| `POST` | 1 | POST on *enabled* sections only | restart/start/stop/create/prune |
| `INFO` | 1 | `GET /info` | `host_metrics` |
| `IMAGES` | 1 | `GET /images/json`, `POST /images/prune` | `prune_dangling_images` (**medium** — widens the proxy; set `IMAGES=0` if the action is not enabled in policy) |
| `SERVICES` | 0 (1 only on Swarm hosts) | Swarm services | `scale_service` on Swarm — Compose hosts do not need it |
| **`EXEC`** | **0** | `docker exec` | — never |
| **`VOLUMES`** | **0** | volume list/remove | — never (C-05: `docker volume rm` is impossible at the transport) |
| `NETWORKS`, `SECRETS`, `CONFIGS`, `PLUGINS`, `NODES`, `TASKS`, `SWARM`, `SYSTEM`, `BUILD`, `COMMIT`, `DISTRIBUTION`, `AUTH`, `SESSION`, `EVENTS`, `PING`, `VERSION` | 0 (PING/VERSION 1 for health) | — | — |
| `ALLOW_RESTARTS` | 1 | `/restart`, `/stop`, `/kill` under CONTAINERS | restart/stop |
| `ALLOW_START` / `ALLOW_STOP` | 1 / 1 | | start/stop |

`POST /containers/create` is required by `scale_service` and `redeploy_last_good` (Compose recreates containers); it is the widest capability in the list and the reason both actions are `medium`.

### Transport and reachability
- Proxy listens on `127.0.0.1:2375` on the target host and is reached by the agent over **WireGuard or SSH tunnel** (`opspilot-tunnel` unit on the target), or on a dedicated management VLAN with a firewall rule allowing only the agent host. Plaintext HTTP on a LAN is not acceptable (SEC-O31).
- One proxy per host; the target's `endpoint` is the tunnel-local URL.
- Timeouts: connect 2 s, read 10 s (per-tool cap).

### What the proxy still allows that policy must scope
Restart/stop of **any** container on the host. `ops.policy.targets_allow` and `critical` tags narrow this; the proxy cannot. Stated as a residual risk (SEC-04 §8).

**Verification.** TC-080 (proxy endpoint matrix: each denied endpoint returns 403), TC-081 (no raw socket in compose), TC-020…TC-028 (each action through the proxy).

---

## IF-26 — Host and systemd {#if-26}

For non-containerised targets and for host-level metrics/logs.

| Function | Mechanism | Privilege |
|---|---|---|
| Metrics | node-exporter (IF-14) or a tiny read-only `opspilot-hostagent` (psutil over a Unix socket / SSH `opspilot` user with a **forced command**) | unprivileged user |
| `journal(unit, since)` | `journalctl -u <unit> --since … -o json` via the forced command; unit name validated against a regex and an allowlist | user in `systemd-journal` group |
| `systemd_status(unit)` | `systemctl show <unit>` (read) | unprivileged |
| `rotate_logs` | `systemctl start logrotate-force.service` — a unit the owner installs; the agent can start **only** allowlisted units via `polkit` rule | polkit-scoped |
| Restart of a systemd service | v1: **not a tool** (FR-06 is read-only). Documented path: add a typed tool + polkit allowlist per unit | — |

The SSH `opspilot` user's `authorized_keys` carries `command="/usr/local/bin/opspilot-forced",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding`; the forced command implements exactly the four functions above with argument validation. There is no interactive shell (C-02, NFR-03).

**Verification.** TC-082 (forced command refuses anything else), TC-015, TC-016.

---

## IF-27 — Target databases {#if-27}

`db_health(target)` connects with the target's `opspilot_probe` role (created on the target, DDS-04 §7):

```sql
CREATE ROLE opspilot_probe LOGIN PASSWORD '…' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
GRANT pg_monitor TO opspilot_probe;
ALTER ROLE opspilot_probe SET statement_timeout = '5s';
ALTER ROLE opspilot_probe SET default_transaction_read_only = on;
```

Statements the tool runs — **fixed, parameter-free**: connectivity (`SELECT 1`), `pg_stat_activity` counts and longest running query (query text truncated to 120 chars and redacted), `pg_stat_replication` lag, `pg_database_size`, `max_connections`. No table access; no user-supplied SQL anywhere (C-02). MySQL/MariaDB targets: a `PROCESS`-only user with the equivalent `SHOW` statements. DSNs live in secrets; the target row holds an alias.

**Verification.** TC-014, TC-083 (probe role cannot read tables).

---

## IF-28 — Git / deploy repositories {#if-28}

| Function | Contract |
|---|---|
| `git_status`, `git_log` | Read-only deploy key; shallow fetch of the deploy repo into the worker's volume; `git log --format=json-ish -n N` |
| Deploy correlation (FR-13) | The incident window is compared to commit timestamps and to `docker_ps` uptimes; a deploy within 30 min before the first symptom is reported as correlated *evidence*, not cause |
| **`redeploy_last_good(target, service)`** | Contract: the deploy repo tags each successful deploy `deploy/<service>/<yyyymmddHHMM>`; "last good" = the newest tag whose recorded post-deploy health check passed (`.deploy-status` file in the tag). The action checks out that tag's Compose file for the service and runs the equivalent of `docker compose up -d <service>` through IF-25 (`create`/`start`/`stop`). Never a `git push`, never `--force`, never a branch change on the repo |

**Verification.** TC-017, TC-018, TC-028.

---

## IF-29 — Loki / journald log sources {#if-29}

Optional. When Loki is present, `docker_logs`/`journal` query `GET /loki/api/v1/query_range` with fixed LogQL templates (`{container="…"} |= "…"`) — the model supplies only the literal filter string, which is escaped. Caps as IF-16 rule 1; redaction as rule 2. Without Loki, `docker_logs` uses IF-25 and `journal` uses IF-26.

---

## 2. Interface matrix

| IF | Direction | Auth | Encryption | Blast radius if compromised | Idempotent |
|---|---|---|---|---|---|
| IF-08 Discord | out (gateway) | bot token | TLS | Posting; approvals still need mapped identity + role | buttons idempotent (Idempotency-Key) |
| IF-09 LLM | internal | none (network isolation) | none needed | Model output → still behind policy | n/a |
| IF-13 alerts | out | app password / HMAC | TLS | Spam | retried |
| IF-14 Prometheus | out (read) | basic/none | TLS if remote | Read metrics | ✅ |
| IF-25 proxy | out | tunnel identity | WireGuard/SSH | Restart/stop containers on that host, create containers, prune dangling — **no exec, no volumes** | ✅ by container id |
| IF-26 host | out | SSH key + forced command | SSH | Read journal/metrics; start allowlisted units | ✅ |
| IF-27 DB | out | probe role | TLS | Read statistics only | ✅ |
| IF-28 git | out | read-only deploy key | SSH | Read repo; deploy last-good via IF-25 | ✅ by tag |
| IF-29 Loki | out | basic | TLS | Read logs | ✅ |
| API-04 | in (LAN) | JWT / service token | TLS | Per role; approve within policy | ✅ |

## 3. Change control

| Change | Requires |
|---|---|
| New tool | Typed implementation, schema, risk, role, verifier, proxy endpoints, policy entry, TCs, registry version, **code review** (C-02) |
| Widening the proxy allowlist | SEC review; the widened flag documented against the tool that needs it; TC-080 matrix updated |
| New forced-command function (IF-26) | Same as a new tool |
| Discord command | UM-04 update; role mapping |
| Prompt change | `prompt_version` bump; the 30-incident corpus re-run (AI-06) |
| Deny-list change | Code change + SEC review; never configuration |

## 4. Traceability

| SRS-04 | Interface |
|---|---|
| FR-01…FR-04, FR-08, FR-09 | IF-16 read tools via IF-25/HTTP/TLS |
| FR-05 | IF-27 |
| FR-06 | IF-26 |
| FR-07, FR-13 | IF-28 |
| FR-10 | IF-16 rule 2 |
| FR-17 | IF-16 write tools; IF-25 endpoints |
| FR-28, FR-29 | IF-08 |
| §4.2 integrations | IF-25 (socket proxy), IF-14, IF-29, IF-27, IF-08, IF-13 |
| AI-01…AI-05 | IF-09 |
| C-02 | IF-16 rule 5, IF-26 forced command, IF-27 fixed statements |
| C-04, NFR-03, NFR-04 | IF-25, IF-26, IF-27 |
| C-06 | IF-09 egress none |
| NFR-06 | IF-09 degraded mode |
