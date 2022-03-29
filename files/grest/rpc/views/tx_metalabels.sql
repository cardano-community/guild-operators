CREATE VIEW grest.tx_metalabels AS SELECT DISTINCT
  key as metalabel
FROM
  public.tx_metadata;

COMMENT ON VIEW grest.tx_metalabels IS 'Get a list of all transaction metalabels';

