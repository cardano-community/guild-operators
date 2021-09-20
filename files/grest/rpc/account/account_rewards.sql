DROP FUNCTION IF EXISTS grest.account_rewards (text, numeric);

CREATE FUNCTION grest.account_rewards (_stake_address text, _epoch_no numeric DEFAULT NULL)
  RETURNS TABLE (
    earned_epoch bigint,
    spendable_epoch bigint,
    amount lovelace,
    type rewardtype,
    pool_id character varying)
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  SA_ID integer DEFAULT NULL;
BEGIN
  SELECT
    STAKE_ADDRESS.ID INTO SA_ID
  FROM
    STAKE_ADDRESS
  WHERE
    STAKE_ADDRESS.VIEW = _stake_address;
  IF SA_ID IS NULL THEN
    RETURN;
  END IF;
  IF _epoch_no IS NULL THEN
    RETURN QUERY
    SELECT
      r.earned_epoch,
      r.spendable_epoch,
      r.amount,
      r.type,
      ph.view as pool_id
    FROM
      reward AS r
    LEFT JOIN pool_hash AS ph ON r.pool_id = ph.id
  WHERE
    r.addr_id = SA_ID
  ORDER BY
    r.spendable_epoch DESC;
  ELSE
    RETURN QUERY
    SELECT
      r.earned_epoch,
      r.spendable_epoch,
      r.amount,
      r.type,
      ph.view as pool_id
    FROM
      reward r
    LEFT JOIN pool_hash ph ON r.pool_id = ph.id
  WHERE
    r.addr_id = SA_ID
      AND r.earned_epoch = _epoch_no;
  END IF;
END;
$$;

COMMENT ON FUNCTION grest.account_rewards IS 'Get the full rewards history in lovelace for a stake address, or certain epoch reward if specified';

