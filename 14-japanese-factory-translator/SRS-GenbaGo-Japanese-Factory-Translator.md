# Software Requirements Specification — Japanese Factory Translator Agent

| Field | Value |
|---|---|
| Document ID | SRS-14-GenbaGo |
| Project code name | **GenbaGo (現場語)** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify a **context-aware Japanese ↔ Thai ↔ English translation and interpretation agent for manufacturing**. Unlike a general translator, GenbaGo understands *genba* language: it maps a Japanese sentence to the process it describes, the quality documents it touches, and the actions it implies.

Example — input `成形条件を変更した後、不良率が上昇しました。` produces not only a Thai translation but a structured reading: process = injection molding, problem = defect-rate increase, likely parameters to check, and the related documents (SPC, FMEA, control plan).

This project's differentiator is the combination of Japanese N1 + factory quality experience + AI — a narrow capability few developers can build correctly.

### 1.2 Scope

**In scope**
- Text translation JA ⇄ TH ⇄ EN with a manufacturing terminology glossary.
- Terminology management: company-specific terms, abbreviations, supplier terms, kanji readings.
- Structured interpretation: process, problem type, entities, implied actions, related documents.
- Document translation preserving layout for common quality documents (8D, 品質報告書, 作業標準書, 検査基準書).
- Image/OCR translation of Japanese shop-floor documents, drawings and machine screens.
- Human review workflow and translation memory reuse.

**Out of scope**
- Real-time speech interpretation (v1 text only; audio is a future phase).
- Certified/legal translation.
- General-domain translation quality guarantees outside manufacturing.

### 1.3 Definitions
| Term | Meaning |
|---|---|
| Genba (現場) | The shop floor / actual place |
| TM | Translation Memory — previously approved segment pairs |
| Glossary term | A term with a mandated translation in each language |
| Segment | A translatable unit (sentence or cell) |
| Register | Formality level (報告書 vs 現場メモ) |

---

## 2. Overall Description

### 2.1 Product perspective
```
Input: text · document (docx/xlsx/pdf) · photo of a Japanese document
                     ↓
             Segmentation + OCR (JA vertical/horizontal aware)
                     ↓
      Translation Memory lookup (exact / fuzzy ≥ 85 %)
                     ↓
      Glossary-constrained MT / LLM translation
                     ↓
      Manufacturing interpretation layer
        · process classification (molding, welding, assembly, inspection…)
        · problem type (defect ↑, machine stop, spec change, audit finding…)
        · entities (line, machine, part, parameter, defect class)
        · implied actions + related document types
                     ↓
      Quality check (terminology · numbers · units · omission)
                     ↓
      Output: translation + structured reading + related links
                     ↓
      Human review → approve → write back to TM
```

### 2.2 User classes
| Class | Need |
|---|---|
| Thai engineer | understand Japanese instructions/reports correctly and fast |
| Japanese manager/expat | receive Thai/English reports in natural Japanese |
| Quality staff | translate 8D and customer complaints without losing technical meaning |
| Translator/coordinator | manage glossary, review, TM |
| New employee | learn genba vocabulary with context |

### 2.3 Operating environment
Docker on-prem (documents are confidential), PostgreSQL + pgvector for TM and glossary, local LLM ≤ 9 B with Japanese capability, OCR with Japanese support (vertical text), Next.js UI, optional browser extension / clipboard tool.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | Glossary terms SHALL be enforced: a mandated term must appear in the output or the segment is flagged. |
| C-02 | Numbers, units, part numbers, dates and product codes SHALL be preserved exactly; any change is a blocking error. |
| C-03 | Confidential documents SHALL be processed locally by default. |
| C-04 | The system SHALL never silently drop content; omissions are detected and flagged. |
| C-05 | Interpretation output SHALL be clearly separated from the translation itself, so users can distinguish "what was said" from "what the system inferred". |

### 2.5 Assumptions
A seed glossary can be assembled from existing documents; historical bilingual documents exist to bootstrap the TM; typical documents are digital, with photos as a secondary path.

---

## 3. Functional Requirements

### 3.1 Translation core
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Translate text between JA, TH and EN in any direction, preserving paragraph and list structure. | Must |
| FR-02 | Segment text correctly for Japanese (no spaces, 句読点, vertical text) and Thai (no word spaces). | Must |
| FR-03 | Look up the TM first: exact matches SHALL be reused verbatim; fuzzy matches ≥ 85 % SHALL be offered with a diff. | Must |
| FR-04 | Enforce glossary terms during generation and verify them after generation. | Must |
| FR-05 | Preserve and verify all numbers, units, tolerances, part numbers, dates and codes. | Must |
| FR-06 | Support register selection: 報告書 (formal report), 現場メモ (shop-floor note), 顧客向け (customer-facing). | Should |
| FR-07 | Provide alternative renderings for ambiguous terms with a short usage note. | Should |
| FR-08 | Provide furigana/reading and meaning for unfamiliar kanji terms on hover. | Could |

### 3.2 Manufacturing interpretation
| ID | Requirement | Priority |
|---|---|---|
| FR-09 | Classify the process referenced (injection molding, press, welding, assembly, painting, inspection, logistics, maintenance, other). | Must |
| FR-10 | Classify the message type (problem report, instruction, spec change, audit finding, schedule, request, information). | Must |
| FR-11 | Extract entities: line, machine, mould/tool, part number, defect class, parameter, quantity, date, person/role. | Must |
| FR-12 | For problem reports, propose the standard items to check, drawn from a curated knowledge base (shared with [MoldMind](../11-injection-molding-ai/SRS-MoldMind-Injection-Molding-AI.md) where applicable). | Must |
| FR-13 | Suggest related document types (SPC chart, FMEA, control plan, 作業標準書, 検査基準書) and link to actual documents when the knowledge base contains them. | Should |
| FR-14 | Interpretation SHALL be labelled as inference with a confidence, never merged into the literal translation. | Must |
| FR-15 | When the source is ambiguous, list the possible readings rather than choosing silently. | Must |

### 3.3 Documents & images
| ID | Requirement | Priority |
|---|---|---|
| FR-16 | Translate DOCX/XLSX/PPTX preserving structure, styles and cell layout. | Must |
| FR-17 | Translate PDFs producing a side-by-side or overlay output. | Should |
| FR-18 | OCR photos of Japanese shop-floor documents, including vertical text and handwriting (best effort, flagged). | Must |
| FR-19 | OCR and translate machine HMI screenshots, with an option to keep the original layout. | Should |
| FR-20 | Batch-translate a folder of documents with a progress and error report. | Should |

### 3.4 Terminology & memory
| ID | Requirement | Priority |
|---|---|---|
| FR-21 | Maintain a glossary: term (JA/TH/EN), domain, part of speech, notes, forbidden alternatives, approver. | Must |
| FR-22 | Support company-specific abbreviations and internal jargon (社内用語). | Must |
| FR-23 | Mine candidate terms from approved translations and propose them for glossary inclusion. | Should |
| FR-24 | Write approved segments back to the TM with metadata (document, domain, approver, date). | Must |
| FR-25 | Provide glossary/TM import-export in TBX/TMX or CSV. | Should |
| FR-26 | Track term usage statistics and flag terms with inconsistent historical translation. | Should |

### 3.5 Review workflow
| ID | Requirement | Priority |
|---|---|---|
| FR-27 | Present segment-by-segment review with source, machine output, TM match and glossary hits highlighted. | Must |
| FR-28 | Flag segments failing quality checks (missing glossary term, number mismatch, length anomaly, omission) before human review. | Must |
| FR-29 | Record every human edit as training/evaluation signal with an edit-distance metric. | Must |
| FR-30 | Support roles: translator (edit), reviewer (approve), admin (glossary). | Must |
| FR-31 | Show a quality dashboard: post-edit distance trend, glossary compliance, throughput. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/translate` | text translation + interpretation |
| POST | `/api/v1/translate/document` | document translation job |
| GET | `/api/v1/jobs/{id}` | job status/result |
| POST | `/api/v1/ocr` | image → text (JA-aware) |
| GET | `/api/v1/glossary?q=` | glossary lookup |
| POST | `/api/v1/glossary` | add/update term (role-checked) |
| POST | `/api/v1/tm/search` | fuzzy TM search |
| POST | `/api/v1/segments/{id}/approve` | approve and store to TM |

### 4.2 Clients
Web UI, Discord bot (`/jp <text>`), optional clipboard/hotkey desktop helper, optional browser extension for internal portals.

---

## 5. Data Requirements

```sql
glossary_term(id, ja, ja_reading, th, en, domain, pos, notes,
              forbidden_json, approved_by, updated_at)
tm_segment(id, src_lang, tgt_lang, src_text, tgt_text, domain, doc_ref,
           approver, created_at, embedding vector(1024))
translation_job(id, kind, src_lang, tgt_lang, status, file_uri, result_uri,
                created_by, created_at)
segment_result(id, job_id, ordinal, src_text, mt_text, tm_match_id, tm_score,
               final_text, edit_distance, checks_json, approved_by)
interpretation(id, segment_id, process, message_type, entities_json,
               suggested_checks_json, related_docs_json, confidence)
term_usage(term_id, date, count, inconsistencies)
```

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Translation SHALL use a local LLM with strong Japanese support, constrained by glossary injection and TM context in the prompt. |
| AI-02 | Quality targets on a 200-segment manufacturing test set: **glossary compliance ≥ 98 %**, number/code preservation 100 %, human post-edit distance ≤ 0.20 (normalised) for JA→TH. |
| AI-03 | A domain test set SHALL be built from real factory documents (not generic corpora) and versioned. |
| AI-04 | Automatic checks SHALL run on every segment: glossary presence, number equality, unit consistency, length ratio bounds, untranslated-source detection. |
| AI-05 | Interpretation classification (process, message type) SHALL reach ≥ 90 % accuracy on a labelled set of ≥ 300 real sentences. |
| AI-06 | OCR for Japanese SHALL support vertical text and achieve ≥ 95 % character accuracy on printed shop-floor documents; handwriting output SHALL be flagged as low confidence. |
| AI-07 | Embeddings for TM fuzzy matching SHALL be multilingual; exact match takes priority over vector similarity. |
| AI-08 | Human edits SHALL feed a monthly evaluation report; a metric regression > 2 % triggers investigation. |
| AI-09 | The LLM SHALL NOT invent related documents; suggested links come from the indexed document store only. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Short text (≤ 200 chars) translation ≤ 5 s p95. |
| NFR-02 | A 20-page DOCX ≤ 3 minutes. |
| NFR-03 | TM lookup ≤ 200 ms over 500 k segments. |
| NFR-04 | Fully local operation; confidential documents never leave the LAN by default (C-03). |
| NFR-05 | Documents access-controlled; who translated what is auditable. |
| NFR-06 | UI available in TH/JA/EN. |
| NFR-07 | Availability ≥ 99 %; failed document jobs are resumable. |
| NFR-08 | Glossary changes versioned with approver and effective date. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Domain test set meets AI-02 targets. |
| AC-02 | A segment containing "±0.05 mm / 3.2 mm / LOT-2609-114" preserves all values exactly. |
| AC-03 | A mandated glossary term rendered with a forbidden alternative is flagged before human review. |
| AC-04 | `成形条件を変更した後、不良率が上昇しました。` yields the correct Thai translation **and** an interpretation identifying molding, defect-rate increase, and the standard parameters to check. |
| AC-05 | An ambiguous sentence produces multiple readings instead of a single confident guess. |
| AC-06 | A vertical-text Japanese document photo is OCR'd and translated with layout preserved side by side. |
| AC-07 | Approved segments appear in TM and are reused verbatim on the next identical input. |
| AC-08 | Interpretation is visually separated from the translation in every output format. |
| AC-09 | Suggested related documents all exist in the index (no invented references). |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | segmentation, glossary schema, TM schema, basic translate API |
| P2 | 3–4 | glossary-constrained generation + automatic quality checks |
| P3 | 5–6 | TM fuzzy matching, review UI, approval → TM write-back |
| P4 | 7–8 | interpretation layer (process/type/entities/checks) + labelled set |
| P5 | 9–10 | document formats (DOCX/XLSX/PPTX/PDF), batch jobs |
| P6 | 11–12 | OCR (vertical/handwriting), HMI screenshots, dashboard, eval report |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Technical mistranslation causes a real production error | glossary enforcement, number checks, human review gate for critical documents |
| Glossary incomplete at launch | mine terms from existing bilingual documents; term-candidate proposal loop |
| Interpretation over-reaches and misleads | separated output (C-05), confidence, "possible readings" behaviour |
| Handwriting OCR poor | flag as low confidence, require human transcription for critical text |
| Local model weaker than cloud MT for JA→TH | TM + glossary compensate; measure with AI-02; allow a larger model if hardware permits |
| Confidential document leakage | local-only default, ACLs, audit |

---

## Appendix A — Example output

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
