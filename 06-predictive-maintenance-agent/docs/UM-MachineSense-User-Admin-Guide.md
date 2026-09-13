# User Manual & Administrator Guide — MachineSense AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | UM-06-MachineSense |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-06](../SRS-MachineSense-Predictive-Maintenance.md) · [SAD-06](SAD-MachineSense-Software-Architecture.md) · [API-06](../api/API-Specification.md) · [OPS-06](OPS-MachineSense-Deployment-Operations.md) · [SEC-06](SEC-MachineSense-Security-Requirements.md) |
| Audience | Part A: maintenance technicians, maintenance planners, production managers, reliability engineers. Part B: plant administrators |
| Languages | The product UI, alerts and explanations are in Thai, Japanese or English (FR-27). This manual is in English; the glossary (Part C) gives the TH/JA terms used on screen |

---

# Part A — User guide

## A0. Read this first (everyone)

MachineSense **watches machines and tells people**. It never touches a machine — it cannot change a setpoint, stop a press or clear an alarm, and there is no setting that would let it (SEC-06 §5.1). Everything it says is advice; the decision and the work are yours.

Three habits make it useful:

1. **Read the numbers, not just the colour.** Every alert shows *now*, *baseline*, how far off it is (**σ**), and how fast it is moving. Those numbers were computed by the scoring engine from the sensors — the AI only puts words around them.
2. **Treat the assessment as a hypothesis.** "Consistent with drive-side bearing degradation (likelihood: high)" means *go and check the bearing*, not *the bearing is broken*. The inspection steps are how you find out.
3. **Tell it what you found.** When you close an alert you are asked whether it was right. That answer is what tunes the system; a plant that skips it drowns in alerts within months.

If MachineSense says nothing about a machine, that does not mean the machine is healthy — it means nothing in the monitored signals has moved. Keep doing your rounds.

## A1. Technician

### A1.1 Where alerts arrive
Discord channel `#maintenance-alerts` (and email if configured), plus the **Alerts** page in the web app. One alert card per machine and suspected component — if the same bearing keeps getting worse you see updates on the same card, not a new alert every hour.

### A1.2 Reading an alert card
```
⚠️  Machine #7 — Injection press B  ·  severity: HIGH  ·  health index 61/100

Bearing temperature (drive side)
  now 78.4 °C · baseline 68.9 ± 2.1 °C · +13.8 % over 5 days · σ = 4.5
Vibration RMS (drive side, running context)
  now 4.9 mm/s · baseline 2.9 ± 0.9 mm/s · σ = 2.2 · rising 6 consecutive days
Motor current: within baseline.

Top contributing features: bearing_temp_mean, vib_rms, vib_band_2x_rpm

Assessment (likelihood: high): …
Recommended inspection (within 3 days): 1. … 2. … 3. …
Similar past case: 2025-03-18 Machine #4 — outcome: bearing replaced (see case #212).
Estimated RUL: 12–30 days (80 % interval, based on 3 prior comparable failures).
```

| Line | What it means | What it is *not* |
|---|---|---|
| **Severity** WATCH / HIGH / CRITICAL | How far from normal and how fast. WATCH = look at it this week; HIGH = inspect within days; CRITICAL = plan intervention now | A prediction of when it fails |
| **Health index 61/100** | 100 = everything at baseline. Points are lost for each signal drifting from its healthy band and for the anomaly model's score. Below 40 is CRITICAL | A remaining-life percentage |
| **now / baseline ± spread** | The current 1-minute value vs. what this machine did when it was healthy, *in the same running context* (running, idle, changeover…). ± is one standard deviation | A factory limit or the manufacturer's spec |
| **σ = 4.5** | How many standard deviations away from baseline. σ 2 = unusual; σ 3 = clearly abnormal; σ 4.5 = far outside anything seen while healthy | — |
| **+13.8 % over 5 days · rising 6 days** | The trend, from a straight-line fit over the window; only shown when the fit is confident | — |
| **Top contributing features** | Which signals drove the anomaly score. If this list does not match the assessment, question the assessment | — |
| **Assessment (likelihood: high/medium/low)** | The AI's hypothesis, written from the numbers above plus similar past cases. It is required to say "consistent with", never "is caused by" | A diagnosis |
| **Recommended inspection** | Concrete steps from the plant's component map, in the order to try them | A work order (a planner makes that) |
| **Similar past case** | A previous alert on a comparable machine with a known outcome | Proof it is the same fault |
| **Estimated RUL 12–30 days** | An **interval**, only shown when at least three comparable past failures exist. Otherwise the line reads *"RUL: insufficient history (n comparable failures, need 3)"* | A date. There is never a single number |

> Vibration σ: the SRS example prints 2.1; (4.9 − 2.9) / 0.9 = 2.2 and the system always shows the computed value.

### A1.3 Acting on an alert
| Button | When | Effect |
|---|---|---|
| **Acknowledge** | You have seen it and will handle it | Card shows your name; escalation timer stops; nothing else changes |
| **Snooze** (up to 7 days, reason required) | You know why and it can wait (e.g. planned changeover, inspection scheduled) | Card goes quiet; **reopens automatically if severity rises**; the reason is kept |
| **Escalate** | You need the engineer or planner | Notifies the engineer role; the card records who and why |
| **Resolve** | Inspection done or work complete | Opens the **feedback form** (A1.5) — resolve is not accepted without it |

An alert on a machine that is under maintenance (a declared maintenance window, A2.3) is not delivered — you will see it as *suppressed* in the alert list with the window's name, so nothing is hidden.

### A1.4 Doing the inspection
Follow the recommended steps; they are ordered cheapest-first. Record what you measured in the resolve form (free text is fine — "bearing housing 81 °C by probe, grease dry, 2× peak visible"). If you replace or repair something, record a **maintenance event** (Machines → machine → *Record maintenance*) with the component: the engineer will be told to re-baseline the machine, and the system will stop comparing the new bearing with the old one's normal.

### A1.5 Feedback — the most important 20 seconds
On resolve:

| Verdict | Choose when |
|---|---|
| **True positive** | You found the condition the alert pointed at (or one close to it) |
| **False positive** | You inspected and found nothing wrong, or the cause was outside the machine (sensor, cable, environment) |
| **Unknown** | You could not inspect or the result is inconclusive |

Then *actual finding* (what you saw) and *action taken*. False positives are not a criticism of you or of the system — they are the input the engineer uses to tune it (A4.5). Feedback cannot be edited after submission; if you were wrong, add a comment to the incident.

### A1.6 Asking the agent
On any alert or machine page, **Ask** lets you type a question ("what changed on M-07 this week?", "is the coolant related?"). The agent can only read: telemetry, health, alert evidence, maintenance history and similar cases. It cannot act on anything and will say so if asked. If it cannot answer from the data it says *"I cannot determine that from the available data"* — that is a correct answer, not a failure.

## A2. Maintenance planner

### A2.1 Top risks
**Risks** → *This week* lists machines ranked by health index and trend, with the open incidents and the RUL interval where one exists. It is regenerated every Monday 08:00 and on demand. Use it to order the week; the same list goes to the production manager.

### A2.2 Work-order drafts
From an alert card or incident: **Draft work order** produces a draft with the machine, component, findings, recommended steps, parts (from the component map) and the alert evidence attached. Review and edit — the draft is a suggestion. **Export** sends it to the CMMS (if connected) or produces a PDF; the draft keeps its export id, so exporting twice does not create two work orders.

### A2.3 Maintenance windows
Before planned work: **Maintenance windows** → *Declare* (machine, from, to, kind: planned service / changeover / trial / other, reason). During the window alerts on that machine are suppressed and marked so; the window is logged. Do **not** declare windows to silence a noisy machine — escalate it to the engineer instead (that is precisely what precision tuning is for).

### A2.4 Recording maintenance
After any component replacement, overhaul or failure repair, record it (A1.4). This is what allows re-baselining, what the RUL statistics are built from, and what makes "similar past cases" exist for the next person.

## A3. Production manager

**Overview** shows every line with machine health, open incidents by severity and the week's top risks. Two things to know:

- **Health index is comparative, not absolute.** 75 on a press and 75 on a chiller do not mean the same thing; the trend of one machine matters more than the number across machines.
- **RUL intervals are wide on purpose.** "12–30 days" is the honest statement from three previous failures; asking for "the date" would only get you a made-up one. Plan to the low end.

The **Precision** report (Reports → Precision) tells you how often alerts were right last month per machine. Under 70 % on a machine means the engineer is tuning it, not that you should ignore it.

## A4. Reliability engineer

### A4.1 What you own
Baselines, alert rules, the anomaly models, failure labels and the monthly precision review. The technicians' feedback is your raw material.

### A4.2 Onboarding and the four weeks
IT/OT connect the machine (OPS-06 §4.4). For the first four weeks alerts are off while data accumulates. Watch **Machines → machine → Context** to confirm the context classifier separates running / idle / changeover / startup sensibly; fix the context rule in the sensor map with the admin if it does not — everything downstream depends on comparing like with like.

### A4.3 Confirming a baseline
**Baselines → Propose**: pick the window (≥ 28 days), the system computes mean ± σ per feature per context and shows coverage (how many windows per context) and the band on the charts. **Confirm** only if you are satisfied the machine was healthy throughout the window — your name goes on it and the alerts start. If the window contains the beginning of a fault, every later alert on that fault is silenced; that is the one mistake the confirmation step exists to prevent.

### A4.4 After maintenance: re-baseline
A recorded component replacement or overhaul flags the machine *re-baseline required*: alerts downgrade to WATCH and you are asked to confirm a new baseline once four healthy weeks exist. Until then, the old baseline stays visible and marked stale.

### A4.5 Tuning from the precision report
Monthly (OPS-06 §6.3): for each machine below 0.7, open the false positives and read the technicians' findings. Fix the cause in this order: sensor or cable → context rule → suppression (changeover, startup warm-up) → and only then thresholds (`consecutive_windows`, σ minimums per severity). Rule changes are versioned; every alert shows the version it was raised under, so you can see whether a change helped.

### A4.6 Failures and RUL
Label every failure (**Failures → Record**: machine, component, failure mode, date, whether an alert preceded it and by how many days). Three comparable failures on the same machine type and component unlock RUL intervals for that component; the interval width shrinks slowly as more are recorded. There is no setting to show RUL with fewer failures, and no point estimate — by design (SRS C-04).

### A4.7 Models
**Models** lists anomaly model versions per machine type with their retrospective precision and lead time. Retraining runs monthly and after each labelled failure; a candidate is only promotable if it is at least as good as the active version on both metrics — the *Promote* button is disabled otherwise and the database refuses it anyway. Review rejected candidates; repeated rejections usually mean the labelled-failure set is too small.

## A5. The agent — what it can and cannot do

| It does | It does not |
|---|---|
| Explain an alert in plain language from the stored evidence, in TH/JA/EN | Compute any number — every figure it states must exist in the alert's evidence, or the explanation is withheld and you get the structured card only |
| Offer a hypothesis with a likelihood and the verification needed | State a root cause as certain |
| Find similar past cases and their outcomes | Decide, schedule, order parts or write to a CMMS without a planner |
| Answer questions by reading telemetry, health and history | Change a setpoint, stop, start or acknowledge anything on a machine — no such capability exists |
| Say "I cannot determine that from the available data" | Guess |

If the explanation is missing on a card ("explanation withheld — grounding check failed"), the numbers and recommendations are still valid; the wording was rejected because it contained a figure or a claim the evidence does not support. Tell the engineer; it is tracked (OPS-06 RB-08).

---

# Part B — Administrator guide

## B1. Roles
| Role | Can | Cannot |
|---|---|---|
| Viewer | see everything | act on alerts |
| Technician | ack / snooze / escalate / resolve with feedback; record maintenance events | declare windows; export work orders |
| Planner | + windows, work-order drafts and export | baselines, rules, models |
| Engineer | + baselines, re-baseline, failure labels, models, alert rules | sensor map, users |
| Admin | + sensor map (OT endpoints), users, Discord/email mapping, retention | write to a machine — nobody can (SEC-06 §5.7) |

Assign the smallest role that fits; the audit log records every baseline, rule, window and export with the user.

## B2. Machines and the sensor map
The sensor map (`sensors.yaml`, OPS-06 §4.4) is the only place machines, sensors, sources and context rules are defined; it is loaded through **Admin → Sensor map** (validated — an invalid file is refused with the line). Rules you cannot break, because the schema refuses them: OPC-UA access other than read-only; Modbus write function codes; Modbus on a non-isolated segment; an inline credential; OPC-UA without signing and encryption. Every load is versioned; the previous version can be restored.

Onboarding checklist (with IT/OT): read-only account created → write test refused (TC-020) → 48 h clean data quality → 4 weeks → engineer confirms baseline. The quarterly write test is yours to schedule.

## B3. Alert rules
`alert-rules.yaml` (engineer-editable, admin-loadable): consecutive windows, severity ladder, health weights (must sum to 1), suppression, component map, delivery. Keep the component map current — it is where "check the drive-side bearing" comes from. Two values cannot be lowered in the file at all: minimum comparable failures for RUL (3) and the point-estimate switch (false).

## B4. Delivery
Discord channel per plant (or per line), email lists per role, optional webhook (HMAC-signed). Minimum severity to deliver is per rules file; WATCH alerts are normally delivered but can be limited to the web app during a machine's first live week.

## B5. Users, language, timezone
Users are local (standalone) or platform-managed (platform mode). Set each user's language (TH/JA/EN) — alert cards and explanations follow it, numbers and units do not change. Plant timezone is global; all evidence timestamps are stored in UTC and displayed in plant time.

## B6. Retention and backup
Raw 90 days, rollups and features 2 years, alerts/failures/baselines/config versions 5 years and never auto-deleted (OPS-06 §5.4). Nightly backup excludes raw samples on purpose; test a restore quarterly (OPS-06 §7).

## B7. When something looks wrong
| You see | Likely | Do |
|---|---|---|
| A machine shows *offline* or *stuck* sensors | field problem | OPS-06 RB-04; scoring excludes the sensor meanwhile |
| Alert storm on one machine | context/sensor problem or real service in progress | RB-11 |
| Explanations withheld on many alerts | prompt/model change | RB-08 |
| Precision below 0.7 | tuning needed | engineer, A4.5 |
| Someone asks for a "write" feature | — | there is none, and the answer is no (SEC-06 §4.2) |

---

# Part C — Glossary (EN / TH / JA)

| English | ไทย | 日本語 | Meaning |
|---|---|---|---|
| Health index | ดัชนีสุขภาพเครื่อง | 健全性指数 | 0–100 score, 100 = at baseline |
| Baseline | ค่าฐานปกติ | ベースライン | Engineer-confirmed healthy behaviour per context |
| σ (sigma) | ค่าเบี่ยงเบน (ซิกม่า) | シグマ | Standard deviations from baseline |
| Context | บริบทการทำงาน | 運転コンテキスト | Running / idle / changeover / startup / stopped |
| Anomaly score | คะแนนความผิดปกติ | 異常スコア | Model output 0–1, with attribution |
| Attribution / top features | ปัจจัยที่ส่งผลมากที่สุด | 寄与要因 | Signals that drove the score |
| Trend | แนวโน้ม | トレンド | Slope over the window with confidence interval |
| Alert (WATCH / HIGH / CRITICAL) | การแจ้งเตือน (เฝ้าระวัง / สูง / วิกฤต) | アラート（注意 / 高 / 重大） | Severity ladder |
| Incident | เหตุการณ์ | インシデント | One open case per machine and component |
| Acknowledge / Snooze / Escalate / Resolve | รับทราบ / เลื่อน / ส่งต่อ / ปิด | 確認 / スヌーズ / エスカレーション / 解決 | Alert actions |
| Feedback (true / false positive) | ผลตรวจสอบ (ถูกต้อง / ผิดพลาด) | フィードバック（正検知 / 誤検知） | Technician verdict on resolve |
| Precision | ความแม่นยำของการแจ้งเตือน | 適合率 | True positives ÷ (true + false positives) |
| RUL (remaining useful life) | อายุการใช้งานที่เหลือ | 残存耐用期間 | Interval in days, or "insufficient history" |
| Maintenance window | ช่วงซ่อมบำรุง | 保全ウィンドウ | Declared period; alerts suppressed and marked |
| Re-baseline | กำหนดค่าฐานใหม่ | ベースライン再設定 | After component replacement |
| Work-order draft | ร่างใบสั่งงาน | 作業指示書ドラフト | Suggestion for the planner |
| Likelihood (low / medium / high) | ความน่าจะเป็น (ต่ำ / กลาง / สูง) | 可能性（低 / 中 / 高） | How the agent phrases a hypothesis |
| Insufficient history | ข้อมูลในอดีตไม่เพียงพอ | 履歴不足 | Fewer than 3 comparable failures |
