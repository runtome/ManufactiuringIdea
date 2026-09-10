# Software Requirements Specification — AI Dog Finder 2.0 (Multimodal Lost-Pet Search)

| Field | Value |
|---|---|
| Document ID | SRS-07-PawTrace |
| Project code name | **PawTrace** |
| Version | 1.0 (Draft) |
| Date | 2026-09-10 |
| Author | Suphot N. |
| Status | Draft for review |
| Predecessor | "Where Is My Dog" (v1) |

---

## 1. Introduction

### 1.1 Purpose
Specify the evolution of the earlier "Where Is My Dog" project into a **multimodal retrieval system**: dog detection → identity embedding → vector search constrained by geography and time → ranked candidate matches reviewed by humans.

This is the consumer/startup-flavoured project in the set. Its technical core — embeddings + pgvector + geospatial + temporal filtering — is directly transferable to industrial part-matching.

### 1.2 Scope

**In scope**
- Public reporting of LOST and FOUND/SIGHTING dogs with photos, location and time.
- Dog detection, cropping, quality filtering and identity embedding.
- Similarity search filtered by radius, time window and coarse attributes (size, colour, breed group).
- Ranked match candidates with a human confirm/reject flow.
- Notifications to owners and nearby users; a public sightings map.
- Mobile-first web app (PWA) + optional Flutter app.

**Out of scope**
- Definitive identification claims (the system ranks candidates; humans decide).
- Payments, rewards, or shelter management software.
- Real-time video surveillance / street-camera integration.
- Non-dog species (v1).

### 1.3 Definitions
**Report** = a LOST or FOUND submission. **Sighting** = a time-stamped, geo-tagged observation. **Embedding** = a vector representing an individual dog's appearance. **Match** = a scored candidate pair (lost report ↔ sighting).

---

## 2. Overall Description

### 2.1 Product perspective
```
Photo upload (owner / finder)
        ↓
Dog detection + crop + quality gate
        ↓
Attribute model (size · coat colour · breed group)
Embedding model (identity vector, 512–1024 d)
        ↓
PostgreSQL + pgvector + PostGIS
        ↓
Candidate search:  ANN similarity
                 ∩ radius (≤ R km)
                 ∩ time window (≤ D days)
                 ∩ attribute compatibility
        ↓
Re-ranking (fusion score)
        ↓
Human review → confirm / reject
        ↓
Notification · map · reunion record
```

### 2.2 User classes
| Class | Need |
|---|---|
| Owner of a lost dog | post, get alerts, review candidates |
| Finder / passer-by | post a sighting in under 60 s, no account required |
| Shelter / rescue volunteer | bulk-post intakes, search by photo |
| Moderator | remove abuse, merge duplicates |
| Admin | models, thresholds, regions |

### 2.3 Operating environment
Mobile browsers (PWA) and Android app; FastAPI backend; PostgreSQL 16 + pgvector + PostGIS; object storage for images; GPU worker for embedding (batch, can be the RTX 3060 Ti); optional CPU-only mode for low volume.

### 2.4 Constraints
| ID | Constraint |
|---|---|
| C-01 | Exact locations SHALL be fuzzed in public views (grid/geohash) to protect user privacy and prevent pet theft. |
| C-02 | Posting a sighting MUST work without account creation (rate-limited, moderated). |
| C-03 | The system SHALL never assert a definitive match; it presents ranked candidates with a similarity score. |
| C-04 | Uploaded images MUST be stripped of EXIF (except a user-consented coarse location) before storage/serving. |
| C-05 | Content moderation is mandatory before public display of user photos. |

### 2.5 Assumptions
Users can supply at least one reasonably clear photo; most searches are local (< 20 km); dataset for identity embeddings can be assembled from public dog re-identification datasets plus in-app data with consent.

---

## 3. Functional Requirements

### 3.1 Reporting
| ID | Requirement | Priority |
|---|---|---|
| FR-01 | A user SHALL create a LOST report with 1–10 photos, last-seen location, time, and description. | Must |
| FR-02 | A user SHALL create a FOUND/SIGHTING report with photo(s), location and time, without registering. | Must |
| FR-03 | Location SHALL be selectable by GPS, map pin or address search. | Must |
| FR-04 | The system SHALL auto-extract capture time from EXIF when present and let the user correct it. | Should |
| FR-05 | Reports SHALL have a status lifecycle: active → matched → reunited → expired/closed. | Must |
| FR-06 | Owners SHALL be able to add photos to a report later, improving the embedding set. | Should |
| FR-07 | A contact channel SHALL be provided that does not expose the poster's phone/email directly (in-app or relay). | Must |

### 3.2 Vision pipeline
| ID | Requirement | Priority |
|---|---|---|
| FR-08 | Each uploaded photo SHALL be processed to detect dogs and produce cropped instances. | Must |
| FR-09 | Photos with no dog, or with a crop below a minimum size/quality, SHALL be rejected with clear feedback. | Must |
| FR-10 | The system SHALL compute an identity embedding per crop and store it with an HNSW index. | Must |
| FR-11 | The system SHALL predict coarse attributes: size class, primary/secondary coat colour, coat length, breed group, and distinctive markings presence. | Should |
| FR-12 | A report with multiple photos SHALL be represented by a set of embeddings and an aggregate (mean/medoid) vector. | Must |
| FR-13 | The pipeline SHALL be idempotent and re-runnable when a model is upgraded (versioned embeddings). | Must |

### 3.3 Matching
| ID | Requirement | Priority |
|---|---|---|
| FR-14 | The system SHALL retrieve candidates by ANN similarity filtered by radius (default 5 km, user-adjustable ≤ 50 km) and time window (default 3 days, ≤ 30 days). | Must |
| FR-15 | Candidates SHALL be re-ranked by a fusion score: visual similarity, attribute compatibility, spatial proximity and temporal plausibility. | Must |
| FR-16 | Temporal plausibility SHALL account for direction of time (a sighting before the loss time is implausible unless it is a re-loss). | Should |
| FR-17 | Matching SHALL run automatically on every new report and re-run on a schedule for active reports. | Must |
| FR-18 | Each candidate SHALL display the score, the matched photos side by side, distance and elapsed time. | Must |
| FR-19 | Users SHALL confirm or reject candidates; both outcomes SHALL be stored as training signal. | Must |
| FR-20 | A confirmed reunion SHALL close the report and record a reunion event. | Must |
| FR-21 | Free-text/semantic search ("brown short-haired medium dog with white chest, near X") SHALL be supported over attributes + text embeddings. | Should |

### 3.4 Notification & map
| ID | Requirement | Priority |
|---|---|---|
| FR-22 | Owners SHALL receive push/email when a candidate exceeds the notify threshold. | Must |
| FR-23 | Users SHALL be able to subscribe to an area and receive new-report alerts within it. | Should |
| FR-24 | A public map SHALL show reports as fuzzed markers/heat cells with filters by species attributes and time. | Must |
| FR-25 | Notifications SHALL be rate-limited and digestible (max N per day per user). | Must |

### 3.5 Moderation & trust
| ID | Requirement | Priority |
|---|---|---|
| FR-26 | Uploaded images SHALL pass automated NSFW/abuse screening before public display. | Must |
| FR-27 | Users SHALL be able to report abusive or fake posts; moderators SHALL be able to hide/remove. | Must |
| FR-28 | Anonymous posting SHALL be rate-limited by IP/device with CAPTCHA on abuse signals. | Must |
| FR-29 | Duplicate reports of the same dog SHALL be detectable and mergeable. | Should |

---

## 4. External Interfaces

### 4.1 API
| Method | Path | Purpose |
|---|---|---|
| POST | `/api/v1/reports` | create LOST/FOUND report |
| POST | `/api/v1/reports/{id}/photos` | add photo (triggers pipeline) |
| GET | `/api/v1/reports/{id}/matches` | ranked candidates |
| POST | `/api/v1/matches/{id}/decision` | confirm / reject |
| GET | `/api/v1/search?lat=&lng=&radius=&days=&q=` | browse/search |
| POST | `/api/v1/search/by-photo` | photo-first search |
| GET | `/api/v1/map/cells?bbox=&days=` | fuzzed map data |
| POST | `/api/v1/subscriptions` | area subscription |

### 4.2 Third-party
Map tiles (OSM/MapLibre), push (Web Push / FCM), email relay, optional SMS. All optional at deploy time.

---

## 5. Data Requirements

```sql
report(id, kind, status, title, description, lost_at, created_at,
       location geography(Point,4326), radius_hint_m, contact_channel_id, user_id NULL)
photo(id, report_id, uri, sha256, width, height, exif_stripped, moderation_status)
dog_instance(id, photo_id, bbox_json, crop_uri, quality_score)
embedding(instance_id, model_version, vec vector(768))
attributes(instance_id, size_class, color_primary, color_secondary, coat_len,
           breed_group, has_markings, confidence_json)
match(id, lost_report_id, found_report_id, score, components_json, status,
      created_at, decided_at, decided_by)
reunion(id, lost_report_id, found_report_id, confirmed_at, story)
subscription(id, user_id, area geography(Polygon,4326), filters_json)
moderation_event(id, entity, entity_id, action, moderator_id, ts, reason)
```

Indexes: HNSW on `embedding.vec`; GIST on `report.location`; BRIN on time columns.

---

## 6. AI/ML Requirements

| ID | Requirement |
|---|---|
| AI-01 | Detection: a general detector (YOLO/DETR) restricted to the dog class, with a minimum crop size of 128 px on the short edge. |
| AI-02 | Identity embedding: a re-identification model (metric learning, ArcFace/triplet) fine-tuned on dog re-ID data; output L2-normalised. |
| AI-03 | Retrieval target on a held-out re-ID benchmark: **Recall@10 ≥ 0.80**, Recall@1 ≥ 0.45 under the geo/time filter conditions. |
| AI-04 | Score calibration: the displayed similarity SHALL map to an empirical precision curve, not a raw cosine value. |
| AI-05 | The notify threshold SHALL be tuned for **high recall** (missing a match is worse than an extra candidate for the owner), with a cap on notifications (FR-25). |
| AI-06 | Embeddings SHALL carry a model version; upgrading a model SHALL trigger a background re-embed and keep search consistent during migration. |
| AI-07 | Human confirm/reject decisions SHALL be collected as a training set with explicit consent terms. |
| AI-08 | Bias check: retrieval quality SHALL be reported per coat colour and size class; a >15 % gap triggers dataset rebalancing. |
| AI-09 | Text/semantic search SHALL use a multilingual text embedding (Thai/English) over attributes + description. |

---

## 7. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | Photo upload → candidates shown ≤ 15 s p95. |
| NFR-02 | ANN search over 1 M embeddings ≤ 300 ms p95. |
| NFR-03 | The system SHALL support ≥ 100 k active reports and ≥ 1 M photos. |
| NFR-04 | Mobile web: first contentful paint ≤ 2 s on 4G; the reporting flow works on a low-end Android device. |
| NFR-05 | Privacy: exact coordinates visible only to the reporter and matched counterpart after mutual consent. |
| NFR-06 | GDPR/PDPA-style rights: export and delete my data, including derived embeddings. |
| NFR-07 | All images stored with private ACL and served via signed, expiring URLs. |
| NFR-08 | Availability ≥ 99.5 %; the reporting path degrades gracefully if the GPU worker is down (queue and process later). |
| NFR-09 | Localisation: Thai and English at launch. |

---

## 8. Acceptance Criteria

| ID | Test |
|---|---|
| AC-01 | Benchmark retrieval meets AI-03 on the held-out set. |
| AC-02 | Seeded scenario: 20 lost/found pairs planted among 10 k distractors — ≥ 16 pairs surfaced in the top 10. |
| AC-03 | A sighting posted anonymously in under 60 s on a phone (usability timing test). |
| AC-04 | Public map never exposes coordinates finer than the configured fuzz radius (verified via API responses). |
| AC-05 | EXIF stripped from every stored/served image (automated check). |
| AC-06 | Data deletion request removes report, photos, crops and embeddings within the SLA. |
| AC-07 | GPU worker stopped: reports still accepted, processed after restart, no loss. |
| AC-08 | Model upgrade re-embeds the corpus without downtime and without mixing vector spaces in one query. |

---

## 9. Delivery Plan

| Phase | Weeks | Deliverable |
|---|---|---|
| P1 | 1–2 | schema (pgvector + PostGIS), report CRUD, image pipeline skeleton |
| P2 | 3–4 | detection + crop + quality gate + attribute model |
| P3 | 5–6 | embedding model fine-tune + benchmark |
| P4 | 7–8 | candidate search, fusion re-ranking, calibration |
| P5 | 9–10 | PWA UI, map, notifications, review flow |
| P6 | 11–12 | moderation, privacy features, load test, launch |

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Cold start — too few reports to match | seed with shelter partners; a single region launch |
| Similar-looking dogs cause false hope | show score + side-by-side, always human-confirmed, careful copy |
| Pet theft via public location data | location fuzzing, no exact coordinates publicly (C-01) |
| Abuse / spam posts | rate limits, CAPTCHA, moderation queue, reporting |
| Re-ID model underperforms on mixed breeds | metric learning on in-domain data, attribute fallback, bias audit AI-08 |
| Cost of storage/GPU as volume grows | image compression, thumbnail tiers, batch embedding, retention policy for closed reports |

---

## Appendix A — Fusion score sketch

```
score = w1 · sim_visual            (calibrated cosine, 0–1)
      + w2 · attr_compat           (colour/size/coat agreement, 0–1)
      + w3 · spatial(d)            (exp(-d / 3 km))
      + w4 · temporal(Δt, order)   (plausibility of Δt and event ordering)
      - penalty(quality)           (low crop quality reduces confidence)

defaults: w1 0.55, w2 0.15, w3 0.20, w4 0.10
notify if calibrated_precision(score) ≥ 0.25 AND rank ≤ 5
```
