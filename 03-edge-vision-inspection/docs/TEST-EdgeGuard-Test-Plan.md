# Test Plan & Test Cases — EdgeGuard Edge Vision Node

| Field | Value |
|---|---|
| Document ID | TEST-03-EdgeGuard |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Basis | [SRS-03](../SRS-EdgeGuard-Edge-Vision-Inspection.md) FR-01…26, AI-01…07, NFR-01…10, AC-01…08, C-01…05 · [SAD-03](SAD-EdgeGuard-Software-Architecture.md) QAS-01…12 · [SEC-03](SEC-EdgeGuard-Security-Requirements.md) · [ICD-03](ICD-EdgeGuard-Interface-Control.md) |
| Executed so far | **TS-0 in full** on the authoring machine (Python 3.14, `sqlite3` 3.50.4, `openapi-spec-validator`, `pyyaml`). Everything from TS-1 onward needs hardware (camera, PLC or simulator, a Jetson) or the lab compose — **not executed**, specified. |

---

## 1. Strategy

### 1.1 What is different about testing a device
- **The line path is tested against physical signals**, not HTTP. The reference rig is the **edge-lab**: a node under test, a PLC simulator (GPIO loopback + logic analyser), a camera replay source (`v4l2loopback` fed from a folder) and the VisionOps (01) stack as the central. [`deploy/lab-compose.override.yml`](../deploy/lab-compose.override.yml) is that rig.
- **Fail-safe is the first gate.** A build that passes every functional test but leaves READY high after a camera unplug does not ship (TS-2 fault truth table, TS-8).
- **Power cuts are a test input.** A relay on the node's supply, scripted, is part of the rig. AC-03 is ×10 hard cuts mid-inspection.
- **Offline is the default state in tests**, not a special case. The central is turned off for most suites; TS-5 turns it on to watch the drain.
- **Things that run on the authoring machine run now** (TS-0): the SQLite schema and seed actually execute; the payload mapping and the client-contract identity are checked programmatically; compose/env/YAML parse.

### 1.2 Levels
| Level | Scope | Runs |
|---|---|---|
| L0 Static / executable artefacts | schema, seed, mapping, OpenAPI, compose, YAML, env | every commit, no hardware |
| L1 Unit | rules engine, fault manager truth table, sync state machine, quality gate maths | every commit |
| L2 Integration (lab) | node + camera replay + PLC sim + 01 central | nightly |
| L3 Hardware-in-the-loop | real camera, real PLC I/O card, power relay, thermal chamber/cabinet | release |
| L4 Site acceptance | AC-01…08 on the production line | commissioning |

### 1.3 Entry / exit
- Entry to L2: L0 + L1 green; lab rig self-test passes.
- Exit for release: all Must FR TCs pass; **all TS-2 fault truth table TCs pass**; TS-5 72 h test passed once on the reference device; TS-9 power-cut ×10; no open critical defect; residual risks acknowledged (SEC-03 §8).

### 1.4 Reference devices and settings
| Device | Runtime | Model precision | Used in |
|---|---|---|---|
| Jetson Orin Nano 8 GB, JetPack 6 | TensorRT | FP16 | all L2/L3 (reference) |
| x86 mini-PC + RTX 3060 | TensorRT | FP16 | TS-3, TS-11 second data point |
| Raspberry Pi 5 + Hailo-8L | HailoRT | INT8 | TS-3 TC-113 only |

---

## 2. Test suites and cases

Notation: **[X]** executed and passed on the authoring machine · **[ ]** specified, not yet run · Pri M/S = Must/Should.

### TS-0 — Build, schema, seed, contracts (L0)

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-001 | Compose and YAML parse | `docker compose -f deploy/docker-compose.yml -f deploy/lab-compose.override.yml config`; parse `node.yaml.example`; check anchors resolve and no service mixes `network_mode` with `networks` | All parse; 9 node services as in SAD-03 §4.2 + 3 lab services | M | [X] PyYAML parse + anchor/conflict checks; `docker compose config` **not run** (Docker daemon unavailable on the authoring machine) |
| TC-002 | Schema executes | `sqlite3` in-memory, `executescript(schema.sql)`; `PRAGMA integrity_check`, `foreign_key_check` | ok / empty; 17 tables, 5 views, 14 explicit indexes, 3 triggers | M | [X] |
| TC-003 | Constraints and triggers carry weight | Insert second `node_info` row; insert `override` with same old/new verdict; set `model_cache.stage='active'` without `verified_at`; delete an inspection that has an override; insert a fifth verdict | Each rejected with the named constraint/trigger; a `downloaded` row without `verified_at` is allowed; a second `active`/`previous`/`shadow` for the same name is rejected by the partial unique index | M | [X] — found defect #6 |
| TC-004 | Compose has no LAN exposure or unnecessary privilege | Static scan of compose: no `ports:` anywhere; `privileged` absent; `devices:` only on `capture` (camera), `supervisor` (GPIO) and `inference` (accelerator); store mounted read-write only by `store`; every `${VAR}` in `.env.example` and vice-versa | As listed | M | [X] 0 ports, 0 privileged, devices on exactly those three, store rw only by `store`, env coverage exact both ways |
| TC-005 | Seed executes with expected values | `executescript(seed_demo.sql)`; run the verification `SELECT`s in the seed header | 2,000 inspections (PASS 1,940 / FAIL 40 / REVIEW 12 / NO_READ 8); unsynced 150 = FAIL 5 / REVIEW 2 / NO_READ 2 / PASS 141; `sync_queue` 151 with 8 at priority 1; `image_queue` 16; images cached 76; purge candidates 60 with **0 unsynced and 0 queued**; overrides 3; effective REVIEW 9; `v_ready` = 1 with alarm `config:SYNC_TARGET_UNREACHABLE`; stages active 2 / previous 1 / shadow 1; detections 52; measurements 50; anomaly 200; re-seed refused by `node_info` trigger | M | [X] |
| TC-006 | Payload mapping complete | Load `01/api/openapi.yaml` `InspectionCreate`; compare to `db/payload_mapping.json`; check every local column named exists in `schema.sql` | 4 required + 16 properties: 0 unmapped, 0 unknown, 0 dangling column references | M | [X] |
| TC-007 | No secrets in examples | Grep `node.yaml.example`, `.env.example`, seeds for key material, real PINs, tokens | None; placeholders only | M | [X] |
| TC-008 | Client-contract identity | Structural diff of `Verdict`, `Detection`, `Measurement`, `AnomalyResult`, `RecipeRules`, `InspectionCreate`, `BatchResult`, `NodeHealth`, `ModelManifest`, `EdgeConfig`, `Problem` between `03/api/openapi.yaml` and `01/api/openapi.yaml` | All 11 identical | M | [X] |
| TC-009 | OpenAPI valid | `openapi-spec-validator`; unique operationIds; every op has a 2xx; no undefined `$ref`; only the three client-contract schemas unreferenced by paths | Pass; 19 paths / 19 ops | M | [X] |

### TS-1 — Capture and sensor (L2/L3) — IF-02, IF-18

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-010 | Hardware trigger | PLC sim pulses TRIGGER ≥ 5 ms at 2 Hz for 10 min | One frame per trigger; `frame_id` monotonic; 0 missed | M | [ ] |
| TC-011 | Software trigger (lab) | `POST /inspect` ×100 with `lab.software_trigger: true`; then with it false | 100 records; 403 `LAB_DISABLED` | M | [ ] |
| TC-012 | Free-run mode | `trigger_mode: freerun` at 10 fps | Continuous records; multi-frame tracking active (TC-115) | S | [ ] |
| TC-013 | Camera disconnect | Unplug GigE cable during inspection; replug after 60 s | `FAULT: camera:DISCONNECTED` ≤ 10 s; READY low; auto-reconnect; READY high after one good frame; events synced | M | [ ] |
| TC-014 | Frozen feed | Replay the same frame for 3 triggers | `FAULT: camera:FROZEN` by the 2nd; **no PASS pulse**; latched until PIN clear | M | [ ] |
| TC-015 | Replay / frame-id regression | Replay source with non-monotonic `ChunkFrameID` | `REPLAY_SUSPECT` alarm; FAULT after 3 | M | [ ] |
| TC-016 | Device clock skew | Offset camera timestamp by 800 ms | `camera:CLOCK_SKEW` alarm; records carry both times | S | [ ] |
| TC-017 | Quality gate → NO_READ | 20 blurred + 20 over-exposed + 20 empty frames | 60 `NO_READ` with correct `no_read_reason`; **no inference ran**; PLC gets `no_read_as` (REVIEW), never PASS; HMI counters show NO_READ | M | [ ] |
| TC-018 | Strobe fault | Disconnect strobe input | NO_READ `EXPOSURE` spike → `light:SUSPECT` alarm within 5 min; inspection continues | S | [ ] |
| TC-019 | Two cameras, shared GPU queue | Two replay sources, two recipes | Independent verdicts; combined p95 within budget; no cross-talk in records | S | [ ] |

### TS-2 — Rules, verdict I/O and the fault truth table (L2/L3) — IF-03

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-020 | I/O commissioning toggle | `edgectl io test` each output | Each seen at the correct PLC input per `plc_io` | M | [ ] |
| TC-021 | One trigger, one pulse | 1,000 triggers, logic analyser on PASS/FAIL/REVIEW | Exactly one pulse per trigger, `pulse_ms` ± 5 ms, no overlap | M | [ ] |
| TC-022 | Camera unplug → FAULT ≤ 10 s | as TC-013, measured at PLC | FAULT high, READY low ≤ 10 s | M | [ ] |
| TC-023 | Node power off → FAULT | Cut node power | FAULT input high at PLC (NC relay / I/O module watchdog) within 1 s | M | [ ] |
| TC-024 | `store` killed → FAULT | `kill -9` the store process | FAULT; no pulses; watchdog restart; READY after self-test | M | [ ] |
| TC-025 | Pulse never precedes record | 1,000 triggers with random power cuts (TC-044 rig); after each boot, compare analyser pulses to `inspection` rows | Every pulse has a row; rows without pulse allowed (never the reverse) | M | [ ] |
| TC-026 | 2× line rate | Trigger at 4 Hz for 2 min | No overlapping pulses; `ring_full` metric > 0; sustained → FAULT, not silent drops | M | [ ] |
| TC-027 | Verdict matrix | Recipe with class_present, class_count, class_area, measurement, ocr_match rules; crafted frames | PASS/FAIL/REVIEW exactly per rule table; `conflict_policy` honoured | M | [ ] |
| TC-028 | Anomaly → REVIEW only | Frame flagged by anomaly model, no rule hit | REVIEW, never FAIL; `anomaly.flagged=1` | M | [ ] |
| TC-029 | Absence ≠ PASS | Block the verdict pulse (kill supervisor GPIO after commit) | PLC sim times out at `timeout_ms` → hold; no PASS seen | M | [ ] |
| TC-030 | Level-verdict variant | `plc_io.variant: level` | Verdict held until next TRIGGER | S | [ ] |
| TC-031 | Truth table: boot | Power on | FAULT high until self-test; READY low | M | [ ] |
| TC-032 | Truth table: camera sources | disconnected / frozen / no-frame ×3 | READY low, FAULT high, no pulses — each | M | [ ] |
| TC-033 | Truth table: model sources | unload / engine building / sha256 mismatch | READY low, FAULT high, no pulses — each | M | [ ] |
| TC-034 | Truth table: calibration | Invalidate calibration with (a) measurement rule active (b) no measurement rule | (a) FAULT; (b) READY stays high, alarm | M | [ ] |
| TC-035 | Truth table: store | Make `/var/lib/edgeguard` read-only | FAULT `store:UNWRITABLE`; no pulses | M | [ ] |
| TC-036 | Truth table: non-blocking sources | Central unreachable; disk at reserve; thermal throttled within budget | READY **stays high**; pulses continue; alarms shown | M | [ ] |
| TC-037 | Truth table: thermal over budget | Force throttle so p95 > 200 ms for 60 s | FAULT `thermal:OVER_BUDGET`; recovers when p95 returns | M | [ ] |

### TS-3 — Inference and runtime (L2/L3) — AI-01…07

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-110 | Inference latency per device | 10,000 frames, production model, each reference device | p95 ≤ 100 ms (NFR-01) on Orin Nano FP16 and x86; Hailo INT8 recorded | M | [ ] |
| TC-111 | INT8 recall gate | Evaluate FP16 vs INT8 on hold-out | INT8 accepted only if recall on critical classes ≥ 0.98 × FP16 (AI-02) | M | [ ] |
| TC-112 | Engine build visible | Clear engine cache; boot | `FAULT: model:ENGINE_BUILDING` on HMI and `/status`; READY after build; cache hit on next boot (≤ 90 s) | M | [ ] |
| TC-113 | Hailo INT8 only | Deploy FP16 manifest to Pi 5 + Hailo | Rejected at verify (`precision unsupported`); previous stays | S | [ ] |
| TC-114 | Anomaly flags unseen defect | Defect type absent from training classes | `anomaly.flagged`, REVIEW (AC-08) | S | [ ] |
| TC-115 | Multi-frame tracking | One part in 5 frames (free-run) | One record, one pulse on the last frame | S | [ ] |
| TC-116 | Latency and GPU memory logged | Run TC-110 | Per-frame latency and GPU mem in metrics and `node_event` summaries (AI-06) | M | [ ] |

### TS-4 — Local store (L1/L2/L3) — DDS-03

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-040 | Purge never touches unsynced | Seed state; run purge at forced reserve | `v_purge_candidates` ∩ unsynced = ∅ (executed on the seed: 0); no unsynced row or its image deleted | M | [X] on seed / [ ] on device |
| TC-041 | Disk policy at 15 % | Fill disk to reserve | PASS images stop (`pass_images_enabled=0`); FAIL/REVIEW still stored; inspection continues; alarm `disk:RESERVE` | M | [ ] |
| TC-042 | Fill to 90 % (AC-05) | Fill; wait one purge cycle | Purge runs; oldest synced PASS images first; unsynced preserved; records intact | M | [ ] |
| TC-043 | Purge order | Mixed synced PASS/FAIL images with ages | PASS before FAIL; oldest first; queued images excluded | M | [X] on seed / [ ] on device |
| TC-044 | Hard power cut ×10 (AC-03) | Relay cuts supply mid-inspection ×10 | Each boot: `quick_check` ok; READY ≤ 90 s; last committed row present; no pulse without row (TC-025) | M | [ ] |
| TC-045 | Single writer | Attempt a write from `sync`/`hmi` connections | `readonly` error; `store` socket is the only write path | M | [ ] |
| TC-046 | Corruption recovery | Corrupt the DB file; boot | File moved aside; new store; `FAULT: store:STORE_RECOVERED` latched until PIN clear; event synced | M | [ ] |
| TC-047 | 100 k records offline | Generate 100 k records with images per policy | Fits in reserve; query latency for HMI ≤ 50 ms; `v_backlog` correct (NFR-04) | M | [ ] |
| TC-048 | Override blocks purge | Purge a synced record whose override is unsynced | Refused (`ON DELETE RESTRICT`) until override synced | M | [X] constraint / [ ] on device |
| TC-049 | Retention | Synced records older than 30 d | Deleted; FAIL images per 90 d rule; unsynced never | S | [ ] |

### TS-5 — Store-and-forward (L2) — IF-01

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-050 | Batch order | Backlog with mixed verdicts | FAIL/REVIEW batches first; ≤ 500 per batch | M | [ ] |
| TC-051 | `accepted` marks synced | Central accepts | `synced_at` set; dequeued; `v_backlog` decrements | M | [ ] |
| TC-052 | `duplicate` marks synced | Re-send an accepted batch | `duplicate` → treated as success; **no duplicate rows centrally** (AC-06) | M | [ ] |
| TC-053 | `rejected` keeps and escalates | Central rejects (unknown SKU) | Row kept; attempts++; after 5 → `stuck`; alarm on HMI/heartbeat; fixed master data → drains | M | [ ] |
| TC-054 | 413 halves batch | Central limit 100 | Batch size halves; drains | S | [ ] |
| TC-055 | Backoff and jitter | Central down 10 min | Delays 1,2,4…300 s ± 20 %; reset on success | M | [ ] |
| TC-056 | Images after records | Backlog with images | No image upload for an unsynced record; sha256 accepted | M | [ ] |
| TC-057 | Override backlog visible | Override while offline | `v_backlog.overrides` = 1 on HMI; syncs after record (ICD-03 IF-01 known gap acknowledged in test notes) | M | [ ] |
| TC-058 | Identity-bound records | Push with a certificate of another `node_code` | Central rejects / attributes to CN; no cross-node injection | M | [ ] |
| TC-059 | Image window and bandwidth | `image_window 22:00-06:00`, 512 kbps | Originals wait for the window; overlays anytime; throttle honoured; flush overrides | M | [ ] |
| TC-060 | **72 h offline then drain (AC-02)** | Unplug network 72 h at 2 parts/s | 0 records lost; ≥ 100 k buffered; READY throughout; on reconnect all records then images sync; duplicates absorbed | M | [ ] |
| TC-061 | Credential rotation | Renew cert via bundle | New cert used after one heartbeat; old rejected after; no redeploy | M | [ ] |
| TC-062 | Central swap | Change `sync.url` from 01 stack to 00 stack | Sync continues; only the URL changed (QAS-11) | M | [ ] |
| TC-063 | Superset config tolerance | Serve 01's `EdgeConfig` with `calibrations`, `stations`, `sync` plus an unknown key | Known keys applied; unknown listed in `/config.ignored_fields`; no rejection | M | [ ] |

### TS-6 — OTA and config (L2) — IF-22

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-070 | sha256 mismatch on download | Serve a manifest with wrong sha256 | Artefact deleted; `model_verify_failed` event; previous active; alarm | M | [ ] |
| TC-071 | Re-verify on load | Replace the artefact on disk after verification | Next load fails verification; previous activated; event | M | [ ] |
| TC-072 | Engine cache key | Change driver version | Cache miss → rebuild; old entry not used | M | [ ] |
| TC-073 | Load failure → previous (AI-07) | Corrupt the active engine | Previous model active automatically; alarm; never "no model" silently | M | [ ] |
| TC-074 | Config references unknown class | Recipe class not in `class_map` | 422 `CONFIG_INVALID` / online reject; previous config kept; alarm (QAS-07) | M | [ ] |
| TC-075 | Boot hash check | Edit `config_cache` bundle / `node.yaml` on disk | `FAULT: config:TAMPERED` | M | [ ] |
| TC-076 | PLC map change evented | Bundle changes `plc_io` | `node_event plc_map_changed`; in next heartbeat; requires TC-020 re-run (process) | M | [ ] |
| TC-077 | Shadow ≥ 200 frames | Stage v1.1.0 shadow; run 250 frames | `shadow_frames ≥ 200`; disagreement reported in heartbeat; no verdict effect; activate refused at 84/200 with `SHADOW_INCOMPLETE` | M | [ ] |
| TC-078 | Rollback offline | Central off; `POST /models/{name}/rollback` | Previous active; event; heartbeat reports on reconnect (AC-04 second half) | M | [ ] |
| TC-079 | ETag | Two pulls, no change | 304; then change → 200 → applied atomically | M | [ ] |

### TS-7 — HMI and override (L2/L4) — IF-23

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-080 | HMI screens and usability (AC-07) | Walkthrough with gloves at 1 m: live, status strip, degraded banner, history, language TH/JA/EN | All readable/operable; FAULT full-screen; alarms as banner; targets ≥ 24 mm | M | [ ] |
| TC-081 | Override flow and attribution | PIN → reason → confirm on a FAIL | `override` row with `user_ref` (not a name), `reason_code`; effective counts update; queued; synced later | M | [ ] |
| TC-082 | PIN lockout | 6 wrong PINs | 429 after 5; 15-min lockout shown; each attempt a `node_event`; FAULT truth unaffected | M | [ ] |
| TC-083 | Override rate alarm | 21 overrides in a shift | Heartbeat alarm `override:RATE`; central sees it | S | [ ] |

### TS-8 — Security (L2/L3) — SEC-03

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-084 | LAN scan and egress | `nmap` from Z3; firewall log 1 h | Only SSH (if enabled) open; egress only to sync target + NTP | M | [ ] |
| TC-085 | Token/PIN enforced | Call each mutating endpoint without and with credentials | 401 without; success with | M | [ ] |
| TC-086 | Secrets storage | Inspect `/etc/edgeguard/secrets`, `node.yaml`, logs, bundle | 0600 root; hashes only; nothing in `node.yaml`/logs | M | [ ] |
| TC-087 | Nothing raises READY | Try `/fault/clear` with cause present; `/inspect` in production; lockout during FAULT | Re-raised / 403 / FAULT unchanged | M | [ ] |
| TC-088 | Impostor central | Self-signed server at sync URL | TLS refused; `sync:TLS_UNTRUSTED` alarm; nothing sent | M | [ ] |
| TC-089 | Tampered bundle | Flip a byte in `bundle.json` | Signature fails; previous config kept; event | M | [ ] |

### TS-9 — Host and resilience (L3) — IF-24

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-090 | GPIO isolation | Inspect container device mappings | Only `supervisor` has the GPIO/I-O device; `capture` the camera | M | [ ] |
| TC-091 | Disk forensics | Remove SSD; mount elsewhere | Encrypted; unreadable | M | [ ] |
| TC-092 | No autologin / SSH | Console; SSH with password | No login; key-only or disabled | M | [ ] |
| TC-093 | usbguard | Plug an unlisted USB stick | Blocked; event | M | [ ] |
| TC-094 | Tamper input | Open case (sensor) | `security:TAMPER` event synced; latched alarm | S | [ ] |
| TC-095 | NTP skew | Offset host clock 10 s | `time_skew` event; records carry both times | S | [ ] |
| TC-096 | Diagnostics redaction | Build bundle; grep | No key material, hashes, PASS images; lots truncated | M | [ ] |
| TC-097 | Watchdog restart ≤ 30 s | Hang the inference process (SIGSTOP) | FAULT; restart ≤ 30 s; READY after self-test (QAS-10) | M | [ ] |
| TC-098 | Cold boot ≤ 90 s ×10 | Power cycle ×10 | READY ≤ 90 s each; no network needed | M | [ ] |
| TC-099 | Thermal soak | 8 h in a 45 °C cabinet at line rate | No throttle-induced FAULT; latency within budget (QAS-09) | M | [ ] |

### TS-10 — Provisioning and app OTA (L3) — IF-22, NFR-09

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-100 | App image by digest | Bundle with `app.digest`; registry serves a different digest under the tag | Pull refused; previous runs | M | [ ] |
| TC-101 | One-at-a-time restart with rollback | Bundle with a broken image | Service fails health → automatic rollback to previous digest; line path unaffected for services not restarted | M | [ ] |
| TC-102 | **Provisioning ≤ 30 min, no developer** | Technician with OPS-03 §4 only: flash, `node.yaml`, certs, first boot | READY and commissioning checklist done ≤ 30 min (QAS-08) | M | [ ] |
| TC-103 | USB bundle apply | Air-gapped: `edgectl bundle apply /media/usb/eg-bundle/` | Config + models applied with same validation; signature required | M | [ ] |
| TC-104 | First-boot self-test | Fresh node, no config | FAULT `config:MISSING` until bundle; then self-test; READY | M | [ ] |

### TS-11 — Performance (L3) — NFR-01…03, AC-01

| TC | Title | Steps | Expected | Pri | Status |
|---|---|---|---|---|---|
| TC-120 | Sustained 10 fps 1 h | Free-run at 10 fps, production model | ≥ 10 fps sustained; no ring backpressure; memory flat | M | [ ] |
| TC-121 | End-to-end p95 (AC-01) | 1 h live production, analyser at PLC | trigger→pulse ≤ 200 ms p95; infer ≤ 100 ms p95 | M | [ ] |
| TC-122 | HMI under load | `/status` at 2 Hz during TC-120 | Line path unaffected; API p95 ≤ 50 ms | S | [ ] |
| TC-123 | Sync during production | Drain a 100 k backlog while inspecting | Latency budget held; sync throttles itself, not inference | M | [ ] |

---

## 3. Traceability

| SRS-03 | Test cases |
|---|---|
| FR-01 | TC-010, 011, 012 |
| FR-02 | TC-027, TC-034 |
| FR-03 | TC-017 |
| FR-04 | TC-019 |
| FR-05 | TC-027, TC-110 |
| FR-06 | TC-027 (measurement, ocr) |
| FR-07 | TC-028, TC-114 |
| FR-08 | TC-027, TC-028 |
| FR-09 | TC-115 |
| FR-10 | TC-021, TC-121 |
| FR-11 | TC-025, TC-044 |
| FR-12 | TC-041, TC-056 |
| FR-13 | TC-040…043 |
| FR-14 | TC-081, TC-082, TC-076 |
| FR-15, 16 | TC-080 |
| FR-17 | TC-081 |
| FR-18 | TC-080, TC-057 |
| FR-19 | TC-080, TC-036 |
| FR-20 | TC-050…053, TC-060 |
| FR-21 | TC-056, TC-059 |
| FR-22 | TC-063, TC-074, TC-079 |
| FR-23 | TC-070, TC-077 |
| FR-24 | TC-073, TC-078 |
| FR-25 | TC-036 (heartbeat content), TC-083 |
| FR-26 | central-side: ICD-01 / TEST-01 |
| AI-01 | TC-072, TC-112 |
| AI-02 | TC-111 |
| AI-03 | TC-070, TC-071 |
| AI-04 | TC-077 |
| AI-05 | TC-114 |
| AI-06 | TC-116 |
| AI-07 | TC-073 |
| NFR-01…03 | TC-110, TC-120, TC-121 |
| NFR-04 | TC-047, TC-060 |
| NFR-05 | TC-098, TC-112 |
| NFR-06 | TC-097, TC-024 |
| NFR-07 | TC-058, TC-061, TC-088 |
| NFR-08 | TC-041, TC-036 |
| NFR-09 | TC-102, TC-104 |
| NFR-10 | TC-096, TC-087 (status suffices) |
| AC-01 | TC-121 |
| AC-02 | TC-060 |
| AC-03 | TC-044, TC-098 |
| AC-04 | TC-077, TC-078 |
| AC-05 | TC-042 |
| AC-06 | TC-052 |
| AC-07 | TC-080 |
| AC-08 | TC-114 |
| C-01 | TC-060, TC-036 |
| C-02 | TC-059, TC-084 |
| C-03 | TC-111, TC-113 |
| C-04 | TC-001, TC-102 |
| C-05 | TC-044, TC-098 |

## 4. Defects found while executing TS-0

| # | Where | Defect | Fix |
|---|---|---|---|
| 1 | `db/seed_demo.sql` | `SELECT … RAISE(ABORT …)` outside a trigger is invalid SQLite | Removed; the `node_info` single-row trigger is the re-seed guard (verified) |
| 2 | `db/seed_demo.sql` header | Expected unsynced split written as 3/1/1/145 and 40 queued images | Corrected to the executed 5/2/2/141 and 16 (76 cached, 60 purge candidates) |
| 3 | `01/api/openapi.yaml` `AnomalyResult.flagged` | Unquoted comma inside a flow mapping parsed as a bogus `never FAIL: null` key | Quoted (01 still validates); the copy in 03 is identical to the fixed source |
| 4 | `03/api/openapi.yaml` | Same class of defect in six tag descriptions and two property descriptions | Quoted; null-valued-key scan added to TC-009 |
| 5 | `api/*` | Override `reason_code` enum diverged from the local `CHECK` and API-01 | Aligned to `CONFIRMED_DEFECT … OTHER` |
| 6 | `db/schema.sql` | `trg_model_active_requires_verified` guarded only `UPDATE OF stage`; an `INSERT … stage='active'` with `verified_at IS NULL` was accepted (TC-003 probe) | Added `trg_model_insert_requires_verified`; re-executed schema + seed; probe now rejected |

## 5. Release gates
1. TS-0 green on every commit (CI).
2. TS-2 truth table (TC-031…037) and TC-025 green on the reference device — **no exceptions**.
3. TC-044 (power cut ×10), TC-060 (72 h), TC-098 (boot ×10), TC-102 (provisioning) green once per release.
4. TS-8 green; SEC-03 §8 residual risks acknowledged by the plant.
5. AC-01…08 signed at site acceptance.
