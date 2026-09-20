# Test Plan and Test Cases — GAPFarm AI (AI Farmer Agent)

| Field | Value |
|---|---|
| Document ID | TEST-12-GAPFarm |
| Version | 1.0 (Draft) |
| Date | 2026-09-20 |
| Author | Suphot N. |
| Status | Draft for review |
| Source | [SRS-12](../SRS-GAPFarm-AI-Farmer-Agent.md) §3, §6, §7, §8 |
| Related | [SAD-12](SAD-GAPFarm-Software-Architecture.md) §8 · [DDS-12](DDS-GAPFarm-Database-Design.md) §7, §9 · [API-12](../api/API-Specification.md) · [ICD-12](ICD-GAPFarm-Interface-Control.md) · [SEC-12](SEC-GAPFarm-Security-Requirements.md) §5 · [OPS-12](OPS-GAPFarm-Deployment-Operations.md) §12 |

---

## 1. Strategy
Ten suites. **TS-0 is static** and was executed on the authoring machine (Python, no PostgreSQL) — its results are in §7. TS-1…TS-9 need the running system, real phone photos, sensors and providers; they are specified with pass criteria and the seed data they rely on. The seed (`db/seed_demo.sql`) is the fixture for most integration cases: its expected values were re-derived in Python (TC-005), so a case that reads a seeded value has a known answer before the database exists.

Levels: unit (functions, twins), integration (API + database + workers), system (phone + sensors + providers), acceptance (AC-01…AC-09), security (TS-9).

## 2. Entry and exit
Entry: TS-0 green; a PostgreSQL 16 + PostGIS + pgvector instance with `schema.sql` and `seed_demo.sql` applied (TC-009); the field test set available for TS-1 (AI-03). Exit: every Must-priority FR covered by a passing case; AC-01…AC-09 passed; zero open defects in TS-2 (records/PHI) and TS-9; ≤ 3 minor elsewhere.

## 3. Traceability (SRS → suite)
| SRS | Cases |
|---|---|
| FR-01…08 | TC-010…TC-018 |
| FR-09…15 | TC-020…TC-030 |
| FR-16…20 | TC-031…TC-036 |
| FR-21…26 | TC-040…TC-047 |
| FR-27…32 | TC-050…TC-055 |
| AI-01…09 | TC-011, 013, 014, 017, 018, 052, 092 |
| NFR-01…09 | TC-060…TC-064, TC-070…TC-074, TC-080…TC-083 |
| C-01…05 | TC-060, TC-021, TC-026, TC-011, TC-073 |
| AC-01…09 | TC-018, 012, 020, 024, 030, 026, 060, 092, 053 |

---

## 4. Test cases

### TS-0 — Static verification (executed; §7)
| ID | Case | Pass criterion |
|---|---|---|
| TC-001 | `api/openapi.yaml` validates (OpenAPI 3.1); no null keys; no undefined or orphan components; every operation has a 2xx; SRS §4.1's nine paths present | validator pass; 9/9 |
| TC-002 | Platform pattern identity: helpers byte-identical; audit tables identical modulo `core.app_user → farm.app_user` | both true |
| TC-003 | Static DDL: parentheses/`$$` balance; FK targets defined and ordered; every table has a PK; 25 guard bindings present; trigger functions defined before binding; role grants (`ingest_rw` INSERT telemetry only; `agent_ro` no `location`/`gps`/`reporter_id`; `auditor_ro` no writes); `setting` CHECKs pin AI-02/AI-04/FR-22 minima | all true |
| TC-004 | Compose/env: parses; profiles gpu/cpu/mqtt/dev; hardening on app services; ports on `BIND_ADDR`; `sensors` network only broker/ingest/sim; egress only api/scheduler; internal-only for db/redis/minio/ollama/workers; `${VAR}` both ways; secrets referenced = defined; buckets private; no secret values in the repo | all true |
| TC-005 | Seed re-derivation (Python): record numbering; hash chain per zone (A 17 / B 10 / C 1) and heads; v1/v2 hashes of SC-2026-0412; traceability counts; export manifest hash; PHI dates; GDD/stage (zone B flowering on 09-09); prediction intervals; risk rule firing; spray conflict; moisture slope; stuck/offline; quiet-hours shift; compliance gaps; 15 probes each targeted at one guard | values in `\echo` block equal |
| TC-006 | Contracts: product list schema + 14 negatives + loader rule L-1; diagnosis result schema (Appendix A valid, OOD valid, gate-fail valid) + 13 negatives; model manifests + 11 negatives; export manifest (example valid, hash recomputed) + 8 negatives; scheme + 7 negatives; config example + schema negatives | all valid / all rejected |
| TC-007 | Secret scan over every file | none |
| TC-008 | API identity: `Problem`, `Cursor`, `Limit`, `IdempotencyKey`, `Unauthorized`, `Forbidden`, `NotFound`, `ValidationFailed`, `TooManyRequests` byte-identical to API-00 | 9/9 |
| TC-009 | Apply `schema.sql` then `seed_demo.sql` on PostgreSQL 16 + PostGIS + pgvector; compare the `\echo` block; every probe fails inside its savepoint | ⚠️ not executable on the authoring machine |

### TS-1 — Diagnosis (FR-01…08, AI-01…06)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-010 | Quality gate | upload a blurred, a dark and a far photo; then 3 good ones | `422 PHOTO_QUALITY` with specific `guidance_th` each; good set returns candidates |
| TC-011 | Diagnosis shape and calibration (C-04, FR-03, AI-05) | Appendix A photos | ≤ 3 candidates ordered, Σ ≤ 1, features + how-to-confirm; `calibration_version` set; database refuses 4 candidates / Σ > 1 / uncalibrated (P-08) |
| TC-012 | OOD refusal (AI-06, AC-02) | a hand, the sky, a car | `status: refused`, `candidates: []`, guidance; no observation record, no task, no review row |
| TC-013 | Correction → training data (FR-07, AI-09) | agronomist corrects seed diagnosis 0903 | `label_example` with photo ids, original candidates, model version, reviewer pseudonym; diagnosis `corrected`; queue resolved |
| TC-014 | Release gate (AI-02, AI-03, AI-04) | try to release chili-v4 (lab pass, field 0.78) and chili-v4-lite (27.3 MB) | `RELEASE_GATE_FAILED`; `CALIBRATION_REQUIRED` then `DEVICE_MODEL_TOO_LARGE`; chili-v3 releases |
| TC-015 | Consult flag (FR-29) | seed diagnosis 0902 (anthracnose, severe) | `consult_agronomist: true`; review queue `severe`; the agronomist line on the card |
| TC-016 | Record-only mode (FR-08) | stop `worker-vision` and the device model; upload | `202 DiagnosisQueued`; observation and photos stored; diagnosis runs when the worker returns; scouting can still be recorded via `/records/scouting` |
| TC-017 | Device vs server (ADR-G02) | device diagnoses offline (`computed_on: device`), server re-scores differently on sync | device diagnosis `superseded`, farmer notified; a confirmed device diagnosis keeps its record |
| TC-018 | Field benchmark (AC-01) | run the field set through the released model | top-1 ≥ 0.80, top-3 ≥ 0.93; ECE ≤ 0.05; reliability diagram attached; OOD AUROC ≥ 0.90 |

### TS-2 — Records and compliance (FR-09…15, C-03, NFR-04)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-020 | Confirmation generates everything (AC-03) | confirm seed diagnosis 0901 | one transaction: `SC-2026-0412`, 3 tasks (today / tomorrow / +7 d, 17:00 local), 3 reminders, recommendation with `spray_conflict: true`; `v_diagnosis_outcome` tasks 3 reminders 3; no typing beyond the tap |
| TC-021 | Approved list only (C-02) | input usage / recommendation with P-PARAQ | `409 UNAPPROVED_PRODUCT` (P-04, P-05); the product picker never lists it |
| TC-022 | Input usage completeness (FR-10) | omit PPE; omit weather; product approved after `ts` | `PPE_REQUIRED`, `WEATHER_REQUIRED`, `UNAPPROVED_PRODUCT`; a complete row snapshots PHI 7 / REI 24 and `phi_clear_at = ts + 7 d` |
| TC-023 | PHI status (FR-11) | zone A at 09-14 and 09-18 | `clear: false, clear_at 2026-09-17 08:00, days_remaining 3.00` at 09-14 08:00; then `clear: true` |
| TC-024 | Harvest refused / allowed (AC-04) | harvest zone A 09-14; then 09-18; complete the harvest task at 09-14 | `409 PHI_NOT_ELAPSED` (P-03); accepted with traceability; task completion refused too |
| TC-025 | Traceability (FR-12) | `GET /records/harvest/LOT-A-20260918/traceability` | 1 input (IU-2026-0031 with hash), 15 scouting events, `phi_clear_at` |
| TC-026 | Versions (AC-06) | correct SC-2026-0412 plants 6 → 8; try UPDATE/DELETE | version 2 with reason; `GET /records/SC-2026-0412` returns both; v1 unchanged; `RECORD_IMMUTABLE` (P-01, P-02); v2 without reason → `VERSION_NEEDS_SUPERSEDES` (P-15) |
| TC-027 | Chain integrity (NFR-04) | `verify_chain` per zone; then modify one payload as superuser and re-verify | all ok; after tampering every later row fails; heads equal the seed's |
| TC-028 | Export package (FR-13) | 3-month export, whole farm | PDF with gaps first and scheme template order; XLSX with every version; manifest 27 records, gap 1, chain heads, `verify_hash` |
| TC-029 | Export verification (AC-05) | `/verify`; then offline script on the XLSX chain sheet | `manifest_ok`, `records_ok = 27`, `chains_ok`; offline recomputation equal |
| TC-030 | Mock audit checklist (AC-05, FR-15) | ThaiGAP mock audit over the package | every mandatory record present for zones A and B; zone C gap (26 d) listed, not hidden; input usage complete; every lot traceable |

### TS-3 — Tasks and reminders (FR-16…20)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-031 | Templates by kind and severity | confirm disease/severe, disease/low, deficiency/low, pest/moderate | 4 / 2 / 2 / 3 tasks respectively with the seeded texts and offsets |
| TC-032 | Completion evidence (FR-17) | complete with photo, without completer | evidence stored; `COMPLETER_REQUIRED` |
| TC-033 | Quiet hours and channel content (FR-18) | reminder requested at 21:30; inspect LINE/Discord/push payloads | scheduled 06:00 next day (seed reminder 1411); payloads carry task text, zone code, due — no photo, GPS or name |
| TC-034 | LINE postback obeys PHI | press "done" on the harvest task inside PHI | refused with the Thai PHI message; nothing changes |
| TC-035 | Escalation (FR-20) | critical task overdue > 24 h | escalation to the farm manager (seed: 1 at 09-10 09:00); acknowledged flag |
| TC-036 | Follow-up comparison (FR-19) | follow-up observation 0706 | `followup_delta_pct = −7.00`; card shows 10 % → 3 % |

### TS-4 — IoT and environment (FR-21…26, NFR-07)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-040 | Unit validation (FR-21) | publish `unit: "C"` from a soil-moisture device; register a sensor with the wrong unit | dropped and counted; `UNIT_MISMATCH` (P-10) |
| TC-041 | Faults → tasks (FR-22) | seed telemetry; `detect_sensor_faults` | 3 faults (EC-B1 offline → critical task, SM-B1 stuck, T-A1 out of range); `v_sensor_health` |
| TC-042 | 24 h buffer (NFR-07) | stop the database 2 h while devices publish | no reading lost after restart; ordering by `ts`; duplicates ignored |
| TC-043 | Weather cache and GDD (FR-23, FR-30) | provider mocked; daily rows | one call/farm/hour; GDD to 09-20: A 1987.00, B 1118.50, C 567.00; stages maturity / fruit_set / vegetative |
| TC-044 | Spray conflict (FR-25) | zone B, P-MANCO, planned 09-10 09:00 | `conflict: true`, rain 09-10 06:00, 6 h window; with a product without rainfast → `false` with reason |
| TC-045 | Provider down (IF-12) | block egress to the provider | `available: false`; spray check `conflict: null, reason forecast unavailable`; risk advisory "ไม่มีข้อมูลอากาศ"; nothing computed on stale data |
| TC-046 | Irrigation advisory (FR-26) | seed SM-A1 series | slope −0.5 %/h, latest 26 %, rain 2 mm → one `irrigation` advisory with factors |
| TC-047 | Risk rule (FR-24) | evaluate 2026-09-19 | cercospora rule fires for 3 zones with source in factors; anthracnose does not |

### TS-5 — Agent and prediction (FR-27…32, AI-07, AI-08)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-050 | Ask with approved products; fallback (FR-27, FR-28, FR-08) | seed questions e11/e12 with the model; then with Ollama stopped | e21 names no product and sets consult; e22 lists P-MANCO/P-COPPER with PHI; fallback answers are complete (`fallback: true`) |
| TC-051 | Citations | e22 | citations to chunks d01, d03 and record SC-2026-0412; each resolvable |
| TC-052 | Prediction interval and factors (FR-30, FR-31) | zone A, zone B | A yield 1450.0 [1102.2, 1797.8] with t 4.303 / sd 70; B harvest date 2026-10-06 [10-06, 10-07] with GDD factors |
| TC-053 | Insufficient data (AC-09) | zone C; zone B yield | `insufficient_data` with reason; no numbers; a forecast row with `ok` and no interval is refused (P-13) |
| TC-054 | Weekly summary (FR-32) | week of 09-14 | issues, treatments with PHI clear, harvest, open tasks 10, gap C 26 d, faults 3 |
| TC-055 | Agronomist line (FR-29) | ask about a fast-spreading condition | `consult_agronomist: true` in the answer |

### TS-6 — Offline and mobile (C-01, NFR-02, NFR-03)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-060 | Airplane mode (AC-07) | 20 observations offline; reconnect | one batch, 20 applied, synced within 5 min; ids unchanged |
| TC-061 | Replay | resend the batch; re-insert the batch row | `replayed: true` with the stored result; `SYNC_REPLAY` (P-14) |
| TC-062 | Resumed photo | kill the connection mid-upload | `308` with range; completes; sha256 matches |
| TC-063 | Large batch | 500 items | applied < 5 s; per-item statuses |
| TC-064 | Install and memory (NFR-03) | 3 GB Android | install ≤ 150 MB with one model; no OOM during diagnosis |

### TS-7 — i18n and PDPA (C-05, NFR-05, NFR-08)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-070 | Photos (NFR-06) | inspect stored object; fetch URL after 16 min | EXIF-free; ≤ 1 MB; URL expired; non-member `403` |
| TC-071 | Consent and export | first login; export request | consent version/time stored; package contains records, photos, requests, channels of the person |
| TC-072 | Erasure | complete seed request 0f12 | user pseudonymised, channels/tokens gone, GPS nulled; observation 0704 kept with `reporter_ref`; audit `pdpa.erasure`; chain unchanged |
| TC-073 | Thai completeness (NFR-08) | walk every screen, error and notification | no untranslated string; Appendix A card renders exactly |
| TC-074 | English secondary | `Accept-Language: en` | English strings; Thai fallback where a term has none |

### TS-8 — Performance and cost (NFR-01, NFR-09)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-080 | Server latency | 3 photos on throttled 4G (2 Mbps up) | result ≤ 8 s p95 |
| TC-081 | Device latency | chili-v3-lite on a 3 GB phone | ≤ 2 s p95; ≤ 25 MB |
| TC-082 | VPS sizing | 20 farms × 10 diagnoses/day, 100 sensors | 4 vCPU / 8 GB with CPU profile: p95 within NFR-01; database < 20 GB/year |
| TC-083 | Availability | 30-day pilot | ≥ 99 %; sensor buffer covered every outage |

### TS-9 — Security (SEC-12)
| ID | Case | Steps | Pass criterion |
|---|---|---|---|
| TC-090 | Auth and scoping | expired token; other farm's zone; auditor writes | 401; 403 (query predicate, not filtering); 403 |
| TC-091 | Device credentials and LINE signature | publish to another device's topic; unsigned webhook | refused by ACL; 401 |
| TC-092 | Adversarial prompts (AC-08) | ≥ 50 prompts (Thai/English, role-play, "school project", pasted label text naming banned products) | zero unapproved product names in any answer; refused rows counted; P-06/P-07 |
| TC-093 | Two-person approval | self-approve; approve without label; withdraw without reason | `APPROVAL_SELF`, `LABEL_REQUIRED`, `REASON_REQUIRED`; audit rows |
| TC-094 | Log scrubbing | grep logs after a full flow | no names, phones, LINE ids, GPS, tokens, question texts |
| TC-095 | Rate limits | exceed each limit | 429 with `Retry-After` |

---

## 5. Defects found while authoring (all fixed)
| # | Defect | Fix |
|---|---|---|
| D1 | `at` used as a view column alias (`v_record_current`), a keyword in `AT TIME ZONE` contexts | renamed `record_at` |
| D2 | Chain payload included `id` and `supersedes` (random UUIDs from trigger-generated rows) — hashes would differ between environments, making the `\echo` expectations unverifiable | payload excludes surrogate ids and server timestamps; `record_chain.record_id` keeps the link |
| D3 | RH-A1 telemetry series ended exactly 60 min before "now" — on the offline boundary | series extended to 09:00 |
| D4 | Zone A routine scouting had a 9-day gap (08-24 → 09-02) that would have failed the AC-05 mock audit | 08-31 and 09-05 records added; counter preset recomputed (390) so Appendix A stays SC-2026-0412 |
| D5 | Diagnosis-result schema required ≥ 1 candidate whenever `ood = false`, which rejected a legitimate gate failure (no candidates, guidance) | branch conditioned on `gate.pass` |
| D6 | Product schema's third `allOf` clause rejected every approved product (tried to express "author ≠ approver" in JSON Schema) | removed; loader rule L-1 documented and checked in Python |
| D7 | OpenAPI: unquoted `available: false` in a summary and a comma inside a flow-style description broke parsing | quoted |
| D8 | Bash heredocs on the authoring machine collapse `\\` to `\` (a JSON-Schema `pattern` lost its escape) | files written through the editor tool; schema repaired |

## 6. Environments
| Level | Environment |
|---|---|
| Static | Python 3.14 (pyyaml, jsonschema, openapi-spec-validator) |
| Integration | `deploy/docker-compose.yml --profile cpu --profile dev` (sensor-sim, mailpit, mocked weather/LINE) |
| System | pilot VPS, 2 Android phones (one 3 GB), 5 sensors, LINE OA sandbox |
| Field set | ≥ 640 real phone photos of chili (mixed lighting, backgrounds), labelled by two agronomists, versioned in `models` bucket (AI-03) |

## 7. Execution record (TS-0, 2026-09-20, authoring machine)
| Case | Result |
|---|---|
| TC-001 | ✅ valid; 56 paths / 62 operations / 78 schemas; 0 undefined, 0 orphans, 0 null keys; 9/9 SRS paths |
| TC-002 | ✅ helpers byte-identical; audit identical modulo FK |
| TC-003 | ✅ 52 tables / 14 views / 35 trigger bindings / 54 functions / 46 indexes / 25 enums; 25/25 guards; grants as specified |
| TC-004 | ✅ see OPS-12 §12 (compose checks) |
| TC-005 | ✅ chain A 17 / B 10 / C 1; heads `05ff22f2ff8d` / `eed384754914` / `d1b32c897c84`; v1 `b1c0a31d5026`, v2 `eed384754914`; export 27 records, gap 1, `727922173316…`; PHI 09-17 08:00; GDD 1987.00 / 1118.50 / 567.00; B on 09-09 922.50 = flowering; yield A [1102.2, 1797.8]; B date 10-06 [10-06, 10-07]; risk 3; spray conflict true; slope −0.5000; gaps C only |
| TC-006 | ✅ product 14/14 + L-1; diagnosis 13/13; manifests 11/11; export 8/8; scheme 7/7; config — see OPS-12 §12 |
| TC-007 | ✅ none |
| TC-008 | ✅ 9/9 |
| TC-009 | ⚠️ not executed — no Docker daemon; commands in OPS-12 §12 |
