# Security Requirements Specification — MachineSense AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | SEC-06-MachineSense |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Inherits | [SEC-00](../../00-factorybrain-platform/docs/SEC-FactoryBrain-Security-Requirements.md) baseline (TLS, auth, secrets, logging, THR-11 Modbus) |
| Related | [SRS-06](../SRS-MachineSense-Predictive-Maintenance.md) · [SAD-06](SAD-MachineSense-Software-Architecture.md) · [ICD-06](ICD-MachineSense-Interface-Control.md) · [API-06](../api/API-Specification.md) · [TEST-06](TEST-MachineSense-Test-Plan.md) · [OPS-06](OPS-MachineSense-Deployment-Operations.md) |

---

## 1. Scope and what is different here

MachineSense connects to **production machines**. That single fact orders everything: the first security objective is not confidentiality of data but the guarantee that this system **cannot act on a machine** — not through a bug, not through a compromised host, not through a model that "decides" to help. The second is that its judgements can be trusted: an alert's numbers are computed and stored, never rewritten by the model, and a suppressed alert is visible.

### 1.1 Security objectives

| # | Objective | Meaning |
|---|---|---|
| **O-1** | **No write path to any machine** | Read-only OPC-UA accounts enforced server-side; Modbus read function codes only; no tool, endpoint or client code that writes (C-01, C-02) |
| **O-2** | **OT network containment** | Ingest is the only thing that touches the OT segment; it initiates, reads, and cannot be reached from outside; Modbus's lack of security is a stated, accepted risk |
| **O-3** | **Evidence integrity** | Every number in an alert is computed by code and stored; the LLM receives only that and its output is post-checked; nobody edits `evidence_json` |
| **O-4** | **Alert integrity** | No silent suppression (windows are records; suppressed alerts exist); feedback immutable; transitions attributed; baselines and models versioned and gated |
| **O-5** | **Availability independence** | A MachineSense outage — or compromise — never affects machine operation (NFR-07) |
| O-6 | Confidentiality of production data | Telemetry reveals throughput and downtime; access by role; no third-party services |

## 2. Assets

| Asset | Where | Attacker value | Impact |
|---|---|---|---|
| OPC-UA / Modbus credentials and endpoints | secrets files; `config_version` (endpoints) | Reach controllers | Read production data; **with a non-read-only account, control** — hence O-1 |
| MQTT credentials / ACLs | broker | Inject false telemetry | False alerts or masked faults |
| Baselines | `telemetry.baseline` | Normalise a fault | Missed failure |
| Models | `anomaly_model`, artefacts | Weaken detection | Missed failure |
| Alert rules / sensor map | `config_version` | Loosen thresholds; remap signals | Missed failure / alert storms |
| Evidence and feedback | `alert`, `alert_feedback` | Rewrite history | Wrong precision, wrong retraining |
| Telemetry and features | hypertables | Production intelligence | Confidentiality |
| Work-order webhook | CMMS integration | Fake work orders | Wasted maintenance |

## 3. Trust boundaries

```
 Z1 OT ─ machines · DAQ · broker ─┐ read-only, ingest-initiated
                                  ▼
 Z2 ingest hosts (ingest-mqtt/opcua/modbus + local WAL buffer)  ── internal ──► Z3 MachineSense server
                                                                                  (db · workers · api · web · ollama)
                                                                                        ▲ LAN (JWT)         ▲ egress (Discord, SMTP, CMMS webhook)
                                                                                     Z4 users
```
The OT segment has **no route** to Z3/Z4; Z3 reaches Z1 only through the ingest hosts' read-only clients. The LLM is inside Z3 but treated as untrusted content-wise (O-3).

## 4. Threat model

### 4.1 Threats (STRIDE)

| ID | Threat | STRIDE | Obj. | Mitigations |
|---|---|---|---|---|
| THR-P01 | **A write reaches a machine** — via a bug, a "helpful" tool, a compromised ingest host with the OPC-UA credential | Elevation | O-1 | Read-only accounts enforced by the OPC-UA server (not the client); Modbus client built without write FCs; no write tool in the registry (deny-list); sensor-map schema refuses write modes; TC-020 write-refusal test on every onboarded controller (SEC-P10…P14) |
| THR-P02 | **Rogue MQTT publisher** injects telemetry for another machine | Spoofing | O-4 | Per-client credentials; topic ACL to own prefix; unknown signals rejected; anomalies in *rate* flagged (SEC-P30) |
| THR-P03 | **Modbus tampering** (no auth in the protocol) | Tampering | O-2 | Isolated OT segment; ACLs; read-only polling; explicit risk acceptance (SEC-P32; §8) |
| THR-P04 | **Poisoned baseline** captured during degradation, or edited | Tampering | O-4 | Engineer confirmation required (trigger); versioned; re-baseline after service; baseline changes audited (SEC-P40…P42) |
| THR-P05 | **Model substitution or regression** | Tampering | O-4 | Versioned models with artefact hash; promotion gated by metrics (trigger); retrain runs recorded (SEC-P43) |
| THR-P06 | **Threshold loosening / signal remapping** via config | Tampering | O-4 | Schema-validated, versioned config; engineer/admin only; every alert stamps the config version; precision report reveals drift (SEC-P44) |
| THR-P07 | **Prompt injection through alarm text, maintenance notes or CSV** | Tampering | O-3 | The model receives evidence values, not free text from machines; alarm text and notes are quoted as data; post-check on numbers and certainty language; tools read-only (SEC-P50…P53) |
| THR-P08 | **Narrative alters the numbers** (model rounds, invents, "corrects") | Repudiation | O-3 | Post-check withholds; `evidence_json` immutable after open; card rendered from evidence, not narrative (SEC-P51) |
| THR-P09 | **Silent suppression** — a window declared to hide a problem, or alerts dropped | Repudiation | O-4 | Windows are rows with declarer; suppressed alerts stored and visible; `alerts_enabled` changes audited (SEC-P45, P46) |
| THR-P10 | **Feedback rewritten** to inflate precision | Repudiation | O-4 | `alert_feedback` immutable (trigger); transitions logged (SEC-P47) |
| THR-P11 | **Fake work orders** to the CMMS | Spoofing | — | Planner role; HMAC-signed webhook; idempotent by draft id; never automatic (SEC-P60) |
| THR-P12 | **Ingest host compromise** | Elevation | O-1, O-2 | Blast radius = read access to machines + inject telemetry; credentials read-only; host hardened; ingest role INSERT-only in the DB (SEC-P31, P33) |
| THR-P13 | **Production intelligence leak** (throughput from `rpm`, downtime from alarms) | Info disclosure | O-6 | Roles; `agent_ro` scoped; no third-party SDKs; exports audited (SEC-P70…P72) |
| THR-P14 | **DoS on ingest** (flood) | DoS | O-5 | Rate limits per client at the broker; buffer bounds; **machines unaffected regardless** |
| THR-P15 | **Time manipulation** (NTP) shifts evidence | Tampering | O-3 | Skew > 5 s → data-quality event; receive time stored alongside |

### 4.2 The attack worth walking through — "use MachineSense to stop the press"

An attacker has a foothold on the plant LAN and wants to halt Injection press B.

1. *Through the API.* There is no endpoint that touches a machine; the closest is `/workorders/{id}/export`, which sends a draft to the CMMS — a human still schedules any work.
2. *Through the agent.* "Stop M-07 now" → the tool registry has only read tools; no `opcua_write` exists and the deny-list refuses registering one; the model can only propose a work order.
3. *Through the ingest host.* The attacker obtains the OPC-UA credential. It is a **read-only account**; a write returns `BadUserAccessDenied` from the controller — TC-020 proves it on every controller at onboarding. The Modbus client has no write function codes compiled in; the register maps are read-only.
4. *Through the data.* Injecting telemetry that looks like an imminent failure could trigger an alert and a technician inspection — a nuisance, not a stop: alerts are advisory, and the technician's feedback (`false_positive`, "sensor reading inconsistent with hand-held probe") records it. MQTT ACLs and unknown-signal rejection make even that require a valid per-machine credential.

The system's inability to act is structural (O-1), not a policy.

## 5. Security requirements

Format `SEC-Pxx` — requirement — verification.

### 5.1 No write path (C-01, C-02)
| ID | Requirement | TC |
|---|---|---|
| SEC-P10 | OPC-UA accounts used by MachineSense SHALL be read-only **enforced by the server**; a write attempt SHALL be refused by the controller | TC-020 |
| SEC-P11 | `ingest-opcua` and `ingest-modbus` SHALL contain no write code path (static analysis: no `write_value`, no FC 5/6/15/16) | TC-100 |
| SEC-P12 | The sensor-map schema SHALL refuse `access: write` and write function codes | TC-006 |
| SEC-P13 | The tool registry SHALL contain no write tool; names matching `write|control|set_|command` SHALL be refused | TC-101 |
| SEC-P14 | No API operation SHALL result in a request to a machine (audit of every outbound call from Z3: only to Discord, SMTP, CMMS webhook, ingest hosts) | TC-102 |

### 5.2 OT containment
| ID | Requirement | TC |
|---|---|---|
| SEC-P30 | MQTT: per-client credentials; ACL to own topic prefix; wildcard subscribe only for ingest; unknown signals rejected and recorded | TC-011, TC-103 |
| SEC-P31 | Ingest hosts SHALL be the only members of the OT-facing network; no route from Z1 to Z3/Z4; ingest initiates all connections | TC-104 |
| SEC-P32 | Modbus SHALL be used only inside an isolated OT segment with ACLs; the risk SHALL be recorded and signed by the plant | TC-105, §8 |
| SEC-P33 | The database role for ingest (`telemetry_ingest`) SHALL be INSERT-only on samples/alarms/data-quality; it cannot read alerts, users or config | TC-003 (grants), TC-106 |
| SEC-P34 | OPC-UA sessions and rejected operations SHALL be audited with account and endpoint (NFR-06) | TC-021 |
| SEC-P35 | OT credentials SHALL live in secrets files (0400), referenced by name in the sensor map; `config_version.content_json` SHALL never contain them and SHALL be unreadable to `agent_ro` | TC-107 |

### 5.3 Baselines, models, configuration
| ID | Requirement | TC |
|---|---|---|
| SEC-P40 | A baseline SHALL become active only with an engineer's confirmation and a ≥ 4-week window (trigger) | TC-003, TC-120 |
| SEC-P41 | `agent_ro` SHALL not read `core.app_user`, `core.user_line_scope`, `audit.*` or `telemetry.config_version` | TC-003 |
| SEC-P42 | Baseline activation, re-baseline flags and `alerts_enabled` changes SHALL be audited | TC-108 |
| SEC-P43 | Model promotion SHALL require retrospective metrics ≥ the active version (trigger); artefact hash recorded | TC-003, TC-127 |
| SEC-P44 | Sensor map and alert rules SHALL be schema-validated, versioned with a hash, and stamped on every alert | TC-006, TC-138 |
| SEC-P45 | Maintenance windows SHALL be records with a declarer; alerts inside them SHALL be stored as `suppressed` (trigger), never dropped | TC-003, TC-133 |
| SEC-P46 | Disabling alerts for a machine SHALL be an audited engineer action with a reason | TC-108 |
| SEC-P47 | `alert_feedback` SHALL be immutable; every alert status change SHALL be logged with actor and channel | TC-003, TC-135 |

### 5.4 Evidence and the model (AI-08, FR-23, FR-26)
| ID | Requirement | TC |
|---|---|---|
| SEC-P50 | The model SHALL receive only the `AlertEvidence` object, baselines, attribution, similar cases and production context — never raw series, alarm free text or notes as instructions | TC-080 |
| SEC-P51 | Every numeric token in a narrative SHALL match an evidence value (rounded); otherwise the narrative SHALL be withheld and `GROUNDING_FAILED` recorded | TC-081, AC-04 |
| SEC-P52 | The narrative SHALL not state causes as certain (lexicon check) and SHALL carry a likelihood | TC-082 |
| SEC-P53 | Free text from machines and users (alarm text, maintenance notes, CSV cells) SHALL be quoted as data in any prompt; an injection corpus SHALL cause zero tool calls beyond the read set and zero unbacked numbers | TC-083 |
| SEC-P54 | `evidence_json` SHALL not be modified after the alert opens (application rule; audited) | TC-084 |

### 5.5 People-facing and export
| ID | Requirement | TC |
|---|---|---|
| SEC-P60 | Work orders SHALL never be posted automatically; export requires planner+; webhook HMAC-signed; idempotent by draft id | TC-061, TC-062 |
| SEC-P61 | Discord/email cards SHALL contain no OT endpoints, credentials or raw series | TC-072 |
| SEC-P62 | Discord identities SHALL be mapped by an admin; unmapped users read-only | TC-073 |

### 5.6 Confidentiality and availability
| ID | Requirement | TC |
|---|---|---|
| SEC-P70 | Roles: viewer (read), technician (ack/snooze/escalate/resolve, maintenance events), planner (+ work-order export, windows), engineer (+ baselines, models, rules, failures), admin (+ sensor map, users) | TC-109 |
| SEC-P71 | No third-party service SHALL receive telemetry, alerts or narratives (NFR-09-style, inherited from SEC-00) | TC-102 |
| SEC-P72 | Exports (CSV, PDF) SHALL be audited with user and scope | TC-110 |
| SEC-P73 | Loss of any MachineSense component SHALL not affect machines (NFR-07): no machine-side dependency exists | TC-111 |

### 5.7 RBAC matrix
| Action | Viewer | Technician | Planner | Engineer | Admin |
|---|---|---|---|---|---|
| View health, charts, alerts, risks | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ack / snooze / escalate / resolve with feedback | ❌ | ✅ | ✅ | ✅ | ✅ |
| Record maintenance events | ❌ | ✅ | ✅ | ✅ | ✅ |
| Declare maintenance windows; export work orders | ❌ | ❌ | ✅ | ✅ | ✅ |
| Propose / confirm baselines; re-baseline; label failures; promote models; alert rules | ❌ | ❌ | ❌ | ✅ | ✅ |
| Sensor map (OT endpoints), users, Discord mapping, retention | ❌ | ❌ | ❌ | ❌ | ✅ |
| Write to a machine | **nobody — no path exists** | | | | |

## 6. Security testing
| Test | TC |
|---|---|
| OPC-UA write refused by every onboarded controller with the MachineSense account | TC-020 |
| Static scan of ingest code for write calls / function codes; registry for write tools | TC-100, TC-101 |
| Egress capture from Z3 for 1 h | TC-102 |
| MQTT: publish to another machine's topic → refused; unknown signal → rejected + event | TC-011, TC-103 |
| Network: from Z1 attempt to reach Z3 → blocked; from Z4 attempt to reach Z1 → blocked | TC-104 |
| DB grants: `telemetry_ingest` cannot SELECT alerts; `agent_ro` cannot SELECT `config_version` | TC-106 |
| Baseline / model / feedback / suppression triggers | TC-003 |
| Injection corpus (alarm text, notes, CSV) | TC-083 |
| Grounding: narrative with an invented number withheld | TC-081 |

## 7. Incident procedures
| Event | Immediate | Then |
|---|---|---|
| OPC-UA credential exposed | Rotate on the controller (still read-only); revoke sessions; review audit for unusual reads | Re-run TC-020 |
| Ingest host compromised | Isolate host; rotate all OT credentials; check for injected telemetry (rate anomalies, unknown-signal events) | Rebuild host from image |
| False telemetry suspected | Mark affected windows via a data-quality event; suppress scoring for the range; inform technicians | Re-baseline if the baseline window was affected |
| Baseline or rules changed without review | Revert to the previous version (`config_version`); audit | Access review |
| Grounding failures spike | Model/prompt regression; roll back `prompt_version` | Corpus re-run |

## 8. Residual risks
| Risk | Why it remains | Owner |
|---|---|---|
| **Modbus has no authentication** | Protocol limitation; mitigated by segmentation only; signed risk acceptance | Plant IT/OT |
| A read-only account still reveals production intelligence | Reading is the product | Plant |
| An OPC-UA server misconfigured with write rights for the account | Outside MachineSense; TC-020 at onboarding and quarterly | Controls |
| Injected plausible telemetry causes a false alert | Advisory system; feedback records it | Maintenance |
| Small local models may misphrase likelihood | Post-check lexicon; structured assessment always present | ML owner |

## 9. Traceability
| SRS-06 | SEC-P |
|---|---|
| C-01 | P10…P14 |
| C-02, NFR-06 | P10, P34, P35 |
| C-04, AI-04 | P51 (RUL interval in narrative), DDS gates |
| C-05, AI-05 | DDS DD-P01 (referenced) |
| FR-08, AI-01, AI-07 | P40, P42 |
| FR-14 | P45 |
| FR-19, FR-20 | P47 |
| FR-21 | P60 |
| FR-23, FR-26, AI-08 | P50…P53 |
| AI-06 | P43 |
| NFR-05 | ingest buffer (ICD-06 IF-04) |
| NFR-07 | P73 |
| AC-04 | P51 |
| AC-06 | P45 |

## Appendix A — Review checklist for a MachineSense change
- [ ] Does it add any outbound call toward Z1? It must be read-only and initiated by ingest (P10–P14, P31).
- [ ] Does it touch baselines, models, rules or windows? Versioned, gated, audited (P40–P47).
- [ ] Does it put anything new in front of the model? Evidence values only; free text quoted as data (P50, P53).
- [ ] Does it change what a card or export shows? No endpoints/credentials/raw series (P61).
- [ ] Does it introduce a dependency a machine could notice? It must not (P73).
