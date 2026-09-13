# PocketQC — Release checklist

Used by OPS-05 §3 for every store/MDM release. Every line has an owner and a TC.

## Build
- [ ] `flutter build apk --release --split-per-abi` (arm64-v8a primary); versionCode bumped; changelog written
- [ ] APK ≤ 200 MB per ABI **including** the bundled self-test sample set (C-02) — TC-009
- [ ] `AndroidManifest`: `allowBackup=false`, `usesCleartextTraffic=false`, `debuggable=false`; `FLAG_SECURE` on inspection screens — TC-100, TC-101, TC-094
- [ ] Dependency review: no SDK with network access besides the HTTP client; ML Kit **bundled** barcode variant — TC-099 (SEC-M53)
- [ ] Signing with the release key from the HSM/keystore; `apksigner verify` output attached

## Data and contracts
- [ ] `db/schema.sql` executes and the 11 constraint probes fail as intended — TC-002, TC-003
- [ ] Drift migration from the previous schema version tested on a seeded device (no data loss) — TC-045 path
- [ ] `api/openapi.yaml` shared parts still identical to API-00 — TC-008
- [ ] Payload mapping complete — TC-006

## Managed configuration and platform
- [ ] `managed-config.example.json` validates; the MDM template matches its keys — TC-004, TC-070
- [ ] Certificate pins in the MDM template match the platform's current **and backup** certificates — TC-098
- [ ] Platform serves IF-11 v1.1 endpoints (or the release notes state which features are inactive until it does)
- [ ] Model manifests published with `samples_url` and `expected_metrics` meeting AI-02 — schema validated

## Device verification (reference device, release build)
- [ ] TC-050 / TC-051: 50 airplane-mode sessions → sync with 0 duplicates, 0 missing images
- [ ] TC-041: force-kill resume at the same step
- [ ] TC-022 / TC-023: latency p95 ≤ 500 ms; model gates
- [ ] TC-027: 20/20 barcode labels; TC-026 OCR ≥ 95 %; TC-028 gauge ±0.5 mm
- [ ] TC-091 storage forensics; TC-093 lost-device drill; TC-099 egress capture
- [ ] TC-080 / TC-112: Thai and Japanese on every screen and in the PDF
- [ ] TC-121 battery ≥ 6 h

## Rollout
- [ ] Pilot: 2 devices, 1 week (TC-130); crash-free ≥ 99.5 % (TC-123)
- [ ] Rollback plan: previous APK retained in the MDM; DB migration is forward-only — a downgrade needs a wipe (state it in the notes)
- [ ] Support bundle procedure tested on the release build (TC-102)
