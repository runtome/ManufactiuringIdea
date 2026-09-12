# Security Requirements Specification — VisionOps (AI Factory Inspector Agent)

| Field | Value |
|---|---|
| Document ID | SEC-01-VisionOps |
| Version | 1.0 (Draft) |
| Date | 2026-09-11 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-01 NFR-06, NFR-07](../SRS-AI-Factory-Inspector-Agent.md), [SAD-01 §5](SAD-VisionOps-Software-Architecture.md) |
| Inherits | [SEC-00](../../00-factorybrain-platform/docs/SEC-FactoryBrain-Security-Requirements.md) — platform requirements apply unchanged; this document adds what is specific to an inspection system |

---

## 1. Scope and what is different here

VisionOps inherits the platform's authentication, authorisation, secrets, egress, audit, supply-chain and privacy requirements (SEC-00 §5, SEC-101…SEC-284). They are not restated. This document covers what a general platform threat model does not:

1. **The output is a physical decision.** A verdict routes product. Corrupting verdicts — hiding defects or condemning good parts — has commercial and, for critical classes, safety consequences without any data leaving the building.
2. **The sensor can lie.** A frozen or replayed camera feed produces confident PASS verdicts indefinitely. This is a failure mode, and also an attack.
3. **Configuration is the attack surface.** Recipes, calibration and model artefacts each determine what the system says is good. Tampering with any of them is quieter and more effective than tampering with the data.
4. **Untrusted text enters through the lens.** OCR of printed markings puts text from the physical world into the database and, eventually, into a prompt.

**Integrity of verdicts is the highest objective.** Confidentiality matters (evidence images can reveal product and process), but a leaked image is a lesser harm than a defect shipped because a threshold was quietly raised.

### 1.1 Security objectives

| ID | Objective | Priority |
|---|---|---|
| SO-V1 | **Verdict integrity** — every verdict is produced by a known model, under a known recipe, from a live frame, and is attributable | **Highest** |
| SO-V2 | **Configuration integrity** — recipes, calibrations and models change only by authorised, reasoned, audited actions | **Highest** |
| SO-V3 | **Sensor authenticity** — frames are live, from the registered camera, not replayed or frozen | High |
| SO-V4 | **Bounded agent authority** — the narrative agent has six read tools and one gated write | High |
| SO-V5 | **Evidence immutability** — images and overrides cannot be altered or selectively deleted | High |
| SO-V6 | **Edge containment** — a stolen node yields one station's buffer and an insert-only credential | High |
| SO-V7 | **Privacy** — no operator identity in analysis or training data | Medium |

---

## 2. Assets

| ID | Asset | Classification | Primary concern |
|---|---|---|---|
| A-V1 | Verdicts and override history | Internal | **Integrity, non-repudiation** |
| A-V2 | Recipes (rules, thresholds) | Internal | **Integrity** |
| A-V3 | Calibration records | Internal | **Integrity** |
| A-V4 | Model artefacts and manifests | Internal | **Integrity (supply chain)** |
| A-V5 | Evidence images | Confidential | Integrity, confidentiality (product/process visible) |
| A-V6 | Dataset snapshots (training data) | Confidential | Integrity, privacy |
| A-V7 | Narratives and facts objects | Internal | Integrity |
| A-V8 | Edge node credentials | Secret | Confidentiality |
| A-V9 | Camera and PLC I/O configuration | Internal | Integrity |
| A-V10 | Prompt templates, tool registry | Internal | **Integrity** (code-equivalent) |
| A-V11 | Audit log | Confidential | **Immutability** |

---

## 3. Trust boundaries

```
Z1  camera · PLC · light controller     physical; no logical auth
 │   IF-02 frames  IF-03 signals  IF-18 strobe
Z2  edge node                            physically accessible shop floor
 │   IF-01 outbound only, mTLS/key, insert-only
Z3  server                               egress default-deny
 │   IF-08 Discord (allow-listed)
Z4  browsers, tablets
```

Two assumptions are stated because they shape the controls:
- **Z2 is assumed physically compromisable.** Contractors, cleaners and temporary staff pass edge nodes daily. The design limits what a taken node yields (§5.5).
- **Z1 wiring is trusted only physically.** A camera or PLC cannot authenticate. Protection is panel access control and liveness detection.

---

## 4. Threat model

### 4.1 VisionOps-specific threats (STRIDE)

| ID | Threat | STRIDE | Asset | Controls |
|---|---|---|---|---|
| THR-V01 | **Recipe tampering** — threshold raised or a class removed so defects pass | T | A-V2 | SEC-V10…V14: `engineer`+, mandatory reason, dry-run impact shown, versioned, audited, ETag change visible on fleet; alert on threshold relaxation |
| THR-V02 | **Calibration tampering** — scale altered so out-of-spec measurements read in spec | T | A-V3 | SEC-V20…V24: gauge verification required for validity; fingerprint; verify posts are audited with raw repeats |
| THR-V03 | **Model substitution** — a tampered or weaker model deployed | T | A-V4 | SEC-V30…V34: SHA-256 manifest, no unverified load, shadow run, critical-recall gate, admin-only promote, rollback |
| THR-V04 | **Frozen / replayed camera feed** | S, T | A-V1 | SEC-V40…V43: identical-frame detection, chunk frame-id monotonicity, device timestamp skew check, `FAULT` |
| THR-V05 | **Trigger spoofing / suppression** at the PLC boundary | S, D | A-V1 | Physical; trigger-count vs frame-count reconciliation (data-quality event) |
| THR-V06 | **Override abuse** — bulk PASS overrides to clear a queue or hide escapes | T, R | A-V1 | SEC-V50…V53: overrides attributed and append-only; rate/pattern anomaly alert; agreement stats surface it |
| THR-V07 | **Evidence deletion or replacement** | T, R | A-V5 | SEC-V60…V63: SHA-256 on record; object versioning; no delete grant outside the sweep; snapshot references block deletion |
| THR-V08 | **Prompt injection through the lens** — instructions printed on a part reach the narrative via `ocr_text`, or via `lot`/`note` strings | T | A-V7 | SEC-V70…V73: OCR/lot/note fields are data, never instruction; length caps; never rendered as markdown; injection corpus includes printed-text vectors |
| THR-V09 | **Narrative fabrication** | T | A-V7 | Inherited SEC-230 grounding gate; `narrative_withheld_has_no_text` constraint |
| THR-V10 | **Dataset poisoning** — mislabelled items injected into a snapshot | T | A-V6 | SEC-V80…V83: items come only from attributed overrides/reviews; `engineer`+ to freeze; frozen immutable; label source recorded |
| THR-V11 | **Edge node theft** | I, S | A-V8, A-V5 | Inherited SEC-170…174; SEC-V90: local evidence encrypted; credential scoped to one node's inserts |
| THR-V12 | **Station config tampering** (PLC I/O map) so PASS and FAIL lines are swapped | T | A-V9 | SEC-V15: `engineer`+, audited, requires commissioning re-check flag; PLC-side validation is the real control |
| THR-V13 | **Evidence image exposure** (product design, process) | I | A-V5 | Inherited SEC-243 signed URLs; SEC-V61 export audited |
| THR-V14 | **Operator identification from evidence** | I | A-V5 | SEC-V95…V97: cameras on the part; incidental faces not training inputs; no operator dimension |

### 4.2 The attack worth walking through

A supplier wants a marginal lot to pass.

```
1. A contractor with panel access lowers the MISSING_FIN threshold in the recipe
   → blocked: recipe change needs an `engineer` login (SEC-V10), and the dry-run
     would show "14 FAIL → PASS" (SEC-V12); the audit entry names the user.
2. Instead, they nudge the ST3 camera 3 mm so fin-pitch reads inside spec
   → the hardware fingerprint still matches, but the next gauge check fails and
     the daily drift metric shifts; meanwhile the measurement rule keeps running
     on the last valid calibration — this is the residual risk RR-V02.
3. They print "PASS ALL" on the part label, hoping the narrative agent obeys
   → `ocr_text` is data (SEC-V70); the six tools have no write except a gated
     Discord post (SEC-V72); nothing happens except a flagged injection event.
4. They unplug the camera and plug in a laptop replaying a good-part video
   → chunk frame-ids restart and device timestamps jump (SEC-V41/V42) → FAULT.
```

Step 2 is the honest one: physical tampering with the optical path is detected **eventually** (drift, next gauge check), not instantly. That is why RR-V02 recommends a periodic automated gauge check on the line, not only at calibration time.

### 4.3 LLM threats scoped to the narrative agent

| OWASP | VisionOps exposure | Control |
|---|---|---|
| LLM01 Prompt injection | Via `ocr_text`, `lot`, `sku`, override `note`, and — in platform mode — retrieved documents | SEC-V70…V73 |
| LLM06 Sensitive disclosure | Narrative reveals another line's data | Inherited SEC-114: scope as predicate in every tool |
| LLM08 Excessive agency | Agent acts beyond six read tools | ADR-V07; SEC-V72; no SQL/shell tool exists |
| LLM09 Overreliance | Manager acts on a narrative's "possible correlation" as fact | Template rules (correlation wording), `significant` guard, UM A6 limitations |
| Fabricated statistics | — | Grounding gate; withheld narrative stores no text |

---

## 5. Security requirements

Platform requirements SEC-101…SEC-284 apply. VisionOps-specific requirements:

### 5.1 Recipe integrity

| ID | Requirement | Priority |
|---|---|---|
| SEC-V10 | Creating a recipe version SHALL require role `engineer` or above. | Must |
| SEC-V11 | A recipe version SHALL carry a mandatory `reason` and SHALL be audited with the full before/after rules. | Must |
| SEC-V12 | The UI SHALL run the dry-run and display the verdict transition matrix before a recipe can be saved. | Must |
| SEC-V13 | Recipes SHALL be versioned and never edited in place; `inspection.recipe_id` SHALL record the version used. | Must |
| SEC-V14 | A recipe change that **relaxes** a threshold on a `is_critical` class, or removes such a class, SHALL raise an alert to `manager`+ in addition to the audit entry. | Must |
| SEC-V15 | Station PLC I/O map changes SHALL require `engineer`+, a reason, and SHALL set a `recommission_required` flag visible on the fleet view until cleared by a commissioning check. | Must |

### 5.2 Calibration integrity

| ID | Requirement | Priority |
|---|---|---|
| SEC-V20 | A calibration SHALL be `valid` only when a gauge verification with ≥ 10 repeats exists and max error ≤ tolerance (generated column). | Must |
| SEC-V21 | Verification submissions SHALL store the raw repeat measurements, the user and the timestamp. | Must |
| SEC-V22 | A hardware fingerprint mismatch at edge startup or config pull SHALL invalidate the calibration automatically and raise `FAULT` when a measurement rule is active. | Must |
| SEC-V23 | Manual invalidation SHALL require a reason and SHALL be audited. | Must |
| SEC-V24 | Calibration records SHALL never be deleted. | Must |

### 5.3 Model integrity

| ID | Requirement | Priority |
|---|---|---|
| SEC-V30 | Model registration SHALL verify the artefact SHA-256 against the manifest; mismatch is rejected and logged as a security event. | Must |
| SEC-V31 | The edge SHALL verify SHA-256 before every load; on mismatch it SHALL keep the previous model and raise an alarm — never run unverified. | Must |
| SEC-V32 | Promotion SHALL require a completed shadow run and hold-out critical recall ≥ 0.98; **no API parameter SHALL bypass this**. | Must |
| SEC-V33 | Promotion and rollback SHALL require `admin` and SHALL be audited with metrics snapshot. | Must |
| SEC-V34 | `trained_from` SHALL reference a frozen dataset snapshot; a model without provenance SHALL NOT be promotable. | Must |

### 5.4 Sensor authenticity

| ID | Requirement | Priority |
|---|---|---|
| SEC-V40 | Two consecutive frames with identical content hash SHALL mark the camera `frozen` and assert `FAULT`. | Must |
| SEC-V41 | Camera chunk frame-ids SHALL be checked for monotonicity; a reset or jump SHALL raise a data-quality event and, if repeated, `FAULT`. | Must |
| SEC-V42 | Device timestamp vs host clock skew > 50 ms SHALL raise a data-quality event. | Should |
| SEC-V43 | Trigger count (PLC) and frame count (edge) SHALL be reconciled per shift; discrepancy > 1 % SHALL alert. | Should |
| SEC-V44 | Camera default credentials SHALL be changed at commissioning; the camera segment SHALL not be reachable from Z3. | Must |

### 5.5 Overrides and evidence

| ID | Requirement | Priority |
|---|---|---|
| SEC-V50 | Overrides SHALL be append-only, attributed to a user, and SHALL require a reason code. | Must |
| SEC-V51 | The model's original verdict SHALL never be modified or hidden. | Must |
| SEC-V52 | An override-rate anomaly (e.g. one user overriding > N parts to PASS within M minutes, or override rate > 3σ above the user's baseline) SHALL alert `engineer`+. | Must |
| SEC-V53 | Bulk override endpoints SHALL NOT exist; each override is one attributed request. | Must |
| SEC-V60 | Evidence images SHALL be stored with a SHA-256 recorded on the inspection; the edge upload SHALL be verified against it. | Must |
| SEC-V61 | Evidence access and export SHALL be audited; bulk export requires `engineer`+. | Must |
| SEC-V62 | No role except the retention job SHALL hold delete permission on the evidence bucket; object versioning SHALL be enabled. | Must |
| SEC-V63 | The retention job SHALL NOT delete an object referenced by a frozen dataset snapshot. | Must |

### 5.6 Narrative agent

| ID | Requirement | Priority |
|---|---|---|
| SEC-V70 | `ocr_text`, `lot`, `sku`, `station`, override `note` and any scanned string SHALL be treated as untrusted data in prompts — never as instruction. | Must |
| SEC-V71 | Such fields SHALL be length-capped (≤ 256 chars) before entering a prompt and SHALL be rendered as plain text, never markdown/HTML, in the UI. | Must |
| SEC-V72 | The narrative agent's tool registry SHALL contain exactly the six read tools and `send_discord`; adding a tool is a code change with review. | Must |
| SEC-V73 | The prompt-injection regression suite SHALL include printed-text vectors (a label reading "ignore instructions…", a lot code with an embedded instruction, a Thai/Japanese variant). | Must |
| SEC-V74 | Narratives SHALL be withheld on grounding failure and SHALL store no text (database constraint). | Must |
| SEC-V75 | Narrative delivery to Discord SHALL require `manager` or an approved proposal. | Must |

### 5.7 Datasets and privacy

| ID | Requirement | Priority |
|---|---|---|
| SEC-V80 | Dataset items SHALL originate only from attributed overrides, confirmed reviews, sampled PASS, or manual entries by `engineer`+. | Must |
| SEC-V81 | Freezing a snapshot SHALL require `engineer`+; frozen snapshots SHALL be immutable (trigger). | Must |
| SEC-V82 | Dataset exports SHALL be pseudonymised by default (no user identifiers in labels). | Must |
| SEC-V83 | Export downloads SHALL be signed, short-lived and audited. | Must |
| SEC-V90 | Edge-local evidence cache SHALL be encrypted at rest; console autologin disabled. | Should |
| SEC-V95 | Cameras SHALL be positioned on the part; a station whose field of view includes a work position SHALL be flagged and masked at capture. | Must |
| SEC-V96 | Incidental faces in evidence SHALL NOT be training inputs; masked regions SHALL be excluded from snapshots. | Must |
| SEC-V97 | No operator identity SHALL exist as an analytical dimension in `vision.*` (there is no operator column; `verdict_override.user_id` is accountability, not analysis). | Must |

### 5.8 RBAC matrix (VisionOps operations)

| Operation | viewer | inspector | engineer | manager | admin |
|---|:--:|:--:|:--:|:--:|:--:|
| Read inspections, stats, narratives | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ask the agent | ✅ | ✅ | ✅ | ✅ | ✅ |
| View evidence images | — | ✅ | ✅ | ✅ | ✅ |
| Review queue, override verdict | — | ✅ | ✅ | ✅ | ✅ |
| `POST /inspect` with persist | — | ✅ | ✅ | ✅ | ✅ |
| Create recipe version, dry-run | — | — | ✅ | ✅ | ✅ |
| Calibrate, verify, invalidate | — | — | ✅ | ✅ | ✅ |
| Stations, cameras | — | — | ✅ | ✅ | ✅ |
| Register model, start shadow run | — | — | ✅ | ✅ | ✅ |
| Create / freeze dataset, export | — | — | ✅ | ✅ | ✅ |
| Bulk evidence export | — | — | ✅ | ✅ | ✅ |
| Deliver narrative, approve `send_discord` | — | — | — | ✅ | ✅ |
| **Promote / roll back model** | — | — | — | — | ✅ |
| Config, audit export, users | — | — | — | — | ✅ |
| Bypass the critical-recall gate | ❌ | ❌ | ❌ | ❌ | ❌ **nobody** |
| Delete evidence, override, calibration | ❌ | ❌ | ❌ | ❌ | ❌ **nobody** |

---

## 6. Security testing

| ID | Test | Frequency |
|---|---|---|
| SEC-V100 | Authorisation matrix over all 62 operations × 5 roles | Per release |
| SEC-V101 | Injection corpus incl. printed-text vectors (TC-095) | Per release |
| SEC-V102 | Frozen/replayed feed detection (TC-013, TC-014) | Per release + commissioning |
| SEC-V103 | Model checksum tamper (TC-051) | Per release |
| SEC-V104 | Override-burst alert (TC-093) | Per release |
| SEC-V105 | Recipe relaxation alert (TC-092) | Per release |
| SEC-V106 | Edge credential scope (TC-094) | Per release |
| SEC-V107 | Evidence delete refused for all roles; snapshot-referenced object survives sweep (TC-083, TC-084) | Per release |
| SEC-V108 | Penetration test incl. physical edge scenario | Annually |

---

## 7. Residual risks

| ID | Residual risk | Level | Position |
|---|---|---|---|
| RR-V01 | PLC wiring and camera link have no logical authentication | Medium | **Accepted.** Physical access control; liveness checks (SEC-V40…V43) bound the exposure |
| RR-V02 | **Physical nudge of the optical path** shifts measurements until the next gauge check or drift alert | Medium | **Partially mitigated.** Fingerprint does not detect small pose changes. Recommended: automated daily gauge check at the line (a reference artefact in the field of view) — future enhancement, not v1 |
| RR-V03 | An `engineer` with a plausible reason can still relax a recipe | Medium | **Accepted and visible.** Dry-run shown, reason audited, critical-class relaxation alerts `manager`+. Two-person rule not enforced in v1 |
| RR-V04 | Grounding catches fabricated numbers, not flawed reasoning | Medium | Inherited RR-05. Correlation wording, `significant` guard, UM limitations |
| RR-V05 | Edge node physically taken | Medium | Bounded: one station's buffered evidence + insert-only credential (SEC-170…174, SEC-V90) |
| RR-V06 | Manual SKU entry (IF-15) applies a wrong recipe for a period | Low–Med | Flagged per record; alert > 5 % of shift; unrecognised SKU → FAULT not default |
| RR-V07 | Self-signed CA on LAN | Low | Inherited RR-06 |

---

## 8. Traceability

| Source | Requirement | Test |
|---|---|---|
| SRS-01 NFR-06 override RBAC + audit | SEC-V50…V53, RBAC matrix | TC-045, TC-046, TC-091, TC-093 |
| SRS-01 NFR-07 data stays on LAN | Inherited SEC-240, SEC-V61 | TC-098 |
| SRS-01 C-03 reproducibility | SEC-V13, SEC-V24, SEC-V31, SEC-V60 | TC-047, TC-051 |
| SRS-01 C-04 no invented numbers | SEC-V74, inherited SEC-230 | TC-071…TC-074 |
| SRS-01 AI-02 recall gate | SEC-V32 | TC-052 |
| SRS-01 AI-04 measurement | SEC-V20…V22 | TC-031…TC-034 |
| SRS-01 AI-08 reproducible retraining | SEC-V34, SEC-V81 | TC-055, TC-056 |
| SAD-01 ADR-V06 | SEC-V20…V24 | TC-031…TC-034 |
| SAD-01 ADR-V07 | SEC-V72 | TC-077 |
| ICD-01 IF-02 | SEC-V40…V44 | TC-013…TC-015 |
| ICD-01 IF-03 | SEC-V15, fail-safe rules | TC-021…TC-026 |
| ICD-01 IF-15 | SEC-V70, RR-V06 | TC-017, TC-018, TC-095 |
| ICD-01 IF-16 | SEC-V72 | TC-077, TC-091 |

---

## Appendix A — Review checklist for a VisionOps change

1. Does it change what the system calls PASS? (recipe, threshold, calibration, model) → who can do it, is a reason required, is it audited, does the dry-run/shadow apply?
2. Does it accept text from the physical world (OCR, scan, label)? → is it length-capped and treated as data?
3. Does it touch evidence? → is the hash checked, is deletion still impossible for users?
4. Does it add an agent tool? → read-only? schema? scope predicate? golden set re-run?
5. What does the PLC see if it fails? → `FAULT`, never a stale PASS.
6. Which test proves 1–5?
