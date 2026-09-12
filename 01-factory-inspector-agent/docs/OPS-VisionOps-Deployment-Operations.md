# Deployment and Operations Guide — VisionOps (AI Factory Inspector Agent)

| Field | Value |
|---|---|
| Document ID | OPS-01-VisionOps |
| Version | 1.0 (Draft) |
| Date | 2026-09-11 |
| Author | Suphot N. |
| Status | Draft for review |
| Artifacts | [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) · [`deploy/.env.example`](../deploy/.env.example) |
| Inherits | [OPS-00](../../00-factorybrain-platform/docs/OPS-FactoryBrain-Deployment-Operations.md) for TLS/CA, JWT keys, backup/restore mechanics, DB operations — linked, not restated |
| Audience | Administrator, on-call, commissioning engineer |

---

## 1. How to use this document

| Situation | Section |
|---|---|
| First install (demo or production) | §3 |
| Commissioning a station on a real line | §3.6 — **do not enable the reject signal before this is signed** |
| Something is wrong now | §8 runbooks |
| Camera, lens or lighting changed | RB-06 (recalibrate + revalidate) |
| Deploying a new model | §5 |
| Configuration | §4 |
| Platform mode | §2.3 |

**On-call summary:**

1. **Offline is not down.** Edge nodes inspect without the server. `Offline — buffering` on the HMI means keep running and fix the server calmly (RB-08).
2. **`FAULT` on the HMI is the only stop signal.** It means the station cannot judge — camera, model, calibration or local disk. Never bypass it by forcing a PASS.
3. **A NO_READ spike is a lighting/camera problem, not a quality problem** (RB-03). Fix the optics; do not touch the recipe.
4. **Never disable** `GROUNDING_CHECK_ENABLED`, `MODEL_VERIFY_SHA256` or `FROZEN_FRAME_DETECT`. Each one prevents a specific way the system could lie.

---

## 2. Deployment shapes

### 2.1 All-in-one — demo, development, single-line pilot
Everything from `docker-compose.yml` plus the `allinone` profile on one machine. Camera by USB/GigE, or **folder replay** (`CAPTURE_SOURCE=folder`) with no hardware at all — this is how the portfolio demo runs.

```bash
docker compose --profile allinone up -d
open http://localhost:8080          # station HMI
open https://visionops.local        # dashboard
```

The edge containers are the **same images** shipped to Jetson nodes (ADR-V01); the demo behaves like production, minus the physical I/O.

### 2.2 Server + edge nodes — production
Server stack without the `allinone` profile; one edge node per station (Jetson Orin Nano or x86 mini-PC) provisioned per §3.5. Edge GPU does inference; server GPU does the LLM.

### 2.3 Platform mode
**Do not use `docker-compose.yml`.** Deploy only edge nodes (§3.5) pointed at the FactoryBrain sync URL, apply migration `visionops_0001` to the platform database, and register the VisionOps web module. The API, DB, object store, LLM and auth are the platform's ([SAD-01 §9](SAD-VisionOps-Software-Architecture.md)). Edge nodes need only a URL change to move between modes.

---

## 3. Installation

### 3.1 Server prerequisites
As OPS-00 §3.1: Ubuntu 22.04, Docker 24+, NVIDIA driver 535+ and Container Toolkit, NTP enabled. VisionOps minimum: 8 cores, 16 GB RAM (32 GB with `allinone`), 1 TB SSD + separate evidence volume, one 8 GB GPU.

```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi   # must list the GPU
timedatectl status                                                         # NTP: yes
```

### 3.2 TLS, edge mTLS and JWT keys
Follow OPS-00 §3.2–3.3 for the internal CA, server certificate and JWT keys. VisionOps additionally issues **one client certificate per edge node**:

```bash
cd deploy/certs
openssl genrsa -out node-L2-ST3.key 2048
openssl req -new -key node-L2-ST3.key -out node-L2-ST3.csr -subj "/CN=L2-ST3/O=VisionOps-Edge"
openssl x509 -req -in node-L2-ST3.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out node-L2-ST3.crt -days 825 -sha256
```
The CN must equal `ops.edge_node.node_code`. The `8443` listener in Caddy requires a client cert signed by `ca.crt`.

### 3.3 Configure and start
```bash
cd deploy && cp .env.example .env && chmod 600 .env
${EDITOR:-nano} .env            # fill every [REQUIRED]; work the pre-flight list
docker compose up -d            # or: --profile allinone
docker compose ps
curl -k https://visionops.local/api/v1/readyz
```
`schema.sql` and `seed_demo.sql` apply on **first start only** (empty data directory). **Remove `seed_demo.sql` from the `../db` mount for a production database** — the seed refuses a non-empty database, but there is no reason to have it present.

### 3.4 First login
Sign in as `BOOTSTRAP_ADMIN_USERNAME`, enrol MFA, create a **second** admin, remove `BOOTSTRAP_ADMIN_PASSWORD` from `.env`, restart `api`.

### 3.5 Edge node provisioning (≤ 30 min, no developer)

1. Flash JetPack 6 (or Ubuntu 22.04 + NVIDIA toolkit on x86). Install Docker.
2. Copy `ca.crt`, the node certificate and key to `/etc/visionops/`.
3. Write `/etc/visionops/node.yaml`:

```yaml
node_code: L2-ST3
sync_url: https://visionops.local:8443      # platform mode: the FactoryBrain URL
auth: { mode: mtls, cert: /etc/visionops/node-L2-ST3.crt, key: /etc/visionops/node-L2-ST3.key }
station: ST3
cameras:
  - id: cam0
    driver: genicam            # genicam | usb | csi
    serial: "40123403"
    trigger: hardware
    exposure_us: 800           # fixed — never auto
    gain_db: 0
    pixel_format: Mono8
    roi: [0, 0, 2448, 2048]
plc_io:
  driver: gpio
  ready: 17  pass: 27  fail: 22  review: 23  fault: 24  trigger: 4
  pulse_ms: 200
inference:
  runtime: tensorrt
  precision: fp16
storage:
  min_free_pct: 15
  pass_image_sample_rate: 0.02
```

4. `docker compose -f edge-compose.yml up -d` on the node (the edge image bundle).
5. Verify: node appears in `GET /edge/nodes` as `online`; `camera_state: ok`; a software-trigger test frame returns a verdict on the HMI.
6. **Do not connect the reject output yet.** Proceed to §3.6.

### 3.6 Commissioning checklist — required before the reject signal is live

| # | Check | Evidence |
|---|---|---|
| 1 | Camera mounted, focused, exposure **fixed**, strobe synced | Exposure histogram in range; no auto features enabled |
| 2 | **Calibration** performed and **gauge-verified** (§3.7) | `v_current_calibration` shows the camera; max error ≤ 0.2 mm |
| 3 | Recipe assigned to every SKU that will run | `GET /recipes` complete; unknown SKU → FAULT confirmed |
| 4 | **PLC fail-safe verified**: suppress one verdict → line holds (TC-023); assert FAULT → line holds (TC-022) | Signed by the controls engineer |
| 5 | Trigger count = frame count over 100 parts | Data-quality events: none |
| 6 | **Frozen-frame detection** proven: cover lens → FAULT within 2 frames | TC-013 |
| 7 | 30-minute network disconnection: zero loss, PLC unaffected | TC-061 short form |
| 8 | **Shadow mode** on real product ≥ 200 parts; disagreement report reviewed with the quality engineer | Report attached |
| 9 | Hold-out metrics for the active model meet AI-02 | TC-058a |
| 10 | Review lane/bin physically exists for REVIEW parts | Photo |
| 11 | `station.plc_io_json` matches the panel drawing | Drawing revision recorded |
| 12 | HMI readable at 1 m with gloves; Thai default | Walkthrough |

Only after all twelve: connect the reject output and set `recommission_required = false` on the station.

### 3.7 Calibration procedure

1. Mount the calibration target (checkerboard 9×6, 10 mm) at the **part plane**, not the conveyor surface.
2. Capture ≥ 15 frames at varied positions; `POST /cameras/{id}/calibrations` with method `intrinsics_scale` and the hardware fingerprint (camera serial | lens id | mount id).
3. Place the certified gauge (25.000 mm block) at the part plane. Measure **30 times**, moving it slightly between repeats.
4. `POST …/verify` with the 30 values. Read the response: `valid = true` requires max error ≤ 0.2 mm.
5. If `valid = false`: **do not re-run until it passes.** Check focus, target flatness, working distance; then repeat from step 2.
6. Record the calibration id on the station commissioning sheet.

**Redo calibration whenever** the camera, lens, mount, working distance or lighting setpoint changes (RB-06). The hardware fingerprint catches component swaps; it does not catch a bumped mount — that shows up in drift and the next gauge check.

---

## 4. Configuration reference

Full list: [`.env.example`](../deploy/.env.example). Settings that matter most:

### 4.1 Never weaken

| Variable | Value | Why |
|---|---|---|
| `GROUNDING_CHECK_ENABLED` | `true` | Removing it removes the no-invented-numbers guarantee (ADR-013) |
| `MODEL_VERIFY_SHA256` | `true` | An unverified model artefact is an integrity risk (SEC-V31) |
| `FROZEN_FRAME_DETECT` | `true` | A frozen camera emits PASS forever (SEC-V40) |
| `PLC_FAULT_ON_INVALID_CALIBRATION` | `true` | Measurement rules must not run on a stale calibration (SEC-V22) |
| `CAPTURE_EXPOSURE_US` | fixed | Auto-exposure hides the drift the monitor exists to catch |
| `RETENTION_PROTECT_SNAPSHOTS` | `true` | Training evidence must survive retention (SEC-V63) |
| `ENABLE_EXTERNAL_LLM` | `false` | `true` sends factory data off-LAN (SEC-241) |

### 4.2 Frequently tuned

| Variable | Default | Guidance |
|---|---|---|
| `PASS_IMAGE_SAMPLE_RATE` | `0.02` | **Main storage lever.** Raise temporarily during model validation, then lower |
| `review_threshold` (per recipe) | `0.55` | Lower → more REVIEW, safer, more inspector load. Tune per SKU **with the dry-run**, one SKU at a time |
| `ALERT_NO_READ_PCT` | `2.0` | Above this, lighting or camera is degrading |
| `ALERT_OVERRIDE_BURST_COUNT/MINUTES` | `30 / 10` | Set from real inspector throughput; too low = noise |
| `EDGE_IMAGE_WINDOW` | empty | Set an off-shift window on constrained networks; records still sync immediately |
| `AGENT_MAX_TOOL_CALLS` | `5` | Raising increases narrative latency and GPU contention |
| `LOCAL_STORE_MIN_FREE_PCT` | `15` | Below this, PASS images stop; inspection continues |

Runtime-tunable thresholds also live in `ops.config` (admin UI, no restart). Secrets never do.

---

## 5. Model management

### 5.1 LLM (narrative only)
As OPS-00 §5.1: pre-pull into the `ollama_models` volume — the `backend` network has no internet route by design.

### 5.2 Vision model lifecycle

```
train (outside VisionOps, from a FROZEN snapshot)
   → ONNX + manifest {name, version, sha256, class_map, metrics, trained_from}
   → mc cp artefact vo/models/            → POST /models  (candidate; sha256 verified)
   → POST /models/{id}/shadow             → ≥200 live frames, no verdict effect
   → GET /models/{id}  (shadow_report, promotion_gate.reasons)
   → POST /models/{id}/promote  (admin)   → refused if critical recall < 0.98
   → edge nodes pull manifest via config ETag → build TensorRT engine on device
   → POST /models/{id}/rollback if needed
```

**Promotion is refused automatically below the critical-recall gate. There is no bypass.** A model that misses more critical defects is a worse model for this line regardless of headline mAP.

**TensorRT engine build** happens on each node at first load (1–5 min on Jetson). The HMI shows "Building model…" and `READY` stays low; this is expected, not a hang. Engines are cached per (device, model version, driver); a driver upgrade rebuilds them.

### 5.3 Retraining hand-off
1. `POST /datasets` selecting overrides, confirmed reviews and sampled PASS for the period.
2. Curate in the UI (remove mislabels); `POST /datasets/{id}/freeze` with `format: yolo`.
3. Hand the signed export URL and SHA-256 to training. **The snapshot name goes into the new model's `trained_from`** — a model without it cannot be promoted.

### 5.4 Air-gapped bundle
As OPS-00 §5.4, plus the edge image and model artefacts. Record digests in the release notes.

---

## 6. Database, evidence, backup

Mechanics (migrations, `pg_dump` + WAL, PITR, restore drill) are OPS-00 §6 and apply unchanged. VisionOps specifics:

| Item | Position |
|---|---|
| Evidence volume | The capacity driver: ~1.6 TB/year/station at 2 % PASS sampling. Size it separately; alert at 70 % |
| Object versioning on `evidence` | **Enabled** (SEC-V62); the sweep is the only deleter |
| Snapshot protection | Sweep skips objects referenced by frozen `dataset_item` rows (SEC-V63) |
| Partition maintenance | Monthly; `vision.inspection_default` must be empty (RB-13) |
| Restore drill | Quarterly, **database + evidence bucket together** — a restored DB without images is half a system |
| RPO / RTO | ≤ 24 h / ≤ 4 h |

---

## 7. Observability

### 7.1 Metrics that page someone

| Metric | Condition | Runbook |
|---|---|---|
| `visionops_camera_state{state="frozen"}` = 1 | any | **RB-02** |
| `visionops_camera_state{state="disconnected"}` = 1 | > 10 s | RB-01 |
| `visionops_no_read_ratio` | > 2 % over 15 min | RB-03 |
| `visionops_inspection_latency_ms` p95 | > 150 ms for 5 min | RB-04 |
| PLC verdict timeouts (from node) | any during production | RB-05 |
| `visionops_calibration_valid{camera}` = 0 | with measurement rule active | RB-06 |
| `visionops_review_queue_depth` | > 200 | RB-07 |
| `visionops_edge_buffer_depth` | rising 15 min | RB-08 |
| Disk free (evidence volume) | < 15 % | RB-09 |
| Model load failure (node event) | any | RB-10 |
| Critical recall delta after promotion | < 0 on agreement stats | RB-11 |
| `visionops_narrative_total{outcome="withheld"}` rate | > 1 % / day | **RB-12** |
| `visionops_edge_heartbeat_age_seconds` | > 180 | RB-08 |
| Recipe `config_etag` mismatch across fleet | > 5 min | RB-13 |

### 7.2 SLOs

| SLO | Target |
|---|---|
| Station inspecting (not FAULT) during shifts | 99.5 % |
| Trigger → verdict p95 | ≤ 200 ms |
| API availability | 99.0 % |
| Narrative delivered by 22:15 | 99 % of days |
| Review queue cleared within a shift | 95 % of shifts |

### 7.3 Dashboards
Fleet (node state, buffer, camera, calibration validity) · Line (verdict stream, defect rate, NO_READ ratio, review depth) · Model (agreement, drift, shadow reports) · Narrative health (withheld rate, significant days).

---

## 8. Runbooks

### RB-01 — Camera disconnected
1. HMI shows `FAULT`; `camera_state: disconnected`. Line is holding — correct behaviour.
2. Check cable, power, PoE budget (GigE), USB3 port. Swap cable first; it is the usual cause.
3. `docker compose logs capture` on the node for the driver error.
4. If the camera is replaced: **it is a hardware change** → RB-06 before resuming measurement rules.
5. Confirm `READY` returns and a test frame judges.

### RB-02 — Frozen or replayed feed (**integrity**)
1. Node asserted `FAULT` on identical consecutive frames or a frame-id reset. **Do not clear it remotely.**
2. Physically inspect the camera link. A frozen feed is usually a driver hang or a stuck sensor; a frame-id reset with the camera physically fine is a security event (SEC-V41).
3. Power-cycle the camera; verify live frames (frame-id increasing, content varying).
4. Record the event; if unexplained, treat per SEC-00 §7.3 incident response.

### RB-03 — NO_READ spike
1. This is optics, not quality. **Do not edit the recipe.**
2. Check `quality_gate.reason` distribution: `BLUR` → focus/vibration/dirty lens; `EXPOSURE` → strobe fault, ambient change, failed LED.
3. Clean lens; verify strobe fires (`ExposureActive` line); check exposure histogram against the commissioning value.
4. If the lighting setpoint was changed: it invalidates drift baselines — re-baseline after fixing.
5. NO_READ parts were **not inspected**; route them for manual check per work instruction.

### RB-04 — Verdict latency over budget
1. `visionops_inspection_latency_ms` by stage: grab / infer / rules / store.
2. Infer high → thermal throttling (`nvidia-smi` / `tegrastats`), or engine running FP32 (check `VISION_PRECISION`).
3. Store high → local disk (RB-09 on the node).
4. Grab high → bandwidth (GigE at full frame); apply ROI.
5. All-in-one: a narrative may be holding the GPU — confirm `GPU_INFERENCE_PRIORITY=true`.

### RB-05 — PLC not receiving verdicts
1. Node shows verdicts on the HMI but PLC times out → wiring or I/O map.
2. Compare `station.plc_io_json` with the panel drawing; check `recommission_required`.
3. Measure the output with a meter during a test trigger (pulse `pulse_ms`).
4. Verify PLC timeout > `PLC_VERDICT_TIMEOUT_MS`; verify PLC treats timeout as hold (TC-023).
5. Any I/O map change → controlled change + re-run commissioning check 4.

### RB-06 — Camera, lens, mount or lighting changed → recalibrate
1. Hardware fingerprint mismatch invalidates the calibration automatically; with a measurement rule active the node shows `FAULT` (`CALIBRATION_STALE`). Correct.
2. Perform §3.7 in full, including the 30-repeat gauge verification.
3. **Re-validate the model** on the hold-out (TC-058a) — a lens or lighting change can shift detection performance even when the scale is right.
4. Re-baseline drift metrics.
5. Update the commissioning sheet.

### RB-07 — Review queue backlog
1. `GET /stats/agreement` — is the model over-flagging one class or SKU?
2. Short term: add inspector capacity; the queue is oldest-first with claim locks.
3. Medium term: tune that SKU's `review_threshold` **with the dry-run** (§4.2), one SKU at a time, observe a shift.
4. If a REVIEW spike coincides with a NO_READ spike → RB-03 first.
5. Never bulk-clear a queue: there is no bulk override endpoint, by design (SEC-V53).

### RB-08 — Edge offline / buffer rising
1. Confirm the node is still **inspecting** (HMI `Offline — buffering`, verdicts flowing). If so, the line is fine.
2. Server side: `docker compose ps`, `/readyz`, disk, `api` logs for `/edge/records:batch` errors.
3. Repeated `rejected` outcomes → master data (unknown SKU/line code); fix and the node retries.
4. Certificate: `401 EDGE_KEY_INVALID` or TLS handshake failure → re-issue the node cert (§3.2).
5. On reconnect, watch `buffer_depth` drain. Records first, images after.

### RB-09 — Disk full (server evidence volume or edge store)
1. Server: `df -h`; evidence bucket is the usual cause. Confirm `retention_sweep` ran. Lower `PASS_IMAGE_SAMPLE_RATE`. Never delete WAL or unsynced data.
2. Edge: below `LOCAL_STORE_MIN_FREE_PCT` the node stops storing PASS images and keeps inspecting. If unsynced records fill the disk, fix RB-08 — the node will not drop them.

### RB-10 — Model load failure on a node
1. Node event `model_load_failed`; previous model retained; `FAULT` only if no model at all.
2. Cause is usually checksum mismatch (corrupt download — re-pull) or TensorRT build failure (driver/JetPack mismatch — check `tegrastats`, free space in `/models`).
3. **Never disable `MODEL_VERIFY_SHA256`** to get past it. A persistent mismatch on a good download is a security event (SEC-V30).

### RB-11 — Critical-recall regression after promotion
1. Agreement stats show `model_pass_human_fail` rising for a critical class since the promotion.
2. `POST /models/{previous}/rollback` with reason. One command; nodes pick up the previous manifest.
3. Open a case with the quality engineer; the shadow report should have shown the disagreement — review why it was accepted.
4. Snapshot the escapes for the next retraining.

### RB-12 — Narrative grounding failures rising (**integrity**)
1. `SELECT * FROM vision.v_narrative_health ORDER BY day DESC LIMIT 7;` and the withheld narratives' `grounding_json`.
2. What changed: model tag, prompt version, a tool's output shape?
3. Prompt/model change → **roll back**; re-run the golden narrative set.
4. False positives on derived figures → tune `GROUNDING_NUMERIC_TOLERANCE`; **never disable the check**.
5. Withheld narratives are the safety net working; the rising rate is the incident (SEC-00 §7.3).

### RB-13 — Recipe not applied on a node
1. Fleet view: node `config_etag` ≠ current. Node polls every `EDGE_CONFIG_POLL_SECONDS`.
2. Node logs: schema validation failure means the recipe references a class not in the node's model `class_map` — the node **refuses** the recipe and keeps the previous version (correct).
3. Fix: promote a model with the class, or remove the rule.
4. Also check `vision.inspection_default` is empty (partition maintenance) — unrelated but often noticed here.

### RB-14 — Planned upgrade
As OPS-00 §9, plus: **upgrade one edge node first**, soak a full shift, then the fleet. Compare agreement stats before/after. Node app versions are visible in the fleet view; an older minor version must keep syncing.

---

## 9. Routine operations

**Daily (10 min)** — all nodes `online`, `camera_state: ok`, buffers ~0 · NO_READ ratio at baseline · review queue cleared last shift · overnight backup ok · narrative delivered with sources · no withheld narratives.

**Weekly (30 min)** — agreement stats per class (watch `model_pass_human_fail`) · drift metrics · evidence volume trend · failed jobs · data-quality events (trigger/frame mismatch, timestamp skew) · security events (override bursts, injection flags, checksum mismatches).

**Monthly (2 h)** — gauge spot-check on one camera (compare to calibration `gauge_mean_mm`) · partition maintenance ran · certificate expiry (server + node certs) · recipe version review with quality · capacity forecast.

**Quarterly (half day)** — restore drill (DB + evidence) with measured RTO · authorisation matrix (TC-091) · injection corpus (TC-095) · golden narrative set · secret rotation · **full recalibration check on every camera** · review this document.

---

## 10. Capacity

| Resource | Driver | Scale trigger |
|---|---|---|
| **Evidence storage** | ~1.6 TB/year/station at 2 % PASS sampling | > 70 % → lower sample rate or add storage |
| Edge GPU | Model size × fps | Latency p95 > 150 ms → ROI, FP16→INT8 (with recall gate), smaller backbone |
| Server GPU | Narratives + batch | Semaphore wait p95 > 20 s → schedule batch off-shift; second GPU |
| Database | ~16 GB/year/station | Partition pruning; check `EXPLAIN` on dashboard queries |
| Inspector capacity | REVIEW rate × time per item | Queue not cleared per shift → threshold tuning or staffing |

---

## 11. Decommissioning a station
Export its calibration, recipe versions and agreement history · revoke the node certificate · retire the node (`state: retired`) · wipe the edge store · remove PLC wiring per controls procedure · record disposal.

---

## 12. Traceability

| Requirement | Section |
|---|---|
| NFR-01/02 latency, throughput | §7.2, RB-04, §10 |
| NFR-03 24 h buffer | RB-08, RB-09 |
| NFR-04 availability | §7.2, RB-01, RB-08 |
| NFR-08 compose deploy | §2.1, §3.3 |
| NFR-09 metrics | §7.1 |
| AI-04 measurement | §3.7, RB-06 |
| AI-02 recall gate | §5.2, RB-11 |
| AI-07 drift | §7.1, RB-03, RB-06 |
| AI-08 reproducible retraining | §5.3 |
| AC-01…AC-07 | §3.6 commissioning checklist |
| SEC-V22 calibration fault | §4.1, RB-06 |
| SEC-V31 model verification | §4.1, RB-10 |
| SEC-V40 frozen feed | §4.1, RB-02 |
| SEC-V63 snapshot protection | §6 |
| ADR-V01 all-in-one | §2.1 |
| ADR-V06 calibration | §3.7 |
| ADR-013 grounding | §4.1, RB-12 |
| IF-03 fail-safe | §3.6 check 4, RB-05 |

---

## Appendix A — Diagnostic bundle (edge node)

```bash
#!/bin/sh
OUT=vo-edge-diag-$(hostname)-$(date +%F-%H%M); mkdir -p "$OUT"
docker compose -f edge-compose.yml ps            > "$OUT/services.txt"
docker compose -f edge-compose.yml logs --tail=500 > "$OUT/logs.txt"
cat /etc/visionops/node.yaml | sed 's/key:.*/key: REDACTED/' > "$OUT/node.yaml"
df -h                                            > "$OUT/disk.txt"
(nvidia-smi || tegrastats --interval 1000 | head -5) > "$OUT/gpu.txt" 2>&1
curl -s http://localhost:9001/healthz            > "$OUT/capture.json"
curl -s http://localhost:9002/healthz            > "$OUT/inference.json"
curl -s http://localhost:9005/status             > "$OUT/sync.json"     # buffer depth, last sync
timedatectl                                      > "$OUT/time.txt"
tar czf "$OUT.tar.gz" "$OUT" && rm -rf "$OUT" && echo "Wrote $OUT.tar.gz"
```
Review for secrets before it leaves the site.
