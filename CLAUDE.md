# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A **specification repository**, not an implementation. 371 files, 182 of them Markdown; there is no application source code, no package manifest, no test runner. The deliverables are engineering documents plus **machine-readable artifacts that are meant to be executable one day and verifiable today**: PostgreSQL DDL, OpenAPI 3.1, JSON Schema, Docker Compose, YAML configuration and CSV/YAML exchange files.

Sixteen numbered folders (`00-factorybrain-platform` … `15-troubleshooting-memory`), each a self-contained documentation set for one product. `00` is the umbrella platform that defines the shared schema, API and interface contracts; `01`–`15` are products that plug into it. The root `README.md` holds the index, the relationship diagram and the conventions every document inherits.

## Fixed layout of every project folder

```
NN-project-name/
  SRS-<CodeName>-<Topic>.md          the requirements spec — written first, treated as fixed input
  README.md                          index, artifact table with verified counts, verification table
  docs/  SAD- DDS- ICD- SEC- TEST- OPS- UM-<CodeName>-*.md    the eight companion documents
  api/   openapi.yaml + API-Specification.md
  db/    schema.sql + seed_demo.sql
  deploy/ docker-compose.yml · .env.example · <name>.example.yaml
          schemas/*.json (contract + config) · examples/*.json · prompts/*.md
```

File names carry the code name, not the folder number: `SAD-GenbaMemory-Software-Architecture.md`, `DDS-VisionOps-Database-Design.md`. Code names are in the root README's index table.

## Architecture that spans folders

**The platform owns the base schema; modules extend it.** A module's `db/schema.sql` begins with sections lifted **byte-identically by line range** out of `00-factorybrain-platform/db/schema.sql` (extensions, helpers, the enums its objects need, `core`, whichever `quality`/`knowledge`/`agent` sections it touches, `audit`, their indexes and `updated_at` triggers), then adds its own schema as a migration named `<schema>_0001` — `shiftbrief`, `machinesense`, `docflow`, `quality`, `copilot`, `moldmind`, `swarm`, `genba`, `memory`. Every extracted block is marked `[platform section N, verbatim]` and a TC in that folder's TEST document diffs it against `00`. If you touch a module schema, re-run the identity check; never "improve" an extracted block.

**Ownership inside a shared schema is per table, and sometimes per column.** `knowledge` is owned by 15 Genba Memory, but `knowledge.glossary_term` and `knowledge.tm_segment` belong to 14 GenbaGo, and `knowledge.chunk.suspicious` belongs to 10 Factory Copilot. Migrations from different modules must apply in any order, which is why additive columns use `ADD COLUMN IF NOT EXISTS` and shared triggers are created inside a `DO` block that checks for absence first. Grants encode the ownership (a module's `worker_rw` is denied another module's tables).

**`IF-xx` interface numbers are global across all ICDs.** `IF-01`…`IF-17` are defined in ICD-00; each module appends a new contiguous block (10 → 53–57, 11 → 58–62, 12 → 63–67, 13 → 68–72, 14 → 73–77, 15 → 78–84). A module that needs a sibling's interface **reuses it by reference** — it does not invent a parallel contract.

**Each module owns one ID letter** for its own decision and security identifiers, so `ADR-`/`DD-`/`THR-`/`SEC-`/`RR-` never collide across folders: 01 V · 02 S · 03 E · 04 O · 05 M · 06 P · 07 T · 08 D · 09 Q · 10 C · 11 M · 12 G · 13 K · 14 J · 15 H. Shared, unlettered prefixes: `FR-`/`NFR-`/`AI-`/`AC-`/`C-` (SRS), `P-n` (principles), `QAS-`, `TS-`/`TC-`, `RB-` (runbooks), `P-nn` (seed probes).

Every requirement is expected to trace `SRS → SAD → DDS → API/ICD → SEC → TEST`, and both the module README and the TEST document carry that chain explicitly.

## Working conventions these documents follow

- **Header table** on every document: Document ID, Version 1.0 (Draft), Date, Author Suphot N., Status Draft for review, plus `Source` and `Related` link rows. English throughout, en-dashes and `·` separators, British spelling.
- **Verification tables must be honest.** PostgreSQL, Docker, Ollama and the models are not available on the authoring machine. Artifacts are marked ✅ for what was actually checked and ⚠️ *not executed* for what was not; TEST documents mark each suite **E**xecuted / **S**pecified / **M**anual / **P**erformance, and no test is reported as passing unless it ran.
- **Seeds and expectations are generated, never typed.** Every computed value in `db/seed_demo.sql` comes from a Python model of the SQL functions ("twins"), and a separate checker re-derives those values **from the generated file** rather than from the model. `\echo` expectation blocks are generated the same way. When a number in a document changes, regenerate the seed, the exchange files and the checker together.
- **Seed probes** are deliberately failing statements (`P-01`…), each in its own transaction with `ON_ERROR_STOP off`, that prove the guard triggers reject what they should. The OPS verification section states how many ERRORs to expect.
- **No secrets anywhere** — only placeholders, `*_FILE` environment references and secret files under `${SECRETS_DIR}`. Compose stacks bind ports to `${BIND_ADDR}`, keep workers on an internal network with no route out, and give only the Discord bot egress.
- Do not modify anything outside the folder being worked on, and **do not commit unless asked**. Commit messages follow `Add detail of NN-folder-name`.

## Verifying artifacts

Python 3.14 with `PyYAML`, `jsonschema` and `openapi-spec-validator` is available. Checkers are written ad hoc per folder into the session scratchpad (not committed); reuse the previous folder's script as the template rather than starting over.

```bash
# OpenAPI: parse, validate, then check refs/orphans/operationIds and the verbatim API-00 blocks
python -c "import yaml,openapi_spec_validator as v; v.validate(yaml.safe_load(open('15-troubleshooting-memory/api/openapi.yaml',encoding='utf-8')))"

# Compose and config YAML parse (no Docker daemon here — `docker compose config` cannot run)
python -c "import yaml; yaml.safe_load(open('15-troubleshooting-memory/deploy/docker-compose.yml',encoding='utf-8'))"

# Contract schemas: every example must validate, and every negative must be rejected
python -c "import json,jsonschema; jsonschema.Draft202012Validator(json.load(open('.../schemas/x.schema.json'))).validate(json.load(open('.../examples/y.json')))"

# Platform identity: extracted blocks byte-identical to the platform schema
diff <(sed -n '144,322p' 00-factorybrain-platform/db/schema.sql) <(sed -n 'A,Bp' NN-x/db/schema.sql)

# SQL itself is never executed here. The psql command set lives in each OPS document's
# final "Verifying an installation" section, with the expected object counts and probe errors.
```

A per-folder **sweep** script closes the set: broken relative links, undefined `{#if-xx}` anchors, SRS IDs never referenced, cited tables/views/triggers/functions/indexes that do not exist in `schema.sql`, cited endpoints absent from `openapi.yaml`, and undefined `TC-`/`RB-`/`ADR-`/`QAS-`/`SEC-`/`THR-`/`DD-`/`RR-`/`P-` references. Run it after the README and fix what it finds.

## Environment gotchas

- **Write documents and patch scripts with the Write tool, not Bash heredocs.** `cat > f <<'MD'` and `python - <<'PY'` have repeatedly aborted or truncated on this content (backslashes, `$$`, nested quotes, CJK/Thai).
- Set `PYTHONIOENCODING=utf-8` before any script that prints Thai or Japanese — the Windows console default is cp874.
- `${VAR}` inside a YAML **flow** mapping opens a brace and breaks the parser: write `{ file: "${SECRETS_DIR}/postgres_password" }` with the value quoted.
- Line-range extraction from `00/db/schema.sql` is off-by-one prone; print the boundary lines with `sed -n` or `awk` and confirm before trusting a range.
