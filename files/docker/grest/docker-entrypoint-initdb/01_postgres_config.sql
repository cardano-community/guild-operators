ALTER SYSTEM
SET max_wal_senders = 0;
ALTER SYSTEM
SET wal_level = minimal;
ALTER SYSTEM
SET synchronous_commit = off;