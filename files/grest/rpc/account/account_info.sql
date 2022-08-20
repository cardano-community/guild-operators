CREATE FUNCTION grest.account_info (_stake_addresses text[])
  RETURNS TABLE (
    stake_address varchar,
    STATUS text,
    DELEGATED_POOL varchar,
    TOTAL_BALANCE text,
    UTXO text,
    REWARDS text,
    WITHDRAWALS text,
    REWARDS_AVAILABLE text,
    RESERVES text,
    TREASURY text)
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  sa_id_list integer[] DEFAULT NULL;
BEGIN
  SELECT INTO sa_id_list
    array_agg(ID)
  FROM
    STAKE_ADDRESS
  WHERE
    STAKE_ADDRESS.VIEW = ANY(_stake_addresses);

  RETURN QUERY
    WITH latest_withdrawal_txs AS (
      SELECT DISTINCT ON (addr_id)
        addr_id,
        tx_id
      FROM WITHDRAWAL
      WHERE ADDR_ID = ANY(sa_id_list)
      ORDER BY addr_id, TX_ID DESC
    ),
    latest_withdrawal_epochs AS (
      SELECT
        lwt.addr_id,
        b.epoch_no
      FROM BLOCK b
        INNER JOIN TX ON TX.BLOCK_ID = b.ID
        INNER JOIN latest_withdrawal_txs lwt ON tx.id = lwt.tx_id
    )

    SELECT
      STATUS_T.view as stake_address,
      CASE WHEN STATUS_T.REGISTERED = TRUE THEN
        'registered'
      ELSE
        'not registered'
      END AS STATUS,
      POOL_T.DELEGATED_POOL,
      CASE WHEN (COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0)) < 0 THEN
        (COALESCE(UTXO_T.UTXO, 0) + COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0) + COALESCE(RESERVES_T.RESERVES, 0) + COALESCE(TREASURY_T.TREASURY, 0) - (COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0)))::text
      ELSE
        (COALESCE(UTXO_T.UTXO, 0) + COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0) + COALESCE(RESERVES_T.RESERVES, 0) + COALESCE(TREASURY_T.TREASURY, 0))::text
      END AS TOTAL_BALANCE,
      COALESCE(UTXO_T.UTXO, 0)::text AS UTXO,
      COALESCE(REWARDS_T.REWARDS, 0)::text AS REWARDS,
      COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0)::text AS WITHDRAWALS,
      CASE WHEN (COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0)) <= 0 THEN
        '0'
      ELSE
        (COALESCE(REWARDS_T.REWARDS, 0) - COALESCE(WITHDRAWALS_T.WITHDRAWALS, 0))::text
      END AS REWARDS_AVAILABLE,
      COALESCE(RESERVES_T.RESERVES, 0)::text AS RESERVES,
      COALESCE(TREASURY_T.TREASURY, 0)::text AS TREASURY
    FROM 
      (
        SELECT
          sas.id,
          sas.view,
          EXISTS (
            SELECT TRUE FROM STAKE_REGISTRATION
            WHERE
              STAKE_REGISTRATION.ADDR_ID = sas.id
              AND NOT EXISTS (
                SELECT TRUE
                FROM STAKE_DEREGISTRATION
                WHERE
                  STAKE_DEREGISTRATION.ADDR_ID = STAKE_REGISTRATION.ADDR_ID
                  AND STAKE_DEREGISTRATION.TX_ID > STAKE_REGISTRATION.TX_ID
              )
          ) AS REGISTERED
        FROM public.stake_address sas
        WHERE sas.id = ANY(sa_id_list)
      ) STATUS_T
      LEFT JOIN (
        SELECT
          delegation.addr_id,
          POOL_HASH.VIEW AS DELEGATED_POOL
        FROM
          DELEGATION
          INNER JOIN POOL_HASH ON POOL_HASH.ID = DELEGATION.POOL_HASH_ID
        WHERE
          DELEGATION.ADDR_ID = ANY(sa_id_list)
          AND NOT EXISTS (
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
                AND STAKE_DEREGISTRATION.TX_ID > DELEGATION.TX_ID)
      ) POOL_T ON POOL_T.addr_id = status_t.id
      LEFT JOIN (
        SELECT
          TX_OUT.STAKE_ADDRESS_ID,
          COALESCE(SUM(VALUE), 0) AS UTXO
        FROM
          TX_OUT
          LEFT JOIN TX_IN ON TX_OUT.TX_ID = TX_IN.TX_OUT_ID
            AND TX_OUT.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
        WHERE
          TX_OUT.STAKE_ADDRESS_ID = ANY(sa_id_list)
          AND TX_IN.TX_IN_ID IS NULL
        GROUP BY
          tx_out.stake_address_id
      ) UTXO_T ON UTXO_T.stake_address_id = status_t.id
      LEFT JOIN (
        SELECT
          REWARD.ADDR_ID,
          COALESCE(SUM(REWARD.AMOUNT), 0) AS REWARDS
        FROM
          REWARD
        WHERE
          REWARD.ADDR_ID = ANY(sa_id_list)
          AND REWARD.SPENDABLE_EPOCH <= (
            SELECT MAX(NO)
            FROM EPOCH
          )
        GROUP BY
          REWARD.ADDR_ID
      ) REWARDS_T ON REWARDS_T.addr_id = status_t.id
      LEFT JOIN (
        SELECT
          WITHDRAWAL.ADDR_ID,
          COALESCE(SUM(WITHDRAWAL.AMOUNT), 0) AS WITHDRAWALS
        FROM
          WITHDRAWAL
        WHERE
          WITHDRAWAL.ADDR_ID = ANY(sa_id_list)
        GROUP BY
          WITHDRAWAL.ADDR_ID
      ) WITHDRAWALS_T ON WITHDRAWALS_T.addr_id = status_t.id
      LEFT JOIN (
        SELECT
          RESERVE.ADDR_ID,
          COALESCE(SUM(RESERVE.AMOUNT), 0) AS RESERVES
        FROM
          RESERVE
          INNER JOIN TX ON TX.ID = RESERVE.TX_ID
          INNER JOIN BLOCK ON BLOCK.ID = TX.BLOCK_ID
          INNER JOIN latest_withdrawal_epochs lwe ON lwe.addr_id = reserve.addr_id
        WHERE
          RESERVE.ADDR_ID = ANY(sa_id_list)
          AND BLOCK.EPOCH_NO >= lwe.epoch_no
        GROUP BY
          RESERVE.ADDR_ID
      ) RESERVES_T ON RESERVES_T.addr_id = status_t.id
      LEFT JOIN (
        SELECT
          TREASURY.ADDR_ID,
          COALESCE(SUM(TREASURY.AMOUNT), 0) AS TREASURY
        FROM
          TREASURY
          INNER JOIN TX ON TX.ID = TREASURY.TX_ID
          INNER JOIN BLOCK ON BLOCK.ID = TX.BLOCK_ID
          INNER JOIN latest_withdrawal_epochs lwe ON lwe.addr_id = TREASURY.addr_id
        WHERE
          TREASURY.ADDR_ID = ANY(sa_id_list)
          AND BLOCK.EPOCH_NO >= lwe.epoch_no
        GROUP BY
          TREASURY.ADDR_ID
      ) TREASURY_T ON TREASURY_T.addr_id = status_t.id;
END;
$$;

COMMENT ON FUNCTION grest.account_info IS 'Get the account info for given stake addresses';

