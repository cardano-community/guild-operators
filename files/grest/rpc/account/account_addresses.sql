CREATE FUNCTION grest.account_addresses (_stake_addresses text[])
  RETURNS TABLE (
    stake_address varchar,
    addresses json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  sa_id_list integer[];
BEGIN
  SELECT INTO sa_id_list
    ARRAY_AGG(STAKE_ADDRESS.ID)
  FROM
    STAKE_ADDRESS
  WHERE
    STAKE_ADDRESS.VIEW = ANY(_stake_addresses);

  RETURN QUERY
    SELECT
      sa.view as stake_address,
      JSON_AGG(
        DISTINCT(TX_OUT.address)
      ) as addresses
    FROM
      TX_OUT
      INNER JOIN STAKE_ADDRESS sa ON sa.id = tx_out.stake_address_id
    WHERE
      TX_OUT.STAKE_ADDRESS_ID = ANY(sa_id_list)
    GROUP BY
      sa.id;
END;
$$;

COMMENT ON FUNCTION grest.account_addresses IS 'Get all addresses associated with given accounts';

