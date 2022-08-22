CREATE FUNCTION grest.epoch_block_protocols (_epoch_no numeric DEFAULT NULL)
  RETURNS TABLE (
    proto_major word31type,
    proto_minor word31type,
    blocks bigint
  )
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  IF _epoch_no IS NOT NULL THEN
    RETURN QUERY
      SELECT
        b.proto_major,
        b.proto_minor,
        count(b.*)
      FROM
        block b
      WHERE
        b.epoch_no = _epoch_no::word31type
      GROUP BY
        b.proto_major, b.proto_minor;
  ELSE
    RETURN QUERY
      SELECT
        b.proto_major,
        b.proto_minor,
        count(b.*)
      FROM
        block b
      WHERE
        b.epoch_no = (SELECT MAX(no) FROM epoch)
      GROUP BY
        b.proto_major, b.proto_minor;
  END IF;
END;
$$;

COMMENT ON FUNCTION grest.epoch_block_protocols IS 'Get the information about block protocol distribution in epoch';
