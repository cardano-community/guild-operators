--------------------------------------------------------------------------------
-- Entry point for Koios node DB setup:
-- 1) grest schema that will hold all RPC functions/views and cached tables
-- 2) web_anon user
-- 3) grest.control_table
-- 4) grest.genesis
-- 5) helper functions
-- 6) optional db indexes on important public tables
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

-- HELPER FUNCTIONS --
DROP FUNCTION IF EXISTS grest.get_query_pids_partial_match (_query text);

CREATE FUNCTION grest.get_query_pids_partial_match (_query text)
  RETURNS TABLE (
    pid integer)
  LANGUAGE plpgsql
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    pg_stat_activity.pid
  FROM
    pg_stat_activity
  WHERE
    query ILIKE '%' || _query || '%'
    AND query NOT ILIKE '%grest.get_query_pids_partial_match%'
    AND datname = (SELECT current_database());
END;
$$;

-- Not really fully tested nor working yet, but in case we'll need something like this for the future.
/* DROP PROCEDURE IF EXISTS grest.kill_queries_partial_match (_query text);

CREATE PROCEDURE grest.kill_queries_partial_match (_query text)
LANGUAGE plpgsql
AS $$
DECLARE
 _pids integer[];
BEGIN
 _pids := ARRAY (
 SELECT
 grest.get_query_pids_partial_match (_query));
 FOR i IN 1..ARRAY_UPPER(_pids, 1)
 LOOP
 RAISE NOTICE 'Cancelling PID: %', _pids[i];
 PERFORM
 PG_CANCEL_BACKEND(_pids[i]);
 END LOOP;
END;
$$; */

DROP FUNCTION IF EXISTS grest.get_current_epoch ();

CREATE FUNCTION grest.get_current_epoch ()
  RETURNS integer
  LANGUAGE plpgsql
  AS 
$$
  BEGIN
    RETURN (
      SELECT MAX(no) FROM public.epoch
    );
  END;
$$;

DROP FUNCTION IF EXISTS grest.get_epoch_stakes_count (integer);

CREATE FUNCTION grest.get_epoch_stakes_count (_epoch_no integer)
  RETURNS integer
  LANGUAGE plpgsql
  AS
$$
  BEGIN
    RETURN (
      SELECT count(*)
        FROM public.epoch_stake
        WHERE epoch_no = _epoch_no
        GROUP BY epoch_no
    );
  END;
$$;

DROP FUNCTION IF EXISTS grest.update_control_table (text, text, text);

CREATE FUNCTION grest.update_control_table (_key text, _last_value text, _artifacts text default null)
  RETURNS void
  LANGUAGE plpgsql
  AS
$$
  BEGIN
    INSERT INTO
      GREST.CONTROL_TABLE (key, last_value, artifacts)
    VALUES
      (_key, _last_value, _artifacts)
    ON CONFLICT (
      key
    ) DO UPDATE
      SET last_value = _last_value;
  END;
$$;

-- DATABASE INDEXES --
