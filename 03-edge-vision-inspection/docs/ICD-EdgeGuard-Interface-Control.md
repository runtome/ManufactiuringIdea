# Interface Control Document — EdgeGuard Edge Vision Node

| Field | Value |
|---|---|
| Document ID | ICD-03-EdgeGuard |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Scope | Every interface an EdgeGuard node has with the world: hardware (camera, PLC, light, identity source), the central (IF-01 as a **client**), the operator (HMI), the fleet administrator (provisioning/OTA) and the host OS |
| Related | [SRS-03](../SRS-EdgeGuard-Edge-Vision-Inspection.md) · [SAD-03](SAD-EdgeGuard-Software-Architecture.md) · [API-03](../api/API-Specification.md) · [SEC-03](SEC-EdgeGuard-Security-Requirements.md) · [ICD-01](../../01-factory-inspector-agent/docs/ICD-VisionOps-Interface-Control.md) (server side of IF-01…IF-18) · [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) |

---

## 1. Scope and register

`IF-xx` numbers are **shared across the repository**: an interface keeps its number whichever document describes it. ICD-01 describes IF-01…IF-18 from the *server's* side and the *station's* side; this document describes them from the **node's** side, in more depth where the node is where the wire is. Three interfaces are new here.

| IF | Interface | Node role | Described in depth here |
|---|---|---|---|
| **IF-01** | Edge ↔ central sync | **Client** | ✅ client state machine, batch assembly, backoff, image window, ETag, heartbeat, credentials |
| **IF-02** | Industrial camera | Master | ✅ features, wiring, bandwidth, liveness |
| **IF-03** | PLC discrete I/O | Peer | ✅ **wiring, pin tables, timing, truth table, commissioning** |
| IF-04 | MQTT verdict mirror | Publisher | Brief — optional |
| IF-15 | SKU/lot identity | Consumer | ✅ HID vs PLC tag |
| IF-18 | Light / strobe | Master | ✅ |
| **IF-22** | Provisioning and OTA | Target | ✅ **new** |
| **IF-23** | Local HMI | Server | ✅ **new** |
| **IF-24** | Host OS: systemd, watchdog, thermal, NTP, disk | Guest | ✅ **new** |
| — | Node-local API | Server | [API-03](../api/API-Specification.md) |

Interfaces the node **does not have**: no LLM (IF-09), no object store (IF-10 — images go through IF-01), no Discord (IF-08), no platform bus (IF-19). A node talks to its camera, its PLC, its light, its operator and its central. Nothing else.

**Network zones.** Z1 = machine/camera segment (isolated); Z2 = node; Z3 = plant server LAN. All node traffic to Z3 is **outbound-initiated**; nothing in Z3 initiates a connection to a node.

---

## IF-01 — Edge ↔ central sync (node as client) {#if-01}

**Parties.** Node `sync` process → central (VisionOps `/edge/*` in [API-01](../../01-factory-inspector-agent/api/openapi.yaml) or FactoryBrain in [API-00](../../00-factorybrain-platform/api/openapi.yaml)). Payload schemas are copied verbatim into [`api/openapi.yaml`](../api/openapi.yaml) and diffed (TC-008).

**Transport.** HTTPS, TLS 1.2+; **mTLS** with the per-node client certificate (CN = `node_code`, issued by the plant's internal CA, IF-22). Where the central cannot terminate mTLS, `X-Edge-Key` from `/etc/edgeguard/secrets/edge.key`. The node **pins the CA** — it will not sync to a server whose certificate does not chain to the provisioned CA (SEC-E20).

### Client state machine

```
           ┌──────────┐  due rows   ┌─────────┐   207   ┌──────────┐
  boot ───►│  IDLE    │────────────►│ SENDING │────────►│ APPLYING │──► IDLE
           └──────────┘             └─────────┘         └──────────┘
                ▲                        │ connect/5xx/timeout
                │ next_retry_at          ▼
           ┌──────────┐             ┌───────────┐
           │ BACKOFF  │◄────────────│UNREACHABLE│  (alarm after 3 failures; never a FAULT)
           └──────────┘             └───────────┘
```

| Loop | Interval | Rule |
|---|---|---|
| Records | immediate when due rows exist, else idle | `SELECT … FROM sync_queue WHERE next_retry_at <= now ORDER BY priority, ts LIMIT 500` |
| Images | after records; in window | `image_queue` for records with `synced_at IS NOT NULL` |
| Config | 300 s | `GET /edge/config?node_code=` with `If-None-Match` |
| Heartbeat | 60 s | `POST /edge/heartbeat`; also immediately on READY/FAULT transitions |

### Batch assembly (`POST /edge/records:batch`)
- ≤ 500 records; FAIL/REVIEW (`priority` 1) before PASS (`priority` 5); within priority, oldest first.
- Body = `{ node_code, records: [InspectionCreate…] }`; each record projected from the local store by [`db/payload_mapping.json`](../db/payload_mapping.json) (DDS-03 §6).
- **Overrides** are sent one by one *after* the record they refer to is `accepted`/`duplicate`, via `PATCH /inspections/{id}/verdict` (API-01 `overrideVerdict`) with the same `reason_code` enum and `label_class`. **Known gap:** that endpoint is a bearer-JWT `inspector` endpoint, not part of the `/edge/*` key-authenticated contract — the central must grant the node's identity an `inspector`-scoped service credential limited to its own records, or the contract needs a `POST /edge/overrides:batch` in v1.1. Until one of those exists, node overrides accumulate locally (`v_backlog.overrides`) and are visible on the HMI. Recorded in README-03 *Known gaps*.

### Outcome handling (207)
| Item status | Node action |
|---|---|
| `accepted` | `store.mark_synced(id)`; dequeue |
| `duplicate` | same as accepted — **this is the healthy retry case**, not an error |
| `rejected` | keep row; `sync_attempts += 1`; `last_sync_error = code:detail`; `next_retry_at` per backoff; after 5 → `stuck` (alarm `sync:REJECTED_RECORDS`, visible on HMI and heartbeat) |
| HTTP 401/403 | credential problem — alarm `sync:AUTH_FAILED`; no retry storm (backoff to max) |
| HTTP 413 | halve batch size for this session |
| 5xx / timeout / TLS error | whole batch retried; nothing marked |

### Backoff
`delay = min(300, 1 × 2^n) × (1 ± 0.2)` seconds; reset to 0 on any 2xx/207. Jitter avoids a fleet thundering herd after a plant-wide outage.

### Images (`POST /edge/images`)
- Only for records already synced; `kind` ∈ original/overlay/heatmap; `sha256` sent — a 422 means the local file changed (re-hash once, then stuck).
- **Window**: `sync.image_window` (e.g. `22:00-06:00`) and `sync.bandwidth_kbps` from the config bundle; outside the window only FAIL/REVIEW *overlays* are sent (small); originals wait. `POST /sync/flush` overrides the window.
- C-02: PASS originals are sent only when `pass_image_sample_rate` > 0 and the central policy allows — sampling is applied at *capture*, so an un-sampled PASS image never exists.

### Config (`GET /edge/config`)
`If-None-Match: <etag>` → 304 (nothing) or 200 (bundle). Validation before apply: JSON schema; each recipe's classes ⊆ active model `class_map`; calibration `hardware_fingerprint` vs live camera; models listed are downloaded/verified (IF-22). Apply is an atomic swap of `config_cache`; failure keeps the previous bundle and raises `config:INVALID`. **Superset rule**: unknown top-level keys are ignored and listed in `/config.ignored_fields` (TC-063).

### Heartbeat (`POST /edge/heartbeat`)
`NodeHealth` every 60 s: `buffer_depth` = unsynced records; `camera_state`; `calibration_valid`; `model_versions` = `{active, previous, shadow: {version, frames, disagree}}`; `disk_pct`, `temp_c`, `fps`, `last_verdict_at`. A failed heartbeat is logged in `heartbeat_log` and is **never a fault**. The central alarms after 3 misses (FR-26) — that is the central's job, not the node's.

### Credentials
Certificate lifetime 1 year; renewal at 30 days remaining via the config bundle (`credentials.renew`) or `edgectl cert renew`; old cert valid until the new one has completed one successful heartbeat; revocation = central rejects the CN (SEC-E22). Rotation never requires a redeploy.

**Verification.** TC-050…TC-062, TC-063 (superset), TC-008 (schema identity).

---

## IF-02 — Industrial camera {#if-02}

**Parties.** Node `capture` process ↔ camera(s). One `capture` per camera; a shared GPU queue (FR-04).

| Interface | Supported | Bandwidth | Notes |
|---|---|---|---|
| **GigE Vision** (GenICam/GenTL) | ✅ reference | 1 GbE ≈ 100 MB/s → ~40 fps at 1920×1200 Mono8 | PoE from a dedicated injector; jumbo frames 9000; camera on Z1 direct link |
| **USB3 Vision** | ✅ | ~350 MB/s | Cable ≤ 3 m unless active; USB power budget on Jetson |
| **MIPI CSI** (Jetson) | ✅ | native | Fixed lens; no chunk data — liveness by frame counter |
| V4L2 / UVC | lab only | — | Camera replay via `v4l2loopback` in the lab compose |

### GenICam features the node sets and reads
| Feature | Value | Why |
|---|---|---|
| `TriggerMode` / `TriggerSource` / `TriggerActivation` | On / Line1 / RisingEdge (hardware) or Software | FR-01 |
| `ExposureTime`, `Gain` | from recipe | Deterministic — never auto in production |
| `BalanceWhiteAuto` | Off (fixed from calibration) | FR-02 |
| `PixelFormat` | Mono8 or BayerRG8 | Bandwidth |
| `AcquisitionFrameRateEnable` | Off in trigger mode | |
| `ChunkModeActive` + `ChunkFrameID`, `ChunkTimestamp`, `ChunkExposureTime` | On | **Liveness and timing evidence** (`inspection.frame_id`, `device_ts`) |
| `LineSelector=Line2, LineSource=ExposureActive` | On | Strobe output (IF-18) |
| `DeviceSerialNumber`, `DeviceModelName`, lens/mount from `node.yaml` | read | `hardware_fingerprint` for calibration validity |
| `GevSCPSPacketSize` / `GevSCPD` | 9000 / tuned | Packet loss = NO_READ; tuned at commissioning |

### Liveness — the frozen-feed and replay checks (ADR-E04)
| Check | Rule | Result |
|---|---|---|
| Frozen | `sha256(frame_n) == sha256(frame_n-1)` for 2 consecutive triggers | `FAULT: camera:FROZEN` (latched — clear via PIN after camera recovers) |
| Frame id | `ChunkFrameID` not strictly increasing | `camera:REPLAY_SUSPECT` alarm; `FAULT` if 3 in a row |
| Device clock | `|device_ts − host_ts|` drift > 500 ms | alarm `camera:CLOCK_SKEW`; data-quality event |
| No frame after trigger | > 100 ms | `camera:NO_FRAME` event (not a NO_READ — nothing was captured); 3 in a row → FAULT |
| Disconnect | GenTL device lost | `FAULT: camera:DISCONNECTED` within ≤ 10 s; auto-reconnect loop; cleared automatically on recovery + one good frame |

### Quality gate (FR-03)
`blur_variance < min_blur_variance` or `exposure_mean ∉ exposure_range` → record `NO_READ` with `no_read_reason` (`BLUR`, `EXPOSURE`, `NO_PART`), **no inference**. The PLC signal for NO_READ is configurable per station (`plc_io.no_read_as`: `REVIEW` default, or `FAIL`) — never PASS.

**Verification.** TC-010…TC-018.

---

## IF-03 — PLC discrete I/O {#if-03}

**Parties.** PLC ↔ node `supervisor` process (the only process with GPIO access).

> **Safety boundary (unchanged from ICD-01).** EdgeGuard is advisory. It communicates a *judgement*; the PLC decides what to do with it. EdgeGuard is not a safety-rated function and must never be the sole means of preventing a hazard.

### Signals

| Signal | Dir | Type | Semantics |
|---|---|---|---|
| `TRIGGER` | PLC → node | Pulse ≥ 5 ms, rising edge | Part in position |
| `PART_PRESENT` | PLC → node | Level, optional | Gates `TRIGGER` (robot pick variant) |
| `READY` | node → PLC | **Level** | High = can judge (v_ready = 1). Low on boot until self-test |
| `PASS` / `FAIL` / `REVIEW` | node → PLC | **Pulse** `pulse_ms` (default 200) or level variant | Exactly one per trigger; **only after durable commit** (ADR-E03) |
| `FAULT` | node → PLC | **Level** | High = cannot judge; = NOT READY (wired separately so a dead node reads FAULT) |
| `HEARTBEAT` | node → PLC | 1 Hz square, optional | PLC watchdog on the node itself — recommended |

### Electrical
- **24 V DC discrete, opto-isolated both directions.** Never drive PLC inputs from 3.3 V GPIO directly.
- Outputs: sinking (NPN) or sourcing (PNP) per PLC input card — declared in `node.yaml: plc_io.output_type`; relay outputs for `FAULT` are recommended so a **powered-off node presents FAULT** (normally-closed contact = FAULT).
- Inputs: 24 V → opto → 3.3 V; debounce 2 ms in hardware or driver.
- Common ground with the PLC I/O card via the isolator only; node chassis to panel earth.

### Pin tables

**Jetson Orin Nano 40-pin header** (BCM numbering; via an opto-isolated 24 V I/O HAT — never bare):

| Pin | GPIO | Signal | Dir |
|---|---|---|---|
| 7 | GPIO09 | `TRIGGER` | in |
| 11 | GPIO17 | `PART_PRESENT` | in |
| 13 | GPIO27 | `READY` | out |
| 15 | GPIO22 | `PASS` | out |
| 16 | GPIO23 | `FAIL` | out |
| 18 | GPIO24 | `REVIEW` | out |
| 22 | GPIO25 | `FAULT` | out (NC relay) |
| 29 | GPIO05 | `HEARTBEAT` | out |
| 6, 9, 14, 20, 25, 30, 34, 39 | GND | | |

**x86 mini-PC / any device via USB or Modbus-TCP I/O module** (e.g. 8-in/8-out 24 V module): the same signal names mapped to `DI0…DI1` / `DO0…DO5`; the module's own watchdog (outputs to safe state on host loss) must be enabled and set to `FAULT` asserted.

The assignment for a station is **data**, not code: `node.yaml: plc_io` (and, when the central supplies `stations[].plc_io`, the bundle — identical shape). It must match the panel drawing; mismatch is a commissioning stop.

### Timing diagram (2 parts/s reference)

```
TRIGGER   ──┐_________________________________________________________┐______
            │                                                         │
            │ grab≤15  gate≤5  infer≤100  rules≤5  commit≤10          │
            │◄──────────── t_verdict ≤ 200 ms p95 ────────────►│      │
PASS      __│___________________________________________________┌────┐│______
            │                                                   │200 ││
READY     ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
FAULT     ______________________________________________________________________
HEARTBEAT ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
            ◄──── 500 ms ────►
```
The PLC `timeout_ms` (default 400) starts at its own `TRIGGER`. No pulse by then = FAULT/hold — **absence of a verdict is never PASS.** At 2 parts/s the next trigger may arrive before the previous pulse ends; verdict pulses are queued per trigger in order and never overlap (`pulse_ms` ≤ ½ trigger period is a commissioning check).

### Variants
| Variant | Rule |
|---|---|
| Pulse verdict (default) | PLC latches |
| Level verdict | Held until next `TRIGGER` |
| `PART_PRESENT` gated | `TRIGGER` while `PART_PRESENT` low = ignored + event |
| Multi-frame tracking (FR-09) | One verdict per part id; pulses on the *last* frame's commit |

### Fault truth table (ADR-E05) — the node's side of fail-safe

| Condition | `READY` | `FAULT` | Verdict pulses |
|---|---|---|---|
| Boot until self-test passed | low | high | none |
| Camera disconnected / frozen / no frame ×3 | low | high | none |
| Model not loaded / engine building / sha256 mismatch | low | high | none |
| Calibration invalid **and** recipe has a measurement rule | low | high | none |
| Store cannot write | low | high | none |
| Node powered off / process dead | low (no drive) | **high (NC relay)** | none |
| Thermal throttled, within budget | high | low | continue (alarm) |
| Thermal: p95 over budget 60 s | low | high | none |
| Central unreachable | high | low | continue |
| Disk below PASS-image reserve | high | low | continue |
| Store recovered from corruption (latched) | low | high | none until PIN clear |

### Commissioning verification (each is a TC)
1. Every output toggled from `edgectl io test` is seen at the correct PLC input (TC-020).
2. `TRIGGER` from the PLC produces exactly one verdict pulse of `pulse_ms` (TC-021).
3. Unplug camera → `FAULT` high within 10 s; PLC holds (TC-022).
4. Power off node → `FAULT` high (NC relay) (TC-023).
5. Kill the `store` process → `FAULT`, no pulses (TC-024).
6. Verdict pulse never precedes the record: replay 1,000 triggers with a power-cut script; every pulsed verdict has a row (TC-025).
7. Trigger at 2× line rate: no overlapping pulses, `ring full` metric, FAULT if sustained (TC-026).

**Change control.** Reassigning a pin = controlled change + panel drawing + PLC re-validation + `node.yaml`/bundle update.

**Verification.** TC-020…TC-037.

---

## IF-04 — MQTT verdict mirror {#if-04}

Optional. `sync` publishes `vision/<line>/<station>/verdict` QoS 1 with `{id, ts, verdict, sku, lot, latency_ms}` immediately after the PLC pulse — **advisory**, never the line signal. TLS, per-node client cert. Failure is invisible to the line. Off unless `node.yaml: mqtt.enabled`.

---

## IF-15 — SKU and lot identity {#if-15}

| Source | Mechanism | Node behaviour |
|---|---|---|
| Barcode scanner (HID) | USB keyboard wedge on the node; `capture` reads `/dev/input/by-id/…` exclusively (grab) | Parses `SKU;LOT` per `node.yaml: identity.pattern`; selects recipe; shows on HMI |
| PLC data tag | Modbus-TCP/OPC-UA read of `SKU`, `LOT` registers on each trigger (or on change) | Same |
| Manual (HMI) | Supervisor PIN selects SKU from the bundle's recipes | Flagged `source: manual` on the records; alarm if > 1 h |

Unknown SKU → node **keeps inspecting** with the last recipe if `identity.fallback: last` (records carry the scanned code; the central rejects with `UNKNOWN_SKU` until master data exists → stuck alarm) or `FAULT: config:UNKNOWN_SKU` if `identity.fallback: fault`. Default: `last` on lines with one recipe, `fault` otherwise.

---

## IF-18 — Light / strobe controller {#if-18}

Camera `Line2 = ExposureActive` → controller strobe input; a `light_ok` feedback input (optional) into the node's `PART_PRESENT`-class GPIO. Brightness set at calibration and recorded in `calibration_cache.intrinsics_json.light`. Failure symptoms: NO_READ `EXPOSURE` spike → alarm `light:SUSPECT` after 20 in 5 min (OPS RB-03).

---

## IF-22 — Provisioning and OTA {#if-22}

**Parties.** Fleet administrator (central, `edgectl`, or a USB bundle) → node. Everything the node receives from outside is **verified before use**.

### Provisioning (NFR-09: ≤ 30 min, no developer)
```
1. Flash device image (JetPack/Ubuntu + Docker + edgeguard compose) ── 10 min
2. Place node.yaml (from template) + /etc/edgeguard/secrets/{ca.crt, node.crt, node.key} ── 5 min
3. First boot: supervisor reads node.yaml → self-test → FAULT until config bundle present
4. Config: pull from central (mTLS) OR `edgectl config apply bundle.json` from USB
5. Models: pulled per manifest OR from the USB bundle; sha256 verified; engine built (1–5 min)
6. READY. Commissioning checklist (OPS §5). ── total ≤ 30 min
```

### `node.yaml` (identity and hardware — immutable per provisioning)
Keys: `node_code`, `plant`, `line`, `station`, `lang`, `sync.url`, `sync.auth` (`mtls` | `key`), `camera` (type, id/serial, lens, mount), `plc_io` (signal → pin/DO, `output_type`, `pulse_ms`, `no_read_as`, `variant`), `identity` (source, pattern, fallback), `lab` (`software_trigger`), `hmi` (`kiosk`, `lang`), `disk` (`min_free_pct`), `thermal` (`fault_after_s`). Full reference in OPS-03 §4.2 and [`deploy/node.yaml.example`](../deploy/node.yaml.example). No secrets.

### Config bundle
`EdgeConfig` from IF-01, or a **signed file** for air-gapped sites: `bundle.json` + `bundle.sig` (Ed25519 by the fleet signing key whose public key is in `node.yaml: signing_pubkey`). `POST /config/apply` verifies the signature, then the same validation as the online path.

### Model OTA
```
manifest (name, version, sha256, uri, task, class_map, input_size)
 → download to /var/lib/edgeguard/models/<name>/<version>/ (resumable; bandwidth-limited)
 → sha256 == manifest.sha256 ? else delete + node_event model_verify_failed + alarm
 → model_cache.verified_at set
 → engine build (TensorRT: keyed cache; Hailo: HEF must be INT8, no build)
 → stage = shadow (if manifest says shadow) — runs beside active, counts disagreements, no verdict effect
 → central marks active in bundle → node activates atomically; previous kept (ADR-E07)
 → rollback: bundle says previous version, or POST /models/{name}/rollback offline
```
USB variant: bundle contains models too; `edgectl bundle apply /media/usb/eg-bundle/` runs the same pipeline.

### App OTA
Container image tags in the bundle (`app.image`, `app.digest`); the node pulls by **digest** from the plant registry (or loads from USB `images.tar`), verifies the digest, restarts one service at a time under the supervisor; failed health after restart → automatic rollback to the previous digest. Never during a shift unless `app.allow_in_shift`.

**Verification.** TC-070…TC-079, TC-100…TC-104.

---

## IF-23 — Local HMI {#if-23}

**Parties.** Operator / inspector at the kiosk display ↔ `hmi` container (static web app served on the Unix socket, rendered by a kiosk browser on the node). No LAN exposure.

| Screen | Content | Touch targets |
|---|---|---|
| **Live** | Last verdict (large, colour: green PASS · red FAIL · amber REVIEW · grey NO_READ), last overlay, shift counters, defect Pareto (shift), status strip | ≥ 24 mm; glove-usable (AC-07) |
| **Status strip** | Connection (●/○), buffer depth, model version, last sync time, calibration, thermal | Always visible |
| **Degraded banner** (FR-19) | `FAULT` full-screen red with reason; alarms as amber banner (e.g. "Server unreachable — buffering 150") | |
| **History** | Last 50 records; tap → detail with overlay | |
| **Override** | PIN pad → reason code → confirm | PIN-gated (ADR-E08) |
| **Fault clear** | PIN pad → acknowledge latched fault | |
| **Language** | TH default; JA / EN toggle | FR-16 |

Behaviour rules: polls `/status` at 2 Hz and `/counters` at 0.2 Hz; never blocks on the network; shows the *effective* verdict counts alongside the model's; a lockout after failed PINs is displayed with the remaining time. Defect names come from the bundle (`class_map` labels per language).

**Verification.** TC-080…TC-083, AC-07 walkthrough.

---

## IF-24 — Host OS: systemd, watchdog, thermal, NTP, disk {#if-24}

| Aspect | Contract |
|---|---|
| Process supervision | `edgeguard.service` (systemd) starts the compose stack; `Restart=always`; `WatchdogSec=30` fed by the supervisor only while `/healthz` and the inference loop are alive → a hung inference process is restarted ≤ 30 s (NFR-06) |
| Hardware watchdog | `/dev/watchdog` armed by the supervisor (Jetson: `tegra_wdt`); a hung supervisor reboots the device |
| Boot order | network **not** a dependency; `After=docker.service time-sync.target` with a 10 s NTP grace, never a wait |
| Thermal | hwmon / `tegrastats` every 5 s → `thermal` fault source; `nvpmodel` mode fixed in `node.yaml`; fan curve managed by the OS |
| Time | `chrony` to the plant NTP; skew > 5 s → `node_event time_skew`; records carry device and host time |
| Disk | store and image cache on the SSD (`/var/lib/edgeguard`), `noatime`; `disk_policy_state` sampled every 60 s |
| Encryption | LUKS on `/var/lib/edgeguard` with TPM-sealed key where the device has a TPM (x86); Jetson: dm-crypt with key in the secure keystore where supported, else documented residual risk (SEC-03 §8) |
| Logs | journald, 500 MB cap, JSON; no image bytes |
| Users | No autologin; SSH key-only, disabled by default in production (`node.yaml: ssh.enabled`) |
| USB | `usbguard` allowlist: barcode scanner and the provisioning USB (by serial) only |

**Verification.** TC-090…TC-097.

---

## 2. Interface matrix

| IF | Zone | Auth | Encryption | Node survives failure? | Idempotent |
|---|---|---|---|---|---|
| IF-01 sync | Z2→Z3 outbound | mTLS (CA-pinned) / key | TLS 1.2+ | ✅ ≥ 72 h buffer | ✅ UUID dedup |
| IF-02 camera | Z1 | physical | ❌ isolated link | ⚠️ FAULT (correct behaviour) | n/a |
| IF-03 PLC | wired | physical | ❌ | ⚠️ FAULT (fail-safe) | n/a |
| IF-04 MQTT | Z2→Z3 | client cert | TLS | ✅ non-blocking | QoS 1 |
| IF-15 identity | local | physical / PLC | ❌ | ⚠️ fallback flagged | n/a |
| IF-18 light | wired | physical | ❌ | ⚠️ NO_READ spike alarm | n/a |
| IF-22 provisioning/OTA | Z3→Z2 (pull) or USB | mTLS + signed bundle + sha256 + digest | TLS / signature | ✅ previous kept | ✅ by version |
| IF-23 HMI | loopback | none / PIN | ❌ socket | ✅ | n/a |
| IF-24 host | local | root at boot only | LUKS | ✅ watchdog | n/a |
| Node API | loopback | token / PIN | ❌ loopback | ✅ | ✅ Idempotency-Key |

---

## 3. Change control

| Change | Requires |
|---|---|
| IF-01 payload schema | Change in API-01 first; then the copied schemas here; TC-008 diff must pass; fleet-wide compatibility statement (superset rule) |
| PLC signal or pin | Controlled change, panel drawing, PLC re-validation, `node.yaml`/bundle, TC-020…026 re-run |
| Camera, lens, mount, light position | **Recalibration** — the hardware fingerprint changes and the node will set `CALIBRATION_STALE` on its own |
| `node.yaml` schema | Version field bump; provisioning template; OPS §4.2 |
| Bundle signing key | Rotation via a bundle signed by the *old* key that carries the new public key |
| HMI screens | UM-03 update; AC-07 re-walkthrough if touch targets change |

## 4. Traceability

| SRS-03 | Interface |
|---|---|
| FR-01 trigger modes | IF-02, IF-03 |
| FR-02 preprocessing with stored calibration | IF-02, IF-22 (calibration in bundle) |
| FR-03 quality gate → NO_READ | IF-02 |
| FR-04 multi-camera | IF-02 |
| FR-10 verdict to I/O ≤ 100 ms, MQTT | IF-03, IF-04 |
| FR-15, 16, 18, 19 HMI | IF-23 |
| FR-17 override | IF-23 → API-03 |
| FR-20, 21 sync, images | IF-01 |
| FR-22, 23, 24 config, model OTA, rollback | IF-01, IF-22 |
| FR-25, 26 heartbeat | IF-01 |
| AI-01 engines on device | IF-22 |
| AI-03 manifest sha256 | IF-22 |
| AI-04 shadow | IF-22 |
| NFR-05 boot ≤ 90 s | IF-24 |
| NFR-06 watchdog ≤ 30 s | IF-24 |
| NFR-07 TLS, identity, rotation | IF-01 |
| NFR-09 provisioning ≤ 30 min | IF-22 |
| AC-02, AC-06 | IF-01 |
| AC-03 | IF-24, IF-03 (pulse after commit) |
| AC-07 | IF-23 |
| C-02 | IF-01 images |
| C-04 | IF-22 |
| C-05 | IF-24 |
