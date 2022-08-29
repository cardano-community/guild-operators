CREATE FUNCTION grest.account_updates (_stake_addresses text[])
  RETURNS TABLE (
    stake_address varchar,
    updates json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  sa_id_list integer[] DEFAULT NULL;
BEGIN
  SELECT INTO sa_id_list
    ARRAY_AGG(STAKE_ADDRESS.ID) 
  FROM
    STAKE_ADDRESS
  WHERE
    STAKE_ADDRESS.VIEW = ANY(_stake_addresses);

  RETURN QUERY
    SELECT
      SA.view as stake_address,
      JSON_AGG(
        JSON_BUILD_OBJECT(
          'action_type', ACTIONS.action_type,
          'tx_hash', ENCODE(TX.HASH, 'hex'),
          'epoch_no', b.epoch_no,
          'epoch_slot', b.epoch_slot_no,
          'absolute_slot', b.slot_no,
          'block_time', EXTRACT(epoch from b.time)::integer
        )
      )
    FROM (
      (
        SELECT
          'registration' AS action_type,
          tx_id,
          addr_id
        FROM
          STAKE_REGISTRATION
        WHERE
          addr_id = ANY(sa_id_list)
      ) UNION (
        SELECT
          'deregistration' AS action_type,
          tx_id,
          addr_id
        FROM
          STAKE_DEREGISTRATION
        WHERE
          addr_id = ANY(sa_id_list)
      ) UNION (
        SELECT
          'delegation' AS action_type,
          tx_id,
          addr_id
        FROM
          DELEGATION
        WHERE
          addr_id = ANY(sa_id_list)
        ) UNION (
        SELECT
          'withdrawal' AS action_type,
          tx_id,
          addr_id
        FROM
          WITHDRAWAL
        WHERE
          addr_id = ANY(sa_id_list)
        )
    ) ACTIONS
      INNER JOIN TX ON TX.ID = ACTIONS.TX_ID
      INNER JOIN STAKE_ADDRESS sa ON sa.id = actions.addr_id
      INNER JOIN BLOCK b ON b.id = tx.block_id
    GROUP BY
      sa.id;
END;
$$;

COMMENT ON FUNCTION grest.account_updates IS 'Get updates (registration, deregistration, delegation and withdrawals) for given stake addresses';

