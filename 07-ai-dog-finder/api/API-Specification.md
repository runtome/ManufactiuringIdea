# API Specification — PawTrace (AI Dog Finder 2.0)

| Field | Value |
|---|---|
| Document ID | API-07-PawTrace |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Machine-readable | [`openapi.yaml`](openapi.yaml) — OpenAPI 3.1, **47 paths / 54 operations / 48 schemas**; `Problem` byte-identical to API-00 (TEST-07 TC-008) |
| Related | [SRS-07](../SRS-PawTrace-AI-Dog-Finder.md) §4.1 · [SAD-07](../docs/SAD-PawTrace-Software-Architecture.md) · [DDS-07](../docs/DDS-PawTrace-Database-Design.md) · [ICD-07](../docs/ICD-PawTrace-Interface-Control.md) · [SEC-07](../docs/SEC-PawTrace-Security-Requirements.md) |

---

## 1. SRS §4.1 mapping
| SRS | This spec | Note |
|---|---|---|
| `POST /api/v1/reports` | `POST /reports` | LOST needs a session; FOUND/SIGHTING accept a device token (C-02) |
| `POST /api/v1/reports/{id}/photos` | same | 202 queued; EXIF stripped before storage; sha256-idempotent |
| `GET /api/v1/reports/{id}/matches` | same | owner only; includes `processing` so the owner sees photos still being embedded |
| `POST /api/v1/matches/{id}/decision` | same | the only path that changes a candidate's status |
| `GET /api/v1/search?lat=&lng=&radius=&days=&q=` | same | public; `ReportPublic` only; `q` is semantic TH/EN (AI-09) |
| `POST /api/v1/search/by-photo` | same | synchronous when a worker is free, else 202 + `Location` |
| `GET /api/v1/map/cells?bbox=&days=` | same | geohash-5 cells; AC-04 tests this endpoint |
| `POST /api/v1/subscriptions` | same | polygon ≤ 20,000 km² |

Added: auth (`/auth/magic-link`, `/auth/verify`, `/auth/device`, `/auth/captcha`), report detail/edit/status/photo, match detail and reunion, contact relay (`/matches/{id}/thread`, `/threads/{id}/messages`, `/threads/{id}/consent`), push registration and inbox, moderation (`/abuse-reports`, `/moderation/*`), privacy (`/me`, `/me/export`, `/me/delete`), geocoding proxy (`/geocode`), admin (models, re-embed, activate, benchmark, bias report, calibration, config, regions, deletions, notify budget), shelters intake (IF-43), system.

## 2. Conventions
- Base `/api/v1`; JSON; UTC timestamps; ids UUIDv7. Errors: RFC 7807 `application/problem+json` (`Problem`, verbatim from API-00) with a stable `code` (§7).
- **Two credentials**: `Authorization: Bearer <jwt>` (session from `/auth/verify`; roles user/shelter/moderator/admin) or `X-Device-Token` (anonymous device from `/auth/device`). Public paths (`/search`, `/map/cells`, `GET /reports/{id}` for non-owners, `/healthz`, `/readyz`) need neither.
- **Two database roles behind the API**: authenticated handlers use `app_rw`; public handlers use `public_ro`, which cannot read `report.location` (DDS-07 DD-T01). This is why the public representation cannot leak a coordinate even through a handler bug.
- Rate limits per device, IP and route → `429` + `Retry-After`; abuse signals → `428` + `CaptchaChallenge` (§5).
- Pagination by opaque `cursor`; list sizes ≤ 50.
- Every image field is a **signed URL** (thumb/card 15 min, full 5 min, exports 24 h). The signer refuses non-approved photos for anyone but the owner. The API never streams image bytes.

## 3. The privacy contract (C-01, C-04, NFR-05, NFR-07)
| Audience | Representation | Location form | Photos |
|---|---|---|---|
| Anyone / anonymous | `ReportPublic`, `MapCell`, `SearchResult`, `PhotoSearchHit` | `Cell` — geohash-5 (≈ 4.9 km), `event_hour` | approved only, signed thumb |
| Logged-in area subscriber (notification payload) | `Notification.payload.cell` | geohash-6 (≈ 1.2 km) | — |
| Owner of a report (or its device) | `Report` | exact `Location` with precision and source | all, all states |
| Owner viewing candidates | `MatchCandidate` | the found report's geohash-6 `found_cell` + `distance_band`; exact `distance_m` in `components` for the owner | side-by-side signed card + crop |
| Both sides of a **confirmed** candidate after **both** consented | `ThreadConsent.exact_locations_shared = true` → `lost_location`, `found_location` | exact | — |
| Moderator | `ModerationItem` | none | preview thumb |

Rules: `Photo.exif_stripped` is a `const true` — a photo with EXIF cannot appear; `capture_time_exif` is time only; EXIF GPS may only pre-fill the report's location when `consent_coarse_location` is true and only rounded to ≥ 1 km (`location.source = exif_coarse`). `Me.email_masked` is the only form in which an email leaves the API; there is no phone field anywhere. `/reports/{id}` for a non-owner returns `ReportPublic` (a `oneOf` in the spec) — never a 403 that would reveal ownership.

## 4. The candidate contract (C-03, AI-04, FR-18, FR-19)
- `MatchCandidate.status` is `candidate` until a `Decision` is posted; `confirmed`/`rejected` afterwards; `superseded` when a reunion closes the report. There is no `identified`, `match` or `certain` value, and no endpoint can create a confirmed candidate.
- **`calibrated_precision`** is the number the UI shows: the empirical confirm rate of past candidates in the same score bin for this model version (`CalibrationBin`). `calibration_provisional` is true while the version has fewer than 200 decisions. `score` and `components.cosine` exist for the details panel; a client must not present them as "the match score".
- `components` always carries the seven Appendix A terms plus `weights`; `distance_m` is exact for the owner, `distance_band` for everyone else.
- A `Decision` carries `consent_version` (AI-07); decisions are append-only — a second decision on the same candidate returns `409 ALREADY_DECIDED`.
- Wording: "possible sighting", "candidate", "% of similar candidates were confirmed" (UM-07 A0). The API `summary` strings follow the same rule.

## 5. The anonymous contract (C-02, FR-28)
1. First post from a browser: `POST /auth/device` → `DeviceToken` (shown once; stored hashed). The PWA keeps it in IndexedDB.
2. `POST /reports` (kind sighting/found) and `/reports/{id}/photos` with `X-Device-Token`. No email, no CAPTCHA by default (AC-03).
3. Limits (defaults, `deploy/pawtrace.yaml`): 5 posts / device / hour, 20 / IP / hour, 3 photo-searches / device / hour; exceeded → `429 RATE_LIMITED` with `Retry-After`.
4. Abuse signals (burst, identical sha256 from several devices, abuse reports, low trust score) → the next post returns `428 CAPTCHA_REQUIRED` with a `CaptchaChallenge`; `POST /auth/captcha` clears it (IF-41).
5. A banned device gets `403 DEVICE_BANNED` on every write.
6. A device can delete its data (`POST /me/delete` with the device token) and gets the same `DeletionStatus`.

## 6. Flows
**Lost dog** — `/auth/magic-link` → `/auth/verify` (consent) → `POST /reports` (lost) → `POST /reports/{id}/photos` ×1–10 → poll `GET /reports/{id}/matches` (`processing` then `candidates`) → push arrives (`Notification.kind = candidate`) → `GET /matches/{id}` → `POST /matches/{id}/decision` confirm → `GET /matches/{id}/thread` → messages → both `POST /threads/{id}/consent` → exact locations in `ThreadConsent` → `POST /matches/{id}/reunion`.

**Sighting in 60 s** — `/auth/device` → `POST /reports` (sighting; GPS) → `POST /reports/{id}/photos` (one photo) → `202`. Done.

**Photo-first search** — `POST /search/by-photo` → `PhotoSearchHit[]` (public representations with calibrated precision) — for finders who want to check before posting, and for shelters.

**Model upgrade (AC-08)** — `POST /admin/models` (v2) → `POST /admin/models/{v2}/benchmark` → `POST /admin/models/{v2}/reembed` → `GET /admin/models` until `reembed_pct = 100` → `POST /admin/models/{v2}/activate` (refused with `REEMBED_INCOMPLETE` before).

**Deletion (AC-06)** — `POST /me/delete {confirm: DELETE}` → `202 DeletionStatus(state: db_done)` → `GET /me/delete/{id}` → `completed` within 72 h; the report URLs return `410 GONE`.

## 7. Error catalogue
| HTTP | `code` | When |
|---|---|---|
| 400 | `BAD_REQUEST` | malformed bbox, cursor |
| 401 | `UNAUTHENTICATED` | no/invalid session or device token |
| 403 | `NOT_OWNER` · `ROLE_REQUIRED` · `DEVICE_BANNED` · `THREAD_NOT_PARTY` | |
| 404 | `NOT_FOUND` · `NO_THREAD` | thread requested on an unconfirmed candidate |
| 409 | `ALREADY_DECIDED` · `REPORT_TRANSITION` · `REEMBED_INCOMPLETE` · `BENCHMARK_MISSING` · `REEMBED_RUNNING` · `PHOTO_NOT_PROCESSED` · `NOT_CONFIRMED` | database guard names surface unchanged (DDS-07 Appendix A) |
| 410 | `GONE` | deleted report/photo |
| 413 | `FILE_TOO_LARGE` | > 12 MB |
| 422 | `VALIDATION_FAILED` · `NO_DOG` · `CROP_TOO_SMALL` · `LOW_QUALITY` · `TOO_MANY_PHOTOS` · `AREA_TOO_LARGE` · `CONFIG_INVALID` · `CAPTCHA_WRONG` | pipeline rejections are also written to `Photo.processing_error` |
| 428 | `CAPTCHA_REQUIRED` | body is `CaptchaChallenge` |
| 429 | `RATE_LIMITED` | `Retry-After` |
| 503 | `NOT_READY` | DB/Redis/object store down — a stopped GPU worker is **not** 503 (NFR-08) |

## 8. Traceability
| SRS-07 | Endpoints / schemas |
|---|---|
| FR-01…FR-07 | `/reports`, `/reports/{id}`, `/reports/{id}/photos`, `/reports/{id}/status`, `ReportCreate.location.source`, `event_at` (FR-04), thread endpoints (FR-07) |
| FR-08…FR-13 | `Photo.processing_state/error`, `instances`, `/admin/models` (versions) |
| FR-14…FR-21 | `/reports/{id}/matches`, `MatchCandidate`, `ScoreComponents`, `/matches/{id}/decision`, `/matches/{id}/reunion`, `/search?q` |
| FR-22…FR-25 | `/push/subscriptions`, `/subscriptions`, `/notifications` (digest), `/map/cells` |
| FR-26…FR-29 | `/abuse-reports`, `/moderation/*`, `428`/`429`, `/moderation/duplicates/{id}` |
| C-01…C-05 | §3, §4, §5 |
| AI-03, AI-04, AI-06, AI-07, AI-08, AI-09 | `/admin/models/*/benchmark`, `CalibrationBin`, re-embed/activate, `Decision.consent_version`, `/admin/bias-report`, `/search?q` |
| NFR-05, NFR-06, NFR-07, NFR-08 | `ThreadConsent`, `/me/export`, `/me/delete`, signed URLs, `/readyz` |
| AC-03, AC-04, AC-06, AC-08 | §5, `/map/cells`, §6 |
