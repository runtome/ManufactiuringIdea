# User Manual and Administrator Guide — ShiftBrief (Production AI Analyst)

| Field | Value |
|---|---|
| Document ID | UM-02-ShiftBrief |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Audience | Part A — managers, supervisors, quality engineers, Japanese management · Part B — administrators and the file owner |

---

## Contents

**Part A — User Manual**
[A1 Getting started](#a1-getting-started) · [A2 Reading the daily brief](#a2-reading-the-daily-brief) · [A3 Production manager](#a3-production-manager) · [A4 Shift supervisor](#a4-shift-supervisor) · [A5 Quality engineer](#a5-quality-engineer) · [A6 Using the analyst (`/ask`)](#a6-using-the-analyst-ask) · [A7 Discord](#a7-discord) · [A8 FAQ](#a8-faq)

**Part B — Administrator Guide**
[B1 Users and roles](#b1-users-and-roles) · [B2 The daily file: sources and mappings](#b2-the-daily-file-sources-and-mappings) · [B3 Arrival expectations and alerts](#b3-arrival-expectations-and-alerts) · [B4 Subscriptions and delivery](#b4-subscriptions-and-delivery) · [B5 Facts, versions and regeneration](#b5-facts-versions-and-regeneration) · [B6 Text-to-SQL](#b6-text-to-sql) · [B7 Prompts and glossary](#b7-prompts-and-glossary) · [B8 Audit and jobs](#b8-audit-and-jobs) · [B9 Health and escalation](#b9-health-and-escalation)

[Glossary (TH/JA/EN)](#glossary)

---

# Part A — User Manual

## A1 Getting started

Open `https://shiftbrief.local` (or the FactoryBrain address in platform mode) and sign in. Choose your language (🌐 ไทย / 日本語 / English) — it applies to the dashboard, briefs and exports.

| Role | You can |
|---|---|
| Viewer | Read dashboards and briefs, ask questions |
| Engineer | Also: upload files, see quarantined rows, manage mappings and subscriptions |
| Manager | Also: deliver a brief now, approve agent actions |
| Admin | Everything, including enabling text-to-SQL |

If a line is missing from your view it is outside your scope — ask an administrator. A line-restricted user does not see the plant-wide brief (it contains other lines' figures).

---

## A2 Reading the daily brief

It arrives at 07:00 in Discord (and by email if subscribed) and is on the dashboard:

```
📅 Production Report — 2026-09-10
Production : 12,430 pcs
Defects    : 382 pcs
Defect rate: 3.07 %   (7-day avg 2.59 %, +18.4 %, p = 0.002 → significant)
Top defect : Missing Component — 41 %
Worst line : Line 3 — 5.82 % (n = 2,147)

AI analysis:
Line 3 shows abnormal defect growth during Shift B (8.82 % vs 2.80 % in Shift A);
Missing Component accounts for 63 % of Line 3 defects. Other lines are within normal variation.

Recommended action:
1. Check the component feeder on Line 3.
2. Review Shift B changeover records on Line 3.

Note: correlation only; root cause not verified.
Facts v1.0 · brief.v1.2 · qwen3:8b · [show the numbers]
```

### How to read the pieces

| Line | Meaning |
|---|---|
| **7-day avg 2.59 %** | The pooled rate over the previous 7 days (Σdefects ÷ Σproduced), excluding today |
| **+18.4 %** | Today's rate relative to that baseline |
| **p = 0.002 → significant** | A statistical test says this change is unlikely to be normal day-to-day variation. **When it is not significant, the brief says "within normal variation" and recommends nothing** — that is an answer, not a gap |
| **Worst line (n = 2,147)** | The sample size is always shown. A line with 12 parts is never called "worst", however bad its percentage looks |
| **correlation only** | The brief can see *what* and *where*. It cannot see *why* — it has no machine, material or operator data |
| **Facts v1.0 · [show the numbers]** | Every figure came from one stored "facts" record. Click to see it. If a number is not there, the brief could not have said it |
| **REVISED** | Appears when a corrected file arrived after the original brief. The text says what changed (e.g. "313 pcs, was 311"). The original is kept |

### What the brief cannot tell you
It validates that the file is **consistent** (NG ≤ produced, known lines, known codes). It cannot know whether the file is **true**. If someone types 35 instead of 95, the brief will faithfully report 35. The archived original and its hash exist so the discrepancy can be traced when it surfaces.

---

## A3 Production manager

**Home** shows today's KPI tiles, the 30-day trend with its baseline band, the defect Pareto, and a **line × shift heatmap** — the fastest way to see where a bad day happened.

Colour on the heatmap follows the **rate**, not the count. A cell with fewer than 100 parts is hatched: it is shown, never headlined.

**Reports → Export** gives PPTX or PDF (Thai, Japanese, English) built from the same facts record as the brief, with the facts version in the footer. A revised day carries a REVISED banner.

**When the brief is late**: the dashboard says *awaiting file* if the daily file has not arrived, or *AI narratives unavailable* if the model is down — in the second case all the numbers are still there, only the prose is missing.

---

## A4 Shift supervisor

**Dashboard → Shift** shows your shift's rate against the other shift and against your own last 7 days. `/kpi L3 shift-B 7d` in Discord gives the same.

If you receive a *revised* brief for a date you already acted on, read the delta line first; it tells you whether the change affects your shift.

---

## A5 Quality engineer

### Drill-down
**Quality → Pareto** by line, shift, SKU and period; **Trend** with 7- and 30-day baselines and pattern flags (consecutive rise, level shift, 3σ outlier); **Significance** for any date.

Baselines are pooled counts, not averaged percentages — so a low-volume Sunday does not distort the week.

### Quarantined rows
**Ingest → Batches** shows every file: how many rows loaded, how many were quarantined and **why, in plain language** ("row 181: NG Qty (48) exceeds Output Qty (40)"). Send these to the file owner; recurring reasons mean the source needs fixing, not the threshold.

A batch marked **rejected** means more than 5 % of rows were bad and **nothing from that file was loaded**. The day is absent, not partial.

### Requesting a mapping change
When the file layout changes, intake **holds** the batch and names the columns that differ. Ask an engineer/admin to create a new mapping version (B2); nothing is guessed.

### Hand-off in platform mode
A significant day also opens a quality signal for the QE-Agent, which can look at machine and material data ShiftBrief cannot see.

---

## A6 Using the analyst (`/ask`)

**Ask** in the sidebar or `/ask` in Discord.

| Instead of | Ask |
|---|---|
| "How are we doing?" | "Defect rate this week versus last week, by line?" |
| "Why so many defects?" | "Which line and shift had the highest defect rate yesterday, and what was the top defect there?" |
| "Is Line 3 getting worse?" | "Line 3 defect rate trend over 30 days" |

Every answer carries **sources** (which tool, which period) and **Show the numbers**.

### What you must understand about the analyst

**It cannot invent a number.** Every figure is checked against the query results before you see it. If one cannot be matched, the answer is **withheld** — you will occasionally see "could not be verified". That is the safety net working.

**It only has the daily file.** Production counts, defect counts, runtime. Ask about a machine parameter, a material lot certificate or an operator and it will say "outside my data". In platform mode it can hand such questions to the quality-engineering agent.

**"Within normal variation" is an answer.** Re-asking will not produce a cause where the statistics say there is only noise.

**It can still be wrong about reasoning.** "Shift B has 59 % of defects, therefore Shift B has a problem" is grounded and possibly wrong — if Shift B ran 60 % of the volume. The analyst is told to compare *rates*; you should read it that way.

**If it shows SQL**, an administrator has enabled the advanced query path. The SQL is shown so you (or an engineer) can check it. It can only read the same summary views the dashboard uses.

| Trust it for | Be careful with |
|---|---|
| Totals, rates, trends, shares, comparisons | Causes |
| Which line / shift / SKU / day | *Why* that line / shift / SKU / day |
| Whether a change is statistically significant | Whether it matters operationally |
| Drafting the report structure | The conclusion in the draft |

**Never use it as the sole basis for** stopping a line, a disciplinary conversation, a customer commitment, or a safety decision.

---

## A7 Discord

| Command | Does |
|---|---|
| `/brief [date] [line] [lang]` | Post the brief (latest revision) |
| `/ask <question>` | Same analyst as the web app |
| `/kpi <line> <period>` | Quick figures |
| `/status` | Which files have arrived today |
| `/subscribe <lang> [tone] [line]` | Subscribe this channel (managers) |

Your Discord account must be linked to your ShiftBrief account; being in the channel grants nothing.

---

## A8 FAQ

**No brief this morning.** Check `/status` — the file is probably late or rejected. The brief is generated as soon as a valid file lands.

**The brief says "REVISED".** A corrected file arrived. The delta line tells you what changed; the original brief is still in history.

**The numbers differ from my spreadsheet.** Click **Show the numbers** and compare the period and the baseline method (pooled, previous 7 days, excluding today). If they still differ, tell an engineer — one of the two is wrong and it matters which.

**Why "within normal variation" when the rate went up?** Because the change is within what the last 7 days would produce by chance. The number is still shown; only the story is withheld.

**The analyst refused my question.** It only has the daily file. That is a feature.

**Can I get the report in Japanese?** Yes — choose the language on export, or subscribe in Japanese.

**Can I edit a brief?** No. You can regenerate it (same facts, new wording) or, after a corrected file, a revision is created automatically. Nothing is edited in place.

---

# Part B — Administrator Guide

## B1 Users and roles
As FactoryBrain UM B1: lowest role that works; **two admins with MFA**; remove access the day someone leaves; no shared accounts. ShiftBrief specifics: `engineer`+ for mappings and uploads; **only `admin` can enable text-to-SQL**, and only after the procedure in B6.

## B2 The daily file: sources and mappings

**Admin → Sources.** A source is one file contract: where it comes from (folder, SFTP, upload, email), its pattern and encoding, and its **mapping** — the versioned YAML that says which column means what ([OPS §3.5](OPS-ShiftBrief-Deployment-Operations.md) walks through authoring one).

| Task | How |
|---|---|
| New file layout announced | Get a sample → **Validate** with a new mapping → read the dry-run (how many rows would quarantine, whether it would reject) → **Save** with a reason |
| Batch held for drift | Read the alert (which columns) → new mapping version → **Release** the held batch |
| Recurring quarantine reason | Fix the source or add the missing master data (line, SKU, defect code); do not raise the threshold |
| Column with a person's name or ID | Mark it `pii: pseudonymise` (or `drop`) — the raw value never enters the system |

Every mapping version is audited with the full YAML before and after, and your reason. Old versions are kept; each batch records the version used.

**Email intake:** populate the sender allow-list *before* enabling it. An empty list accepts nothing. Prefer a folder or SFTP for production.

## B3 Arrival expectations and alerts

**Admin → Sources → Expectation.** When the file is due, and the grace period. Past that, a `FILE_NOT_ARRIVED` alert fires and **no brief is generated from partial data**.

**Admin → Alerts** — thresholds:

| Alert | Set from | Not this |
|---|---|---|
| Defect rate | Process capability | A round number |
| Rate change | Historical variation | So low it fires weekly |
| Quarantine spike | Normal quarantine count × 5 | — |
| Withheld brief | Always on | Off |

Review monthly which alerts were acted on. An ignored alert teaches people to ignore the channel.

## B4 Subscriptions and delivery

**Admin → Subscriptions.** Channel (Discord/email), target, language, tone (short for chat, long with tables for email/PPTX), optional line. A plant-wide Discord subscription requires `admin`, because it exposes every line's figures to everyone in that channel. Email recipients must be on the allow-list.

Delivery happens at 07:00 from a brief generated at 06:45 (earlier on CPU if needed — see OPS §4.2). A **withheld** brief is never delivered by any channel.

## B5 Facts, versions and regeneration

**Admin → Facts.** Every date has a stored *facts* record (the numbers the brief was written from) with a version and a hash. It cannot be edited. It changes only when:

- a **corrected file** arrives → a superseding batch, a new facts version, a **revised** brief; or
- the **analytics code** changes → `FACTS_VERSION` is bumped by the developers, and regenerated dates get new rows under the new version. Old rows stay.

**Regenerate** recomputes and compares the hash. A mismatch (`FACTS_STALE`) means something changed that should not have — a warehouse row edited by hand, or code changed without a version bump. Escalate (OPS RB-13); do not force it.

## B6 Text-to-SQL

Off by default. It lets the analyst turn a question into a database query when the standard tools cannot answer. When on, the query is restricted to a whitelist of summary views, read-only, limited to 200 rows and 5 seconds, scoped to the user's lines, and **shown with the answer**.

Enable only after the procedure in [OPS §5.4](OPS-ShiftBrief-Deployment-Operations.md): accuracy gate (≥ 85 %), injection corpus (100 % rejected), then the audited toggle. Disable immediately if the audit log ever shows a query reaching something outside the whitelist.

## B7 Prompts and glossary
Prompt templates live in version control and cannot be edited in the application — whoever can change the prompt can change what the AI says. **Admin → Glossary** holds the Thai/Japanese/English terms the brief must use (defect names, line names, plant vocabulary); keep it current with your factory's own words.

## B8 Audit and jobs
**Admin → Audit** is append-only. Recorded: file uploads, batch dispositions, mapping versions (full YAML), expectation changes, subscriptions, every brief generation and delivery, every `/ask` run with its tool calls and SQL, config changes, the text-to-SQL toggle. **Admin → Jobs**: `intake_watch`, `file_expectation`, `facts_rebuild`, `daily_brief`, `retention_sweep`, `backup_full` (**critical**).

## B9 Health and escalation
**Admin → Health.** `degraded` because the LLM is down is **not an outage** — files load, facts compute, dashboards work; only briefs and `/ask` pause. Say "AI narratives unavailable", not "the system is down".

| Symptom | Runbook |
|---|---|
| File not arrived | RB-01 |
| Quarantine spike | RB-02 |
| Batch rejected | RB-03 |
| Mapping drift | RB-04 |
| Duplicate / corrected file | RB-05 |
| **"Could not be verified" briefs** | **RB-06 — integrity** |
| Discord not delivering | RB-07 |
| Brief late / LLM slow | RB-08 |
| Disk | RB-09 |
| Report rendering | RB-11 |
| Text-to-SQL rejections | RB-12 |
| **`FACTS_STALE`** | **RB-13 — integrity** |

---

## Glossary

| English | ไทย | 日本語 | Note |
|---|---|---|---|
| Production report / brief | รายงานการผลิต | 生産報告 | |
| Defect rate | อัตราของเสีย | 不良率 | NG ÷ produced |
| Baseline | ค่าฐาน | 基準値 | Pooled previous 7 days |
| Within normal variation | อยู่ในช่วงปกติ | 通常のばらつきの範囲内 | Not significant |
| Significant | มีนัยสำคัญ | 有意 | p < 0.05 |
| Top defect | ของเสียหลัก | 主要不良 | |
| Worst line | ไลน์ที่แย่ที่สุด | 最も悪いライン | Only among rankable groups |
| Sample size (n) | จำนวนตัวอย่าง | サンプル数 | |
| Shift | กะ | シフト | |
| Changeover | การเปลี่ยนรุ่น | 段取り替え | |
| Downtime | เวลาหยุดเครื่อง | 停止時間 | |
| OEE / availability / quality | ประสิทธิผลโดยรวม | 設備総合効率 | Performance omitted |
| Pareto | พาเรโต | パレート | |
| Quarantine (row) | แถวที่ถูกกัก | 隔離行 | Invalid row held with a reason |
| Rejected (batch) | ไฟล์ถูกปฏิเสธ | 却下 | > 5 % invalid; nothing loaded |
| Mapping | การจับคู่คอลัมน์ | 列マッピング | Which column means what |
| Drift | เค้าโครงไฟล์เปลี่ยน | レイアウト変更 | Header differs from mapping |
| Facts | ข้อมูลข้อเท็จจริง | ファクト | The stored numbers the brief is written from |
| Revised | ฉบับแก้ไข | 改訂版 | After a corrected file |
| Withheld | ถูกระงับ | 保留 | Could not be verified |
| Correlation | ความสัมพันธ์ | 相関 | Not cause |
| Root cause | สาเหตุที่แท้จริง | 真因 | Not something this tool determines |
| Missing component | ชิ้นส่วนขาด | 部品欠品 | |
| Missing fin | ฟินขาด | フィン欠品 | |
| Scratch / Dent / Leak | รอยขีดข่วน / รอยบุบ / รั่ว | キズ / へこみ / 漏れ | |

---

## Appendix — One-page quick reference

**Manager** — "significant" means probably not noise · "within normal variation" is the answer · n is always shown; small n is never "worst" · correlation ≠ cause · a REVISED brief tells you what changed · never act on a brief alone for a line stop, discipline, or a customer commitment.

**Supervisor** — compare rates, not counts · read the delta line on a revised brief first.

**Quality engineer** — quarantine reasons are written for the file owner; send them · a rejected batch loaded nothing · drift holds the batch until the mapping is updated · pooled baselines, not averaged percentages.

**Admin** — two admins with MFA · mark PII columns before the first file · allow-lists populated (empty denies) · never raise the 5 % threshold · text-to-SQL stays off until the procedure is done · `FACTS_STALE` and withheld briefs are incidents, not tuning problems.
