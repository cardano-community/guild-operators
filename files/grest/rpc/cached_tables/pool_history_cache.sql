drop table if exists grest.pool_history_cache;

CREATE TABLE grest.pool_history_cache (
  pool_id varchar,
  epoch_no int8 NULL,
  active_stake lovelace NULL,
  active_stake_pct numeric NULL,
  saturation_pct numeric NULL,
  block_cnt int8 NULL,
  delegator_cnt int8 NULL,
  pool_fee_variable float8 NULL,
  pool_fee_fixed lovelace NULL,
  pool_fees float8 NULL,
  deleg_rewards float8 NULL,
  epoch_ros numeric NULL,
  PRIMARY KEY (pool_id, epoch_no)
);

COMMENT ON TABLE grest.pool_history_cache IS 'A history of pool performance including blocks, delegators, active stake, fees and rewards';

DROP FUNCTION IF EXISTS grest.pool_history_cache_update CASCADE;

create function grest.pool_history_cache_update (_epoch_no_to_insert_from bigint default NULL)
  returns void
  language plpgsql
  as $$
declare
  _curr_epoch bigint;
  _latest_epoch_no_in_cache bigint;
begin
   IF (
    SELECT
      COUNT(pid) > 1
    FROM
      pg_stat_activity
    WHERE
      state = 'active' AND query ILIKE '%GREST.pool_history_cache_update%') THEN
    RAISE EXCEPTION 'Previous pool_history_cache_update query still running but should have completed! Exiting...';
  END IF;

  if _epoch_no_to_insert_from is null then
    select
      COALESCE(MAX(epoch_no), 0) into _latest_epoch_no_in_cache
    from
      grest.pool_history_cache;
    -- special handling of the case where cron job might be invoked while setup-grest is still running
    -- we want the setup-grest to finish populating the table before we check for any needed updates
    if _latest_epoch_no_in_cache = 0 then
      return;
    end if;
    select
      MAX(no) into _curr_epoch
    from
      epoch;
    -- no-op if we already have data up until second most recent epoch
    if _latest_epoch_no_in_cache >= (_curr_epoch - 1) then
      return;
    end if;
    -- if current epoch is at least 2 ahead of latest in cache, repopulate from latest in cache until current-1
    _epoch_no_to_insert_from := _latest_epoch_no_in_cache;
  end if;
  -- purge the data for the given epoch range, in theory should do nothing if invoked only at start of new epoch
  delete from grest.pool_history_cache
  where epoch_no >= _epoch_no_to_insert_from;
  
  insert into grest.pool_history_cache ( with blockcounts as (
      select
        sl.pool_hash_id,
        b.epoch_no,
        COUNT(*) as block_cnt
      from
        block b,
        slot_leader sl
      where
        b.slot_leader_id = sl.id
        and epoch_no >= _epoch_no_to_insert_from
      group by
        sl.pool_hash_id,
        b.epoch_no),
      leadertotals as (
        select
          pool_id,
          earned_epoch,
          COALESCE(SUM(amount), 0) as leadertotal
        from
          reward r
        where
          r.type = 'leader'
          and earned_epoch >= _epoch_no_to_insert_from
        group by
          pool_id,
          earned_epoch),
        membertotals as (
          select
            pool_id,
            earned_epoch,
            COALESCE(SUM(amount), 0) as memtotal
          from
            reward r
          where
            r.type = 'member'
            and earned_epoch >= _epoch_no_to_insert_from
          group by
            pool_id,
            earned_epoch),
          activeandfees as (
            select
              pool_id,
              epoch_no,
              amount as active_stake,
              (
                select
                  margin
                from
                  pool_update
                where
                  id = (
                    select
                      MAX(pup2.id)
                    from
                      pool_hash ph,
                      pool_update pup2
                    where
                      pup2.hash_id = ph.id
                      and ph.view = act.pool_id
                      and pup2.active_epoch_no <= act.epoch_no)) pool_fee_variable,
                  (
                    select
                      fixed_cost
                    from
                      pool_update
                    where
                      id = (
                        select
                          MAX(pup2.id)
                        from
                          pool_update pup2,
                          pool_hash ph
                        where
                          ph.view = act.pool_id
                          and pup2.hash_id = ph.id
                          and pup2.active_epoch_no <= act.epoch_no)) pool_fee_fixed,
                    (amount / (
                        select
                          NULLIF(amount, 0)
                        from
                          grest.EPOCH_ACTIVE_STAKE_CACHE epochActiveStakeCache
                        where
                          epochActiveStakeCache.epoch_no = act.epoch_no)) * 100 active_stake_pct,
                      ROUND((amount / (
                          select
                            supply / (
                              select
                                p_optimal_pool_count from grest.epoch_info_cache
                              where
                                epoch = act.epoch_no)
                              from grest.totals (act.epoch_no)) * 100), 2) saturation_pct
                    from
                      grest.pool_active_stake_cache act
                    where
                      epoch_no >= _epoch_no_to_insert_from
                      -- TODO: revisit later: currently ignore latest epoch as active stake might not be populated for it yet
                      and epoch_no < (
                        select
                          MAX(e."no")
                        from
                          epoch e)),
                      delegators as (
                        select
                          pool_id,
                          epoch_no,
                          COUNT(*) as delegator_cnt
                        from
                          epoch_stake es
                        where
                          epoch_no >= _epoch_no_to_insert_from
                        group by
                          pool_id,
                          epoch_no
)
                        select
                          ph.view as pool_id,
                          actf.epoch_no,
                          actf.active_stake,
                          actf.active_stake_pct,
                          actf.saturation_pct,
                          COALESCE(b.block_cnt, 0) as block_cnt,
                          del.delegator_cnt,
                          actf.pool_fee_variable,
                          actf.pool_fee_fixed,
                          -- for debugging: m.memtotal,
                          -- for debugging: l.leadertotal,
                          case COALESCE(b.block_cnt, 0)
                          when 0 then
                            0
                          else
                            -- special case for when reward information is not available yet
                            case COALESCE(l.leadertotal, 0) + COALESCE(m.memtotal, 0)
                            when 0 then
                              null
                            else
                              ROUND(actf.pool_fee_fixed + (((COALESCE(m.memtotal, 0) + COALESCE(l.leadertotal, 0)) - actf.pool_fee_fixed) * actf.pool_fee_variable))
                            end
                          end pool_fees,
                          case COALESCE(b.block_cnt, 0)
                          when 0 then
                            0
                          else
                            -- special case for when reward information is not available yet
                            case COALESCE(l.leadertotal, 0) + COALESCE(m.memtotal, 0)
                            when 0 then
                              null
                            else
                              ROUND(COALESCE(m.memtotal, 0) + (COALESCE(l.leadertotal, 0) - (actf.pool_fee_fixed + (((COALESCE(m.memtotal, 0) + COALESCE(l.leadertotal, 0)) - actf.pool_fee_fixed) * actf.pool_fee_variable))))
                            end
                          end deleg_rewards,
                          case COALESCE(b.block_cnt, 0)
                          when 0 then
                            0
                          else
                            -- special case for when reward information is not available yet
                            case COALESCE(l.leadertotal, 0) + COALESCE(m.memtotal, 0)
                            when 0 then
                              null
                            else
                              -- using LEAST as a way to prevent overflow, in case of dodgy database data (e.g. giant rewards / tiny active stake)
                              ROUND((((POW(( LEAST(( ((COALESCE(m.memtotal, 0) + (COALESCE(l.leadertotal, 0) - (actf.pool_fee_fixed + (((COALESCE(m.memtotal, 0) + 
								              COALESCE(l.leadertotal, 0)) - actf.pool_fee_fixed) * actf.pool_fee_variable))))) / (NULLIF(actf.active_stake,0)) ), 1000) + 1), 73) - 1)) * 100)::numeric, 2)
                            end
                          end epoch_ros
                        from
                          pool_hash ph
                          inner join activeandfees actf on actf.pool_id = ph."view"
                          left join blockcounts b on ph.id = b.pool_hash_id
                            and actf.epoch_no = b.epoch_no
                        left join leadertotals l on ph.id = l.pool_id
                          and actf.epoch_no = l.earned_epoch
                      left join membertotals m on ph.id = m.pool_id
                        and actf.epoch_no = m.earned_epoch
                    left join delegators del on ph.id = del.pool_id
                      and actf.epoch_no = del.epoch_no);
           
           INSERT INTO GREST.CONTROL_TABLE (key, last_value)
              values('pool_history_cache_last_updated', now() at time zone 'utc')
           ON CONFLICT (key)
           DO UPDATE SET
              last_value = now() at time zone 'utc';
end;
$$;

COMMENT ON FUNCTION grest.pool_history_cache_update IS 'Internal function to update pool history for data from specified epoch until 
current-epoch-minus-one. Invoke with non-empty param for initial population, with empty for subsequent updates';

-- initial population of the history table, will take longer as the number of Cardano epochs grows
-- if we decide to remove the below and let cron-based invocation to populate it then need to adjust the update function logic and remove special case for empty table handling
select * from grest.pool_history_cache_update (0);

