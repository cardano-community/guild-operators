CREATE TABLE IF NOT EXISTS GREST.STAKE_DISTRIBUTION (
    STAKE_ADDRESS varchar,
    POOL_ID varchar,
    TOTAL_BALANCE numeric,
    UTXO numeric,
    REWARDS numeric,
    WITHDRAWALS numeric,
    REWARDS_AVAILABLE numeric,
    RESERVES numeric,
    TREASURY numeric,
    PRIMARY KEY (STAKE_ADDRESS)
);

INSERT INTO GREST.STAKE_DISTRIBUTION
SELECT
    STAKE_ADDRESS,
    POOL_ID,
    CASE WHEN (COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0)) <= 0 THEN
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
            COALESCE(SUM(VALUE), 0) AS UTXO
        FROM
            TX_OUT
            INNER JOIN TX ON TX_OUT.TX_ID = TX.ID
                AND TX_OUT.STAKE_ADDRESS_ID = T1.ID
                AND TX.BLOCK_ID < (
                    SELECT
                        MAX(ID)
                    FROM
                        BLOCK) - 5
                INNER JOIN TX_IN ON TX_OUT.TX_ID = TX_IN.TX_OUT_ID
                    AND TX_OUT.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
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
        UTXO = EXCLUDED.UTXO,
        REWARDS = EXCLUDED.REWARDS,
        WITHDRAWALS = EXCLUDED.WITHDRAWALS,
        REWARDS_AVAILABLE = EXCLUDED.REWARDS_AVAILABLE,
        RESERVES = EXCLUDED.RESERVES,
        TREASURY = EXCLUDED.TREASURY
    WHERE
        STAKE_DISTRIBUTION.POOL_ID IS DISTINCT FROM EXCLUDED.POOL_ID
        OR STAKE_DISTRIBUTION.UTXO IS DISTINCT FROM EXCLUDED.UTXO
        OR STAKE_DISTRIBUTION.REWARDS IS DISTINCT FROM EXCLUDED.REWARDS
        OR STAKE_DISTRIBUTION.WITHDRAWALS IS DISTINCT FROM EXCLUDED.WITHDRAWALS
        OR STAKE_DISTRIBUTION.REWARDS_AVAILABLE IS DISTINCT FROM EXCLUDED.REWARDS_AVAILABLE
        OR STAKE_DISTRIBUTION.RESERVES IS DISTINCT FROM EXCLUDED.RESERVES
        OR STAKE_DISTRIBUTION.TREASURY IS DISTINCT FROM EXCLUDED.TREASURY;

