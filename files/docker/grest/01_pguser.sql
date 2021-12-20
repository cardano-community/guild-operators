DO
$do$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles WHERE  rolname = 'guild') THEN
  CREATE ROLE guild superuser login;
  ALTER user guild password 'P4r4b0l4!!';
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO guild;
  CREATE DATABASE guild WITH OWNER guild;
    END IF;
END
$do$;
