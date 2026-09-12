# Deployment & Operations Guide — EdgeGuard Edge Vision Node

| Field | Value |
|---|---|
| Document ID | OPS-03-EdgeGuard |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) (the node) · [`deploy/lab-compose.override.yml`](../deploy/lab-compose.override.yml) (edge-lab) · [`deploy/node.yaml.example`](../deploy/node.yaml.example) · [`deploy/.env.example`](../deploy/.env.example) |
| Related | [SAD-03](SAD-EdgeGuard-Software-Architecture.md) · [ICD-03](ICD-EdgeGuard-Interface-Control.md) · [SEC-03](SEC-EdgeGuard-Security-Requirements.md) · [TEST-03](TEST-EdgeGuard-Test-Plan.md) · [UM-03](UM-EdgeGuard-User-Admin-Guide.md) · central side: [OPS-01](../../01-factory-inspector-agent/docs/OPS-VisionOps-Deployment-Operations.md) §3.6 commissioning |
| Audience | Fleet administrator (provisions and updates nodes), maintenance technician (on the floor), controls engineer (PLC side) |

---

## 1. What you are operating

A **fleet of identical boxes**, each bolted beside a station, each fully autonomous. The operational model is therefore:

- **Nodes are cattle.** Any node is reproducible from *image + `node.yaml` + certificates + bundle* in ≤ 30 min (C-04, NFR-09). You never repair a node's software by hand; you re-provision.
- **Nobody logs in.** Diagnosis is `/status`, the HMI, the heartbeat on the central and the diagnostics bundle (NFR-10). SSH is off unless a technician turns it on for a visit.
- **The central pushes nothing.** Nodes pull config, models and app images by digest; a node that cannot reach the central keeps working on its caches (C-01).
- **The line signal is sacred.** No operational procedure may leave READY high while the node cannot judge. When in doubt, the node is in FAULT and the PLC holds parts.

## 2. Hardware

### 2.1 Reference devices
| Class | Device | Accelerator | Camera | PLC I/O | Notes |
|---|---|---|---|---|---|
| **Reference** | NVIDIA Jetson Orin Nano 8 GB dev kit or industrial carrier (JetPack 6) | TensorRT FP16 | GigE (PoE injector) / USB3 / CSI | 40-pin GPIO via opto-isolated 24 V HAT | Fanless carrier; NVMe SSD ≥ 256 GB |
| High rate | x86 fanless mini-PC + RTX A2000 / 3060 | TensorRT FP16 | GigE / USB3 | USB or Modbus-TCP 24 V I/O module (with watchdog) | TPM 2.0 → LUKS sealed |
| Low cost | Raspberry Pi 5 + Hailo-8L | HailoRT **INT8 only** | USB3 / CSI | GPIO via HAT | INT8 must pass the AI-02 recall gate; no TensorRT |

### 2.2 Bill of materials (per station, reference class)
Jetson module + carrier · NVMe SSD 256 GB (industrial) · 24 V → 5 V/19 V PSU (shared 24 V rail with the PLC) · opto-isolated 24 V I/O HAT (≥ 2 in / 6 out, NC relay for FAULT) · GigE camera + lens + PoE injector or USB3 camera · light + strobe controller · kiosk touch display 10–15″ (HDMI/DP) · enclosure IP54 with heat-sink plate · DIN rail clips · shielded cables with strain relief · optional case-open sensor · optional USB barcode scanner.

### 2.3 Enclosure, thermal, power
- Passive cooling sized for **45 °C cabinet ambient** (TC-099). Heat-sink plate to the enclosure wall; no fans in dusty areas.
- Jetson power mode fixed in `node.yaml: hardware.nvpmodel` and never left on a "max" mode without the thermal budget for it.
- 24 V industrial PSU with the PLC; a supply relay in the **lab** only (TC-044) — not in production.
- Earth the chassis to the panel; camera cable shielded; PLC I/O through the isolator only.

### 2.4 Storage and encryption
- The store, image cache, models and engines live on the SSD at `/var/lib/edgeguard`. **Never on SD or eMMC** (endurance).
- x86: LUKS with the key sealed to TPM 2.0 (unattended boot, SEC-E45). Jetson: dm-crypt with the key in the secure keystore on carriers that support it; otherwise the residual risk in SEC-03 §8 applies and must be accepted by the plant.

## 3. Network
- Camera on a **dedicated NIC** (`CAMERA_IFACE`) or direct cable — no route to the plant LAN. Jumbo frames on that NIC only.
- Plant LAN: node in zone Z2; firewall allows **outbound only** to the central (443), NTP (123), the registry (443) and — optionally — MQTT (8883). Nothing inbound (SSH only when enabled, from the maintenance VLAN).
- DNS for the sync URL; the CA is pinned so DNS games achieve nothing (SEC-E20).

## 4. Provisioning (≤ 30 min, no developer — NFR-09)

### 4.1 Steps
| # | Step | Time | Who |
|---|---|---|---|
| 1 | Flash the device image (`edgeguard-<device>-<ver>.img`: OS + Docker + NVIDIA runtime + `edgeguard.service` + `usbguard` + `chrony`) | 10 min | technician |
| 2 | Boot; log in on the console **once** (provisioning account, removed at step 7); set the disk encryption per §2.4 | 3 min | technician |
| 3 | Copy `/etc/edgeguard/node.yaml` from the template ([`node.yaml.example`](../deploy/node.yaml.example)); fill `node_code`, plant/line/station, camera serial, `plc_io` from the panel drawing, `sync.url` | 5 min | technician |
| 4 | Copy `/etc/edgeguard/secrets/{ca.crt,node.crt,node.key}` (issued by the fleet admin from the internal CA with CN = `node_code`), `pin.hash`, `tech.hash` — all 0600 root | 2 min | technician (files from fleet admin) |
| 5 | Copy `/etc/edgeguard/.env` from [`.env.example`](../deploy/.env.example) with the device-class block and image digests from the current signed bundle | 2 min | technician |
| 6 | `systemctl enable --now edgeguard` → the stack starts; FAULT until config. Online: bundle pulls in ≤ 5 min. Air-gapped: `edgectl bundle apply /media/usb/eg-bundle/` | 5 min (+ engine build 1–5 min) | technician |
| 7 | `edgectl provision finish` — records hash(`node.yaml`), removes the provisioning account, disables SSH unless `ssh.enabled`, runs the self-test | 1 min | technician |
| 8 | Commissioning checklist (§5) | 10 min | technician + controls engineer |

### 4.2 `node.yaml` reference
Every key is documented inline in [`node.yaml.example`](../deploy/node.yaml.example). The ones that hurt when wrong:

| Key | Wrong value → symptom |
|---|---|
| `node_code` ≠ certificate CN | `sync:AUTH_FAILED`; central rejects everything |
| `camera[].serial` | `CALIBRATION_STALE` at boot (fingerprint mismatch) |
| `plc_io.signals.*` | Verdicts on the wrong PLC input — caught by commissioning check 1, never by software |
| `plc_io.output_type` pnp/npn | Outputs inverted or dead |
| `plc_io.no_read_as` | NO_READ parts routed wrongly (never PASS regardless) |
| `identity.fallback` | Unknown SKU stops the line (`fault`) or runs the last recipe (`last`) |
| `hardware.precision: int8` without the recall gate | Model refused at verify |
| `lab.software_trigger: true` in production | Security finding — TC-087 |

### 4.3 `.env` reference
Runtime knobs only; listed and commented in [`.env.example`](../deploy/.env.example). Image **digests** come from the signed bundle; never edit them by hand except on an air-gapped site following §7.4.

### 4.4 Certificates
Fleet admin issues from the internal CA: `edgectl ca issue --cn L2-ST3 --days 365` → `node.crt`, `node.key`. Renewal at 30 days remaining via the bundle (`credentials.renew`) or `edgectl cert renew` on site; the old certificate stays valid until the new one has completed one heartbeat (SEC-E23). Revocation: central denies the CN.

## 5. Commissioning checklist

The twelve checks of OPS-01 §3.6 apply unchanged; the node-side essentials, each mapped to a TC:

| # | Check | Pass criterion | TC |
|---|---|---|---|
| 1 | I/O map | `edgectl io test` toggles each output; controls engineer confirms each PLC input | TC-020 |
| 2 | Trigger → pulse | One pulse per trigger, `pulse_ms` correct, no overlap at line rate | TC-021 |
| 3 | Camera unplug | FAULT ≤ 10 s; PLC holds | TC-022 |
| 4 | Node power off | PLC sees FAULT (NC relay) | TC-023 |
| 5 | Absence ≠ PASS | PLC timeout configured (`timeout_ms`) and verified to hold | TC-029 |
| 6 | Self-test | `POST /selftest` passes; per-stage latency within budget | — |
| 7 | Calibration | `POST /calibration/check` with the gauge block within tolerance | — |
| 8 | Quality gate | Cover the lens → NO_READ `EXPOSURE`, routed per `no_read_as` | TC-017 |
| 9 | Identity | Scan a label → correct SKU/lot on HMI and in records | — |
| 10 | Sync | Central shows the node in `/edge/nodes`; a test record arrives; heartbeat every 60 s | TC-051 |
| 11 | HMI | Operator walkthrough with gloves at 1 m; language set | TC-080 |
| 12 | Security | `nmap` from the LAN shows nothing but SSH (if enabled); USB stick blocked | TC-084, TC-093 |

Sign-off by the controls engineer and the line supervisor; the checklist is attached to the node's record on the central.

## 6. Day-to-day operation

### 6.1 Observability
| Signal | Where | Meaning |
|---|---|---|
| `/status` | node, HMI status strip | READY/FAULT with reasons; buffer; disk; thermal; sync |
| Heartbeat | central `/edge/nodes`, fleet dashboard | Missing 3 → central alarm (FR-26) |
| Node metrics | `127.0.0.1:9100/metrics`, summarised into the heartbeat | fps, latency p50/p95, ring backpressure, verdict counts, sync backlog, disk, temp |
| `node_event` | synced to central `ops.node_event` | boot (cause), faults, model/config/calibration changes, PIN attempts, tamper |
| Diagnostics bundle | `POST /diagnostics/bundle` → `edgectl diag pull` | For support tickets; redacted (SEC-E52) |

### 6.2 Alert rules (fleet)
| Alert | Condition | Severity |
|---|---|---|
| Node FAULT | `ready = 0` for > 60 s during a shift | P1 |
| Heartbeat missing | 3 consecutive | P1 |
| Backlog rising | `buffer_depth` growing for > 30 min | P2 |
| Stuck records | `stuck > 0` | P2 (master data) |
| Disk reserve | `free_pct < min_free_pct` | P2 |
| Thermal | `throttled` for > 10 min | P2 |
| NO_READ spike | > 5 % over 15 min | P2 |
| Override rate | > 20 per shift | P3 (quality review) |
| Model verify failed / config invalid | event | P2 |
| Tamper / PIN lockout | event | P2 (security) |

### 6.3 SLOs
| SLO | Target | Measured by |
|---|---|---|
| Inspecting during production shifts | ≥ 99.5 % (NFR-06) | `ready` time series from heartbeats |
| Cold boot to READY | ≤ 90 s (NFR-05) | `node_event boot` → first READY |
| Trigger → pulse | ≤ 200 ms p95 (NFR-02) | node metrics |
| Records lost | 0 (AC-02) | central dedup report vs node counters |

## 7. Updates (OTA)

### 7.1 Order of operations for any change
**One node first** (a designated canary station), one full shift, then the line, then the plant. Config and model changes are decided on the central (VisionOps recipe/model promotion); the node only executes.

### 7.2 Config
Central edits → new ETag → nodes pull within 5 min → validate → atomic apply. Invalid → `config:INVALID` alarm, previous kept (QAS-07). The bundle's `stations[].plc_io` overrides `node.yaml` — **a PLC map change through the bundle still requires commissioning check 1** (TC-076).

### 7.3 Models
Manifest in bundle → download → sha256 → engine build (`FAULT: ENGINE_BUILDING` on the canary is expected; schedule between shifts) → shadow ≥ 200 frames → central reads disagreement → central promotes → node activates; previous kept. Rollback: central bundle or `POST /models/{name}/rollback` on the node (offline-capable).

### 7.4 App images
Bundle carries `app.image` + `app.digest` per service. `edgectl app update` pulls by digest, restarts services **one at a time** (store last), health-checks each, and rolls back automatically on failure (TC-101). Never during a shift unless `app.allow_in_shift`. Air-gapped: `images.tar` in the USB bundle; digests verified after load.

### 7.5 Air-gapped bundle
`eg-bundle/` = `bundle.json` + `bundle.sig` (Ed25519 by the fleet key) + `models/` + `images.tar` (optional). `edgectl bundle apply /media/usb/eg-bundle/` runs signature → config validation → model verify → app update. The USB stick must be on the `usbguard` allowlist by serial.

## 8. Backup and recovery
- **Nothing on a node is precious except unsynced rows.** Everything else is on the central or in the bundle.
- Before a risky action (SSD swap, re-provision): `edgectl store backup /media/usb/` = `VACUUM INTO` while running, plus the image cache for unsynced records.
- Re-provisioned or replacement node: restore the store file → `sync` drains the old UUIDs → the central deduplicates (RB-14).

## 9. Runbooks

| RB | Symptom | Diagnose | Fix |
|---|---|---|---|
| **RB-01** | FAULT: `camera:DISCONNECTED` | `/status.camera`; link LED; PoE injector; `edgectl camera list` | Reseat/replace cable or injector; camera auto-reconnects; READY after one good frame. Persistent → swap camera (**recalibrate**, ICD-03 §3) |
| **RB-02** | FAULT: `camera:FROZEN` (latched) | Live view on HMI static; `node_event frozen` | Remove the obstruction / restart camera; **PIN clear** on HMI; review the records around the event for a tampering pattern (SEC-03 §4.2) |
| **RB-03** | NO_READ spike | `/counters.no_read_reasons`: `EXPOSURE` → light/strobe; `BLUR` → focus/vibration; `NO_PART` → trigger timing | Fix light (IF-18), refocus (**recalibrate if the lens moved**), adjust trigger delay with the controls engineer |
| **RB-04** | Latency over budget / FAULT `thermal:OVER_BUDGET` | `/status.thermal`, `/selftest` stage latencies; `tegrastats` in the bundle | Clean heat-sink, check ambient (§2.3), reduce `nvpmodel`, confirm the engine is FP16 not FP32; if the model grew, revisit precision with the ML owner |
| **RB-05** | PLC not receiving verdicts | `edgectl io test`; analyser; `/status.ready`; `plc_io` vs panel drawing | Fix wiring/`output_type`/pin map; commissioning check 1–2; if READY is low, see the FAULT reason first |
| **RB-06** | `CALIBRATION_STALE` | `/status.calibration`: `fingerprint_ok=false` → camera/lens/mount changed; `valid=false` → central invalidated | Run the calibration flow on the central (VisionOps) or apply a bundle with the new calibration; `POST /calibration/check` to confirm |
| **RB-07** | Buffer rising / `SYNC_TARGET_UNREACHABLE` | `/sync/status`: TLS error → certificate/CA; connect timeout → network; 401 → CN/revocation; `rejected` → master data | Fix the cause; `POST /sync/flush`; watch `stuck` drain. The line never needed you — buffer is fine for 72 h |
| **RB-08** | `disk:RESERVE` | `/status.disk`; `v_purge_candidates` count; is sync stuck? (RB-07) | Sync first (purge needs synced rows); lower `pass_image_sample_rate` in the bundle; if the SSD is simply full of unsynced data after > 72 h, fix sync — never delete by hand |
| **RB-09** | Model load failed / `ENGINE_BUILDING` stuck | `/models`: `stage=failed`, engine `state`; `node_event model_verify_failed` | Verify failed → check the artefact source, re-publish; build stuck > 10 min → `edgectl engine rebuild`; the node is on the previous model meanwhile (AI-07). Rolling back on the node without rolling back on the central means the next pull re-promotes — do both |
| **RB-10** | `thermal:THROTTLE` alarm (not FAULT) | `/status.thermal.temp_c` trend in the bundle | As RB-04; schedule enclosure work; no line impact yet |
| **RB-11** | FAULT: `store:STORE_RECOVERED` (latched) | Boot event shows `quick_check` failed; `edgeguard.db.corrupt-<ts>` present | Copy the aside file off (`edgectl store salvage`) — it may hold unsynced rows; hand to support; **PIN clear** to resume; investigate power/SSD health |
| **RB-12** | Config not applied / `config:INVALID` | `/config`: ETag old; `node_event config_rejected` with reason (class not in class_map, signature, schema) | Fix on the central (recipe references a class the active model lacks → promote the model first, or fix the recipe); nodes re-pull in 5 min |
| **RB-13** | `sync:AUTH_FAILED` / certificate expiry | `/sync/status.last_error`; `edgectl cert show` | Renew (`edgectl cert renew` or bundle); if revoked by mistake, re-enable on the central; CN must equal `node_code` |
| **RB-14** | Node replacement with unsynced data | `/status.buffer.records > 0` on the dead/dying node | Pull the SSD (or `edgectl store backup`); provision the replacement (§4) with the **same `node_code`** and a new certificate; restore the store file *before* first start; `sync` drains the old UUIDs; the central deduplicates any that had already arrived (AC-06). Retire the old certificate |

## 10. Retiring a node
`edgectl store backup` (if any unsynced) → revoke the certificate on the central → mark the node retired in `/edge/nodes` → wipe: `edgectl wipe` (crypto-erase of the LUKS volume) → remove `node.yaml` and secrets → physical removal. The `node_code` may be reused by a replacement at the same station.

## 11. Traceability
| SRS-03 | Section |
|---|---|
| C-01 offline ≥ 72 h | §1, RB-07 |
| C-03 runtime / precision | §2.1 |
| C-04 reprovisionable ≤ 30 min | §4 |
| C-05 unattended recovery | §2.4 (unattended boot with sealed key), RB-11 |
| FR-13 disk policy | RB-08 |
| FR-22…24 config/model OTA, rollback | §7 |
| FR-25, 26 heartbeat, central alert | §6.1, §6.2 |
| AI-07 fall back on load failure | RB-09 |
| NFR-05 boot ≤ 90 s | §6.3 |
| NFR-06 uptime, watchdog | §6.3, IF-24 |
| NFR-07 TLS/identity | §4.4, RB-13 |
| NFR-09 provisioning | §4 |
| NFR-10 diagnostics without shell | §6.1 |
| AC-02, AC-05, AC-06 | RB-07, RB-08, RB-14 |
