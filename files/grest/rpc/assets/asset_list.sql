CREATE FUNCTION grest.asset_list ()
  RETURNS TABLE (
    policy_id text,
    asset_name text,
    fingerprint character varying
  )
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
    SELECT
      ENCODE(policy, 'hex'),
      ENCODE(name, 'hex'),
      MA.fingerprint
    FROM 
      public.multi_asset MA;
END;
$$;

COMMENT ON FUNCTION grest.asset_list IS 'Get the list of all native assets';
