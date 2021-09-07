CREATE TABLE IF NOT EXISTS GREST.STAKE_DISTRIBUTION_CACHE (
    STAKE_ADDRESS varchar PRIMARY KEY,
    POOL_ID varchar, -- Index added after data is inserted
    TOTAL_BALANCE numeric,
    UTXO numeric,
    REWARDS numeric,
    WITHDRAWALS numeric,
    REWARDS_AVAILABLE numeric,
    RESERVES numeric,
    TREASURY numeric
);

CREATE TABLE IF NOT EXISTS GREST.CONTROL_TABLE (
    key text PRIMARY KEY,
    last_value text NOT NULL,
    artifacts text
);

DROP FUNCTION IF EXISTS GREST.UPDATE_STAKE_DISTRIBUTION_CACHE ();

CREATE FUNCTION GREST.UPDATE_STAKE_DISTRIBUTION_CACHE ()
    RETURNS VOID
    LANGUAGE PLPGSQL
    AS $$
DECLARE
    -- Last block height to control future re-runs of the query
    _last_accounted_block_height bigint;
BEGIN
    SELECT
        MAX(BLOCK_NO) - 5
    FROM
        PUBLIC.BLOCK
    WHERE
        block_no IS NOT NULL INTO _last_accounted_block_height;
    INSERT INTO GREST.STAKE_DISTRIBUTION_CACHE
    SELECT
        STAKE_ADDRESS,
        POOL_ID,
        CASE WHEN (COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0)) < 0 THEN
            COALESCE(UTXO_T.UTXO, 0) + COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0) + COALESCE(RESERVES_T.RESERVES, 0) + COALESCE(TREASURY_T.TREASURY, 0) - (COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0))
        ELSE
            COALESCE(UTXO_T.UTXO, 0) + COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0) + COALESCE(RESERVES_T.RESERVES, 0) + COALESCE(TREASURY_T.TREASURY, 0)
        END AS TOTAL_BALANCE,
        COALESCE(UTXO_T.UTXO, 0) AS UTXO,
        COALESCE(REWARDS_T.REWARDS, 0) AS REWARDS,
        COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0) AS WITHDRAWALS,
        CASE WHEN (COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0)) <= 0 THEN
            0
        ELSE
            COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0)
        END AS REWARDS_AVAILABLE,
        COALESCE(RESERVES_T.RESERVES, 0) AS RESERVES,
        COALESCE(TREASURY_T.TREASURY, 0) AS TREASURY
    FROM (
        SELECT
            STAKE_ADDRESS.ID,
            STAKE_ADDRESS.VIEW AS STAKE_ADDRESS,
            POOL_HASH.VIEW AS POOL_ID
        FROM
            STAKE_ADDRESS
            INNER JOIN DELEGATION ON DELEGATION.ADDR_ID = STAKE_ADDRESS.ID
            INNER JOIN POOL_HASH ON POOL_HASH.ID = DELEGATION.POOL_HASH_ID
        WHERE
            NOT EXISTS (
                SELECT
                    TRUE
                FROM
                    DELEGATION D
                WHERE
                    D.ADDR_ID = DELEGATION.ADDR_ID
                    AND D.ID > DELEGATION.ID)
                AND NOT EXISTS (
                    SELECT
                        TRUE
                    FROM
                        STAKE_DEREGISTRATION
                    WHERE
                        STAKE_DEREGISTRATION.ADDR_ID = DELEGATION.ADDR_ID
                        AND STAKE_DEREGISTRATION.TX_ID > DELEGATION.TX_ID)) T1
    LEFT JOIN LATERAL (
        SELECT
            COALESCE(SUM(TX_OUT.VALUE), 0) AS UTXO
        FROM
            TX_OUT
            INNER JOIN TX ON TX_OUT.TX_ID = TX.ID
                AND TX_OUT.STAKE_ADDRESS_ID = T1.ID
        LEFT JOIN TX_IN ON TX_OUT.TX_ID = TX_IN.TX_OUT_ID
            AND TX_OUT.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
    WHERE
        TX.BLOCK_ID <= _last_accounted_block_height
        AND TX_IN.TX_IN_ID IS NULL) UTXO_T ON TRUE
    LEFT JOIN LATERAL (
        SELECT
            COALESCE(SUM(REWARD.AMOUNT), 0) AS REWARDS
        FROM
            REWARD
        WHERE
            REWARD.ADDR_ID = T1.ID
            AND REWARD.SPENDABLE_EPOCH <= (
                SELECT
                    MAX(NO)
                FROM
                    EPOCH)
            GROUP BY
                T1.ID) REWARDS_T ON TRUE
    LEFT JOIN LATERAL (
        SELECT
            COALESCE(SUM(WITHDRAWAL.AMOUNT), 0) AS WITHDRAWALS
        FROM
            WITHDRAWAL
        WHERE
            WITHDRAWAL.ADDR_ID = T1.ID
        GROUP BY
            T1.ID) WITHDRAWALS_T ON TRUE
    LEFT JOIN LATERAL (
        SELECT
            COALESCE(SUM(RESERVE.AMOUNT), 0) AS RESERVES
        FROM
            RESERVE
        WHERE
            RESERVE.ADDR_ID = T1.ID
        GROUP BY
            T1.ID) RESERVES_T ON TRUE
    LEFT JOIN LATERAL (
        SELECT
            COALESCE(SUM(TREASURY.AMOUNT), 0) AS TREASURY
        FROM
            TREASURY
        WHERE
            TREASURY.ADDR_ID = T1.ID
        GROUP BY
            T1.ID) TREASURY_T ON TRUE
ON CONFLICT (STAKE_ADDRESS)
    DO UPDATE SET
        POOL_ID = EXCLUDED.POOL_ID,
        TOTAL_BALANCE = EXCLUDED.TOTAL_BALANCE,
        UTXO = EXCLUDED.UTXO,
        REWARDS = EXCLUDED.REWARDS,
        WITHDRAWALS = EXCLUDED.WITHDRAWALS,
        REWARDS_AVAILABLE = EXCLUDED.REWARDS_AVAILABLE,
        RESERVES = EXCLUDED.RESERVES,
        TREASURY = EXCLUDED.TREASURY
    WHERE
        STAKE_DISTRIBUTION_CACHE.POOL_ID IS DISTINCT FROM EXCLUDED.POOL_ID
        OR STAKE_DISTRIBUTION_CACHE.TOTAL_BALANCE IS DISTINCT FROM EXCLUDED.TOTAL_BALANCE
        OR STAKE_DISTRIBUTION_CACHE.UTXO IS DISTINCT FROM EXCLUDED.UTXO
        OR STAKE_DISTRIBUTION_CACHE.REWARDS IS DISTINCT FROM EXCLUDED.REWARDS
        OR STAKE_DISTRIBUTION_CACHE.WITHDRAWALS IS DISTINCT FROM EXCLUDED.WITHDRAWALS
        OR STAKE_DISTRIBUTION_CACHE.REWARDS_AVAILABLE IS DISTINCT FROM EXCLUDED.REWARDS_AVAILABLE
        OR STAKE_DISTRIBUTION_CACHE.RESERVES IS DISTINCT FROM EXCLUDED.RESERVES
        OR STAKE_DISTRIBUTION_CACHE.TREASURY IS DISTINCT FROM EXCLUDED.TREASURY;
    -- Store last block height in the control table
    INSERT INTO GREST.CONTROL_TABLE (key, last_value)
        VALUES ('stake_distribution_lbh', _last_accounted_block_height)
    ON CONFLICT (key)
        DO UPDATE SET
            last_value = _last_accounted_block_height;
END;
$$;

-- Run the first time update
SELECT
    GREST.UPDATE_STAKE_DISTRIBUTION_CACHE ();

CREATE INDEX IF NOT EXISTS idx_pool_id ON GREST.STAKE_DISTRIBUTION_CACHE (POOL_ID);

-- Create trigger for re-running the query every 90 blocks (30 mins theoretical time)
DROP FUNCTION IF EXISTS GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK CASCADE;

CREATE FUNCTION GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK ()
    RETURNS TRIGGER
    AS $UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK$
DECLARE
    _last_update_block_height integer DEFAULT NULL;
    _current_block_height integer DEFAULT NULL;
BEGIN
    SELECT
        last_value
    FROM
        GREST.control_table
    WHERE
        key = 'stake_distribution_lbh' INTO _last_update_block_height;
    SELECT
        MAX(block_no)
    FROM
        PUBLIC.BLOCK
    WHERE
        BLOCK_NO IS NOT NULL INTO _current_block_height;
    -- Do nothing until there is a 90 blocks difference in height
    IF (_current_block_height - _last_update_block_height < 90) THEN
        RETURN NULL;
    ELSE
        SELECT
            GREST.UPDATE_STAKE_DISTRIBUTION_CACHE ();
        RETURN NEW;
    END IF;
END;
$UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK$
LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_stake_distribution_cache_trigger ON public.block;

CREATE TRIGGER update_stake_distribution_cache_trigger
    AFTER INSERT ON public.block
    FOR EACH STATEMENT
    EXECUTE PROCEDURE GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK ();

