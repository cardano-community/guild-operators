CREATE TABLE IF NOT EXISTS GREST.ACTIVE_STAKE_CACHE (
    POOL_ID varchar, -- Index created after initial data insert
    EPOCH_NO bigint,
    AMOUNT lovelace
);

INSERT INTO GREST.ACTIVE_STAKE_CACHE
SELECT
    POOL_HASH.VIEW,
    SUM(EPOCH_STAKE.AMOUNT),
    EPOCH_STAKE.EPOCH_NO
FROM
    EPOCH_STAKE
    INNER JOIN POOL_HASH ON POOL_HASH.ID = EPOCH_STAKE.POOL_ID
GROUP BY
    POOL_HASH.VIEW,
    EPOCH_STAKE.EPOCH_NO;

CREATE INDEX IF NOT EXISTS pool_id_idx ON GREST.ACTIVE_STAKE_CACHE (pool_id);

-- TODO: current_epoch + 1 entries (needs to be manually calculated via delegation table)
