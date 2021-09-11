CREATE TABLE IF NOT EXISTS GREST.ACTIVE_STAKE_CACHE (
    POOL_ID varchar NOT NULL,
    EPOCH_NO bigint NOT NULL,
    AMOUNT LOVELACE NOT NULL,
    PRIMARY KEY (POOL_ID, EPOCH_NO)
);

INSERT INTO GREST.ACTIVE_STAKE_CACHE
SELECT
    POOL_HASH.VIEW,
    EPOCH_STAKE.EPOCH_NO,
    SUM(EPOCH_STAKE.AMOUNT)
FROM
    EPOCH_STAKE
    INNER JOIN POOL_HASH ON POOL_HASH.ID = EPOCH_STAKE.POOL_ID
GROUP BY
    POOL_HASH.VIEW,
    EPOCH_STAKE.EPOCH_NO;

-- Trigger for inserting new epoch active stake data
DROP FUNCTION IF EXISTS GREST.ACTIVE_STAKE_EPOCH_UPDATE CASCADE;

CREATE FUNCTION GREST.ACTIVE_STAKE_EPOCH_UPDATE ()
    RETURNS TRIGGER
    AS $active_stake_epoch_update$
DECLARE
    _current_epoch integer DEFAULT NULL;
BEGIN
    SELECT
        MAX(epoch_no)
    FROM
        public.epoch_stake INTO _current_epoch;
    INSERT INTO grest.ACTIVE_STAKE_CACHE
    SELECT
        POOL_HASH.VIEW,
        EPOCH_STAKE.EPOCH_NO,
        SUM(EPOCH_STAKE.AMOUNT)
    FROM
        EPOCH_STAKE
        INNER JOIN POOL_HASH ON POOL_HASH.ID = EPOCH_STAKE.POOL_ID
    WHERE
        epoch_stake.epoch_no = _current_epoch
    GROUP BY
        POOL_HASH.VIEW,
        EPOCH_STAKE.EPOCH_NO
        -- At the moment, epoch_stake gets inserts in chunks of 2000 and there is
        -- no way to figure out whether a given chunk is the last one. This means
        -- that we have to run the function on every chunk so the conflict clause
        -- below is skipping inserts that we already processed.
        -- This conflict clause should be removed once db-syncs has an event for
        -- epoch_stake inserts completion. Then, the trigger can be switched
        -- to be based on that event and ran only once for each new epoch.
        -- Linked issue: https://github.com/input-output-hk/cardano-db-sync/issues/797
    ON CONFLICT (POOL_ID,
        EPOCH_NO)
        DO NOTHING;
    RETURN NULL;
END;
$active_stake_epoch_update$
LANGUAGE PLPGSQL;

DROP TRIGGER IF EXISTS ACTIVE_STAKE_EPOCH_UPDATE_TRIGGER ON PUBLIC.EPOCH_STAKE;

CREATE TRIGGER ACTIVE_STAKE_EPOCH_UPDATE_TRIGGER
    AFTER INSERT ON PUBLIC.EPOCH_STAKE
    FOR EACH STATEMENT
    EXECUTE FUNCTION GREST.ACTIVE_STAKE_EPOCH_UPDATE ();

