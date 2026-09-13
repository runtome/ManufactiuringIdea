# Security Requirements Specification — PawTrace (AI Dog Finder 2.0)

| Field | Value |
|---|---|
| Document ID | SEC-07-PawTrace |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-07](../SRS-PawTrace-AI-Dog-Finder.md) · [SAD-07](SAD-PawTrace-Software-Architecture.md) · [DDS-07](DDS-PawTrace-Database-Design.md) · [API-07](../api/API-Specification.md) · [ICD-07](ICD-PawTrace-Interface-Control.md) · [TEST-07](TEST-PawTrace-Test-Plan.md) TS-6, TS-9 · [OPS-07](OPS-PawTrace-Deployment-Operations.md) |

---

## 1. Scope and what is different here
PawTrace is a **public** service used by anonymous strangers about their **homes**: a lost-dog report is a statement that a family lives at a place, is distressed, and will go where they are told a dog was seen. The security problem is therefore not industrial (no machines, no ERP) but personal: location privacy, stalking, pet theft, luring, harassment, and the ordinary abuse of any open posting system. Two further properties shape the requirements: the system must accept posts **without an account** (C-02), and it must never present its own output as a fact (C-03) — a wrong "match" delivered confidently can send a person to a stranger's door.

### 1.1 Security objectives
| # | Objective | Enforcement point |
|---|---|---|
| **O-1** | **No exact location leaves the system except to the reporter and a mutually-consented counterpart.** | `public_ro` role without `location`; `fuzz_cell()`; `region.fuzz_public_precision ≤ 5`; notification payload check; `thread` consent flags (DDS-07 DD-T01, DD-T07) |
| **O-2** | **No personal contact data is exchanged by the system.** | Relay threads; no phone column; `email_masked` only; email relay rewrites addresses (ADR-T08) |
| **O-3** | **Images are private, EXIF-free and moderated before anyone sees them.** | Upload gate strips in memory; `photo.exif_stripped` CHECK; no originals bucket; signed URLs minted only for approved photos (DD-T03, IF-10) |
| **O-4** | **Anonymous posting cannot be turned into spam, scraping or luring at scale.** | Device tokens with trust scores; rate limits per device/IP/route; CAPTCHA escalation; moderation queue; bans (DD-T09, IF-41) |
| **O-5** | **People can take their data back, including what the models derived from it.** | `deletion_request` cascade incl. embeddings and text embeddings; export; SLA 72 h (DD-T08) |
| **O-6** | **The system never asserts an identification.** | `match` cannot be inserted or updated to confirmed without a human decision; displayed number is a calibrated precision; wording rules (DD-T02, ADR-T04, UM-07) |

## 2. Assets
| Asset | Sensitivity | Where |
|---|---|---|
| Exact report locations | **critical** — home addresses of vulnerable people; pet-theft targeting | `report.location` |
| Photos (originals never exist; derivatives, crops) | high — faces, homes, children in the background | private buckets |
| Identity of posters (email, device token hash, IP) | high | `app_user`, `device`, `audit.log.ip` |
| Relay messages | high — may contain volunteered phone numbers/addresses | `message` |
| Decisions and calibration | medium — training data with consent versions | `match_decision`, `calibration_bin` |
| Embeddings | medium — derived data; a deletion right applies (NFR-06) | `embedding`, `report_embedding`, `text_embedding` |
| Model artefacts and versions | medium — a tampered model degrades retrieval or biases it | `model_version.checksum`, volumes |
| Secrets (DB, S3, VAPID, FCM, CAPTCHA, SMTP, JWT) | critical | secret files |

## 3. Trust boundaries
| Zone | Contents | Trust |
|---|---|---|
| Z0 Internet | PWA/Flutter clients, anonymous posters, scrapers, push/tile/CAPTCHA/mail providers | none |
| Z1 Edge | reverse proxy (TLS, rate limits, WAF rules), `api` public pool (`public_ro`) | low |
| Z2 App | `api` authenticated pool (`app_rw`), workers (`worker_rw`), scheduler | medium |
| Z3 Data | PostgreSQL, Redis, object store (private buckets) | high |
| Z4 Ops | admin role, moderators, secret files | high; audited |

Boundary rules: Z0→Z1 only over TLS; Z1 handlers cannot read a coordinate (role); Z2 has egress only to the configured providers; Z3 is not reachable from Z0/Z1 except through the API; Z4 actions are in `audit.log`.

## 4. Threat model

### 4.1 Threats (STRIDE)
| ID | Threat | Category | Objective | Controls |
|---|---|---|---|---|
| THR-T01 | **Location scraping** — repeated `/map/cells` or `/search` calls, jittered queries, or timing/correlation to sharpen a location below the cell | Information disclosure | O-1 | Cells not jitter (ADR-T05); public role cannot read coordinates (SEC-T01); rate limits per IP on public routes (SEC-T20); `event_hour` not exact time; cell size never below geohash-5 by CHECK |
| THR-T02 | **EXIF GPS leak** — a photo served with its EXIF, or the coarse-location consent used to store a fine location | Information disclosure | O-3, O-1 | In-memory strip before any write; CHECK on the row; `exif_location_coarse` CHECK ≥ 1 km (SEC-T10, SEC-T11); AC-05 automated test |
| THR-T03 | **Stalking via contact** — a poster's email/phone exposed, or the relay used to extract them | Information disclosure | O-2 | No phone column; masked email; relay rewrite; the UI warns before a user pastes contact details; moderator can hide messages (SEC-T30) |
| THR-T04 | **Luring** — fake sightings posted to make an owner come to a place | Spoofing / safety | O-4, O-6 | Anonymous posts carry a device with trust score; calibrated score exposes low-evidence candidates; UM-07 safety copy ("meet in public, bring someone"); abuse reports; moderators; shelters as trusted posters |
| THR-T05 | **Photo scraping / re-hosting** | Information disclosure | O-3 | Signed URLs 5–15 min; no listing; thumbnails public-facing only for approved photos; per-IP limits on URL minting |
| THR-T06 | **Spam / flood** — thousands of anonymous posts, duplicate photos from many devices | DoS / tampering | O-4 | Device + IP buckets; sha256 duplicate detection across devices → CAPTCHA; ban; moderation queue priority |
| THR-T07 | **Model-space mixing** after an upgrade — candidates compared across incompatible vectors | Tampering (integrity) | O-6 | One `search_active` version; per-version partial indexes; activation gated on completed re-embed (DD-T06) |
| THR-T08 | **Model tampering** — a swapped artefact biases or breaks retrieval | Tampering | O-6 | `model_version.checksum` verified by the worker at load; volumes read-only; benchmark required before activation |
| THR-T09 | **Moderator abuse** — hiding legitimate posts, reading threads to harass | Elevation / disclosure | O-2 | Every moderation action audited with reason; thread access by moderators only via an abuse report on that thread; quarterly audit review |
| THR-T10 | **Account takeover via magic link** — link forwarded, intercepted, or replayed | Spoofing | O-1, O-2 | Single-use link/OTP, 10-min expiry, bound to the requesting user-agent family; sessions 30 d with rotation; `auth_event` log |
| THR-T11 | **Public handler bug** returning a `Report` instead of `ReportPublic` | Information disclosure | O-1 | Structural: the public pool's role has no column grant on `location`, so the query fails rather than leaks (SEC-T01); TC-060 |
| THR-T12 | **Deletion incomplete** — embeddings or crops survive a deletion request | Repudiation of rights | O-5 | Trigger cascade for DB rows; scheduler for objects; `v_deletion_status.sla_breached` alert; AC-06 test |
| THR-T13 | **Push payload leak** — a notification carrying coordinates through a third-party push service | Information disclosure | O-1 | `trg_notification_budget` refuses `lat`/`lng` keys; payloads encrypted (Web Push) |
| THR-T14 | **Subscription polygon as a probe** — many tiny area subscriptions to localise reports | Information disclosure | O-1 | Minimum polygon area (≥ 1 km²), ≤ 5 subscriptions per user, alerts carry geohash-6 only |
| THR-T15 | **Consent bypass** — one side sees the other's exact location before both consented | Information disclosure | O-1 | `ThreadConsent.exact_locations_shared` computed from both flags in the database; TC-124 |

### 4.2 The attack worth walking through — "find where the dog (and the family) lives"
An attacker wants the home of the owner of a lost-dog report. Public views give geohash-5 (≈ 4.9 km): useless. They create 50 anonymous devices and post fake sightings around the city to trigger candidate notifications — but notifications go to the owner, not to them, and carry the *sighting's* cell, not the owner's location. They subscribe to areas: alerts carry geohash-6 of new reports (≈ 1.2 km), minimum polygon 1 km², five subscriptions — still coarse. They query `/search` with moving centres to find where the report enters and leaves the radius: the response is the cell, identical for every query that includes the report, and the public role cannot compute a distance from an exact point because it cannot read one. They post a plausible sighting and get confirmed by the owner: the thread opens; the owner's exact location appears only if **the owner** consents; the UI tells the owner to meet in a public place. Residual: a determined attacker who is confirmed by a trusting owner and receives consent — social, not technical (RR-T01).

## 5. Security requirements

### 5.1 Location (O-1)
| ID | Requirement | Verification |
|---|---|---|
| SEC-T01 | The database role used by public request handlers SHALL have no SELECT grant on `report.location`, `thread`, `message`, `app_user`, `device`, `match`, `subscription`, `notification` or any vector table. | TC-003 grant check; TC-060 |
| SEC-T02 | Public representations SHALL carry a geohash cell of ≤ 5 characters; subscriber notifications ≤ 6; `region` CHECKs SHALL make finer configuration impossible. | TC-003, TC-061, AC-04 |
| SEC-T03 | Exact coordinates SHALL be returned only to the report's owner/device, and to the confirmed counterpart when both consent flags are true. | TC-124, TC-125 |
| SEC-T04 | Notification payloads SHALL be refused by the database if they contain `lat`, `lng` or `location`. | TC-003 probe 7 |
| SEC-T05 | Area subscriptions SHALL be ≥ 1 km² and ≤ 20,000 km², at most 5 per user. | TC-070 |
| SEC-T06 | Public timestamps SHALL be truncated to the hour; created dates to the day. | TC-061 |

### 5.2 Contact and identity (O-2)
| ID | Requirement | Verification |
|---|---|---|
| SEC-T10 | No phone number SHALL be stored in a structured column; email SHALL be returned only masked and only to its owner. | TC-003 (schema has no phone column), TC-126 |
| SEC-T11 | Contact between parties SHALL occur only through relay threads; email relay SHALL rewrite sender addresses. | TC-052, TC-127 |
| SEC-T12 | Threads SHALL be readable by their two parties; moderators SHALL access a thread only via an open abuse report on it, with an audit row. | TC-128 |
| SEC-T13 | Sign-in SHALL be passwordless: single-use magic link/OTP, 10-min expiry; sessions SHALL rotate; `audit.auth_event` SHALL record all outcomes. | TC-130 |
| SEC-T14 | Device tokens SHALL be stored hashed; the plaintext SHALL be shown once. | TC-131 |

### 5.3 Images (O-3)
| ID | Requirement | Verification |
|---|---|---|
| SEC-T20 | Uploads SHALL be decoded, stripped of all metadata and re-encoded in memory before any persistent write; no originals bucket SHALL exist. | TC-014 (AC-05), TC-004 |
| SEC-T21 | A `photo` row SHALL be impossible with `exif_stripped = false` (CHECK). | TC-003 probe 5 |
| SEC-T22 | Signed URLs SHALL expire (≤ 15 min thumb/card, ≤ 5 min full, 24 h export) and SHALL be minted only for approved photos unless the caller owns the report. | TC-132 |
| SEC-T23 | Buckets SHALL deny public read; object keys SHALL contain no identity, location or time. | TC-004 |
| SEC-T24 | NSFW screening SHALL run before any non-owner can see a photo; `≥ 0.9` auto-hidden, `0.6–0.9` held for a moderator. | TC-100 |

### 5.4 Abuse resistance (O-4)
| ID | Requirement | Verification |
|---|---|---|
| SEC-T30 | Rate limits SHALL apply per device, per IP and per route to every write and to public reads (`/search`, `/map/cells`, `/geocode`, URL minting). | TC-102 |
| SEC-T31 | A device whose trust score falls below 0.3 SHALL be challenged with a CAPTCHA; below 0.1 or on moderator action it SHALL be banned; banned devices SHALL be refused by the database. | TC-103, TC-003 probe 8 |
| SEC-T32 | Identical photo hashes from ≥ 3 devices within 24 h SHALL trigger a CAPTCHA challenge and a moderation item. | TC-104 |
| SEC-T33 | Every moderation action SHALL carry a reason and an audit row; hide/remove SHALL be reversible except `remove` of NSFW content. | TC-101 |
| SEC-T34 | CAPTCHA provider failure SHALL fail closed for challenged devices only. | TC-105 |

### 5.5 Rights (O-5)
| ID | Requirement | Verification |
|---|---|---|
| SEC-T40 | A deletion request SHALL remove reports, photos, crops, embeddings, text embeddings, subscriptions, push subscriptions and notifications of the subject, anonymise the account or device, and leave only an identity-free tombstone. | TC-120 (AC-06) |
| SEC-T41 | Bucket objects SHALL be removed within 72 h; breaches SHALL alert. | TC-121 |
| SEC-T42 | Export SHALL include reports, photos, decisions and messages of the subject, delivered by a 24 h signed URL. | TC-122 |
| SEC-T43 | Decisions SHALL carry the consent version; training exports SHALL include only decisions whose consent version permits it. | TC-123 |

### 5.6 Honesty of output (O-6)
| ID | Requirement | Verification |
|---|---|---|
| SEC-T50 | The database SHALL refuse a match inserted or updated as confirmed without a decision row. | TC-003 probes 1–2 |
| SEC-T51 | The displayed score SHALL be the calibrated precision; raw cosine SHALL appear only in a details panel labelled as similarity. | TC-046, UM-07 review |
| SEC-T52 | Exactly one embedding version SHALL be searchable at a time; activation SHALL require a benchmark and a completed re-embed. | TC-110, TC-003 probe 6 |
| SEC-T53 | Model artefacts SHALL be checksum-verified at load; mismatch SHALL stop the worker. | TC-111 |

### 5.7 Platform hygiene (inherited)
| ID | Requirement | Verification |
|---|---|---|
| SEC-T60 | Containers non-root, read-only root fs, `cap_drop ALL`, `no-new-privileges`; ports bound to `BIND_ADDR`; egress network only for services that need providers. | TC-004 |
| SEC-T61 | Secrets in files (0400), never in `.env`, config or images. | TC-007 |
| SEC-T62 | TLS at the edge; HSTS; CSP for the PWA; no `localStorage` sessions. | TC-133 |
| SEC-T63 | `audit.log` append-only (no UPDATE/DELETE grants); retained 3 years. | TC-003 |

### 5.8 RBAC matrix
| Action | Anonymous (device) | User | Shelter | Moderator | Admin |
|---|---|---|---|---|---|
| Browse map/search (cells) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Post sighting/found | ✅ (rate-limited) | ✅ | ✅ (+ bulk) | ✅ | ✅ |
| Post lost report; see own candidates; decide | ❌ | ✅ | ✅ | ✅ | ✅ |
| Relay thread (own matches) | ✅ (found side) | ✅ | ✅ | via abuse report | ❌ |
| Report abuse | ✅ | ✅ | ✅ | ✅ | ✅ |
| Hide/remove/restore, merge duplicates, ban device | ❌ | ❌ | ❌ | ✅ | ✅ |
| Models, config, regions, calibration, bias report, deletions | ❌ | ❌ | ❌ | ❌ | ✅ |
| Read exact locations of others | **nobody** — only mutual consent in a thread | | | | |

## 6. Security testing
| Suite | Content |
|---|---|
| TS-0 (static) | grants (`public_ro`), CHECKs, compose hardening, secret scan |
| TS-6 (privacy) | AC-04 fuzz verification through the API with 10 k randomised queries; EXIF strip (AC-05) on a corpus with GPS/XMP/IPTC; consent handshake; deletion (AC-06) incl. bucket keys |
| TS-9 (security) | rate limits and CAPTCHA escalation; magic-link replay; signed-URL expiry and non-approved minting; moderator thread access; push payload scan; subscription polygon limits; model checksum |
| Pen test before launch | scope: Z0→Z1, public API, PWA; explicit goal: obtain a coordinate finer than the cell for any report not owned |

## 7. Incident procedures
| Incident | First actions |
|---|---|
| Coordinate leak suspected | Disable public routes (`PUBLIC_ROUTES_ENABLED=false`); confirm via audit; rotate signed-URL key; notify affected owners; post-mortem on the grant/view path |
| Harassment via thread | Moderator hides messages, bans device/user, preserves audit; owner offered report closure |
| Spam wave | Lower CAPTCHA threshold (`trust.captcha_below`), tighten buckets, bulk-hide by sha256 cluster |
| Model artefact mismatch | Worker halts; restore artefact from the release store; verify checksum; re-run benchmark |
| Deletion SLA breach | Run the object sweep manually (OPS-07 RB-09); record in `deletion_request.summary_json` |

## 8. Residual risks
| ID | Risk | Acceptance |
|---|---|---|
| RR-T01 | An owner consents to share an exact location with a malicious "finder" | Social risk; mitigated by copy, calibrated score, meeting advice; accepted |
| RR-T02 | Photos reveal homes or people in the background | Users are warned; moderators can hide; accepted |
| RR-T03 | Third-party push/tile/CAPTCHA providers see IPs and cells | Providers configurable and self-hostable (OPS-07 §5); accepted |
| RR-T04 | Determined scraping of thumbnails within URL lifetime | 15-min TTL and rate limits; accepted |
| RR-T05 | Geohash cell boundaries: a report near an edge is in one cell only, so density across cells can hint at position | Cells are large; accepted |

## 9. Traceability
| SRS-07 | SEC |
|---|---|
| C-01, AC-04, NFR-05 | O-1, SEC-T01…T06, THR-T01, T11, T13, T14, T15 |
| C-02, FR-28 | O-4, SEC-T30…T34, THR-T06 |
| C-03, AI-04 | O-6, SEC-T50, T51 |
| C-04, AC-05 | O-3, SEC-T20, T21, THR-T02 |
| C-05, FR-26, FR-27 | SEC-T24, T33 |
| FR-07 | O-2, SEC-T10…T12, THR-T03 |
| AI-06, AI-07, AC-08 | SEC-T52, T53, T43, THR-T07, T08 |
| NFR-06, AC-06 | O-5, SEC-T40…T42, THR-T12 |
| NFR-07 | SEC-T22, T23, THR-T05 |

## Appendix A — Review checklist for a PawTrace change
- Does any new query run on the public pool? Then it must not touch `location`, threads, users or vectors — the role will refuse, but the handler must expect it.
- Does any new payload leave the system (push, mail, webhook, export)? Cells only; run the payload scan.
- Does any new UI string say "match", "found", "identified" before a decision? Rewrite.
- Does the change touch the upload gate? Re-run the EXIF corpus (TC-014).
- Does the change add a model? Register a version; benchmark; re-embed; never overwrite.
- Does the change store anything about a person? Add it to the deletion cascade and the export.
