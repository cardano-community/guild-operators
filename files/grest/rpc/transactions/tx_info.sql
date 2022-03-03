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
    total_output text,
    fee text,
    deposit text,
    invalid_before word64type,
    invalid_after word64type,
    collaterals json,
    inputs json,
    outputs json,
    withdrawals json,
    assets_minted json,
    metadata json,
    certificates json,
    native_scripts json,
    plutus_contracts json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _tx_hashes_bytea          bytea[];
  _tx_id_list               bigint[];
  _collateral_id_list       bigint[];
  _withdrawal_id_list       bigint[];
  _mint_id_list             bigint[];
  _metadata_id_list         bigint[];
  _cert_id_list             bigint[];
  _native_script_id_list    bigint[];
  _plutus_contract_id_list  bigint[];
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
  
  -- all tx with collateral
  SELECT INTO _collateral_id_list ARRAY_AGG(tx_id)
  FROM (
    SELECT
      tx_in_id AS tx_id
    FROM 
      collateral_tx_in
    WHERE collateral_tx_in.tx_in_id = ANY (_tx_id_list)
  ) AS tmp;
  
  -- all tx with withdrawals
  SELECT INTO _withdrawal_id_list ARRAY_AGG(tx_id)
  FROM (
    SELECT
      tx_id
    FROM 
      withdrawal
    WHERE withdrawal.tx_id = ANY (_tx_id_list)
  ) AS tmp;
  
  -- all tx with assets minted
  SELECT INTO _mint_id_list ARRAY_AGG(tx_id)
  FROM (
    SELECT
      tx_id
    FROM 
      ma_tx_mint
    WHERE ma_tx_mint.tx_id = ANY (_tx_id_list)
  ) AS tmp;
  
  -- all tx with metadata
  SELECT INTO _metadata_id_list ARRAY_AGG(tx_id)
  FROM (
    SELECT
      tx_id
    FROM 
      tx_metadata
    WHERE tx_metadata.tx_id = ANY (_tx_id_list)
  ) AS tmp;
  
  -- all tx with certificates
  SELECT INTO _cert_id_list ARRAY_AGG(DISTINCT(tx_id))
  FROM (
    SELECT tx_id
    FROM   stake_registration
    WHERE  stake_registration.tx_id = ANY (_tx_id_list)
    --
    UNION ALL
    --
    SELECT tx_id
    FROM   stake_deregistration
    WHERE  stake_deregistration.tx_id = ANY (_tx_id_list)
    --
    UNION ALL
    --
    SELECT tx_id
    FROM   delegation
    WHERE  delegation.tx_id = ANY (_tx_id_list)
    --
    UNION ALL
    --
    SELECT tx_id
    FROM   treasury
    WHERE  treasury.tx_id = ANY (_tx_id_list)
    --
    UNION ALL
    --
    SELECT tx_id
    FROM   reserve
    WHERE  reserve.tx_id = ANY (_tx_id_list)
    --
    UNION ALL
    --
    SELECT tx_id
    FROM   pot_transfer
    WHERE  pot_transfer.tx_id = ANY (_tx_id_list)
    --
    UNION ALL
    --
    SELECT registered_tx_id AS tx_id
    FROM   param_proposal
    WHERE  param_proposal.registered_tx_id = ANY (_tx_id_list)
    --
    UNION ALL
    --
    SELECT announced_tx_id AS tx_id
    FROM   pool_retire
    WHERE  pool_retire.announced_tx_id = ANY (_tx_id_list)
    --
    UNION ALL
    --
    SELECT tx_id
    FROM   grest.pool_info_cache
    WHERE  pool_info_cache.tx_id = ANY (_tx_id_list)
  ) AS tmp;
  
  -- all tx with native scripts
  SELECT INTO _native_script_id_list ARRAY_AGG(tx_id)
  FROM (
    SELECT tx_id
    FROM   script
    WHERE  script.tx_id = ANY (_tx_id_list)
           AND
           script.type = 'timelock'
  ) AS tmp;
  
  -- all tx with plutus contracts
  SELECT INTO _plutus_contract_id_list ARRAY_AGG(tx_id)
  FROM (
    SELECT tx_id
    FROM   redeemer
    WHERE  redeemer.tx_id = ANY (_tx_id_list)
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
              'tx_hash', ENCODE(tx.hash, 'hex'),
              'tx_index', tx_out.index,
              'value', tx_out.value::text,
              'asset_list', COALESCE((
                SELECT
                  JSON_AGG(JSON_BUILD_OBJECT(
                    'policy_id', ENCODE(MA.policy, 'hex'),
                    'asset_name', ENCODE(MA.name, 'hex'),
                    'quantity', MTX.quantity::text
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
            INNER JOIN tx ON tx_out.tx_id = tx.id
            LEFT JOIN stake_address SA on tx_out.stake_address_id = SA.id
          WHERE 
            tx_out.tx_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
      ),

      _all_collateral_inputs AS (
        SELECT
          tx_id,
          JSON_AGG(tc_inputs) AS list
        FROM (
          SELECT 
            collateral_tx_in.tx_in_id AS tx_id,
            JSON_BUILD_OBJECT(
              'payment_addr', JSON_BUILD_OBJECT(
                'bech32', tx_out.address,
                'cred', ENCODE(tx_out.payment_cred, 'hex')
              ),
              'stake_addr', SA.view,
              'tx_hash', ENCODE(tx.hash, 'hex'),
              'tx_index', tx_out.index,
              'value', tx_out.value::text,
              'asset_list', COALESCE((
                SELECT 
                  JSON_AGG(JSON_BUILD_OBJECT(
                    'policy_id', ENCODE(MA.policy, 'hex'),
                    'asset_name', ENCODE(MA.name, 'hex'),
                    'quantity', MTX.quantity::text
                  ))
                FROM 
                  ma_tx_out MTX
                  INNER JOIN MULTI_ASSET MA ON MA.id = MTX.ident
                WHERE 
                  MTX.tx_out_id = tx_out.id
              ), JSON_BUILD_ARRAY())
            ) AS tc_inputs
          FROM
            collateral_tx_in
            INNER JOIN tx ON collateral_tx_in.tx_in_id = tx.id
            INNER JOIN tx_out ON tx_out.tx_id = collateral_tx_in.tx_out_id
              AND tx_out.index = collateral_tx_in.tx_out_index
            LEFT JOIN stake_address SA ON tx_out.stake_address_id = SA.id
          WHERE 
            collateral_tx_in.tx_in_id = ANY (_collateral_id_list)
        ) AS tmp

        GROUP BY tx_id
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
              'value', tx_out.value::text,
              'asset_list', COALESCE((
                SELECT 
                  JSON_AGG(JSON_BUILD_OBJECT(
                    'policy_id', ENCODE(MA.policy, 'hex'),
                    'asset_name', ENCODE(MA.name, 'hex'),
                    'quantity', MTX.quantity::text
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
              'amount', W.amount::text,
              'stake_addr', SA.view
            ) AS data
          FROM 
            withdrawal W
            INNER JOIN stake_address SA ON W.addr_id = SA.id
          WHERE
            W.tx_id = ANY (_withdrawal_id_list)
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
              'quantity', MTM.quantity::text
            ) AS data
          FROM 
            ma_tx_mint MTM
            INNER JOIN MULTI_ASSET MA ON MA.id = MTM.ident
          WHERE
            MTM.tx_id = ANY (_mint_id_list)
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
            TM.tx_id = ANY (_metadata_id_list)
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
            SR.tx_id = ANY (_cert_id_list)
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
            SD.tx_id = ANY (_cert_id_list)
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
            D.tx_id = ANY (_cert_id_list)
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
                'amount', T.amount::text
              )
            ) AS data
          FROM 
            public.treasury T
            INNER JOIN public.stake_address SA ON SA.id = T.addr_id
          WHERE
            T.tx_id = ANY (_cert_id_list)
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
                'amount', R.amount::text
              )
            ) AS data
          FROM 
            public.reserve R
            INNER JOIN public.stake_address SA ON SA.id = R.addr_id
          WHERE
            R.tx_id = ANY (_cert_id_list)
          --
          UNION ALL
          --
          SELECT
            PT.tx_id,
            JSON_BUILD_OBJECT(
              'index', PT.cert_index,
              'type', 'pot_transfer',
              'info', JSON_BUILD_OBJECT(
                'treasury', PT.treasury::text,
                'reserves', PT.reserves::text
              )
            ) AS data
          FROM
            public.pot_transfer PT
          WHERE
            PT.tx_id = ANY (_cert_id_list)
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
            PP.registered_tx_id = ANY (_cert_id_list)
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
            PR.announced_tx_id = ANY (_cert_id_list)
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
                'fixed_cost', PIC.fixed_cost::text,
                'pledge', PIC.pledge::text,
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
            PIC.tx_id = ANY (_cert_id_list)
        ) AS tmp

        GROUP BY tx_id
      ),

      _all_native_scripts AS (
        SELECT
          tx_id,
          JSON_AGG(data) AS list
        FROM (
          SELECT
            script.tx_id,
            JSON_BUILD_OBJECT(
              'script_hash', ENCODE(script.hash, 'hex'),
              'script_json', script.json
            ) AS data
          FROM
            script
          WHERE
            script.tx_id = ANY (_native_script_id_list)
            AND
            script.type = 'timelock'
        ) AS tmp

        GROUP BY tx_id
      ),

      _all_plutus_contracts AS (
        SELECT
          tx_id,
          JSON_AGG(data) AS list
        FROM (
          SELECT
            redeemer.tx_id,
            JSON_BUILD_OBJECT(
              'address', INUTXO.address,
              'script_hash', ENCODE(script.hash, 'hex'),
              'bytecode', ENCODE(script.bytes, 'hex'),
              'size', script.serialised_size,
              'valid_contract', tx.valid_contract,
              'input', JSON_BUILD_OBJECT(
                'redeemer', JSON_BUILD_OBJECT(
                  'purpose', redeemer.purpose,
                  'fee', redeemer.fee::text,
                  'unit', JSON_BUILD_OBJECT(
                    'steps', redeemer.unit_steps::text,
                    'mem', redeemer.unit_mem::text
                  ),
                  'datum', JSON_BUILD_OBJECT(
                    'hash', ENCODE(rd.hash, 'hex'),
                    'value', rd.value
                  )
                ),
                'datum', JSON_BUILD_OBJECT(
                  'hash', ENCODE(ind.hash, 'hex'),
                  'value', ind.value
                )
              ),
              'output', CASE WHEN outd.hash IS NULL THEN NULL
                        ELSE
                          JSON_BUILD_OBJECT(
                            'hash', ENCODE(outd.hash, 'hex'),
                            'value', outd.value
                          )
                        END
            ) AS data
          FROM
            redeemer
            INNER JOIN tx ON redeemer.tx_id = tx.id
            INNER JOIN datum RD ON RD.id = redeemer.datum_id
            INNER JOIN script ON redeemer.script_hash = script.hash
            INNER JOIN tx_in ON tx_in.redeemer_id = redeemer.id
            INNER JOIN tx_out INUTXO ON INUTXO.tx_id = tx_in.tx_out_id AND INUTXO.index = tx_in.tx_out_index
            INNER JOIN datum IND ON IND.hash = INUTXO.data_hash
            LEFT JOIN tx_out OUTUTXO ON OUTUTXO.tx_id = redeemer.tx_id AND OUTUTXO.address = INUTXO.address
            LEFT JOIN datum OUTD ON OUTD.hash = OUTUTXO.data_hash
          WHERE
            redeemer.tx_id = ANY (_plutus_contract_id_list)
        ) AS tmp

        GROUP BY tx_id
      )

    SELECT
      ENCODE(ATX.tx_hash, 'hex'),
      ENCODE(ATX.block_hash, 'hex'),
      ATX.block_height,
      ATX.epoch AS epoch_no,
      ATX.epoch_slot,
      ATX.absolute_slot,
      ATX.tx_timestamp,
      ATX.tx_block_index,
      ATX.tx_size,
      ATX.total_output::text,
      ATX.fee::text,
      ATX.deposit::text,
      ATX.invalid_before,
      ATX.invalid_after,
      (CASE WHEN array_length(_collateral_id_list, 1) > 0 THEN (SELECT ACI.list FROM _all_collateral_inputs ACI WHERE ACI.tx_id = ATX.id) ELSE JSON_BUILD_ARRAY() END),
      COALESCE((SELECT AI.list FROM _all_inputs AI WHERE AI.tx_id = ATX.id), JSON_BUILD_ARRAY()),
      COALESCE((SELECT AO.list FROM _all_outputs AO WHERE AO.tx_id = ATX.id), JSON_BUILD_ARRAY()),
      (CASE WHEN array_length(_withdrawal_id_list, 1) > 0 THEN (SELECT AW.list FROM _all_withdrawals AW WHERE AW.tx_id = ATX.id) ELSE JSON_BUILD_ARRAY() END),
      (CASE WHEN array_length(_mint_id_list, 1) > 0 THEN (SELECT AMI.list FROM _all_mints AMI WHERE AMI.tx_id = ATX.id) ELSE JSON_BUILD_ARRAY() END),
      (CASE WHEN array_length(_metadata_id_list, 1) > 0 THEN (SELECT AME.list FROM _all_metadata AME WHERE AME.tx_id = ATX.id) ELSE JSON_BUILD_ARRAY() END),
      (CASE WHEN array_length(_cert_id_list, 1) > 0 THEN (SELECT AC.list FROM _all_certs AC WHERE AC.tx_id = ATX.id) ELSE JSON_BUILD_ARRAY() END),
      (CASE WHEN array_length(_native_script_id_list, 1) > 0 THEN (SELECT ANS.list FROM _all_native_scripts ANS WHERE ANS.tx_id = ATX.id) ELSE JSON_BUILD_ARRAY() END),
      (CASE WHEN array_length(_plutus_contract_id_list, 1) > 0 THEN (SELECT APC.list FROM _all_plutus_contracts APC WHERE APC.tx_id = ATX.id) ELSE JSON_BUILD_ARRAY() END)
    FROM
      _all_tx ATX
    WHERE ATX.tx_hash = ANY (_tx_hashes_bytea)
);

END;
$$;

COMMENT ON FUNCTION grest.tx_info IS 'Get information about transactions.';
