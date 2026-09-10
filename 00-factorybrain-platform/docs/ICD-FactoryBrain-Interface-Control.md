# Interface Control Document — FactoryBrain AI Platform

| Field | Value |
|---|---|
| Document ID | ICD-00-FactoryBrain |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS §5](../SRS-FactoryBrain-AI-Platform.md), [SAD §4.1](SAD-FactoryBrain-Software-Architecture.md) |

---

## 1. Purpose and scope

This document specifies every interface across a FactoryBrain **system boundary** — where the platform meets equipment, other systems, external services or its own physically separate components. Each interface has a stable `IF-xx` identifier used by the [Test Plan](TEST-FactoryBrain-Test-Plan.md) and the [Security Requirements](SEC-FactoryBrain-Security-Requirements.md).

Purely internal function calls inside one deployment unit are **not** interfaces and are not listed here. Two exceptions are included because they are contracts even though they are internal: the agent tool contract (IF-16) and the inter-agent message bus (IF-17). Both are consumed by independently-developed components and both are versioned.

### 1.1 Interface register

| ID | Interface | Parties | Protocol | Criticality |
|---|---|---|---|---|
| [IF-01](#if-01) | Edge node ↔ Platform sync | Edge node, API | HTTPS/JSON | **Critical** |
| [IF-02](#if-02) | Industrial camera | Camera, edge node | GenICam / USB3 Vision | **Critical** |
| [IF-03](#if-03) | PLC digital I/O | Edge node, PLC | 24 V DC discrete | **Critical** |
| [IF-04](#if-04) | MQTT telemetry | Machines/gateway, Ingest | MQTT 3.1.1/5 | High |
| [IF-05](#if-05) | OPC-UA machine data | Machine controller, Ingest | OPC-UA binary | High |
| [IF-06](#if-06) | Modbus TCP | Legacy device, Ingest | Modbus TCP | Medium |
| [IF-07](#if-07) | ERP adapter | DocFlow, ERP | REST/SOAP/table/file | **Critical** |
| [IF-08](#if-08) | Discord | Notifier, Discord | WSS + HTTPS | Medium |
| [IF-09](#if-09) | LLM runtime | AI Gateway, Ollama | HTTP/JSON | High |
| [IF-10](#if-10) | Object storage | Services, MinIO | S3 API | High |
| [IF-11](#if-11) | Mobile sync | PocketQC, API | HTTPS/JSON | High |
| [IF-12](#if-12) | Farm IoT & weather | Sensors/API, GAPFarm | MQTT / HTTPS | Low |
| [IF-13](#if-13) | SMTP & webhook | Notifier, mail/endpoint | SMTP / HTTPS | Low |
| [IF-14](#if-14) | Metrics scrape | Prometheus, services | HTTP/text | Medium |
| [IF-15](#if-15) | Barcode scanner | Scanner, HMI | USB HID | Medium |
| [IF-16](#if-16) | Agent tool contract | Agent runtime, tools | In-process typed | **Critical** |
| [IF-17](#if-17) | Inter-agent bus | Specialist agents, Manager | NATS / Redis Streams | Medium |

### 1.2 Specification template
Each interface below specifies: parties and direction · protocol and transport · data format · timing · error and retry behaviour · security · versioning · verification method.

---

## IF-01 — Edge node ↔ Platform sync {#if-01}

**Parties.** Edge node (SRS-03) → Platform API. Node-initiated only; the platform never connects *to* a node.

> Direction matters: edge nodes sit in a lower-trust network zone (SAD §4.5.3). Making the connection outbound-only means no inbound firewall rule into the edge zone is required, and a compromised platform cannot reach into the OT-adjacent network.

**Protocol.** HTTPS 1.1/2, JSON. Endpoints `POST /edge/records:batch`, `POST /edge/images`, `GET /edge/config`, `POST /edge/heartbeat`.

**Data format.** See `InspectionCreate` and `BatchResult` in [`openapi.yaml`](../api/openapi.yaml).

```json
{
  "node_code": "L3-ST3",
  "records": [
    { "id": "0192f0a1-0000-7000-8000-000000000001",
      "ts": "2026-09-09T14:00:30+07:00",
      "line": "L3", "sku": "RAD-500-A", "station": "ST3",
      "lot": "LOT-2609-114", "verdict": "FAIL",
      "model_version": "defect-yolo11s:1.0.0", "latency_ms": 98,
      "detections": [ { "class_name": "MISSING_COMPONENT", "confidence": 0.91,
                        "bbox": {"x":120,"y":240,"w":86,"h":74} } ] }
  ]
}
```

**Timing.**
| Aspect | Value |
|---|---|
| Batch size | ≤ 500 records |
| Sync interval | 30 s when online; immediate on FAIL |
| Image upload | Lower priority; optional bandwidth window (e.g. 22:00–05:00) |
| Heartbeat | Every 60 s |
| Offline tolerance | **≥ 72 h**, ≥ 100 k buffered records |

**Error and retry.** At-least-once delivery; server deduplicates by record `id`, making the effect exactly-once. `207 Multi-Status` per record; `duplicate` is a success outcome. Exponential backoff 1 s → 5 min on 5xx. **A record is deleted from the local buffer only after a non-`rejected` outcome is received** — this is the property that makes "no data loss" true rather than aspirational.

**Security.** mTLS client certificate preferred; `X-Edge-Key` per node otherwise. Credential grants insert-only access scoped to that node (DB role `edge_ingest`). Keys rotatable without redeployment (OPS RB-04).

**Versioning.** API major version in the path. Nodes tolerate unknown response fields. A node running an older minor version must remain able to sync — an edge fleet cannot be upgraded atomically.

**Verification.** [TC-061…TC-068](TEST-FactoryBrain-Test-Plan.md): 72 h disconnection with zero loss; duplicate batch produces no duplicate rows; partial-batch rejection does not block the rest.

---

## IF-02 — Industrial camera {#if-02}

**Parties.** Camera → edge node capture service. Terminates entirely at the edge; no image data crosses this interface to the platform in real time.

**Protocol.** GenICam over GigE Vision or USB3 Vision. CSI for Jetson-attached sensors. Access via a GenTL producer or `v4l2`.

**Data format.** Mono8 / BayerRG8 / BGR8 raw frames plus a metadata block: frame ID, device timestamp, exposure, gain, trigger source.

**Timing.**
| Aspect | Value |
|---|---|
| Trigger | Hardware (preferred), software, or free-run |
| Trigger-to-first-byte | ≤ 20 ms |
| Frame rate | ≥ 10 fps sustained at working resolution |
| Jitter tolerance | ≤ 5 ms on hardware trigger |

**Error and retry.** Disconnection detected within **10 s** and raised as an alarm. A camera returning byte-identical consecutive frames is treated as failed — a frozen sensor otherwise produces a stream of confident PASS verdicts, which is the most dangerous failure mode in the system. Frames failing the focus/exposure gate become `NO_READ`, never silent PASS.

**Security.** Camera network is isolated (zone Z1/Z2). Default credentials must be changed at commissioning. No camera is exposed to the platform zone.

**Versioning.** Camera model and firmware recorded in `vision.camera`. **Changing camera or lens invalidates the pixel-to-mm calibration and may invalidate the model** — it requires re-calibration and re-validation, not just a config edit.

**Verification.** TC-021…TC-024: trigger jitter measured over 1 h; disconnect detected ≤ 10 s; frozen-frame detection; calibration repeatability ≤ ±0.2 mm over 30 repeats.

---

## IF-03 — PLC digital I/O {#if-03}

**Parties.** Edge node → PLC (verdict signal); PLC → edge node (part-present trigger, optional).

> **Safety boundary.** FactoryBrain is advisory (SRS §1.2). This interface communicates a *judgement*; the PLC decides what to do with it. FactoryBrain is not a safety-rated function and must never be the sole means of preventing a hazard.

**Protocol.** 24 V DC discrete I/O via GPIO with opto-isolation, or an I/O module. MQTT (IF-04) is an acceptable soft alternative where latency permits.

**Signals.**

| Signal | Direction | Meaning |
|---|---|---|
| `READY` | node → PLC | Node healthy, model loaded, accepting triggers |
| `PASS` | node → PLC | Part judged good |
| `FAIL` | node → PLC | Part judged bad |
| `REVIEW` | node → PLC | Needs human judgement (route to review lane) |
| `FAULT` | node → PLC | Node cannot judge — **fail-safe state** |
| `TRIGGER` | PLC → node | Part in position |

**Timing.**

```
TRIGGER   ──┐__________________________________
            │
            │◄── t_infer ≤ 150 ms ──►│
            │                        │
PASS/FAIL ______________________┌────────────┐________
                                │◄─ 200 ms ─►│  pulse
            │◄──── t_total ≤ 200 ms p95 ────►│
```
Verdict pulse width 200 ms (configurable); one verdict per trigger; a missing verdict within the timeout must be treated by the PLC as `FAULT`.

**Error and retry.** There is no retry — this is a real-time signal. On any internal failure the node asserts `FAULT` and de-asserts `READY`. **The interface is fail-safe: absence of a verdict must never be interpreted as PASS.** The PLC program is responsible for enforcing that, and the commissioning checklist verifies it.

**Security.** Physical wiring; no logical authentication. Protection is physical access control to the panel.

**Versioning.** Signal assignment is fixed per installation and documented in the panel drawing. Changing it requires a controlled change with PLC re-validation.

**Verification.** TC-025…TC-027: latency distribution over 1,000 triggers; `FAULT` asserted on model unload; PLC correctly holds the line when verdict is absent.

---

## IF-04 — MQTT telemetry {#if-04}

**Parties.** Machine gateways / edge nodes → Ingest (subscriber). Platform → nodes for verdict mirroring (optional).

**Protocol.** MQTT 3.1.1 or 5.0. TLS on the platform side; plain permitted only inside an isolated OT segment.

**Topic taxonomy.**
```
factory/{plant}/{line}/{station}/verdict      QoS 1   retained: no
factory/{plant}/{line}/{station}/health       QoS 0   retained: yes
factory/{plant}/{machine}/telemetry/{signal}  QoS 0   retained: no
factory/{plant}/{machine}/alarm               QoS 1   retained: no
factory/{plant}/{machine}/event               QoS 1   retained: no
```

**Payloads.**
```json
// telemetry/{signal}
{ "ts": "2026-09-10T06:00:00+07:00", "value": 78.4, "unit": "degC", "quality": 192 }

// alarm
{ "ts": "...", "code": "OVL-01", "severity": "HIGH", "text": "Overload", "active": true }
```

`quality` follows the OPC-UA convention (192 = Good) so a value can be trusted or discarded on its own merits.

**Timing.** Telemetry ≤ 1 Hz per signal (higher rates must be reduced to features at the gateway — see IF-05 note); health every 60 s; alarms immediate.

**Error and retry.** QoS 0 for telemetry: a lost sample is acceptable and gaps are detected and recorded as `ops.data_quality_event`. QoS 1 for alarms and verdicts. Ingest buffers ≥ 24 h if the database is unavailable. **Broker outage must not stall a machine** — publishers are fire-and-forget.

**Security.** Per-client credentials, ACL restricting each publisher to its own topic prefix. Wildcard subscribe is granted only to the ingest service.

**Versioning.** Topic structure is a contract. New fields may be added to payloads; existing fields never change meaning. A breaking change uses a new topic level (`.../telemetry2/...`).

**Verification.** TC-071…TC-074: gap detection; unauthorised publish to another machine's topic rejected; 24 h ingest buffering.

---

## IF-05 — OPC-UA machine data {#if-05}

**Parties.** Machine controller (server) → Ingest (client). **Read-only session.**

**Protocol.** OPC-UA binary (`opc.tcp`), subscription with monitored items. Euromap 77 companion specification for injection moulding (SRS-11).

**Node mapping.** Configured per machine, not hard-coded:
```yaml
machine: M-07
endpoint: opc.tcp://10.20.3.7:4840
security: Basic256Sha256 / SignAndEncrypt
credential: opcua_readonly          # read-only account, enforced server-side
nodes:
  - node_id: "ns=2;s=Injection.HoldingPressure"
    signal: holding_pressure
    unit: bar
  - node_id: "ns=2;s=Injection.Cushion"
    signal: cushion
    unit: mm
  - node_id: "ns=2;s=Cycle.Time"
    signal: cycle_time
    unit: s
```

**Timing.** Publishing interval 1000 ms default; sampling interval per item; per-shot parameters delivered on cycle completion. Session keep-alive 10 s; reconnect with backoff.

**Error and retry.** Reconnect with exponential backoff, capped at 60 s. Bad/Uncertain status codes are stored with the value, not discarded — a sensor reporting `Uncertain` is information. Session loss > 5 min raises an alert.

**Security.** `SignAndEncrypt` with `Basic256Sha256`; client certificate trusted explicitly on the machine. **The account is read-only, enforced at the OPC-UA server** — not merely by the client choosing not to write. This is the enforcement point for SRS §1.2 "no machine control".

> High-rate vibration data (≥ 10 kHz) is **not** transported over this interface. It is reduced to features (RMS, kurtosis, FFT bands) at a dedicated DAQ/edge device, which publishes features via IF-04. Moving raw waveforms across the plant network is neither necessary nor affordable.

**Versioning.** Node IDs change between controller firmware versions. The mapping file is versioned and validated at startup; an unresolvable node ID is a startup error, not a silent null.

**Verification.** TC-075…TC-078: write attempt refused by the server; node-ID validation on startup; reconnect after a 1 h outage with buffered shots reconciled.

---

## IF-06 — Modbus TCP {#if-06}

**Parties.** Legacy device → Ingest (polling client).

**Protocol.** Modbus TCP, port 502, function codes 3 (holding) and 4 (input registers).

**Register map.** Explicitly configured, including scaling and word order — the most common source of Modbus integration errors is an undocumented byte order:
```yaml
machine: M-11
unit_id: 1
registers:
  - address: 40001, count: 2, type: float32, word_order: big, signal: motor_current, unit: A
  - address: 40010, count: 1, type: uint16,  scale: 0.1,      signal: temperature,   unit: degC
```

**Timing.** Poll 1–5 s; response timeout 1 s; 3 retries then mark offline.

**Error and retry.** Exception responses logged with code. A register reading a constant value across `N` polls raises a stuck-value data-quality event.

**Security.** Modbus has **no authentication or encryption**. It is permitted only inside an isolated OT segment with network-level access control. This is stated plainly so it is a conscious risk acceptance rather than an oversight — see [SEC THR-11](SEC-FactoryBrain-Security-Requirements.md).

**Verification.** TC-079: scaling and word order verified against a known reference value on the device display.

---

## IF-07 — ERP adapter {#if-07}

**Parties.** DocFlow (SRS-08) → ERP. **The only outbound write path in the platform.**

**Protocol.** Pluggable adapter; one of REST/JSON, SOAP/XML, staging table (direct SQL insert), or CSV/XML file export.

**Contract.** Every adapter implements:
```python
class ErpAdapter(Protocol):
    def find_open_po(self, po_number: str) -> PO | None: ...
    def find_goods_receipt(self, po_number: str) -> list[GR]: ...
    def lookup_item(self, part_no: str) -> Item | None: ...
    def lookup_supplier(self, tax_id: str | None, name: str) -> Supplier | None: ...
    def create_purchase_order(self, doc: PurchaseOrder, idem_key: str) -> ErpRef: ...
    def create_invoice(self, doc: Invoice, idem_key: str) -> ErpRef: ...
```

**`idem_key` is mandatory in the contract.** An adapter that cannot honour it must implement idempotency itself (for example, by checking for an existing document reference before creating). A duplicated purchase order is a real financial event, and network retries are routine.

**Timing.** Synchronous call, 30 s timeout. Lookups cached 5 min. Posting is queued, not inline with the HTTP request that approved it.

**Error and retry.** Failure leaves state `posting_failed` — **never half-posted**. Retry with exponential backoff, max 5 attempts, then the exception queue for human handling. `UNIQUE (adapter, idem_key)` in the database is the last line of defence (DDS §10.1).

**Security.** Dedicated service account with the minimum ERP privileges required. Credentials in secrets, rotated per policy. All postings audited with the approving user.

**Preconditions (enforced, not assumed).** A posting requires: state `approved`, a recorded approval by a sufficient role, and — above the configured amount — an approver distinct from the field editor.

**Verification.** TC-081…TC-085: 5 retries produce exactly one ERP transaction; posting without approval rejected; segregation-of-duties violation rejected.

---

## IF-08 — Discord {#if-08}

**Parties.** Notifier ↔ Discord. Outbound: briefs, alerts. Inbound: slash commands.

**Protocol.** Discord Gateway (WSS) for commands; REST/webhook for posting.

**Commands.** `/brief [date] [lang]`, `/ask <question>`, `/kpi <line> <period>`, `/approve <id>`, `/deny <id>`, `/status`.

**Message contract.** Every AI-generated message carries its sources and, where relevant, the AI-generated label. Approval prompts render as an embed showing the **exact action and arguments** with Approve/Deny buttons — an approval request that does not show what is being approved is not an approval.

**Timing.** Briefs on cron (default 07:00). Alerts immediate. `/ask` acknowledged within 3 s (Discord's interaction deadline) with a deferred response; the real answer follows.

**Error and retry.** Respect `429` with `Retry-After`. Gateway reconnect with backoff. **Discord is not a system of record** — an undelivered brief is still retrievable in the dashboard, and delivery failure never blocks the underlying process.

**Security.** Bot token in secrets. Channel allow-list. Discord identity is mapped to a platform user for authorisation; **an unmapped Discord user has no permissions** — chat presence is not authentication.

**Versioning.** Discord API version pinned; deprecation notices monitored.

**Verification.** TC-051…TC-054: scheduled brief for 7 consecutive days; approval buttons bound to `args_hash`; unmapped user cannot approve.

---

## IF-09 — LLM runtime {#if-09}

**Parties.** AI Gateway → Ollama (default) or an OpenAI-compatible endpoint.

**Protocol.** HTTP/JSON, `/api/chat` with tool definitions; streaming supported.

**Request contract.**
```json
{
  "model": "qwen3:8b",
  "messages": [ { "role": "system", "content": "<versioned template>" },
                { "role": "user",   "content": "<question + facts object>" } ],
  "tools": [ /* JSON Schema per tool */ ],
  "options": { "temperature": 0.2, "num_ctx": 8192 },
  "stream": true
}
```

**Timing.** First token ≤ 3 s; complete answer ≤ 20 s p95 (NFR-03). Hard wall-clock cap per turn (default 60 s). **Requests serialise through the GPU semaphore** (ADR-011); queue wait is measured and exported separately from inference time, so a slow answer can be attributed correctly.

**Error and retry.** One retry on transport error. On unavailability the gateway returns `503 MODEL_UNAVAILABLE` and the platform continues in **degraded mode** — dashboards, SPC, review queue and reports all work without the model. `/readyz` reports `degraded`, not `not_ready`.

**Security.** Local, in-cluster, **not exposed outside the platform zone**. Using an external provider is an explicit, logged, feature-flagged admin action because it changes where factory data goes (SRS C-01).

**Prompt-injection boundary.** Content retrieved from documents, logs or machine data is inserted as **data, never as instructions**. Text inside retrieved content that resembles an instruction is not followed. This is a property of the gateway's prompt assembly and is tested adversarially (TC-095).

**Versioning.** Model name and tag pinned per deployment and recorded on every `agent.run`. Prompt templates versioned in git (`prompt_version`). Changing either requires re-running the golden set before release.

**Verification.** TC-041…TC-046, TC-095: grounding gate; degraded-mode behaviour; injection resistance.

---

## IF-10 — Object storage {#if-10}

**Parties.** All services → MinIO (S3 API).

**Buckets.**
| Bucket | Contents | Lifecycle |
|---|---|---|
| `evidence` | Inspection images and overlays | PASS 30 d → thumbnail; FAIL/REVIEW 2 y |
| `documents` | Source business and quality documents | 7 y |
| `reports` | Generated PDF/PPTX | 1 y |
| `models` | Model artefacts and manifests | Retained while referenced |
| `backups` | Database dumps | 90 d |

**Access.** Services use scoped credentials per bucket. **Clients never receive storage credentials** — images are delivered as short-lived signed URLs (default 15 min).

**Timing.** Upload ≤ 2 s for a 2 MB image; signed URL generation < 50 ms.

**Error and retry.** Retry with backoff. **The record is written to the database first; the image is uploaded second.** An inspection with a missing image is a degraded record; an image with no record is an orphan. Losing the record is worse, so ordering favours the record.

**Security.** Private ACL on every object; TLS in transit; encryption at rest via the underlying volume. Signed URLs are short-lived and not logged in full.

**Verification.** TC-101: signed URL expires; direct object access without a signature is refused.

---

## IF-11 — Mobile sync {#if-11}

**Parties.** PocketQC (SRS-05) → Platform API.

**Protocol.** HTTPS/JSON. `GET /mobile/bootstrap`, `POST /mobile/sessions:batch`, resumable image upload.

**Conflict rule.** Server wins for **master data** (checklists, SKUs, defect codes). Device wins for **inspection records** — the server never silently changes a verdict an inspector recorded.

**Timing.** Sync on Wi-Fi by default; manual trigger available. Offline capacity ≥ 5,000 records. Bootstrap uses ETag; unchanged returns `304`.

**Error and retry.** At-least-once with UUIDv7 dedup, as IF-01. `WorkManager` constraints survive process death and network changes. Images upload after records.

**Security.** User JWT with an offline validity window (default 30 days cached token). Device data encrypted at rest. Remote wipe on next connect for a lost device.

**Verification.** TC-066…TC-068: airplane-mode session capture, sync with zero duplicates, resumed after force-kill.

---

## IF-12 — Farm IoT and weather {#if-12}

**Parties.** Soil/climate sensors → GAPFarm (SRS-12); weather provider → GAPFarm.

> **Scope note.** GAPFarm is a **separate deployment** (SAD §6, DDS §3.1). This interface is documented for completeness of the sibling set; it does not connect to the factory platform.

**Protocol.** MQTT for sensors (`farm/{farm}/{zone}/{signal}`); HTTPS REST for the weather provider, response cached ≥ 30 min.

**Timing.** Sensors 5–15 min. Weather refresh hourly. Sensor offline > 1 h raises a maintenance task.

**Error and retry.** Weather API failure degrades gracefully: advisories that need a forecast are suppressed with a stated reason rather than computed on stale data. Sensor faults (stuck, out-of-range) raise data-quality events.

**Security.** Per-device credentials. The weather API key is a secret. **This is the one interface with a legitimate internet dependency** in the whole document set, and it is in a system that is not part of the factory platform.

**Verification.** TC-121: sensor stuck-value detection; advisory suppressed when forecast unavailable.

---

## IF-13 — SMTP and webhook {#if-13}

**Parties.** Notifier → mail server / arbitrary webhook endpoint.

**Protocol.** SMTP with STARTTLS; HTTPS POST with an HMAC-SHA256 signature header for webhooks.

**Timing.** Best-effort, queued, 3 retries with backoff.

**Error and retry.** Delivery failure is logged and surfaced in the admin UI. **Never blocks the originating process** — a report is generated and stored whether or not the email is delivered.

**Security.** Credentials in secrets. Recipient allow-list to prevent the platform being used to send arbitrary mail. Webhook payloads are signed so the receiver can verify origin.

**Verification.** TC-055: webhook signature verification; recipient outside the allow-list rejected.

---

## IF-14 — Metrics scrape {#if-14}

**Parties.** Prometheus → each service `/metrics`.

**Protocol.** HTTP, OpenMetrics text format. Scrape interval 15 s.

**Core metrics.**
```
factorybrain_http_request_duration_seconds{route,method,status}
factorybrain_inspection_total{line,verdict}
factorybrain_inspection_latency_ms{line,station}
factorybrain_agent_run_total{outcome}          # outcome includes grounding_failed
factorybrain_agent_latency_seconds{stage}      # stage: queue_wait | inference
factorybrain_gpu_semaphore_wait_seconds
factorybrain_edge_buffer_depth{node}
factorybrain_edge_heartbeat_age_seconds{node}
factorybrain_ingest_rows_quarantined_total{source}
factorybrain_posting_attempts_total{adapter,status}
```

`factorybrain_agent_run_total{outcome="grounding_failed"}` is the operational expression of the platform's core integrity property. A rising rate is an incident (OPS RB-09).

**Security.** `/metrics` bound to the internal network only; no authentication inside the platform zone, never exposed externally. Metrics carry no personal data and no free-text content.

**Verification.** TC-111: all documented metrics present and non-empty after a synthetic workload.

---

## IF-15 — Barcode scanner {#if-15}

**Parties.** USB HID scanner → edge HMI or mobile app.

**Protocol.** HID keyboard emulation, configured with a terminating character (CR).

**Data.** Code 128 / QR containing lot, part number or work order. Format validated against a configured pattern; an unrecognised code prompts rather than silently proceeding with a wrong SKU.

**Timing.** Scan-to-field < 200 ms.

**Error and retry.** Unparseable scan shows an error and requests a re-scan. Manual entry is permitted but flagged in the record, since it is a common source of transcription error.

**Verification.** TC-035: 20 sample labels auto-select the correct checklist; malformed code rejected.

---

## IF-16 — Agent tool contract {#if-16}

**Parties.** Agent runtime → tool implementations. Internal, but a **versioned contract** consumed by independently-developed sibling modules.

**Contract.** Every tool is typed, JSON-Schema-validated, read-only by default, permission-filtered and idempotent.

```
query_production(date_from, date_to, line?, sku?, shift?)  -> rows
query_defects(date_from, date_to, group_by)                -> rows
get_spc(characteristic, line?, window?)                    -> chart data + violations
get_machine_telemetry(machine_id, signal, window)          -> series
search_memory(text, top_k?)                                -> past cases
get_inspection_images(record_ids)                          -> signed URLs
create_draft_report(type, payload)                         -> draft_id   [write, HITL]
send_discord(channel, message)                             -> ok         [write, rate-limited]
```

**Rules.**
1. Arguments are validated against the schema **before** execution. An invalid call is rejected, not "repaired" by the model.
2. Read tools execute as DB role `agent_ro`, which cannot read `core.app_user` or `core.user_line_scope`.
3. The caller's line scope is applied as a **query predicate**, not as post-filtering.
4. Write tools never execute directly — they create an `action_proposal` requiring approval.
5. Results carry `row_count` and a digest so the grounding check has ground truth.
6. **There is no free-form shell or SQL tool.** Adding a capability requires a new typed tool and code review (ADR-005).

**Timing.** Per-tool timeout 10 s; per-turn budget 5 tool calls / 60 s wall clock, enforced by the executor.

**Versioning.** Tool schemas are versioned; removing or narrowing a parameter is breaking and requires re-running the golden set.

**Verification.** TC-041…TC-048: schema rejection of malformed calls; scope predicate enforcement; write tool cannot bypass approval.

---

## IF-17 — Inter-agent message bus {#if-17}

**Parties.** Manager agent ↔ specialist agents (SRS-13).

**Transport.** NATS subjects (preferred) or Redis Streams. Introduced only when KaizenSwarm is built (ADR-008).

**Subjects.**
```
agent.request.{agent}     RequestAssessment
agent.finding.{agent}     Finding
agent.status.{agent}      StatusUpdate | Error
orchestrator.run.{run_id} run lifecycle
```

**Message types.** Typed and JSON-Schema-validated. `Finding` requires a non-empty `evidence` array — enforced both at the schema and in the database (`agent.finding.finding_has_evidence`).

**Timing.** Per-agent timeout 60 s; full run ≤ 3 min. Budgets enforced by the orchestrator, not by agent cooperation.

**Error and retry.** One retry on malformed output, then the agent is recorded as failed. **A failed agent degrades the briefing to `partial` with a named reason — it never fails the whole run**, and never silently omits a domain.

**Rules.**
- Agents communicate only through typed messages; there is no shared mutable state and no free-form agent-to-agent chat.
- Specialists stay in their domain. Cross-domain inference is the Manager's job alone.
- The Manager may aggregate, relate and rank; it may **not** invent findings.

**Verification.** TC-131…TC-135: killing one agent yields a `partial` briefing with the other domains intact; malformed output retried once then recorded as an error; Manager output contains no claim absent from specialist findings.

---

## 2. Interface matrix

| Interface | Crosses trust boundary | Authenticated | Encrypted | Survives outage | Idempotent |
|---|---|---|---|---|---|
| IF-01 Edge sync | Z2→Z3 | mTLS / key | TLS | ✅ 72 h buffer | ✅ UUID dedup |
| IF-02 Camera | Z1→Z2 | Device cred | ❌ (isolated) | ✅ local | n/a |
| IF-03 PLC I/O | Z2→Z1 | Physical | ❌ (wired) | ✅ fail-safe | n/a |
| IF-04 MQTT | Z1/Z2→Z3 | Per-client + ACL | TLS on Z3 | ✅ 24 h buffer | ⚠️ QoS 0 telemetry |
| IF-05 OPC-UA | Z1→Z3 | Cert + read-only acct | Sign & Encrypt | ✅ reconnect | ✅ per-shot key |
| IF-06 Modbus | Z1→Z3 | ❌ **none** | ❌ **none** | ✅ poll resumes | n/a |
| IF-07 ERP | Z3→external | Service account | TLS | ✅ retry queue | ✅ `idem_key` + DB constraint |
| IF-08 Discord | Z3→internet | Bot token | TLS | ✅ non-blocking | ⚠️ at-least-once |
| IF-09 LLM | in-zone | — | in-cluster | ✅ degraded mode | ✅ stateless |
| IF-10 Object store | in-zone | Scoped creds | TLS | ✅ retry | ✅ by key |
| IF-11 Mobile | Z4→Z3 | JWT | TLS | ✅ offline queue | ✅ UUID dedup |
| IF-12 Farm IoT | separate system | Per-device | TLS | ✅ | ✅ |
| IF-13 SMTP/webhook | Z3→external | Creds / HMAC | STARTTLS / TLS | ✅ non-blocking | ⚠️ at-least-once |
| IF-14 Metrics | in-zone | ❌ (internal only) | ❌ | ✅ | ✅ read-only |
| IF-15 Barcode | local | Physical | ❌ | ✅ manual entry | n/a |
| IF-16 Agent tools | in-process | Role predicate | n/a | ✅ | ✅ |
| IF-17 Agent bus | in-zone | in-cluster | in-cluster | ✅ partial briefing | ✅ by run id |

**The two rows worth arguing about:**

**IF-06 Modbus** has no authentication and no encryption. This is inherent to the protocol, not a shortcut. It is acceptable only because the interface lives inside an isolated OT segment with network-level access control, and because it is read-only telemetry whose corruption would produce implausible values that data-quality checks catch. Recorded as an accepted risk in [SEC](SEC-FactoryBrain-Security-Requirements.md), not as a satisfied control.

**IF-04 telemetry at QoS 0** deliberately allows message loss. Guaranteed delivery of a 1 Hz temperature reading is not worth blocking a publisher on a machine. Gaps are detected and recorded, so lost data is *visible* rather than silently interpolated.

---

## 3. Change control

| Change | Requires |
|---|---|
| New field in an existing payload | Minor version; consumers must tolerate unknown fields |
| Removing or renaming a field | **Major version**; deprecation for ≥ 2 release cycles |
| New MQTT topic or OPC-UA node | Config change + startup validation |
| Camera, lens or lighting change (IF-02) | **Re-calibration and model re-validation** — not a config edit |
| PLC signal reassignment (IF-03) | Controlled change + PLC re-validation + updated panel drawing |
| New agent tool (IF-16) | Schema + permission predicate + golden-set re-run |
| ERP adapter change (IF-07) | Idempotency test must pass before release |

---

## 4. Traceability

| SRS item | Interface |
|---|---|
| §5.2 hardware interfaces | IF-02, IF-03, IF-15 |
| §5.3 communications | IF-01, IF-04, IF-05, IF-08, IF-13 |
| §3.2 agent tool contract | IF-16 |
| FR-P-03 edge push over HTTPS + key | IF-01 |
| FR-P-04 MQTT / OPC-UA telemetry | IF-04, IF-05 |
| FR-U-03 Discord brief and `/ask` | IF-08 |
| FR-A-07 write-tool approval gating | IF-16 rule 4, IF-08 approval embed |
| NFR-04 edge survives server loss | IF-01 buffering, IF-03 fail-safe |
| NFR-06 security in transit | Matrix §2 |
| NFR-11 observability | IF-14 |
| C-01 local inference | IF-09 |
| SRS-08 C-04 no double posting | IF-07 `idem_key` |
| SRS-13 C-02 evidence required | IF-17 message schema |
