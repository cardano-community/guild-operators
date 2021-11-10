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

CREATE INDEX IF NOT EXISTS idx_asset ON grest.asset_registry_cache (asset_policy, asset_name);
