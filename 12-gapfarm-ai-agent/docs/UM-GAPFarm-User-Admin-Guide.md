# User Manual & Administrator Guide — GAPFarm AI (AI Farmer Agent)

| Field | Value |
|---|---|
| Document ID | UM-12-GAPFarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-20 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-12](../SRS-GAPFarm-AI-Farmer-Agent.md) · [OPS-12](OPS-GAPFarm-Deployment-Operations.md) · [SEC-12](SEC-GAPFarm-Security-Requirements.md) §5.7 (roles) · [API-12](../api/API-Specification.md) · [ICD-12](ICD-GAPFarm-Interface-Control.md) IF-65, IF-66 |
| Languages | This manual is in English; the product UI, notifications and every error are in Thai first with English secondary (C-05, NFR-08). Part C is the Thai/English glossary. |

---

# Part A — User guide

## A.0 What GAPFarm AI does — and what it never does
You photograph an affected leaf or fruit; the app tells you the likely disease, pest or deficiency **as a probability**, what to look for, and how to confirm it. When you confirm, the app has already written the GAP scouting record, created the tasks and set the reminders — nothing to type (Appendix A). It tracks the pre-harvest interval of every treatment, keeps every record with its history, and can hand an auditor a package that proves nothing was changed.

It never:
- **names a product outside the farm's approved list**, or tells you a dose — doses are "per label", and the label is one tap away (C-02).
- **decides for you.** Every diagnosis is a probability with "how to confirm"; severe, unfamiliar or fast-spreading cases carry "consult an agronomist" (C-04, FR-29).
- **lets a harvest through inside the PHI** — the app refuses, with the date you can harvest (FR-11).
- **edits a record.** A correction is a new version; the original stays (C-03).
- **guesses on a photo it does not understand** — a hand or the sky is refused with advice on what to photograph (AI-06).
- waters or sprays anything (advisory only).

## A.1 Roles
| Role | Can |
|---|---|
| Farmer | photograph, confirm, record treatments and harvests, do tasks, ask questions, see zones, PHI and advisories, request own data export/erasure |
| Farm manager | + zone overview, PHI board, compliance gaps, escalations, weekly summary, export packages, correct records (new versions) |
| Agronomist | + review queue, corrections, propose task templates and risk rules |
| GAP auditor | records and their versions, chain verification, exports — nothing personal |
| Admin | crops, approved inputs, schemes, sensors, models, users, configuration |

## A.2 Farmer — from a photo to a done task (≤ 3 taps)

### A.2.1 Take the photos
Open the zone (or let GPS pick it), tap the camera, take 1–5 photos of the affected part. The app tells you before you upload if a photo is too blurred, too dark or too far ("ถ่ายใกล้ขึ้นอีก", "ถือให้นิ่ง", "หาแสงเพิ่ม"). Add how many plants look affected out of how many you checked (optional, one slider). Offline? Everything is saved on the phone and sent within 5 minutes of getting signal — with the on-device model you still get a result.

### A.2.2 Read the result card
```
📷 ผลการวิเคราะห์ (แปลง B · พริก · ระยะออกดอก)
น่าจะเป็น: โรคใบจุด (Cercospora leaf spot)  — ความเชื่อมั่น 82 %
รองลงมา : โรคแอนแทรคโนส 9 % · ขาดธาตุแมกนีเซียม 5 %
จุดสังเกตที่ใช้: จุดกลมสีน้ำตาลขอบเข้ม กลางใบซีด กระจายที่ใบล่าง
วิธียืนยัน   : ถ่ายภาพใต้ใบเพิ่ม และดูว่ามีวงซ้อนหรือไม่
ระดับความรุนแรง: ปานกลาง (ประเมิน 8–12 % ของพื้นที่ใบ)
```
- **82 %** means: of past cases the model was this sure about, about 82 % were right (calibrated, AI-05). Not a verdict.
- **จุดสังเกต / วิธียืนยัน** tell you what to check with your own eyes before you confirm.
- Below **60 %** the card says an agronomist will look at it (`needs_review`); you can still confirm if you are sure.
- A photo that is not a plant is refused — nothing is recorded; take the photo the card asks for.

### A.2.3 Confirm — one tap
Tap **ยืนยัน** on the candidate you agree with (or pick another). This single tap creates:
```
งานที่แนะนำ (สร้างให้อัตโนมัติแล้ว):
 ☐ ตรวจต้นข้างเคียง 10 ต้น — ครบกำหนดวันนี้
 ☐ พิจารณาพ่นสารตามรายการที่อนุมัติ — ครบกำหนดพรุ่งนี้
 ☐ ถ่ายภาพติดตามผลอีกครั้ง — อีก 7 วัน
⚠️ พยากรณ์อากาศ: ฝนตกใน 12 ชม. — ควรเลื่อนการพ่นออกไป
📋 บันทึก GAP: สร้างบันทึกการสำรวจแปลงเรียบร้อย (SC-2026-0412)
👨‍🌾 หากลุกลามเร็วหรือไม่แน่ใจ แนะนำปรึกษานักวิชาการเกษตร
```
The record number is your GAP scouting record; the tasks are on your list with reminders (LINE by default, never between 20:00 and 06:00).

### A.2.4 Treat — from the approved list only
Tap the treat task → the app lists **only** the farm's approved products for this condition, each with **PHI** (days before you may harvest), **REI** (hours before re-entering without PPE), the label and its cautions, and the rain check ("rain expected within 6 h of application — postpone"). Pick one, enter dose *as on the label*, method, PPE used; the weather is filled in for you. This is your GAP input-usage record; the zone's harvest date moves to `today + PHI` and the PHI board shows it.

### A.2.5 Follow up
In 7 days the reminder asks for a follow-up photo of the same spot; the card compares severity ("10 % → 3 %, improving") and closes the task.

### A.2.6 Harvest
Tap the harvest task or *บันทึกการเก็บเกี่ยว*: lot code, quantity, grade. If any product's PHI on that zone has not elapsed the app refuses: "เก็บเกี่ยวได้ตั้งแต่ 17 ก.ย. 08:00 (แมนโคเซบ, PHI 7 วัน)". There is no override — ask the farm manager if you believe the record is wrong (they can add a corrected version with a reason, never delete). A recorded lot carries its traceability: zone, inputs since planting, scouting events.

### A.2.7 Ask
*ถามผู้ช่วย*: "ใบจุดแปลง B ควรใช้อะไร แล้วเก็บพริกได้เมื่อไหร่" → the answer lists approved products with PHI, your zone's PHI status, and cites the crop library and your records. Ask for a banned product and it will say the product is not on the list, without naming it, and point you to an agronomist. Answers are the same without the language model (`fallback`) — just plainer.

### A.2.8 Your data (PDPA)
*ข้อมูลของฉัน*: export everything held about you; request erasure — your name, phone, LINE and GPS go; the GAP records you wrote stay under a code (the farm's certification needs them). This is explained when you consent.

## A.3 Farm manager
- **Zones**: crop, stage (from degree days), PHI status, open tasks, last scouting.
- **PHI board**: every zone with `clear_at` and the blocking product.
- **Compliance gaps**: "แปลง C ไม่มีบันทึกสำรวจ 26 วัน" — fix by scouting, not by editing.
- **Records**: every version of every record; *แก้ไข* creates version 2 with a reason (AC-06).
- **Escalations**: critical tasks overdue > 24 h land here.
- **Weekly summary** (Monday): issues, treatments with PHI clear dates, harvests, open tasks, gaps, sensor faults.
- **Export for audit**: pick period and zone → PDF + XLSX + manifest; *ตรวจสอบ* recomputes the hashes; keep the manifest.

## A.4 Agronomist
**Review queue**: low-confidence and severe cases with photos, candidates and the farmer's counts. *ยืนยัน* or *แก้ไข* (correct class and severity, note). A correction becomes a training example with your pseudonym and a new record version (or the first record if none existed) with its tasks. Propose new task templates and disease-risk rules to the admin with a source.

## A.5 GAP auditor
Log in as auditor: records, versions, chain status per zone, exports. Verify a package: *ตรวจสอบ* (or offline, OPS-12 §10). You see reporter codes, not names; no GPS; no phone numbers.

## A.6 Reading the numbers honestly
| Field | Meaning |
|---|---|
| ความเชื่อมั่น | calibrated probability of the top candidate; not a verdict |
| ระดับความรุนแรง | leaf-area band: น้อย < 5 %, ปานกลาง 5–15 %, รุนแรง > 15 % |
| PHI / เก็บเกี่ยวได้ตั้งแต่ | last application + label PHI; the app refuses before it |
| ความเสี่ยงโรค | a rule fired (humidity/temperature/hours) with its source; not a diagnosis |
| พยากรณ์เก็บเกี่ยว | degree days to maturity ± the recent day-to-day variability; yield = your zone's past seasons with an interval; "ข้อมูลไม่พอ" when fewer than 3 seasons |
| ช่องว่างการบันทึก GAP | days without a mandatory record; shown to the auditor too |

---

# Part B — Administrator guide

## B.1 Crops and conditions
Import the crop file (name, variety, base temperature, stage model as degree-day thresholds, conditions with Thai/English names, distinguishing features, how to confirm, fast-spreading flag). A condition is what the model may output; a model whose classes are not in the library cannot be registered.

## B.2 Approved-input list (the file that matters most)
`inputs/approved-products.yaml` (IF-65): trade name, active ingredient, type, **PHI, REI, rainfast, MRL with source, label PDF, target conditions, cautions**. Verify every value against the registered label — the example file is not a reference. Import as unapproved; a *different* admin approves each entry in *ปัจจัยการผลิต* (self-approval is refused). Withdrawing needs a reason. Everything is audited.

## B.3 Schemes
`schemes/thaigap.yaml`: record templates (export field order) and rules (mandatory records, max gap days). Map to the certifying body's current checklist before the first audit; a change is a new version.

## B.4 Farms, zones, users
Farm point (weather), timezone, quiet hours, reminder time; zones as polygons with area, crop, planting date, season number; yield history per zone for predictions; users with roles and farm membership; LINE linking.

## B.5 Sensors
Register (zone, kind, device code) → one-time credential; kinds fix unit and range; faults create maintenance tasks automatically; *เซ็นเซอร์* shows health. See OPS-12 §5.1 for the broker.

## B.6 Models
*โมเดล*: registry with field/lab evaluations, calibration, OOD threshold, size. *ปล่อยใช้* is refused without a passed **field** evaluation (top-1 ≥ 0.80, top-3 ≥ 0.93), an active calibration, or over 25 MB for a phone model. Watch OOD rate, review rate and corrected rate per version.

## B.7 Task templates and risk rules
Templates per condition kind × minimum severity: text (Thai/English), offset days, priority. Risk rules: crop, condition, RH ≥, temperature band, hours ≥, level, message, **source**. Both are data; changes apply to new diagnoses only.

## B.8 Configuration
`gapfarm.yaml` — tunables (review threshold, bands, quiet hours, fault rules, prediction seasons, retention); the rest is pinned by the schema (OPS-12 §6). The agent can be switched off (`AGENT_ENABLED=false`) without losing any record function.

## B.9 What to watch
OPS-12 §9: chain verification (must never fail), unapproved-product refusals (should be zero — investigate any), PHI refusals (informational), sync lag, review-queue age, sensor faults, weather availability, reminder failures, model fallback rate, open compliance gaps.

---

# Part C — Glossary (TH / EN)
| TH | EN | Meaning here |
|---|---|---|
| โรคใบจุด | Cercospora leaf spot | fungal round brown spots with dark margins on leaves |
| โรคแอนแทรคโนส | anthracnose | sunken fruit lesions; fast-spreading in rain |
| ขาดธาตุแมกนีเซียม | magnesium deficiency | interveinal yellowing of lower leaves |
| โรคเหี่ยวเขียว | bacterial wilt | whole plant wilts while green; fast-spreading |
| เพลี้ยไฟ | thrips | tiny insects; curled leaves |
| หนอนเจาะผล | fruit borer | larva inside the fruit |
| ระยะปลอดภัยก่อนเก็บเกี่ยว (PHI) | pre-harvest interval | days between last application and harvest, per label — enforced |
| ระยะปลอดภัยก่อนเข้าแปลง (REI) | re-entry interval | hours before entering without PPE |
| ค่าปริมาณสารพิษตกค้างสูงสุด (MRL) | maximum residue limit | legal residue limit per crop |
| รายการปัจจัยการผลิตที่อนุมัติ | approved-input list | the only products the system can name |
| บันทึกการสำรวจแปลง | scouting record | GAP record created by a confirmed diagnosis or routine scouting |
| บันทึกการใช้ปัจจัยการผลิต | input-usage record | GAP treatment record with weather and PPE |
| ล็อตเก็บเกี่ยว | harvest lot | traceable harvest unit |
| เวอร์ชันบันทึก | record version | a correction; the original stays |
| สายโซ่แฮช | hash chain | tamper-evidence of records per zone |
| ความเชื่อมั่น | confidence (calibrated) | probability, not a verdict |
| ระดับความรุนแรง | severity level | leaf-area band |
| งานที่แนะนำ | recommended task | generated on confirmation |
| ช่วงเวลาเงียบ | quiet hours | no reminders 20:00–06:00 |
| ช่องว่างการบันทึก GAP | compliance gap | missing mandatory record period |
| องศาวันสะสม (GDD) | growing degree days | crop stage and harvest-date basis |
| ข้อมูลไม่พอ | insufficient data | no forecast when history is too short |
| ปรึกษานักวิชาการเกษตร | consult an agronomist | the standard line for severe / unfamiliar / fast-spreading cases |
