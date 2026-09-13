# Interface Control Document — PocketQC Offline Mobile Inspector

| Field | Value |
|---|---|
| Document ID | ICD-05-PocketQC |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Scope | Every interface of the app: the platform (IF-11, as a client), the camera, the on-device runtimes, labels and markings, the MDM, the share sheet, and the device's secure storage |
| Related | [SRS-05](../SRS-PocketQC-Offline-Mobile-Inspector.md) · [SAD-05](SAD-PocketQC-Software-Architecture.md) · [API-05](../api/API-Specification.md) · [SEC-05](SEC-PocketQC-Security-Requirements.md) · [ICD-00 IF-11](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-11) · [ICD-03](../../03-edge-vision-inspection/docs/ICD-EdgeGuard-Interface-Control.md) (the line-side sibling's camera and OTA interfaces, for contrast) |

---

## 1. Scope and register

`IF-xx` numbers are shared across the repository (00: IF-01…19; 02: 20–21; 03: 22–24; 04: 25–29). PocketQC describes the client side of **IF-11** in depth and adds six device-side interfaces.

| IF | Interface | App role | New |
|---|---|---|---|
| **IF-11** | Mobile sync with the platform | **Client** | — (server side in ICD-00) |
| **IF-30** | Camera (CameraX) | Consumer | ✅ |
| **IF-31** | On-device inference (TFLite + delegates) | Consumer | ✅ |
| **IF-32** | Barcode and OCR (ML Kit + OCR model) | Consumer | ✅ |
| **IF-33** | Managed configuration and remote wipe (Android Enterprise / MDM) | Target | ✅ |
| **IF-34** | Share sheet and PDF export | Producer | ✅ |
| **IF-35** | Secure storage (Android Keystore, EncryptedSharedPreferences, SQLCipher, BiometricPrompt) | Consumer | ✅ |

Interfaces the app does **not** have: no local HTTP server, no PLC, no cloud inference (C-04), no third-party analytics (NFR-09), no Discord.

**Zones.** Z4 client (the device) → Z3 platform, outbound only, over factory Wi-Fi. Nothing connects *to* the device.

---

## IF-11 — Mobile sync (client side) {#if-11}

**Parties.** PocketQC `sync` layer → platform `/mobile/*` ([API-05](../api/openapi.yaml): v1.0 parts verbatim from API-00; v1.1 proposed).

### Client state machine
```
        ┌────────┐ trigger (WorkManager) ┌───────────┐ 304/200 ┌─────────┐ 207 ┌────────┐ done ┌───────────┐
 idle ─►│ GATED  │──────────────────────►│ BOOTSTRAP │────────►│ SESSIONS│────►│ IMAGES │─────►│ MODELS/   │──► idle
        │(network│                       └───────────┘         └─────────┘     └────────┘      │ AUDIT/HB  │
        │ policy)│      any step: network lost / 5xx / timeout → BACKOFF (2 s ×2 … 900 s, ±20 %) └───────────┘
        └────────┘      auth 401 → refresh; refresh fails → offline window check → continue offline or require login
```
WorkManager constraints: `NetworkType.UNMETERED` (policy `wifi`) or `CONNECTED` (`any`); no charging requirement; periodic 15 min; expedited on manual sync and on connectivity change. Survives process death and reboot (NFR-06).

### Batch assembly
`SELECT … FROM session WHERE finished_at IS NOT NULL AND synced_at IS NULL ORDER BY finished_at LIMIT 200`, each projected to `MobileSession` with typed `MobileSessionStep` items via [`db/payload_mapping.json`](../db/payload_mapping.json). Outcomes: `accepted` / `duplicate` → `synced_at`; `rejected` → `sync_attempts++`, `last_sync_error`, backoff; stuck after 5 (shown in the UI, heartbeat).

### Images (resumable)
Only for sessions with `synced_at`. `POST /mobile/images` → `PATCH` chunks of 512 KB with `Upload-Offset` → on any interruption `HEAD` and continue from the server's offset (`image.upload_offset` mirrors it). Completion verifies `sha256`. Compressed copy per policy (`max_edge_px`, `jpeg_quality`); **the original stays on the device until purge** (FR-25).

### Bootstrap, models, policy
ETag on all three. Bootstrap replaces the three caches in one transaction (server wins). Models: manifest → ranged download → sha256 → self-test with `samples_url` on this device → activate; previous kept; failure → event + heartbeat (FR-26). Policy: applied immediately; `wipe_requested` / `wipe` command → API-05 §4 ordering.

### Heartbeat and commands
Every sync: `DeviceHeartbeat` (pending counts, model versions and self-test state, delegate, storage, battery, offline window). Commands: `wipe`, `force_relogin`, `force_bootstrap`, `rollback_model`; acknowledged before destructive execution.

### Auth
`/mobile/auth` online → access + refresh (bound to `device_id`) + `offline_valid_until`. Offline: the passcode/biometric gate (IF-35) opens the app while the window is valid; expired → history read-only until online login (FR-27).

**Verification.** TC-050…TC-064; TC-008 contract identity.

---

## IF-30 — Camera (CameraX) {#if-30}

| Aspect | Contract |
|---|---|
| Plugin | Flutter `camera` (CameraX backend) via platform channel; lifecycle bound to the step screen |
| Pre-warm | Camera opened when the step screen opens; ready ≤ 1.5 s (NFR-01) |
| Capture | Single or **burst of 5** (FR-03); JPEG; resolution ≥ 1920 px long edge; autofocus locked before shutter; tap-to-focus |
| Framing guide | Overlay from the checklist step (`guide: {shape, aspect, text_th/ja/en}`) |
| Torch | Toggle; state recorded per image (`image.torch_on`, FR-05) |
| **Quality gate** (FR-02) | Per frame: Laplacian variance (blur) ≥ `min_blur_variance` (default 120); exposure mean within `exposure_range` (default 60–200); glare ratio (pixels > 250) ≤ 5 %. Thresholds per checklist step or managed config. Fail → retake prompt with the reason and a torch suggestion; **no analysis on a failed frame** |
| Burst selection | Highest blur variance among gate-passing frames; `burst_index` stored |
| Metadata (FR-04) | Timestamp with offset, user, device, step, lot, SKU; GPS only if `policy.gps_enabled` |
| **EXIF** | Stripped before storage (no location, no device serial leaks in the file) |
| Output | Encrypted file (IF-35) + `image` row with plaintext `sha256` |

**Verification.** TC-010…TC-016.

---

## IF-31 — On-device inference (TFLite + delegates) {#if-31}

| Aspect | Contract |
|---|---|
| Runtime | TensorFlow Lite via `tflite_flutter`; models INT8 (AI-01); input 640 (detection), 320 (OCR) |
| Delegate probe (ADR-M04) | Order **NNAPI → GPU → XNNPACK (CPU)**; each tried in an isolate with a 5 s timeout on a bundled sample; first success cached in `device_info.delegate`; re-probed on app update |
| Model files | `files/models/<name>/<version>.tflite` (+ `.json` class map); ≤ 25 MB (C-02); sha256 from manifest |
| Load | Active model per step's `model` name; interpreter kept for the session; warm-up 1 frame on step open |
| Output → step | Detections `[class, conf, box]` → `model_result_json`; `suggested_result` by the step's `accept.no_class_above` rule; **review band** ±0.1 around each threshold → `REVIEW` |
| Latency | Measured per inference (`latency_ms`); p95 ≤ 500 ms on the reference device (AI-03); reported in diagnostics and heartbeat |
| Self-test (FR-26) | Bundled sample set per model (`samples_url`): expected classes must be detected with recall ≥ `selftest.min_recall` (0.95) and p95 ≤ `max_latency_ms` on **this** device; result in `model_asset.selftest_json` |
| Manual mode (AI-08) | No active model for the step's name → photo + human verdict; `model_version = NULL` |
| Memory | One interpreter at a time; GPU delegate released on background |

**Verification.** TC-020…TC-028.

---

## IF-32 — Barcode and OCR {#if-32}

| Function | Contract |
|---|---|
| Barcode (FR-08) | ML Kit Barcode Scanning (on-device, bundled model — no Play Services download at runtime); formats CODE128, CODE39, EAN-13, QR, DataMatrix; parsed by the checklist's `identity.pattern` (regex with named groups `sku`, `lot`); SKU → `sku_cache.checklist_id` → auto-select (AC-06); unknown SKU → manual selection with a warning |
| OCR (FR-07) | On-device OCR model (`ocr-lotcode`, TFLite) for the lot-code font set; per-character confidence; text validated against the step's `pattern`; **one-tap correction** field pre-filled; `text_raw` and `text_value` both stored; char confidence < 0.9 → step REVIEW |
| Accuracy target | ≥ 95 % characters under normal lighting (AI-04); measured on the lot-code corpus (TEST-05 TC-026) |
| Privacy | Nothing leaves the device; ML Kit bundled variant only (NFR-09) |

---

## IF-33 — Managed configuration and remote wipe {#if-33}

**Parties.** MDM (Android Enterprise) → app restrictions; platform → wipe command.

### Managed configuration keys ([`deploy/managed-config.example.json`](../deploy/managed-config.example.json), schema [`deploy/schemas/managed-config.schema.json`](../deploy/schemas/managed-config.schema.json))
| Key | Type | Meaning |
|---|---|---|
| `server_url` | string | Platform base URL (the only allowed egress) |
| `cert_pins` | string[] | SPKI SHA-256 pins for certificate pinning (≥ 2: current + backup) |
| `device_id` | string | Company device identifier (not the serial) |
| `sync_network` | `wifi` / `any` | Default until policy overrides |
| `offline_days` | 1–90 | Offline token window (FR-27) |
| `gps_enabled` | bool | FR-04 optional metadata |
| `allowed_share_targets` | string[] | Package names allowed for PDF share (IF-34); empty = any |
| `require_device_lock` | bool | FR-29 gate (default true) |
| `lang_default` | th/ja/en | |
| `low_space_warn_pct`, `low_space_crit_pct` | int | |
| `debug_diagnostics` | bool | Extra diagnostics screen (never logs images/secrets) |

Rules: the app **has no settings screen** for these; changes apply on next app start; a missing `server_url` blocks login with a clear message; the MDM may also enforce device passcode, disable screenshots, disable backup and block sideloading (SEC-05).

### Remote wipe (FR-28)
Admin marks the device lost on the platform → `wipe` command via policy/heartbeat/commands → app: flush ≤ 60 s → ack → delete DB, image dir, Keystore aliases, secure prefs → show "device wiped". The MDM's own device wipe is the second, independent path.

**Verification.** TC-070…TC-074.

---

## IF-34 — Share sheet and PDF export {#if-34}

| Aspect | Contract |
|---|---|
| Report (FR-18) | Generated locally from the session: header (SKU, lot, verdict, user, device, time), per step: thumbnail, model suggestion, human result, defect code/severity/note, measurements with ± and spec; footer with app/model/checklist versions |
| Fonts | Noto Sans Thai and Noto Sans JP embedded (AC-08) |
| Share | Android share sheet (`ACTION_SEND`, `application/pdf`); restricted to `allowed_share_targets` when set; the PDF is written to the app's cache dir with a `FileProvider` URI, expires after 1 h |
| Privacy | Images in the PDF are the compressed copies; no GPS unless enabled; the PDF is **outside the encryption boundary once shared** — a policy decision (SEC-05 §8) |

**Verification.** TC-080…TC-083.

---

## IF-35 — Secure storage {#if-35}

| Item | Mechanism |
|---|---|
| DB key | 32 random bytes generated on first run, wrapped by an Android Keystore AES key (`setUserAuthenticationRequired(false)` for background sync; StrongBox when available); stored in EncryptedSharedPreferences; passed as `PRAGMA key` |
| Image data keys | Per file random AES-256-GCM key, wrapped by the same Keystore key; wrapped key stored in the file header |
| Tokens | EncryptedSharedPreferences; referenced from `auth_state.token_ref` |
| Supervisor PIN | Argon2id hash in EncryptedSharedPreferences; 5 attempts then 15-min lockout; every attempt an `audit_event` |
| App gate (FR-29) | `BiometricPrompt` with device-credential fallback on open and after 5 min background; enforced when `require_device_lock` |
| Wipe | Delete Keystore aliases first (renders every file unreadable instantly), then files |
| What is never stored | Plain tokens, the DB key in the DB, images unencrypted, the PIN itself |

**Verification.** TC-090…TC-096.

---

## 2. Interface matrix

| IF | Direction | Auth | Encryption | Survives failure? | Idempotent |
|---|---|---|---|---|---|
| IF-11 | out | JWT (offline window) | TLS 1.2+, pinned | ✅ full offline operation; backlog | ✅ UUIDv7 dedup; resumable uploads |
| IF-30 camera | local | — | — | ⚠️ step cannot proceed without a photo (retake) | n/a |
| IF-31 inference | local | — | model sha256 | ✅ manual mode | ✅ |
| IF-32 barcode/OCR | local | — | — | ✅ manual entry with correction | ✅ |
| IF-33 MDM | in (config), in (command) | MDM enrolment; platform command | TLS | ✅ last config kept | ✅ commands acked by id |
| IF-34 share | out (user-initiated) | user | OS | ✅ | n/a |
| IF-35 Keystore | local | biometric/credential | hardware-backed | ⚠️ key loss = data loss (by design) | n/a |

## 3. Change control

| Change | Requires |
|---|---|
| `MobileSession`/step shape | API-00 first (v1.1 adoption); then this set; TC-008 diff |
| Checklist schema (`checklist.schema.json`) | Version bump; old checklists still load (additive); sessions keep `checklist_version` |
| Model class map | Manifest version bump; checklists referencing removed classes are rejected at bootstrap validation |
| Managed-config keys | Schema bump; OPS-05 §4; MDM template update |
| Quality-gate thresholds | Checklist step or managed config — not code |
| Certificate pins | Managed config with current + backup pin; rotate before expiry |

## 4. Traceability

| SRS-05 | Interface |
|---|---|
| FR-01…05 | IF-30 |
| FR-06, FR-10, FR-12, AI-01…03, AI-06, AI-08 | IF-31 |
| FR-07, FR-08, AI-04 | IF-32 |
| FR-09, AI-05 | IF-30 (marker capture) + `measure` layer (SAD-05 §4.3.4) |
| FR-18 | IF-34 |
| FR-19, FR-29 | IF-35 |
| FR-20…FR-26, FR-24 | IF-11 |
| FR-27 | IF-11 auth, IF-35 |
| FR-28 | IF-33, IF-11 commands |
| §4.2 device | IF-30, IF-31, IF-32, IF-35, WorkManager (IF-11) |
| C-04, NFR-09 | IF-31/32 bundled models; egress only IF-11 |
| C-05, NFR-05 | IF-35 |
| NFR-06 | IF-11 WorkManager |
| NFR-07, AC-08 | IF-34 fonts |
