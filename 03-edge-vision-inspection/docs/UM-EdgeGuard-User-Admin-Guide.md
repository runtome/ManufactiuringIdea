# User Manual & Administrator Guide — EdgeGuard Edge Vision Node

| Field | Value |
|---|---|
| Document ID | UM-03-EdgeGuard |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Applies to | EdgeGuard node software 1.4.x; HMI in Thai (default), Japanese, English |
| Companion | [UM-01](../../01-factory-inspector-agent/docs/UM-VisionOps-User-Admin-Guide.md) covers the central web app (review queue, recipes, models, fleet view). This guide covers **what happens at the node** |

---

## Contents

**Part A — At the station**
- A1 The screen at a glance
- A2 Line operator
- A3 Line inspector / supervisor (PIN)
- A4 Maintenance technician
- A5 FAQ

**Part B — Fleet administrator**
- B1 Provisioning a node
- B2 `node.yaml` and certificates
- B3 Config and model updates
- B4 Rollback
- B5 The fleet view and alerts
- B6 Replacing and retiring a node
- B7 Escalation

Glossary (TH / JA / EN) · Quick reference card

---

# Part A — At the station

## A1 The screen at a glance

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  ● L2-ST3   MOLD-A12  lot L2-260910-07                     14:32  TH JA EN   │
├──────────────────────────────┬───────────────────────────────────────────────┤
│                              │   PASS  1,940     FAIL  40    REVIEW  12      │
│      [ last image with       │   NO_READ  8      (with overrides: REVIEW 9)  │
│        coloured boxes ]      │                                               │
│                              │   Top defects this shift                      │
│                              │   ■■■■■■■■ flash        18                    │
│    ┌──────────────────┐      │   ■■■■■ short shot      11                    │
│    │      PASS        │      │   ■■■ silver streak      6                    │
│    │   74 ms · 14:32  │      │                                               │
│    └──────────────────┘      │                                               │
├──────────────────────────────┴───────────────────────────────────────────────┤
│  ● Server: buffering 150 (since 21:25)   model 1.0.0   calib OK   61 °C      │
└──────────────────────────────────────────────────────────────────────────────┘
```

| Element | Meaning |
|---|---|
| **Big result box** | The last verdict: 🟢 **PASS** · 🔴 **FAIL** · 🟠 **REVIEW** (a person must look) · ⚪ **NO_READ** (could not see the part — not judged) |
| Image | The last part with boxes around what the model found |
| Counters | This shift; "with overrides" shows the effect of supervisor corrections |
| Top defects | Which defects, how many, this shift |
| Status strip | ● green = talking to the server · ● amber "buffering N" = server unreachable, the node is **still inspecting** and keeps every result · model version · calibration · temperature |
| **Full red screen "FAULT"** | The node cannot judge. The PLC is holding parts. See A2 |

The screen is read-only except two PIN-protected actions (A3). Touch targets are large enough for gloves; it is designed to be read from 1 m.

## A2 Line operator

**Your job at this screen:** know the four results, know what FAULT means, scan the label when the lot changes.

### The four results
| You see | It means | You do |
|---|---|---|
| 🟢 PASS | The node saw the part and found nothing | Nothing |
| 🔴 FAIL | Found a defect (named on screen) | The line already rejected it; nothing at the screen |
| 🟠 REVIEW | Not sure, or something unusual | The part goes to the review bin; a QC inspector decides (on the central, or here with a PIN) |
| ⚪ NO_READ | Could not see the part (blurred, too dark, empty) | The line treats it like REVIEW (or FAIL — set per station). If NO_READ repeats, the light or camera needs attention → tell maintenance |

**A missing result is never a PASS.** If the node is slow or silent, the PLC holds the part.

### FAULT (full red screen)
The node has stopped judging on purpose — camera unplugged, model not ready, disk error, or too hot. The reason is written on the screen. **The line is holding parts; this is correct.** Call maintenance (A4). Do not power-cycle the node unless maintenance asks — it will not help, and a fault that needs acknowledgement (e.g. "camera frozen") comes back until the cause is fixed.

### Amber banners (not FAULT)
"Server unreachable — buffering 150": the node keeps inspecting and keeps every result; they upload later. "Disk reserve — PASS images paused": still inspecting. "Warm": still inspecting. None of these need you to do anything.

### Scanning the label
When the lot or product changes, scan the label — the screen shows the new SKU and lot. If it shows "Unknown product", the station is either holding parts (FAULT: config) or running the last recipe with a warning — tell the supervisor either way.

## A3 Line inspector / supervisor (PIN)

Two actions need your 6-digit PIN. Every PIN entry is logged with your badge id.

### Override a verdict
Tap the result in **History**, tap **Override**, enter your PIN, choose the new verdict and a reason (confirmed defect · false alarm · acceptable mark · escape found · wrong class · other), and — for FAIL — the defect class you saw. Confirm.

- The part has already moved; the override **corrects the record** and teaches the model. It does not re-signal the PLC.
- The counters' "with overrides" line updates immediately; the override uploads to the central with your id.
- The model's own verdict is never erased — both are kept.
- Five wrong PINs → 15-minute lockout, shown on screen. The lockout never affects inspection.

**When to override here vs on the central:** here when you are at the line and know the part; on the central (UM-01 A3) when reviewing the queue with the evidence images side by side. Both are the same record.

### Acknowledge a latched fault
Some faults stay after the cause is fixed because someone must confirm the fix: **camera frozen**, **store recovered**, **tamper**. Tap **Clear fault**, PIN, confirm. If the cause is still there the fault returns immediately — that is the node telling you it is not fixed.

### Select the product manually
When the scanner is broken: **Product**, PIN, choose from the list. Records are marked "manual" and an alarm shows after an hour — get the scanner fixed.

## A4 Maintenance technician

You have a **technician token** (issued per visit by the fleet admin) and reach the node's local API through `edgectl` on your laptop over an SSH tunnel — the node has no network port of its own.

### First look
`edgectl status` = the HMI status strip in full: READY/FAULT with reasons, camera, models, calibration, buffer, disk, thermal, sync, last verdict. The reason on a FAULT tells you which runbook: [OPS-03 §9](OPS-EdgeGuard-Deployment-Operations.md#9-runbooks).

### Self-test
`edgectl selftest` captures one frame, runs the model and the recipe, and prints per-stage latency (capture / gate / inference / rules / store). The slow stage is the problem. Does not signal the PLC.

### Camera and light
Live view on the HMI (technician mode) · `edgectl camera list` · NO_READ reasons in `edgectl counters`. If you move the camera, lens, light or mount, the node will report **calibration stale** on its own — that is not a bug; **recalibrate** (on the central, UM-01 B3) and confirm with `edgectl calibration check --gauge 25.00`.

### Sync
`edgectl sync status` shows why records are not leaving (TLS, network, credentials, or the central rejecting a record because of missing master data — "stuck"). After fixing the cause: `edgectl sync flush`.

### Models and config
`edgectl models` shows active / previous / shadow and engine state. You may **roll back** (`edgectl model rollback defect-yolo11s`) with no server — tell the fleet admin, because the central will re-promote on the next pull unless they roll back there too. You may **activate** a model only after the central decided it (the command executes, it does not decide).

### Diagnostics for support
`edgectl diag build && edgectl diag pull ./` produces a redacted archive (no keys, no PINs, no PASS images, lot numbers truncated). Attach it to the ticket.

### Things you must not do
- Edit files under `/var/lib/edgeguard` by hand — the store is single-writer; the node will detect and fault on tampering.
- Delete images or database files to free space — unsynced data is the only precious thing on the node; use RB-08.
- Enable `lab.software_trigger` on a production node.
- Leave SSH enabled after the visit (`edgectl ssh off`).

## A5 FAQ

**The screen says "buffering 3,200". Are results lost?** No. They are on the node's disk and upload when the server is back. Up to three days of results fit.

**The node rebooted after a power cut and came back by itself. Is that normal?** Yes — it should be inspecting again within 90 s with no one touching it. If it shows FAULT "store recovered", a technician must acknowledge it (a file was set aside for inspection).

**Why is NO_READ not PASS?** Because nothing was judged. A dirty lens would otherwise pass every part.

**Can I see yesterday's parts on the node?** The last 50 are on the HMI; older records are on the central (UM-01). Synced records are eventually removed from the node.

**The node is warm to the touch.** Normal up to the "warm" banner. If it says FAULT thermal, the cabinet cooling needs attention (RB-04).

---

# Part B — Fleet administrator

## B1 Provisioning a node
Follow [OPS-03 §4](OPS-EdgeGuard-Deployment-Operations.md#4-provisioning--30-min-no-developer--nfr-09): image → `node.yaml` → certificates and hashes → `.env` → start → bundle → `edgectl provision finish` → commissioning checklist with the controls engineer. Thirty minutes; no developer. Keep the signed commissioning checklist with the node's record on the central.

## B2 `node.yaml` and certificates
- `node.yaml` is the device's identity and wiring. It contains **no secrets** and its hash is checked at every boot; edit it only through a controlled change (re-run `edgectl provision finish`).
- Certificates: one per node, CN = `node_code`, one year. Issue with `edgectl ca issue`; renew through the bundle 30 days before expiry (the fleet dashboard lists expiries). Revoke on the central when a node is retired or stolen.
- PIN and technician token hashes: generate with `edgectl secret pin` / `edgectl token issue`; distribute PINs to named supervisors; rotate tokens per visit.

## B3 Config and model updates
You decide on the **central** (VisionOps: recipes, thresholds, model promotion — UM-01 B4/B5). Nodes pull within 5 minutes and validate before applying. Watch for `config:INVALID` events — usually a recipe naming a class the node's active model does not have; promote the model first.

Model roll-out: canary station → one shift → line → plant. Shadow disagreement is reported in the heartbeat; promote only when it is within the threshold (AI-04). Engine builds take minutes on Jetson; schedule between shifts or accept a short FAULT on the canary.

Air-gapped plants: build a signed USB bundle (`edgectl bundle build`), have the technician apply it; the node does the same checks it would online.

## B4 Rollback
- **Config**: re-publish the previous version on the central; nodes pull it.
- **Model**: demote on the central (nodes activate `previous` on the next pull) or, urgently, on the node offline (`edgectl model rollback`) — then also on the central, or it re-promotes.
- **App**: the bundle carries the previous digests; `edgectl app update` rolls services one at a time and rolls back on failed health by itself.

## B5 The fleet view and alerts
The central's fleet page (UM-01 B7) shows every node's heartbeat: READY/FAULT, buffer depth, versions, calibration, temperature, disk. Alert rules and severities are in [OPS-03 §6.2](OPS-EdgeGuard-Deployment-Operations.md#62-alert-rules-fleet). The two that matter most: **node FAULT during a shift** and **heartbeat missing ×3**. "Backlog rising" during a network outage is expected; "stuck records" means master data on the central is missing (unknown SKU) — fix it there and the backlog drains.

## B6 Replacing and retiring a node
Replacement with unsynced data: [RB-14](OPS-EdgeGuard-Deployment-Operations.md#9-runbooks) — restore the store file before first start; the central deduplicates. Retiring: backup → revoke → mark retired → crypto-erase → remove.

## B7 Escalation
| Situation | First | Then |
|---|---|---|
| Node FAULT during production | Line supervisor + maintenance technician (runbook by reason) | Fleet admin if re-provisioning is needed |
| Heartbeat missing ×3 | Technician checks power/network on site | Fleet admin |
| Config/model rejected fleet-wide | Fleet admin (central) | ML owner (class map) |
| Security event (tamper, PIN lockout storm, auth failure) | Fleet admin + plant security | SEC-03 §7 |
| Records rejected as unknown SKU | Master-data owner on the central | — |

---

## Glossary (TH / JA / EN)

| EN | TH | JA | Meaning |
|---|---|---|---|
| Node | โหนด | ノード | The inspection box at the station |
| READY | พร้อม | 準備完了 | The node can judge; the PLC may send parts |
| FAULT | ขัดข้อง | 異常 | The node cannot judge; the PLC holds parts |
| Verdict | ผลตัดสิน | 判定 | PASS / FAIL / REVIEW / NO_READ |
| NO_READ | อ่านไม่ได้ | 読取不可 | Could not see the part; not judged; never PASS |
| Override | แก้ผลตัดสิน | 判定上書き | A person's correction of the record (PIN) |
| Buffer / backlog | ข้อมูลรอส่ง | 未送信データ | Results waiting to upload; nothing is lost |
| Sync | ซิงค์ | 同期 | Uploading results and pulling config from the central |
| Heartbeat | สัญญาณสถานะ | ハートビート | The node's health report every minute |
| Watchdog | วอทช์ด็อก | ウォッチドッグ | Restarts a hung part of the node within 30 s |
| Throttle | ลดความเร็ว (ร้อน) | サーマルスロットリング | Slowed because too hot |
| Engine | เอนจิน (โมเดลที่คอมไพล์แล้ว) | エンジン | The model compiled for this device |
| Shadow model | โมเดลเงา | シャドウモデル | A new model running alongside, not judging |
| Rollback | ย้อนกลับเวอร์ชัน | ロールバック | Return to the previous model/config/app |
| Calibration | สอบเทียบ | キャリブレーション | Pixels → millimetres; redo when optics change |
| Bundle | ชุดตั้งค่า | バンドル | Signed package of config, models, app digests |
| Latched fault | ขัดข้องค้าง | ラッチ異常 | A fault that stays until a person confirms the fix |
| Fingerprint | ลายนิ้วมือฮาร์ดแวร์ | ハードウェア指紋 | Camera + lens + mount identity tied to a calibration |

## Appendix — Quick reference card (print, laminate, mount by the screen)

```
 EdgeGuard station card — L_-ST_                         emergency: maintenance ext. ____
 ─────────────────────────────────────────────────────────────────────────────
  🟢 PASS        nothing to do
  🔴 FAIL        line rejected it; defect named on screen
  🟠 REVIEW      review bin; QC decides
  ⚪ NO_READ     could not see the part; repeats → call maintenance
  🔴 FAULT (full screen)   node stopped judging ON PURPOSE; PLC holds parts; CALL MAINTENANCE
     • camera / model / calibration / disk / thermal / store — reason is on screen
     • do NOT power-cycle unless asked
  amber "buffering N"      server down; still inspecting; nothing lost
  amber "PASS images paused" / "warm"   still inspecting; no action
 ─────────────────────────────────────────────────────────────────────────────
  Lot change → scan the label.   "Unknown product" → tell the supervisor.
  Override / clear fault = supervisor PIN (logged).  A missing result is NEVER a PASS.
```
