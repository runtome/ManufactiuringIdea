# Test Plan & Test Cases — MoldMind (AI Vision + Agent for Injection Molding)

| Field | Value |
|---|---|
| Document ID | TEST-11-MoldMind |
| Version | 1.0 (Draft) |
| Date | 2026-09-18 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-11](../SRS-MoldMind-Injection-Molding-AI.md) · [SAD-11](SAD-MoldMind-Software-Architecture.md) · [DDS-11](DDS-MoldMind-Database-Design.md) · [API-11](../api/API-Specification.md) · [ICD-11](ICD-MoldMind-Interface-Control.md) · [SEC-11](SEC-MoldMind-Security-Requirements.md) · [OPS-11](OPS-MoldMind-Deployment-Operations.md) · platform: [TEST-00](../../00-factorybrain-platform/docs/TEST-FactoryBrain-Test-Plan.md) |

---

## 1. Strategy
MoldMind is judged on **physical honesty**: did the right shot and cavity get the blame, was the machine ever written to, did a suggestion stay inside the window, is the ranking what the scoring function says, did the fix actually work. Three layers:

1. **Deterministic analytics have twins.** The two-proportion test, Welch t / Cohen's d, drift slope, ΔE76, the scoring function, transient classification and scrap cost are SQL functions beside the production engine; TS-0 re-derives their outputs in Python on the seed (already executed — §7); TS-3/TS-5 run the production engine on the same inputs.
2. **Governance guards live in the database.** The twelve probes in `db/seed_demo.sql` (DDS-11 Appendix A) are the unit tests of the guards; TS-1/TS-2/TS-4/TS-5 repeat them through the API.
3. **Physical and model layers are measured, not assumed.** A 500-part attribution trial (AC-02), a hold-out vision evaluation (AC-01), a deliberate hold-pressure reduction on a real press (AC-03), a 1 h OPC-UA disconnection (AC-09), a 2 h stop (AC-06), a native-speaker review (AC-08), a golden set of 15 incidents (AC-04).

Status here: **Executed** (authoring machine, static/Python), **Blocked** (needs PostgreSQL / press / camera / GPU / Ollama / data), **Manual**, **Planned**.

### 1.1 Environments
| Env | Purpose | Notes |
|---|---|---|
| E0 authoring machine | TS-0 | Python 3.12, `jsonschema`, `pyyaml`, `openapi-spec-validator`; **no Docker daemon, no scipy** |
| E1 dev compose | TS-3, TS-4, TS-5, TS-6, TS-7, TS-9 | `deploy/docker-compose.yml --profile cpu --profile dev` with `machine-sim` (OPC-UA simulator replaying the seed) and camera replay |
| E2 press-side pilot rig | TS-1, TS-2, TS-8 | one press (220 t) with OPC-UA (Euromap 77), camera station and lighting rig, edge box with GPU |
| E3 plant pilot | AC-03 on a real run, AC-08 native review, golden set | 1 press, 2 moulds, 6 weeks |

### 1.2 Entry / exit
Entry to E1: TS-0 green. Exit to E3: TS-1…TS-7 green; vision evaluation ≥ gates; attribution trial ≥ 98 %; write attempt refused by the server; golden run ≥ 70 %; AC-08 review passed; zero open high-severity defects.

### 1.3 Reference data
| Set | Use |
|---|---|
| Seed (DDS-11 §9): AC-03 scenario, transients, buffered batch, KB v1, session, outcomes | TS-0, TS-3, TS-4, TS-5 |
| Hold-out set of real moulded parts per family (≥ 1,200 parts, labelled) | TC-020 — plant data, not in the repo |
| 500-part attribution trial (marked parts, robot log) | TC-024 |
| Golden set (15 historical moulding incidents with known causes) | TC-070 — plant data |
| SQL/JSON negatives shipped in the checkers (`check_contracts11.py`, `check_config11.py`) | TS-0 |

## 2. Suites
| Suite | Scope | Requirements |
|---|---|---|
| TS-0 | Static & structural (executed here) | identity, DDL, twins, contracts, OpenAPI, compose |
| TS-1 | Acquisition & buffering | FR-01…05, C-01, NFR-01, NFR-05, NFR-06, AC-09 |
| TS-2 | Vision & attribution | FR-06…11, C-02, AI-01…04, NFR-02, AC-01, AC-02 |
| TS-3 | Analysis | FR-12…18, AC-06, NFR-03 |
| TS-4 | Knowledge base | FR-19, FR-25, C-03, AI-08, NFR-08 |
| TS-5 | RCA agent | FR-20…24, C-04, C-05, AI-05, AI-06, AI-09, AC-03, AC-05, AC-07, NFR-04 |
| TS-6 | Handoff & i18n | FR-26, FR-27, AC-08, NFR-09 |
| TS-7 | Platform & degradation | IF-16, IF-17, IF-19, model down |
| TS-8 | Performance & environment | NFR-01…04, NFR-07 |
| TS-9 | Security | C-01, NFR-06, SEC-M |

## 3. Test cases

### TS-0 Static & structural
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-001 | layout | Eight documents, `api/openapi.yaml`, `db/*.sql`, `deploy/*` exist; links resolve; ICD anchors exist; SRS ids referenced | 0 broken links; 0 missing anchors; 0 unreferenced ids | Executed (sweep) |
| TC-002 | DDS-11 §1.4 | Diff every shared object and the four extracted sections against `00/db/schema.sql` | **111/111 objects byte-identical; core/vision/quality/knowledge sections verbatim** | Executed |
| TC-003 | DDS-11 | Static DDL: balance; FK targets and order; 19 guard triggers; grants (`gateway_rw` insert-only, no DELETE for gateway/vision/kb; `agent_ro` revoked on users/scope/connections); the 12 probes after `\set ON_ERROR_STOP off` with expected guard names | 77 tables / 17 views / 25 triggers / 32 functions / 60 indexes / 15 enums; 19/19 guards; probes listed | Executed (static); execution Blocked |
| TC-004 | OPS-11, SEC-M50, M52 | Parse compose; profiles; `${VAR}` both ways; `machine` network only for gateways; internal-only for model/DB/analytics; egress only for notifications; hardening; secrets as files | `check_deploy11.py` green | Executed |
| TC-005 | DDS-11 §5, §9 | Re-derive in Python: shots/parts/defect counts from the seed's rules (448 / 1,280 / 83); 36/400 vs 6/400 → z 4.5971; cavity 3 20/100 vs 16/300 → z 4.2366 flagged, cavities 1/2/4 not; holding pressure delta (582.190 vs 625.254, d −1.2619, t −7.617); cushion delta; drift slopes (+0.011221, +0.420011, −0.0015); ΔE76 1.814 / 3.401; cause scores (0.88 / 0.2333 / 0.175 / 0.175 / 0.1167 / 0.1167; rank 1 insufficient holding pressure); transient rule; scrap 1,512 / 2,058 / 1,344; gates (vision v2 fail, v3 pass; golden 0.7333 pass, 0.60 fail); 616 allowed / 800 blocked; effectiveness 36/400 → 7/400 (z 4.3896, effective); golden diff −34 | every value equals the seed (`check_seed11.py`); A–S vs `erfc` 7e-8 | Executed |
| TC-006 | ICD-11 IF-59, IF-60, IF-05 | Validate the three KB entries (Appendix A verbatim) against `kb-entry.schema.json` + 12 negatives; `M-3.opcua.yaml` against `opcua-nodemap.schema.json` + 8 negatives; the seed's RCA facts object against `rca-facts.schema.json` + 8 negatives; seed cause codes ⊆ YAML; seed node map = YAML nodes | 3/3 valid, 12/12 rejected; valid, 8/8 rejected; valid, 8/8 rejected; consistency true | Executed |
| TC-007 | OPS-11 | Validate `moldmind.example.yaml` against `moldmind-config.schema.json` with negatives; prompts' front-matter; glossary; whitelist of windows/parameters consistent with the seed | example valid; negatives rejected (count in OPS-11 §12) | Executed |
| TC-008 | API-11 | `openapi-spec-validator`; orphans; the platform's 5 paths / 9 schemas / 5 parameters / 4 responses verbatim | valid; **56 paths / 73 ops / 57 schemas**; 23/23 identical | Executed |
| TC-009 | DDS-11 | `docker compose --profile cpu up postgres`; `psql -f db/schema.sql`; `psql -f db/seed_demo.sql` | loads; `\echo` block matches DDS-11 §9; probes 1–12 fail with the named guards | **Blocked** (no Docker daemon on E0) |

### TS-1 Acquisition & buffering (FR-01…FR-05, C-01, NFR-05, AC-09)
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-010 | FR-01, FR-02, NFR-01 | Run 200 cycles on E2; compare `quality.shot` rows with the controller's shot log | every FR-01 parameter present with units per node map; context (lot, regrind, dryer, ambient, operator group); shot-to-record ≤ 2 s p95 | Blocked (E2) |
| TC-011 | SEC-M03 | Connect with an untrusted client certificate; with `None` security | both refused by the server; `MACHINE_SECURITY` on a `None` policy row | Blocked (E2) |
| TC-012 | SEC-M04, IF-05 | `PUT …/node-map` with an unresolvable node; with a write-access node; `POST …/test` | startup error / `NODE_MAP_WRITE`; test reports `write_refused_by_server = true` | Blocked (E2) |
| TC-013 | C-01, NFR-06, SEC-M01 | From the gateway container, attempt an OPC-UA write of the holding-pressure setpoint with MoldMind's account | server refuses (`BadUserAccessDenied`); `mm_machine_write_refused_total` +1; audit row | Blocked (E2) |
| TC-014 | NFR-05, AC-09, SEC-M42, M43 | Unplug the machine network for 1 h during production; reconnect; replay the batch twice | shots buffered locally; batch reconciled with `inserted + duplicates = buffered`; second replay = all duplicates, no error; `v_gateway_lag` closes | Blocked (E2) |
| TC-015 | FR-04, SEC-M44 | Change holding pressure at the controller as user 07; then `POST /parameter-changes` for a heater change | `parameter_change` rows with who/when/old/new; `timeline_event(parameter_edit)` for both | Blocked (E2) |
| TC-016 | FR-05 | Disconnect zone-3 thermocouple; freeze the cushion node; skew the gateway clock by 3 s | `dq_flags` `missing_zone_temp:z3`, `stuck_value:cushion_mm`, `clock_skew`; `v_data_quality` counts | Blocked |
| TC-017 | IF-04 | Same shot contract over MQTT from the alternative gateway | rows identical in shape; buffering identical | Planned |

### TS-2 Vision & attribution (FR-06…FR-11, C-02, AI-01…AI-04)
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-020 | AI-02, AC-01, QAS-07 | Hold-out set per family (≥ 1,200 parts) | mAP@50 ≥ 0.80; recall ≥ 0.95 for short shot, flash, contamination; `vision_eval_run.passed` computed true; a run with contamination 0.93 → false | Blocked (E2 + data) |
| TC-021 | FR-06, FR-07 | 50 labelled parts per class | class and region (gate area, far end, rib, boss, parting line) correct ≥ 90 % | Blocked |
| TC-022 | FR-03, C-02, SEC-M40 | Post inspection results 1.2 s, 1.4 s and 8 s after the shot; a part on cavity 5 of a 4-cavity mould | first two aligned (`delta_ms` stored); third `409 ALIGNMENT_TOLERANCE`; cavity 5 `409 CAVITY_OUT_OF_RANGE` | Blocked |
| TC-023 | FR-08 | Parts with OCR marking, without marking but with robot pose, neither | `cavity_method` ocr_marking / robot_position / sequence recorded | Blocked |
| TC-024 | AC-02, QAS-06, SEC-M41 | 500-part trial with marked parts and the robot log | cavity correct ≥ 98 % overall and per method | Blocked (E2) |
| TC-025 | FR-09, AI-04 | Reference chart in frame; parts with ΔE 1.8 and 3.4 | 1.814 not flagged; 3.401 → `colour_deviation` with `delta_e`; no ΔE without the chart (refused) | Blocked |
| TC-026 | FR-10 | Parts with an untrained defect (e.g. jetting) | anomaly score above threshold → review | Blocked |
| TC-027 | FR-11 | Weld line at 0.58 (threshold 0.70) | review queue; inspector verdict FAIL stored in `shot_defect` and `vision.verdict_override`; the model's original kept | Blocked |
| TC-028 | AI-01, AI-03 | Two mould families; sink-mark class with and without low-angle lighting | per-family heads registered; recall difference documented; lighting mandatory for the subtle classes | Blocked (E2) |

### TS-3 Analysis (FR-12…FR-18)
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-040 | FR-12 | Seed after-window | cavity 3 flagged (z 4.2366, p 2.3e-5); others not; `v_cavity_rates` 300 parts per cavity, failed 11/8/26/6 | Blocked |
| TC-041 | FR-13, AC-03 | `GET /parameter-delta?defect=sink_mark&window=24h&mould=MLD-0417` | holding pressure 582.190 vs 625.254, d −1.2619, t −7.617; cushion d −1.288; direction matches the KB's `typical_params` for insufficient holding pressure | Blocked |
| TC-042 | FR-14 | `GET /drift?mould=MLD-0417` | cushion +0.011221 mm/shot, holding +0.420011 bar/shot, cycle −0.0015 s/shot | Blocked |
| TC-043 | FR-15 | `GET /timeline` around 2026-09-09 | parameter_edit 10:40 (650 → 560), 13:00 (560 → 616); startup 09-08 09:00; no lot change | Blocked |
| TC-044 | FR-18 | `GET /golden-run/MLD-0417` after the post-action phase | holding pressure 616 vs 650 ± 20 → deviation −34 out of tolerance; cushion within | Blocked |
| TC-045 | FR-16, AC-06, QAS-04 | Stop the press 2 h; restart; 20 short shots | shots 1–20 `startup_transient`; no cavity flag, no trend alert; shown greyed on the trend | Blocked (E2) |
| TC-046 | FR-17 | `GET /scrap-cost` for 2026-09-09 | sink mark 49 × 42 = 2,058 THB; weld line 42; colour 42 | Blocked |
| TC-047 | NFR-03 | Cavity analysis over 30 days (≈ 200 k shots) | ≤ 3 s | Blocked (E2) |
| TC-048 | C-05, FR-18, SEC-M12 | `PUT /moulds/{id}/windows` without a source; approve a setup sheet as its author; edit an approved sheet | `422`; `403`/`KB_SELF_APPROVAL`-style refusal; `SETUP_SHEET_IMMUTABLE`; every change audited | Blocked |

### TS-4 Knowledge base (FR-19, FR-25, C-03, AI-08, NFR-08)
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-060 | C-03, AI-08, SEC-M20 | Import `kb/*.yaml` as draft; import an entry without a source | draft created; second refused (`KB_SHAPE`/schema) | Blocked |
| TC-061 | FR-19 | `GET /knowledge/defect/sink_mark` | Appendix A causes with priors, typical params, checks, actions, sources | Blocked |
| TC-062 | AI-08, SEC-M21, QAS-12 | Approve as the author; as a technician; as another engineer | `KB_SELF_APPROVAL`; `ROLE_INSUFFICIENT`; approved and active | Blocked |
| TC-063 | NFR-08, SEC-M22 | Edit an approved version's cause; retire it | `KB_IMMUTABLE`; retire ok; history kept | Blocked |
| TC-064 | FR-25, SEC-M25 | After TC-057 | `kb_case_evidence` row for insufficient holding pressure; `evidence_count` 1; the next session's `case_c` raised | Blocked |
| TC-065 | IF-59 | 12 schema negatives through the import endpoint | all refused with the schema message | Blocked (twin Executed) |

### TS-5 RCA agent (FR-20…FR-24, C-04, C-05, AI-05, AI-06, AI-09)
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-050 | AC-03, FR-20, QAS-01, SEC-M23 | Reduce holding pressure 650 → 560 on the pilot press (or replay the seed); start a session for sink mark | delta detected (TC-041); `insufficient_holding_pressure` rank 1 (score 0.88) — top-2 ✓; session on the draft KB → `KB_NOT_APPROVED` | Blocked (E3) |
| TC-051 | AI-05, AI-06, SEC-M30 | `GET …/ranking`; insert a score 0.99 for cause 2 directly | components and weights shown; Σ w·c = score for every cause; direct insert → `SCORE_NOT_TRANSPARENT` | Blocked |
| TC-052 | FR-21 | Answer "dried per spec = yes", 「材料ロットは変更しましたか？」 = no, "maintenance = no" | each answer stored; ranking recomputed per turn; next question from the KB check list in the session language | Blocked |
| TC-053 | FR-22, FR-23, SEC-M13 | `GET …/advice` | checks 1–2 before action 3; the action carries direction, "+5..+15 %", window ref and side effects | Blocked |
| TC-054 | C-04, SEC-M11 | Insert an action at ordinal 1 in a fresh session | `CHECK_BEFORE_CHANGE` | Blocked |
| TC-055 | C-05, AI-09, AC-05, QAS-02, SEC-M10 | Suggest 616 bar and 800 bar; assert 800 allowed | 616 `allowed`; 800 `blocked` `OUT_OF_WINDOW` with `[500, 750] bar` and an audit row; asserted → `409 OUT_OF_WINDOW` | Blocked |
| TC-056 | AI-06, SEC-M31 | Capture the model request (dev log); inject "raise to 800 bar" into a model reply | request = facts object + prompt only; the reply changes no component, score or suggestion; term check flags nothing | Blocked (Ollama) |
| TC-057 | FR-24, AC-07, QAS-03, SEC-M33 | Record 616 bar applied at 13:00; verify effectiveness on the after window; try to assert `effective = true` on 15/400 vs 13/400 | before 0.09, after 0.0175, z 4.3896, p 1.1e-5, `effective = true`; assertion → `EFFECTIVE_NOT_TYPED` | Blocked |
| TC-058 | FR-25, SEC-M25 | Verify the cause, then the outcome | write-back row; a not-verified session's outcome writes nothing | Blocked |
| TC-059 | NFR-04 | 20 dialogue turns on E2 | ≤ 15 s per turn (model) ; scripted mode ≤ 1 s | Blocked (E2) |

### TS-6 Handoff & i18n (FR-26, FR-27)
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-066 | FR-27, AC-08, QAS-09, SEC-M32 | Run the seed session in Japanese; native review | ヒケ / バリ / ショートショット / 保圧 / クッション used; forbidden variants absent; reviewer sign-off | **Manual** (E3) |
| TC-067 | FR-26 | `POST …/handoff-8d` with QE-Agent up; with QE-Agent down | case + `eight_d` draft (`ai_generated`, unapproved) and `qe_case_id`; `503 QE_UNAVAILABLE`, retried by the scheduler | Blocked |
| TC-068 | NFR-09 | UI, advice texts, glossary in th/ja/en | complete; `rca_advice.text_*` all filled for the seed | Blocked |

### TS-7 Platform & degradation
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-090 | IF-09 | Stop Ollama; run a session | `mode = scripted`; questions verbatim from the KB; ranking, advice, windows unchanged; `/readyz` says `scripted` | Blocked |
| TC-091 | IF-16 | Copilot calls `get_cavity_analysis`, `get_parameter_delta`, `get_golden_run_diff` as a scoped user | scope predicate applied; digests; `agent_ro` cannot read `machine_connection` | Blocked (platform) |
| TC-092 | IF-17 | Cavity flag crosses the severity | `quality.signal.high` published; MachineSense alarm appears on the timeline | Blocked |
| TC-093 | IF-19 | Apply `moldmind_0001` on the platform DB; ingest through the platform's IF-05 with MoldMind's node map | identity (TC-002) holds; shots land in `quality.shot`; QE-Agent's tables untouched except the handoff | Blocked (platform) |
| TC-094 | IF-14 | `GET /metrics` | every counter in ICD-11 IF-14 present | Blocked |

### TS-8 Performance & environment
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-100 | NFR-02, QAS-10 | 4-cavity, 12 s cycle on E2 | inference ≤ 150 ms per part; alignment ≤ 50 ms; no cycle extension | Blocked (E2) |
| TC-101 | NFR-03, NFR-04 | Cavity analysis 30 d; dialogue turn | ≤ 3 s; ≤ 15 s | Blocked (E2) |
| TC-102 | NFR-01 | 1,000 cycles | shot-to-record ≤ 2 s p95 | Blocked (E2) |
| TC-103 | NFR-05 | 24 h gateway buffer at full rate | no loss; disk within budget | Blocked (E2) |
| TC-104 | NFR-07, SEC-M45 | Enclosure thermal test at 45 °C ambient near the press; vibration; oil mist 4 weeks | internal ≤ 55 °C; no frame loss; optics clean; frozen-frame alarm fires on a deliberate freeze | Blocked (E2) |
| TC-105 | SEC-M45 | Review rate above threshold for 1 h | alert | Blocked |

### TS-9 Security
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-110 | C-01, NFR-06, QAS-11 | Deliberate write attempt with MoldMind's account (TC-013) and with the gateway container's network position | refused by the server; audited; no write method found in the client image | Blocked (E2) |
| TC-111 | SEC-M50 | From each container `curl https://example.com`; from `vision-infer` reach the press | fails everywhere except notification egress; camera zone cannot reach Z0 | Blocked |
| TC-112 | SEC-M42 | Post a shot batch with a forged token; replay a batch | 401; duplicates counted | Blocked |
| TC-113 | SEC-M52, M53 | Inspect containers; `gateway_rw` attempts DELETE/UPDATE on `quality.shot`; `kb_rw` on `rca_session` | non-root, read-only fs, `cap_drop ALL`; permission denied | Blocked |
| TC-114 | SEC-11 §5.7 | RBAC sweep: every endpoint × roles | matrix as SEC-11 §5.7 | Blocked |
| TC-115 | SEC-M51 | Open an image URL after 16 min; look for images in notifications | 403; none | Blocked |
| TC-116 | SEC-M04, M12 | Reconstruct from `audit.log` who changed the node map, the window, and which suggestions were blocked | complete chain | Blocked |
| TC-117 | SEC-11 §6 | Pen test goals | none achieved | Manual |
| TC-085 | SEC-M02 | Code review of the gateway image | no OPC-UA write call compiled in | Manual |

## 4. Traceability
| SRS-11 | TCs |
|---|---|
| FR-01…FR-05 | TC-010…TC-017 |
| FR-06…FR-11 | TC-020…TC-028 |
| FR-12…FR-18 | TC-040…TC-048 |
| FR-19, FR-25 | TC-060…TC-065 |
| FR-20…FR-24 | TC-050…TC-059 |
| FR-26, FR-27 | TC-066…TC-068 |
| C-01…C-05 | TC-013/110, TC-022, TC-060/063, TC-054, TC-055 |
| AI-01…AI-09 | TC-028, TC-020, TC-028, TC-025, TC-051, TC-056, TC-070, TC-062, TC-055 |
| NFR-01…NFR-09 | TC-102, TC-100, TC-047/101, TC-059, TC-014/103, TC-013, TC-104, TC-063, TC-068 |
| AC-01…AC-09 | TC-020, TC-024, TC-050, TC-070, TC-055, TC-045, TC-057, TC-066, TC-014 |
| SEC-11 THR-M01…M12 | TC-013/110/085, TC-055, TC-054, TC-060…063, TC-051/056, TC-022/024, TC-112, TC-015, TC-057/058, TC-111/115, TC-062, TC-104/105 |

### TS-4b Golden set (AI-07, AC-04)
| ID | Req | Steps | Expected | Status |
|---|---|---|---|---|
| TC-070 | AI-07, AC-04, QAS-08, SEC-M24 | `POST /eval/golden-runs` on the 15-incident set with kb-2026.09.1 | true cause in top-3 ≥ 70 % → `passed`; the seed's earlier priors run 9/15 → not passed; a KB/scoring/prompt change without a run cannot activate | Blocked (E3 + data) |

## 5. Defects found while authoring this set (fixed before release of the drafts)
| # | Where | Defect | Fix |
|---|---|---|---|
| D1 | seed | a `checks` value written as a SQL array literal instead of a JSON string | quoted |
| D2 | seed | `count(*)` (bigint) inserted into integer columns of `cavity_flag` | cast |
| D3 | KB schema | the design-cause conditional fired for causes without the key (properties are vacuously true) | `required: [design_cause]` in the `if` |
| D4 | schema | the suggestion guard silently recomputed an asserted `allowed = true`; effectiveness likewise | both now refuse an assertion that the rule does not support (`OUT_OF_WINDOW`, `EFFECTIVE_NOT_TYPED`) |
| D5 | seed | facts object and `\echo` texts carried estimated delta means | replaced by the re-derived 582.190 / 625.254, 3.293 / 4.139 and drift slopes |
| D6 | assembly | agent enums/indexes and grounding view carried over from the Copilot assembler | removed; VIEW_REVIEW added |
| D7 | seed | probe 4 originally could not fail (the guard recomputed silently) | guard changed (D4); probe asserts `allowed` |

## 6. Not executable on the authoring machine
PostgreSQL (TC-003 probes, TC-009 and every Blocked case), the press and OPC-UA (TS-1, TC-013), camera/lighting/models (TS-2), GPU timing (TS-8), Ollama (TC-056, TC-059, TC-090), the hold-out set, the attribution trial and the golden set (plant data), native review (TC-066). Commands in OPS-11 §12.

## 7. TS-0 execution record (E0, 2026-09-18)
| TC | Result |
|---|---|
| TC-001 | sweep: 0 broken links, 0 missing anchors, 0 unreferenced requirement ids |
| TC-002 | 111/111 shared objects byte-identical; 4/4 sections verbatim |
| TC-003 | 77 / 17 / 25 / 32 / 60 / 15; FK order ok; 19/19 guards; grants ok; 12 probes present |
| TC-004 | compose parsed; profiles; env both ways; network placement; hardening; no secret values |
| TC-005 | all values equal (`check_seed11.py`) |
| TC-006 | KB 3/3 valid, 12/12 negatives; node map valid, 8/8; facts valid, 8/8; consistency true |
| TC-007 | config example valid; negatives rejected (count in OPS-11 §12) |
| TC-008 | OpenAPI valid; 56/73/57; 0 orphans; 23/23 verbatim |
| TC-009 | Blocked |
