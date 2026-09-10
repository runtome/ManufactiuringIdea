# Software Requirements Specification — AI Production Troubleshooting Memory

| Field | Value |
|---|---|
| Document ID | SRS-15-GenbaMemory |
| Project code name | **Genba Memory** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify an **institutional memory system for factory problems**: every incident, its investigation, root cause, action and outcome is captured, indexed and retrievable, so that when a similar symptom appears months or years later the system says *"this happened before — here is what it turned out to be and what fixed it."*

This attacks the most common failure of factory knowledge: the fix lives in one person's head or in a PDF nobody can find.

### 1.2 Scope

**In scope**
- Ingestion of historical and ongoing quality/maintenance records: 8D reports, RCA notes, maintenance logs, work orders, shift handover notes, chat/Discord threads, emails.
- Normalisation into a structured case model (symptom → investigation → cause → action → outcome).
- Multilingual (TH/JA/EN) hybrid retrieval with reranking.
- Similar-case suggestion, triggered automatically when a new problem is opened.
- Effectiveness statistics: which causes recur, which fixes actually work.
- Curation workflow so the memory improves rather than accumulating noise.

**Out of scope**
- Being the authoritative quality-records system (it indexes; the source of record may stay elsewhere).
- Automatic root-cause determination — it retrieves precedent; [QE-Agent (SRS-09)](../09-quality-engineer-agent/SRS-QE-Agent-Quality-Engineer.md) analyses.
- Document editing/authoring tools.

### 1.3 Definitions
**Case** = one problem from symptom to closure. **Symptom** = observable evidence. **Recurrence** = a case matching a prior case's symptom+scope. **Curation** = human confirmation that a case record is accurate and useful.

---

## 2. Overall Description

### 2.1 Product perspective
```
Sources: 8D PDFs · RCA notes · maintenance logs · work orders
         shift handovers · Discord threads · emails · spreadsheets
                          ↓
             Ingest · OCR · language detect · dedup
                          ↓
      Structuring (LLM-assisted extraction → case model)
                          ↓
   Normalisation: machine/line/SKU/defect codes → canonical entities
                          ↓
   Index: BM25 (multilingual) + vector (pgvector) + structured filters
                          ↓
   Retrieval: symptom query → similar cases (ranked, with outcomes)
                          ↓
   Curation & feedback  ←  "was this useful?" / "this is wrong"
                          ↓
   Surfaces: Copilot answers · new-case suggestions · recurrence alerts
```

### 2.2 User classes
| Class | Need |
|---|---|
| Technician | "has this happened before? what fixed it?" |
| Quality engineer | precedent for a current investigation, recurrence evidence |
| Maintenance planner | recurring failure patterns per machine |
| New employee | learn from history without asking a senior every time |
| Knowledge curator | keep the memory accurate and de-duplicated |

### 2.3 Operating environment
Docker on-prem, PostgreSQL 16 + pgvector (HNSW), OpenSearch/Postgres FTS for BM25, local embedding model (multilingual), local LLM ≤ 9 B for extraction and summarisation, Next.js UI, integration into [Factory Copilot (SRS-10)](../10-factory-copilot/SRS-FactoryCopilot-Local-Multilingual-Assistant.md).

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | The system SHALL always link back to the original document; the extracted structure never replaces the source. |
| C-02 | LLM-extracted fields SHALL be marked as extracted (vs human-verified) and shown as such. |
| C-03 | Retrieval SHALL never present an unverified extraction as an established fact. |
| C-04 | Everything runs locally; historical quality documents are confidential. |
| C-05 | Access control SHALL follow the source document's ACL; retrieval must not leak restricted content. |

### 2.5 Assumptions
Historical documents exist in some accessible form (file shares, email, ticket systems); entity codes (machine, line, SKU, defect) can be normalised with a mapping table; users will provide feedback if it is one click.

---

## 3. Functional Requirements

### 3.1 Ingestion
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Ingest PDF, DOCX, XLSX, PPTX, images, plain text, email (EML/MSG) and chat exports. | Must |
| FR-02 | OCR scanned documents including Japanese vertical text and Thai. | Must |
| FR-03 | Detect language per document and per section. | Must |
| FR-04 | Deduplicate by content hash and near-duplicate detection (same report in multiple formats). | Must |
| FR-05 | Preserve the original file immutably with provenance (source path, date, uploader). | Must |
| FR-06 | Support incremental sync from watched folders and mail/chat connectors. | Should |
| FR-07 | Report ingestion failures with actionable reasons (unreadable scan, password-protected). | Must |

### 3.2 Structuring
| ID | Requirement | Priority |
|---|---|---|
| FR-08 | Classify document type: 8D, RCA note, maintenance log, work order, handover, complaint, other. | Must |
| FR-09 | Extract the case model: title, date range, scope (line/machine/mould/SKU), symptom, investigation steps, root cause, containment, corrective action, verification result, status. | Must |
| FR-10 | Normalise extracted entities to canonical ids via a mapping table, flagging unmapped values for curation. | Must |
| FR-11 | Extract structured symptom descriptors: defect class, measurement deviation, failure mode, alarm code. | Must |
| FR-12 | Extract the *outcome*: did the action resolve the problem, and was recurrence observed afterwards? | Must |
| FR-13 | Mark each extracted field with confidence and provenance (page/section) and flag low-confidence fields for review. | Must |
| FR-14 | Support manual case entry and editing for knowledge that exists only in someone's head. | Must |

### 3.3 Retrieval
| ID | Requirement | Priority |
|---|---|---|
| FR-15 | Support free-text symptom queries in TH/JA/EN, returning ranked similar cases. | Must |
| FR-16 | Combine BM25 and vector search with reranking; support cross-language retrieval (Thai query finding Japanese documents). | Must |
| FR-17 | Support structured filters: machine, line, SKU, defect class, date range, outcome (resolved/unresolved). | Must |
| FR-18 | Rank by a combination of symptom similarity, entity overlap, recency and outcome quality (a case with a verified effective fix outranks an unresolved one). | Must |
| FR-19 | Show each result as: symptom, cause, action, outcome, date, source link, and why it matched. | Must |
| FR-20 | Automatically suggest similar cases when a new quality case or maintenance alert is opened. | Must |
| FR-21 | Detect recurrence: alert when a new case matches a closed case above a threshold, including the elapsed interval. | Must |
| FR-22 | Provide "cases like this on other lines/machines" for horizontal deployment (水平展開). | Should |

### 3.4 Analytics
| ID | Requirement | Priority |
|---|---|---|
| FR-23 | Report top recurring problems by machine, line, SKU and defect class over any period. | Must |
| FR-24 | Report action effectiveness: for each recurring cause, which corrective actions were followed by recurrence and which were not. | Must |
| FR-25 | Report mean time between recurrences per problem family. | Should |
| FR-26 | Identify knowledge gaps: cases closed without a recorded root cause or verification. | Should |

### 3.5 Curation & feedback
| ID | Requirement | Priority |
|---|---|---|
| FR-27 | Provide a curation queue for low-confidence extractions, unmapped entities and near-duplicate merges. | Must |
| FR-28 | Verified cases SHALL be badged as human-verified and boosted in ranking. | Must |
| FR-29 | Users SHALL be able to mark a retrieved case as helpful/not helpful, feeding ranking evaluation. | Must |
| FR-30 | Users SHALL be able to flag an incorrect extraction; flagged fields SHALL be suppressed until reviewed. | Must |
| FR-31 | The system SHALL report coverage metrics: % cases with cause, with verification, with human verification. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/documents` | ingest a document |
| GET | `/api/v1/cases/{id}` | case detail + source links |
| POST | `/api/v1/search` | symptom search (text + filters) |
| POST | `/api/v1/similar` | similar cases for a given case/alert |
| GET | `/api/v1/analytics/recurring?scope=` | recurrence report |
| POST | `/api/v1/cases/{id}/verify` | curator verification |
| POST | `/api/v1/feedback` | helpful / not helpful / incorrect |

### 4.2 Consumers
Factory Copilot (SRS-10) `search_memory` tool, QE-Agent (SRS-09) hypothesis retrieval, MachineSense (SRS-06) alert enrichment, KaizenSwarm (SRS-13) agents.

---

## 5. Data Requirements

```sql
source_document(id, sha256, kind, lang, uri, original_name, ingested_at,
                source_system, acl_json)
case(id, title, opened_at, closed_at, scope_json, status,
     symptom_text, cause_text, action_text, verification_text, outcome,
     recurrence_of_case_id, verified_by, verified_at)
case_field(id, case_id, field, value, confidence, provenance_json,
           extracted_by, flagged, corrected_by)
case_source(case_id, document_id, page_range)
case_entity(case_id, kind, canonical_id, raw_value, mapped)
case_chunk(id, case_id, ordinal, text, lang, embedding vector(1024))
entity_map(id, kind, raw_value, canonical_id, approved_by)
retrieval_log(id, ts, user_id, query, filters_json, results_json, latency_ms)
feedback(id, retrieval_log_id, case_id, rating, reason, ts)
```

Indexes: HNSW on `case_chunk.embedding`; GIN full-text per language; BTREE on scope fields.

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Extraction SHALL use schema-constrained generation with a local LLM; output validated against the case-model schema. |
| AI-02 | Extraction quality target on a 100-document labelled set: **field-level accuracy ≥ 85 %** for symptom/cause/action, ≥ 95 % for dates and scope entities. |
| AI-03 | Embeddings SHALL be multilingual and validated for cross-language retrieval (Thai query ↔ Japanese document) on a bilingual test set. |
| AI-04 | Retrieval target on a 50-query evaluation set with known relevant cases: **Recall@5 ≥ 0.80**, MRR ≥ 0.60. |
| AI-05 | Reranking SHALL use a cross-encoder or LLM reranker over the top 30 candidates. |
| AI-06 | Recurrence detection threshold SHALL be tuned on historical data with a reported precision/recall trade-off; default favours recall with human confirmation. |
| AI-07 | Every retrieval answer SHALL cite the case id and source document; no synthesised "combined case" may be presented as a real one. |
| AI-08 | Prompt-injection defence: document content is data, not instructions. |
| AI-09 | Re-embedding after a model upgrade SHALL be a background job that keeps the index queryable throughout. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Search results ≤ 1 s p95 over 100 k case chunks. |
| NFR-02 | Similar-case suggestion on case open ≤ 3 s. |
| NFR-03 | Ingestion throughput ≥ 500 documents/hour (excluding OCR-heavy scans). |
| NFR-04 | Support ≥ 50 k cases and ≥ 500 k chunks on the baseline hardware. |
| NFR-05 | ACL enforcement at query time; restricted documents never appear in results or snippets. |
| NFR-06 | Local-only processing; no document content sent externally. |
| NFR-07 | Availability ≥ 99 %; ingestion failures never block retrieval. |
| NFR-08 | All extractions reproducible: model + prompt + schema version stored. |
| NFR-09 | UI in TH/JA/EN with cross-language result display (original + translated snippet via [GenbaGo](../14-japanese-factory-translator/SRS-GenbaGo-Japanese-Factory-Translator.md)). |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Extraction meets AI-02 on the labelled set. |
| AC-02 | Retrieval meets AI-04 on the 50-query evaluation set. |
| AC-03 | A Thai symptom query retrieves a relevant Japanese 8D report in the top 5. |
| AC-04 | Opening a new case about "machine overload" surfaces the 2024 proximity-sensor case with its outcome. |
| AC-05 | A restricted document is invisible to a user without permission, including in snippets (automated ACL test). |
| AC-06 | An extraction flagged as incorrect is suppressed from results until curated. |
| AC-07 | Recurrence alert fires on a genuine repeat and reports the elapsed interval. |
| AC-08 | Every result links to a retrievable original document. |
| AC-09 | Model upgrade re-embeds 50 k chunks with search available throughout. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | ingestion, OCR, dedup, storage, provenance |
| P2 | 3–4 | case model extraction + schema validation + labelled set |
| P3 | 5–6 | entity normalisation, curation queue, manual case entry |
| P4 | 7–8 | hybrid retrieval + reranking + evaluation set |
| P5 | 9–10 | similar-case suggestion, recurrence detection, alerts |
| P6 | 11–12 | analytics (recurring problems, action effectiveness), feedback loop, ACLs |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Historical documents are messy/scanned/incomplete | OCR + confidence flags + curation queue + manual entry path |
| Wrong extraction becomes "institutional truth" | extracted-vs-verified badging (C-02), flagging, source links |
| Garbage accumulation reduces retrieval quality | curation workflow, verified boost, feedback-driven ranking evaluation |
| Cross-language retrieval underperforms | multilingual embeddings + BM25 per language + bilingual test set |
| Confidential leakage via snippets | query-time ACL enforcement, AC-05 test |
| Low adoption (nobody searches) | automatic suggestion on case open (FR-20) instead of relying on search behaviour |

---

## Appendix A — Example retrieval

```
Query (TH): "เครื่องจักร overload บ่อย มอเตอร์ไม่หมุน"
Scope filter: machine = M-07

3 similar cases found

① Case #418 · 2024-08-21 · M-07 · ✅ verified · similarity 0.87
   Symptom : Machine overload alarm, motor not rotating, intermittent
   Cause   : Proximity sensor abnormal (drifting output when hot)
   Action  : Replaced proximity sensor, added to 6-month PM list
   Outcome : Resolved — no recurrence for 14 months
   Source  : 8D_M07_2024-08.pdf (p.2–4) · matched on: symptom text, machine, alarm code

② Case #602 · 2025-06-03 · M-04 · ✅ verified · similarity 0.74
   Symptom : Overload trip after 2 h of continuous running
   Cause   : Coupling misalignment after mould change
   Action  : Realignment, added alignment check to changeover checklist
   Outcome : Resolved — 1 recurrence in 2025-11 (checklist not followed)
   Source  : maintenance_log_2025-06.xlsx (row 214)

③ Case #331 · 2023-12-11 · M-07 · ⚠ extracted, not human-verified · similarity 0.61
   Symptom : Motor stop, no alarm recorded
   Cause   : (not recorded)
   Action  : Reset and restart
   Outcome : Unknown — knowledge gap
   Source  : handover_note_2023-12-11.docx

⚠ Recurrence check: current symptom matches Case #418 (0.87) after 25 months.
  Suggested first inspection: proximity sensor condition and temperature drift.
```
