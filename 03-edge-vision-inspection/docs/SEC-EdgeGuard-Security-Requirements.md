# Security Requirements Specification — EdgeGuard Edge Vision Node

| Field | Value |
|---|---|
| Document ID | SEC-03-EdgeGuard |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Inherits | [SEC-00](../../00-factorybrain-platform/docs/SEC-FactoryBrain-Security-Requirements.md) (platform baseline) · [SEC-01](../../01-factory-inspector-agent/docs/SEC-VisionOps-Security-Requirements.md) (recipe, calibration, model, sensor, override integrity on the server) |
| Related | [SRS-03](../SRS-EdgeGuard-Edge-Vision-Inspection.md) · [SAD-03](SAD-EdgeGuard-Software-Architecture.md) · [ICD-03](ICD-EdgeGuard-Interface-Control.md) · [API-03](../api/API-Specification.md) · [TEST-03](TEST-EdgeGuard-Test-Plan.md) · [OPS-03](OPS-EdgeGuard-Deployment-Operations.md) |

---

## 1. Scope and what is different here

A node is a computer **bolted to a machine on a factory floor**. It is physically reachable by anyone with panel access, runs unattended, holds product images and lot numbers, drives a PLC signal, and accepts software (models, config, app images) from outside. Every one of those is an attack surface the server documents do not have.

The threat model is therefore led by **physical access** and **supply of artefacts**, not by web attacks. And the security objective that outranks all others is the one no other document in this repository has:

### 1.1 Security objectives, in priority order

| # | Objective | Meaning on a node |
|---|---|---|
| **O-1** | **Fail-safe integrity** | No attacker, fault or bug can make the node signal PASS for a part it did not judge, or READY when it cannot judge. Security controls must never *weaken* fail-safe behaviour (a security lockout must produce FAULT, not silence). |
| O-2 | Artefact integrity | Only verified models, config and app images run (sha256, signatures, digests); the previous version is always retained |
| O-3 | Identity integrity | A node is exactly one `node_code`; it talks only to the provisioned central; the central can revoke it |
| O-4 | Physical containment | Theft or tampering of a node yields no usable secrets and is detected |
| O-5 | Data minimisation | The node holds only what it needs, for as long as it needs it; diagnostics never leak secrets or product images |
| O-6 | Accountable human actions | Every override, fault clear, PIN attempt and technician action is attributed and synced |

## 2. Assets

| Asset | Where | Value to an attacker | Impact if compromised |
|---|---|---|---|
| Node client certificate / edge key | `/etc/edgeguard/secrets/` | Impersonate the node; inject false inspection records into the central | Corrupt quality history; hide escapes |
| Bundle signing public key, CA cert | `node.yaml`, secrets | Replace with own → accept rogue bundles / rogue central | Full control of what the node runs |
| Model artefacts and engines | `/var/lib/edgeguard/models/` | Substitute a model that passes everything | Escapes with a clean record |
| Config bundle (recipes, thresholds, PLC map) | `config_cache` | Loosen thresholds; remap PASS/FAIL pins | Escapes; wrong parts rejected |
| Local store (records, overrides, events) | SQLite file | Product/quality data; lot numbers; evidence of tampering | Confidentiality; loss of audit |
| Image cache | `/var/lib/edgeguard/images/` | Product design/defect images | IP leak (C-02) |
| PIN and technician token hashes | secrets dir | Override verdicts; clear faults | Fraudulent record correction |
| PLC I/O | GPIO / I/O module | Assert PASS without inspection | **Safety-adjacent** — the PLC is advisory-driven but downstream reject gates trust it |
| Camera feed | Z1 link | Replay a "good part" image | Escapes |

## 3. Trust boundaries

```
 Z1 camera segment ──[no IP route to Z3]── node ──[outbound-only mTLS, CA pinned]── Z3 central
                                            │
                        physical panel ─────┤ USB (usbguard allowlist) · console (no autologin) · GPIO (isolated)
                        kiosk display ──────┤ loopback socket only
                        technician laptop ──┘ SSH key-only (off by default) → localhost API with token
```
Nothing in Z3 initiates a connection to the node. The only inbound paths are physical.

## 4. Threat model

### 4.1 Node-specific threats (STRIDE)

| ID | Threat | STRIDE | Objective | Mitigations |
|---|---|---|---|---|
| THR-E01 | **Frozen or replayed camera feed** — a still image of a good part in front of the lens, or a looped stream | Spoofing | O-1 | Byte-identical consecutive frames = FAULT (ADR-E04); chunk frame-id monotonic; device clock skew alarm; FAULT on trigger-without-frame (SEC-E40…E42) |
| THR-E02 | **Model artefact substitution on disk** | Tampering | O-2 | sha256 verified on every load, not only at download; `model_cache.verified_at` trigger; engine cache keyed and re-verified; disk encryption (SEC-E30…E33) |
| THR-E03 | **Config tampering** — thresholds, class map, `plc_io` remap | Tampering | O-1, O-2 | Bundles signed (air-gapped) or over pinned mTLS (online); validated before atomic apply; `config_cache` hash checked at boot; `node.yaml` hash recorded at provisioning and checked (SEC-E34…E36) |
| THR-E04 | **Rogue central** — DNS/ARP redirect to an impostor server that returns malicious config/models | Spoofing | O-2, O-3 | CA pinning; server name check; config ETag continuity; bundle signature even online (`bundle.sig` mandatory when `signing_pubkey` set) (SEC-E20, E21) |
| THR-E05 | **Stolen node credentials** | Spoofing | O-3 | Per-node cert with CN = node_code; central binds records to CN; revocation; 1-year lifetime with rotation; key in LUKS volume / TPM (SEC-E22…E24) |
| THR-E06 | **Local API reachable from LAN** | Elevation | O-5, O-6 | Loopback + Unix socket only; compose has no published port; TC-084 scans from the LAN (SEC-E10…E12) |
| THR-E07 | **Override abuse** — inspector flips FAIL→PASS repeatedly, or PIN guessing | Repudiation, Elevation | O-6 | PIN with lockout; attribution by `user_ref`; every attempt an event; override rate alarm; overrides sync; model verdict never modified (SEC-E60…E64) |
| THR-E08 | **Physical theft / disk forensics** | Info disclosure | O-4, O-5 | LUKS/dm-crypt; no autologin; secrets 0600 root; tamper event on case open (where sensor exists); SD cards not used for the store (SEC-E43…E47) |
| THR-E09 | **Evidence exfiltration via USB** | Info disclosure | O-5 | `usbguard` allowlist; diagnostics bundle redacted; image cache purged per policy; PASS images sampled (SEC-E50…E53) |
| THR-E10 | **Malicious OTA app image** | Tampering | O-2 | Pull by digest from the plant registry; digest in signed bundle; one-service-at-a-time restart with health check and automatic rollback (SEC-E37, E38) |
| THR-E11 | **Denial of inspection** — flooding the local API, filling the disk, PIN lockout used to block fault-clear | DoS | O-1 | Line path independent of the API; disk policy never purges unsynced and never stops inspection; lockout affects PIN only, FAULT remains truthful (SEC-E13, E70) |
| THR-E12 | **GPIO driven by another process** | Tampering | O-1 | Only `supervisor` has the GPIO device; containers otherwise unprivileged; I/O module watchdog to safe state (SEC-E44) |
| THR-E13 | **Log/diagnostics leak secrets** | Info disclosure | O-5 | Redaction list; no image bytes in logs; lot numbers truncated in bundles (SEC-E52) |
| THR-E14 | **Time manipulation** (NTP spoof) to hide the order of events | Repudiation | O-6 | Device timestamps from camera chunk data recorded beside host time; skew event; UUIDv7 ordering (SEC-E48) |

### 4.2 The attack worth walking through — "make the node pass everything"

An insider with panel access wants a batch of defective parts to pass. Options and what stops each:

1. *Tape a good-part photo over the lens.* Consecutive frames are byte-identical → `FAULT: camera:FROZEN` within two triggers; the line stops. Even with noise added, frame ids and exposure chunk data keep changing and detections keep coming from a static scene; the anomaly model sees an out-of-distribution scene → REVIEW, not PASS.
2. *Edit the config to loosen thresholds.* The bundle is signed; `config_cache` hash is checked at boot; an edited file → `config:INVALID`, previous kept, event synced.
3. *Swap the model file.* sha256 mismatch on load → `FAULT: model:VERIFY_FAILED`, previous model activated (AI-07), event synced.
4. *Jumper the PASS output.* The node cannot prevent a wire; the PLC's verdict pulse timing (`timeout_ms`) and the record trail expose it (pulses without triggers/records). Documented residual risk; panel access control is the mitigation.
5. *Override every FAIL at the HMI.* Attributed by `user_ref`, rate-limited, synced; the central's override-rate report flags the shift.

None of these yield a *silent* PASS. That is O-1.

## 5. Security requirements

Format: `SEC-Exx` — requirement — verification. Platform SEC-00 requirements apply unchanged where relevant (TLS, secrets handling, logging).

### 5.1 Local API and HMI exposure
| ID | Requirement | Verified by |
|---|---|---|
| SEC-E10 | The node-local API and HMI SHALL bind only to `127.0.0.1` and a Unix socket; compose SHALL publish no ports for them | TC-084 |
| SEC-E11 | Mutating endpoints SHALL require the technician token; override and fault-clear SHALL require the supervisor PIN | TC-085 |
| SEC-E12 | Technician tokens SHALL expire ≤ 24 h and be stored only as Argon2 hashes under `/etc/edgeguard/secrets/` (0600) | TC-086 |
| SEC-E13 | No API call SHALL be able to raise READY or emit a verdict pulse in production (`/inspect` disabled unless `lab.software_trigger`) | TC-087 |

### 5.2 Identity and transport to the central
| ID | Requirement | Verified by |
|---|---|---|
| SEC-E20 | The node SHALL pin the provisioned CA and reject any sync target whose certificate does not chain to it | TC-088 |
| SEC-E21 | When `signing_pubkey` is set, every config bundle (online or USB) SHALL carry a valid signature | TC-089 |
| SEC-E22 | Node identity SHALL be a per-node client certificate (CN = `node_code`) or per-node key; the central SHALL bind records to that identity | TC-058 |
| SEC-E23 | Credentials SHALL be rotatable without redeploy; old credential valid until the new one completes one heartbeat | TC-061 |
| SEC-E24 | Private keys SHALL live on the encrypted volume (or TPM), 0600, never in `node.yaml`, logs, bundles or images | TC-086 |

### 5.3 Artefact integrity (models, config, app)
| ID | Requirement | Verified by |
|---|---|---|
| SEC-E30 | A model SHALL not be staged `active` or `shadow` without `sha256` verification (`trg_model_active_requires_verified`) | TC-003, TC-070 |
| SEC-E31 | sha256 SHALL be re-verified on every load, not only at download | TC-071 |
| SEC-E32 | Engine cache entries SHALL be keyed by (device, driver, model, version, precision) and invalidated on any key change | TC-072 |
| SEC-E33 | The previous model SHALL be retained and activated automatically on load failure (AI-07) | TC-073 |
| SEC-E34 | Config SHALL be validated (schema, class map, fingerprint) and applied atomically; failure keeps the previous | TC-074 |
| SEC-E35 | `config_cache` and `node.yaml` hashes SHALL be checked at boot; mismatch → `config:TAMPERED` fault | TC-075 |
| SEC-E36 | PLC signal mapping changes SHALL be logged as a node_event and reported in the next heartbeat | TC-076 |
| SEC-E37 | App images SHALL be pulled by digest; the digest SHALL come from a signed bundle | TC-100 |
| SEC-E38 | App OTA SHALL restart one service at a time with health check and automatic rollback | TC-101 |

### 5.4 Sensor authenticity and fail-safe
| ID | Requirement | Verified by |
|---|---|---|
| SEC-E40 | Two byte-identical consecutive frames SHALL raise `FAULT: camera:FROZEN` (latched; PIN clear) | TC-014, TC-032 |
| SEC-E41 | Non-monotonic chunk frame ids SHALL raise `REPLAY_SUSPECT`; three in a row → FAULT | TC-015 |
| SEC-E42 | A verdict pulse SHALL be emitted only after the local record is durably committed; absence of a verdict SHALL never read as PASS at the PLC | TC-025, TC-033 |
| SEC-E43 | A powered-off or crashed node SHALL present FAULT to the PLC (NC relay / I/O module watchdog) | TC-023 |
| SEC-E44 | Only the `supervisor` process SHALL have access to the GPIO/I-O device | TC-090 |

### 5.5 Physical and host
| ID | Requirement | Verified by |
|---|---|---|
| SEC-E45 | `/var/lib/edgeguard` and `/etc/edgeguard/secrets` SHALL be on an encrypted volume (LUKS/TPM on x86; dm-crypt on Jetson where supported — else residual risk §8) | TC-091 |
| SEC-E46 | No console autologin; SSH key-only and disabled by default; `usbguard` allowlist (scanner + provisioning USB by serial) | TC-092, TC-093 |
| SEC-E47 | Case-open / tamper input (where fitted) SHALL create a `security:TAMPER` event, synced, and a latched alarm on the HMI | TC-094 |
| SEC-E48 | Records SHALL carry camera device time and host time; NTP skew > 5 s SHALL be an event | TC-095 |

### 5.6 Data minimisation and privacy
| ID | Requirement | Verified by |
|---|---|---|
| SEC-E50 | Overrides and events SHALL identify people by `user_ref` (badge/PIN-holder id), never free-text names | TC-005 (seed), TC-081 |
| SEC-E51 | PASS images SHALL be stored only at the configured sample rate; images SHALL be purged per policy after sync (never unsynced) | TC-040…TC-043 |
| SEC-E52 | The diagnostics bundle SHALL exclude secrets, certificates, PIN/token hashes and PASS images, and SHALL truncate lot numbers | TC-096 |
| SEC-E53 | No raw image SHALL leave the node except through IF-01 under the central's policy (C-02); no other network egress from the image cache | TC-084 (egress scan) |

### 5.7 Overrides, fault clear and accountability
| ID | Requirement | Verified by |
|---|---|---|
| SEC-E60 | Override and fault-clear SHALL require the supervisor PIN; 5 attempts/min then 15-min lockout | TC-080, TC-082 |
| SEC-E61 | Every PIN attempt SHALL be a node_event with outcome and `user_ref` (when supplied) | TC-082 |
| SEC-E62 | Overrides SHALL never modify the model's verdict; they append (`override` table; effective verdict is a view) | TC-003 |
| SEC-E63 | Overrides SHALL sync to the central with attribution; a backlog of unsynced overrides SHALL be visible on the HMI | TC-081, TC-057 |
| SEC-E64 | Override rate > N per shift (default 20) SHALL raise an alarm in the heartbeat | TC-083 |
| SEC-E70 | A PIN lockout SHALL never affect the READY/FAULT truth or the line path | TC-087 |

### 5.8 RBAC — node roles

| Action | Operator | Inspector (PIN) | Technician (token) | Fleet admin (central) |
|---|---|---|---|---|
| View live/status/history on HMI | ✅ | ✅ | ✅ | via `/edge/nodes` |
| Select SKU manually | ❌ | ✅ | ✅ | — |
| Override verdict | ❌ | ✅ | ❌ | ✅ on central |
| Clear latched fault | ❌ | ✅ | ✅ (token) | ❌ |
| Self-test, calibration check, diagnostics bundle | ❌ | ❌ | ✅ | — |
| Activate / rollback model locally | ❌ | ❌ | ✅ (executes central's decision) | ✅ decides |
| Apply config bundle from USB | ❌ | ❌ | ✅ | ✅ signs |
| Sync flush | ❌ | ❌ | ✅ | — |
| Software trigger (`/inspect`) | ❌ | ❌ | ✅ lab only | — |
| Issue technician token | ❌ | ❌ | ❌ | ✅ (bundle) or provisioning |
| Rotate certificate / revoke node | ❌ | ❌ | ✅ `edgectl cert renew` | ✅ |
| Shell access | ❌ | ❌ | ⚠️ only if `ssh.enabled` | ❌ |

## 6. Security testing

| Test | Content | Where |
|---|---|---|
| Static | Compose has no `ports:` for api/hmi; no `privileged: true` except the documented device access; secrets not in `node.yaml.example`; `.env.example` has no real values | TC-004, TC-007 |
| LAN scan | `nmap` from Z3 against the node: only the SSH port (if enabled) | TC-084 |
| Egress | Firewall log during 1 h: only the sync target and NTP | TC-084 |
| Impostor central | Self-signed server at the sync URL → node refuses, alarm | TC-088 |
| Tampered bundle | Flip a byte in `bundle.json` → signature fails, previous config kept | TC-089 |
| Model swap | Replace artefact on disk → verify-failed, previous model active, event synced | TC-071, TC-073 |
| Frozen/replay | Static image; looped stream | TC-014, TC-015 |
| PIN | Brute force → lockout; lockout does not affect FAULT | TC-082, TC-087 |
| Forensics | Pull the SSD, mount on another machine → encrypted | TC-091 |
| Diagnostics leak | Grep the bundle for key material, PIN hashes, PASS image names | TC-096 |

## 7. Incident procedures (node-specific)

| Event | Immediate | Then |
|---|---|---|
| Node stolen | Revoke its certificate on the central; rotate the bundle signing key if the node held it (it holds only the public key) | Provision replacement (OPS RB-14) |
| Tamper event | Line supervisor inspects; node stays in alarm until PIN-cleared | Review overrides/events of the shift |
| Model verify failed | Nothing to do on the node — it rolled back | Investigate the artefact source (registry / USB) |
| Technician token leaked | `edgectl token revoke` (all tokens) | Re-issue per visit |
| Override rate alarm | Central quality review of the shift | Retrain if the model is wrong; retrain the person if it is not |

## 8. Residual risks

| Risk | Why it remains | Owner |
|---|---|---|
| **Physical access to the panel** — jumpering PLC outputs, swapping the camera | Software cannot prevent a wire; detection via pulse/record mismatch and calibration fingerprint only | Plant security / controls |
| Jetson without a hardware keystore — dm-crypt key on the same device | Documented per device model in OPS §2; x86 with TPM preferred for high-value lines | Fleet admin |
| Camera link is unencrypted (GigE Vision) | Isolated Z1 segment or direct cable; no IP route | Network |
| Override sync depends on a central credential outside the `/edge/*` contract (ICD-03 IF-01 known gap) | Contract v1.1 | Platform owner |
| A determined insider with the supervisor PIN and panel access | Attribution, rate alarms and central review, not prevention | Quality management |

## 9. Traceability

| SRS-03 | SEC-E |
|---|---|
| FR-13 never purge unsynced | E51 |
| FR-14 local audit log | E61, E36 |
| FR-17 override with user id and reason | E50, E60…E63 |
| FR-22 atomic config apply | E34, E35 |
| FR-23 checksum verify → shadow → promote/rollback | E30…E33, E37 |
| FR-24 previous kept, rollback | E33, E38 |
| AI-03 manifest sha256 | E30, E31 |
| AI-07 fall back on load failure | E33 |
| NFR-07 TLS, node identity, key rotation | E20…E24 |
| NFR-08 disk-full never stops inspection | E13, THR-E11 |
| NFR-10 diagnostics without shell | E52, E46 |
| C-02 no raw image leaves without policy | E51, E53 |
| C-05 unattended recovery | E43, E45 |
| AC-03 power cut, DB intact | E42 |
| AC-06 duplicate push, no duplicate rows | E22 (identity-bound dedup) |

## Appendix A — Review checklist for a node change
- [ ] Does the change add a listener? It must be loopback/socket only (E10).
- [ ] Does it accept a file, bundle, model or image from outside? Verified before use; previous retained (E30…E38).
- [ ] Can it, in any failure mode, leave READY high or emit a pulse without a committed record? (E42, E43)
- [ ] Does it write to logs or the diagnostics bundle? Redaction list updated (E52).
- [ ] Does it add a human action? PIN or token, attributed, evented, synced (E60…E63).
- [ ] Does it touch the PLC map, camera or optics? Change control in ICD-03 §3.
