DO
$do$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles WHERE  rolname = 'web_anon') THEN
  CREATE ROLE web_anon nologin;
  GRANT USAGE on schema public to web_anon;
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO web_anon;
    END IF;
END
$do$;

CREATE SCHEMA IF NOT EXISTS koios;
GRANT USAGE ON SCHEMA public TO web_anon;
GRANT USAGE ON SCHEMA koios TO web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA koios TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA koios GRANT SELECT ON TABLES TO web_anon;
ALTER ROLE web_anon SET search_path TO koios, public;



