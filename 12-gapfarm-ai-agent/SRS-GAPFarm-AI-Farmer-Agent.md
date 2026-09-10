# Software Requirements Specification — GAPFarm AI Farmer Agent

| Field | Value |
|---|---|
| Document ID | SRS-12-GAPFarm |
| Project code name | **GAPFarm AI** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Predecessor | GAPFarm (existing farm-record application) |

---

## 1. Introduction

### 1.1 Purpose
Specify the AI extension of the existing **GAPFarm** application: crop disease/pest detection from farmer photos, IoT sensor monitoring, and an agent that converts findings into GAP-compliant records, farm tasks, treatment tracking and harvest prediction.

The distinguishing idea is that the AI does not stop at "possible leaf disease" — it **creates the record, the task, the reminder and the traceability entry** that GAP certification requires.

### 1.2 Scope

**In scope**
- Photo-based crop disease/pest/deficiency identification with zone context.
- Automatic creation of GAP records (scouting, treatment, input usage, harvest).
- Farm task generation, reminders and completion tracking.
- IoT ingestion: soil moisture, temperature, humidity, EC/pH, rainfall; weather API.
- Advisory agent: what to do, when, and what must be recorded for GAP.
- Harvest prediction and yield tracking.
- Thai-first UI, offline-tolerant mobile use.

**Out of scope**
- Prescribing chemical dosages as a professional agronomic authority — the system suggests from an approved list and always defers to label instructions and local regulation.
- Automatic actuation of irrigation/spraying (v1 advisory; actuation is a future phase).
- Marketplace, logistics or accounting.

### 1.3 Definitions
| Term | Meaning |
|---|---|
| GAP | Good Agricultural Practices (e.g. ThaiGAP / GLOBALG.A.P.) |
| Zone / Plot | A managed subdivision of the farm |
| Scouting | Routine field inspection for pests/disease |
| PHI | Pre-Harvest Interval — minimum days between treatment and harvest |
| MRL | Maximum Residue Limit |

---

## 2. Overall Description

### 2.1 Product perspective
```
Farmer phone ──photo──►  Detection (leaf/fruit disease, pest, deficiency)
                                │
IoT sensors ──MQTT──►  Telemetry │        Weather API ──► forecast
 (soil, temp, EC/pH)      │      │              │
                          ▼      ▼              ▼
                     GAPFarm Data Layer (plots · crops · inputs · records)
                                │
                          AI Agent (advisory + workflow)
                                │
        ┌───────────────┬───────┴────────┬────────────────┐
        ▼               ▼                ▼                ▼
   GAP record      Farm task        Reminder        Harvest forecast
        └───────────────┴────────────────┴────────────────┘
                                ▼
                     Dashboard · LINE/Discord · GAP export
```

### 2.2 User classes
| Class | Need |
|---|---|
| Farmer | fast diagnosis in Thai, simple task list, minimal typing |
| Farm manager | zone overview, treatment history, cost, compliance status |
| GAP auditor | complete, tamper-evident records with evidence |
| Agronomist / advisor | review AI suggestions, correct diagnoses |
| Admin | crop library, treatment library, sensors, users |

### 2.3 Operating environment
Mobile-first PWA/Flutter app on low-end Android; FastAPI backend; PostgreSQL + PostGIS + pgvector; MQTT broker for sensors; small VPS or on-farm mini-PC; on-device or server-side inference depending on connectivity; local LLM optional, rule-based fallback mandatory.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | The app MUST be usable on a low-end Android phone with intermittent 4G; core flows work offline and sync later. |
| C-02 | Any chemical recommendation SHALL come from an admin-curated, locally approved product list with PHI/MRL data — never generated freely by the LLM. |
| C-03 | GAP records SHALL be append-only with an audit trail; corrections create a new version, never overwrite. |
| C-04 | Diagnoses SHALL be presented as probabilities with a "consult an agronomist" path; the system is decision support, not an authority. |
| C-05 | Thai is the primary language; English secondary. |

### 2.5 Assumptions
Farmers can photograph affected plants reasonably; plot boundaries are mapped once; sensors (if any) are installed per zone; the operator maintains the approved-input list.

---

## 3. Functional Requirements

### 3.1 Diagnosis
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | The app SHALL accept 1–5 photos of an affected plant part with an automatic quality gate (blur/lighting/subject distance). | Must |
| FR-02 | The system SHALL classify the crop, affected part and the likely disease/pest/deficiency with probabilities. | Must |
| FR-03 | The system SHALL return the top-3 candidates with distinguishing features and a "how to confirm" note. | Must |
| FR-04 | Photos SHALL be tagged with plot/zone, GPS, timestamp and growth stage. | Must |
| FR-05 | When confidence is low, the system SHALL request a better photo (specific guidance) or escalate to an agronomist review queue. | Must |
| FR-06 | The system SHALL estimate the affected area / severity level from the photo set and the farmer's report of how many plants are affected. | Should |
| FR-07 | Agronomist corrections SHALL be stored and used for retraining. | Must |
| FR-08 | The system SHALL work in a degraded "record only" mode with no model available. | Must |

### 3.2 Records & compliance (GAP)
| ID | Requirement | Priority |
|---|---|---|
| FR-09 | A confirmed diagnosis SHALL automatically create a scouting record with evidence photos, zone, date and severity. | Must |
| FR-10 | Applying a treatment SHALL create an input-usage record: product, active ingredient, dose, method, applicator, weather at application, PPE used. | Must |
| FR-11 | The system SHALL compute and enforce PHI: harvest tasks SHALL be blocked/warned until the PHI has elapsed for every applied product on that zone. | Must |
| FR-12 | The system SHALL maintain traceability from harvest lot → zone → inputs applied → scouting events. | Must |
| FR-13 | Records SHALL be exportable as a GAP audit package (PDF/XLSX) for a selectable period and zone. | Must |
| FR-14 | All records SHALL be append-only and versioned with author and timestamp. | Must |
| FR-15 | The system SHALL flag missing mandatory records (e.g. no scouting for N days) as compliance gaps. | Should |

### 3.3 Tasks & reminders
| ID | Requirement | Priority |
|---|---|---|
| FR-16 | A diagnosis SHALL generate a recommended task list (inspect N nearby plants, treat, re-inspect after X days). | Must |
| FR-17 | Tasks SHALL have owner, due date, zone and completion evidence (photo optional). | Must |
| FR-18 | Reminders SHALL be delivered via push and/or LINE/Discord, respecting quiet hours. | Must |
| FR-19 | Re-inspection tasks SHALL prompt a follow-up photo and compare severity against the original. | Must |
| FR-20 | Overdue critical tasks SHALL escalate to the farm manager. | Should |

### 3.4 IoT & environment
| ID | Requirement | Priority |
|---|---|---|
| FR-21 | Ingest sensor data via MQTT with per-zone mapping and unit validation. | Must |
| FR-22 | Detect sensor faults (stuck value, out of range, offline > 1 h) and raise a maintenance task. | Must |
| FR-23 | Fetch weather forecast per farm location and store it for correlation. | Must |
| FR-24 | Raise environment-based advisories (e.g. high humidity + temperature range → elevated fungal risk for this crop). | Should |
| FR-25 | Warn when a planned spray conflicts with forecast rain within the product's rainfast window. | Should |
| FR-26 | Provide irrigation advisories from soil moisture trend, crop stage and forecast (advisory only). | Should |

### 3.5 Agent & prediction
| ID | Requirement | Priority |
|---|---|---|
| FR-27 | The agent SHALL answer farmer questions in Thai using farm data, crop library and record history, with citations. | Must |
| FR-28 | The agent SHALL propose only products from the approved list, showing PHI, re-entry interval and label cautions. | Must |
| FR-29 | The agent SHALL explicitly recommend consulting an agronomist for severe, unfamiliar or rapidly spreading cases. | Must |
| FR-30 | The system SHALL predict harvest window and expected yield per zone from planting date, growth stage observations, weather accumulation (GDD) and history. | Should |
| FR-31 | Prediction SHALL include an uncertainty range and the factors used. | Must |
| FR-32 | The system SHALL produce a weekly farm summary: issues found, treatments applied, upcoming tasks, harvest outlook. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/diagnose` | upload photos, get candidates |
| POST | `/api/v1/records/scouting` | create scouting record |
| POST | `/api/v1/records/input-usage` | log a treatment |
| GET | `/api/v1/zones/{id}/phi-status` | harvest eligibility |
| GET | `/api/v1/tasks?status=` | task list |
| POST | `/api/v1/telemetry` | sensor ingest (also MQTT) |
| GET | `/api/v1/forecast/harvest?zone=` | harvest prediction |
| POST | `/api/v1/ask` | farmer question |
| GET | `/api/v1/export/gap?zone=&from=&to=` | audit package |

### 4.2 Integrations
MQTT broker, weather API (configurable provider, cached), LINE Messaging API and/or Discord, object storage for photos.

---

## 5. Data Requirements

```sql
farm(id, name, owner_id, location geography(Point,4326), gap_scheme)
zone(id, farm_id, name, boundary geography(Polygon,4326), area_rai, crop_id, planted_at)
crop(id, name_th, name_en, variety, stage_model_json)
observation(id, zone_id, ts, kind, photos_json, severity, area_pct, reporter_id)
diagnosis(id, observation_id, model_version, candidates_json, chosen_id,
          confirmed_by, confirmed_at)
input_product(id, name, active_ingredient, type, phi_days, rei_hours,
              approved, label_uri, mrl_json)
input_usage(id, zone_id, product_id, ts, dose, unit, method, applicator_id,
            weather_json, ppe, record_version)
task(id, zone_id, kind, description, due_at, owner_id, status, evidence_json,
     source_diagnosis_id)
sensor(id, zone_id, kind, unit, last_seen_at, status)
telemetry(ts, sensor_id, value, quality)
harvest(id, zone_id, lot_code, harvested_at, qty, unit, grade, traceability_json)
forecast(id, zone_id, kind, value, low, high, generated_at, factors_json)
audit_log(id, ts, user_id, action, entity, entity_id, before_json, after_json)
```

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Disease/pest classifier per crop family; start with the crops actually grown (e.g. chili, then expand), not a generic global model. |
| AI-02 | Target: top-1 accuracy ≥ 0.80 and top-3 ≥ 0.93 on a field-collected hold-out set (not only lab datasets like PlantVillage). |
| AI-03 | A field-condition test set SHALL be maintained (real phone photos, mixed lighting, background clutter); lab-only metrics are not acceptable evidence. |
| AI-04 | On-device model ≤ 25 MB for offline diagnosis; server model may be larger when online. |
| AI-05 | Calibration: displayed probabilities SHALL be calibrated (temperature scaling) and validated with a reliability diagram. |
| AI-06 | The system SHALL detect out-of-distribution images (not a plant, unknown crop) and refuse rather than guess. |
| AI-07 | The LLM SHALL be restricted to explaining and orchestrating; treatment options come from the curated `input_product` table. |
| AI-08 | Harvest prediction SHALL use an interpretable model (GDD + stage observations + history regression) with prediction intervals. |
| AI-09 | Agronomist corrections SHALL flow into a labelled dataset with provenance for retraining. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Diagnosis result ≤ 8 s on 4G (server) or ≤ 2 s on-device. |
| NFR-02 | Core flows (photo, record, task completion) work fully offline and sync within 5 min of reconnection. |
| NFR-03 | App install ≤ 150 MB; works on 3 GB RAM Android. |
| NFR-04 | GAP records tamper-evident: append-only with audit log; export includes a verification hash. |
| NFR-05 | Personal data (farmer identity, location) protected per PDPA; export/delete supported. |
| NFR-06 | Photo storage private with signed URLs; automatic compression for bandwidth. |
| NFR-07 | Availability ≥ 99 %; sensor ingestion buffers ≥ 24 h. |
| NFR-08 | Thai UI complete including error and notification text; English secondary. |
| NFR-09 | Cost target: runnable on a single small VPS for a pilot of ≤ 20 farms. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Field test set meets AI-02 thresholds. |
| AC-02 | Non-plant photo (e.g. a hand, the sky) is refused as out-of-distribution. |
| AC-03 | A confirmed diagnosis produces a scouting record, a task list and a reminder without extra typing. |
| AC-04 | Harvest is blocked/warned when PHI has not elapsed after a logged treatment. |
| AC-05 | GAP audit export for a 3-month period contains all mandatory records and passes a mock audit checklist. |
| AC-06 | Editing a record creates a new version; the original remains retrievable. |
| AC-07 | Airplane mode: 20 observations recorded and synced correctly on reconnection. |
| AC-08 | Agent never recommends a product outside the approved list (adversarial prompt test). |
| AC-09 | Harvest prediction reports an interval and its factors; a zone with no history returns "insufficient data". |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | data model extension (zones, inputs, records), audit/versioning |
| P2 | 3–5 | disease dataset collection + classifier + field test set |
| P3 | 6–7 | diagnosis flow in app, offline mode, on-device model |
| P4 | 8–9 | auto-record generation, task engine, reminders, PHI enforcement |
| P5 | 10–11 | IoT ingest, sensor health, weather correlation, advisories |
| P6 | 12–13 | agent Q&A, weekly summary, harvest prediction |
| P7 | 14 | GAP export package, pilot with real farm, docs |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Lab-trained model fails on real field photos | field test set (AI-03), quality gate, agronomist review loop |
| Wrong chemical advice causes crop or legal harm | curated approved list only, PHI/MRL enforcement, label deference, agronomist escalation |
| Farmers do not adopt (typing burden) | photo-first flow, auto-generated records, Thai voice-free UI, ≤ 3 taps per record |
| Connectivity in the field | offline-first, on-device model, sync queue |
| Sensor hardware unreliable | fault detection, advisory works without sensors |
| GAP scheme differences | scheme-configurable record templates |

---

## Appendix A — Example diagnosis output (TH)

```
📷 ผลการวิเคราะห์ (แปลง B · พริก · ระยะออกดอก)

น่าจะเป็น: โรคใบจุด (Cercospora leaf spot)  — ความเชื่อมั่น 82 %
รองลงมา : โรคแอนแทรคโนส 9 % · ขาดธาตุแมกนีเซียม 5 %

จุดสังเกตที่ใช้: จุดกลมสีน้ำตาลขอบเข้ม กลางใบซีด กระจายที่ใบล่าง
วิธียืนยัน   : ถ่ายภาพใต้ใบเพิ่ม และดูว่ามีวงซ้อนหรือไม่

ระดับความรุนแรง: ปานกลาง (ประเมิน 8–12 % ของพื้นที่ใบ)

งานที่แนะนำ (สร้างให้อัตโนมัติแล้ว):
 ☐ ตรวจต้นข้างเคียง 10 ต้น — ครบกำหนดวันนี้
 ☐ พิจารณาพ่นสารตามรายการที่อนุมัติ — ครบกำหนดพรุ่งนี้
 ☐ ถ่ายภาพติดตามผลอีกครั้ง — อีก 7 วัน

⚠️ พยากรณ์อากาศ: ฝนตกใน 12 ชม. — ควรเลื่อนการพ่นออกไป
📋 บันทึก GAP: สร้างบันทึกการสำรวจแปลงเรียบร้อย (SC-2026-0412)
👨‍🌾 หากลุกลามเร็วหรือไม่แน่ใจ แนะนำปรึกษานักวิชาการเกษตร
```
