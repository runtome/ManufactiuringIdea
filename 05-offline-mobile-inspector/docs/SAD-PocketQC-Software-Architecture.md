# Software Architecture Document — PocketQC Offline Mobile Inspector

| Field | Value |
|---|---|
| Document ID | SAD-05-PocketQC |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-05](../SRS-PocketQC-Offline-Mobile-Inspector.md) |
| Platform relationship | **Mobile client of FactoryBrain** over [IF-11](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-11) (loose coupling, async idempotent sync — [SAD-00 §13](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md)). No server of its own. See §6 for what the platform must add |
| Related | [DDS-05](DDS-PocketQC-Local-Database-Design.md) · [API-05](../api/API-Specification.md) · [ICD-05](ICD-PocketQC-Interface-Control.md) · [SEC-05](SEC-PocketQC-Security-Requirements.md) · [TEST-05](TEST-PocketQC-Test-Plan.md) · [OPS-05](OPS-PocketQC-Deployment-Operations.md) · [UM-05](UM-PocketQC-User-Admin-Guide.md) · sibling runtime: [SAD-03 EdgeGuard](../../03-edge-vision-inspection/docs/SAD-EdgeGuard-Software-Architecture.md) (line-side, automatic; PocketQC is hand-held, human-judged) |

---

## 1. Introduction

### 1.1 Purpose
The architecture of **PocketQC**: a Flutter Android app that lets a roaming inspector run a guided checklist — photos with on-device defect detection, barcode and OCR reading, reference-marker measurement — with **no network at all**, and later synchronises the results to the central platform without losing or duplicating anything.

### 1.2 What kind of system this is
A phone in a factory is the opposite of a server: it is offline more often than online, it is dropped, it runs out of battery and storage, it is lost. The design therefore assumes three things throughout:

1. **There is no network** (C-01). Every feature is designed offline-first; sync is an afterthought that must not lose data.
2. **The inspector is the judge** (FR-10, FR-11). The model suggests; the person decides; both values are kept forever. This is P-1 on a phone: the model never *claims* a verdict.
3. **The device will be lost** (C-05, NFR-05). Everything at rest is encrypted with keys the device hardware protects; the server can wipe it on next contact.

### 1.3 Audience
| Reader | Start at |
|---|---|
| Flutter implementer | §4.2 layers, §4.3 components, §7 ADRs, then [DDS-05](DDS-PocketQC-Local-Database-Design.md) |
| Platform team | §6 — the IF-11 contract PocketQC needs |
| Security reviewer | §5, [SEC-05](SEC-PocketQC-Security-Requirements.md) |
| Admin | §4.5 deployment, [OPS-05](OPS-PocketQC-Deployment-Operations.md) |

### 1.4 Related documents
Platform principles P-1…P-4 ([SAD-00 §5.1](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md)); the UUIDv7 client-generated id rule (SAD-00 §5.7); IF-11 ([ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-11)); the store-and-forward pattern already specified for EdgeGuard ([SAD-03 §4.3.3](../../03-edge-vision-inspection/docs/SAD-EdgeGuard-Software-Architecture.md)) — PocketQC reuses its shape (records first, images second, delete after non-rejected).

---

## 2. Architecture principles

| Principle | On PocketQC |
|---|---|
| **P-1 The LLM never computes** → **the model never judges** | There is no LLM on the device. The detection model produces classes and confidences; the checklist's accept rule turns them into a *suggested* step result; below the confidence threshold the step is `REVIEW` and **the inspector must decide**. `model_result_json` and `human_result` are stored side by side and both are synced (FR-11, AI-07). |
| **P-2 Offline-first** → **offline-only is the normal case** | 100 % of inspection works in airplane mode (C-01). Login has a cached window; checklists, SKUs, defect codes and models are cached; the report PDF is generated locally. Sync is opportunistic and must be invisible to the inspector except as a counter (FR-24). |
| **P-3 Human-in-the-loop** | The human is not "in the loop" — the human *is* the loop. Re-judging a finished session needs a supervisor PIN and leaves an audit row (FR-19). |
| **P-4 Database is the source of truth** | The local database is the truth **until sync acknowledges**; after that the server is. Every step commits before the UI advances (FR-16); the UI never holds state the database does not. The server never edits a device record's verdict silently (FR-23). |

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-05 §2.4)
| ID | Constraint | Consequence |
|---|---|---|
| C-01 | 100 % works in airplane mode | No feature may require a request; all caches versioned; offline token |
| C-02 | Model ≤ 25 MB; install ≤ 200 MB | INT8 TFLite; narrow per-SKU-family models; ABI-split APK; models downloaded OTA, not bundled (except one sample set for self-test) |
| C-03 | Inference ≤ 500 ms | Delegate probing (NNAPI → GPU → CPU/XNNPACK); 640 px input; warm-up on step open |
| C-04 | No cloud inference | Only egress: the platform's `/mobile/*` |
| C-05 | Images encrypted at rest | Per-image AES-GCM with a Keystore-wrapped key (ADR-M05) |
| C-06 | Flutter + Dart; native only where required | Platform channels for CameraX, TFLite delegates, Keystore, WorkManager, ML Kit |

### 3.2 Quality attributes
| Attribute | Driver | Design response |
|---|---|---|
| **No data loss** | FR-16, AC-01, AC-03 | Per-step commit; WAL; sync queue in the same DB; resume from `session.current_step` |
| **Exactly-once effect** | FR-20, AC-02 | Client UUIDv7 ids; at-least-once transport; server dedup; `duplicate` = success |
| Speed of work | NFR-02 ≤ 4 min / 20 steps | Barcode auto-select; one-tap OCR correction; framing guide; burst pick; minimal typing |
| Latency | C-03, NFR-01 | Delegate probe cached per device; model kept loaded per session; camera pre-warmed on step open |
| Confidentiality | C-05, NFR-05, NFR-09 | SQLCipher DB; encrypted images; no third-party SDKs that phone home; certificate pinning |
| Resilience | NFR-06, NFR-08 | WorkManager with constraints; idempotent sync steps; crash-safe DB |
| Capacity | NFR-04 | ≥ 5,000 records / 20 GB images; purge policy; low-space warnings at 20 % / 10 % |
| Usability | NFR-07, AC-08 | 48 dp targets; TH/JA/EN runtime switch; fonts embedded for PDF |

### 3.3 Not drivers
iOS (must not be blocked: no Android-only Dart code outside platform channels); video; on-device training; line-side automation (EdgeGuard).

---

## 4. Views

### 4.1 Context view

```
  Inspector ──touch/voice──► ┌──────────────────────────────────────────┐
  Part + lot label ─camera─► │              PocketQC (Android)          │
  Reference marker ─camera─► │ capture · detect · OCR · barcode         │
                             │ measure · checklist · store · sync       │
  MDM (managed config) ────► │ report · security                        │
                             └───────────────┬──────────────────────────┘
                                             │ IF-11 — HTTPS, JWT, at-least-once, UUIDv7
                                             ▼  (when Wi-Fi is present)
                              FactoryBrain platform: /mobile/* (§6)
                              → vision.inspection (source = mobile), review queue, retraining data
```

| Actor / system | Interface | Notes |
|---|---|---|
| Inspector / supervisor | UI (IF-34 for sharing) | TH/JA/EN; gloves; supervisor PIN |
| Camera | [IF-30](ICD-PocketQC-Interface-Control.md#if-30) | CameraX; torch; burst; quality gate |
| On-device models | [IF-31](ICD-PocketQC-Interface-Control.md#if-31) | TFLite + delegates |
| Labels and markings | [IF-32](ICD-PocketQC-Interface-Control.md#if-32) | ML Kit barcode; OCR model |
| MDM / admin | [IF-33](ICD-PocketQC-Interface-Control.md#if-33) | Managed configuration; remote wipe |
| Share targets | [IF-34](ICD-PocketQC-Interface-Control.md#if-34) | PDF report |
| Android Keystore | [IF-35](ICD-PocketQC-Interface-Control.md#if-35) | Keys for DB and images |
| Platform | [IF-11](ICD-PocketQC-Interface-Control.md#if-11) | Client side of the sync contract |

### 4.2 Container view — Flutter layers

```
┌─ PocketQC app process ────────────────────────────────────────────────────────┐
│  ui            screens · i18n (TH/JA/EN) · 48 dp targets · framing overlays   │
│  checklist     steps · kinds · accept rules · session verdict (FR-13, FR-14) │
│  capture       CameraX · quality gate (blur/exposure/glare) · burst · torch   │
│  inference     TFLite · delegate probe · model registry · latency meter       │
│  reading       ML Kit barcode · OCR model · one-tap correction                │
│  measure       ArUco marker → px/mm → value ± tolerance                       │
│  store         Drift/SQLCipher · encrypted image store · purge (DDS-05)       │
│  sync          WorkManager · queue · records→images · bootstrap ETag · OTA    │
│  security      login · offline token · passcode/biometric gate · wipe         │
│  report        PDF (embedded TH/JA fonts) · share sheet                       │
└───────────────────────────────────────────────────────────────────────────────┘
   native (Kotlin via platform channels): CameraX · TFLite delegates · Keystore · WorkManager · ML Kit
```

| Layer | Tech | Responsibility | Native? |
|---|---|---|---|
| `ui` | Flutter, `flutter_localizations` | Screens, guidance, counters, history | no |
| `checklist` | Dart | Checklist model, rule evaluation, verdict | no |
| `capture` | `camera`/CameraX | Frames, quality metrics, EXIF stripping | channel |
| `inference` | `tflite_flutter` + delegates | Load, probe, run, measure | channel (delegates) |
| `reading` | ML Kit barcode; TFLite OCR | Codes and text | channel |
| `measure` | Dart (OpenCV via FFI for ArUco) | Scale and measurement | FFI |
| `store` | Drift + SQLCipher | DDS-05 | channel (key) |
| `sync` | Dart + WorkManager | IF-11 client | channel (scheduling) |
| `security` | Keystore, BiometricPrompt | Keys, gate, wipe | channel |
| `report` | `pdf` package | PDF with embedded fonts | no |

**Process model.** One app process; the sync worker runs under WorkManager and may run without the UI. Both use the same Drift database; Drift serialises writes. Every UI step is a transaction that commits before navigation (ADR-M02).

### 4.3 Component view

#### 4.3.1 Capture and quality gate (FR-01…FR-05)
```
open step ─► camera pre-warm (≤ 1.5 s) ─► framing guide overlay (from checklist step)
   ─► shutter (single | burst 5) ─► per-frame: blur variance · exposure mean · glare ratio
   ─► gate: all within thresholds? ── no ──► "Retake: too dark / blurred / glare" (torch suggestion)
   ─► yes ─► best frame (burst: highest sharpness) ─► EXIF stripped, metadata row written ─► encrypt & store ─► analysis
```
Thresholds come from the checklist step (defaults in managed config). Torch state, timestamp, user, device, step, lot, SKU and optional GPS are recorded with the image (FR-04, FR-05).

#### 4.3.2 On-device inference and delegate probing (FR-06, FR-12, AI-01…03)
```
first run on this device: try NNAPI ─fail─► try GPU ─fail─► XNNPACK CPU   (result cached in device_info.delegate)
model load per session: active model_asset for the step's model name ─► interpreter with cached delegate ─► warm-up 1 frame
per image: preprocess 640 ─► run ─► detections (class, conf, box) ─► latency_ms recorded (AI-03 diagnostics)
```
`model_result_json` stores the detections and the `model_asset.version` used (FR-12). If no model is installed for the step's model name, the step runs in **manual mode**: photo + human verdict, `model_result_json = null` (AI-08, ADR-M10).

#### 4.3.3 Reading: barcode and OCR (FR-07, FR-08)
Barcode (1D/2D) → parsed per the checklist's `identity` pattern → SKU → checklist auto-selected (AC-06). OCR on the lot marking → candidate text with per-character confidence → shown with a **one-tap correction** field; the corrected text and the raw OCR text are both stored.

#### 4.3.4 Measurement (FR-09, AI-05)
ArUco marker of known size in frame → detected corners → px/mm at the marker plane → the user taps two points (or the step defines a template) → value, `± tolerance` from the marker size and distance → compared with `usl`/`lsl` → `in_spec`. Method and marker id are stored. A frame without a valid marker cannot produce a measurement (the step becomes REVIEW).

#### 4.3.5 Checklist engine and verdicts (FR-13…FR-15)
A checklist is versioned JSON (from bootstrap; schema in `deploy/schemas/checklist.schema.json`). Step kinds: `photo_ai`, `photo`, `barcode`, `ocr`, `measure`, `check`. Each step yields `suggested_result` (model/rule) and `human_result`. Rules:

| Step kind | Suggested result | Becomes REVIEW when |
|---|---|---|
| `photo_ai` | `accept.no_class_above` evaluated on detections | any class confidence within the review band (default ±0.1 of its threshold), or model missing |
| `measure` | `in_spec` | no marker / out of working distance / value within 5 % of a limit |
| `barcode`, `ocr` | parsed / read | OCR char confidence < 0.9 |
| `photo`, `check` | none — human only | — |

Session verdict = `verdict_rule` over the **human results** (default: FAIL if any FAIL; REVIEW if any REVIEW; else PASS). A session cannot finish with an undecided REVIEW step (DB trigger, DDS-05).

#### 4.3.6 Store-and-forward (FR-20…FR-26)
```
finish session ─► session + steps + measurements committed ─► enqueue(session)  [images enqueued separately, after]
WorkManager (Wi-Fi by default, charging not required):
   1. bootstrap: GET /mobile/bootstrap If-None-Match ─► 304 | 200 → replace caches atomically (server wins, FR-23)
   2. policy:    GET /mobile/policy → retention/sync/wipe; wipe command → §4.4.7
   3. sessions:  POST /mobile/sessions:batch (≤ 200) → 207: accepted|duplicate → synced_at; rejected → attempts++, backoff
   4. images:    resumable upload per image (sha256 verified) → uploaded_at
   5. models:    GET /mobile/models → new version → download → sha256 → self-test → activate (§4.3.7)
   6. heartbeat: pending counts, versions, storage
```
Conflict rules (FR-23): master data — server wins; inspection records — **device wins**: the server stores what the device sent and may add its own review later as a separate override, never by changing the device's `human_result`.

#### 4.3.7 Model OTA (FR-26, AI-06)
download → `sha256` equals manifest → **self-test on the bundled sample images** (expected classes must be detected within tolerance, latency within budget on this device) → `selftest_passed_at` → activate; previous kept for rollback; failure → previous stays, event synced.

#### 4.3.8 Session persistence and resume (FR-16, AC-03)
Every step result is written in a transaction *before* the next step is shown; `session.current_step` advances in the same transaction. On app start, an unfinished session is offered for resume at `current_step`. Images are written to the encrypted store before their row is committed, so a row never points at a missing file.

#### 4.3.9 Purge (FR-30, NFR-04)
Synced sessions older than the policy's `retention_days` (default 60) are purged with their images; unsynced data is never purged; low-space warnings at 20 % and 10 % free; below 10 % PASS-step images of synced sessions go first (`v_purge_candidates`).

### 4.4 Runtime views

#### 4.4.1 A 20-step inspection in ≤ 4 minutes (NFR-02)
```
scan lot label (3 s) → checklist auto-selected → step 1 photo_ai: camera ready 1.2 s, capture, gate ok, inference 320 ms, PASS suggested (2 s to confirm)
… 14 photo steps × ~9 s · 3 measure steps × ~15 s · 2 check steps × ~4 s · OCR step 6 s
→ finish: verdict PASS, PDF available, "pending sync: 1"                       ≈ 3 min 20 s
```

#### 4.4.2 Airplane-mode day, then Wi-Fi (AC-01, AC-02)
50 sessions completed offline → pending 50; on Wi-Fi: bootstrap 304, sessions in one batch (207: 50 accepted), images 180 resumable uploads in the background, heartbeat. A second run of the same batch (e.g. after a crash mid-207) returns `duplicate` ×50 — success, no duplicates centrally.

#### 4.4.3 Force-kill mid-session (AC-03)
At step 7: results of steps 1–6 committed; app killed; relaunch → "Resume session RAD-500 lot L2-…, step 7 of 20" → continue. No data lost by construction (ADR-M02).

#### 4.4.4 REVIEW step
Model: `scratch 0.38` against threshold 0.4 → review band → step marked REVIEW with the box drawn → inspector taps PASS or FAIL (defect code, severity, note) → `human_result` stored; `model_result_json` kept → both synced (AI-07 retraining data).

#### 4.4.5 Offline login (FR-27)
Online login → JWT + refresh cached in secure storage with `offline_valid_until = now + 30 d` (managed config). Offline: passcode/biometric gate (FR-29) → cached token still valid → app opens. Expired offline → read-only history until online login. Admin can shorten the window centrally via policy.

#### 4.4.6 Model update with failed self-test (FR-26)
v1.1.0 downloaded → sha256 ok → self-test: recall on samples 0.80 < 0.95 → **not activated**, `selftest_failed` event synced; v1.0.0 stays active. Fleet admin sees it in the heartbeat.

#### 4.4.7 Remote wipe (FR-28)
Device reported lost → admin marks it → next `GET /mobile/policy` / commands returns `wipe` → app deletes DB, images, keys, tokens; posts acknowledgement; shows "device wiped — contact admin". Unsynced data on that device is lost — by design (the alternative is exposure).

#### 4.4.8 Storage low
20 % free: banner; PASS images compressed harder; 10 %: purge synced PASS images first; refuse new burst capture (single only); still never purges unsynced data.

### 4.5 Deployment view

| Aspect | Design |
|---|---|
| Device class | Android 10+ (target 14), ARM64, ≥ 4 GB RAM, autofocus camera, ≥ 8 GB free; certified list in OPS-05 |
| Distribution | Android Enterprise managed devices; app via managed Play or private APK; **managed configuration** carries server URL, sync policy, GPS toggle, offline days (ADR-M09) |
| Size | ABI-split release ≤ 200 MB incl. one sample-image set; models OTA ≤ 25 MB each |
| Network | Only the platform's `/mobile/*` over HTTPS with certificate pinning; no analytics SDKs (NFR-09) |
| Storage | App-private directories; SQLCipher DB; encrypted image files; Android backup **disabled** |
| Background | WorkManager periodic (15 min min) + on-connectivity; expedited on manual sync |

### 4.6 Data view
Owned by [DDS-05](DDS-PocketQC-Local-Database-Design.md). SQLite via Drift, SQLCipher; the record shape maps to IF-11 `MobileSession` by [`db/payload_mapping.json`](../db/payload_mapping.json).

---

## 5. Cross-cutting concerns

| Concern | Position |
|---|---|
| Identity | Company credentials → platform JWT; offline window; `user_id` on every record |
| Device identity | `device_id` (managed-config-provisioned, not hardware serial); appears on every record and heartbeat |
| Authorisation | Inspector; supervisor PIN (re-judge); admin on the platform. No local admin |
| Secrets | Tokens in EncryptedSharedPreferences/Keystore; DB and image keys wrapped by Keystore (IF-35); nothing in plain prefs or logs |
| Configuration | Managed configuration (IF-33) > `/mobile/policy` > bootstrap; the app has no local settings that weaken security |
| Observability | Heartbeat (pending, versions, storage, latency p95, delegate); support bundle (redacted logs); crash reporting **local only** (NFR-09) |
| Logging | No image bytes, no lot text, no tokens in logs |
| Time | Device time recorded with `tz` offset; server records receipt time; skew > 5 min flagged by the server |
| i18n | TH default, JA/EN switch at runtime; PDF embeds Noto Sans Thai / JP |

---

## 6. Platform relationship — the IF-11 contract PocketQC needs

PocketQC is a **client** of FactoryBrain's `/mobile/*`. Today [API-00](../../00-factorybrain-platform/api/openapi.yaml) defines `GET /mobile/bootstrap` and `POST /mobile/sessions:batch` with a loose `MobileSession.steps: object[]`. SRS-05 §4.1 requires more. [`api/openapi.yaml`](../api/openapi.yaml) specifies the contract *as PocketQC needs it* — existing parts copied verbatim and diffed (TEST-05 TC-008), additions marked **proposed v1.1**:

| Endpoint | In API-00 today | PocketQC needs | Status |
|---|---|---|---|
| `GET /mobile/bootstrap` | ✅ | ETag, checklists/SKUs/defect codes/models | identical |
| `POST /mobile/sessions:batch` | ✅ (steps untyped) | typed `MobileSessionStep` (model + human results, image refs, measurements) | **additive refinement** |
| `POST /mobile/auth`, `/mobile/auth/refresh` | ❌ | login, offline window | **proposed** |
| `GET /mobile/models`, `…/download` | ❌ (manifests only inside bootstrap) | ranged download, sha256 | **proposed** |
| `POST/PATCH/HEAD /mobile/images` | ❌ | resumable upload | **proposed** |
| `GET /mobile/policy` | ❌ | retention, sync, wipe | **proposed** |
| `POST /mobile/devices/{id}/heartbeat`, `GET …/commands` | ❌ | fleet view, remote wipe | **proposed** |

Server-side landing: `vision.inspection` with `source = 'mobile'` (one row per `photo_ai` step), `vision.measurement`, `vision.verdict_override` for human-vs-model disagreements (AI-07), images in object storage (IF-10). Recorded as a gap in README-05.

---

## 7. Architecture Decision Records

### ADR-M01 — SQLite via Drift with SQLCipher
**Context.** Offline store with typed Dart access, encryption at rest (NFR-05). **Decision.** Drift (type-safe, migrations, reactive queries) on SQLCipher; WAL; one database for records, queue and caches so a step and its enqueue are one transaction. **Consequences.** ✅ one crash domain; ❌ SQLCipher adds ~7 MB — within budget.

### ADR-M02 — Every step commits before the UI advances
**Context.** FR-16, AC-03. **Decision.** Step result + image row + `current_step` in one transaction; navigation only after commit; image file written before its row. **Consequences.** ✅ resume is trivial and exact; ❌ ~20 ms per step — invisible.

### ADR-M03 — The model never decides; both results are stored
**Context.** FR-10, FR-11, AI-07. **Decision.** `suggested_result` from model/rule and `human_result` from the inspector are separate columns; a session cannot finish with an undecided REVIEW step (trigger); both are synced. **Consequences.** ✅ retraining data and accountability; ❌ one more tap on REVIEW steps — intended.

### ADR-M04 — Delegate probing with CPU fallback, cached per device
**Context.** Device fragmentation (SRS §10). **Decision.** Probe NNAPI → GPU → XNNPACK once, cache in `device_info`; re-probe on app update or driver change; latency reported in diagnostics. **Consequences.** ✅ works everywhere; ❌ CPU devices may exceed 500 ms — flagged, not blocked.

### ADR-M05 — Images encrypted individually with a Keystore-wrapped key
**Context.** C-05. **Decision.** AES-256-GCM per file with a random data key wrapped by an Android Keystore key (StrongBox when available); file names are UUIDs; thumbnails encrypted too. **Consequences.** ✅ a copied storage tree is useless; ❌ decrypt on view (~10 ms) — fine.

### ADR-M06 — Records first, images second; UUIDv7; delete only after acknowledgement
**Context.** FR-20, AC-02; same pattern as EdgeGuard (ADR-E09). **Decision.** Session batch → 207; `accepted`/`duplicate` mark synced; images upload only for synced sessions; nothing is purged unsynced. **Consequences.** ✅ zero loss/zero duplicates by construction; ❌ images lag — acceptable.

### ADR-M07 — Server wins for master data, device wins for records
**Context.** FR-23, IF-11. **Decision.** Bootstrap replaces caches atomically; a device record is stored as sent; server-side changes are *overrides* linked to it. **Consequences.** ✅ inspectors' judgements are never silently altered; ❌ a checklist change mid-session applies to the next session only.

### ADR-M08 — Model OTA gated by an on-device self-test
**Context.** FR-26, AI-06. **Decision.** Activation requires sha256 match **and** a passed self-test on bundled samples on *this* device (recall and latency); previous kept. **Consequences.** ✅ a model that is fine on the server but slow/wrong on this phone never activates; ❌ ~10 s per update.

### ADR-M09 — Managed configuration is the only provisioning channel
**Context.** Company-managed devices (SRS §2.5). **Decision.** Server URL, pinned cert hashes, sync policy, GPS toggle, offline days, allowed share targets come from Android Enterprise managed configuration; the app has no settings screen that can change them. **Consequences.** ✅ no misconfigured devices; ❌ requires MDM — an assumption the SRS already makes.

### ADR-M10 — Manual mode when no model is installed
**Context.** AI-08, AC-07. **Decision.** `photo_ai` steps degrade to photo + human verdict with `model_result_json = null`; nothing blocks work. **Consequences.** ✅ never blocked; ❌ no AI assistance — surfaced on the step and in the heartbeat.

---

## 8. Quality attribute scenarios

| ID | Scenario | Measure | Traces |
|---|---|---|---|
| QAS-01 | 50 inspections in airplane mode | 0 errors, 0 data loss | AC-01, C-01 |
| QAS-02 | Reconnect after the day | 50 synced, 0 duplicates, 0 missing images; batch replay yields `duplicate` only | AC-02, FR-20 |
| QAS-03 | Force-kill at step 7 | Resume at step 7 with steps 1–6 intact | AC-03, FR-16 |
| QAS-04 | Reference device, production model | ≤ 500 ms p95; mAP/recall gates | AC-04, AI-02, AI-03 |
| QAS-05 | Gauge ×30 | within ±0.5 mm | AC-05, AI-05 |
| QAS-06 | 20 sample labels | 20/20 correct checklist | AC-06, FR-08 |
| QAS-07 | Model uninstalled | Manual mode, work continues | AC-07, AI-08 |
| QAS-08 | Thai/Japanese UI and PDF | Renders correctly | AC-08, NFR-07 |
| QAS-09 | Device lost | DB and images unreadable; wipe on next connect | C-05, FR-28 |
| QAS-10 | 20-step inspection | ≤ 4 min | NFR-02 |
| QAS-11 | 6 h shift | Battery lasts | NFR-03 |
| QAS-12 | Model update fails self-test | Previous stays active; event synced | FR-26 |

---

## 9. Risks and technical debt

| Risk | Mitigation | Residual |
|---|---|---|
| Delegate crashes on some devices | Probe in a separate isolate with timeout; CPU fallback; certified list | Slower CPU-only devices |
| Poor lighting | Gate + torch + guidance; ring light option | Retakes cost time |
| Storage exhaustion | Compression, purge policy, warnings | Long offline periods with many FAIL images |
| Small model too weak | Narrow per-SKU-family models; REVIEW band | More REVIEW taps |
| Inspectors bypass the app | ≤ 4 min target; barcode auto-select | Culture |
| Lost device | Encryption, passcode, wipe | Unsynced data on a wiped device is gone |
| Platform IF-11 v1.1 not implemented yet | Contract specified here; gap tracked | Sync of images/models/policy blocked until then |

Debt: measurement via two taps (no auto edge detection in v1); OCR limited to the lot-code font set; iOS untested (architecture keeps it possible).

---

## 10. Traceability to SRS-05

| SRS-05 | Architecture |
|---|---|
| C-01…C-06 | §3.1 |
| FR-01…05 | §4.3.1 |
| FR-06, FR-12, AI-01…03 | §4.3.2, ADR-M04 |
| FR-07, FR-08 | §4.3.3 |
| FR-09, AI-05 | §4.3.4 |
| FR-10, FR-11, AI-07 | §4.3.5, ADR-M03 |
| FR-13…FR-15 | §4.3.5 |
| FR-16 | §4.3.8, ADR-M02 |
| FR-17, FR-18 | `report`, `store` views (DDS-05) |
| FR-19 | P-3, DDS-05 audit trigger |
| FR-20…FR-25 | §4.3.6, ADR-M06, ADR-M07 |
| FR-26, AI-06 | §4.3.7, ADR-M08 |
| FR-27…FR-29 | §4.4.5, §4.4.7, §5 |
| FR-30 | §4.3.9 |
| AI-04 | §4.3.3, TEST-05 |
| AI-08 | ADR-M10 |
| NFR-01…09 | §3.2, §4.5 |
| AC-01…08 | §8 |
