# Interface Control Document — MoldMind (AI Vision + Agent for Injection Molding)

| Field | Value |
|---|---|
| Document ID | ICD-11-MoldMind |
| Version | 1.0 (Draft) |
| Date | 2026-09-18 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-11](../SRS-MoldMind-Injection-Molding-AI.md) §4 · [SAD-11](SAD-MoldMind-Software-Architecture.md) §4 · [API-11](../api/API-Specification.md) · [DDS-11](DDS-MoldMind-Database-Design.md) · [SEC-11](SEC-MoldMind-Security-Requirements.md) · [TEST-11](TEST-MoldMind-Test-Plan.md) · platform: [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) · sibling: [ICD-09](../../09-quality-engineer-agent/docs/ICD-QEAgent-Interface-Control.md) |

---

## 1. Scope and register
| IF | Name | Direction | Owner | Section |
|---|---|---|---|---|
| IF-02 | Industrial camera at the part-exit / robot station | camera → edge | platform | [§IF-02](#if-02) |
| IF-04 | MQTT telemetry (alternative machine feed) | gateway → MoldMind | platform | [§IF-04](#if-04) |
| **IF-05** | **OPC-UA / Euromap 77 machine data — per-shot parameters, read-only** | press → gateway | platform (node maps: MoldMind) | [§IF-05](#if-05) |
| IF-09 | LLM runtime (dialogue and explanation only) | rca-agent → Ollama | platform | [§IF-09](#if-09) |
| IF-10 | Object storage (part images, ΔE frames, evaluation artefacts) | MoldMind ↔ MinIO | platform | [§IF-10](#if-10) |
| IF-14 | Metrics | Prometheus → MoldMind | platform | [§IF-14](#if-14) |
| IF-16 | Agent tool contract — provider and consumer | Copilot → MoldMind; MoldMind → QE-Agent | platform | [§IF-16](#if-16) |
| IF-17 | Inter-agent bus | MoldMind → KaizenSwarm / QE-Agent | platform | [§IF-17](#if-17) |
| IF-19 | Platform integration | MoldMind ↔ FactoryBrain | platform | [§IF-19](#if-19) |
| **IF-58** | **Shot–image alignment & cavity attribution** | camera station → aligner | **MoldMind** | [§IF-58](#if-58) |
| **IF-59** | **Moulding knowledge-base format** | process engineer → kb-service | **MoldMind** | [§IF-59](#if-59) |
| **IF-60** | **Cause-scoring function & RCA facts object** | analyser → rca-agent → model | **MoldMind** | [§IF-60](#if-60) |
| **IF-61** | **Parameter suggestion & process-window contract** | rca-agent → technician | **MoldMind** | [§IF-61](#if-61) |
| **IF-62** | **QE-Agent 8D handoff** | MoldMind → QE-Agent | **MoldMind** | [§IF-62](#if-62) |

## IF-02 — Industrial camera {#if-02}
Inherits [ICD-00 IF-02](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-02). MoldMind specifics: hardware trigger from the robot's part-present signal or the machine's ejection signal; one frame per part (or per cavity group with a fixed robot pose); the reference colour chart is in frame for ΔE (AI-04); per-class lighting rigs (low-angle / deflectometry for sink marks and weld lines — AI-03) are selectable per capture by the recipe; the camera and lighting are inside a rated enclosure (NFR-07, OPS-11 §2). Frame metadata carries the trigger timestamp used for alignment (IF-58).

## IF-04 — MQTT telemetry {#if-04}
Inherits [ICD-00 IF-04](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-04). Used only when a press has no OPC-UA server: a gateway publishes `factory/{plant}/{machine}/event` with `{kind: "shot", shot_id, ts, params, context}` (QoS 1) per cycle and `{kind: "setpoint_change", parameter, old, new, user}` for edits; the same shot contract as IF-05; buffering rules identical.

## IF-05 — OPC-UA / Euromap 77 machine data {#if-05}
Inherits [ICD-00 IF-05](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-05) — read-only session, `SignAndEncrypt`, node maps configured per machine, buffered reconnect. MoldMind's node map is the FR-01 parameter list ([`deploy/machines/M-3.opcua.yaml`](../deploy/machines/M-3.opcua.yaml), schema [`deploy/schemas/opcua-nodemap.schema.json`](../deploy/schemas/opcua-nodemap.schema.json)):

| Item | Contract |
|---|---|
| Nodes (mandatory) | holding pressure and time, injection pressure and speed (+ optional profile array), back pressure, screw rpm, cushion, melt temperature per zone (≥ 1 `melt_z*`), mould temperature fixed/moving, cooling time, cycle time, clamping force, controller shot counter; every node `access: read` |
| Setpoint nodes | the setpoint values and the controller's active-user node → `parameter_change` rows with who/when/old/new (FR-04) |
| Shot trigger | the shot counter's change (or the cycle-complete event) closes a shot: one `quality.shot` row with the last value of every node; delivered within 2 s (NFR-01) |
| Security | `Basic256Sha256/SignAndEncrypt`; client certificate trusted on the machine; **the account is read-only, enforced at the OPC-UA server**; the gateway has no write method compiled in; `machine_connection.credential_kind` and the node map refuse anything else (C-01, NFR-06) |
| Buffering | store-and-forward at the gateway ≥ 24 h (NFR-05); on reconnect `POST /gateway/batches` with the buffered shots; reconciliation by `shot_id`; duplicates reported, not errors (AC-09) |
| Data quality | a `Bad`/`Uncertain` status is stored with the value and flagged (`dq_flags`: `missing_zone_temp`, `stuck_value`, `clock_skew`) — FR-05 |
| Alternatives | Euromap 63 file interface (session/request files on a shared folder, polled per cycle) or MQTT (IF-04) with the same shot contract; both read-only by construction |
| Versioning | node IDs change with controller firmware: `node_map_version` with checksum, validated at startup — an unresolvable node is a startup error |

## IF-09 — LLM runtime {#if-09}
Inherits [ICD-00 IF-09](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-09). MoldMind uses the model for **two things only** (AI-06): phrasing the next question of the guided dialogue and explaining the ranking — both from the RCA facts object (IF-60) and a versioned prompt (`deploy/prompts/rca_question.v1.md`, `explain.v1.md`); temperature ≤ 0.3; ≤ 9 B on the baseline (shared with vision inference — the GPU semaphore applies); turn ≤ 15 s (NFR-04). The model never sees raw shots, never ranks, never proposes a magnitude; its output is term-checked (FR-27). Unavailable → `mode = scripted`: the KB's check list is asked verbatim; the ranking, advice and windows are unchanged.

## IF-10 — Object storage {#if-10}
Inherits [ICD-00 IF-10](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-10). Prefixes: `parts/<machine>/<date>/<shot>-c<cavity>.jpg` (defect images 2 years, PASS images 90 days), `colour/<sku>/<chart>/…` (reference frames), `eval/vision/<run>/…`, `eval/golden/<run>/…` (5 years). Signed URLs 15 min.

## IF-14 — Metrics {#if-14}
`/metrics` (Prometheus, internal): `mm_shots_total{machine}`, `mm_shot_lag_seconds`, `mm_gateway_buffer_depth`, `mm_gateway_batches_total{state}`, `mm_alignment_misses_total`, `mm_cavity_method_total{method}`, `mm_inference_seconds`, `mm_review_rate`, `mm_defects_total{class}`, `mm_cavity_flags_total`, `mm_drift_alerts_total`, `mm_transient_shots_total`, `mm_rca_sessions_total{status}`, `mm_rca_turn_seconds`, `mm_suggestions_total{verdict}`, `mm_outcomes_total{outcome}`, `mm_kb_stale_causes`, `mm_eval_vision_passed`, `mm_eval_golden_passed`, `mm_llm_available`, `mm_machine_write_refused_total`.

## IF-16 — Agent tool contract {#if-16}
Inherits [ICD-00 IF-16](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-16). MoldMind **provides** three read tools and **consumes** QE-Agent's:

| Tool | Provider / consumer | Returns |
|---|---|---|
| `get_cavity_analysis(mould, date_from, date_to, defect?, lines?)` | provider | `CavityAnalysis` — rates with n, flag tests, transients excluded |
| `get_parameter_delta(defect, window, mould?, lines?)` | provider | `ParameterDeltaReport` — deltas with Cohen's d and Welch t |
| `get_golden_run_diff(mould, lines?)` | provider | `GoldenRunDiff` |
| `get_case(case_id)`, `create_draft_report(type = eight_d, payload)` [write, HITL] | consumer (QE-Agent) | the FR-26 handoff (IF-62) |

Rules: read-only, schema-validated, scope predicate on `lines`; results carry `row_count` and a digest; no tool changes a parameter, approves knowledge or closes a session.

## IF-17 — Inter-agent message bus {#if-17}
MoldMind publishes `quality.signal.high` when a cavity flag or defect trend crosses the configured severity (payload: mould, machine, class, rates with n, p-value, session id if opened) and `moldmind.rca.closed` (verified cause, effectiveness) for KaizenSwarm's briefing; it subscribes to MachineSense's `telemetry.alert` to place machine alarms on the timeline (FR-15).

## IF-19 — Platform integration {#if-19}
Same containers; platform database (`moldmind_0001` applied; MoldMind owns `quality.mould/shot/shot_part/timeline_event`); machine data through the platform's IF-05 ingest with MoldMind's node maps; inspections through VisionOps/EdgeGuard with MoldMind's family heads; images in the platform object store; QE-Agent for the 8D; Genba Memory for past cases; the gateway serves the five platform paths and the rest under `/moldmind/`.

## IF-58 — Shot–image alignment & cavity attribution {#if-58}
**Parties.** camera station (edge capture + vision-infer) → `aligner` → `quality.shot_part` + `moldmind.image_alignment`.

| Item | Contract |
|---|---|
| Message | `{shot_id?, image_ts, cavity_no?, ocr_text?, robot_pose?, frame_seq, verdict, detections[], colour_lab?}` per part |
| Alignment | if `shot_id` is present (robot/PLC hands it over) → `align_method = shot_id`; else the shot whose `ts` is nearest to `image_ts` within `tolerance_ms` (default 1,500; per station) → `timestamp`; none within tolerance → the part is stored `unaligned` and excluded from analysis, counted in `mm_alignment_misses_total`; the database refuses an alignment row outside tolerance (FR-03) |
| Cavity | `ocr_marking` (part marking OCR, e.g. "C3") → else `robot_position` (pose → cavity table) → else `sequence` (fixed ejection order); the method is stored per part and its accuracy is measured (AC-02: ≥ 98 % on a 500-part trial per method mix) |
| Cavity range | `cavity_no ≤ mould.cavities` or refused (C-02) |
| Review | detections below the class threshold → `review_required`; the human verdict goes to `shot_defect.review_verdict` and `vision.verdict_override` (FR-11) |
| Colour | `colour_lab` measured against the in-frame chart → ΔE (CIE76; CIE2000 selectable) vs `colour_reference`; above threshold → `colour_deviation` defect with `delta_e` (FR-09, AI-04) |
| Timing | inference ≤ 150 ms per part (NFR-02); alignment adds ≤ 50 ms; a 12 s cycle with 4 cavities has ≥ 11 s of slack |

## IF-59 — Moulding knowledge-base format {#if-59}
The reviewable form of C-03: one YAML file per defect class ([`deploy/kb/sink_mark.yaml`](../deploy/kb/sink_mark.yaml) is SRS-11 Appendix A), validated against [`deploy/schemas/kb-entry.schema.json`](../deploy/schemas/kb-entry.schema.json) on import.

Rules: (1) `defect` ∈ the ten FR-06 classes; descriptions TH/JA/EN; (2) each cause: `cause` code, `prior_weight` (0–1; the set's priors normally sum to 1), `typical_params` (parameter → `up|down|low|high|unstable`), `checks[]` (≥ 1 unless `design_cause`), `actions[]` each with `param`, `direction`, `range` (`+5..+15 %` form), `window_ref`, `side_effects`, and a mandatory `source` (textbook, supplier datasheet, internal case — AI-08); (3) `design_cause: true` entries carry no actions and are routed to engineering; (4) import creates a `draft` version with the file set's checksum; approval by a process engineer who is not the author activates it; approved versions are immutable (NFR-08); (5) verified session outcomes are written back as evidence and shown as `evidence_count` — they change the case component, never the file.

TEST-11 TC-006: the three shipped entries validate; 12 negatives rejected (cause without source, prior 1.5, action without side effects / window ref, non-range magnitude, unknown direction, non-design cause without checks, design cause with an action, unknown class, unknown typical parameter, prompt-like key, action on a non-parameter).

## IF-60 — Cause-scoring function & RCA facts object {#if-60}
**The scoring function (AI-05, code, `moldmind.cause_score`)**: for each cause `c` of the defect in the active KB version,
`score(c) = w_prior·prior_c + w_delta·delta_c + w_timeline·timeline_c + w_case·case_c`, weights from the active `scoring_config` (sum 1; default 0.35/0.30/0.20/0.15), components ∈ [0,1]:
- `prior_c` = `prior_weight / max prior_weight` of the defect's causes;
- `delta_c` = agreement between the observed parameter deltas (FR-13: direction and |Cohen's d|, capped at 1 for |d| ≥ 0.8) and the cause's `typical_params`; 0 when no relevant parameter moved;
- `timeline_c` = 1 when a timeline event that the cause explains (parameter edit of a typical parameter, lot change, maintenance, purge) lies within the onset window, decaying to 0 at 24 h;
- `case_c` = share of effective outcomes for the cause in `kb_case_evidence` (Laplace-smoothed), plus 0.2 when the cause's source cites an internal case for the same mould family.
Answers update components: e.g. "material dried per spec = yes" sets moisture-related causes' `delta_c` to 0; "lot changed = no" removes the lot-change timeline contribution.

**The facts object** ([`deploy/schemas/rca-facts.schema.json`](../deploy/schemas/rca-facts.schema.json), `rca-facts.v1`): the only input of the dialogue/explanation model — trend with n/z/p, cavity flags, parameter deltas, timeline, the ranked causes with components, weights, checks, actions with windows, the KB questions, answers so far, glossary entries, constant `wording_rules`. Every number carries an `E-nn` evidence code. TEST-11 TC-006: the seed's object validates; 8 negatives rejected.

## IF-61 — Parameter suggestion & process-window contract {#if-61}
| Item | Contract |
|---|---|
| Source of truth | `parameter_window` per mould × material grade × parameter with `lo`, `hi`, `unit`, `source` (mould datasheet, material datasheet, process validation), approver (C-05) |
| Suggestion | `{parameter, current_value, suggested_value}` from an action's `range` applied to the current value; magnitude % computed |
| Verdict | inside → `allowed`; outside or no window → `blocked` with `block_reason` and an `audit.log` row; an asserted `allowed` on an out-of-window value is refused (`OUT_OF_WINDOW`) — AI-09, AC-05 |
| Ordering | suggestions belong to `action` advice rows, which the database orders after every `check` (C-04) |
| Presentation | direction, magnitude range, the window `[lo, hi] unit` with its source, expected side effects (FR-23); never a bare number |
| Outcome | the technician records what was applied (`/actions`); effectiveness is a two-proportion test on the after-window (`/outcomes`), α 0.05, min after-window shots configurable (default 200) |

## IF-62 — QE-Agent 8D handoff {#if-62}
**Parties.** MoldMind `rca-agent` → QE-Agent (API-09 `POST /cases`, `POST /cases/{id}/draft/8d`; platform `create_draft_report`).

Payload: `{source: "moldmind", session_id, defect_class, mould, machine, window, trend {before, after, z, p}, cavity_flags[], parameter_deltas[], timeline[], verified_cause {code, names, evidence}, actions[], outcomes[] , kb_version}`. QE-Agent creates the case (severity from the trend), registers the payload's numbers as evidence rows, drafts the 8D with its own grounding gate and DRAFT watermark, and returns `case_id` + the artefact; MoldMind stores `qe_case_id`. Approval, export and the customer-facing document are QE-Agent's (SRS-09 C-01). If QE-Agent is unreachable the handoff is retried by the scheduler; the session is not blocked. Standalone mode writes the same shape into the local `quality.case`/`artifact` (draft, unapproved).

## 2. Interface matrix
| IF | Protocol | Security | Timing | Failure behaviour |
|---|---|---|---|---|
| IF-02 | GigE/USB3 Vision | isolated camera network | ≤ 20 ms trigger-to-frame | alarm ≤ 10 s; frozen-frame detection |
| IF-04 | MQTT | TLS / OT segment | per cycle | gateway buffers |
| IF-05 | OPC-UA binary | SignAndEncrypt; read-only account | shot ≤ 2 s after cycle end | buffer ≥ 24 h; reconcile by shot id |
| IF-09 | HTTP/JSON | internal; no egress | ≤ 15 s per turn | scripted mode |
| IF-10 | S3 | signed URLs 15 min | — | images retried; analysis unaffected |
| IF-14 | HTTP | Prometheus host only | 15 s | — |
| IF-16 | HTTP/JSON typed | JWT; scope predicate; `agent_ro` | ≤ 10 s | partial answer |
| IF-17 | bus | platform | event | best-effort |
| IF-58 | internal queue | edge zone | ≤ 200 ms per part | part stored unaligned, excluded |
| IF-59 | YAML files | git; approval | — | import refused with the schema error |
| IF-60 | JSON | schema-validated | — | session `error`; facts invalid never reach the model |
| IF-61 | JSON | window table | — | blocked + audited |
| IF-62 | HTTP/JSON | service token | — | retried; session unaffected |

## 3. Change control
| Change | Who | Requires |
|---|---|---|
| Node map (firmware change, new node) | admin | new version, checksum, startup validation, `POST /machines/connections/{id}/test` (write refused) |
| Knowledge base | process engineer (author) + a second engineer (approver) | draft version → golden run → approval; retired versions kept |
| Scoring weights | admin | new config version; golden run ≥ 70 % before activation |
| Process windows / setup sheets | process engineer | source cited; approver ≠ author; old versions kept |
| Prompts / model | ML owner | version + checksum; golden run; term check |
| Vision model per family | ML owner | hold-out evaluation ≥ gates (AI-02) |
| Camera / lens / lighting | maintenance | re-calibration and re-validation (ICD-00 IF-02) |

## 4. Traceability
| SRS-11 | IF |
|---|---|
| FR-01, FR-02, FR-04, FR-05, C-01, NFR-01, NFR-05, NFR-06, AC-09 | IF-05, IF-04 |
| FR-03, FR-06…FR-11, C-02, AI-01…AI-04, NFR-02, AC-02 | IF-02, IF-58 |
| FR-19, FR-25, C-03, AI-08, NFR-08 | IF-59 |
| FR-20, FR-21, AI-05, AI-06, NFR-04 | IF-60, IF-09 |
| FR-22, FR-23, FR-24, C-04, C-05, AI-09, AC-05, AC-07 | IF-61 |
| FR-26 | IF-62, IF-16 |
| FR-12…FR-14, FR-18 (tools) | IF-16 |
| FR-15, FR-17 | IF-17 (alarms on the timeline), IF-14 |
| FR-27, AC-08 | IF-09 (term check) |
| NFR-07 | IF-02 (enclosure) |
