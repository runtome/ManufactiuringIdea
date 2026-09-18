# User Manual & Administrator Guide — MoldMind (AI Vision + Agent for Injection Molding)

| Field | Value |
|---|---|
| Document ID | UM-11-MoldMind |
| Version | 1.0 (Draft) |
| Date | 2026-09-18 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-11](../SRS-MoldMind-Injection-Molding-AI.md) · [OPS-11](OPS-MoldMind-Deployment-Operations.md) · [SEC-11](SEC-MoldMind-Security-Requirements.md) §5.7 (roles) · [API-11](../api/API-Specification.md) · [ICD-11](ICD-MoldMind-Interface-Control.md) IF-59, IF-61 |
| Languages | This manual is in English; the product UI and outputs are in Thai, Japanese and English with the moulding glossary (FR-27, NFR-09). Part C is the glossary. |

---

# Part A — User guide

## A.1 What MoldMind does — and what it never does
MoldMind watches every shot of the press (the parameters), every part that comes out (the camera), and everything that changed around them (lot, mould, maintenance, setpoint edits). When a defect trend appears it tells you which cavity, which parameters moved, what happened on the timeline, and walks you through the known causes in the order a good process engineer would — checks first, then bounded parameter changes — and then measures whether your fix worked.

It never:
- **touches the machine.** MoldMind reads; it cannot write a setpoint (C-01). Every change is yours, at the controller.
- **suggests a value outside the documented window.** A suggestion outside the mould/material limits is shown blocked, with the window and its source (C-05, AC-05).
- **puts a parameter change before a check** (C-04).
- **states a cause it has not verified.** Causes are ranked hypotheses until an engineer verifies one; the ranking is a formula you can read, not a model's opinion (AI-05).
- **calls a fix effective without a test** (FR-24).
- **blames a cavity it cannot attribute.** Every defect belongs to one shot and one cavity, or it is not counted (C-02).

## A.2 Roles
| Role | Can |
|---|---|
| Viewer (production manager) | see shots, cavity analysis, deltas, drift, golden run, sessions, scrap cost |
| Molding technician / mould maintenance (inspector) | + review low-confidence detections; record startup events and manual parameter changes; start sessions; answer; mark checks/actions done; record what was applied; request effectiveness |
| Process engineer / quality engineer (engineer) | + verify causes; close sessions; hand off the 8D; author and approve setup sheets, windows and knowledge (not their own) |
| Manager | + approvals |
| Admin | machines, node maps, scoring, models, config |

## A.3 Molding technician — a defect trend from alert to fix
### A.3.1 The alert
"**Sink marks on MLD-0417 — 1.5 % → 9.0 % since 10:40, cavity 3 flagged**". Open the mould:
- **Cavity view**: parts and fail rate per cavity, with the flag test ("cavity 3: 20/100 vs 16/300 on the others, p < 0.001"). Startup transients are shown greyed and excluded.
- **Parameter delta**: which parameters differ between defective and good shots, with the effect size: "holding pressure 582 vs 625 bar, d −1.26; cushion 3.3 vs 4.1 mm".
- **Timeline**: "10:40 parameter edit holding pressure 650 → 560 (controller user 07)". Lot change? Maintenance? Startup?
- **Golden run**: current parameters vs the approved setup sheet, out-of-tolerance in red.

### A.3.2 Start the RCA
**Start RCA → sink mark**. The ranked causes appear with their scores and — under *why this order* — the components:

```
1. Insufficient holding pressure     0.88   prior 1.0 · delta 1.0 · timeline 1.0 · case 0.2
2. Holding time too short            0.23   prior 0.67
3. Melt temperature too high         0.18   prior 0.5
4. Mould temperature too high (local) 0.18  prior 0.5
5. Part wall thickness (design)      0.12   design cause — engineering
6. Insufficient cooling time         0.12   prior 0.33
```
`prior` is the knowledge base's weight; `delta` says the parameters moved the way this cause predicts; `timeline` says something that explains it happened at the onset; `case` says past verified cases support it. The weights (0.35/0.30/0.20/0.15) are shown too.

### A.3.3 Answer the questions
The agent asks one question at a time from the knowledge base — "Was the material dried per spec?", 「材料ロットは変更しましたか？」, "Was mould maintenance performed?" — in your language. Answer yes/no/unknown or a value; the ranking updates after each answer and you see what changed.

### A.3.4 Do the checks, then the change
**Advice** lists checks first, changes after — the order is fixed:
1. ☐ Verify cushion vs setup sheet (target 3–6 mm) — currently 2.8 mm
2. ☐ Check the holding-pressure trace against the golden run (650 bar)
3. ☐ **Action**: holding pressure **up +5..+15 %** — window **500–750 bar** (mould datasheet rev C) — side effects: flash, internal stress

Tick each check as you do it. For the action, enter the value you intend: **616 bar → allowed** (+10 %). **800 bar → blocked**: "outside [500, 750] bar" — it is logged and cannot be allowed; ask a process engineer if you believe the window is wrong.

### A.3.5 Apply at the controller, record, verify
Make the change at the press yourself; MoldMind captures the setpoint edit on the timeline. **Record action** (what, when). After enough shots (≥ 200), **Verify effectiveness**: "before 9.0 % (36/400), after 1.75 % (7/400), p < 0.001 — **effective**". If the test says *not effective* or *inconclusive*, that is the answer — continue with the next check; nobody can type "effective".

### A.3.6 Close
A process engineer verifies the cause and closes the session; the verified cause–action–outcome is written into the knowledge base as evidence, and the 8D is handed to QE-Agent (FR-26) — you will find the draft there.

## A.4 Process engineer
- **Cavity analysis, deltas, drift, golden run** — the four views above, over any window; drift shows the slope per shot and when a parameter will leave tolerance.
- **DOE support**: export shots with parameters and verdicts for a window (`GET /shots`), transients excluded.
- **Verify a cause / close a session**: the verified cause must be one of the ranked causes; closures are *verified*, *design cause* or *unresolved*.
- **Knowledge authoring** (Part B.4): edit the YAML, import a draft, ask a colleague to approve.
- **Windows and setup sheets**: every value needs a source (datasheet, validation); approved versions are immutable — create a new one.

## A.5 Quality engineer
Hand the session to QE-Agent for the 8D (`Handoff 8D`); the draft carries the trend, deltas, timeline, verified cause, actions and effectiveness with evidence codes; approval, export and the customer document happen in QE-Agent.

## A.6 Mould maintenance
The cavity view and the flag test tell you *which* cavity; the defect images (region: gate area, far end, rib, boss, parting line) tell you *where*; the timeline tells you when polish/maintenance last happened. Record maintenance as a startup event (`mould_change`) so the first shots are treated as transients.

## A.7 Production manager
**Scrap cost** per defect class per period (defects × unit cost); the RCA board (open sessions, blocked suggestions, effectiveness); the KB status (approved versions, evidence).

## A.8 Reading the numbers honestly
| Field | Meaning |
|---|---|
| fail rate / defect rate | failed parts ÷ parts, transients excluded; the flag compares a cavity with the mould's other cavities (p < 0.01, ≥ 200 parts) |
| Cohen's d | standardised difference defective vs good; |d| ≥ 0.8 is large |
| slope per shot | least-squares drift; sign shows direction |
| score / components | Σ weight × component; components are 0–1 and shown |
| blocked | outside the documented window — never a recommendation |
| effective | p < 0.05 and the rate fell; anything else is *not effective* or *inconclusive* |
| startup transient | one of the first N shots after a stop/mould change/purge — shown, not counted |

---

# Part B — Administrator guide

## B.1 Machines
Register the connection (protocol, endpoint, the **read-only** credential file, SignAndEncrypt); load the node map (every FR-01 parameter, setpoint nodes, controller user); run the connection test and confirm `write_refused_by_server`. A firmware change is a new node-map version. If the press ever reports a refused write, follow OPS-11 RB-11.

## B.2 Camera station
Trigger, lighting recipe per class (sink marks and weld lines require low-angle lighting), reference chart in frame, enclosure alarms. Any camera/lens/lighting change → re-calibration and re-validation.

## B.3 Moulds, setup sheets, windows, colour, scrap cost
Cavities; setup sheet versions (author, approver ≠ author, one active); process windows per material grade and parameter with a source — a parameter without a window blocks every suggestion for it; colour reference Lab and threshold; unit cost.

## B.4 Knowledge base
Files under `deploy/kb/` (one per defect class, SRS Appendix A shape): every cause has a prior weight, typical parameter directions, checks, actions (direction, range, window reference, side effects) and a **source**. Import creates a draft; a process engineer who is not the author approves it; approved versions are immutable; every version runs the golden set (≥ 15 incidents, ≥ 70 % top-3) before it ranks. Verified outcomes are written back as evidence automatically.

## B.5 Scoring
Weights prior/delta/timeline/case sum to 1; a new weight version is inactive until a golden run passes; the database recomputes every score from its components, so the ranking cannot be edited.

## B.6 Models and evaluation
Family detection models are released only when the hold-out evaluation passes (mAP ≥ 0.80; recall ≥ 0.95 on short shot, flash, contamination). The dialogue model is ≤ 9 B at temperature ≤ 0.3 and is used only for questions and explanations; without it the dialogue runs scripted.

## B.7 Transients, data quality, buffering
Transient window (default 20 shots) per startup event; data-quality flags (missing zone temperature, stuck value, clock skew) on the daily view; the gateway buffers ≥ 24 h and reconciles by shot id — watch `open_batches` and `duplicates`.

## B.8 Glossary and languages
`glossary.csv`: JA term, reading, TH, EN, forbidden variants (ヒケ not 引け跡; バリ not フラッシュ; ショートショット not 充填不足). The term check runs on dialogue text; a Japanese session is reviewed by a native speaker before release (AC-08).

## B.9 What to watch
OPS-11 §9: shot lag, buffer depth, **write refusals (must be zero)**, alignment misses, attribution method mix, inference latency, review rate, blocked-suggestion share, outcome mix, stale knowledge, evaluation gates.

---

# Part C — Glossary (TH / JA / EN)
| EN | JA | TH | Meaning here |
|---|---|---|---|
| sink mark | ヒケ | รอยยุบ | surface depression from shrinkage at thick sections |
| flash | バリ | ครีบ | excess material at the parting line |
| short shot | ショートショット | ฉีดไม่เต็ม | incomplete filling |
| weld line | ウェルドライン | รอยประสาน | line where flow fronts meet |
| silver streak | シルバーストリーク | ริ้วสีเงิน | moisture/volatile streaking |
| burn mark | 焼け | รอยไหม้ | degradation / trapped-gas burn |
| warpage | 反り | บิดงอ | distortion after ejection |
| contamination / black spot | 異物 | สิ่งปนเปื้อน | foreign material |
| holding pressure | 保圧 | แรงดันย้ำ | pressure after fill |
| holding time | 保圧時間 | เวลาย้ำ | duration of holding |
| cushion | クッション | คุชชั่น | residual material at end of hold |
| injection pressure / speed | 射出圧 / 射出速度 | แรงดันฉีด / ความเร็วฉีด | fill phase |
| melt temperature | 樹脂温度 | อุณหภูมิหลอม | per zone |
| mould temperature | 金型温度 | อุณหภูมิแม่พิมพ์ | fixed / moving half |
| cooling time | 冷却時間 | เวลาหล่อเย็น | |
| clamping force | 型締力 | แรงปิดแม่พิมพ์ | |
| cavity | キャビティ | โพรงแม่พิมพ์ | one impression |
| setup sheet / golden run | 条件表 | ใบเงื่อนไขการฉีด | the approved parameter set |
| process window | プロセスウィンドウ | ช่วงค่าที่อนุญาต | documented limits per mould × material |
| startup transient | 立ち上げ過渡 | ช่วงเริ่มเดินเครื่อง | first N shots after a stop |
| check before change | 確認優先 | ตรวจก่อนปรับ | advice ordering rule |
| hypothesis to verify | 要検証の仮説 | สมมติฐานที่ต้องตรวจสอบ | an unverified cause |
| effective | 効果あり | ได้ผล | rate fell with p < 0.05 |
