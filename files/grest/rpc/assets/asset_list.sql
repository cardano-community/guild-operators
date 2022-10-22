CREATE FUNCTION grest.asset_list (
  _asset_policies text[] DEFAULT null,
  _asset_names text[] DEFAULT null,
  _fingerprints text[] DEFAULT null
)
  RETURNS TABLE (
    policy_id text,
    asset_name text,
    fingerprint character varying
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _asset_policies_decoded bytea[];
  _asset_names_decoded bytea[];
BEGIN

  SELECT INTO _asset_policies_decoded ARRAY_AGG(policies_bytea)
  FROM (
    SELECT
      DECODE(policies_hex, 'hex') AS policies_bytea
    FROM
      UNNEST(_asset_policies) AS policies_hex
  ) AS tmp;

  SELECT INTO _asset_names_decoded ARRAY_AGG(names_bytea)
  FROM (
    SELECT
      DECODE(names_hex, 'hex') AS names_bytea
    FROM
      UNNEST(_asset_names) AS names_hex
  ) AS tmp;

  RETURN QUERY
    SELECT
      ENCODE(policy, 'hex'),
      ENCODE(name, 'hex'),
      MA.fingerprint
    FROM
      multi_asset MA
    WHERE
      (_asset_policies IS NULL OR MA.policy = any(_asset_policies_decoded))
      AND
      (_asset_names IS NULL OR MA.name = any(_asset_names_decoded))
      AND
      (_fingerprints IS NULL OR MA.fingerprint = any(_fingerprints));
END;
$$;

COMMENT ON FUNCTION grest.asset_list IS 'Get the list of all native assets';
