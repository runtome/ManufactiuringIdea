# User Manual and Administrator Guide — VisionOps (AI Factory Inspector Agent)

| Field | Value |
|---|---|
| Document ID | UM-01-VisionOps |
| Version | 1.0 (Draft) |
| Date | 2026-09-11 |
| Author | Suphot N. |
| Status | Draft for review |
| Audience | Part A — operators, inspectors, engineers, managers · Part B — administrators |

---

## Contents

**Part A — User Manual**
[A1 Getting started](#a1-getting-started) · [A2 Line operator — the station screen](#a2-line-operator--the-station-screen) · [A3 QC inspector — the review queue](#a3-qc-inspector--the-review-queue) · [A4 Quality engineer](#a4-quality-engineer) · [A5 Production manager](#a5-production-manager) · [A6 Using the narrative agent](#a6-using-the-narrative-agent) · [A7 Discord](#a7-discord) · [A8 FAQ](#a8-faq)

**Part B — Administrator Guide**
[B1 Users and roles](#b1-users-and-roles) · [B2 Stations and cameras](#b2-stations-and-cameras) · [B3 Calibration](#b3-calibration) · [B4 Recipes](#b4-recipes) · [B5 Models](#b5-models) · [B6 Datasets and retraining](#b6-datasets-and-retraining) · [B7 Edge fleet](#b7-edge-fleet) · [B8 Alerts](#b8-alerts) · [B9 Audit and jobs](#b9-audit-and-jobs) · [B10 Health and escalation](#b10-health-and-escalation)

[Glossary (TH/JA/EN)](#glossary)

---

# Part A — User Manual

## A1 Getting started

Open `https://visionops.local` (or the FactoryBrain address in platform mode) and sign in. Sessions last **one shift** — a tablet left signed in must not still work for the next crew. Choose your language (🌐: ไทย / 日本語 / English); it applies to screens, narratives and reports.

| Role | You can |
|---|---|
| Viewer | See dashboards and narratives, ask questions |
| Inspector | Also: review queue, change verdicts, see evidence images |
| Engineer | Also: recipes, calibration, models (shadow), datasets |
| Manager | Also: deliver narratives, approve agent actions |
| Admin | Everything, including promoting models and configuration |

If a line is missing from your filters it is outside your scope — ask an administrator.

---

## A2 Line operator — the station screen

The kiosk beside the line shows one thing at a time:

```
┌────────────────────────────────────────────┐
│  L2 · ST3  Feeder #3 out       ● Connected │
├────────────────────────────────────────────┤
│                                            │
│                ✅  PASS                     │
│                                            │
│          RAD-500-A · LOT-2609-114          │
├────────────────────────────────────────────┤
│  Shift B   Inspected 1,240   NG 37  2.98 % │
│  Review 0   No read 0                      │
└────────────────────────────────────────────┘
```

### The four results

| Result | Meaning | You |
|---|---|---|
| ✅ **PASS** | Judged good | Continue |
| ❌ **FAIL** | Defect found (the overlay shows where) | Route per work instruction |
| ⚠️ **REVIEW** | Not sure — needs a person | Put it in the review lane. **Do not guess.** |
| ⛔ **NO READ** | Could not see the part properly (blur, glare, mis-position, no calibration) | Re-present it. If it keeps happening, call maintenance — it is the camera or light, not the part |

**NO READ is not PASS.** The part has not been inspected.

### The status light

| Status | Meaning | You |
|---|---|---|
| ● Connected | Normal | — |
| ◐ **Offline — buffering** | Server unreachable. **Inspection is still running normally.** Results upload later | Keep working |
| ⛔ **FAULT** | The station cannot judge (camera, model, calibration, disk) | **Stop presenting parts. Call maintenance.** |
| 🔧 Building model… | New model being prepared (1–5 min) | Wait; the light goes green |

Offline is not broken. FAULT is the only stop signal.

### Scanning the label
Scan the lot/SKU label when prompted. If the scanner fails you can type it, but typed entries are flagged and your supervisor is told if there are many — a wrong SKU applies the wrong rules to every part.

---

## A3 QC inspector — the review queue

**Quality → Review queue.** Parts the system was not confident about. Your decision is the verdict of record.

```
┌───────────────────────────┬──────────────────────────────┐
│                           │  RAD-500-A · LOT-2609-114    │
│  [image with overlay]     │  2026-09-09 14:32 · L2 · ST3 │
│                           │                              │
│   ⊕ zoom   ▣ heatmap      │  Model saw: SCRATCH 61 %     │
│                           │   (rule threshold 75 %)      │
│                           │  Anomaly: no                 │
│                           │                              │
│                           │  [P] Pass  [F] Fail  [S] Skip│
└───────────────────────────┴──────────────────────────────┘
        ← →  navigate     Z zoom     H heatmap     R reason
```

Keyboard: **P** pass · **F** fail · **S** skip · **Z** zoom · **H** anomaly heatmap · **R** reason code. A hundred parts should take about five minutes. The item is reserved for you for 5 minutes so two people never judge the same part.

**Reason codes matter.** `FALSE_ALARM` (model saw a defect that isn't one) and `ACCEPTABLE_MARK` (real mark, within limit) lead to different fixes. If you choose **Fail**, say what you saw (**label class**) — it teaches the next model.

Your decision is stored with your name and time. The model's original verdict is kept beside it, never erased. You cannot delete a decision; you can add a new one.

**If you disagree with the model often on one class or SKU, tell your engineer.** That is a threshold or training signal, not something to absorb quietly.

---

## A4 Quality engineer

### Reading the day
**Dashboard → Line.** Defect rate uses only PASS and FAIL; REVIEW and NO READ are shown separately. A rate shown as **—** means nothing was judged (not 0 %).

**Stats → Correlation** shows defect share by shift, station, SKU and lot **next to volume share**. 31 of 37 defects in Shift B means little if Shift B ran 80 % of the parts; compare the *rate* column.

### Requesting a recipe change
You own recipes (**Admin → Recipes**, see B4). Before saving, the screen runs a **dry-run** on the last 500 parts and shows what would flip:

```
Proposed: SCRATCH threshold 0.75 → 0.60
   PASS → REVIEW   14        REVIEW → FAIL   2        FAIL → PASS   0
   Defect rate 3.0 % → 3.4 %      Expected +14 REVIEW/day
```
Read it. Then give a reason — it is recorded with your name.

### The agreement report
**Stats → Agreement.** Per class: how often the model and inspectors agreed. Two cells matter:

| Cell | Meaning | Response |
|---|---|---|
| Model FAIL, human PASS | False alarm | Consider raising the threshold |
| **Model PASS, human FAIL** | **Escape** — found later by a person | Lower the threshold, retrain; this is the critical-recall signal |

### Retraining hand-off
**Admin → Datasets → New snapshot** from overrides and confirmed reviews (B6). Freeze it; give the export to training. The model that comes back must name this snapshot — that is how any model can be traced to its data.

---

## A5 Production manager

### The daily narrative
Arrives after Shift B in Discord and on the dashboard:

```
Production line 2 — 2026-09-10
1,240 units inspected · 37 defects · defect rate 2.98 % (+42 % vs 7-day avg 2.10 %)
Main defect: missing fin (19 pcs, 51 %)
Most affected SKU: RAD-500-A
Possible correlation: 31 of 37 defects in Shift B · 27 of 37 at station ST3,
coincident with lot LOT-2609-114 entering at 14:05 (5.12 % on that lot vs 0.94 % before)
Recommendation: inspect feeder station #3 and verify the incoming lot.
Confidence: correlation only — not verified as root cause.
Sources: inspection_stats · defect_pareto · station_breakdown · shift_correlation
```

**"+42 % vs 7-day avg" with a significance note** means the change is unlikely to be normal variation. When a day is normal, the narrative **says so and recommends nothing**. That is information, not a missing answer.

### Reports
**Reports → Generate**: daily, shift, station, agreement, calibration — PDF or PPTX, in your language.

---

## A6 Using the narrative agent

**Ask** in the sidebar or `/ask` in Discord.

| Instead of | Ask |
|---|---|
| "How was today?" | "Defect rate on line 2 today versus the last 7 days?" |
| "Why so many defects?" | "Which station and shift had the highest defect rate on line 2 yesterday?" |
| "Is the new lot bad?" | "Defect rate for lot LOT-2609-114 versus the previous lot?" |

Every answer carries **sources**; click **Show the numbers** for the underlying query results.

### What you must understand about this agent

**It cannot invent a number.** Every figure is checked against query results before you see it. If one cannot be matched, the whole answer is **withheld** — you will occasionally see "could not be verified". That is the safety net working.

**It can only see inspection data.** Ask about machine temperature or material certificates and it will say "outside my data". In platform mode it can hand such questions to the quality-engineering agent.

**It can still be wrong about reasoning.** "31 of 37 defects in Shift B, therefore Shift B has a training problem" can be perfectly grounded and wrong. The agent is told to say *correlation* and *possible*; you should read it that way.

| Trust it for | Be careful with |
|---|---|
| Counts, rates, trends, shares | Causes |
| Which station / shift / lot / SKU | *Why* that station / shift / lot / SKU |
| "This resembles 14 May" | "This is the same problem as 14 May" |
| Drafting the report structure | The conclusion in the draft |

**Never use it as the sole basis for** stopping a line, scrapping product, a customer commitment, or a safety decision.

---

## A7 Discord

| Command | Does |
|---|---|
| `/narrative [date] [line] [lang]` | Post the daily narrative |
| `/ask <question>` | Same agent as the web app |
| `/kpi <line> <period>` | Quick figures |
| `/status` | Fleet and camera status |
| `/approve <id>` · `/deny <id>` | Decide a pending action (managers) |

Approval prompts show the **exact message** that would be posted. Your Discord account must be linked to your VisionOps account; being in the channel grants nothing.

---

## A8 FAQ

**The station says Offline — buffering. Do I stop?** No. Only ⛔ FAULT means stop.

**The station shows NO READ on every part.** It is the camera or lighting, not the parts. Call maintenance (RB-03). Those parts were not inspected.

**My verdict was changed.** Open the inspection → override history shows who, when and why. Nothing is deleted.

**The dashboard rate differs from my count.** Check whether you counted REVIEW or NO READ as defects — the system does not. Click **Show the SQL** on any narrative figure.

**The agent refused my question.** It does that when the data is insufficient or outside inspection data. That is a feature.

**Why is the image missing for a PASS part?** PASS images are sampled (about 1 in 50) to keep storage bounded. FAIL and REVIEW images are always kept for two years.

**Can I get the report in Japanese?** Yes — choose the language when generating, or set your default.

---

# Part B — Administrator Guide

## B1 Users and roles
As FactoryBrain UM B1: lowest role that works; **two admins with MFA, never one**; remove access on the day someone leaves; no shared accounts. VisionOps adds: **model promotion is admin-only**, and recipe/calibration changes are engineer-and-above with a mandatory reason.

## B2 Stations and cameras

**Admin → Stations.** A station has a code, a trigger mode, a camera and a **PLC I/O map**:

```json
{"ready":"Q2.0","pass":"Q2.1","fail":"Q2.2","review":"Q2.3","fault":"Q2.4","trigger":"I2.0","pulse_ms":200}
```

The map must match the panel drawing. **Changing it sets `recommission_required`** on the station and the fleet view shows it until a controls engineer re-runs commissioning check 4 (verdict absence → hold). Do not clear the flag without that test.

Camera exposure and gain are **fixed** per station and recorded here. Never enable auto-exposure: it hides the lighting drift the system is watching for.

## B3 Calibration

**Admin → Cameras → Calibrate.** The procedure is [OPS §3.7](OPS-VisionOps-Deployment-Operations.md): target at the part plane, ≥ 15 frames, then **30 measurements of the certified gauge**. The calibration becomes valid only if the worst gauge error is ≤ 0.2 mm.

| Result | What it means | Do |
|---|---|---|
| ✅ valid, max error 0.09 mm | Ready | Record on the commissioning sheet |
| ❌ invalid, max error 0.36 mm | Setup problem: focus, target flatness, distance | **Fix the setup, then repeat.** Do not re-run hoping it passes |
| ⚠️ invalidated: fingerprint mismatch | Camera, lens or mount changed | Recalibrate ([RB-06](OPS-VisionOps-Deployment-Operations.md)) and re-validate the model |

While a camera has no valid calibration, any recipe with a measurement rule makes the station show **FAULT** with reason `CALIBRATION_STALE`. That is correct — a confident wrong measurement is worse than a stopped station.

**Redo calibration when:** camera, lens, mount, working distance or lighting setpoint changes; quarterly as a check; or when the monthly gauge spot-check drifts.

## B4 Recipes

**Admin → Recipes.** One recipe per SKU; every save creates a **new version** with your reason. Old versions are kept; each inspection records the version that judged it.

### Rule types

| Rule | Fails when | Example |
|---|---|---|
| `class_present` | A listed class is detected at or above its threshold | `MISSING_FIN ≥ 0.60` |
| `class_count` | More than `max` detections of a class | `DENT > 2` |
| `class_area` | Detected area exceeds `max_mm2` (needs calibration) | `SCRATCH > 12 mm²` |
| `measurement` | A dimension is outside LSL…USL (needs **valid** calibration) | `fin_pitch 2.8–3.2 mm` |
| `ocr_match` | Printed code does not match the pattern | `^LOT-\d{4}-\d{3}$` |

**Review threshold** (per recipe): a detection between the review threshold and the rule threshold gives REVIEW instead of FAIL. Lower it to catch more (more inspector work); raise it to reduce REVIEW load (more risk of escapes). **Anomaly** can only add REVIEW, never FAIL.

### Before saving — read the dry-run
The screen re-judges the last 500 parts under your proposed rules and shows exactly what would flip. If lowering a threshold shows "FAIL → PASS 14", you are about to let 14 defects through per 500 parts. If you relax a threshold on a **critical** class, managers are alerted automatically — that is expected, not an error.

Change **one SKU at a time** and watch a shift.

## B5 Models

**Admin → Models.**

```
candidate → shadow (≥ 200 live parts, no effect on verdicts) → review report → promote → rollback available
```

- **Register** a candidate from its manifest. The file's SHA-256 is checked; a mismatch is refused and logged as a security event.
- **Shadow** runs the candidate beside the live model on real parts. The report shows disagreement per class and the critical-recall delta.
- **Promote** (admin) is **refused if critical-class recall < 98 %**. The screen tells you why. There is no override — a model that misses more critical defects is a worse model here, whatever its overall score.
- **Rollback** is one click with a reason. The previous model is always kept.

After promotion, nodes build their engines (1–5 min, `READY` low, HMI "Building model…"). Roll out to **one node first**, soak a shift, then the rest.

**Drift alerts** mean the images changed — lighting, a moved camera, a new part finish. Find the physical cause first. Retraining to match a drifted camera hides the problem.

## B6 Datasets and retraining

**Admin → Datasets.** A snapshot gathers labelled parts from overrides, confirmed reviews and a sample of PASS parts. Curate it (remove mislabels), then **Freeze** — after that it cannot change, and its images are protected from the retention sweep. Hand the export (COCO/YOLO) and its SHA-256 to training.

The model that comes back must name the snapshot in `trained_from`; otherwise it cannot be promoted. This is how any verdict can be traced to the data that trained the model that produced it.

## B7 Edge fleet

**Admin → Edge nodes.**

| Column | Watch for |
|---|---|
| Heartbeat age | > 3 min → [RB-08](OPS-VisionOps-Deployment-Operations.md) |
| Camera state | `frozen` or `disconnected` → RB-02 / RB-01 |
| Calibration valid | ✗ with a measurement rule → RB-06 |
| Buffer depth | Rising → sync problem, line unaffected |
| Config ETag | ≠ current → recipe not applied (RB-13) |
| App / model version | Drift across the fleet |
| `recommission_required` | Station I/O changed, not yet verified |

## B8 Alerts

| Alert | Set from | Not this |
|---|---|---|
| Defect rate | Process capability | A round number |
| NO READ ratio | Commissioning baseline (+ margin) | Zero — some NO READ is normal |
| Review queue depth | Inspector capacity per shift | — |
| Override burst | Real inspector throughput | So low it fires on a busy inspector |
| Manual SKU entry | 5 % | — |
| Drift | 3σ | — |

Review monthly which alerts were acted on. An ignored alert teaches people to ignore the channel — delete or retune it.

## B9 Audit and jobs

**Admin → Audit** is append-only; nobody can alter or delete entries. Recorded: overrides, recipe versions (with full rules before/after), calibrations and verifications (with raw repeats), model registration/shadow/promotion/rollback, dataset freezes, station changes, config changes, evidence exports, every agent run.

**Admin → Jobs**: `daily_narrative`, `agreement_stats`, `retention_sweep` (disk fills if it fails), `partition_maintain` (monthly), `drift_check`, `backup_full` (**critical**).

## B10 Health and escalation

**Admin → Health.** `degraded` because the LLM is down is **not an outage** — inspection, review and stats work; only narratives pause. Say "AI narratives unavailable", not "the system is down".

| Symptom | Runbook |
|---|---|
| Camera disconnected | RB-01 |
| **Frozen / replayed feed** | **RB-02 — integrity** |
| NO READ spike | RB-03 |
| Slow verdicts | RB-04 |
| PLC not getting verdicts | RB-05 |
| Camera / lens / light changed | RB-06 |
| Review backlog | RB-07 |
| Node offline / buffer rising | RB-08 |
| Disk | RB-09 |
| Model won't load | RB-10 |
| Escapes rising after a new model | RB-11 |
| **"Could not be verified" narratives rising** | **RB-12 — integrity** |
| Recipe not applied | RB-13 |

---

## Glossary

| English | ไทย | 日本語 | Note |
|---|---|---|---|
| Inspection | การตรวจสอบ | 検査 | |
| Verdict | ผลตัดสิน | 判定 | PASS / FAIL / REVIEW / NO READ |
| Pass / Fail | ผ่าน / ไม่ผ่าน | 合格 / 不合格 | |
| Review | รอตรวจสอบ | 要確認 | Needs a person |
| No read | อ่านไม่ได้ | 読取不可 | Not inspected — **not** a pass |
| Override | การแก้ผลตัดสิน | 判定変更 | Human decision of record |
| Defect rate | อัตราของเสีย | 不良率 | FAIL ÷ (PASS + FAIL) |
| Escape | ของเสียหลุด | 流出 | Defect that passed |
| False alarm | แจ้งเตือนผิด | 誤検出 | Good part called defective |
| Recall | อัตราการตรวจจับ | 検出率 | Share of true defects caught |
| Confidence | ความเชื่อมั่น | 信頼度 | Model score 0–1 |
| Threshold | เกณฑ์ | しきい値 | |
| Recipe | สูตรตรวจสอบ | 検査レシピ | Rules per SKU |
| Calibration | การสอบเทียบ | 校正 | Pixel → mm |
| Gauge | เกจมาตรฐาน | ゲージ | Certified reference |
| Station | สถานี | ステーション | Inspection position |
| Trigger | สัญญาณทริกเกอร์ | トリガ | Part in position |
| Fault | ขัดข้อง | 異常 | Station cannot judge |
| Evidence image | ภาพหลักฐาน | 証拠画像 | |
| Anomaly | ความผิดปกติ | 異常検知 | Unknown defect → REVIEW |
| Shadow run | การทดสอบเงา | シャドー運用 | New model, no effect |
| Dataset snapshot | ชุดข้อมูลฝึก | 学習データセット | Frozen, traceable |
| Drift | การเบี่ยงเบน | ドリフト | Images changing over time |
| Missing fin | ฟินขาด | フィン欠品 | |
| Missing component | ชิ้นส่วนขาด | 部品欠品 | |
| Scratch / Dent | รอยขีดข่วน / รอยบุบ | キズ / へこみ | |
| Lot | ล็อต | ロット | |
| Shift | กะ | シフト | |
| Takt time | เวลาแท็กต์ | タクトタイム | |

---

## Appendix — One-page quick reference

**Operator** — PASS go · FAIL route · **REVIEW to the lane, don't guess** · NO READ re-present, then call maintenance · Offline is fine · **FAULT means stop**.

**Inspector** — P/F/S · reason code every time · say what you saw on a FAIL · your decision is final and recorded · report persistent disagreement.

**Engineer** — read the dry-run before saving a recipe · fix the setup, don't re-run the gauge until it passes · escapes cell = critical-recall signal · freeze the snapshot before training.

**Manager** — "+42 %, significant" means probably not noise · correlation ≠ cause · a normal day says "within normal variation" and that is the answer · never act on a narrative alone for a line stop, scrap or customer commitment.

**Admin** — two admins with MFA · one node first · no bypass for the recall gate · never disable grounding, checksum or frozen-frame checks · rising "could not be verified" is an incident today.
