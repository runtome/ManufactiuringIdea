# Deployment & Operations Guide — PocketQC Offline Mobile Inspector

| Field | Value |
|---|---|
| Document ID | OPS-05-PocketQC |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/managed-config.example.json`](../deploy/managed-config.example.json) · [`deploy/policy.example.json`](../deploy/policy.example.json) · [`deploy/checklists/RAD-500-A-incoming.yaml`](../deploy/checklists/RAD-500-A-incoming.yaml) · [`deploy/models/manifest.example.json`](../deploy/models/manifest.example.json) · [`deploy/schemas/`](../deploy/schemas/) · [`deploy/release-checklist.md`](../deploy/release-checklist.md) |
| Related | [SAD-05](SAD-PocketQC-Software-Architecture.md) · [ICD-05](ICD-PocketQC-Interface-Control.md) · [SEC-05](SEC-PocketQC-Security-Requirements.md) · [TEST-05](TEST-PocketQC-Test-Plan.md) · [UM-05](UM-PocketQC-User-Admin-Guide.md) · platform side: [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) |
| Audience | Mobile admin (MDM, releases), quality admin (checklists, models, policy on the platform), support |

---

## 1. What you are operating

**There is no server to run.** PocketQC deploys as an Android app on company-managed devices; everything server-side is the FactoryBrain platform's `/mobile/*` (OPS-00). This guide is therefore about **devices, configuration, content and support** — not containers. Deliberately, there is no `docker-compose.yml` in this set.

Three facts shape every procedure:
- **Devices are offline most of the time.** Anything you change (checklist, model, policy, wipe) reaches a device on its *next Wi-Fi contact*, which the SRS assumes is at least daily. Plan changes a day ahead; verify with the fleet view.
- **Configuration is pushed, never typed on the device.** Server URL, certificate pins, device id, offline window and share policy come from **managed configuration** (IF-33). A device with wrong config is fixed by the MDM, not by an inspector.
- **A lost device is a procedure, not a panic.** Encrypted at rest; wipe on next contact; the only loss is unsynced work (SEC-05 §4.2).

## 2. Devices

### 2.1 Certified device classes
| Class | Example | Delegate | Latency (TC-022) | Role |
|---|---|---|---|---|
| **Reference** | Samsung Galaxy Tab Active4 Pro (rugged, IP68, glove mode) | NNAPI | gate applies | All gates measured here |
| Mid-range phone | Samsung A5x / Pixel 7a | GPU | recorded | Functional |
| Low-end | Any Android 10+ ARM64 with 4 GB | CPU/XNNPACK | recorded, may exceed 500 ms | Functional; flagged in heartbeat |

Requirements: Android 10+ (target 14), ARM64, ≥ 4 GB RAM, autofocus camera, ≥ 8 GB free, Play Integrity passing (or the MDM's own attestation). Optional: ring light with a mount; ArUco marker cards (20 mm and 50 mm, printed on rigid stock, dictionary `DICT_4X4_50`).

### 2.2 Enrolment (Android Enterprise, work-managed or COPE)
1. Enrol the device in the MDM; assign the **PocketQC device profile**: passcode required (≥ 6 digits or biometric), screenshots blocked, USB debugging blocked, backup blocked, Wi-Fi profiles for the factory SSIDs, app auto-update on Wi-Fi.
2. Assign the app (managed Play or private APK) and the **managed configuration** (§4).
3. First launch: the app reads the configuration, shows the server name, and asks for login (online). Login caches the token for the offline window.
4. Bootstrap runs; models download and self-test; the home screen shows "ready — N checklists, models OK".
5. Hand over with the laminated card (UM-05 Appendix).

## 3. Releases
Follow [`deploy/release-checklist.md`](../deploy/release-checklist.md). Builds: `flutter build apk --release --split-per-abi`; ≤ 200 MB per ABI including the bundled self-test samples (C-02); signed with the release key. Distribute via managed Play (staged rollout 10 % → 100 %) or the MDM's private app store. Migrations are forward-only: a downgrade requires a wipe — say so in the release notes.

## 4. Managed configuration (every key)

Template: [`managed-config.example.json`](../deploy/managed-config.example.json); schema: [`managed-config.schema.json`](../deploy/schemas/managed-config.schema.json).

| Key | Set to | Wrong value → symptom |
|---|---|---|
| `server_url` | `https://factorybrain.plant.local` | Login blocked with "no server configured" / "server not reachable" |
| `cert_pins` | current **and** backup SPKI pins (≥ 2) | TLS refused → "cannot verify server"; nothing syncs (TC-098). **Rotate pins before the certificate changes** |
| `device_id` | company asset id (`TAB-07`) | Wrong id → refresh token binding fails on another device; fleet view shows the wrong name |
| `sync_network` | `wifi` (default) / `any` | `any` on cellular-capable devices costs data; policy may override |
| `offline_days` | 30 (1–90) | Too long = longer exposure of a lost device; too short = inspectors locked out in remote areas |
| `gps_enabled` | false unless required | Privacy; battery |
| `allowed_share_targets` | company mail/Teams packages; empty = any | Empty lets a PDF go anywhere (SEC-05 §8) |
| `require_device_lock` | true | false only on kiosk-mounted devices in a controlled room |
| `lang_default` | `th` | Users can switch at runtime |
| `low_space_warn_pct` / `crit_pct` | 20 / 10 | |
| `debug_diagnostics` | false in production | Extra diagnostics screen (never secrets) |

Changes apply on the next app start. The MDM is the only way to change these (ADR-M09).

## 5. Platform-side content (quality admin)

| Content | Where | Validation | Reaches devices |
|---|---|---|---|
| **Checklists** | platform admin → bootstrap bundle | `checklist.schema.json` on publish **and** on the device; every `photo_ai` class must exist in the referenced model's class map; SKU pattern must not overlap another active checklist | next bootstrap (ETag) |
| **SKUs, defect codes** | platform master data | — | next bootstrap |
| **Models** | platform model registry → `/mobile/models` | `model-manifest.schema.json`: ≤ 25 MB, INT8, `samples_url` + expected classes, AI-02 metrics; the device also runs the **self-test** before activation | next sync; activation only after the on-device self-test passes |
| **Policy** | platform → `/mobile/policy` | `policy.schema.json` | next sync |
| **Wipe** | platform device page → command | — | next contact (also do the MDM wipe) |

Checklist authoring notes: use the [`RAD-500-A-incoming.yaml`](../deploy/checklists/RAD-500-A-incoming.yaml) file as the template; quote the `"no"` key (a YAML 1.1 parser reads bare `no` as `false`); keep `review_band` at 0.1 unless the quality engineer asks; measurement steps need the marker size that matches the printed cards.

**Prerequisite:** the platform must serve IF-11 **v1.1** (API-05) for models, images, policy, heartbeat and wipe. Until then, only bootstrap and session upload work, and wipe relies on the MDM path alone (README-05 known gaps).

## 6. Day-to-day operation

### 6.1 Fleet view (from heartbeats)
Per device: last contact, app/model versions, self-test state, delegate, pending sessions/images, stuck, storage free %, battery, offline window expiry. Alerts:

| Alert | Condition | Action |
|---|---|---|
| Device silent | no heartbeat > 2 days | RB-01 |
| Backlog | pending sessions > 100 or images > 500 | RB-02 |
| Stuck records | `stuck > 0` | RB-03 (master data) |
| Storage | free < 20 % / < 10 % | RB-04 |
| Offline window expiring | < 5 days | RB-05 |
| Model self-test failed | heartbeat `selftest_passed=false` for the target version | RB-06 |
| CPU delegate on a reference device | `delegate=cpu` where NNAPI expected | RB-07 |
| Root/integrity failure | login/sync blocked event | SEC-05 §7 |

### 6.2 SLOs
| SLO | Target | Source |
|---|---|---|
| Sync within 24 h of a session | ≥ 99 % | server receipt time vs `finished_at` |
| Lost sessions | 0 | device counters vs server (weekly reconciliation) |
| Crash-free sessions | ≥ 99.5 % (NFR-08) | device-local crash log uploaded with heartbeat metadata (no third-party service, NFR-09) |
| Inspection time (20 steps) | median ≤ 4 min (NFR-02) | `started_at`/`finished_at` |

### 6.3 Retention and purge
Policy `retention_days` (default 60) purges **synced** sessions and their images on the device; unsynced data is never purged. Server-side retention is the platform's (OPS-00). Low space: 20 % warn (harder compression), 10 % purge synced PASS images first, single capture only.

### 6.4 Model and checklist updates
Model: publish manifest (+ samples) → canary device group → check heartbeat `selftest_passed` and latency → widen. A failed self-test on a device class means that class keeps the previous model — expected, not an error. Rollback: `rollback_model` command or republish the previous manifest as current.
Checklist: publish new version → devices take it at next bootstrap; sessions in progress keep their version; retire the old version after a week.

### 6.5 Certificate rotation
Add the new pin to managed configuration **at least one sync cycle before** the server certificate changes; keep both pins for a month; then remove the old one. A device that missed the window will refuse TLS (RB-08) — the MDM push of a corrected config is the fix, since the app cannot reach the server to fetch it.

## 7. Lost device
1. Inspector reports the loss → admin marks the device **lost** on the platform (queues `wipe`, revokes the refresh token) **and** issues the MDM wipe.
2. Whichever path reaches the device first wipes it; the platform path flushes unsynced sessions for up to 60 s first (API-05 §4).
3. Reconcile: the fleet view shows the last heartbeat's pending count — those sessions are re-inspected.
4. Incident record; replacement device enrolled (§2.2) with a **new** `device_id`.

## 8. Support bundle
`Diagnostics → Export support bundle` (technician or admin): app/OS versions, managed-config keys (no pins values), delegate and latency p95, sync log, `v_pending_sync`, last 200 log lines, DB `quick_check` result. **Never** tokens, keys, images, lot text (SEC-M55). Sent via an allowed share target.

## 9. Runbooks

| RB | Symptom | Diagnose | Fix |
|---|---|---|---|
| **RB-01** | Device silent (no heartbeat) | Is it in use? MDM last seen; Wi-Fi profile | Ask the inspector to open the app on Wi-Fi; check `cert_pins`/`server_url` in the MDM; RB-08 if TLS refused |
| **RB-02** | Sync backlog rising | Fleet view pending; device shows "pending N" | Wi-Fi coverage at the workplace; `sync_network: any` if cellular is acceptable; manual sync from the home screen |
| **RB-03** | Stuck records (`CHECKLIST_UNKNOWN`, `SKU_UNKNOWN`) | Sync log detail | Fix master data on the platform (the checklist version/SKU the device used); device retries automatically |
| **RB-04** | Storage low | `v_storage`; pending images | Get the device on Wi-Fi (uploads free space); lower `jpeg_quality`/`max_edge_px` in policy; never delete by hand |
| **RB-05** | Offline window expiring / expired | Fleet view `offline_valid_until` | Inspector logs in online once; consider a longer window for remote sites (max 90) |
| **RB-06** | Model self-test failed on a device class | Heartbeat `selftest_json` (recall, latency) | Expected behaviour; the previous model stays. ML owner reviews the class's samples/latency; republish or exclude the class |
| **RB-07** | Inference slow / delegate fell back to CPU | Diagnostics screen latency p95; delegate | App update re-probes; check the device is on the certified list; NNAPI driver update via OS |
| **RB-08** | "Cannot verify server" (pin mismatch) | Cert changed without pin rotation | Push corrected managed configuration via MDM; §6.5 |
| **RB-09** | Barcode not recognised / wrong checklist | Label format vs `identity.pattern`; unknown SKU | Fix the pattern or add the SKU on the platform; manual selection meanwhile |
| **RB-10** | OCR consistently wrong on a marking | Raw vs corrected in step results | Corrections are stored; collect them for the OCR model owner; inspectors keep using one-tap correction |
| **RB-11** | Measurement drift | Marker card damaged/wrong size; working distance | Replace the card; re-run TC-028 with the gauge |
| **RB-12** | PDF fonts wrong (boxes) | App version < font bundle | Update the app; fonts are embedded, not system |
| **RB-13** | DB corruption event | Support bundle `quick_check` | The app moved the file aside and continued; export the aside file through the MDM channel for recovery; unsynced sessions in it may be recoverable with the device's key — decide within the lost-device policy |
| **RB-14** | Device replacement with unsynced data | Old device still works? | Put it on Wi-Fi and let it sync first; if dead, the data is gone (encrypted) — re-inspect; enrol the new device with a new id |

## 10. Traceability
| SRS-05 | Section |
|---|---|
| §2.3, §2.5 | §2 |
| C-02 | §3 |
| FR-21, FR-25, FR-30 | §4, §6.3 |
| FR-22, FR-26, AI-06 | §5, §6.4 |
| FR-27 | §4 `offline_days`, RB-05 |
| FR-28 | §7 |
| NFR-08, NFR-09 | §6.2 |
| AC-02 | §6.2 reconciliation |
