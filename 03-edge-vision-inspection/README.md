# EdgeGuard — Edge Vision Inspection Node — Documentation Set

The box beside the line: capture → infer → judge → signal the PLC → persist → sync. Runs with **zero network for ≥ 72 hours**, recovers from a power cut by itself, and signals FAULT — never PASS — when it cannot judge. Where [VisionOps (01)](../01-factory-inspector-agent/) defines the *intelligence* (recipes, models, review, retraining), EdgeGuard defines the **runtime**: the device, the camera driver, the model runtime, the buffer, the sync protocol, the HMI and fleet management.

**Standalone** means *a node with no server at all* — it inspects, drives the PLC and serves its operator from local caches. Its central is VisionOps (01) or FactoryBrain (00); the node cannot tell which (identical IF-01).

**Status:** v1.0 drafts. Specifications and machine-readable artifacts; no implementation yet. **First set in this repository whose database artifacts were verified by execution.**

---

## Documents

| ID | Document | Answers | Audience |
|---|---|---|---|
| SRS-03 | [Software Requirements Specification](SRS-EdgeGuard-Edge-Vision-Inspection.md) | *What must it do?* | Everyone — start here |
| SAD-03 | [Software Architecture Document](docs/SAD-EdgeGuard-Software-Architecture.md) | *How is a device built so it never lies to the PLC?* | Implementer, architect |
| DDS-03 | [Local Store Design Specification](docs/DDS-EdgeGuard-Local-Store-Design.md) | *What does the node keep, and how does it survive a power cut?* (SQLite) | Implementer |
| API-03 | [API Specification](api/API-Specification.md) + [`openapi.yaml`](api/openapi.yaml) | *What does the node expose on itself, and what does it consume from the central?* | HMI/CLI developer, integrator |
| ICD-03 | [Interface Control Document](docs/ICD-EdgeGuard-Interface-Control.md) | *Wiring, timing, camera features, sync client, provisioning, HMI, host* | Controls engineer, integrator |
| SEC-03 | [Security Requirements Specification](docs/SEC-EdgeGuard-Security-Requirements.md) | *What can someone with panel access do — and what can they not?* | Security reviewer, plant security |
| TEST-03 | [Test Plan and Test Cases](docs/TEST-EdgeGuard-Test-Plan.md) | *How do we know it is fail-safe?* | QA, implementer |
| OPS-03 | [Deployment and Operations Guide](docs/OPS-EdgeGuard-Deployment-Operations.md) | *Provision in 30 min, commission, update, fix* | Fleet admin, technician |
| UM-03 | [User Manual and Administrator Guide](docs/UM-EdgeGuard-User-Admin-Guide.md) | *What does the screen mean; what does a PIN let me do?* | Operators, inspectors, technicians, fleet admins |

### Machine-readable artifacts

| File | What it is | Verified |
|---|---|---|
| [`api/openapi.yaml`](api/openapi.yaml) | OpenAPI 3.1 — node-local API, **19 paths / 19 operations / 18 schemas**, plus `x-client-contracts` | ✅ validator pass; 70 `$ref`s resolve; **11 schemas byte-identical to API-01** (`InspectionCreate`, `BatchResult`, `NodeHealth`, `ModelManifest`, `EdgeConfig`, …) |
| [`db/schema.sql`](db/schema.sql) | **SQLite** local store — 17 tables, 5 views, 14 indexes, 3 triggers, WAL | ✅ **Executed** (Python `sqlite3` 3.50.4): `integrity_check` ok, `foreign_key_check` clean; every constraint probed |
| [`db/seed_demo.sql`](db/seed_demo.sql) | One node at end of shift with a 150-record sync backlog (2,000 inspections) | ✅ **Executed**; all 20 expected values read back and match |
| [`db/payload_mapping.json`](db/payload_mapping.json) | Local column → IF-01 `InspectionCreate` field → platform column | ✅ Checked against `01/api/openapi.yaml`: 0 unmapped, 0 unknown, 0 dangling |
| [`deploy/docker-compose.yml`](deploy/docker-compose.yml) | The node: 9 services, no published ports, devices only where stated | ✅ YAML + anchor/conflict checks; 0 `ports`, 0 `privileged`; store rw only by `store`; ⚠️ `docker compose config` not run (Docker unavailable) |
| [`deploy/lab-compose.override.yml`](deploy/lab-compose.override.yml) | Edge-lab: camera replay, PLC simulator, power relay | ✅ YAML; 3 services |
| [`deploy/node.yaml.example`](deploy/node.yaml.example) · [`deploy/.env.example`](deploy/.env.example) | Device identity/wiring (no secrets) · runtime knobs | ✅ parse; 44/44 compose variables covered both ways; secret scan clean |

---

## Reading paths

**Wiring a station** (controls engineer) → ICD-03 IF-03 (pin table, timing, **fault truth table**) → OPS-03 §5 commissioning → TEST-03 TS-2.

**Implementing the node** → SRS-03 → SAD-03 §4.2–4.4 (process model, frame pipeline, store-and-forward, fault manager, the 200 ms budget) → DDS-03 → `db/schema.sql` (run it) → API-03 → ICD-03 IF-01 client → TEST-03.

**Reviewing fail-safety** → SAD-03 ADR-E03/E04/E05 → ICD-03 IF-03 truth table → SEC-03 §4.2 (the "make it pass everything" walk-through) → TEST-03 TC-025, TC-031…037 → OPS-03 §5.

**Provisioning and running a fleet** → OPS-03 §4 → `node.yaml.example` → OPS-03 §7 (OTA) and §9 (runbooks) → UM-03 Part B.

**Standing at the station** → UM-03 A1–A3 and the quick-reference card.

---

## What makes this design what it is

The four platform principles ([00 README](../00-factorybrain-platform/README.md)) land on a device like this:

| Principle | On the node |
|---|---|
| **The LLM never computes numbers** | There is **no LLM on the node**. Numbers come from a deterministic rules engine over model outputs; narratives are the central's job. |
| **Offline-first** | The *primary* driver. Boot needs no network; config, models and calibration come from local caches; the store buffers ≥ 72 h; the PLC signal never depends on the server. |
| **Human-in-the-loop** | Overrides at the HMI are PIN-gated, attributed and synced; model promotion is **never** decided on the node — it executes what the central decided. |
| **The database is the source of truth** | The local store is authoritative **until sync** — a verdict is pulsed only after its row is committed (ADR-E03); after the central acknowledges, the local row is disposable. `synced_at` is set only by the writer on `accepted`/`duplicate`; the purge view cannot return an unsynced row. |

Plus one the server documents do not have — **fail-safe integrity**: the fault manager is one component with one truth table (ADR-E05); a frozen frame is a fault (ADR-E04); a powered-off node reads FAULT at the PLC (NC relay); a missing verdict is never PASS; no API call can raise READY.

---

## Relationship to the platform and siblings

| | Relationship |
|---|---|
| [01 VisionOps](../01-factory-inspector-agent/) | **The central this node is designed against.** IF-01 client of `/edge/*`; the five contract schemas are copied from API-01 and diffed; the edge-lab uses the 01 stack as its central; commissioning checklist shared (OPS-01 §3.6). |
| [00 FactoryBrain](../00-factorybrain-platform/) | Alternative central — identical IF-01 (SAD-03 §6). Superset config from 01 is tolerated; base config from 00 is enough (falls back to `node.yaml` for stations/calibration). |
| Other siblings | None directly. A node talks to its camera, its PLC, its light, its operator and its central. |

---

## Identifier conventions

Shared with the set: `FR-`/`NFR-`/`AI-`/`AC-`/`C-` (SRS-03) · `P-1…P-4` · **`ADR-E01…E10`** · `QAS-01…12` · **`DD-E01…E05`** · `IF-xx` shared numbering (**IF-22 provisioning/OTA, IF-23 local HMI, IF-24 host** new) · **`THR-E`/`SEC-E`** · `TS-`/`TC-` · `RB-01…14`.

```
SRS-03 FR-11 / AC-03  "persist before ack; power cut ×10, nothing lost, DB intact"
  └─ SAD-03 ADR-E01 SQLite WAL · ADR-E03 pulse after commit · §4.4.5 power loss
      └─ DDS-03 DD-E01/E02 · synchronous=NORMAL trade-off · v_purge_candidates
          └─ ICD-03 IF-03 truth table · IF-24 watchdog
              └─ SEC-03 O-1 · SEC-E42/E43
                  └─ TEST-03 TC-025 (pulse never precedes record) · TC-044 (power cut ×10) · TC-005 (seed, executed)
                      └─ OPS-03 RB-11 · UM-03 A2 "FAULT is correct"
```

---

## Verification

| Check | Result |
|---|---|
| **`db/schema.sql` executed** (SQLite in-memory) | ✅ **Pass** — 17 tables, 5 views, 14 explicit indexes, 3 triggers; `integrity_check` ok; `foreign_key_check` empty |
| **Constraint probes** (TC-003) | ✅ **Pass** — second `node_info` row, same-verdict override, fifth verdict, delete-with-override, unverified `active`/`shadow` (INSERT **and** UPDATE), second `active`/`previous`/`shadow` per name: all rejected; unverified `downloaded` allowed |
| **`db/seed_demo.sql` executed** (TC-005) | ✅ **Pass** — 2,000 inspections (1,944/44/12/8); unsynced 150 = FAIL 5 / REVIEW 2 / NO_READ 2 / PASS 141; `sync_queue` 151 (8 at priority 1); `image_queue` 16; 76 images; 60 purge candidates, **0 unsynced, 0 queued**; 3 overrides; effective REVIEW 9; `v_ready` = 1 with alarm `config:SYNC_TARGET_UNREACHABLE`; stages 2/1/1; detections 52; measurements 50; anomaly 200; re-seed refused |
| Payload mapping vs API-01 `InspectionCreate` (TC-006) | ✅ **Pass** — 4 required + 16 properties; 0 unmapped; 0 unknown; 0 dangling column references |
| `openapi.yaml` vs OpenAPI 3.1 schema (TC-009) | ✅ **Pass** — 19 paths / 19 operations; unique operationIds; all ops have 2xx; no null-valued keys |
| Client-contract identity vs API-01 (TC-008) | ✅ **Pass** — 11/11 schemas structurally identical |
| Compose, lab override, `node.yaml.example` (TC-001, TC-004) | ✅ **Pass** — parse; anchors resolve; no `network_mode`+`networks` conflict; 0 ports; 0 privileged; devices on `capture`/`supervisor`/`inference` only; store rw only by `store`; 44/44 env variables both ways; ⚠️ `docker compose config` itself not run |
| Secret scan of examples and seeds (TC-007) | ✅ **Pass** — 0 hits |
| SRS-03 coverage, cited objects/endpoints, links | ✅ see sweep note below |

**Defects found by executing** (all fixed, listed in TEST-03 §4): an invalid `RAISE()` outside a trigger in the seed; wrong expected values in the seed header (3/1/1/145 → 5/2/2/141; 40 → 16 images); an unquoted comma in a flow mapping in **01's** `openapi.yaml` that parsed as a bogus key (fixed there — 01 still validates); the same class of defect in this set's spec; an override enum drift; and **a missing INSERT-side guard** on `model_cache` — the verified-before-active trigger only covered `UPDATE` until the TC-003 probe inserted an unverified active row.

To reproduce the execution:
```bash
cd 03-edge-vision-inspection
python -c "import sqlite3;c=sqlite3.connect(':memory:');c.executescript(open('db/schema.sql',encoding='utf-8').read());c.executescript(open('db/seed_demo.sql',encoding='utf-8').read());print(c.execute('PRAGMA integrity_check').fetchone(),c.execute('SELECT count(*),sum(synced_at IS NULL) FROM inspection').fetchone())"
```

---

## Known gaps and open decisions

| Gap | Where |
|---|---|
| **Override sync has no edge contract.** API-01's `PATCH /inspections/{id}/verdict` is an inspector-JWT endpoint, not part of `/edge/*`; node overrides need either a node service credential scoped to its own records or a `POST /edge/overrides:batch` in IF-01 v1.1. Until then overrides accumulate locally and are visible on the HMI | ICD-03 IF-01, SEC-03 §8 |
| `no_read_reason` and `camera_id` are not in the IF-01 v1 payload; carried via heartbeat counters / resolved by the central | DDS-03 §6 |
| Jetson carriers without a hardware keystore leave the dm-crypt key on the device | SEC-03 §8, OPS-03 §2.4 |
| Physical access (jumpered outputs, swapped camera) is detected, not prevented | SEC-03 §8 |
| `docker compose config` not run (Docker daemon unavailable); YAML validated with PyYAML plus structural checks | Above |
| Everything from TS-1 onward requires the edge-lab or hardware; ~100 TCs specified, not run | TEST-03 |
| FR-26 (central alerts on 3 missed heartbeats) is a central-side requirement; verified in TEST-01, referenced here | TEST-03 §3 |
| `edgectl` CLI referenced throughout is specified by its commands only; no separate CLI spec yet | OPS-03, UM-03 |
