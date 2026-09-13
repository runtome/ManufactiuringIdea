-- =====================================================================
--  OpsPilot — Local AI Operations Agent — PostgreSQL 16 schema
--  DDS-04-OpsPilot v1.0 · 2026-09-12 · Suphot N.
--
--  Own database (separate deployment — SAD-00 §13, DDS-00 §12.3).
--  Schemas:  ops   — users, targets, tool registry, runs, proposals, policy, runbooks, alerts, incidents
--            audit — append-only trail (audit.log extracted from the platform, FK retargeted)
--
--  Structural parity: ops.tool / ops.agent_run / ops.tool_call / ops.action_proposal mirror the
--  platform's agent.tool / agent.run / agent.tool_call / agent.action_proposal column-for-column,
--  except role vocabularies and FK targets. Verified by TEST-04 TC-002 (parity script).
--
--  Helpers (§3) are byte-identical to 00-factorybrain-platform/db/schema.sql lines 59–104 (TC-003).
-- =====================================================================

-- =====================================================================
-- 1. EXTENSIONS
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_bytes, digest (args_hash)
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- incident / run text search

-- =====================================================================
-- 2. SCHEMAS
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS ops;        -- the agent
CREATE SCHEMA IF NOT EXISTS audit;      -- append-only audit trail

-- =====================================================================
-- 3. HELPER FUNCTIONS  (byte-identical to the platform — do not edit here)
-- =====================================================================
-- =====================================================================
-- 3. HELPER FUNCTIONS
-- =====================================================================

-- UUIDv7 (time-ordered) — ADR-012.
-- PostgreSQL 18 ships uuidv7() natively; this shim keeps PG16 compatible.
CREATE OR REPLACE FUNCTION public.uuid_generate_v7()
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    unix_ts_ms  bigint;
    uuid_bytes  bytea;
BEGIN
    unix_ts_ms := (extract(epoch FROM clock_timestamp()) * 1000)::bigint;

    -- Layout: 48-bit big-endian millisecond timestamp, then random bits.
    -- int8send gives 8 bytes big-endian; bytes 3..8 are the low 48 bits.
    uuid_bytes := overlay(gen_random_bytes(16)
                          PLACING substring(int8send(unix_ts_ms) FROM 3 FOR 6)
                          FROM 1 FOR 6);

    -- Byte 6 high nibble = version 7  -> 0x70 | (random & 0x0F)
    uuid_bytes := set_byte(uuid_bytes, 6,
                           112 | (get_byte(uuid_bytes, 6) & 15));

    -- Byte 8 high bits = RFC 4122 variant 10xx -> 0x80 | (random & 0x3F)
    uuid_bytes := set_byte(uuid_bytes, 8,
                           128 | (get_byte(uuid_bytes, 8) & 63));

    RETURN encode(uuid_bytes, 'hex')::uuid;
END;
$$;

COMMENT ON FUNCTION public.uuid_generate_v7() IS
  'Time-ordered UUIDv7 (ADR-012). Preserves B-tree locality unlike uuidv4. Replace with native uuidv7() on PG18+.';

-- Generic updated_at trigger
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- =====================================================================
-- 4. ROLE LADDER AND PERMANENT DENY-LIST (code-level constants, ADR-O07)
-- =====================================================================

-- viewer < operator < admin < owner. The agent service account has NO role (SRS-04 §2.2).
CREATE OR REPLACE FUNCTION ops.role_rank(r text)
RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE r WHEN 'viewer' THEN 1 WHEN 'operator' THEN 2 WHEN 'admin' THEN 3 WHEN 'owner' THEN 4 ELSE 0 END::smallint
$$;

-- Tool names that may never enter the registry (C-02, ADR-O01). Belt-and-braces to the code constant.
CREATE OR REPLACE FUNCTION ops.is_denylisted_tool_name(n text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT n ~* '(shell|exec|eval|sql|query_raw|volume_rm|system_prune|force_push|drop_|truncate)'
$$;

-- Canonical JSON for hashing: jsonb text form is key-sorted and whitespace-normalised by PostgreSQL.
CREATE OR REPLACE FUNCTION ops.args_hash(tool_name text, args jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT encode(digest(tool_name || '|' || args::text, 'sha256'), 'hex')
$$;

COMMENT ON FUNCTION ops.args_hash(text, jsonb) IS
  'sha256(tool_name | canonical jsonb text). Approval binds to this value (ADR-O03, FR-19). TEST-04 TC-005 recomputes it in Python.';

-- =====================================================================
-- 5. USERS, ENVIRONMENTS, TARGETS
-- =====================================================================

CREATE TABLE ops.app_user (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    username        text        NOT NULL UNIQUE,
    display_name    text        NOT NULL,
    email           text,
    role            text        NOT NULL CHECK (role IN ('viewer','operator','admin','owner')),
    discord_user_id text        UNIQUE,
    lang            text        NOT NULL DEFAULT 'th' CHECK (lang IN ('th','ja','en')),
    password_hash   text,
    mfa_secret      text,
    active          boolean     NOT NULL DEFAULT true,
    last_login_at   timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN ops.app_user.role IS
  'Four roles per SRS-04 §2.2: viewer < operator < admin < owner. Approver role is compared with ops.role_rank().';
COMMENT ON COLUMN ops.app_user.discord_user_id IS
  'Discord snowflake mapped by the owner (IF-08). An unmapped Discord user is treated as viewer.';

CREATE TABLE ops.environment (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code        text        NOT NULL UNIQUE CHECK (code IN ('prod','staging','dev')),
    name        text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ops.target (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    env_id       uuid        NOT NULL REFERENCES ops.environment(id) ON DELETE RESTRICT,
    code         text        NOT NULL UNIQUE,
    kind         text        NOT NULL CHECK (kind IN ('docker_host','systemd_host','database','http','git')),
    endpoint     text        NOT NULL,          -- proxy URL, host, DSN alias (never a secret), URL, repo alias
    tags         text[]      NOT NULL DEFAULT '{}',   -- 'critical', 'ot', 'plc' are honoured by the deny-list
    enabled      boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN ops.target.endpoint IS
  'Connection *alias* only. Real DSNs, tokens and keys are runtime secrets (NFR-05); the alias is resolved by the executor.';
COMMENT ON COLUMN ops.target.tags IS
  'critical: no stop_container, restart needs admin. ot / plc: no write tool at all (SRS-04 §1.2 out of scope).';

-- =====================================================================
-- 6. TOOL REGISTRY  (parity: agent.tool)
-- =====================================================================

CREATE TABLE ops.tool (
    id                uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name              text        NOT NULL UNIQUE,
    kind              text        NOT NULL CHECK (kind IN ('read','write')),
    risk              text        NOT NULL DEFAULT 'low' CHECK (risk IN ('low','medium','high')),
    schema_json       jsonb       NOT NULL,
    min_role          text        NOT NULL DEFAULT 'viewer'
                      CHECK (min_role IN ('viewer','operator','admin','owner')),
    enabled           boolean     NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- OpsPilot-only columns
    verify_with       text,                    -- read tool re-run before/after execution (ADR-O09)
    dry_run_supported boolean     NOT NULL DEFAULT false,
    proxy_endpoints   text[]      NOT NULL DEFAULT '{}',   -- IF-25 endpoints this tool needs
    registry_version  text        NOT NULL,
    CONSTRAINT tool_write_has_verify CHECK (kind = 'read' OR verify_with IS NOT NULL),
    CONSTRAINT tool_read_is_low      CHECK (kind = 'write' OR risk = 'low')
);

COMMENT ON TABLE ops.tool IS
  'The registry IS the capability boundary (C-01, ADR-O01). No shell, exec or SQL tool can be inserted (trigger below).';

CREATE OR REPLACE FUNCTION ops.trg_tool_denylist() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF ops.is_denylisted_tool_name(NEW.name) THEN
        RAISE EXCEPTION 'tool name "%" is permanently deny-listed (C-02, ADR-O07)', NEW.name;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tool_denylist BEFORE INSERT OR UPDATE OF name ON ops.tool
    FOR EACH ROW EXECUTE FUNCTION ops.trg_tool_denylist();

-- =====================================================================
-- 7. RUNS AND TOOL CALLS  (parity: agent.run, agent.tool_call)
-- =====================================================================

CREATE TABLE ops.agent_run (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    ts               timestamptz NOT NULL DEFAULT now(),
    user_id          uuid        REFERENCES ops.app_user(id) ON DELETE SET NULL,
    conversation_id  uuid,                      -- Discord thread id / console session (no FK — views are not truth)
    correlation_id   text,
    kind             text        NOT NULL DEFAULT 'ask'
                     CHECK (kind IN ('ask','diag','runbook','sweep','verify')),
    question         text,
    answer           text,
    model            text        NOT NULL,      -- 'none' when deterministic (NFR-06)
    prompt_version   text,
    facts_json       jsonb,                     -- the evidence bundle handed to the model (redacted)
    tokens_in        integer,
    tokens_out       integer,
    latency_ms       integer,
    tool_call_count  smallint    NOT NULL DEFAULT 0,
    outcome          text        NOT NULL DEFAULT 'ok'
                     CHECK (outcome IN ('ok','partial','refused','grounding_failed','error','budget_exceeded')),
    grounding_json   jsonb,
    -- OpsPilot-only columns
    channel          text        NOT NULL DEFAULT 'discord' CHECK (channel IN ('discord','web','api','scheduler')),
    registry_version text        NOT NULL,
    iterations       smallint    NOT NULL DEFAULT 0,
    deterministic    boolean     NOT NULL DEFAULT false,
    confidence       text        CHECK (confidence IN ('low','medium','high')),
    probable_cause   text,
    next_checks_json jsonb,
    CONSTRAINT run_deterministic_model CHECK (NOT deterministic OR model = 'none'),
    CONSTRAINT run_iterations_cap      CHECK (iterations BETWEEN 0 AND 8)
);

COMMENT ON COLUMN ops.agent_run.facts_json IS
  'The redacted evidence bundle (SAD-04 §4.3.5). With grounding_json it makes FR-16 auditable: every claim maps to a tool_call id.';
COMMENT ON COLUMN ops.agent_run.registry_version IS 'AI-07: model, prompt_version and registry_version on every run.';

CREATE TABLE ops.tool_call (
    id                   uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id               uuid        NOT NULL REFERENCES ops.agent_run(id) ON DELETE CASCADE,
    ordinal              smallint    NOT NULL,
    tool_name            text        NOT NULL,
    args_json            jsonb       NOT NULL,
    result_digest        text,
    row_count            integer,
    duration_ms          integer,
    ok                   boolean     NOT NULL DEFAULT true,
    error                text,
    -- OpsPilot-only columns
    redacted_result_json jsonb,                 -- the ONLY stored result (ADR-O06); no raw column exists
    redaction_count      integer     NOT NULL DEFAULT 0,
    truncated            boolean     NOT NULL DEFAULT false,
    target_id            uuid        REFERENCES ops.target(id) ON DELETE SET NULL,
    CONSTRAINT tool_call_ordinal_unique UNIQUE (run_id, ordinal)
);

COMMENT ON COLUMN ops.tool_call.redacted_result_json IS
  'Redacted before persistence (NFR-05, ADR-O06). result_digest is sha256 of the RAW result so audit equality is provable without content.';

-- =====================================================================
-- 8. POLICY, FREEZE, RATE LIMITS
-- =====================================================================

CREATE TABLE ops.policy (
    id              uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    tool_name       text        NOT NULL REFERENCES ops.tool(name) ON DELETE CASCADE,
    env_id          uuid        NOT NULL REFERENCES ops.environment(id) ON DELETE CASCADE,
    allow           boolean     NOT NULL DEFAULT true,
    require_role    text        NOT NULL CHECK (require_role IN ('operator','admin','owner')),
    rate_limit_json jsonb       NOT NULL DEFAULT '{"max": 3, "window_s": 3600, "key": "target"}'::jsonb,
    auto_execute    boolean     NOT NULL DEFAULT false,
    targets_allow   text[],                     -- NULL = any enabled target of the env; else explicit codes
    policy_version  text        NOT NULL,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT policy_unique UNIQUE (tool_name, env_id)
);

COMMENT ON TABLE ops.policy IS
  'Loaded from deploy/policy.yaml (schema-validated). auto_execute is opt-in per action per env and never for high risk (C-03) — enforced by trigger.';

CREATE OR REPLACE FUNCTION ops.trg_policy_no_auto_high() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
    SELECT risk INTO r FROM ops.tool WHERE name = NEW.tool_name;
    IF NEW.auto_execute AND r = 'high' THEN
        RAISE EXCEPTION 'auto_execute is never allowed for high-risk tool "%" (C-03)', NEW.tool_name;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER policy_no_auto_high BEFORE INSERT OR UPDATE ON ops.policy
    FOR EACH ROW EXECUTE FUNCTION ops.trg_policy_no_auto_high();

CREATE TABLE ops.freeze (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    env_id       uuid        NOT NULL REFERENCES ops.environment(id) ON DELETE CASCADE,
    starts_at    timestamptz NOT NULL,
    ends_at      timestamptz NOT NULL,
    reason       text        NOT NULL,
    declared_by  uuid        REFERENCES ops.app_user(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT freeze_window CHECK (ends_at > starts_at)
);

CREATE TABLE ops.rate_limit_event (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts          timestamptz NOT NULL DEFAULT now(),
    tool_name   text        NOT NULL,
    target_id   uuid        REFERENCES ops.target(id) ON DELETE SET NULL,
    counter     integer     NOT NULL,
    limit_max   integer     NOT NULL,
    window_s    integer     NOT NULL,
    proposal_id uuid                       -- set below once action_proposal exists
);

-- =====================================================================
-- 9. ACTION PROPOSALS  (parity: agent.action_proposal) — the P-3 gate
-- =====================================================================

CREATE TABLE ops.action_proposal (
    id               uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id           uuid        REFERENCES ops.agent_run(id) ON DELETE CASCADE,
    tool_name        text        NOT NULL,
    args_json        jsonb       NOT NULL,
    args_hash        text        NOT NULL,
    risk             text        NOT NULL CHECK (risk IN ('low','medium','high')),
    status           text        NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','approved','denied','expired','executed','failed','aborted')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    expires_at       timestamptz NOT NULL,
    approver_id      uuid        REFERENCES ops.app_user(id) ON DELETE SET NULL,
    decided_at       timestamptz,
    result_json      jsonb,
    -- OpsPilot-only columns
    target_id        uuid        REFERENCES ops.target(id) ON DELETE SET NULL,
    require_role     text        NOT NULL CHECK (require_role IN ('operator','admin','owner')),
    decision_json    jsonb       NOT NULL,      -- the policy engine's decision record (SAD-04 §4.3.2)
    denied_reason    text        CHECK (denied_reason IN ('DENYLISTED','TOOL_NOT_IN_REGISTRY','SCHEMA_INVALID','POLICY_DENIED',
                                                          'CHANGE_FREEZE','RATE_LIMITED','ROLE_INSUFFICIENT','TARGET_NOT_ALLOWED','USER_DENIED')),
    expected_effect  text,
    dry_run_json     jsonb,
    before_json      jsonb,
    after_json       jsonb,
    verification_ok  boolean,
    executed_at      timestamptz,
    idempotency_key  text        UNIQUE,
    CONSTRAINT proposal_expiry_window  CHECK (expires_at <= created_at + interval '10 minutes'),
    CONSTRAINT proposal_executed_verified CHECK (status <> 'executed' OR (before_json IS NOT NULL AND after_json IS NOT NULL AND verification_ok IS NOT NULL)),
    CONSTRAINT proposal_denied_has_reason CHECK (status <> 'denied' OR denied_reason IS NOT NULL),
    CONSTRAINT proposal_high_never_auto   CHECK (risk <> 'high' OR (decision_json->>'auto')::boolean IS NOT TRUE)
);

COMMENT ON TABLE ops.action_proposal IS
  'P-3 gate (C-03, FR-18/19/20). Approval binds to args_hash and expires within 10 minutes; an executed row always carries before/after and a verification result (FR-16, FR-20).';

ALTER TABLE ops.rate_limit_event
    ADD CONSTRAINT rate_limit_event_proposal_fk FOREIGN KEY (proposal_id) REFERENCES ops.action_proposal(id) ON DELETE SET NULL;

-- args_hash is computed by trigger and immutable (ADR-O03)
CREATE OR REPLACE FUNCTION ops.trg_proposal_hash() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.args_hash := ops.args_hash(NEW.tool_name, NEW.args_json);
    ELSIF NEW.args_json IS DISTINCT FROM OLD.args_json OR NEW.tool_name IS DISTINCT FROM OLD.tool_name OR NEW.args_hash IS DISTINCT FROM OLD.args_hash THEN
        RAISE EXCEPTION 'proposal % is immutable: tool_name/args/args_hash cannot change after creation (ADR-O03)', OLD.id;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER proposal_hash BEFORE INSERT OR UPDATE ON ops.action_proposal
    FOR EACH ROW EXECUTE FUNCTION ops.trg_proposal_hash();

-- Legal status transitions and approval rules (FR-19, C-03)
CREATE OR REPLACE FUNCTION ops.trg_proposal_transition() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE approver_role text;
BEGIN
    IF NEW.status = OLD.status THEN RETURN NEW; END IF;
    IF NOT (
        (OLD.status = 'pending'  AND NEW.status IN ('approved','denied','expired','aborted')) OR
        (OLD.status = 'approved' AND NEW.status IN ('executed','failed','aborted','expired'))
    ) THEN
        RAISE EXCEPTION 'illegal proposal transition % -> %', OLD.status, NEW.status;
    END IF;
    IF NEW.status = 'approved' THEN
        IF NEW.approver_id IS NULL THEN RAISE EXCEPTION 'approval requires approver_id'; END IF;
        IF now() > OLD.expires_at THEN RAISE EXCEPTION 'APPROVAL_EXPIRED'; END IF;
        SELECT role INTO approver_role FROM ops.app_user WHERE id = NEW.approver_id AND active;
        IF approver_role IS NULL OR ops.role_rank(approver_role) < ops.role_rank(OLD.require_role) THEN
            RAISE EXCEPTION 'ROLE_INSUFFICIENT: approver must be at least %', OLD.require_role;
        END IF;
        NEW.decided_at := COALESCE(NEW.decided_at, now());
    END IF;
    IF NEW.status = 'executed' THEN NEW.executed_at := COALESCE(NEW.executed_at, now()); END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER proposal_transition BEFORE UPDATE OF status ON ops.action_proposal
    FOR EACH ROW EXECUTE FUNCTION ops.trg_proposal_transition();

-- =====================================================================
-- 10. RUNBOOKS, SWEEPS, ALERTS, INCIDENTS
-- =====================================================================

CREATE TABLE ops.runbook (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    name         text        NOT NULL UNIQUE,
    version      integer     NOT NULL DEFAULT 1,
    description  text,
    yaml_text    text        NOT NULL,
    yaml_sha256  text        NOT NULL,
    steps_json   jsonb       NOT NULL,          -- parsed, schema-validated (deploy/schemas/runbook.schema.json)
    enabled      boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ops.runbook_run (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    runbook_id   uuid        NOT NULL REFERENCES ops.runbook(id) ON DELETE RESTRICT,
    run_id       uuid        NOT NULL REFERENCES ops.agent_run(id) ON DELETE CASCADE,
    started_at   timestamptz NOT NULL DEFAULT now(),
    finished_at  timestamptz,
    status       text        NOT NULL DEFAULT 'running'
                 CHECK (status IN ('running','waiting_approval','completed','failed','aborted')),
    steps_done   smallint    NOT NULL DEFAULT 0,
    last_step    text
);

CREATE TABLE ops.alert_rule (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    code        text        NOT NULL UNIQUE,
    description text        NOT NULL,
    tool_name   text        NOT NULL REFERENCES ops.tool(name),
    condition   text        NOT NULL,           -- expression over the tool result (documented in DDS §6)
    severity    text        NOT NULL CHECK (severity IN ('info','warning','critical')),
    cooldown_s  integer     NOT NULL DEFAULT 3600,
    enabled     boolean     NOT NULL DEFAULT true
);

CREATE TABLE ops.alert (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    rule_id      uuid        NOT NULL REFERENCES ops.alert_rule(id) ON DELETE RESTRICT,
    target_id    uuid        REFERENCES ops.target(id) ON DELETE SET NULL,
    opened_at    timestamptz NOT NULL DEFAULT now(),
    acked_at     timestamptz,
    acked_by     uuid        REFERENCES ops.app_user(id) ON DELETE SET NULL,
    resolved_at  timestamptz,
    status       text        NOT NULL DEFAULT 'open' CHECK (status IN ('open','acknowledged','resolved')),
    value_json   jsonb       NOT NULL,
    run_id       uuid        REFERENCES ops.agent_run(id) ON DELETE SET NULL,
    incident_id  uuid
);

-- One OPEN alert per (rule, target) — de-duplication (SAD-04 §4.4.8)
CREATE UNIQUE INDEX ux_alert_open ON ops.alert(rule_id, target_id) WHERE status <> 'resolved';

CREATE TABLE ops.sweep (
    id            uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    run_id        uuid        NOT NULL REFERENCES ops.agent_run(id) ON DELETE CASCADE,
    sweep_date    date        NOT NULL,
    targets_ok    smallint    NOT NULL,
    targets_warn  smallint    NOT NULL,
    targets_crit  smallint    NOT NULL,
    summary_json  jsonb       NOT NULL,
    posted_at     timestamptz,
    CONSTRAINT sweep_daily_unique UNIQUE (sweep_date)
);

CREATE TABLE ops.incident (
    id           uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    opened_at    timestamptz NOT NULL DEFAULT now(),
    closed_at    timestamptz,
    title        text        NOT NULL,
    severity     text        NOT NULL CHECK (severity IN ('low','medium','high','critical')),
    summary      text,
    cause        text,
    actions_json jsonb       NOT NULL DEFAULT '[]'::jsonb,   -- proposal ids in order
    run_ids      uuid[]      NOT NULL DEFAULT '{}',
    opened_by    uuid        REFERENCES ops.app_user(id) ON DELETE SET NULL,
    timeline_json jsonb,                                     -- FR-27 post-incident summary (generated from DB, not model text)
    CONSTRAINT incident_close_after_open CHECK (closed_at IS NULL OR closed_at >= opened_at)
);

ALTER TABLE ops.alert ADD CONSTRAINT alert_incident_fk FOREIGN KEY (incident_id) REFERENCES ops.incident(id) ON DELETE SET NULL;

CREATE TABLE ops.redaction_pattern (
    id          uuid PRIMARY KEY DEFAULT public.uuid_generate_v7(),
    family      text        NOT NULL,           -- bearer, api_key, url_password, kv_password, private_key, cloud, discord, b64_prefixed
    pattern     text        NOT NULL,
    replacement text        NOT NULL DEFAULT '[REDACTED]',
    enabled     boolean     NOT NULL DEFAULT true,
    CONSTRAINT redaction_pattern_unique UNIQUE (family, pattern)
);

CREATE TABLE ops.schema_version (
    version     text        PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    notes       text
);

-- =====================================================================
-- 11. AUDIT  (audit.log extracted from the platform; FK retargeted to ops.app_user)
-- =====================================================================
CREATE TABLE audit.log (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts             timestamptz NOT NULL DEFAULT now(),
    user_id        uuid        REFERENCES ops.app_user(id) ON DELETE SET NULL,
    actor          text,
    correlation_id text,
    action         text        NOT NULL,
    entity         text        NOT NULL,
    entity_id      text,
    before_json    jsonb,
    after_json     jsonb,
    ip             inet,
    user_agent     text
);

COMMENT ON TABLE audit.log IS
  'Append-only. app_rw is granted INSERT and SELECT only; there is no UPDATE or DELETE grant anywhere (SEC).';

-- Append-only: no UPDATE/DELETE grant exists (see §14) and a trigger refuses them regardless of role.
CREATE OR REPLACE FUNCTION audit.trg_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit.log is append-only (FR-32)';
END $$;
CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit.log
    FOR EACH ROW EXECUTE FUNCTION audit.trg_append_only();

-- Every proposal decision is audited automatically (AC-03, AC-04): the model never sees a denial that the log does not.
CREATE OR REPLACE FUNCTION ops.trg_proposal_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit.log (user_id, actor, correlation_id, action, entity, entity_id, before_json, after_json)
    VALUES (NEW.approver_id,
            CASE WHEN NEW.denied_reason IS NOT NULL AND NEW.denied_reason <> 'USER_DENIED' THEN 'policy' ELSE 'user' END,
            NEW.run_id::text,
            'proposal.' || NEW.status,
            'ops.action_proposal', NEW.id::text,
            CASE WHEN TG_OP = 'UPDATE' THEN jsonb_build_object('status', OLD.status) END,
            jsonb_build_object('status', NEW.status, 'tool', NEW.tool_name, 'args_hash', NEW.args_hash,
                               'risk', NEW.risk, 'denied_reason', NEW.denied_reason, 'verification_ok', NEW.verification_ok));
    RETURN NEW;
END $$;
CREATE TRIGGER proposal_audit AFTER INSERT OR UPDATE OF status ON ops.action_proposal
    FOR EACH ROW EXECUTE FUNCTION ops.trg_proposal_audit();

-- =====================================================================
-- 12. INDEXES
-- =====================================================================
CREATE INDEX ix_run_ts            ON ops.agent_run (ts DESC);
CREATE INDEX ix_run_user          ON ops.agent_run (user_id, ts DESC);
CREATE INDEX ix_run_kind_outcome  ON ops.agent_run (kind, outcome, ts DESC);
CREATE INDEX ix_run_question_trgm ON ops.agent_run USING gin (question gin_trgm_ops);
CREATE INDEX ix_tool_call_run     ON ops.tool_call (run_id, ordinal);
CREATE INDEX ix_tool_call_tool_ts ON ops.tool_call (tool_name, target_id);
CREATE INDEX ix_proposal_status   ON ops.action_proposal (status, expires_at);
CREATE INDEX ix_proposal_run      ON ops.action_proposal (run_id);
CREATE INDEX ix_proposal_exec     ON ops.action_proposal (tool_name, target_id, executed_at DESC) WHERE status = 'executed';
CREATE INDEX ix_alert_status      ON ops.alert (status, opened_at DESC);
CREATE INDEX ix_incident_open     ON ops.incident (opened_at DESC) WHERE closed_at IS NULL;
CREATE INDEX ix_incident_trgm     ON ops.incident USING gin ((coalesce(title,'') || ' ' || coalesce(cause,'')) gin_trgm_ops);
CREATE INDEX ix_freeze_env_window ON ops.freeze (env_id, starts_at, ends_at);
CREATE INDEX ix_audit_ts          ON audit.log (ts DESC);
CREATE INDEX ix_audit_entity      ON audit.log (entity, entity_id);
CREATE INDEX ix_audit_corr        ON audit.log (correlation_id);

-- updated_at triggers
CREATE TRIGGER app_user_updated_at BEFORE UPDATE ON ops.app_user FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER target_updated_at   BEFORE UPDATE ON ops.target   FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER policy_updated_at   BEFORE UPDATE ON ops.policy   FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER runbook_updated_at  BEFORE UPDATE ON ops.runbook  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =====================================================================
-- 13. VIEWS
-- =====================================================================

CREATE VIEW ops.v_pending_approvals AS
SELECT p.id, p.created_at, p.expires_at, p.tool_name, p.args_json, p.args_hash, p.risk, p.require_role,
       p.expected_effect, t.code AS target_code, r.user_id AS requested_by, r.question,
       GREATEST(0, EXTRACT(epoch FROM (p.expires_at - now())))::integer AS seconds_left
FROM ops.action_proposal p
JOIN ops.agent_run r ON r.id = p.run_id
LEFT JOIN ops.target t ON t.id = p.target_id
WHERE p.status = 'pending';

-- AC-07: an incident timeline reconstructed from the database alone
CREATE VIEW ops.v_run_timeline AS
SELECT r.id AS run_id, r.ts AS event_ts, 'run.started' AS event, r.question AS detail, NULL::text AS ref
FROM ops.agent_run r
UNION ALL
SELECT c.run_id, r.ts + make_interval(secs => COALESCE(
           (SELECT sum(duration_ms) FROM ops.tool_call c2 WHERE c2.run_id = c.run_id AND c2.ordinal < c.ordinal), 0) / 1000.0),
       'tool_call', c.tool_name || ' ' || c.args_json::text, c.id::text
FROM ops.tool_call c JOIN ops.agent_run r ON r.id = c.run_id
UNION ALL
SELECT p.run_id, p.created_at, 'proposal.created', p.tool_name || ' risk=' || p.risk, p.id::text FROM ops.action_proposal p
UNION ALL
SELECT p.run_id, p.decided_at,
       CASE WHEN p.denied_reason IS NOT NULL THEN 'proposal.denied' ELSE 'proposal.approved' END,
       COALESCE(p.denied_reason, 'approver role >= ' || p.require_role), p.id::text
FROM ops.action_proposal p WHERE p.decided_at IS NOT NULL
UNION ALL
SELECT p.run_id, p.executed_at, 'proposal.executed', 'verification_ok=' || p.verification_ok::text, p.id::text
FROM ops.action_proposal p WHERE p.executed_at IS NOT NULL;

-- Rate-limit input (ADR-O08): executed write actions per tool/target in the last hour; Redis counters rebuild from this
CREATE VIEW ops.v_restart_rate AS
SELECT p.tool_name, p.target_id, t.code AS target_code, count(*) AS executed_last_hour,
       max(p.executed_at) AS last_executed_at
FROM ops.action_proposal p LEFT JOIN ops.target t ON t.id = p.target_id
WHERE p.status = 'executed' AND p.executed_at >= now() - interval '1 hour'
GROUP BY p.tool_name, p.target_id, t.code;

CREATE VIEW ops.v_open_alerts AS
SELECT a.id, a.opened_at, a.status, ar.code AS rule_code, ar.severity, t.code AS target_code, a.value_json, a.incident_id
FROM ops.alert a JOIN ops.alert_rule ar ON ar.id = a.rule_id LEFT JOIN ops.target t ON t.id = a.target_id
WHERE a.status <> 'resolved';

CREATE VIEW ops.v_tool_registry AS
SELECT t.name, t.kind, t.risk, t.min_role, t.enabled, t.verify_with, t.dry_run_supported, t.proxy_endpoints, t.registry_version,
       (SELECT count(*) FROM ops.policy p WHERE p.tool_name = t.name AND p.allow) AS envs_allowed
FROM ops.tool t ORDER BY t.kind, t.risk, t.name;

-- Retention (SRS-04 §5): tool-call results 90 d (metadata 2 y), audit 2 y, incidents forever
CREATE VIEW ops.v_retention_due AS
SELECT 'tool_call.result' AS what, count(*) AS rows_due FROM ops.tool_call c JOIN ops.agent_run r ON r.id = c.run_id
 WHERE r.ts < now() - interval '90 days' AND c.redacted_result_json IS NOT NULL
UNION ALL
SELECT 'agent_run', count(*) FROM ops.agent_run WHERE ts < now() - interval '2 years'
UNION ALL
SELECT 'audit.log', count(*) FROM audit.log WHERE ts < now() - interval '2 years';

-- =====================================================================
-- 14. ROLES AND GRANTS
-- =====================================================================
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'opspilot_app') THEN CREATE ROLE opspilot_app LOGIN PASSWORD 'SET_AT_BOOTSTRAP'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'opspilot_ro')  THEN CREATE ROLE opspilot_ro  LOGIN PASSWORD 'SET_AT_BOOTSTRAP'; END IF;
END $$;

GRANT USAGE ON SCHEMA ops, audit TO opspilot_app, opspilot_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ops TO opspilot_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ops, audit TO opspilot_app;
GRANT SELECT, INSERT ON audit.log TO opspilot_app;          -- append-only: no UPDATE, no DELETE (FR-32)
REVOKE UPDATE, DELETE ON audit.log FROM opspilot_app;
GRANT SELECT ON ALL TABLES IN SCHEMA ops, audit TO opspilot_ro;
GRANT EXECUTE ON FUNCTION ops.args_hash(text, jsonb), ops.role_rank(text), ops.is_denylisted_tool_name(text) TO opspilot_app, opspilot_ro;

-- Target databases are probed with a SEPARATE read-only role created on each target (IF-27, C-04):
--   CREATE ROLE opspilot_probe LOGIN PASSWORD '…' NOSUPERUSER NOCREATEDB NOCREATEROLE;
--   GRANT pg_monitor TO opspilot_probe;            -- pg_stat_activity, pg_stat_replication, sizes
--   ALTER ROLE opspilot_probe SET statement_timeout = '5s';
-- No table grants: db_health reads catalog/statistics views only.

-- =====================================================================
-- 15. VERSION STAMP
-- =====================================================================
INSERT INTO ops.schema_version (version, notes) VALUES ('opspilot_0001', 'OpsPilot v1.0 — DDS-04');
