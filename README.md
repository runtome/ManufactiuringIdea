# Manufacturing AI — Project Specifications

Software Requirements Specifications for 16 AI project ideas, centred on **industrial / manufacturing AI**: computer vision, agents, edge inference, quality engineering and local LLMs.

Each project has its own folder and its own uniquely-named SRS document, so any one of them can be built, demoed or handed over independently.

Date: 2026-09-10 · Author: Suphot N.

---

## Index

| # | Project | Code name | Document |
|---|---|---|---|
| 00 | Manufacturing intelligence platform (umbrella) | **FactoryBrain AI** | [SRS-FactoryBrain-AI-Platform.md](00-factorybrain-platform/SRS-FactoryBrain-AI-Platform.md) |
| 01 | AI Factory Inspector Agent | **VisionOps** | [SRS-AI-Factory-Inspector-Agent.md](01-factory-inspector-agent/SRS-AI-Factory-Inspector-Agent.md) |
| 02 | Production CSV → AI Analyst → Discord | **ShiftBrief** | [SRS-ShiftBrief-Production-AI-Analyst.md](02-production-ai-analyst/SRS-ShiftBrief-Production-AI-Analyst.md) |
| 03 | Edge AI Quality Inspection node | **EdgeGuard** | [SRS-EdgeGuard-Edge-Vision-Inspection.md](03-edge-vision-inspection/SRS-EdgeGuard-Edge-Vision-Inspection.md) |
| 04 | Local AI Agent for Company IT | **OpsPilot** | [SRS-OpsPilot-Local-AI-Operations-Agent.md](04-local-ai-ops-agent/SRS-OpsPilot-Local-AI-Operations-Agent.md) |
| 05 | Offline AI Mobile Inspector | **PocketQC** | [SRS-PocketQC-Offline-Mobile-Inspector.md](05-offline-mobile-inspector/SRS-PocketQC-Offline-Mobile-Inspector.md) |
| 06 | AI Predictive Maintenance Agent | **MachineSense** | [SRS-MachineSense-Predictive-Maintenance.md](06-predictive-maintenance-agent/SRS-MachineSense-Predictive-Maintenance.md) |
| 07 | AI Dog Finder 2.0 | **PawTrace** | [SRS-PawTrace-AI-Dog-Finder.md](07-ai-dog-finder/SRS-PawTrace-AI-Dog-Finder.md) |
| 08 | AI Document → ERP Agent | **DocFlow** | [SRS-DocFlow-Document-to-ERP-Agent.md](08-document-erp-agent/SRS-DocFlow-Document-to-ERP-Agent.md) |
| 09 | AI Manufacturing Quality Engineer Agent | **QE-Agent** | [SRS-QE-Agent-Quality-Engineer.md](09-quality-engineer-agent/SRS-QE-Agent-Quality-Engineer.md) |
| 10 | Local AI Factory Copilot | **Factory Copilot** | [SRS-FactoryCopilot-Local-Multilingual-Assistant.md](10-factory-copilot/SRS-FactoryCopilot-Local-Multilingual-Assistant.md) |
| 11 | AI Vision + Agent for Injection Molding | **MoldMind** | [SRS-MoldMind-Injection-Molding-AI.md](11-injection-molding-ai/SRS-MoldMind-Injection-Molding-AI.md) |
| 12 | GAPFarm AI Farmer Agent | **GAPFarm AI** | [SRS-GAPFarm-AI-Farmer-Agent.md](12-gapfarm-ai-agent/SRS-GAPFarm-AI-Farmer-Agent.md) |
| 13 | Multi-Agent Factory System | **KaizenSwarm** | [SRS-KaizenSwarm-Multi-Agent-Factory.md](13-multi-agent-factory/SRS-KaizenSwarm-Multi-Agent-Factory.md) |
| 14 | Japanese Factory Translator Agent | **GenbaGo (現場語)** | [SRS-GenbaGo-Japanese-Factory-Translator.md](14-japanese-factory-translator/SRS-GenbaGo-Japanese-Factory-Translator.md) |
| 15 | AI Production Troubleshooting Memory | **Genba Memory** | [SRS-GenbaMemory-Troubleshooting-RAG.md](15-troubleshooting-memory/SRS-GenbaMemory-Troubleshooting-RAG.md) |

---

## How the projects relate

`00 FactoryBrain` is the umbrella platform — it defines the shared data schema, the agent tool contract, auth and deployment. The others are independent products that can plug into it.

```
                          ┌──────────────────────────────┐
                          │   00  FactoryBrain Platform  │
                          │  data layer · AI gateway ·   │
                          │  auth · tool contract        │
                          └──┬─────┬─────┬─────┬─────┬───┘
        ingest / vision      │     │     │     │     │      knowledge
   ┌──────────────┬──────────┘     │     │     │     └──────────────┬──────────────┐
   ▼              ▼                ▼     ▼     ▼                    ▼              ▼
01 VisionOps  03 EdgeGuard   02 ShiftBrief  06 MachineSense   15 Genba Memory  14 GenbaGo
   │              │                │             │                  │              │
   └──────┬───────┘                └──────┬──────┘                  └──────┬───────┘
          ▼                               ▼                                ▼
    09 QE-Agent  ◄────────── 11 MoldMind (molding domain) ──────────►  10 Factory Copilot
          │                                                                 │
          └───────────────────► 13 KaizenSwarm (orchestration) ◄────────────┘

Standalone / adjacent:  04 OpsPilot (infrastructure)   05 PocketQC (mobile)
                        08 DocFlow (business docs)     07 PawTrace (consumer)
                        12 GAPFarm AI (agriculture)
```

---

## Suggested build order

| Order | Project | Why |
|---|---|---|
| 1 | **02 ShiftBrief** | Fastest to value, no hardware, immediately useful at work. Builds the data + LLM-grounding foundation everything else reuses. |
| 2 | **01 VisionOps** | The strongest portfolio piece: CV + agent + dashboard + real business outcome. |
| 3 | **09 QE-Agent** | Turns raw defect data into quality engineering — the differentiator versus a generic CV project. |
| 4 | **03 EdgeGuard** | Productionises VisionOps: latency, offline, fleet management. |
| 5 | **10 Factory Copilot** | The face of the platform; demos extremely well in three languages. |
| 6 | **15 Genba Memory** | Compounding value — every case makes the system smarter. |
| 7 | **06 MachineSense** or **11 MoldMind** | Depends on which data you can actually access. |
| 8 | Others | 04/05/08/12/13/14/07 as interest and opportunity dictate. |

A realistic personal-project target is **02 → 01 → 09 → 10** as one coherent portfolio system (essentially FactoryBrain v1), rather than 16 separate half-finished repos.

---

## Conventions shared by all documents

**Structure** — every SRS follows the same skeleton: Introduction → Overall Description → Functional Requirements → External Interfaces → Data Requirements → AI/ML Requirements → Non-Functional Requirements → Acceptance Criteria → Delivery Plan → Risks → Appendix.

**Requirement IDs** — `FR-xx` functional, `AI-xx` model/ML, `NFR-xx` non-functional, `AC-xx` acceptance, `C-xx` constraint. Priorities use MoSCoW (Must / Should / Could).

**Hardware baseline** — a single **RTX 3060 Ti 8 GB** development machine. Every design choice respects it: local LLMs ≤ 9 B parameters at Q4_K_M, vision models at 640 px, GPU work serialised where both compete.

**Default stack** — Python 3.11 + FastAPI, Next.js 15 + TypeScript, PostgreSQL 16 (+ pgvector, PostGIS or TimescaleDB where relevant), Ollama, Docker Compose, Flutter for mobile, Discord for delivery.

**Three rules that appear in every specification**

1. **The LLM never computes numbers.** Statistics come from code; the model writes prose around a structured facts object. Every figure must be traceable to a tool result.
2. **Offline-first.** Factory networks fail. Anything on the shop floor buffers locally and syncs later; nothing critical depends on the internet.
3. **Human-in-the-loop for consequences.** AI drafts, proposes and ranks. A named person approves anything that changes a verdict, a document of record, a machine, or an ERP transaction.

---

## Status

All 16 documents are **v1.0 drafts** — specifications, not implementations. No code has been written yet.
