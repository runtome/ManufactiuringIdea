# API Specification — VisionOps (AI Factory Inspector Agent)

| Field | Value |
|---|---|
| Document ID | API-01-VisionOps |
| Version | 1.0 (Draft) |
| Date | 2026-09-11 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable spec | [`openapi.yaml`](./openapi.yaml) — OpenAPI 3.1, validated |
| Implements | [SRS-01 §4.1](../SRS-AI-Factory-Inspector-Agent.md), [SAD-01 §4.3](../docs/SAD-VisionOps-Software-Architecture.md) |
| Platform relationship | Conventions identical to [API-00](../../00-factorybrain-platform/api/API-Specification.md); §11 describes platform-mode mounting |

---

## 1. Relationship to `openapi.yaml`
`openapi.yaml` is the contract (54 paths, 62 operations, 50 schemas; validated against the OpenAPI 3.1 schema, all 220 `$ref`s resolve). This document holds what the spec cannot express: conventions, the semantics of recipes/calibration/promotion, the grounding contract for narratives, the error catalogue, and how the standalone surface maps onto the platform.

---

## 2. Conventions (inherited)

Identical to [API-00 §2](../../00-factorybrain-platform/api/API-Specification.md): path-versioned `/api/v1`, `snake_case`, RFC 3339 timestamps with offset, plant-local inclusive dates, cursor pagination, unknown query parameters **rejected** (400), rates returned unrounded, `null` (never `0`) when the denominator is zero.

Two VisionOps-specific additions:

- **Defect-rate denominator.** Every rate in this API is `FAIL / (PASS + FAIL)` on the **effective** verdict. `REVIEW` and `NO_READ` are reported separately and never counted as either good or bad. A client that computes `failed / inspected` will get a different — and wrong — number.
- **`verdict` filters mean effective verdict.** `GET /inspections?verdict=FAIL` returns parts whose verdict of record is FAIL, including PASS parts a human overrode to FAIL. `model_verdict` and `effective_verdict` are both returned so the distinction is visible.

---

## 3. Authentication and authorisation

| Principal | Mechanism | Scope |
|---|---|---|
| User | JWT bearer, 15 min access / 12 h rotating refresh, MFA for `admin` | Role + line scope |
| Edge node | `X-Edge-Key` or mTLS | Insert inspections for its own node; read its own config |

Roles: `viewer` < `inspector` < `engineer` < `manager` < `admin`.

| Capability | Minimum role |
|---|---|
| Read inspections, stats, narratives, ask | `viewer` |
| Evidence URLs, review queue, override verdict | `inspector` |
| Recipes (create/validate), calibration, stations, datasets, register model, shadow run | `engineer` |
| Approve `send_discord` proposals, deliver narratives | `manager` |
| Promote / roll back a model, config, audit export | `admin` |

**Three writes carry a mandatory `reason`** and are audited with before/after: recipe version, calibration invalidation, model rollback. A recipe change without a reason is `422`.

Line scope is enforced as a query predicate, never as response filtering (SEC-114).

---

## 4. Idempotency and delivery

Identical mechanisms to API-00 §4:

1. **Client-generated UUIDv7** on every inspection (`InspectionCreate.id`). Re-posting returns `200` with the existing record.
2. **`Idempotency-Key`** header on mutating operations; replays within 24 h return the original response.
3. **Batch `207 Multi-Status`** on `/edge/records:batch`; `duplicate` is a success outcome.

The `/edge/*` contract is **byte-for-byte the platform's IF-01**. An EdgeGuard node configured for VisionOps standalone needs only a URL change to sync with FactoryBrain instead.

---

## 5. Recipe semantics

### 5.1 Versioning
| Rule | Behaviour |
|---|---|
| Never edit in place | `POST /recipes/{sku}` creates version N+1 with `active_from`; version N gets `active_to` |
| In-flight isolation | An inspection records the `recipe_id` it was judged with; a recipe change never re-judges history |
| Propagation | The edge config ETag changes; nodes pull on their next poll (≤ 60 s) and swap atomically |
| Reason required | `reason` (≥ 5 chars) is mandatory and appears in the audit entry and the version history |

### 5.2 Validation before change
`POST /recipes/{sku}/validate` is a **dry run**: it re-evaluates the last `sample_size` inspections under the proposed rules and returns the verdict transition matrix.

```json
{ "transitions": [ {"from":"PASS","to":"REVIEW","count":14}, {"from":"REVIEW","to":"FAIL","count":2} ],
  "unchanged": 484, "current_defect_rate_pct": 3.0, "new_defect_rate_pct": 3.4,
  "warnings": ["class_present threshold for SCRATCH lowered from 0.75 to 0.60: 14 additional REVIEW/day expected"] }
```

The UI runs this automatically before enabling the Save button. It exists because a threshold change that silently flips hundreds of parts is the most common recipe error, and it is invisible without it.

### 5.3 Rule evaluation
Documented in [DDS-01 §6](../docs/DDS-VisionOps-Database-Design.md) and [SAD-01 §4.3.1](../docs/SAD-VisionOps-Software-Architecture.md). The API guarantees: same `(recipe version, inputs)` → same verdict, on the edge and on `POST /inspect`.

---

## 6. Calibration semantics

```
POST /cameras/{id}/calibrations          →  version N+1, valid = false
POST …/calibrations/{cid}/verify         →  ≥10 gauge repeats; valid = (max_err ≤ tolerance)
POST …/calibrations/{cid}/invalidate     →  manual: camera moved, lens changed
```

| Guarantee | Mechanism |
|---|---|
| No measurement from an unverified calibration | `valid` is a generated column; the rules engine reads `v_current_calibration` |
| A failing verification is still recorded | It is evidence that the setup is wrong; it does not become "valid" by being re-run |
| Hardware change invalidates automatically | `hardware_fingerprint` (camera serial + lens + mount) is checked on the edge at startup and on each config pull |
| What the client sees | `POST /inspect` with measurements and no valid calibration → `409 CALIBRATION_STALE`; on the line the verdict is `NO_READ` with the same reason |

---

## 7. Model lifecycle semantics

```
POST /models              register candidate (SHA-256 verified; trained_from must be a frozen snapshot)
POST /models/{id}/shadow  ≥ 200 live frames, no verdict effect, disagreement report accumulates
POST /models/{id}/promote admin; refused unless shadow complete AND critical recall ≥ 0.98
POST /models/{id}/rollback re-activate a previous model; reason required
```

`GET /models/{id}` returns `promotion_gate` with explicit `reasons[]` so the UI can show *why* promotion is not yet available instead of a disabled button.

**The critical-recall gate cannot be bypassed through the API.** There is no `force` parameter. A model that misses more critical defects is a worse model for this purpose regardless of its headline mAP (SRS-01 AI-02).

---

## 8. The grounding contract

Identical to [API-00 §5](../../00-factorybrain-platform/api/API-Specification.md), applied to narratives and `/agent/ask`.

| Promise | Detail |
|---|---|
| Every number in `text`/`answer` appears in `sources` | Verified by a deterministic post-check, not by prompting |
| Failure withholds the output | `422 GROUNDING_FAILED`; the narrative row stores `text = NULL` (database constraint) |
| Non-significant change is stated as such | `significant: false` → "within normal variation", no cause proposed (FR-21) |
| Insufficient data is a success | `outcome: refused`, HTTP 200 — the agent declining to speculate is correct behaviour |
| Verification is one call away | `GET /agent/runs/{id}` returns every tool call, the facts object and the grounding result |

VisionOps-specific: the narrative's `sources` include `similar_periods` hits with their similarity score, so "this resembles 2026-05-14" is as traceable as a number.

### 8.1 Streaming
`POST /agent/ask?stream=true` uses SSE with `status`, `tool`, `token`, `done` and `error` events. **Tokens are provisional until `done`.** On `error` with `GROUNDING_FAILED` the client must discard accumulated text — same obligation as the platform.

---

## 9. Error catalogue

Platform codes (API-00 §7) apply. VisionOps adds:

| HTTP | `code` | Meaning | Caller action |
|---|---|---|---|
| 409 | `CALIBRATION_STALE` | No valid calibration for the camera; measurements refused | Verify or recalibrate (UM B3) |
| 409 | `CAMERA_OFFLINE` | Station camera disconnected or frozen | Check IF-02; OPS RB-01/RB-02 |
| 409 | `MODEL_NOT_SHADOWED` | Promotion before a completed shadow run | Start/complete the shadow run |
| 409 | `CRITICAL_RECALL_BELOW_GATE` | Hold-out recall on critical classes < 0.98 | Retrain; do not look for a bypass |
| 409 | `SNAPSHOT_FROZEN` | Attempt to change items of a frozen dataset | Create a new snapshot |
| 409 | `VERDICT_UNCHANGED` | Override equals the current effective verdict | No action |
| 409 | `REVIEW_CLAIMED` | Another inspector holds the claim on this item | Take the next item |
| 422 | `RECIPE_INVALID` | Rules fail the JSON Schema; `errors[]` lists fields | Fix the rules |
| 422 | `CHECKSUM_MISMATCH` | Model artefact or evidence upload SHA-256 differs from manifest | Re-upload; treat repeated mismatch as a security event |
| 422 | `NO_READ_QUALITY_GATE` | `POST /inspect` image failed the quality gate | Re-capture; see `quality_gate.reason` |
| 422 | `GROUNDING_FAILED` | Narrative/answer withheld | Report — model-quality incident (OPS RB-12) |
| 503 | `MODEL_UNAVAILABLE` | LLM down; inspection, review, stats unaffected | Retry later |

Retry rules: never retry 4xx except 429; retry 5xx with backoff — all mutating endpoints are idempotent.

---

## 10. Rate limits

| Endpoint class | viewer/inspector | engineer/manager | admin | Edge node |
|---|---|---|---|---|
| Reads (stats, inspections) | 120/min | 300/min | 600/min | — |
| `POST /inspect` | 10/min | 60/min | 60/min | — |
| `POST /agent/ask` | 10/min | 30/min | 30/min | — |
| `POST /agent/narrative` | 2/min | 10/min | 10/min | — |
| Recipe validate | — | 20/min | 20/min | — |
| `/edge/records:batch` | — | — | — | 60/min/node |
| `/edge/images` | — | — | — | 300/min/node |
| `/edge/heartbeat` | — | — | — | 2/min/node |

`X-Queue-Depth` is returned on agent endpoints when the GPU semaphore is contended.

---

## 11. Platform mode — how the surface maps onto FactoryBrain

| Standalone path | Platform mode |
|---|---|
| `/auth/*` | **Collapses** into the platform's `/auth/*` (same roles) |
| `/edge/*` | **Collapses** into the platform's `/edge/*` — identical contract, so no edge change |
| `/admin/config`, `/admin/audit`, `/healthz`, `/readyz` | Platform's; VisionOps settings appear under a `visionops.*` prefix in config |
| `/models/*` | Mounted as-is; the platform's `/admin/models*` delegates to these for vision models |
| `/inspections`, `/reviews`, `/inspect`, `/recipes`, `/stations`, `/cameras`, `/datasets`, `/stats/*`, `/reports/*` | **Mounted unchanged** under the platform API |
| `/agent/narrative`, `/agent/narratives` | Mounted unchanged |
| `/agent/ask`, `/agent/tools`, `/agent/proposals/*`, `/agent/runs/*`, `/agent/feedback` | **Collapse** into the platform Copilot; the six VisionOps tools are registered into the platform registry |

Consequences a client should expect in platform mode: `GET /agent/tools` returns more than six tools; `/agent/ask` can answer "why" questions by handing off to QE-Agent; `similar_periods` is joined by `search_memory`.

---

## 12. Endpoint index

| Domain | Endpoint | Method | Min role | SRS-01 |
|---|---|---|---|---|
| auth | `/auth/login`, `/auth/refresh` | POST | — | — |
| auth | `/auth/me` | GET | viewer | — |
| inspect | `/inspect` | POST | viewer (persist requires inspector) | FR-05…12 |
| inspections | `/inspections` | GET, POST | viewer / inspector | FR-02, FR-10 |
| inspections | `/inspections/{id}` | GET | viewer | FR-10 |
| inspections | `/inspections/{id}/verdict` | PATCH | inspector | FR-13, FR-14 |
| inspections | `/inspections/{id}/evidence` | GET | inspector | FR-10 |
| inspections | `/reviews`, `/reviews/next` | GET | inspector | FR-13, AC-07 |
| recipes | `/recipes`, `/recipes/{sku}`, `/recipes/{sku}/versions` | GET | viewer | FR-08 |
| recipes | `/recipes/{sku}` | POST | engineer | FR-08, FR-09 |
| recipes | `/recipes/{sku}/validate` | POST | engineer | FR-08 |
| stations | `/stations`, `/cameras` | GET, POST | viewer / engineer | FR-02 |
| stations | `/stations/{id}` | PATCH | engineer | FR-12 (I/O map) |
| stations | `/cameras/{id}/calibrations` | GET, POST | viewer / engineer | FR-07, AI-04 |
| stations | `…/calibrations/{cid}/verify`, `…/invalidate` | POST | engineer | AI-04 |
| models | `/models` | GET, POST | viewer / engineer | AI-03 |
| models | `/models/{id}` | GET | viewer | AI-03 |
| models | `/models/{id}/shadow` | POST | engineer | AI-08 |
| models | `/models/{id}/promote`, `/rollback` | POST | admin | AI-02, AI-03 |
| models | `/models/{id}/drift` | GET | engineer | AI-07 |
| datasets | `/datasets`, `/datasets/{id}` | GET, POST | engineer | FR-15 |
| datasets | `/datasets/{id}/freeze` | POST | engineer | FR-15, AI-08 |
| stats | `/stats/summary`, `/pareto`, `/stations`, `/correlation` | GET | viewer | FR-17, FR-23 |
| stats | `/stats/agreement` | GET | viewer | FR-16 |
| narrative | `/agent/narrative` | POST | viewer (deliver: manager) | FR-17…22 |
| narrative | `/agent/narratives` | GET | viewer | FR-17 |
| narrative | `/agent/ask` | POST | viewer | FR-20 |
| narrative | `/agent/runs/{id}`, `/agent/tools` | GET | viewer | FR-19 |
| narrative | `/agent/proposals*` | GET, POST | manager | — |
| narrative | `/agent/feedback` | POST | viewer | — |
| edge | `/edge/records:batch`, `/edge/images`, `/edge/heartbeat` | POST | edge key | FR-01…03, NFR-03 |
| edge | `/edge/config` | GET | edge key | FR-08 |
| edge | `/edge/nodes` | GET | engineer | — |
| reports | `/reports/{type}`, `/jobs/{id}` | POST, GET | viewer | FR-25 |
| admin | `/admin/config`, `/admin/audit` | GET, PATCH | admin | NFR-06 |
| admin | `/healthz`, `/readyz` | GET | — | NFR-09 |

---

## 13. Deliberately unusual choices

| Choice | Why |
|---|---|
| `POST /inspect` is **not** the line path | The line must never wait on the server. `/inspect` exists for manual checks and dry-runs; production judgement happens on the edge and arrives via batch |
| `verdict` filters on the *effective* verdict | The verdict of record is what a quality engineer means by "the FAILs"; the model's original is still returned alongside |
| `/reviews/next` soft-locks an item | Two inspectors judging the same part produce contradictory overrides and a wasted minute each; a 5-minute claim costs nothing |
| A failing gauge verification is stored, not rejected | It is evidence that the rig is wrong. Rejecting it invites re-running until it passes by luck |
| No `force` on promotion | The critical-recall gate is the difference between a vision system and a liability |
| `similar_periods` appears in `sources` | A narrative that says "this resembles May" must be as traceable as one that quotes a number |

---

## 14. Traceability

| SRS-01 | Endpoint / mechanism |
|---|---|
| FR-01…04 acquisition | `/edge/records:batch` (`quality_gate`, `NO_READ`), `/edge/heartbeat` `camera_state` |
| FR-05…09 inspection & rules | `/inspect`, `Recipe`, `/recipes/{sku}/validate`, `review_threshold` |
| FR-10 evidence | `/inspections/{id}/evidence`, `/edge/images` with SHA-256 |
| FR-11 OCR | `InspectResult.ocr_text`, rule kind `ocr_match` |
| FR-12 verdict I/O | `Station.plc_io`, `EdgeConfig.stations` |
| FR-13…14 review & override | `/reviews`, `/reviews/next`, `PATCH …/verdict` with `reason_code` |
| FR-15 dataset export | `/datasets`, `/datasets/{id}/freeze` |
| FR-16 agreement | `/stats/agreement` |
| FR-17…19 narrative | `/agent/narrative`, `Narrative.facts/sources/grounding`, §8 |
| FR-20 ad-hoc questions | `/agent/ask` |
| FR-21 no-significant-change | `significant: false` semantics |
| FR-22 languages | `lang` parameter |
| FR-23…25 delivery | `/stats/*`, `deliver: true`, `/reports/{type}` |
| AI-02 recall gate | `CRITICAL_RECALL_BELOW_GATE` |
| AI-03 model versioning | `/models`, `model_version` on every record |
| AI-04 measurement accuracy | `/calibrations/{id}/verify`, `CALIBRATION_STALE` |
| AI-06 anomaly fallback | `AnomalyResult.flagged` → REVIEW only |
| AI-07 drift | `/models/{id}/drift` |
| AI-08 reproducible retraining | `trained_from` must be a frozen snapshot |
| NFR-03 24 h buffer | UUIDv7 dedup, `207` batch |
| NFR-06 RBAC | §3 |
| C-03 reproducibility | `recipe_version` + `model_version` + `image_sha256` on every record |
| C-04 no invented numbers | §8 |
