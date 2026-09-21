# User Manual and Administrator Guide — KaizenSwarm (Multi-Agent Factory System)

| Field | Value |
|---|---|
| Document ID | UM-13-KaizenSwarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-21 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-13](../SRS-KaizenSwarm-Multi-Agent-Factory.md) · [API-13](../api/API-Specification.md) · [OPS-13](OPS-KaizenSwarm-Deployment-Operations.md) |
| Audience | Part A — plant and production managers, shift leaders, quality and maintenance engineers · Part B — administrators · Part C — glossary TH/JA/EN |

---

# Part A — Using KaizenSwarm

## A.0 What it does — and what it never does

Twice a day (shift start), four specialist agents look at their own domain with the plant's own tools — **Quality** (SPC violations, defect-rate signals, open cases), **Maintenance** (health index, alerts, overdue PM), **Production** (plan vs actual, OEE, downtime, schedule risk), **Material** (stock coverage, deliveries, lots with history). Each reports *findings with evidence*, or says explicitly that nothing is significant. The **Manager** merges duplicates, relates findings on the same line, machine, SKU or lot into **compound risks**, ranks everything with a published formula, and writes the **shift briefing**: the top 3 risks, each with a score, evidence, a suggested owner and a recommended action.

| It does | It never does |
|---|---|
| ranks with `impact × likelihood × urgency × confidence` from tables you can read (A.4) | rank by "judgement" — the model only phrases |
| quotes numbers that a tool returned | invent a number — a briefing with an unknown number is refused by the system |
| tell you when a domain failed (`⚠ PARTIAL`) | hide a failed domain to look complete |
| recommend an action and a probable owner | act on a machine, a schedule or an order — people do |
| keep one finding per issue and count how often it recurs | flood you with the same issue twice |

## A.1 Roles
| Role | You can |
|---|---|
| Viewer (everyone on the floor) | read briefings and the blackboard for your lines |
| Shift leader | acknowledge, assign, snooze, dismiss findings (with a reason) |
| Engineer (quality, maintenance) | drill into evidence and traces; resolve; reopen |
| Plant / production manager | trigger a run, ask the Manager a question |
| Admin | Part B |

## A.2 Reading the briefing — line by line (SRS Appendix A)

```
🏭 Shift briefing — 2026-09-10 · Shift A · Plant 1
Data freshness: quality 5 min · maintenance 2 min · production 1 min · material 6 h ⚠
```
*When the data each agent used was last updated. ⚠ = older than an hour — treat that domain's item with care; the agent already lowered its confidence.*

```
1. [HIGH 0.84] Line 3 — compound risk: quality + maintenance
   Defect rate 5.82 % (+141 % vs 7-day, p<0.001) AND press M-07 bearing
   temperature +13.8 % over 5 days. Both concentrated on the same line/shift.
   → Inspect M-07 drive-side bearing today; hold RAD-500-A lot LOT-2609-114.
   Evidence: signal S-241 · alert 1184        Owner: Maintenance + QE
```
- **[HIGH 0.84]** — severity and score. A *compound* combines two findings from different agents on the same line; its score (0.84) is always at least the higher of its parts (quality 0.68, maintenance 0.50) — that is why it is on top although neither part alone would be.
- **The numbers** come from the tools (5.82 %, +141 %, +13.8 %). Every one of them exists in the findings; the system checked before sending.
- **→** the recommended action, **Owner** the suggested owner. Nothing has been ordered; it is your call.
- **Evidence** — click to open the signal in QE-Agent or the alert in MachineSense.

```
2. [HIGH 0.71] Material — coverage risk for SKU RAD-500-A
3. [MEDIUM 0.52] Production — OEE performance loss on Line 1
Nothing significant reported by: (none — all domains reported)
Partial: no. Run 411 · 2 min 14 s · 4 agents · 23 tool calls.
```
- **Nothing significant reported by** — domains that looked and found nothing. Not the same as a domain that failed.
- **Partial: no** — every agent reported. When it says `yes — maintenance (timeout after 60 s)`, machine health was **not assessed this run**; existing machine findings stay on the blackboard.
- **Run 411 …** — the run number to quote when you ask an engineer or admin about it.

## A.3 Working the blackboard (shift leader)

Open **Blackboard**. Each finding shows severity, score, how many times it was seen (`occurrences`), who reported it, and its status.

| Action | When | What happens |
|---|---|---|
| **Acknowledge** | you have seen it | status `acknowledged`; stops the "new" badge |
| **Assign** | you hand it to someone | owner set; status `in progress` |
| **Snooze until …** | you know, it can wait (a reason is required) | hidden from the top list until then; still counted |
| **Dismiss** with a reason: *false positive · duplicate · known · not actionable · not related (compound)* | the agent is wrong, or it is not a risk | status `dismissed`; the reason feeds the agent's precision score, so please be accurate |
| **Resolve** (engineer) | done | write what was done |
| **Reopen** | it came back or was dismissed by mistake | status `new` |

A finding **expires by itself** when every agent that reported it has since looked twice and not seen it — you will read "condition cleared" in its history. A timeout or a budget stop never clears anything.

## A.4 Why is it ranked there? (engineer, manager)
Open the item → **Explain**. You see the four factors and the tables:

| Factor | From | v1 table |
|---|---|---|
| impact | severity | INFO 0.2 · LOW 0.4 · MEDIUM 0.6 · HIGH 0.8 · CRITICAL 1.0 |
| likelihood | observed / trend / forecast / possible | 1.0 · 0.8 · 0.6 · 0.4 |
| urgency | this shift / today / within 3 days / this week / later | 1.0 · 0.9 · 0.8 · 0.6 · 0.4 |
| confidence | the agent's own, lowered for stale data | as reported |

Appendix A, maintenance: 0.8 × 1.0 × 0.8 × 0.78 = 0.4992 → shown as 0.50. Compound: 1 − (1 − 0.68)(1 − 0.4992) = 0.84. You can recompute any rank by hand; if you think the tables are wrong, tell an admin — they can be changed, but only after the scenario suite passes (B.4).

## A.5 Asking the Manager (manager)
**Ask** → "Is line 3 at risk this shift?" The Manager asks all four agents about line 3 only and answers with the ranked list for that scope, the same way a briefing is built. It cannot answer from memory or opinion; if a domain fails, the answer says so.

## A.6 Trace (engineer)
Open a run → **Trace**: every request, status, finding and error message in order; every tool call with its arguments and duration; the model calls with token counts; the GPU leases. This is what an audit sees too (export as JSON with a hash).

## A.7 Reading the numbers honestly
- A score is a **priority**, not a probability of failure.
- "Nothing significant" means the agent's thresholds were not crossed, not that all is well — see what it *checked* in the trace.
- A compound on a line can join two unrelated issues; dismiss it as *not related* if so — that improves the rules.
- Stale data (⚠) can hide a change that happened since; ask for an on-demand run if it matters.

---

# Part B — Administration

## B.1 Agents (registry)
**Admin → Agents.** Each agent: enabled, domains, tools, budget (tool calls / tokens / time), schedule, prompt version, circuit state, last outcomes, precision. Import `agents.yaml`; enable a new agent only after the scenario suite passes. The Manager cannot be disabled. Only *read* tools can be bound — the system refuses anything else.

## B.2 Budgets, timeouts, circuit
`kaizenswarm.yaml → orchestrator`. Defaults: 12 tool calls, 6,000 tokens, 60 s active time per agent; 3 min per run; one retry on malformed output (fixed); circuit opens after 3 failures for 15 min. An agent over budget is stopped and the briefing says so — raise a budget only if the trace shows real need, and only with the suite passing.

## B.3 Issue codes, dedupe, expiry
`blackboard` section: which scope fields identify an issue family (`machine.* → machine`, `lot.* → lot`, `sku.*/material.* → SKU`, others → line), the freshness threshold (60 min), expiry after 2 clean scheduled runs, maximum snooze.

## B.4 Scoring tables and relation rules — the gate
**Admin → Ranking.** Publish a new weights version or a rule (both inactive), **Run the suite**, activate when `passed`. The gate is fixed: ≥ 80 % of the 15+ scenarios must reproduce their expected top-3 and no phrased briefing may contain an invented number. Every change is logged with your name.

## B.5 Scenario suite
`scenarios/suite.yaml`: synthetic plant states with expected top risks; SC-15 in the example is a deliberate disagreement between an engineer and the tables — keep one or two such cases so the suite stays honest. Add a scenario for every new agent, rule or issue code.

## B.6 Prompts and the model
One shared model (≤ 9 B, temperature ≤ 0.3, one call at a time). Prompts are versioned files; a new version goes through the suite in full mode (nightly CI). Symptoms of a bad prompt: `template fallback` in briefings, claim-check failures, `invalid output` outcomes.

## B.7 Delivery
Discord channel per plant, languages (th/en/ja), CRITICAL pushed immediately; webhook allow-list (https only); the dashboard always. The bot posts stored briefings by id — it has no free-text commands.

## B.8 Users and scope
Platform users and roles; a user with a line scope sees only findings, compounds and briefing items for those lines, with a note that plant-level items are withheld.

## B.9 What to watch (weekly)
Partial-briefing rate, precision per agent (below 0.5 → review), budget stops, claim-check failures, lease waits. Runbooks in OPS-13 §11.

---

# Part C — Glossary

| EN | TH | JA | Meaning |
|---|---|---|---|
| specialist agent | เอเจนต์เฉพาะทาง | 専門エージェント | one domain, its tools, typed findings |
| Manager | ผู้จัดการ (เอเจนต์) | マネージャー | aggregates, relates, ranks, phrases — never invents |
| finding | ข้อค้นพบ | 所見 | an evidence-backed observation |
| evidence | หลักฐาน | 根拠 | a reference to a signal, alert, metric, PO, lot… |
| blackboard | กระดานข้อค้นพบ | ブラックボード | the shared store of findings with lifecycle |
| compound risk | ความเสี่ยงร่วม | 複合リスク | ≥ 2 findings from different domains on the same line / machine / SKU / lot |
| score | คะแนนความเสี่ยง | リスクスコア | impact × likelihood × urgency × confidence |
| briefing | สรุปความเสี่ยงต้นกะ | シフトブリーフィング | top-N risks at shift start |
| partial | บางส่วน | 部分結果 | a domain failed or timed out; the briefing says which |
| nothing significant | ไม่มีสิ่งผิดปกติ | 特記事項なし | an explicit "nothing crossed a threshold" |
| budget | งบประมาณ (การรัน) | バジェット | tool calls / tokens / time per agent per run |
| freshness | ความสดของข้อมูล | データ鮮度 | age of the newest data used |
| occurrence | ครั้งที่พบ | 検出回数 | one detection of an issue in one run |
| dismiss (false positive) | ปัดตก (ผลบวกลวง) | 却下（誤検知） | wrong finding — feeds precision |
| snooze | เลื่อนเตือน | スヌーズ | hide until a time |
| expire | หมดอายุ (อาการหาย) | 失効 | the condition cleared |
| run / trace | การรัน / ร่องรอย | 実行 / トレース | one orchestration and its full log |
| circuit breaker | เบรกเกอร์ | サーキットブレーカー | an agent paused after repeated failures |
| defect rate | อัตราของเสีย | 不良率 | |
| bearing | แบริ่ง | 軸受 | |
| micro-stop | หยุดสั้น | チョコ停 | |
| stock coverage | จำนวนวันที่สต็อกครอบคลุม | 在庫カバー日数 | |
