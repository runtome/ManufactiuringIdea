# Interface Control Document — PawTrace (AI Dog Finder 2.0)

| Field | Value |
|---|---|
| Document ID | ICD-07-PawTrace |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-07](../SRS-PawTrace-AI-Dog-Finder.md) §4 · [SAD-07](SAD-PawTrace-Software-Architecture.md) §4 · [API-07](../api/API-Specification.md) · [SEC-07](SEC-PawTrace-Security-Requirements.md) · [OPS-07](OPS-PawTrace-Deployment-Operations.md) · platform patterns: [ICD-00](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md) |
| Numbering | Shared `IF-xx` register. Reused: IF-10, IF-13, IF-14. **New: IF-39 map tiles & geocoding, IF-40 push, IF-41 CAPTCHA & device tokens, IF-42 vision model contract, IF-43 shelter bulk intake** |

---

## 1. Scope and register
Every interface between PawTrace and something it does not own. The public HTTP API is API-07; this document covers what sits behind and around it.

| IF | Interface | Direction | Criticality | Section |
|---|---|---|---|---|
| IF-10 | Object storage (S3 / MinIO) | out | high — every image | [§IF-10](#if-10) |
| IF-13 | SMTP and webhook (email relay, optional SMS) | out | medium | [§IF-13](#if-13) |
| IF-14 | Metrics | out | low | [§IF-14](#if-14) |
| **IF-39** | Map tiles and geocoding | out | medium — degraded UI without | [§IF-39](#if-39) |
| **IF-40** | Push (Web Push VAPID / FCM) | out | medium | [§IF-40](#if-40) |
| **IF-41** | CAPTCHA and anonymous device tokens | out/in | high — anti-abuse | [§IF-41](#if-41) |
| **IF-42** | Vision model contract (detector, re-ID, attributes, NSFW, text) | in-process | high | [§IF-42](#if-42) |
| **IF-43** | Shelter bulk intake | in | low | [§IF-43](#if-43) |
| — | PWA client behaviour (offline draft, background upload) | — | — | [§2](#2-pwa-client-notes) |

All third-party services are **optional at deploy time** (SRS §4.2): the compose file runs with none of them; OPS-07 §5 lists what degrades.

---

## IF-10 — Object storage {#if-10}
Inherits [ICD-00 IF-10](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-10) (S3 API, private ACL, signed URLs). PawTrace specifics:

| Bucket | Content | Written by | Read via |
|---|---|---|---|
| `derivatives` | `derivatives/<photo_id>/full.jpg` (≤ 2048 px), `card.jpg` (800), `thumb.jpg` (200) — **EXIF-free** | api (upload gate) | signed URL: thumb/card 15 min, full 5 min |
| `crops` | `crops/<instance_id>.jpg` | worker-vision | signed URL 15 min (owner, candidates) |
| `exports` | `exports/<request_id>.zip` | scheduler | signed URL 24 h |
| `intake` | shelter CSV + zip, deleted after processing | api | worker only |

Rules: (1) **no `originals` bucket exists** — the upload bytes are stripped and re-encoded in memory, then only derivatives are written (C-04, AC-05); (2) bucket policies deny public read (TC-004 checks the compose/MinIO policy); (3) object keys carry no user id, no location, no time; (4) the URL signer (`api`) checks `photo.moderation_status = approved` unless the caller owns the report (C-05); (5) deletion: the scheduler removes all keys of a deletion request and of photos removed by the owner, then marks the request `completed` (AC-06); (6) lifecycle rules implement retention (thumb-only after 90 d for closed reports, delete after 365 d) — OPS-07 §8.

## IF-13 — SMTP and webhook {#if-13}
Inherits [ICD-00 IF-13](../../00-factorybrain-platform/docs/ICD-FactoryBrain-Interface-Control.md#if-13). Uses: magic-link / OTP mail; candidate and digest mails (with the fuzzed cell and signed thumbnails, never coordinates); **email relay** for threads when enabled — messages are forwarded from `thread-<id>@relay.<domain>` with the sender's address rewritten (FR-07, ADR-T08). Optional SMS provider (webhook adapter) for OTP only; disabled by default. Outbound mail is rate-limited by the same budget as push (FR-25).

## IF-14 — Metrics {#if-14}
`/metrics` (Prometheus, internal network only): `pt_upload_latency_seconds`, `pt_vision_backlog`, `pt_vision_oldest_age_seconds`, `pt_embed_seconds{device}`, `pt_ann_latency_seconds{radius_bucket}`, `pt_candidates_total`, `pt_notify_total{channel}`, `pt_budget_digested_total`, `pt_moderation_queue_depth`, `pt_captcha_challenges_total`, `pt_rate_limited_total{route}`, `pt_calibration_drift` (|shown precision − realised precision| over 30 d), `pt_recall10_slice{color,size}` (from the last benchmark), `pt_deletion_open`, `pt_active_embedding_version`.

## IF-39 — Map tiles and geocoding {#if-39}
| Item | Contract |
|---|---|
| Tiles | MapLibre GL in the PWA with a raster or vector tile source. Default: a self-hosted tile server (OPS-07 §5) or a hosted OSM-compatible provider with an API key in the client config. The PWA sends **no report data** to the tile provider — only tile coordinates |
| Geocoding (FR-03 address search) | Nominatim/Photon-compatible `GET /search?q=&countrycodes=th&format=json` via the API proxy `GET /geocode` (the client never calls the provider directly, so the provider sees the API's IP, not the user's). Results cached 24 h. Reverse geocoding is used only to label the owner's own location |
| Failure | Tiles down → the map renders a grid with cells on a blank background; geocoding down → GPS and pin still work (FR-03 has three sources) |
| Privacy | Address search queries are not logged with user ids; the geocoder is configured with `CONFIG.geocoder.log_queries = false` |

## IF-40 — Push {#if-40}
| Item | Contract |
|---|---|
| Web Push | VAPID keys (`SECRETS/vapid_private`, public key in client config); endpoints from the browser stored in `push_subscription` with `p256dh`/`auth`; payload encrypted (RFC 8291), ≤ 4 KB |
| FCM (Flutter app) | Server key in `SECRETS/fcm_server_key`; token stored as `endpoint` with `provider = fcm` |
| Payload | `{kind, title, body, url, cell, match_id?, calibrated_precision?}` — **a cell, never coordinates** (`trg_notification_budget` refuses `lat`/`lng`) |
| Budget | `can_notify()` before sending; over the cap the row becomes a digest (FR-25) |
| Failure | 404/410 from the push service → subscription revoked; provider down → email fallback for `candidate` kind; nothing is retried more than 3 times |

## IF-41 — CAPTCHA and anonymous device tokens {#if-41}
| Item | Contract |
|---|---|
| Device token | 32 random bytes, base64url, issued by `POST /auth/device`; stored as `sha256` in `device.token_hash`; sent as `X-Device-Token`; the PWA keeps it in IndexedDB; rotates on ban |
| Trust score | 0–1, starts 0.5; +0.05 per approved photo, −0.2 per hidden photo, −0.3 per upheld abuse report, −0.1 per rate-limit hit; `< 0.3` → `captcha_required`; `< 0.1` or moderator action → banned |
| CAPTCHA | Cloudflare Turnstile or hCaptcha (configurable). Server verifies with `POST https://challenges.cloudflare.com/turnstile/v0/siteverify` (or hCaptcha equivalent) using `SECRETS/captcha_secret`; the challenge id is bound to the device and expires in 10 min |
| Rate limits | Redis token buckets per `device:<id>:<route>`, `ip:<addr>:<route>`; defaults in `deploy/pawtrace.yaml`; counters mirrored hourly to `rate_limit_bucket` |
| Failure | CAPTCHA provider down → challenged devices cannot post (fail closed) but unchallenged ones can; the event is logged |

## IF-42 — Vision model contract {#if-42}
The contract between `worker-vision` and the model artefacts (any implementation that satisfies it can be registered as a `model_version`).

| Model | Input | Output | Rules |
|---|---|---|---|
| **Detector** (`kind = detector`) | RGB image ≤ 2048 px | `[{bbox: [x, y, w, h], class: dog, confidence}]` | classes other than dog discarded (AI-01); `confidence ≥ 0.5`; crops with short edge < 128 px rejected `CROP_TOO_SMALL`; no detection → `NO_DOG` (FR-09) |
| **Quality gate** (part of the detector stage) | crop | `quality_score ∈ [0, 1]` (Laplacian sharpness, occlusion estimate, exposure) | `< 0.3` → `LOW_QUALITY`; `< 0.5` → fusion penalty (Appendix A) |
| **NSFW screen** (`kind = nsfw`) | whole photo | `nsfw_score ∈ [0, 1]` | `≥ 0.9` → `hidden` + `nsfw_auto_hide` event; `0.6–0.9` → stays `pending` for a moderator; otherwise auto-approve (C-05, FR-26) |
| **Attributes** (`kind = attributes`) | crop | `{size_class, color_primary, color_secondary, coat_len, breed_group, has_markings}` each with confidence | confidence < 0.5 → field NULL (unknown is neutral in `attr_compat`) (FR-11) |
| **Identity embedding** (`kind = embedding`) | crop, 224–384 px square letterboxed | `float32[768]`, **L2-normalised** (‖v‖ = 1 ± 1e-3) | metric-learning model (ArcFace/triplet, AI-02); dims fixed at 768 by schema CHECK; every vector is stored with its `model_version_id`; a version is registered with its `checksum`; the worker refuses to run a version whose checksum differs |
| **Text embedding** (`kind = text`) | attributes rendered as text + description, TH/EN | `float32[1024]`, L2-normalised | multilingual model (AI-09) |

Batch API of the worker: `process(photo_id, model_versions{detector, nsfw, attributes, embedding})` → idempotent on `(photo_id, model_version_id)` (FR-13); `reembed(instance_ids[], to_version)` for AC-08 jobs (batch 256, GPU; 32, CPU). Aggregation: report vector = normalised mean of crop vectors (FR-12); medoid = crop with the highest mean cosine to the others. Versioning: a model change is a new `model_version`, never an overwrite; the benchmark harness (`AI-03`, filtered protocol) writes `benchmark_run`/`benchmark_slice`.

## IF-43 — Shelter bulk intake {#if-43}
`POST /shelters/intake` (role shelter): CSV (UTF-8, header `photo_file,intake_at,lat,lng,size_class,color_primary,coat_len,breed_group,notes`) + a zip of photos. Each row → a FOUND report owned by the shelter account with the shelter's location precision (≥ 100 m; shelters are not fuzzed against themselves but appear publicly as cells like everyone else); photos go through the same upload gate (EXIF strip, NSFW) and pipeline. Per-row result at `/shelters/intake/{batchId}`; limits 500 rows / 200 MB per batch, one batch at a time per account. Rejections use the same `processing_error` codes.

---

## 2. PWA client notes
- **Offline draft**: a sighting can be composed offline (photo, GPS, time) and is uploaded by a background sync when connectivity returns; the draft holds the stripped image (the strip runs client-side too, but the server strips again — the server is the guarantee).
- **Client-side resize** to ≤ 2048 px before upload (NFR-04); HEIC converted on the client where supported, otherwise server-side.
- **Location**: GPS with accuracy shown; pin on a MapLibre map; address search via the API proxy (IF-39). The client sends `precision_m`.
- **Device token** in IndexedDB; the PWA never stores an owner's session in `localStorage` (SEC-07).
- **Flutter app**: same API; FCM for push (IF-40); nothing else differs.

---

## 3. Interface matrix
| IF | Protocol | Auth | Data leaving PawTrace | Retry / failure |
|---|---|---|---|---|
| IF-10 | S3 over TLS | access key (secret file) | EXIF-free derivatives, crops, exports | 3 retries; upload gate fails closed |
| IF-13 | SMTP over TLS / HTTPS webhook | credentials (secret file) | email address of the recipient, cell, signed thumbnail | queue + retry; budget |
| IF-14 | HTTP scrape | internal network | metrics | — |
| IF-39 | HTTPS | API key (client tiles), none/self-hosted (geocoder) | tile coordinates; address query text (no user id) | degrade to GPS/pin |
| IF-40 | HTTPS (Web Push, FCM) | VAPID key / FCM key | notification payload with a cell | 3 retries; revoke on 410 |
| IF-41 | HTTPS (siteverify) | secret key | CAPTCHA token, client IP | fail closed for challenged devices |
| IF-42 | in-process (worker) | — | none | queue; NFR-08 |
| IF-43 | HTTPS multipart | session (shelter) | — | per-row results |

## 4. Change control
| Item | Versioned in | Change procedure |
|---|---|---|
| Model artefacts (IF-42) | `model_version` (checksum, dims, benchmark) | register → benchmark → re-embed → activate (OPS-07 §7); never overwrite |
| Fuzz precision, thresholds, weights, rate limits | `config_version` (validated against `deploy/schemas/pawtrace-config.schema.json`) | `PUT /admin/config`; every candidate/notification produced after the load carries the version |
| Bucket layout and URL TTLs | `setting.signed_url.ttl_s`, OPS-07 §5 | config change |
| Push/CAPTCHA/mail providers | `.env` + secret files | OPS-07 §4 |
| CSV intake header (IF-43) | this document | additive columns only |

## 5. Traceability
| SRS-07 | IF |
|---|---|
| FR-03 | IF-39 |
| FR-07 | IF-13 (relay), §2 |
| FR-08…FR-13, AI-01, AI-02, AI-06, AI-09 | IF-42 |
| FR-22, FR-25 | IF-40, IF-13 |
| FR-26 | IF-42 (NSFW) |
| FR-28, C-02 | IF-41 |
| C-04, C-05, NFR-07, AC-05 | IF-10 |
| NFR-04, AC-03 | §2 |
| NFR-08, AC-07 | IF-42 batch API, IF-14 backlog metrics |
| SRS §2.2 shelter volunteer | IF-43 |
