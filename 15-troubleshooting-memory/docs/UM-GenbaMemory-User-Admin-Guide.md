# User Manual and Administrator Guide — Genba Memory

| Field | Value |
|---|---|
| Document ID | UM-15-GenbaMemory |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-15](../SRS-GenbaMemory-Troubleshooting-RAG.md) · [API-15](../api/API-Specification.md) |
| Related | [OPS-15](OPS-GenbaMemory-Deployment-Operations.md) · [SEC-15](SEC-GenbaMemory-Security-Requirements.md) |

---

# Part A — Using it

## A.1 What this is, and what it is not

Genba Memory remembers factory problems. Every 8D, RCA note, maintenance log, handover note and complaint the plant has kept is in here, turned into a **case**: symptom → investigation → cause → action → outcome, with a link back to the document it came from.

It **does**: find past cases from a symptom, in Thai, Japanese or English; tell you what turned out to be the cause and whether the fix held; push precedent at you when a new case opens, so you do not have to remember to search; count which problems keep coming back.

It **does not**: decide what is wrong with your machine. It retrieves what happened before. The analysis is yours — or QE-Agent's (09).

Two words on every screen decide how much weight to give a case:

| Badge | Means |
|---|---|
| ✅ **verified** | a curator read the original document and confirmed this record |
| ⚠ **extracted, not human-verified** | a model wrote this from a document and nobody has checked it |

By default you only see ✅ cases. The ⚠ ones are there when you ask for them, and they are always marked. This is the whole discipline of the system: *a machine's reading of a document is not the same as a fact*.

## A.2 The technician — "has this happened before?"

Type the symptom the way you would say it. Add the machine if you know it.

```
Query (TH): "เครื่องจักร overload บ่อย มอเตอร์ไม่หมุน"
Scope: machine = M-07

3 similar cases found

① Case #418 · 2024-08-21 · M-07 · ✅ verified · similarity 0.87
   Symptom : Machine overload alarm, motor not rotating, intermittent
   Cause   : Proximity sensor abnormal (drifting output when hot)
   Action  : Replaced proximity sensor, added to 6-month PM list
   Outcome : Resolved — no recurrence for 14 months
   Source  : 8D_M07_2024-08.pdf (p.1–6) · matched on: symptom text, machine, alarm code

② Case #602 · 2025-06-03 · M-04 · ✅ verified · similarity 0.74
   Symptom : Overload trip after 2 h of continuous running
   Cause   : Coupling misalignment after mould change
   Action  : Realignment, added alignment check to the changeover checklist
   Outcome : Resolved — 1 recurrence in 2025-11 (checklist not followed)
   Source  : maintenance_log_2025-06.xlsx

③ Case #331 · 2023-12-11 · M-07 · ⚠ extracted, not human-verified · similarity 0.61
   Symptom : Motor stop, no alarm recorded
   Cause   : (not recorded)
   Action  : Reset and restart
   Outcome : Unknown — knowledge gap
   Source  : handover_note_2023-12-11.docx

⚠ Recurrence check: current symptom matches Case #418 (0.87) after 25 months.
  Suggested first inspection: proximity sensor condition and temperature drift.
```

Line by line:

| What you see | What it means |
|---|---|
| **3 similar cases found** | three passed the ranking and your access; if the system had removed something you may not see, it would say so as a number, never as a row |
| **① Case #418** | one real case with one real document. There is no "combined case" here — if two cases matter, you get two rows |
| **· M-07 ·** | the machine as the plant names it. `M07`, `เครื่อง 7` and `7号機` in the original all mapped to this |
| **✅ verified** | somebody read `8D_M07_2024-08.pdf` and confirmed the record |
| **similarity 0.87** | the final score. Press *why did this match?* to see the five parts of it |
| **Outcome: Resolved — no recurrence for 14 months** | the fix held. A case whose fix came back ranks lower, on purpose |
| **② M-04** | a different machine, and it still appears: you asked M-07 as a *scope*, not as a filter, so "the same thing on another machine" still reaches you (水平展開) |
| **1 recurrence in 2025-11 (checklist not followed)** | the honest ending. The action worked; following it did not always happen |
| **③ ⚠ / Cause: (not recorded)** | the note simply never said. The system will not guess one. This is a **knowledge gap**, and it is counted |
| **Recurrence check … after 25 months** | the elapsed time is computed from the two cases' dates, not typed by anyone |
| **Suggested first inspection** | quoted from #418's own action text. Nothing here is invented |

**One thing worth noticing about ①.** The Japanese 8D was the *worst* word-for-word match of the three for a Thai query — it shares almost no text with what you typed. It came first because the meaning matched, the machine matched, both symptoms matched, the fix held and a curator signed it. Press *why did this match?* and you will see exactly that.

### If you disagree with a result

- **helpful / not helpful** — one click; it feeds the monthly quality check, and it does *not* push the case up or down for the next person.
- **this is wrong** — pick the field that is wrong and say why. The field disappears from every screen immediately and goes to a curator. You are not deleting history; you are stopping a wrong line from being read as true.

## A.3 The quality engineer — precedent for an investigation

When you open a quality case, precedent arrives by itself within a few seconds (you do not have to search). Above the list you may see:

> ⚠ **Recurrence:** matches Case #418 (0.87) after 25 months — **not yet confirmed**

"Not yet confirmed" is the part to read. The system found a strong match; until you press **confirm** or **reject**, it counts in no report. Confirm it and the analytics learn that this machine's problem came back after two years; reject it and nothing is lost but the proposal.

For horizontal deployment (水平展開), search the symptom **without** a machine scope, or use *cases like this on other lines*. The ranking still favours the same machine, but it will not hide the others.

## A.4 The maintenance planner — what keeps coming back

*Analytics → Recurring problems* by machine, line, SKU or defect class:

- **n_cases** — how many cases named this machine.
- **n_recurrences** — how many *confirmed* repeats. This number is deliberately smaller than the number of proposals; nobody's report is inflated by a threshold.
- **Action effectiveness** — for one defect class, every corrective action ever recorded with a `recurred` flag next to it. This is the closest thing the plant has to "which fixes actually work".
- **MTBR** — mean months between confirmed recurrences.
- **Gaps** — cases closed without a cause or without a verification. This list is meant to get shorter.

## A.5 The new employee — learning from history

Browse by machine or by defect class instead of searching. Read the ✅ cases first; they were checked. A ⚠ case is still worth reading — it is what somebody wrote at the time — but treat its cause as a note, not as an answer.

If you find a case that helped and it was ⚠, tell a curator. Verification exists because someone reads the original; you are the person most likely to have just done that.

## A.6 What the system will never do

- It will never show a case without a document you can open.
- It will never merge two incidents into one summary and present it as an incident.
- It will never show you a record you are not allowed to see, and it will never let one influence a count or a chart you can see.
- It will never invent a cause. A blank cause means the document was blank.
- It will never follow an instruction found inside a document it ingested.

---

# Part B — Administering it

## B.1 Roles

| Role | Can |
|---|---|
| `viewer` | search, read, open originals, give feedback |
| `engineer` | the above, plus manual case entry, corrections, confirming or rejecting recurrences |
| `curator` | the above, plus verification, curation decisions, entity mapping, merges — and restricted records **if in the group** |
| `admin` | the above, plus sources, ACLs, evaluation, re-embedding and configuration |

Access to a restricted document is a *group*, separate from the role ladder. A curator who is not in the group still cannot see it.

## B.2 The curation queue, item by item

Oldest first. Five kinds, one question each:

| Kind | Ask yourself | Decide |
|---|---|---|
| Low confidence | is this what the document actually says? | verified · corrected · suppressed |
| Unmapped entity | which machine, line or SKU is this? | mapped · dismissed |
| Near-duplicate | one incident or two? | merged · distinct |
| Flagged field | who is right — the extractor or the person who flagged it? | corrected · verified · suppressed |
| Suspicious chunk | is this document hostile, or just oddly worded? | dismissed · restrict the document |

**Verifying a case means you read the original.** Not that it looks plausible. The system will refuse to verify a case that has no source document, and it will refuse while a field is flagged — both on purpose.

When a case's cause was never recorded: **leave it empty**. It becomes a counted knowledge gap that somebody may one day close from memory or from a better document. A plausible invented cause is the only error in this system that nothing downstream can detect.

## B.3 Manual case entry

Knowledge that lives in one person's head is the problem this product exists for. *Cases → New* records it: title, dates, scope, symptom, cause, action, outcome. Everything you type is marked as written by a human.

It still needs a source before it can be verified. Attach the photo, the note, the email — whatever you were reading from. If there is genuinely nothing, the case stays ⚠ and that is the honest state.

## B.4 Entity maps

`M07`, `M-07`, `เครื่อง 7` and `7号機` are one machine, and the system will not assume that on its own. Map it once, with your name on the mapping, and every affected case re-normalises. Export and import is CSV, so the list can live in a spreadsheet between edits.

An unmapped value never becomes a guess — it becomes a queue item.

## B.5 Sources and access

A source (a folder, a mailbox, a chat export, a ticket system) carries a **default ACL**, and everything it ingests inherits it. Setting it on the source is one edit; fixing four thousand documents later is not.

A source never holds a credential in its definition — only a reference to a secret file (OPS-15 §4). The API refuses anything else.

A case is as restricted as its **strictest** source. Attaching a confidential complaint to an open case restricts the case; that is intended.

## B.6 Evaluation

Monthly, automatically, and gated:

| Run | Passes at |
|---|---|
| Retrieval | Recall@5 ≥ 0.80 **and** MRR ≥ 0.60 |
| Extraction | ≥ 0.85 on symptom/cause/action, ≥ 0.95 on dates and entities |

You cannot mark a failing run as passed; the number decides. A failure means the candidate model or index is not promoted — nothing breaks, and the active one keeps serving.

Building the real sets is described in OPS-15 §8. The short version: sample across kinds, machines and years; label fields, not documents; write the queries the way people actually ask, a quarter of them cross-language; and version the set, because a metric from a different set is not a comparison.

## B.7 Re-embedding

A better embedding model arrives. Register it, start the re-embed, and keep working: search runs against the current version the whole time and switches in one step at the end. The old version cannot be retired while the job needs it.

## B.8 Settings that are not settings

Some configuration keys are locked. They are constraints, not preferences, and a deployment that wants them changed wants a different product:

verified-only retrieval by default · the ACL as a query predicate · local-only processing · a source link on every result · provenance on every extracted field · rerank depth 30 · embedding dimension 1024 · the four quality gates · no automatic near-duplicate merge · feedback not wired into ranking · the recurrence interval computed rather than entered.

## B.9 The dashboard to watch

| Number | What it tells you |
|---|---|
| Curation queue age | over 72 hours → stop the current ingestion wave |
| Coverage: with cause / with verification / human-verified | whether curation is keeping up with ingestion |
| Recall@5 trend | one bad month is noise; three is a problem |
| Search p95 | approaching 1 s → see OPS-15 RB-05 |
| ACL-filtered count rising | someone is searching for what they cannot see |
| Suspicious chunks | any rise deserves a look |

---

# Part C — Reference

## C.1 The case card, field by field

| Field | Written by | Notes |
|---|---|---|
| Title | extraction or a person | short, English |
| Opened / closed | extraction | copied from the document, never inferred |
| Scope | extraction + entity map | machine, line, SKU, mould — canonical codes |
| Symptom | extraction or a person | what was observed |
| Investigation | extraction | what was checked |
| Cause | extraction or a person | **blank means the document was blank** |
| Containment / corrective action | extraction or a person | what was done |
| Verification | extraction | the evidence it worked |
| Outcome | extraction | resolved · not resolved · unknown |
| Badge | the system | ✅ verified · ⚠ extracted, not human-verified |
| Sources | the system | at least one, always openable |

Every extracted field also carries a confidence and the page it came from. *Show details* on any field shows them, together with the model, prompt version and schema version that produced it.

## C.2 Why did this match?

| Component | Weight | Meaning |
|---|---|---|
| Similarity | 0.65 | how close the symptoms are, after reranking |
| Entity overlap | 0.10 | machine, line and the symptoms named in your query |
| Recency | 0.05 | 900-day half-life — a two-year-old fix is still worth reading |
| Outcome | 0.12 | a fix that held > a fix that came back > unresolved > unknown |
| Verified | 0.08 | a curator signed it |

They sum to 1.000, and the case card shows each one. For Case #418 above: 0.65 × 0.8342 + 0.10 × 1.000 + 0.05 × 0.556 + 0.12 × 1.000 + 0.08 × 1 = **0.870**.

## C.3 Screen labels

| English | ไทย | 日本語 |
|---|---|---|
| Search the memory | ค้นหาความจำโรงงาน | 現場メモリを検索 |
| Similar cases | เคสที่คล้ายกัน | 類似ケース |
| Symptom | อาการ | 不具合内容 |
| Cause | สาเหตุ | 原因 |
| Action | การแก้ไข | 是正処置 |
| Outcome | ผลลัพธ์ | 結果 |
| Verified | ตรวจสอบแล้ว | 確認済み |
| Extracted, not verified | สกัดโดยระบบ ยังไม่ตรวจสอบ | 抽出のみ・未確認 |
| Source document | เอกสารต้นฉบับ | 原本 |
| Why did this match? | ทำไมจึงตรงกัน | 一致理由 |
| Recurrence | การเกิดซ้ำ | 再発 |
| Confirm / Reject | ยืนยัน / ปฏิเสธ | 確認 / 却下 |
| Knowledge gap | ช่องว่างความรู้ | 知識の欠落 |
| This is wrong | ข้อมูลนี้ไม่ถูกต้อง | これは誤りです |
| Curation queue | คิวตรวจสอบ | キュレーション待ち |
| Horizontal deployment | การขยายผล | 水平展開 |

## C.4 What each error message means

| Message | What happened | What to do |
|---|---|---|
| `SOURCE_REQUIRED` | verifying a case with no document behind it | attach the source, then verify |
| `FLAGGED_FIELD_PRESENT` | a field is flagged as wrong | resolve it in the queue first |
| `VERIFY_NEEDS_CURATOR` | you are not a curator | ask one; this is not a permission to widen |
| `CONFIRM_NEEDS_ENGINEER` | a viewer tried to confirm a recurrence | an engineer who knows the machine confirms it |
| `ENTITY_NOT_MAPPED` | a raw value claimed to be canonical | map it first, with your name on the mapping |
| `EVAL_GATE` | a failing run was marked as passed | it cannot be; read the metrics |
| `VERSION_IN_USE` | retiring an embedding version a job still serves | wait for the job |
| `SOURCE_CREDENTIAL_INLINE` | a password typed into a source definition | put it in a secret file and reference it |
| `404` on a case you were told exists | either it does not exist, or you may not see it | the two look the same on purpose; ask someone with access |
