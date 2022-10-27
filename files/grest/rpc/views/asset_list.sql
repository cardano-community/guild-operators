DROP VIEW IF EXISTS grest.asset_list;

CREATE VIEW grest.asset_list AS
  SELECT
      ENCODE(MA.policy, 'hex') AS policy_id,
      ENCODE(MA.name, 'hex') AS asset_name,
      MA.fingerprint
  FROM 
    public.multi_asset MA
  ORDER BY MA.policy, MA.name;

COMMENT ON VIEW grest.asset_list IS 'Get the list of all native assets';
