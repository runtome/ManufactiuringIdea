# User Manual and Administrator Guide — FactoryBrain AI Platform

| Field | Value |
|---|---|
| Document ID | UM-00-FactoryBrain |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Audience | Part A — all users · Part B — administrators |

---

## Contents

**Part A — User Manual**
[A1 Getting started](#a1-getting-started) · [A2 Line operator](#a2-line-operator) · [A3 QC inspector](#a3-qc-inspector) · [A4 Quality engineer](#a4-quality-engineer) · [A5 Production manager](#a5-production-manager) · [A6 Using the AI assistant](#a6-using-the-ai-assistant) · [A7 Discord](#a7-discord) · [A8 Mobile app](#a8-mobile-app) · [A9 FAQ](#a9-faq)

**Part B — Administrator Guide**
[B1 Users and roles](#b1-users-and-roles) · [B2 Master data](#b2-master-data) · [B3 Inspection recipes](#b3-inspection-recipes) · [B4 Alerts](#b4-alerts) · [B5 Models](#b5-models) · [B6 Edge fleet](#b6-edge-fleet) · [B7 Prompts and glossary](#b7-prompts-and-glossary) · [B8 Audit](#b8-audit) · [B9 Jobs](#b9-jobs) · [B10 Health and escalation](#b10-health-and-escalation)

[Glossary (TH/JA/EN)](#glossary)

---

# Part A — User Manual

## A1 Getting started

### Signing in
Open `https://factorybrain.local` and sign in with your company username. Administrators also enter a 6-digit code from their authenticator app.

Your session lasts **one shift**. This is deliberate: a session left open on a shared shop-floor tablet must not still work for the next crew. If you are signed out mid-task, nothing is lost — unsaved work is stored locally.

### Choosing your language
Top-right menu → 🌐. Thai, 日本語 and English. The choice applies to the interface, AI answers and exported reports.

### What you can see
Your role and, sometimes, your assigned lines determine what you can access. If a line is missing from a filter, it is outside your scope — ask your administrator rather than assuming it is a fault.

| Role | What you can do |
|---|---|
| Viewer | See dashboards, ask questions |
| Inspector | Also: review queue, change verdicts, see evidence |
| Engineer | Also: SPC, cases, approve AI drafts, upload data |
| Manager | Also: approve actions and ERP postings |
| Admin | Everything, plus configuration |

---

## A2 Line operator

You mostly use the **station screen** on the tablet or panel beside the line.

```
┌──────────────────────────────────────────┐
│  Line 3 · Station ST3     ● Connected    │
├──────────────────────────────────────────┤
│                                          │
│              ✅  PASS                     │
│                                          │
│         RAD-500-A  ·  LOT-2609-114       │
├──────────────────────────────────────────┤
│  Shift B    Inspected 1,240   NG 37      │
│             Defect rate 2.98 %           │
└──────────────────────────────────────────┘
```

### The four results

| Result | Meaning | What you do |
|---|---|---|
| ✅ **PASS** | Judged good | Continue |
| ❌ **FAIL** | Defect found | Route per your work instruction |
| ⚠️ **REVIEW** | Not confident enough to decide | Set aside for an inspector — **do not guess** |
| ⛔ **NO READ** | Could not see the part properly (blur, glare, wrong position) | Re-present the part; if it repeats, call maintenance |

**NO READ is not PASS.** Nothing was judged. A part that reads NO READ has not been inspected.

### Status indicators
| Indicator | Meaning |
|---|---|
| ● Connected | Normal |
| ◐ Offline — buffering | Server unreachable. **Inspection continues normally.** Results upload automatically later. Keep working. |
| ⛔ FAULT | The station cannot judge. **Stop and call maintenance.** |

The middle case matters: an offline station is not a broken station. The system is designed to keep the line running when the network does not.

---

## A3 QC inspector

### The review queue
**Quality → Review queue.** These are parts the system was not confident enough to judge. Your decision is final and is recorded.

```
┌─────────────────────────┬────────────────────────────┐
│                         │  RAD-500-A · LOT-2609-114  │
│    [part image with     │  2026-09-09 14:32:10       │
│     detection overlay]  │  Line 3 · ST3              │
│                         │                            │
│                         │  Model suggests:           │
│                         │    SCRATCH  48 % ← below   │
│                         │    threshold (55 %)        │
│                         │                            │
│                         │  [P] Pass  [F] Fail  [S] Skip │
└─────────────────────────┴────────────────────────────┘
   ← →  navigate      Z  zoom      R  reason code
```

Keyboard-first: **P** pass, **F** fail, **S** skip, **Z** zoom, **←/→** navigate. A hundred parts should take about five minutes.

### Overriding a verdict
Open the inspection, click **Change verdict**, choose the new one and a reason code.

Your decision:
- becomes the verdict of record,
- is stored with your name and the time,
- **never erases** the model's original judgement,
- feeds the training set that improves the model.

Reason codes matter. "Model missed a real scratch" and "model flagged an acceptable mark" lead to opposite fixes.

### When you disagree with the model often
Tell your engineer. Persistent disagreement on one defect class or one SKU usually means the threshold needs adjusting or the model needs retraining — it is a signal, not something to absorb quietly.

---

## A4 Quality engineer

### Control charts
**Quality → SPC.** Select a characteristic and a line.

- Points outside the limits and rule violations are marked with the **Nelson rule number**.
- Control limits show the baseline period and **why they were set**. Limits are never recalculated silently — every change carries a reason and an author.

### Process capability
**Quality → Capability.** Cp, Cpk, Pp and Ppk are always shown with:
- **n** — the sample size,
- the **period** evaluated,
- a **normality check**.

> ⚠️ If normality is rejected, the page says so and warns you. Cp and Cpk assume a normal distribution; quoting them for non-normal data produces a confident, wrong number. The system will not hide this from you.

### Working a quality case

```
Signal detected ──► Case opened ──► Analyse ──► Hypotheses
                                                    │
                        Verify a hypothesis ◄───────┘
                                │
                    Draft 5-Why / 8D  ──► YOU REVIEW ──► Approve
                                │
                        Actions ──► Verify effectiveness ──► Close
```

**Analyse** tests whether the defect is associated with material lot, machine, mould, shift, operator group or a recent parameter change. It returns **ranked hypotheses**, each with supporting evidence, contradicting evidence and a suggested way to verify it.

> These are hypotheses, not causes. The system finds *correlation*. Only you can confirm *causation* — usually by going and looking.

### Approving AI drafts
Drafted 5-Why, 8D, FMEA rows and reports arrive marked:

```
╔══════════════════════════════════════════╗
║   DRAFT — AI generated · not approved    ║
╚══════════════════════════════════════════╝
```

Until you approve it, a draft:
- cannot be exported without that watermark,
- cannot be found by anyone searching past cases,
- cannot be cited by the AI in a future analysis.

**Before approving, check the four things the AI cannot check for you:**
1. Do the numbers match what you know? (Click **Show the numbers**.)
2. Is the causal chain actually logical, or just plausible-sounding?
3. Is anything important missing that is not in the data?
4. Would you sign your name to this? Because approving is exactly that.

Edit freely first — your edits are tracked against the AI version.

### Verifying effectiveness
When you close an action, the system compares the defect rate before and after with a significance test. If there is no real improvement, it says so. **Resist the temptation to close a case with "no significant improvement" recorded** — that is the system telling you the fix did not work.

---

## A5 Production manager

### Dashboard
**Home** shows today's KPI tiles, trend, defect Pareto, and a line/shift heatmap. Filter by date, line, SKU or shift.

> A defect rate shown as **—** means nothing was produced. It is deliberately not shown as 0 %, which would read as a perfect day on a line that did not run.

### The daily brief
Arrives each morning in Discord and on the dashboard:

```
📅 Production Report — 2026-09-10
Production : 12,430 pcs      Defects: 382 pcs
Defect rate: 3.07 %  (7-day avg 2.59 %, +18.4 %, p = 0.004 → significant)
Top defect : Missing Component — 41 %
Worst line : Line 3 — 5.82 % (n = 2,140)

AI analysis:
Line 3 shows abnormal defect growth beginning during Shift B...

Recommended action:
1. Check component feeder on Line 3.
2. Review Shift B operator changeover records.

Note: correlation only; root cause not verified.
```

**Read "p = 0.004 → significant" as: this change is unlikely to be normal variation.** When a change is *not* significant, the brief says the day was within normal variation — and that is useful information, not a missing answer.

### Reports
**Reports → Generate.** Daily, shift, case, SPC or fleet, as PDF or PPTX, in any of the three languages. Unapproved AI content is always watermarked.

---

## A6 Using the AI assistant

**Ask** in the sidebar, or `/ask` in Discord.

### Asking well

| Instead of | Ask |
|---|---|
| "How are we doing?" | "What was the defect rate on line 3 last week compared with the previous week?" |
| "Why so many defects?" | "Which defect type increased most on line 2 in September?" |
| "Is machine 7 OK?" | "Show the bearing temperature trend for machine 7 over the last 14 days." |

Be specific about **line, date range and metric**. If your question is ambiguous in a way that changes the answer, the assistant will ask rather than guess.

### Reading an answer

Every answer carries its **sources** — which queries produced which numbers.

- **Show the numbers** — the underlying rows.
- **Show the SQL** — the exact query, runnable yourself.
- Charts are generated from the same data as the text.

### 🔴 What you must understand about this assistant

**It cannot invent a number.** Every figure is checked against the query results before you see it. If a number cannot be matched, the answer is **withheld entirely** rather than shown with a warning. You will occasionally see "the answer could not be verified" — that is the safety net working.

**It can still be wrong about *reasoning*.** The check verifies that numbers are real. It does not verify that the argument is sound. This is genuinely correct and completely useless:

> "Defect rate rose 42 % and Shift B ran 61 % of volume, therefore Shift B has a training problem."

Both numbers are real. The conclusion does not follow.

**Where to be careful:**

| Trust it for | Be careful with |
|---|---|
| Numbers, totals, rates, trends | Causes and explanations |
| "What happened" | "Why it happened" |
| Finding similar past cases | Deciding this case is the same |
| Drafting document structure | The technical content in that draft |
| Retrieving what a document says | Whether that document is still correct |

**When it says it doesn't know, believe it.** "Shift C data has not been uploaded" is an honest answer, not a failure. Re-asking a different way will not conjure the data.

**Never use it as the sole basis for:** stopping or restarting a line · scrapping product · a customer commitment · a safety decision.

Use it as a fast, tireless analyst who has read everything — and, like any analyst, whose conclusions you check before acting on them.

---

## A7 Discord

| Command | Does |
|---|---|
| `/brief [date] [lang]` | Post the production brief |
| `/ask <question>` | Same assistant as the web app |
| `/kpi <line> <period>` | Quick KPI figures |
| `/status` | Platform and edge fleet status |
| `/approve <id>` · `/deny <id>` | Decide a pending action |

Approval prompts always show the **exact action and its arguments** before you press Approve. If the message does not show what you are approving, do not approve it.

Your Discord account must be linked to your platform account. Being in the channel does not grant permission.

---

## A8 Mobile app

For inspection away from a fixed station.

1. **Scan** the part label — the checklist is selected automatically.
2. **Photograph** each step following the on-screen guide. Blurry photos are rejected before analysis.
3. **Review** what the app detected and confirm or change it.
4. **Finish** — a verdict is calculated from your step results.

**Working offline is normal.** Everything works in airplane mode. A badge shows how many records are waiting to sync; they upload automatically on Wi-Fi. Your recorded verdicts are never changed by the server.

If a session is interrupted, reopen the app — it resumes at the same step.

---

## A9 FAQ

**The screen says "Offline — buffering". Should I stop?**
No. Inspection continues and results upload later. Only ⛔ FAULT means stop.

**Why is the AI's answer different from my Excel sheet?**
Click **Show the SQL** and compare the filters. The usual causes are a different date range, a shift boundary, or REVIEW/NO_READ records being counted differently. If they still disagree, tell your engineer — one of the two is wrong and it matters which.

**Can I delete a wrong verdict?**
No. You can override it; both values are kept. That is what makes the record trustworthy.

**The defect rate shows "—".**
Nothing was produced in that period, so the rate is undefined.

**The AI refused to answer.**
It does that when the data is insufficient. It is a feature.

**Can I get the report in Japanese?**
Yes — choose the language when generating, or set it as your default.

**How long are images kept?**
Failed and reviewed parts: 2 years. Passed parts: 30 days (a sample is kept longer).

**Someone changed my verdict.**
Open the inspection and read the override history — who, when and why are all recorded.

---

# Part B — Administrator Guide

## B1 Users and roles

**Admin → Users.**

Assign the **lowest role that lets someone do their job**. Roles are cumulative; there is no way to grant one capability from a higher role without granting the rest.

| Role | Grant to |
|---|---|
| viewer | Anyone who needs visibility |
| inspector | Anyone who judges parts |
| engineer | Quality and process engineers |
| manager | Those who approve spend or actions |
| admin | **Two people. Not more.** |

**Line scope** restricts a user to specific lines. Leave it empty for unrestricted access. Scope is enforced in the query itself — a restricted user's request never retrieves other lines' rows.

**Non-negotiables:** MFA for every admin · at least two admins (never one) · remove access on the day someone leaves, not at the end of the month · never share accounts, because shared accounts destroy the audit trail's usefulness.

---

## B2 Master data

**Admin → Master data.** Lines, SKUs, machines, defect types, shift calendar.

**Defect types** need all three names (Thai, Japanese, English) — a missing translation appears as a blank label on a shop-floor screen. Mark a class `is_critical` when missing it is worse than a false alarm; this flag drives the ≥ 98 % recall gate on model promotion.

**Shift calendar** entries are versioned by date. When shift times change, add a new entry with a new `valid_from` — **do not edit the existing one**, or every historical report silently re-attributes its data.

---

## B3 Inspection recipes

**Admin → Recipes.** Per-SKU rules: which classes fail, thresholds, measurements, the review threshold.

Recipes are **versioned**. Editing creates a new version; inspections record which version judged them.

**Tuning the review threshold**

| Symptom | Change | Cost |
|---|---|---|
| Defects reaching the customer | **Lower** the threshold | More REVIEW load on inspectors |
| Inspectors overwhelmed with REVIEW | Raise it | Higher risk of escapes |

Decide this with the quality engineer using the model/human agreement report — not by feel. Change one SKU at a time and observe for a shift.

---

## B4 Alerts

**Admin → Alerts.**

| Alert | Set from |
|---|---|
| Defect rate threshold | Actual process capability, not a round number |
| Rate-of-change | Historical variation |
| Edge node offline | Leave at 3 missed heartbeats |
| Disk space | Leave at 85 % |

**The failure mode to avoid is alert fatigue.** An alert nobody acts on is worse than no alert — it teaches people to dismiss the channel. Review monthly: which alerts fired, which were acted on, which were ignored. Delete or retune the ignored ones.

---

## B5 Models

**Admin → Models.**

### Promotion
```
candidate → shadow (≥200 live frames) → review → promote → (rollback available)
```

Never promote straight from candidate. The shadow run reports how often the new model disagrees with the current one **on your actual line**, which is information no benchmark provides.

**Promotion is refused automatically if critical-defect recall falls below 98 %.** A model with better headline accuracy that misses more critical defects is a worse model for this purpose. Do not look for a way around this check.

### Drift alerts
A drift alert means the input images have changed — new lighting, a moved camera, a different material finish. Investigate the **physical cause first**. Retraining to fit a camera that has drifted out of position hides the problem instead of fixing it.

---

## B6 Edge fleet

**Admin → Edge nodes.**

| Column | Watch for |
|---|---|
| Heartbeat age | > 3 min = investigate |
| Buffer depth | Rising = sync problem (OPS RB-05) |
| App / model version | Drift across the fleet |
| Disk | Approaching the purge threshold |

Roll out updates **one node first**, soak for a shift, then the rest. A bad model or config pushed to every node at once takes out every line at once.

---

## B7 Prompts and glossary

### Prompt templates
Prompts live in version control, not in the database, and **cannot be edited through the application**. Changing one is a code change: reviewed, versioned and gated by the golden question set before release.

This is deliberate. Whoever can change the prompt can change what the AI says — it is as consequential as changing code, and it is protected the same way.

### Terminology glossary
**Admin → Glossary.** Japanese/Thai/English terms with mandated translations and forbidden alternatives.

Keep it current with your factory's own vocabulary (社内用語). It is what stops a translation being technically correct and locally meaningless. Terms require an approver, and that approver should be someone who actually speaks the language on the floor.

---

## B8 Audit

**Admin → Audit.** Filter by user, entity, date or correlation ID.

The audit log is **append-only** — nobody, including you, can alter or delete an entry. If it were editable it would not be evidence.

Recorded: verdict overrides · artifact approvals · ERP postings · configuration changes · model promotions · user and role changes · data exports · every AI call with its model, prompt version and tool calls.

**Monthly spot-check:** pick three consequential actions and confirm each traces to a named person with a sensible before/after. Export before any retention drop.

---

## B9 Scheduled jobs

**Admin → Jobs.**

| Job | Default | If it fails |
|---|---|---|
| `daily_brief` | 07:00 | Regenerate manually |
| `retention_sweep` | 02:00 | **Disk fills** — fix promptly |
| `partition_maintain` | Monthly | Inserts land in the default partition (OPS RB-13) |
| `drift_check` | Every 6 h | Drift goes unnoticed |
| `backup_full` | 01:00 | **Critical — fix same day** |

---

## B10 Health and escalation

**Admin → Health** shows service status, dependencies, edge fleet and job history.

> `/readyz` reporting **degraded** because the LLM is unavailable is not an outage. Dashboards, SPC and the review queue all work without it. Communicate it as "AI features unavailable", not "the system is down".

**Escalate to the operations runbooks** ([OPS §8](OPS-FactoryBrain-Deployment-Operations.md)) when:

| Symptom | Runbook |
|---|---|
| Service down | RB-01 |
| Disk filling | RB-02 |
| Slow AI answers | RB-03 |
| Node offline | RB-04 |
| Buffer growing | RB-05 |
| Ingest failures | RB-06 |
| ERP posting failures | RB-07 |
| Certificate expiring | RB-08 |
| **"Answer could not be verified" appearing repeatedly** | **RB-09 — treat as an integrity incident** |

The last one deserves emphasis. Occasional grounding failures are the safety net doing its job. A **rising rate** means the model is drifting toward fabrication and needs investigation the same day — it is not a performance nuisance to be tuned away.

---

## Glossary

| English | ไทย | 日本語 | Note |
|---|---|---|---|
| Defect rate | อัตราของเสีย | 不良率 | NG ÷ produced |
| Pass / Fail | ผ่าน / ไม่ผ่าน | 合格 / 不合格 | |
| Review | รอตรวจสอบ | 要確認 | Needs human judgement |
| No read | อ่านไม่ได้ | 読取不可 | Not judged — **not** a pass |
| Inspection | การตรวจสอบ | 検査 | |
| Control chart | แผนภูมิควบคุม | 管理図 | |
| Process capability | ความสามารถของกระบวนการ | 工程能力 | Cp / Cpk |
| Control limit | ขีดจำกัดควบคุม | 管理限界 | Not the spec limit |
| Specification limit | ขีดจำกัดข้อกำหนด | 規格限界 | USL / LSL |
| Root cause | สาเหตุที่แท้จริง | 真因 | Verified, not suspected |
| Corrective action | การแก้ไข | 是正処置 | |
| Preventive action | การป้องกัน | 予防処置 | |
| Horizontal deployment | การขยายผล | 水平展開 | Apply the fix elsewhere |
| Containment | การกักกัน | 歯止め | Stop the escape now |
| Material lot | ล็อตวัตถุดิบ | 材料ロット | |
| Shift | กะ | シフト | |
| Changeover | การเปลี่ยนรุ่น | 段取り替え | |
| Downtime | เวลาหยุดเครื่อง | 停止時間 | |
| Shop floor | หน้างาน | 現場 | Genba |
| Scratch | รอยขีดข่วน | キズ | |
| Dent | รอยบุบ | へこみ | |
| Missing component | ชิ้นส่วนขาด | 部品欠品 | |
| Short shot | ฉีดไม่เต็ม | ショートショット | Molding |
| Flash | ครีบ | バリ | Molding |
| Sink mark | รอยยุบ | ヒケ | Molding |
| Draft (unapproved) | ฉบับร่าง | 未承認 | AI output before approval |
| Approve | อนุมัติ | 承認 | |

---

## Appendix — One-page quick reference

**Operator** — PASS continue · FAIL route per instruction · **REVIEW set aside, don't guess** · NO READ re-present · Offline is fine, FAULT means stop.

**Inspector** — P/F/S keyboard · your verdict is final and recorded · give a reason code · report persistent model disagreement.

**Engineer** — check normality before quoting Cpk · hypotheses are not causes · read the numbers before approving a draft · "no significant improvement" means the fix did not work.

**Manager** — "significant" means it is probably not normal variation · correlation ≠ cause · never act on AI output alone for a line stop, scrap or customer commitment.

**Admin** — lowest role that works · two admins, both with MFA · one node first · never disable the grounding check · a rising "could not be verified" rate is an incident today.
