# Test Plan & Test Cases — PocketQC Offline Mobile Inspector

| Field | Value |
|---|---|
| Document ID | TEST-05-PocketQC |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Basis | [SRS-05](../SRS-PocketQC-Offline-Mobile-Inspector.md) FR-01…30, AI-01…08, NFR-01…09, AC-01…08, C-01…06 · [SAD-05](SAD-PocketQC-Software-Architecture.md) QAS-01…12 · [SEC-05](SEC-PocketQC-Security-Requirements.md) SEC-M10…M62 · [ICD-05](ICD-PocketQC-Interface-Control.md) |
| Executed so far | **TS-0 in full** on the authoring machine (Python 3.14 `sqlite3` 3.50.4, `pyyaml`, `openapi-spec-validator`, `jsonschema`): the on-device schema and seed **executed**, 11 constraint probes, payload mapping, contract identity vs API-00, OpenAPI, JSON Schemas for the deploy artefacts. No Flutter/Android toolchain here — everything from TS-1 onward needs devices; specified, not run. |

---

## 1. Strategy

### 1.1 What is different about testing a phone app
- **Airplane mode is the default test condition.** Every functional suite runs with the network off; TS-5 turns it on to observe the drain. The pass criterion that outranks the rest: **no session is lost and none is duplicated** (AC-01, AC-02).
- **The database is testable without a device** — and was: the Drift schema (as plain SQL) and the AC-01 seed run in-process; the gate constraints were probed. Device tests then confirm the app uses those transactions as designed (TS-4).
- **The inspector's judgement is the unit under protection.** TS-3 asserts, on every path, that `human_result` is written only by a tap and never changed without a PIN.
- **Device matrix**: reference device (Galaxy Tab Active4 Pro, NNAPI), a mid-range phone (GPU delegate), a low-end phone (CPU/XNNPACK) — latency gates apply to the reference device only (AI-03); the others must remain functional.
- **Corpora as gates**: hold-out image set (AI-02), lot-code OCR corpus (AI-04), 20 sample labels (AC-06), calibrated gauge ×30 (AC-05).

### 1.2 Levels
| Level | Scope | Runs |
|---|---|---|
| L0 Static / executable | schema, seed, mapping, OpenAPI, deploy schemas | every commit |
| L1 Unit (Dart) | checklist engine, verdict rule, quality gate maths, measurement maths, redaction of logs, mapping projection | every commit |
| L2 Instrumented (emulator + device farm) | capture, inference, sync against a mock platform, persistence | nightly |
| L3 Device lab | reference device + matrix; battery; latency; forensics | release |
| L4 Field trial | 2 inspectors, 1 week, real lots (SRS P6) | release |

### 1.3 Exit for release
All Must FR TCs green on the reference device; AC-01…08 green; TS-6 security green incl. forensics and lost-device drill; TS-8 latency/battery gates; field trial with crash-free ≥ 99.5 % (NFR-08); residual risks acknowledged (SEC-05 §8).

---

## 2. Test suites and cases

Notation: **[X]** executed on the authoring machine · **[ ]** specified, not run · Pri M/S.

### TS-0 — Static and executable artefacts (L0)

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-001 | OpenAPI valid | validator; unique operationIds; every op 2xx; refs; null-key scan | Pass | M | [X] 13 paths / 14 ops / 13 schemas; the only unreferenced schema is `MobileSessionStep` (typed shape for the untyped `steps[]`, by design) |
| TC-002 | Schema executes | `sqlite3` in-memory `executescript(schema.sql)`; `integrity_check`, `foreign_key_check`; every view queryable | ok / clean; 17 tables, 7 views, 13 indexes, 6 triggers | M | [X] |
| TC-003 | Constraint probes | Finish a session with an undecided REVIEW step; second active model per name; activate a model whose self-test failed; insert active without self-test; model > 25 MB; change a finished verdict without audit; update/delete audit; delete a referenced image; finished session without verdict; second `device_info` row; purge view contains an unsynced session | Each rejected; purge view 0 unsynced | M | [X] 11/11 rejected; 0 unsynced in purge view |
| TC-004 | Deploy artefacts vs JSON Schemas | `managed-config.example.json`, `policy.example.json`, `checklists/RAD-500-A-incoming.yaml`, `models/manifest.example.json` vs `deploy/schemas/*`; negatives: unknown step kind; accept rule naming a class not in the step's model; model > 25 MB; retention 0; `sync_network: cellular` | Positives pass; negatives fail | M | [X] |
| TC-005 | Seed executes with expected values | `executescript(seed_demo.sql)`; verification selects | 51 sessions (50 finished: 43 PASS / 7 FAIL; 1 in progress at step 7 with 6 steps); 1,006 steps; 150 measurements; 804 images; review 3; overrides 8; manual-mode 0; undecided-in-finished 0; synced 30 / unsynced 20; uploaded 400 / 404; pending 20 sessions · 80 images · stuck 0; queue 20 @1 + 80 @5; purge candidates 0; low-space 397 all synced+uploaded+PASS; models 4 (active 2, previous 1, self-test failed 1); audit 6; re-judged session 22 = FAIL | M | [X] |
| TC-006 | Payload mapping | `MobileSession` required/properties vs `db/payload_mapping.json`; every local column referenced exists in the executed schema | 0 unmapped; 0 outside contract; 0 dangling | M | [X] |
| TC-007 | No secrets in examples | Scan deploy examples and seed for tokens/keys/PINs | None; `token_ref`/`pin_ref` are references | M | [X] |
| TC-008 | Contract identity vs API-00 | Structural diff of `MobileBootstrap`, `MobileSession`, `BatchResult`, `ModelManifest`, `Verdict`, `Problem` and the two existing paths | Identical | M | [X] 6/6 schemas, 2/2 paths |
| TC-009 | Flutter release build, size budget | `flutter build apk --split-per-abi --release`; APK ≤ 200 MB; no debuggable; `allowBackup=false` | Pass | M | [ ] **blocked** — no Flutter/Android toolchain on the authoring machine |

### TS-1 — Capture and quality gate (L2/L3) — FR-01…05, IF-30

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-010 | Framing guide per step | Overlay shape/text from the checklist; TH/JA/EN | M | [ ] |
| TC-011 | Camera ready ≤ 1.5 s | Measured over 20 step opens on the reference device (NFR-01) | M | [ ] |
| TC-012 | Quality gate — blur | Defocused frame → retake prompt "blurred"; no analysis ran | M | [ ] |
| TC-013 | Quality gate — exposure and glare | Dark frame → "too dark" + torch suggestion; reflective frame → "glare" | M | [ ] |
| TC-014 | Burst pick | 5 frames, sharpest chosen, `burst_index` stored | S | [ ] |
| TC-015 | Metadata and EXIF | Timestamp with offset, user, device, step, lot, SKU, torch state stored; GPS only when policy enables; **EXIF stripped** from the stored file | M | [ ] |
| TC-016 | Image encrypted before row commit | Kill the app between file write and row commit ×20 → no row without a decryptable file; no plaintext JPEG anywhere in `files/` | M | [ ] |

### TS-2 — On-device AI (L2/L3) — FR-06…12, AI-01…05, AI-08, IF-31, IF-32

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-020 | Delegate probe and fallback | NNAPI on reference; GPU on mid-range; CPU on low-end; result cached; forced failure → next delegate; never a crash | M | [ ] |
| TC-021 | Detection UI | Classes, confidences, boxes drawn; class labels localised from the defect-code cache | M | [ ] |
| TC-022 | Latency gate (AI-03, AC-04) | 500 inferences on the reference device: p95 ≤ 500 ms; `latency_ms` recorded per step; diagnostics screen shows p95 | M | [ ] |
| TC-023 | Model quality gate (AI-02, AC-04) | Hold-out set: mAP@50 ≥ 0.75; recall on critical classes ≥ 0.95; INT8 within 3 % of FP32 | M | [ ] |
| TC-024 | REVIEW band (FR-10) | Confidence within ±0.1 of the threshold → step REVIEW; a REVIEW step cannot be skipped; both values stored | M | [ ] |
| TC-025 | Model version per record (FR-12) | Two versions installed sequentially → each step carries the version used | M | [ ] |
| TC-026 | OCR accuracy and correction (FR-07, AI-04) | Lot-code corpus (≥ 300 codes): ≥ 95 % character accuracy; one-tap correction stores raw and corrected | M | [ ] |
| TC-027 | Barcode auto-select (FR-08, AC-06) | 20 sample labels → 20/20 correct checklist; unknown SKU → manual with warning | M | [ ] |
| TC-028 | Measurement (FR-09, AI-05, AC-05) | Calibrated gauge ×30 with the ArUco marker: within ±0.5 mm; ± tolerance shown; no marker → REVIEW | S | [ ] |
| TC-029 | Manual mode (AI-08, AC-07) | Uninstall the model → `photo_ai` steps become photo + human verdict; `model_version` NULL; work continues | M | [ ] |

### TS-3 — Checklist engine and verdicts (L1/L2) — FR-13…15, FR-19

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-030 | Model never writes `human_result` | Code path audit + instrumented test: `human_result` set only from the tap handler; a step with `suggested_result` and no tap stays undecided | M | [ ] |
| TC-031 | Verdict rule | FAIL if any FAIL; else PASS; a session with an undecided step cannot finish (trigger + UI) | M | [ ] |
| TC-032 | Step annotations (FR-15) | Note, defect code (localised), severity on any step; defect code on a PASS step requires severity | M | [ ] |
| TC-033 | Checklist versions (FR-13, FR-23) | Bootstrap with v4 mid-session → current session keeps v3; next session uses v4 | M | [ ] |
| TC-034 | Supervisor re-judge (FR-19) | Wrong PIN ×5 → lockout 15 min, audited; correct PIN → verdict change with `rejudge` audit row; without PIN the DB refuses | S | [ ] |
| TC-035 | Appendix A checklist loads | `RAD-500-A-incoming.yaml` → 20 steps, rules, measurements as specified | M | [ ] |

### TS-4 — Persistence and storage (L2/L3) — FR-16, FR-30, NFR-04, AC-03

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-040 | Purge never touches unsynced (FR-30) | Seed-like state → purge job → unsynced sessions/images untouched; synced past retention removed with `purge_log` | M | [X] view property on the seed / [ ] job on device |
| TC-041 | **Force-kill mid-session (AC-03)** | Kill at step 7 ×10 → resume at step 7 with steps 1–6 intact; kill during image write → no orphan row | M | [ ] |
| TC-042 | Device restart mid-session | Same as TC-041 after reboot | M | [ ] |
| TC-043 | Low space 20 % / 10 % | Warn banner; harder compression; below 10 %: synced PASS images purged first, burst disabled; unsynced never purged | M | [ ] |
| TC-044 | Capacity (NFR-04) | 5,000 sessions + 20 GB images: history search ≤ 1 s; app stable | M | [ ] |
| TC-045 | DB corruption recovery | Corrupt file → moved aside, fresh DB, event; app usable | S | [ ] |

### TS-5 — Sync (L2) — FR-20…26, AC-01, AC-02, IF-11

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-050 | **50 inspections in airplane mode (AC-01)** | 0 errors; 0 data loss; pending counter 50 | M | [ ] |
| TC-051 | **Reconnect drains (AC-02)** | 50 sessions accepted; 0 duplicates centrally; all images uploaded; counter 0 | M | [ ] |
| TC-052 | Replay after crash mid-207 | Same batch again → `duplicate` ×N treated as success; no duplicates centrally | M | [ ] |
| TC-053 | Images only after records | Image upload attempted only for accepted sessions; server never holds an orphan | M | [ ] |
| TC-054 | Resumable upload across network change | Wi-Fi drop at 40 % → `HEAD` → resume from server offset; no re-upload from zero | M | [ ] |
| TC-055 | sha256 verification | Corrupted local file → 422 → image marked stuck; record intact | M | [ ] |
| TC-056 | Conflict rules (FR-23) | Server changes a checklist → device takes it; server "edits" a verdict → arrives as an override, device `human_result` unchanged | M | [ ] |
| TC-057 | WorkManager survives process death (NFR-06) | Kill app during sync; reboot → sync resumes without UI | M | [ ] |
| TC-058 | Model OTA (FR-26, AI-06) | Good manifest → download → sha256 → self-test → active; tampered byte → refused; weak model → self-test fails → previous active; rollback command works | M | [ ] |
| TC-059 | Bootstrap ETag | Unchanged → 304 → no cache write; changed → atomic replace | M | [ ] |
| TC-060 | Policy applied | Retention, sync network, compression, GPS reflected in behaviour | M | [ ] |
| TC-061 | Pending counter and last sync (FR-24) | Always visible; matches `v_pending_sync` | M | [ ] |
| TC-062 | Offline login window (FR-27) | Day 29: opens offline; day 31: history read-only until online login | M | [ ] |
| TC-063 | `force_relogin` / revocation | Next contact ends offline access | M | [ ] |
| TC-064 | Refresh token device binding | Token copied to another device → 401 | M | [ ] |

### TS-6 — Security (L3) — SEC-05

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-070 | Managed configuration applied; no in-app override | Server URL, pins, offline days, share targets from MDM; no settings screen exposes them | M | [ ] |
| TC-071 | Missing managed config | Login blocked with a clear message | M | [ ] |
| TC-072 | Remote wipe via command | Flush ≤ 60 s → ack → keys deleted before files → "device wiped" | M | [ ] |
| TC-073 | Wipe via 403 `DEVICE_WIPED` on login | Same result | M | [ ] |
| TC-074 | MDM wipe path independent | MDM enterprise wipe removes the app data | M | [ ] |
| TC-080 | PDF report content and fonts (FR-18, AC-08) | Thai and Japanese render; per-step content; versions in footer | S | [ ] |
| TC-081 | Share restricted to allowed targets | Unlisted package absent from the sheet; cache PDF gone after 1 h | M | [ ] |
| TC-082 | PDF privacy | Compressed images; no GPS unless enabled | M | [ ] |
| TC-083 | Share audited | `audit_event` with target package | S | [ ] |
| TC-090 | No secrets in the DB | Dump the decrypted DB → only `token_ref`/`pin_ref` references | M | [ ] |
| TC-091 | **Storage forensics** | Copy `files/` and the DB off a release-build device → unreadable | M | [ ] |
| TC-092 | App gate (FR-29) | Credential/biometric on open and after 5 min background | S | [ ] |
| TC-093 | Lost-device drill | Mark lost → next contact wipes; timing recorded | M | [ ] |
| TC-094 | `FLAG_SECURE` | Screenshot/recording blocked on inspection screens | M | [ ] |
| TC-095 | `secure_delete` | Purged rows not recoverable from the file | S | [ ] |
| TC-096 | Key loss | Keystore cleared → app starts fresh, event reported | S | [ ] |
| TC-097 | Rooted device | Integrity fail → login/sync blocked, reported | M | [ ] |
| TC-098 | Certificate pinning | Proxy with a valid public-CA cert → refused; rotated pin from managed config accepted | M | [ ] |
| TC-099 | Egress | 1-h packet capture → only `server_url`; no analytics; ML Kit bundled (no runtime download) | M | [ ] |
| TC-100 | Backup disabled | `adb backup` yields nothing; no external storage use | M | [ ] |
| TC-101 | Release build hardening | `debuggable=false`; diagnostics never show secrets | M | [ ] |
| TC-102 | Logs and support bundle | No tokens, keys, image bytes, lot text | M | [ ] |

### TS-7 — UX and i18n (L2/L4) — NFR-02, NFR-07, AC-08

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-110 | 20-step inspection ≤ 4 min (NFR-02) | 10 runs by 2 inspectors on the reference device: median ≤ 4 min | M | [ ] |
| TC-111 | Gloved use | All targets ≥ 48 dp; whole flow with work gloves | M | [ ] |
| TC-112 | TH/JA/EN runtime switch | Every screen; no truncation; defect names localised | M | [ ] |
| TC-113 | Resume prompt | Unfinished session offered on app open | M | [ ] |
| TC-114 | History search (FR-17) | By lot, SKU, date, verdict | M | [ ] |
| TC-115 | Sync indicator (FR-24) | Pending count + last sync visible on home and during inspection | M | [ ] |

### TS-8 — Performance and battery (L3) — NFR-01, NFR-03, NFR-08

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-120 | Cold start ≤ 3 s | 20 cold starts | M | [ ] |
| TC-121 | Battery ≥ 6 h | Scripted intermittent use: 8 inspections/h, screen on 30 %, sync off | M | [ ] |
| TC-122 | Memory | No OOM across 100 sessions; interpreter released in background | M | [ ] |
| TC-123 | Crash-free (NFR-08) | ≥ 99.5 % over the field trial and device-farm runs | M | [ ] |
| TC-124 | Device matrix | Functional on GPU and CPU devices; latency recorded (not gated) | S | [ ] |

### TS-9 — Field trial (L4)

| TC | Title | Expected | Pri | Status |
|---|---|---|---|---|
| TC-130 | One week, two inspectors, real lots | 0 lost sessions; sync every evening; issues logged | M | [ ] |
| TC-131 | Inspector feedback | Flow time, retake rate, REVIEW rate reviewed with quality engineering | S | [ ] |
| TC-132 | Retraining export (AI-07) | Overrides arrive centrally with image and both labels | M | [ ] |

---

## 3. Traceability

| SRS-05 | TCs |
|---|---|
| FR-01 | TC-010 |
| FR-02 | TC-012, TC-013 |
| FR-03 | TC-014 |
| FR-04, FR-05 | TC-015 |
| FR-06 | TC-021 |
| FR-07 | TC-026 |
| FR-08 | TC-027 |
| FR-09 | TC-028 |
| FR-10 | TC-024, TC-003 |
| FR-11 | TC-030, TC-003 |
| FR-12 | TC-025 |
| FR-13 | TC-033, TC-035 |
| FR-14 | TC-031 |
| FR-15 | TC-032 |
| FR-16 | TC-041, TC-042, TC-016 |
| FR-17 | TC-114 |
| FR-18 | TC-080 |
| FR-19 | TC-034, TC-003 |
| FR-20 | TC-051…TC-055 |
| FR-21 | TC-060, TC-057 |
| FR-22 | TC-059 |
| FR-23 | TC-033, TC-056 |
| FR-24 | TC-061, TC-115 |
| FR-25 | TC-060, TC-082 |
| FR-26 | TC-058 |
| FR-27 | TC-062 |
| FR-28 | TC-072…TC-074, TC-093 |
| FR-29 | TC-092 |
| FR-30 | TC-040, TC-043 |
| AI-01 | TC-009 (size), TC-023 |
| AI-02 | TC-023 |
| AI-03 | TC-022 |
| AI-04 | TC-026 |
| AI-05 | TC-028 |
| AI-06 | TC-058 |
| AI-07 | TC-132 |
| AI-08 | TC-029 |
| NFR-01 | TC-011, TC-120 |
| NFR-02 | TC-110 |
| NFR-03 | TC-121 |
| NFR-04 | TC-044 |
| NFR-05 | TC-090, TC-091 |
| NFR-06 | TC-057 |
| NFR-07 | TC-111, TC-112 |
| NFR-08 | TC-123 |
| NFR-09 | TC-099 |
| AC-01 | TC-050 (+ seed TC-005) |
| AC-02 | TC-051 |
| AC-03 | TC-041 (+ seed session 51) |
| AC-04 | TC-022, TC-023 |
| AC-05 | TC-028 |
| AC-06 | TC-027 |
| AC-07 | TC-029 |
| AC-08 | TC-080, TC-112 |
| C-01 | TC-050 (every TS-1…TS-4 case runs in airplane mode) |
| C-02 | TC-009, TC-003 (size CHECK) |
| C-03 | TC-022 |
| C-04 | TC-099 |
| C-05 | TC-091 |
| C-06 | code review — native only in platform channels (ICD-05 §IF-30/31/35) |

## 4. Defects found during TS-0

| # | Where | Defect | Fix |
|---|---|---|---|
| 1 | `db/schema.sql` | A no-op "guard" trigger (`SELECT 1` body) that enforced nothing | Removed; the real guard is `trg_session_finish_requires_decisions` |
| 2 | `db/seed_demo.sql` header | Image count guessed as 806 and low-space candidates as 375; execution gave 804 (the in-progress session has 4 image steps, not 6) and 397 | Header corrected from executed values |
| 3 | `api/openapi.yaml` | Unquoted commas in a flow-mapping description parsed as bogus keys | Quoted; null-key scan in TC-001 |

## 5. Release gates
1. TS-0 green on every commit; TC-009 green in CI with the Flutter toolchain.
2. AC-01/AC-02 (TC-050/051) and AC-03 (TC-041) green on the reference device — **no exceptions**.
3. TS-6: TC-091 forensics, TC-093 lost-device drill, TC-098 pinning, TC-099 egress green on a release build.
4. TS-2 gates: TC-022 latency, TC-023 model quality, TC-026 OCR, TC-027 barcode 20/20, TC-028 gauge ±0.5 mm.
5. TS-8 battery and crash-free; field trial complete.
