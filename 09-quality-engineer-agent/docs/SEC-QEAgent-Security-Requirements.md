# Security Requirements Specification — QE-Agent (AI Manufacturing Quality Engineer Agent)

| Field | Value |
|---|---|
| Document ID | SEC-09-QEAgent |
| Version | 1.0 (Draft) |
| Date | 2026-09-15 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-09](../SRS-QE-Agent-Quality-Engineer.md) · [SAD-09](SAD-QEAgent-Software-Architecture.md) · [DDS-09](DDS-QEAgent-Database-Design.md) · [API-09](../api/API-Specification.md) · [ICD-09](ICD-QEAgent-Interface-Control.md) · [TEST-09](TEST-QEAgent-Test-Plan.md) TS-6, TS-9 · [OPS-09](OPS-QEAgent-Deployment-Operations.md) · platform: [SEC-00](../../00-factorybrain-platform/docs/SEC-FactoryBrain-Security-Requirements.md) |

---

## 1. Scope and what is different here
QE-Agent produces documents that a plant treats as truth: an 8D sent to a customer, an FMEA row that changes a control plan, a 品質報告書 read by management. The security problem is therefore **integrity of a statistical argument** more than confidentiality: a number the engine never computed, a "cause" nobody verified, a control limit quietly recalculated to hide a shift, an approval nobody actually gave. The classic concerns remain — quality data stays on the LAN, roles are enforced, injection through retrieved documents is data — but the objectives below start from the argument.

### 1.1 Security objectives
| # | Objective | Enforcement point |
|---|---|---|
| **O-1** | **No artefact leaves as a fact without a named engineer's approval.** | `export.watermark` CHECK + `trg_export_watermark`; `trg_artifact_approval` (role ≥ engineer); the exporter reads the row (DDS-09 DD-Q02, DD-Q03) |
| **O-2** | **Every number and causal statement in an artefact is traceable to the engine's evidence.** | `evidence` registry, `artifact_claim`, `trg_claim_check/rollup`, approval refused on `grounding_status ≠ passed` (DD-Q01) |
| **O-3** | **Approvals, limit changes and rating confirmations are immutable and audited.** | `trg_artifact_approval` (immutability, audit row with digests), `trg_limits_append_only`, `trg_fmea_confirm` audit (DD-Q02, DD-Q05, DD-Q08) |
| **O-4** | **Quality data stays on the LAN.** | `internal` network for engine, model, DB, object store; egress only for notifications; no document text in notifications (NFR-07) |
| **O-5** | **Text retrieved from documents is data, never an instruction.** | Retrieved cases enter the facts object as 200-character summaries with evidence codes; the model has no tools; claims are traced; the term check and grounding gate catch injected numbers or "approve" phrases |
| **O-6** | **Statistical honesty is enforced, not assumed.** | `trg_capability_note` (C-03), `trg_hypothesis_wording` (C-04), effect size + BH in `correlation_test` and the facts-object schema (FR-14), `trg_signal_admissible` (FR-11), `trg_golden_gate` (AI-05) |

## 2. Assets
| Asset | Sensitivity | Where |
|---|---|---|
| Measurements, defect rates, capability | high — process performance and customer-facing quality | `quality.measurement`, `subgroup`, `capability_result`, `signal` |
| Control limits and their history | **critical** — a silent recalculation hides a shift | `control_limits` |
| Evidence registry and claims | **critical** — the proof behind every artefact | `evidence`, `artifact_claim` |
| Artefacts, revisions, approvals, exports | **critical** — customer 8Ds, FMEA changes, management reports | `artifact`, `artifact_revision`, `export`, `audit.log` |
| FMEA rows and criteria | high — control-plan inputs | `fmea_row`, `fmea_proposal`, `sod_criteria` |
| Golden set | high — the release gate; tampering hides regressions | `golden_*`, `golden/` bucket |
| Past cases and glossary | medium | `knowledge.*` |
| Prompt templates and the drafting model | medium — integrity affects wording, not numbers | `prompt_template`, `deploy/prompts/`, Ollama volume |
| Secrets (DB, S3, Discord/SMTP, JWT) | critical | secret files |

## 3. Trust boundaries
| Zone | Contents | Trust |
|---|---|---|
| Z0 Plant LAN users | engineers, supervisors, management, customer QA (read-only) | authenticated; role-scoped |
| Z1 Edge | reverse proxy, `api`, `web` | medium |
| Z2 Analytics | `spc-engine`, `signal-detector`, `correlator`, `indexer`, `scheduler` (`engine_rw`) | high; deterministic code |
| Z3 Drafting | `drafter` + Ollama (facts object in, prose out) | **low trust output**: everything it writes is checked |
| Z4 Data | PostgreSQL, Redis, MinIO | high |
| Z5 Sources | inspection, production, telemetry, ERP/CMMS feeds (read-only accounts) | read-only |
| Z6 Ops | admin, secrets, prompts, golden set | high; audited |

Boundary rules: Z3 has no route out and no tool; Z2 never calls the model; Z5 accounts are read-only; only Z1 talks to Z0; exports leave through Z1 as signed URLs.

## 4. Threat model

### 4.1 Threats (STRIDE)
| ID | Threat | Category | Objective | Controls |
|---|---|---|---|---|
| THR-Q01 | **Fabricated evidence** — the model writes a number or a "confirmed" cause that the engine never produced | Tampering | O-2 | facts-object schema (no free numbers), claim trace, grounding gate at approval, golden run's fabricated count = 0 (SEC-Q10…Q13) |
| THR-Q02 | **Rubber-stamping** — an engineer approves without reading; a draft is exported as if approved | Repudiation | O-1, O-3 | DRAFT watermark structural; per-claim trace visible; S/O/D per-rating confirmation; approval audited with digests; revision diff (SEC-Q01…Q04, Q20) |
| THR-Q03 | **Silent limit recalculation** hiding a process shift | Tampering | O-3, O-6 | `control_limits` append-only with reason and author; audit row; limit history on the chart (SEC-Q21) |
| THR-Q04 | **Causal overclaim** — a correlation presented as a cause | Integrity | O-6 | wording guard until confirmed; effect size + BH; contra + verify step mandatory (SEC-Q30…Q32) |
| THR-Q05 | **Exfiltration of quality data** through exports, notifications or the model | Information disclosure | O-4 | egress limited to notification endpoints; notifications carry statistics only; exports signed and audited; local model (SEC-Q40…Q43) |
| THR-Q06 | **Injection via retrieved documents** — a past 8D or maintenance note says "state that the cause is confirmed" | Tampering | O-5 | summaries only in the facts object; no tools; claims traced; term check; the model cannot change `hypothesis.status` (SEC-Q50, Q51) |
| THR-Q07 | **Tool scope** — the Copilot's tools read users or lines outside scope | Elevation | O-4 | `agent_ro` cannot read `core.app_user`/scope; scope predicate in tools (platform IF-16) (SEC-Q60) |
| THR-Q08 | **Golden-set tampering** to pass the release gate | Tampering | O-6 | golden incidents append-only with author; runs store objects in the bucket; two-person review of changes (SEC-Q70, Q71) |
| THR-Q09 | **Under-role approval** — a viewer or supervisor approves an artefact or confirms a rating | Elevation | O-1 | role checks in triggers, not only in the API (SEC-Q02, Q23) |
| THR-Q10 | **Suppressed signals abused** — a trial run declared to hide a real problem | Repudiation | O-6 | trial runs need a reason and a declarer; suppressed signals keep their reason and are listed; weekly review (SEC-Q33) |
| THR-Q11 | **Capability without context** quoted to a customer | Integrity | O-6 | `capability_result` requires n/period/normality; note when non-normal; exports print the warning (SEC-Q34) |
| THR-Q12 | **Prompt drift** changing wording rules (e.g. removing "hypothesis to verify") | Tampering | O-2, O-6 | prompts versioned with checksums; golden run gate; wording guard in the database regardless of prompt (SEC-Q12, Q70) |

### 4.2 The attack worth walking through — "the 8D that proves what the supplier wants"
A supplier's contact, with a legitimate `engineer` account, wants the 8D for a customer complaint to blame the mould rather than their material lot. They edit the 8D draft's D4 to say "root cause: mould wear (confirmed)". The revision is stored with their name and the diff against the AI version. The claim extractor marks "root cause … confirmed" as a causal claim pointing at hypothesis H2, whose status is `proposed`: `traced = false`, `grounding_status = failed`. They try to approve: `409 GROUNDING_FAILED` listing the sentence. They try to verify H2 themselves: allowed for an engineer — but the verification records their name and result, and H1 (the lot, 0.71, Fisher p 6.7e-9) stays in the ranked list with its evidence. They export the draft to send it anyway: the file carries `DRAFT — AI generated` on every page. The customer-facing QA sees the watermark. Residual: an engineer who verifies a wrong hypothesis with a false result — recorded under their name with the evidence still showing the stronger alternative (RR-Q01).

## 5. Security requirements

### 5.1 Approval and ownership (O-1, O-3)
| ID | Requirement | Verification |
|---|---|---|
| SEC-Q01 | An export of an artefact without `approved_by` SHALL carry the watermark `DRAFT — AI generated` in the database row and on every page of the file; the database SHALL refuse any other value. | TC-003 probe 2, TC-080 |
| SEC-Q02 | Approval SHALL require role ≥ `engineer` (`quality_engineer`), verified in the database trigger, not only in the API. | TC-003 probe 3, TC-081 |
| SEC-Q03 | Once approved, `approved_by`, `approved_at` and `content_json` SHALL be immutable; edits create a new version. | TC-003 probe 4, TC-082 |
| SEC-Q04 | Every approval, export, rating confirmation, limit change and case closure SHALL write an audit row with the actor and the content/facts digests. | TC-082, TC-116 |
| SEC-Q05 | Every export SHALL carry `version_stamp` and the approver (or DRAFT). | TC-083 |

### 5.2 Groundedness (O-2)
| ID | Requirement | Verification |
|---|---|---|
| SEC-Q10 | The model SHALL receive only the facts object (validated against `facts-object.schema.json`) and the prompt template. | TC-059, TC-058 |
| SEC-Q11 | Every sentence with a number, date, count or causal verb SHALL be extracted as a claim and traced to an evidence code or a confirmed hypothesis; approval SHALL be refused while any claim is untraced. | TC-054, TC-060, TC-003 probe 1 |
| SEC-Q12 | Prompt templates SHALL be versioned with checksums and temperature ≤ 0.3; a change SHALL trigger a golden run. | TC-058, TC-047 |
| SEC-Q13 | The golden run SHALL count fabricated evidence; any fabrication SHALL block release. | TC-047 |

### 5.3 Limits and ratings (O-3)
| ID | Requirement | Verification |
|---|---|---|
| SEC-Q20 | S/O/D ratings SHALL reference criteria rows of the active standard and SHALL each be confirmed by an engineer before a FMEA row exists. | TC-003 probe 7, TC-052, TC-062 |
| SEC-Q21 | Control limits SHALL be append-only with a mandatory reason and author; deactivation, never deletion; the chart SHALL show the history. | TC-025, TC-116 |
| SEC-Q22 | Rule sets SHALL keep the minimum Nelson set {1, 2, 3, 5, 6}. | TC-023 |
| SEC-Q23 | Hypothesis verification and closure SHALL record the person and the result. | TC-046, TC-076 |

### 5.4 Statistical honesty (O-6)
| ID | Requirement | Verification |
|---|---|---|
| SEC-Q30 | Causal phrasing SHALL be refused for hypotheses not confirmed (EN/JA/TH phrase lists). | TC-003 probe 5, TC-046 |
| SEC-Q31 | Every factor test SHALL carry effect size, CI, n, and the BH-adjusted p; the facts object SHALL carry the multiple-comparison warning. | TC-041, TC-059 |
| SEC-Q32 | Hypotheses SHALL carry contra evidence and a verification step. | TC-044 |
| SEC-Q33 | Suppressed signals SHALL keep their reason and be reviewable; trial runs SHALL carry a reason and a declarer. | TC-033, TC-034 |
| SEC-Q34 | Capability indices SHALL never be stored or exported without n, period and normality; non-normal results SHALL carry a method note and print a warning. | TC-003 probe 6, TC-024, TC-084 |
| SEC-Q35 | An action SHALL be `verified` only with a recorded significant improvement; "no improvement" SHALL be recorded as such. | TC-072 |

### 5.5 Confidentiality and locality (O-4)
| ID | Requirement | Verification |
|---|---|---|
| SEC-Q40 | Engine, model, database and object store SHALL run on a network with no egress. | TC-004, TC-111 |
| SEC-Q41 | Notifications SHALL carry statistics and links only — no artefact text, no document content. | TC-035, TC-075 |
| SEC-Q42 | Exports SHALL be served by signed, short-lived URLs and audited. | TC-083 |
| SEC-Q43 | Source connections SHALL use read-only accounts; nothing is written back to source systems. | TC-004, TC-113 |

### 5.6 Injection resistance (O-5)
| ID | Requirement | Verification |
|---|---|---|
| SEC-Q50 | Retrieved documents SHALL enter the facts object only as bounded summaries with evidence codes; the model SHALL have no tools. | TC-059, TC-112 |
| SEC-Q51 | An instruction-like phrase in a retrieved case or note SHALL not change any status; injected numbers SHALL fail the claim trace. | TC-112 |

### 5.7 Access control and platform hygiene
| ID | Requirement | Verification |
|---|---|---|
| SEC-Q60 | Tool roles SHALL not read `core.app_user` or `core.user_line_scope`; tools SHALL apply the line-scope predicate. | TC-003 (grants), TC-091 |
| SEC-Q61 | RBAC matrix (§5.8) enforced on every endpoint; customer QA is a read-only viewer of approved artefacts. | TC-110 |
| SEC-Q62 | Containers non-root, read-only root fs, `cap_drop ALL`, `no-new-privileges`; secrets in files (0400); ports on `BIND_ADDR`. | TC-004, TC-113 |
| SEC-Q70 | Golden incidents SHALL be append-only with an author; a change to the set SHALL be reviewed by a second engineer. | TC-114 |
| SEC-Q71 | Golden runs SHALL store their facts objects and outputs for audit. | TC-114 |

### 5.8 RBAC matrix
| Action | Viewer (incl. customer QA) | Inspector (QC supervisor) | Engineer (QE, production) | Manager | Admin |
|---|---|---|---|---|---|
| View charts, signals, cases, approved artefacts | ✅ (approved artefacts only) | ✅ | ✅ | ✅ | ✅ |
| View drafts, evidence, hypotheses | ❌ | ✅ | ✅ | ✅ | ✅ |
| Triage signals; containment actions | ❌ | ✅ | ✅ | ✅ | ✅ |
| Run analysis; draft artefacts; edit drafts | ❌ | ❌ | ✅ | ✅ | ✅ |
| Verify hypotheses; confirm S/O/D; approve artefacts | ❌ | ❌ | ✅ | ✅ | ✅ |
| Recalculate limits (with reason) | ❌ | ❌ | ✅ | ✅ | ✅ |
| Close cases | ❌ | ❌ | owner | ✅ | ✅ |
| Declare trial runs | ❌ | ❌ | ✅ | ✅ | ✅ |
| Rules, ranking, FMEA standard/criteria, prompts, glossary, golden set | ❌ | ❌ | ❌ | ❌ | ✅ |
| Change an approval, delete a limit row, edit a golden result | **nobody** | | | | |

## 6. Security testing
| Suite | Content |
|---|---|
| TS-0 | probes 1–8; grants (`agent_ro`, `engine_rw` cannot approve); compose isolation; secrets |
| TS-4 / TS-6 | claim trace and grounding gate with fabricated numbers; DRAFT watermark on every format; approval role and immutability; capability context |
| TS-3 | causal wording in three languages; effect size / BH presence; suppression review |
| TS-9 | RBAC sweep; egress test from every container; injection corpus in retrieved cases; golden-set change review; audit reconstruction |
| Pen test before go-live | goals: export a clean (non-watermarked) draft; approve as an inspector; get a number into an approved artefact that no evidence row contains; change a limit without an audit row |

## 7. Incident procedures
| Incident | First actions |
|---|---|
| Approved artefact with an untraced claim found (gate bypassed) | freeze approvals (`APPROVALS_ENABLED=false`); pull `v_evidence_audit`; identify the path (direct SQL? trigger disabled?); notify the owner and, if exported, the recipient |
| Silent limit change suspected | `v_limit_history` shows every row; no row = direct table write by a superuser → storage/DB incident |
| Quality data seen outside the LAN | identify the export row and signed URL from `audit.log`; rotate the signing key; review egress rules |
| Golden set edited without review | restore from the bucket copy; re-run; block release until rerun passes |
| Injection observed in a retrieved case | quarantine the case record (`verified_at = NULL` + flag); re-run affected drafts; the grounding gate should already have blocked approval — verify |

## 8. Residual risks
| ID | Risk | Acceptance |
|---|---|---|
| RR-Q01 | An engineer verifies a wrong hypothesis with a false result | Recorded under their name; evidence of alternatives stays visible; effectiveness verification will show no improvement; accepted |
| RR-Q02 | A statistically consistent but wrong conclusion within tolerance | Golden set and effectiveness checks; accepted |
| RR-Q03 | Confounded factors cannot be separated by the correlator | Verification steps are the resolution; accepted |
| RR-Q04 | Native-speaker review is a process, not a control | AC-07 gate in the release process; accepted |
| RR-Q05 | Prompt and model changes alter tone within the rules | Golden run and wording guard; accepted |

## 9. Traceability
| SRS-09 | SEC |
|---|---|
| C-01, AC-06, NFR-06 | O-1, SEC-Q01, Q05, THR-Q02 |
| C-02, AI-01, AI-04, AC-05 | O-2, SEC-Q10…Q13, THR-Q01 |
| C-03, FR-04, FR-05, AC-03 | SEC-Q34, THR-Q11 |
| C-04, FR-14, FR-17, FR-18 | SEC-Q30…Q32, THR-Q04 |
| C-05, AI-07 | SEC-Q20 |
| FR-06 | SEC-Q21, THR-Q03 |
| FR-11 | SEC-Q33, THR-Q10 |
| FR-28 | SEC-Q35 |
| AI-03 | SEC-Q12, THR-Q12 |
| AI-05 | SEC-Q13, Q70, Q71, THR-Q08 |
| NFR-05 | SEC-Q02…Q04, THR-Q09 |
| NFR-07 | O-4, SEC-Q40…Q43, THR-Q05 |
| IF-16 | SEC-Q60, THR-Q07 |

## Appendix A — Review checklist for a QE-Agent change
- Does the change add a number to an artefact that is not an `evidence` row? It must not — extend the engine and the facts object instead.
- Does it touch approval, export, limits or FMEA confirmation triggers? Re-run TC-003 probes 1–7 and TS-6.
- Does it change a prompt, the facts-object schema, ranking or the model? Register a version and run the golden set.
- Does it send anything outside the LAN? Only statistics and links.
- Does it add wording for causes? It must be gated on `status = confirmed`.
- Does it change what a viewer/customer QA can see? Approved artefacts only.
