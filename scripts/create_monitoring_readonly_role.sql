-- PostgreSQL / EDB 9.6 least-privilege role for collect_metrics.sh
-- Adjust names below as needed, then run as a superuser/admin.

-- ==========================================================================
-- 1) Create roles
-- ===========================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'edb_monitor_ro') THEN
        CREATE ROLE edb_monitor_ro NOLOGIN;
    END IF;

    -- Service login used by collect_metrics.sh (PGUSER)
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_dbmonitor') THEN
        CREATE ROLE n8n_dbmonitor LOGIN;
    END IF;
END
$$;

-- Set service account password (replace before running in production)
\set monitor_password 'CHANGE_ME_STRONG_PASSWORD'
ALTER ROLE n8n_dbmonitor WITH PASSWORD :'monitor_password';

GRANT edb_monitor_ro TO n8n_dbmonitor;

-- ==========================================================================
-- 2) Database-level access (default DB in script is "edb")
-- ===========================================================================
GRANT CONNECT ON DATABASE edb TO n8n_dbmonitor;

\connect edb

-- ==========================================================================
-- 3) Schema and object grants needed by collect_metrics.sh
-- ===========================================================================
GRANT USAGE ON SCHEMA pg_catalog TO n8n_dbmonitor;
GRANT USAGE ON SCHEMA public TO n8n_dbmonitor;
GRANT USAGE ON SCHEMA valdezha TO n8n_dbmonitor;

-- System catalogs/views referenced by queries
GRANT SELECT ON
    pg_catalog.pg_stat_activity,
    pg_catalog.pg_stat_database,
    pg_catalog.pg_statio_user_tables,
    pg_catalog.pg_stat_user_tables,
    pg_catalog.pg_stat_bgwriter,
    pg_catalog.pg_replication_slots,
    pg_catalog.pg_locks,
    pg_catalog.pg_class,
    pg_catalog.pg_namespace,
    pg_catalog.pg_settings
TO edb_monitor_ro;

-- Custom views/materialized views referenced by script
GRANT SELECT ON
    valdezha.mv_largest_tab,
    valdezha.mv_largest_idx,
    valdezha.mv_tab_bloat,
    valdezha.mv_idx_bloat
TO n8n_dbmonitor;

-- ==========================================================================
-- 4) Optional hardening
-- ===========================================================================
-- Keep this account read-only at SQL level.
ALTER ROLE n8n_dbmonitor NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;

-- ==========================================================================
-- 5) Validation checks
-- ===========================================================================
-- Run these as n8n_dbmonitor to verify expected access.
-- SELECT 1;
-- SELECT count(*) FROM pg_stat_activity;
-- SELECT * FROM valdezha.mv_largest_tab LIMIT 1;
-- SELECT * FROM valdezha.mv_tab_bloat LIMIT 1;

-- NOTE:
-- Some pg_stat_activity columns (especially full query text for other sessions)
-- may still be restricted depending on server settings/version permissions.
-- If you need full cross-session visibility without superuser, create
-- SECURITY DEFINER views owned by a privileged role and grant SELECT on them.
