DROP FUNCTION IF EXISTS grest.rewards_history;

CREATE FUNCTION grest.rewards_history (_stake_address text DEFAULT NULL, _epoch_no numeric DEFAULT NULL)
    RETURNS TABLE (
        earned_epoch bigint,
        stake_pool character varying,
        reward_amount lovelace,
        reward_type rewardtype,
        spendable_epoch bigint)
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    IF _epoch_no IS NULL THEN
        RETURN QUERY (
            SELECT
                r.earned_epoch, ph.view, r.amount, r.type, r.spendable_epoch FROM reward AS r
                INNER JOIN stake_address AS sa ON r.addr_id = sa.id
                LEFT JOIN pool_hash AS ph ON r.pool_id = ph.id
            WHERE
                sa.view = _stake_address ORDER BY r.spendable_epoch DESC);
    ELSE
        RETURN QUERY (
            SELECT
                r.earned_epoch, ph.view, r.amount, r.type, r.spendable_epoch FROM reward AS r
                INNER JOIN stake_address AS sa ON r.addr_id = sa.id
                LEFT JOIN pool_hash AS ph ON r.pool_id = ph.id
            WHERE
                sa.view = _stake_address
                AND r.earned_epoch = _epoch_no);
    END IF;
END;
$$;

COMMENT ON FUNCTION grest.rewards_history IS 'Get the full rewards history in lovelace for a stake address, or certain epoch reward if specified';

