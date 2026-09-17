# Deployment & Operations Guide — Factory Copilot (Local AI Factory Copilot)

| Field | Value |
|---|---|
| Document ID | OPS-10-Copilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-17 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-10](../SRS-FactoryCopilot-Local-Multilingual-Assistant.md) · [SAD-10](SAD-Copilot-Software-Architecture.md) · [DDS-10](DDS-Copilot-Database-Design.md) · [ICD-10](ICD-Copilot-Interface-Control.md) · [SEC-10](SEC-Copilot-Security-Requirements.md) · [TEST-10](TEST-Copilot-Test-Plan.md) · [UM-10](UM-Copilot-User-Admin-Guide.md) · files: [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) · [`deploy/copilot.example.yaml`](../deploy/copilot.example.yaml) · [`deploy/schemas/copilot-config.schema.json`](../deploy/schemas/copilot-config.schema.json) · [`deploy/tools.example.json`](../deploy/tools.example.json) · platform: [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) |

---

## 1. What you are operating
A question router with a language model attached — not a model with some tools. The things that decide whether an answer is right are the tool implementations, the scope predicate, the evidence bundle and the post-check; the model only plans and phrases. Operate accordingly: watch the tools' reachability and latency, the grounding-failure rate, the scope audit and the evaluation status. When the model is down, dashboards, saved questions and document search must keep working (NFR-06).

Four operational truths this guide enforces:
- **No answer with an ungrounded number ever reaches a user** — `copilot_grounding_failed_total` rising is a defect to investigate, never a nuisance to tune away (RB-08).
- **Every tool call carries the caller's scope** — `v_scope_audit.in_scope = false` must never appear (RB-09).
- **Nothing leaves the LAN without a recorded decision** — Discord and external models are flags with a reason and a policy (RB-11).
- **Every prompt, model, tool-schema or embedding change runs the evaluation set first** (RB-07).

## 2. Topology and sizing
| Service | Image | Role | Sizing (one plant, 10 concurrent users, 100 k chunks) |
|---|---|---|---|
| `web` | `copilot/web` | chat UI (tablet), dashboards-only fallback, embed widget | 1 vCPU / 1 GB |
| `api` | `copilot/api` | auth, conversations, SSE, shares, admin, `/agent/*` in platform mode | 2 vCPU / 2 GB |
| `planner` | `copilot/planner` | understanding, typed plan, clarification (one model call) | 1 vCPU / 1 GB |
| `executor` | `copilot/executor` | tool calls with scope predicate, budget, digests | 2 vCPU / 2 GB |
| `sql-sandbox` | `copilot/sql-sandbox` | parser + whitelist + `copilot_sql_ro` | 0.5 vCPU / 512 MB |
| `retriever` | `copilot/retriever` | hybrid retrieval + reranker | 2 vCPU / 2 GB |
| `indexer` | `copilot/indexer` | ingestion, chunking, embeddings, watch | 2 vCPU / 4 GB |
| `composer` | `copilot/composer` | bundle → answer (one model call), post-check, masking, term check | 1 vCPU / 1 GB |
| `renderer` | `copilot/renderer` | charts, PNG/PDF exports | 1 vCPU / 1 GB |
| `scheduler` | `copilot/scheduler` | retention, evaluation runs, queue snapshots | 0.5 vCPU |
| `discord-bot` | `copilot/discord-bot` | profile `discord` only | 0.5 vCPU |
| `postgres` | `pgvector/pgvector:pg16` | DDS-10 | 4 vCPU / 8 GB; 40 GB/y |
| `redis`, `minio` | | queue, rate limits; docs/exports/uploads | 256 MB; 50 GB |
| `ollama` / `ollama-cpu` | `ollama/ollama` | `qwen2.5:7b-instruct-q4_K_M`, `bge-m3`, reranker | 8 GB VRAM (baseline); CPU profile is dev only |

Total production host (standalone): 16 vCPU / 32 GB / 1 × 8 GB GPU / 500 GB NVMe. In platform mode the GPU is shared through the semaphore (SAD-00 ADR-011).

## 3. Networks
| Network | Members | Egress |
|---|---|---|
| `frontend` | reverse proxy → `web`, `api` | LAN only, TLS |
| `internal` (`internal: true`) | everything except `web`, `sibling-stub` | **none** |
| `sources` (`internal: true`) | `executor`, `indexer`, `scheduler` (+ `sibling-stub` in dev) | sibling tool endpoints, document folders |
| `egress` | `discord-bot` only, only with the `discord` profile | Discord gateway |

The model has no route out and no tools; the sandbox has one secret (its own read-only DB role) and no network but `internal`. `check_deploy10.py` (TEST-10 TC-004) verifies the placement.

## 4. Installing
### 4.1 Steps
1. Host: Ubuntu 24.04, Docker 27, NVIDIA container toolkit (gpu profile), `chrony`, `TZ=Asia/Bangkok`.
2. `git clone …/10-factory-copilot && cd deploy && cp .env.example .env && chmod 600 .env`; set `PUBLIC_URL`, `EMBED_ALLOWED_ORIGINS`, `SIBLING_*_URL`, `DOC_SOURCES_ROOT`.
3. Create `${SECRETS_DIR}` and the 11 secret files (§4.2).
4. `${CONFIG_DIR}`: `copilot.yaml` (from `copilot.example.yaml`), `tools.json` (from `tools.example.json`), `prompts/`, `schemas/`, `aliases.csv`.
5. `docker compose --profile gpu up -d postgres minio minio-init` (schema auto-applied on first start) → create the login roles (§4.2).
6. `docker compose --profile gpu up -d` → `docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M && ollama pull bge-m3 && ollama pull bge-reranker-v2-m3`.
7. `cpctl config load copilot.yaml` → `cpctl tools load tools.json` → `cpctl aliases load aliases.csv` → `cpctl prompts register` (checksums into `prompt_template`).
8. `cpctl selftest` (§4.5) → connect sibling tools (§5) → register document sources (§6) → per-tool scope tests (TEST-10 TC-033) → evaluation run (§8).

### 4.2 Secrets (files, 0400, `root:10001`) and database login roles
| File | Used by | Content |
|---|---|---|
| `database_url` | `api`, `planner`, `composer`, `renderer`, `scheduler` | `postgresql://app_rw:…@postgres/copilot` |
| `executor_database_url` | `executor`, `retriever` | role `agent_ro` — cannot read `core.app_user` or `core.user_line_scope` (DDS-10 §8) |
| `sandbox_database_url` | `sql-sandbox` | role `copilot_sql_ro` — `SELECT` on three views; `statement_timeout 5 s`; read-only |
| `indexer_database_url` | `indexer` | role `indexer_rw` |
| `postgres_password` | `postgres` | superuser — never used by a service |
| `jwt_secret`, `share_signing_key` | `api`, `renderer` | 32+ random bytes; rotate on incident |
| `s3_access_key`, `s3_secret_key` | all but the sandbox | MinIO root (standalone); scoped user in platform mode |
| `sibling_service_token` | `executor`, `scheduler` | service token for the sibling tool endpoints (read scopes only) |
| `discord_bot_token` | `discord-bot` | only with the `discord` profile |

Login roles: `CREATE ROLE … LOGIN PASSWORD …` for `app_rw`, `app_ro`, `agent_ro`, `copilot_sql_ro`, `indexer_rw`; grants are in `db/schema.sql`; passwords are `SET_AT_BOOTSTRAP` from the files above. Verify the sandbox role: `psql -U copilot_sql_ro -c "SELECT 1 FROM core.app_user"` must fail; `-c "SELECT pg_sleep(10)"` must time out.

### 4.3 Models
| Model | Use | Rule |
|---|---|---|
| `qwen2.5:7b-instruct-q4_K_M` (7 B) | planner and composer | ≤ 9 B on the 8 GB baseline (AI-01); tool calling; changing it → evaluation run (RB-07) |
| `bge-m3` | embeddings (1024 d) | changing it → `cpctl index reembed` + retrieval regression (TC-048) |
| `bge-reranker-v2-m3` | rerank 30 → 5 | changing it → retrieval regression |

### 4.4 Tool registry and siblings
`tools.json` is the visible capability boundary: 10 read tools with JSON Schemas, providers, minimum roles and the scope parameter. Standalone: local implementations against the extracted tables (`query_production`, `query_defects`, `search_memory`, `get_inspection_images`) and HTTP calls to the sibling URLs for the rest; a sibling that is unreachable makes its tools `unavailable` in `/tools` and the planner refuses questions that need them ("analysis not available"). Platform mode: the registry is the platform's.

### 4.5 Start, load, verify
```
docker compose --profile gpu up -d
docker compose exec postgres psql -U copilot -d copilot -f /db/seed_demo.sql     # dev/staging only — expected \echo block in DDS-10 §9
cpctl selftest     # twins vs production code on the seed (lang, time, aliases, grounding, SQL rules), bundle schema, config, tools, Ollama ping, sandbox role
curl -s $PUBLIC_URL/api/v1/readyz    # {"ready":true,"mode":"full"} — "dashboards_only" when the model is down
```

### 4.6 Reverse proxy
TLS termination; `BIND_ADDR=127.0.0.1`; SSE needs `proxy_buffering off` and a read timeout ≥ 120 s on `/api/v1/chat` and `/turns/*/clarify`; `/api/v1/metrics` from the Prometheus host only; request body limit 8 MB (photo uploads); `/shares/*` LAN only (deny from outside the plant ranges even if the proxy is reachable).

## 5. Tools, scope and the sandbox
1. **Enable a tool**: `PUT /tool-policy/{name}` with `min_role`, `scope_param`, `max_rows`, `timeout_ms` — only `kind = read`; write tools are refused (`READ_ONLY`).
2. **Scope test before enabling** (NFR-05, TC-033): a restricted user in scope / out of scope / without predicate; record the result in the change ticket.
3. **Text-to-SQL** stays off until `POST /eval/sql-runs` reports ≥ 85 % on ≥ 30 questions; then `PUT /feature-flags/text_to_sql {enabled: true, reason}`; the whitelist lists views only, never users/scope/audit (CHECK); `copilot_sql_ro` grants must equal the whitelist (`check_config10.py` verifies for the example).
4. **Aliases** (`cpctl aliases load`): every line/machine/SKU/defect in TH/JA/EN plus local nicknames; a wrong alias silently answers the wrong entity — review the `v_turn_trace.entities_json` sample weekly (RB-03).

## 6. Documents (IF-55)
Register sources (`POST /documents/sources`: kind, folder, ACL, watch interval); the indexer scans every 5 min, skips unchanged files by sha256, re-chunks changed ones. Watch `v_index_status`: `failed` jobs (no text layer, corrupt file) and `suspicious_chunks` (instruction-like text — review and either keep flagged or clean the document; RB-05). A document above a user's ACL is never retrieved for them.

## 7. Channels
- **Web** — default; tablet layout at ≥ 360 px.
- **Embed** — `EMBED_ALLOWED_ORIGINS` and `channels.embed.allowed_origins` must match the dashboard origin.
- **Discord** — off by default. To enable: sign policy DISC-01 (masking on, no images, no document text, channel allow-list), `PUT /feature-flags/discord {enabled: true, reason}`, create and verify `channel_bindings` for each user, start `docker compose --profile discord up -d discord-bot`. Answers leave the LAN from this point (RB-11).

## 8. Prompts, models, evaluation
| Task | Command | Rule |
|---|---|---|
| Register prompt versions | `cpctl prompts register` | checksum stored; a changed file without a new version fails to load |
| Change a prompt / model / tool schema / embedding / bundle schema | edit → `cpctl eval run` → `v_eval_summary` → deploy | accuracy ≥ 90 %, citation ≥ 95 %, fabricated 0 on ≥ 60 questions across 3 languages and 6 intents; otherwise `release_blocked` (RB-07) |
| Maintain the evaluation set | `cpctl eval add question.yaml` (append-only, reviewer) | keep every language and intent represented; add questions from flagged answers |
| Review flagged answers | `/flags` (engineer+) | correct → curated answer (approved, embedded) or dismiss |
| Inspect grounding failures | `SELECT * FROM agent.run WHERE outcome = 'grounding_failed'` | a rising rate means the prompt regressed or a tool stopped returning a derived value (RB-08) |

## 9. Observability
| Signal | Where | Alert |
|---|---|---|
| `copilot_llm_available` | `/metrics` | 0 for > 5 min (mode dashboards_only — RB-06) |
| `copilot_first_token_seconds` p95 | | > 3 (NFR-01) |
| `copilot_answer_seconds` p95 | | > 20 |
| `copilot_queue_depth` / `copilot_queue_wait_seconds` | | depth > 8 or wait > 30 s (NFR-03) |
| `copilot_grounding_failed_total` rate | | > 2 % of turns in a day (RB-08) |
| `copilot_refused_total` rate | | > 20 % — data feeds probably lagging |
| `copilot_scope_narrowed_total` | | informational; `v_scope_audit.in_scope = false` **> 0 → RB-09 immediately** |
| `copilot_sql_generated_total{verdict="rejected"}` | | > 30 % of generated statements — planner drifting |
| `copilot_tool_seconds{tool}` p95 | | > 8 s (a sibling is slow) |
| `copilot_retrieval_seconds` p95 | | > 0.5 (NFR-02) |
| `copilot_suspicious_chunks_total` | | any new — review (RB-05) |
| `copilot_eval_blocked` | | = 1 (do not deploy) |
| DB: `v_copilot_daily`, `v_scope_audit`, `v_sql_audit`, `v_flag_queue`, `v_index_status`, `v_queue`, `agent.v_grounding_health` | psql | |

Logs: JSON to stdout; every turn traceable through `v_turn_trace`; `audit.log` for admin actions, purges, share opens.

## 10. Retention, backup, restore
- Conversations/runs/turns 365 days (scheduler purge; per-user export/delete on request — `DELETE /me/conversations`), shares ≤ 30 days (bucket lifecycle), uploads 24 h, evaluation runs 5 years, documents with their source.
- Backups: nightly `pg_dump` + WAL; MinIO `docs` versioned and mirrored; `${CONFIG_DIR}` in git (prompts, tools, aliases, config).
- Restore drill quarterly: restore to staging; `cpctl selftest`; re-run the evaluation set; reconstruct one turn end-to-end from `v_turn_trace` (TC-116).

## 11. Upgrades and platform mode
- Upgrade: changelog → `cpctl eval run` on the new image → promote; migrations `copilot_000N` idempotent; changes to `agent.*` are platform changes.
- Platform mode: drop `postgres`, `redis`, `minio`, `ollama`, `web` from this compose; point the DB secrets at the platform database; apply `copilot_0001`; the gateway serves `/agent/*` and `/knowledge/*`; tools come from the platform registry; documents from Genba Memory; Discord through the platform notifier (`/ask` routed here).

## 12. Verification commands and runbooks
### 12.1 Verification commands (TEST-10 TS-0 on the authoring machine; TC-009 on a host with Docker)
```
python check_openapi.py api/openapi.yaml                # TC-008: valid, 59/70/57, 0 orphans
python check_api_identity10.py                         # TC-008: 26/26 platform blocks verbatim
python assemble10.py                                   # regenerates db/schema.sql from the platform file + cp_body.sql
python check_schema10.py                               # TC-002/TC-003: 134/134 identical, 5 sections verbatim, counts, guards, grants
python check_seed10.py                                 # TC-005: twins vs Python on the seed (all values equal)
python check_bundle10.py                               # TC-006: 8/8 bundles valid, 14/14 negatives rejected; tools registry 10/10
python check_config10.py                               # TC-007: copilot.example.yaml valid, 32/32 negatives rejected, prompts/aliases/whitelist consistent
python check_deploy10.py                               # TC-004: 19 services, 59 env vars both ways, 11 secrets, placement, hardening
docker compose --profile cpu up -d postgres && psql -f db/schema.sql && psql -f db/seed_demo.sql   # TC-009 (not run here)
```

### 12.2 Runbooks
| ID | Situation | Steps |
|---|---|---|
| RB-01 | **Install / first start** | §4.1–4.5; `cpctl selftest`; ask the six SRS §2.2 questions as a manager and as a scoped inspector; check `v_scope_audit` |
| RB-02 | **A sibling tool is unreachable** (`copilot_tool_seconds` errors) | `/tools` shows it `unavailable`; questions needing it are refused with "analysis not available"; check `SIBLING_*_URL`, the service token, the sibling's `/readyz`; nothing to fix in Copilot |
| RB-03 | **Wrong entity resolved** (alias) | find the turn in `v_turn_trace.entities_json`; fix/add the alias (`POST /aliases`); add an evaluation question; if the alias was wrong for days, review answers shared in that period |
| RB-04 | **Time range resolved wrongly** (shift change) | check `core.shift_calendar` versions (`valid_from`); the resolved range is printed on every answer — search `v_turn_trace.time_resolution` for the period; correct the calendar, never the answers |
| RB-05 | **Suspicious chunks after indexing** | `v_index_status.suspicious_chunks`; open the chunk; if it is a real instruction in a document, keep it flagged (excluded) and inform the document owner; if a false positive, mark reviewed; never disable flagging |
| RB-06 | **Model down / dashboards-only mode** | UI keeps dashboards, saved questions and document search; `docker compose restart ollama`; VRAM check; `mode = full` within 60 s; queued turns resume |
| RB-07 | **Prompt / model / tool-schema / embedding change** | change in git → `cpctl prompts register` or `tools load` → `cpctl eval run` → `v_eval_summary.passed` → deploy; `release_blocked` → revert |
| RB-08 | **Grounding failures rising** | sample `agent.run.grounding_json.unmatched`; typical causes: a tool stopped returning a derived value the composer needs (add it as a fact), model rounding (tighten the prompt, never the tolerance), a new answer template; never relax the post-check |
| RB-09 | **`v_scope_audit.in_scope = false` exists** | the trigger was bypassed — a direct write to `agent.tool_call`; treat as a DB incident (SEC-10 §7): rotate `executor_database_url`, review `audit.log`, revoke shares of the affected turns |
| RB-10 | **Text-to-SQL rejections rising or a bad answer via SQL** | `v_sql_audit`; disable the flag if a statement escaped the rules; add the case to the SQL corpus; re-run `cpctl eval sql` |
| RB-11 | **Enable / disable Discord or an external model** | policy signed → `PUT /feature-flags/…` with reason → (Discord) bindings verified → `--profile discord up`; disable = flag off + `docker compose stop discord-bot`; audit row either way |
| RB-12 | **User asks for their data** | `GET /conversations/{id}/export` per conversation or `DELETE /me/conversations` (purge, audited); confirm with `v_conversation_board` |
| RB-13 | **Restore** | restore `pg_dump` + WAL and the `docs` bucket; `cpctl selftest`; `cpctl eval run`; reconstruct a turn (TC-116) |
| RB-14 | **Platform migration** | §11; apply `copilot_0001` on the platform DB; re-point secrets; verify TC-002 identity on the platform schema; run TC-033 scope tests against platform tools; TC-093 |

## 13. Traceability
| SRS-10 | OPS |
|---|---|
| FR-01…FR-06 | RB-03, RB-04 |
| FR-07, FR-22, C-01, C-03, NFR-05 | §5, RB-02, RB-09 |
| FR-08, C-05, AI-06 | §5.3, RB-10 |
| FR-09…FR-12, AI-07 | §6, RB-05 |
| FR-13…FR-18, AI-04 | §9, RB-08 |
| FR-19, FR-24, FR-25 | §8, §10 |
| FR-23, NFR-07 | §9, §10, RB-12 |
| AI-01, AI-03, AI-05 | §4.3, §8, RB-07 |
| C-04, NFR-04 | §3, §7, RB-11 |
| NFR-01…NFR-03 | §9 |
| NFR-06, AC-09 | §1, RB-06 |
