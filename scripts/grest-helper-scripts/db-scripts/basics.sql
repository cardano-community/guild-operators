--------------------------------------------------------------------------------
-- Entry point for Koios node DB setup:
-- 1) grest schema that will hold all RPC functions/views and cached tables
-- 2) web_anon user setup
--------------------------------------------------------------------------------
SET client_min_messages TO WARNING;

BEGIN;

DO $$
BEGIN
  CREATE ROLE web_anon nologin;
EXCEPTION
  WHEN DUPLICATE_OBJECT THEN
    RAISE NOTICE 'web_anon exists, skipping...';
END
$$;

CREATE SCHEMA IF NOT EXISTS grest;

GRANT USAGE ON SCHEMA public TO web_anon;

GRANT USAGE ON SCHEMA grest TO web_anon;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;

GRANT SELECT ON ALL TABLES IN SCHEMA grest TO web_anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT
SELECT
  ON TABLES TO web_anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA grest GRANT
SELECT
  ON TABLES TO web_anon;

ALTER ROLE web_anon SET search_path TO grest, public;

-- Most likely deprecated after 12.0.0
CREATE INDEX IF NOT EXISTS _asset_policy_idx ON PUBLIC.MA_TX_OUT ( policy);

CREATE INDEX IF NOT EXISTS _asset_identifier_idx ON PUBLIC.MA_TX_OUT ( policy, name);

