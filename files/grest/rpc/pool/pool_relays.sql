DROP FUNCTION IF EXISTS grest.pool_relays(text);

CREATE FUNCTION grest.pool_relays(_pool_bech32 text)
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
BEGIN
    RETURN ( SELECT json_agg(js) json_final FROM ( SELECT json_build_object(
        'ipv4', pr.ipv4,
        'ipv6', pr.ipv6,
        'dns', pr.dns_name,
        'srv', pr.dns_srv_name,
        'port', pr.port
    ) js
    FROM public.pool_relay AS pr
    WHERE pr.update_id = (SELECT id from public.pool_hash where view=_pool_bech32)
    ) t );
END; $$;
COMMENT ON FUNCTION grest.pool_relays IS 'Get registered pool relays';
