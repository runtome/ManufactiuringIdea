# PocketQC — Offline Mobile Inspector — Documentation Set

Scan the lot label → guided checklist → photos judged on-device (defect detection, OCR, barcode, marker-based measurement) → **the inspector decides** → everything stored encrypted on the tablet → synced to FactoryBrain when Wi-Fi returns, with no loss and no duplicates. 100 % of inspection works in airplane mode.

**A mobile client of the platform.** PocketQC serves nothing; it consumes the platform's IF-11 (`/mobile/*`). Its line-side sibling is [EdgeGuard (03)](../03-edge-vision-inspection/) — automatic, PLC-signalled; PocketQC is hand-held and human-judged.

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. **The on-device database was verified by execution** (like EdgeGuard's).

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-05 | [Software Requirements Specification](SRS-PocketQC-Offline-Mobile-Inspector.md) | *What must it do?* | Everyone — start here |
| SAD-05 | [Software Architecture Document](docs/SAD-PocketQC-Software-Architecture.md) | *How does a phone app stay offline-first, human-judged and safe to lose?* | Flutter implementer, architect |
| DDS-05 | [Local Database Design Specification](docs/DDS-PocketQC-Local-Database-Design.md) | *What is stored, which constraints protect the inspector's verdict, and how does purge never lose work?* (SQLite/Drift/SQLCipher) | Implementer |
| API-05 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *The IF-11 server contract as PocketQC needs it — v1.0 verbatim, v1.1 proposed* | Platform team, sync implementer |
| ICD-05 | [Interface Control Document](docs/ICD-PocketQC-Interface-Control.md) | *Camera, delegates, ML Kit, MDM, share sheet, Keystore, and the sync client* | Implementer, security reviewer |
| SEC-05 | [Security Requirements Specification](docs/SEC-PocketQC-Security-Requirements.md) | *What does a lost tablet yield? Who can change a verdict?* | Security reviewer, IT |
| TEST-05 | [Test Plan and Test Cases](docs/TEST-PocketQC-Test-Plan.md) | *How do we prove 50 offline inspections sync with zero loss?* | QA |
| OPS-05 | [Deployment and Operations Guide](docs/OPS-PocketQC-Deployment-Operations.md) | *Devices, MDM configuration, content publishing, lost devices* | Mobile admin, quality admin |
| UM-05 | [User Manual and Administrator Guide](docs/UM-PocketQC-User-Admin-Guide.md) | *Using the step screen; REVIEW; the sync indicator; the quick card* | Inspectors, supervisors, admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`db/schema.sql`](db/schema.sql) | **SQLite** on-device schema (Drift; SQLCipher at rest) — 17 tables, 7 views, 13 indexes, 6 triggers | ✅ **Executed** (Python `sqlite3`): integrity/FK clean; every view queryable; **11 constraint probes rejected** |
| [`db/seed_demo.sql`](db/seed_demo.sql) | AC-01 exactly: 50 airplane-mode sessions + in-progress session + overrides + re-judge + sync backlog | ✅ **Executed**; all header values read back; the supervisor re-judge runs through the trigger inside the seed |
| [`db/payload_mapping.json`](db/payload_mapping.json) | Local tables → `MobileSession` / proposed `MobileSessionStep` | ✅ 0 unmapped / 0 outside contract / 0 dangling columns (checked against API-00 and the executed schema) |
| [`api/openapi.yaml`](api/openapi.yaml) | IF-11 as PocketQC needs it — **13 paths / 14 operations / 13 schemas** | ✅ validator pass; **6 schemas and 2 paths byte-identical to API-00**; 12 operations marked `x-status: proposed` |
| [`deploy/schemas/*.json`](deploy/schemas/) | JSON Schemas: checklist, model manifest, policy, managed configuration | ✅ schema-valid (Draft 2020-12) |
| [`deploy/checklists/RAD-500-A-incoming.yaml`](deploy/checklists/RAD-500-A-incoming.yaml) | SRS Appendix A completed to 20 steps | ✅ validates; classes ⊆ model class map; step kinds equal the seed's cached definition; **11 negative cases rejected** across the four schemas |
| [`deploy/managed-config.example.json`](deploy/managed-config.example.json) · [`deploy/policy.example.json`](deploy/policy.example.json) · [`deploy/models/manifest.example.json`](deploy/models/manifest.example.json) | MDM restrictions · `/mobile/policy` payload · model manifest with self-test samples | ✅ validate; secret scan clean |
| [`deploy/release-checklist.md`](deploy/release-checklist.md) | Per-release gates with TC references | — |

There is deliberately **no `docker-compose.yml`**: PocketQC has no server; its server is [OPS-00](../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md).

---

## Reading paths

**Implementing the app** → SRS-05 → SAD-05 §4.2–4.3 (layers; capture gate; delegate probe; checklist engine; store-and-forward; model OTA; session resume) → DDS-05 → `db/schema.sql` (run it) → ICD-05 IF-30/31/32/35 → API-05 §3–5 → TEST-05.

**Platform team** → SAD-05 §6 and API-05 §1 (what v1.1 must add) → `api/openapi.yaml` `x-status: proposed` → `db/payload_mapping.json`.

**Security review** → SEC-05 §4.2 ("the tablet in the taxi") → ICD-05 IF-35 → DDS-05 Appendix A → TEST-05 TS-6.

**Running a fleet** → OPS-05 §2 (enrolment), §4 (every managed-config key), §5 (publishing checklists and models), §7 (lost device), §9 runbooks.

**Using it** → UM-05 A4–A5 (the step screen and REVIEW), A9 (pending), the quick card.

---

## What makes this design what it is

| Principle | On a phone |
|---|---|
| **The LLM never computes** → **the model never judges** | No LLM on the device. Detection produces a *suggestion*; near the threshold it is REVIEW; **the inspector taps PASS or FAIL**; both values are stored and synced (FR-10, FR-11, AI-07). A session cannot finish with an undecided step — a database trigger, not a UI rule. |
| **Offline-first** → **offline is the normal case** | Login window, cached checklists/SKUs/codes/models, local PDF; sync is a counter, not a workflow (C-01, FR-24). |
| **Human-in-the-loop** | The human *is* the loop. Re-judging a finished session needs a supervisor PIN and leaves an append-only audit row (FR-19). |
| **The database is the source of truth** | Every step commits before the UI advances (FR-16); the local DB is authoritative until the platform acknowledges; the server never edits a device verdict silently (FR-23). |
| Plus: **the device will be lost** | SQLCipher DB, per-image AES-GCM with Keystore-wrapped keys, app gate, remote wipe on next contact, no backup, no third-party SDKs (C-05, NFR-05, NFR-09). |

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [00 FactoryBrain](../00-factorybrain-platform/) | **Client of IF-11** (loose coupling, async idempotent sync — SAD-00 §13). Shared schemas and the two existing paths are copied verbatim and diffed. Records land in `vision.inspection` with `source = mobile`; human-vs-model disagreements become `vision.verdict_override` (retraining data). **Gap:** the platform needs IF-11 v1.1 (auth with offline window, models download, resumable images, policy, heartbeat/commands, typed steps) — specified in API-05. |
| [03 EdgeGuard](../03-edge-vision-inspection/) | Sibling runtime with the same store-and-forward shape (records first, images second, purge never touches unsynced, model OTA gated by verification). Different judge: EdgeGuard signals a PLC automatically; PocketQC asks a person. |
| [01 VisionOps](../01-factory-inspector-agent/) | Owns the models and the review queue the synced records feed. |

---

## Identifier conventions

`FR-`/`NFR-`/`AI-`/`AC-`/`C-` (SRS-05) · `P-1…P-4` · **`ADR-M01…M10`** · `QAS-01…12` · **`DD-M01…M07`** · `IF-xx` shared numbering (**IF-30 camera, IF-31 inference, IF-32 barcode/OCR, IF-33 managed config & wipe, IF-34 share/PDF, IF-35 secure storage** new; IF-11 client side) · **`THR-M`/`SEC-M`** · `TS-`/`TC-` · `RB-01…14`.

```
SRS-05 FR-10 / FR-11 / AI-07  "low confidence → REVIEW; the inspector's judgement always overrides; both stored"
  └─ SAD-05 P-1 "the model never judges" · ADR-M03 · §4.3.5 review band
      └─ DDS-05 DD-M02 · step_result.suggested_result + human_result · trg_session_finish_requires_decisions · v_session_summary.overrides
          └─ API-05 MobileSessionStep.suggested_result / human_result · §5 "device wins"
              └─ ICD-05 IF-31 review band · IF-11 batch assembly
                  └─ SEC-05 O-2 · SEC-M20…M25
                      └─ TEST-05 TC-003 (probe, executed) · TC-024 · TC-030 · TC-034 · seed: 3 REVIEW steps, 8 overrides
                          └─ OPS-05 §5 · UM-05 A5, B7
```

---

## Verification

| Check | Result |
|---|---|
| **`db/schema.sql` executed** (TC-002) | ✅ **Pass** — 17 tables, 7 views, 13 explicit indexes, 6 triggers; `integrity_check` ok; `foreign_key_check` empty; all views queryable |
| **Constraint probes** (TC-003) | ✅ **Pass** — 11/11 rejected: finish with undecided REVIEW; second active model; activate after failed self-test; insert active without self-test; model > 25 MB; verdict change without audit; audit update; audit delete; delete referenced image; finished without verdict; second `device_info` row; purge view holds 0 unsynced sessions |
| **`db/seed_demo.sql` executed** (TC-005) | ✅ **Pass** — 51 sessions (50 finished: 43 PASS / 7 FAIL; 1 in progress at step 7 with 6 steps); 1,006 steps; 150 measurements; 804 images; 3 REVIEW steps; 8 overrides; 0 manual-mode; 0 undecided in finished; synced 30 / unsynced 20; images 400 / 404; pending 20 sessions · 80 images · 0 stuck; queue 20 @1 + 80 @5; purge candidates 0; low-space candidates 397 (all synced+uploaded+PASS); models 4 (2 active, 1 previous, 1 self-test failed); audit 6; session 22 re-judged to FAIL **through the trigger** |
| Payload mapping vs API-00 `MobileSession` and the executed schema (TC-006) | ✅ **Pass** — 0 / 0 / 0 |
| `openapi.yaml` (TC-001) | ✅ **Pass** — 13 paths / 14 ops / 13 schemas; 0 undefined refs; one intentionally unreferenced schema (`MobileSessionStep`) |
| Contract identity vs API-00 (TC-008) | ✅ **Pass** — `MobileBootstrap`, `MobileSession`, `BatchResult`, `ModelManifest`, `Verdict`, `Problem`, `/mobile/bootstrap`, `/mobile/sessions:batch` identical |
| Deploy artefacts vs JSON Schemas incl. 11 negatives; classes ⊆ class map; YAML kinds = seed kinds (TC-004) | ✅ **Pass** |
| Secret scan (TC-007) | ✅ **Pass** |
| SRS-05 coverage; cited tables/views/endpoints/TCs/RBs/ADRs/SEC-Ms; links | ✅ see sweep note below |
| Flutter release build, size budget (TC-009) | ⚠️ **Not verified** — no Flutter/Android toolchain on the authoring machine |
| Everything on a device (TS-1…TS-9) | ⚠️ Specified, not run |

To reproduce the execution:
```bash
cd 05-offline-mobile-inspector
python -c "import sqlite3;c=sqlite3.connect(':memory:');c.executescript(open('db/schema.sql',encoding='utf-8').read());s=open('db/seed_demo.sql',encoding='utf-8').read();c.executescript(s[:s.index('-- 10. VERIFICATION')]);print(c.execute('PRAGMA integrity_check').fetchone(),c.execute('SELECT count(*),sum(verdict=\"PASS\"),sum(verdict=\"FAIL\") FROM session').fetchone(),c.execute('SELECT * FROM v_pending_sync').fetchone())"
```

**Defects found by checking** (all fixed; TEST-05 §4): a no-op guard trigger in the first schema draft; header counts guessed wrong (806 → 804 images; 375 → 397 low-space candidates); unquoted commas in the OpenAPI; and one worth passing back to the SRS — **`no:` as a YAML key parses as boolean `false` under YAML 1.1** (the Appendix A sketch has this pitfall); the shipped checklist quotes it.

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| **Platform IF-11 is v1.0**: no auth/offline window, model download, resumable images, policy, heartbeat/commands endpoints; `MobileSession.steps` untyped. PocketQC's contract (API-05) proposes v1.1 additively | API-05 §1, SAD-05 §6 |
| Until v1.1: remote wipe relies on the MDM path only; image sha256 verification and self-test samples need the models endpoint | SEC-05 §8, OPS-05 §5 |
| Unsynced work on a wiped or never-reconnecting device is lost — deliberate | SEC-05 §8, API-05 §4 |
| SRS Appendix A YAML sketch: `no:` key must be quoted for YAML 1.1 parsers | deploy checklist, OPS-05 §5 |
| Measurement is two-tap in v1 (no auto edge detection); OCR limited to the lot-code font set | SAD-05 §9 |
| iOS not built; architecture keeps native code in platform channels only (C-06) | SAD-05 §3.3 |
| App build and all device behaviour unverifiable on the authoring machine | TEST-05 |
