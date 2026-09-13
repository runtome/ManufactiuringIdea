# User Manual & Administrator Guide — OpsPilot Local AI Operations Agent

| Field | Value |
|---|---|
| Document ID | UM-04-OpsPilot |
| Version | 1.0 (Draft) |
| Date | 2026-09-12 |
| Author | Suphot N. |
| Status | Draft for review |
| Applies to | OpsPilot 1.0.x; Discord bot and web console; answers in Thai, Japanese or English |
| Related | [OPS-04](OPS-OpsPilot-Deployment-Operations.md) for installation and onboarding; [SEC-04](SEC-OpsPilot-Security-Requirements.md) for what the agent can never do |

---

## Contents

**Part A — Using OpsPilot**
- A1 What OpsPilot is (and is not)
- A2 Asking questions — viewer
- A3 Reading a diagnosis
- A4 Approving and denying — operator and admin
- A5 Runbooks, alerts, incidents
- A6 The web console
- A7 Discord command reference
- A8 FAQ

**Part B — Owner's guide**
- B1 Users, roles and Discord mapping
- B2 Policy: who may approve what, where, how often
- B3 Targets and tags
- B4 The tool registry (and why you cannot add a tool from the console)
- B5 Runbooks and alert rules
- B6 Model, prompt and registry versions
- B7 Audit and export
- B8 What the agent will never do

Glossary (TH / JA / EN)

---

# Part A — Using OpsPilot

## A1 What OpsPilot is (and is not)

OpsPilot is a colleague you can ask "why is the backend down?" at 2 a.m. It looks at the servers with a fixed set of read-only tools, tells you what it found and what it thinks the cause is, and — if there is a sensible fix among nine pre-approved actions — proposes it. **It never does the fix by itself.** A person with the right role approves, the action runs, and the agent checks the result and shows you before and after.

It is not a shell. There is no command it can run that is not on its list; there is no "just do it" mode for anything risky; and text found in logs cannot give it orders.

## A2 Asking questions — viewer

In Discord, in one of the ops channels:

```
/ask Check why the backend is down.
/ask Is disk space OK on vps-1?
/diag vps-1
```

`/ask` opens a thread and streams what it is doing: the plan, each tool it runs, the evidence, the diagnosis and — sometimes — a proposal. `/diag <target>` is the fast, fixed check-up (containers → logs → resources → dependencies → health); it works even when the AI model is offline and never proposes anything.

Tips: name the service or host if you know it; ask one thing at a time; the answer is in your language setting (TH/JA/EN) but tool names and codes stay in English.

## A3 Reading a diagnosis

```
Probable cause (confidence: high)
The deploy 12 minutes ago raised the embedding batch size; embeddings-worker now holds
~6.2 GB and the host is out of memory, so the kernel OOM-kills backend repeatedly.
Evidence: tc-01 docker_ps · tc-02 docker_logs · tc-03 host_metrics · tc-04 docker_ps · tc-05 git_log

Proposed action  [risk: medium · requires: admin]
  redeploy_last_good(target="vps-1", service="embeddings-worker")
Expected effect: worker returns to previous batch size, memory frees, backend stabilises
[Approve]  [Deny]  [Dry run]
```

| Element | What it means |
|---|---|
| **Confidence** | `high` = several independent pieces of evidence agree; `medium` = plausible, one line of evidence; `low` = a guess — read "next checks" |
| **Evidence `tc-xx`** | Every sentence in the cause is backed by a tool result you can open in the thread or the console. If a statement has no `tc-xx`, the system withholds it — you will not see unbacked claims |
| **Next checks** | When the agent is not sure it says so and lists what it would look at next (you can ask it to) |
| **Proposed action** | The exact tool and arguments — nothing hidden. Risk and the role that may approve come from the owner's policy, not from the model |
| **Expected effect** | What should be true afterwards; it is what "verified" is checked against |
| **Refused by policy** | The model asked for something not allowed (for example something destructive). Nothing happened; it is logged. This is the system working |

## A4 Approving and denying — operator and admin

Only people mapped by the owner can approve, and only up to their role: **operators approve low-risk** actions (restart, start, clear cache, rotate logs, rerun a job); **admins approve medium-risk** (stop, scale, prune images, redeploy last good). Nothing is `high` in v1, and `high` can never run automatically.

Before you click **Approve**:
1. Read the evidence, not only the cause. Open a `tc-xx` if something feels off.
2. Check the arguments on the card — target and service. They are exactly what will run.
3. Use **Dry run** if unsure: it shows what would happen and changes nothing.
4. Notice the timer. A proposal expires **10 minutes** after it is made; after that the buttons stop working and you ask again.

After you approve: the card changes to "approved by you — executing…", then to a **before / after** comparison and `verified ✔` or `verification failed ✖`. If verification failed, the agent does not claim success; it shows what it saw and you decide the next step.

**Deny** when the proposal is wrong, unnecessary, or the wrong moment. Denying changes nothing on any server and is recorded with your name.

You may see:
- *"Blocked: 3/3 restarts of backend used this hour; next at 11:06"* — the rate limit. A fourth restart is rarely the answer; run the `backend-down` runbook instead.
- *"Change freeze: prod is frozen until Sun 06:00 (quarter-end close)"* — no changes in that environment until then; an admin can end the freeze early if it is an emergency.
- *"Role insufficient: requires admin"* — ask an admin; your click is logged, nothing else happened.

## A5 Runbooks, alerts, incidents

`/runbook backend-down` (or `disk-full`, `db-slow`) runs a fixed sequence of the same tools without the AI model. If a step is an action, it stops and asks for approval like any proposal. Steps are shown as they complete; a failed step stops the runbook and shows how far it got.

Alerts arrive in the ops channel when a rule fires — disk above 85 %, a container restarting in a loop, a certificate under 14 days, too many DB connections — once per problem, not once per check. **Acknowledge** with the button so others see someone is on it. A daily summary posts at 08:00.

Incidents: `/incident open <title>` groups runs, alerts and actions; `POST summary` in the console produces a timeline from the records (with prose only if the model is available — and every sentence points at a timeline entry).

## A6 The web console

Runs (filter by kind, outcome, person, text), tool calls with their redacted results, proposals (pending first, with the countdown), policy and freezes, runbooks, alerts, incidents, audit. Everything you can do in Discord you can do here; approvals from the console need your login (and MFA for admin/owner).

## A7 Discord command reference

| Command | Who | What |
|---|---|---|
| `/ask <question>` | everyone | Investigate; may propose one action |
| `/diag <target>` | everyone | Fixed check-up; works without the model; never proposes |
| `/status` | everyone | Agent health, open alerts, pending proposals |
| `/runbook <name> [target]` | operator+ | Run a runbook |
| `/approve <id> [note]` · `/deny <id> [note]` | per policy / operator+ | Same as the buttons |
| `/freeze <env> <hours> <reason>` | admin+ | Declare a change freeze |
| `/incident open <title>` | operator+ | Open an incident |

## A8 FAQ

**It restarted something without asking?** Only if the owner enabled `auto_execute` for that low-risk action in that environment (staging by default, never prod in the shipped policy). Every automatic execution is logged like an approval — check the audit page.

**Why did it refuse to delete old volumes when disk was full?** Destructive actions are permanently denied — not by the model, by the policy engine — and the proxy on the server does not even expose volume operations. Use the `disk-full` runbook (rotate logs, prune dangling images).

**A log line told the agent to do something. Did it?** No. Log content is data to the agent; it may mention the line as suspicious. Even if the model were fooled, the same approval gate and deny-list stand in front of any action.

**Can I see the raw log it read?** You see the redacted version — secrets are replaced before the model or anyone sees them. The redaction counter on each tool call tells you how many were removed.

**The AI is offline. Is the agent useless?** No: `/diag`, runbooks, alerts and the daily summary all work; `/ask` gives the evidence without the narrative.

**Who can add a new action?** Nobody through the console — a new action is code, reviewed and released. That is deliberate (B4).

---

# Part B — Owner's guide

## B1 Users, roles and Discord mapping
Roles: **viewer** (ask, read), **operator** (approve low, run runbooks, ack alerts), **admin** (approve medium, freezes, incidents, audit read), **owner** (policy, registry enable/disable, targets, users, export). Create users in the console or `opsctl user create`; **map Discord identities yourself** (`opsctl user link`) — an unmapped Discord account is a viewer no matter what it calls itself. Admins and owners need MFA on the console.

## B2 Policy — who may approve what, where, how often
`/etc/opspilot/policy.yaml` ([example](../deploy/policy.yaml.example)): per action, per environment — `allow`, `require_role`, `rate_limit` (`max` per `window_s`, keyed by target or target+service), `targets_allow`, `auto_execute`. Load it with `opsctl policy load`; it is validated (the file cannot enable a deny-listed name or auto-execute a high-risk action — the schema, the API and the database all refuse), applied atomically, and recorded with its version.

Guidance: prod never auto-executes; keep `stop_container` and `redeploy_last_good` at admin; keep restart limits at 3/hour — the limit is a signal, not an obstacle.

## B3 Targets and tags
Onboarding a target is an operations procedure (OPS-04 §5) with a verification step; in the console you only **enable/disable** and **tag**. Tags matter: `critical` (no stop; restart needs admin), `ot` / `plc` (**no write tool at all** — OpsPilot never touches production equipment or an EdgeGuard node's line path).

## B4 The tool registry
The console shows every tool with its kind, risk, required role, argument schema, verifier and the proxy endpoints it needs. You can **enable or disable** a tool. You cannot add one, change its risk, or loosen its schema — those are code, reviewed and released, because the registry *is* the boundary of what the agent can do (C-01, C-02). If the team needs a new capability, file it as a change request; it arrives as a new registry version.

## B5 Runbooks and alert rules
Runbooks are YAML files of registry tools with conditions ([examples](../deploy/runbooks/)); load with `opsctl runbook load` (schema-validated; a step naming a non-registry tool is rejected). Alert rules are small conditions over a tool's result (`max(disk[*].used_pct) > 85`) with a severity and cooldown; four ship by default.

## B6 Model, prompt and registry versions
Every run records which model, prompt and registry produced it. Change the model or prompt only with the corpora re-run (OPS-04 §6.5); a run from an older version is still fully explained by its own records.

## B7 Audit and export
The audit log cannot be edited or deleted — not by the app, not by the owner. Export a window (NDJSON + manifest with counts and a hash) for an auditor or an incident review; the export alone reconstructs who asked, what the agent saw, what it proposed, who approved, what ran and what the verification showed.

## B8 What the agent will never do
- Run a command that is not a registered tool (there is no shell tool, and there will not be one).
- Delete data, remove volumes, prune everything, force-push, drop or truncate anything.
- Execute a state change without an approval bound to that exact action — or without an owner's explicit, audited, low/medium-only auto-execute setting.
- Execute anything `high` risk automatically.
- Follow instructions found in logs, files, database rows or web pages.
- Show a secret to the model, to Discord, or to the console.
- Claim an action succeeded without checking with a read tool.
- Touch OT/PLC equipment or a factory edge node's line path.
- Change its own policy, registry or audit trail.

---

## Glossary (TH / JA / EN)

| EN | TH | JA | Meaning |
|---|---|---|---|
| Tool | เครื่องมือ | ツール | A typed function the agent may call; read or write |
| Registry | ทะเบียนเครื่องมือ | ツール登録簿 | The list of all tools — the boundary of what the agent can do |
| Proposal | ข้อเสนอการดำเนินการ | 提案 | An action the agent suggests; nothing runs until approved |
| Approval | การอนุมัติ | 承認 | A person's OK bound to one exact proposal; expires in 10 min |
| Deny | ปฏิเสธ | 却下 | Decline a proposal; nothing changes; recorded |
| Dry run | ทดลองรัน | ドライラン | Show what would happen without doing it |
| Risk level | ระดับความเสี่ยง | リスクレベル | low / medium / high — decides who may approve |
| Deny-list | รายการห้ามถาวร | 永久禁止リスト | Destructive actions that are never allowed, by code |
| Policy | นโยบาย | ポリシー | Who may approve what, where, how often |
| Change freeze | ช่วงระงับการเปลี่ยนแปลง | 変更凍結 | No state changes in an environment for a period |
| Rate limit | จำกัดความถี่ | レート制限 | e.g. at most 3 restarts of a service per hour |
| Runbook | คู่มือปฏิบัติอัตโนมัติ | ランブック | A fixed sequence of tools for a known problem |
| Sweep | การตรวจรอบ | 巡回チェック | The scheduled health check and daily summary |
| Evidence | หลักฐาน | 証拠 | Tool results (`tc-xx`) the diagnosis is based on |
| Verification | การตรวจสอบผล | 検証 | Reading the state after an action; "done" means verified |
| Redaction | การปิดบังข้อมูลลับ | 秘匿化 | Secrets removed from tool output before anyone sees it |
| Deterministic mode | โหมดไม่ใช้ AI | 決定論モード | Diagnostics and runbooks without the language model |
| Audit log | บันทึกตรวจสอบ | 監査ログ | Append-only record of every decision and action |
| Target | เป้าหมาย | 対象 | A host, database, URL or repository the agent may look at or act on |
