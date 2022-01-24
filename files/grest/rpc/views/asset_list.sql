DROP VIEW IF EXISTS grest.asset_list;

CREATE VIEW grest.asset_list AS
  SELECT
      ENCODE(policy, 'hex') AS policy_id,
      JSON_BUILD_OBJECT(
        'hex', JSON_AGG(name),
        'ascii', JSON_AGG(ENCODE(name, 'escape'))
      ) AS asset_names
  FROM 
    public.multi_asset MA
  GROUP BY
    policy;

COMMENT ON VIEW grest.asset_list IS 'Get the list of all native assets';
