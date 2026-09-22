# User Manual & Administrator Guide — GenbaGo (Japanese Factory Translator Agent)

| Field | Value |
|---|---|
| Document ID | UM-14-GenbaGo |
| Version | 1.0 (Draft) |
| Date | 2026-09-22 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-14](../SRS-GenbaGo-Japanese-Factory-Translator.md) §2.2 user classes, §3, Appendix A · [SAD-14](SAD-GenbaGo-Software-Architecture.md) · [API-14](../api/API-Specification.md) · [OPS-14](OPS-GenbaGo-Deployment-Operations.md) |
| Audience | Part A — Thai engineers, Japanese managers, quality staff, translators/coordinators, new employees · Part B — administrators · Part C — everyone (glossary) |

The UI is available in Thai, Japanese and English (top-right switch). This guide uses the English labels; the Thai and Japanese labels are the same words in the glossary of Part C.

---

## Part A — Using GenbaGo

### A.1 What GenbaGo does — and what it does not

GenbaGo translates between Japanese, Thai and English **for this plant**: it uses the plant's own glossary and its memory of approved translations first, and a local language model only for the words in between. After translating it **checks** the result — every number, unit, tolerance, part number and date must be exactly as in the source, the plant's mandated terms must be used, forbidden ones must be absent, and no sentence may be missing. Then, in a **separate block**, it tells you what it thinks the text is about: the process, the kind of message, the numbers and parts named, the standard things to check, and the documents in the plant index that are related.

Three things to remember:

1. **The translation block is what was said.** The **interpretation block is what GenbaGo inferred** — it is always marked *inferred* with a confidence number, and it can be wrong. Never quote it as if the Japanese author wrote it.
2. **A blocked segment is not a translation.** If a number differs, GenbaGo blocks the segment and nobody can approve it until it is fixed. A flag (⚑) means "look at this" — a term, a possibly missing sentence, an odd length.
3. **Everything is confidential unless you say otherwise.** Your text and documents stay on the plant's server. Only the Discord `/jp` command is non-confidential — never paste a customer document there.

### A.2 Translate a sentence or a short text (Thai engineer, Japanese manager)

1. Open GenbaGo → **Translate**. Paste the text (≤ 2,000 characters). Choose the target language (or both TH and EN for a Japanese source) and the **register**: *report* (neutral written), *shopfloor* (short, plain), *customer* (polite です/ます).
2. Press **Translate**. Within ~5 s you see:

```
SOURCE (JA)
成形条件を変更した後、不良率が上昇しました。

TRANSLATION (TH)
หลังจากเปลี่ยนเงื่อนไขการขึ้นรูป อัตราของเสียเพิ่มขึ้น

TRANSLATION (EN)
After changing the molding conditions, the defect rate increased.

──────── INTERPRETATION (inferred — confidence 0.91) ────────
Process       : Injection molding (成形)
Message type  : Problem report
Entities      : parameter change (成形条件) · metric: defect rate (不良率) · direction: ↑
Timing        : change precedes the increase (causal claim implied, not verified)

Standard items to check
  ✓ Melt / mould temperature (溶融温度・金型温度)
  ✓ Injection pressure & speed (射出圧力・速度)
  ✓ Holding pressure & time (保圧・保圧時間)
  ✓ Cooling / cycle time (冷却時間・サイクルタイム)
  ✓ Material condition: lot, drying, regrind % (材料ロット・乾燥・再生材比率)

Related documents (found in index)
  · SPC chart — Line 3 fin pitch (last 30 days)
  · FMEA — RAD-500-A, process step 20
  · Control plan — RAD-500-A rev.7
  · Past case #178 — mould polish overdue → scratch increase

Glossary terms applied: 成形条件, 不良率, 保圧
```

Reading it line by line:

| Line | Meaning | Where it comes from |
|---|---|---|
| TRANSLATION | the sentence, with the plant's terms (成形条件 → เงื่อนไขการขึ้นรูป, 不良率 → อัตราของเสีย) | memory first (an exact earlier approval is reused word for word — a **TM** badge shows it), otherwise the model, constrained by the glossary |
| a green ✓ under it | all checks passed: numbers identical, terms used, nothing missing | computed by the database, not by the model |
| INTERPRETATION (inferred — 0.91) | GenbaGo's reading of what the text is about; 0.91 is how sure it is | a rule-based classifier on the plant's keywords plus the model; **never part of the translation** |
| Process / Message type | injection moulding; a problem report (not a request, not an instruction) | keywords such as 成形条件, 不良率, 上昇 |
| Entities | the parameter, the metric and the direction the sentence names | the plant's entity patterns |
| Timing | what the sentence says about order — and that "after" does not prove "because" | the wording (後) |
| Standard items to check | the five items the plant's QE has curated for *molding + problem report*; the names match MoldMind's parameters | the curated check list — GenbaGo cannot add items of its own |
| Related documents | documents that **exist** in the plant index, with links | the index — GenbaGo cannot cite a document that is not there |
| Glossary terms applied | which mandated terms were used | the glossary |

3. **Hover** any Japanese term underlined in the source to see its reading (ふりがな), its Thai and English renderings and a note. Hover a Thai or English term to see the Japanese.
4. **Copy** the translation alone with the copy button on the translation block; the interpretation block has its own button and copies with its label — you cannot copy them as one text.

**When the sentence is ambiguous.** For `不良品は現場で処理してください` GenbaGo does not guess. The interpretation block says *ambiguous — confidence 0.55* and lists the readings:

| # | Reading (JA) | TH | EN | When people mean this |
|---|---|---|---|---|
| 1 | 処理 = 廃棄する | ทิ้ง/ทำลายของเสียที่หน้างาน | dispose of the defective parts on the shop floor | a scrap bin is at the line |
| 2 | 処理 = 手直しする | แก้ไข/ซ่อมของเสียที่หน้างาน | rework the defective parts on the shop floor | a rework station exists at the line |
| 3 | 処理 = 対応・記録する | จัดการ/บันทึกของเสียที่หน้างาน | handle (sort and record) the defective parts on the shop floor | the safe reading; confirm with the author |

Ask the author which one was meant — the readings are there so you can ask a precise question.

**Japanese managers** use the same screen with Thai or English source and Japanese target; choose *customer* for text going outside the plant. Aliases and abbreviations used in the plant (成条, 傷, CA, SPC chart) are understood.

### A.3 Translate a document (quality staff, translators)

1. **Documents → New job**. Drag a DOCX, XLSX, PPTX, PDF or image (≤ 50 MB), or a folder for a batch (≤ 500 files). Choose languages and register. *Keep layout* is on: tables, numbering and styles are preserved; a PDF is delivered side-by-side (original left, translation right); a photo or HMI screenshot is delivered with the translated labels overlaid.
2. The job page shows progress (segments done / total). A 20-page report takes about 3 minutes.
3. When it is **done** (or **done with gaps** — the model was unavailable for some segments, which stay empty and are listed), open **Review** (A.4) or **Download** the result. A batch with a failed file shows the file; **Resume** restarts at that file only.

**Photographed documents (OCR).** A photo of a printed 検査基準書, even in vertical Japanese, is read region by region; the result is side-by-side. Regions that are **handwritten or read with low confidence are marked ⚠** and their segments are flagged for review — check those against the photo before trusting a number.

### A.4 Review segments (quality staff, translators, reviewers)

The review screen shows one segment per row: **source · memory match (if any) · machine translation · final text**, with the check result on the right.

| Mark | Meaning | What to do |
|---|---|---|
| ✓ clean | all checks pass | approve, or edit if the wording can be better |
| ⛔ blocked | a number, unit, tolerance, code or date differs from the source (`3.2 mm` → `3.5 mm`) | fix the number in the final text; the block clears by itself; **it cannot be approved while blocked** |
| ⚑ forbidden term | a rendering the plant forbids was used (修正措置 instead of 是正処置) | replace it with the mandated term shown; or approve with a note explaining why |
| ⚑ missing term | a mandated term from the source is not in the target | add it |
| ⚑ omission | fewer sentences in the target than in the source | add the missing sentence |
| ⚑ length / untranslated | the target is much longer/shorter than usual, or still contains source-language text | check |
| TM 100 % | an approved earlier translation of exactly this sentence was reused | no model was involved; approve unless the context differs |
| TM 92 % | a close earlier translation is shown with the differences highlighted | use it as a base if it fits |

- **Edit**: click the final text, change it, save. Every edit is recorded with who, when and how much changed (the *edit distance* shown as a percentage).
- **Approve** (reviewer role): approving writes the segment into the plant's memory, so the next time the same sentence appears it is reused word for word. A flagged segment needs a note; a blocked one cannot be approved.
- **Needs review**: leave a segment for a reviewer; it appears in **Review queue** oldest first.
- An approved segment is frozen; to change it later, translate it again in a new job — the newer approval takes precedence.

### A.5 Glossary and candidates (translators / coordinators)

**Glossary** lists every term with its reading, Thai, English, domain, forbidden renderings and the version in force; translators can search and propose. **Candidates** lists recurring Japanese expressions that were translated the same way several times but are not in the glossary yet — propose a rendering; an administrator accepts or rejects. **Memory** lets a reviewer search approved segments (`/tm/search`) and import/export TMX.

### A.6 Vocabulary mode (new employees)

Choose **Learn** in the menu: the glossary by domain (parameter, defect, document, action, …) with readings, both renderings and an example sentence from the memory; hover works everywhere in the UI. Use the *shopfloor* register when translating instructions for yourself — sentences are shorter.

### A.7 Discord `/jp` (non-confidential only)

In the plant channel type `/jp 不良率が上がっています`. The bot replies with the translation and the interpretation block. It refuses attachments and long texts, and it cannot show confidential jobs — use the web UI for documents.

### A.8 Copilot and QE-Agent

When Factory Copilot or the Quality Engineer Agent write Japanese text, they call GenbaGo for the mandated terms and a term check; a forbidden rendering in their drafts is reported by GenbaGo the same way as in the review screen.

---

## Part B — Administration

### B.1 Roles

| Role | Grants | Given by |
|---|---|---|
| viewer (default platform user) | translate, own jobs, hover readings | — |
| translator | upload documents, edit final text, propose candidates | admin (**Roles**) |
| reviewer | approve/reject, TM import/export, decide candidates | admin |
| admin | glossary, aliases, check items, keywords, test sets, roles, settings, exports | admin |

Nothing lets any role bypass a blocked segment or an unlabelled interpretation — those are database rules.

### B.2 Glossary administration

- **Add / change a term** (`Glossary → Edit`): Japanese, reading, Thai, English, domain, notes, forbidden renderings per language, **effective from** date and a change note. Every save is a new **version** with you as approver; the old versions remain visible under *History*. A forbidden rendering equal to the mandated one is refused.
- **Aliases**: plant abbreviations and 社内用語 that map to a term.
- **Import**: CSV with the columns of `deploy/glossary.example.csv`; the import report lists rejected rows and why.
- **Export**: CSV or TBX to the locked export bucket, with a checksum.
- **Consistency**: `Glossary → Consistency` shows terms that appear with more than one rendering in approved segments; decide which is right, version the term, and ask for the affected segments to be re-translated.

### B.3 Curated check items, keywords, entity patterns

Under **Interpretation settings**: the check items per *process × message type* (names shared with MoldMind), the process and message keywords with weights, and the entity patterns. Any change must pass an evaluation run (B.5) before it goes live — the classifier must stay ≥ 0.90 on the labelled set.

### B.4 Memory administration

Reviewers approve; admins can **import** an approved TMX, **export** the memory, and see **Memory stats** (segments per pair and domain, hit rate). Memory rows cannot be edited or deleted — a correction is a new approval. Duplicated sources with different targets are rejected at import.

### B.5 Test sets and evaluation

**Evaluation → Test sets**: import a versioned set (≥ 200 segments per pair; the demo set has 40). **Runs** shows every monthly run with glossary compliance, number preservation, post-edit distance and classification accuracy, the gate result and an **investigate** mark when a metric got worse by more than 2 %. Start a run manually after any change to prompts, keywords, check items or the model, and promote the change only if the run passes without *investigate*.

### B.6 Confidentiality and Discord

- Jobs are confidential by default; the setting cannot be changed. A non-confidential job is an explicit choice by the requester (and the only kind the Discord bot creates).
- No cloud translation provider is configured. Enabling one is a change request under SEC-14 §4 (SEC-J11), never a switch in the UI.
- Signed download links last ≤ 15 minutes; results follow the source document's access list.
- Post the `/jp` policy in the Discord channel topic.

### B.7 OCR

Before the first OCR job the plant's printed sample set must be measured (OPS-14 §7); until the measured accuracy is ≥ 95 % OCR jobs are refused. Handwriting is always flagged; do not ask for it to be trusted.

### B.8 Settings

**Settings** shows the values of `genba.setting` (thresholds, gates, model, retention) and whether the running configuration file matches them; mismatches stop the API. Change a value here first, then in `genbago.yaml` (OPS-14 §5).

### B.9 Dashboard

**Quality dashboard**: post-edit distance trend per month and pair, glossary compliance, blocked/flagged counts, throughput (segments and documents per day), memory hit rate, review queue age, OCR low-confidence share, last evaluation result.

---

## Part C — Glossary (the demo plant's 30 terms)

The glossary in force on the demo instance (`deploy/glossary.example.csv`). A forbidden rendering is shown as `lang:text`.

| 日本語 | 読み | ไทย | English | Domain | Forbidden |
|---|---|---|---|---|---|
| 成形条件 | せいけいじょうけん | เงื่อนไขการขึ้นรูป | molding conditions | parameter | — |
| 不良率 | ふりょうりつ | อัตราของเสีย | defect rate | metric | — |
| 保圧 | ほあつ | แรงดันย้ำ | holding pressure | parameter | — |
| 金型 | かながた | แม่พิมพ์ | mould | general | en:mold die |
| 射出圧力 | しゃしゅつあつりょく | แรงดันฉีด | injection pressure | parameter | — |
| 溶融温度 | ようゆうおんど | อุณหภูมิหลอม | melt temperature | parameter | — |
| 冷却時間 | れいきゃくじかん | เวลาหล่อเย็น | cooling time | parameter | — |
| サイクルタイム | さいくるたいむ | รอบเวลาการผลิต | cycle time | parameter | — |
| 是正処置 | ぜせいしょち | มาตรการแก้ไข | corrective action | action | ja:修正措置; en:correction measure |
| 水平展開 | すいへいてんかい | การขยายผลแนวราบ | horizontal deployment | action | ja:横展開 |
| 作業標準書 | さぎょうひょうじゅんしょ | เอกสารมาตรฐานการทำงาน | work standard | document | th:คู่มือการทำงาน |
| 検査基準書 | けんさきじゅんしょ | เอกสารมาตรฐานการตรวจสอบ | inspection standard | document | — |
| 品質報告書 | ひんしつほうこくしょ | รายงานคุณภาพ | quality report | document | — |
| 管理図 | かんりず | แผนภูมิควบคุม | control chart | document | — |
| 公差 | こうさ | พิกัดความคลาดเคลื่อน | tolerance | general | — |
| ロット | ろっと | ล็อต | lot | general | — |
| 再生材 | さいせいざい | วัสดุรีไซเคิล | regrind | material | — |
| 乾燥 | かんそう | การอบแห้ง | drying | process | — |
| 段取り | だんどり | การเตรียมงาน | changeover | process | — |
| チョコ停 | ちょこてい | หยุดสั้น | micro-stop | metric | — |
| キズ | きず | รอยขีดข่วน | scratch | defect | — |
| バリ | ばり | ครีบ | burr | defect | — |
| ショート | しょーと | ชิ้นงานไม่เต็ม | short shot | defect | — |
| ヒケ | ひけ | รอยยุบ | sink mark | defect | — |
| 寸法 | すんぽう | ขนาด | dimension | general | — |
| 検査 | けんさ | การตรวจสอบ | inspection | process | — |
| 工程 | こうてい | กระบวนการ | process step | general | — |
| 対策 | たいさく | มาตรการ | countermeasure | action | — |
| 現場 | げんば | หน้างาน | genba (shop floor) | general | — |
| 溶接 | ようせつ | การเชื่อม | welding | process | — |

Aliases (`genba.term_alias`): 成条 → 成形条件 (jargon) · 傷 → キズ (variant) · CA → 是正処置 (abbreviation) · SPC chart → 管理図 (variant) · สภาพการฉีด → เงื่อนไขการขึ้นรูป (variant).

GenbaGo words: **segment** — one sentence or cell being translated · **memory (TM)** — approved translations reused word for word · **blocked / flagged** — see A.4 · **interpretation** — GenbaGo's inferred reading, never the translation · **reading** — one of the possible meanings of an ambiguous sentence · **register** — report / shopfloor / customer · **version** — a glossary term's history entry with approver and effective date.
