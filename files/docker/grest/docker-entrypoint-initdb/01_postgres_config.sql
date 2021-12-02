ALTER SYSTEM
SET checkpoint_timeout = '5min';
ALTER SYSTEM
SET max_segment_size = '1GB';
ALTER SYSTEM
SET max_wal_size = '2GB';
ALTER SYSTEM
SET min_wal_size = '300MB';
ALTER SYSTEM shared_preload_libraries = 'pglogical';
ALTER SYSTEM
SET wal_level = 'logical';
ALTER SYSTEM
SET max_wal_senders = 1;
ALTER SYSTEM
SET max_worker_processes = 10;
ALTER SYSTEM
SET max_replication_slots = 10;
CREATE EXTENSION pglogical;
SELECT pglogical.create_node(
        node_name := 'provider1',
        dsn := 'host=providerhost port=5432 dbname=cexplorer'
    );