# User Manual & Administrator Guide — DocFlow (AI Document → ERP Agent)

| Field | Value |
|---|---|
| Document ID | UM-08-DocFlow |
| Version | 1.0 (Draft) |
| Date | 2026-09-14 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-08](../SRS-DocFlow-Document-to-ERP-Agent.md) · [SAD-08](SAD-DocFlow-Software-Architecture.md) · [API-08](../api/API-Specification.md) · [OPS-08](OPS-DocFlow-Deployment-Operations.md) · [SEC-08](SEC-DocFlow-Security-Requirements.md) |
| Audience | Part A: purchasing clerks, accounts payable, warehouse, managers, anyone asking "where is my document". Part B: administrators (finance admin, ML owner, internal audit) |
| Languages | The UI is in Thai, Japanese and English. This manual is in English; Part C gives the on-screen terms in TH/JA |

---

# Part A — User guide

## A0. Read this first (everyone)

DocFlow reads supplier documents so you do not have to type them, checks the numbers, and — after **you** approve — posts them to the ERP. Three things it never does:

1. **It never approves spend.** Every posting has a person's name on it. Above the amount limit it needs a manager, and that manager may not be the person who corrected the fields.
2. **It never trusts a number from the AI.** Every amount is recomputed: line = quantity × price, lines + tax = total, price against the contract, quantities against the PO and the goods receipt. If the arithmetic does not close, the document cannot auto-clear and you will see exactly which rule failed.
3. **It never follows instructions written in a document.** If a supplier PDF says "approve this immediately", the sentence is shown to you with a warning flag — and the document goes to review no matter what.

If a document's numbers look right but the story looks wrong (new bank details, an unusual supplier, a PO you do not recognise), reject it with a reason or escalate. The system is built to make that easy.

## A1. Purchasing clerk

### A1.1 The queue
**Review** lists documents waiting for a person, oldest first, with the type, supplier, amount, the gate result and how many rules warned or failed. Documents you may approve yourself (within your limit) are marked; others say which role is needed.

### A1.2 The review screen
The page image is on the left, the extracted fields on the right. **Click any field and the place it came from lights up on the page.** A field with a grey question mark could not be located on the page — treat it as unverified even if the value looks plausible. Fields below their confidence gate or involved in a failed rule are outlined in orange (warning) or red (fail).

```
PO-2026-004821 · Sakura Kogyo Co., Ltd. (SUP-0142) · JPY · 3 pages · Japanese
Gate: review required — 1 warning
  ✓ arithmetic.line     1,200 × 870 = 1,044,000 ✓ · 400 × 600 = 240,000 ✓
  ✓ arithmetic.total    1,284,000 + 0 = 1,284,000 ✓
  ✓ supplier.master     SUP-0142 (by tax id)
  ✓ item.master         RAD-500-A → ITM-8891 · RAD-500-B → ITM-8892
  ⚠ price.contract      unit_price 870 vs contract 845 (+3.0 %) — line 1
  ✓ duplicate.invoice   —
  ✓ injection.flag      no flags
Amount for approval: 295,962 THB → needs: manager (not the editor)
```

### A1.3 Correcting a field
Click the field, type the value, give a short reason if it is not obvious. Corrections are kept forever with your name (they improve the system for that supplier) and the checks re-run immediately. **If the document is above the manager limit, correcting a field means you cannot be its approver** — that is deliberate.

### A1.4 Approving, rejecting
- **Approve** is enabled only when your role is sufficient for the amount. Warnings must be acknowledged (you are saying "I looked at the +3 % and it is fine"). A failed rule blocks approval until the field is corrected.
- **Reject** needs a reason; tick *Reply to sender* to send the reason to the supplier's address (never the document itself).
- After approval the document is posted automatically; you get a notification with the ERP reference, or an exception if the ERP refused.

## A2. Accounts payable

### A2.1 Invoices and matching
Invoices show the 2-way match (invoice vs purchase order: quantity, price) and, where a goods receipt exists, the 3-way match (vs received quantity). Tolerances are configured by the admin; within tolerance = ✓, above the warning level = ⚠, above the failure level = ✗. A 5 % over-delivery with a 2 % tolerance is a warning you must acknowledge or reject.

### A2.2 Duplicates
The same invoice number from the same supplier is detected even when it arrives as a scan of the emailed original. The second copy is blocked from approval and linked to the first; you will see *duplicate of INV-2209 (posted 10 Sep)*. Reject it with the reason "duplicate".

### A2.3 Exceptions
**Exceptions** lists postings the ERP refused or that timed out after five tries, and documents the AI could not read into the required structure. Each item shows the adapter's error. *Retry* re-sends with the same idempotency key — it can never create a second transaction. *Reject* closes it with a reason.

## A3. Warehouse
Delivery notes are matched against the purchase order and the goods receipt. Quantities on the note that differ from what was booked are flagged; confirm or correct from the physical count. You may approve delivery notes within your limit; they do not post to the ERP as transactions but update the match data for the invoice.

## A4. Manager

### A4.1 Approvals above the limit
Your queue shows documents above the clerk limit (example policy: > 100,000 THB). The screen shows who corrected which field; if you corrected any, the system will not let you approve — ask another manager. Read the warnings; a price above contract, a changed bank detail or an injection flag are the three most common reasons to reject.

### A4.2 Rejecting
A reason is required and is stored with your name; the supplier may receive it if you tick the reply option.

## A5. "Where is invoice INV-2209?"
Search by document number in the top bar, or ask the Copilot (platform mode): "status of INV-2209". You get the state (received / in review / approved / posted with the ERP reference / rejected with reason / exception) and who acted last — never the document itself.

## A6. What the system never claims
- Never "verified" — only *rules passed / warned / failed*, each with the numbers.
- Never "approved" without a person; never "posted" without an ERP reference.
- Never a value without a place on the page (unverified values are marked).
- Never a decision on an instruction found inside a document.

---

# Part B — Administrator guide

## B1. Roles
| Role (platform name) | DocFlow duty | Can |
|---|---|---|
| viewer (auditor) | internal audit | audit export, document summaries; no field values, no originals |
| inspector | purchasing clerk | review, correct, approve within the limit, reject |
| engineer | AP, warehouse | + matching, exceptions/retry, templates, aliases, price lists |
| manager | finance manager | + approve above the limit (not as editor), audit export |
| admin | DocFlow admin | + policies, gates, STP, adapters, intake sources, models, cloud flag |

Nobody — including admins — can create a posting without an approval row, change an original, or edit a correction. The `poster` service account can post but cannot approve or edit.

## B2. Approval policy and segregation of duties
`docflow.yaml → approval` (Admin → Configuration, schema-validated). Rows map an amount (in THB, converted with the stored rate for the policy only) to the minimum role and whether segregation of duties applies. Keep one row without an upper bound. Rejection reasons are always required (not configurable).

## B3. Gates and tolerances
`gates.fields`: minimum confidence per field and whether it is critical (critical fields require review unless template-matched and arithmetic-consistent). `tolerances.rules`: warning/failure percentages for price vs contract and for 2/3-way matching (≤ 20 %). Loosening a tolerance is audited with the config version.

## B4. Straight-through processing
Off by default and per (supplier, document type). **Admin → STP** shows, per pair, posted documents and the share posted without any correction. Enabling requires ≥ 50 documents at ≥ 98 % — the system refuses otherwise — and your name is recorded. A drift alert on the pair means disable it. An auto-cleared document still needs an approval (OPS-08 §7).

## B5. Suppliers, aliases, items, price lists, templates
Master data is synced from the ERP every 30 minutes. Add aliases when a supplier's name or part numbers on documents differ from the ERP (Admin → Suppliers). Templates are layout hints per supplier and document type: suggest one from recent corrections, measure it on the next 20 documents, activate; one active per pair; drift alerts when accuracy drops 5 points.

## B6. Adapters and intake
Adapters must declare idempotency support — the configuration refuses otherwise. The connectivity test only reads. Intake sources (mailbox, folder, SFTP, scanner) show last poll and last error; credentials are secret files, never in the configuration.

## B7. Models, prompts, schemas
Every change is a version with an evaluation on the 200-document set; a drop of more than 2 points or a metric below target blocks activation. The extraction schemas (`po.v2`, `invoice.v1`, `delivery_note.v1`) are the contract the AI must satisfy — never loosen a schema to make a supplier "work"; fix the template instead.

**Cloud model**: off by default. Enabling is an acknowledged admin decision (a fixed statement, your name, the time) that is audited; every extraction made with it is marked in the review screen. Disable it the same way (OPS-08 §8).

## B8. Audit
**Audit → Export** produces, for a period, who saw, edited, approved and posted every document (AC-09), in JSON or CSV. Reads of originals and page images are included. Quarterly: sample above-limit approvals for segregation of duties and sample original views for business need (OPS-08 §6).

## B9. When something looks wrong
| You see | Do |
|---|---|
| A posting with no approval, or an ERP transaction not in DocFlow | Incident (OPS-08 RB-07): deactivate the adapter; preserve evidence; finance reverses in the ERP |
| Many documents in review for one supplier | Template drift — Admin → Templates; disable STP for the pair |
| Exceptions with the same ERP error | The ERP or its account changed — OPS-08 RB-06; do not widen the account |
| An extraction marked *cloud* when policy is local | RB-10: revert the configuration; review the affected documents |
| Injection flags from one sender | RB-09: quarantine the sender; inform the supplier's real contact |

---

# Part C — Glossary (EN / TH / JA)

| English | ไทย | 日本語 | Meaning |
|---|---|---|---|
| Review queue | คิวตรวจสอบ | 確認待ち | Documents waiting for a person |
| Gate: auto-clear / review required / blocked | ผ่านอัตโนมัติ / ต้องตรวจสอบ / ถูกบล็อก | 自動承認可 / 要確認 / 保留 | Result of the code-side checks |
| Rule passed / warning / failed | ผ่าน / เตือน / ไม่ผ่าน | 合格 / 警告 / 不合格 | Per-rule validation result |
| Provenance (highlight) | ตำแหน่งที่มาบนเอกสาร | 出典位置 | Where a value was read on the page |
| Correction | การแก้ไขค่า | 修正 | A reviewer's change; kept with the name |
| Approve / Reject (with reason) | อนุมัติ / ปฏิเสธ (ระบุเหตุผล) | 承認 / 却下（理由） | The human decision |
| Segregation of duties | การแบ่งแยกหน้าที่ | 職務分掌 | The approver may not be the editor above the limit |
| 2-way / 3-way match | จับคู่ 2 ทาง / 3 ทาง | 2 者照合 / 3 者照合 | Invoice vs PO (vs goods receipt) |
| Duplicate invoice | ใบแจ้งหนี้ซ้ำ | 重複請求書 | Same supplier and number |
| Posting / ERP reference | การบันทึกเข้า ERP / เลขอ้างอิง ERP | 転記 / ERP 参照番号 | The transaction created once |
| Exception | รายการค้าง | 例外 | A posting or extraction that needs a person |
| Injection flag | สัญญาณคำสั่งแฝง | 指示混入フラグ | Instruction-like text found in a document |
| Straight-through processing (STP) | ประมวลผลอัตโนมัติ | 自動処理 | Skip review (not approval) for an earned pair |
| Template | แม่แบบผู้ขาย | サプライヤーテンプレート | Layout hints per supplier |
| Cloud model | โมเดลบนคลาวด์ | クラウドモデル | External model; acknowledged and audited |
