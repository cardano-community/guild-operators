CREATE OR REPLACE FUNCTION grest.rewards_history (_stake_address_bech32 text DEFAULT NULL, _epoch_no numeric DEFAULT NULL)
    RETURNS json STABLE
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    IF _epoch_no IS NULL THEN
        RETURN (
            SELECT
                json_agg(js) json_final
            FROM (
                SELECT
                    json_build_object('earned_epoch', reward.earned_epoch, 'stake_pool', pool_hash.view, 'reward_amount', reward.amount, 'reward_type', reward.type, 'spendable_epoch', reward.spendable_epoch) js
                FROM
                    reward
                    INNER JOIN stake_address ON reward.addr_id = stake_address.id
                    INNER JOIN pool_hash ON reward.pool_id = pool_hash.id
                WHERE
                    stake_address.view = _stake_address_bech32
                ORDER BY
                    spendable_epoch DESC) t);
    ELSE
        RETURN (
            SELECT
                json_agg(js) json_final
            FROM (
                SELECT
                    json_build_object('earned_epoch', reward.earned_epoch, 'stake_pool', pool_hash.view, 'reward_amount', reward.amount, 'reward_type', reward.type, 'spendable_epoch', reward.spendable_epoch) js
                FROM
                    reward
                    INNER JOIN stake_address ON reward.addr_id = stake_address.id
                    INNER JOIN pool_hash ON reward.pool_id = pool_hash.id
                WHERE
                    stake_address.view = _stake_address_bech32
                    AND reward.spendable_epoch = _epoch_no) t);
    END IF;
END;
$$;

COMMENT ON FUNCTION grest.rewards_history IS 'Get the full rewards history in lovelace for a stake address, or certain epoch reward if specified';

