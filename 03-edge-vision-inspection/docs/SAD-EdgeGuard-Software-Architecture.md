# Software Architecture Document — EdgeGuard (Edge AI Quality Inspection Node)

| Field | Value |
|---|---|
| Document ID | SAD-03-EdgeGuard |
| Project code name | **EdgeGuard** |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Governs | [SRS-03-EdgeGuard](../SRS-EdgeGuard-Edge-Vision-Inspection.md) |
| Relationship | The **edge runtime** that [VisionOps (SAD-01)](../../01-factory-inspector-agent/docs/SAD-VisionOps-Software-Architecture.md) deploys onto; syncs to VisionOps or [FactoryBrain (SAD-00)](../../00-factorybrain-platform/docs/SAD-FactoryBrain-Software-Architecture.md) over an identical contract |

**Structure basis:** ISO/IEC/IEEE 42010:2011 with C4-model views.

---

## 1. Introduction

### 1.1 Purpose
This document describes **how** an EdgeGuard node is built: a small computer beside the line that captures frames, judges parts, signals the PLC, keeps every result on local disk until the server has acknowledged it, and serves a kiosk screen to the operator — with **zero dependency on the network** for any of that.

### 1.2 What a device is, and is not
EdgeGuard has no LLM, no dashboard, no analysis. It has one job: **judge every part, at line speed, correctly, and never lose the record.** Everything in this document serves that. The intelligence (recipes, models, narratives, review queues) lives on the central platform; the node consumes configuration and models from it and returns records to it.

"Standalone" for a device means: **a node with no server**. It inspects, signals, buffers and displays. When a server appears — VisionOps or FactoryBrain, the node cannot tell which — it drains.

### 1.3 Audience
| Audience | Read |
|---|---|
| Implementer | §4 views, §5 cross-cutting, §7 ADRs |
| Controls engineer | §4.4.1, [ICD IF-03](ICD-EdgeGuard-Interface-Control.md#if-03) |
| Reviewer | §3, §7, §8, §10 |
| Field technician | §4.5, [OPS](OPS-EdgeGuard-Deployment-Operations.md) |

### 1.4 Related documents
| ID | Document |
|---|---|
| SRS-03 | [Requirements](../SRS-EdgeGuard-Edge-Vision-Inspection.md) |
| DDS-03 | [Local Store Design](DDS-EdgeGuard-Local-Store-Design.md) · [`schema.sql`](../db/schema.sql) (SQLite) |
| API-03 | [API Specification](../api/API-Specification.md) · [`openapi.yaml`](../api/openapi.yaml) |
| ICD-03 | [Interface Control](ICD-EdgeGuard-Interface-Control.md) |
| SEC-03 | [Security Requirements](SEC-EdgeGuard-Security-Requirements.md) |
| TEST-03 | [Test Plan](TEST-EdgeGuard-Test-Plan.md) |
| OPS-03 | [Deployment & Operations](OPS-EdgeGuard-Deployment-Operations.md) |
| SAD-01 | [VisionOps architecture](../../01-factory-inspector-agent/docs/SAD-VisionOps-Software-Architecture.md) — what the node inspects and where results go |

---

## 2. Architecture principles

The four platform principles, as they land on a device. **P-2 is the primary driver here**; the others follow from it.

| ID | Principle | On the node |
|---|---|---|
| **P-2** | **Offline-first** | The verdict path — trigger → capture → infer → rules → local commit → PLC pulse — touches **no network**. The node runs ≥ 72 h with no server. Sync is a background drain with at-least-once delivery. |
| **P-3** | Human-in-the-loop | A supervisor can override a verdict at the node with a PIN; the override is attributed and synced. A model is **never** promoted from the node — promotion is a central, human decision; the node only executes shadow/activate/rollback on instruction. |
| **P-4** | Database is the source of truth | The local store is a **buffer**, authoritative only until the server acknowledges a record. Once synced, the server row is the truth and the local copy is disposable. The node never edits a synced record. |
| **P-1** | The LLM never computes numbers | There is no LLM on the node. Counters on the HMI are SQL over the local store. |

And the device rule that outranks convenience: **absence of a verdict must never be interpreted as PASS.** The node asserts `FAULT` whenever it cannot judge; the PLC treats a missing pulse as a hold. This is enforced in three places (fault manager, PLC program, commissioning checklist) because one of them will eventually be misconfigured.

---

## 3. Architectural drivers

### 3.1 Constraints (SRS-03 §2.4)
| ID | Constraint | Impact |
|---|---|---|
| C-01 | ≥ 72 h fully offline | Local store sized for ≥ 100 k records + images; sync is a background process |
| C-02 | No raw image leaves the node unless policy allows | Image queue separate from record queue; PASS sampling decided locally |
| C-03 | ONNX Runtime or TensorRT; FP16/INT8 as needed | Runtime abstraction; engines built on-device and cached |
| C-04 | Containerised; reprovision from image + config in ≤ 30 min | One compose file, one `node.yaml`, no manual steps |
| C-05 | Unattended; auto-recover from power loss | WAL store, watchdog, systemd restart, FAULT-until-selftest on boot |

### 3.2 Quality attributes that shape the design
| Driver | Requirement | Shapes |
|---|---|---|
| Latency | NFR-01 ≤ 100 ms infer, NFR-02 ≤ 200 ms trigger→I/O p95 | Shared-memory frame ring; inference process pinned; rules in-process; commit before I/O |
| Throughput | NFR-03 ≥ 10 fps | Zero-copy pipeline; ROI; TensorRT |
| Offline | NFR-04 ≥ 72 h, ≥ 100 k records | SQLite WAL; disk policy; image sampling |
| Boot | NFR-05 ≤ 90 s cold to inspecting | Cached engines; self-test frame; no network wait |
| Uptime | NFR-06 ≥ 99.5 %; hung service restarted ≤ 30 s | Supervisor + watchdog; per-process health |
| Security | NFR-07 TLS, node identity, key rotation | mTLS client; localhost-only API |
| Disk | NFR-08 degrade, never stop inspecting | Policy state machine; unsynced never purged |
| Provisioning | NFR-09 ≤ 30 min, no developer | Image + `node.yaml` |
| Diagnostics | NFR-10 without shell | `/status`, `/diagnostics/bundle` |

### 3.3 Not drivers
Multi-node coordination, analytics, model training, any user beyond operator/inspector/technician.

---

## 4. Views

### 4.1 Context view

```
                        ┌──────────────────────────────────────┐
  Camera (GigE/USB3/CSI)│                                      │──► PLC: READY · PASS · FAIL · REVIEW · FAULT
  PLC: TRIGGER ────────►│           EdgeGuard node             │──► Light/strobe (sync)
  Barcode / PLC tag ───►│   capture · infer · judge · store    │──► Local HMI (kiosk, operator)
  Light controller ◄────┤            · sync · serve            │──► MQTT mirror (optional)
                        │                                      │
  Technician (laptop) ─►│  localhost API · diagnostics         │
                        └──────────────┬───────────────────────┘
                                       │ IF-01 — outbound only, mTLS, at-least-once
                                       ▼
                         Central: VisionOps (01)  or  FactoryBrain (00)
                         — identical contract; the node does not know which —
```

| Actor | Interface | Notes |
|---|---|---|
| Camera | [IF-02](ICD-EdgeGuard-Interface-Control.md#if-02) | GenICam / V4L2 / CSI; frozen-feed detection |
| PLC | [IF-03](ICD-EdgeGuard-Interface-Control.md#if-03) | Discrete 24 V; advisory verdict; fail-safe |
| Light | [IF-18](ICD-EdgeGuard-Interface-Control.md#if-18) | Strobe from camera `ExposureActive` |
| Identity source | [IF-15](ICD-EdgeGuard-Interface-Control.md#if-15) | Barcode HID or PLC data tag; recipe selection |
| Central | [IF-01](ICD-EdgeGuard-Interface-Control.md#if-01) | Node-initiated; VisionOps or FactoryBrain |
| Operator | [IF-23](ICD-EdgeGuard-Interface-Control.md#if-23) | Kiosk HMI |
| Technician | [API-03](../api/API-Specification.md) | Localhost only |
| Host OS | [IF-24](ICD-EdgeGuard-Interface-Control.md#if-24) | systemd, watchdog, thermal, NTP |
| Fleet admin | [IF-22](ICD-EdgeGuard-Interface-Control.md#if-22) | Provisioning, OTA |

### 4.2 Container view

```
┌─ EdgeGuard node (one device) ──────────────────────────────────────────────────┐
│                                                                                │
│  supervisor   process manager · watchdog · fault manager · /status            │
│      │                                                                         │
│  capture ──► [shm frame ring] ──► inference ──► rules ──► store ──► sync ──►IF-01
│   IF-02          zero-copy       ONNX/TRT/Hailo   recipe   SQLite    batches   │
│   trigger                        engine cache              WAL       images    │
│   quality gate                   anomaly · OCR             images    ETag pull │
│      │                                                        │                │
│      └─ strobe (IF-18)                              PLC I/O ◄─┘ (verdict pulse │
│                                                       IF-03     after commit)  │
│  hmi          kiosk web app, reads store (read-only), PIN override via API     │
│  api          localhost:8080 / unix socket — status, records, override, config │
│  metrics      /metrics for the fleet Prometheus                                │
│                                                                                │
│  GPU/NPU: inference only                                                       │
└────────────────────────────────────────────────────────────────────────────────┘
```

| Container | Tech | Responsibility | Privilege |
|---|---|---|---|
| `supervisor` | Python + systemd watchdog | Starts/monitors processes; **fault manager**; READY/FAULT to PLC; `/status` | GPIO access |
| `capture` | Python + GenTL / V4L2 / Argus | Trigger, grab, quality gate, ROI, undistort, frame ring, strobe line | Camera device |
| `inference` | Python + ONNX Runtime / TensorRT / HailoRT | Detection, anomaly, OCR; engine cache; shadow model in parallel | GPU/NPU |
| `rules` | Python | Recipe evaluation → verdict; measurement via calibration | none |
| `store` | Python + SQLite (WAL) | **Single writer**; durable commit; image cache; disk policy; purge | disk |
| `sync` | Python + httpx (mTLS) | Batches, 207 handling, image queue, config/model pull, heartbeat | outbound network |
| `hmi` | Static web + tiny server | Kiosk screens; reads store; PIN override through `api` | none |
| `api` | FastAPI | Localhost node API | reads store; PIN/token auth |
| `metrics` | prometheus_client | Exposes node metrics | none |

**Process model.** Separate OS processes, not threads — a crash in `inference` must not take `store` down. IPC: shared-memory ring for frames (capture → inference), Unix domain sockets for control, SQLite as the shared read model. `store` is the **only writer** to the database (ADR-E02).

### 4.3 Component view

#### 4.3.1 Frame pipeline

```
trigger ─► grab (GenTL) ─► chunk metadata (frame id, device ts, exposure)
        ─► liveness: sha256(frame) == previous? ──yes──► FROZEN → FAULT
        ─► quality gate: blur variance, exposure mean ──fail──► NO_READ record, no inference
        ─► ROI crop, undistort (cached maps) ─► write to shm ring slot ─► notify inference
```
The ring holds 8 slots; a slot is not overwritten until inference releases it. Backpressure (ring full) is a metric and, sustained, a `FAULT` — better a stopped line than silently dropped triggers.

#### 4.3.2 Runtime abstraction

```
class Runtime(Protocol):
    def load(self, artefact: Path, precision: str) -> Engine   # builds/loads engine, verifies sha256 first
    def infer(self, frame_view) -> Detections
    def warmup(self) -> None

impls: OnnxRuntime (CPU/CUDA EP) · TensorRtRuntime (engine cache) · HailoRuntime (INT8 HEF)
engine_cache key = (device_model, driver_version, model_name, model_version, precision)
```
A cache miss builds the engine (1–5 min on Jetson) while the node stays `FAULT` with reason `ENGINE_BUILDING` — visible on the HMI, not a hang. The previous model's engine is retained for rollback (ADR-E07).

#### 4.3.3 Store-and-forward engine

```
rules ──► store.commit(record, detections, measurements)   [BEGIN; INSERT…; COMMIT — WAL, fsync per policy]
              │
              ├──► ack to rules ──► PLC verdict pulse           (only after COMMIT returns)
              └──► enqueue(sync_queue, priority = FAIL/REVIEW > PASS)
                   enqueue(image_queue) for FAIL/REVIEW; PASS if sampled

sync loop:   take ≤ 500 due rows ──► POST /edge/records:batch ──► 207
             per item: accepted|duplicate → mark synced_at, dequeue
                       rejected           → attempts++, next_retry = backoff, last_error
             images: separate loop, lower priority, bandwidth window, after record synced
             config: GET /edge/config If-None-Match ──► 304 | 200 → validate → atomic swap
             heartbeat: every 60 s with NodeHealth
```
**Delete-after-non-rejected:** a local row is eligible for purge only when `synced_at IS NOT NULL`. `rejected` rows stay, are retried with backoff, and are surfaced — they usually mean master data (unknown SKU) on the server.

#### 4.3.4 Fault manager
One component decides READY/FAULT. Inputs and their effect:

| Source | Condition | READY | Verdict pulses |
|---|---|---|---|
| Camera | disconnected / frozen / trigger without frame | low | none |
| Model | not loaded / engine building / sha256 mismatch | low | none |
| Calibration | invalid **and** active recipe has a measurement rule | low | none |
| Store | cannot write (disk error, reserve exhausted for records) | low | none |
| Thermal | throttled below the latency budget | **stays high**, alarm | continue |
| Sync | server unreachable | **stays high** | continue |
| Disk | below PASS-image reserve | **stays high** | continue (no PASS images) |

The last three are the point: **network and disk pressure never stop inspection**; only the inability to judge does.

### 4.4 Runtime views

#### 4.4.1 Trigger → verdict → I/O (the 200 ms budget)

```
PLC      capture      inference     rules      store        supervisor/GPIO
 │─trig─►│              │             │           │               │
 │       │ grab 15 ms   │             │           │               │
 │       │ gate 5 ms    │             │           │               │
 │       │──shm slot───►│             │           │               │
 │       │              │ infer ≤100  │           │               │
 │       │              │──dets──────►│           │               │
 │       │              │             │ eval 5    │               │
 │       │              │             │──commit──►│ WAL 10 ms     │
 │       │              │             │◄──ack─────┤               │
 │       │              │             │──verdict──────────────────►│ pulse 200 ms
 │◄──────┼──────────────┼─────────────┼───────────┼───────────────┤  t ≤ 200 ms p95
 │       │              │             │           │ image encode → async
 │       │              │             │           │ sync queue    → async
```

#### 4.4.2 Cold boot → READY (≤ 90 s)
```
power ─► systemd ─► supervisor (FAULT asserted immediately)
      ─► store: open DB, WAL recovery, integrity quick-check
      ─► capture: enumerate camera, apply node.yaml features, verify hardware fingerprint vs calibration cache
      ─► inference: load active model (sha256 verify) → engine from cache (or build → FAULT: ENGINE_BUILDING)
      ─► rules: load config cache (recipe), validate classes vs model class_map
      ─► self-test: software-trigger one frame → gate → infer → evaluate → must complete ≤ 2 s
      ─► READY high · sync starts draining · heartbeat
```
No step waits for the network. Config and models come from the **local caches**; the server is consulted afterwards.

#### 4.4.3 72 h offline, then drain
Records accumulate (≥ 100 k fits in the reserve); PASS images stop being stored when disk crosses the reserve threshold; FAIL/REVIEW images always stored. On reconnect: records first (priority FAIL/REVIEW), then images in the bandwidth window; duplicates from any earlier partial success are absorbed by server dedup.

#### 4.4.4 Model OTA on the node
```
config pull → manifest lists model vN+1 ──► download to models/ ──► sha256 verify (fail → delete, alarm)
──► build engine (cache) ──► stage = shadow: run beside active on live frames, record disagreements (no verdict effect)
──► central promotes ──► config says active = vN+1 ──► atomic activate; previous kept
──► rollback instruction ──► previous re-activated; one command
```
The node **never decides** to promote. It reports shadow disagreement; a human on the central decides.

#### 4.4.5 Power loss mid-write
SQLite WAL guarantees the last committed transaction survives; an uncommitted verdict is lost **and its PLC pulse was never sent** (the pulse follows the commit), so the part is re-presented — consistent by construction. On boot, `PRAGMA quick_check` runs; a corrupt database is moved aside, a new one created, and a `FAULT` with reason `STORE_RECOVERED` demands technician acknowledgement so the aside file is recovered, not forgotten.

#### 4.4.6 Thermal throttle
`tegrastats`/hwmon sampled every 5 s. Throttled → alarm; if inference p95 exceeds the budget for 60 s → `FAULT: THERMAL` (a slow verdict is a missed part). The enclosure spec in OPS exists to make this rare.

### 4.5 Deployment view

| Device | Runtime | Precision | Typical fps @ 640 | Notes |
|---|---|---|---|---|
| **Jetson Orin Nano 8 GB** (reference) | TensorRT | FP16 | 25–40 | JetPack 6; CSI or USB3/GigE; 40-pin GPIO |
| x86 mini-PC + RTX A2000/3060 | TensorRT | FP16 | 60+ | I/O module for PLC |
| Raspberry Pi 5 + Hailo-8L | HailoRT | INT8 only | 15–30 | INT8 must pass the recall gate; no TensorRT |

Storage ≥ 256 GB SSD (never SD for the store); fanless enclosure rated for cabinet temperature; 24 V industrial PSU with the PLC; NTP from the plant.

Network: zone Z2, **outbound only** to the central sync endpoint; camera on an isolated segment or direct link; local API bound to `127.0.0.1` and a Unix socket.

### 4.6 Data view
Owned by [DDS-03](DDS-EdgeGuard-Local-Store-Design.md). SQLite, WAL, single writer. The record shape is a strict projection of the IF-01 `InspectionCreate` payload; the mapping is verified programmatically.

---

## 5. Cross-cutting concerns

| Concern | Position |
|---|---|
| Identity | Per-node mTLS client certificate (preferred) or `X-Edge-Key`; CN = `node_code`; rotatable without redeploy |
| Local access | API on `127.0.0.1`/Unix socket only; technician token for mutating calls; supervisor **PIN** for override and fault-clear |
| Configuration | `node.yaml` (immutable per provisioning) + config cache pulled by ETag; secrets in files with 0600, never in `node.yaml` |
| Integrity | sha256 on every model artefact and config bundle before use; hardware fingerprint on calibration |
| Time | NTP mandatory; skew > 5 s → data-quality event; device timestamp from chunk data vs host compared |
| Observability | `/status`, `/metrics`, heartbeat; correlation id = record uuid; diagnostics bundle redacted |
| Logging | JSON to journald; ring-buffered; no image bytes, no secrets |
| Privilege | Only `supervisor` (GPIO) and `capture` (camera device) get device access; nothing runs as root except where the runtime demands (stated in compose) |
| i18n | HMI in TH/JA/EN from `node.yaml`; defect names from the config bundle |

---

## 6. Central compatibility

The node syncs to **VisionOps (01)** or **FactoryBrain (00)** with only a URL change. IF-01 is identical by construction ([ICD-01 IF-01](../../01-factory-inspector-agent/docs/ICD-VisionOps-Interface-Control.md#if-01)).

| Contract | VisionOps | FactoryBrain | Node behaviour |
|---|---|---|---|
| `POST /edge/records:batch` | identical | identical | — |
| `POST /edge/images` | identical (+ `sha256`, `heatmap` kind) | base | Send `sha256`; central may ignore |
| `GET /edge/config` | **superset**: adds `calibrations`, `stations`, `sync` | base | Parse known keys; **ignore unknown**; fall back to `node.yaml` for stations/calibration when absent |
| `POST /edge/heartbeat` | superset (`camera_state`, `calibration_valid`) | base | Always send; central may ignore |
| Model manifest | identical | identical | — |

Tolerating the superset is a requirement (SEC/TEST TC-063): an edge fleet is never upgraded atomically and must keep syncing across central versions.

---

## 7. Architecture Decision Records

Inherited: **ADR-004** store-and-forward · **ADR-010** ONNX + on-device TensorRT · **ADR-012** UUIDv7 · **ADR-V01** inference at the edge · **ADR-V03** REVIEW first-class · **ADR-V04** NO_READ ≠ PASS · **ADR-V05** anomaly → REVIEW only · **ADR-V06** calibration fingerprint · **ADR-V09** PASS sampling.

### ADR-E01 — SQLite (WAL) over embedded PostgreSQL
**Context.** SRS-03 allows either. **Decision.** SQLite, `journal_mode=WAL`, single-writer process. **Consequences.** ✅ No daemon, one file, survives power loss by design, trivial backup (copy), ~zero operations on a Jetson. ✅ Readers (HMI, sync, metrics) never block the writer. ❌ One writer — enforced by process design, which is what we want anyway. ❌ No server-side types (UUID is `TEXT`) — the mapping to IF-01 is verified instead.

### ADR-E02 — `store` is the only database writer
**Context.** Concurrent writers on SQLite serialise on a lock; a slow writer delays the verdict. **Decision.** All writes go through `store` over a Unix socket; `sync` requests state changes (`mark_synced`) rather than writing. **Consequences.** ✅ The verdict commit is never blocked by a sync update. ❌ One more IPC hop for sync — negligible.

### ADR-E03 — Verdict pulse only after durable local commit
**Context.** NFR-04 "0 records lost" and the fail-safe rule. **Decision.** Rules waits for `store.commit()` (WAL fsync per policy) before asking supervisor to pulse. **Consequences.** ✅ A pulsed verdict always has a record; a lost record never had a pulse — the line and the data agree after any crash. ❌ ~10 ms on the budget — accepted and budgeted.

### ADR-E04 — Frozen frame is a fault
**Context.** A hung driver or stuck sensor returns the same image forever; a detector sees "no defect" forever. **Decision.** Two consecutive byte-identical frames (SHA-256 of the raw buffer) → `FAULT: FROZEN`. Frame-id non-monotonic → data-quality event, repeated → `FAULT`. **Consequences.** ✅ The most dangerous silent failure becomes a loud one. ❌ A genuinely identical scene in free-run mode could trip it — under hardware trigger with a moving part this does not occur; free-run mode requires `frozen_detect.min_interval_ms` tuning.

### ADR-E05 — Fault manager is one component with a truth table
**Context.** READY/FAULT computed in several places drifts. **Decision.** Supervisor owns the table in §4.3.4; every other process reports state, none drives GPIO. **Consequences.** ✅ One place to audit, one truth table to test (TC-031…037). ❌ Supervisor becomes critical — it is the simplest process and watchdog-protected.

### ADR-E06 — Engines built on-device, cached by (device, driver, model, precision)
Inherited ADR-010, node specifics: build under `FAULT: ENGINE_BUILDING`, keep the previous engine, invalidate cache on driver change. **Consequence:** first boot after an update is slow and *visibly* so.

### ADR-E07 — Two model versions kept on disk: active and previous
**Context.** Rollback must work offline. **Decision.** `model_cache` holds at most one `active`, one `previous`, and optionally one `shadow`; older artefacts purged. **Consequences.** ✅ One-command rollback with no download. ❌ ~2× model storage — trivial.

### ADR-E08 — HMI is read-only except PIN-gated override and fault-clear
**Context.** A shop-floor kiosk is unattended. **Decision.** The HMI reads the store; the only mutations are `override` and `fault/clear`, both requiring a supervisor PIN, attributed by `user_ref`, synced to the central. **Consequences.** ✅ Small attack surface; every consequential action is attributed. ❌ PIN management is an operational duty (OPS §4).

### ADR-E09 — Sync deletes local rows only after a non-`rejected` outcome
**Context.** At-least-once delivery. **Decision.** `accepted` and `duplicate` mark `synced_at`; `rejected` never does. Purge reads only synced rows. **Consequences.** ✅ "No data loss" is a property of the schema, not of luck. ❌ Persistently rejected rows accumulate — surfaced on the HMI and fleet view so master data gets fixed.

### ADR-E10 — Local API bound to localhost / Unix socket only
**Context.** A node is physically accessible and on the plant LAN. **Decision.** `api` and `hmi` bind `127.0.0.1` and a socket; the only network listener is `/metrics` on the LAN interface, and the only outbound is IF-01. Technicians use SSH port-forwarding or the console. **Consequences.** ✅ No remote attack surface on the node. ❌ Remote troubleshooting needs SSH (which is itself locked down — SEC-03).

---

## 8. Quality attribute scenarios

| ID | Scenario | Measure | Traces |
|---|---|---|---|
| QAS-01 | Part at full line rate | ≤ 100 ms infer, ≤ 200 ms trigger→pulse p95; ≥ 10 fps 1 h | NFR-01…03 |
| QAS-02 | Server down 72 h | 0 records lost; ≥ 100 k buffered; PLC signalling unaffected | NFR-04, AC-02 |
| QAS-03 | Power cut ×10 mid-inspection | Back to READY ≤ 90 s each time; DB intact; no pulsed verdict without a record | NFR-05, AC-03 |
| QAS-04 | Camera freezes | `FAULT: FROZEN` within 2 frames; no PASS emitted | ADR-E04 |
| QAS-05 | Disk reaches reserve | PASS images stop; inspection continues; unsynced untouched | NFR-08, AC-05 |
| QAS-06 | Model update arrives | Verified, built, shadowed; `FAULT: ENGINE_BUILDING` visible; rollback works offline | AC-04 |
| QAS-07 | Config references an unknown class | Rejected; previous config kept; alarm | FR-22 |
| QAS-08 | New node from image + `node.yaml` | Inspecting ≤ 30 min, no developer | NFR-09 |
| QAS-09 | Cabinet at 45 °C | No throttle-induced FAULT over an 8 h soak | thermal |
| QAS-10 | Inference process hangs | Watchdog restarts it ≤ 30 s; `FAULT` meanwhile | NFR-06 |
| QAS-11 | Central switched from VisionOps to FactoryBrain | URL change only; superset config tolerated | §6 |
| QAS-12 | Technician needs to diagnose without shell | `/status` + bundle sufficient | NFR-10 |

---

## 9. Risks and technical debt

| ID | Risk | Mitigation |
|---|---|---|
| AR-E01 | Thermal throttling in a sealed cabinet | Enclosure spec, thermal soak test, throttle alarm before FAULT |
| AR-E02 | Storage wear from image writes | SSD required; PASS sampling; WAL `synchronous=NORMAL`; wear metric |
| AR-E03 | Silent camera failure | Frozen/replay detection; trigger/frame reconciliation; heartbeat carries `camera_state` |
| AR-E04 | Config drift across a fleet | ETag + applied-version in heartbeat; fleet view highlights mismatch |
| AR-E05 | Model skew across nodes | Manifest + shadow + fleet view; one-node-first rollout |
| AR-E06 | Physical access to the node | Disk encryption, no autologin, USB disabled, insert-only credential (SEC-03) |
| AR-E07 | Persistently rejected records | Surfaced locally and in fleet view; usually master data |
| AR-E08 | Hailo INT8 path weaker than FP16 | Recall gate applies per precision; INT8 blocked if it fails |

**Accepted debt:** no multi-camera fusion per part; no on-node measurement beyond scale/homography; free-run mode is second-class (hardware trigger is the design centre).

---

## 10. Traceability to SRS-03

| SRS item | Addressed in |
|---|---|
| C-01 72 h offline | §4.4.3, ADR-E09 |
| C-02 images stay unless policy | §4.3.3 image queue |
| C-03 ONNX/TRT | §4.3.2, ADR-E06 |
| C-04 containerised, ≤ 30 min | §4.5, [OPS](OPS-EdgeGuard-Deployment-Operations.md) |
| C-05 unattended recovery | §4.4.2, §4.4.5 |
| FR-01…04 capture | §4.3.1 |
| FR-05…10 inference/verdict | §4.3.2, §4.3.4, §4.4.1 |
| FR-11…14 storage | §4.3.3, DDS |
| FR-15…19 HMI | `hmi`, ADR-E08, IF-23 |
| FR-20…26 sync & fleet | §4.3.3, §4.4.4, §6 |
| AI-01…07 | §4.3.2, ADR-E06, ADR-E07 |
| NFR-01…10 | §8 |
| AC-01…08 | §8, [TEST-03](TEST-EdgeGuard-Test-Plan.md) |
