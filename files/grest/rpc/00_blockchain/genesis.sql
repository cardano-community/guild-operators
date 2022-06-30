CREATE FUNCTION grest.genesis ()
  RETURNS TABLE (
    NETWORKMAGIC varchar,
    NETWORKID varchar,
    ACTIVESLOTCOEFF varchar,
    UPDATEQUORUM varchar,
    MAXLOVELACESUPPLY varchar,
    EPOCHLENGTH varchar,
    SYSTEMSTART numeric,
    SLOTSPERKESPERIOD varchar,
    SLOTLENGTH varchar,
    MAXKESREVOLUTIONS varchar,
    SECURITYPARAM varchar,
    ALONZOGENESIS varchar
  )
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    g.NETWORKMAGIC,
    g.NETWORKID,
    g.ACTIVESLOTCOEFF,
    g.UPDATEQUORUM,
    g.MAXLOVELACESUPPLY,
    g.EPOCHLENGTH,
    EXTRACT(epoch from g.SYSTEMSTART::timestamp),
    g.SLOTSPERKESPERIOD,
    g.SLOTLENGTH,
    g.MAXKESREVOLUTIONS,
    g.SECURITYPARAM,
    g.ALONZOGENESIS
  FROM
    grest.genesis g;
END;
$$;

COMMENT ON FUNCTION grest.tip IS 'Get the tip info about the latest block seen by chain';

