CREATE OR REPLACE PROCEDURE GREST.UPDATE_NEWLY_REGISTERED_ACCOUNTS_STAKE_DISTRIBUTION_CACHE()
LANGUAGE PLPGSQL AS
$$
BEGIN
  WITH
    newly_registered_accounts AS (
      SELECT DISTINCT ON (STAKE_ADDRESS.ID)
        stake_address.id as stake_address_id,
        stake_address.view as stake_address,
        pool_hash_id
      FROM STAKE_ADDRESS
        INNER JOIN DELEGATION ON DELEGATION.ADDR_ID = STAKE_ADDRESS.ID
        WHERE
          NOT EXISTS (
            SELECT TRUE FROM DELEGATION D
              WHERE D.ADDR_ID = DELEGATION.ADDR_ID AND D.ID > DELEGATION.ID
          )
          AND NOT EXISTS (
            SELECT TRUE FROM STAKE_DEREGISTRATION
              WHERE STAKE_DEREGISTRATION.ADDR_ID = DELEGATION.ADDR_ID
                AND STAKE_DEREGISTRATION.TX_ID > DELEGATION.TX_ID
          )
          AND NOT EXISTS (
            SELECT TRUE FROM EPOCH_STAKE
              WHERE EPOCH_STAKE.EPOCH_NO = (
                SELECT last_value::integer FROM GREST.CONTROL_TABLE
                  WHERE key = 'last_active_stake_validated_epoch'
                )
                AND EPOCH_STAKE.ADDR_ID = STAKE_ADDRESS.ID
          )
    )
  -- INSERT QUERY START
  INSERT INTO GREST.STAKE_DISTRIBUTION_CACHE
    SELECT
      nra.stake_address,
      ai.delegated_pool as pool_id,
      ai.total_balance::lovelace,
      ai.utxo::lovelace,
      ai.rewards::lovelace,
      ai.withdrawals::lovelace,
      ai.rewards_available::lovelace
    FROM newly_registered_accounts nra,
      LATERAL grest.account_info(nra.stake_address) ai
    ON CONFLICT (STAKE_ADDRESS) DO
      UPDATE
        SET
          POOL_ID = EXCLUDED.POOL_ID,
          TOTAL_BALANCE = EXCLUDED.total_balance,
          UTXO = EXCLUDED.utxo,
          REWARDS = EXCLUDED.rewards,
          WITHDRAWALS = EXCLUDED.withdrawals,
          REWARDS_AVAILABLE = EXCLUDED.rewards_available;
END;
$$;
