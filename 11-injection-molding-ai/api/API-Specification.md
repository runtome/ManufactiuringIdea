# API Specification — MoldMind (AI Vision + Agent for Injection Molding)

| Field | Value |
|---|---|
| Document ID | API-11-MoldMind |
| Version | 1.0 (Draft) |
| Date | 2026-09-18 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **56 paths / 73 operations / 57 schemas**; the platform's five inspection/quality/knowledge paths, 9 schemas, 5 parameters and 4 responses byte-identical to API-00 (TEST-11 TC-008) |
| Related | [SRS-11](../SRS-MoldMind-Injection-Molding-AI.md) §4.1 · [SAD-11](../docs/SAD-MoldMind-Software-Architecture.md) · [DDS-11](../docs/DDS-MoldMind-Database-Design.md) · [ICD-11](../docs/ICD-MoldMind-Interface-Control.md) IF-58…IF-62 · [SEC-11](../docs/SEC-MoldMind-Security-Requirements.md) · platform: [API-00](../../00-factorybrain-platform/api/API-Specification.md) · sibling: [API-09](../../09-quality-engineer-agent/api/API-Specification.md) |

---

## 1. SRS §4.1 mapping and platform mode
| SRS | Path here | Platform (API-00, verbatim) | Note |
|---|---|---|---|
| `POST /api/v1/shots` | `/shots` | — (machine data arrives through IF-05 ingest in platform mode) | idempotent on `shot_id`; buffered replays report `duplicate` |
| `POST /api/v1/shots/{id}/inspection` | `/shots/{id}/inspection` | `/inspections` (platform ingest) + `/inspections/{inspectionId}` | joined to the shot and cavity or refused (`409`) |
| `GET /api/v1/cavity-analysis?mould=&from=&to=` | same | — | Copilot tool `get_cavity_analysis` |
| `GET /api/v1/parameter-delta?defect=&window=` | same | — | Copilot tool `get_parameter_delta` |
| `GET /api/v1/golden-run/{mould}` | same | — | Copilot tool `get_golden_run_diff` |
| `POST /api/v1/rca/sessions` | same | — | |
| `POST /api/v1/rca/sessions/{id}/answer` | same | — | |
| `GET /api/v1/knowledge/defect/{class}` | same | `/knowledge/search` (past cases) | |

Platform paths served verbatim: `/inspections/{inspectionId}`, `/inspections/{inspectionId}/verdict` (FR-11 human verdicts), `/reviews` (review queue), `/cases/{caseId}/artifacts/{kind}` (the 8D lives in QE-Agent — FR-26), `/knowledge/search`.

Added beyond the SRS: machine connections/node maps/tests, gateway batches, moulds/setup sheets/windows, shot list and detail, defects and review, timeline, parameter changes, startup events, data quality, drift, transients, scrap cost, colour references, session board/ranking/advice/suggestions/actions/outcomes/verify/close/handoff/term-check, KB defects/versions/approve/causes/evidence, evaluation runs, scoring config, glossary, config, system.

## 2. Conventions
- Base `/api/v1`; JSON; timestamps UTC (the UI shows plant time); ids UUIDv7; `Problem` verbatim from API-00 with a stable `code` (§8).
- Auth: bearer JWT with the platform roles; molding technician and mould maintenance = `inspector`, process and quality engineers = `engineer`; KB approval and setup-sheet approval need `engineer` and a different person than the author; connections, node maps, scoring, config need `admin`. The gateway uses a service token bound to `gateway_rw`.
- Lists paginate with the platform's `Cursor`/`Limit`; windows with `from`/`to`.
- Every rate carries `n`; every delta carries `cohens_d` (and `welch_t` when computable); every session response carries the ranking's components and weights; every suggestion carries its window verdict.

## 3. The shot contract (C-02, FR-01…FR-11 — IF-05, IF-58)
- `POST /shots`: one row per cycle completion with the FR-01 `params` and FR-02 `context`; `shot_id` is the idempotency key, so a gateway replay after an outage never duplicates (AC-09); data-quality flags (`missing_zone_temp`, `stuck_value`, `clock_skew`) are computed on ingest (FR-05); a shot within `transient_shots` of a startup event is `startup_transient` (FR-16).
- `POST /shots/{id}/inspection`: parts carry `cavity_no`, `image_ts`, `cavity_method` (`ocr_marking` | `robot_position` | `sequence`), detections with class, confidence, region; the response returns `delta_ms`/`tolerance_ms` and the methods used. A part outside the tolerance → `409 ALIGNMENT_TOLERANCE`; a cavity the mould does not have → `409 CAVITY_OUT_OF_RANGE`; a shot without a mould → `409 SHOT_WITHOUT_MOULD`. Nothing is stored loose.
- Low confidence → `review_required`; `POST /defects/{id}/review` (inspector+) stores the human verdict and records the platform `verdict_override` (FR-11). `colour_lab` in a part → ΔE against the SKU's reference (`GET /colour-references`), a `colour_deviation` defect when above the threshold (FR-09, AI-04).

## 4. The analysis contract (FR-12…FR-18)
| Endpoint | Always carries |
|---|---|
| `/cavity-analysis` | per cavity `parts`, `failed`, `fail_rate_pct`, `defects_by_class`, and the flag test (`x/n` vs `others_x/others_n`, `z`, `p_value`, `flagged` at α 0.01 with ≥ 200 parts); `transients_excluded` |
| `/parameter-delta` | per parameter defective vs good `n/mean/sd`, `delta`, `cohens_d`, `welch_t`, `ci95`, `kb_direction_match` |
| `/drift` | slope per shot per parameter and, when a tolerance exists, the projected shots to breach |
| `/golden-run/{mould}` | setup version, approver, per parameter target/tolerance/current/deviation/`out_of_tolerance` |
| `/timeline`, `/parameter-changes` | every event with `kind`, `detail`, who/when/old/new for edits |
| `/transients` | the events and their transient windows — shown, excluded from trends (AC-06) |
| `/scrap-cost` | defects × unit cost per class per day |

The analytics engine computes; handlers read views (`v_cavity_rates`, `v_parameter_delta`, `v_drift`, `v_golden_diff`, …). The API never computes a statistic in a handler.

## 5. The RCA contract (FR-20…FR-24, C-04, C-05, AI-05, AI-06, AI-09)
- **Ranking** (`POST /rca/sessions`, `GET …/ranking`): every cause with `components {prior, delta, timeline, case}` ∈ [0,1], the active `weights` (sum 1) and `score = Σ weight × component`; `evidence[]` explains each component. The database refuses a stored score the function does not produce (`SCORE_NOT_TRANSPARENT`). The session opens only on an approved KB version (`409 KB_NOT_APPROVED`).
- **Dialogue** (`POST …/answer`): the next question comes from the KB check list (`question_key`), phrased by the model in the session language; the answer updates components; the response carries the new ranking and the next question. Without the model (`mode = scripted`) the questions come verbatim from the KB — the ranking is unchanged.
- **Advice** (`GET …/advice`): `kind = check` rows first, then `action` rows; every action has `parameter`, `direction`, `magnitude_range`, `window_ref`, `side_effects` (FR-23); an action ordered before a check is refused at the database (`CHECK_BEFORE_CHANGE`).
- **Suggestions** (`POST …/suggestions`): a concrete value is validated against the mould × material window; inside → `allowed`; outside → `blocked` with `block_reason` and an audit row — the response is `201` either way and a blocked suggestion is never `allowed` (AC-05).
- **Actions and outcomes** (`POST …/actions`, `POST …/outcomes`): the technician records what was applied; the outcome computes before/after rates, `z`, `p_value`, `effective` (p < 0.05 and improvement) and `outcome` (`effective` | `not_effective` | `inconclusive`); an asserted `effective` is refused (`EFFECTIVE_NOT_TYPED`). An effective outcome on a session with a verified cause writes `KbEvidence` (FR-25).
- **Verify / close** (`POST …/verify`, `POST …/close`): the verified cause must be a ranked cause; closure is `verified`, `design_cause` or `unresolved`.

## 6. The knowledge contract (FR-19, FR-25, C-03, AI-08, NFR-08 — IF-59)
- `POST /knowledge/versions` imports YAML entries validated against `kb-entry.schema.json`: every cause has a `source`; non-design causes have checks; actions have direction, range, window ref and side effects. The version is `draft`.
- `POST /knowledge/versions/{id}/approve` (engineer+, not the author) makes it the ranking source; approved versions are immutable — a change is a new version. `GET /knowledge/defect/{class}` and the session use the active approved version only.
- `GET /knowledge/evidence` lists the verified triplets written back from sessions; `KbCause.evidence_count` shows how many.

## 7. The handoff contract (FR-26 — IF-62)
`POST /rca/sessions/{id}/handoff-8d` creates the QE-Agent case and `eight_d` draft from the session (defect, mould, window, verified cause, actions, effectiveness) and stores `qe_case_id`; the artefact is returned in the platform's `Artifact` shape (`ai_generated`, unapproved). Approval, export and the DRAFT watermark are QE-Agent's (API-09 §5). MoldMind never writes an 8D itself; when QE-Agent is unreachable the response is `503 QE_UNAVAILABLE` and the session keeps its data.

## 8. Error catalogue
| HTTP | `code` | When |
|---|---|---|
| 401 | `UNAUTHENTICATED` | |
| 403 | `ROLE_INSUFFICIENT` | approvals below engineer; admin endpoints |
| 404 | `NOT_FOUND` | |
| 409 | `ALIGNMENT_TOLERANCE` · `CAVITY_OUT_OF_RANGE` · `SHOT_WITHOUT_MOULD` · `DEFECT_NOT_JOINABLE` · `KB_NOT_APPROVED` · `KB_IMMUTABLE` · `KB_SELF_APPROVAL` · `SCORING_INACTIVE` · `CHECK_BEFORE_CHANGE` · `OUT_OF_WINDOW` · `EFFECTIVE_NOT_TYPED` · `SCORE_NOT_TRANSPARENT` · `CAUSE_NOT_RANKED` · `CLOSURE_UNVERIFIED` · `SETUP_SHEET_IMMUTABLE` · `MACHINE_READONLY` · `MACHINE_SECURITY` · `NO_OPEN_QUESTION` · `SESSION_CLOSED` · `INSUFFICIENT_SAMPLE` | database guard names surface unchanged (DDS-11 Appendix A) |
| 422 | `VALIDATION_FAILED` · `KB_SHAPE` · `KB_ACTION_SHAPE` · `NODE_MAP_WRITE` · `NODE_MAP_SHAPE` · `CONFIG_INVALID` | |
| 503 | `MODEL_UNAVAILABLE` (platform) | dialogue only — the session continues in `scripted` mode |
| 503 | `QE_UNAVAILABLE` · `NOT_READY` | handoff; DB/Redis/object store/vision down |

## 9. Traceability
| SRS-11 | Endpoints / schemas |
|---|---|
| FR-01, FR-02 | `/shots`, `ShotCreate`, `ShotParams`, `ShotContext`, `/machines/connections/{id}/node-map` |
| FR-03, FR-08, C-02 | `/shots/{id}/inspection`, `ShotInspectionResult.parts[].delta_ms/cavity_method` |
| FR-04, FR-15 | `/parameter-changes`, `/timeline` |
| FR-05 | `Shot.dq_flags`, `/data-quality` |
| FR-06, FR-07, FR-10 | `ShotInspection.parts[].detections`, `DefectClass`, `PartRegion`, `anomaly_score` |
| FR-09 | `/colour-references`, `colour_lab`, `ShotDefect.delta_e` |
| FR-11 | `/defects/{id}/review`, `/reviews`, `/inspections/{inspectionId}/verdict` |
| FR-12 | `/cavity-analysis` |
| FR-13 | `/parameter-delta` |
| FR-14 | `/drift` |
| FR-16 | `/startup-events`, `/transients`, `Shot.startup_transient` |
| FR-17 | `/scrap-cost` |
| FR-18 | `/golden-run/{mould}`, `/moulds/{id}/setup-sheets*` |
| FR-19, FR-25 | `/knowledge/defect/{class}`, `/knowledge/versions*`, `/knowledge/evidence` |
| FR-20, AI-05, AI-06 | `/rca/sessions`, `CauseRanking` |
| FR-21 | `/rca/sessions/{id}/answer`, `RcaSession.next_question/turns` |
| FR-22, FR-23, C-04 | `/rca/sessions/{id}/advice`, `Advice` |
| FR-24 | `/rca/sessions/{id}/actions`, `/outcomes`, `ActionOutcome` |
| FR-26 | `/rca/sessions/{id}/handoff-8d`, `/cases/{caseId}/artifacts/{kind}` |
| FR-27 | `/glossary/terms`, `/rca/sessions/{id}/term-check`, TH/JA/EN text objects |
| C-01, NFR-06 | `/machines/connections*`, `MachineConnection.credential_kind`, `ConnectionTest.write_refused_by_server` |
| C-05, AI-09 | `/moulds/{id}/windows`, `/rca/sessions/{id}/suggestions`, `ParameterSuggestion.blocked` |
| AI-02, AI-07 | `/eval/vision-runs`, `/eval/golden-runs` |
| NFR-05 | `/gateway/batches` |
| AC-03, AC-05, AC-07 | §5 |
