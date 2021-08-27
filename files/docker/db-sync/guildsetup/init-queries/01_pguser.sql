DO
$do$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles WHERE  rolname = 'guild') THEN
  CREATE ROLE guild superuser login;
  ALTER user guild password 'HelloWorld54321';
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO guild;
    END IF;
END
$do$;
