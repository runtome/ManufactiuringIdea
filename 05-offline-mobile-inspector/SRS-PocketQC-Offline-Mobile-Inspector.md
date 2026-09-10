# Software Requirements Specification — Offline AI Mobile Inspector

| Field | Value |
|---|---|
| Document ID | SRS-05-PocketQC |
| Project code name | **PocketQC** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify an **Android (Flutter) inspection app** that runs defect detection, OCR, barcode reading and dimensional measurement entirely on-device, stores results locally, and synchronises to the central platform when connectivity returns.

The driving constraint: factory Wi-Fi is unreliable or absent in many areas, but inspection cannot wait for the network.

### 1.2 Scope

**In scope**
- On-device inference (TFLite / ONNX Runtime Mobile / NNAPI-GPU delegate).
- Guided inspection flows (checklists per part/SKU) with photo evidence.
- Barcode/QR scanning and OCR of lot and part markings.
- Reference-object-based dimensional measurement.
- Offline database, inspection history, and conflict-safe sync.
- Thai / Japanese / English UI.

**Out of scope**
- iOS (v1 Android only; architecture must not block iOS later).
- Model training on-device.
- Continuous video inspection (single/burst photo capture only).
- Line-side automatic inspection — that is [EdgeGuard (SRS-03)](../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md).

### 1.3 Definitions
**Inspection session** = one checklist run for one part/lot. **Sync** = bidirectional exchange with the server. **Reference object** = a known-size marker (ArUco / coin / gauge) used to derive px→mm scale.

---

## 2. Overall Description

### 2.1 Product perspective
```
Android phone / tablet
   camera → capture (with quality gate)
        ↓
   on-device model (TFLite / ONNX, NNAPI or GPU delegate)
        ↓
   defect classes · OCR text · barcode · measurements
        ↓
   local DB (SQLite/Drift) + encrypted image store
        ↓
   sync engine (queue, retry, conflict resolution)
        ↓ when online
   Central platform (FactoryBrain) → dashboard / agent
```

### 2.2 User classes
| Class | Need |
|---|---|
| Roaming QC inspector | fast capture, offline, minimal typing |
| Incoming inspection staff | supplier lot checks with evidence |
| Line supervisor | spot checks, immediate result |
| Quality engineer | reviews synced records centrally |
| Admin | assigns checklists, models, users |

### 2.3 Operating environment
Android 10+ (target 14), 4 GB+ RAM mid-range device, ARM64. Camera with autofocus. Storage ≥ 8 GB free. Optional external ring light. Intermittent Wi-Fi; no cellular assumed.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | 100 % of inspection functionality MUST work with airplane mode on. |
| C-02 | Model size ≤ 25 MB per model; total app install ≤ 200 MB. |
| C-03 | Inference ≤ 500 ms per image on the reference mid-range device. |
| C-04 | No cloud inference call is permitted for the core flow. |
| C-05 | Images stored on-device MUST be encrypted at rest. |
| C-06 | Flutter + Dart; native platform channels only where required (camera, delegates). |

### 2.5 Assumptions
Inspectors carry company-managed devices; checklists and models are provisioned before going offline; devices reconnect to Wi-Fi at least daily.

---

## 3. Functional Requirements

### 3.1 Capture
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | The app SHALL capture photos with an on-screen framing guide per checklist step. | Must |
| FR-02 | The app SHALL run a quality gate (blur, exposure, glare) and prompt for retake before analysis. | Must |
| FR-03 | The app SHALL support burst capture and let the user pick the best frame. | Should |
| FR-04 | The app SHALL attach metadata: timestamp, user, device, GPS (optional, configurable), checklist step, lot, SKU. | Must |
| FR-05 | Torch/flash SHALL be toggleable and its state recorded with the image. | Should |

### 3.2 On-device AI
| ID | Requirement | Priority |
|---|---|---|
| FR-06 | The app SHALL run defect detection/classification on-device and display classes with confidence and boxes. | Must |
| FR-07 | The app SHALL run OCR on-device to read lot/part codes and allow one-tap correction. | Must |
| FR-08 | The app SHALL scan 1D/2D barcodes to identify the part and auto-select the checklist. | Must |
| FR-09 | The app SHALL measure dimensions using a reference object or a calibrated fixed distance, reporting value ± tolerance. | Should |
| FR-10 | Low-confidence results SHALL be marked REVIEW and require the inspector's judgement. | Must |
| FR-11 | The inspector's final judgement SHALL always override the model, and both values SHALL be stored. | Must |
| FR-12 | The app SHALL support multiple model versions and indicate which was used per record. | Must |

### 3.3 Inspection workflow
| ID | Requirement | Priority |
|---|---|---|
| FR-13 | Checklists SHALL be configurable per SKU: ordered steps, required photos, measurements, accept criteria. | Must |
| FR-14 | The app SHALL compute an overall session verdict from step results and configured rules. | Must |
| FR-15 | The inspector SHALL be able to add a note, a defect code and a severity to any step. | Must |
| FR-16 | Sessions SHALL be resumable after app kill or device restart with no data loss. | Must |
| FR-17 | The app SHALL show inspection history with search by lot, SKU, date and verdict. | Must |
| FR-18 | The app SHALL generate a local PDF inspection report shareable via any Android share target. | Should |
| FR-19 | The app SHALL support a supervisor PIN to unlock re-judging a completed session. | Should |

### 3.4 Sync
| ID | Requirement | Priority |
|---|---|---|
| FR-20 | The sync engine SHALL upload records first and images second, resumable and at-least-once with server-side dedup by UUID. | Must |
| FR-21 | Sync SHALL be automatic on Wi-Fi (configurable: Wi-Fi only / any network) and manually triggerable. | Must |
| FR-22 | The app SHALL download checklist, SKU, defect-code and model updates during sync. | Must |
| FR-23 | Conflicts SHALL be resolved as: server wins for master data, device wins for inspection records (server never edits a record's verdict silently). | Must |
| FR-24 | The UI SHALL always show pending-sync count and last successful sync time. | Must |
| FR-25 | Images SHALL be compressed (configurable quality/max edge) before upload; the original stays on device until purge. | Should |
| FR-26 | A model update SHALL be verified by checksum and applied only after a successful self-test on bundled sample images. | Must |

### 3.5 Administration & security
| ID | Requirement | Priority |
|---|---|---|
| FR-27 | Login with company credentials; offline login via a cached token valid for a configurable period (default 30 days). | Must |
| FR-28 | Remote wipe of local data SHALL be possible on next connect for a lost device. | Should |
| FR-29 | The app SHALL enforce a device passcode/biometric before opening. | Should |
| FR-30 | Local data SHALL be purged per policy (e.g. synced records older than 60 days). | Must |

---

## 4. External Interfaces

### 4.1 Server API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/mobile/auth` | login, token issue |
| GET | `/api/v1/mobile/bootstrap?etag=` | checklists, SKUs, defect codes |
| GET | `/api/v1/mobile/models` | model manifest (version, url, sha256, size) |
| POST | `/api/v1/mobile/sessions:batch` | upload inspection sessions |
| POST | `/api/v1/mobile/images` | resumable image upload |
| GET | `/api/v1/mobile/policy` | retention, sync and wipe policy |

### 4.2 Device
CameraX, NNAPI / GPU delegate, ML Kit or on-device OCR model, secure storage (Keystore-backed), WorkManager for background sync.

---

## 5. Data Requirements

```sql
-- on-device (Drift/SQLite)
session(uuid PK, checklist_id, sku, lot, started_at, finished_at, verdict,
        user_id, device_id, synced_at)
step_result(uuid PK, session_uuid, step_no, kind, model_result_json,
            human_result, note, defect_code, severity, image_uuid)
image(uuid PK, path_encrypted, sha256, width, height, captured_at, uploaded_at)
measurement(uuid PK, step_uuid, name, value, unit, usl, lsl, in_spec, method)
sync_queue(id, entity, entity_uuid, attempts, last_error, next_retry_at)
model_asset(name, version, sha256, path, installed_at, active)
```

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Detection model: YOLO11-n or MobileNet-SSD/EfficientDet-lite exported to TFLite INT8, ≤ 25 MB. |
| AI-02 | Acceptance on the mobile hold-out set: mAP@50 ≥ 0.75, **recall ≥ 0.95 on critical defects**; INT8 must stay within 3 % of FP32 mAP. |
| AI-03 | Inference ≤ 500 ms p95 on the reference device; the app SHALL report measured latency in diagnostics. |
| AI-04 | OCR SHALL achieve ≥ 95 % character accuracy on the lot-code font set under normal lighting. |
| AI-05 | Measurement accuracy ≤ ±0.5 mm with a reference marker at the specified working distance. |
| AI-06 | Models SHALL be delivered over-the-air with checksum verification, self-test and rollback to the previous version. |
| AI-07 | Human overrides SHALL be exported centrally as retraining data with the image and both labels. |
| AI-08 | The app SHALL degrade to manual inspection (photo + human verdict) if no model is installed, never blocking work. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Cold start ≤ 3 s; camera ready ≤ 1.5 s after opening a step. |
| NFR-02 | A full 20-step inspection SHALL be completable in ≤ 4 minutes including capture. |
| NFR-03 | Battery: ≥ 6 h of intermittent inspection use on the reference device. |
| NFR-04 | The app SHALL store ≥ 5,000 offline records and ≥ 20 GB of images subject to free space. |
| NFR-05 | Image storage encrypted with a Keystore-backed key; DB encrypted (SQLCipher or equivalent). |
| NFR-06 | Sync SHALL survive process death and network changes (WorkManager constraints). |
| NFR-07 | UI localised TH / JA / EN with runtime switching; touch targets ≥ 48 dp for gloved use. |
| NFR-08 | Crash-free session rate ≥ 99.5 %. |
| NFR-09 | No analytics or images sent to third-party services. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Airplane mode: 50 complete inspections performed with no errors or data loss. |
| AC-02 | After reconnect, all 50 sync with 0 duplicates and 0 missing images. |
| AC-03 | Force-kill mid-session: session resumes at the same step with prior results intact. |
| AC-04 | Model metrics on the hold-out set meet AI-02; latency meets AI-03 on the reference device. |
| AC-05 | Measurement of a calibrated gauge ×30 repeats within ±0.5 mm. |
| AC-06 | Barcode scan auto-selects the correct checklist for 20/20 sample labels. |
| AC-07 | Uninstalling the model leaves the app usable in manual mode. |
| AC-08 | Japanese and Thai UI render correctly, including PDF report output. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | Flutter shell, camera, capture quality gate, local DB |
| P2 | 3–4 | TFLite integration, detection + confidence UI, latency benchmark |
| P3 | 5 | barcode + OCR + checklist engine |
| P4 | 6 | measurement with reference marker |
| P5 | 7–8 | sync engine, model OTA, conflict rules |
| P6 | 9–10 | history, PDF report, i18n, security hardening, field trial |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Device fragmentation (delegate support varies) | runtime delegate probing with CPU fallback; certified device list |
| Poor lighting in the factory | quality gate + torch + optional ring light + guidance overlay |
| Storage exhaustion offline | compression, retention policy, low-space warnings at 20 %/10 % |
| Model too weak at small size | task-specific narrow models per SKU family rather than one big model |
| Inspectors bypass the app for speed | ≤ 4 min flow target, barcode auto-selection, minimal typing |
| Lost device with quality data | encryption at rest, passcode, remote wipe |

---

## Appendix A — Checklist definition sketch

```yaml
checklist: RAD-500-A-incoming
version: 3
steps:
  - no: 1
    kind: photo_ai
    title_th: "ถ่ายด้านหน้า"
    title_ja: "正面を撮影"
    model: defect-yolo11n-int8
    classes: [scratch, dent, missing_fin]
    accept: { no_class_above: { scratch: 0.4, dent: 0.4, missing_fin: 0.25 } }
  - no: 2
    kind: barcode
    title_en: "Scan lot label"
  - no: 3
    kind: measure
    name: fin_pitch
    usl: 3.2
    lsl: 2.8
    unit: mm
    method: aruco_reference
verdict_rule: "FAIL if any step FAIL; REVIEW if any step REVIEW; else PASS"
```
