ALTER SYSTEM
SET checkpoint_timeout = '5min';
<<<<<<< HEAD
=======
--ALTER SYSTEM
--SET max_segment_size = '1GB';
--ALTER SYSTEM
--SET max_wal_size = '2GB';
>>>>>>> 20151489b0062bea377c07b46444c2479c09671e
ALTER SYSTEM
SET min_wal_size = '300MB';
ALTER SYSTEM
SET wal_level = 'logical';
ALTER SYSTEM
SET max_wal_senders = 1;
ALTER SYSTEM
SET max_worker_processes = 10;
ALTER SYSTEM
SET max_replication_slots = 10;
CREATE EXTENSION pglogical;
<<<<<<< HEAD
=======
SELECT pglogical.create_node(
        node_name := 'provider1',
        dsn := 'host=providerhost port=5432 dbname=cexplorer'
    );
>>>>>>> 20151489b0062bea377c07b46444c2479c09671e
