#!/bin/sh
# GenbaGo — sets the passwords of the database roles created by db/schema.sql from secret files (OPS-14 §4.2).
# The role passwords are read from the same files that database_url / worker_database_url embed; nothing is echoed.
set -eu
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
ALTER ROLE app_rw     PASSWORD '$(sed -n 's#^postgresql://app_rw:\([^@]*\)@.*#\1#p' /run/secrets/database_url 2>/dev/null || echo ReplaceAtBootstrap)';
ALTER ROLE worker_rw  PASSWORD '$(sed -n 's#^postgresql://worker_rw:\([^@]*\)@.*#\1#p' /run/secrets/worker_database_url 2>/dev/null || echo ReplaceAtBootstrap)';
ALTER ROLE app_ro     NOLOGIN;
ALTER ROLE auditor_ro NOLOGIN;
SQL
