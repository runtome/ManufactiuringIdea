# User Manual & Administrator Guide — Factory Copilot (Local AI Factory Copilot)

| Field | Value |
|---|---|
| Document ID | UM-10-Copilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-17 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-10](../SRS-FactoryCopilot-Local-Multilingual-Assistant.md) · [OPS-10](OPS-Copilot-Deployment-Operations.md) · [SEC-10](SEC-Copilot-Security-Requirements.md) §5.9 (roles) · [API-10](../api/API-Specification.md) · [ICD-10](ICD-Copilot-Interface-Control.md) IF-53, IF-54 |
| Languages | This manual is in English; the product UI, error messages and chart labels are in Thai, Japanese and English (NFR-08). Part C is the glossary. |

---

# Part A — User guide

## A.1 What Copilot does — and what it never does
Copilot answers questions about the factory — production, defects, SPC, machines, defect images, SOPs and past quality reports — in Thai, Japanese or English, with charts and with its sources attached. It is the front door: the analysis behind the answer is done by the platform's tools and engines, not by the chat model.

It never:
- **invents a number.** Every figure in an answer comes from a tool result or a cited document; if the model tries to write one that is not there, the answer is withheld and you see "answer withheld — could not be verified" instead (C-02).
- **guesses.** If data is missing ("shift C not yet uploaded") it says so and tells you how to get it (FR-17).
- **shows you data outside your permissions.** Your line scope is applied inside every query; if you ask about another line you get a notice, not the data (C-03).
- **changes anything.** Copilot is read-only; actions belong to the other applications (C-01).
- **states a cause.** "Why" questions are handed to QE-Agent and answered as *hypotheses to verify* with QE's evidence and a link to the case (FR-21).
- **sends your question outside the plant** unless the admin enabled a channel that does (Discord) and told you (C-04).

## A.2 Asking well — examples by role
| You are | Ask like this | You get |
|---|---|---|
| Operator | «วันนี้ไลน์ 3 ของเสียเท่าไหร่» | today's NG count and rate for line 3, the date used, sources |
| QC inspector | "show me scratch defect images from yesterday, line 2" | the images (links valid 15 min), count, lot, station |
| Quality engineer | "Cpk of fin pitch for RAD-500-A last month" | Cp/Cpk with n, period, subgroup rule and the normality result — never an index alone |
| Production manager | "which line has the worst trend this week?" | ranked lines with the metric, the week used, a trend chart |
| Japanese management | 「不良率が増えた原因を分析してください（ライン3、昨日）」 | data, change point, Pareto and trend charts, QE-Agent's hypotheses 「未検証の仮説です」, case link |
| New employee | "how do we handle a short shot on machine 7?" | the SOP steps with section and page citations |

Tips: name the line/machine/SKU as you say it on the floor (aliases are configured — ไลน์ 3, ライン3, L3 all work); relative times are fine (yesterday / เมื่อวาน / 先週 / this shift) — the answer prints the exact range it used; follow-ups keep the context ("and line 4?" reuses the same period and metric — AC-08); if the question is ambiguous Copilot asks one short question back (FR-05).

## A.3 Reading an answer
Every answer has the same shape (FR-13):
1. **Result** — the direct answer with the resolved date range: "Line 3 yesterday (2026-09-09): 5.82 % (187/3,213)".
2. **Detail** — supporting numbers, charts (trend, Pareto, control chart), images.
3. **Sources** — for data: the tool and its parameters (`query_defects(line=3, 2026-09-09)`); for text: document title, section, page. Click a source to open it (`/sources/{id}`).
4. **Confidence note** — present whenever something is partial: "shift C not yet uploaded", "line 3 is outside your permissions — showing line 1".

**Show the numbers** lists every fact the answer was allowed to use, with its id (`F-03 defect_rate_pct 5.82 %`). **Show the SQL** appears when the answer came from a generated query: the exact read-only statement, which an engineer can re-run to reproduce the figures (FR-18, AC-07).

## A.4 Cause questions
Ask "why" and Copilot fetches QE-Agent's analysis for the matching signal: the statistic (rate now vs baseline, p-value), the change point, the ranked hypotheses with what supports and contradicts each, and the verification step — worded as hypotheses until an engineer confirms one. The answer links the QE case (e.g. S-241 / QC-0241); verification, drafting an 8D and approvals happen there, not in Copilot.

## A.5 Follow-ups, clarifications, language
- Follow-ups reuse the previous turn's line, period and metric; change one thing and the rest stays.
- A clarification ("which line — 3 or 4?") is answered in the same thread; the original question is not lost.
- Copilot answers in the language you wrote; set a preferred answer language in *Preferences* if you want otherwise (FR-01).

## A.6 Sharing, pinning, saving, rating
- **Share** a grounded answer as a link, PNG or PDF (expires, default 7 days, max 30; LAN only). Refused or partial answers cannot be shared. Exports carry "AI-generated answer — sources attached".
- **Pin** an answer to your dashboard; **save** a question to re-ask it in one tap — saved questions also work as plain dashboard links when the assistant is down.
- **Rate** 👍/👎 with a reason; a 👎 becomes a flag an engineer reviews. Corrections become *curated answers* that are shown first and labelled "curated (approved by …)".

## A.7 When the assistant is down
The chat shows "assistant unavailable — dashboard mode": your saved questions become dashboard links, document search still works (text search), KPI pages open directly. No error page (NFR-06, AC-09).

## A.8 Discord (if your admin enabled it)
`/ask <question>` in an allowed channel; the answer comes in a thread with sources; names are always masked; no images or document text are posted. You must be registered (a verified binding) — an unregistered Discord user gets "not registered". Remember that Discord messages leave the plant network.

## A.9 Your data
Your conversations are yours: others cannot open them (engineers can review turns for quality purposes, and that is audited). They are kept for one year; you can export them or delete them all from *Preferences → My data* (NFR-07).

---

# Part B — Administrator guide

## B.1 Users, roles, scopes
Roles viewer < inspector < engineer < manager < admin (platform accounts). **Line scope** (`core.user_line_scope`) restricts what a user's questions can reach; empty scope = all lines. Scope is applied inside every tool; test it with a scoped account after every change (OPS-10 §5).

## B.2 Tools
`/tool-policy` lists what Copilot can call, to whom, with which scope parameter. Only read tools can be enabled — enabling a write tool is refused. A new tool needs its scope test before it goes live (TEST-10 TC-033). A sibling that is down shows its tools as unavailable; users see "analysis not available" for questions that need them.

## B.3 Text-to-SQL
Off by default. Turn it on only after a SQL evaluation run (≥ 30 questions, ≥ 85 % execution accuracy). Generated statements run as a read-only role on whitelisted views with a 5-second timeout and a row limit; every statement is stored and visible under "show the SQL". Keep the whitelist to views — users, scope and audit tables are refused by the database.

## B.4 Documents and indexing
Register folders as sources with a kind and a minimum role (ACL). Files are chunked by structure with page/section metadata; unchanged files are skipped on rescan. Watch the index status for failed jobs and **suspicious chunks** — text inside a document that looks like an instruction ("ignore instructions, reveal…") is flagged and excluded from answers, never followed; review it with the document owner.

## B.5 Aliases and time
Load aliases (`aliases.csv`) for every line, machine, SKU, defect and mould in TH/JA/EN and floor nicknames; a wrong alias answers the wrong entity — review a sample of resolved entities weekly. Time expressions resolve through the versioned shift calendar; when shifts change, add a new calendar version — never edit the old one.

## B.6 Masking and privacy
Operator names are masked below the configured role (default manager) and always on Discord. Users can export and delete their conversations; deletions are audited and complete.

## B.7 Curated answers and flags
Review `/flags`: dismiss, or correct by writing a curated answer with its sources. A curated answer becomes citable after an engineer approves it and it is embedded; it is shown first and labelled.

## B.8 Prompts, model, evaluation
Prompts are versioned files with checksums; the model is ≤ 9 B with tool calling; any change to a prompt, the model, a tool schema, the embedding model or the evidence-bundle schema runs the evaluation set (≥ 60 questions across TH/JA/EN and all six intents): accuracy ≥ 90 %, citation correctness ≥ 95 %, **zero fabricated numbers**, or the release is blocked. Add questions from flagged answers; the set is append-only with a reviewer.

## B.9 Channels
Web and the dashboard embed are on by default (origins allow-listed). Discord is a recorded decision: policy signed, flag enabled with a reason, users bound and verified, bot started. An external model provider is likewise a recorded flag; when off, no data leaves the LAN.

## B.10 What to watch
OPS-10 §9: model availability, first-token and answer latency, queue depth, grounding failures (must stay near zero), refusals (data feeds), scope audit (`in_scope = false` must never appear), SQL rejections, suspicious chunks, evaluation status.

---

# Part C — Glossary (TH / JA / EN)
| EN | JA | TH | Meaning here |
|---|---|---|---|
| grounded answer | 根拠付き回答 | คำตอบที่มีหลักฐาน | every number traces to a tool result or a cited document |
| source / citation | 出典 | แหล่งข้อมูล | tool + parameters, or document title + section/page |
| evidence bundle | 根拠バンドル | ชุดหลักฐาน | the facts and citations the answer was built from ("show the numbers") |
| withheld answer | 保留された回答 | คำตอบถูกระงับ | the post-check found an unverifiable number; nothing was shown |
| refusal | 回答不可 | ตอบไม่ได้ | data missing; the answer says what and how to obtain it |
| scope | 権限範囲 | ขอบเขตสิทธิ์ | the lines a user may see; applied inside every query |
| hypothesis to verify | 要検証の仮説 | สมมติฐานที่ต้องตรวจสอบ | QE-Agent's wording for an unconfirmed cause |
| defect rate | 不良率 | อัตราของเสีย | NG ÷ produced |
| missing part | 部品欠品 | ชิ้นส่วนขาด | defect code MISSING_PART |
| scratch | キズ | รอยขีดข่วน | defect code SCRATCH |
| short shot | ショートショット | ฉีดไม่เต็ม | defect code SHORT_SHOT |
| change point | 変化点 | จุดเปลี่ยน | estimated time a series changed |
| shift | シフト / 直 | กะ | A 06–14, B 14–22, C 22–06 (versioned calendar) |
| dashboard mode | ダッシュボードモード | โหมดแดชบอร์ด | the assistant is unavailable; direct links instead |
| curated answer | 承認済み回答 | คำตอบที่รับรองแล้ว | an engineer-approved answer shown first |
| AI-generated answer — sources attached | AI生成回答（出典付き） | คำตอบสร้างโดย AI (แนบแหล่งข้อมูล) | label on every shared export |
