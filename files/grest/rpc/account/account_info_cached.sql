CREATE OR REPLACE FUNCTION grest.account_info_cached (_stake_addresses text[])
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
      sdc.stake_address,
      CASE  WHEN STATUS_T.REGISTERED = TRUE THEN
        'registered'
      ELSE
        'not registered'
      END AS status,
      sdc.pool_id as pool_id,
      sdc.total_balance::text,
      sdc.utxo::text,
      sdc.rewards::text,
      sdc.withdrawals::text,
      sdc.rewards_available::text,
      COALESCE(RESERVES_T.RESERVES, 0)::text AS RESERVES,
      COALESCE(TREASURY_T.TREASURY, 0)::text AS TREASURY
    FROM
      grest.stake_distribution_cache sdc
      LEFT JOIN (
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
        ) STATUS_T ON sdc.stake_address = STATUS_T.view
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
      ) TREASURY_T ON TREASURY_T.addr_id = status_t.id
    WHERE sdc.stake_address = ANY(_stake_addresses);
END;
$$;

COMMENT ON FUNCTION grest.account_info IS 'Get the cached account information for given stake addresses';
