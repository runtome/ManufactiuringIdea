# Deployment and Operations Guide — Genba Memory

| Field | Value |
|---|---|
| Document ID | OPS-15-GenbaMemory |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SAD-15](SAD-GenbaMemory-Software-Architecture.md) · [DDS-15](DDS-GenbaMemory-Database-Design.md) · [ICD-15](ICD-GenbaMemory-Interface-Control.md) · [SEC-15](SEC-GenbaMemory-Security-Requirements.md) |
| Artifacts | [`deploy/`](../deploy/) — compose, `.env.example`, `genbamemory.example.yaml`, schemas, prompts, `minio-init.sh`, `initdb/20-roles.sh` |

---

## 1. Topology

One host. `docker compose` with four profiles.

```
                     reverse proxy (TLS)
                              │
     frontend ────────── web ─┴─ api ──────────────┐
                                                   │
     internal (internal: true — no route out)      │
       postgres (pgvector) · redis · minio         │
       ollama (gpu | cpu)                          │
       worker-ingest · worker-ocr · worker-extract │
       normaliser · indexer · retriever · scheduler┘
                                                   
     egress ── discord-bot  ← the ONLY container that reaches the internet
```

**17 services.** Sizing for the SRS targets (50 k cases, 500 k chunks, ≤ 1 s p95): 8 vCPU, 32 GB RAM, 1 TB NVMe, and a GPU with ≥ 12 GB if you want the extraction backlog to clear overnight rather than over a weekend. Without a GPU run the `cpu` profile and expect ingestion, not retrieval, to be the slow part.

```bash
docker compose --profile gpu --profile discord up -d      # plant
docker compose --profile cpu --profile dev up -d          # integration tests (TS-1…TS-9)
```

---

## 2. Platform mode

Genba Memory is the **tight (core)** module that owns `knowledge` (SAD-00 §13). In platform mode:

- Drop `postgres`, `redis`, `minio`, `ollama` and `web` from this compose; point the database secrets at the platform database.
- Apply **sections 10–19 only** of `db/schema.sql` as migration `memory_0001`. `core`, `quality`, `knowledge` and `audit` already exist.
- `knowledge.glossary_term` and `knowledge.tm_segment` belong to GenbaGo (14) — read-only here, and the grants say so. `knowledge.chunk.suspicious` belongs to Copilot (10); the migration adds it only if missing.
- The gateway serves `/knowledge/search` and `/knowledge/documents`; the rest mounts under `/memory/`.
- Register the four IF-16 tools in `agent.tool`: `search_memory`, `get_case`, `similar_cases`, `recurrence_check` — all `read`, all `min_role: viewer`.
- Genba Memory takes over the **IF-55** document ingestion contract for the platform; Copilot's own indexer keeps only the folders 15 does not cover.
- Subscribe to `quality.case.opened` on the bus (IF-17) so suggestions fire without anyone searching.

---

## 3. Install

```bash
cd 15-troubleshooting-memory/deploy
cp .env.example .env                 # edit: registry, PUBLIC_URL, ports, buckets
mkdir -p secrets config
cp genbamemory.example.yaml config/genbamemory.yaml
cp -r schemas prompts config/
# create the sixteen secret files — §4
docker compose --profile gpu up -d postgres
docker compose --profile gpu up -d                # the rest
docker compose exec -T postgres psql -U postgres -d genbamemory -f /docker-entrypoint-initdb.d/10-schema.sql   # only if the volume already existed
```

`db/schema.sql` runs automatically on the first boot of an empty volume, followed by `initdb/20-roles.sh`, which sets the role passwords from the secret files. The demo data is optional and never loaded in a plant:

```bash
docker compose exec -T postgres psql -U postgres -d genbamemory < ../db/seed_demo.sql
```

Pull the models once:

```bash
docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M
docker compose exec ollama ollama pull bge-m3
docker compose exec ollama ollama pull bge-reranker-v2-m3
```

---

## 4. The sixteen secrets

Every credential is a **file** under `${SECRETS_DIR}`. Nothing is an environment value, and nothing is in the repository (SEC-H30, SEC-H31).

| File | What it is |
|---|---|
| `postgres_password` | the superuser password |
| `app_rw_password`, `worker_rw_password` | the two application role passwords |
| `database_url` | `postgresql://app_rw:…@postgres:5432/genbamemory` |
| `worker_database_url` | `postgresql://worker_rw:…@postgres:5432/genbamemory` |
| `jwt_secret` | API token signing |
| `tool_token` | the bearer the IF-16 consumers present |
| `s3_access_key`, `s3_secret_key` | the application's MinIO user |
| `minio_root_user`, `minio_root_password` | bootstrap only, used by `minio-init` |
| `bot_api_token` | the Discord bot's API credential |
| `discord_token`, `discord_channel_id` | the bot itself |
| `source_mail_password`, `source_chat_token` | IF-78 source credentials — the only two a worker ever holds |

```bash
umask 077
openssl rand -base64 48 > secrets/jwt_secret
printf 'postgresql://app_rw:%s@postgres:5432/genbamemory' "$(cat secrets/app_rw_password)" > secrets/database_url
```

Rotation follows SEC-00 §5. Rotating `worker_rw_password` needs a restart of the six worker services and nothing else.

---

## 5. The ingestion campaign

This is the part that goes wrong, and it goes wrong in a predictable way: someone points the system at ten years of file shares on day one, forty thousand documents arrive, the curation queue fills with low-confidence fields, and nobody ever looks at it again. The memory is then technically complete and practically useless.

Ingest in waves.

| Wave | What | Why first |
|---|---|---|
| 1 | 8D and RCA reports from the last 3 years | highest signal per document; they already have a symptom, a cause and an action |
| 2 | Maintenance logs for the machines those cases name | fills in recurrence intervals |
| 3 | Handover notes and work orders, newest first | low signal each, high volume — the wave that tests your curation capacity |
| 4 | Complaints and supplier documents, **with their ACL set on the source** | the wave where a mistake is expensive (SEC-H01) |
| 5 | Everything older than 3 years | by now you know the extraction accuracy on your own documents |

```bash
curl -sX POST "$API/sources" -H "$AUTH" -d @source-8d.json
curl -sX POST "$API/sources/$ID/sync" -H "$AUTH"
watch -n 30 'curl -s "$API/ingest/jobs?state=failed" -H "$AUTH" | jq ".items | length"'
```

Rules of thumb:

- **Stop a wave when the curation queue's oldest open item passes 72 hours.** The queue age is a metric for exactly this (`memory_curation_age_hours`).
- Set `default_acl` on the *source*, not per document. Correcting one source is one edit; correcting four thousand documents is not.
- A failed job is a row, never a crash: `GET /ingest/errors` groups them by reason, and each carries the action to take (FR-07).
- `unreadable_scan` on a batch of old photocopies is not a bug to fix — it is the signal to re-scan at 300 dpi or to enter those cases by hand (FR-14).

---

## 6. OCR

The `ocr-models` volume holds the Japanese vertical and Thai models. `OCR_CONFIDENCE_GATE` defaults to 0.95; handwriting is **always** low confidence regardless of what the engine reports (`trg_ocr_flag`).

```bash
curl -s "$API/documents/$DOC/ocr" -H "$AUTH" | jq '.pages[].regions[] | select(.low_confidence)'
```

Measure the accuracy on your own scans before trusting it. `ingestion.ocr.measured_accuracy` in the configuration is `null` on purpose: this set never assumed a number nobody measured.

---

## 7. The curation loop

A curator works one queue, oldest first. Each kind has one decision to make:

| Kind | The question | Decisions |
|---|---|---|
| `low_confidence` | is this what the document says? | `verified` · `corrected` · `suppressed` |
| `unmapped_entity` | which machine, line or SKU is this? | `mapped` · `dismissed` |
| `near_duplicate` | same incident or two? | `merged` · `distinct` |
| `flagged_field` | who is right, the extractor or the person who flagged it? | `corrected` · `verified` · `suppressed` |
| `suspicious_chunk` | is this document hostile or just badly worded? | `dismissed` · restrict the document |

Two rules a curator should know by heart. **Verification means "I read the original"** — not "it looks plausible"; that is the whole difference between this memory and a wiki. And **a case with no recorded cause stays without one**; `knowledge_gaps()` counts it, and an invented cause is the one error nothing downstream can catch.

```bash
curl -s "$API/curation?state=open" -H "$AUTH" | jq -r '.items[] | "\(.age_hours|floor)h \(.kind) \(.detail)"'
curl -sX POST "$API/curation/$ITEM/decide" -H "$AUTH" -d '{"decision":"mapped","value":"M-07"}'
```

---

## 8. Evaluation

The monthly run (`EVAL_SCHEDULE`, default 03:00 on the 1st) does two things and gates both.

| Run | Needs | Passes at |
|---|---|---|
| retrieval | an eval set with qrels | Recall@5 ≥ 0.80 **and** MRR ≥ 0.60 (AI-04) |
| extraction | a labelled set | ≥ 0.85 narrative **and** ≥ 0.95 factual (AI-02) |

`passed` is computed by `eval_finalize()`; the database refuses a disagreeing value. A failing run is not a failure of the month — it is the gate doing its job, and the candidate model or index simply is not promoted.

**Building the real sets.** The SRS asks for 100 labelled documents and 50 queries; the seed ships 12 and 12 and says so. To build the real ones:

1. Take a stratified sample across document kinds, machines and years — not the easiest fifty.
2. Label **fields**, not documents: two people, disagreements resolved by reading the original.
3. Write the queries the way technicians actually ask, in the language they ask in. At least a quarter cross-language (AI-03).
4. Mark relevance 2 for the case the asker wanted and 1 for also-relevant ones.
5. Version the set. A metric from a different set is not a comparison.

**When a model upgrade regresses**: the gate refuses it, the active version keeps serving, and `GET /eval/runs/{runId}` gives the per-query hit ranks. Compare query by query — a regression concentrated in the cross-language queries is an embedding problem; one spread evenly is usually a reranker problem.

---

## 9. Re-embedding a live index

```bash
curl -sX POST "$API/embeddings/reembed" -H "$AUTH" -d '{"to_version":"bge-m3@2","batch_size":1000}'
watch -n 60 'curl -s "$API/embeddings/reembed/$JOB" -H "$AUTH" | jq "{done:.done_chunks,total:.total_chunks,search:.search_available}"'
```

Queries stay pinned to the active version for the whole job; the switch at the end is one row. The old version cannot be retired while the job runs (`VERSION_IN_USE`). Expect roughly double the vector storage until the old version is retired.

---

## 10. Tuning the recurrence threshold

The default is 0.72 and it favours recall, because a missed recurrence is the expensive error (AI-06). Tune it against your own confirmed links:

```sql
SELECT round(t::numeric, 2) AS threshold,
       count(*) FILTER (WHERE r.score >= t)                          AS proposals,
       count(*) FILTER (WHERE r.score >= t AND r.confirmed_at IS NOT NULL) AS confirmed
  FROM memory.recurrence r, generate_series(0.60, 0.90, 0.02) t
 GROUP BY t ORDER BY t;
```

| Threshold | Proposals | Confirmed | Precision | Missed |
|---|---|---|---|---|
| 0.60 | many | most | low | none |
| **0.72** | moderate | most | acceptable | few |
| 0.85 | few | nearly all | high | several |

Move it up only when engineers tell you they are dismissing proposals without reading them — that, not the precision number, is the real cost of a low threshold.

---

## 11. Monitoring, retention and backup

| Metric | Watch for |
|---|---|
| `memory_ingest_backlog` | rising for more than a shift → a worker is down or a source is unreachable |
| `memory_ingest_failed_total{reason}` | a new reason appearing is a new document format |
| `memory_extraction_confidence_bucket` | the distribution sliding left → the model or the document kind changed |
| `memory_search_latency_seconds` | p95 approaching 1 s (NFR-01) |
| `memory_search_acl_filtered_total` | a sudden rise → someone is searching for things they cannot see |
| `memory_recall_at_5` | the monthly trend; one bad month is noise, three is a problem |
| `memory_coverage_ratio{kind}` | `human_verified` falling → curation is losing to ingestion |
| `memory_curation_age_hours` | over 72 → **stop the current ingestion wave** |
| `memory_suspicious_chunks_total` | any rise deserves a look |

**Retention.** Originals ≥ 730 days and never expired on a schedule — an admin runs the retention job explicitly. OCR artefacts expire at 365 days and the scratch bucket at 7; both are derived and can be rebuilt. Retrieval logs ≥ 365 days because evaluation needs history.

**Backup.** `memory` and `knowledge` are the irreplaceable schemas: verifications, curation decisions and entity mappings exist nowhere else. The originals bucket is re-creatable from the sources it came from, and the vector index is re-creatable from the text. Nightly `pg_dump` of the database, weekly bucket sync, and a quarterly restore rehearsal that ends by running §12.

---

## 12. Runbooks

| ID | Situation | Action |
|---|---|---|
| **RB-01** | Ingestion backlog rising | `GET /ingest/jobs?state=queued`; check `worker-ingest` and the source's reachability; a stuck source is `source_unreachable`, not a silent stall |
| **RB-02** | Many `unreadable_scan` failures | one batch of photocopies; re-scan at 300 dpi or route them to manual entry (FR-14) |
| **RB-03** | Extraction queue not draining | the GPU semaphore or a model pull; check `ollama` logs; ingestion continues, retrieval is unaffected |
| **RB-04** | Curation queue over 72 h | stop the ingestion wave; batch-decide `unmapped_entity` items first — they unblock ranking for many cases at once |
| **RB-05** | Search p95 over 1 s | check `rerank_depth`, the HNSW `ef_search`, and whether a re-embed is running; the retriever scales horizontally |
| **RB-06** | A restricted document was seen | SEC-15 I-1; revoke, read `query_log`, re-run TC-071 |
| **RB-07** | A verified case is wrong | flag the field (it disappears at once), revoke the verification with a reason, re-verify after reading the original |
| **RB-08** | A recurrence proposal storm | usually one machine with many similar cases; confirm or reject in a batch, then reconsider the threshold (§10) |
| **RB-09** | Evaluation gate failed | do not promote; compare per query; §8 |
| **RB-10** | Re-embed stuck | the job is resumable — `done_chunks` is the cursor; restart `indexer`; search was never affected |
| **RB-11** | Discord silent | the bot is the only egress container; check the token and the channel id secrets; alerts queue rather than drop |
| **RB-12** | A suspicious chunk cluster appears | one source, probably a chat export; review the source and its ACL |
| **RB-13** | A merge was wrong | RR-H02: recreate the merged case and move its sources back; the merge event is append-only evidence |
| **RB-14** | Restore from backup | restore the dump, re-run §13, re-sync the buckets, then re-ingest anything newer than the dump — idempotent by sha256 |

---

## 13. Verifying an installation

Run these against a fresh database with the demo seed loaded. They are the same expectations TEST-15 TC-005 checks in Python, so a difference here is a real difference, not a rounding artefact.

```bash
psql -U postgres -d genbamemory <<'SQL'
\echo '--- 1. objects'
SELECT count(*) FILTER (WHERE table_schema='memory')    AS memory_tables,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='memory')                      AS memory_functions,
       (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal) AS triggers
  FROM information_schema.tables WHERE table_type='BASE TABLE';
-- expected: 40 tables, 56 functions, 35 triggers

\echo '--- 2. the ranking weights sum to 1.000'
SELECT sum(weight) FROM memory.rank_weight;

\echo '--- 3. Appendix A'
SELECT r.rank, cr.title, r.final_score, r.lex_score, r.lex_rank, r.vec_rank
  FROM memory.query_result r JOIN knowledge.case_record cr ON cr.id = r.case_record_id
 WHERE r.query_id = '00000000-0000-7000-8000-000000007001' ORDER BY r.rank;
-- expected: 1 #418 0.870 (lex 1.1323, lex rank 6, vec rank 1) | 2 #602 0.740 | 3 #331 0.610

\echo '--- 4. the ranking re-runs to the same numbers'
SELECT memory.rank_query('00000000-0000-7000-8000-000000007001');
SELECT rank, final_score FROM memory.query_result
 WHERE query_id = '00000000-0000-7000-8000-000000007001' ORDER BY rank;
-- expected: unchanged — 0.870 / 0.740 / 0.610

\echo '--- 5. AC-05: the restricted complaint, as an engineer and as a curator'
SELECT memory.case_card('00000000-0000-7000-8000-000000006688', 'engineer', ARRAY[]::text[]) IS NULL AS hidden,
       memory.case_card('00000000-0000-7000-8000-000000006688', 'curator',
                        ARRAY['quality_restricted']) IS NOT NULL AS visible;
-- expected: t, t

\echo '--- 6. AC-06: the flagged cause is suppressed'
SELECT cause_text IS NULL AS suppressed FROM memory.v_case_card
 WHERE case_record_id = '00000000-0000-7000-8000-000000006710';
-- expected: t

\echo '--- 7. AC-07: the interval is computed'
SELECT interval_months, confirmed_at IS NULL AS awaiting FROM memory.recurrence
 WHERE case_record_id = '00000000-0000-7000-8000-000000006733';
-- expected: 25, t

\echo '--- 8. AI-08: the chat export'
SELECT suspicious, suspicious_reason FROM knowledge.chunk
 WHERE id = '00000000-0000-7000-8000-000000008405';
-- expected: t, instruction-like text in an ingested document (SRS-15 AI-08)

\echo '--- 9. the gates'
SELECT kind, recall_at_5, mrr, narrative_accuracy, factual_accuracy, passed, investigate
  FROM memory.v_eval_gate;
-- expected: 0.833/0.632 passed t · 0.667/0.413 passed f investigate t · 0.875/0.958 passed t

\echo '--- 10. coverage and gaps'
SELECT memory.coverage_metrics();
SELECT count(*) FROM memory.knowledge_gaps();
-- expected: 4 gaps (#331, #688, #710, #733)

\echo '--- 11. worker_rw cannot touch GenbaGo or verification'
SET ROLE worker_rw;
SELECT has_table_privilege('knowledge.tm_segment', 'INSERT') AS tm_insert,
       has_table_privilege('memory.verification', 'INSERT')  AS verify_insert;
RESET ROLE;
-- expected: f, f
SQL
```

Then run the seed's probe section on its own. **All sixteen must fail**, each inside its transaction:

```bash
psql -U postgres -d genbamemory -f ../db/seed_demo.sql 2>&1 | grep -c '^ERROR'
# expected: 16
```

Sixteen errors is a pass. Fewer means a guard is missing; more means something above the probe section broke.
