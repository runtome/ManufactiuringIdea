# Software Requirements Specification — AI Vision + Agent for Injection Molding

| Field | Value |
|---|---|
| Document ID | SRS-11-MoldMind |
| Project code name | **MoldMind** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Parent platform | [FactoryBrain AI](../00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |

---

## 1. Introduction

### 1.1 Purpose
Specify a **process-specific** system for injection molding: detect molding defects from images, join them with machine parameters, mould and material context, and let a domain-aware agent map the defect to its known process causes and drive a structured root-cause conversation ending in an 8D.

Where [VisionOps (SRS-01)](../01-factory-inspector-agent/SRS-AI-Factory-Inspector-Agent.md) is process-agnostic, MoldMind encodes injection-molding **domain knowledge**: the causal relationships between short shot, flash, sink mark, burn mark, weld line, warpage, silver streak, contamination and the parameters that produce them.

### 1.2 Scope

**In scope**
- Defect classes specific to injection molding (see §3.2).
- Machine parameter acquisition per shot (injection pressure/speed, holding pressure/time, melt & mould temperatures, cooling time, cycle time, cushion, screw position, clamping force).
- Shot-level traceability: mould id, cavity number, material lot, dryer condition, regrind %, machine, operator.
- Defect ↔ parameter knowledge base (molding troubleshooting matrix).
- Guided RCA dialogue and 8D generation.
- Cavity-level defect analysis (which cavity is producing the defect).

**Out of scope**
- Closed-loop parameter adjustment on the machine (advisory only, v1).
- Mould design / flow simulation (Moldflow-class analysis).
- Non-injection processes.

### 1.3 Definitions
| Term | Meaning |
|---|---|
| Short shot | Incomplete filling of the cavity |
| Flash (バリ) | Excess material at the parting line |
| Sink mark (ヒケ) | Surface depression from volumetric shrinkage |
| Burn mark | Degradation/trapped-gas burn |
| Weld line | Line where flow fronts meet |
| Silver streak | Moisture/volatile streaking |
| Cushion | Residual material at end of hold |
| Cavity | One impression in a multi-cavity mould |

---

## 2. Overall Description

### 2.1 Product perspective
```
Camera (part exit / robot pick)         Machine (OPC-UA / Euromap 77 / MQTT)
        ↓                                            ↓
  Vision AI (defect class + location)      Shot record (parameters)
        └──────────────┬─────────────────────────────┘
                       ▼  joined by shot id / timestamp / cavity
                 Shot Database
        (mould · cavity · material lot · dryer · regrind %)
                       ▼
             Defect–Parameter Analyser
       (per-cavity rates · parameter deltas · drift · correlation)
                       ▼
        Molding Knowledge Base (troubleshooting matrix + past cases)
                       ▼
                 RCA Agent (guided dialogue)
                       ▼
        Hypotheses → checks → verified cause → 8D → 水平展開
```

### 2.2 User classes
| Class | Need |
|---|---|
| Molding technician | which parameter to check, in what order |
| Process engineer | parameter drift, cavity analysis, DOE support |
| Quality engineer | defect trend, 8D, customer response |
| Mould maintenance | mould/cavity condition signals |
| Production manager | scrap cost and downtime impact |

### 2.3 Operating environment
Edge camera at the part-exit/robot station; machine data via OPC-UA (Euromap 77/83) or MQTT gateway; on-prem server (Docker, PostgreSQL/TimescaleDB, pgvector); local LLM ≤ 9 B. Hot, noisy environment near the press.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | Read-only access to the moulding machine. No parameter write-back in v1. |
| C-02 | Every defect record MUST be joinable to exactly one shot and, where possible, one cavity. |
| C-03 | Domain rules SHALL live in a reviewable knowledge base (YAML/DB), not inside prompt text. |
| C-04 | Advice SHALL always be ordered by safety/reversibility: check-before-change; parameter changes are suggestions for the technician, within documented process windows. |
| C-05 | Suggested parameter changes SHALL never exceed the mould/material documented limits. |

### 2.5 Assumptions
The machine exposes per-shot data; parts can be imaged individually or by cavity group; mould/cavity identity is derivable (marking, robot position, or fixed sequence); material lot and dryer records are logged.

---

## 3. Functional Requirements

### 3.1 Shot data acquisition
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Acquire per-shot parameters: injection pressure & speed profile, holding pressure & time, back pressure, screw RPM, cushion, melt temperature (per zone), mould temperature (fixed/moving), cooling time, cycle time, clamping force. | Must |
| FR-02 | Record shot context: machine, mould id, cavity count, material grade & lot, regrind %, dryer temp/time, ambient temp/humidity, operator group, shift. | Must |
| FR-03 | Assign a unique shot id and align it with the captured image(s) within a configurable time tolerance. | Must |
| FR-04 | Detect and record parameter changes (who/when/old/new) as timeline events. | Must |
| FR-05 | Flag data-quality problems (missing zone temperature, stuck value, clock skew). | Should |

### 3.2 Vision detection
| ID | Requirement | Priority |
|---|---|---|
| FR-06 | Detect and classify: short shot, flash, sink mark, burn mark, weld line, silver streak, warpage, contamination/black spot, colour deviation, scratch. | Must |
| FR-07 | Localise the defect on the part and map it to a part region (gate area, far end, rib, boss, parting line). | Must |
| FR-08 | Determine the cavity number from part marking OCR, robot position or shot sequence. | Must |
| FR-09 | Measure colour deviation as ΔE against a reference standard under controlled lighting. | Should |
| FR-10 | Flag out-of-distribution appearance via an anomaly model for defects outside the trained set. | Should |
| FR-11 | Route low-confidence detections to human review; store the human verdict. | Must |

### 3.3 Analysis
| ID | Requirement | Priority |
|---|---|---|
| FR-12 | Compute defect rate per cavity and flag cavities significantly worse than the mould average. | Must |
| FR-13 | Compare parameters on defective vs good shots in the same window and report significant deltas with effect sizes. | Must |
| FR-14 | Detect parameter drift (e.g. cushion trending down, cycle time creeping) against the setup sheet / golden run. | Must |
| FR-15 | Correlate defect onset with the event timeline: material lot change, mould change, purge, maintenance, parameter edit, shift change, startup after downtime. | Must |
| FR-16 | Distinguish startup-transient defects from steady-state defects (first N shots after start). | Must |
| FR-17 | Compute the scrap cost impact per defect class per period. | Should |
| FR-18 | Provide a golden-run comparison view: current parameters vs the approved setup sheet, highlighting deviations. | Must |

### 3.4 Knowledge base & RCA agent
| ID | Requirement | Priority |
|---|---|---|
| FR-19 | Maintain a reviewable defect→cause→check→action knowledge base covering the classes in FR-06, with the plausible parameter directions for each cause. | Must |
| FR-20 | For a detected defect trend, the agent SHALL produce a ranked cause list combining knowledge-base priors with observed data evidence. | Must |
| FR-21 | The agent SHALL conduct a guided dialogue asking targeted questions ("Was the material dried per spec?", "材料ロットは変更しましたか？", "Was mould maintenance performed?") and update the ranking with each answer. | Must |
| FR-22 | The agent SHALL propose checks ordered cheapest/most-reversible first, separating *checks* from *parameter changes*. | Must |
| FR-23 | Any suggested parameter change SHALL include direction, magnitude range, the documented process window and the expected side effects. | Must |
| FR-24 | The agent SHALL record the technician's actions and outcomes, and verify effectiveness by comparing defect rates before/after with a significance test. | Must |
| FR-25 | Verified cause–action–outcome triplets SHALL be written back to the knowledge base as case evidence, strengthening future ranking. | Must |
| FR-26 | The agent SHALL generate an 8D draft via [QE-Agent (SRS-09)](../09-quality-engineer-agent/SRS-QE-Agent-Quality-Engineer.md) rather than duplicating that logic. | Should |
| FR-27 | Output SHALL be available in Thai, Japanese and English with correct molding terminology. | Must |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/shots` | shot record from the machine gateway |
| POST | `/api/v1/shots/{id}/inspection` | vision result for a shot |
| GET | `/api/v1/cavity-analysis?mould=&from=&to=` | per-cavity defect rates |
| GET | `/api/v1/parameter-delta?defect=&window=` | good vs bad parameter comparison |
| GET | `/api/v1/golden-run/{mould}` | setup sheet comparison |
| POST | `/api/v1/rca/sessions` | start guided RCA |
| POST | `/api/v1/rca/sessions/{id}/answer` | answer an agent question |
| GET | `/api/v1/knowledge/defect/{class}` | knowledge-base entry |

### 4.2 Machine integration
OPC-UA (Euromap 77) preferred; Euromap 63 file interface or MQTT gateway as alternatives; read-only credentials.

---

## 5. Data Requirements

```sql
mould(id, code, cavities, material_spec, setup_sheet_json, last_maintenance_at)
machine(id, code, tonnage, controller, opcua_endpoint)
material_lot(id, grade, lot_code, supplier, received_at, dryer_temp, dryer_hours,
             regrind_pct, moisture_pct)
shot(id, ts, machine_id, mould_id, material_lot_id, cycle_time_s,
     params_json, cushion_mm, melt_temp_json, mould_temp_json, operator_group, shift)
shot_part(id, shot_id, cavity_no, image_uri, verdict, model_version)
shot_defect(id, shot_part_id, defect_class, confidence, region, bbox_json, delta_e)
timeline_event(id, ts, machine_id, mould_id, kind, detail_json)  -- lot/parameter/maintenance
kb_defect(id, class, description_th, description_ja, description_en)
kb_cause(id, defect_id, cause, prior_weight, typical_params_json, check_steps_json,
         action_steps_json, side_effects, source)
rca_session(id, opened_at, defect_class, mould_id, status, ranked_causes_json,
            dialogue_json, verified_cause_id, closed_at)
action_outcome(id, rca_session_id, action, applied_at, before_rate, after_rate,
               p_value, effective)
```

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Detection model trained per mould family where appearance differs substantially; a shared backbone with per-family heads is acceptable. |
| AI-02 | Target metrics: mAP@50 ≥ 0.80 across classes; **recall ≥ 0.95 for short shot, flash and contamination** (customer-critical). |
| AI-03 | Classes that are visually subtle (sink mark, weld line) SHALL use controlled lighting (e.g. deflectometry/low-angle) rather than being forced onto a generic model. |
| AI-04 | Colour deviation SHALL be measured colourimetrically (ΔE) with a reference chart in frame, not inferred by the model. |
| AI-05 | Cause ranking SHALL be a transparent scoring function combining knowledge-base priors, observed parameter deltas, timeline coincidence and past-case outcomes — inspectable, not a black box. |
| AI-06 | The LLM SHALL be used for dialogue and explanation only; ranking numbers come from the scoring function. |
| AI-07 | Golden set of ≥ 15 historical molding incidents with known causes; target: true cause in top-3 for ≥ 70 % (domain priors make this higher than the generic QE-Agent target). |
| AI-08 | Knowledge-base entries SHALL cite a source (textbook, supplier datasheet, internal case) and be approved by a process engineer before use. |
| AI-09 | Any suggested parameter magnitude SHALL be validated against the mould/material window; out-of-window suggestions are blocked. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Shot-to-record latency ≤ 2 s; inspection must not extend cycle time. |
| NFR-02 | Vision inference ≤ 150 ms per part; sufficient for a 12 s cycle with 4 cavities. |
| NFR-03 | Cavity analysis over 30 days ≤ 3 s. |
| NFR-04 | RCA dialogue response ≤ 15 s per turn. |
| NFR-05 | Shot data ingestion SHALL buffer ≥ 24 h if the DB is unavailable. |
| NFR-06 | Read-only machine access enforced at the credential level and auditable. |
| NFR-07 | Enclosure and camera mount rated for the press environment (heat, vibration, oil mist). |
| NFR-08 | Knowledge-base changes SHALL be versioned with author and approval. |
| NFR-09 | Full TH/JA/EN terminology support in UI and outputs. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Vision metrics meet AI-02 on a hold-out set of real molded parts. |
| AC-02 | Cavity attribution correct for ≥ 98 % of parts on a 500-part trial. |
| AC-03 | Injected scenario (deliberate hold-pressure reduction) is detected as a parameter delta and ranks "insufficient holding pressure" in the top-2 causes for sink mark. |
| AC-04 | Golden set: true cause in top-3 for ≥ 70 % of 15 incidents. |
| AC-05 | An out-of-window parameter suggestion is blocked and logged. |
| AC-06 | Startup transient after a 2 h stop is classified as transient and does not raise a trend alert. |
| AC-07 | Effectiveness verification correctly confirms improvement after a real corrective action. |
| AC-08 | Japanese dialogue uses correct molding terms (ヒケ, バリ, ショートショット) — native review. |
| AC-09 | Machine connection loss for 1 h: shots buffered at the gateway and reconciled. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | machine gateway (OPC-UA), shot schema, timeline events |
| P2 | 3–4 | camera station, image↔shot alignment, cavity attribution |
| P3 | 5–7 | defect model training + lighting setup + evaluation |
| P4 | 8–9 | cavity analysis, parameter delta, drift, golden-run view |
| P5 | 10–11 | knowledge base authoring + scoring function |
| P6 | 12–13 | RCA guided dialogue, action tracking, effectiveness verification |
| P7 | 14 | i18n, 8D handoff to QE-Agent, validation, docs |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Subtle defects invisible under normal lighting | dedicated lighting design; scope classes to what the optics can resolve |
| Cavity misattribution corrupts analysis | multiple attribution methods + AC-02 gate |
| Technicians change parameters without recording | capture parameter changes from the machine automatically (FR-04) |
| Knowledge base becomes stale or wrong | approval workflow, source citation, case-outcome feedback (FR-25) |
| Suggested change causes another defect | side-effect field mandatory, process-window validation, check-first ordering |
| Camera survivability near the press | rated enclosure, vibration isolation, thermal test |

---

## Appendix A — Knowledge-base entry sketch

```yaml
defect: sink_mark
description_ja: "ヒケ — 厚肉部の体積収縮による表面のくぼみ"
causes:
  - cause: insufficient_holding_pressure
    prior_weight: 0.30
    typical_params: { holding_pressure: down, cushion: low }
    checks:
      - "Verify cushion value vs setup sheet (target 3–6 mm)"
      - "Check holding pressure trace against golden run"
    actions:
      - { param: holding_pressure, direction: up, range: "+5..+15 %",
          window_ref: setup_sheet, side_effects: "risk of flash, increased internal stress" }
    source: "Internal case #178; molding troubleshooting guide §4.2"
  - cause: holding_time_too_short
    prior_weight: 0.20
    typical_params: { holding_time: down }
    checks: ["Confirm gate seal time by gate-freeze study"]
  - cause: melt_temperature_too_high
    prior_weight: 0.15
  - cause: mould_temperature_too_high_local
    prior_weight: 0.15
    checks: ["Measure mould surface temperature near the thick section"]
  - cause: part_wall_thickness_design
    prior_weight: 0.10
    note: "Design cause — not correctable by parameters; route to engineering"
  - cause: insufficient_cooling_time
    prior_weight: 0.10
```
