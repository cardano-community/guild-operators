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
    WITH txo_addr AS (
      SELECT address, stake_address_id FROM
        (SELECT
          DISTINCT ON (address) address, stake_address_id, id
        FROM
          TX_OUT
        WHERE stake_address_id = ANY(sa_id_list) ORDER BY address, id) x
        ORDER BY id
    )
    SELECT
      sa.view as stake_address,
      JSON_AGG(txo_addr.address) as addresses
    FROM
      txo_addr
      INNER JOIN STAKE_ADDRESS sa ON sa.id = txo_addr.stake_address_id
    GROUP BY
      sa.id;
END;
$$;

COMMENT ON FUNCTION grest.account_addresses IS 'Get all addresses associated with given accounts';

