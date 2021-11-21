create or replace function grest.sync_tx_details (tx_hash_list bytea[])
  returns json stable
  language plpgsql
  as $$
declare
  tx_id_list_out bigint[];
  tx_id_list_in bigint[];
  tx_id_list bigint[];
  tx_id_in_list bigint[];
  addr_list text[];
begin
  -- ccw-lib/rpc/ISyncTxDetails
  -- all tx_out t_ids
  select
    into tx_id_list_out ARRAY_AGG(tx_id)
  from ( select distinct on (tx_id)
      tx_id
    from
      tx_out
      inner join tx on tx.id = tx_id
    where
      tx.hash = any (tx_hash_list)) as tmp_tx_id_list;
  -- all tx_in t_ids
  select
    into tx_id_list_in ARRAY_AGG(tx_id)
  from ( select distinct on (tx_in_id)
      tx_in_id as tx_id
    from
      tx_out
    left join tx_in on tx_out.tx_id = tx_in.tx_out_id
      and tx_out.index = tx_in.tx_out_index
  left join tx on tx.id = tx_out.tx_id
where
  tx_in.tx_in_id is not null
    and tx.hash = any (tx_hash_list)) as tmp_tx_id_list;
  -- combined tx_ids
  select
    into tx_id_list ARRAY_AGG(tx_id)
  from ( select distinct
      UNNEST(tx_id_list_out || tx_id_list_in) as tx_id) as tmp_tx_id_list;
  -- all tx_out ids off all the inputs of all combined tx
  select
    into tx_id_in_list ARRAY_AGG(tx_out_id)
  from ( select distinct on (tx_out_id)
      tx_out_id
    from
      tx_in
    where
      tx_in_id = any (tx_id_list)) as tmp_tx_id_list;
  return ( with
    -- limit by last known block, also join with block only once
    all_tx as (
      select
        tx.id,
        tx.hash,
        tx.block_index,
        tx.out_sum,
        tx.fee,
        tx.deposit,
        tx.size,
        tx.invalid_before,
        tx.invalid_hereafter,
        b.block_no,
        b.epoch_no,
        b.time
      from
        tx
        inner join block as b on tx.block_id = b.id
      where
        tx.id = any (tx_id_list)),
      all_outputs as (
        select
          tx_id,
          JSON_AGG(tx_out_list) as list
        from (
          select
            tx_out.tx_id,
            JSON_BUILD_OBJECT('paymentAddr', JSON_BUILD_OBJECT('bech32', tx_out.address, 'cred', REPLACE(tx_out.payment_cred::text, '\x', '')), 'stakeAddr', case when sa.view is null then
                null
              else
                JSON_BUILD_OBJECT('bech32', sa.view)
              end, 'txHash', REPLACE(all_tx.hash::text, '\x', ''), 'txIndex', tx_out.index, 'output', CAST(tx_out.value as text), 'tokenList', COALESCE((
                select
                  JSON_AGG(JSON_BUILD_OBJECT('name', REPLACE(t.name::text, '\x', ''), 'policy', REPLACE(t.policy::text, '\x', ''), 'quantity', CAST(t.quantity as text))) from ma_tx_out as t
                where
                  t.tx_out_id = tx_out.id), JSON_BUILD_ARRAY())) as tx_out_list
          from
            tx_out
            inner join all_tx on tx_out.tx_id = all_tx.id
            left join stake_address as sa on tx_out.stake_address_id = sa.id
          where
            tx_out.tx_id = any (tx_id_list)) as tmp
        group by
          tx_id
        order by
          tx_id),
        all_inputs as (
          select
            tx_id,
            JSON_AGG(tx_out_list) as list
          from (
            select
              tx_in.tx_in_id as tx_id,
              JSON_BUILD_OBJECT('paymentAddr', JSON_BUILD_OBJECT('bech32', tx_out.address, 'cred', REPLACE(tx_out.payment_cred::text, '\x', '')), 'stakeAddr', case when sa.view is null then
                  null
                else
                  JSON_BUILD_OBJECT('bech32', sa.view)
                end, 'txHash', REPLACE(tx.hash::text, '\x', ''), 'txIndex', tx_out.index, 'output', CAST(tx_out.value as text), 'tokenList', COALESCE((
                  select
                    JSON_AGG(JSON_BUILD_OBJECT('name', REPLACE(t.name::text, '\x', ''), 'policy', REPLACE(t.policy::text, '\x', ''), 'quantity', CAST(t.quantity as text))) from ma_tx_out as t
                  where
                    t.tx_out_id = tx_out.id), JSON_BUILD_ARRAY())) as tx_out_list
            from
              tx_out
              inner join tx on tx_out.tx_id = tx.id
              inner join tx_in on tx_in.tx_out_id = tx_out.tx_id
                and tx_in.tx_out_index = tx_out.index
            left join stake_address as sa on tx_out.stake_address_id = sa.id
          where
            tx_out.tx_id = any (tx_id_in_list)) as tmp
        group by
          tx_id
        order by
          tx_id),
        all_withdrawal as (
          -- mapping of tx to withdrawal json object
          select
            tx_id,
            JSON_AGG(data) as list
          from (
            select
              w.tx_id,
              JSON_BUILD_OBJECT('amount', CAST(w.amount as text), 'stakeAddr', case when sa.view is null then
                  null
                else
                  JSON_BUILD_OBJECT('bech32', sa.view)
                end, 'txHash', REPLACE(all_tx.hash::text, '\x', ''), 'blockNo', all_tx.block_no) as data
            from
              withdrawal as w
              inner join stake_address as sa on w.addr_id = sa.id
              inner join all_tx on w.tx_id = all_tx.id
            where
              w.tx_id = any (tx_id_list)) as tmp
          group by
            tx_id
          order by
            tx_id),
          all_metadata as (
            -- mapping of tx to tx_metadata json object
            select
              tx_id,
              JSON_AGG(data) as list
            from (
              select
                tm.tx_id,
                JSON_BUILD_OBJECT('key', CAST(tm.key as text), 'json', tm.json, 'bytes', REPLACE(tm.bytes::text, '\x', '')) as data
              from
                tx_metadata as tm
                inner join tx on tm.tx_id = tx.id
              where
                tm.tx_id = any (tx_id_list)) as tmp
            group by
              tx_id
            order by
              tx_id),
            all_mints as (
              -- mapping of tx to tx_mint json object
              select
                tx_id,
                JSON_AGG(data) as list
              from (
                select
                  t.tx_id,
                  JSON_BUILD_OBJECT('name', REPLACE(t.name::text, '\x', ''), 'policy', REPLACE(t.policy::text, '\x', ''), 'quantity', CAST(t.quantity as text)) as data
                from
                  ma_tx_mint as t
                where
                  t.tx_id = any (tx_id_list)) as tmp
              group by
                tx_id
              order by
                tx_id
)
              select
                JSON_BUILD_OBJECT('txList', JSON_AGG(JSON_BUILD_OBJECT('txHash', REPLACE(atx.hash::text, '\x', ''), 'deposit', CAST(atx.deposit as text), 'fee', CAST(atx.fee as text), 'totalOutput', CAST(atx.out_sum as text), 'blockIndex', atx.block_index, 'size', atx.size, 'invalidBefore', COALESCE(atx.invalid_before, 0), 'invalidHereafter', COALESCE(atx.invalid_hereafter, 0), 'blockNo', atx.block_no, 'blockTime', atx.time, 'epochNo', atx.epoch_no, 'inputList', COALESCE(ai.list, JSON_BUILD_ARRAY()), 'outputList', COALESCE(ao.list, JSON_BUILD_ARRAY()), 'metadataList', COALESCE(ame.list, JSON_BUILD_ARRAY()), 'mintList', COALESCE(ami.list, JSON_BUILD_ARRAY()), 'withdrawalList', COALESCE(awi.list, JSON_BUILD_ARRAY())))) as tx_list
              from
                all_tx atx
              left join all_inputs ai on ai.tx_id = atx.id
              left join all_outputs ao on ao.tx_id = atx.id
              left join all_metadata ame on ame.tx_id = atx.id
              left join all_mints ami on ami.tx_id = atx.id
              left join all_withdrawal awi on awi.tx_id = atx.id);
end;
$$;

