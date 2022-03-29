DROP VIEW IF EXISTS grest.tx_metalabels;

CREATE VIEW grest.tx_metalabels AS SELECT DISTINCT
  key::text as metalabel
FROM
  public.tx_metadata;

COMMENT ON VIEW grest.tx_metalabels IS 'Get a list of all transaction metalabels';

