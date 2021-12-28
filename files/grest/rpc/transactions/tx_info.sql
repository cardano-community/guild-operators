DROP FUNCTION IF EXISTS grest.tx_info (text[]);

CREATE FUNCTION grest.tx_info (_tx_hashes text[])
  RETURNS TABLE (
    tx_hash text,
    block_hash text,
    block_height uinteger,
    epoch uinteger,
    epoch_slot uinteger,
    absolute_slot uinteger,
    tx_timestamp timestamp without time zone,
    tx_block_index uinteger,
    tx_size uinteger,
    total_output lovelace,
    fee lovelace,
    deposit bigint,
    invalid_before word64type,
    invalid_after word64type,
    inputs json,
    outputs json,
    withdrawals json,
    assets_minted json,
    metadata json,
    certificates json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _tx_hashes_bytea    bytea[];
  _tx_id_list         bigint[];
BEGIN

  -- convert input _tx_hashes array into bytea array
  SELECT INTO _tx_hashes_bytea ARRAY_AGG(hashes_bytea)
  FROM (
    SELECT
      DECODE(hashes_hex, 'hex') AS hashes_bytea
    FROM
      UNNEST(_tx_hashes) AS hashes_hex
  ) AS tmp;

  -- all tx ids
  SELECT INTO _tx_id_list ARRAY_AGG(id)
  FROM (
    SELECT
      id
    FROM 
      tx
    WHERE tx.hash = ANY (_tx_hashes_bytea)
  ) AS tmp;

  RETURN QUERY (
    WITH

      -- limit by last known block, also join with block only once
      _all_tx AS (
        SELECT
          tx.id,
          tx.hash as tx_hash,
          b.hash as block_hash,
          b.block_no AS block_height,
          b.epoch_no AS epoch,
          b.epoch_slot_no AS epoch_slot,
          b.slot_no AS absolute_slot,
          b.time AS tx_timestamp,
          tx.block_index AS tx_block_index,
          tx.size AS tx_size,
          tx.out_sum AS total_output,
          tx.fee,
          tx.deposit,
          tx.invalid_before,
          tx.invalid_hereafter AS invalid_after
        FROM
          tx
          INNER JOIN block b ON tx.block_id = b.id
        WHERE tx.id = ANY (_tx_id_list)
      ),

      _all_outputs AS (
        SELECT
          tx_id,
          JSON_AGG(t_outputs) AS list
        FROM (
          SELECT 
            tx_out.tx_id,
            JSON_BUILD_OBJECT(
              'payment_addr', JSON_BUILD_OBJECT(
                'bech32', tx_out.address,
                'cred', ENCODE(tx_out.payment_cred, 'hex')
              ),
              'stake_addr', SA.view,
              'tx_hash', ENCODE(_all_tx.tx_hash, 'hex'),
              'tx_index', tx_out.index,
              'value', tx_out.value,
              'asset_list', COALESCE((
                SELECT
                  JSON_AGG(JSON_BUILD_OBJECT(
                    'policy_id', ENCODE(MA.policy, 'hex'),
                    'asset_name', ENCODE(MA.name, 'hex'),
                    'quantity', MTX.quantity
                  ))
                FROM 
                  ma_tx_out MTX
                  INNER JOIN MULTI_ASSET MA ON MA.id = MTX.ident
                WHERE 
                  MTX.tx_out_id = tx_out.id
              ), JSON_BUILD_ARRAY())
            ) AS t_outputs
          FROM
            tx_out
            INNER JOIN _all_tx ON tx_out.tx_id = _all_tx.id
            LEFT JOIN stake_address SA on tx_out.stake_address_id = SA.id
          WHERE 
            tx_out.tx_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
        ORDER BY tx_id
      ),

      _all_inputs AS (
        SELECT
          tx_id,
          JSON_AGG(t_inputs) AS list
        FROM (
          SELECT 
            tx_in.tx_in_id AS tx_id,
            JSON_BUILD_OBJECT(
              'payment_addr', JSON_BUILD_OBJECT(
                'bech32', tx_out.address,
                'cred', ENCODE(tx_out.payment_cred, 'hex')
              ),
              'stake_addr', SA.view,
              'tx_hash', ENCODE(tx.hash, 'hex'),
              'tx_index', tx_out.index,
              'value', tx_out.value,
              'asset_list', COALESCE((
                SELECT 
                  JSON_AGG(JSON_BUILD_OBJECT(
                    'policy_id', ENCODE(MA.policy, 'hex'),
                    'asset_name', ENCODE(MA.name, 'hex'),
                    'quantity', MTX.quantity
                  ))
                FROM 
                  ma_tx_out MTX
                  INNER JOIN MULTI_ASSET MA ON MA.id = MTX.ident
                WHERE 
                  MTX.tx_out_id = tx_out.id
              ), JSON_BUILD_ARRAY())
            ) AS t_inputs
          FROM
            tx_in
            INNER JOIN tx_out ON tx_out.tx_id = tx_in.tx_out_id
              AND tx_out.index = tx_in.tx_out_index
            INNER JOIN tx on tx_out.tx_id = tx.id
            LEFT JOIN stake_address SA on tx_out.stake_address_id = SA.id
          WHERE 
            tx_in.tx_in_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
      ),

      _all_withdrawals AS (
        SELECT
          tx_id,
          JSON_AGG(data) AS list
        FROM (
          SELECT
            W.tx_id,
            JSON_BUILD_OBJECT(
              'amount', W.amount,
              'stake_addr', SA.view
            ) AS data
          FROM 
            withdrawal W
            INNER JOIN stake_address SA ON W.addr_id = SA.id
          WHERE
            W.tx_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
      ),

      _all_mints AS (
        SELECT
          tx_id,
          JSON_AGG(data) AS list
        FROM (
          SELECT
            MTM.tx_id,
            JSON_BUILD_OBJECT(
              'policy_id', ENCODE(MA.policy, 'hex'),
              'asset_name', ENCODE(MA.name, 'hex'),
              'quantity', MTM.quantity
            ) AS data
          FROM 
            ma_tx_mint MTM
            INNER JOIN MULTI_ASSET MA ON MA.id = MTM.ident

          WHERE
            MTM.tx_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
      ),

      _all_metadata AS (
        SELECT
          tx_id,
          JSON_AGG(data) AS list
        FROM (
          SELECT
            TM.tx_id,
            JSON_BUILD_OBJECT(
              'key', TM.key,
              'json', TM.json
            ) AS data
          FROM 
            tx_metadata TM
          WHERE
            TM.tx_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
      ),

      _all_certs AS (
        SELECT
          tx_id,
          JSON_AGG(data) AS list
        FROM (
          SELECT
            SR.tx_id,
            JSON_BUILD_OBJECT(
              'index', SR.cert_index,
              'type', 'stake_registration',
              'info', JSON_BUILD_OBJECT(
                'stake_address', SA.view
              )
            ) AS data
          FROM 
            public.stake_registration SR
            INNER JOIN public.stake_address SA ON SA.id = SR.addr_id
          WHERE
            SR.tx_id = ANY (_tx_id_list)
          --
          UNION ALL
          --
          SELECT
            SD.tx_id,
            JSON_BUILD_OBJECT(
              'index', SD.cert_index,
              'type', 'stake_deregistration',
              'info', JSON_BUILD_OBJECT(
                'stake_address', SA.view
              )
            ) AS data
          FROM 
            public.stake_deregistration SD
            INNER JOIN public.stake_address SA ON SA.id = SD.addr_id
          WHERE
            SD.tx_id = ANY (_tx_id_list)
          --
          UNION ALL
          --
          SELECT
            D.tx_id,
            JSON_BUILD_OBJECT(
              'index', D.cert_index,
              'type', 'delegation',
              'info', JSON_BUILD_OBJECT(
                'stake_address', SA.view, 
                'pool_id_bech32', PH.view,
                'pool_id_hex', ENCODE(PH.hash_raw, 'hex')
              )
            ) AS data
          FROM 
            public.delegation D
            INNER JOIN public.stake_address SA ON SA.id = D.addr_id
            INNER JOIN public.pool_hash PH ON PH.id = D.pool_hash_id
          WHERE
            D.tx_id = ANY (_tx_id_list)
          --
          UNION ALL
          --
          SELECT
            T.tx_id,
            JSON_BUILD_OBJECT(
              'index', T.cert_index,
              'type', 'treasury_MIR',
              'info', JSON_BUILD_OBJECT(
                'stake_address', SA.view, 
                'amount', T.amount
              )
            ) AS data
          FROM 
            public.treasury T
            INNER JOIN public.stake_address SA ON SA.id = T.addr_id
          WHERE
            T.tx_id = ANY (_tx_id_list)
          --
          UNION ALL
          --
          SELECT
            R.tx_id,
            JSON_BUILD_OBJECT(
              'index', R.cert_index,
              'type', 'reserve_MIR',
              'info', JSON_BUILD_OBJECT(
                'stake_address', SA.view, 
                'amount', R.amount
              )
            ) AS data
          FROM 
            public.reserve R
            INNER JOIN public.stake_address SA ON SA.id = R.addr_id
          WHERE
            R.tx_id = ANY (_tx_id_list)
          --
          UNION ALL
          --
          SELECT
            PT.tx_id,
            JSON_BUILD_OBJECT(
              'index', PT.cert_index,
              'type', 'pot_transfer',
              'info', JSON_BUILD_OBJECT(
                'treasury', PT.treasury,
                'reserves', PT.reserves
              )
            ) AS data
          FROM
            public.pot_transfer PT
          WHERE
            PT.tx_id = ANY (_tx_id_list)
          --
          UNION ALL
          --
          SELECT
            -- SELECT DISTINCT below because there are multiple entries for each signing key of a given transaction
            DISTINCT ON (PP.registered_tx_id) PP.registered_tx_id AS tx_id,
            JSON_BUILD_OBJECT(
              'index', null, -- cert_index not stored in param_proposal table
              'type', 'param_proposal',
              'info', JSON_STRIP_NULLS(JSON_BUILD_OBJECT(
                'min_fee_a', PP.min_fee_a,
                'min_fee_b', PP.min_fee_b,
                'max_block_size', PP.max_block_size,
                'max_tx_size', PP.max_tx_size,
                'max_bh_size', PP.max_bh_size,
                'key_deposit', PP.key_deposit,
                'pool_deposit', PP.pool_deposit,
                'max_epoch', PP.max_epoch,
                'optimal_pool_count', PP.optimal_pool_count,
                'influence', PP.influence,
                'monetary_expand_rate', PP.monetary_expand_rate,
                'treasury_growth_rate', PP.treasury_growth_rate,
                'decentralisation', PP.decentralisation,
                'entropy', PP.entropy,
                'protocol_major', PP.protocol_major,
                'protocol_minor', PP.protocol_minor,
                'min_utxo_value', PP.min_utxo_value,
                'min_pool_cost', PP.min_pool_cost,
                'cost_model_id', PP.cost_model_id,
                'price_mem', PP.price_mem,
                'price_step', PP.price_step,
                'max_tx_ex_mem', PP.max_tx_ex_mem,
                'max_tx_ex_steps', PP.max_tx_ex_steps,
                'max_block_ex_mem', PP.max_block_ex_mem,
                'max_block_ex_steps', PP.max_block_ex_steps,
                'max_val_size', PP.max_val_size,
                'collateral_percent', PP.collateral_percent,
                'max_collateral_inputs', PP.max_collateral_inputs,
                'coins_per_utxo_word', PP.coins_per_utxo_word
              ))
            ) AS data
          FROM 
            public.param_proposal PP
          WHERE
            PP.registered_tx_id = ANY (_tx_id_list)
          --
          UNION ALL
          --
          SELECT
            PR.announced_tx_id AS tx_id,
            JSON_BUILD_OBJECT(
              'index', PR.cert_index,
              'type', 'pool_retire',
              'info', JSON_BUILD_OBJECT(
                'pool_id_bech32', PH.view,
                'pool_id_hex', ENCODE(PH.hash_raw, 'hex'),
                'retiring epoch', PR.retiring_epoch
              )
            ) AS data
          FROM 
            public.pool_retire PR
            INNER JOIN public.pool_hash PH ON PH.id = PR.hash_id
          WHERE
            PR.announced_tx_id = ANY (_tx_id_list)
          --
          UNION ALL
          --
          SELECT
            PIC.tx_id,
            JSON_BUILD_OBJECT(
              'index', PU.cert_index,
              'type', 'pool_update',
              'info', JSON_BUILD_OBJECT(
                'pool_id_bech32', PIC.pool_id_bech32,
                'pool_id_hex', PIC.pool_id_hex,
                'active_epoch_no', PIC.active_epoch_no,
                'vrf_key_hash', PIC.vrf_key_hash,
                'margin', PIC.margin,
                'fixed_cost', PIC.fixed_cost,
                'pledge', PIC.pledge,
                'reward_addr', PIC.reward_addr,
                'owners', PIC.owners,
                'relays', PIC.relays,
                'meta_url', PIC.meta_url,
                'meta_hash', PIC.meta_hash
              )
            ) AS data
          FROM 
            grest.pool_info_cache PIC
            INNER JOIN public.pool_update PU ON PU.registered_tx_id = PIC.tx_id
          WHERE
            PIC.tx_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
        ORDER BY tx_id
      )

    SELECT
      ENCODE(ATX.tx_hash, 'hex'),
      ENCODE(ATX.block_hash, 'hex'),
      ATX.block_height,
      ATX.epoch,
      ATX.epoch_slot,
      ATX.absolute_slot,
      ATX.tx_timestamp,
      ATX.tx_block_index,
      ATX.tx_size,
      ATX.total_output,
      ATX.fee,
      ATX.deposit,
      ATX.invalid_before,
      ATX.invalid_after,
      COALESCE(AI.list, JSON_BUILD_ARRAY()),
      COALESCE(AO.list, JSON_BUILD_ARRAY()),
      COALESCE(AW.list, JSON_BUILD_ARRAY()),
      COALESCE(AMI.list, JSON_BUILD_ARRAY()),
      COALESCE(AME.list, JSON_BUILD_ARRAY()),
      COALESCE(AC.list, JSON_BUILD_ARRAY())
    FROM
      _all_tx ATX
      LEFT JOIN _all_inputs AI ON AI.tx_id = ATX.id
      LEFT JOIN _all_outputs AO ON AO.tx_id = ATX.id
      LEFT JOIN _all_withdrawals AW ON AW.tx_id = ATX.id
      LEFT JOIN _all_mints AMI ON AMI.tx_id = ATX.id
      LEFT JOIN _all_metadata AME ON AME.tx_id = ATX.id
      LEFT JOIN _all_certs AC ON AC.tx_id = ATX.id
    WHERE ATX.tx_hash = ANY (_tx_hashes_bytea)
);

END;
$$;

COMMENT ON FUNCTION grest.tx_info IS 'Get information about transactions.';
