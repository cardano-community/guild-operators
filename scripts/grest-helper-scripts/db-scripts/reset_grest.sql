-- Drop triggers first that depend on grest.functions()
SELECT
  'DROP TRIGGER ' || trigger_name || ' ON ' || event_object_table || ';'
FROM
  information_schema.triggers
WHERE
  trigger_schema = 'public';


-- Recreate grest schema
DROP SCHEMA IF EXISTS grest;

CREATE SCHEMA grest;

GRANT USAGE ON SCHEMA grest TO web_anon;

GRANT SELECT ON ALL TABLES IN SCHEMA grest TO web_anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA grest GRANT
SELECT
  ON TABLES TO web_anon;

