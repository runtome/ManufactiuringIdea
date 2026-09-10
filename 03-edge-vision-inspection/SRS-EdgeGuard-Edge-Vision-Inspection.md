# Software Requirements Specification — Edge AI Quality Inspection Node

| Field | Value |
|---|---|
| Document ID | SRS-03-EdgeGuard |
| Project code name | **EdgeGuard** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify the **on-premise inference node** that performs quality inspection next to the production line without sending images to the cloud: low latency, data privacy, and continued operation when the network is down.

Where [VisionOps (SRS-01)](../01-factory-inspector-agent/SRS-AI-Factory-Inspector-Agent.md) defines the *intelligence* layer, EdgeGuard defines the *runtime* layer: the box, the model runtime, the buffering and the sync protocol.

### 1.2 Scope

**In scope**
- Edge device software stack: camera driver, inference runtime, rules, local DB, local UI.
- Model deployment, versioning and rollback on the edge.
- Store-and-forward sync to the central platform.
- Local operator HMI (PASS / FAIL / REVIEW) and human review.
- Device health, remote monitoring and OTA-style model/config updates.

**Out of scope**
- The central dashboard and agent (SRS-01 / SRS-00).
- Safety-rated rejection interlocks (PLC responsibility).
- Mobile inspection (see [PocketQC, SRS-05](../05-offline-mobile-inspector/SRS-PocketQC-Offline-Mobile-Inspector.md)).

### 1.3 Definitions
**Node** = one edge device serving one or more cameras. **Store-and-forward** = buffer results locally, push when connectivity returns. **Recipe** = per-SKU inspection configuration.

---

## 2. Overall Description

### 2.1 Product perspective
```
    Camera
      ↓ (GigE / USB3 / CSI)
┌─────────────────────────────────────────┐
│  EDGE NODE  (Jetson Orin / mini-PC)     │
│  capture → preprocess → model runtime   │
│      → rules engine → verdict           │
│  local SQLite/Postgres + image cache    │
│  local HMI (kiosk browser)              │
│  sync agent (store-and-forward)         │
└──────────────┬──────────────────────────┘
               │ HTTPS (batched, resumable)
               ▼
     Central platform  →  Cloud/LAN dashboard
```

### 2.2 User classes
Operator (HMI only), Inspector (local review), Line leader (shift totals), Maintenance/Admin (device health, model updates).

### 2.3 Operating environment
| Item | Spec |
|---|---|
| Reference device | NVIDIA Jetson Orin Nano 8 GB, JetPack 6 |
| Alternative | x86 mini-PC + RTX A2000/3060, Ubuntu 22.04 |
| Low-cost option | Raspberry Pi 5 + Hailo-8L (INT8 models only) |
| Storage | ≥ 256 GB SSD (image buffer) |
| Environment | 0–45 °C, dusty; fanless/IP-rated enclosure preferred |
| Network | factory LAN, may be intermittent or absent |

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | Inspection MUST continue with zero network connectivity for ≥ 72 hours. |
| C-02 | No raw image may leave the node unless the central sync policy allows it. |
| C-03 | Model runtime: ONNX Runtime or TensorRT; models quantised to FP16/INT8 as needed to meet latency. |
| C-04 | Whole stack containerised; a node MUST be reprovisionable from an image + config file in ≤ 30 min. |
| C-05 | Unattended operation: the node MUST auto-recover from power loss without human action. |

### 2.5 Assumptions
Fixed camera mount and controlled lighting; the central platform is reachable at least intermittently; SKU/recipe selection is available from PLC tag, barcode or operator input.

---

## 3. Functional Requirements

### 3.1 Capture & preprocessing
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Support hardware trigger, software trigger and free-run capture modes. | Must |
| FR-02 | Apply per-recipe preprocessing: ROI crop, resize, white balance, undistort with stored calibration. | Must |
| FR-03 | Reject frames failing a focus/exposure gate and log them as NO_READ with the reason. | Must |
| FR-04 | Support multiple cameras per node with independent recipes and a shared GPU queue. | Should |

### 3.2 Inference
| ID | Requirement | Priority |
|---|---|---|
| FR-05 | Run object detection on each frame and output class, confidence, bbox. | Must |
| FR-06 | Optionally run segmentation for area, OCR for codes, and classical CV for dimensional measurement. | Should |
| FR-07 | Run an anomaly-detection model to flag out-of-distribution parts not covered by trained classes. | Should |
| FR-08 | Apply the recipe rule set to produce PASS / FAIL / REVIEW plus a per-defect confidence score. | Must |
| FR-09 | Support multi-frame tracking so one physical part inspected in N frames yields ONE verdict. | Should |
| FR-10 | Emit the verdict to digital I/O and/or MQTT within 100 ms of decision. | Must |

### 3.3 Local storage & evidence
| ID | Requirement | Priority |
|---|---|---|
| FR-11 | Persist every inspection locally (record + detections + measurements) before acknowledging. | Must |
| FR-12 | Store the original frame and annotated overlay for FAIL/REVIEW; store PASS images per a configurable sampling rate. | Must |
| FR-13 | Enforce a disk-usage policy: when free space < 15 %, purge oldest synced PASS images first; never purge unsynced records. | Must |
| FR-14 | Provide a local audit log of verdicts, overrides, config and model changes. | Must |

### 3.4 Local HMI & review
| ID | Requirement | Priority |
|---|---|---|
| FR-15 | Full-screen HMI showing live verdict, last image with overlay, shift counters and defect Pareto. | Must |
| FR-16 | Large, glove-usable touch targets; Thai UI with JA/EN switch. | Must |
| FR-17 | Inspector may override a verdict locally; overrides queue for sync with user id and reason. | Must |
| FR-18 | HMI shows connection status, buffer depth, model version and last sync time. | Must |
| FR-19 | HMI SHALL clearly indicate degraded mode (e.g. anomaly-only, or camera fault). | Must |

### 3.5 Sync & fleet management
| ID | Requirement | Priority |
|---|---|---|
| FR-20 | The sync agent SHALL push records in batches with resumable, at-least-once delivery and server-side dedup by record UUID. | Must |
| FR-21 | Images SHALL sync at a lower priority than records, with bandwidth throttling and an optional schedule window. | Must |
| FR-22 | The node SHALL pull recipe and threshold updates from the central platform and apply them atomically. | Must |
| FR-23 | The node SHALL support model update: download → checksum verify → shadow-run on a validation set → promote or roll back. | Must |
| FR-24 | The node SHALL keep the previous model and config and allow one-command rollback. | Must |
| FR-25 | The node SHALL report health every 60 s: CPU, GPU, temperature, disk, fps, buffer depth, camera state, uptime. | Must |
| FR-26 | Central SHALL alert when a node misses 3 consecutive heartbeats. | Must |

---

## 4. External Interfaces

### 4.1 Node → Central
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/edge/records:batch` | push inspection batch (idempotent by UUID) |
| POST | `/api/v1/edge/images` | upload evidence (multipart, resumable) |
| GET | `/api/v1/edge/config?node=&etag=` | pull recipes/thresholds |
| GET | `/api/v1/edge/models?node=` | model manifest (version, url, sha256) |
| POST | `/api/v1/edge/heartbeat` | health payload |

Auth: per-node API key or mTLS client certificate.

### 4.2 Node local
- HMI: `http://localhost:8080` (kiosk).
- Local REST: `/inspect`, `/status`, `/records`, `/override`.
- MQTT out: `factory/{line}/{station}/verdict`, `.../health`.
- Digital I/O: PASS/FAIL/READY lines via GPIO or an I/O module.

---

## 5. Data Requirements

```sql
-- local (SQLite or embedded Postgres)
inspection(uuid PK, ts, camera_id, sku, lot, verdict, model_version,
           recipe_version, latency_ms, image_path, overlay_path, synced_at)
detection(id, inspection_uuid, class, confidence, bbox_json)
measurement(id, inspection_uuid, name, value, unit, usl, lsl, in_spec)
override(id, inspection_uuid, new_verdict, user, reason, ts, synced_at)
sync_queue(id, entity, entity_uuid, attempts, last_error, next_retry_at)
node_event(id, ts, kind, detail_json)   -- boot, model_change, config_change, fault
```

Local retention: unsynced records forever (until synced); synced records 30 days; FAIL images 90 days locally.

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Models deployed as ONNX; TensorRT engines built **on the target device** and cached with a device+version key. |
| AI-02 | INT8 quantisation permitted only if hold-out recall on critical classes stays ≥ 0.98 relative to FP16. |
| AI-03 | Each model artefact SHALL carry a manifest: version, sha256, input size, class map, expected metrics, calibration data id. |
| AI-04 | Before promotion, a new model SHALL run in shadow mode on ≥ 200 live frames and its disagreement rate with the current model SHALL be reported. |
| AI-05 | Anomaly model (PatchCore / PaDiM / autoencoder) trained on PASS-only data SHALL provide an OOD score per frame. |
| AI-06 | The node SHALL log per-frame inference latency and GPU memory for capacity planning. |
| AI-07 | On model load failure the node SHALL fall back to the previous model and raise an alarm — never run with no model silently. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Inference latency ≤ 100 ms p95 per frame at the deployed resolution. |
| NFR-02 | End-to-end (trigger → I/O verdict) ≤ 200 ms p95. |
| NFR-03 | Sustained ≥ 10 FPS on the reference device with the production model. |
| NFR-04 | ≥ 72 h fully offline operation with ≥ 100 k buffered records. |
| NFR-05 | Cold boot to inspecting ≤ 90 s after power restore, unattended. |
| NFR-06 | Uptime ≥ 99.5 % during production shifts; watchdog restarts a hung service within 30 s. |
| NFR-07 | All node↔central traffic over TLS; node identity via key or client cert; keys rotatable. |
| NFR-08 | Disk-full condition SHALL degrade gracefully (stop storing PASS images) and never stop inspection. |
| NFR-09 | Provisioning: flash image + `node.yaml` → operational in ≤ 30 min without a developer. |
| NFR-10 | Remote diagnostics available without shell access (health API + log bundle download). |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Latency and FPS measured over 1 h of live production meet NFR-01…03. |
| AC-02 | Network unplugged for 72 h: inspection continues, 0 records lost, all sync on reconnect. |
| AC-03 | Hard power cut × 10: node returns to inspecting each time, DB not corrupted. |
| AC-04 | Model update applied remotely, shadow report generated, rollback executed successfully. |
| AC-05 | Disk filled to 90 %: purge policy runs, unsynced records preserved. |
| AC-06 | Duplicate batch push results in no duplicate rows centrally. |
| AC-07 | Operator can read the HMI and act correctly with gloves at 1 m distance (usability walkthrough). |
| AC-08 | Anomaly model flags an unseen defect type not present in training classes. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | device provisioning image, camera driver, capture service |
| P2 | 3–4 | ONNX/TensorRT runtime, latency benchmark, rules engine |
| P3 | 5–6 | local DB, evidence storage, disk policy, audit log |
| P4 | 7–8 | HMI kiosk UI, override flow |
| P5 | 9–10 | sync agent, dedup, image throttling, heartbeat |
| P6 | 11–12 | model update/rollback, shadow mode, anomaly model, soak test |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Thermal throttling in a hot cabinet | temperature monitoring, fan/heatsink sizing, thermal soak test |
| SD-card/SSD wear from image writes | SSD required, write batching, PASS sampling |
| Model too slow for takt time | quantisation, smaller backbone, ROI-only inference, multi-node |
| Silent camera failure | heartbeat + frame-hash-identical detection + alarm |
| Config drift between nodes | central config with etag + node reports applied versions |
| Unauthorised physical access to the node | disk encryption option, disabled console autologin |

---

## Appendix A — `node.yaml` sketch

```yaml
node_id: line2-station3
central_url: https://factorybrain.local
auth: { mode: mtls, cert: /etc/edgeguard/node.crt }
cameras:
  - id: cam0
    driver: gige
    trigger: hardware
    calib_px_per_mm: 18.42
    recipe: RAD-500-A
inference:
  model: defect-yolo11s
  runtime: tensorrt
  precision: fp16
  review_threshold: 0.55
storage:
  pass_image_sample_rate: 0.02
  min_free_pct: 15
sync:
  batch_size: 200
  image_window: "22:00-05:00"
  bandwidth_kbps: 2000
```
