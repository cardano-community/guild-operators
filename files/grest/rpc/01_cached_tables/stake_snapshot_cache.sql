/* Keeps track of stake snapshots taken at the end of epochs n - 1 and n - 2 */
CREATE TABLE IF NOT EXISTS GREST.stake_snapshot_cache (
  addr_id integer,
  pool_id integer,
  amount numeric,
  epoch_no bigint,
  PRIMARY KEY (addr_id, epoch_no)
);

CREATE INDEX IF NOT EXISTS _idx_pool_id ON grest.stake_snapshot_cache (pool_id);
CREATE INDEX IF NOT EXISTS _idx_addr_id ON grest.stake_snapshot_cache (addr_id);

CREATE OR REPLACE PROCEDURE GREST.CAPTURE_LAST_EPOCH_SNAPSHOT ()
LANGUAGE PLPGSQL
AS $$
DECLARE
  _previous_epoch_no bigint;
  _lower_bound_account_tx_id bigint;
  _upper_bound_account_tx_id bigint;
  _newly_registered_account_ids bigint[];
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

  IF NOT EXISTS (
    SELECT i_last_tx_id from grest.epoch_info_cache
      WHERE epoch_no = _previous_epoch_no
      AND i_last_tx_id IS NOT NULL
  ) THEN
    RAISE NOTICE 'Epoch % info cache not ready, exiting.', _previous_epoch_no;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT FROM grest.stake_snapshot_cache
      WHERE epoch_no = _previous_epoch_no
  ) THEN
    RETURN;
  END IF;

  -- Set-up interval limits for previous epoch
  SELECT MAX(tx.id) INTO _lower_bound_account_tx_id
  FROM PUBLIC.TX
  INNER JOIN BLOCK b ON b.id = tx.block_id
    WHERE b.epoch_no <= _previous_epoch_no - 2
    AND b.block_no IS NOT NULL
    AND b.tx_count != 0;

  SELECT MAX(tx.id) INTO _upper_bound_account_tx_id
  FROM PUBLIC.TX
  INNER JOIN BLOCK b ON b.id = tx.block_id
    WHERE b.epoch_no <= _previous_epoch_no
    AND b.block_no IS NOT NULL
    AND b.tx_count != 0;

  /* Temporary table to figure out valid delegations ending up in active stake in case of pool retires */
  DROP TABLE IF EXISTS minimum_pool_delegation_tx_ids;
  CREATE TEMP TABLE minimum_pool_delegation_tx_ids (
    pool_hash_id integer PRIMARY KEY,
    latest_registered_tx_id integer,
    latest_registered_tx_cert_index integer
  );

  DROP TABLE IF EXISTS latest_accounts_delegation_txs;
  CREATE TEMP TABLE latest_accounts_delegation_txs (
    addr_id integer PRIMARY KEY,
    tx_id integer,
    cert_index integer,
    pool_hash_id integer
  );

  DROP TABLE IF EXISTS rewards_subset;
  CREATE TEMP TABLE rewards_subset (
    stake_address_id bigint,
    type rewardtype,
    spendable_epoch bigint,
    amount lovelace
  );
  
  INSERT INTO rewards_subset
    SELECT addr_id, type, spendable_epoch, amount
    FROM reward
    WHERE spendable_epoch BETWEEN _previous_epoch_no - 1 AND _previous_epoch_no + 1;

/* Registered and delegated accounts to be captured (have epoch_stake entries for baseline) */
  WITH
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
            AND pu.registered_tx_id <= _upper_bound_account_tx_id
            AND pu.registered_tx_id <= (
              SELECT i_last_tx_id
              FROM grest.epoch_info_cache eic
              WHERE eic.epoch_no = pr.retiring_epoch - 1
            )
        )
        AND NOT EXISTS (
          SELECT TRUE
          FROM pool_retire sub_pr
          WHERE pr.hash_id = sub_pr.hash_id 
            AND (
              sub_pr.announced_tx_id > pr.announced_tx_id
                OR (
                  sub_pr.announced_tx_id = pr.announced_tx_id
                    AND sub_pr.cert_index > pr.cert_index
                )
            )
            AND sub_pr.announced_tx_id <= _upper_bound_account_tx_id
            AND sub_pr.announced_tx_id <= (
              SELECT i_last_tx_id
              FROM grest.epoch_info_cache eic
              WHERE eic.epoch_no = pr.retiring_epoch - 1
            )
        )
      ORDER BY
        pr.hash_id, pr.retiring_epoch DESC
    )

    INSERT INTO minimum_pool_delegation_tx_ids
      SELECT DISTINCT ON (pu.hash_id)
        pu.hash_id,
        pu.registered_tx_id as min_tx_id,
        pu.cert_index
      FROM pool_update pu
        LEFT JOIN latest_non_cancelled_pool_retire lncpr ON lncpr.hash_id = pu.hash_id
      WHERE pu.registered_tx_id <= _upper_bound_account_tx_id
        AND
        CASE WHEN lncpr.retiring_epoch IS NOT NULL
          THEN
            pu.registered_tx_id > (
              SELECT i_last_tx_id
              FROM grest.epoch_info_cache eic
              WHERE eic.epoch_no = lncpr.retiring_epoch - 1
            )
          ELSE TRUE
        END
      ORDER BY
        pu.hash_id, pu.registered_tx_id ASC;

    INSERT INTO latest_accounts_delegation_txs
      SELECT distinct on (d.addr_id)
        d.addr_id,
        d.tx_id,
        d.cert_index,
        d.pool_hash_id
      FROM DELEGATION D
      WHERE
        d.tx_id <= _upper_bound_account_tx_id
        AND NOT EXISTS (
          SELECT TRUE FROM STAKE_DEREGISTRATION
            WHERE STAKE_DEREGISTRATION.ADDR_ID = D.ADDR_ID
            AND (
                STAKE_DEREGISTRATION.TX_ID > D.TX_ID
                OR (
                    STAKE_DEREGISTRATION.TX_ID = D.TX_ID
                        AND STAKE_DEREGISTRATION.CERT_INDEX > D.CERT_INDEX
                )
            )
            AND STAKE_DEREGISTRATION.TX_ID <= _upper_bound_account_tx_id
        )
      ORDER BY
        d.addr_id, d.tx_id DESC;
    
    CREATE INDEX _idx_pool_hash_id ON latest_accounts_delegation_txs (pool_hash_id);


  /* Registered and delegated accounts to be captured (have epoch_stake entries for baseline) */
  WITH
    accounts_with_delegated_pools AS (
      SELECT DISTINCT ON (ladt.addr_id)
        ladt.addr_id as stake_address_id,
        ladt.pool_hash_id
      FROM latest_accounts_delegation_txs ladt
        INNER JOIN minimum_pool_delegation_tx_ids mpdtx ON mpdtx.pool_hash_id = ladt.pool_hash_id
      WHERE
        (
          ladt.tx_id > mpdtx.latest_registered_tx_id
            OR (
              ladt.tx_id = mpdtx.latest_registered_tx_id
                AND ladt.cert_index > mpdtx.latest_registered_tx_cert_index
            )
        )
        -- Account must be present in epoch_stake table for the previous epoch
        AND EXISTS (
          SELECT TRUE FROM epoch_stake es
            WHERE es.epoch_no = _previous_epoch_no
              AND es.addr_id = ladt.addr_id
        )
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
      SELECT awdp.stake_address_id, COALESCE(SUM(rs.amount), 0) AS REWARDS
      FROM rewards_subset rs
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = rs.stake_address_id
      WHERE
        CASE WHEN rs.type = 'refund'
          THEN rs.spendable_epoch IN (_previous_epoch_no - 1, _previous_epoch_no)
          ELSE rs.spendable_epoch IN (_previous_epoch_no, _previous_epoch_no + 1)
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
          awdp.stake_address_id as addr_id,
          awdp.pool_hash_id,
          COALESCE(aas.amount, 0) + COALESCE(ado.amount, 0) - COALESCE(adi.amount, 0) + COALESCE(adr.rewards, 0) - COALESCE(adw.withdrawals, 0) as AMOUNT,
          _previous_epoch_no as epoch_no
        from accounts_with_delegated_pools awdp
          LEFT JOIN account_active_stake aas ON aas.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_delta_input adi ON adi.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_delta_output ado ON ado.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_delta_rewards adr ON adr.stake_address_id = awdp.stake_address_id
          LEFT JOIN account_delta_withdrawals adw ON adw.stake_address_id = awdp.stake_address_id
        ON CONFLICT (addr_id, EPOCH_NO) DO
          UPDATE
            SET
              POOL_ID = EXCLUDED.POOL_ID,
              AMOUNT = EXCLUDED.AMOUNT;

  /* Newly registered accounts to be captured (they don't have epoch_stake entries for baseline) */
  SELECT INTO _newly_registered_account_ids ARRAY_AGG(addr_id)
  FROM (
    SELECT DISTINCT ladt.addr_id
    FROM latest_accounts_delegation_txs ladt
      INNER JOIN minimum_pool_delegation_tx_ids mpdtx ON mpdtx.pool_hash_id = ladt.pool_hash_id
    WHERE
      (
        ladt.tx_id > mpdtx.latest_registered_tx_id
        OR (
          ladt.tx_id = mpdtx.latest_registered_tx_id
            AND ladt.cert_index > mpdtx.latest_registered_tx_cert_index
        )
      )
      -- Account must NOT be present in epoch_stake table for the previous epoch
      AND NOT EXISTS (
        SELECT TRUE FROM epoch_stake es
          WHERE es.epoch_no = _previous_epoch_no
            AND es.addr_id = ladt.addr_id
      )
  ) AS tmp;
  WITH
    account_delta_tx_ins AS (
      SELECT tx_out.stake_address_id, tx_in.tx_out_id AS txoid, tx_in.tx_out_index AS txoidx 
      FROM tx_in
        LEFT JOIN tx_out ON tx_in.tx_out_id = tx_out.tx_id AND tx_in.tx_out_index::smallint = tx_out.index::smallint
      WHERE tx_in.tx_in_id <= _upper_bound_account_tx_id
        AND tx_out.stake_address_id = ANY(_newly_registered_account_ids)
    ),
    account_delta_input AS (
      SELECT tx_out.stake_address_id, COALESCE(SUM(tx_out.value), 0) AS amount
      FROM account_delta_tx_ins
        LEFT JOIN tx_out ON account_delta_tx_ins.txoid=tx_out.tx_id AND account_delta_tx_ins.txoidx = tx_out.index
      WHERE tx_out.stake_address_id = ANY(_newly_registered_account_ids)
      GROUP BY tx_out.stake_address_id
    ),
    account_delta_output AS (
      SELECT tx_out.stake_address_id, COALESCE(SUM(tx_out.value), 0) AS amount
      FROM tx_out
      WHERE TX_OUT.TX_ID <= _upper_bound_account_tx_id
        AND tx_out.stake_address_id = ANY(_newly_registered_account_ids)
      GROUP BY tx_out.stake_address_id
    ),
    account_delta_rewards AS (
      SELECT r.addr_id as stake_address_id, COALESCE(SUM(r.amount), 0) AS REWARDS
      FROM REWARD r
      WHERE r.addr_id = ANY(_newly_registered_account_ids)
        AND
        CASE WHEN r.type = 'refund'
          THEN r.spendable_epoch <= _previous_epoch_no
          ELSE r.spendable_epoch <= _previous_epoch_no + 1
        END
      GROUP BY r.addr_id
    ),
    account_delta_withdrawals AS (
      SELECT withdrawal.addr_id as stake_address_id, COALESCE(SUM(withdrawal.amount), 0) AS withdrawals
      FROM withdrawal
      WHERE withdrawal.tx_id <= _upper_bound_account_tx_id
        AND withdrawal.addr_id = ANY(_newly_registered_account_ids)
      GROUP BY withdrawal.addr_id
    )

      INSERT INTO GREST.stake_snapshot_cache
        SELECT
          ladt.addr_id,
          ladt.pool_hash_id,
          COALESCE(ado.amount, 0) - COALESCE(adi.amount, 0) + COALESCE(adr.rewards, 0) - COALESCE(adw.withdrawals, 0) as amount,
          _previous_epoch_no as epoch_no
        FROM latest_accounts_delegation_txs ladt
          LEFT JOIN account_delta_input adi ON adi.stake_address_id = ladt.addr_id
          LEFT JOIN account_delta_output ado ON ado.stake_address_id = ladt.addr_id
          LEFT JOIN account_delta_rewards adr ON adr.stake_address_id = ladt.addr_id
          LEFT JOIN account_delta_withdrawals adw ON adw.stake_address_id = ladt.addr_id
        WHERE
          ladt.addr_id = ANY(_newly_registered_account_ids)
      ON CONFLICT (addr_id, epoch_no) DO
        UPDATE
          SET
            pool_id = EXCLUDED.pool_id,
            amount = EXCLUDED.amount;

  INSERT INTO GREST.CONTROL_TABLE (key, last_value)
    VALUES (
      'last_stake_snapshot_epoch',
      _previous_epoch_no
    ) ON CONFLICT (key)
    DO UPDATE
      SET last_value = _previous_epoch_no;

  INSERT INTO grest.epoch_active_stake_cache
    SELECT
      _previous_epoch_no + 2,
      SUM(amount)
    FROM grest.stake_snapshot_cache
    WHERE epoch_no = _previous_epoch_no
    ON CONFLICT (epoch_no) DO UPDATE
      SET amount = excluded.amount
      WHERE epoch_active_stake_cache.amount IS DISTINCT FROM excluded.amount;

  INSERT INTO grest.pool_active_stake_cache
    SELECT
      ph.view,
      _previous_epoch_no + 2,
      SUM(ssc.amount)
    FROM grest.stake_snapshot_cache ssc
      INNER JOIN pool_hash ph ON ph.id = ssc.pool_id
    WHERE epoch_no = _previous_epoch_no
    GROUP BY
      ssc.pool_id, ph.view
    ON CONFLICT (pool_id, epoch_no) DO UPDATE
      SET amount = excluded.amount
      WHERE pool_active_stake_cache.amount IS DISTINCT FROM excluded.amount;

  DELETE FROM grest.stake_snapshot_cache
    WHERE epoch_no <= _previous_epoch_no - 2;
END;
$$;
