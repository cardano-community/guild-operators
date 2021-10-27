drop table if exists grest.pool_history_cache;

CREATE TABLE grest.pool_history_cache (
	pool_id varchar NULL,
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
	epoch_ros numeric NULL
);


COMMENT ON TABLE grest.pool_history_cache IS 'A history of pool performance including blocks, delegators, active stake, fees and rewards';



DROP FUNCTION IF EXISTS grest.pool_history_cache_update CASCADE;

create function grest.pool_history_cache_update (_epoch_no_to_insert_from bigint)
returns void
language plpgsql
as $$
begin

-- TODO: add some validation of the parameter vs existing table contents perhaps?
	
-- purge the data for the given epoch range, in theory should do nothing if invoked only at start of new epoch
delete from grest.pool_history_cache where epoch_no >= _epoch_no_to_insert_from;
	
insert into grest.pool_history_cache
(
	with 
	
	blockcounts as (
		select sl.pool_hash_id, b.epoch_no, count(*) as block_cnt 
		from block b, slot_leader sl 
		where b.slot_leader_id = sl.id
		and epoch_no >= _epoch_no_to_insert_from
		group by sl.pool_hash_id, b.epoch_no
	),
	
	leadertotals as (
		select pool_id, earned_epoch, coalesce (sum(amount), 0) as leadertotal 
		from reward r 
		where r.type = 'leader'
		and earned_epoch >= _epoch_no_to_insert_from
		group by pool_id, earned_epoch
	),
	
	membertotals as (
		select pool_id, earned_epoch, coalesce (sum(amount), 0) as memtotal 
		from reward r 
		where r.type = 'member'
		and earned_epoch >= _epoch_no_to_insert_from
		group by pool_id, earned_epoch
	),
	
	activeandfees as (
		select pool_id, epoch_no, amount as active_stake,
		(select margin from pool_update where id = 
		(select max(pup2.id) from pool_hash ph, pool_update pup2 where pup2.hash_id = ph.id and ph.view = act.pool_id and pup2.active_epoch_no  <= act.epoch_no)) pool_fee_variable,
		(select fixed_cost from pool_update where id = 
		(select max(pup2.id) from pool_update pup2, pool_hash ph where ph.view = act.pool_id and pup2.hash_id = ph.id and pup2.active_epoch_no  <= act.epoch_no)) pool_fee_fixed,
		(amount / (select i_active_stake from grest.epoch_info_cache epInfo where epInfo.epoch = act.epoch_no)) * 100 active_stake_pct,
		round((amount / (select supply / (select p_optimal_pool_count from grest.epoch_info_cache where epoch = act.epoch_no) from grest.totals(act.epoch_no)) * 100), 2) saturation_pct
		
		from grest.active_stake_cache act
		where epoch_no >= _epoch_no_to_insert_from
		-- TODO: revisit later: currently ignore latest epoch as active stake might not be populated for it yet
		and epoch_no < (select max(e."no") from epoch e)
	),
	
	delegators as (
		select pool_id, epoch_no, count(*) as delegator_cnt 
		from epoch_stake es
		where epoch_no >= _epoch_no_to_insert_from
		group by pool_id, epoch_no
	)

	select 
	ph.view as pool_id, 
	actf.epoch_no,
    actf.active_stake, 
	actf.active_stake_pct, 
	actf.saturation_pct,
	coalesce(b.block_cnt,0) as block_cnt,
	del.delegator_cnt,
	actf.pool_fee_variable, 
	actf.pool_fee_fixed,
	-- for debugging: m.memtotal,
	-- for debugging: l.leadertotal,
	case coalesce(b.block_cnt,0)
		when 0 then 0
		else (actf.pool_fee_fixed + (((coalesce (m.memtotal, 0) + coalesce(l.leadertotal,0)) - actf.pool_fee_fixed) * actf.pool_fee_variable)) 
	end pool_fees,
	case coalesce(b.block_cnt,0)
		when 0 then 0
		else (coalesce(m.memtotal,0) + (coalesce(l.leadertotal,0) - (actf.pool_fee_fixed + (((coalesce(m.memtotal,0) + coalesce(l.leadertotal, 0)) - actf.pool_fee_fixed) * actf.pool_fee_variable)))) 
	end deleg_rewards,
	case coalesce(b.block_cnt,0)
		when 0 then 0
		else round((((pow((( ((coalesce(m.memtotal,0) + (coalesce(l.leadertotal,0) - (actf.pool_fee_fixed + (((coalesce(m.memtotal,0) + coalesce(l.leadertotal,0)) - actf.pool_fee_fixed) * actf.pool_fee_variable)))))  
		/ (actf.active_stake)) + 1), 73) - 1)) * 100)::numeric, 2)
	end epoch_ros
		
	from pool_hash ph 
	inner join activeandfees actf
		on actf.pool_id = ph."view"
	left join blockcounts b
		on ph.id = b.pool_hash_id and actf.epoch_no = b.epoch_no 
	left join leadertotals l
		on ph.id = l.pool_id and actf.epoch_no = l.earned_epoch 
	left join membertotals m 
		on ph.id = m.pool_id and actf.epoch_no = m.earned_epoch
	left join delegators del
		on ph.id = del.pool_id and actf.epoch_no = del.epoch_no
);
	
end;
$$;


COMMENT ON FUNCTION grest.pool_history_cache_update IS 'Internal function to update pool history for data from specified epoch until current-epoch-minus-one (can be tweaked to current epoch if we decide to do so)';

-- initial population of the history table, will take longer as the number of Cardano epochs grows
select * from grest.pool_history_cache_update(0);

