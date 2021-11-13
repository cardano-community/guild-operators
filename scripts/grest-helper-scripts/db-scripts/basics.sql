--------------------------------------------------------------------------------
-- Entry point for Koios node DB setup:
-- 1) grest schema that will hold all RPC functions/views and cached tables
-- 2) web_anon user
-- 3) grest.control_table
-- 4) grest.genesis
-- 5) optional db indexes on important public tables
--------------------------------------------------------------------------------
-- GREST SCHEMA --
CREATE SCHEMA IF NOT EXISTS grest;

-- WEB_ANON USER --
DO $$
BEGIN
  CREATE ROLE web_anon nologin;
EXCEPTION
  WHEN DUPLICATE_OBJECT THEN
    RAISE NOTICE 'web_anon exists, skipping...';
END
$$;

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

-- CONTROL TABLE --
CREATE TABLE IF NOT EXISTS GREST.CONTROL_TABLE (
  key text PRIMARY KEY,
  last_value text NOT NULL,
  artifacts text
);

-- GENESIS TABLE --
DROP TABLE IF EXISTS grest.genesis;

-- Data Types are intentionally kept varchar for single ID row to avoid future edge cases
CREATE TABLE grest.genesis (
  NETWORKMAGIC varchar,
  NETWORKID varchar,
  ACTIVESLOTCOEFF varchar,
  UPDATEQUORUM varchar,
  MAXLOVELACESUPPLY varchar,
  EPOCHLENGTH varchar,
  SYSTEMSTART varchar,
  SLOTSPERKESPERIOD varchar,
  SLOTLENGTH varchar,
  MAXKESREVOLUTIONS varchar,
  SECURITYPARAM varchar,
  ALONZOGENESIS varchar
);

-- Most likely deprecated after 12.0.0
CREATE INDEX IF NOT EXISTS _asset_policy_idx ON PUBLIC.MA_TX_OUT ( policy);

CREATE INDEX IF NOT EXISTS _asset_identifier_idx ON PUBLIC.MA_TX_OUT ( policy, name);

