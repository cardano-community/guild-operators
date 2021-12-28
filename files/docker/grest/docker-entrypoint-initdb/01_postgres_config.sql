ALTER SYSTEM
SET checkpoint_timeout = '15min';
ALTER SYSTEM
SET synchronous_commit = 'off';
ALTER SYSTEM
SET wal_writer_delay = '800ms';
ALTER SYSTEM
SET max_segment_size = '64MB';
ALTER SYSTEM
SET max_wal_size = '14GB';
ALTER SYSTEM
SET min_wal_size = '600MB';
ALTER SYSTEM
SET wal_level = 'minimal';
