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
    inputs json,
    outputs json,
    withdrawals json,
    assets_minted json,
    invalid_before word64type,
    invalid_after word64type,
    certificates json)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    T1.tx_hash,
    T1.block_hash,
    T1.block_height,
    T1.epoch,
    T1.epoch_slot,
    T1.absolute_slot,
    T1.tx_timestamp,
    T1.tx_block_index,
    T1.tx_size,
    T1.total_output,
    T1.fee,
    T1.deposit,
    INPUTS_T.inputs,
    OUTPUTS_T.outputs,
    WITHDRAWALS_T.withdrawals,
    MINTED_T.assets_minted,
    T1.invalid_before,
    T1.invalid_after,
    JSON_STRIP_NULLS (CERTIFICATES_T.certificates)
  FROM (
    SELECT
      tx.id,
      ENCODE(tx.hash, 'hex') as tx_hash,
      ENCODE(b.hash, 'hex') as block_hash,
      b.block_no as block_height,
      b.epoch_no as epoch,
      b.epoch_slot_no as epoch_slot,
      b.slot_no as absolute_slot,
      b.time as tx_timestamp,
      tx.block_index as tx_block_index,
      tx.size as tx_size,
      tx.out_sum as total_output,
      tx.fee,
      tx.deposit,
      tx.invalid_before,
      tx.invalid_hereafter as invalid_after
    FROM
      public.tx
      INNER JOIN public.block b ON b.id = tx.block_id
    WHERE
      tx.hash::bytea = ANY (
        SELECT
          DECODE(hashes, 'hex')
        FROM
          UNNEST(_tx_hashes) AS hashes)) T1
  LEFT JOIN LATERAL (
    SELECT
      JSON_AGG(JSON_BUILD_OBJECT(
        'payment_addr', json_build_object(
          'bech32', tx_out.address,
          'cred', ENCODE(tx_out.payment_cred, 'hex')
          ),
        'stake_addr', SA.view,
        'tx_hash', T1.tx_hash,
        'tx_index', tx_out.index,
        'value', tx_out.value,
        'asset_list', COALESCE((SELECT JSON_AGG(JSON_BUILD_OBJECT(
          'policy_id', ENCODE(MTX.policy, 'hex'),
          'asset_name', ENCODE(MTX.name, 'hex'),
          'quantity', MTX.quantity
          ))
          FROM 
            ma_tx_out MTX
          WHERE 
            MTX.tx_out_id = tx_out.id), JSON_BUILD_ARRAY())
        )) AS outputs
    FROM
      tx_out
      LEFT JOIN stake_address SA ON tx_out.stake_address_id = SA.id
    WHERE
      tx_id = T1.id
    GROUP BY
      tx_id) OUTPUTS_T ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      JSON_AGG(JSON_BUILD_OBJECT(
        'payment_addr', json_build_object(
          'bech32', tx_out.address,
          'cred', ENCODE(tx_out.payment_cred, 'hex')
          ),
        'stake_addr', SA.view,
        'tx_hash', ENCODE(tx.hash, 'hex'),
        'tx_index', tx_out.index,
        'value', tx_out.value,
        'asset_list', COALESCE((SELECT JSON_AGG(JSON_BUILD_OBJECT(
          'policy_id', ENCODE(MTX.policy, 'hex'),
          'asset_name', ENCODE(MTX.name, 'hex'),
          'quantity', MTX.quantity
          ))
          FROM 
            ma_tx_out MTX
          WHERE 
            MTX.tx_out_id = tx_out.id), JSON_BUILD_ARRAY())
        )) AS inputs
    FROM
      tx_in
      INNER JOIN tx ON tx.id = tx_in.tx_out_id
      INNER JOIN tx_out ON tx_out.tx_id = tx_in.tx_out_id
        AND tx_out.index = tx_in.tx_out_index
      LEFT JOIN stake_address SA ON tx_out.stake_address_id = SA.id
    WHERE
      tx_in.tx_in_id = T1.id
    GROUP BY
      tx_in_id) INPUTS_T ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      JSON_AGG(JSON_BUILD_OBJECT(
        'amount', W.amount,
        'stake_addr', CASE WHEN SA.view IS NULL THEN NULL ELSE JSON_BUILD_OBJECT(
          'bech32', SA.view
          ) END
        )) AS withdrawals
    FROM
      withdrawal W
      INNER JOIN stake_address SA ON W.addr_id = SA.id
    WHERE
      W.tx_id = T1.id) WITHDRAWALS_T ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      JSON_AGG(JSON_BUILD_OBJECT(
        'policy_id', ENCODE(MTX.policy, 'hex'),
        'asset_name', ENCODE(MTX.name, 'hex'),
        'quantity', MTX.quantity
        )) AS assets_minted
    FROM
      ma_tx_mint MTX
    WHERE
      MTX.tx_id = T1.id) MINTED_T ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      COALESCE(
        --
        JSON_AGG(
          --
          JSON_BUILD_OBJECT(
            --
            'index', CERTIFICATES_SUB_T.index,
            --
            'type', CERTIFICATES_SUB_T.type,
            --
            'info', CERTIFICATES_SUB_T.info))
        --
        FILTER (WHERE CERTIFICATES_SUB_T.info IS NOT NULL), '[]') as certificates
    FROM (
      SELECT
        stake_registration.cert_index as index,
        'stake_registration' as type,
        JSON_BUILD_OBJECT('stake_address', stake_address.view) as info
      FROM
        public.stake_registration
        INNER JOIN public.stake_address ON stake_address.id = stake_registration.addr_id
      WHERE
        tx_id = T1.id
      UNION ALL
      SELECT
        stake_deregistration.cert_index as index,
        'stake_deregistration' as type,
        JSON_BUILD_OBJECT('stake_address', stake_address.view) as info
      FROM
        public.stake_deregistration
        INNER JOIN public.stake_address ON stake_address.id = stake_deregistration.addr_id
      WHERE
        tx_id = T1.id
      UNION ALL
      SELECT
        delegation.cert_index as index,
        'delegation' as type,
        JSON_BUILD_OBJECT('stake_address', stake_address.view, 'pool', pool_hash.view) as info
      FROM
        public.delegation
        INNER JOIN public.stake_address ON stake_address.id = delegation.addr_id
        INNER JOIN public.pool_hash ON pool_hash.id = delegation.pool_hash_id
      WHERE
        tx_id = T1.id
      UNION ALL
      SELECT
        NULL as index, -- Cert index in info for each MIR below
        'treasury_MIR' as type,
        JSON_BUILD_OBJECT(stake_address.view, treasury.amount, 'tx_index', treasury.cert_index) as info
      FROM
        public.treasury
        INNER JOIN public.stake_address ON stake_address.id = treasury.addr_id
      WHERE
        treasury.tx_id = T1.id
      UNION ALL
      SELECT
        NULL as index,
        'reserve_MIR' as type,
        JSON_BUILD_OBJECT(stake_address.view, reserve.amount, 'tx_index', reserve.cert_index) as info
      FROM
        public.reserve
        INNER JOIN public.stake_address ON stake_address.id = reserve.addr_id
      WHERE
        reserve.tx_id = T1.id
      UNION ALL
      SELECT
        NULL as index,
        'pot_transfer' as type,
        JSON_OBJECT_AGG('todo', '') as info
      FROM
        public.pot_transfer
      WHERE
        tx_id = T1.id
      UNION ALL
      -- SELECT DISTINCT below because there are multiple entries for each signing key of a given transaction
      SELECT DISTINCT ON (REGISTERED_TX_ID)
        NULL as index, -- No info provided
        'param_proposal' as type,
        JSON_STRIP_NULLS (JSON_BUILD_OBJECT('min_fee_a', param_proposal.min_fee_a,
            --
            'min_fee_b', param_proposal.min_fee_b,
            --
            'max_block_size', param_proposal.max_block_size,
            --
            'max_tx_size', param_proposal.max_tx_size,
            --
            'max_bh_size', param_proposal.max_bh_size,
            --
            'key_deposit', param_proposal.key_deposit,
            --
            'pool_deposit', param_proposal.pool_deposit,
            --
            'max_epoch', param_proposal.max_epoch,
            --
            'optimal_pool_count', param_proposal.optimal_pool_count,
            --
            'influence', param_proposal.influence,
            --
            'monetary_expand_rate', param_proposal.monetary_expand_rate,
            --
            'treasury_growth_rate', param_proposal.treasury_growth_rate,
            --
            'decentralisation', param_proposal.decentralisation,
            --
            'entropy', param_proposal.entropy,
            --
            'protocol_major', param_proposal.protocol_major,
            --
            'protocol_minor', param_proposal.protocol_minor,
            --
            'min_utxo_value', param_proposal.min_utxo_value,
            --
            'min_pool_cost', param_proposal.min_pool_cost,
            --
            'cost_models', param_proposal.cost_models,
            --
            'price_mem', param_proposal.price_mem,
            --
            'price_step', param_proposal.price_step,
            --
            'max_tx_ex_mem', param_proposal.max_tx_ex_mem,
            --
            'max_tx_ex_steps', param_proposal.max_tx_ex_steps,
            --
            'max_block_ex_mem', param_proposal.max_block_ex_mem,
            --
            'max_block_ex_steps', param_proposal.max_block_ex_steps,
            --
            'max_val_size', param_proposal.max_val_size,
            --
            'collateral_percent', param_proposal.collateral_percent,
            --
            'max_collateral_inputs', param_proposal.max_collateral_inputs,
            --
            'coins_per_utxo_word', param_proposal.coins_per_utxo_word)) as info
      FROM
        public.param_proposal
      WHERE
        registered_tx_id = T1.id
      UNION ALL
      SELECT
        pool_retire.cert_index as index,
        'pool_retire' as type,
        JSON_BUILD_OBJECT('pool', pool_hash.view, 'retiring epoch', pool_retire.retiring_epoch) as info
      FROM
        public.pool_retire
        INNER JOIN public.pool_hash ON pool_hash.id = pool_retire.hash_id
      WHERE
        announced_tx_id = T1.id
      UNION ALL
      SELECT
        pool_update.cert_index as index,
        'pool_update' as type,
        JSON_BUILD_OBJECT('pool', pool_hash.view, 'pledge', pool_update.pledge,
          --
          'reward_address', ENCODE(pool_update.reward_addr, 'hex'),
          --
          'margin', pool_update.margin, 'cost', pool_update.fixed_cost,
          --
          'metadata_url', pool_metadata_ref.url, 'metadata_hash',
          --
          ENCODE(pool_metadata_ref.hash, 'hex')) as info
      FROM
        public.pool_update
        INNER JOIN public.pool_hash ON pool_hash.id = pool_update.hash_id
        INNER JOIN public.pool_metadata_ref ON pool_metadata_ref.id = pool_update.meta_id
      WHERE
        pool_update.registered_tx_id = T1.id) CERTIFICATES_SUB_T) CERTIFICATES_T ON TRUE;
END;
$$;

COMMENT ON FUNCTION grest.tx_info IS 'Get information about transactions.';

