DROP TABLE IF EXISTS grest.asset_registry_cache;

CREATE TABLE grest.asset_registry_cache (
    asset_policy text NOT NULL,
    asset_name text NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    ticker text,
    url text,
    logo text,
    decimals integer
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_asset ON grest.asset_registry_cache (asset_policy, asset_name);

CREATE FUNCTION grest.asset_registry_cache_update (
        _asset_policy text,
        _asset_name text,
        _name text,
        _description text,
        _ticker text DEFAULT NULL,
        _url text DEFAULT NULL,
        _logo text DEFAULT NULL,
        _decimals uinteger DEFAULT 0
    )
    RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO grest.asset_registry_cache (
        asset_policy,
        asset_name,
        name,
        description,
        ticker,
        url,
        logo,
        decimals
    )
    VALUES(
        _asset_policy, 
        _asset_name,
        _name,
        _description,
        _ticker,
        _url,
        _logo,
        _decimals
    )
    ON CONFLICT (asset_policy, asset_name)
    DO UPDATE SET
        name = _name,
        description = _description,
        ticker = _ticker,
        url = _url,
        logo = _logo,
        decimals = _decimals;
END;
$$;