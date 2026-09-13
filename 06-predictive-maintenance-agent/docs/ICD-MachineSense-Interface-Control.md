# Interface Control Document — MachineSense AI Predictive Maintenance Agent

| Field | Value |
|---|---|
| Document ID | ICD-06-MachineSense |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Scope | Every interface of MachineSense: the machine-side protocols (MQTT, OPC-UA, Modbus, DAQ features, files), the people-side channels (Discord, email/webhook, CMMS), the LLM, metrics, the agent tool contract and the platform |
| Related | [SRS-06](../SRS-MachineSense-Predictive-Maintenance.md) · [SAD-06](SAD-MachineSense-Software-Architecture.md) · [API-06](../api/API-Specification.md) · [SEC-06](SEC-MachineSense-Security-Requirements.md) · [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) (IF-04/05/06/08/09/13/14/16/19 originals) |

---

## 1. Scope and register

`IF-xx` numbers are shared across the repository (00: 01–19; 02: 20–21; 03: 22–24; 04: 25–29; 05: 30–35). MachineSense describes the machine-side protocols in depth — they are where its data comes from and where its **advisory-only** constraint is enforced — and adds three.

| IF | Interface | MachineSense role | New |
|---|---|---|---|
| **IF-04** | MQTT telemetry and alarms | Subscriber (ingest) | — (in depth) |
| **IF-05** | OPC-UA machine data | Read-only client — **the C-01/C-02 enforcement point** | — (in depth) |
| **IF-06** | Modbus TCP | Polling client (read function codes only) | — (in depth) |
| IF-08 | Discord | Alert cards with ack/snooze/escalate; feedback prompt | — |
| IF-09 | LLM runtime | Evidence-only prompts; post-check | — |
| IF-13 | SMTP / webhook | Alert delivery | — |
| IF-14 | Metrics | Ingest rate, lags, buffer depth | — |
| IF-16 | Agent tool contract | MachineSense tools | — |
| IF-19 | Platform integration | Platform mode | — |
| **IF-36** | CSV / Parquet import | Consumer | ✅ |
| **IF-37** | CMMS / work-order export | Producer | ✅ |
| **IF-38** | Vibration DAQ feature contract | Consumer | ✅ |

**Zones.** Z1 OT (machines, DAQ, brokers on the machine segment) → Z2 ingest hosts → Z3 MachineSense server → Z4 users. All Z1 connections are **initiated by ingest, read-only**; nothing in Z2/Z3 can write to Z1.

---

## IF-04 — MQTT telemetry and alarms {#if-04}

**Parties.** Machine gateways / DAQ → broker (`mosquitto`, on the ingest host or the OT segment) → `ingest-mqtt`. Platform baseline: [ICD-00 IF-04](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-04) (topics and payloads unchanged).

| Aspect | Contract |
|---|---|
| Topics | `factory/{plant}/{machine}/telemetry/{signal}` (QoS 0), `factory/{plant}/{machine}/alarm` (QoS 1), `factory/{plant}/{machine}/features/{signal}` (QoS 0, IF-38), `factory/{plant}/{machine}/event` (QoS 1) |
| Payload | `{ ts, value, unit?, quality }`; `quality` OPC-UA style (192 = Good); ts RFC 3339 with offset; Sparkplug B accepted via a decoder that maps metrics to the same shape |
| Rates | ≤ 1 Hz per telemetry signal (FR-02 "configured rate"); features per DAQ window (1–60 s); alarms immediate |
| Validation | Machine and signal must exist in the sensor map; unknown → `data_quality_event` (`unknown_signal`), dropped; unit mismatch → stored with `quality = 64` (Uncertain) and an event |
| Checks (FR-03) | Gap: no sample for > 3 × expected interval; stuck: N = 30 identical values; range: outside the signal's physical range; skew: `|ts − receive_ts| > 5 s` (NFR-09) — each a `data_quality_event`, never silently dropped except out-of-range (value stored with `quality = 0`, Bad) |
| Buffer (NFR-05) | Local SQLite WAL queue per ingest process, fsync per 5,000-row batch; ≥ 24 h at the process's share of 50 k/s; replay in order; `(sensor_id, ts)` PK makes replay idempotent |
| Broker outage | Publishers are fire-and-forget; ingest reconnects with backoff (1 → 60 s); a data-quality event marks the gap; **no effect on machines** |
| Security | Per-client credentials; ACL: each publisher only its own `factory/{plant}/{machine}/#`; ingest has wildcard subscribe; TLS on the platform side; plaintext only inside an isolated OT segment (SEC-P31) |

**Verification.** TC-010…TC-016.

---

## IF-05 — OPC-UA machine data (read-only) {#if-05}

**Parties.** Machine controller (server) → `ingest-opcua` (client). Platform baseline: [ICD-00 IF-05](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-05).

> **This is where C-01 and C-02 are enforced.** The account MachineSense uses is created on the controller with **read-only** rights (browse + read + subscribe), enforced by the OPC-UA server — not by the client choosing not to write. `ingest-opcua` contains no write code path; the sensor map schema refuses `access: write`; TC-020 attempts a write with the account and expects `BadUserAccessDenied`.

| Aspect | Contract |
|---|---|
| Endpoint, security | `opc.tcp://…:4840`, `Basic256Sha256` / `SignAndEncrypt`; client certificate trusted explicitly on the controller |
| Account | `machinesense_ro` per machine (or per controller), read-only, documented in the sensor map as `credential_ref` (secrets file, never the map) |
| Node map | Per machine in `sensors.yaml`: `node_id`, `signal`, `unit`, `sampling_ms`, `deadband`; validated at startup — an unresolvable node id is a startup error, not a silent null |
| Subscription | Publishing interval 1,000 ms; monitored items with the configured sampling interval; deadband to suppress noise; keep-alive 10 s |
| Status codes | Stored with the value (`quality` column); `Bad*` → `quality = 0`; `Uncertain*` → 64; a run of Bad > 5 min → sensor health `offline` |
| Reconnect | Exponential backoff to 60 s; session loss > 5 min → alert on MachineSense itself (OPS-06 §6) |
| Context tags | A PLC status tag (e.g. `ns=2;s=Machine.State`) may feed the context classifier (`context_rule` expression), still read-only |
| Audit (NFR-06) | Every session open/close and every rejected operation logged with account and endpoint |

**Verification.** TC-020…TC-024 (incl. write refused; node-id validation; 1 h outage reconciliation).

---

## IF-06 — Modbus TCP {#if-06}

**Parties.** Legacy device → `ingest-modbus` (polling). Platform baseline: [ICD-00 IF-06](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-06).

| Aspect | Contract |
|---|---|
| Function codes | **3 and 4 only** (read holding / input registers). Function codes 5, 6, 15, 16 (writes) are absent from the client build and refused by the sensor map schema (C-01) |
| Register map | `address, count, type (uint16/int16/uint32/float32), word_order, scale, offset, signal, unit` per register — word order explicit, verified against the device display at commissioning (TC-030) |
| Poll | 1–5 s per device; response timeout 1 s; 3 retries → `offline` and a data-quality event |
| Stuck detection | Constant value across N = 30 polls → `stuck` event (a frozen register is the classic silent failure) |
| Security | None in the protocol — permitted **only** inside an isolated OT segment with network ACLs; explicit risk acceptance (SEC-P32, SEC-06 §8) |

**Verification.** TC-030…TC-032.

---

## IF-38 — Vibration DAQ feature contract {#if-38}

**Parties.** Edge DAQ device (accelerometers, ≥ 10 kHz sampling) → MQTT `features/{signal}` topic → `ingest-mqtt`. This is the interface that makes C-03 real: **raw waveforms never cross the plant network**.

### Payload (per window)
```json
{ "ts": "2026-09-10T07:59:00+07:00", "window_s": 10, "rpm_ref": 1450, "sensor": "vib_ds",
  "rms": 4.9, "peak": 14.2, "kurtosis": 3.4, "crest": 2.9,
  "bands": { "1x": 0.8, "2x": 1.1, "3x": 0.3, "bpfo": 0.21, "bpfi": 0.12, "hf_10k_20k": 0.05 },
  "quality": 192, "daq": { "id": "DAQ-07", "fw": "2.3.1", "fs_hz": 25600 } }
```
Each field becomes a `feature` row (`name` = `rms`, `kurtosis`, `crest`, `band_1x`, `band_2x`, `band_bpfo`, …; `window_s` from the payload) for the sensor `vib_rms_ds` (RMS also stored as a `sample` for charting). Band definitions are **RPM-referenced** (orders), so they stay comparable across speed changes; the DAQ receives the RPM reference from the same machine's `rpm` tag or the sensor map's nominal RPM.

### Snapshots
On request (`event` topic `snapshot_request` with a window id) or automatically on the first alert per incident, the DAQ publishes a short raw waveform (≤ 2 s, ≤ 1 MB, gzip) to `features/{signal}/snapshot` → stored in object storage (platform IF-10 in platform mode; local volume standalone) and linked from the alert's evidence. Never continuous.

### Rules
- Feature windows ≥ 1 s and ≤ 60 s; ≥ 1 window/min.
- Missing `rpm_ref` → bands stored but marked `quality = 64` and excluded from baselines.
- DAQ firmware version recorded per row (`daq.fw` → `feature` is keyed by sensor/ts/window/name; the version lives in `sensor_health.detail` and the sensor map).

**Verification.** TC-040…TC-043 (payload validation; band naming; snapshot size cap; RPM reference missing).

---

## IF-36 — CSV / Parquet import {#if-36}

**Parties.** Historian export / manual file → `POST /telemetry/import` → `import` worker.

| Aspect | Contract |
|---|---|
| Columns | `ts` (RFC 3339 or `YYYY-MM-DD HH:MM:SS` with `tz` parameter), `signal`, `value`, optional `quality` (default 192); one machine per file (`machine` parameter) |
| Validation | Signals must exist in the sensor map; ts monotonic not required; duplicates within the file collapsed; rows conflicting with stored `(sensor_id, ts)` are skipped and counted |
| Size | ≤ 500 MB per file; Parquet preferred above 50 MB |
| Quality | Same gap/stuck/range/skew checks as live ingest, attributed to `source = csv` |
| Outcome | Job record with `rows_detected / inserted / skipped / rejected`; features and scoring backfill for the imported range (marked `backfill = true` in the job) |

**Verification.** TC-050, TC-051.

---

## IF-37 — CMMS / work-order export {#if-37}

**Parties.** MachineSense → CMMS (webhook) or PDF (share). Drafts are **never posted automatically** (FR-21).

| Aspect | Contract |
|---|---|
| Trigger | `POST /workorders/{id}/export` by a planner (or admin) |
| Webhook | `POST {CMMS_WEBHOOK_URL}` JSON: `{ draft_id, machine_code, symptom, priority, due_within_days, tasks[], parts[], evidence_summary, alert_url, idempotency_key = draft_id }`; HMAC-SHA256 signature header; 2xx → `exported_at`, `export_ref` from the response body (`{ workorder_id }`); non-2xx → 502 `CMMS_EXPORT_FAILED`, draft kept, retry manual |
| PDF | Machine, symptom, evidence table (the alert's numbers), attribution, recommended inspection steps, similar case, versions; TH/JA/EN with embedded fonts |
| Idempotency | Same `draft_id` → the CMMS must return the same `workorder_id`; MachineSense refuses a second export of an exported draft (409) |
| Security | Outbound only; webhook URL from configuration; secret in a file; the CMMS never calls MachineSense |

**Verification.** TC-060…TC-062.

---

## IF-08 — Discord {#if-08}

Platform baseline: [ICD-00 IF-08](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-08).

### Alert card (FR-16, FR-19)
```
⚠️ M-07 Injection press B · HIGH · health 61/100 · incident #… (drive-side bearing)
Bearing temp (DS)  78.4 °C · baseline 68.9 ± 2.1 · +13.8 % / 5 d · σ 4.5
Vib RMS (DS)        4.9 mm/s · baseline 2.9 ± 0.9 · σ 2.2 · rising 6 days
Motor current       within baseline
Top features: bearing_temp_mean · vib_rms · vib_band_2x
Inspect within 3 days: lubrication + hand-held temp · vibration spectrum (BPFO/BPFI) · coupling alignment
RUL 12–30 days (80 %, 3 prior comparable failures)
[Acknowledge] [Snooze 24 h] [Escalate] [Explain] [Chart]
```
Every number on the card comes from `evidence_json` (the card renderer is deterministic; no model text). The **Explain** button calls `/agent/explain` and posts the narrative in a thread (or "explanation withheld — numbers could not be verified" with the structured recommendation). A new violation on the same incident **edits** the card (severity may rise) — no duplicate posts (FR-18). Closing prompts for feedback (true/false positive/unknown + finding) and refuses to close without it (FR-20).

Commands: `/machine <code>` (health + open incidents), `/risks` (top risks this week), `/ask <question>`, `/ack <id>`, `/snooze <id> <hours>`, `/escalate <id>`, `/resolve <id>`.

Identity: Discord user → `core.app_user` mapping; unmapped users read only. Never posted: OT endpoints, credentials, raw series.

**Verification.** TC-070…TC-074.

---

## IF-09 — LLM runtime {#if-09}

Platform baseline: [ICD-00 IF-09](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-09). MachineSense specifics:

| Aspect | Contract |
|---|---|
| Input | **Only** the `AlertEvidence` object, the baselines used, the attribution, similar cases and production context (AI-08). Never a series, never a table of samples |
| Prompt | Versioned (`prompt_version`); instructs: cite every number from the evidence; hypotheses with likelihood; verification steps; never certainty language; language TH/JA/EN |
| Output | Structured JSON (`Explanation` schema) + narrative |
| Post-check | Numeric tokens ↔ evidence values (rounded); certainty-language lexicon; unmatched → narrative withheld, `GROUNDING_FAILED` recorded on the agent run |
| Caps | 30 s per call; ask: ≤ 6 tool calls / 60 s |
| Degraded mode | Alerts, cards, charts and structured recommendations do not depend on the LLM; `/readyz.llm=false` |

---

## IF-13 — SMTP and webhook {#if-13}
Alert delivery in addition to Discord: email (TLS, app password file) with the same card content; generic webhook (JSON, HMAC) for the plant's own tools. Retried thrice; failures logged; never blocks alerting.

---

## IF-14 — Metrics {#if-14}
`/metrics` (Prometheus): `ms_ingest_samples_total{source}`, `ms_ingest_lag_seconds`, `ms_buffer_depth_rows{process}`, `ms_feature_lag_seconds`, `ms_scoring_lag_seconds`, `ms_alerts_opened_total{severity}`, `ms_alerts_suppressed_total`, `ms_precision_30d{machine}`, `ms_llm_breaker_state`. Scraped on the internal network only.

---

## IF-16 — Agent tool contract (MachineSense tools) {#if-16}

Inherits the platform rules ([ICD-00 IF-16](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-16)): typed, schema-validated, read-only, run as `agent_ro`, results with digest and row count, **no free-form SQL**.

| Tool | Returns | Notes |
|---|---|---|
| `get_machine_telemetry(machine, signal, window)` | series summary (n, mean, min, max, last, baseline band) — **not raw points** to the model | platform tool, reused |
| `get_machine_health(machine)` | health now, 7-day drop, components, open incidents | new |
| `get_alert_evidence(alert_id)` | the `AlertEvidence` object | new |
| `list_top_risks(limit)` | `v_top_risks_week` rows | new |
| `list_failures(machine?, failure_mode?, since?)` | failure events with lead times | new |
| `get_trend(machine, signal, days)` | slope with CI, pct change | new |
| `search_memory(text, top_k)` | similar past cases (Genba Memory, SRS-15) | platform tool (FR-24); standalone: local `alert_group.incident_summary` search |

Permanently absent: any write tool, any OPC-UA/Modbus access, raw SQL (ADR-P09).

---

## IF-19 — Platform integration {#if-19}
Platform mode: same containers, platform database (`telemetry` schema + migration `machinesense_0001`), platform auth, platform Ollama with the GPU semaphore, tools registered into the platform registry, alerts also written as `quality.signal` rows for QE-Agent, `v_top_risks_week` read by KaizenSwarm's Maintenance Agent, closed incidents filed to Genba Memory. Standalone → platform migration: OPS-06 §9.

---

## 2. Interface matrix

| IF | Direction | Auth | Encryption | MachineSense survives failure? | Machine affected by MachineSense failure? |
|---|---|---|---|---|---|
| IF-04 MQTT | in | per-client + ACL | TLS (plant side) | ✅ 24 h buffer; gaps recorded | **never** |
| IF-05 OPC-UA | out (read-only) | read-only account, cert | SignAndEncrypt | ✅ reconnect | **never** (no write path) |
| IF-06 Modbus | out (read FC 3/4) | none (isolated segment) | none | ✅ | **never** |
| IF-38 DAQ | in | as IF-04 | as IF-04 | ✅ | never |
| IF-36 import | in (file) | JWT | TLS | ✅ | n/a |
| IF-37 CMMS | out | HMAC | TLS | ✅ draft kept | n/a |
| IF-08 / IF-13 | out | tokens | TLS | ✅ retried | n/a |
| IF-09 LLM | internal | none (isolation) | — | ✅ degraded mode | n/a |
| IF-19 | internal | platform | — | ✅ | n/a |

## 3. Change control

| Change | Requires |
|---|---|
| Sensor map (nodes, registers, contexts, derived) | Schema validation; version bump; `config_version` row; node-id/register verification (TC-022, TC-030); an OPC-UA account change is a controls change |
| Alert rules (thresholds, N, weights, ladder) | Schema validation; version bump; precision report review; the version is on every alert (`config_version`) |
| Baseline | Engineer confirmation; version; re-baseline after service |
| Model | Metrics-gated promotion; version on every score and alert |
| DAQ firmware | Feature names and band definitions must remain; `sensor_health.detail` records fw |
| Discord card layout | UM-06 update |

## 4. Traceability

| SRS-06 | Interface |
|---|---|
| FR-01, FR-02 | IF-04, IF-05, IF-06, IF-36 |
| FR-03, NFR-09 | IF-04 checks (all sources) |
| FR-04 (FFT bands) | IF-38 |
| FR-05 | IF-05 context tags, IF-16 |
| FR-07 | IF-04 alarm topic, IF-05 alarm nodes |
| FR-16, FR-19, FR-20 | IF-08 |
| FR-21 | IF-37 |
| FR-23…FR-26, AI-08 | IF-09, IF-16 |
| FR-24 | IF-16 `search_memory` |
| C-01, C-02, NFR-06 | IF-05 (read-only enforced server-side, audited), IF-06 (read FCs only) |
| C-03 | IF-38 |
| NFR-05 | IF-04 buffer |
| NFR-07 | §2 matrix last column |
