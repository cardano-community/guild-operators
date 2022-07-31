/* Keeps track of stake snapshots taken at the end of epochs n - 1 and n - 2 */
DROP TABLE IF EXISTS GREST.stake_snapshot_cache;

CREATE TABLE GREST.stake_snapshot_cache (
  STAKE_ADDRESS varchar,
  POOL_ID varchar,
  AMOUNT numeric,
  EPOCH_NO bigint,
  PRIMARY KEY (STAKE_ADDRESS, EPOCH_NO)
);

-- This function captures the stake snapshot of previous epoch
CREATE OR REPLACE PROCEDURE GREST.CAPTURE_LAST_EPOCH_SNAPSHOT ()
LANGUAGE PLPGSQL
AS $$
DECLARE
  _previous_epoch_no bigint;
  _previous_epoch_last_block_id bigint;
  _active_stake_baseline_epoch bigint;
  _last_active_stake_block_id bigint;
  _lower_bound_account_tx_id bigint;
  _upper_bound_account_tx_id bigint;
BEGIN
  IF (
    -- If checking query with the same name there will be 2 results
    SELECT COUNT(pid) > 1
      FROM pg_stat_activity
      WHERE state = 'active'
        AND query ILIKE '%GREST.CAPTURE_LAST_EPOCH_SNAPSHOT(%'
        AND datname = (
          SELECT current_database()
        )
  ) THEN
      RAISE EXCEPTION 'Previous query still running but should have completed! Exiting...';
  END IF;

  SELECT MAX(NO) - 1 INTO _previous_epoch_no FROM PUBLIC.EPOCH;

  IF EXISTS (
    SELECT FROM grest.stake_snapshot_cache
    WHERE epoch_no = _previous_epoch_no
    LIMIT 1
  ) THEN
    RETURN;
  END IF;

  SELECT _previous_epoch_no - 2 INTO _active_stake_baseline_epoch;

  -- Set-up interval limits for previous epoch
  SELECT id INTO _last_active_stake_block_id FROM PUBLIC.BLOCK
    WHERE epoch_no = _active_stake_baseline_epoch
      AND block_no IS NOT NULL
      AND tx_count != 0
    ORDER BY block_no DESC LIMIT 1;

  SELECT id INTO _previous_epoch_last_block_id FROM PUBLIC.BLOCK
    WHERE epoch_no = _previous_epoch_no
      AND block_no IS NOT NULL
      AND tx_count != 0
    ORDER BY block_no DESC LIMIT 1;

  SELECT MAX(id) INTO _lower_bound_account_tx_id FROM PUBLIC.TX
    WHERE block_id = _last_active_stake_block_id;

  SELECT MAX(id) INTO _upper_bound_account_tx_id FROM PUBLIC.TX
    WHERE block_id = _previous_epoch_last_block_id;

/* Registered and delegated accounts to be captured (have epoch_stake entries for baseline) */
  WITH
    latest_retiring_epoch as (
      SELECT DISTINCT ON (pr.retiring_epoch)
        pr.retiring_epoch
      FROM pool_retire pr
      WHERE
        pr.announced_tx_id <= _upper_bound_account_tx_id
        AND pr.retiring_epoch <= _previous_epoch_no
      ORDER BY
        pr.retiring_epoch DESC
    ),
    epoch_last_tx_id as (
      SELECT
        lre.retiring_epoch - 1 as epoch,
        MAX(tx.id) as last_tx_id
      FROM latest_retiring_epoch lre
      INNER JOIN public.block ON block.epoch_no = lre.retiring_epoch - 1
      INNER JOIN public.tx ON tx.block_id = block.id
      WHERE
        block_no IS NOT NULL
        AND tx_count != 0
      GROUP BY lre.retiring_epoch
    ),
    latest_non_cancelled_pool_retire as (
      SELECT DISTINCT ON (pr.hash_id)
        pr.hash_id,
        pr.retiring_epoch
      FROM pool_retire pr
      WHERE
        pr.announced_tx_id <= _upper_bound_account_tx_id
        AND pr.retiring_epoch <= _previous_epoch_no
        AND NOT EXISTS (
          SELECT TRUE
          FROM pool_update pu
          WHERE pu.hash_id = pr.hash_id 
            AND (
              pu.registered_tx_id > pr.announced_tx_id
                OR (
                  pu.registered_tx_id = pr.announced_tx_id
                    AND pu.cert_index > pr.cert_index
                )
            )
            AND registered_tx_id <= _upper_bound_account_tx_id
            AND registered_tx_id <= (
              SELECT last_tx_id
              FROM epoch_last_tx_id elti
              WHERE elti.epoch = pr.retiring_epoch - 1
            )
        )
        ORDER BY
          pr.hash_id, pr.retiring_epoch DESC
    ),
    minimum_pool_delegation_tx_ids as (
      SELECT DISTINCT ON (pu.hash_id)
        pu.hash_id,
        pu.registered_tx_id as min_tx_id,
        pu.cert_index
      FROM pool_update pu
      LEFT JOIN latest_non_cancelled_pool_retire lncpr ON lncpr.hash_id = pu.hash_id
      WHERE pu.registered_tx_id <= _upper_bound_account_tx_id AND
      CASE WHEN lncpr.retiring_epoch IS NOT NULL
      THEN
        pu.registered_tx_id > (
          SELECT last_tx_id
          FROM epoch_last_tx_id elti
          WHERE elti.epoch = lncpr.retiring_epoch - 1
        )
      ELSE TRUE
      END
      ORDER BY
        pu.hash_id, pu.registered_tx_id ASC
    ),
    accounts_with_delegated_pools AS (
      SELECT DISTINCT ON (STAKE_ADDRESS.ID)
        stake_address.id as stake_address_id,
        stake_address.view as stake_address,
        delegation.pool_hash_id
      FROM STAKE_ADDRESS
        INNER JOIN DELEGATION ON DELEGATION.ADDR_ID = STAKE_ADDRESS.ID
        INNER JOIN minimum_pool_delegation_tx_ids mpdtx ON mpdtx.hash_id = delegation.pool_hash_id
      WHERE
        DELEGATION.TX_ID <= _upper_bound_account_tx_id
        AND (
          delegation.tx_id > mpdtx.min_tx_id
            OR (
              delegation.tx_id = mpdtx.min_tx_id
                AND delegation.cert_index > mpdtx.cert_index
            )
        )
        AND NOT EXISTS (
        SELECT TRUE FROM DELEGATION D
            WHERE D.ADDR_ID = DELEGATION.ADDR_ID
            AND D.ID > DELEGATION.ID
            AND D.TX_ID <= _upper_bound_account_tx_id
        )
        AND NOT EXISTS (
        SELECT TRUE FROM STAKE_DEREGISTRATION
            WHERE STAKE_DEREGISTRATION.ADDR_ID = DELEGATION.ADDR_ID
            AND (
                STAKE_DEREGISTRATION.TX_ID > DELEGATION.TX_ID
                OR (
                    STAKE_DEREGISTRATION.TX_ID = DELEGATION.TX_ID
                        AND STAKE_DEREGISTRATION.CERT_INDEX > DELEGATION.CERT_INDEX
                )
            )
            AND STAKE_DEREGISTRATION.TX_ID <= _upper_bound_account_tx_id
        )
        -- Account must be present in epoch_stake table for the previous epoch
        AND EXISTS (
        SELECT TRUE FROM EPOCH_STAKE
            WHERE EPOCH_STAKE.EPOCH_NO = _previous_epoch_no
            AND EPOCH_STAKE.ADDR_ID = STAKE_ADDRESS.ID
        )
        AND _previous_epoch_no + 1 <= (
          SELECT COALESCE(pic.retiring_epoch, 9999) --handle this better?
          FROM grest.pool_info_cache pic
          WHERE pic.pool_hash_id = delegation.pool_hash_id
            AND pic.tx_id <= _upper_bound_account_tx_id
          ORDER BY
            pic.tx_id DESC
          LIMIT 1
        )
    ),
    pool_ids as (
      SELECT awdp.stake_address_id,
        pool_hash.view AS pool_id
      FROM POOL_HASH
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.pool_hash_id = pool_hash.id
    ),
    account_active_stake AS (
      SELECT awdp.stake_address_id, es.amount
      FROM public.epoch_stake es
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = es.addr_id
        WHERE epoch_no = _previous_epoch_no
    ),
    account_delta_tx_ins AS (
      SELECT awdp.stake_address_id, tx_in.tx_out_id AS txoid, tx_in.tx_out_index AS txoidx FROM tx_in
        LEFT JOIN tx_out ON tx_in.tx_out_id = tx_out.tx_id AND tx_in.tx_out_index::smallint = tx_out.index::smallint
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = tx_out.stake_address_id
        WHERE tx_in.tx_in_id > _lower_bound_account_tx_id
          AND tx_in.tx_in_id <= _upper_bound_account_tx_id
    ),
    account_delta_input AS (
      SELECT tx_out.stake_address_id, COALESCE(SUM(tx_out.value), 0) AS amount
      FROM account_delta_tx_ins
        LEFT JOIN tx_out ON account_delta_tx_ins.txoid=tx_out.tx_id AND account_delta_tx_ins.txoidx = tx_out.index
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = tx_out.stake_address_id
        GROUP BY tx_out.stake_address_id
    ),
    account_delta_output AS (
      SELECT awdp.stake_address_id, COALESCE(SUM(tx_out.value), 0) AS amount
      FROM tx_out
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = tx_out.stake_address_id
      WHERE TX_OUT.TX_ID > _lower_bound_account_tx_id
        AND TX_OUT.TX_ID <= _upper_bound_account_tx_id
      GROUP BY awdp.stake_address_id
    ),
    account_delta_rewards AS (
      SELECT awdp.stake_address_id, COALESCE(SUM(reward.amount), 0) AS REWARDS
      FROM REWARD
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = reward.addr_id
      WHERE
        CASE WHEN REWARD.TYPE = 'refund'
          THEN REWARD.SPENDABLE_EPOCH IN (_previous_epoch_no - 1, _previous_epoch_no)
          ELSE REWARD.SPENDABLE_EPOCH IN (_previous_epoch_no, _previous_epoch_no + 1)
        END
      GROUP BY awdp.stake_address_id
    ),
    account_delta_withdrawals AS (
      SELECT accounts_with_delegated_pools.stake_address_id, COALESCE(SUM(withdrawal.amount), 0) AS withdrawals
      FROM withdrawal
        INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = withdrawal.addr_id
      WHERE withdrawal.tx_id > _lower_bound_account_tx_id
        AND withdrawal.tx_id <= _upper_bound_account_tx_id
      GROUP BY accounts_with_delegated_pools.stake_address_id
    )

      INSERT INTO GREST.stake_snapshot_cache
        SELECT
          awdp.stake_address,
          pi.pool_id,
          COALESCE(aas.amount, 0) + COALESCE(ado.amount, 0) - COALESCE(adi.amount, 0) + COALESCE(adr.rewards, 0) - COALESCE(adw.withdrawals, 0) as AMOUNT,
          _previous_epoch_no as epoch_no
        from accounts_with_delegated_pools awdp
          INNER JOIN pool_ids pi ON pi.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_active_stake aas ON aas.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_delta_input adi ON adi.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_delta_output ado ON ado.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_delta_rewards adr ON adr.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_delta_withdrawals adw ON adw.stake_address_id = awdp.stake_address_id
        ON CONFLICT (STAKE_ADDRESS, EPOCH_NO) DO
          UPDATE
            SET
              POOL_ID = EXCLUDED.POOL_ID,
              AMOUNT = EXCLUDED.AMOUNT;

  /* Newly registered accounts to be captured (they don't have epoch_stake entries for baseline) */
  WITH
    latest_retiring_epoch as (
      SELECT DISTINCT ON (pr.retiring_epoch)
        pr.retiring_epoch
      FROM pool_retire pr
      WHERE
        pr.announced_tx_id <= _upper_bound_account_tx_id
        AND pr.retiring_epoch <= _previous_epoch_no
      ORDER BY
        pr.retiring_epoch DESC
    ),
    epoch_last_tx_id as (
      SELECT
        lre.retiring_epoch - 1 as epoch,
        MAX(tx.id) as last_tx_id
      FROM latest_retiring_epoch lre
      INNER JOIN public.block ON block.epoch_no = lre.retiring_epoch - 1
      INNER JOIN public.tx ON tx.block_id = block.id
      WHERE
        block_no IS NOT NULL
        AND tx_count != 0
      GROUP BY lre.retiring_epoch
    ),
    latest_non_cancelled_pool_retire as (
      SELECT DISTINCT ON (pr.hash_id)
        pr.hash_id,
        pr.retiring_epoch
      FROM pool_retire pr
      WHERE
        pr.announced_tx_id <= _upper_bound_account_tx_id
        AND pr.retiring_epoch <= _previous_epoch_no
        AND NOT EXISTS (
          SELECT TRUE
          FROM pool_update pu
          WHERE pu.hash_id = pr.hash_id 
            AND (
              pu.registered_tx_id > pr.announced_tx_id
                OR (
                  pu.registered_tx_id = pr.announced_tx_id
                    AND pu.cert_index > pr.cert_index
                )
            )
            AND registered_tx_id <= _upper_bound_account_tx_id
            AND registered_tx_id <= (
              SELECT last_tx_id
              FROM epoch_last_tx_id elti
              WHERE elti.epoch = pr.retiring_epoch - 1
            )
        )
        ORDER BY
          pr.hash_id, pr.retiring_epoch DESC
    ),
    minimum_pool_delegation_tx_ids as (
      SELECT DISTINCT ON (pu.hash_id)
        pu.hash_id,
        pu.registered_tx_id as min_tx_id,
        pu.cert_index
      FROM pool_update pu
      LEFT JOIN latest_non_cancelled_pool_retire lncpr ON lncpr.hash_id = pu.hash_id
      WHERE pu.registered_tx_id <= _upper_bound_account_tx_id AND
      CASE WHEN lncpr.retiring_epoch IS NOT NULL
      THEN
        pu.registered_tx_id > (
          SELECT last_tx_id
          FROM epoch_last_tx_id elti
          WHERE elti.epoch = lncpr.retiring_epoch - 1
        )
      ELSE TRUE
      END
      ORDER BY
        pu.hash_id, pu.registered_tx_id ASC
    ),
    newly_registered_accounts AS (
      SELECT DISTINCT ON (STAKE_ADDRESS.ID)
        stake_address.id as stake_address_id,
        stake_address.view as stake_address,
        delegation.pool_hash_id
      FROM STAKE_ADDRESS
        INNER JOIN DELEGATION ON DELEGATION.ADDR_ID = STAKE_ADDRESS.ID
        INNER JOIN minimum_pool_delegation_tx_ids mpdtx ON mpdtx.hash_id = delegation.pool_hash_id        
      WHERE
          DELEGATION.TX_ID <= _upper_bound_account_tx_id
          AND (
            delegation.tx_id > mpdtx.min_tx_id
              OR (
                delegation.tx_id = mpdtx.min_tx_id
                  AND delegation.cert_index > mpdtx.cert_index
              )
          )
          AND NOT EXISTS (
            SELECT TRUE FROM DELEGATION D
              WHERE D.ADDR_ID = DELEGATION.ADDR_ID
                AND D.ID > DELEGATION.ID
                AND D.TX_ID <= _upper_bound_account_tx_id 
          )
          AND NOT EXISTS (
            SELECT TRUE FROM STAKE_DEREGISTRATION
              WHERE STAKE_DEREGISTRATION.ADDR_ID = DELEGATION.ADDR_ID
                AND (
                    STAKE_DEREGISTRATION.TX_ID > DELEGATION.TX_ID
                    OR (
                        STAKE_DEREGISTRATION.TX_ID = DELEGATION.TX_ID
                            AND STAKE_DEREGISTRATION.CERT_INDEX > DELEGATION.CERT_INDEX
                    )
                )
              AND STAKE_DEREGISTRATION.TX_ID <= _upper_bound_account_tx_id
          )
          -- Account must NOT be present in epoch_stake table for the previous epoch
          AND NOT EXISTS (
            SELECT TRUE FROM EPOCH_STAKE
              WHERE EPOCH_STAKE.EPOCH_NO = _previous_epoch_no
                AND EPOCH_STAKE.ADDR_ID = STAKE_ADDRESS.ID
          )
          AND _previous_epoch_no + 1 <= (
            SELECT COALESCE(pic.retiring_epoch, 9999) -- handle this better?
              FROM grest.pool_info_cache pic
                WHERE pic.pool_hash_id = delegation.pool_hash_id
                  AND pic.tx_id <= _upper_bound_account_tx_id
              ORDER BY 
                pic.tx_id DESC
              LIMIT 1
          )
    ),
    pool_ids as (
      SELECT nra.stake_address_id,
        pool_hash.view AS pool_id
      FROM POOL_HASH
        INNER JOIN newly_registered_accounts nra ON nra.pool_hash_id = pool_hash.id
    ),
    account_delta_tx_ins AS (
      SELECT nra.stake_address_id, tx_in.tx_out_id AS txoid, tx_in.tx_out_index AS txoidx FROM tx_in
        LEFT JOIN tx_out ON tx_in.tx_out_id = tx_out.tx_id AND tx_in.tx_out_index::smallint = tx_out.index::smallint
        INNER JOIN newly_registered_accounts nra ON nra.stake_address_id = tx_out.stake_address_id
        WHERE tx_in.tx_in_id <= _upper_bound_account_tx_id
    ),
    account_delta_input AS (
      SELECT tx_out.stake_address_id, COALESCE(SUM(tx_out.value), 0) AS amount
      FROM account_delta_tx_ins
        LEFT JOIN tx_out ON account_delta_tx_ins.txoid=tx_out.tx_id AND account_delta_tx_ins.txoidx = tx_out.index
        INNER JOIN newly_registered_accounts nra ON nra.stake_address_id = tx_out.stake_address_id
        GROUP BY tx_out.stake_address_id
    ),
    account_delta_output AS (
      SELECT nra.stake_address_id, COALESCE(SUM(tx_out.value), 0) AS amount
      FROM tx_out
        INNER JOIN newly_registered_accounts nra ON nra.stake_address_id = tx_out.stake_address_id
      WHERE TX_OUT.TX_ID <= _upper_bound_account_tx_id
      GROUP BY nra.stake_address_id
    ),
    account_delta_rewards AS (
      SELECT nra.stake_address_id, COALESCE(SUM(reward.amount), 0) AS REWARDS
      FROM REWARD
        INNER JOIN newly_registered_accounts nra ON nra.stake_address_id = reward.addr_id
      WHERE
        CASE WHEN REWARD.TYPE = 'refund'
          THEN REWARD.SPENDABLE_EPOCH <= _previous_epoch_no
          ELSE REWARD.SPENDABLE_EPOCH <= _previous_epoch_no + 1
        END
      GROUP BY nra.stake_address_id
    ),
    account_delta_withdrawals AS (
      SELECT nra.stake_address_id, COALESCE(SUM(withdrawal.amount), 0) AS withdrawals
      FROM withdrawal
        INNER JOIN newly_registered_accounts nra ON nra.stake_address_id = withdrawal.addr_id
      WHERE withdrawal.tx_id <= _upper_bound_account_tx_id
      GROUP BY nra.stake_address_id
    )

      INSERT INTO GREST.stake_snapshot_cache
        SELECT
          nra.stake_address,
          pi.pool_id,
          COALESCE(ado.amount, 0) - COALESCE(adi.amount, 0) + COALESCE(adr.rewards, 0) - COALESCE(adw.withdrawals, 0) as amount,
          _previous_epoch_no as epoch_no
        FROM newly_registered_accounts nra
          INNER JOIN pool_ids pi ON pi.stake_address_id = nra.stake_address_id
          LEFT JOIN account_delta_input adi ON adi.stake_address_id = nra.stake_address_id
          LEFT JOIN account_delta_output ado ON ado.stake_address_id = nra.stake_address_id
          LEFT JOIN account_delta_rewards adr ON adr.stake_address_id = nra.stake_address_id
          LEFT JOIN account_delta_withdrawals adw ON adw.stake_address_id = nra.stake_address_id
      ON CONFLICT (STAKE_ADDRESS, EPOCH_NO) DO
        UPDATE
          SET
            POOL_ID = EXCLUDED.POOL_ID,
            AMOUNT = EXCLUDED.AMOUNT;

  INSERT INTO GREST.CONTROL_TABLE (key, last_value)
    VALUES (
      'last_stake_snapshot_epoch',
      _previous_epoch_no
    ) ON CONFLICT (key)
    DO UPDATE
      SET last_value = _previous_epoch_no;

  DELETE FROM grest.stake_snapshot_cache
    WHERE epoch_no <= _previous_epoch_no - 2;
END;
$$;
