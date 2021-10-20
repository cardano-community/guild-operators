DROP FUNCTION IF EXISTS koios.account_updates (text);

CREATE FUNCTION koios.account_updates (_stake_address text)
  RETURNS TABLE (
    action_type text,
    tx_hash text)
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
  RETURN QUERY
  SELECT
    ACTIONS.action_type,
    ENCODE(TX.HASH, 'hex') AS tx_hash
  FROM ((
      SELECT
        'registration' AS action_type,
        tx_id
      FROM
        STAKE_REGISTRATION
      WHERE
        addr_id = SA_ID)
    UNION (
      SELECT
        'deregistration' AS action_type,
        tx_id
      FROM
        STAKE_DEREGISTRATION
      WHERE
        addr_id = SA_ID)
    UNION (
      SELECT
        'delegation' AS action_type,
        tx_id
      FROM
        DELEGATION
      WHERE
        addr_id = SA_ID)
    UNION (
      SELECT
        'withdrawal' AS action_type,
        tx_id
      FROM
        WITHDRAWAL
      WHERE
        addr_id = SA_ID)) ACTIONS
  INNER JOIN TX ON TX.ID = ACTIONS.TX_ID
ORDER BY
  TX.ID ASC,
  ACTIONS.action_type DESC;
  -- Ordering inside each transaction:
  -- Withdrawal -> Registration -> Delegation -> Deregistration
END;
$$;

COMMENT ON FUNCTION koios.account_updates IS 'Get the account updates (registration, deregistration, delegation and withdrawals)';

