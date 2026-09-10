# Software Requirements Specification — AI Factory Inspector Agent

| Field | Value |
|---|---|
| Document ID | SRS-01-VisionOps |
| Project code name | **VisionOps** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify a system that turns a camera stream into **manufacturing intelligence**: detect and measure defects, persist evidence, then let an LLM agent explain *what changed, why it probably changed, and what to do next* — instead of only saying "defect detected".

### 1.2 Scope

**In scope**
- Image acquisition from one or more line cameras (trigger or continuous).
- Detection / segmentation / dimensional measurement of defects.
- Inspection database with full evidence traceability.
- Analysis agent producing shift and daily narratives with recommended actions.
- Dashboard + Discord delivery.

**Out of scope**
- Physical reject actuation (v1 outputs a signal only; interlocking is the PLC's job).
- Edge hardware bring-up — see [EdgeGuard (SRS-03)](../03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md).
- Full SPC/8D/FMEA workflow — see [QE-Agent (SRS-09)](../09-quality-engineer-agent/SRS-QE-Agent-Quality-Engineer.md).

### 1.3 Definitions
**Verdict** = PASS / FAIL / REVIEW. **Evidence** = original frame + annotated overlay + metadata. **Station** = a fixed inspection position on a line.

---

## 2. Overall Description

### 2.1 Product perspective
```
Industrial Camera
      ↓ frame + trigger
Vision Pipeline  (YOLO / RF-DETR / SAM)
      ↓ detections + masks
Measurement & Rules Engine
      ↓ verdict + measurements
Quality Database (PostgreSQL + object store)
      ↓
AI Agent (Ollama, tool-calling)
   ┌──┴───┐
   ↓      ↓
Analysis  Report
   ↓      ↓
Dashboard  Discord
```

### 2.2 User classes
Operator (sees verdict), QC inspector (reviews REVIEW queue), Quality engineer (reads analysis, tunes thresholds), Manager (reads daily narrative), Admin (models, cameras, retraining).

### 2.3 Operating environment
Edge PC or workstation with NVIDIA GPU (8 GB baseline), Ubuntu + Docker, GigE/USB3 camera, factory LAN. Local LLM via Ollama.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | Inference and agent MUST run fully on-premise. |
| C-02 | Vision model must sustain the line's takt time (default target ≥ 10 FPS at 640 px). |
| C-03 | Every verdict must be reproducible: model version + threshold set + input hash stored. |
| C-04 | The agent MUST NOT invent numbers; all figures come from SQL tool results. |

### 2.5 Assumptions
Fixed lighting and camera pose; a labelled dataset of ≥200 images per defect class for v1; SKU and lot identity available (barcode, PLC tag, or manual entry).

---

## 3. Functional Requirements

### 3.1 Acquisition
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | The system SHALL acquire frames on hardware trigger, software trigger, or fixed interval. | Must |
| FR-02 | The system SHALL tag each frame with camera id, station, line, SKU, lot, shift and timestamp (ms). | Must |
| FR-03 | The system SHALL detect camera disconnection and raise an alarm within 10 s. | Must |
| FR-04 | The system SHALL reject frames failing a quality gate (blur variance, exposure) and mark them NO_READ. | Should |

### 3.2 Inspection
| ID | Requirement | Priority |
|---|---|---|
| FR-05 | The system SHALL run object detection returning class, confidence and bounding box per defect. | Must |
| FR-06 | The system SHALL optionally run segmentation to compute defect area in px and mm². | Should |
| FR-07 | The system SHALL compute dimensional measurements from a calibrated pixel-to-mm scale, per configured measurement recipe. | Must |
| FR-08 | The system SHALL evaluate a per-SKU rule set (class present, count, area, dimension vs USL/LSL) to produce a verdict. | Must |
| FR-09 | Confidence below `review_threshold` OR conflicting rules SHALL yield REVIEW. | Must |
| FR-10 | The system SHALL store the original frame, an annotated overlay and the full detection JSON. | Must |
| FR-11 | The system SHALL support OCR of lot/part markings and attach the decoded string. | Should |
| FR-12 | The system SHALL expose the verdict as a digital output / MQTT message within 100 ms of decision. | Should |

### 3.3 Review & learning
| ID | Requirement | Priority |
|---|---|---|
| FR-13 | Inspectors SHALL be able to confirm or override a verdict from a review queue with single-key actions. | Must |
| FR-14 | Overrides SHALL be stored with user, timestamp and optional reason code. | Must |
| FR-15 | The system SHALL export overridden + confirmed records as a versioned training dataset (images + COCO/YOLO labels). | Must |
| FR-16 | The system SHALL report per-class agreement between model and human over any period. | Should |

### 3.4 Analysis agent
| ID | Requirement | Priority |
|---|---|---|
| FR-17 | The agent SHALL generate a shift/daily narrative containing: units inspected, defect count, defect rate, delta vs baseline, top defect class, most affected SKU, and any line/shift/station correlation. | Must |
| FR-18 | The agent SHALL propose 1–3 concrete recommended actions referencing a specific station, lot, SKU or shift. | Must |
| FR-19 | Every number in the narrative SHALL come from a tool call recorded in the same agent run. | Must |
| FR-20 | The agent SHALL answer ad-hoc questions (`/ask`) over the inspection database. | Must |
| FR-21 | When data is insufficient or the change is not statistically significant, the agent SHALL say so explicitly. | Must |
| FR-22 | Narratives SHALL be renderable in Thai, Japanese and English. | Should |

### 3.5 Delivery
| ID | Requirement | Priority |
|---|---|---|
| FR-23 | The dashboard SHALL show live verdict stream, KPI tiles, defect Pareto, trend chart and an evidence gallery with filters (line/SKU/class/date/verdict). | Must |
| FR-24 | The system SHALL post the narrative to Discord on a schedule and on threshold alerts. | Must |
| FR-25 | The system SHALL export a PDF/PPTX daily report with charts and top evidence images. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/inspect` | inspect an uploaded image (sync) |
| POST | `/api/v1/inspections` | record a result produced at the edge |
| GET | `/api/v1/inspections?…` | query with filters/pagination |
| PATCH | `/api/v1/inspections/{id}/verdict` | human override |
| GET | `/api/v1/stats/summary?from=&to=` | KPI aggregate |
| POST | `/api/v1/agent/narrative` | generate shift/daily narrative |
| POST | `/api/v1/agent/ask` | ad-hoc question |
| GET | `/api/v1/recipes/{sku}` | inspection rule set |

### 4.2 Hardware
GenICam/GigE Vision or USB3 camera; optional strobe controller; digital I/O module or PLC via MQTT for the PASS/FAIL signal.

### 4.3 Messaging
MQTT topics: `factory/{line}/{station}/verdict`, `.../heartbeat`, `.../alarm`.

---

## 5. Data Requirements

```sql
camera(id, line_id, station, model, resolution, calib_px_per_mm, active)
recipe(id, sku_id, version, rules_json, review_threshold, active_from)
inspection(id, ts, camera_id, line_id, sku_id, lot, verdict, model_version,
           recipe_version, latency_ms, image_uri, overlay_uri, ocr_text)
detection(id, inspection_id, class_id, confidence, bbox_json, mask_uri, area_mm2)
measurement(id, inspection_id, name, value, unit, usl, lsl, in_spec)
verdict_override(id, inspection_id, old_verdict, new_verdict, user_id, reason, ts)
agent_run(id, ts, kind, question, tool_calls_json, answer, model, latency_ms)
```

Retention: PASS images 30 days, FAIL/REVIEW 2 years, records 5 years.

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Baseline detector: YOLO11-s/m @640; RF-DETR as accuracy alternative; SAM only for offline mask generation during labelling. |
| AI-02 | Acceptance: mAP@50 ≥ 0.85 overall; **recall ≥ 0.98 on classes marked `critical`**; false-alarm rate ≤ 3 % on PASS parts. |
| AI-03 | Models SHALL be exported to ONNX (and TensorRT where available) and pinned by version hash. |
| AI-04 | Measurement accuracy SHALL be within ±0.2 mm (or the recipe's stated tolerance) verified against a calibration gauge. |
| AI-05 | LLM: local instruct model ≤ 9 B (Q4_K_M) with tool calling; the model MUST NOT be asked to compute statistics itself. |
| AI-06 | An anomaly-detection fallback (e.g. PatchCore/autoencoder) SHALL flag unknown defect types not in the trained class list. |
| AI-07 | A drift monitor SHALL track mean brightness, blur and class distribution and alert on >3σ deviation from baseline. |
| AI-08 | Retraining SHALL be reproducible from a dataset snapshot id and produce a metric comparison report before promotion. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | End-to-end latency (frame → verdict) ≤ 200 ms p95. |
| NFR-02 | Sustained throughput ≥ 10 inspections/s per camera at 640 px on the baseline GPU. |
| NFR-03 | Inspection service SHALL keep running and buffer results if the database is unreachable (≥ 24 h local buffer). |
| NFR-04 | Availability ≥ 99 % during production shifts. |
| NFR-05 | Agent narrative generated in ≤ 30 s. |
| NFR-06 | RBAC: only `inspector` and above may override verdicts; all overrides audited. |
| NFR-07 | No image or production data leaves the LAN unless an admin enables cloud export. |
| NFR-08 | Deployment via one `docker compose up`; models pre-baked into the image or mounted volume. |
| NFR-09 | Structured logs + Prometheus metrics (fps, latency, verdict counts, GPU memory). |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | On a 500-image hold-out set, metrics meet AI-02. |
| AC-02 | A known-good and known-bad physical sample set of 100 parts yields ≤ 1 misclassification. |
| AC-03 | Calibration gauge measurement repeatability ≤ ±0.2 mm over 30 repeats. |
| AC-04 | Database disconnected for 1 h: no inspection lost, all synced on reconnect. |
| AC-05 | Narrative figures match SQL ground truth exactly on a seeded dataset. |
| AC-06 | Agent given a period with no significant change reports "no significant change" (no invented cause). |
| AC-07 | Review queue: 100 records judged in ≤ 5 minutes by one inspector. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | capture rig, dataset collection & labelling pipeline |
| P2 | 3–4 | detection model v1, ONNX export, benchmark |
| P3 | 5–6 | inspection service, recipe/rules engine, DB, MQTT verdict |
| P4 | 7–8 | dashboard, evidence gallery, review queue |
| P5 | 9–10 | agent tools + narrative + Discord |
| P6 | 11–12 | anomaly fallback, drift monitor, retraining loop, docs/demo |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Not enough defect samples (defects are rare) | anomaly detection first; targeted defect harvesting; augmentation |
| Lighting/pose changes break the model | fixed fixture, drift monitor, periodic re-validation |
| Operators distrust AI verdicts | REVIEW queue + override + visible agreement statistics |
| Takt time too fast for the model | smaller model / lower resolution / TensorRT / multiple edge nodes |
| Agent over-claims causality | correlation-only wording rules + explicit significance test in tools |

---

## Appendix A — Example narrative

```
Production line 2 — 2026-09-10
1,240 units inspected · 37 defects · defect rate 2.98 % (+42 % vs yesterday)
Main defect: missing fin (19 pcs)
Most affected SKU: RAD-500-A
Possible correlation: Line 2 / Shift B (31 of 37 defects)
Recommendation: inspect feeder station #3.
Confidence: correlation only — not verified as root cause.
```
