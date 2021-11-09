-- Still need a way to reset even the public schema because of triggers
DROP SCHEMA IF EXISTS grest;

CREATE SCHEMA grest;

GRANT USAGE ON SCHEMA grest TO web_anon;

GRANT SELECT ON ALL TABLES IN SCHEMA grest TO web_anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA grest GRANT
SELECT
  ON TABLES TO web_anon;

