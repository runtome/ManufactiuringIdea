# User Manual & Administrator Guide — QE-Agent (AI Manufacturing Quality Engineer Agent)

| Field | Value |
|---|---|
| Document ID | UM-09-QEAgent |
| Version | 1.0 (Draft) |
| Date | 2026-09-15 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-09](../SRS-QE-Agent-Quality-Engineer.md) · [OPS-09](OPS-QEAgent-Deployment-Operations.md) · [SEC-09](SEC-QEAgent-Security-Requirements.md) §5.8 (roles) · [API-09](../api/API-Specification.md) · [ICD-09](ICD-QEAgent-Interface-Control.md) IF-50/IF-52 |
| Languages | This manual is in English; the product UI, exports and chart labels are in Thai, Japanese and English (NFR-09). Part C is the glossary. |

---

# Part A — User guide

## A.1 What QE-Agent does — and what it never does
QE-Agent does the routine analytical work of a quality engineer: it draws the control charts, flags rule violations, computes capability with its normality check, notices when a defect rate has changed and when, tests which lot / machine / mould / shift / operator group / parameter change goes with the change, finds similar past cases, and writes a **ranked list of hypotheses** — each with what supports it, what speaks against it, and how to verify it. From that it drafts the 5-Why, the 8D, FMEA row proposals and the 品質報告書.

It never:
- **states a cause.** Until *you* verify a hypothesis and record the result, every statement is "— hypothesis to verify" (C-04). The database refuses causal wording on anything else.
- **invents a number.** Every number in a draft comes from the engine and carries an evidence code `[E-nn]`; a sentence the engine cannot account for makes the draft *ungrounded* and it cannot be approved (AI-04, AC-05).
- **approves anything.** Ratings, hypotheses, artefacts and case closures are your actions, recorded under your name (NFR-05).
- **exports a draft as a fact.** Anything not approved leaves with `DRAFT — AI generated` on every page (C-01, AC-06).
- **quotes a Cpk without its context** — n, period, subgroup rule and the normality result travel with it; non-normal data gets a method note instead of a naive index (C-03).

## A.2 Roles
| Role | Can |
|---|---|
| Viewer (incl. customer-facing QA) | see charts, signals, cases and **approved** artefacts |
| Inspector (QC supervisor) | + drafts, evidence, hypotheses; triage signals; containment actions |
| Engineer (quality / production engineer, `quality_engineer`) | + run analysis, draft, edit, verify hypotheses, confirm S/O/D, approve, recalculate limits (with reason), declare trial runs, close own cases |
| Manager | + close any case |
| Admin | rules, ranking, FMEA standard and criteria, prompts, glossary, golden set, sources |

## A.3 Quality engineer — a case from signal to export
### A.3.1 The signal
The **Signals** board lists open signals by score. Open **S-241**:

```
Signal S-241 · Scratch defect  Line 4 · 0.52 % → 3.18 % (p < 0.001)
Change point estimated 2026-09-08 14:20 (±40 min)
```
- *0.52 % → 3.18 %* is the 30-day baseline against the current window; the **statistic panel** shows the counts behind it (80 of 15,400 vs 70 of 2,200), the test (two-proportion z with continuity correction, z 12.58) and the p-value. Both baselines (7 and 30 days) are shown.
- *Change point ±40 min* is where CUSUM and binary segmentation agree the series changed. The timeline below it lists what happened around that time (lot change 14:12, maintenance, parameter edits).
- **Suppressed** signals (too few parts, or a declared trial run) are listed under their own tab with the reason — nothing is silently dropped.

Triage: *Open case* (HIGH signals are opened for you and you are notified), *Dismiss* (reason required), *Watch*.

### A.3.2 Analyse
On the case, **Analyse** (≤ 20 s) runs the factor tests and produces the hypothesis list. Read it line by line:

```
1. Material lot change  — score 0.71
   Supporting : lot LOT-2609-114 started 14:12; defect rate on that lot 4.9 %
                vs 0.6 % on other lots in the same window (Fisher p < 0.001, n=1,880)
   Contra     : incoming inspection recorded no abnormality
   Verify     : re-inspect retained sample of LOT-2609-114 surface condition
```
- **Score** ranks hypotheses by the evidence (strength of association, timing relative to the change point, similar past cases); it is not a probability.
- **Supporting** lines are evidence rows: click one to see the query, the counts and the effect size with its confidence interval. The **Correlations** tab shows *every* factor tested, including the ones with no association (machine, operator group, ambient temperature, parameter change), with the Benjamini–Hochberg-adjusted p-values and the warning that seven factors were tested.
- **Contra** is mandatory: the engine always looks for what speaks against a hypothesis. A hypothesis without contra evidence does not exist.
- **Verify** is the step you (or production) perform. When you have the result, **Verify hypothesis** → confirmed / rejected + note. Only then does the wording change from "hypothesis to verify" to "cause".
- **Similar cases** (#212, #178) come from the plant's own past 8Ds with their outcome; open one to read the original.

### A.3.3 Draft
**Draft → 8D / 5-Why / FMEA rows / Report (TH/JA/EN)**. The draft appears in ≤ 90 s with:
- `DRAFT — AI generated` banner;
- every number followed by `[E-nn]` — hover to see the evidence;
- a **grounding status**: *passed* (every numeric and causal sentence traced) or *failed* with the offending sentences highlighted. A failed draft can be edited but not approved;
- for Japanese: the **term check** list (e.g. 修正措置 → 是正処置).

If the model is unavailable you still get the analysis, hypotheses and evidence; the *Draft* button says "statistics-only mode" (AC-09).

### A.3.4 Edit
Edit in the editor; each save is a **revision** with a diff against the AI version (FR-24). Claims are re-extracted on every save, so a number you type by hand that the engine did not compute turns the grounding status to *failed* — add it as evidence (ask the engine for the query) or remove it.

### A.3.5 FMEA rows
Proposed rows show S, O and D **with the criteria row each rating references** (e.g. "O = 4: 0.5 per 1000") and a justification. Confirm each rating (or change it to another criteria row) — the FMEA row is created only when all three are confirmed (AI-07); RPN / AP is computed by the system from the confirmed ratings, never typed.

### A.3.6 Approve
**Approve** checks: your role, grounding *passed*, no open term violations. Approval is recorded once, with your name and the content digest; it cannot be edited or repeated — a later change creates a new version that needs its own approval (NFR-05, NFR-06).

### A.3.7 Export
**Export → DOCX / XLSX / PDF**. Approved artefacts carry `v1.2 · approved by <name> · <date>` in the footer; unapproved ones carry the diagonal `DRAFT — AI generated` on every page. Capability figures print their n, period and normality note. Download links expire after 15 minutes.

### A.3.8 Actions, effectiveness, closure
Add actions (containment, corrective, preventive, horizontal) with owners and due dates. After a corrective action has run long enough (≥ 500 parts), **Verify effectiveness**: the system compares the rate before and after with the same two-proportion test and records *improved* (action → verified) or *no significant improvement* (action stays *done*; the report says so — AC-08). Close the case when every action is verified or cancelled and you have written the closure note; the case is indexed as a past case and **horizontal deployment candidates** (same characteristic on other lines/SKUs/moulds) are proposed.

## A.4 QC supervisor
- 06:00 digest: open signals by score, suppressed signals with reasons, yesterday's closures.
- **Containment**: add a containment action on the case; it counts toward closure.
- **Trial runs**: when a trial is planned on a line, declare it (reason, window) so its signals are suppressed and labelled — and expire it when done.

## A.5 Production engineer
- **Correlations** tab: parameter edits and machine alarms on the timeline relative to the change point; the *parameter_change* factor test with its effect size.
- Record the verification result of a hypothesis you tested on the floor (e.g. mould cavity inspection) — the case owner sees it immediately.

## A.6 Japanese management — 品質報告書
The report has the standard sections in order: **現象・原因・対策・効果確認・水平展開**. In 原因, unverified items are written 「…の可能性（要検証）」 with the verification method; confirmed items are stated as causes with their evidence codes. 効果確認 states the before/after rates and the test result, or that verification is pending. Terms follow the company glossary (Part C). A report is exported for management only after a Japanese-speaking engineer or manager has approved it (AC-07).

## A.7 Customer-facing QA
You see approved 8Ds only. The evidence codes are retained in the export (appendix) so a customer's question "where does 4.9 % come from?" is answered by the query behind `E-04`. A draft you receive with the watermark is not yet the company's position — ask the case owner for the approved version.

## A.8 Reading capability
| Field | Meaning |
|---|---|
| n / period / subgroup | how many measurements, over what period, grouped how — printed with every index |
| Normality (Anderson–Darling) | *ok* → Cp/Cpk/Pp/Ppk shown; *failed* → warning, recommended method (Box-Cox, Johnson, percentile Ppk) and only the method's result |
| Cp vs Pp | within-subgroup vs overall variation; a large gap means between-subgroup shifts |
| Provisional | limits or indices from fewer than 25 subgroups / 100 measurements |

---

# Part B — Administrator guide

## B.1 Characteristics and limits
Create characteristics with chart type, USL/LSL, subgroup rule and unit; calculate limits from an agreed baseline (**reason required**); the limit history is visible on the chart and cannot be deleted (RB-04). Rules default to {1, 2, 3, 5, 6}; add 4/7/8 per characteristic; the minimum set cannot be removed.

## B.2 Sources and defect codes
Connect the five sources with read-only accounts (OPS-09 §6); map every defect code in `core.defect_type` (unmapped codes appear on the data-quality panel and are excluded from analysis until mapped).

## B.3 Signals
`min_sample` (default 50, never below 30), baselines (7/30 days), ranking weights (sum to 1) and per-defect criticality, auto-case severities, quiet hours (CRITICAL always delivered).

## B.4 FMEA standard and criteria
Choose AIAG-VDA AP or classic RPN; load the S/O/D criteria table (30 rows); the AP table for AIAG-VDA. Changing the standard does not alter existing FMEA rows; new proposals use the new tables.

## B.5 Prompts, model, facts schema, golden set
Prompt templates live in git (`deploy/prompts/<kind>.<lang>.<vN>.md`) and are registered with their checksum; the model is ≤ 9 B at temperature ≤ 0.3. **Any change** to a prompt, the model, the ranking weights or the facts schema runs the golden set (≥ 20 incidents): ≥ 60 % true cause in top-3 and **zero fabricated evidence**, else the change is blocked (AI-05, RB-08). Golden incidents are appended with a reviewer; they are never edited.

## B.6 Glossary
`glossary.csv`: `domain, ja, ja_reading, th, en, forbidden` (`|`-separated forbidden variants). Load with `qectl glossary load`; the loader refuses a forbidden variant that is a substring of a mandated term. The term check runs on every JA/TH draft and revision.

## B.7 Templates and exports
Company DOCX/XLSX templates per artefact kind × language under `templates/`; `qectl templates check` renders the seed artefacts and verifies the DRAFT watermark on every page. Exports are immutable objects kept 10 years.

## B.8 Users and roles
Platform accounts; `quality_engineer` maps to *engineer*. Line scope limits what a user sees and what the Copilot tools return in platform mode.

## B.9 What to watch
OPS-09 §9: source lag, chart/analysis/draft latency, LLM availability, grounding failures, untraced-claim ratio, suppressed-signal share, overdue actions, golden status, and — above all — `qe_export_watermark_mismatch_total`, which must stay at zero.

---

# Part C — Glossary (TH / JA / EN)
| EN | JA | TH | Meaning here |
|---|---|---|---|
| defect rate | 不良率 | อัตราของเสีย | defects ÷ inspected, per window |
| control limit | 管理限界 | ขีดจำกัดควบคุม | UCL/LCL from the baseline (never a spec limit) |
| process capability | 工程能力 | ความสามารถของกระบวนการ | Cp/Cpk/Pp/Ppk with n, period, normality |
| signal | シグナル / 異常兆候 | สัญญาณ | a statistically significant change vs baseline |
| change point | 変化点 | จุดเปลี่ยน | estimated time the series changed |
| hypothesis to verify | 要検証の仮説 | สมมติฐานที่ต้องตรวจสอบ | any cause not yet verified by a person |
| evidence | 根拠 | หลักฐาน | an engine result with an `E-nn` code |
| phenomenon | 現象 | ปรากฏการณ์ | what was observed (report section 1) |
| cause | 原因 | สาเหตุ | verified cause (report section 2) |
| countermeasure | 対策 | มาตรการ | corrective / preventive action (section 3) |
| effectiveness verification | 効果確認 | การยืนยันผล | before/after test result (section 4) |
| horizontal deployment | 水平展開 | การขยายผล | applying the countermeasure to similar lines/SKUs/moulds (section 5) |
| containment action | 暫定処置 | มาตรการชั่วคราว | D3 |
| corrective action | 是正処置 | การแก้ไข | D5 (not 修正措置) |
| recurrence prevention | 再発防止 | การป้องกันการเกิดซ้ำ | D7 |
| trial run | 試作 / 条件出し | การทดลองผลิต | declared window whose signals are suppressed |
| DRAFT — AI generated | 下書き（AI 生成） | ร่าง (สร้างโดย AI) | the watermark on every unapproved export |
