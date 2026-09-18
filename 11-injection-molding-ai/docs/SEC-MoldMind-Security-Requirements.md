# Security Requirements Specification — MoldMind (AI Vision + Agent for Injection Molding)

| Field | Value |
|---|---|
| Document ID | SEC-11-MoldMind |
| Version | 1.0 (Draft) |
| Date | 2026-09-18 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-11](../SRS-MoldMind-Injection-Molding-AI.md) · [SAD-11](SAD-MoldMind-Software-Architecture.md) · [DDS-11](DDS-MoldMind-Database-Design.md) · [API-11](../api/API-Specification.md) · [ICD-11](ICD-MoldMind-Interface-Control.md) · [TEST-11](TEST-MoldMind-Test-Plan.md) TS-4, TS-5, TS-9 · [OPS-11](OPS-MoldMind-Deployment-Operations.md) · platform: [SEC-00](../../00-factorybrain-platform/docs/SEC-FactoryBrain-Security-Requirements.md) |

---

## 1. Scope and what is different here
MoldMind sits next to a press. The things that can go wrong are physical before they are informational: a parameter written to the machine, a suggestion that exceeds what the mould or material tolerates, a technician acting on advice that skipped the check, a wrong cavity blamed and a good cavity blocked, a knowledge base quietly edited to say what someone wants it to say. The objectives start there; confidentiality of images and shot data follows the platform's baseline.

### 1.1 Security objectives
| # | Objective | Enforcement point |
|---|---|---|
| **O-1** | **The machine is read-only.** No path from MoldMind writes a setpoint. | OPC-UA account read-only on the server; `SignAndEncrypt`; client without write methods; `trg_machine_readonly`, `trg_node_map_readonly`; `gateway_rw` grants; audited write refusals (C-01, NFR-06) |
| **O-2** | **No suggestion outside the documented window; checks before changes.** | `parameter_window` + `trg_suggestion_window` (blocked + audit; asserted allowed refused); `trg_advice_check_first`; side effects mandatory (C-04, C-05, AI-09) |
| **O-3** | **Knowledge is sourced, approved by a second engineer, versioned and immutable.** | `kb_cause.source` CHECK; `trg_kb_version_immutable`; only approved versions rank (C-03, AI-08, NFR-08) |
| **O-4** | **Rankings are transparent; the model never ranks or computes.** | `cause_score()`; `trg_cause_score_transparent`; facts-object-only model input (AI-05, AI-06) |
| **O-5** | **Every defect is attributable; evidence is never orphaned or misattributed silently.** | `trg_defect_joinable`, `trg_shot_part_cavity`, `trg_alignment_tolerance`; attribution method stored and measured (C-02, AC-02) |
| **O-6** | **Local by default; images and shot data stay on the LAN; gateway and camera are isolated.** | `machine` and camera networks isolated; `internal` network without egress; signed URLs; no external model |

## 2. Assets
| Asset | Sensitivity | Where |
|---|---|---|
| The press's setpoints | **safety-critical** — a wrong write damages the mould or the part run | outside MoldMind; reached only through the read-only IF-05 account |
| Process windows and setup sheets | critical — the bounds of every suggestion | `parameter_window`, `setup_sheet_version` |
| Knowledge base | integrity-critical — shapes every ranking | `kb_*`, `deploy/kb/*.yaml` |
| Scoring config, prompts, models | integrity-critical | `scoring_config`, `prompt_template`, model registry |
| Shots and parameters | high — process know-how | `quality.shot`, `shot_ext` |
| Part images | medium–high — customer parts | MinIO `parts/` |
| RCA sessions, outcomes, evidence | high — decisions and their proof | `rca_*`, `action_outcome`, `kb_case_evidence` |
| Machine credentials, certificates, service tokens | critical | secret files |

## 3. Trust boundaries
| Zone | Contents | Trust |
|---|---|---|
| Z0 Press | controller (OPC-UA server), setpoints | authoritative; **must refuse writes from MoldMind's account** |
| Z1 Machine network | `gateway-opcua` / `gateway-mqtt` | read-only client; buffers |
| Z2 Camera / edge | camera, lighting, `vision-infer`, capture | isolated; no route to Z0 |
| Z3 Server | `api`, `aligner`, `analyser`, `kb-service`, `rca-agent`, `scheduler` | high; deterministic |
| Z4 Model | Ollama | **low-trust output** — phrases only; term-checked |
| Z5 Data | PostgreSQL, Redis, MinIO | high |
| Z6 Users | technicians, engineers, maintenance, managers (LAN) | authenticated; role-scoped |
| Z7 Siblings | QE-Agent (handoff), Copilot (tools), MachineSense (alarms) | service tokens; read scopes |

Boundary rules: Z1 has no write method and the server refuses writes anyway; Z2 never reaches Z0; Z4 has no tools, no network; nothing leaves Z3–Z5 except notifications (statistics only).

## 4. Threat model

### 4.1 Threats (STRIDE)
| ID | Threat | Category | Objective | Controls |
|---|---|---|---|---|
| THR-M01 | **Parameter write path** — a compromised gateway, a mis-scoped account or a future "auto-adjust" feature writes a setpoint | Tampering (physical) | O-1 | read-only account enforced on the server; write attempts refused and counted (`mm_machine_write_refused_total`); no write method in the client; node maps refuse `access ≠ read`; `credential_kind` check (SEC-M01…M04) |
| THR-M02 | **Window bypass** — a suggestion outside the mould/material limits reaches the technician as allowed; the window itself is widened without a source | Tampering | O-2 | `trg_suggestion_window` (blocked + audit; asserted allowed refused); windows require a source and an approver; window changes audited (SEC-M10…M13) |
| THR-M03 | **Check skipped** — advice presents a parameter change first | Integrity | O-2 | `trg_advice_check_first`; UI cannot reorder (SEC-M11) |
| THR-M04 | **KB poisoning or stale KB** — a wrong cause/action inserted; priors edited to favour a supplier's story; the KB never updated | Tampering | O-3 | sources mandatory; approval by a different engineer; immutability; golden run on every version; stale-cause check (SEC-M20…M24) |
| THR-M05 | **Model-invented cause or magnitude** — the dialogue model adds a cause or suggests "raise to 800 bar" | Tampering | O-4 | model sees only the facts object; ranking stored with components and recomputed; magnitudes only from actions × windows; term check (SEC-M30…M32) |
| THR-M06 | **Cavity misattribution** — OCR misreads C3 as C8; sequence drift after a robot change | Integrity | O-5 | cavity ≤ mould cavities refused; attribution method stored; AC-02 trial per method; alignment tolerance (SEC-M40, M41) |
| THR-M07 | **Gateway spoofing / replay** — forged shots or replayed batches distort analysis | Spoofing | O-5 | service token bound to `gateway_rw`; TLS; `shot_id` idempotency; batch accounting (`inserted + duplicates = buffered`) (SEC-M42, M43) |
| THR-M08 | **Unrecorded parameter change** — a technician edits at the controller; the timeline is blind | Repudiation | O-2 | setpoint nodes captured automatically with the controller user (FR-04); manual-entry endpoint for what the controller does not expose (SEC-M44) |
| THR-M09 | **Effectiveness asserted** — an action marked effective without proof; a non-verified cause written into knowledge | Repudiation | O-3, O-4 | `trg_action_effective` (computed); write-back only for verified causes (SEC-M25, M33) |
| THR-M10 | **Image / shot exfiltration** | Information disclosure | O-6 | isolated networks; no egress; signed URLs; images never in notifications (SEC-M50…M52) |
| THR-M11 | **Under-role approval** — a technician approves a setup sheet or a KB version | Elevation | O-3 | role ≥ engineer and author ≠ approver in triggers (SEC-M21) |
| THR-M12 | **Camera / enclosure failure producing confident nonsense** | Availability / integrity | O-5 | frozen-frame detection (ICD-00 IF-02); enclosure monitoring; review rate alert (SEC-M45) |

### 4.2 The attack worth walking through — "just raise the holding pressure"
A technician under time pressure asks the assistant for "the number". The RCA session ranks `insufficient_holding_pressure` first; the action row says "+5..+15 %" and the window says 500–750 bar. The technician types 800 into the suggestion box. The database stores the row `blocked` with `OUT_OF_WINDOW: holding_pressure 800 outside [500, 750] bar` and an audit row; the UI shows it red with the window and its source (mould datasheet MLD-0417 rev C). If a client tried to assert `allowed = true`, the insert is refused. Even if the technician sets 800 at the controller anyway, MoldMind cannot have done it (read-only), the change is captured from the setpoint node with the controller user, appears on the timeline, and the next flash trend points back at it. Residual: the technician's own action at the controller is outside MoldMind's control — RR-M01.

## 5. Security requirements

### 5.1 Read-only machine (O-1)
| ID | Requirement | Verification |
|---|---|---|
| SEC-M01 | The OPC-UA account SHALL be read-only, enforced on the machine's server; a deliberate write attempt from the gateway SHALL be refused by the server and counted. | TC-110, TC-013 |
| SEC-M02 | The gateway client SHALL contain no write method; node maps SHALL refuse `access ≠ read`; `machine_connection.credential_kind` SHALL be `read_only`. | TC-003 probes 9, 12; TC-085 |
| SEC-M03 | OPC-UA sessions SHALL use `Basic256Sha256/SignAndEncrypt` with a client certificate trusted on the machine. | TC-011 |
| SEC-M04 | Connection and node-map changes SHALL be admin-only and audited; the connection test SHALL report `write_refused_by_server`. | TC-012, TC-116 |

### 5.2 Windows and ordering (O-2)
| ID | Requirement | Verification |
|---|---|---|
| SEC-M10 | Every suggested value SHALL be validated against the mould × material window; outside → stored `blocked`, audited, never `allowed`. | TC-003 probe 4, TC-055 |
| SEC-M11 | Advice SHALL order every check before any parameter change; the database SHALL refuse the opposite. | TC-003 probe 8, TC-054 |
| SEC-M12 | Windows and setup sheets SHALL carry a source and an approver; changes SHALL be versioned and audited. | TC-048, TC-116 |
| SEC-M13 | Every action SHALL state direction, magnitude range, window reference and side effects; a suggestion SHALL never be a bare number. | TC-053 |

### 5.3 Knowledge integrity (O-3)
| ID | Requirement | Verification |
|---|---|---|
| SEC-M20 | Every cause SHALL cite a source; import SHALL refuse entries without one. | TC-003 probe 6, TC-060 |
| SEC-M21 | Approval SHALL require role ≥ engineer and a person other than the author. | TC-062 |
| SEC-M22 | Approved versions SHALL be immutable; a change is a new version; retired versions are kept. | TC-003 probe 10, TC-063 |
| SEC-M23 | Ranking SHALL use approved versions only. | TC-003 probe 7, TC-050 |
| SEC-M24 | Every KB, scoring, prompt or model change SHALL run the golden set before activation. | TC-070 |
| SEC-M25 | Knowledge write-back SHALL happen only for verified causes with a computed effective/not-effective outcome. | TC-058 |

### 5.4 Transparency (O-4)
| ID | Requirement | Verification |
|---|---|---|
| SEC-M30 | The stored score of every cause SHALL equal the scoring function over its stored components and the session's weights. | TC-003 probe 11, TC-051 |
| SEC-M31 | The dialogue model SHALL receive only the schema-validated facts object; its output SHALL never change a component, a score, or a suggestion. | TC-006, TC-056 |
| SEC-M32 | Dialogue text SHALL pass the moulding term check; a JA session is reviewed by a native speaker before release (AC-08). | TC-066 |
| SEC-M33 | Effectiveness SHALL be computed from the before/after test; an asserted value SHALL be refused. | TC-003 probe 5, TC-057 |

### 5.5 Attribution and ingestion integrity (O-5)
| ID | Requirement | Verification |
|---|---|---|
| SEC-M40 | A part on a cavity the mould does not have, or an image outside the alignment tolerance, SHALL be refused. | TC-003 probes 1, 3; TC-022 |
| SEC-M41 | The attribution method SHALL be stored per part and its accuracy measured per method (≥ 98 %). | TC-024 |
| SEC-M42 | The gateway SHALL authenticate with a service token bound to `gateway_rw` (insert-only); shots SHALL be idempotent on `shot_id`. | TC-014, TC-113 |
| SEC-M43 | Batch reconciliation SHALL account for every buffered shot (`inserted + duplicates = buffered`). | TC-014 |
| SEC-M44 | Setpoint changes SHALL be captured from the controller with the controller user; manual entries SHALL name a person. | TC-015 |
| SEC-M45 | Frozen frames, enclosure over-temperature and a review rate above threshold SHALL alert. | TC-104, TC-105 |

### 5.6 Locality and hygiene (O-6)
| ID | Requirement | Verification |
|---|---|---|
| SEC-M50 | Gateways SHALL sit on the machine network only; camera/edge on the isolated camera network; analytics, model and data on `internal` without egress. | TC-004, TC-111 |
| SEC-M51 | Images SHALL be served by signed URLs (15 min) and never included in notifications or bus messages. | TC-064 |
| SEC-M52 | Containers non-root, read-only root fs, `cap_drop ALL`, `no-new-privileges`; secrets in files (0400); ports on `BIND_ADDR`. | TC-004, TC-113 |
| SEC-M53 | Role separation in the database: `gateway_rw` insert-only, `vision_rw`, `kb_rw`, `agent_ro` without users/scope/connections. | TC-003, TC-113 |

### 5.7 RBAC matrix
| Action | Viewer | Technician / mould maintenance (inspector) | Process / quality engineer | Manager | Admin |
|---|---|---|---|---|---|
| View shots, cavity analysis, deltas, drift, golden run, sessions | ✅ | ✅ | ✅ | ✅ | ✅ |
| Review low-confidence detections; record startup events; record manual parameter changes | ❌ | ✅ | ✅ | ✅ | ✅ |
| Start an RCA session; answer; mark advice done; record actions; request effectiveness | ❌ | ✅ | ✅ | ✅ | ✅ |
| Verify a cause; close a session; hand off the 8D | ❌ | ❌ | ✅ | ✅ | ✅ |
| Author setup sheets, windows, KB versions | ❌ | ❌ | ✅ | ❌ | ✅ |
| Approve setup sheets / KB versions (not the author) | ❌ | ❌ | ✅ | ✅ | ✅ |
| Machine connections, node maps, scoring config, models, config | ❌ | ❌ | ❌ | ❌ | ✅ |
| Write a machine setpoint through MoldMind | **nobody** | | | | |

## 6. Security testing
| Suite | Content |
|---|---|
| TS-0 | probes 1–12; grants; compose isolation; node-map, KB and facts negatives |
| TS-1 | write attempt refused by the OPC-UA server; certificate validation; batch replay/forgery |
| TS-4 / TS-5 | KB import negatives; self-approval; immutability; score transparency; window bypass attempts; check ordering; asserted effectiveness |
| TS-9 | RBAC sweep; egress from every container; camera network isolation; image URL expiry; audit reconstruction |
| Pen test before go-live | goals: write any setpoint through MoldMind's credentials; get an out-of-window suggestion shown as allowed; change an approved KB entry; forge a shot batch; read images from outside the LAN |

## 7. Incident procedures
| Incident | First actions |
|---|---|
| Write attempt logged by the machine's OPC-UA server | stop the gateway; rotate the machine account and certificate; compare the node map checksum; review `audit.log`; treat as a compromise of Z1 |
| Suggestion shown allowed outside the window | `v_suggestion_audit`; if `allowed = true` with a value outside `[lo, hi]` the trigger was bypassed → DB incident; freeze sessions (`SESSIONS_ENABLED=false`); notify technicians |
| KB entry changed without a version | `v_kb_status` and the checksum vs `deploy/kb/*.yaml` in git; restore the approved version; re-run the golden set |
| Cavity misattribution suspected (flags on the wrong cavity) | check the attribution method mix; run the 500-part trial; disable `sequence` attribution until fixed |
| Forged/replayed shots | batch accounting; rotate the gateway service token; compare controller shot counters |
| Image URL leaked | rotate the signing key; `audit.log` shows every open |

## 8. Residual risks
| ID | Risk | Acceptance |
|---|---|---|
| RR-M01 | A technician changes a setpoint at the controller outside any window | captured on the timeline; outside MoldMind's control; accepted |
| RR-M02 | Subtle defects the optics cannot resolve are missed | per-class lighting; classes scoped; accepted |
| RR-M03 | A systematic attribution error below the 2 % gate persists | method mix monitored; accepted |
| RR-M04 | Manual mechanical/heater changes not on any node | manual-entry endpoint; accepted |
| RR-M05 | The KB is right in general and wrong for a new material | evidence write-back; per-family evaluation; accepted |
| RR-M06 | A within-window change still causes another defect | side effects stated; effectiveness measured; accepted |
| RR-M07 | Enclosure failure near the press | rated enclosure, thermal test, monitoring; accepted |

## 9. Traceability
| SRS-11 | SEC |
|---|---|
| C-01, NFR-06 | O-1, SEC-M01…M04, THR-M01 |
| C-02, FR-03, FR-08, AC-02 | O-5, SEC-M40, M41, THR-M06 |
| C-03, FR-19, AI-08, NFR-08 | O-3, SEC-M20…M24, THR-M04, THR-M11 |
| C-04, FR-22, FR-23 | SEC-M11, M13, THR-M03 |
| C-05, AI-09, AC-05 | SEC-M10, M12, THR-M02 |
| FR-04 | SEC-M44, THR-M08 |
| FR-24, FR-25, AC-07 | SEC-M25, M33, THR-M09 |
| AI-05, AI-06 | O-4, SEC-M30, M31, THR-M05 |
| AI-07 | SEC-M24 |
| FR-27, AC-08 | SEC-M32 |
| NFR-05, AC-09 | SEC-M42, M43, THR-M07 |
| NFR-07 | SEC-M45, THR-M12 |
| §2.3 operating environment | O-6, SEC-M50…M53, THR-M10 |

## Appendix A — Review checklist for a MoldMind change
- Does it add any path that could write to the machine? It must not exist — not behind a flag, not "advisory with confirm".
- Does it add a parameter action? It needs direction, range, window reference, side effects, and a check before it.
- Does it change what the dialogue model receives? Only the facts object; re-run the golden set and the term check.
- Does it touch windows, setup sheets or the KB? Source, approver ≠ author, new version.
- Does it change alignment or attribution? Re-run the 500-part trial.
- Does it send anything outside the LAN? Statistics and links only.
