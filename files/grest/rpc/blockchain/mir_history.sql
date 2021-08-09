CREATE OR REPLACE FUNCTION grest.mir_history (_stake_address_bech32 text DEFAULT NULL, _epoch_no numeric DEFAULT NULL)
    RETURNS TABLE (
        earned_epoch bigint,
        amount lovelace,
        reward_type rewardtype,
        spendable_epoch bigint)
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    IF _epoch_no IS NULL THEN
        RETURN QUERY
        SELECT
            reward.earned_epoch,
            reward.amount,
            reward.type,
            reward.spendable_epoch
        FROM
            reward
            INNER JOIN stake_address ON reward.addr_id = stake_address.id
        WHERE
            stake_address.view = _stake_address_bech32
            AND reward.type IN ('reserves', 'treasury')
        ORDER BY
            spendable_epoch DESC;
    ELSE
        RETURN QUERY
        SELECT
            reward.earned_epoch,
            reward.amount,
            reward.type,
            reward.spendable_epoch
        FROM
            reward
            INNER JOIN stake_address ON reward.addr_id = stake_address.id
        WHERE
            stake_address.view = _stake_address_bech32
            AND reward.type IN ('reserves', 'treasury')
            AND reward.earned_epoch = _epoch_no;
    END IF;
END;
$$;

COMMENT ON FUNCTION grest.rewards_history IS 'Get the full MIR history in lovelace for a stake address, or certain epoch if specified';

