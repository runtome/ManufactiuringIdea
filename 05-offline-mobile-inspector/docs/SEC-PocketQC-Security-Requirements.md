# Security Requirements Specification — PocketQC Offline Mobile Inspector

| Field | Value |
|---|---|
| Document ID | SEC-05-PocketQC |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Inherits | [SEC-00](../../00-factorybrain-platform/docs/SEC-FactoryBrain-Security-Requirements.md) baseline (TLS, auth, logging; SEC-177 remote wipe) |
| Related | [SRS-05](../SRS-PocketQC-Offline-Mobile-Inspector.md) · [SAD-05](SAD-PocketQC-Software-Architecture.md) · [ICD-05](ICD-PocketQC-Interface-Control.md) · [API-05](../api/API-Specification.md) · [TEST-05](TEST-PocketQC-Test-Plan.md) · [OPS-05](OPS-PocketQC-Deployment-Operations.md) |

---

## 1. Scope and what is different here

The threat that dominates a mobile app is not a clever attacker on the network; it is a **tablet left on a bench, in a taxi, or taken home**. The device holds product images, lot numbers, defect data and a valid login for up to 30 days. The second threat is subtler: the app records a person's **judgement**, and that judgement must be provably theirs and unaltered — by the model, by the server, or by a colleague with the tablet.

### 1.1 Security objectives

| # | Objective | Meaning |
|---|---|---|
| **O-1** | **A lost device yields nothing** | Everything at rest is encrypted with hardware-protected keys; the app is gated; the server can wipe it on next contact |
| **O-2** | **The inspector's verdict is theirs** | `human_result` cannot be changed by the model, by sync, or without a supervisor PIN and an audit row |
| **O-3** | **Sync neither loses nor duplicates** | UUIDv7, at-least-once, dedup; images only for accepted records |
| **O-4** | **Nothing leaves the device except to the platform** | No cloud inference, no analytics, pinned TLS; the share sheet is the one policy-governed exception |
| **O-5** | **Offline access is bounded** | Token window ≤ 90 days (default 30), device lock, revocation on next contact |

## 2. Assets

| Asset | Where | Value | Impact |
|---|---|---|---|
| Inspection images | encrypted files | Product design/defect IP | Confidentiality |
| Records (lots, verdicts, notes) | SQLCipher DB | Quality and supplier data | Confidentiality, integrity |
| Cached tokens (30-day window) | EncryptedSharedPreferences | Platform access as the inspector | Impersonation |
| DB and image keys | Android Keystore (wrapped) | Everything above | Total exposure |
| Models | files | Company IP (trained on company defects) | IP |
| Checklists, SKUs | caches | Product structure | Mild |
| Supervisor PIN hash | secure prefs | Re-judge authority | Integrity of verdicts |
| Managed configuration | MDM | Server URL, pins | Redirect to a fake server |

## 3. Trust boundaries

```
 ┌── Device (Z4) ─────────────────────────────────────────────────────────────┐
 │  App sandbox: DB (SQLCipher) · images (AES-GCM) · secure prefs · Keystore  │
 │  Gate: device lock / biometric (FR-29)                                     │
 │  Boundaries out: IF-11 (pinned TLS) · share sheet (policy) · MDM channel  │
 └───────────────┬───────────────────────────────────────────────────────────┘
                 │ factory Wi-Fi (untrusted)                 ▲ managed configuration, wipe
                 ▼                                           │
          Platform /mobile/* (Z3)                          MDM
```

## 4. Threat model

### 4.1 Threats (STRIDE)

| ID | Threat | STRIDE | Obj. | Mitigations |
|---|---|---|---|---|
| THR-M01 | **Lost or stolen device** | Info disclosure | O-1 | SQLCipher DB; per-image AES-GCM with Keystore-wrapped keys (StrongBox); device lock gate; remote wipe on next contact; offline window; Android backup disabled; screenshots blocked (SEC-M10…M17) |
| THR-M02 | **Rooted / tampered device** | Elevation | O-1 | Play Integrity / root detection → block login and sync, alert admin; Keystore keys still hardware-bound; MDM compliance policy (SEC-M18) |
| THR-M03 | **Model silently deciding** (a REVIEW auto-passed) | Tampering | O-2 | Separate `suggested_result` / `human_result`; finish trigger; REVIEW requires a tap (SEC-M20, M21) |
| THR-M04 | **Verdict altered after the fact** (colleague with the tablet, or server) | Repudiation | O-2 | Re-judge needs supervisor PIN + audit row (trigger); server never edits `human_result` (conflict rule); audit synced (SEC-M22…M24) |
| THR-M05 | **MITM on factory Wi-Fi** (fake bootstrap, fake model, credential capture) | Spoofing, Tampering | O-4 | Certificate pinning (2 pins); sha256 on models; managed `server_url` only; no cleartext (SEC-M30…M33) |
| THR-M06 | **Stale offline access after an employee leaves** | Elevation | O-5 | Window ≤ 90 d (default 30); revocation + `force_relogin` command on next contact; MDM wipe (SEC-M40…M42) |
| THR-M07 | **Data exfiltration via share/PDF/screenshot** | Info disclosure | O-4 | `allowed_share_targets` policy; PDF in cache with 1-h expiry; `FLAG_SECURE` on inspection screens; images in PDF are compressed copies (SEC-M50…M53) |
| THR-M08 | **Backup / ADB extraction** | Info disclosure | O-1 | `allowBackup=false`, `fullBackupContent` none; debuggable off in release; MDM blocks USB debugging (SEC-M43, M44) |
| THR-M09 | **Fake or corrupted model** | Tampering | O-4 | Manifest sha256; on-device self-test; size ≤ 25 MB; previous kept (SEC-M34, M35) |
| THR-M10 | **Replayed or duplicated uploads** | Tampering | O-3 | UUIDv7; server dedup; images only for accepted records; sha256 (SEC-M60…M62) |
| THR-M11 | **GPS / privacy** | Info disclosure | O-4 | GPS off by default; policy-controlled; EXIF stripped (SEC-M54) |
| THR-M12 | **Secrets in logs or support bundles** | Info disclosure | O-1 | No tokens/keys/images/lot text in logs; support bundle redacted (SEC-M55) |
| THR-M13 | **Debug build in the field** | Elevation | O-1 | Release signing; debug diagnostics only via managed config, never secrets (SEC-M45) |
| THR-M14 | **Supervisor PIN brute force** | Elevation | O-2 | Argon2id; 5 attempts / 15-min lockout; every attempt audited (SEC-M25) |

### 4.2 The attack worth walking through — "the tablet in the taxi"

An inspector's tablet with 20 unsynced sessions and a valid 30-day token is lost at 17:00.

1. **Screen lock.** The finder cannot open the device (MDM enforces a passcode). Even unlocked, the app asks for the device credential/biometric on open (FR-29).
2. **Pull the storage.** A copied `files/` tree contains `*.enc` images and a SQLCipher file; keys are in the Keystore — hardware-bound, not extractable. Backup is disabled; ADB debugging is blocked by MDM.
3. **Use the token.** The refresh token is bound to `device_id`; at 17:30 the inspector reports the loss; the admin marks the device lost. The next time the device reaches the platform — sync attempt, heartbeat, or login — it receives `wipe` (or 403 `DEVICE_WIPED`) and destroys its keys first, then files. The MDM issues its own wipe in parallel.
4. **Never reconnects.** The data stays encrypted forever; the 30-day window expires; the 20 unsynced sessions are re-inspected — the company lost an afternoon's work, not its data. That trade-off is stated in SEC-05 §8.

## 5. Security requirements

### 5.1 Data at rest and the lost device (C-05, NFR-05, FR-28, FR-29)
| ID | Requirement | TC |
|---|---|---|
| SEC-M10 | The database SHALL be SQLCipher-encrypted with a 256-bit key wrapped by an Android Keystore key (StrongBox when available); the key SHALL never be written to the DB, prefs in clear, or logs | TC-090, TC-091 |
| SEC-M11 | Every image and thumbnail SHALL be encrypted individually (AES-256-GCM) with a data key wrapped by the Keystore key | TC-091 |
| SEC-M12 | The app SHALL require device credential or biometric on open and after 5 min in background when `require_device_lock` is set (default) | TC-092 |
| SEC-M13 | Remote wipe SHALL delete Keystore aliases first, then files, then acknowledge; it SHALL be triggered by any of: policy flag, heartbeat/command, 403 `DEVICE_WIPED` | TC-093, TC-072 |
| SEC-M14 | Tokens SHALL live only in EncryptedSharedPreferences and SHALL be referenced, not stored, by the DB | TC-090 |
| SEC-M15 | Inspection screens SHALL set `FLAG_SECURE` (no screenshots/recording) | TC-094 |
| SEC-M16 | `secure_delete` SHALL be on; purge SHALL overwrite | TC-095 |
| SEC-M17 | Key loss (factory reset, Keystore cleared) SHALL make data unreadable by design; the app SHALL start fresh and report the event | TC-096 |
| SEC-M18 | Rooted/tampered devices (Play Integrity fail) SHALL be blocked from login and sync and reported | TC-097 |

### 5.2 Verdict integrity (FR-10, FR-11, FR-19)
| ID | Requirement | TC |
|---|---|---|
| SEC-M20 | `suggested_result` and `human_result` SHALL be separate; the model SHALL never write `human_result` | TC-030, TC-003 |
| SEC-M21 | A session SHALL not finish while a judged step lacks `human_result` (DB trigger) | TC-003 |
| SEC-M22 | Changing a finished session's verdict SHALL require a supervisor PIN and SHALL create an audit row (DB trigger) | TC-003, TC-034 |
| SEC-M23 | The audit table SHALL be append-only (triggers) and synced | TC-003 |
| SEC-M24 | The server SHALL never modify a device's `human_result`; server reviews are separate overrides (conflict rule) | TC-056 |
| SEC-M25 | Supervisor PIN: Argon2id hash; 5 attempts / 15-min lockout; each attempt audited | TC-034 |

### 5.3 Transport and platform trust (NFR-09, C-04)
| ID | Requirement | TC |
|---|---|---|
| SEC-M30 | All traffic SHALL be TLS 1.2+ with **certificate pinning** to ≥ 2 SPKI pins from managed configuration; cleartext SHALL be impossible (`usesCleartextTraffic=false`) | TC-098 |
| SEC-M31 | The server URL SHALL come only from managed configuration; no in-app override | TC-070 |
| SEC-M32 | The app SHALL make no network call other than to `server_url` (no analytics, no crash upload, no Play Services model download at runtime) | TC-099 |
| SEC-M33 | Login SHALL be rate-limited server-side; offline login SHALL not consume network | TC-062 |
| SEC-M34 | Models SHALL be verified by sha256 against the manifest and SHALL pass the on-device self-test before activation; size ≤ 25 MB | TC-003, TC-058 |
| SEC-M35 | The previous model SHALL be kept for rollback; a failed self-test SHALL never activate | TC-058 |

### 5.4 Offline access bounds (FR-27)
| ID | Requirement | TC |
|---|---|---|
| SEC-M40 | Offline access SHALL expire at `offline_valid_until` (1–90 days; default 30); expired → history read-only until online login | TC-062 |
| SEC-M41 | A `force_relogin` command or a revoked refresh token SHALL end offline access on next contact | TC-063 |
| SEC-M42 | The refresh token SHALL be bound to `device_id`; a token used from another device SHALL be rejected | TC-064 |
| SEC-M43 | Android backup SHALL be disabled (`allowBackup=false`); no data in external storage | TC-100 |
| SEC-M44 | Release builds SHALL be non-debuggable; USB debugging blocked by MDM policy | TC-101 |
| SEC-M45 | Debug diagnostics (managed config) SHALL never expose tokens, keys, images or lot text | TC-101 |

### 5.5 Data leaving the device (NFR-09)
| ID | Requirement | TC |
|---|---|---|
| SEC-M50 | PDF share SHALL honour `allowed_share_targets`; the PDF SHALL be served from the app cache via `FileProvider` and expire in 1 h | TC-080, TC-081 |
| SEC-M51 | Shared PDFs SHALL contain compressed images only and no GPS unless enabled | TC-082 |
| SEC-M52 | The share action SHALL be audited (`audit_event` with target package) | TC-083 |
| SEC-M53 | No third-party SDK with network access SHALL be included; the dependency list is reviewed per release | TC-099 |
| SEC-M54 | EXIF SHALL be stripped from every stored and uploaded image; GPS SHALL be off unless policy enables it | TC-015 |
| SEC-M55 | Logs and support bundles SHALL contain no tokens, keys, image bytes or lot text | TC-102 |

### 5.6 Sync integrity (FR-20)
| ID | Requirement | TC |
|---|---|---|
| SEC-M60 | All record ids SHALL be client UUIDv7; the server SHALL dedup; `duplicate` is success | TC-052 |
| SEC-M61 | Images SHALL upload only for sessions already accepted, with sha256 verified on completion | TC-053, TC-055 |
| SEC-M62 | `synced_at` SHALL be set only by the sync layer on `accepted`/`duplicate`; purge SHALL never touch unsynced data | TC-003, TC-040 |

### 5.7 RBAC
| Action | Inspector | Supervisor (PIN) | Admin (platform) |
|---|---|---|---|
| Run inspections, judge steps, share PDF (per policy) | ✅ | ✅ | — |
| Re-judge a finished session | ❌ | ✅ (PIN, audited) | ✅ on the platform (as an override) |
| Change server/policy/config | ❌ | ❌ | ✅ via MDM / platform |
| Wipe a device | ❌ | ❌ | ✅ |
| Install a model | automatic (verified + self-test) | — | publishes manifests |

## 6. Security testing
| Test | TC |
|---|---|
| Storage forensics: copy `files/` and the DB off a test device; attempt to open | TC-091 |
| Lost-device drill: mark lost → next contact wipes; keys gone before files | TC-093 |
| Root detection; backup disabled; debuggable off; `FLAG_SECURE` | TC-097, TC-100, TC-101, TC-094 |
| Pinning: proxy with a valid public CA cert → refused | TC-098 |
| Egress: packet capture 1 h → only `server_url` | TC-099 |
| Offline window expiry and revocation | TC-062, TC-063, TC-064 |
| Verdict integrity probes (DB) and PIN lockout | TC-003, TC-034 |
| Model tamper: flip a byte → sha256 fail; weak model → self-test fail | TC-058 |
| Log/support-bundle scan for secrets and lot text | TC-102 |

## 7. Incident procedures
| Event | Immediate | Then |
|---|---|---|
| Device lost | Mark lost on the platform (wipe queued) + MDM wipe; revoke refresh token | Re-inspect unsynced lots; incident record |
| Employee leaves | Revoke on the platform; `force_relogin` queued; MDM unenroll | — |
| Pin rotation / cert change | Push managed config with new pins **before** the server cert changes | Verify with a pilot device |
| Suspected verdict tampering | Pull the device's audit export; compare `suggested` vs `human` vs server overrides | Quality review |

## 8. Residual risks
| Risk | Why it remains | Owner |
|---|---|---|
| Unsynced work on a wiped or never-reconnecting lost device is lost | Exposure outranks the records; the flush-before-wipe window is best effort | Quality / IT |
| A shared PDF is outside the encryption boundary | Sharing is the feature; `allowed_share_targets` limits it | Admin policy |
| Root detection is detection, not prevention | Hardware-bound keys still limit exposure | IT |
| A supervisor with the PIN can re-judge anything | Audited and synced; reviewed centrally | Quality management |
| Platform IF-11 v1.1 not yet implemented: wipe via heartbeat/commands and image sha256 verification depend on it | Until then, wipe relies on the MDM path alone | Platform owner |

## 9. Traceability
| SRS-05 | SEC-M |
|---|---|
| C-04 | M32 |
| C-05, NFR-05 | M10, M11, M16 |
| FR-10, FR-11 | M20, M21 |
| FR-19 | M22, M25 |
| FR-20 | M60…M62 |
| FR-23 | M24 |
| FR-26, AI-06 | M34, M35 |
| FR-27 | M40…M42 |
| FR-28 | M13 |
| FR-29 | M12 |
| NFR-09 | M32, M53, M55 |
| AC-02 | M60, M61 |

## Appendix A — Release security checklist
- [ ] `allowBackup=false`, `usesCleartextTraffic=false`, `debuggable=false`, `FLAG_SECURE` on inspection screens
- [ ] Pins in managed config match the server certificate chain (current + backup)
- [ ] Dependency review: no SDK with network access besides the HTTP client
- [ ] Storage forensics test on a release build
- [ ] Lost-device drill passed on a pilot device
- [ ] DB constraint probes green (TC-003)
