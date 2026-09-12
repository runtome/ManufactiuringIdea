# Interface Control Document — VisionOps (AI Factory Inspector Agent)

| Field | Value |
|---|---|
| Document ID | ICD-01-VisionOps |
| Version | 1.0 (Draft) |
| Date | 2026-09-11 |
| Author | Suphot N. |
| Status | Draft for review |
| Implements | [SRS-01 §4](../SRS-AI-Factory-Inspector-Agent.md), [SAD-01 §4.1](SAD-VisionOps-Software-Architecture.md) |
| Platform relationship | `IF-xx` numbering is **shared with [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md)** so cross-references hold; IF-18 and IF-19 are new here |

---

## 1. Scope and register

Every interface across a VisionOps system boundary. Where an interface is identical to the platform's, this document states what VisionOps *adds* (usually: more detail, because VisionOps is where the hardware actually lives) and links the platform entry for the rest.

| ID | Interface | Parties | Protocol | Criticality | vs ICD-00 |
|---|---|---|---|---|---|
| [IF-01](#if-01) | Edge ↔ server sync | Edge node, API | HTTPS/JSON | **Critical** | Identical |
| [IF-02](#if-02) | Industrial camera | Camera, edge | GenICam / USB3 / CSI | **Critical** | **Expanded** |
| [IF-03](#if-03) | PLC digital I/O | Edge, PLC | 24 V discrete | **Critical** | **Expanded** |
| [IF-04](#if-04) | MQTT verdict mirror | Edge, broker | MQTT | Low | Subset |
| [IF-08](#if-08) | Discord | Notifier, Discord | WSS/HTTPS | Medium | Identical |
| [IF-09](#if-09) | LLM runtime | Narrative agent, Ollama | HTTP/JSON | High | Narrowed |
| [IF-10](#if-10) | Object storage | Services, MinIO | S3 | High | **Expanded** (evidence ordering) |
| [IF-14](#if-14) | Metrics | Prometheus, services | HTTP | Medium | VisionOps metric set |
| [IF-15](#if-15) | SKU / lot identity | Scanner or PLC tag, edge | HID / tag | High | **Expanded** |
| [IF-16](#if-16) | Narrative agent tools | Agent, tools | In-process typed | **Critical** | **VisionOps tool set** |
| [IF-18](#if-18) | Light / strobe controller | Edge, controller | GPIO / serial | Medium | **New** |
| [IF-19](#if-19) | Platform integration | VisionOps, FactoryBrain | Shared DB + mounted API | High | **New** |

Not applicable to VisionOps: IF-05 OPC-UA, IF-06 Modbus, IF-07 ERP, IF-11 mobile (platform), IF-12 farm, IF-13 SMTP (optional, platform-identical), IF-17 agent bus.

---

## IF-01 — Edge ↔ server sync {#if-01}

**Identical to [ICD-00 IF-01](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-01).** Node-initiated HTTPS; at-least-once batches ≤ 500; server dedup on client UUIDv7; `207` per-record outcomes; local row deleted only after a non-`rejected` outcome; images after records; heartbeat 60 s; mTLS or `X-Edge-Key`.

**What VisionOps adds to the payload** (all optional, all in `InspectionCreate`):

| Field | Purpose |
|---|---|
| `image_sha256` | Evidence integrity; verified on `/edge/images` upload |
| `anomaly` `{score, threshold, flagged}` | Anomaly fallback result |
| `recipe_version` | Reproducibility (C-03) — which rule set judged this part |
| `ocr_text` | Decoded lot/part marking; **treated as untrusted text** downstream (SEC-01) |

**What VisionOps adds to `GET /edge/config`:** `calibrations[]` (per camera, with `valid` and `hardware_fingerprint`), `stations[]` (trigger mode, PLC I/O map), `sync.pass_image_sample_rate`.

**Offline tolerance:** ≥ 24 h on the VisionOps minimum hardware (NFR-03); 72 h on EdgeGuard reference hardware.

**Verification:** TC-061…TC-066.

---

## IF-02 — Industrial camera {#if-02}

**Parties.** Camera → edge capture service (E1). Terminates at the edge; the server never receives live video.

**Protocol.** GenICam via a GenTL producer (GigE Vision or USB3 Vision), or V4L2/CSI on Jetson. Vendor SDK (Basler pylon, FLIR Spinnaker, Hikrobot MVS) wrapped behind one capture interface.

### GenICam features used

| Feature | Setting | Why |
|---|---|---|
| `TriggerMode` / `TriggerSource` | `On` / `Line1` (hardware) or `Software` | Deterministic part-in-position capture |
| `TriggerActivation` | `RisingEdge` | Matches PLC pulse |
| `ExposureTime` | Fixed per station (e.g. 800 µs) | Motion blur budget; **never auto** — auto-exposure defeats drift detection |
| `Gain` | Fixed | Same reason |
| `PixelFormat` | `Mono8` or `BayerRG8` | Bandwidth; colour only if a defect class needs it |
| `Width/Height/OffsetX/OffsetY` | ROI | Reduces bandwidth and inference cost |
| `ChunkModeActive` + `ChunkTimestamp`, `ChunkFrameID` | On | Frame ID and device timestamp travel with the image |
| `AcquisitionFrameRateEnable` | Off under trigger | Trigger governs rate |
| `LineSelector/LineMode/LineSource` | Strobe output = `ExposureActive` | Drives IF-18 light sync |

### Bandwidth budget

| Link | Sustained | Frame 2448×2048 Mono8 | Max fps |
|---|---|---|---|
| GigE (1 Gb/s) | ~110 MB/s | 5.0 MB | ~22 |
| USB3 (5 Gb/s) | ~350 MB/s | 5.0 MB | ~70 |
| CSI-2 (Jetson, 4-lane) | ~1.5 GB/s | — | sensor-limited |

VisionOps requires ≥ 10 fps sustained (NFR-02). GigE at full resolution has little headroom; use ROI or a USB3 camera where takt is tight.

**Timing.** Trigger-to-first-byte ≤ 20 ms; jitter ≤ 5 ms; frame complete ≤ 15 ms at 2448×2048 over USB3.

**Error handling.**
| Condition | Detection | Response |
|---|---|---|
| Disconnected | Heartbeat/`GetNodeMap` failure | Alarm within **10 s**; `FAULT` on IF-03; `camera_state: disconnected` |
| **Frozen feed** | Two consecutive frames with identical SHA-256 | Treated as failed; `camera_state: frozen`; `FAULT`. A frozen camera otherwise emits confident PASS forever — the most dangerous failure in the system |
| Missed trigger | Trigger count from PLC ≠ frame count | Data-quality event; alarm if > 1 % |
| Quality-gate fail | Blur variance / exposure out of range | `NO_READ`, never PASS |
| Chunk timestamp skew vs host | > 50 ms drift | Data-quality event; NTP check |

**Security.** Isolated camera segment (Z1/Z2). Default camera credentials changed at commissioning. No camera reachable from Z3.

**Versioning and change control.** Camera model, serial, firmware, lens and mount id form the `hardware_fingerprint` on `vision.calibration`. **Any change invalidates the calibration and requires model re-validation** — this is a controlled change, not a config edit.

**Verification.** TC-011…TC-016.

---

## IF-03 — PLC digital I/O {#if-03}

**Parties.** PLC → edge (`TRIGGER`, optional `PART_PRESENT`); edge → PLC (`READY`, `PASS`, `FAIL`, `REVIEW`, `FAULT`).

> **Safety boundary.** VisionOps is advisory. It communicates a *judgement*; the PLC decides what to do with it. VisionOps is not a safety-rated function and must never be the sole means of preventing a hazard (SRS-01 §1.2).

**Protocol.** 24 V DC discrete, opto-isolated, via GPIO or an I/O module. Signal assignment lives in `vision.station.plc_io_json` and **must match the panel drawing**.

### Signals

| Signal | Dir | Level semantics |
|---|---|---|
| `READY` | edge → PLC | **Level.** High = node healthy, model loaded, calibration valid, accepting triggers |
| `TRIGGER` | PLC → edge | **Pulse** ≥ 5 ms rising edge = part in position |
| `PASS` / `FAIL` / `REVIEW` | edge → PLC | **Pulse**, `pulse_ms` (default 200); exactly one of the three per trigger |
| `FAULT` | edge → PLC | **Level.** High = cannot judge; PLC must treat the line accordingly |

### Timing diagram

```
TRIGGER   ───┐_____________________________________________________
             │
             │  grab   gate   infer      rules  store
             │ ≤15ms  ≤5ms   ≤100ms     ≤5ms   ≤10ms
             │◄───────────── t_verdict ≤ 200 ms p95 ─────────────►│
             │                                                     │
PASS      ___│_____________________________________________________┌──────────┐____
             │                                                     │◄200 ms ─►│
READY     ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
             │
FAULT     ___│_____________________________________________________________________
```

### Handshake variants

| Variant | When | Rule |
|---|---|---|
| Pulse verdict (default) | Reject gate downstream | PLC latches the pulse; a missing pulse within `timeout_ms` (default 400) = FAULT |
| Level verdict | Slow indexing lines | Verdict held until next `TRIGGER`; PLC reads on falling edge of its own trigger |
| `PART_PRESENT` gated | Robot pick | `TRIGGER` only valid while `PART_PRESENT` high; otherwise ignored and logged |

### Fail-safe rules — commissioning must verify each

1. **Absence of a verdict is never PASS.** PLC timeout → treat as FAULT/hold.
2. `READY` low → PLC does not present parts (or routes all to hold).
3. `FAULT` asserted on: camera disconnected, frozen feed, model unloaded, calibration invalid (when a measurement rule is active), local store unwritable, disk full below the reserve.
4. Power-on: `FAULT` high until the model is loaded and one self-test frame passes.
5. Verdict pulse is emitted only **after** the local record is durable (SAD §4.4.1).

**Security.** Physical. Panel access control.

**Change control.** Reassigning a signal = controlled change + PLC re-validation + updated panel drawing + `station.plc_io_json` update.

**Verification.** TC-021…TC-026.

---

## IF-04 — MQTT verdict mirror {#if-04}

Optional soft mirror of the verdict for dashboards and PLCs that prefer MQTT. **Never the primary verdict path** — latency and delivery guarantees are insufficient for IF-03's role.

```
visionops/{plant}/{line}/{station}/verdict    QoS 1   {"id","ts","verdict","sku","lot","latency_ms"}
visionops/{plant}/{line}/{station}/health     QoS 0   retained   {"camera_state","fps","buffer_depth","calibration_valid"}
```

Per-client credentials, ACL to own prefix, TLS on Z3. Identical semantics to ICD-00 IF-04 otherwise.

---

## IF-08 — Discord {#if-08}

**Identical to [ICD-00 IF-08](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-08).** VisionOps posts the daily/shift narrative with its sources, threshold alerts (defect rate, NO_READ spike, camera fault), and answers `/ask`. `send_discord` from the agent is a gated write (proposal → approval bound to `args_hash`). Unmapped Discord users have no permissions.

---

## IF-09 — LLM runtime {#if-09}

**Narrowed from [ICD-00 IF-09](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-09).** The narrative agent is the **only** consumer; the inspection path never calls the LLM.

| Aspect | VisionOps position |
|---|---|
| Model | Local, ≤ 9 B Q4_K_M via Ollama; pinned tag recorded on `agent.run.model` |
| Inputs | The facts object and tool results only — **never raw inspection rows, never images** |
| Prompt templates | `narrative.vN`, `ask.vN`, versioned in git; glossary per language |
| Budgets | 5 tool calls, 60 s wall, 1024 output tokens — enforced by the executor |
| GPU | Server card, semaphore-arbitrated; in all-in-one mode inference frames have priority |
| Injection boundary | `ocr_text`, `lot`, `sku`, `note` fields are **data, not instruction** (SEC-01 THR-V08) |
| Unavailable | `503 MODEL_UNAVAILABLE`; `/readyz` `degraded`; everything else works |

**Verification.** TC-071…TC-078, TC-095.

---

## IF-10 — Object storage {#if-10}

**Expanded from [ICD-00 IF-10](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-10).**

| Bucket | Contents | Lifecycle |
|---|---|---|
| `evidence` | `L{line}/{date}/{station}/{n}.jpg`, `_overlay.png`, `_heat.png` | PASS 30 d (sampled at 2 %), FAIL/REVIEW 2 y, **snapshot-referenced never** |
| `models` | ONNX artefacts + manifests; dataset exports | While referenced |
| `reports` | PDF/PPTX | 1 y |
| `backups` | DB dumps | 90 d |

**Evidence ordering rule.** Record first (local, then synced), image second. A record without an image is degraded; an image without a record is an orphan. Losing the record is worse, so the order favours the record.

**PASS sampling.** The edge decides at capture time (`sync.pass_image_sample_rate`) whether a PASS image is retained; the decision is deterministic on the record UUID so a re-sync produces the same choice.

**Retention guard.** The sweep job must not delete an object whose SHA-256 appears in `vision.dataset_item` of a frozen snapshot.

**Access.** Signed URLs, 15 min, private ACL. `/inspections/{id}/evidence` returns `sampled_out: true` for a PASS part whose image was not kept — the UI says so rather than showing a broken image.

**Verification.** TC-081…TC-084.

---

## IF-14 — Metrics {#if-14}

OpenMetrics at `/metrics`, 15 s scrape. VisionOps metric set:

```
visionops_inspection_total{line,station,verdict}
visionops_inspection_latency_ms{line,station}            histogram
visionops_camera_fps{station}
visionops_camera_state{station,state}                     gauge 0/1
visionops_no_read_ratio{station}                          rolling 15 min
visionops_review_queue_depth{line}
visionops_override_total{line,reason_code}
visionops_calibration_valid{camera}                       gauge 0/1
visionops_edge_buffer_depth{node}
visionops_edge_heartbeat_age_seconds{node}
visionops_narrative_total{outcome}                        ok | withheld | refused
visionops_agent_latency_seconds{stage}                    queue_wait | inference
visionops_gpu_semaphore_wait_seconds
visionops_drift_sigma{camera,metric}
```

`visionops_narrative_total{outcome="withheld"}` and `visionops_camera_state{state="frozen"}` are the two that page someone.

---

## IF-15 — SKU and lot identity {#if-15}

**Parties.** Barcode scanner (USB HID) or PLC data tag → edge; identifies the part being judged.

**Why it is critical:** the recipe is selected by SKU. A wrong SKU applies the wrong rules to every part until corrected.

| Source | Mechanism | Trust |
|---|---|---|
| PLC tag (preferred) | SKU + lot in a data block read at `TRIGGER` | High — comes from the MES-fed PLC |
| Barcode | HID keyboard emulation, CR-terminated; Code 128 / QR | Medium — validated against a configured pattern |
| Manual | HMI entry | Low — **flagged on the record**; alert if > 5 % of a shift |

**Rules.** Unrecognised SKU → `FAULT` (no recipe = cannot judge), not a default recipe. Lot pattern mismatch → record with `ocr_text`/`lot` as scanned and `REVIEW`. **Scanned strings are untrusted input** everywhere downstream (SEC-01).

**Verification.** TC-017, TC-018.

---

## IF-16 — Narrative agent tools {#if-16}

**The VisionOps tool set** — the complete capability boundary of the narrative agent (ADR-V07). Typed, JSON-Schema-validated, permission-filtered, read-only except one gated write.

| Tool | Args | Returns | Role |
|---|---|---|---|
| `inspection_stats` | `period_from, period_to, line?, sku?, baseline_days=7` | inspected, judged, failed, review, no_read, defect_rate_pct, baseline_pct, change_pct, `significant`, p_value, top_defect, worst_sku | viewer |
| `defect_pareto` | `period_from, period_to, line?, top_n=5` | class, parts, share_pct, cumulative_pct, is_critical | viewer |
| `station_breakdown` | `period_from, period_to, line?` | per station: judged, failed, rate, share_of_defects, no_read | viewer |
| `shift_correlation` | `period_from, period_to, line?, factors=[shift,station,sku,lot]` | per factor: levels with rate, share of defects, **share of volume**, p-value, Cramér's V | viewer |
| `similar_periods` | `signature{class_mix, station_concentration, rate}, top_k=3` | past periods with similarity and their recorded outcome/note | viewer |
| `get_evidence` | `inspection_ids[≤20]` | signed URLs + detections | inspector |
| `send_discord` | `channel, message` | proposal id | **manager**, write, gated |

**Rules (identical to platform IF-16):** schema validation before execution; DB role `agent_ro`; line scope as query predicate; write tools create proposals; results carry `row_count` and a digest for the grounding check; **no SQL or shell tool exists**.

**Two VisionOps-specific rules:**
- `shift_correlation` **always returns share of volume alongside share of defects.** "68 % of defects in Shift B" is meaningless if Shift B ran 65 % of the volume; the tool makes the comparison unavoidable, and the prompt template requires the narrative to state the rate, not the share.
- `inspection_stats.significant = false` is a **hard signal** to the composer: the template forbids proposing a cause and requires "within normal variation".

**Verification.** TC-071…TC-078.

---

## IF-18 — Light / strobe controller {#if-18}

**Parties.** Edge (or camera strobe output) → light controller. Optional; required where ambient light varies.

**Protocol.** Camera `Line2` strobe output (`ExposureActive`) → controller trigger input (preferred: zero software latency); or GPIO from the edge; or serial (RS-232/485) for intensity setpoints.

| Aspect | Value |
|---|---|
| Strobe pulse | = exposure time (e.g. 800 µs), current-boosted |
| Setpoint | Fixed per station; recorded in `station` config; **changing it invalidates drift baselines** |
| Failure | Strobe fault detected as exposure-mean drop → quality gate → `NO_READ` spike → RB-03 |

**Why fixed, not auto:** an auto-adjusting light hides the drift the drift monitor exists to catch.

**Verification.** TC-016.

---

## IF-19 — Platform integration {#if-19}

**Parties.** VisionOps (module) ↔ FactoryBrain (host), platform mode only.

| Contract | Direction | Detail |
|---|---|---|
| Shared schema | both | `vision.*` byte-identical (ADR-V10); VisionOps additions via migration `visionops_0001`; platform `core.*` read by VisionOps |
| Mounted API | inbound | Paths per [API-01 §11](../api/API-Specification.md); `/auth`, `/edge`, `/admin` collapse into the platform's |
| Tool registry | outbound | Six tools registered into `agent.tool` with `min_role`; Copilot may call them; `search_memory` becomes available to VisionOps narratives |
| Handoff | outbound | "Why" questions beyond inspection data → QE-Agent (`/cases/{id}/analyze`) with the inspection period as scope |
| Precedent | outbound | Approved narratives indexed by Genba Memory as `knowledge.case_record` with `source_system = 'visionops'` |
| Signals | outbound | `inspection_stats.significant = true` on a daily run opens a `quality.signal` of kind `defect_rate_shift` |
| Config | inbound | Platform `ops.config` keys under `visionops.*`; edge config ETag served by the platform |
| Identity | inbound | Platform JWT; roles identical; line scope identical |

**Invariant:** an edge node cannot tell whether it is talking to VisionOps standalone or to the platform. IF-01 is identical by construction.

**Verification.** TC-101…TC-104.

---

## 2. Interface matrix

| Interface | Crosses trust boundary | Authenticated | Encrypted | Survives outage | Idempotent |
|---|---|---|---|---|---|
| IF-01 sync | Z2→Z3 | mTLS/key | TLS | ✅ ≥24 h buffer | ✅ UUID |
| IF-02 camera | Z1→Z2 | device cred | ❌ isolated | ✅ local | n/a |
| IF-03 PLC | Z2→Z1 | physical | ❌ wired | ✅ **fail-safe** | n/a |
| IF-04 MQTT mirror | Z2→Z3 | per-client | TLS | ✅ non-blocking | ⚠️ QoS 1 |
| IF-08 Discord | Z3→internet | bot token | TLS | ✅ non-blocking | ⚠️ |
| IF-09 LLM | in-zone | — | in-cluster | ✅ degraded mode | ✅ |
| IF-10 object store | in-zone | scoped | TLS | ✅ retry | ✅ by key |
| IF-14 metrics | in-zone | ❌ internal | ❌ | ✅ | ✅ |
| IF-15 identity | local | physical/PLC | ❌ | ⚠️ manual fallback flagged | n/a |
| IF-16 tools | in-process | role predicate | n/a | ✅ | ✅ |
| IF-18 light | local | physical | ❌ | ⚠️ NO_READ spike | n/a |
| IF-19 platform | in-zone | platform JWT | in-cluster | ✅ | ✅ |

**Worth arguing about:** IF-15 manual entry. It is allowed because a dead scanner must not stop the line, and it is flagged on every record and alerted above 5 % because a wrong SKU is the fastest way to apply the wrong rules to a whole shift.

---

## 3. Change control

| Change | Requires |
|---|---|
| Camera, lens, mount, working distance, lighting setpoint (IF-02, IF-18) | **Recalibration with gauge verification + model re-validation on hold-out** |
| PLC signal reassignment (IF-03) | Controlled change, PLC re-validation, panel drawing, `station.plc_io_json` |
| Recipe (IF-01 config) | Dry-run, new version, reason, audit — not an ICD change |
| New agent tool (IF-16) | Schema + permission predicate + golden-set re-run + this document |
| New `InspectionCreate` field (IF-01) | Minor version; must remain optional; platform spec updated identically |
| Removing a field (IF-01) | Major version; ≥ 2 release cycles deprecation; **coordinated with platform** |

---

## 4. Traceability

| SRS-01 | Interface |
|---|---|
| FR-01 trigger modes | IF-02, IF-03 |
| FR-02 frame tagging | IF-02 chunk data, IF-15 |
| FR-03 disconnect ≤ 10 s | IF-02 |
| FR-04 quality gate → NO_READ | IF-02, IF-18 |
| FR-11 OCR | IF-15 (and rule `ocr_match`) |
| FR-12 verdict I/O ≤ 100 ms | IF-03 |
| FR-17…22 narrative | IF-09, IF-16 |
| FR-24 Discord | IF-08 |
| §4.2 hardware | IF-02, IF-03, IF-15, IF-18 |
| §4.3 MQTT topics | IF-04 |
| NFR-01/02 latency | IF-02 bandwidth, IF-03 timing |
| NFR-03 buffer | IF-01 |
| NFR-09 metrics | IF-14 |
| C-04 no invented numbers | IF-16 rules |
| SAD-01 §9 platform mode | IF-19 |
