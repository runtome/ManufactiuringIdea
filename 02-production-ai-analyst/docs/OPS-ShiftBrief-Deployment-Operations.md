# Deployment and Operations Guide — ShiftBrief (Production AI Analyst)

| Field | Value |
|---|---|
| Document ID | OPS-02-ShiftBrief |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) |
| Inherits | [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) for TLS/CA, JWT keys, backup/restore mechanics — linked, not restated |
| Audience | Administrator, on-call, the person who owns the daily file |

---

## 1. How to use this document

| Situation | Section |
|---|---|
| First install on a VPS | §3 |
| Setting up the daily file (folder / SFTP / email) and its mapping | §3.5 — the part that takes real effort |
| The brief did not arrive this morning | RB-01, RB-06, RB-08 |
| The file did not arrive / was rejected / drifted | RB-01, RB-03, RB-04 |
| "Could not be verified" briefs | RB-06 — integrity |
| Configuration | §4 |
| Platform mode | §2.3 |

**On-call summary:**

1. **No file, no brief.** A missing brief at 07:15 is almost always a missing or rejected file (RB-01/RB-03). Check `/sources` first, the LLM second.
2. **A rejected batch is the system working.** Do not raise the 5 % threshold to make it pass; fix the file or the mapping.
3. **A withheld brief is the safety net working; a rising rate of them is an incident** (RB-06).
4. **Never** set `GROUNDING_CHECK_ENABLED=false`, and never enable `ENABLE_TEXT_TO_SQL` outside the procedure in §5.4.

---

## 2. Deployment shapes

### 2.1 Single server / VPS, CPU-only — the reference
Everything in `docker-compose.yml`, no GPU. A ≤ 4 B model on CPU generates the daily brief in 2–4 minutes; generation is scheduled at 06:45 so delivery at 07:00 holds.

| Resource | Minimum | Comfortable |
|---|---|---|
| vCPU | 4 | 8 |
| RAM | 8 GB | 16 GB |
| Disk | 60 GB SSD | 200 GB (2 years of archives) |
| GPU | none | — |
| Network | LAN or VPS; internet only for Discord/SMTP egress (allow-listed) | |

### 2.2 GPU profile
`docker compose --profile gpu up -d` after `docker compose stop ollama`. Same stack; `LLM_PROFILE=gpu`, `LLM_MODEL=qwen3:8b`; brief ≤ 60 s; higher `/ask` rate limits.

### 2.3 Platform mode
**Do not use `docker-compose.yml`.** Apply migration `shiftbrief_0001` to the FactoryBrain database, deploy the ShiftBrief intake/analytics/brief modules as platform workers, and configure sources there. The platform's `POST /ingest/production` and `POST /agent/brief` become ShiftBrief ([SAD-02 §9](SAD-ShiftBrief-Software-Architecture.md)).

---

## 3. Installation

### 3.1 Prerequisites
Ubuntu 22.04 (or any Docker host), Docker 24+ with Compose v2, NTP enabled. No GPU driver needed for the reference profile.

```bash
timedatectl status          # NTP: yes — "yesterday" depends on it
df -h                       # ≥ 60 GB free
```

### 3.2 TLS and JWT keys
As OPS-00 §3.2–3.3 (internal CA, server certificate, RS256 key pair). For a VPS with a public hostname, Caddy can obtain a Let's Encrypt certificate instead — but only if the host has inbound 80/443 from the internet, which most factory deployments should not.

### 3.3 Configure and start

```bash
cd deploy && cp .env.example .env && chmod 600 .env
${EDITOR:-nano} .env            # every [REQUIRED]; work the pre-flight list
mkdir -p incoming/mes           # one subfolder per source
docker compose up -d
docker compose ps
curl -k https://shiftbrief.local/api/v1/readyz     # llm_profile: cpu
```

`schema.sql` and `seed_demo.sql` apply on **first start only**. **Remove `seed_demo.sql` from the `../db` mount for a production database.** The seed refuses a non-empty database, but the file should not be present at all.

### 3.4 First login
Sign in as the bootstrap admin, enrol MFA, create a **second** admin, remove `BOOTSTRAP_ADMIN_PASSWORD`, restart `api`.

### 3.5 Source setup — the daily file

This is the step that decides whether ShiftBrief is useful. Budget an afternoon with the person who produces the file.

#### Step 1 — Get three real files
Yesterday's, a day with a known problem, and one from a month ago. Layouts drift; three files show whether the header is stable.

#### Step 2 — Choose the transport
| Transport | When | Setup |
|---|---|---|
| **Folder** (recommended) | MES can write to a share, or a scheduled copy exists | Mount the share at `SB_INCOMING_DIR/<source>/` |
| **SFTP** | MES can push over the network | `--profile sftp`; per-source account; give the MES admin the host key fingerprint |
| **Upload** | A person exports manually | Nothing; `engineer` uploads in the UI |
| **IMAP** | The file already arrives by email | Populate `IMAP_SENDER_ALLOWLIST` **before** enabling; recommend folder/SFTP for production |

#### Step 3 — Create the source and write the mapping
`POST /sources` (or the UI), then author the mapping YAML. A real MES export usually looks like this:

```
Date,Shift,Line,Item Code,Output Qty,NG Qty,Defect,Defect Qty,Run Min,Down Min,Operator
2026-09-10,1,Line 3,CND-220-X,1070,30,Missing Component,12,440,40,OP-0412
2026-09-10,1,Line 3,CND-220-X,1070,30,Scratch,7,440,40,OP-0412
...
```

and the mapping that reads it:

```yaml
schema_version: 1
source: mes_daily
delimiter: ","
date_format: "%Y-%m-%d"
columns:
  prod_date:    { from: "Date" }
  shift:        { from: "Shift",      map: { "1": "A", "2": "B" } }
  line:         { from: "Line",       map: { "Line 1": "L1", "Line 2": "L2", "Line 3": "L3" } }
  sku:          { from: "Item Code" }
  qty_produced: { from: "Output Qty", type: int, min: 0 }
  qty_ng:       { from: "NG Qty",     type: int, min: 0 }
  defect_code:  { from: "Defect",     optional: true,
                  map: { "Missing Component": "MISSING_COMPONENT", "Scratch": "SCRATCH",
                         "Missing Fin": "MISSING_FIN", "Dent": "DENT", "Leak": "LEAK" } }
  defect_qty:   { from: "Defect Qty", type: int, optional: true }
  runtime_min:  { from: "Run Min",    type: number, optional: true }
  downtime_min: { from: "Down Min",   type: number, optional: true }
  operator_id:  { from: "Operator",   optional: true, pii: pseudonymise }
rules:
  - qty_ng <= qty_produced
  - line in known_lines
  - sku in known_skus
  - defect_code in known_defect_codes
```

Note the **`pii: pseudonymise`** on the operator column. If the file has any person-identifying column, mark it. The raw value never reaches the database.

#### Step 4 — Dry-run, then save
`POST /sources/mes_daily/mappings/validate` with the YAML and each of the three files. Read the result:

```
header_match: true · rows_total: 183 · rows_ok: 180 · rows_would_quarantine: 3 · would_reject: false
  row 181: NG Qty (48) exceeds Output Qty (40)
  row 182: Line "Line 4" is not a known line
  row 183: Date "10/09/2026" does not match YYYY-MM-DD
```

Three quarantines on a real file is normal and useful — show them to the file's owner. Save the mapping with a reason.

#### Step 5 — Expectation
`PUT /sources/mes_daily/expectation` — `{"cadence":"daily","expected_by":"09:00","grace_minutes":30}`. If nothing has arrived by 09:30, `FILE_NOT_ARRIVED` fires and no brief is generated from partial data.

#### Step 6 — First brief, reviewed by a person
Drop yesterday's file, wait for facts, `POST /brief` for the date, and **read it against the file with the manager** before subscribing any channel. Then `POST /subscriptions`.

Run in parallel with the existing manual PowerPoint for two weeks (TEST-02 field run) before retiring it.

---

## 4. Configuration reference

Full list: [`.env.example`](../deploy/.env.example).

### 4.1 Never weaken

| Variable | Value | Why |
|---|---|---|
| `GROUNDING_CHECK_ENABLED` | `true` | The no-invented-numbers guarantee (ADR-013) |
| `ENABLE_TEXT_TO_SQL` | `false` until §5.4 is complete | Off by default by design (ADR-S07) |
| `ENABLE_EXTERNAL_LLM` | `false` | `true` sends production data off-LAN (SEC-241) |
| `INGEST_QUARANTINE_THRESHOLD_PCT` | `5` | Raising it lets bad days into the warehouse looking complete |
| `IMAP_SENDER_ALLOWLIST` / `SMTP_RECIPIENT_ALLOWLIST` | populated | Empty **denies**; a wildcard makes the mailbox an open intake and the mailer an open relay |
| `PII_HMAC_KEY` | set, backed up elsewhere | Losing it breaks pseudonym continuity; leaking it enables re-identification |

### 4.2 Frequently tuned

| Variable | Default | Guidance |
|---|---|---|
| `CRON_BRIEF_GENERATE` | `45 6 * * *` | On CPU, measure brief latency (TC-103) and start early enough for the 07:00 delivery |
| `ANALYTICS_MIN_RANK_VOLUME` | `100` | Below this a group is shown but never "worst"; set from real line volumes |
| `ALERT_DEFECT_RATE_PCT` | `4.0` | From process capability, not a round number |
| `ALERT_DEFECT_RATE_CHANGE_PCT` | `25` | Relative alert; the significance test is separate and always runs |
| `OLLAMA_NUM_THREADS` | `4` | = vCPU count minus 1 on the CPU profile |
| `LLM_MODEL` | `qwen3:4b` | CPU: stay ≤ 4 B; GPU: `qwen3:8b` |
| `FACTS_VERSION` | `1.0` | **Bump on any analytics change** — CI enforces it |

Runtime-tunable thresholds also live in `ops.config` (admin UI, no restart). Secrets never do.

---

## 5. Model and analytics management

### 5.1 LLM model (offline)
The `backend` network has no internet route; pull on a connected machine and copy the volume, as OPS-00 §5.1:
```bash
ollama pull qwen3:4b            # CPU profile   (qwen3:8b for GPU)
docker run --rm -v shiftbrief_ollama_models:/dest -v ~/.ollama:/src alpine sh -c "cp -a /src/. /dest/"
```
Changing `LLM_MODEL` or a prompt template **requires re-running the golden brief set** before the next delivery (TEST-02 §7).

### 5.2 Analytics changes and `FACTS_VERSION`
Any change to how a facts field is computed → bump `FACTS_VERSION` → old facts rows stay, new rows are written for regenerated dates. Dashboards show the version. Never edit a facts row (the trigger prevents it anyway).

### 5.3 Prompt templates
In git under `brief/prompts/`; `prompt_version` is stamped on every brief. Not editable at runtime. A change is a code change with the golden set as its test.

### 5.4 Enabling text-to-SQL — the procedure
1. Confirm the `agent_ro` grant list in `schema.sql` §14 is exactly the intended whitelist.
2. Run the 30-question execution-accuracy set (TC-051): **≥ 85 %** or stop.
3. Run the SQL injection corpus (TC-052): **100 % rejected** or stop.
4. `admin` sets `ask.enable_text_to_sql = true` in the UI (audited).
5. Announce to users that `/ask` may now show SQL, and where the whitelist is documented (UM-02 A6).
6. Watch `text_to_sql_rejected_total` for a week (RB-12).

Disable immediately if any query reaches a non-whitelisted object in the audit log — that is a security event.

---

## 6. Database, archives, backup

Mechanics inherited from OPS-00 §6. ShiftBrief specifics:

| Item | Position |
|---|---|
| Archive bucket | Versioning on; the sweep is the only deleter; 2-year lifecycle; **access audited** (originals may contain raw PII) |
| Backup | Nightly dump + WAL; RPO ≤ 24 h, RTO ≤ 4 h; **restore DB and archives together** |
| Restore drill | Quarterly; success = seed verification queries pass on the restored copy |
| `PII_HMAC_KEY` | Not in the backup; stored separately; rotation invalidates old pseudonyms (document the date) |
| Retention | Facts and briefs are never auto-deleted while a brief references the facts row |

---

## 7. Observability

### 7.1 Metrics that page someone

| Metric | Condition | Runbook |
|---|---|---|
| `shiftbrief_file_arrival_lag_seconds{source}` | > grace | RB-01 |
| `shiftbrief_ingest_batches_total{disposition="rejected"}` | any | RB-03 |
| `shiftbrief_ingest_batches_total{disposition="held_drift"}` | any | RB-04 |
| `shiftbrief_ingest_rows_quarantined_total` | rate ×5 vs 7-day | RB-02 |
| `shiftbrief_brief_total{outcome="withheld"}` | any; **rate > 1 %/week = incident** | **RB-06** |
| `shiftbrief_brief_delivery_lag_seconds` | > 900 (07:15) | RB-08 / RB-07 |
| `shiftbrief_facts_stale_total` | any | **RB-13** |
| `shiftbrief_text_to_sql_rejected_total` | > 10/h | RB-12 |
| `shiftbrief_brief_generation_seconds{profile="cpu"}` | p95 > 240 | RB-08 |
| Disk free | < 15 % | RB-09 |

### 7.2 SLOs

| SLO | Target |
|---|---|
| Brief delivered by 07:15 (file on time) | 99 % of days |
| File-arrival alert within 5 min of grace expiry | 100 % |
| KPI/dashboard availability | 99 % |
| Withheld briefs | < 1 % of briefs per month |
| `/ask` p95 (GPU / CPU) | ≤ 20 s / ≤ 90 s |

---

## 8. Runbooks

### RB-01 — File not arrived
1. `GET /sources` → `arrival_status: late`. Check the transport: share mounted? SFTP login? mailbox reachable?
2. If the file exists but was not picked up: name matches `file_pattern`? size stable? `.part` suffix?
3. Chase the file owner; the alert names the source and the expected time.
4. When it lands, intake runs automatically and the brief is generated (it was deferred, not skipped).
5. Never generate a brief from a partial day to "have something".

### RB-02 — Quarantine spike
1. `GET /ingest/batches/{id}/quarantine` — read the reasons; they are written for the file owner.
2. Usually one of: a new line/SKU/defect code not in master data (add it, re-ingest is idempotent); a date-format change (mapping); NG > produced on a shift (the owner must fix the file).
3. Do **not** raise the quarantine threshold.

### RB-03 — Batch rejected (> 5 %)
1. Nothing was committed — the day is absent, not partial. The dashboard says "awaiting file".
2. Read `reject_reason` and the quarantine rows; send them to the owner.
3. A corrected file re-ingests normally; the rejected batch stays in history.
4. If the file is genuinely > 5 % bad for a legitimate reason (a new line went live), fix master data first, then re-upload.

### RB-04 — Mapping drift
1. Alert lists missing/unexpected columns; the batch is **held**, not lost.
2. Compare the file header with the active mapping; confirm with the owner whether the change is intentional.
3. `POST /sources/{code}/mappings/validate` with the file → new version with a reason → `POST /ingest/batches/{id}/release`.
4. Layout changes without notice are common; ask the owner to warn you next time, but the fingerprint means you are never surprised silently.

### RB-05 — Duplicate or corrected file
1. Identical file → `409`, existing batch, nothing to do.
2. Same dates, different content → superseding batch, new facts version, **revised** brief posted with the delta. Verify `brief.revised_of` links correctly.
3. If a correction arrives for a date > 30 days old, the revised brief still posts; consider whether the channel needs it.

### RB-06 — Withheld brief(s) (**integrity**)
1. `SELECT * FROM analytics.v_brief_health ORDER BY day DESC LIMIT 7;` and the withheld rows' `grounding_json` (`unmatched[]`).
2. Single event: regenerate (`POST /brief` with `regenerate`); usually a rounding/format token — tune `GROUNDING_NUMERIC_TOLERANCE` only with evidence.
3. Rising rate: what changed — model tag, prompt version, facts field? **Roll back** the change; re-run the golden set.
4. **Never disable the check.** The withheld briefs are correct behaviour; the drift behind them is the incident.

### RB-07 — Discord not delivering
1. Brief exists in the dashboard (`GET /brief/history`)? Then it is delivery, not generation.
2. Bot token valid, channel on the allow-list, bot in the channel, rate limits (`429`)?
3. Email fallback delivered? If neither, `POST /brief/{id}/deliver` after fixing.
4. Discord is not the record; the dashboard is.

### RB-08 — Brief late or LLM slow / down
1. `/readyz` → `llm: unavailable` or `degraded`. Intake, facts and KPI are unaffected.
2. `docker compose logs ollama`; memory limit hit on CPU? (`OLLAMA_MEMORY_LIMIT`, model too large for the profile).
3. Restart; the brief job retries every `BRIEF_RETRY_MINUTES`.
4. Chronic lateness on CPU: move `CRON_BRIEF_GENERATE` earlier, reduce `BRIEF_MAX_TOKENS_OUT`, or adopt the GPU profile. Do not switch to an external LLM to fix latency.

### RB-09 — Disk
1. Archives are the usual growth. Confirm the lifecycle rule and the retention sweep ran.
2. Never delete WAL, unprocessed incoming files, or archives referenced by an open investigation.

### RB-10 — Database down
1. Intake queues files (they stay in the folder/mailbox); nothing is lost.
2. Restore per OPS-00 §6; after recovery, intake processes the backlog in arrival order.

### RB-11 — PPTX/PDF wrong (mojibake, missing chart)
1. Mojibake → fonts not embedded in the image (TC-074); rebuild the image with Noto Sans Thai/JP.
2. Chart mismatch → the export reads the same facts row as the brief; check `facts_version` in the footer vs the brief.

### RB-12 — Text-to-SQL rejections spiking
1. `text_to_sql_rejected_total{reason}` — parser vs whitelist vs function.
2. Many parser rejections on ordinary questions = the model is generating bad SQL; consider disabling until prompts improve.
3. **Any** non-whitelisted object reached in the audit log = disable now, treat as a security event (SEC-02 §7.3 inherited).

### RB-13 — `FACTS_STALE`
1. Two causes: a warehouse row was changed without a superseding batch (who? `audit.log` on `core.production_fact`), or analytics code changed without a `FACTS_VERSION` bump.
2. Do not "fix" by regenerating. Identify the cause; if code, bump the version and regenerate under the new one (old rows remain); if data, find the change, create the missing correction batch, then regenerate.

### RB-14 — Planned upgrade
As OPS-00 §9, plus: check the release notes for `FACTS_VERSION` and `prompt_version` changes; run the golden set on staging before the first production brief.

---

## 9. Routine operations

**Daily (5 min)** — every source `on_time` · no rejected/held batches · brief delivered with badge · no withheld briefs · quarantine count normal.

**Weekly (20 min)** — quarantine reasons trend (recurring reason = fix the source) · significance days reviewed with the manager (were they real?) · `/ask` feedback ratings · text-to-SQL rejections if enabled.

**Monthly (1 h)** — regenerate one random past date and confirm the hash matches (TC-029 in production) · mapping versions reviewed with the file owner · alert precision review · disk/archives trend.

**Quarterly (half day)** — restore drill (DB + archives) · authorisation matrix · injection corpora · golden brief set · secret rotation (**note the `PII_HMAC_KEY` rotation consequence**) · review this document.

---

## 10. Capacity

Trivial for the database. **Archives** are the only growth (1–50 MB/day); size at 2 years. CPU profile: one 4 B model serves one plant's daily brief and a handful of `/ask` per hour comfortably; beyond ~20 `/ask`/hour, use the GPU profile.

---

## 11. Decommissioning
Export facts, briefs and audit (retention obligations outlive the tool) · revoke Discord/SMTP/IMAP/SFTP credentials · destroy `PII_HMAC_KEY` **after** confirming exports contain no pseudonyms that must remain linkable · wipe volumes · record disposal.

---

## 12. Traceability

| Requirement | Section |
|---|---|
| NFR-01 ingest ≤ 3 min | §7.1, TC-101 |
| NFR-02 brief ≤ 60 s (GPU) / CPU documented | §2.1, §4.2, RB-08 |
| NFR-05 8 GB footprint | §2.1 |
| NFR-08 reproducible | §5.2, RB-13 |
| AC-01 30-day import | §3.5 |
| AC-05 7 days Discord | §7.2 SLO |
| C-02 archives | §6 |
| C-04 no internet | §5.1 |
| ADR-S02 mapping drift | RB-04 |
| ADR-S03 rejection | RB-03 |
| ADR-S06 CPU reference | §2.1 |
| ADR-S07 text-to-SQL | §5.4, RB-12 |
| SEC-S16/S71 allow-lists | §4.1 |
| SEC-S50/S51 PII key | §4.1, §6 |
| SEC-S45 facts stale | RB-13 |

---

## Appendix A — Diagnostic bundle

```bash
#!/bin/sh
OUT=sb-diag-$(date +%F-%H%M); mkdir -p "$OUT"
docker compose ps                                   > "$OUT/services.txt"
docker compose logs --tail=500                      > "$OUT/logs.txt"
df -h                                               > "$OUT/disk.txt"
curl -sk https://localhost/api/v1/readyz            > "$OUT/readyz.json"
docker compose exec -T postgres psql -U shiftbrief -c "SELECT * FROM analytics.v_intake_health;"  > "$OUT/intake.txt"
docker compose exec -T postgres psql -U shiftbrief -c "SELECT * FROM analytics.v_brief_health ORDER BY day DESC LIMIT 14;" > "$OUT/briefs.txt"
docker compose exec -T postgres psql -U shiftbrief -c "SELECT ts, kind, severity, detail_json FROM analytics.alert_event ORDER BY ts DESC LIMIT 30;" > "$OUT/alerts.txt"
ls -la incoming/*/                                  > "$OUT/incoming.txt" 2>&1
tar czf "$OUT.tar.gz" "$OUT" && rm -rf "$OUT" && echo "Wrote $OUT.tar.gz"
```
Review for secrets and for raw file contents (which may include PII) before it leaves the site.
