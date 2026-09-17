# API Specification — QE-Agent (AI Manufacturing Quality Engineer Agent)

| Field | Value |
|---|---|
| Document ID | API-09-QEAgent |
| Version | 1.0 (Draft) |
| Date | 2026-09-15 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **44 paths / 50 operations / 44 schemas**; the platform's nine quality/knowledge paths, 13 schemas, 6 parameters and 4 responses byte-identical to API-00 (TEST-09 TC-008) |
| Related | [SRS-09](../SRS-QE-Agent-Quality-Engineer.md) §4.1 · [SAD-09](../docs/SAD-QEAgent-Software-Architecture.md) · [DDS-09](../docs/DDS-QEAgent-Database-Design.md) · [ICD-09](../docs/ICD-QEAgent-Interface-Control.md) IF-51 · [SEC-09](../docs/SEC-QEAgent-Security-Requirements.md) · platform: [API-00](../../00-factorybrain-platform/api/API-Specification.md) |

---

## 1. SRS §4.1 mapping and platform mode
| SRS | Path here | Platform (API-00, verbatim) | Note |
|---|---|---|---|
| `GET /api/v1/spc/chart?char=&line=&from=&to=` | `/spc/chart` | same | chart data + violations (`SpcChart`) |
| `GET /api/v1/capability?char=&line=&period=` | `/capability` | `/spc/capability` | the SRS spelling is served as an alias with the same payload extended by C-03 context (`CapabilityDetail`) |
| `GET /api/v1/signals?status=open` | `/signals` | same | ranked (`score`) |
| `POST /api/v1/cases` | `/cases` | same | |
| `POST /api/v1/cases/{id}/analyze` | `/cases/{caseId}/analyze` | same | correlation + hypotheses; ≤ 20 s (NFR-02) |
| `POST /api/v1/cases/{id}/draft/{artifact}` | `/cases/{id}/draft/{artifact}` (5why\|8d\|fmea\|report\|ocap) | `/cases/{caseId}/artifacts/{kind}` (five_why\|eight_d\|fmea\|report\|ocap) | both spellings served standalone; both create a DRAFT with its claim trace |
| `POST /api/v1/cases/{id}/approve` | `/cases/{id}/approve` | `/artifacts/{artifactId}/approve` (per artefact) | the SRS case-level call approves the case's listed drafts, each through the same gate |
| `GET /api/v1/knowledge/search?q=` | `POST /knowledge/search` | same | the platform's hybrid search is a POST with a body; standalone also accepts `?q=` |

Added beyond the SRS: characteristics and limit history/recalculation, rule sets, violations, chart export, signal detail/triage, trial runs, evidence, correlations, timeline, hypotheses with verify, similar cases, artefact detail/revisions/diff/export/term-check, FMEA proposals and per-rating confirmation, OCAP, actions and effectiveness, closure and horizontal deployment, golden runs, glossary, config, system.

## 2. Conventions
- Base `/api/v1`; JSON; UTC timestamps; ids UUIDv7; `Problem` verbatim from API-00 with a stable `code` (§7).
- Auth: bearer JWT with the platform roles; `quality_engineer` = `engineer`. Approvals, rating confirmations and hypothesis verification are `engineer`+ operations; closure `manager`+ or the case owner; configuration `admin`.
- Every list is paginated by the platform's `Cursor`/`Limit`; charts by `DateFrom`/`DateTo`/`LineFilter`.
- Localisation: `lang` selects TH/JA/EN for artefacts, exports and chart labels (NFR-09).
- Every response that carries a statistic carries its context (§6). Every artefact response carries its claim trace (§3).

## 3. The evidence contract (C-02, FR-23, AI-01, AI-04, AC-05)
- `GET /cases/{id}/evidence` is the registry: `Evidence{code E-nn, kind, value, source_query, source_ref, digest}`. The facts object the model receives (ICD-09 IF-51, `deploy/schemas/facts-object.schema.json`) is built from these rows only.
- `ArtifactDetail.claims[]`: every sentence with a number, date, count or causal verb, with `kind`, the `evidence_code` or `hypothesis_id` it maps to, and `traced`. `grounding_status` is `passed` only when every claim is traced; `failed` artefacts are returned normally as drafts (the UI highlights the untraced sentences) but **cannot be approved** (`409 GROUNDING_FAILED` with `untraced_claims`).
- A causal claim is traced only when its hypothesis is `confirmed` (§4).
- `facts_digest` on the artefact identifies exactly which facts object produced it (AI-08-style reproducibility for QE: model + prompt template + facts digest).

## 4. The hypothesis contract (C-04, FR-13…FR-18)
- `HypothesisDetail`: `rank`, `score`, `status` (proposed → verifying → confirmed | rejected), `factor`/`level`, `effect_size`, `p_adjusted`, `supporting[]`, `contra[]` (evidence), `verify_step`, and after verification `verified_by/at/result`.
- Wording: statements are written as "… — hypothesis to verify"; the database refuses causal phrases (`caused by`, `root cause is`, `due to`, 原因は, สาเหตุคือ) on anything not confirmed (`422 CAUSAL_WORDING`).
- `CorrelationReport`: every test with `p_value`, `p_adjusted` (Benjamini–Hochberg), `effect_measure/size` with CI, `n`, `meaningful`; `no_meaningful_association[]` lists the factors without an association (FR-18); `multiple_comparison.warning` is always present.
- `POST /hypotheses/{id}/verify` records the engineer's result; only then may a draft's D4 / why-chain say "cause".

## 5. The approval & export contract (C-01, NFR-05, NFR-06, AC-06)
- `POST /artifacts/{artifactId}/approve` (platform) and `POST /cases/{id}/approve` (SRS): caller role ≥ `engineer`; the artefact's `grounding_status = passed` and `term_violations = 0`; approval is written once — a second approval or a content edit afterwards is `409 APPROVAL_IMMUTABLE`; a new version is created instead. Every approval writes an audit row with the content and facts digests.
- `POST /artifacts/{id}/export`: for an unapproved artefact the `Export.watermark` is `DRAFT — AI generated` — the database CHECK refuses anything else — and the file carries the diagonal watermark on every page; approved artefacts export with `APPROVED`. Every export carries `version_stamp = v<version>.<revision>` and the approver.
- `POST /artifacts/{id}/revisions` stores an engineer's edit with the diff against revision 1 (the AI version); claims are re-extracted and re-traced.
- Capability figures in exports print the normality warning when `normality_ok` is false (C-03).

## 6. The statistics contract (C-03, NFR-04, FR-01…FR-14)
| Object | Always carries |
|---|---|
| `SpcChart` (platform) | points, limits, violations with rule id and point ids |
| `ControlLimits` | baseline window, `sample_size`, `reason`, author, `active`; history never deleted |
| `CapabilityDetail` | `n`, `period_from/to`, subgroup rule, `normality_test = anderson_darling`, `normality_p`, `normality_ok`; when false: `method_note` and `warning`, and the naive Cp/Cpk are omitted |
| `SignalDetail.statistic` | `n`, `x`, `rate`, `baseline_n`, `baseline_x`, `baseline_rate`, `test`, `z`, `p_value` |
| `CorrelationTest` | `test`, `statistic`, `p_value`, `p_adjusted`, `effect_measure`, `effect_size`, `ci_low/high`, `n`, `table` |
| `EffectivenessCheck` | before/after windows and counts, `rate_before/after`, `z`, `p_value`, `improved` |
| `Violation` | `rule` 1–8 and `points[]` |

All of these are computed by the analytics engine (Python, reference-tested) and stored; the API never computes a statistic in a handler.

## 7. Error catalogue
| HTTP | `code` | When |
|---|---|---|
| 401 | `UNAUTHENTICATED` | |
| 403 | `ROLE_INSUFFICIENT` · `NOT_OWNER` | approval/confirmation/verification below `engineer`; closure by a non-owner below `manager` |
| 404 | `NOT_FOUND` | |
| 409 | `GROUNDING_FAILED` · `TERM_CHECK` · `APPROVAL_IMMUTABLE` · `DRAFT_WATERMARK` · `NO_ANALYSIS` · `ACTIONS_OPEN` · `CLOSURE_NOTE_REQUIRED` · `RATINGS_NOT_CONFIRMED` · `CRITERIA_MISMATCH` · `NOT_EFFECTIVE` · `LIMITS_APPEND_ONLY` | database guard names surface unchanged (DDS-09 Appendix A) |
| 422 | `VALIDATION_FAILED` · `CAUSAL_WORDING` · `VERIFY_STEP_REQUIRED` · `CAPABILITY_METHOD_NOTE` · `REASON_REQUIRED` · `RULES_MINIMUM_SET` · `CONFIG_INVALID` | |
| 503 | `MODEL_UNAVAILABLE` (platform `ModelUnavailable`) | drafting only; charts, tests, correlations and hypotheses keep working (AI-08, AC-09) |
| 503 | `NOT_READY` | DB/Redis/object store/engine down |

## 8. Traceability
| SRS-09 | Endpoints / schemas |
|---|---|
| FR-01…FR-07 | `/spc/chart`, `/characteristics*`, `/characteristics/{id}/limits`, `/characteristics/{id}/rules`, `/spc/violations`, `/spc/chart/export`, `/capability`, `/spc/capability` |
| FR-08…FR-12 | `/signals`, `/signals/{id}`, `/signals/{id}/triage`, `/trial-runs`, `SignalDetail` |
| FR-13…FR-18 | `/cases/{caseId}/analyze`, `/cases/{id}/correlations`, `/cases/{id}/timeline`, `/cases/{id}/similar`, `/cases/{id}/hypotheses`, `/hypotheses/{id}/verify`, `/knowledge/search` |
| FR-19…FR-26 | `/cases/{id}/draft/{artifact}`, `/cases/{caseId}/artifacts/{kind}`, `/artifacts/{id}*`, `ArtifactDetail`, `Claim`, `Export`, `TermViolation` |
| FR-27…FR-31 | `/cases/{id}/actions`, `/actions/{id}/effectiveness`, `/cases/{id}/close`, `/cases/{id}/horizontal`, `Action.overdue_days` |
| C-01…C-05 | §5, §3, §6, §4, `FmeaProposal.standard` |
| AI-01, AI-04 | §3 |
| AI-03 | `ArtifactDetail.prompt_template/model_version` |
| AI-05 | `/golden/runs` |
| AI-06 | `/artifacts/{id}/term-check`, `/glossary/terms` |
| AI-07 | `/cases/{id}/fmea-proposals`, `/fmea-proposals/{id}/confirm` |
| AI-08, AC-09 | `/readyz.mode`, `MODEL_UNAVAILABLE` |
| NFR-05, NFR-06 | §5 |
| AC-05, AC-06 | §3, §5 |
