# User Manual & Administrator Guide — PocketQC Offline Mobile Inspector

| Field | Value |
|---|---|
| Document ID | UM-05-PocketQC |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Applies to | PocketQC 1.0.x on Android; UI in Thai (default), Japanese, English |
| Related | [OPS-05](OPS-PocketQC-Deployment-Operations.md) for devices, configuration and content; [UM-00](../../00-factorybrain-platform/docs/UM-FactoryBrain-User-Admin-Guide.md) for what happens to your records on the platform |

---

## Contents

**Part A — Using PocketQC**
- A1 Before you start
- A2 Logging in (and working offline)
- A3 Starting an inspection — scan the label
- A4 The step screen: photos, the quality gate, and what the AI shows
- A5 REVIEW steps — you decide
- A6 Measuring with the marker card
- A7 Notes, defect codes, finishing
- A8 History, reports, sharing
- A9 The sync indicator — what "pending" means
- A10 Supervisor: re-judging a finished session
- A11 FAQ

**Part B — Administrator's guide**
- B1 Devices and enrolment
- B2 Users and roles
- B3 Checklists
- B4 Models
- B5 Policy
- B6 Lost devices and wipe
- B7 What the app will never do

Glossary TH / JA / EN · Quick card

---

# Part A — Using PocketQC

## A1 Before you start
You need: the company tablet (enrolled, with a passcode), the **marker cards** (20 mm and 50 mm) for measuring steps, and — ideally — Wi-Fi once a day. You do **not** need Wi-Fi to inspect. Everything in this part works with airplane mode on.

## A2 Logging in (and working offline)
Open PocketQC → unlock with the device passcode or fingerprint → enter your company username and password (needs Wi-Fi the first time). After that you can open the app without any network for up to **30 days** (your admin may set a different window). The home screen shows the days remaining when fewer than 5 are left. When it reaches zero, you can still look at history but cannot inspect until you log in on Wi-Fi.

## A3 Starting an inspection — scan the label
Tap **Inspect** → point the camera at the lot label. The app reads the barcode, shows the SKU and lot, and **opens the right checklist by itself**. If it says "Unknown product", choose the checklist from the list and tell your quality engineer — the SKU needs to be added centrally.

## A4 The step screen

```
┌ Step 3 of 20 · Front view ──────────── ● pending 12 ┐
│                                                     │
│        [ live camera with a rectangle guide ]       │
│                                                     │
│  💡 torch    ⟳ burst    (📷 big shutter button)     │
├─────────────────────────────────────────────────────┤
│  AI: scratch 0.83  [box drawn]    → suggests FAIL   │
│  [ PASS ]           [ FAIL ]           320 ms        │
└─────────────────────────────────────────────────────┘
```

1. Fill the guide with the part and press the shutter. **Burst** takes five frames and keeps the sharpest.
2. If the photo is blurred, too dark or has glare, the app says so and asks for a retake — turn on the torch if it suggests it. Nothing is analysed until the photo is good.
3. The AI draws boxes and suggests PASS or FAIL with its confidence. **It is a suggestion.** You tap PASS or FAIL. The app stores both — what the AI thought and what you decided.
4. The step is saved the moment you tap. If the app is closed or the tablet dies, you continue from this step.

## A5 REVIEW steps — you decide
When the AI is not sure (the confidence sits near the limit), the step shows **REVIEW** in orange. You must look and tap PASS or FAIL; the session cannot be finished with a REVIEW left undecided. Your decision is exactly as valid as any other — and it teaches the model.

## A6 Measuring with the marker card
Place the marker card flat next to the feature, in the same plane, at the working distance shown on the guide. Take the photo; tap the two points to measure. The app shows the value **± tolerance** and whether it is in spec. If it says "no marker found", re-place the card — a measurement without the marker is not possible, by design.

## A7 Notes, defect codes, finishing
On any step you can add a **note**, a **defect code** (the list is in your language) and a **severity**. Tapping FAIL asks for a defect code. At the last step the app shows the session verdict — FAIL if any step failed, otherwise PASS — and "Finish". The PDF report is available immediately.

## A8 History, reports, sharing
**History** lists your sessions; search by lot, SKU, date or verdict. Open one to see every step with its photo, the AI suggestion and your decision. **Share PDF** opens the Android share sheet — only the apps your company allows appear. The PDF contains smaller copies of the photos.

## A9 The sync indicator — what "pending" means
The dot and number at the top right: **● pending 12** means 12 finished sessions are waiting for Wi-Fi. This is normal. When Wi-Fi is available the app uploads by itself (records first, photos later) and the number falls to 0; "last sync" shows when. You can tap it to sync now. If the number does not fall on Wi-Fi for a day, tell your admin (OPS RB-02).

## A10 Supervisor: re-judging a finished session
A finished session's verdict can be changed only by a supervisor: open the session → **Re-judge** → supervisor PIN → new verdict and reason. Every attempt (right or wrong PIN) is logged; five wrong PINs lock re-judging for 15 minutes. The original verdict stays in the record.

## A11 FAQ
**The AI said PASS but I see a defect.** Tap FAIL. Your judgement counts; the model learns from it.
**Can I skip a step?** Optional steps yes; required steps no. A REVIEW step never.
**I closed the app by mistake.** Open it — "Resume session … step N" is on the home screen.
**The tablet is almost full.** Get it on Wi-Fi; uploaded photos free space by themselves. Do not delete anything in Android settings.
**Can the office change my verdict?** Not silently. A quality engineer can add their own review on the platform; yours stays as you recorded it.
**The AI is missing (manual mode).** You still inspect: photo + your PASS/FAIL. Tell your admin — the model needs to be installed or updated.
**Is my location recorded?** Only if your company turned it on; the home screen shows "GPS on" when it is.

---

# Part B — Administrator's guide

## B1 Devices and enrolment
Devices are enrolled in the MDM with the PocketQC profile and **managed configuration** (server, certificate pins, device id, offline window, share policy). Inspectors cannot change these. Certified devices and the enrolment steps are in OPS-05 §2; certificate pins must be rotated **before** the server certificate changes (OPS-05 §6.5).

## B2 Users and roles
Users are platform accounts (UM-00). Roles on the device: **inspector**, **supervisor** (holds the re-judge PIN), **admin** (platform only). PINs are issued per supervisor on the platform and cached hashed on the device; revoke centrally.

## B3 Checklists
Author as YAML/JSON per the template (`deploy/checklists/RAD-500-A-incoming.yaml`) and publish on the platform; it is validated against the schema on publish and again on each device. Rules of thumb: one checklist per SKU family with a `sku_pattern`; every AI step names its model and classes; measurement steps name the marker size printed on your cards; quote `"no"` in YAML. Devices take a new version at their next bootstrap; a session in progress keeps its version.

## B4 Models
Publish a manifest (name, version, sha256, size ≤ 25 MB, class map, **sample images with expected classes**, metrics meeting AI-02). Each device downloads it, checks the checksum, **tests it on the samples on that device**, and only then activates it — keeping the previous version. A device where the self-test fails keeps the old model and tells you in the fleet view; that is the system protecting the inspector, not a fault. Rollback is a command.

## B5 Policy
`/mobile/policy`: retention on the device (default 60 days for **synced** sessions), sync network, image compression, GPS, offline window, low-space thresholds, allowed share targets. Devices apply it at the next sync.

## B6 Lost devices and wipe
Mark the device **lost** on the platform *and* wipe it in the MDM. The app wipes itself at its next contact (after trying to upload pending sessions for a minute). Data at rest is encrypted; the only loss is unsynced work, which you can see in the last heartbeat and re-inspect. Enrol the replacement with a new device id.

## B7 What the app will never do
- Judge a part on its own — every AI result is a suggestion; a person taps PASS or FAIL.
- Change a recorded verdict without a supervisor PIN and an audit entry.
- Send a photo, a lot number or anything else to any service other than your platform.
- Use cloud inference or analytics.
- Delete unsynced work to free space.
- Run a model that failed its checksum or its self-test on that device.
- Let an inspector change the server, the pins or the security settings.

---

## Glossary (TH / JA / EN)

| EN | TH | JA | Meaning |
|---|---|---|---|
| Session | รอบการตรวจ | 検査セッション | One checklist run for one part/lot |
| Step | ขั้นตอน | ステップ | One photo, scan, measurement or check |
| Checklist | รายการตรวจ | チェックリスト | The ordered steps for a SKU |
| Quality gate | ด่านคุณภาพภาพ | 画質ゲート | Blur/exposure/glare check before analysis |
| AI suggestion | ข้อเสนอจาก AI | AI提案 | The model's PASS/FAIL/REVIEW — never final |
| REVIEW | ต้องตัดสิน | 要判断 | The AI is unsure; the inspector decides |
| Verdict | ผลตัดสิน | 判定 | PASS or FAIL — yours |
| Defect code | รหัสข้อบกพร่อง | 不良コード | Classification of what you saw |
| Marker card | การ์ดมาร์กเกอร์ | マーカーカード | Known-size card for measuring |
| Pending | รอส่ง | 未送信 | Finished sessions waiting for Wi-Fi |
| Sync | ซิงค์ | 同期 | Upload records and photos; download checklists and models |
| Offline window | ช่วงใช้งานออฟไลน์ | オフライン有効期間 | Days you can open the app without Wi-Fi |
| Re-judge | ตัดสินใหม่ | 再判定 | Supervisor changes a finished verdict with PIN |
| Manual mode | โหมดไม่ใช้ AI | 手動モード | No model installed; photo + your verdict |
| Wipe | ล้างข้อมูลระยะไกล | リモートワイプ | Remote erase of a lost device |

## Quick card (print, laminate, attach to the tablet case)

```
 PocketQC — quick card
 1  Unlock · open PocketQC · (Wi-Fi only needed for first login)
 2  INSPECT → scan the lot label → checklist opens by itself
 3  Each step: fill the guide · shutter · retake if asked (torch!)
 4  AI suggests · YOU tap PASS or FAIL · orange REVIEW = you must look
 5  Measure: marker card flat, same plane · tap two points
 6  FAIL → choose a defect code · add a note if useful
 7  Finish → verdict · PDF ready · "pending N" = waiting for Wi-Fi (normal)
 8  Closed the app? Home screen → Resume session
 Never delete app data yourself · Lost tablet? Tell your admin immediately
```
