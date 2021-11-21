-- show running queries (9.2)
SELECT
  pid,
  AGE(CLOCK_TIMESTAMP(), query_start),
  usename,
  query
FROM
  pg_stat_activity
WHERE
  query != '<IDLE>'
  AND query NOT ILIKE '%pg_stat_activity%'
ORDER BY
  query_start desc;

-- kill running query
SELECT
  PG_CANCEL_BACKEND(procpid);

-- kill running queries based on filters
SELECT
  PG_CANCEL_BACKEND(
    SELECT
      pid FROM pg_stat_activity
    WHERE
      query ILIKE '%GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK(%');

-- kill idle query
SELECT
  PG_TERMINATE_BACKEND(procpid);

-- vacuum command
VACUUM (VERBOSE,
  ANALYZE);

-- all database users
select
  *
from
  pg_stat_activity
where
  current_query not like '<%';

-- all databases and their sizes
select
  *
from
  pg_user;

-- all tables and their size, with/without indexes
select
  datname,
  PG_SIZE_PRETTY(PG_DATABASE_SIZE(datname))
from
  pg_database
order by
  PG_DATABASE_SIZE(datname) desc;

-- cache hit rates (should not be less than 0.99)
SELECT
  SUM(heap_blks_read) as heap_read,
  SUM(heap_blks_hit) as heap_hit,
  (SUM(heap_blks_hit) - SUM(heap_blks_read)) / SUM(heap_blks_hit) as ratio
FROM
  pg_statio_user_tables;

-- table index usage rates (should not be less than 0.99)
SELECT
  relname,
  100 * idx_scan / (seq_scan + idx_scan) percent_of_times_index_used,
  n_live_tup rows_in_table
FROM
  pg_stat_user_tables
ORDER BY
  n_live_tup DESC;

-- how many indexes are in cache
SELECT
  SUM(idx_blks_read) as idx_read,
  SUM(idx_blks_hit) as idx_hit,
  (SUM(idx_blks_hit) - SUM(idx_blks_read)) / SUM(idx_blks_hit) as ratio
FROM
  pg_statio_user_indexes;

-- Dump database on remote host to file
$ pg_dump - U username - h hostname databasename > dump.sql
-- Import dump into existing database
$ psql - d newdb - f dump.sql
SELECT
  'DROP TRIGGER ' || trigger_name || ' ON ' || event_object_table || ';'
FROM
  information_schema.triggers
WHERE
  trigger_schema = 'public';

