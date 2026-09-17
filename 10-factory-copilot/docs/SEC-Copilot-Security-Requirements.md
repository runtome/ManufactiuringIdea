# Security Requirements Specification — Factory Copilot (Local AI Factory Copilot)

| Field | Value |
|---|---|
| Document ID | SEC-10-Copilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-17 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-10](../SRS-FactoryCopilot-Local-Multilingual-Assistant.md) · [SAD-10](SAD-Copilot-Software-Architecture.md) · [DDS-10](DDS-Copilot-Database-Design.md) · [API-10](../api/API-Specification.md) · [ICD-10](ICD-Copilot-Interface-Control.md) · [TEST-10](TEST-Copilot-Test-Plan.md) TS-2, TS-3, TS-9 · [OPS-10](OPS-Copilot-Deployment-Operations.md) · platform: [SEC-00](../../00-factorybrain-platform/docs/SEC-FactoryBrain-Security-Requirements.md) |

---

## 1. Scope and what is different here
Copilot is the one component every factory person can type into, and it sits on top of every data store the platform has. It is also the component whose output looks most authoritative. The threats are therefore about **what an answer can be made to contain**: another line's numbers, a fabricated figure, an operator's name, an instruction smuggled through an SOP, or a query that reads what it should not. And about **where an answer can go**: a share link, a Discord channel, an external model.

### 1.1 Security objectives
| # | Objective | Enforcement point |
|---|---|---|
| **O-1** | **Read-only.** Copilot has no write path into production, quality or ERP data. | no write tool can be enabled (`trg_tool_policy_read_only`); generated SQL only as `copilot_sql_ro` on views; no `action_proposal` path |
| **O-2** | **Grounded or withheld.** Every number traces to a tool result or a cited chunk; otherwise the answer does not leave. | evidence bundle (IF-56) + post-check (`trg_run_grounded`) |
| **O-3** | **Permissions at the tool layer, for every tool.** | scope predicate injected by the executor; `trg_tool_scope`; per-tool tests (NFR-05) |
| **O-4** | **Local by default.** No question or data leaves the LAN unless an admin recorded the decision. | `feature_flag` rows (`discord`, `external_model`) with `enabled_by/at/reason`; egress only for `discord-bot` |
| **O-5** | **Documents are data.** Instruction-like text in a retrieved document is never followed. | bundle-only composer input; chunk flagging; planner never sees chunk text |
| **O-6** | **Personal data and conversation privacy.** Names masked below a role; logs retained 1 year; export and delete on request. | `mask_names()`, `trg_turn_rules`; `purge_user_conversations()`; messages immutable |

## 2. Assets
| Asset | Sensitivity | Where |
|---|---|---|
| Production, defect, SPC, telemetry data reachable through tools | high — plant performance | sibling stores via IF-16; `core.*`, `vision.*`, `quality.*` |
| Documents (SOP, 8D, FMEA, manuals) | high — know-how, sometimes customer data | `knowledge.document/chunk`, MinIO `docs/` |
| Defect images | medium–high | `vision.inspection`, MinIO `images/` |
| Conversations, runs, evidence bundles | high — they contain the data above and the user's questions | `agent.*`, `copilot.turn` |
| Operator names | personal data | tool results; masked in answers |
| Share exports | high — leave the UI | MinIO `exports/shares/` |
| Tool registry, policy, whitelist, aliases, curated Q&A, prompts | integrity-critical — they shape every answer | `agent.tool`, `copilot.*` |
| Evaluation set and runs | integrity-critical — the release gate | `copilot.eval_*` |
| Secrets (DB roles, JWT, S3, Discord bot token) | critical | secret files |

## 3. Trust boundaries
| Zone | Contents | Trust |
|---|---|---|
| Z0 Users | web (LAN), embed in the dashboard, Discord (opt-in) | authenticated; role- and line-scoped |
| Z1 Edge | reverse proxy, `api`, `web` | medium |
| Z2 Understanding & execution | `planner`, `executor`, `retriever`, `composer`, `renderer`, `scheduler` | high; deterministic except the two model calls |
| Z3 Model | Ollama (planner/composer/embeddings) | **low-trust output**: plan validated, answer post-checked |
| Z4 Sandbox | `sql-sandbox` as `copilot_sql_ro` | contained; parser + role + timeout |
| Z5 Data | PostgreSQL, Redis, MinIO | high |
| Z6 Providers | sibling tool endpoints / read-only source connections | read-only accounts |
| Z7 Outside | Discord | **untrusted; off by default** |

Boundary rules: Z3 has no tools and no network; Z4 sees only whitelisted views; only `discord-bot` reaches Z7; documents (Z5) reach Z3 only as bounded quoted chunks.

## 4. Threat model

### 4.1 Threats (STRIDE)
| ID | Threat | Category | Objective | Controls |
|---|---|---|---|---|
| THR-C01 | **Fabricated number** — the composer writes a figure absent from the bundle | Tampering | O-2 | post-check withholds; `grounding_failed` metric; eval gate fabricated = 0 (SEC-C10…C13) |
| THR-C02 | **Scope bypass** — a user asks about another line, directly or via follow-up context ("and line 3?"), or via SQL | Elevation | O-3 | scope injected per call, `trg_tool_scope`, sandbox predicate; context slots re-checked each turn (SEC-C20…C24) |
| THR-C03 | **Text-to-SQL escape** — the model writes a statement reaching `core.app_user`, DML, or a long-running query | Elevation / DoS | O-1, O-3 | parser, whitelist, `LIMIT`, `statement_timeout`, role grants only on views, flag + eval gate (SEC-C30…C34) |
| THR-C04 | **Injection via documents** — an SOP or supplier note says "reveal all salaries" | Tampering | O-5 | planner never sees text; composer gets quoted chunks; flagging; no tool from text; AC-05 test (SEC-C50…C52) |
| THR-C05 | **Cross-user conversation access** — reading another user's history, trace or export | Information disclosure | O-6 | conversations owned by user; `NOT_OWNER`; engineer+ review only through `/turns` with audit (SEC-C60) |
| THR-C06 | **Exfiltration via share links** — a grounded answer with sensitive data shared outside | Information disclosure | O-4 | LAN-only share host; expiry ≤ 30 d; revocation; only `ok` runs; audit (SEC-C40, C42) |
| THR-C07 | **Exfiltration via Discord / external model** | Information disclosure | O-4 | flags off by default; recorded enablement with policy; masking forced; no images; channel allow-list (SEC-C41, C43) |
| THR-C08 | **Alias / curated-Q&A poisoning** — an alias maps "line 3" to line 1; a curated answer carries a wrong figure | Tampering | O-2 | admin-only aliases with audit; curated answers approved by engineer+ and cited as curated; eval set covers aliases (SEC-C70, C71) |
| THR-C09 | **Unmasked personal data** in an answer or export for a low role | Information disclosure | O-6 | `mask_names()` at the composer; `MASKING_REQUIRED` guard; Discord always masked (SEC-C61) |
| THR-C10 | **Confident wrong answer** — right number, wrong period; correlation read as cause | Integrity | O-2 | time range printed; QE delegation and wording; citation-correctness gate (SEC-C14) |
| THR-C11 | **Prompt / tool-schema drift** changing behaviour without review | Tampering | O-2 | versioned prompts with checksums; registry versions; eval run gate (SEC-C12, C72) |
| THR-C12 | **Resource exhaustion** — many long questions saturate the GPU | DoS | availability | tool-call cap, per-turn wall clock, per-user rate limit, visible queue (SEC-C80) |
| THR-C13 | **Log privacy** — traces retained forever; a user cannot delete | Privacy | O-6 | 365-day retention; export/delete endpoints; purge audited (SEC-C62, C63) |

### 4.2 The attack worth walking through — "and line 3?"
An inspector scoped to line 1 asks "what was the defect rate yesterday?" (answered for L1), then "and line 3?". The planner reuses the slots and resolves L3. The executor injects the caller's scope: `lines = ["L1"]` — the request for L3 is *narrowed*, not passed through, and the bundle carries the note "line 3 requested, caller scope [L1]". The composer answers that line 3 is outside the user's permissions and shows line 1. If a bug let the executor pass `["L3"]`, `trg_tool_scope` refuses the `agent.tool_call` row and the turn ends with `SCOPE` — no L3 rows were read because the tool never ran. If the user switches to SQL ("select defect rate from kpi where line = 'L3'"), the sandbox appends `AND line_code = ANY('{L1}')`, so the query returns nothing about L3. Residual: aggregates that include the user's line together with others (a plant total) are permitted by design and could let a user infer another line's contribution — RR-C03.

## 5. Security requirements

### 5.1 Read-only (O-1)
| ID | Requirement | Verification |
|---|---|---|
| SEC-C01 | No tool of kind `write` SHALL be enabled for Copilot; the policy table SHALL refuse it. | TC-003 probe 7, TC-032 |
| SEC-C02 | Generated SQL SHALL execute only as `copilot_sql_ro`, which has `SELECT` on the whitelisted views and nothing else. | TC-003, TC-040, TC-113 |
| SEC-C03 | Copilot SHALL have no code path that creates an `action_proposal` or calls a sibling's write endpoint. | TC-085 (code review), TC-110 |

### 5.2 Groundedness (O-2)
| ID | Requirement | Verification |
|---|---|---|
| SEC-C10 | The composer SHALL receive only the schema-validated evidence bundle and the prompt template. | TC-006, TC-058 |
| SEC-C11 | An answer containing a numeric token absent from the bundle SHALL be withheld (`422 GROUNDING_FAILED`), never returned with a warning. | TC-003 probe 1, TC-055 |
| SEC-C12 | Prompts, model tag, embedding version and tool-schema version SHALL be recorded on every run; any change SHALL trigger an evaluation run before release. | TC-058, TC-070 |
| SEC-C13 | The evaluation gate SHALL block release on any fabricated number. | TC-070 |
| SEC-C14 | Every quantitative answer SHALL print its resolved time range and cite its sources; cause questions SHALL be delegated with QE's wording. | TC-014, TC-053 |

### 5.3 Permissions (O-3)
| ID | Requirement | Verification |
|---|---|---|
| SEC-C20 | Every tool call SHALL carry the caller's line scope as an argument predicate; the database SHALL refuse a call outside it. | TC-003 probe 5, TC-030 |
| SEC-C21 | Follow-up context SHALL be re-scoped on every turn; slots never widen permissions. | TC-031 |
| SEC-C22 | Every tool SHALL have a scope test in TS-2 before it is enabled (NFR-05). | TC-033 |
| SEC-C23 | Document retrieval SHALL apply the document ACL as a predicate; `/sources/{id}` SHALL apply the same. | TC-045, TC-034 |
| SEC-C24 | Copilot's tool role SHALL not read `core.app_user` or `core.user_line_scope` (`agent_ro` revokes). | TC-003 |

### 5.4 Sandbox (O-1, O-3)
| ID | Requirement | Verification |
|---|---|---|
| SEC-C30 | Generated SQL SHALL be parsed; only a single `SELECT`/`WITH` without DML/DDL/comments/forbidden functions SHALL pass. | TC-003 probes 2–4, TC-041 |
| SEC-C31 | Only whitelisted relations SHALL be referenced; the whitelist SHALL never contain users, scope or audit tables (CHECK). | TC-042 |
| SEC-C32 | `LIMIT ≤ 1000` and `statement_timeout = 5 s` SHALL apply to every execution. | TC-043 |
| SEC-C33 | Text-to-SQL SHALL stay disabled until a SQL evaluation run ≥ 85 % on ≥ 30 questions; disabling SHALL be immediate. | TC-003 probe 11, TC-044 |
| SEC-C34 | Every proposed statement SHALL be stored with its verdict, whether or not it executed. | TC-040 |

### 5.5 Locality (O-4)
| ID | Requirement | Verification |
|---|---|---|
| SEC-C40 | Model, database, object store, planner, executor, retriever, composer, sandbox SHALL run on a network with no egress. | TC-004, TC-111 |
| SEC-C41 | Discord SHALL be off by default; enabling SHALL record who/when/why and a policy: masking on, no images, no document text, channel allow-list, verified bindings only. | TC-090, TC-091 |
| SEC-C42 | Share links SHALL be served on the LAN only, expire ≤ 30 days, be revocable, and exist only for grounded answers; every open SHALL be audited. | TC-003 probe 6, TC-064 |
| SEC-C43 | An external model provider SHALL be a recorded feature flag; when off, no outbound model call SHALL exist in the configuration. | TC-007, TC-111 |

### 5.6 Documents are data (O-5)
| ID | Requirement | Verification |
|---|---|---|
| SEC-C50 | The planner SHALL never receive document text; the composer SHALL receive chunks as bounded quoted data with citation metadata. | TC-058, TC-006 |
| SEC-C51 | Instruction-like text in a chunk SHALL be flagged on ingest and excluded from bundles; no tool call SHALL result from chunk text. | TC-112, TC-046 |
| SEC-C52 | The AC-05 corpus (EN/JA/TH injections in SOPs, notes and uploads) SHALL produce zero policy violations in every evaluation run. | TC-112 |

### 5.7 Privacy (O-6)
| ID | Requirement | Verification |
|---|---|---|
| SEC-C60 | Conversations, traces and exports SHALL be readable only by their owner; engineer+ review through `/turns` SHALL be audited. | TC-060, TC-110 |
| SEC-C61 | Operator names SHALL be masked below the configured role; Discord turns SHALL always be masked; exports SHALL carry the masked text. | TC-003 (turn rule), TC-035, TC-064 |
| SEC-C62 | Conversation logs SHALL be retained 365 days and deletable/exportable by the user; deletion SHALL be audited and complete (messages, runs, tool calls, turns, shares, pins). | TC-062, TC-063 |
| SEC-C63 | Messages SHALL be immutable; only the purge path deletes them. | TC-003 probe 9 |

### 5.8 Integrity of the answer machinery
| ID | Requirement | Verification |
|---|---|---|
| SEC-C70 | Aliases, masking rules, whitelist, tool policy and flags SHALL be admin-only and audited. | TC-110, TC-116 |
| SEC-C71 | Curated answers SHALL be approved by engineer+ and cited as curated; the eval set SHALL include alias and curated-answer questions. | TC-003 probe 8, TC-066 |
| SEC-C72 | The evaluation set SHALL be versioned; results SHALL store the bundle per question for audit. | TC-070, TC-114 |
| SEC-C80 | Per-user rate limits, the 5-call/60 s budget and a visible queue SHALL bound resource use; a queued user SHALL see the position. | TC-101, TC-103 |
| SEC-C81 | Containers non-root, read-only root fs, `cap_drop ALL`, `no-new-privileges`; secrets in files (0400); ports on `BIND_ADDR`. | TC-004, TC-113 |

### 5.9 RBAC matrix
| Action | Viewer | Inspector | Engineer | Manager | Admin |
|---|---|---|---|---|---|
| Ask; own conversations; feedback; save/pin; share own grounded answers | ✅ (scoped) | ✅ | ✅ | ✅ | ✅ |
| Show the numbers / show the SQL | ✅ | ✅ | ✅ | ✅ | ✅ |
| Image lookup; machine telemetry; QE hypotheses | ❌ | ✅ | ✅ | ✅ | ✅ |
| See unmasked operator names | ❌ | ❌ | ❌ | ✅ | ✅ |
| Review flags; create/approve curated answers; re-run SQL; review `/turns` | ❌ | ❌ | ✅ | ✅ | ✅ |
| Aliases, masking, whitelist, tool policy, flags, config, Discord, eval runs | ❌ | ❌ | ❌ | ❌ | ✅ |
| Write to production/quality/ERP through Copilot | **nobody** | | | | |

## 6. Security testing
| Suite | Content |
|---|---|
| TS-0 | probes 1–11; grants (`copilot_sql_ro`, `agent_ro`); compose isolation; secrets; config negatives (flags, whitelist) |
| TS-2 | per-tool scope tests; follow-up context re-scoping; masking; document ACL |
| TS-3 | SQL corpus: DML, DDL, comments, `pg_sleep`, `core.app_user`, missing `LIMIT`, CTE tricks, unicode homoglyphs, stacked statements |
| TS-9 | RBAC sweep; egress from every container; AC-05 injection corpus; share-link expiry/revocation; Discord policy; purge completeness; audit reconstruction |
| Pen test before go-live | goals: read another line's rows through any path; get an ungrounded number into a returned answer; run a non-whitelisted query; exfiltrate a document via Discord; read another user's conversation |

## 7. Incident procedures
| Incident | First actions |
|---|---|
| Ungrounded number found in a returned answer | freeze `/chat` for the affected intent (`ANSWERS_ENABLED=false` for that intent); pull `agent.run.grounding_json`; determine whether the post-check was bypassed (direct SQL? outcome set without check?); re-run the eval set; notify the users who received it |
| Out-of-scope data in an answer | `copilot.v_scope_audit` for the run; if `in_scope = false` rows exist the trigger was bypassed → DB incident; rotate the executor's credential; review shares of the turn and revoke |
| Generated SQL executed outside the whitelist | `copilot.v_sql_audit`; disable `text_to_sql`; check the role's grants (`\dp core.v_kpi_daily`) and `pg_stat_statements` |
| Injected document reached the composer unflagged | quarantine the source; add the phrase to `injection_suspect()`; re-index; verify no tool call resulted |
| Discord exfiltration suspected | disable the flag; revoke the bot token; export the channel's turns from `copilot.turn` (`channel = discord`) |
| Share link leaked | revoke; `audit.log` shows every open (IP, time); rotate the share signing key |

## 8. Residual risks
| ID | Risk | Acceptance |
|---|---|---|
| RR-C01 | A grounded answer can still mislead (wrong period, correlation as cause) | time range printed, delegation, citation gate; accepted |
| RR-C02 | Text-to-SQL joins that are syntactically safe but semantically wrong | typed tools first; flag + eval gate; visible SQL; accepted |
| RR-C03 | Plant-level aggregates let a scoped user infer other lines' contribution | by design; documented in UM-10; accepted |
| RR-C04 | A novel injection phrasing not matched by the flagging patterns | flagging is defence in depth — the bundle-only composer input is the primary control; accepted |
| RR-C05 | Thai/Japanese retrieval misses a relevant document | hybrid + aliases + eval per language; accepted |
| RR-C06 | Latency under a vision batch on the shared GPU | queue visibility; accepted |

## 9. Traceability
| SRS-10 | SEC |
|---|---|
| C-01 | O-1, SEC-C01…C03 |
| C-02, AI-04, AC-06 | O-2, SEC-C10…C14, THR-C01 |
| C-03, FR-22, NFR-05, AC-04 | O-3, SEC-C20…C24, THR-C02 |
| C-04, NFR-04 | O-4, SEC-C40…C43, THR-C06, THR-C07 |
| C-05, FR-08, AI-06, AC-07 | SEC-C30…C34, THR-C03 |
| AI-07, AC-05 | O-5, SEC-C50…C52, THR-C04 |
| FR-26, NFR-07 | O-6, SEC-C60…C63, THR-C05, THR-C09, THR-C13 |
| FR-25, FR-03 | SEC-C70, C71, THR-C08 |
| AI-05, AI-08, NFR-03 | SEC-C72, SEC-C80, THR-C11, THR-C12 |

## Appendix A — Review checklist for a Copilot change
- Does the change let the model see anything but the question, tool schemas and the evidence bundle? It must not.
- Does it add a number to an answer that is not a bundle fact? Add a tool or a derived fact instead.
- Does it add a tool? Add its scope test, its policy row (read only) and re-run the evaluation set.
- Does it touch the sandbox, the whitelist or `copilot_sql_ro`? Re-run TS-3 and probes 2–4, 11.
- Does it send anything outside the LAN? Only through a recorded flag with a policy.
- Does it change what a viewer/inspector can see (masking, ACL, scope)? Re-run TS-2 and TC-110.
